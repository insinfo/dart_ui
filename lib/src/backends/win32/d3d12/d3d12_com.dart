/// The four COM primitives this backend needs, written locally on purpose.
///
/// ## Declared duplication
///
/// `lib/src/ffi/com.dart` is being written by another agent *while this file
/// is being written*. Waiting for it would have serialised two backends
/// against one another for no technical reason, so the pieces of COM the
/// Direct3D 12 backend cannot start without live here instead:
///
///   * [Guid] - the 16-byte structure and a parser for the textual form the
///     Windows headers spell IIDs in;
///   * [comFailed] / [hresultText] - the sign convention of an `HRESULT` and
///     the names of the codes a graphics backend actually meets;
///   * [comMethod] - one double dereference through an object's vtable;
///   * [ComObject] - `AddRef`, `Release` and `QueryInterface`, which are the
///     first three slots of every interface in the system.
///
/// Nothing here is Direct3D-specific, which is exactly why it should be
/// absorbed. The report at the end of this change lists the members by name;
/// the unification is meant to be mechanical, so the *shape* deliberately
/// follows `poc/poc_05_com_direct2d/bin/direct2d_windows.dart` - a `GUID`
/// laid out as `Data1, Data2, Data3, Data4[8]`, an interface pointer carried
/// as a bare `Pointer<Void>`, and vtable slots addressed by index rather than
/// by generated bindings.
///
/// ## Why slots are numbers and not generated
///
/// A COM vtable is an array of function pointers whose order is fixed by the
/// interface declaration in the SDK header. There is no runtime way to ask an
/// object where `Release` is: the index *is* the ABI. So every wrapper in this
/// directory writes the slot index as a constant next to the method name, with
/// the inherited interfaces counted out above it, and a wrong number is a
/// wrong function call rather than an error - which is why the counts are
/// spelled out rather than left implicit.
library;

import 'dart:ffi';

/// A COM interface identifier, laid out as the Windows SDK declares it.
final class Guid extends Struct {
  @Uint32()
  external int data1;
  @Uint16()
  external int data2;
  @Uint16()
  external int data3;
  @Array(8)
  external Array<Uint8> data4;
}

/// Writes the GUID [text] names into [target].
///
/// [text] is the canonical `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` form, with
/// or without the surrounding braces the headers use. Throws on anything else:
/// a mistyped IID produces `E_NOINTERFACE` at some unrelated call site hours
/// later, and the whole point of parsing here is to fail at the constant.
void writeGuid(Pointer<Guid> target, String text) {
  final String body =
      text.startsWith('{') ? text.substring(1, text.length - 1) : text;
  final List<String> parts = body.split('-');
  if (parts.length != 5 ||
      parts[0].length != 8 ||
      parts[1].length != 4 ||
      parts[2].length != 4 ||
      parts[3].length != 4 ||
      parts[4].length != 12) {
    throw ArgumentError.value(text, 'text', 'not a GUID');
  }
  target.ref
    ..data1 = int.parse(parts[0], radix: 16)
    ..data2 = int.parse(parts[1], radix: 16)
    ..data3 = int.parse(parts[2], radix: 16);
  final Array<Uint8> tail = target.ref.data4;
  tail[0] = int.parse(parts[3].substring(0, 2), radix: 16);
  tail[1] = int.parse(parts[3].substring(2, 4), radix: 16);
  for (var i = 0; i < 6; i++) {
    tail[2 + i] = int.parse(parts[4].substring(i * 2, i * 2 + 2), radix: 16);
  }
}

/// Whether an `HRESULT` reports failure.
///
/// The severity bit is the sign bit, and Dart FFI hands back an `Int32`, so
/// "failed" is literally "negative". Written as a function rather than
/// inlined at eighty call sites because `hr != 0` is the wrong test - `S_FALSE`
/// is 1 and succeeds, and several DXGI calls return it.
bool comFailed(int hr) => hr < 0;

/// The eight hex digits of [hr], plus its SDK name when this file knows one.
///
/// Every diagnostic in this backend carries one of these. A bare decimal
/// `HRESULT` in a log is unsearchable: the codes are documented in hex, and
/// Dart prints the sign-extended negative.
String hresultText(int hr) {
  final String hex =
      '0x${hr.toUnsigned(32).toRadixString(16).padLeft(8, '0').toUpperCase()}';
  final String? name = _hresultNames[hr.toUnsigned(32)];
  return name == null ? hex : '$hex ($name)';
}

/// The codes a Direct3D 12 backend actually meets, and nothing else.
///
/// A complete table would be thousands of entries and would still miss the
/// driver-specific ones. These are the ones whose meaning changes what the
/// caller should do.
const Map<int, String> _hresultNames = <int, String>{
  0x80004001: 'E_NOTIMPL',
  0x80004002: 'E_NOINTERFACE',
  0x80004005: 'E_FAIL',
  0x8007000E: 'E_OUTOFMEMORY',
  0x80070057: 'E_INVALIDARG',
  0x887A0001: 'DXGI_ERROR_INVALID_CALL',
  0x887A0002: 'DXGI_ERROR_NOT_FOUND',
  0x887A0004: 'DXGI_ERROR_UNSUPPORTED',
  0x887A0005: 'DXGI_ERROR_DEVICE_REMOVED',
  0x887A0006: 'DXGI_ERROR_DEVICE_HUNG',
  0x887A0007: 'DXGI_ERROR_DEVICE_RESET',
  0x887A0020: 'DXGI_ERROR_DRIVER_INTERNAL_ERROR',
  0x887A002D: 'DXGI_ERROR_SDK_COMPONENT_MISSING',
  0x887E0003: 'D3D12_ERROR_ADAPTER_NOT_FOUND',
  0x887E0004: 'D3D12_ERROR_DRIVER_VERSION_MISMATCH',
};

/// The function pointer in slot [index] of [object]'s vtable.
///
/// A COM object is a pointer to a pointer to an array of function pointers.
/// Both dereferences are here so that no caller writes them by hand: getting
/// one of them wrong calls whatever integer happens to sit at that address,
/// which is not a crash you can read a stack trace out of.
///
/// The result is meant to be bound **once** per object and kept - see the
/// wrappers in `d3d12_interfaces.dart`, which bind in their constructors. A
/// per-frame call that re-walked the vtable would pay two loads and a Dart
/// closure allocation for nothing.
Pointer<NativeFunction<NF>> comMethod<NF extends Function>(
  Pointer<Void> object,
  int index,
) {
  final Pointer<Pointer<Void>> vtable =
      object.cast<Pointer<Pointer<Void>>>().value;
  return vtable[index].cast<NativeFunction<NF>>();
}

/// `IUnknown`: the three slots every COM interface starts with.
///
/// Held as a value type over a raw pointer rather than as a class hierarchy.
/// The alternative - one Dart class per interface, inheriting the way the C++
/// declarations do - buys nothing here, because the only thing the hierarchy
/// would express is the slot offset, and the slot offset is a constant this
/// directory writes down anyway.
extension type const ComObject(Pointer<Void> pointer) {
  static const int _queryInterfaceSlot = 0;
  static const int _addRefSlot = 1;
  static const int _releaseSlot = 2;

  bool get isNull => pointer == nullptr;

  int addRef() => comMethod<Uint32 Function(Pointer<Void>)>(
        pointer,
        _addRefSlot,
      ).asFunction<int Function(Pointer<Void>)>()(pointer);

  /// Drops one reference. Returns the count that remains, which is only worth
  /// looking at in a leak test.
  int release() {
    if (pointer == nullptr) return 0;
    return comMethod<Uint32 Function(Pointer<Void>)>(
      pointer,
      _releaseSlot,
    ).asFunction<int Function(Pointer<Void>)>()(pointer);
  }

  /// Asks for another interface on the same object, writing it into [out].
  ///
  /// Returns the `HRESULT`; `E_NOINTERFACE` is the expected answer for a
  /// feature the running Windows does not have (`IDXGISwapChain3` on a build
  /// old enough to lack it), which is why this reports rather than throws.
  int queryInterface(Pointer<Guid> iid, Pointer<Pointer<Void>> out) =>
      comMethod<
              Int32 Function(Pointer<Void>, Pointer<Guid>,
                  Pointer<Pointer<Void>>)>(pointer, _queryInterfaceSlot)
          .asFunction<
              int Function(Pointer<Void>, Pointer<Guid>,
                  Pointer<Pointer<Void>>)>()(pointer, iid, out);
}

/// Releases [pointer] if it is not null, and returns null.
///
/// Written as a helper because every teardown path in this backend is a list
/// of these and a forgotten null check there is a crash during disposal - the
/// place where a crash is hardest to attribute, because the object that
/// mattered was already gone.
Pointer<Void> releaseCom(Pointer<Void> pointer) {
  if (pointer != nullptr) ComObject(pointer).release();
  return nullptr;
}
