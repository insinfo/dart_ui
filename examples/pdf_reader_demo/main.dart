import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';

PdfDocument _parsePdfBytes(Uint8List bytes) => PdfDocument.fromBytes(bytes);

Future<PdfDocument> _loadPdfPath(String path) async =>
    PdfDocument.fromBytes(await File(path).readAsBytes());

void main(List<String> arguments) {
  FrameworkFonts.install();
  // PDFs resolve non-embedded fonts (Arial and friends) by family name, which
  // needs the machine's font index. Building it lazily would block the first
  // painted page for the whole scan; warming it here runs the scan in a
  // background isolate while the user picks a file or the document parses.
  FontRegistry.warmSystemFonts();
  final ApplicationOptions options = ApplicationOptions.fromArguments(
    arguments,
    environment: Platform.environment,
    title: 'dart_ui PDF Reader',
  );
  runApp(
    PdfReaderDemoApp(initialPath: _initialPdfPath(arguments)),
    options: options,
  );
}

String? _initialPdfPath(List<String> arguments) {
  const Set<String> optionsWithValue = <String>{
    '--backend',
    '--presentation',
    '--scale',
    '--frames',
  };
  for (var index = 0; index < arguments.length; index++) {
    final String argument = arguments[index];
    if (optionsWithValue.contains(argument)) {
      index++;
      continue;
    }
    if (!argument.startsWith('--')) return argument;
  }
  return null;
}

class PdfReaderDemoApp extends StatefulWidget {
  const PdfReaderDemoApp({super.key, this.initialPath});

  final String? initialPath;

  @override
  State<PdfReaderDemoApp> createState() => _PdfReaderDemoAppState();
}

class _PdfReaderDemoAppState extends State<PdfReaderDemoApp> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'PDF search');
  final PdfViewController _pdfController = PdfViewController(
    minimumZoom: 0.25,
    maximumZoom: 4,
  );
  PdfDocument? _document;
  String? _fileName;
  String? _error;
  String? _status;
  bool _isLoading = false;
  bool _darkMode = false;

  @override
  void initState() {
    super.initState();
    _pdfController.addListener(_onReaderChanged);
    final String? initialPath = widget.initialPath;
    if (initialPath != null) {
      _isLoading = true;
      _openInitialPath(initialPath);
    }
  }

  @override
  void dispose() {
    _pdfController.removeListener(_onReaderChanged);
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onReaderChanged(PdfViewState state) {
    if (mounted) setState(() {});
  }

  Future<void> _openInitialPath(String path) async {
    try {
      final PdfDocument document = await compute<String, PdfDocument>(
        _loadPdfPath,
        path,
        debugLabel: 'dart_ui.pdf.load',
      );
      if (!mounted) return;
      _showDocument(
        document,
        File(path).uri.pathSegments.last,
      );
    } on Object catch (error) {
      _showLoadError(error);
    }
  }

  void _showDocument(PdfDocument document, String fileName) {
    if (!mounted) return;
    setState(() {
      _document = document;
      _fileName = fileName;
      _isLoading = false;
      _status = 'Documento aberto. Arraste sobre o texto para selecioná-lo.';
    });
    _pdfController.attachDocument(document);
  }

  void _showLoadError(Object error) {
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _error = 'Não foi possível abrir o PDF: $error';
    });
  }

  Future<void> _openPdf() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final PickedFile? selected = await FilePicker.openFile(
        title: 'Abrir documento PDF',
        filters: const <FilePickerFilter>[
          FilePickerFilter(
            label: 'Documentos PDF (*.pdf)',
            extensions: <String>['pdf'],
          ),
          FilePickerFilter(
            label: 'Todos os arquivos (*.*)',
            extensions: <String>['*'],
          ),
        ],
      );
      if (!mounted || selected == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      final PdfDocument document = await compute<Uint8List, PdfDocument>(
        _parsePdfBytes,
        selected.bytes,
        debugLabel: 'dart_ui.pdf.parse',
      );
      if (!mounted) return;
      _showDocument(document, selected.name);
    } on Object catch (error) {
      _showLoadError(error);
    }
  }

  void _onSearch() {
    if (_document == null || _searchController.value.trim().isEmpty) return;
    final PdfSearchMatch? match =
        _pdfController.findNext(_searchController.value);
    setState(() {
      _status = match == null
          ? 'Nenhuma ocorrência encontrada.'
          : 'Encontrado na página ${match.pageNumber}: ${match.excerpt}';
    });
  }

  Future<void> _copySelection() async {
    if (!_pdfController.hasSelection) return;
    try {
      await ClipboardScope.of(context).writeText(_pdfController.selectedText);
      if (mounted) {
        setState(() {
          _status =
              '${_pdfController.selectedText.length} caractere(s) copiado(s).';
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _status = 'Falha ao copiar: $error');
    }
  }

  void _fitWidth() {
    final PdfDocument? document = _document;
    if (document == null) return;
    final page = document.getPage(_pdfController.currentPage);
    _pdfController.fitWidth(
      pageWidth: page.width,
      viewportWidth: MediaQuery.widthOf(context),
      padding: 48,
    );
  }

  void _fitPage() {
    final PdfDocument? document = _document;
    if (document == null) return;
    final page = document.getPage(_pdfController.currentPage);
    final Size viewport = MediaQuery.sizeOf(context);
    _pdfController.fitPage(
      pageWidth: page.width,
      pageHeight: page.height,
      viewportWidth: viewport.width,
      viewportHeight: viewport.height - 132,
      padding: 48,
    );
  }

  @override
  Widget build(BuildContext context) {
    final PdfDocument? document = _document;
    final PdfViewState reader = _pdfController.value;
    final ThemeData theme =
        _darkMode ? ThemeData.materialDark : ThemeData.materialLight;
    final ApplicationRuntimeInfo runtime = ApplicationInfo.of(context);
    return Theme(
      data: theme,
      child: ColoredBox(
        color: theme.colorScheme.surfaceContainer,
        child: Column(
          children: <Widget>[
            Toolbar(
              showBorder: false,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  ToolbarGroup(
                    children: <Widget>[
                      IconButton(
                        icon: const Icon(PhosphorIcons.folderOpen),
                        tooltip: _isLoading ? 'Abrindo PDF' : 'Abrir PDF',
                        onPressed: _isLoading ? null : _openPdf,
                      ),
                    ],
                  ),
                  const ToolbarDivider(),
                  ToolbarGroup(
                    spacing: 2,
                    children: <Widget>[
                      IconButton(
                        icon: const Icon(PhosphorIcons.caretLeft),
                        tooltip: 'Página anterior',
                        onPressed: document == null || reader.currentPage <= 1
                            ? null
                            : () =>
                                _pdfController.goToPage(reader.currentPage - 1),
                      ),
                      SizedBox(
                        width: 72,
                        height: 40,
                        child: Center(
                          child: Text(
                            document == null
                                ? '- / -'
                                : '${reader.currentPage} / ${reader.pageCount}',
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(PhosphorIcons.caretRight),
                        tooltip: 'Próxima página',
                        onPressed: document == null ||
                                reader.currentPage >= reader.pageCount
                            ? null
                            : () =>
                                _pdfController.goToPage(reader.currentPage + 1),
                      ),
                    ],
                  ),
                  const ToolbarDivider(),
                  ToolbarGroup(
                    spacing: 4,
                    children: <Widget>[
                      IconButton(
                        icon: const Icon(PhosphorIcons.magnifyingGlassMinus),
                        tooltip: 'Reduzir zoom',
                        onPressed:
                            document == null ? null : _pdfController.zoomOut,
                      ),
                      SizedBox(
                        width: 72,
                        height: 40,
                        child: Button(
                          label: '${(reader.zoom * 100).round()}%',
                          onPressed: document == null
                              ? null
                              : _pdfController.resetZoom,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(PhosphorIcons.magnifyingGlassPlus),
                        tooltip: 'Aumentar zoom',
                        onPressed:
                            document == null ? null : _pdfController.zoomIn,
                      ),
                    ],
                  ),
                  const ToolbarDivider(),
                  ToolbarGroup(
                    spacing: 4,
                    children: <Widget>[
                      IconButton(
                        icon: const Icon(PhosphorIcons.arrowsOut),
                        tooltip: 'Ajustar à largura',
                        onPressed: document == null ? null : _fitWidth,
                      ),
                      SizedBox(
                        width: 76,
                        height: 40,
                        child: Button(
                          label: 'Página',
                          onPressed: document == null ? null : _fitPage,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(
                      _darkMode ? PhosphorIcons.sun : PhosphorIcons.moon,
                    ),
                    tooltip: _darkMode ? 'Modo claro' : 'Modo escuro',
                    onPressed: () => setState(() {
                      _darkMode = !_darkMode;
                    }),
                  ),
                ],
              ),
            ),
            Toolbar(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  const Text('Localizar:'),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    icon: const Icon(PhosphorIcons.magnifyingGlass),
                    tooltip: reader.searchMatch == null
                        ? 'Buscar'
                        : 'Próxima ocorrência',
                    onPressed: document == null ? null : _onSearch,
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    icon: const Icon(PhosphorIcons.copy),
                    tooltip: 'Copiar seleção',
                    onPressed:
                        _pdfController.hasSelection ? _copySelection : null,
                  ),
                ],
              ),
            ),
            ColoredBox(
              color: theme.surface,
              child: Padding(
                padding: const EdgeInsets.only(
                  left: 12,
                  top: 8,
                  right: 12,
                  bottom: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            _fileName == null
                                ? 'Leitor PDF'
                                : '$_fileName  •  ${document?.pageCount ?? 0} páginas',
                            style: theme.textTheme.bodyMedium.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (_status != null)
                          Text(
                            _status!,
                            style: TextStyle(
                              color: theme.foregroundSecondary,
                              fontSize: 13,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: <Widget>[
                        Icon(
                          runtime.presentationKind == PresentationKind.gpu
                              ? PhosphorIcons.graphicsCard
                              : PhosphorIcons.cpu,
                          size: 14,
                          color: theme.foregroundSecondary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Execução/renderização: ${runtime.shortDescription}',
                          style: TextStyle(
                            color: theme.foregroundSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: _content(document, theme)),
          ],
        ),
      ),
    );
  }

  Widget _content(PdfDocument? document, ThemeData theme) {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(semanticsLabel: 'Carregando PDF'),
            SizedBox(height: 14),
            Text('Carregando PDF...'),
          ],
        ),
      );
    }
    final String? error = _error;
    if (error != null) {
      return Center(child: Text(error, fontSize: 14));
    }
    if (document == null) {
      return Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.surfaceAlternate,
            border: BoxBorder(color: theme.border, width: 1),
            radius: 14,
          ),
          child: const Padding(
            padding: EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.article, size: 48),
                SizedBox(height: 12),
                Text(
                  'Leitor de PDF',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 12),
                Text(
                    'Abra um documento para navegar, buscar, ampliar e copiar texto.'),
              ],
            ),
          ),
        ),
      );
    }
    return PdfView(
      document: document,
      controller: _pdfController,
      scrollDirection: Axis.vertical,
      pageSpacing: 20,
      enableTextSelection: true,
      enablePinchZoom: true,
      onTextSelectionStarted: _searchFocusNode.unfocus,
      backgroundColor: theme.colorScheme.surfaceContainer,
    );
  }
}
