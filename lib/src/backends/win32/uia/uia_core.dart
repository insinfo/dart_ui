/// `uiautomationcore.dll` and the `oleaut32.dll` types its arguments are made
/// of.
///
/// Two libraries and one struct writer, because a UI Automation provider
/// cannot answer a single question without all three: `GetPropertyValue` fills
/// a `VARIANT`, a `VARIANT` holding text holds a `BSTR`, and `GetRuntimeId`
/// returns a `SAFEARRAY`. None of the three is a plain buffer and none can be
/// faked - a `BSTR` is a pointer four bytes *into* an allocation whose header
/// holds the length, and handing UI Automation anything else is a crash inside
/// `SysFreeString` with our name nowhere in the stack.
///
/// Everything here follows `win32_api.dart`'s rule: a missing library or
/// symbol is **data**, not an exception, so a machine without UI Automation
/// reports that and keeps running.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../../../foundation/diagnostics.dart';
import 'uia_constants.dart';

/// `UiaRect` - the rectangle `IRawElementProviderFragment` returns, in screen
/// coordinates and in **doubles**.
///
/// Not `RECT`. A `RECT` is four `LONG`s and reusing it here silently halves
/// the struct and reads two rectangles' worth of garbage.
final class UiaRect extends Struct {
  @Double()
  external double left;
  @Double()
  external double top;
  @Double()
  external double width;
  @Double()
  external double height;
}

/// The size of a `VARIANT` on this architecture.
///
/// 24 bytes where a pointer is 8 (the union's widest member is `BRECORD`, two
/// pointers) and 16 where it is 4. Writing 16 on x64 leaves the tail of every
/// `VARIANT` uninitialised, which `VariantClear` then walks.
int get variantSize => sizeOf<Pointer<Void>>() == 8 ? 24 : 16;

/// The bound entry points, or an explanation.
final class UiaCoreLoadResult {
  const UiaCoreLoadResult({required this.core, required this.diagnostics});

  /// Null when a library or a required symbol was missing.
  final UiaCore? core;

  final List<BackendDiagnostic> diagnostics;
}

/// `uiautomationcore.dll` plus the `oleaut32.dll` allocators its arguments
/// need.
final class UiaCore {
  UiaCore._(this._uia, this._oleaut32) {
    _bindOleAut32();
    _bindUia();
  }

  final DynamicLibrary _uia;
  final DynamicLibrary _oleaut32;

  static UiaCoreLoadResult? _cached;

  /// Loads once per process. Repeated probes are normal and reopening the DLLs
  /// per probe is wasted work.
  static UiaCoreLoadResult load() {
    final UiaCoreLoadResult? cached = _cached;
    if (cached != null) return cached;

    if (!Platform.isWindows) {
      return _cached = const UiaCoreLoadResult(
        core: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.note(
            'UI Automation is a Windows API; this platform has none',
          ),
        ],
      );
    }

    DynamicLibrary uia;
    DynamicLibrary oleaut32;
    try {
      uia = DynamicLibrary.open('uiautomationcore.dll');
      oleaut32 = DynamicLibrary.open('oleaut32.dll');
    } on Object catch (error) {
      return _cached = UiaCoreLoadResult(
        core: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingLibrary(
            'uiautomationcore.dll / oleaut32.dll',
            detail: '$error',
          ),
        ],
      );
    }

    try {
      final UiaCore core = UiaCore._(uia, oleaut32);
      return _cached = UiaCoreLoadResult(
        core: core,
        diagnostics: core._diagnostics,
      );
    } on ArgumentError catch (error) {
      return _cached = UiaCoreLoadResult(
        core: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingSymbol('$error', detail: 'required symbol'),
        ],
      );
    }
  }

  /// Drops the cache. Only for a test that wants a fresh load.
  static void debugResetCache() => _cached = null;

  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];

  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(_diagnostics);

  // -------------------------------------------------------------------------
  // oleaut32
  // -------------------------------------------------------------------------

  /// `SysAllocString` - the only correct way to make a `BSTR`.
  late final Pointer<Void> Function(Pointer<Uint16>) sysAllocString;

  /// `SysFreeString`. Ours to call only for a `BSTR` we made and did not hand
  /// away: once a `BSTR` is inside a `VARIANT` the caller has, `VariantClear`
  /// owns it.
  late final void Function(Pointer<Void>) sysFreeString;

  late final Pointer<Void> Function(int, int, int) safeArrayCreateVector;
  late final int Function(Pointer<Void>) safeArrayDestroy;
  late final int Function(Pointer<Void>, Pointer<Pointer<Void>>)
      safeArrayAccessData;
  late final int Function(Pointer<Void>) safeArrayUnaccessData;
  late final int Function(Pointer<Void>) variantClear;

  void _bindOleAut32() {
    sysAllocString = _oleaut32.lookupFunction<
        Pointer<Void> Function(Pointer<Uint16>),
        Pointer<Void> Function(Pointer<Uint16>)>('SysAllocString');
    sysFreeString = _oleaut32.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('SysFreeString');
    safeArrayCreateVector = _oleaut32.lookupFunction<
        Pointer<Void> Function(Uint16, Int32, Uint32),
        Pointer<Void> Function(int, int, int)>('SafeArrayCreateVector');
    safeArrayDestroy = _oleaut32.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('SafeArrayDestroy');
    safeArrayAccessData = _oleaut32.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>),
        int Function(
            Pointer<Void>, Pointer<Pointer<Void>>)>('SafeArrayAccessData');
    safeArrayUnaccessData = _oleaut32.lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('SafeArrayUnaccessData');
    variantClear = _oleaut32.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('VariantClear');
  }

  // -------------------------------------------------------------------------
  // uiautomationcore
  // -------------------------------------------------------------------------

  /// `UiaReturnRawElementProvider` - what a `WM_GETOBJECT` handler returns.
  ///
  /// The `LRESULT` it produces is **not** a pointer and must not be
  /// interpreted: it is a cookie UIAutomationCore hands the caller, and the
  /// only correct thing a window procedure can do with it is return it
  /// unchanged.
  late final int Function(int, int, int, Pointer<Void>)
      uiaReturnRawElementProvider;

  /// `UiaHostProviderFromHwnd` - the provider for the HWND itself.
  ///
  /// A fragment root must return this from `get_HostRawElementProvider`, and
  /// it is not optional: without it the element has no window, no process id
  /// and no place in the desktop tree, and a client that starts from
  /// `ElementFromHandle` never reaches us.
  late final int Function(int, Pointer<Pointer<Void>>) uiaHostProviderFromHwnd;

  late final int Function(Pointer<Void>, int) uiaRaiseAutomationEvent;

  /// `UiaRaiseStructureChangedEvent`.
  late final int Function(Pointer<Void>, int, Pointer<Int32>, int)
      uiaRaiseStructureChangedEvent;

  /// `UiaClientsAreListening` - whether raising an event would reach anybody.
  ///
  /// Cheap, and the difference between a frame that costs nothing and a frame
  /// that marshals a hundred events into a process that is not there.
  late final int Function() uiaClientsAreListening;

  /// `UiaDisconnectProvider` - tells UI Automation to drop its references to
  /// a provider whose element is gone.
  late final int Function(Pointer<Void>) uiaDisconnectProvider;

  late final int Function() uiaDisconnectAllProviders;

  /// `UiaRaiseAutomationPropertyChangedEvent`, or null on a 32-bit process.
  ///
  /// The signature takes two `VARIANT`s **by value**. On x64 Windows a struct
  /// larger than eight bytes is passed by a hidden pointer to a caller-owned
  /// copy, so declaring the parameters as `Pointer<Void>` and passing the
  /// address of a local `VARIANT` is exactly the right ABI - no struct-by-value
  /// support needed, and no chance of `dart:ffi` and MSVC disagreeing about
  /// the layout of a union.
  ///
  /// On x86 the same struct is *pushed*, so the trick is wrong and the symbol
  /// is left null rather than bound to a signature that would corrupt the
  /// stack. Property-changed events are then absent, which is reported.
  int Function(Pointer<Void>, int, Pointer<Void>, Pointer<Void>)?
      uiaRaiseAutomationPropertyChangedEvent;

  void _bindUia() {
    uiaReturnRawElementProvider = _uia.lookupFunction<
        IntPtr Function(IntPtr, IntPtr, IntPtr, Pointer<Void>),
        int Function(
            int, int, int, Pointer<Void>)>('UiaReturnRawElementProvider');
    uiaHostProviderFromHwnd = _uia.lookupFunction<
        Int32 Function(IntPtr, Pointer<Pointer<Void>>),
        int Function(int, Pointer<Pointer<Void>>)>('UiaHostProviderFromHwnd');
    uiaRaiseAutomationEvent = _uia.lookupFunction<
        Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)>('UiaRaiseAutomationEvent');
    uiaRaiseStructureChangedEvent = _uia.lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Int32>, Int32),
        int Function(Pointer<Void>, int, Pointer<Int32>,
            int)>('UiaRaiseStructureChangedEvent');
    uiaClientsAreListening =
        _uia.lookupFunction<Int32 Function(), int Function()>(
            'UiaClientsAreListening');
    uiaDisconnectProvider = _uia.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('UiaDisconnectProvider');
    uiaDisconnectAllProviders =
        _uia.lookupFunction<Int32 Function(), int Function()>(
            'UiaDisconnectAllProviders');

    if (sizeOf<Pointer<Void>>() == 8) {
      uiaRaiseAutomationPropertyChangedEvent = _uia.lookupFunction<
          Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Pointer<Void>),
          int Function(Pointer<Void>, int, Pointer<Void>,
              Pointer<Void>)>('UiaRaiseAutomationPropertyChangedEvent');
    } else {
      _diagnostics.add(
        const BackendDiagnostic.note(
          'UiaRaiseAutomationPropertyChangedEvent not bound on a 32-bit '
          'process: its two VARIANT arguments are passed by value, which is '
          'by hidden pointer only on x64',
          detail: 'property-changed events are absent; structure-changed and '
              'plain automation events still fire',
        ),
      );
    }
  }

  // -------------------------------------------------------------------------
  // VARIANT
  // -------------------------------------------------------------------------

  /// Writes [value] into the `VARIANT` at [variant], which must have room for
  /// [variantSize] bytes.
  ///
  /// The mapping is the one `uia_mapping.dart` documents: [String] becomes
  /// `VT_BSTR`, [bool] becomes `VT_BOOL` (with the -1 that `VARIANT_TRUE`
  /// is - writing 1 gives a value some clients read as true and some do not),
  /// [int] becomes `VT_I4`, [double] becomes `VT_R8`, a `List<double>` becomes
  /// a one-dimensional `VT_R8 | VT_ARRAY`, and null becomes `VT_EMPTY`.
  ///
  /// **Ownership.** The `BSTR` and the `SAFEARRAY` this allocates belong to
  /// whoever receives the `VARIANT`; UI Automation calls `VariantClear` on it.
  /// So this must not be called to fill a `VARIANT` that is then thrown away
  /// without clearing, and [clearVariant] exists for the caller that does.
  void writeVariant(Pointer<Void> variant, Object? value) {
    final Pointer<Uint8> bytes = variant.cast<Uint8>();
    bytes.asTypedList(variantSize).fillRange(0, variantSize, 0);
    final Pointer<Uint16> vt = variant.cast<Uint16>();
    final Pointer<Uint8> payload =
        Pointer<Uint8>.fromAddress(variant.address + 8);

    switch (value) {
      case null:
        vt.value = vtEmpty;
      case final bool flag:
        vt.value = vtBool;
        payload.cast<Int16>().value = flag ? variantTrue : variantFalse;
      case final int number:
        vt.value = vtI4;
        payload.cast<Int32>().value = number;
      case final double number:
        vt.value = vtR8;
        payload.cast<Double>().value = number;
      case final String text:
        final Pointer<Void> bstr = _allocateBstr(text);
        if (bstr == nullptr) {
          vt.value = vtEmpty;
          return;
        }
        vt.value = vtBstr;
        payload.cast<Pointer<Void>>().value = bstr;
      case final List<double> numbers:
        final Pointer<Void> array = allocateDoubleArray(numbers);
        if (array == nullptr) {
          vt.value = vtEmpty;
          return;
        }
        vt.value = vtR8 | vtArray;
        payload.cast<Pointer<Void>>().value = array;
      default:
        throw ArgumentError.value(
          value,
          'value',
          'no VARIANT representation; add one here rather than letting a '
              'property answer VT_EMPTY by accident',
        );
    }
  }

  /// `VariantClear`, for a `VARIANT` this process filled and is discarding.
  void clearVariant(Pointer<Void> variant) => variantClear(variant);

  /// A `BSTR` copy of [text], owned by whoever receives it.
  ///
  /// Every `get_Value`-shaped method returns one of these, and the receiver
  /// frees it with `SysFreeString`. Never a plain buffer: a `BSTR` points four
  /// bytes past the start of an allocation whose header holds the byte length,
  /// and `SysFreeString` reads that header.
  Pointer<Void> allocateBstr(String text) => _allocateBstr(text);

  /// A `VT_UNKNOWN` vector of interface pointers.
  ///
  /// The pointers must already carry a reference for the receiver - putting a
  /// pointer into a `SAFEARRAY` of `VT_UNKNOWN` does **not** call `AddRef`,
  /// but `SafeArrayDestroy` does call `Release` on every element. So a caller
  /// that fills this without adding references has handed out a deletion.
  Pointer<Void> allocateUnknownArray(List<Pointer<Void>> values) {
    final Pointer<Void> array =
        safeArrayCreateVector(vtUnknown, 0, values.length);
    if (array == nullptr) return nullptr;
    if (values.isEmpty) return array;
    final Pointer<Pointer<Void>> data = _scratchPointer();
    if (safeArrayAccessData(array, data) < 0) {
      safeArrayDestroy(array);
      return nullptr;
    }
    final Pointer<Pointer<Void>> elements = data.value.cast<Pointer<Void>>();
    for (int i = 0; i < values.length; i++) {
      elements[i] = values[i];
    }
    safeArrayUnaccessData(array);
    return array;
  }

  Pointer<Void> _allocateBstr(String text) {
    // A BSTR is UTF-16 with a length prefix the caller never sees, so the
    // source has to be a null-terminated UTF-16 buffer - and a Dart string is
    // already UTF-16 code units, surrogate pairs included.
    final List<int> units = text.codeUnits;
    final Pointer<Uint16> buffer = _scratch(units.length + 1).cast<Uint16>();
    final Uint16List view = buffer.asTypedList(units.length + 1);
    view.setRange(0, units.length, units);
    view[units.length] = 0;
    return sysAllocString(buffer);
  }

  /// A `VT_R8` vector of [values], or `nullptr` when `oleaut32` refused.
  Pointer<Void> allocateDoubleArray(List<double> values) {
    final Pointer<Void> array = safeArrayCreateVector(vtR8, 0, values.length);
    if (array == nullptr) return nullptr;
    final Pointer<Pointer<Void>> data = _scratchPointer();
    if (safeArrayAccessData(array, data) < 0) {
      safeArrayDestroy(array);
      return nullptr;
    }
    data.value.cast<Double>().asTypedList(values.length).setAll(0, values);
    safeArrayUnaccessData(array);
    return array;
  }

  /// A `VT_I4` vector of [values] - what a runtime id is.
  Pointer<Void> allocateIntArray(List<int> values) {
    final Pointer<Void> array = safeArrayCreateVector(vtI4, 0, values.length);
    if (array == nullptr) return nullptr;
    final Pointer<Pointer<Void>> data = _scratchPointer();
    if (safeArrayAccessData(array, data) < 0) {
      safeArrayDestroy(array);
      return nullptr;
    }
    data.value.cast<Int32>().asTypedList(values.length).setAll(0, values);
    safeArrayUnaccessData(array);
    return array;
  }

  // A single reusable staging buffer, grown on demand. Every use of it is
  // synchronous, finishes before returning, and happens on the one thread this
  // provider answers on - so reuse costs nothing and saves an allocation per
  // property read, of which a tree walk does thousands.
  Pointer<Uint16> _scratchBuffer = nullptr;
  int _scratchUnits = 0;

  Pointer<Uint16> _scratch(int units) {
    if (units > _scratchUnits) {
      if (_scratchBuffer != nullptr) _releaseScratch();
      _scratchBuffer = _heapAllocate(units * 2).cast<Uint16>();
      _scratchUnits = units;
    }
    return _scratchBuffer;
  }

  Pointer<Pointer<Void>> _scratchOut = nullptr;

  Pointer<Pointer<Void>> _scratchPointer() {
    _scratchOut = _scratchOut == nullptr
        ? _heapAllocate(sizeOf<Pointer<Void>>()).cast<Pointer<Void>>()
        : _scratchOut;
    _scratchOut.value = nullptr;
    return _scratchOut;
  }

  Pointer<Void> _heapAllocate(int bytes) {
    final Pointer<Void> pointer = _coTaskMemAlloc(bytes);
    if (pointer == nullptr) {
      throw StateError('CoTaskMemAlloc refused $bytes bytes');
    }
    return pointer;
  }

  void _releaseScratch() {
    _coTaskMemFree(_scratchBuffer.cast<Void>());
    _scratchBuffer = nullptr;
    _scratchUnits = 0;
  }

  late final Pointer<Void> Function(int) _coTaskMemAlloc = DynamicLibrary.open(
    'ole32.dll',
  ).lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void> Function(int)>(
    'CoTaskMemAlloc',
  );

  late final void Function(Pointer<Void>) _coTaskMemFree = DynamicLibrary.open(
    'ole32.dll',
  ).lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'CoTaskMemFree',
  );
}
