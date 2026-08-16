/// The Dart-side COM vtable, checked by calling it the way Windows does.
///
/// Everything in this file runs on every platform, and that is not an
/// accident: `com_server.dart` names no Windows type. It allocates memory,
/// writes function pointers into it and hands the block to whoever asks - and
/// the questions worth asking about it (is the identity rule kept, is
/// `AddRef` matched by `Release`, does a stale pointer answer instead of
/// crashing) are questions about arithmetic and bookkeeping, not about COM
/// being installed.
///
/// The calls are made through `comMethod` from `lib/src/ffi/com.dart` - the
/// *consuming* side of the same ABI - so the two halves of this repository's
/// COM support are tested against each other. If the producer wrote slot 3
/// where the consumer reads slot 4, this file fails.
library;

import 'dart:ffi';

import 'package:dart_ui/src/backends/win32/uia/com_server.dart';
import 'package:dart_ui/src/ffi/com.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:test/test.dart';

/// A payload with two facts to read back through a vtable.
final class _Target {
  _Target(this.number);

  int number;
  int selfCalls = 0;
  bool throwOnSelf = false;
}

final Guid _iidFirst = Guid.parse('11111111-2222-3333-4444-555555555555');
final Guid _iidSecond = Guid.parse('66666666-7777-8888-9999-aaaaaaaaaaaa');
final Guid _iidAbsent = Guid.parse('deadbeef-0000-0000-0000-000000000000');

ComServerClass<_Target> _buildClass() => ComServerClass<_Target>(
      '_Target',
      <ComInterfaceSpec<_Target>>[
        ComInterfaceSpec<_Target>(
          name: 'IFirst',
          iid: _iidFirst,
          methods: <ComMethod<_Target>>[
            ComSelfMethod<_Target>('Bump', (_Target target) {
              if (target.throwOnSelf) throw StateError('deliberate');
              target.selfCalls++;
              return sOk;
            }),
            ComPointerMethod<_Target>('GetNumber',
                (_Target target, Pointer<Void> out) {
              if (out == nullptr) return ePointer;
              out.cast<Int32>().value = target.number;
              return sOk;
            }),
            ComIntPointerMethod<_Target>('Add',
                (_Target target, int value, Pointer<Void> out) {
              out.cast<Int32>().value = target.number + value;
              return sOk;
            }),
            ComPointPointerMethod<_Target>('Sum',
                (_Target target, double x, double y, Pointer<Void> out) {
              out.cast<Double>().value = x + y;
              return sOk;
            }),
          ],
        ),
        ComInterfaceSpec<_Target>(
          name: 'ISecond',
          iid: _iidSecond,
          methods: <ComMethod<_Target>>[
            ComPointerMethod<_Target>('GetDoubled',
                (_Target target, Pointer<Void> out) {
              out.cast<Int32>().value = target.number * 2;
              return sOk;
            }),
          ],
        ),
      ],
    );

// The consuming side, spelled the way `d3d11_bindings.dart` spells it: a slot
// number and both signatures at the call site.
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

void main() {
  setUp(ComServerRegistry.clearFaults);

  group('a Dart-implemented COM object', () {
    test('is a pointer to a vtable, and slot 3 is the first real method', () {
      final ComServerClass<_Target> klass = _buildClass();
      final ComServerObject<_Target> object = klass.instantiate(_Target(7));
      final arena = NativeArena();
      try {
        final _DartSelf bump =
            comMethod<_NativeSelf>(object.pointer, 3).asFunction();
        expect(hresult(bump(object.pointer)), sOk);
        expect(object.target.selfCalls, 1);

        final Pointer<Int32> out = arena.allocate<Int32>(4);
        final _DartPointer getNumber =
            comMethod<_NativePointer>(object.pointer, 4).asFunction();
        expect(hresult(getNumber(object.pointer, out.cast())), sOk);
        expect(out.value, 7);

        final _DartIntPointer add =
            comMethod<_NativeIntPointer>(object.pointer, 5).asFunction();
        expect(hresult(add(object.pointer, 35, out.cast())), sOk);
        expect(out.value, 42);

        final Pointer<Double> sumOut = arena.allocate<Double>(8);
        final _DartPointPointer sum =
            comMethod<_NativePointPointer>(object.pointer, 6).asFunction();
        expect(hresult(sum(object.pointer, 1.5, 2.25, sumOut.cast())), sOk);
        expect(sumOut.value, 3.75);
      } finally {
        arena.dispose();
        object.dispose();
        klass.dispose();
      }
    });

    test(
        'answers QueryInterface for what it has and E_NOINTERFACE for what '
        'it has not', () {
      final ComServerClass<_Target> klass = _buildClass();
      final ComServerObject<_Target> object = klass.instantiate(_Target(3));
      final arena = NativeArena();
      try {
        final _DartQueryInterface qi =
            comMethod<_NativeQueryInterface>(object.pointer, 0).asFunction();
        final Pointer<Pointer<Void>> out = arena.allocateOutPointer();

        expect(
          hresult(qi(object.pointer, _iidSecond.allocateIn(arena), out)),
          sOk,
        );
        expect(out.value, isNot(nullptr));
        // A second interface is a *different* pointer, which is the whole
        // reason tear-offs exist: its vtable has ISecond's methods at slot 3.
        expect(out.value, isNot(object.pointer));
        final Pointer<Int32> value = arena.allocate<Int32>(4);
        final _DartPointer getDoubled =
            comMethod<_NativePointer>(out.value, 3).asFunction();
        expect(hresult(getDoubled(out.value, value.cast())), sOk);
        expect(value.value, 6);

        expect(
          hresult(qi(object.pointer, _iidAbsent.allocateIn(arena), out)),
          eNoInterface,
        );
        // COM requires the out parameter to be nulled on failure. A client
        // that releases whatever was there is releasing a stack value.
        expect(out.value, nullptr);
      } finally {
        arena.dispose();
        // Two references: the creator's and the one QueryInterface added.
        expect(object.refCount, 2);
        object.dispose();
        expect(object.refCount, 1);
        // Standing in for the client releasing what it was given.
        comMethod<_NativeRefCount>(object.pointer, 2)
            .asFunction<_DartRefCount>()(object.pointer);
        klass.dispose();
      }
    });

    test(
        'keeps COM identity: IUnknown is the same pointer from every '
        'interface', () {
      final ComServerClass<_Target> klass = _buildClass();
      final ComServerObject<_Target> object = klass.instantiate(_Target(1));
      final arena = NativeArena();
      try {
        final Pointer<Void>? second = object.pointerForInterface(_iidSecond);
        expect(second, isNotNull);
        expect(second, isNot(object.pointer));

        final _DartQueryInterface fromFirst =
            comMethod<_NativeQueryInterface>(object.pointer, 0).asFunction();
        final _DartQueryInterface fromSecond =
            comMethod<_NativeQueryInterface>(second!, 0).asFunction();
        final Pointer<Pointer<Void>> a = arena.allocateOutPointer();
        final Pointer<Pointer<Void>> b = arena.allocateOutPointer();
        final Pointer<Uint8> iid = iidIUnknown.allocateIn(arena);

        expect(hresult(fromFirst(object.pointer, iid, a)), sOk);
        expect(hresult(fromSecond(second, iid, b)), sOk);
        // The rule a client uses to decide whether two pointers are the same
        // object. Breaking it makes a tree walk revisit nodes forever.
        expect(a.value, b.value);
        expect(a.value, object.pointer);
      } finally {
        arena.dispose();
        object.dispose();
        klass.dispose();
      }
    });
  });

  group('reference counting', () {
    test('AddRef and Release balance, counted rather than assumed', () {
      final ComServerClass<_Target> klass = _buildClass();
      final ComServerObject<_Target> object = klass.instantiate(_Target(0));
      final _DartRefCount addRef =
          comMethod<_NativeRefCount>(object.pointer, 1).asFunction();
      final _DartRefCount release =
          comMethod<_NativeRefCount>(object.pointer, 2).asFunction();

      expect(object.refCount, 1, reason: 'the creator holds exactly one');
      expect(addRef(object.pointer), 2);
      expect(addRef(object.pointer), 3);
      expect(release(object.pointer), 2);
      expect(release(object.pointer), 1);
      expect(object.refCount, 1);

      final int before = ComServerRegistry.liveTearoffCount;
      object.dispose();
      // Two interfaces, both withdrawn on the last release.
      expect(ComServerRegistry.liveTearoffCount, before - 2);
      klass.dispose();
    });

    test(
        'the object outlives dispose() while a client still holds a '
        'reference', () {
      final ComServerClass<_Target> klass = _buildClass();
      final ComServerObject<_Target> object = klass.instantiate(_Target(9));
      final _DartRefCount addRef =
          comMethod<_NativeRefCount>(object.pointer, 1).asFunction();
      final _DartRefCount release =
          comMethod<_NativeRefCount>(object.pointer, 2).asFunction();
      final arena = NativeArena();
      try {
        addRef(object.pointer); // the client takes one
        object.dispose(); // the owner gives up its own
        expect(object.refCount, 1);

        // Still fully usable. This is the case that separates "disposed" from
        // "destroyed", and getting it wrong is a read of freed memory inside
        // whatever screen reader is attached.
        final Pointer<Int32> out = arena.allocate<Int32>(4);
        final _DartPointer getNumber =
            comMethod<_NativePointer>(object.pointer, 4).asFunction();
        expect(hresult(getNumber(object.pointer, out.cast())), sOk);
        expect(out.value, 9);

        expect(release(object.pointer), 0);
        expect(object.refCount, 0);
      } finally {
        arena.dispose();
        klass.dispose();
      }
    });

    test('a released object answers instead of crashing', () {
      final ComServerClass<_Target> klass = _buildClass();
      final ComServerObject<_Target> object = klass.instantiate(_Target(5));
      final Pointer<Void> stale = object.pointer;
      final arena = NativeArena();
      try {
        object.dispose();
        expect(object.refCount, 0);

        // The pointer is now a block the allocator has taken back and a token
        // the registry has withdrawn. Reading word 1 finds an id that resolves
        // to nothing, and every method says so.
        final _DartRefCount addRef =
            comMethod<_NativeRefCount>(stale, 1).asFunction();
        expect(addRef(stale), 0);
      } finally {
        arena.dispose();
        klass.dispose();
      }
    },
        skip: 'reads memory the allocator has already reclaimed; kept as the '
            'written statement of what the token indirection is for, and run by '
            'hand under a heap checker rather than in CI');
  });

  group('a method that throws', () {
    test('becomes E_FAIL and a fault, never an unwind into the native frame',
        () {
      final ComServerClass<_Target> klass = _buildClass();
      final _Target target = _Target(0)..throwOnSelf = true;
      final ComServerObject<_Target> object = klass.instantiate(target);
      try {
        final _DartSelf bump =
            comMethod<_NativeSelf>(object.pointer, 3).asFunction();
        expect(hresult(bump(object.pointer)), eFail);
        expect(ComServerRegistry.faults, hasLength(1));
        expect(ComServerRegistry.faults.single.methodName, 'Bump');
        expect(ComServerRegistry.faults.single.interfaceName, 'IFirst');
        expect(target.selfCalls, 0);
      } finally {
        object.dispose();
        klass.dispose();
      }
    });
  });

  group('a class', () {
    test(
        'refuses to be built with no interfaces, because the first one is '
        'the object identity', () {
      expect(
        () => ComServerClass<_Target>('empty', <ComInterfaceSpec<_Target>>[]),
        throwsArgumentError,
      );
    });
  });
}

typedef _NativeRefCount = Uint32 Function(Pointer<Void>);
typedef _DartRefCount = int Function(Pointer<Void>);
typedef _NativeQueryInterface = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>);
typedef _DartQueryInterface = int Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>);
