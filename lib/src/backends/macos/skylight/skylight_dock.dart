/// The Dock, for a process with no AppKit: a tile, minimise and restore,
/// and the Apple Events a click on the tile sends.
///
/// Measured on macOS 27, 2026-10-12, with SkyLight windows and no
/// NSApplication:
///
///   * `TransformProcessType(psn, kProcessTransformToForegroundApplication)`
///     turns the process from `BackgroundOnly` into `Foreground` - it gets a
///     Dock tile;
///   * `CoreDockMinimizeItemWithTitleAsync(windowId, title)` has the Dock
///     take the window off screen with its minimise effect, and
///     `CoreDockRestoreItemAsync(windowId)` brings it back - without the
///     process registering as a Dock client, so nothing here needs a run
///     loop or a callback from another thread. `SLSWindowIsOrderedIn` says
///     which side of that a window is on, which is how a restore the Dock
///     does by itself is noticed;
///   * a click on the tile is `kAEReopenApplication`, and Quit in its menu
///     `kAEQuitApplication`, sent to the port `AEGetRegisteredMachPort`
///     answers. The port is polled like the event port and each message
///     handed to `AEProcessMessage` on this thread, which calls the handlers
///     installed here synchronously. The message must be received with the
///     audit trailer, or `AEProcessMessage` rejects it.
///
/// `CoreDock*` is private API: the signatures come from the arguments of
/// the Dock's MIG messages and from what AppKit and HIToolbox import.
library;

import 'dart:ffi';

import '../../../ffi/objc_runtime.dart'
    show objcAllocateCString, objcFreeCString;
import '../io_surface.dart' show macosCalloc, macosFree;

typedef _VoidPtr = Pointer<Void>;
typedef _AEHandlerNative = Int16 Function(_VoidPtr, _VoidPtr, _VoidPtr);

/// What the Dock asked of the application.
enum SkylightDockRequest {
  /// The tile was clicked: bring back what is minimised.
  reopen,

  /// Quit, from the tile's menu.
  quit,
}

// Four-character codes.
const int _kCoreEventClass = 0x61657674; // 'aevt'
const int _kAEReopenApplication = 0x72617070; // 'rapp'
const int _kAEQuitApplication = 0x71756974; // 'quit'
const int _kCFStringEncodingUTF8 = 0x08000100;
const int _kErrAEEventNotHandled = -1708;

// mach_msg: MACH_RCV_MSG | MACH_RCV_LARGE | MACH_RCV_TIMEOUT, with the
// audit trailer (MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT)).
const int _kReceiveOptions = 0x2 | 0x4 | 0x100 | (3 << 24);
const int _kMachRcvTooLarge = 0x10004004;

final class SkylightDock {
  SkylightDock._(this._services, this._coreServices, this._coreFoundation);

  /// Gives the process its tile and installs the Apple Event handlers;
  /// null when the process cannot become a foreground application.
  static SkylightDock? open(DynamicLibrary coreFoundation) {
    try {
      final DynamicLibrary services = DynamicLibrary.open('/System/Library/'
          'Frameworks/ApplicationServices.framework/ApplicationServices');
      final DynamicLibrary coreServices = DynamicLibrary.open(
          '/System/Library/Frameworks/CoreServices.framework/CoreServices');
      final SkylightDock dock =
          SkylightDock._(services, coreServices, coreFoundation);
      if (!dock._becomeForeground()) return null;
      dock._installHandlers();
      return dock;
    } on Object {
      return null;
    }
  }

  final DynamicLibrary _services;
  final DynamicLibrary _coreServices;
  final DynamicLibrary _coreFoundation;
  final List<SkylightDockRequest> _requests = <SkylightDockRequest>[];
  NativeCallable<_AEHandlerNative>? _reopen;
  NativeCallable<_AEHandlerNative>? _quit;
  int _port = 0;
  Pointer<Uint8> _buffer = nullptr;
  int _bufferSize = 0;
  bool _disposed = false;

  bool _becomeForeground() {
    final Pointer<Uint32> psn = macosCalloc<Uint32>(8);
    try {
      _services.lookupFunction<Int16 Function(Pointer<Uint32>),
          int Function(Pointer<Uint32>)>('GetCurrentProcess')(psn);
      // kProcessTransformToForegroundApplication.
      return _services.lookupFunction<Int32 Function(Pointer<Uint32>, Uint32),
              int Function(Pointer<Uint32>, int)>('TransformProcessType')(
            psn,
            1,
          ) ==
          0;
    } finally {
      macosFree(psn);
    }
  }

  void _installHandlers() {
    final install = _coreServices.lookupFunction<
        Int16 Function(Uint32, Uint32,
            Pointer<NativeFunction<_AEHandlerNative>>, _VoidPtr, Bool),
        int Function(int, int, Pointer<NativeFunction<_AEHandlerNative>>,
            _VoidPtr, bool)>('AEInstallEventHandler');
    _reopen = NativeCallable<_AEHandlerNative>.isolateLocal(
        (_VoidPtr event, _VoidPtr reply, _VoidPtr refcon) {
      _requests.add(SkylightDockRequest.reopen);
      return 0;
    }, exceptionalReturn: _kErrAEEventNotHandled);
    _quit = NativeCallable<_AEHandlerNative>.isolateLocal(
        (_VoidPtr event, _VoidPtr reply, _VoidPtr refcon) {
      _requests.add(SkylightDockRequest.quit);
      return 0;
    }, exceptionalReturn: _kErrAEEventNotHandled);
    install(_kCoreEventClass, _kAEReopenApplication, _reopen!.nativeFunction,
        nullptr, false);
    install(_kCoreEventClass, _kAEQuitApplication, _quit!.nativeFunction,
        nullptr, false);
    _port = _coreServices.lookupFunction<Uint32 Function(), int Function()>(
        'AEGetRegisteredMachPort')();
  }

  /// Takes [windowId] off screen into the Dock, titled [title].
  bool minimize(int windowId, String title) {
    final Pointer<Uint8> text = objcAllocateCString(title);
    final _VoidPtr string = _coreFoundation.lookupFunction<
        _VoidPtr Function(_VoidPtr, Pointer<Uint8>, Uint32),
        _VoidPtr Function(
            _VoidPtr, Pointer<Uint8>, int)>('CFStringCreateWithCString')(
      nullptr,
      text,
      _kCFStringEncodingUTF8,
    );
    objcFreeCString(text);
    try {
      return _services.lookupFunction<Int32 Function(Uint32, _VoidPtr),
                  int Function(int, _VoidPtr)>(
              'CoreDockMinimizeItemWithTitleAsync')(windowId, string) ==
          0;
    } finally {
      if (string != nullptr) {
        _coreFoundation.lookupFunction<Void Function(_VoidPtr),
            void Function(_VoidPtr)>('CFRelease')(string);
      }
    }
  }

  /// Brings [windowId] back from the Dock.
  bool restore(int windowId) =>
      _services.lookupFunction<Int32 Function(Uint32), int Function(int)>(
          'CoreDockRestoreItemAsync')(windowId) ==
      0;

  /// Forgets [windowId]'s minimised tile, for a window closed while in the
  /// Dock.
  void remove(int windowId) =>
      _services.lookupFunction<Int32 Function(Uint32), int Function(int)>(
          'CoreDockRemoveItem')(windowId);

  /// The Apple Events queued since the last call, as requests, without
  /// blocking: [queued] says how many messages wait on a port.
  List<SkylightDockRequest> poll(int Function(int port) queued) {
    if (_disposed || _port == 0) return const <SkylightDockRequest>[];
    for (var guard = 0; guard < 16 && queued(_port) > 0; guard++) {
      if (!_receiveOne()) break;
    }
    if (_requests.isEmpty) return const <SkylightDockRequest>[];
    final List<SkylightDockRequest> requests =
        List<SkylightDockRequest>.of(_requests);
    _requests.clear();
    return requests;
  }

  late final int Function(Pointer<Uint8>, int, int, int, int, int, int)
      _machMsg = DynamicLibrary.process().lookupFunction<
          Int32 Function(
              Pointer<Uint8>, Int32, Uint32, Uint32, Uint32, Uint32, Uint32),
          int Function(
              Pointer<Uint8>, int, int, int, int, int, int)>('mach_msg');

  bool _receiveOne() {
    var size = _bufferSize == 0 ? 16384 : _bufferSize;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (size > _bufferSize) {
        if (_buffer != nullptr) macosFree(_buffer);
        _buffer = macosCalloc<Uint8>(size);
        _bufferSize = size;
      }
      final int rc =
          _machMsg(_buffer, _kReceiveOptions, 0, _bufferSize, _port, 0, 0);
      if (rc == _kMachRcvTooLarge) {
        // MACH_RCV_LARGE left the message queued and wrote its size, plus
        // room for the trailer.
        size = _buffer.cast<Uint32>()[1] + 256;
        continue;
      }
      if (rc != 0) return false;
      _coreServices.lookupFunction<Int32 Function(Pointer<Uint8>),
          int Function(Pointer<Uint8>)>('AEProcessMessage')(_buffer);
      return true;
    }
    return false;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final remove = _coreServices.lookupFunction<
        Int16 Function(
            Uint32, Uint32, Pointer<NativeFunction<_AEHandlerNative>>, Bool),
        int Function(int, int, Pointer<NativeFunction<_AEHandlerNative>>,
            bool)>('AERemoveEventHandler');
    if (_reopen != null) {
      remove(_kCoreEventClass, _kAEReopenApplication, _reopen!.nativeFunction,
          false);
    }
    if (_quit != null) {
      remove(
          _kCoreEventClass, _kAEQuitApplication, _quit!.nativeFunction, false);
    }
    _reopen?.close();
    _quit?.close();
    _reopen = null;
    _quit = null;
    if (_buffer != nullptr) macosFree(_buffer);
    _buffer = nullptr;
    _bufferSize = 0;
  }
}
