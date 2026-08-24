import 'dart:io';
import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';

void main(List<String> arguments) {
  FrameworkFonts.install();
  runApp(
    PdfSignerDemoApp(arguments: arguments),
    options: ApplicationOptions.fromArguments(
      arguments,
      environment: Platform.environment,
      title: 'dart_ui PDF Signer',
    ),
  );
}

final class PdfSignerDemoApp extends StatefulWidget {
  const PdfSignerDemoApp({super.key, required this.arguments});

  final List<String> arguments;

  @override
  State<PdfSignerDemoApp> createState() => _PdfSignerDemoAppState();
}

enum _KeySource { system, pkcs11 }

final class _PdfSignerDemoAppState extends State<PdfSignerDemoApp> {
  final _moduleController = TextEditingController();
  final _pinController = TextEditingController();
  final _reasonController = TextEditingController('Assinatura digital');
  final _locationController = TextEditingController('Brasil');

  PickedFile? _input;
  PdfDocument? _document;
  Pkcs11Module? _module;
  List<Pkcs11Token> _tokens = const <Pkcs11Token>[];
  Pkcs11CertificateProvider? _pkcs11Provider;
  List<CryptoIdentity> _pkcs11Identities = const <CryptoIdentity>[];
  CertificateProvider? _systemProvider;
  List<CryptoIdentity> _systemIdentities = const <CryptoIdentity>[];
  late _KeySource _keySource;
  int? _selectedToken;
  int? _selectedCertificate;
  int? _selectedSystemCertificate;
  int _previewPage = 1;
  int _signaturePage = 1;
  double _previewZoom = 1;
  Rect _signatureRect = const Rect.fromLTWH(36, 36, 280, 76);
  bool _draggingSignature = false;
  late final ScrollPosition _previewScrollPosition;
  late final ScrollPosition _previewHorizontalPosition;
  bool _programmaticPreviewScroll = false;
  String _status = 'Selecione um PDF para começar.';
  InfoBarSeverity _severity = InfoBarSeverity.info;
  bool _busy = false;

  bool get _hasSystemProvider => Platform.isWindows || Platform.isMacOS;

  String get _systemName => Platform.isMacOS
      ? 'Keychain do macOS'
      : Platform.isWindows
          ? 'Certificados do Windows'
          : 'Certificados do sistema';

  String get _systemTechnology => Platform.isMacOS
      ? 'Security.framework e CryptoTokenKit'
      : 'CNG/KSP, minidriver e CryptoAPI/CSP';

  @override
  void initState() {
    super.initState();
    _previewScrollPosition = ScrollPosition(axis: ScrollAxis.vertical)
      ..addListener(_onPreviewScrolled);
    _previewHorizontalPosition = ScrollPosition(axis: ScrollAxis.horizontal);
    _keySource = _hasSystemProvider ? _KeySource.system : _KeySource.pkcs11;
    final moduleArgument = _argumentValue('--module');
    final discovered = Pkcs11Module.discoverCommonModules();
    _moduleController.value =
        moduleArgument ?? (discovered.isEmpty ? '' : discovered.first);
    final inputArgument = _inputArgument();
    if (inputArgument != null) _loadInitialPdf(inputArgument);
  }

  String? _argumentValue(String name) {
    for (var i = 0; i < widget.arguments.length; i++) {
      final value = widget.arguments[i];
      if (value.startsWith('$name=')) return value.substring(name.length + 1);
      if (value == name && i + 1 < widget.arguments.length) {
        return widget.arguments[i + 1];
      }
    }
    return null;
  }

  String? _inputArgument() {
    const optionsWithSeparateValue = <String>{
      '--backend',
      '--presentation',
      '--scale',
      '--frames',
      '--module',
    };
    for (var index = 0; index < widget.arguments.length; index++) {
      final value = widget.arguments[index];
      if (value.startsWith('--')) {
        if (!value.contains('=') && optionsWithSeparateValue.contains(value)) {
          index++;
        }
        continue;
      }
      return value;
    }
    return null;
  }

  Future<void> _loadInitialPdf(String path) async {
    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      _openDocument(
        PickedFile(
          name: file.uri.pathSegments.last,
          path: file.path,
          bytes: bytes,
        ),
      );
    } on Object catch (error) {
      _report('Não foi possível abrir o PDF inicial: $error', error: true);
    }
  }

  @override
  void dispose() {
    _previewScrollPosition.removeListener(_onPreviewScrolled);
    _pkcs11Provider?.close();
    _systemProvider?.close();
    _module?.close();
    super.dispose();
  }

  void _openDocument(PickedFile selected) {
    final document = PdfDocument.fromBytes(selected.bytes);
    final page = document.getPage(1);
    final width = math.min(280.0, math.max(160.0, page.width - 48));
    const height = 76.0;
    setState(() {
      _input = selected;
      _document = document;
      _previewPage = 1;
      _signaturePage = 1;
      _previewZoom = 1;
      _signatureRect = Rect.fromLTWH(
        math.max(24, page.width - width - 32),
        math.max(24, page.height - height - 32),
        width,
        height,
      );
      _status = 'Documento aberto: ${document.pageCount} página(s).';
      _severity = InfoBarSeverity.success;
    });
    _previewScrollPosition.jumpTo(0);
    _previewHorizontalPosition.jumpTo(0);
  }

  Future<void> _choosePdf() async {
    final selected = await FilePicker.openFile(
      title: 'Documento PDF a assinar',
      filters: const <FilePickerFilter>[
        FilePickerFilter(label: 'PDF (*.pdf)', extensions: <String>['pdf']),
      ],
    );
    if (!mounted || selected == null) return;
    try {
      _openDocument(selected);
    } on Object catch (error) {
      _report('O arquivo selecionado não é um PDF suportado: $error',
          error: true);
    }
  }

  Future<void> _chooseModule() async {
    final selected = await FilePicker.openFile(
      title: 'Biblioteca PKCS#11 do token',
      filters: const <FilePickerFilter>[
        FilePickerFilter(
          label: 'Módulo PKCS#11',
          extensions: <String>['dll', 'so', 'dylib'],
        ),
      ],
    );
    if (!mounted || selected == null || selected.path == null) return;
    _moduleController.value = selected.path!;
  }

  Future<void> _loadModule() async {
    if (_busy || _moduleController.value.trim().isEmpty) return;
    _setBusy(true);
    try {
      _pkcs11Provider?.close();
      _module?.close();
      final module = Pkcs11Module(_moduleController.value.trim());
      final tokens = module.listTokens();
      if (!mounted) {
        module.close();
        return;
      }
      setState(() {
        _module = module;
        _tokens = tokens;
        _pkcs11Provider = null;
        _pkcs11Identities = const <CryptoIdentity>[];
        _selectedToken = tokens.isEmpty ? null : 0;
        _selectedCertificate = null;
        _status = tokens.isEmpty
            ? 'Módulo carregado, mas nenhum token está conectado.'
            : '${tokens.length} token(s) encontrado(s).';
        _severity =
            tokens.isEmpty ? InfoBarSeverity.warning : InfoBarSeverity.success;
      });
    } on Object catch (error) {
      _report('Falha ao carregar o módulo PKCS#11: $error', error: true);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _loadPkcs11Certificates() async {
    final module = _module;
    final tokenIndex = _selectedToken;
    if (_busy || module == null || tokenIndex == null) return;
    if (_pinController.value.isEmpty) {
      _report('Informe o PIN do token.', warning: true);
      return;
    }
    _setBusy(true);
    try {
      _pkcs11Provider?.close();
      final provider = Pkcs11CertificateProvider.forToken(
        module: module,
        token: _tokens[tokenIndex],
      );
      final identities = await provider.listIdentities(
        context: CertificateOperationContext(pin: _pinController.value),
      );
      if (!mounted) {
        provider.close();
        return;
      }
      setState(() {
        _pkcs11Provider = provider;
        _pkcs11Identities = identities;
        _selectedCertificate = identities.isEmpty ? null : 0;
        _status = identities.isEmpty
            ? 'Nenhum certificado X.509 foi encontrado no token.'
            : '${identities.length} certificado(s) encontrado(s) no token.';
        _severity = identities.isEmpty
            ? InfoBarSeverity.warning
            : InfoBarSeverity.success;
      });
    } on Object catch (error) {
      _report('Não foi possível ler os certificados: $error', error: true);
    } finally {
      _setBusy(false);
    }
  }

  CertificateProvider _createSystemProvider() {
    if (Platform.isWindows) return WindowsCertificateProvider();
    if (Platform.isMacOS) return MacOsCertificateProvider();
    throw UnsupportedError(
        'Não há store de certificados nativo nesta plataforma');
  }

  Future<void> _loadSystemCertificates() async {
    if (_busy || !_hasSystemProvider) return;
    _setBusy(true);
    try {
      final provider = _systemProvider ??= _createSystemProvider();
      final identities = await provider.listIdentities();
      if (!mounted) return;
      setState(() {
        _systemIdentities = identities;
        _selectedSystemCertificate = identities.isEmpty ? null : 0;
        _status = identities.isEmpty
            ? 'Nenhum certificado com chave privada foi encontrado em '
                '$_systemName. Conecte o token e tente novamente.'
            : '${identities.length} certificado(s) com chave privada em '
                '$_systemName.';
        _severity = identities.isEmpty
            ? InfoBarSeverity.warning
            : InfoBarSeverity.success;
      });
    } on Object catch (error) {
      _report('Não foi possível ler $_systemName: $error', error: true);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _signPdf() async {
    final input = _input;
    final document = _document;
    if (_busy || input == null || document == null) {
      _report('Selecione o PDF antes de assinar.', warning: true);
      return;
    }
    final CertificateProvider provider;
    final CryptoIdentity identity;
    final CertificateOperationContext operationContext;
    if (_keySource == _KeySource.system) {
      final index = _selectedSystemCertificate;
      final selectedProvider = _systemProvider;
      if (selectedProvider == null || index == null) {
        _report('Leia e selecione um certificado do sistema.', warning: true);
        return;
      }
      provider = selectedProvider;
      identity = _systemIdentities[index];
      final window = DragDropScope.windowOf(context);
      operationContext = CertificateOperationContext(
        nativeWindowHandle: switch (window) {
          final NativeHandleWindow nativeWindow => nativeWindow.nativeHandle,
          _ => 0,
        },
      );
    } else {
      final selectedProvider = _pkcs11Provider;
      final index = _selectedCertificate;
      if (selectedProvider == null || index == null) {
        _report('Selecione módulo, token e certificado antes de assinar.',
            warning: true);
        return;
      }
      provider = selectedProvider;
      identity = _pkcs11Identities[index];
      operationContext = CertificateOperationContext(pin: _pinController.value);
    }
    _setBusy(true);
    try {
      final certificate = identity.certificate;
      final signer = PdfSigner(
        document: document,
        signerName: certificate.commonName,
        reason: _reasonController.value.trim(),
        location: _locationController.value.trim(),
      )..setVisualAppearance(
          PdfSignatureAppearance(
            pageNumber: _signaturePage,
            rect: _signatureRect,
            signerName: certificate.commonName,
            reason: _reasonController.value.trim(),
            location: _locationController.value.trim(),
          ),
        );
      final bytes = await signer.sign(
        externalSigner: PdfCertificateProviderSigner(
          provider: provider,
          identity: identity,
          context: operationContext,
        ),
      );
      final outputPath = _outputPath(input);
      await File(outputPath).writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      setState(() {
        _pinController.value = '';
        _status = 'PDF assinado com sucesso: $outputPath';
        _severity = InfoBarSeverity.success;
      });
    } on Object catch (error) {
      _report('A assinatura falhou: $error', error: true);
    } finally {
      _setBusy(false);
    }
  }

  String _outputPath(PickedFile input) {
    final source = input.path == null
        ? File(
            '${Directory.current.path}${Platform.pathSeparator}${input.name}')
        : File(input.path!);
    final name = source.uri.pathSegments.last;
    final dot =
        name.toLowerCase().endsWith('.pdf') ? name.length - 4 : name.length;
    return '${source.parent.path}${Platform.pathSeparator}'
        '${name.substring(0, dot)}_assinado.pdf';
  }

  void _setBusy(bool value) {
    if (mounted) setState(() => _busy = value);
  }

  void _report(String message, {bool error = false, bool warning = false}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _severity = error
          ? InfoBarSeverity.error
          : (warning ? InfoBarSeverity.warning : InfoBarSeverity.info);
    });
  }

  void _showPage(int pageNumber) {
    final document = _document;
    if (document == null) return;
    final next = pageNumber.clamp(1, document.pageCount);
    if (next != _previewPage) setState(() => _previewPage = next);
    _programmaticPreviewScroll = true;
    _previewScrollPosition.jumpTo(_previewOffsetForPage(next));
    _programmaticPreviewScroll = false;
  }

  void _onPreviewScrolled(ScrollPosition position) {
    if (_programmaticPreviewScroll || !mounted) return;
    final document = _document;
    if (document == null || document.pageCount == 0) return;
    final probe = position.pixels + position.viewportExtent * 0.22;
    var cursor = 0.0;
    var pageNumber = document.pageCount;
    for (var index = 1; index <= document.pageCount; index++) {
      final extent = _previewExtentFor(document.getPage(index));
      if (probe < cursor + extent) {
        pageNumber = index;
        break;
      }
      cursor += extent;
    }
    if (pageNumber != _previewPage) {
      setState(() => _previewPage = pageNumber);
    }
  }

  double _pageScale(PdfPage page) =>
      math.min(0.78, 620 / page.height) * _previewZoom;

  double _previewExtentFor(PdfPage page) => page.height * _pageScale(page) + 28;

  double _previewCanvasWidth() {
    final document = _document;
    if (document == null) return 0;
    var widest = 0.0;
    for (var pageNumber = 1; pageNumber <= document.pageCount; pageNumber++) {
      final page = document.getPage(pageNumber);
      widest = math.max(widest, page.width * _pageScale(page));
    }
    return widest + 48;
  }

  double _previewOffsetForPage(int pageNumber) {
    final document = _document;
    if (document == null) return 0;
    var offset = 0.0;
    for (var index = 1; index < pageNumber; index++) {
      offset += _previewExtentFor(document.getPage(index));
    }
    return offset;
  }

  void _changeZoom(double delta) {
    final next = (_previewZoom + delta).clamp(0.5, 1.5);
    if (next == _previewZoom) return;
    final oldZoom = _previewZoom;
    final oldOffset = _previewScrollPosition.pixels;
    final oldHorizontalOffset = _previewHorizontalPosition.pixels;
    setState(() => _previewZoom = next);
    _programmaticPreviewScroll = true;
    _previewScrollPosition.jumpTo(oldOffset * next / oldZoom);
    _previewHorizontalPosition.jumpTo(
      oldHorizontalOffset * next / oldZoom,
    );
    _programmaticPreviewScroll = false;
  }

  void _resetZoom() {
    if (_previewZoom == 1) return;
    final page = _previewPage;
    setState(() => _previewZoom = 1);
    _programmaticPreviewScroll = true;
    _previewScrollPosition.jumpTo(_previewOffsetForPage(page));
    _previewHorizontalPosition.jumpTo(0);
    _programmaticPreviewScroll = false;
  }

  Rect _clampSignatureRect(Rect rect, PdfPage page) {
    final width = math.min(rect.width, page.width);
    final height = math.min(rect.height, page.height);
    return Rect.fromLTWH(
      rect.left.clamp(0.0, math.max(0.0, page.width - width)),
      rect.top.clamp(0.0, math.max(0.0, page.height - height)),
      width,
      height,
    );
  }

  void _moveSignature(
    int pageNumber,
    Offset previewPosition,
    double scale,
    PdfPage page,
  ) {
    final next = Rect.fromLTWH(
      previewPosition.dx / scale,
      previewPosition.dy / scale,
      _signatureRect.width,
      _signatureRect.height,
    );
    _signaturePage = pageNumber;
    _signatureRect = _clampSignatureRect(next, page);
  }

  void _placeSignature(int pageNumber, Offset pagePosition, PdfPage page) {
    final next = Rect.fromLTWH(
      pagePosition.dx - _signatureRect.width / 2,
      pagePosition.dy - _signatureRect.height / 2,
      _signatureRect.width,
      _signatureRect.height,
    );
    setState(() {
      _previewPage = pageNumber;
      _signaturePage = pageNumber;
      _signatureRect = _clampSignatureRect(next, page);
    });
  }

  @override
  Widget build(BuildContext context) {
    const theme = ThemeData.materialLight;
    return Theme(
      data: theme,
      child: ColoredBox(
        color: const Color(0xFFF4F7FB),
        child: Column(
          children: <Widget>[
            _appHeader(theme),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(width: 440, child: _controlPanel(theme)),
                  Expanded(child: _previewPanel(theme)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _appHeader(ThemeData theme) => ColoredBox(
        color: const Color(0xFF0F2440),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: <Widget>[
              const ColoredBox(
                color: Color(0xFF2F6FED),
                child: Padding(
                  padding: EdgeInsets.all(9),
                  child: Icon(
                    PhosphorIcons.signature,
                    size: 22,
                    color: Color(0xFFFFFFFF),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'dart_ui Sign',
                    style: TextStyle(
                      color: Color(0xFFFFFFFF),
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'Assinatura digital PAdES B-B',
                    style: TextStyle(
                      color: Color(0xFFB9C8DC),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              const Icon(
                PhosphorIcons.shieldCheck,
                color: Color(0xFF69D7A0),
                size: 18,
              ),
              const SizedBox(width: 7),
              const Text(
                'A chave privada nunca sai do token',
                style: TextStyle(color: Color(0xFFD8E3F0), fontSize: 12),
              ),
              if (_busy) ...<Widget>[
                const SizedBox(width: 18),
                const CircularProgressIndicator(
                  size: 20,
                  semanticsLabel: 'Processando',
                ),
              ],
            ],
          ),
        ),
      );

  Widget _controlPanel(ThemeData theme) => ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Text(
                        'Preparar assinatura',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF172033),
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Escolha o documento, o certificado e posicione a '
                        'aparência visual.',
                        softWrap: true,
                        maxLines: 2,
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748B),
                        ),
                      ),
                      const SizedBox(height: 14),
                      InfoBar(
                        title: _busy ? 'Processando' : 'Status',
                        message: _status,
                        severity: _severity,
                      ),
                      const SizedBox(height: 12),
                      _documentStep(theme),
                      const SizedBox(height: 10),
                      _sourceStep(theme),
                      const SizedBox(height: 10),
                      _certificateStep(theme),
                      const SizedBox(height: 10),
                      _appearanceStep(theme),
                    ],
                  ),
                ),
              ),
            ),
            ColoredBox(
              color: const Color(0xFFF8FAFC),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Row(
                      children: <Widget>[
                        Icon(PhosphorIcons.lock, size: 15),
                        SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            'O PIN é efêmero e não é gravado pelo aplicativo.',
                            softWrap: true,
                            maxLines: 2,
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Button(
                      label: _busy ? 'Assinando documento...' : 'Assinar PDF',
                      isDefault: true,
                      onPressed: _busy ? null : _signPdf,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  Widget _stepTitle(int number, IconData icon, String title) => Row(
        children: <Widget>[
          ColoredBox(
            color: const Color(0xFFE8F0FF),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(icon, size: 17, color: const Color(0xFF2F6FED)),
            ),
          ),
          const SizedBox(width: 9),
          Text(
            '$number. $title',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Color(0xFF24324A),
            ),
          ),
        ],
      );

  Widget _documentStep(ThemeData theme) => Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _stepTitle(1, PhosphorIcons.filePdf, 'Documento'),
            const SizedBox(height: 9),
            ColoredBox(
              color: const Color(0xFFF8FAFC),
              child: Padding(
                padding: const EdgeInsets.all(9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _input == null
                          ? 'Nenhum arquivo selecionado'
                          : _input!.name,
                      softWrap: true,
                      maxLines: 2,
                      ellipsis: '…',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _input == null
                            ? const Color(0xFF64748B)
                            : const Color(0xFF172033),
                      ),
                    ),
                    if (_document != null) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        '${_document!.pageCount} páginas • '
                        '${(_input!.size / (1024 * 1024)).toStringAsFixed(2)} MB',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Button(
              label: _input == null ? 'Selecionar PDF' : 'Trocar documento',
              onPressed: _busy ? null : _choosePdf,
            ),
          ],
        ),
      );

  Widget _sourceStep(ThemeData theme) => Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _stepTitle(2, PhosphorIcons.key, 'Origem do certificado'),
            const SizedBox(height: 9),
            Row(
              children: <Widget>[
                Expanded(
                  child: Button(
                    label: Platform.isMacOS ? 'Keychain' : 'Sistema',
                    isDefault: _keySource == _KeySource.system,
                    onPressed: _busy || !_hasSystemProvider
                        ? null
                        : () => setState(() => _keySource = _KeySource.system),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Button(
                    label: 'PKCS#11',
                    isDefault: _keySource == _KeySource.pkcs11,
                    onPressed: _busy
                        ? null
                        : () => setState(() => _keySource = _KeySource.pkcs11),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              _keySource == _KeySource.system
                  ? '$_systemTechnology. A autenticação segura é exibida '
                      'pelo sistema.'
                  : 'Compatível com módulos .dll, .so e .dylib de SafeSign, '
                      'OpenSC e outros fabricantes.',
              softWrap: true,
              maxLines: 3,
              style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
            ),
          ],
        ),
      );

  Widget _certificateStep(ThemeData theme) => _keySource == _KeySource.system
      ? _systemCertificateStep(theme)
      : _pkcs11CertificateStep(theme);

  Widget _systemCertificateStep(ThemeData theme) => Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _stepTitle(3, PhosphorIcons.certificate, 'Certificado'),
            const SizedBox(height: 9),
            Button(
              label: 'Ler $_systemName',
              onPressed: _busy ? null : _loadSystemCertificates,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 112,
              child: ListBox(
                itemCount: _systemIdentities.length,
                selectedIndex: _selectedSystemCertificate,
                onSelected: (index) =>
                    setState(() => _selectedSystemCertificate = index),
                itemExtent: 48,
                itemBuilder: (context, index) => _identityTile(
                  _systemIdentities[index],
                ),
              ),
            ),
          ],
        ),
      );

  Widget _pkcs11CertificateStep(ThemeData theme) => Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _stepTitle(3, PhosphorIcons.certificate, 'Token e certificado'),
            const SizedBox(height: 9),
            TextField(
              controller: _moduleController,
              label: 'Módulo PKCS#11 (.dll/.so/.dylib)',
            ),
            const SizedBox(height: 7),
            Row(
              children: <Widget>[
                Expanded(
                  child: Button(
                    label: 'Procurar',
                    onPressed: _busy ? null : _chooseModule,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Button(
                    label: 'Carregar módulo',
                    onPressed: _busy ? null : _loadModule,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            SizedBox(
              height: 66,
              child: ListBox(
                itemCount: _tokens.length,
                selectedIndex: _selectedToken,
                onSelected: (index) => setState(() {
                  _selectedToken = index;
                  _pkcs11Provider?.close();
                  _pkcs11Provider = null;
                  _pkcs11Identities = const <CryptoIdentity>[];
                  _selectedCertificate = null;
                }),
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '${_tokens[index].label} • ${_tokens[index].serialNumber}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 7),
            Row(
              children: <Widget>[
                Expanded(
                  child: PasswordField(
                    controller: _pinController,
                    label: 'PIN do token',
                  ),
                ),
                const SizedBox(width: 7),
                Button(
                  label: 'Ler certificados',
                  onPressed: _busy ? null : _loadPkcs11Certificates,
                ),
              ],
            ),
            const SizedBox(height: 7),
            SizedBox(
              height: 92,
              child: ListBox(
                itemCount: _pkcs11Identities.length,
                selectedIndex: _selectedCertificate,
                onSelected: (index) =>
                    setState(() => _selectedCertificate = index),
                itemExtent: 46,
                itemBuilder: (context, index) =>
                    _identityTile(_pkcs11Identities[index]),
              ),
            ),
          ],
        ),
      );

  Widget _identityTile(CryptoIdentity identity) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              identity.certificate.commonName,
              softWrap: true,
              maxLines: 1,
              ellipsis: '…',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              'Válido até ${_date(identity.certificate.notAfter)}',
              style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
            ),
          ],
        ),
      );

  Widget _appearanceStep(ThemeData theme) => Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _stepTitle(4, PhosphorIcons.stamp, 'Aparência visual'),
            const SizedBox(height: 8),
            const Text(
              'Clique na página ou arraste o bloco azul. A posição mostrada '
              'será gravada no PDF.',
              softWrap: true,
              maxLines: 3,
              style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 8),
            TextField(controller: _reasonController, label: 'Motivo'),
            const SizedBox(height: 7),
            TextField(controller: _locationController, label: 'Localização'),
            const SizedBox(height: 8),
            Text(
              'Página $_signaturePage • x ${_signatureRect.left.round()} • '
              'y ${_signatureRect.top.round()} • '
              '${_signatureRect.width.round()} × '
              '${_signatureRect.height.round()} pt',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF2F6FED),
              ),
            ),
          ],
        ),
      );

  Widget _previewPanel(ThemeData theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ColoredBox(
            color: const Color(0xFFFFFFFF),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(PhosphorIcons.filePdf, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _input == null
                              ? 'Pré-visualização do documento'
                              : _input!.name,
                          softWrap: true,
                          maxLines: 2,
                          ellipsis: '…',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_document != null) ...<Widget>[
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 40,
                      child: SingleChildScrollView(
                        axis: ScrollAxis.horizontal,
                        scrollbar: ScrollbarVisibility.never,
                        child: _previewToolbar(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Expanded(
            child: _document == null
                ? _emptyPreview()
                : TwoDimensionalScrollbar(
                    horizontalPosition: _previewHorizontalPosition,
                    verticalPosition: _previewScrollPosition,
                    child: SingleChildScrollView(
                      axis: ScrollAxis.horizontal,
                      controller: _previewHorizontalPosition,
                      contentAlignment: ScrollContentAlignment.center,
                      scrollbar: ScrollbarVisibility.never,
                      child: SizedBox(
                        width: _previewCanvasWidth(),
                        child: ListView.builder(
                          controller: _previewScrollPosition,
                          scrollbar: ScrollbarVisibility.never,
                          itemCount: _document!.pageCount,
                          estimatedItemExtent:
                              _previewExtentFor(_document!.getPage(1)),
                          cacheExtent: _previewExtentFor(_document!.getPage(1)),
                          itemBuilder: (context, index) => Padding(
                            padding: const EdgeInsets.only(top: 14, bottom: 14),
                            child: Center(child: _pagePreview(index + 1)),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          ColoredBox(
            color: const Color(0xFFEAF0F8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Row(
                children: <Widget>[
                  Icon(
                    _draggingSignature
                        ? PhosphorIcons.handGrabbing
                        : PhosphorIcons.cursorClick,
                    size: 16,
                    color: const Color(0xFF2F6FED),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      _draggingSignature
                          ? 'Solte para confirmar a posição'
                          : 'Clique na página para posicionar ou arraste o bloco azul',
                      softWrap: true,
                      maxLines: 2,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );

  Widget _previewToolbar() => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          const Text(
            'Zoom',
            style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(PhosphorIcons.magnifyingGlassMinus),
            tooltip: 'Diminuir zoom',
            onPressed: _previewZoom > 0.5 ? () => _changeZoom(-0.25) : null,
          ),
          SizedBox(
            width: 52,
            child: Center(
              child: Text(
                '${(_previewZoom * 100).round()}%',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(PhosphorIcons.magnifyingGlassPlus),
            tooltip: 'Aumentar zoom',
            onPressed: _previewZoom < 1.5 ? () => _changeZoom(0.25) : null,
          ),
          IconButton(
            icon: const Icon(PhosphorIcons.arrowsOut),
            tooltip: 'Ajustar à página',
            onPressed: _previewZoom == 1 ? null : _resetZoom,
          ),
          const SizedBox(width: 14),
          const Text(
            'Página',
            style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(PhosphorIcons.caretLeft),
            tooltip: 'Página anterior',
            onPressed:
                _previewPage > 1 ? () => _showPage(_previewPage - 1) : null,
          ),
          SizedBox(
            width: 72,
            child: Center(
              child: Text(
                '$_previewPage / ${_document!.pageCount}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(PhosphorIcons.caretRight),
            tooltip: 'Próxima página',
            onPressed: _previewPage < _document!.pageCount
                ? () => _showPage(_previewPage + 1)
                : null,
          ),
        ],
      );

  Widget _emptyPreview() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              PhosphorIcons.filePdf,
              size: 58,
              color: Color(0xFF9EB0C7),
            ),
            const SizedBox(height: 14),
            const Text(
              'Seu documento aparecerá aqui',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Color(0xFF334155),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Selecione um PDF para posicionar a assinatura visual.',
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 14),
            Button(label: 'Selecionar PDF', onPressed: _choosePdf),
          ],
        ),
      );

  Widget _pagePreview(int pageNumber) {
    final document = _document!;
    final page = document.getPage(pageNumber);
    final scale = _pageScale(page);
    final pageSize = Size(page.width * scale, page.height * scale);
    final signatureSize = Size(
      _signatureRect.width * scale,
      _signatureRect.height * scale,
    );
    final signaturePosition = Offset(
      _signatureRect.left * scale,
      _signatureRect.top * scale,
    );
    return ColoredBox(
      color: const Color(0xFFD5DEE9),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: SizedBox(
          width: pageSize.width,
          height: pageSize.height,
          child: Stack(
            children: <Widget>[
              PdfPageView(
                page: page,
                scale: scale,
                onTap: (pagePosition) =>
                    _placeSignature(pageNumber, pagePosition, page),
              ),
              if (pageNumber == _signaturePage)
                BoundedDraggable(
                  key: ValueKey<String>('signature-$pageNumber'),
                  position: signaturePosition,
                  size: signatureSize,
                  bounds: pageSize,
                  enabled: !_busy,
                  onDragStateChanged: (dragging) {
                    if (mounted) {
                      setState(() => _draggingSignature = dragging);
                    }
                  },
                  onPositionChanged: (position) =>
                      _moveSignature(pageNumber, position, scale, page),
                  child: _signatureBlock(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _signatureBlock() {
    final identity = _selectedIdentity;
    return ColoredBox(
      color: _draggingSignature
          ? const Color(0xFF174FB6)
          : const Color(0xFF2F6FED),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: ColoredBox(
          color: const Color(0xFFF7FAFF),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: <Widget>[
                const Icon(
                  PhosphorIcons.signature,
                  size: 24,
                  color: Color(0xFF2F6FED),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'ASSINADO DIGITALMENTE',
                        style: TextStyle(
                          color: Color(0xFF2F6FED),
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        identity?.certificate.commonName ??
                            'Selecione um certificado',
                        softWrap: true,
                        maxLines: 1,
                        ellipsis: '…',
                        style: const TextStyle(
                          color: Color(0xFF172033),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        _reasonController.value.trim().isEmpty
                            ? 'Assinatura digital'
                            : _reasonController.value.trim(),
                        softWrap: true,
                        maxLines: 1,
                        ellipsis: '…',
                        style: const TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 8,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  PhosphorIcons.handGrabbing,
                  size: 15,
                  color: Color(0xFF8293AA),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  CryptoIdentity? get _selectedIdentity {
    if (_keySource == _KeySource.system) {
      final index = _selectedSystemCertificate;
      return index == null ? null : _systemIdentities[index];
    }
    final index = _selectedCertificate;
    return index == null ? null : _pkcs11Identities[index];
  }

  String _date(DateTime value) {
    final local = value.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/${local.year}';
  }
}
