import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Cooperative loop that waits for Win32 input, then yields to Dart between
/// native wait iterations so Futures and Timers retain their normal semantics.
final class Win32EventLoop {
  Win32EventLoop() : _threadId = GetCurrentThreadId();

  static const int _wakeMessage = WM_APP + 1;

  final int _threadId;
  bool _disposed = false;
  int nativeMessages = 0;
  int wakeMessages = 0;

  /// Posts an application message, causing a pending native wait to return.
  void wake() {
    if (_disposed) return;
    final posted = PostThreadMessage(_threadId, _wakeMessage, 0, 0);
    if (posted == 0) throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
  }

  /// Processes native messages and waits until [timeout] for new input.
  ///
  /// The returned future creates an event-loop boundary; this is what allows
  /// Dart Timer/Future callbacks to run alongside the native message queue.
  Future<void> pump(Duration timeout) async {
    if (_disposed) return;
    _drainMessages();
    MsgWaitForMultipleObjectsEx(
      0,
      nullptr,
      timeout.inMilliseconds,
      QUEUE_STATUS_FLAGS.QS_ALLINPUT,
      MSG_WAIT_FOR_MULTIPLE_OBJECTS_EX_FLAGS.MWMO_INPUTAVAILABLE,
    );
    _drainMessages();
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> runUntil(bool Function() shouldStop,
      {Duration idleTimeout = const Duration(milliseconds: 50)}) async {
    while (!shouldStop() && !_disposed) {
      await pump(idleTimeout);
    }
  }

  void dispose() {
    _disposed = true;
  }

  void _drainMessages() {
    final message = calloc<MSG>();
    try {
      while (PeekMessage(
              message, NULL, 0, 0, PEEK_MESSAGE_REMOVE_TYPE.PM_REMOVE) !=
          0) {
        nativeMessages++;
        if (message.ref.message == _wakeMessage) {
          wakeMessages++;
          continue;
        }
        TranslateMessage(message);
        DispatchMessage(message);
      }
    } finally {
      calloc.free(message);
    }
  }
}
