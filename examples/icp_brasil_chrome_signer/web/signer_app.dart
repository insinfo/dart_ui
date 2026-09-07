import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:web/web.dart' as web;

import 'signer_client.dart';

final class BrowserSignerApp extends StatefulWidget {
  const BrowserSignerApp({
    super.key,
    required this.client,
    this.compact = false,
  });

  final SignerClient client;
  final bool compact;

  @override
  State<BrowserSignerApp> createState() => _BrowserSignerAppState();
}

final class _BrowserSignerAppState extends State<BrowserSignerApp> {
  List<Map<String, Object?>> _certificates = const <Map<String, Object?>>[];
  String? _selectedId;
  PickedFile? _pdf;
  final TextEditingController _hashController = TextEditingController();
  bool _busy = false;
  bool _connected = false;
  String _status = 'Conectando ao assinador instalado…';
  InfoBarSeverity _severity = InfoBarSeverity.info;

  @override
  void initState() {
    super.initState();
    _hashController.addListener(_onHashChanged);
    _checkStatus();
  }

  void _onHashChanged(String value) {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _hashController.removeListener(_onHashChanged);
    super.dispose();
  }

  Future<void> _checkStatus() async {
    try {
      await widget.client.call('status');
      if (!mounted) return;
      setState(() {
        _connected = true;
        _status = 'Assinador instalado e pronto.';
        _severity = InfoBarSeverity.success;
      });
    } on Object catch (error) {
      _report('Assinador não encontrado: $error', error: true);
    }
  }

  Future<void> _detectCertificates() async {
    if (_busy) return;
    _setBusy(true, 'Aguardando sua confirmação no Windows…');
    try {
      final result = await widget.client.call('listCertificates');
      final raw = result['certificates'];
      final certificates = raw is List
          ? raw
              .whereType<Map<Object?, Object?>>()
              .map((value) =>
                  Map<String, Object?>.from(value.cast<String, Object?>()))
              .toList(growable: false)
          : const <Map<String, Object?>>[];
      if (!mounted) return;
      setState(() {
        _certificates = certificates;
        _selectedId =
            certificates.isEmpty ? null : certificates.first['id']?.toString();
        _status = certificates.isEmpty
            ? 'Nenhum certificado ICP-Brasil foi encontrado.'
            : '${certificates.length} certificado(s) ICP-Brasil disponível(is).';
        _severity = certificates.isEmpty
            ? InfoBarSeverity.warning
            : InfoBarSeverity.success;
      });
    } on Object catch (error) {
      _report('Não foi possível consultar os certificados: $error',
          error: true);
    } finally {
      _finishBusy();
    }
  }

  Future<void> _choosePdf() async {
    final selected = await FilePicker.openFile(
      title: 'Selecione o PDF que será assinado',
      filters: const <FilePickerFilter>[
        FilePickerFilter(label: 'Documento PDF', extensions: <String>['pdf']),
      ],
    );
    if (!mounted || selected == null) return;
    setState(() {
      _pdf = selected;
      _status = '${selected.name} pronto para assinatura.';
      _severity = InfoBarSeverity.success;
    });
  }

  Future<void> _signPdf() async {
    final pdf = _pdf;
    final certificateId = _selectedId;
    if (pdf == null || certificateId == null || _busy) return;
    _setBusy(true, 'Confirme a assinatura e informe o PIN no Windows…');
    try {
      final result = await widget.client.call('signPdf', <String, Object?>{
        'certificateId': certificateId,
        'pdf': base64Encode(pdf.bytes),
        'reason': 'Assinatura digital',
        'location': 'Brasil',
      });
      final signed = result['pdf']?.toString();
      if (signed == null) {
        throw StateError('O host não retornou o PDF assinado.');
      }
      _download(signed, _signedName(pdf.name), 'application/pdf');
      _report('PDF assinado. O download foi iniciado.');
    } on Object catch (error) {
      _report('A assinatura falhou: $error', error: true);
    } finally {
      _finishBusy();
    }
  }

  Future<void> _signPdfHash() async {
    final certificateId = _selectedId;
    if (certificateId == null || _busy) return;
    final Uint8List digest;
    try {
      digest = base64Decode(_hashController.value.trim());
      if (digest.length != 32) {
        throw const FormatException(
            'O SHA-256 precisa ter exatamente 32 bytes.');
      }
    } on Object catch (error) {
      _report('Hash inválido: $error', error: true);
      return;
    }
    _setBusy(true, 'Solicitando assinatura destacada do hash SHA-256…');
    try {
      final result = await widget.client.call('signPdfHash', <String, Object?>{
        'certificateId': certificateId,
        'byteRangeDigest': base64Encode(digest),
        'reason': 'Assinatura remota de PDF',
      });
      final cms = result['cms']?.toString();
      if (cms == null) {
        throw StateError('O host não retornou a assinatura CMS.');
      }
      _download(cms, 'assinatura-pades.p7s', 'application/pkcs7-signature');
      _report('CMS destacado gerado. Incorpore-o ao /Contents reservado.');
    } on Object catch (error) {
      _report('A assinatura do hash falhou: $error', error: true);
    } finally {
      _finishBusy();
    }
  }

  Future<void> _authenticate() async {
    final certificateId = _selectedId;
    if (certificateId == null || _busy) return;
    final random = Random.secure();
    final challenge = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    _setBusy(true, 'Confirme a autenticação no Windows…');
    try {
      await widget.client.call('authenticate', <String, Object?>{
        'certificateId': certificateId,
        'challenge': base64Encode(challenge),
        'audience': web.window.location.origin,
      });
      _report('Desafio autenticado com o certificado selecionado.');
    } on Object catch (error) {
      _report('A autenticação falhou: $error', error: true);
    } finally {
      _finishBusy();
    }
  }

  void _download(String base64, String name, String mimeType) {
    final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
    anchor
      ..href = 'data:$mimeType;base64,$base64'
      ..download = name;
    web.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
  }

  String _signedName(String value) => value.toLowerCase().endsWith('.pdf')
      ? '${value.substring(0, value.length - 4)}-assinado.pdf'
      : '$value-assinado.pdf';

  void _setBusy(bool value, String status) {
    if (!mounted) return;
    setState(() {
      _busy = value;
      _status = status;
      _severity = InfoBarSeverity.info;
    });
  }

  void _finishBusy() {
    if (mounted) setState(() => _busy = false);
  }

  void _report(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _severity = error ? InfoBarSeverity.error : InfoBarSeverity.success;
    });
  }

  Map<String, Object?>? get _selectedCertificate {
    for (final certificate in _certificates) {
      if (certificate['id']?.toString() == _selectedId) return certificate;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => Theme(
        data: ThemeData.fluentLight,
        child: ColoredBox(
          color: const Color(0xFFF3F7FC),
          child: Padding(
            padding: EdgeInsets.all(widget.compact ? 14 : 26),
            child: widget.compact ? _compact() : _full(),
          ),
        ),
      );

  Widget _compact() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _brand(compact: true),
          const SizedBox(height: 12),
          InfoBar(title: 'Status', message: _status, severity: _severity),
          const SizedBox(height: 12),
          Button(
            label: _certificates.isEmpty
                ? 'Detectar certificado ICP-Brasil'
                : 'Atualizar certificados',
            onPressed: _connected && !_busy ? _detectCertificates : null,
            isDefault: true,
          ),
          const SizedBox(height: 12),
          if (_selectedCertificate case final certificate?)
            Expanded(child: _certificateCard(certificate))
          else
            const Expanded(
              child: Center(
                child: Text(
                  'A chave privada permanece no token.\n'
                  'Sites só recebem o resultado autorizado.',
                  softWrap: true,
                  style: TextStyle(fontSize: 12, color: Color(0xFF52647A)),
                ),
              ),
            ),
        ],
      );

  Widget _full() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _brand(),
          const SizedBox(height: 18),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(width: 390, child: _workflow()),
                const SizedBox(width: 18),
                Expanded(child: _documentPanel()),
              ],
            ),
          ),
        ],
      );

  Widget _brand({bool compact = false}) => ColoredBox(
        color: const Color(0xFF102A43),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 18,
            vertical: compact ? 10 : 14,
          ),
          child: Row(
            children: <Widget>[
              const Icon(PhosphorIcons.signature,
                  size: 25, color: Color(0xFF6EE7B7)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      compact
                          ? 'Dart UI Assinador'
                          : 'Dart UI Assinador ICP-Brasil',
                      style: const TextStyle(
                        color: Color(0xFFFFFFFF),
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Text(
                      'PAdES B-B · certificado A1 ou token A3',
                      style: TextStyle(fontSize: 10, color: Color(0xFFB8C9DB)),
                    ),
                  ],
                ),
              ),
              if (_busy) const CircularProgressIndicator(size: 20),
            ],
          ),
        ),
      );

  Widget _workflow() => Card(
        padding: 16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text('Preparar assinatura',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            InfoBar(title: 'Status', message: _status, severity: _severity),
            const SizedBox(height: 14),
            Button(
              label: '1. Detectar certificado ICP-Brasil',
              onPressed: _connected && !_busy ? _detectCertificates : null,
            ),
            const SizedBox(height: 10),
            if (_certificates.isNotEmpty)
              ComboBox<String>(
                label: 'Certificado',
                items: <ComboBoxItem<String>>[
                  for (final certificate in _certificates)
                    ComboBoxItem<String>(
                      value: certificate['id']!.toString(),
                      label: '${certificate['name']} · '
                          '${certificate['maskedCpf'] ?? ''}',
                    ),
                ],
                value: _selectedId,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _selectedId = value),
              ),
            const SizedBox(height: 10),
            Button(
              label: _pdf == null ? '2. Selecionar documento PDF' : _pdf!.name,
              onPressed: !_busy ? _choosePdf : null,
            ),
            const SizedBox(height: 10),
            Button(
              label: 'Autenticar desafio',
              onPressed: !_busy && _selectedId != null ? _authenticate : null,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _hashController,
              label: 'Hash SHA-256 do /ByteRange em base64 (32 bytes)',
            ),
            const Spacer(),
            Button(
              label: 'Assinar somente hash (CMS)',
              onPressed: !_busy &&
                      _hashController.value.trim().isNotEmpty &&
                      _selectedId != null
                  ? _signPdfHash
                  : null,
            ),
            const SizedBox(height: 8),
            Button(
              label: 'Assinar e baixar PDF',
              onPressed: !_busy && _pdf != null && _selectedId != null
                  ? _signPdf
                  : null,
              isDefault: true,
            ),
          ],
        ),
      );

  Widget _documentPanel() => Card(
        padding: 18,
        child: _pdf == null
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(PhosphorIcons.filePdf,
                        size: 68, color: Color(0xFF9CB0C7)),
                    SizedBox(height: 14),
                    Text('Seu PDF aparecerá aqui',
                        style: TextStyle(
                            fontSize: 19, fontWeight: FontWeight.w700)),
                    SizedBox(height: 6),
                    Text('Selecione um documento para iniciar.',
                        style: TextStyle(color: Color(0xFF60758D))),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(_pdf!.name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  Expanded(
                    child: PdfView(
                      document: PdfDocument.fromBytes(_pdf!.bytes),
                    ),
                  ),
                ],
              ),
      );

  Widget _certificateCard(Map<String, Object?> certificate) => Card(
        padding: 14,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('CERTIFICADO DISPONÍVEL',
                style: TextStyle(
                    fontSize: 10,
                    color: Color(0xFF078454),
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(certificate['name']?.toString() ?? '',
                softWrap: true,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            Text(certificate['maskedCpf']?.toString() ?? '',
                style: const TextStyle(color: Color(0xFF52647A))),
            const Spacer(),
            const Text('Chave protegida pelo Windows e pelo token',
                softWrap: true,
                style: TextStyle(fontSize: 11, color: Color(0xFF52647A))),
          ],
        ),
      );
}
