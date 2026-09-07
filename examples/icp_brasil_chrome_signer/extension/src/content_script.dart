import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

@JS('chrome')
external JSObject get chrome;

void main() {
  final marker = web.document.createElement('meta') as web.HTMLMetaElement;
  marker.name = 'dart-ui-icp-brasil';
  final runtimeId = chrome
      .getProperty<JSObject>('runtime'.toJS)
      .getProperty<JSString?>('id'.toJS);
  marker.content = runtimeId?.toDart ?? 'unknown';
  (web.document.head ?? web.document.documentElement)?.append(marker);
  web.window.addEventListener('message', _onWindowMessage.toJS);
}

void _onWindowMessage(web.Event rawEvent) {
  final event = rawEvent as web.MessageEvent;
  if (event.source != web.window) {
    return;
  }
  final data = event.data.dartify();
  if (data is! Map ||
      data['channel'] != 'dart-ui-icp-brasil' ||
      data['direction'] != 'request') {
    return;
  }
  final request = Map<String, Object?>.from(data.cast<String, Object?>());
  request.remove('origin');
  final runtime = chrome.getProperty<JSObject>('runtime'.toJS);
  runtime
      .callMethod<JSPromise<JSAny?>>('sendMessage'.toJS, request.jsify())
      .toDart
      .then(
        (reply) => web.window.postMessage(<String, Object?>{
          'channel': 'dart-ui-icp-brasil',
          'direction': 'response',
          'id': request['id'],
          'payload': reply?.dartify(),
        }.jsify()),
      );
}
