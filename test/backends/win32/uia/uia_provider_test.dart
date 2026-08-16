/// The providers, exercised through their vtables exactly as UI Automation
/// would.
///
/// Windows only, and the reason is narrow: `GetPropertyValue` fills a
/// `VARIANT` whose string half is a `BSTR`, and `GetRuntimeId` returns a
/// `SAFEARRAY`. Both are `oleaut32.dll` types with allocation rules that
/// cannot be simulated - a `BSTR` is a pointer four bytes into an allocation
/// whose header holds the length, and testing against a hand-rolled buffer
/// would prove nothing about the one that ships.
///
/// Everything that *can* be checked without them already is, in
/// `com_server_test.dart` (the vtable, reference counting, identity) and
/// `uia_mapping_test.dart` (what the answers should say).
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/src/backends/win32/uia/com_server.dart';
import 'package:dart_ui/src/backends/win32/uia/uia_constants.dart';
import 'package:dart_ui/src/backends/win32/uia/uia_core.dart';
import 'package:dart_ui/src/backends/win32/uia/uia_provider.dart';
import 'package:dart_ui/src/ffi/com.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/widgets/semantics.dart';
import 'package:test/test.dart';

const String _needsWindows =
    'UI Automation is a Windows API: VARIANT, BSTR and SAFEARRAY come from '
    'oleaut32.dll and there is nothing to bind on Linux or macOS';

// IRawElementProviderSimple, after IUnknown's three.
const int _slotProviderOptions = 3;
const int _slotGetPatternProvider = 4;
const int _slotGetPropertyValue = 5;
const int _slotHostRawElementProvider = 6;

// IRawElementProviderFragment.
const int _slotNavigate = 3;
const int _slotGetRuntimeId = 4;
const int _slotBoundingRectangle = 5;
const int _slotFragmentSetFocus = 7;
const int _slotFragmentRoot = 8;

// IRawElementProviderFragmentRoot.
const int _slotElementProviderFromPoint = 3;
const int _slotGetFocus = 4;

typedef _NativeQi = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>);
typedef _DartQi = int Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>);
typedef _NativeRefCount = Uint32 Function(Pointer<Void>);
typedef _DartRefCount = int Function(Pointer<Void>);
typedef _NativeSelf = Int32 Function(Pointer<Void>);
typedef _DartSelf = int Function(Pointer<Void>);
typedef _NativePointer = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _DartPointer = int Function(Pointer<Void>, Pointer<Void>);
typedef _NativeIntPointer = Int32 Function(Pointer<Void>, Int32, Pointer<Void>);
typedef _DartIntPointer = int Function(Pointer<Void>, int, Pointer<Void>);
typedef _NativePointPointer = Int32 Function(
    Pointer<Void>, Double, Double, Pointer<Void>);
typedef _DartPointPointer = int Function(
    Pointer<Void>, double, double, Pointer<Void>);

_DartQi _qi(Pointer<Void> object) =>
    comMethod<_NativeQi>(object, comSlotQueryInterface).asFunction();
_DartRefCount _release(Pointer<Void> object) =>
    comMethod<_NativeRefCount>(object, comSlotRelease).asFunction();
_DartSelf _self(Pointer<Void> object, int slot) =>
    comMethod<_NativeSelf>(object, slot).asFunction();
_DartPointer _pointer(Pointer<Void> object, int slot) =>
    comMethod<_NativePointer>(object, slot).asFunction();
_DartIntPointer _intPointer(Pointer<Void> object, int slot) =>
    comMethod<_NativeIntPointer>(object, slot).asFunction();
_DartPointPointer _pointPointer(Pointer<Void> object, int slot) =>
    comMethod<_NativePointPointer>(object, slot).asFunction();

/// The interface [iid] on [object], with the reference it added.
Pointer<Void> _queryInterface(
  Pointer<Void> object,
  Guid iid,
  NativeArena arena,
) {
  final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
  final int hr = hresult(_qi(object)(object, iid.allocateIn(arena), out));
  expect(hr, sOk, reason: 'QueryInterface($iid)');
  return out.value;
}

/// The `VT_BSTR` in a `VARIANT`, decoded and freed.
String? _readVariantString(UiaCore core, Pointer<Void> variant) {
  final int vt = variant.cast<Uint16>().value;
  if (vt == vtEmpty) return null;
  expect(vt, vtBstr);
  final Pointer<Void> bstr = Pointer<Void>.fromAddress(variant.address + 8)
      .cast<Pointer<Void>>()
      .value;
  if (bstr == nullptr) return null;
  final Pointer<Uint16> units = bstr.cast<Uint16>();
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; units[i] != 0 && i < 4096; i++) {
    buffer.writeCharCode(units[i]);
  }
  core.sysFreeString(bstr);
  return buffer.toString();
}

int? _readVariantInt(Pointer<Void> variant) {
  final int vt = variant.cast<Uint16>().value;
  if (vt == vtEmpty) return null;
  expect(vt, vtI4);
  return Pointer<Int32>.fromAddress(variant.address + 8).value;
}

bool? _readVariantBool(Pointer<Void> variant) {
  final int vt = variant.cast<Uint16>().value;
  if (vt == vtEmpty) return null;
  expect(vt, vtBool);
  return Pointer<Int16>.fromAddress(variant.address + 8).value != 0;
}

List<int> _readIntSafeArray(UiaCore core, Pointer<Void> array, int count) {
  final NativeArena arena = NativeArena();
  try {
    final Pointer<Pointer<Void>> data = arena.allocateOutPointer();
    expect(core.safeArrayAccessData(array, data) >= 0, isTrue);
    final Pointer<Int32> elements = data.value.cast<Int32>();
    final List<int> values = <int>[
      for (int i = 0; i < count; i++) elements[i],
    ];
    core.safeArrayUnaccessData(array);
    core.safeArrayDestroy(array);
    return values;
  } finally {
    arena.dispose();
  }
}

SemanticsNode _node(
  int id,
  SemanticsRole role, {
  String? label,
  String? value,
  Rect bounds = const Rect.fromLTWH(0, 0, 100, 40),
  Set<SemanticsState> states = const <SemanticsState>{},
  Set<SemanticsAction> actions = const <SemanticsAction>{},
  List<SemanticsNode> children = const <SemanticsNode>[],
}) =>
    SemanticsNode(
      id: id,
      role: role,
      bounds: bounds,
      label: label,
      value: value,
      states: states,
      actions: actions,
      children: children,
    );

/// root > [ button "Save", checkbox "Remember me" (checked) ]
SemanticsSnapshot _sample() => SemanticsSnapshot(
      _node(
        0,
        SemanticsRole.generic,
        bounds: const Rect.fromLTWH(0, 0, 400, 300),
        children: <SemanticsNode>[
          _node(
            1,
            SemanticsRole.button,
            label: 'Save',
            bounds: const Rect.fromLTWH(10, 20, 80, 30),
            actions: <SemanticsAction>{
              SemanticsAction.activate,
              SemanticsAction.focus,
            },
          ),
          _node(
            2,
            SemanticsRole.checkbox,
            label: 'Remember me',
            bounds: const Rect.fromLTWH(10, 60, 120, 20),
            states: <SemanticsState>{
              SemanticsState.checked,
              SemanticsState.focused,
            },
            actions: <SemanticsAction>{SemanticsAction.activate},
          ),
        ],
      ),
    );

void main() {
  if (!Platform.isWindows) {
    test('UI Automation providers', () {}, skip: _needsWindows);
    return;
  }

  final UiaCore? core = UiaCore.load().core;
  if (core == null) {
    test('UI Automation providers', () {},
        skip: 'uiautomationcore.dll did not load on this machine: '
            '${UiaCore.load().diagnostics}');
    return;
  }

  late UiaProviderTree tree;
  late NativeArena arena;

  setUp(() {
    ComServerRegistry.clearFaults();
    arena = NativeArena();
    tree = UiaProviderTree(core: core, hostProviderFor: () => nullptr)
      ..publish(_sample());
  });

  tearDown(() {
    arena.dispose();
    tree.dispose();
    expect(ComServerRegistry.faults, isEmpty,
        reason: 'a provider method threw where it should have answered');
  });

  Pointer<Void> root() => tree.root!.pointer;
  Pointer<Void> button() => tree.providerFor(1)!.pointer;

  group('IRawElementProviderSimple', () {
    test('declares itself server-side and apartment-affine', () {
      final Pointer<Int32> out = arena.allocate<Int32>(4);
      expect(
        hresult(_pointer(root(), _slotProviderOptions)(root(), out.cast())),
        sOk,
      );
      expect(
        out.value & providerOptionsServerSideProvider,
        providerOptionsServerSideProvider,
      );
      // The flag the whole directory depends on: without it UI Automation
      // calls the provider on a thread of its own and the isolate-local
      // trampoline aborts the process.
      expect(
        out.value & providerOptionsUseComThreading,
        providerOptionsUseComThreading,
      );
    });

    test('answers the name and the control type a screen reader reads', () {
      final Pointer<Void> variant =
          arena.allocate<Uint8>(variantSize).cast<Void>();
      final _DartIntPointer get = _intPointer(button(), _slotGetPropertyValue);

      expect(
        hresult(get(button(), uiaNamePropertyId, variant)),
        sOk,
      );
      expect(_readVariantString(core, variant), 'Save');

      expect(
        hresult(get(button(), uiaControlTypePropertyId, variant)),
        sOk,
      );
      expect(_readVariantInt(variant), uiaButtonControlTypeId);

      expect(
        hresult(get(button(), uiaIsEnabledPropertyId, variant)),
        sOk,
      );
      expect(_readVariantBool(variant), isTrue);
    });

    test('a checkbox reports its toggle state through the property too', () {
      final Pointer<Void> variant =
          arena.allocate<Uint8>(variantSize).cast<Void>();
      final Pointer<Void> checkbox = tree.providerFor(2)!.pointer;
      expect(
        hresult(_intPointer(checkbox, _slotGetPropertyValue)(
          checkbox,
          uiaToggleToggleStatePropertyId,
          variant,
        )),
        sOk,
      );
      expect(_readVariantInt(variant), toggleStateOn);
    });

    test('an unknown property is VT_EMPTY and not a failure', () {
      final Pointer<Void> variant =
          arena.allocate<Uint8>(variantSize).cast<Void>();
      expect(
        hresult(_intPointer(button(), _slotGetPropertyValue)(
          button(),
          uiaItemStatusPropertyId,
          variant,
        )),
        sOk,
      );
      expect(variant.cast<Uint16>().value, vtEmpty);
    });

    test('only the root has a host provider', () {
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      out.value = Pointer<Void>.fromAddress(0xdead);
      expect(
        hresult(_pointer(button(), _slotHostRawElementProvider)(
          button(),
          out.cast(),
        )),
        sOk,
      );
      // A child with a host would be a second element for the same HWND and
      // the fragment would have two roots.
      expect(out.value, nullptr);
    });

    test('GetPatternProvider gates on what the node actually supports', () {
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      final _DartIntPointer get =
          _intPointer(button(), _slotGetPatternProvider);

      expect(hresult(get(button(), uiaInvokePatternId, out.cast())), sOk);
      expect(out.value, button(),
          reason: 'the element is its own pattern provider');
      _release(out.value)(out.value);

      expect(hresult(get(button(), uiaTogglePatternId, out.cast())), sOk);
      expect(out.value, nullptr,
          reason: 'a plain button has no toggle state to report');

      // And the pattern interface really is there once advertised.
      final Pointer<Void> invoke =
          _queryInterface(button(), iidIInvokeProvider, arena);
      expect(invoke, isNot(nullptr));
      _release(invoke)(invoke);
    });
  });

  group('IRawElementProviderFragment', () {
    test('navigates the tree the way a client walks it', () {
      final Pointer<Void> fragment =
          _queryInterface(root(), iidIRawElementProviderFragment, arena);
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      final _DartIntPointer navigate = _intPointer(fragment, _slotNavigate);

      expect(
        hresult(navigate(fragment, navigateDirectionFirstChild, out.cast())),
        sOk,
      );
      expect(out.value, button());
      _release(out.value)(out.value);

      expect(
        hresult(navigate(fragment, navigateDirectionLastChild, out.cast())),
        sOk,
      );
      expect(out.value, tree.providerFor(2)!.pointer);
      _release(out.value)(out.value);

      // The root's parent is null: that is what says "top of the fragment",
      // and UI Automation takes the host provider from there instead.
      expect(
        hresult(navigate(fragment, navigateDirectionParent, out.cast())),
        sOk,
      );
      expect(out.value, nullptr);

      final Pointer<Void> child =
          _queryInterface(button(), iidIRawElementProviderFragment, arena);
      final _DartIntPointer childNavigate = _intPointer(child, _slotNavigate);
      expect(
        hresult(
          childNavigate(child, navigateDirectionNextSibling, out.cast()),
        ),
        sOk,
      );
      expect(out.value, tree.providerFor(2)!.pointer);
      _release(out.value)(out.value);
      expect(
        hresult(
          childNavigate(child, navigateDirectionParent, out.cast()),
        ),
        sOk,
      );
      expect(out.value, root());
      _release(out.value)(out.value);
      _release(child)(child);
      _release(fragment)(fragment);
    });

    test('a runtime id opens with UiaAppendRuntimeId and carries the node', () {
      final Pointer<Void> fragment =
          _queryInterface(button(), iidIRawElementProviderFragment, arena);
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      expect(
        hresult(_pointer(fragment, _slotGetRuntimeId)(fragment, out.cast())),
        sOk,
      );
      expect(out.value, isNot(nullptr));
      // The 3 is what tells UI Automation to prefix the host window's own id,
      // which is how this stays unique across the desktop without us knowing
      // anything about the desktop.
      expect(
        _readIntSafeArray(core, out.value, 2),
        <int>[uiaAppendRuntimeId, 1],
      );
      _release(fragment)(fragment);
    });

    test('bounds arrive in physical desktop pixels, transformed', () {
      tree.transform
        ..clientOriginX = 300
        ..clientOriginY = 200
        ..scale = 2.0;
      final Pointer<Void> fragment =
          _queryInterface(button(), iidIRawElementProviderFragment, arena);
      final Pointer<UiaRect> rect = arena.allocate<UiaRect>(32);
      expect(
        hresult(
          _pointer(fragment, _slotBoundingRectangle)(fragment, rect.cast()),
        ),
        sOk,
      );
      // Logical (10, 20, 80, 30) at scale 2 from a client origin of (300, 200).
      expect(rect.ref.left, 320);
      expect(rect.ref.top, 240);
      expect(rect.ref.width, 160);
      expect(rect.ref.height, 60);
      _release(fragment)(fragment);
    });

    test('every element points back at one fragment root', () {
      for (final int id in <int>[0, 1, 2]) {
        final Pointer<Void> element = tree.providerFor(id)!.pointer;
        final Pointer<Void> fragment =
            _queryInterface(element, iidIRawElementProviderFragment, arena);
        final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
        expect(
          hresult(_pointer(fragment, _slotFragmentRoot)(fragment, out.cast())),
          sOk,
        );
        expect(out.value, root());
        _release(out.value)(out.value);
        _release(fragment)(fragment);
      }
    });

    test('only the root answers a QueryInterface for the fragment root', () {
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      final Pointer<Uint8> iid =
          iidIRawElementProviderFragmentRoot.allocateIn(arena);
      expect(hresult(_qi(root())(root(), iid, out)), sOk);
      _release(out.value)(out.value);
      // A child that answered would be the root of a fragment of its own, and
      // the window would have as many fragments as it has controls.
      expect(hresult(_qi(button())(button(), iid, out)), eNoInterface);
    });

    test(
        'SetFocus answers UIA_E_NOTSUPPORTED while nothing can perform an '
        'action', () {
      final Pointer<Void> fragment =
          _queryInterface(button(), iidIRawElementProviderFragment, arena);
      expect(
        hresult(_self(fragment, _slotFragmentSetFocus)(fragment)),
        uiaErrorNotSupported,
      );

      // ... and routes it once somebody can.
      int? seen;
      tree.actionDispatcher =
          (int nodeId, SemanticsAction action, {String? value}) {
        seen = nodeId;
        return true;
      };
      expect(hresult(_self(fragment, _slotFragmentSetFocus)(fragment)), sOk);
      expect(seen, 1);
      tree.actionDispatcher = null;
      _release(fragment)(fragment);
    });
  });

  group('IRawElementProviderFragmentRoot', () {
    test('hit tests in desktop coordinates', () {
      tree.transform
        ..clientOriginX = 1000
        ..clientOriginY = 500
        ..scale = 1.0;
      final Pointer<Void> fragmentRoot = _queryInterface(
        root(),
        iidIRawElementProviderFragmentRoot,
        arena,
      );
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      final _DartPointPointer fromPoint =
          _pointPointer(fragmentRoot, _slotElementProviderFromPoint);

      // Inside the button: logical (10..90, 20..50) offset by the origin.
      expect(hresult(fromPoint(fragmentRoot, 1050, 530, out.cast())), sOk);
      expect(out.value, button());
      _release(out.value)(out.value);

      // Inside the root but outside both children.
      expect(hresult(fromPoint(fragmentRoot, 1300, 700, out.cast())), sOk);
      expect(out.value, root());
      _release(out.value)(out.value);

      // Outside the window entirely.
      expect(hresult(fromPoint(fragmentRoot, 5000, 5000, out.cast())), sOk);
      expect(out.value, nullptr);
      _release(fragmentRoot)(fragmentRoot);
    });

    test('reports the focused element', () {
      final Pointer<Void> fragmentRoot = _queryInterface(
        root(),
        iidIRawElementProviderFragmentRoot,
        arena,
      );
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      expect(
        hresult(
            _pointer(fragmentRoot, _slotGetFocus)(fragmentRoot, out.cast())),
        sOk,
      );
      expect(out.value, tree.providerFor(2)!.pointer);
      _release(out.value)(out.value);
      _release(fragmentRoot)(fragmentRoot);
    });
  });

  group('a node the tree has dropped', () {
    test('keeps its element and answers by name instead of crashing', () {
      final UiaNodeProvider provider = tree.providerFor(1)!;
      final Pointer<Void> held = provider.pointer;
      // A client holds a reference across the rebuild, which is exactly what
      // Narrator does between one keystroke and the next.
      comMethod<_NativeRefCount>(held, comSlotAddRef)
          .asFunction<_DartRefCount>()(held);

      tree.publish(
        SemanticsSnapshot(
          _node(
            0,
            SemanticsRole.generic,
            bounds: const Rect.fromLTWH(0, 0, 400, 300),
          ),
        ),
      );
      expect(provider.isAlive, isFalse);

      final Pointer<Void> variant =
          arena.allocate<Uint8>(variantSize).cast<Void>();
      final _DartIntPointer get = _intPointer(held, _slotGetPropertyValue);

      // The name and the role survive: that is how a client recognises the
      // element it was holding and can say "the Save button is gone".
      expect(hresult(get(held, uiaNamePropertyId, variant)), sOk);
      expect(_readVariantString(core, variant), 'Save');
      expect(hresult(get(held, uiaControlTypePropertyId, variant)), sOk);
      expect(_readVariantInt(variant), uiaButtonControlTypeId);
      // And it is no longer usable, which is a different statement.
      expect(hresult(get(held, uiaIsEnabledPropertyId, variant)), sOk);
      expect(_readVariantBool(variant), isFalse);

      final Pointer<Void> fragment =
          _queryInterface(held, iidIRawElementProviderFragment, arena);
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      expect(
        hresult(_intPointer(fragment, _slotNavigate)(
          fragment,
          navigateDirectionParent,
          out.cast(),
        )),
        uiaErrorElementNotAvailable,
      );
      final Pointer<UiaRect> rect = arena.allocate<UiaRect>(32);
      expect(
        hresult(
          _pointer(fragment, _slotBoundingRectangle)(fragment, rect.cast()),
        ),
        sOk,
      );
      expect(rect.ref.width, 0, reason: 'an empty rect is UIA "no location"');

      _release(fragment)(fragment);
      _release(held)(held);
    });

    test('a whole tree that is disposed freezes every element it handed out',
        () {
      final UiaProviderTree doomed =
          UiaProviderTree(core: core, hostProviderFor: () => nullptr)
            ..publish(_sample());
      final UiaNodeProvider provider = doomed.providerFor(1)!;
      final Pointer<Void> held = provider.pointer;
      comMethod<_NativeRefCount>(held, comSlotAddRef)
          .asFunction<_DartRefCount>()(held);

      expect(provider.isAlive, isTrue);
      doomed.dispose();
      // The generation, not a null check: "not published yet" and "published
      // and gone" are different answers and a null cannot tell them apart.
      expect(provider.isAlive, isFalse);
      expect(doomed.acceptsGeneration(provider.generation), isFalse);

      final Pointer<Void> variant =
          arena.allocate<Uint8>(variantSize).cast<Void>();
      expect(
        hresult(_intPointer(held, _slotGetPropertyValue)(
          held,
          uiaNamePropertyId,
          variant,
        )),
        sOk,
      );
      expect(_readVariantString(core, variant), 'Save');
      _release(held)(held);
    });
  });

  group('identity across frames', () {
    test('a node that survives a rebuild keeps its element', () {
      final Pointer<Void> before = button();
      tree.publish(_sample());
      expect(button(), before,
          reason: 'a fresh COM object per frame would make a screen reader '
              'think the window was replaced sixty times a second');
    });

    test('references handed out are balanced by the tree', () {
      final UiaNodeProvider provider = tree.providerFor(1)!;
      expect(provider.refCount, 1);
      final Pointer<Void> fragment =
          _queryInterface(root(), iidIRawElementProviderFragment, arena);
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      _intPointer(fragment, _slotNavigate)(
        fragment,
        navigateDirectionFirstChild,
        out.cast(),
      );
      expect(provider.refCount, 2, reason: 'Navigate added one for the caller');
      _release(out.value)(out.value);
      expect(provider.refCount, 1);
      _release(fragment)(fragment);
    });
  });
}
