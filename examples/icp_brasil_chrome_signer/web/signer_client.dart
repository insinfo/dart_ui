import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('globalThis')
external JSObject get globalThis;

@JS('chrome')
external JSObject get chrome;

abstract interface class SignerClient {
  Future<Map<String, Object?>> call(
    String operation, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]);
}

final class PageSignerClient implements SignerClient {
  const PageSignerClient();

  @override
  Future<Map<String, Object?>> call(
    String operation, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    final api = globalThis.getProperty<JSObject?>('dartUiIcpBrasil'.toJS);
    if (api == null) {
      throw StateError('Extensão Dart UI ICP-Brasil não encontrada.');
    }
    final result = await api
        .callMethod<JSPromise<JSAny?>>(operation.toJS, arguments.jsify())
        .toDart;
    return _map(result?.dartify());
  }
}

final class NativeMessagingSignerClient implements SignerClient {
  const NativeMessagingSignerClient();

  @override
  Future<Map<String, Object?>> call(
    String operation, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) {
    final completer = Completer<Map<String, Object?>>();
    final runtime = chrome.getProperty<JSObject>('runtime'.toJS);
    runtime.callMethod<JSAny?>(
      'sendNativeMessage'.toJS,
      'br.com.dartui.icp_signer'.toJS,
      <String, Object?>{
        'id': 'ui-${DateTime.now().microsecondsSinceEpoch}',
        'operation': operation,
        'origin': 'https://extension.dartui.local',
        ...arguments,
      }.jsify(),
      ((JSAny? reply) {
        final response = _map(reply?.dartify());
        if (response['ok'] == true) {
          completer.complete(_map(response['result']));
          return;
        }
        final error = _map(response['error']);
        completer.completeError(
          StateError(error['message']?.toString() ?? 'Falha no assinador.'),
        );
      }).toJS,
    );
    return completer.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () => throw TimeoutException(
        'O assinador nativo não respondeu em 45 segundos.',
      ),
    );
  }
}

Map<String, Object?> _map(Object? value) => value is Map
    ? Map<String, Object?>.from(value.cast<String, Object?>())
    : <String, Object?>{};
