import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

@JS('globalThis')
external JSObject get globalThis;

void main() {
  final api = JSObject();
  for (final operation in const <String>[
    'status',
    'listCertificates',
    'authenticate',
    'signPdf',
    'signPdfHash',
  ]) {
    api.setProperty(
        operation.toJS, ((JSAny? args) => _request(operation, args)).toJS);
  }
  globalThis.setProperty('dartUiIcpBrasil'.toJS, api);
}

JSPromise<JSAny?> _request(String operation, JSAny? args) {
  final id = '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  // A JS Promise is used so ordinary sites can simply `await` the API.
  return JSPromise<JSAny?>(((JSFunction resolve, JSFunction reject) {
    late JSFunction listener;
    listener = ((web.MessageEvent event) {
      final data = event.data.dartify();
      if (event.source != web.window ||
          data is! Map ||
          data['id'] != id ||
          data['direction'] != 'response') {
        return;
      }
      web.window.removeEventListener('message', listener);
      final payload = data['payload'];
      if (payload is Map && payload['ok'] == true) {
        resolve.callAsFunction(null, (payload['result'] as Object?).jsify());
      } else {
        final Object? error = payload is Map ? payload['error'] : payload;
        reject.callAsFunction(null, error.jsify());
      }
    }).toJS;
    web.window.addEventListener('message', listener);
    final values = args?.dartify();
    web.window.postMessage(<String, Object?>{
      'channel': 'dart-ui-icp-brasil',
      'direction': 'request',
      'id': id,
      'operation': operation,
      if (values is Map) ...values.cast<String, Object?>(),
    }.jsify());
  }).toJS);
}

int _sequence = 0;
