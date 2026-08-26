/// An out-of-process UI Automation client, pointed at another process's window.
///
/// **Not a test file** - no `_test` suffix. `uia_app_test.dart` starts
/// `uia_app_host.dart`, takes the HWND it prints, and runs this against it.
///
/// This is the shape Narrator has. It shares nothing with the provider but a
/// window handle: no isolate, no heap, no apartment. Every call it makes is
/// marshalled by COM across a process boundary and delivered to the provider
/// thread by that process's own message pump, which is the arrangement
/// `uia_bridge.dart` documents and which nothing in this repository had ever
/// exercised.
///
/// It walks the **control view** rather than the raw view, because that is what
/// a screen reader reads: the raw view carries the window's non-client
/// furniture and every grouping element, and a client that navigated it would
/// announce boxes nobody can see. Finding the button in the control view is
/// therefore a slightly stronger statement than finding it at all.
///
/// Usage: `dart run uia_app_client.dart <hwnd>`.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/src/backends/win32/uia/uia_constants.dart';
import 'package:dart_ui/src/backends/win32/uia/uia_core.dart' show variantSize;
import 'package:dart_ui/src/ffi/com.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';

void _say(String message) => print('client: $message');

// IUIAutomation, after IUnknown's three.
const int _slotElementFromHandle = 6;
const int _slotControlViewWalker = 14;

// IUIAutomationElement.
const int _slotGetCurrentPropertyValue = 10;
const int _slotGetCurrentPattern = 16;

// IUIAutomationTreeWalker.
const int _slotGetFirstChildElement = 4;
const int _slotGetNextSiblingElement = 6;

// The pattern objects, each after IUnknown's three.
const int _slotInvoke = 3;
const int _slotToggle = 3;
const int _slotSetValue = 3;

void main(List<String> args) {
  if (!Platform.isWindows) {
    _say('skipped: not Windows');
    return;
  }
  if (args.isEmpty) {
    _say('failed: no hwnd argument');
    exit(2);
  }
  final int? hwnd = int.tryParse(args.first);
  if (hwnd == null || hwnd == 0) {
    _say('failed: hwnd "${args.first}" is not a window handle');
    exit(2);
  }

  final NativeArena arena = NativeArena();
  final DynamicLibrary ole32 = DynamicLibrary.open('ole32.dll');
  final int coInit = hresult(
    ole32.lookupFunction<Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)>('CoInitializeEx')(nullptr, 0x2),
  );
  if (coInit < 0) {
    _say('failed: CoInitializeEx ${hresultName(coInit)}');
    exit(3);
  }

  final DynamicLibrary oleaut32 = DynamicLibrary.open('oleaut32.dll');
  final sysAllocString = oleaut32.lookupFunction<
      Pointer<Void> Function(Pointer<Uint16>),
      Pointer<Void> Function(Pointer<Uint16>)>('SysAllocString');
  final sysFreeString = oleaut32.lookupFunction<Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('SysFreeString');

  final coCreateInstance = ole32.lookupFunction<
      Int32 Function(Pointer<Uint8>, Pointer<Void>, Uint32, Pointer<Uint8>,
          Pointer<Pointer<Void>>),
      int Function(Pointer<Uint8>, Pointer<Void>, int, Pointer<Uint8>,
          Pointer<Pointer<Void>>)>('CoCreateInstance');
  final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
  final int created = hresult(
    coCreateInstance(
      clsidCUIAutomation.allocateIn(arena),
      nullptr,
      1, // CLSCTX_INPROC_SERVER - the *client* library, in this process.
      iidIUIAutomation.allocateIn(arena),
      out,
    ),
  );
  if (created < 0 || out.value == nullptr) {
    _say('failed: CoCreateInstance ${hresultName(created)}');
    exit(4);
  }
  final Pointer<Void> automation = out.value;
  _say('automation created');

  final Pointer<Void> root = _elementFromHandle(automation, hwnd, arena);
  if (root == nullptr) {
    _say('failed: ElementFromHandle - the window published no provider');
    exit(5);
  }
  _say('root.name=${_stringProperty(
    root,
    uiaNamePropertyId,
    arena,
    sysFreeString,
  )}');

  final Pointer<Void> walker = _outCall(
    automation,
    _slotControlViewWalker,
    arena,
    'get_ControlViewWalker',
  );
  if (walker == nullptr) exit(6);

  // Depth-first over the control view. The application's own layout puts the
  // controls under a column, so a one-level walk would find nothing - and a
  // screen reader does not do one-level walks either.
  final List<({String name, int controlType, Pointer<Void> element})> found =
      <({String name, int controlType, Pointer<Void> element})>[];
  void descend(Pointer<Void> parent, int depth) {
    if (depth > 12 || found.length > 200) return;
    Pointer<Void> child =
        _walk(walker, _slotGetFirstChildElement, parent, arena);
    while (child != nullptr) {
      found.add((
        name: _stringProperty(child, uiaNamePropertyId, arena, sysFreeString),
        controlType: _intProperty(child, uiaControlTypePropertyId, arena),
        element: child,
      ));
      descend(child, depth + 1);
      child = _walk(walker, _slotGetNextSiblingElement, child, arena);
    }
  }

  descend(root, 0);
  _say('elements=${found.length}');
  for (final element in found) {
    _say('element[${element.name}].controlType=${element.controlType}');
  }

  Pointer<Void> byName(String name, int code) {
    for (final element in found) {
      if (element.name == name) return element.element;
    }
    _say('failed: no element named "$name" among '
        '${found.map((e) => e.name).toList()}');
    exit(code);
  }

  Pointer<Void> byType(int controlType, int code) {
    for (final element in found) {
      if (element.controlType == controlType) return element.element;
    }
    _say('failed: no element of control type $controlType');
    exit(code);
  }

  // --- Invoke -------------------------------------------------------------
  final Pointer<Void> button = byName('Save', 7);
  _say('button.controlType=${_intProperty(
    button,
    uiaControlTypePropertyId,
    arena,
  )}');
  final Pointer<Void> invoke =
      _pattern(button, uiaInvokePatternId, arena, 'Invoke');
  if (invoke == nullptr) exit(8);
  _say('button.invoke=${hresultName(_call0(invoke, _slotInvoke))}');

  // --- Toggle -------------------------------------------------------------
  final Pointer<Void> checkBox = byName('Remember me', 9);
  _say('checkBox.toggleBefore=${_intProperty(
    checkBox,
    uiaToggleToggleStatePropertyId,
    arena,
  )}');
  final Pointer<Void> toggle =
      _pattern(checkBox, uiaTogglePatternId, arena, 'Toggle');
  if (toggle == nullptr) exit(10);
  _say('checkBox.toggle=${hresultName(_call0(toggle, _slotToggle))}');

  // --- SetValue -----------------------------------------------------------
  final Pointer<Void> slider = byType(uiaSliderControlTypeId, 11);
  final Pointer<Void> sliderValue =
      _pattern(slider, uiaValuePatternId, arena, 'Value (slider)');
  if (sliderValue == nullptr) exit(12);
  final Pointer<Void> number = sysAllocString(_utf16('0.75', arena));
  _say('slider.setValue='
      '${hresultName(_call1(sliderValue, _slotSetValue, number))}');
  sysFreeString(number);

  final Pointer<Void> field = byName('Name', 13);
  final Pointer<Void> fieldValue =
      _pattern(field, uiaValuePatternId, arena, 'Value (text field)');
  if (fieldValue == nullptr) exit(14);
  final Pointer<Void> text = sysAllocString(_utf16('after', arena));
  _say('field.setValue='
      '${hresultName(_call1(fieldValue, _slotSetValue, text))}');
  sysFreeString(text);

  // --- Read back ----------------------------------------------------------
  // The host runs frames on its own clock, and each of the three actions above
  // has to survive a build, a layout and a pump before the new value is in the
  // tree. Polling rather than sleeping a fixed amount: a fixed sleep is either
  // a flake or a delay, and usually both.
  final String toggled = _await(
    () => _intProperty(checkBox, uiaToggleToggleStatePropertyId, arena)
        .toString(),
    '1',
  );
  _say('checkBox.toggleAfter=$toggled');
  _say('slider.valueAfter=${_await(
    () =>
        _stringProperty(slider, uiaValueValuePropertyId, arena, sysFreeString),
    '0.75',
  )}');
  _say('field.valueAfter=${_await(
    () => _stringProperty(field, uiaValueValuePropertyId, arena, sysFreeString),
    'after',
  )}');

  _say('done');
  exit(0);
}

/// Reads [read] until it answers [wanted], or for two seconds.
///
/// Returns whatever it last saw, so a failure reports the value that was
/// actually there rather than only that it timed out.
String _await(String Function() read, String wanted) {
  final Stopwatch clock = Stopwatch()..start();
  String last = read();
  while (last != wanted && clock.elapsedMilliseconds < 2000) {
    sleep(const Duration(milliseconds: 25));
    last = read();
  }
  return last;
}

Pointer<Uint16> _utf16(String value, NativeArena arena) {
  final Pointer<Uint16> buffer =
      arena.allocate<Uint16>((value.length + 1) * 2).cast<Uint16>();
  for (int i = 0; i < value.length; i++) {
    buffer[i] = value.codeUnitAt(i);
  }
  buffer[value.length] = 0;
  return buffer;
}

typedef _NativeHandleOut = Int32 Function(
    Pointer<Void>, IntPtr, Pointer<Pointer<Void>>);
typedef _DartHandleOut = int Function(
    Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _NativeOut = Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _DartOut = int Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _NativeElementOut = Int32 Function(
    Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _DartElementOut = int Function(
    Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _NativePropertyValue = Int32 Function(
    Pointer<Void>, Int32, Pointer<Void>);
typedef _DartPropertyValue = int Function(Pointer<Void>, int, Pointer<Void>);
typedef _NativePatternOut = Int32 Function(
    Pointer<Void>, Int32, Pointer<Pointer<Void>>);
typedef _DartPatternOut = int Function(
    Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _NativeCall0 = Int32 Function(Pointer<Void>);
typedef _DartCall0 = int Function(Pointer<Void>);
typedef _NativeCall1 = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _DartCall1 = int Function(Pointer<Void>, Pointer<Void>);

Pointer<Void> _elementFromHandle(
  Pointer<Void> automation,
  int hwnd,
  NativeArena arena,
) {
  final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
  final int hr = hresult(
    comMethod<_NativeHandleOut>(automation, _slotElementFromHandle)
        .asFunction<_DartHandleOut>()(automation, hwnd, out),
  );
  if (hr < 0) {
    _say('ElementFromHandle -> ${hresultName(hr)}');
    return nullptr;
  }
  return out.value;
}

Pointer<Void> _outCall(
  Pointer<Void> target,
  int slot,
  NativeArena arena,
  String label,
) {
  final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
  final int hr = hresult(
    comMethod<_NativeOut>(target, slot).asFunction<_DartOut>()(target, out),
  );
  if (hr < 0) {
    _say('failed: $label -> ${hresultName(hr)}');
    return nullptr;
  }
  return out.value;
}

Pointer<Void> _walk(
  Pointer<Void> walker,
  int slot,
  Pointer<Void> element,
  NativeArena arena,
) {
  final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
  out.value = nullptr;
  final int hr = hresult(
    comMethod<_NativeElementOut>(walker, slot).asFunction<_DartElementOut>()(
        walker, element, out),
  );
  return hr < 0 ? nullptr : out.value;
}

Pointer<Void> _pattern(
  Pointer<Void> element,
  int patternId,
  NativeArena arena,
  String label,
) {
  final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
  out.value = nullptr;
  final int hr = hresult(
    comMethod<_NativePatternOut>(element, _slotGetCurrentPattern)
        .asFunction<_DartPatternOut>()(element, patternId, out),
  );
  if (hr < 0 || out.value == nullptr) {
    _say('failed: $label pattern -> ${hresultName(hr)}');
    return nullptr;
  }
  return out.value;
}

int _call0(Pointer<Void> target, int slot) => hresult(
      comMethod<_NativeCall0>(target, slot).asFunction<_DartCall0>()(target),
    );

int _call1(Pointer<Void> target, int slot, Pointer<Void> argument) => hresult(
      comMethod<_NativeCall1>(target, slot).asFunction<_DartCall1>()(
          target, argument),
    );

String _stringProperty(
  Pointer<Void> element,
  int propertyId,
  NativeArena arena,
  void Function(Pointer<Void>) freeBstr,
) {
  final Pointer<Void> variant = arena.allocate<Uint8>(variantSize).cast<Void>();
  final int hr = hresult(
    comMethod<_NativePropertyValue>(element, _slotGetCurrentPropertyValue)
        .asFunction<_DartPropertyValue>()(element, propertyId, variant),
  );
  if (hr < 0) return '<${hresultName(hr)}>';
  final int vt = variant.cast<Uint16>().value;
  if (vt != vtBstr) return '<vt=$vt>';
  final Pointer<Void> bstr = Pointer<Void>.fromAddress(variant.address + 8)
      .cast<Pointer<Void>>()
      .value;
  if (bstr == nullptr) return '';
  final Pointer<Uint16> units = bstr.cast<Uint16>();
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < 4096 && units[i] != 0; i++) {
    buffer.writeCharCode(units[i]);
  }
  freeBstr(bstr);
  return buffer.toString();
}

int _intProperty(Pointer<Void> element, int propertyId, NativeArena arena) {
  final Pointer<Void> variant = arena.allocate<Uint8>(variantSize).cast<Void>();
  final int hr = hresult(
    comMethod<_NativePropertyValue>(element, _slotGetCurrentPropertyValue)
        .asFunction<_DartPropertyValue>()(element, propertyId, variant),
  );
  if (hr < 0) return -1;
  if (variant.cast<Uint16>().value != vtI4) return -1;
  return Pointer<Int32>.fromAddress(variant.address + 8).value;
}
