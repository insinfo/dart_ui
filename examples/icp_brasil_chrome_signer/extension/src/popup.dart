import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

@JS('chrome')
external JSObject get chrome;

void main() {
  final status = web.document.querySelector('#status')!;
  final details = web.document.querySelector('#details')!;
  final detect = web.document.querySelector('#detect') as web.HTMLButtonElement;
  final runtime = chrome.getProperty<JSObject>('runtime'.toJS);

  void send(String operation, void Function(Map<dynamic, dynamic>) receive) {
    runtime.callMethod<JSAny?>(
      'sendNativeMessage'.toJS,
      'br.com.dartui.icp_signer'.toJS,
      <String, Object?>{
        'channel': 'dart-ui-icp-brasil',
        'id': 'popup-$operation',
        'operation': operation,
        'origin': 'https://extension.dartui.local',
      }.jsify(),
      ((JSAny? reply) {
        final value = reply?.dartify();
        receive(value is Map ? value : <Object?, Object?>{});
      }).toJS,
    );
  }

  send('status', (value) {
    final connected = value['ok'] == true;
    status.textContent =
        connected ? 'Assinador conectado' : 'Host nativo não encontrado';
    status.className = connected ? 'status ready' : 'status error';
    detect.disabled = !connected;
  });

  detect.onClick.listen((_) {
    detect.disabled = true;
    status
      ..textContent = 'Confirme a consulta na janela do Windows…'
      ..className = 'status';
    send('listCertificates', (value) {
      final result = value['result'];
      final certificates = result is Map ? result['certificates'] : null;
      if (value['ok'] == true &&
          certificates is List &&
          certificates.isNotEmpty) {
        status
          ..textContent = '${certificates.length} certificado(s) encontrado(s)'
          ..className = 'status ready';
        details.textContent = certificates.map((certificate) {
          final item = certificate as Map;
          return '${item['name']}\n${item['maskedCpf'] ?? ''}\n'
              'Válido até ${item['notAfter']}';
        }).join('\n\n');
      } else {
        status
          ..textContent = certificates is List && certificates.isEmpty
              ? 'Nenhum certificado ICP-Brasil encontrado'
              : 'Não foi possível listar certificados'
          ..className = 'status error';
        details.textContent = value['error']?.toString() ?? '';
      }
      detect.disabled = false;
    });
  });
}
