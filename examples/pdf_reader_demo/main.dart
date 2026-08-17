import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';

void main(List<String> arguments) {
  FrameworkFonts.install();
  runApp(PdfReaderDemoApp(
    initialPath: arguments.isEmpty ? null : arguments.first,
  ));
}

class PdfReaderDemoApp extends StatefulWidget {
  const PdfReaderDemoApp({super.key, this.initialPath});

  final String? initialPath;

  @override
  State<PdfReaderDemoApp> createState() => _PdfReaderDemoAppState();
}

class _PdfReaderDemoAppState extends State<PdfReaderDemoApp> {
  final TextEditingController _searchController = TextEditingController();
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
      try {
        final File file = File(initialPath);
        final PdfDocument document =
            PdfDocument.fromBytes(file.readAsBytesSync());
        _document = document;
        _fileName = file.uri.pathSegments.last;
        _status = 'Documento aberto. Clique com o botão direito para copiar.';
        _pdfController.attachDocument(document);
      } on Object catch (error) {
        _error = 'Não foi possível abrir o PDF: $error';
      }
    }
  }

  @override
  void dispose() {
    _pdfController.removeListener(_onReaderChanged);
    super.dispose();
  }

  void _onReaderChanged(PdfViewState state) {
    if (mounted) setState(() {});
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
      final PdfDocument document = PdfDocument.fromBytes(selected.bytes);
      if (!mounted) return;
      setState(() {
        _document = document;
        _fileName = selected.name;
        _isLoading = false;
        _status = 'Documento aberto. Arraste sobre o texto para selecioná-lo.';
      });
      _pdfController.attachDocument(document);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Não foi possível abrir o PDF: $error';
      });
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
    return Theme(
      data: theme,
      child: ColoredBox(
        color: theme.colorScheme.surfaceContainer,
        child: Column(
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                color: theme.surfaceAlternate,
                border: BoxBorder(color: theme.border, width: 1),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        IconButton(
                          icon: const Icon(Icons.folderOpen),
                          tooltip: _isLoading ? 'Abrindo PDF' : 'Abrir PDF',
                          onPressed: _isLoading ? null : _openPdf,
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          icon: const Icon(Icons.navigateBefore),
                          tooltip: 'Página anterior',
                          onPressed: document == null || reader.currentPage <= 1
                              ? null
                              : () => _pdfController
                                  .goToPage(reader.currentPage - 1),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 68,
                          child: Center(
                            child: Text(
                              document == null
                                  ? '- / -'
                                  : '${reader.currentPage} / ${reader.pageCount}',
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          icon: const Icon(Icons.navigateNext),
                          tooltip: 'Próxima página',
                          onPressed: document == null ||
                                  reader.currentPage >= reader.pageCount
                              ? null
                              : () => _pdfController
                                  .goToPage(reader.currentPage + 1),
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          icon: const Icon(Icons.zoomOut),
                          tooltip: 'Reduzir zoom',
                          onPressed:
                              document == null ? null : _pdfController.zoomOut,
                        ),
                        const SizedBox(width: 6),
                        Button(
                          label: '${(reader.zoom * 100).round()}%',
                          onPressed: document == null
                              ? null
                              : _pdfController.resetZoom,
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          icon: const Icon(Icons.zoomIn),
                          tooltip: 'Aumentar zoom',
                          onPressed:
                              document == null ? null : _pdfController.zoomIn,
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          icon: const Icon(Icons.fitScreen),
                          tooltip: 'Ajustar à largura',
                          onPressed: document == null ? null : _fitWidth,
                        ),
                        const SizedBox(width: 6),
                        Button(
                          label: 'Página',
                          onPressed: document == null ? null : _fitPage,
                        ),
                        const Spacer(),
                        IconButton(
                          icon: Icon(
                            _darkMode ? Icons.lightMode : Icons.darkMode,
                          ),
                          tooltip: _darkMode ? 'Modo claro' : 'Modo escuro',
                          onPressed: () => setState(() {
                            _darkMode = !_darkMode;
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        const Text('Localizar:'),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(controller: _searchController),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          icon: const Icon(Icons.search),
                          tooltip: reader.searchMatch == null
                              ? 'Buscar'
                              : 'Próxima ocorrência',
                          onPressed: document == null ? null : _onSearch,
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          icon: const Icon(Icons.contentCopy),
                          tooltip: 'Copiar seleção',
                          onPressed: _pdfController.hasSelection
                              ? _copySelection
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            ColoredBox(
              color: theme.surface,
              child: Padding(
                padding: const EdgeInsets.only(
                  left: 12,
                  top: 7,
                  right: 12,
                  bottom: 7,
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        _fileName == null
                            ? 'Leitor PDF'
                            : '$_fileName  •  ${document?.pageCount ?? 0} páginas',
                      ),
                    ),
                    if (_status != null) Text(_status!),
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
      backgroundColor: theme.colorScheme.surfaceContainer,
    );
  }
}
