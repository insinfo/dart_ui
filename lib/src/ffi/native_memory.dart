/// A native allocator for the FFI layer, with no package dependency.
///
/// `dart:ffi` ships an [Allocator] *interface* and no implementation, and this
/// repository's pubspec has no runtime dependency beyond `meta`, so
/// `package:ffi`'s `calloc` is not available to it. The GL backend already
/// solved this once (`NativeHeap` in `lib/src/rendering/gpu/gl/gl_bindings.dart`)
/// by binding `malloc` and `free` out of a library that is already loaded. This
/// is the same trick, moved down to the layer where it belongs so that COM code
/// does not have to depend on the OpenGL bindings to allocate sixteen bytes for
/// a GUID.
///
/// ## What was taken from `package:ffi`'s design, and what was not
///
/// The package is the reference design for this problem and there is no reason
/// to re-derive it. What was **adopted**:
///
///   * **[NativeArena], with block release.** `package:ffi`'s `Arena` allocates
///     freely and frees everything at once, and exposes both `releaseAll` and a
///     `using` scope function. COM is exactly the workload that shape is for:
///     every call that returns an interface needs an out-parameter and every
///     call that takes a descriptor needs a struct, all of them short lived and
///     all of them easy to leak on the error path - which is the path that runs
///     on the machine you cannot debug. So [NativeArena.releaseAll] and the
///     top-level [using] are here, spelled the same way.
///   * **`implements Allocator`.** Both the arena and the raw allocator
///     implement `dart:ffi`'s own interface, which is what makes
///     `arena<WndClassExW>()` work through the `AllocatorAlloc` extension and
///     what lets an arena be passed to anything that takes an `Allocator` -
///     including `win32_api.dart`, which already has one of its own.
///   * **`CoTaskMemAlloc` on Windows.** `package:ffi` allocates through the COM
///     task allocator there rather than through a C runtime, and the reason
///     applies here twice over. A Dart process can have more than one CRT
///     loaded (`msvcrt.dll` and `ucrtbase.dll` both export `malloc`), each with
///     its own heap, and a block allocated in one and freed in the other is
///     heap corruption that surfaces somewhere else entirely. `ole32.dll` is
///     loaded once and its allocator is *the* allocator COM itself uses, so a
///     buffer this file allocates and a buffer a COM method allocated are
///     freed by the same function.
///   * **The `Utf8` / `Utf16` conversions.** Windows is a UTF-16 API surface
///     from top to bottom, and a wrong conversion there is the class of bug
///     that works perfectly until somebody's user name has an accent in it.
///     See [NativeArena.allocateUtf16] and [readNativeUtf16].
///
/// What was **not** adopted, and why:
///
///   * **`Pointer<Utf8>` and `Pointer<Utf16>` as opaque marker types.** The
///     package declares `final class Utf8 extends Opaque {}` so that a string
///     pointer has a type of its own. That is a real improvement in a general
///     library and a cost here: every native signature in
///     `d3d11_bindings.dart` and `win32_api.dart` already spells its string
///     arguments `Pointer<Uint8>` or `Pointer<Uint16>`, matching the C
///     declaration, and introducing a second spelling would mean a cast at
///     every call site. The element type *is* the documentation here.
///   * **A process-wide `malloc` / `calloc` singleton pair.** The package
///     exports two allocators differing only in whether the memory is zeroed.
///     Everything in this repository wants it zeroed - every Windows descriptor
///     struct is filled field by field and the fields nobody sets have to be
///     zero, or `DXGI_SWAP_CHAIN_DESC1.Stereo` is a swap chain that fails to
///     create with an HRESULT naming nothing - so there is one allocator and it
///     always zeroes. A non-zeroing variant would be a footgun with no
///     measurable payoff at these sizes.
///   * **`allocate` counted in elements.** `package:ffi`'s `Allocator.allocate`
///     takes bytes and its `call` extension takes elements. This file keeps
///     both, unchanged, because the byte form is what every descriptor here
///     wants and silently reinterpreting the existing call sites as element
///     counts would be a change nothing would catch.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../foundation/lifecycle.dart';

/// Native memory, allocated and released by whatever this machine exports.
///
/// Bound lazily and once. [isAvailable] answers without throwing so a probe can
/// report "no allocator" as a diagnostic rather than as a stack trace - the
/// rule section 6.6 of the roadmap sets for every backend.
///
/// Implements `dart:ffi`'s [Allocator], so it can be handed to anything that
/// takes one and so the `AllocatorAlloc` extension's `allocator<T>(count)` form
/// works. Note the difference the interface itself defines and that is easy to
/// misread: [allocate] takes **bytes**, the `call` extension takes elements.
final class NativeAllocator implements Allocator {
  NativeAllocator._(this._allocate, this._release, this.provenance);

  final Pointer<Void> Function(int) _allocate;
  final void Function(Pointer<Void>) _release;

  /// Which pair was bound - `CoTaskMemAlloc/CoTaskMemFree (ole32.dll)`,
  /// `malloc/free (process)`, `malloc/free (msvcrt.dll)`.
  ///
  /// Reported rather than inferred, because the failure this file is most
  /// likely to be blamed for - a block allocated on one heap and freed on
  /// another - is invisible except through knowing which one was used.
  final String provenance;

  static NativeAllocator? _instance;
  static bool _attempted = false;

  /// The process-wide allocator, or null when nothing could be bound.
  ///
  /// The order is deliberate and is the whole reason this is a list:
  ///
  ///   1. **`ole32.dll`'s `CoTaskMemAlloc`/`CoTaskMemFree`** on Windows. The
  ///      COM task allocator: one heap, loaded once, and the same one every COM
  ///      method that returns a buffer allocated from. It needs no
  ///      `CoInitialize`.
  ///   2. **`DynamicLibrary.process()`'s `malloc`/`free`** everywhere else,
  ///      which on Linux and macOS is the one libc the process has.
  ///   3. **A named C runtime** as the last resort on Windows, for the case
  ///      where `ole32.dll` is somehow not loadable. Both halves come from the
  ///      *same* library handle, because mixing two CRTs' heaps is the failure
  ///      this ordering exists to avoid.
  static NativeAllocator? tryBind() {
    if (_attempted) return _instance;
    _attempted = true;
    for (final NativeAllocator? Function() attempt
        in <NativeAllocator? Function()>[
      _bindCoTaskMem,
      _bindProcessMalloc,
      _bindCrtMalloc,
    ]) {
      final NativeAllocator? bound = attempt();
      if (bound != null) return _instance = bound;
    }
    return null;
  }

  /// The allocator, or a [StateError] naming what was missing.
  ///
  /// For call sites that are already past the probe and for which "no
  /// allocator" is not a recoverable state.
  static NativeAllocator get instance {
    final NativeAllocator? bound = tryBind();
    if (bound == null) {
      throw StateError(
        'no native allocator: neither ole32.dll, DynamicLibrary.process() nor '
        'a C runtime exported an allocation pair on this platform',
      );
    }
    return bound;
  }

  static bool get isAvailable => tryBind() != null;

  /// Drops the binding. Only for a test that wants to observe a fresh bind.
  static void debugReset() {
    _attempted = false;
    _instance = null;
  }

  static NativeAllocator? _bindCoTaskMem() {
    if (!Platform.isWindows) return null;
    try {
      final DynamicLibrary ole32 = DynamicLibrary.open('ole32.dll');
      final allocate = ole32.lookupFunction<Pointer<Void> Function(IntPtr),
          Pointer<Void> Function(int)>('CoTaskMemAlloc');
      final release = ole32.lookupFunction<Void Function(Pointer<Void>),
          void Function(Pointer<Void>)>('CoTaskMemFree');
      return NativeAllocator._(
          allocate, release, 'CoTaskMemAlloc/CoTaskMemFree (ole32.dll)');
    } on Object {
      return null;
    }
  }

  static NativeAllocator? _bindProcessMalloc() {
    try {
      // Unsupported on Windows, where it throws. Expected, not exceptional.
      final DynamicLibrary process = DynamicLibrary.process();
      return _bindMalloc(process, 'malloc/free (process)');
    } on Object {
      return null;
    }
  }

  static NativeAllocator? _bindCrtMalloc() {
    if (!Platform.isWindows) return null;
    for (final String name in const <String>['msvcrt.dll', 'ucrtbase.dll']) {
      try {
        final NativeAllocator? bound =
            _bindMalloc(DynamicLibrary.open(name), 'malloc/free ($name)');
        if (bound != null) return bound;
      } on Object {
        continue;
      }
    }
    return null;
  }

  static NativeAllocator? _bindMalloc(
      DynamicLibrary library, String provenance) {
    try {
      final allocate = library.lookupFunction<Pointer<Void> Function(IntPtr),
          Pointer<Void> Function(int)>('malloc');
      final release = library.lookupFunction<Void Function(Pointer<Void>),
          void Function(Pointer<Void>)>('free');
      return NativeAllocator._(allocate, release, provenance);
    } on Object {
      return null;
    }
  }

  /// [byteCount] bytes of zeroed native memory - **bytes**, not elements of
  /// `T`.
  ///
  /// Zeroed because every Windows descriptor struct in this repository is
  /// filled field by field and the fields nobody sets have to be zero:
  /// `DXGI_SWAP_CHAIN_DESC1.Stereo` left as garbage is a swap chain that fails
  /// to create with an HRESULT that names nothing.
  ///
  /// [alignment] is accepted because [Allocator] declares it, and is honoured
  /// only up to what the underlying allocator already guarantees. Both
  /// `CoTaskMemAlloc` and `malloc` return memory suitably aligned for any
  /// fundamental type, which is 16 bytes on every platform this runs on.
  /// Anything stricter is refused by name rather than returned misaligned,
  /// because a silently misaligned SIMD load faults a long way from here.
  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    if (byteCount < 0) {
      throw ArgumentError.value(byteCount, 'byteCount', 'must not be negative');
    }
    if (alignment != null && alignment > 16) {
      throw ArgumentError.value(
        alignment,
        'alignment',
        'this allocator guarantees 16-byte alignment and cannot promise more; '
            'over-allocate and align by hand if a stricter one is needed',
      );
    }
    final Pointer<Void> pointer = _allocate(byteCount);
    if (pointer == nullptr) {
      throw StateError('$provenance returned null for $byteCount bytes');
    }
    if (byteCount > 0) {
      pointer.cast<Uint8>().asTypedList(byteCount).fillRange(0, byteCount, 0);
    }
    return pointer.cast<T>();
  }

  @override
  void free(Pointer<NativeType> pointer) {
    if (pointer == nullptr) return;
    _release(pointer.cast<Void>());
  }

  /// The old name for [free]. Kept because call sites spell it this way and
  /// renaming them buys nothing.
  void release(Pointer<NativeType> pointer) => free(pointer);

  @override
  String toString() => 'NativeAllocator($provenance)';
}

/// A scope of native allocations released in reverse order.
///
/// `package:ffi`'s `Arena` in this repository's own idiom: allocate freely,
/// release in one call. Built on [DisposableBag] rather than a list of its own,
/// so the "last acquired, first released" rule lives in exactly one place in
/// the framework and a release that throws still lets the rest run.
///
/// Implements [Allocator], so `arena<Uint32>(4)` allocates four `UINT`s through
/// the `AllocatorAlloc` extension and `arena.allocate<Uint8>(44)` allocates
/// forty-four bytes. Both spellings are used in this repository and the
/// difference between them is the interface's, not this class's.
final class NativeArena with DisposableMixin implements Allocator {
  NativeArena() : _allocator = NativeAllocator.instance;

  /// An arena over an allocator the caller chose - a test double, or the
  /// process heap allocator `win32_api.dart` already owns.
  NativeArena.over(this._allocator);

  final NativeAllocator _allocator;

  /// Replaced wholesale by [releaseAll] rather than emptied, so the ordering
  /// guarantee stays [DisposableBag]'s and this class never walks a list of
  /// pointers itself.
  DisposableBag _bag = DisposableBag();

  /// [byteCount] bytes of zeroed memory owned by this arena.
  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    throwIfDisposed();
    final Pointer<T> pointer =
        _allocator.allocate<T>(byteCount, alignment: alignment);
    _bag.add(pointer, () => _allocator.free(pointer));
    return pointer;
  }

  /// Does nothing, deliberately, exactly as `package:ffi`'s `Arena.free` does.
  ///
  /// An arena's contract is that its memory outlives every individual use and
  /// dies once, at [releaseAll] or [dispose]. Freeing one pointer early would
  /// leave the bag holding a release for memory that is already gone, which is
  /// a double free at teardown - the failure this class exists to remove. The
  /// method is here because [Allocator] declares it and because a caller that
  /// hands an arena to code expecting an allocator must get arena behaviour.
  @override
  void free(Pointer<NativeType> pointer) {}

  /// Releases every allocation and leaves this arena usable.
  ///
  /// The `reuse: true` half of `package:ffi`'s `Arena.releaseAll`, and the
  /// reason it is worth having separately from [dispose]: a frame loop or a
  /// retry loop can keep one arena and empty it per iteration instead of
  /// building a new one, and the object handing the arena around does not have
  /// to be told that its reference went stale.
  void releaseAll() {
    throwIfDisposed();
    final DisposableBag previous = _bag;
    _bag = DisposableBag();
    previous.dispose();
  }

  /// A slot for one out-parameter of pointer width, zeroed.
  Pointer<Pointer<Void>> allocateOutPointer() =>
      allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());

  /// A null-terminated ASCII copy of [value], for the `LPCSTR` arguments the
  /// D3D compiler and the input-layout descriptor take.
  ///
  /// ASCII and not UTF-8 on purpose: every string that crosses here is a shader
  /// entry point, a target profile or a semantic name, all of which are spelled
  /// in the ASCII subset by the very APIs that read them. A non-ASCII code unit
  /// is a caller bug and is refused rather than silently truncated. Use
  /// [allocateUtf8] for text that is genuinely text.
  Pointer<Uint8> allocateAscii(String value) {
    final Pointer<Uint8> pointer = allocate<Uint8>(value.length + 1);
    final Uint8List list = pointer.asTypedList(value.length + 1);
    for (var i = 0; i < value.length; i++) {
      final int unit = value.codeUnitAt(i);
      if (unit > 0x7F) {
        throw ArgumentError.value(value, 'value', 'not ASCII at index $i');
      }
      list[i] = unit;
    }
    list[value.length] = 0;
    return pointer;
  }

  /// A null-terminated UTF-8 copy of [value].
  ///
  /// `package:ffi`'s `String.toNativeUtf8`, in this arena. Note that the
  /// terminator is one byte and the *length* is in bytes, not code units: a
  /// caller that sizes a buffer from `value.length` is wrong for every string
  /// outside ASCII, which is the whole reason this is a method and not a loop
  /// at the call site.
  Pointer<Uint8> allocateUtf8(String value) {
    final List<int> encoded = utf8.encode(value);
    final Pointer<Uint8> pointer = allocate<Uint8>(encoded.length + 1);
    final Uint8List list = pointer.asTypedList(encoded.length + 1);
    list.setRange(0, encoded.length, encoded);
    list[encoded.length] = 0;
    return pointer;
  }

  /// A null-terminated UTF-16 copy of [value], which is what every `W` entry
  /// point on Windows takes.
  ///
  /// `package:ffi`'s `String.toNativeUtf16`, in this arena, and the conversion
  /// is a copy rather than a transcode: **a Dart `String` is already UTF-16**,
  /// and [String.codeUnits] is exactly the sequence a `LPCWSTR` wants,
  /// surrogate pairs included. Anything that walked runes and re-encoded them
  /// would produce the same bytes with more code and one more chance to get an
  /// astral character wrong.
  ///
  /// The terminator is a 16-bit zero, not an 8-bit one. Writing a single zero
  /// byte leaves a `LPCWSTR` unterminated and is read past the end of the
  /// allocation by the first API that takes it.
  Pointer<Uint16> allocateUtf16(String value) {
    final List<int> units = value.codeUnits;
    final Pointer<Uint16> pointer = allocate<Uint16>((units.length + 1) * 2);
    final Uint16List list = pointer.asTypedList(units.length + 1);
    list.setRange(0, units.length, units);
    list[units.length] = 0;
    return pointer;
  }

  /// How many allocations are outstanding. For tests and leak reports.
  int get length => _bag.length;

  /// Which allocator this arena hands out memory from. For a leak report.
  NativeAllocator get allocator => _allocator;

  @override
  void onDispose() => _bag.dispose();
}

/// Runs [action] with a fresh [NativeArena] and releases it afterwards.
///
/// `package:ffi`'s `using`, and the reason to have it is that the alternative
/// spelling - `final arena = NativeArena(); try { ... } finally { arena
/// .dispose(); }` - is four lines whose middle one is the only one that varies,
/// and the `finally` is the line that gets dropped when the body grows an early
/// return. The release runs whether [action] returns or throws.
R using<R>(R Function(NativeArena arena) action) {
  final NativeArena arena = NativeArena();
  try {
    return action(arena);
  } finally {
    arena.dispose();
  }
}

/// The bytes at [pointer] up to the first NUL, as a Dart string.
///
/// [limit] bounds the scan: a compiler error blob that is not NUL-terminated
/// would otherwise walk off the end of the allocation.
String readNativeAscii(Pointer<Uint8> pointer, {required int limit}) {
  if (pointer == nullptr || limit <= 0) return '';
  final Uint8List bytes = pointer.asTypedList(limit);
  var end = 0;
  while (end < limit && bytes[end] != 0) {
    end++;
  }
  return String.fromCharCodes(bytes, 0, end);
}

/// The UTF-8 bytes at [pointer] up to the first NUL, decoded.
///
/// `package:ffi`'s `Pointer<Utf8>.toDartString`, with the bound made mandatory
/// rather than optional. [limit] is in **bytes**.
///
/// Malformed sequences are replaced rather than thrown on: this decodes
/// whatever a native library handed back, and a diagnostic that throws while
/// being formatted loses the failure it was describing.
String readNativeUtf8(Pointer<Uint8> pointer, {required int limit}) {
  if (pointer == nullptr || limit <= 0) return '';
  final Uint8List bytes = pointer.asTypedList(limit);
  var end = 0;
  while (end < limit && bytes[end] != 0) {
    end++;
  }
  return utf8.decode(Uint8List.sublistView(bytes, 0, end),
      allowMalformed: true);
}

/// The UTF-16 code units at [pointer] up to the first NUL, as a Dart string.
///
/// `package:ffi`'s `Pointer<Utf16>.toDartString`, and the same argument as
/// [NativeArena.allocateUtf16] in reverse: a Dart `String` is UTF-16, so this
/// is a copy and not a transcode, and a surrogate pair survives it untouched.
///
/// [limit] is in **code units**, not bytes. Getting that wrong reads twice as
/// far as intended, which for a fixed-size field such as
/// `DXGI_ADAPTER_DESC.Description` - 128 code units - means running off the end
/// of the structure.
String readNativeUtf16(Pointer<Uint16> pointer, {required int limit}) {
  if (pointer == nullptr || limit <= 0) return '';
  final Uint16List units = pointer.asTypedList(limit);
  var end = 0;
  while (end < limit && units[end] != 0) {
    end++;
  }
  return String.fromCharCodes(units, 0, end);
}
