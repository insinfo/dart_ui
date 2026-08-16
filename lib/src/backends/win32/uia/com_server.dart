/// COM the other way round: vtables **Windows calls into**, written in Dart.
///
/// `lib/src/ffi/com.dart` consumes COM - it takes a pointer somebody else
/// created, reads `lpVtbl`, indexes it and calls. A UI Automation provider is
/// the inverse: UIAutomationCore is handed a pointer, reads `lpVtbl`, indexes
/// it and calls **us**. Nothing in this repository did that before, so this
/// file exists.
///
/// ## What a COM object is, from the producing side
///
/// Exactly one thing: a block of memory whose first machine word points at an
/// array of function pointers, and whose function pointers take that block back
/// as their first argument. Everything else - reference counting,
/// `QueryInterface`, apartment rules - is convention layered on that.
///
/// So an object here is
///
///     word 0: lpVtbl        -> shared per interface, built once
///     word 1: token         -> index into [ComServerRegistry]
///
/// and a method is a `NativeCallable` closure that reads word 1, resolves the
/// Dart object, and runs.
///
/// **Why a token and not the Dart object's address.** The same argument
/// `win32_window_class.dart` makes for `GWLP_USERDATA`, and here it is even
/// sharper: a client of an automation API holds interface pointers for as long
/// as it likes and there is no message that says "stop". A token resolved
/// through a map cannot dangle - the map either has the entry or it does not -
/// and "does not" is answerable with `UIA_E_ELEMENTNOTAVAILABLE` instead of a
/// read of freed memory that still looks like a vtable.
///
/// ## Multiple interfaces: tear-offs, not multiple inheritance
///
/// C++ gets several vtables per object by inheriting several interfaces, and
/// the `this` pointer for the second one is the object's address plus eight.
/// That is unreproducible in Dart and unnecessary. Instead each interface gets
/// its own two-word block with its own token, all of them naming one
/// [ComServerObject] and sharing one reference count. `QueryInterface` hands
/// back the sibling.
///
/// The one rule this must not break is COM identity: `QueryInterface(IID_
/// IUnknown)` has to return the *same* pointer from every interface of one
/// object, because that is how a client decides whether two pointers are the
/// same thing. The first interface in the class's list is that pointer.
///
/// ## Threading, stated because it is the sharpest edge in this directory
///
/// Every method here is reached through `NativeCallable.isolateLocal`, which is
/// the only kind that can return a value - and a COM method that cannot return
/// an `HRESULT` is not a COM method. `isolateLocal` invoked from a thread that
/// is not the isolate's **aborts the process**. It is not catchable.
///
/// This file therefore does not pretend to be free-threaded. It records the
/// thread it was built on ([ComServerRegistry.ownerThreadId], set by the
/// backend) so that a report can say which thread the calls were expected on,
/// and `uia_bridge.dart` documents what has to be true for UI Automation to
/// call on that thread. Nothing here can enforce it: by the time a foreign
/// thread reaches the trampoline, Dart has already aborted.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../ffi/com.dart';
import '../../../ffi/native_memory.dart';
import '../../../foundation/lifecycle.dart';

// ---------------------------------------------------------------------------
// Native shapes
// ---------------------------------------------------------------------------

/// `ULONG Method(void* self)` - `AddRef` and `Release`.
typedef ComServerRefCountNative = Uint32 Function(Pointer<Void>);

/// `HRESULT QueryInterface(void* self, REFIID, void**)`.
typedef ComServerQueryInterfaceNative = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>);

/// `HRESULT Method(void* self)` - `Invoke`, `Toggle`, `SetFocus`, `Select`.
typedef ComServerSelfNative = Int32 Function(Pointer<Void>);

/// `HRESULT Method(void* self, void* p)` - every getter with one out
/// parameter, and every setter with one pointer argument. The two are the same
/// shape at the ABI and are deliberately not distinguished here.
typedef ComServerPointerNative = Int32 Function(Pointer<Void>, Pointer<Void>);

/// `HRESULT Method(void* self, int32 n, void* p)` - `GetPropertyValue`,
/// `GetPatternProvider`, `Navigate`.
typedef ComServerIntPointerNative = Int32 Function(
    Pointer<Void>, Int32, Pointer<Void>);

/// `HRESULT Method(void* self, double x, double y, void* p)` -
/// `ElementProviderFromPoint`.
typedef ComServerPointPointerNative = Int32 Function(
    Pointer<Void>, Double, Double, Pointer<Void>);

// ---------------------------------------------------------------------------
// Method descriptions
// ---------------------------------------------------------------------------

/// One method of one interface, at the slot its position in
/// [ComInterfaceSpec.methods] gives it.
sealed class ComMethod<T extends Object> {
  const ComMethod(this.name);

  /// The method's own name - `GetPropertyValue`, not `slot 5`. Used by the
  /// fault report, which is the only place a slot number is useless.
  final String name;
}

/// `HRESULT f(self)`.
final class ComSelfMethod<T extends Object> extends ComMethod<T> {
  const ComSelfMethod(super.name, this.call);

  final int Function(T target) call;
}

/// `HRESULT f(self, void* p)`.
final class ComPointerMethod<T extends Object> extends ComMethod<T> {
  const ComPointerMethod(super.name, this.call);

  final int Function(T target, Pointer<Void> argument) call;
}

/// `HRESULT f(self, int32 n, void* p)`.
final class ComIntPointerMethod<T extends Object> extends ComMethod<T> {
  const ComIntPointerMethod(super.name, this.call);

  final int Function(T target, int value, Pointer<Void> argument) call;
}

/// `HRESULT f(self, double x, double y, void* p)`.
final class ComPointPointerMethod<T extends Object> extends ComMethod<T> {
  const ComPointPointerMethod(super.name, this.call);

  final int Function(T target, double x, double y, Pointer<Void> argument) call;
}

/// One interface: its identifier, its name and its methods after `IUnknown`.
///
/// The three `IUnknown` slots are supplied by [ComServerClass] and are not
/// listed here, because getting them wrong is the failure that shows up as a
/// leak or a double free rather than as an error, and there is no reason for
/// an interface author to be able to.
final class ComInterfaceSpec<T extends Object> {
  const ComInterfaceSpec({
    required this.name,
    required this.iid,
    required this.methods,
  });

  /// `IRawElementProviderSimple`. Diagnostics only.
  final String name;

  final Guid iid;

  /// In vtable order, starting at slot 3.
  final List<ComMethod<T>> methods;
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

/// A fault raised inside a COM method this process implements.
final class ComServerFault {
  const ComServerFault({
    required this.interfaceName,
    required this.methodName,
    required this.error,
    required this.stackTrace,
  });

  final String interfaceName;
  final String methodName;
  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() => 'ComServerFault($interfaceName::$methodName: $error)';
}

/// Token to tear-off, and the fault log.
///
/// Static because the vtables are static: a `NativeCallable` built for a
/// vtable outlives every object that uses it, and it has to be able to resolve
/// `self` without capturing anything per object.
final class ComServerRegistry {
  ComServerRegistry._();

  static int _nextToken = 1;
  static final Map<int, _ComTearoff> _tearoffs = <int, _ComTearoff>{};

  /// The thread the provider objects were built on, as
  /// `GetCurrentThreadId` reports it, or 0 when nobody recorded it.
  ///
  /// Set by the backend. Read only by diagnostics: see the threading note in
  /// this library's own documentation for why it cannot be a guard.
  static int ownerThreadId = 0;

  static const int _maxFaults = 32;
  static final List<ComServerFault> _faults = <ComServerFault>[];

  static List<ComServerFault> get faults =>
      List<ComServerFault>.unmodifiable(_faults);

  static void clearFaults() => _faults.clear();

  /// How many tear-offs are alive. The teardown test asserts zero, which is a
  /// stronger claim than "dispose returned".
  static int get liveTearoffCount => _tearoffs.length;

  static void _report(ComServerFault fault) {
    if (_faults.length >= _maxFaults) _faults.removeAt(0);
    _faults.add(fault);
  }

  static int _register(_ComTearoff tearoff) {
    final int token = _nextToken++;
    _tearoffs[token] = tearoff;
    return token;
  }

  static void _unregister(int token) => _tearoffs.remove(token);

  static _ComTearoff? _resolve(Pointer<Void> self) {
    if (self == nullptr) return null;
    final int token = self.cast<IntPtr>()[1];
    return _tearoffs[token];
  }
}

/// One interface's two-word block.
final class _ComTearoff {
  _ComTearoff({
    required this.owner,
    required this.interfaceIndex,
    required this.pointer,
  });

  final ComServerObject<Object> owner;
  final int interfaceIndex;
  final Pointer<Void> pointer;

  late final int token;
}

// ---------------------------------------------------------------------------
// The class
// ---------------------------------------------------------------------------

/// The vtables for a set of interfaces, built once and shared by every object.
///
/// Building a vtable is expensive in the only way that matters here: one
/// `NativeCallable` per method, each of which is a trampoline the runtime has
/// to keep alive. A per-object vtable would mean forty of them per node in the
/// semantic tree. So the vtables belong to the class, exactly as they do in
/// C++, and an object is two words.
final class ComServerClass<T extends Object> with DisposableMixin {
  ComServerClass(this.className, this.interfaces) {
    if (interfaces.isEmpty) {
      throw ArgumentError.value(
        interfaces,
        'interfaces',
        'a COM class needs at least one interface: the first one is the '
            'object identity that QueryInterface(IID_IUnknown) must return',
      );
    }
    for (final ComInterfaceSpec<T> spec in interfaces) {
      _vtables.add(_buildVtable(spec));
    }
  }

  /// Diagnostics only - `UiaNodeProvider`.
  final String className;

  /// In order. The first is the object's `IUnknown` identity.
  final List<ComInterfaceSpec<T>> interfaces;

  final NativeAllocator _allocator = NativeAllocator.instance;
  final List<Pointer<IntPtr>> _vtables = <Pointer<IntPtr>>[];
  final List<NativeCallable<Function>> _callables =
      <NativeCallable<Function>>[];

  /// A live object of this class, holding one reference.
  ComServerObject<T> instantiate(T target) {
    throwIfDisposed();
    _liveObjects++;
    return ComServerObject<T>._(this, target);
  }

  int _liveObjects = 0;
  bool _tornDown = false;

  /// How many objects of this class have not reached a reference count of
  /// zero. The teardown test reads it.
  int get liveObjectCount => _liveObjects;

  /// Whether the vtables have actually been released.
  ///
  /// Not the same as [isDisposed]: see [onDispose].
  bool get isTornDown => _tornDown;

  Pointer<IntPtr> _buildVtable(ComInterfaceSpec<T> spec) {
    final List<int> slots = <int>[
      _bindQueryInterface(spec),
      _bindAddRef(spec),
      _bindRelease(spec),
    ];
    for (final ComMethod<T> method in spec.methods) {
      slots.add(switch (method) {
        ComSelfMethod<T>() => _bindSelf(spec, method),
        ComPointerMethod<T>() => _bindPointer(spec, method),
        ComIntPointerMethod<T>() => _bindIntPointer(spec, method),
        ComPointPointerMethod<T>() => _bindPointPointer(spec, method),
      });
    }
    final Pointer<IntPtr> vtable =
        _allocator.allocate<IntPtr>(slots.length * sizeOf<IntPtr>());
    for (int i = 0; i < slots.length; i++) {
      vtable[i] = slots[i];
    }
    return vtable;
  }

  /// Runs [body] with the object [self] names, turning every failure into an
  /// HRESULT rather than letting it unwind into the native frame.
  ///
  /// The exception policy is `win32_window_class.dart`'s, and for the same
  /// reason: a Dart exception crossing an FFI callback boundary is undefined
  /// behaviour at worst and a silently swallowed error at best. Here it
  /// becomes `E_FAIL` and a [ComServerFault], so the client sees a failure it
  /// can report and the log says which method.
  int _guard(
    ComInterfaceSpec<T> spec,
    ComMethod<T> method,
    Pointer<Void> self,
    int Function(ComServerObject<Object> object, T target) body,
  ) {
    try {
      final _ComTearoff? tearoff = ComServerRegistry._resolve(self);
      if (tearoff == null) {
        // The object was released and its token withdrawn. A client holding a
        // stale pointer is a bug on its side; answering rather than crashing
        // is the whole reason the indirection exists.
        return eFail;
      }
      return body(tearoff.owner, tearoff.owner.target as T);
    } on Object catch (error, stackTrace) {
      ComServerRegistry._report(
        ComServerFault(
          interfaceName: spec.name,
          methodName: method.name,
          error: error,
          stackTrace: stackTrace,
        ),
      );
      return eFail;
    }
  }

  int _keep<F extends Function>(NativeCallable<F> callable) {
    _callables.add(callable);
    return callable.nativeFunction.address;
  }

  int _bindQueryInterface(ComInterfaceSpec<T> spec) => _keep(
        NativeCallable<ComServerQueryInterfaceNative>.isolateLocal(
          (Pointer<Void> self, Pointer<Uint8> riid,
              Pointer<Pointer<Void>> out) {
            try {
              if (out == nullptr) return ePointer;
              out.value = nullptr;
              final _ComTearoff? tearoff = ComServerRegistry._resolve(self);
              if (tearoff == null) return eFail;
              if (riid == nullptr) return eInvalidArg;
              final Guid requested = _readGuid(riid);
              final Pointer<Void>? answer =
                  tearoff.owner._pointerFor(requested);
              if (answer == null) return eNoInterface;
              tearoff.owner._addRef();
              out.value = answer;
              return sOk;
            } on Object catch (error, stackTrace) {
              ComServerRegistry._report(
                ComServerFault(
                  interfaceName: spec.name,
                  methodName: 'QueryInterface',
                  error: error,
                  stackTrace: stackTrace,
                ),
              );
              return eFail;
            }
          },
          exceptionalReturn: eFail,
        ),
      );

  int _bindAddRef(ComInterfaceSpec<T> spec) => _keep(
        NativeCallable<ComServerRefCountNative>.isolateLocal(
          (Pointer<Void> self) {
            final _ComTearoff? tearoff = ComServerRegistry._resolve(self);
            return tearoff == null ? 0 : tearoff.owner._addRef();
          },
          exceptionalReturn: 0,
        ),
      );

  int _bindRelease(ComInterfaceSpec<T> spec) => _keep(
        NativeCallable<ComServerRefCountNative>.isolateLocal(
          (Pointer<Void> self) {
            final _ComTearoff? tearoff = ComServerRegistry._resolve(self);
            return tearoff == null ? 0 : tearoff.owner._release();
          },
          exceptionalReturn: 0,
        ),
      );

  int _bindSelf(ComInterfaceSpec<T> spec, ComSelfMethod<T> method) => _keep(
        NativeCallable<ComServerSelfNative>.isolateLocal(
          (Pointer<Void> self) =>
              _guard(spec, method, self, (_, T target) => method.call(target)),
          exceptionalReturn: eFail,
        ),
      );

  int _bindPointer(ComInterfaceSpec<T> spec, ComPointerMethod<T> method) =>
      _keep(
        NativeCallable<ComServerPointerNative>.isolateLocal(
          (Pointer<Void> self, Pointer<Void> argument) => _guard(
            spec,
            method,
            self,
            (_, T target) => method.call(target, argument),
          ),
          exceptionalReturn: eFail,
        ),
      );

  int _bindIntPointer(
    ComInterfaceSpec<T> spec,
    ComIntPointerMethod<T> method,
  ) =>
      _keep(
        NativeCallable<ComServerIntPointerNative>.isolateLocal(
          (Pointer<Void> self, int value, Pointer<Void> argument) => _guard(
            spec,
            method,
            self,
            (_, T target) => method.call(target, value, argument),
          ),
          exceptionalReturn: eFail,
        ),
      );

  int _bindPointPointer(
    ComInterfaceSpec<T> spec,
    ComPointPointerMethod<T> method,
  ) =>
      _keep(
        NativeCallable<ComServerPointPointerNative>.isolateLocal(
          (Pointer<Void> self, double x, double y, Pointer<Void> argument) =>
              _guard(
            spec,
            method,
            self,
            (_, T target) => method.call(target, x, y, argument),
          ),
          exceptionalReturn: eFail,
        ),
      );

  /// Asks for the vtables to be released, and releases them **only** once the
  /// last object of this class is gone.
  ///
  /// The deferral is not caution, it is the contract. A vtable slot is a
  /// `NativeCallable`'s trampoline, and `close()` on a callable that a live
  /// object still points at turns the next call into
  /// "Callback invoked after it has been deleted" - a VM-level abort with no
  /// Dart frame in it, arriving on whichever call a screen reader happened to
  /// make next.
  ///
  /// And live objects are the *normal* case at teardown: a client of an
  /// automation API holds element references across a window closing, and this
  /// directory's whole answer to that is that such an element keeps answering.
  /// It cannot keep answering through a freed vtable. So a disposed class
  /// stops handing out objects immediately and stops existing when the last
  /// one is released, which is what [isTornDown] distinguishes from
  /// [isDisposed].
  @override
  void onDispose() => _teardownIfIdle();

  void _objectDestroyed() {
    _liveObjects--;
    if (isDisposed) _teardownIfIdle();
  }

  void _teardownIfIdle() {
    if (_tornDown || _liveObjects > 0) return;
    _tornDown = true;
    for (final NativeCallable<Function> callable in _callables) {
      callable.close();
    }
    _callables.clear();
    for (final Pointer<IntPtr> vtable in _vtables) {
      _allocator.free(vtable);
    }
    _vtables.clear();
  }
}

/// One COM identity: several interface pointers, one reference count.
final class ComServerObject<T extends Object> with DisposableMixin {
  ComServerObject._(this._class, this.target) {
    final int count = _class.interfaces.length;
    // One allocation for every tear-off, two machine words each. One block
    // means one free, and a free that cannot be half done.
    _block = _class._allocator
        .allocate<IntPtr>(count * 2 * sizeOf<IntPtr>())
        .cast<Void>();
    for (int i = 0; i < count; i++) {
      final Pointer<IntPtr> slot = Pointer<IntPtr>.fromAddress(
          _block.address + i * 2 * sizeOf<IntPtr>());
      final _ComTearoff tearoff = _ComTearoff(
        owner: this,
        interfaceIndex: i,
        pointer: slot.cast<Void>(),
      );
      tearoff.token = ComServerRegistry._register(tearoff);
      slot[0] = _class._vtables[i].address;
      slot[1] = tearoff.token;
      _tearoffs.add(tearoff);
    }
  }

  final ComServerClass<T> _class;

  /// The Dart object the methods run against.
  final T target;

  late final Pointer<Void> _block;
  final List<_ComTearoff> _tearoffs = <_ComTearoff>[];

  /// One: the reference the creator owns and gives up in [dispose].
  int _refCount = 1;

  /// The object identity - the first interface, and what
  /// `QueryInterface(IID_IUnknown)` answers.
  Pointer<Void> get pointer => _tearoffs.first.pointer;

  /// The pointer for [iid], or null when this object does not implement it.
  ///
  /// Does **not** take a reference: this is the Dart-side question. The COM
  /// `QueryInterface` above adds the reference the caller then owns.
  Pointer<Void>? pointerForInterface(Guid iid) => _pointerFor(iid);

  Pointer<Void>? _pointerFor(Guid iid) {
    if (iid == iidIUnknown) return _tearoffs.first.pointer;
    for (int i = 0; i < _class.interfaces.length; i++) {
      if (_class.interfaces[i].iid == iid) return _tearoffs[i].pointer;
    }
    return null;
  }

  /// The current count, for the test that has to prove `AddRef` was matched.
  ///
  /// Readable directly, unlike a foreign object's - which `ComObject.refCount`
  /// can only get at by adding and dropping a reference. Both spellings agree
  /// on the same object, and the COM-side test checks exactly that.
  int get refCount => _refCount;

  /// Takes the reference a method is about to hand out.
  ///
  /// COM's rule for an out parameter: the callee adds the reference and the
  /// caller releases it. Every method here that writes an interface pointer
  /// into an out parameter calls this first, and forgetting to is the leak's
  /// mirror image - the client releases a reference nobody took and the object
  /// dies while the tree still points at it.
  int addRefForClient() => _addRef();

  int _addRef() => ++_refCount;

  int _release() {
    if (_refCount == 0) return 0;
    final int remaining = --_refCount;
    if (remaining == 0) _destroy();
    return remaining;
  }

  void _destroy() {
    for (final _ComTearoff tearoff in _tearoffs) {
      ComServerRegistry._unregister(tearoff.token);
    }
    _tearoffs.clear();
    _class._allocator.free(_block);
    _class._objectDestroyed();
  }

  /// Gives up the creator's reference.
  ///
  /// The object survives if a client still holds one - which is the point.
  /// Disposal is not destruction in COM and pretending otherwise is how a
  /// screen reader reads freed memory.
  @override
  void onDispose() => _release();
}

/// Reads a `REFIID` back into a [Guid].
///
/// The inverse of [Guid.toBytes] and, like it, the place a byte-order mistake
/// turns into `E_NOINTERFACE` for an interface we certainly implement.
Guid _readGuid(Pointer<Uint8> pointer) {
  final Uint8List bytes = pointer.asTypedList(16);
  final ByteData view = ByteData.sublistView(bytes);
  return Guid(
    view.getUint32(0, Endian.little),
    view.getUint16(4, Endian.little),
    view.getUint16(6, Endian.little),
    <int>[for (int i = 0; i < 8; i++) bytes[8 + i]],
  );
}
