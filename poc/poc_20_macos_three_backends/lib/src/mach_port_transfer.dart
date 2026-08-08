import 'dart:ffi';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Moving a mach port right to a child process.
//
// `IOSurfaceLookup` is deprecated; the supported replacement is
// `IOSurfaceLookupFromMachPort`. Swapping the call is trivial. The problem is
// upstream of it: a mach port right is a capability held in a task's port
// namespace, not a number, so writing it into a pipe transfers nothing. The
// port has to be moved by the kernel, which means one of a small number of
// mechanisms - and which of them an unsigned command-line binary with no
// launchd job and no entitlements is still allowed to use is not something the
// documentation answers. This file implements three so CI can answer it.
//
//   registered   `mach_ports_register` before the spawn, `mach_ports_lookup`
//                in the child. The kernel copies the parent's three registered
//                ports into every task it creates, so nothing has to be sent.
//                Cheapest by far, and the most likely to be broken: libxpc is
//                documented (rdar://15417334) to overwrite that array from its
//                atfork handler, and Dart's `Process.start` forks. Hence
//                [lookupRegisteredPorts] - the parent's own array is read back
//                after the spawn, which turns "did not work" into "libxpc took
//                the slot", or rules that explanation out.
//
//   bootstrap    `bootstrap_register` publishes the surface port itself under
//                a name; the child looks the name up. No message passing at
//                all. Deprecated since 10.5, so this may simply be refused.
//
//   rendezvous   The child publishes a receive right with `bootstrap_check_in`
//                and the parent sends it one message carrying the port. This
//                is the direction that avoids the chicken-and-egg problem: an
//                anonymous XPC endpoint cannot travel without a channel, but a
//                *name* travels fine through the pipe, and only the child
//                needs to create one. It is also the only mechanism with no
//                ordering constraint - the channel outlives any one surface,
//                so a resize is another message rather than another process.
//
// Nothing here throws on a mach failure. Every entry point returns the
// `kern_return_t` so the caller can print it, because on a spike the code that
// says which of three mechanisms failed and how is worth more than the code
// that works.
// ---------------------------------------------------------------------------

/// `KERN_SUCCESS`.
const int kernSuccess = 0;

/// Returned instead of a `kern_return_t` when the symbol itself is missing, so
/// "the OS removed this API" is distinguishable from "the API said no".
const int kSymbolMissing = -1;

/// `TASK_PORT_REGISTER_MAX` - the array has been three entries wide since
/// Mach, and `mach_ports_register` silently clears the slots a short array
/// does not cover, which is why every write here passes all three.
const int registeredPortSlots = 3;

const int _machPortNull = 0;
const int _taskBootstrapPort = 4;

final DynamicLibrary _process = DynamicLibrary.process();

/// Looks a symbol up without throwing, so a missing deprecated export is a
/// diagnostic rather than an exception thrown from an unrelated line later.
T? _tryLookup<T extends Function>(T Function() resolve) {
  try {
    return resolve();
  } on ArgumentError {
    return null;
  }
}

typedef _MachPortsRegisterNative = Int32 Function(
    Uint32 task, Pointer<Uint32> ports, Uint32 count);
typedef _MachPortsRegister = int Function(
    int task, Pointer<Uint32> ports, int count);

typedef _MachPortsLookupNative = Int32 Function(
    Uint32 task, Pointer<Pointer<Uint32>> ports, Pointer<Uint32> count);
typedef _MachPortsLookup = int Function(
    int task, Pointer<Pointer<Uint32>> ports, Pointer<Uint32> count);

typedef _BootstrapRegisterNative = Int32 Function(
    Uint32 bootstrapPort, Pointer<Utf8> name, Uint32 port);
typedef _BootstrapRegister = int Function(
    int bootstrapPort, Pointer<Utf8> name, int port);

typedef _BootstrapLookUpNative = Int32 Function(
    Uint32 bootstrapPort, Pointer<Utf8> name, Pointer<Uint32> port);
typedef _BootstrapLookUp = int Function(
    int bootstrapPort, Pointer<Utf8> name, Pointer<Uint32> port);

typedef _TaskGetSpecialPortNative = Int32 Function(
    Uint32 task, Int32 which, Pointer<Uint32> port);
typedef _TaskGetSpecialPort = int Function(
    int task, int which, Pointer<Uint32> port);

typedef _MachMsgNative = Int32 Function(
    Pointer<Uint8> message,
    Int32 option,
    Uint32 sendSize,
    Uint32 receiveSize,
    Uint32 receiveName,
    Uint32 timeout,
    Uint32 notify);
typedef _MachMsg = int Function(Pointer<Uint8> message, int option,
    int sendSize, int receiveSize, int receiveName, int timeout, int notify);

typedef _VmDeallocateNative = Int32 Function(
    Uint32 task, UintPtr address, UintPtr size);
typedef _VmDeallocate = int Function(int task, int address, int size);

final _machPortsRegister = _tryLookup<_MachPortsRegister>(() =>
    _process.lookupFunction<_MachPortsRegisterNative, _MachPortsRegister>(
        'mach_ports_register'));
final _machPortsLookup = _tryLookup<_MachPortsLookup>(() =>
    _process.lookupFunction<_MachPortsLookupNative, _MachPortsLookup>(
        'mach_ports_lookup'));
final _bootstrapRegister = _tryLookup<_BootstrapRegister>(() =>
    _process.lookupFunction<_BootstrapRegisterNative, _BootstrapRegister>(
        'bootstrap_register'));
final _bootstrapLookUp = _tryLookup<_BootstrapLookUp>(() =>
    _process.lookupFunction<_BootstrapLookUpNative, _BootstrapLookUp>(
        'bootstrap_look_up'));
final _taskGetSpecialPort = _tryLookup<_TaskGetSpecialPort>(() =>
    _process.lookupFunction<_TaskGetSpecialPortNative, _TaskGetSpecialPort>(
        'task_get_special_port'));
final _machMsg = _tryLookup<_MachMsg>(
    () => _process.lookupFunction<_MachMsgNative, _MachMsg>('mach_msg'));
final _vmDeallocate = _tryLookup<_VmDeallocate>(() => _process
    .lookupFunction<_VmDeallocateNative, _VmDeallocate>('vm_deallocate'));

/// `mach_task_self()` is a macro over an exported global, not a call, so the
/// global is what gets read here.
int get _taskSelf => _process.lookup<Uint32>('mach_task_self_').value;

/// The three registered ports as this task currently sees them.
class RegisteredPorts {
  const RegisteredPorts(this.status, this.ports);

  /// `kern_return_t` from `mach_ports_lookup`, or [kSymbolMissing].
  final int status;

  /// One entry per slot, `MACH_PORT_NULL` (0) where the slot is empty. Empty
  /// when [status] is not [kernSuccess].
  final List<int> ports;

  bool get ok => status == kernSuccess;

  /// Bit per occupied slot - the compact form the host prints, so both sides
  /// of the boundary can be compared in a log without arithmetic.
  int get occupancyMask {
    var mask = 0;
    for (var slot = 0; slot < ports.length; slot++) {
      if (ports[slot] != _machPortNull) mask |= 1 << slot;
    }
    return mask;
  }

  @override
  String toString() => 'RegisteredPorts(status: $status, mask: $occupancyMask)';
}

/// What [MachPortTransfer.registerInHighestFreeSlot] did, in enough detail to
/// explain a later failure in the child.
class RegisteredPortHandoff {
  const RegisteredPortHandoff({
    required this.slot,
    required this.status,
    required this.before,
    required this.after,
  });

  /// The slot the port was written to, or -1 if nothing was written.
  final int slot;

  /// `kern_return_t` from `mach_ports_register`, or [kSymbolMissing].
  final int status;

  /// The array before and after the write. If [after] does not contain the
  /// port at [slot], the registration did not even survive its own call.
  final RegisteredPorts before;
  final RegisteredPorts after;

  bool get ok => slot >= 0 && status == kernSuccess;
}

class MachPortTransfer {
  MachPortTransfer._();

  /// The task's bootstrap port. Read through `task_get_special_port` rather
  /// than the `bootstrap_port` global because the global is libSystem's
  /// private cache of the same value and has been renamed before.
  static int? bootstrapPort() {
    final getSpecialPort = _taskGetSpecialPort;
    if (getSpecialPort == null) return null;
    final slot = calloc<Uint32>();
    try {
      final status = getSpecialPort(_taskSelf, _taskBootstrapPort, slot);
      if (status != kernSuccess) return null;
      return slot.value;
    } finally {
      calloc.free(slot);
    }
  }

  // --- mechanism (a): registered ports --------------------------------------

  /// Reads this task's registered-port array.
  ///
  /// Called twice by the probe on purpose: once before the spawn to find a
  /// free slot, once after to see whether the array still holds what was put
  /// there. The second reading is the interesting one.
  static RegisteredPorts lookupRegisteredPorts() {
    final lookup = _machPortsLookup;
    if (lookup == null) return const RegisteredPorts(kSymbolMissing, []);
    final portsOut = calloc<Pointer<Uint32>>();
    final countOut = calloc<Uint32>();
    try {
      final status = lookup(_taskSelf, portsOut, countOut);
      if (status != kernSuccess) return RegisteredPorts(status, const []);
      final count = countOut.value;
      final array = portsOut.value;
      final ports = <int>[
        for (var index = 0; index < count; index++) array[index],
      ];
      // The array arrives as out-of-line memory the kernel allocated in this
      // task. Freeing it does not touch the rights it named.
      _vmDeallocate?.call(_taskSelf, array.address, count * 4);
      return RegisteredPorts(kernSuccess, ports);
    } finally {
      calloc.free(portsOut);
      calloc.free(countOut);
    }
  }

  /// Puts [port] into the highest free registered slot, preserving the others.
  ///
  /// Read-modify-write, not a bare write: libxpc keeps its own bootstrap port
  /// in this array, and `mach_ports_register` clears every slot the call does
  /// not name. Clearing libxpc's slot would leave the child without an XPC
  /// bootstrap - which for an AppKit host means no WindowServer, i.e. a much
  /// worse failure than the one being investigated.
  ///
  /// The *highest* free slot rather than the lowest because libxpc writes from
  /// slot 0 up. If it overwrites the array during the fork, a high slot comes
  /// back empty - a clean "not delivered" - where a low slot would come back
  /// holding somebody else's port, and handing a foreign port to
  /// `IOSurfaceLookupFromMachPort` is a worse experiment.
  static RegisteredPortHandoff registerInHighestFreeSlot(int port) {
    final register = _machPortsRegister;
    final before = lookupRegisteredPorts();
    if (register == null) {
      return RegisteredPortHandoff(
          slot: -1, status: kSymbolMissing, before: before, after: before);
    }
    if (!before.ok) {
      return RegisteredPortHandoff(
          slot: -1, status: before.status, before: before, after: before);
    }

    final slots = List<int>.filled(registeredPortSlots, _machPortNull);
    for (var index = 0; index < before.ports.length; index++) {
      if (index < registeredPortSlots) slots[index] = before.ports[index];
    }
    var chosen = -1;
    for (var index = registeredPortSlots - 1; index >= 0; index--) {
      if (slots[index] == _machPortNull) {
        chosen = index;
        break;
      }
    }
    if (chosen < 0) {
      return RegisteredPortHandoff(
          slot: -1, status: kernSuccess, before: before, after: before);
    }
    slots[chosen] = port;

    final array = calloc<Uint32>(registeredPortSlots);
    try {
      for (var index = 0; index < registeredPortSlots; index++) {
        array[index] = slots[index];
      }
      final status = register(_taskSelf, array, registeredPortSlots);
      final after = lookupRegisteredPorts();
      return RegisteredPortHandoff(
        slot: status == kernSuccess ? chosen : -1,
        status: status,
        before: before,
        after: after,
      );
    } finally {
      calloc.free(array);
    }
  }

  // --- mechanism (b): bootstrap_register ------------------------------------

  /// Publishes [port] under [name] in the bootstrap namespace.
  ///
  /// Returns `kern_return_t`; 1100 is `BOOTSTRAP_NOT_PRIVILEGED`, which is the
  /// expected answer if launchd has finished retiring this call.
  static int bootstrapRegister(String name, int port) {
    final register = _bootstrapRegister;
    if (register == null) return kSymbolMissing;
    final bootstrap = bootstrapPort();
    if (bootstrap == null) return kSymbolMissing;
    final encoded = name.toNativeUtf8();
    try {
      return register(bootstrap, encoded, port);
    } finally {
      calloc.free(encoded);
    }
  }

  // --- mechanism (c): rendezvous over a child-published name ----------------

  // A mach message is a header, an optional body, then descriptors, then
  // inline data. Dart FFI has no bitfields, so the port descriptor's packed
  // last word is written byte by byte; the offsets below are the 64-bit
  // userspace layout of <mach/message.h> and are the one thing in this file
  // that a header change would silently break.
  static const int _msghBits = 0;
  static const int _msghSize = 4;
  static const int _msghRemotePort = 8;
  static const int _msghLocalPort = 12;
  static const int _msghVoucherPort = 16;
  static const int _msghId = 20;
  static const int _bodyDescriptorCount = 24;
  static const int _descriptorName = 28;
  static const int _descriptorPad1 = 32;
  static const int _descriptorPad2 = 36; // uint16
  static const int _descriptorDisposition = 38; // uint8
  static const int _descriptorType = 39; // uint8
  static const int _messageToken = 40;
  static const int _messageSize = 44;

  static const int _machMsgTypeCopySend = 19;
  static const int _machMsgPortDescriptor = 0;
  static const int _machMsghBitsComplex = 0x80000000;
  static const int _machSendMsg = 0x00000001;
  static const int _machSendTimeout = 0x00000010;

  /// Must match `kDartUiSurfaceMessageId` in `minimal_appkit_host.m`. The host
  /// rejects anything else, because a bootstrap name is world-lookupable and
  /// therefore world-sendable.
  static const int surfaceMessageId = 0x64756930; // 'dui0'

  /// Sends [port] to the service the host published as [name].
  ///
  /// Returns a `mach_msg_return_t`: 0 is success, 0x10000003 is
  /// `MACH_SEND_INVALID_DEST`, 0x10000004 `MACH_SEND_TIMED_OUT`. The lookup
  /// failing first is reported as the `bootstrap_look_up` status instead, and
  /// those are small positive numbers (1102 = unknown service), so the two
  /// cannot be confused.
  static int rendezvousSend(String name, int port, int token,
      {int timeoutMilliseconds = 5000}) {
    final lookUp = _bootstrapLookUp;
    final send = _machMsg;
    if (lookUp == null || send == null) return kSymbolMissing;
    final bootstrap = bootstrapPort();
    if (bootstrap == null) return kSymbolMissing;

    final encoded = name.toNativeUtf8();
    final serviceOut = calloc<Uint32>();
    final message = calloc<Uint8>(_messageSize);
    try {
      final status = lookUp(bootstrap, encoded, serviceOut);
      if (status != kernSuccess) return status;

      final words = message.cast<Uint32>();
      words[_msghBits ~/ 4] = _machMsgTypeCopySend | _machMsghBitsComplex;
      words[_msghSize ~/ 4] = _messageSize;
      words[_msghRemotePort ~/ 4] = serviceOut.value;
      words[_msghLocalPort ~/ 4] = _machPortNull;
      words[_msghVoucherPort ~/ 4] = _machPortNull;
      words[_msghId ~/ 4] = surfaceMessageId;
      words[_bodyDescriptorCount ~/ 4] = 1;
      words[_descriptorName ~/ 4] = port;
      words[_descriptorPad1 ~/ 4] = 0;
      words[_descriptorPad2 ~/ 4] = 0;
      message[_descriptorDisposition] = _machMsgTypeCopySend;
      message[_descriptorType] = _machMsgPortDescriptor;
      words[_messageToken ~/ 4] = token;

      // COPY_SEND rather than MOVE_SEND: the caller keeps its own right, so a
      // failed send leaves the surface exactly as it was and the fallback can
      // still use it.
      return send(message, _machSendMsg | _machSendTimeout, _messageSize, 0,
          _machPortNull, timeoutMilliseconds, _machPortNull);
    } finally {
      calloc.free(encoded);
      calloc.free(serviceOut);
      calloc.free(message);
    }
  }
}
