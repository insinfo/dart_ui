/// COM in pure Dart: vtables, `IUnknown`, `GUID` and `HRESULT`.
///
/// Promoted from `poc/poc_05_com_direct2d/bin/direct2d_windows.dart`, which
/// proved the three things this file exists to make reusable: that a Dart
/// `Pointer` can be treated as a COM interface pointer, that the first machine
/// word of such an object is a pointer to a table of function pointers, and
/// that a 16-byte `GUID` handed to a native call has to be laid out exactly the
/// way the C struct is.
///
/// What was promoted and what was rewritten is worth stating, because the POC
/// still works and this is deliberately not a copy of it:
///
///   * **Promoted**: the vtable-dispatch idea, the GUID field layout (three
///     integers and eight bytes, not sixteen bytes), the HRESULT-is-signed
///     convention, and the process-heap allocation discipline.
///   * **Rewritten**: everything about *shape*. The POC declares one `Struct`
///     per interface with `@Array(n)` padding to reach the method it wants,
///     which is fine for a demo and unusable as infrastructure - the padding
///     has to be recounted for every new method, a miscount is silent, and
///     `Release` is spelled once per interface. This file indexes the vtable
///     by integer instead, so an interface is a *list of slot numbers* and a
///     new method costs one constant. Reference counting, `QueryInterface` and
///     ordered teardown, none of which the POC had, are the rest of it.
///
/// ## Reference counting is where COM leaks
///
/// Every `Create*` on a COM API hands back a reference the caller owns, and
/// every interface obtained from `QueryInterface` is another one. Miss one
/// `Release` and the object survives the process; call one too many and the
/// next use is a read of freed memory that usually still looks like a vtable.
/// Neither failure shows up in the picture on screen.
///
/// So [ComObject] owns exactly one reference and releases exactly once
/// ([DisposableMixin] guarantees the idempotence), [ComBag] releases a group in
/// reverse acquisition order through [DisposableBag], and [ComObject.refCount]
/// exposes the count so a test can *prove* the balance rather than assume it.
/// That last one is the reason this file is testable at all: the count is not
/// readable in COM, but `AddRef` followed by `Release` returns it, and the pair
/// is balanced by construction.
///
/// ## Nothing here is Windows-specific at compile time
///
/// COM is a Windows ABI, but this file names no Windows type and loads no
/// library: it manipulates pointers and integers. It therefore analyses and
/// imports cleanly on Linux and macOS, where the tests that would call into a
/// real object skip by `Platform.isWindows` and the ones that only check
/// layout and arithmetic - GUID bytes, HRESULT names - still run.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../foundation/lifecycle.dart';
import 'native_memory.dart';

// ---------------------------------------------------------------------------
// HRESULT
// ---------------------------------------------------------------------------

/// The success codes and failures this framework has to tell apart by name.
///
/// Not an exhaustive list of Windows error codes and not meant to become one.
/// A code that is not here is reported by its hexadecimal value, which is what
/// a bug report needs; a code that *is* here is one the renderer branches on
/// or one whose bare number has cost somebody an afternoon.
const int sOk = 0x00000000;
const int sFalse = 0x00000001;

const int eNoInterface = -2147467262; // 0x80004002
const int eFail = -2147467259; // 0x80004005
const int eInvalidArg = -2147024809; // 0x80070057
const int eOutOfMemory = -2147024882; // 0x8007000E
const int eNotImplemented = -2147467263; // 0x80004001
const int ePointer = -2147467261; // 0x80004003
const int eAccessDenied = -2147024891; // 0x80070005
const int eHandle = -2147024890; // 0x80070006

/// The DXGI codes that mean the device is gone, and the one that means the
/// caller broke the rules.
///
/// These live here rather than in the D3D11 bindings because they are HRESULTs
/// like any other and [hresultName] has to be able to spell them: a present
/// that fails with `0x887a0005` and no name is the exact failure section 6.6
/// exists to forbid.
const int dxgiErrorInvalidCall = -2005270527; // 0x887A0001
const int dxgiErrorDeviceRemoved = -2005270523; // 0x887A0005
const int dxgiErrorDeviceHung = -2005270522; // 0x887A0006
const int dxgiErrorDeviceReset = -2005270521; // 0x887A0007
const int dxgiErrorDriverInternalError = -2005270496; // 0x887A0020
const int dxgiErrorWasStillDrawing = -2005270518; // 0x887A000A
const int dxgiErrorUnsupported = -2005270524; // 0x887A0004
const int dxgiErrorNotFound = -2005270526; // 0x887A0002
const int dxgiStatusOccluded = 0x087A0002;

const Map<int, String> _hresultNames = <int, String>{
  sOk: 'S_OK',
  sFalse: 'S_FALSE',
  eNoInterface: 'E_NOINTERFACE',
  eFail: 'E_FAIL',
  eInvalidArg: 'E_INVALIDARG',
  eOutOfMemory: 'E_OUTOFMEMORY',
  eNotImplemented: 'E_NOTIMPL',
  ePointer: 'E_POINTER',
  eAccessDenied: 'E_ACCESSDENIED',
  eHandle: 'E_HANDLE',
  dxgiErrorInvalidCall: 'DXGI_ERROR_INVALID_CALL',
  dxgiErrorDeviceRemoved: 'DXGI_ERROR_DEVICE_REMOVED',
  dxgiErrorDeviceHung: 'DXGI_ERROR_DEVICE_HUNG',
  dxgiErrorDeviceReset: 'DXGI_ERROR_DEVICE_RESET',
  dxgiErrorDriverInternalError: 'DXGI_ERROR_DRIVER_INTERNAL_ERROR',
  dxgiErrorWasStillDrawing: 'DXGI_ERROR_WAS_STILL_DRAWING',
  dxgiErrorUnsupported: 'DXGI_ERROR_UNSUPPORTED',
  dxgiErrorNotFound: 'DXGI_ERROR_NOT_FOUND',
  dxgiStatusOccluded: 'DXGI_STATUS_OCCLUDED',
};

/// An `HRESULT` as a signed 32-bit value.
///
/// The normalisation matters. `dart:ffi` returns an `Int32` return type as a
/// signed Dart int, so `0x887A0005` arrives as a negative number - but a
/// constant written in a Dart source file as `0x887A0005` is *positive*,
/// because Dart integers are 64-bit. Comparing the two directly is never
/// equal, which is how a device-removed check silently stops firing. Every
/// entry point in this file runs its argument through here first.
int hresult(int value) => value.toSigned(32);

/// Whether [value] is a success code. COM's own rule: the sign bit.
bool succeeded(int value) => hresult(value) >= 0;

/// Whether [value] is a failure code.
bool failed(int value) => hresult(value) < 0;

/// The name of [value] if it has one, and its hexadecimal value always.
///
/// Both, never one or the other. The name is what a reader recognises; the
/// number is what a search engine and a driver's own documentation index.
String hresultName(int value) {
  final int code = hresult(value);
  final String hex =
      '0x${code.toUnsigned(32).toRadixString(16).padLeft(8, '0')}';
  final String? name = _hresultNames[code];
  return name == null ? hex : '$name ($hex)';
}

/// Raised when a COM call that had to succeed did not.
///
/// An [Error] rather than an exception because reaching it means the caller
/// asked for something it had already established was possible. The recoverable
/// cases - a probe, a present against a removed device - do not come through
/// here; they read the HRESULT and report a `BackendDiagnostic`.
final class ComError extends Error {
  ComError({
    required this.hresult,
    required this.operation,
    this.detail,
  });

  /// The raw code, already signed.
  final int hresult;

  /// What was being attempted, named the way the native API names it -
  /// `ID3D11Device::CreateTexture2D`, not `createTexture`.
  final String operation;

  final String? detail;

  String get name => hresultName(hresult);

  @override
  String toString() => detail == null
      ? 'ComError: $operation failed with $name'
      : 'ComError: $operation failed with $name ($detail)';
}

/// Returns [value] when it succeeded, throws [ComError] naming [operation]
/// otherwise.
int checkHresult(int value, String operation, {String? detail}) {
  final int code = hresult(value);
  if (code < 0) {
    throw ComError(hresult: code, operation: operation, detail: detail);
  }
  return code;
}

// ---------------------------------------------------------------------------
// GUID
// ---------------------------------------------------------------------------

/// A COM interface identifier: 16 bytes, in the layout the C struct has.
///
/// ## The layout is the whole point
///
/// A `GUID` is **not** sixteen bytes in text order. It is
///
///     DWORD Data1;     // 4 bytes, little-endian on every platform COM runs on
///     WORD  Data2;     // 2 bytes, little-endian
///     WORD  Data3;     // 2 bytes, little-endian
///     BYTE  Data4[8];  // 8 bytes, in order
///
/// so the first three groups of the canonical text are *numbers* and reach
/// memory back-to-front, while the last two groups are *bytes* and reach it in
/// the order they are written. `db6f6ddb-ac77-4e88-8253-819df9bbf140` is
///
///     db 6d 6f db | 77 ac | 88 4e | 82 53 81 9d f9 bb f1 40
///
/// A sixteen-byte buffer filled straight from the text would put `db 6f 6d db`
/// in the first four and be wrong in three places out of four.
///
/// Getting this wrong does not crash. `QueryInterface` simply answers
/// `E_NOINTERFACE` for an interface the object certainly implements, and the
/// backend reports "this driver is too old" for the rest of its life. That is
/// why [toBytes] is public and why a test asserts the exact sixteen bytes of a
/// known IID rather than only checking that a QI succeeded: a QI test passes
/// on a machine whose driver happens to answer, and a byte test is true
/// everywhere, including on the Linux CI that has no COM at all.
final class Guid {
  const Guid(this.data1, this.data2, this.data3, this.data4)
      : assert(data4.length == 8);

  /// Parses the canonical `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` spelling,
  /// with or without the surrounding braces Windows tooling prints.
  ///
  /// A parser rather than twelve integer arguments per IID because every
  /// source that documents an interface - MSDN, a header, a stack trace -
  /// prints this exact form, and retyping it as integers is where a digit gets
  /// transposed.
  factory Guid.parse(String text) {
    var value = text.trim();
    if (value.startsWith('{') && value.endsWith('}')) {
      value = value.substring(1, value.length - 1);
    }
    final parts = value.split('-');
    if (parts.length != 5 ||
        parts[0].length != 8 ||
        parts[1].length != 4 ||
        parts[2].length != 4 ||
        parts[3].length != 4 ||
        parts[4].length != 12) {
      throw FormatException('not a GUID: $text');
    }
    int hex(String s) {
      final parsed = int.tryParse(s, radix: 16);
      if (parsed == null) throw FormatException('not a GUID: $text');
      return parsed;
    }

    final tail = '${parts[3]}${parts[4]}';
    return Guid(
      hex(parts[0]),
      hex(parts[1]),
      hex(parts[2]),
      <int>[
        for (var i = 0; i < 8; i++) hex(tail.substring(i * 2, i * 2 + 2)),
      ],
    );
  }

  final int data1;
  final int data2;
  final int data3;
  final List<int> data4;

  /// The 16 bytes exactly as the native struct holds them.
  Uint8List toBytes() {
    final bytes = Uint8List(16);
    final view = ByteData.view(bytes.buffer);
    view.setUint32(0, data1, Endian.little);
    view.setUint16(4, data2, Endian.little);
    view.setUint16(6, data3, Endian.little);
    for (var i = 0; i < 8; i++) {
      bytes[8 + i] = data4[i];
    }
    return bytes;
  }

  /// Writes the 16 bytes at [destination], which must hold at least that many.
  void writeTo(Pointer<Uint8> destination) {
    destination.asTypedList(16).setAll(0, toBytes());
  }

  /// A freshly allocated copy of this GUID owned by [arena].
  Pointer<Uint8> allocateIn(NativeArena arena) {
    final Pointer<Uint8> pointer = arena.allocate<Uint8>(16);
    writeTo(pointer);
    return pointer;
  }

  @override
  bool operator ==(Object other) {
    if (other is! Guid) return false;
    if (other.data1 != data1 || other.data2 != data2 || other.data3 != data3) {
      return false;
    }
    for (var i = 0; i < 8; i++) {
      if (other.data4[i] != data4[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(data1, data2, data3, Object.hashAll(data4));

  @override
  String toString() {
    String hex(int value, int digits) =>
        value.toRadixString(16).padLeft(digits, '0');
    final tail = <String>[for (final byte in data4) hex(byte, 2)];
    return '${hex(data1, 8)}-${hex(data2, 4)}-${hex(data3, 4)}-'
        '${tail.take(2).join()}-${tail.skip(2).join()}';
  }
}

/// `IUnknown` itself. Every COM object answers a QI for it.
final Guid iidIUnknown = Guid.parse('00000000-0000-0000-C000-000000000046');

// ---------------------------------------------------------------------------
// Vtable dispatch
// ---------------------------------------------------------------------------

/// The first three slots of every COM vtable, in the order the ABI fixes them.
///
/// Constants and not an enum: they are indices into a native table, arithmetic
/// is done on them (an interface that inherits `IUnknown` starts its own
/// methods at 3), and an enum would only add a `.index` to every call site.
const int comSlotQueryInterface = 0;
const int comSlotAddRef = 1;
const int comSlotRelease = 2;

/// The function pointer in slot [index] of [object]'s vtable.
///
/// A COM interface pointer points at a structure whose first machine word is
/// `lpVtbl`, a pointer to an array of function pointers. So this is two
/// dereferences and an index, and the type parameter is the caller's promise
/// about what it found - there is nothing at run time to check it against,
/// which is exactly why the slot numbers live next to the interface they
/// belong to and are commented with the method name.
Pointer<NativeFunction<F>> comMethod<F extends Function>(
  Pointer<Void> object,
  int index,
) {
  final Pointer<IntPtr> vtable = object.cast<Pointer<IntPtr>>().value;
  return Pointer<NativeFunction<F>>.fromAddress(vtable[index]);
}

/// `ULONG Method(void* self)` - what `AddRef` and `Release` are.
typedef _NativeRefCount = Uint32 Function(Pointer<Void>);
typedef _DartRefCount = int Function(Pointer<Void>);

typedef _NativeQueryInterface = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>);
typedef _DartQueryInterface = int Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>);

/// One owned reference to a COM interface.
///
/// Owns *one* reference and releases it exactly once, whether [dispose] is
/// called once or five times - the idempotence [DisposableMixin] supplies is
/// not a convenience here, it is the difference between a leak and a
/// double-free, and both paths are routinely taken by the same error handler.
///
/// Subclassing is the intended use: a concrete interface extends this and adds
/// `late final` fields bound with [comMethod] at its own slot numbers. See
/// `lib/src/rendering/gpu/d3d11/d3d11_bindings.dart`.
///
/// There is deliberately no `method<Native, Dart>(int slot)` helper on this
/// class, and the reason is a `dart:ffi` restriction rather than taste:
/// `asFunction` requires its native type to be statically known at the call
/// site, so a generic forwarder fails to compile with "expected type
/// `NativeFunction<F>` to be a valid and instantiated subtype of NativeType".
/// Each binding therefore names both signatures where it is written, which is
/// also where a reader wants to see them.
class ComObject with DisposableMixin {
  ComObject(this.pointer, {this.interfaceName = 'IUnknown'})
      : assert(pointer != nullptr, 'a COM object pointer must not be null');

  /// The raw interface pointer. Valid until [dispose].
  final Pointer<Void> pointer;

  /// For diagnostics only - `ID3D11Device`, `IDXGISwapChain1`. Never branched
  /// on; branching on a name is how backend assumptions spread.
  final String interfaceName;

  late final _DartRefCount _addRef =
      comMethod<_NativeRefCount>(pointer, comSlotAddRef).asFunction();
  late final _DartRefCount _release =
      comMethod<_NativeRefCount>(pointer, comSlotRelease).asFunction();
  late final _DartQueryInterface _queryInterface =
      comMethod<_NativeQueryInterface>(pointer, comSlotQueryInterface)
          .asFunction();

  /// Takes a reference. Returns the new count.
  ///
  /// The returned value is documented by COM as "for diagnostics only", which
  /// is exactly what it is used for here and in the tests.
  int addRef() {
    throwIfDisposed();
    return _addRef(pointer);
  }

  /// Drops a reference. Returns the count that remains.
  ///
  /// Public and separate from [dispose] because balance is what the tests
  /// assert, and a wrapper that could only ever release on teardown could not
  /// be asked whether an [addRef] was matched.
  int release() {
    throwIfDisposed();
    return _release(pointer);
  }

  /// The current reference count.
  ///
  /// COM has no getter for it, so this takes a reference and immediately drops
  /// it: `AddRef` returns *n+1* and the matching `Release` returns *n*, which
  /// is the count that was there before either call. The pair is balanced by
  /// construction, so asking cannot change the answer.
  ///
  /// Documented by Microsoft as diagnostic-only, and used here for exactly
  /// that: a test that proves an `AddRef` was matched by a `Release`, and a
  /// leak report. Nothing in the renderer branches on it.
  int get refCount {
    throwIfDisposed();
    _addRef(pointer);
    return _release(pointer);
  }

  /// Asks for [iid], returning the raw HRESULT and writing the interface into
  /// [out].
  ///
  /// The raw form, for a caller that wants to distinguish `E_NOINTERFACE` from
  /// a real failure. [queryInterface] is the usual one.
  int queryInterfaceInto(Guid iid, Pointer<Pointer<Void>> out) {
    throwIfDisposed();
    final arena = NativeArena();
    try {
      return hresult(_queryInterface(pointer, iid.allocateIn(arena), out));
    } finally {
      arena.dispose();
    }
  }

  /// The interface [iid] names, or null when this object does not implement it.
  ///
  /// Null and not an exception: "does this driver expose `IDXGIFactory2`" is a
  /// question with two legitimate answers, and the caller turns the negative
  /// one into a diagnostic naming the interface. A failure that is *not*
  /// `E_NOINTERFACE` still throws, because it means something other than the
  /// answer went wrong.
  ///
  /// The returned object owns a new reference and must be disposed
  /// independently of this one.
  ComObject? queryInterface(Guid iid, {String interfaceName = 'IUnknown'}) {
    final arena = NativeArena();
    try {
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      final int hr = queryInterfaceInto(iid, out);
      if (hr == eNoInterface) return null;
      checkHresult(hr, '$this::QueryInterface($iid)');
      if (out.value == nullptr) return null;
      return ComObject(out.value, interfaceName: interfaceName);
    } finally {
      arena.dispose();
    }
  }

  @override
  void onDispose() => _release(pointer);

  @override
  String toString() => '$interfaceName(0x'
      '${pointer.address.toUnsigned(64).toRadixString(16)})';
}

/// A group of COM references released last-acquired-first.
///
/// The order is not cosmetic and it is not the same argument as
/// `DisposableBag`'s in general: COM objects hold references to each other -
/// a swap chain holds the device, a render-target view holds the texture - and
/// releasing the device while a swap chain still points at it is legal but
/// leaves the last release running on a different thread at a time nobody
/// chose. Releasing in reverse acquisition order means the dependent goes
/// first, every time, and the final release is the one the caller expects.
///
/// [DisposableBag] already implements exactly that, including "a release that
/// throws does not stop the rest", so this is a thin typed front for it rather
/// than a second implementation.
final class ComBag with DisposableMixin {
  final DisposableBag _bag = DisposableBag();

  /// Registers [object] and returns it, so an acquisition and its release can
  /// be written in one expression.
  T keep<T extends ComObject>(T object) {
    throwIfDisposed();
    _bag.addDisposable(object);
    return object;
  }

  /// Registers a release that is not a [ComObject] - a native allocation, a
  /// handle - in the same ordering.
  void keepRelease(void Function() release) {
    throwIfDisposed();
    _bag.add(null, release);
  }

  /// How many releases are pending.
  int get length => _bag.length;

  @override
  void onDispose() => _bag.dispose();
}
