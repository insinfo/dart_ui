import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

@JS('chrome')
external JSObject get chrome;

void main() {
  final status = web.document.querySelector('#status')!;
  final runtime = chrome.getProperty<JSObject>('runtime'.toJS);
  runtime
      .callMethod<JSPromise<JSAny?>>(
        'sendMessage'.toJS,
        <String, Object?>{
          'channel': 'dart-ui-icp-brasil',
          'id': 'popup-status',
          'operation': 'status',
        }.jsify(),
      )
      .toDart
      .then((reply) {
    final value = reply?.dartify();
    final connected = value is Map && value['ok'] == true;
    status.textContent = connected
        ? 'Pronto para usar certificados ICP-Brasil'
        : 'Host nativo não encontrado';
    status.className = connected ? 'status ready' : 'status error';
  }, onError: (Object _) {
    status.textContent = 'Host nativo não encontrado';
    status.className = 'status error';
  });
}
