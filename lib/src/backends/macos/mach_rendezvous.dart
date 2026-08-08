/// Handing an `IOSurface` to the host process the supported way.
///
/// `IOSurfaceLookup` is deprecated. The replacement,
/// `IOSurfaceLookupFromMachPort`, is a one-line change - the problem is
/// upstream of it: a mach port right is a capability the kernel moves, not a
/// number, so writing it into the pipe transfers nothing.
///
/// Three mechanisms were measured in
/// `doc/logs/MACH_PORT_HANDOFF_2026-08-08.md`:
///
///   * `mach_ports_register` inherited across the spawn - **fails**. libxpc's
///     `atfork` handler overwrites the registered-port array and Dart's
///     `Process.start` forks, so the slot is gone before the child exists.
///     The probe caught it in the *parent*: mask 5 before the spawn, mask 1
///     after. rdar://15417334, still true on macOS 14 arm64 in 2026.
///   * `bootstrap_register` - works, deprecated since 10.5. Recorded as
///     working, not chosen: building on it is the debt this spike came to pay.
///   * rendezvous via `bootstrap_check_in` - **works, and is what this file
///     implements**. The host checks a receive right in under a name derived
///     from its own pid, the *name* travels through the pipe perfectly well,
///     and the parent sends the port. No deprecated call, and no ordering
///     constraint: the channel outlives any one surface, so a resize is
///     another message rather than another process.
///
/// Only the chosen mechanism is implemented here. The other two live in
/// `poc/poc_20_macos_three_backends/lib/src/mach_port_transfer.dart` as the
/// record of the measurement.
library;

import 'dart:ffi';

import 'io_surface.dart';

/// `KERN_SUCCESS`.
const int kernSuccess = 0;

/// Returned instead of a `kern_return_t` when the symbol itself is missing, so
/// "the OS removed this API" reads differently from "the API said no".
const int kMachSymbolMissing = -1;

/// `BOOTSTRAP_UNKNOWN_SERVICE` - the host has not checked its name in yet.
const int kBootstrapUnknownService = 1102;

/// `BOOTSTRAP_NOT_PRIVILEGED` - what App Sandbox returns for `mach-register`.
/// A plain unsigned binary does not see it; a packaged one will, and that is
/// the day this backend needs an entitlement rather than a bug report.
const int kBootstrapNotPrivileged = 1100;

const int _machPortNull = 0;
const int _taskBootstrapPort = 4;

final DynamicLibrary _process = DynamicLibrary.process();

T? _tryLookup<T extends Function>(T Function() resolve) {
  try {
    return resolve();
  } on ArgumentError {
    return null;
  }
}

typedef _BootstrapLookUpNative = Int32 Function(
    Uint32 bootstrapPort, Pointer<Uint8> name, Pointer<Uint32> port);
typedef _BootstrapLookUp = int Function(
    int bootstrapPort, Pointer<Uint8> name, Pointer<Uint32> port);

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
  Uint32 notify,
);
typedef _MachMsg = int Function(
  Pointer<Uint8> message,
  int option,
  int sendSize,
  int receiveSize,
  int receiveName,
  int timeout,
  int notify,
);

final _bootstrapLookUp = _tryLookup<_BootstrapLookUp>(() =>
    _process.lookupFunction<_BootstrapLookUpNative, _BootstrapLookUp>(
        'bootstrap_look_up'));
final _taskGetSpecialPort = _tryLookup<_TaskGetSpecialPort>(() =>
    _process.lookupFunction<_TaskGetSpecialPortNative, _TaskGetSpecialPort>(
        'task_get_special_port'));
final _machMsg = _tryLookup<_MachMsg>(
    () => _process.lookupFunction<_MachMsgNative, _MachMsg>('mach_msg'));

/// `mach_task_self()` is a macro over an exported global, not a call.
int get _taskSelf => _process.lookup<Uint32>('mach_task_self_').value;

/// Sends a surface port to a host that published a bootstrap name.
final class MachRendezvous {
  const MachRendezvous._();

  // A mach message is header, body, descriptors, then inline data. Dart FFI
  // has no bitfields, so the port descriptor's packed final word is written
  // byte by byte. These offsets are the 64-bit userspace layout of
  // <mach/message.h> and are the one thing here a header change would break
  // silently - which is why the host validates the message shape and the id
  // before it believes a word of it.
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

  /// Must equal `kDartUiSurfaceMessageId` in the host. The host rejects any
  /// other id, because a bootstrap name is world-lookupable and therefore
  /// world-sendable.
  static const int surfaceMessageId = 0x64756930; // 'dui0'

  /// Whether the symbols this mechanism needs exist in this process.
  ///
  /// Checked by `probe()` so that "rendezvous unavailable" is reported before
  /// a window is created rather than as a five-second timeout during one.
  static bool get isAvailable =>
      _bootstrapLookUp != null &&
      _taskGetSpecialPort != null &&
      _machMsg != null;

  /// The task's bootstrap port.
  ///
  /// Read through `task_get_special_port` rather than libSystem's
  /// `bootstrap_port` global, which is a private cache of the same value and
  /// has been renamed before.
  static int? bootstrapPort() {
    final getSpecialPort = _taskGetSpecialPort;
    if (getSpecialPort == null) return null;
    final slot = macosCalloc<Uint32>(4);
    try {
      final status = getSpecialPort(_taskSelf, _taskBootstrapPort, slot);
      if (status != kernSuccess) return null;
      return slot.value;
    } finally {
      macosFree(slot);
    }
  }

  /// Sends [port] to the service the host published as [name].
  ///
  /// Returns 0 on success. A small positive number is a `bootstrap_look_up`
  /// status ([kBootstrapUnknownService] means the host has not checked in
  /// yet); a large one is a `mach_msg_return_t` (0x10000003
  /// `MACH_SEND_INVALID_DEST`, 0x10000004 `MACH_SEND_TIMED_OUT`). The two
  /// ranges do not overlap, so one integer carries both without ambiguity.
  static int send(
    String name,
    int port,
    int token, {
    int timeoutMilliseconds = 5000,
  }) {
    final lookUp = _bootstrapLookUp;
    final sendMessage = _machMsg;
    if (lookUp == null || sendMessage == null) return kMachSymbolMissing;
    final bootstrap = bootstrapPort();
    if (bootstrap == null) return kMachSymbolMissing;

    final encoded = _toCString(name);
    final serviceOut = macosCalloc<Uint32>(4);
    final message = macosCalloc<Uint8>(_messageSize);
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

      // COPY_SEND, not MOVE_SEND: the caller keeps its own right, so a failed
      // send leaves the surface exactly as it was and the deprecated fallback
      // is still usable.
      return sendMessage(
        message,
        _machSendMsg | _machSendTimeout,
        _messageSize,
        0,
        _machPortNull,
        timeoutMilliseconds,
        _machPortNull,
      );
    } finally {
      macosFree(encoded);
      macosFree(serviceOut);
      macosFree(message);
    }
  }

  /// NUL-terminated ASCII copy of [text]. Bootstrap names are ASCII by
  /// construction here (`HostCommands.rendezvousName`), so no UTF-8 encoder is
  /// needed and none is dragged in.
  static Pointer<Uint8> _toCString(String text) {
    final buffer = macosCalloc<Uint8>(text.length + 1);
    for (var index = 0; index < text.length; index++) {
      buffer[index] = text.codeUnitAt(index) & 0x7F;
    }
    return buffer;
  }
}
