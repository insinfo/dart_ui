import 'dart:async';
import 'dart:isolate';

import 'clock.dart';
import 'win32_bindings.dart';

/// Background isolate that stands in for "any source of Dart work that the
/// loop cannot predict": a completed HTTP request, a decoded image, a reply
/// from a worker.
///
/// It stamps each message with the shared QPC clock so the loop isolate can
/// measure how long the message sat in the queue.
///
/// When [wakeHandle] is non-zero it also signals a kernel event after sending.
/// That is the hand-rolled equivalent of the proposed
/// `EventLoopDriver.setWakeCallback`.
void senderMain(List<Object> args) {
  final sendPort = args[0] as SendPort;
  final intervalUs = args[1] as int;
  final wakeHandle = args[2] as int;

  final control = ReceivePort();
  sendPort.send(control.sendPort);

  final timer = Timer.periodic(Duration(microseconds: intervalUs), (_) {
    sendPort.send(Clock.nowUs());
    if (wakeHandle != 0) {
      setEvent(wakeHandle);
    }
  });

  control.listen((Object? message) {
    timer.cancel();
    control.close();
  });
}
