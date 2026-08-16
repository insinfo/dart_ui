/// A scoped allocator for the description structures Direct3D 12 is built out
/// of.
///
/// ## Declared duplication, and what should absorb it
///
/// This is `package:ffi`'s `Arena` in miniature: allocate freely, release
/// everything at once when the scope ends. The framework is 100% pure Dart and
/// cannot take the package as a dependency, so the *design* is followed rather
/// than the code - which is the same decision `d3d12_com.dart` records for
/// `Guid` and `comMethod`.
///
/// `lib/src/ffi/native_memory.dart` is being aligned to that same design by
/// another agent while this file is being written. When it lands, this class
/// should become an alias for it: the members are [allocate],
/// [allocatePointers], [allocateAscii] and [releaseAll], and none of them is
/// Direct3D-specific. The final report of this change names them so the
/// unification is mechanical.
///
/// ## Why an arena and not a field per structure
///
/// Creating a pipeline state object needs, in one call, a
/// `D3D12_GRAPHICS_PIPELINE_STATE_DESC`, an input-layout array, four
/// null-terminated semantic names, a `Guid` and an out-pointer. Six lifetimes
/// that all end together. Held as fields they would be six `late final`s and
/// six lines of teardown that a future seventh structure would silently not
/// join; held here they are one [releaseAll] in a `finally`.
///
/// The counterpart matters as much: this is **not** the allocator a frame
/// uses. Anything on the per-frame path - the viewport, the scissor, the
/// barrier array, the vertex buffer view - is allocated once and kept, because
/// a heap round trip per draw call is exactly the cost a batcher exists to
/// avoid. The rule is: an arena for creation, a field for a frame.
library;

import 'dart:ffi';

/// Native memory whose lifetime is a scope.
final class D3d12Arena {
  D3d12Arena(this._allocator);

  final Allocator _allocator;
  final List<Pointer<NativeType>> _blocks = <Pointer<NativeType>>[];

  /// Runs [body] with a fresh arena and releases everything it allocated.
  ///
  /// The `finally` is the whole point: a `D3DCompile` that fails, a
  /// `CreateGraphicsPipelineState` that returns `E_INVALIDARG`, an exception
  /// out of Dart code in between - all of them leave through here.
  static T using<T>(Allocator allocator, T Function(D3d12Arena arena) body) {
    final D3d12Arena arena = D3d12Arena(allocator);
    try {
      return body(arena);
    } finally {
      arena.releaseAll();
    }
  }

  /// [count] zeroed elements of [T].
  ///
  /// Zeroed because the allocator behind this is `HeapAlloc` with
  /// `HEAP_ZERO_MEMORY`, and that is not a convenience: a Direct3D description
  /// has fields this renderer never sets, and every one of them has to be zero
  /// or the runtime reads garbage out of a field whose enumeration has no
  /// zero-is-invalid rule.
  Pointer<T> allocate<T extends NativeType>(int byteCount) {
    final Pointer<T> pointer = _allocator.allocate<T>(byteCount);
    _blocks.add(pointer);
    return pointer;
  }

  /// [byteCount] bytes as a `Pointer<T>`, so a call site reads
  /// `arena<D3d12ResourceDesc>(sizeOf<D3d12ResourceDesc>())`.
  ///
  /// The size is passed rather than derived from `T`, because `sizeOf` needs a
  /// type known at compile time and a type *parameter* is not one - the
  /// analyzer rejects `sizeOf<T>()` outright. Repeating the type is the cost
  /// of that rule; getting the size from somewhere else would be worse,
  /// because a structure whose declared size and allocated size disagree is
  /// read past its end by the runtime.
  Pointer<T> call<T extends NativeType>(int byteCount) =>
      allocate<T>(byteCount);

  /// [count] slots for out-parameters of the `void**` shape every COM
  /// creation call ends with.
  Pointer<Pointer<Void>> allocatePointers(int count) =>
      allocate<Pointer<Void>>(sizeOf<Pointer<Void>>() * count);

  /// [text] as a null-terminated ASCII buffer.
  ///
  /// ASCII and not UTF-8 on purpose: every string this backend hands to
  /// Direct3D is an entry point name, a shader target or an input semantic,
  /// and all three are constrained by the API to `[A-Za-z0-9_]`. A non-ASCII
  /// code unit here means the caller passed something that was never going to
  /// be a valid HLSL identifier, and truncating it silently is how that
  /// becomes a compiler error about a symbol nobody wrote.
  Pointer<Uint8> allocateAscii(String text) {
    final Pointer<Uint8> buffer = allocate<Uint8>(text.length + 1);
    for (var i = 0; i < text.length; i++) {
      final int unit = text.codeUnitAt(i);
      if (unit > 0x7F) {
        throw ArgumentError.value(text, 'text', 'not ASCII at index $i');
      }
      buffer[i] = unit;
    }
    buffer[text.length] = 0;
    return buffer;
  }

  /// Releases every block, in reverse order of allocation.
  ///
  /// Reverse order is not required by the process heap and is done anyway,
  /// because it is the order [DisposableBag] uses and a teardown that differs
  /// from the framework's other teardowns for no reason is a teardown that
  /// gets read wrong.
  void releaseAll() {
    for (var i = _blocks.length - 1; i >= 0; i--) {
      _allocator.free(_blocks[i]);
    }
    _blocks.clear();
  }
}
