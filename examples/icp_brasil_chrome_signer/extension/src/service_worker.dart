import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('chrome')
external JSObject get chrome;

void main() {
  final runtime = chrome.getProperty<JSObject>('runtime'.toJS);
  runtime
      .getProperty<JSObject>('onMessage'.toJS)
      .callMethod<JSAny?>('addListener'.toJS, _onMessage.toJS);
}

JSAny? _onMessage(JSAny? raw, JSAny? senderRaw, JSFunction sendResponse) {
  final message = raw?.dartify();
  final sender = senderRaw as JSObject;
  if (message is! Map || message['channel'] != 'dart-ui-icp-brasil') {
    return null;
  }
  final url = sender
      .getProperty<JSObject?>('tab'.toJS)
      ?.getProperty<JSString?>('url'.toJS)
      ?.toDart;
  final origin = url == null
      ? 'https://extension.dartui.local'
      : Uri.tryParse(url)?.origin;
  if (origin == null) {
    sendResponse.callAsFunction(null, _error('INVALID_ORIGIN').jsify());
    return null;
  }
  final request = Map<String, Object?>.from(message.cast<String, Object?>());
  request['origin'] = origin;
  final runtime = chrome.getProperty<JSObject>('runtime'.toJS);
  runtime.callMethod<JSAny?>(
    'sendNativeMessage'.toJS,
    'br.com.dartui.icp_signer'.toJS,
    request.jsify(),
    ((JSAny? reply) {
      if (reply != null) {
        sendResponse.callAsFunction(null, reply);
        return;
      }
      final lastError = runtime.getProperty<JSObject?>('lastError'.toJS);
      final error = lastError?.getProperty<JSString?>('message'.toJS)?.toDart ??
          'native host returned no response';
      sendResponse.callAsFunction(null, _error(error).jsify());
    }).toJS,
  );
  return true.toJS;
}

Map<String, Object?> _error(String message) => <String, Object?>{
      'ok': false,
      'error': <String, Object?>{
        'code': 'NATIVE_HOST_ERROR',
        'message': message,
      },
    };
