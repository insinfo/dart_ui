import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';

void main() => runApp(const PdfReaderDemoApp());

class PdfReaderDemoApp extends StatefulWidget {
  const PdfReaderDemoApp({super.key});

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

  @override
  void initState() {
    super.initState();
    _pdfController.addListener(_onReaderChanged);
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
    return ColoredBox(
      color: 0xFFE9EEF5,
      child: Column(
        children: <Widget>[
          DecoratedBox(
            decoration: const BoxDecoration(
              color: 0xFFF8FAFC,
              border: BoxBorder(color: 0xFFCBD5E1, width: 1),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Button(
                        label: _isLoading ? 'Abrindo...' : 'Abrir PDF',
                        onPressed: _isLoading ? null : _openPdf,
                      ),
                      const SizedBox(width: 12),
                      Button(
                        label: '<',
                        onPressed: document == null || reader.currentPage <= 1
                            ? null
                            : () =>
                                _pdfController.goToPage(reader.currentPage - 1),
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
                      Button(
                        label: '>',
                        onPressed: document == null ||
                                reader.currentPage >= reader.pageCount
                            ? null
                            : () =>
                                _pdfController.goToPage(reader.currentPage + 1),
                      ),
                      const SizedBox(width: 12),
                      Button(
                        label: '-',
                        onPressed:
                            document == null ? null : _pdfController.zoomOut,
                      ),
                      const SizedBox(width: 6),
                      Button(
                        label: '${(reader.zoom * 100).round()}%',
                        onPressed:
                            document == null ? null : _pdfController.resetZoom,
                      ),
                      const SizedBox(width: 6),
                      Button(
                        label: '+',
                        onPressed:
                            document == null ? null : _pdfController.zoomIn,
                      ),
                      const SizedBox(width: 12),
                      Button(
                        label: 'Largura',
                        onPressed: document == null ? null : _fitWidth,
                      ),
                      const SizedBox(width: 6),
                      Button(
                        label: 'Página',
                        onPressed: document == null ? null : _fitPage,
                      ),
                      const Spacer(),
                      Text(
                        document == null
                            ? 'Seleção e zoom'
                            : '${(reader.zoom * 100).round()}%  •  página ${reader.currentPage}',
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
                      Button(
                        label:
                            reader.searchMatch == null ? 'Buscar' : 'Próximo',
                        onPressed: document == null ? null : _onSearch,
                      ),
                      const SizedBox(width: 6),
                      Button(
                        label: 'Copiar seleção',
                        onPressed:
                            _pdfController.hasSelection ? _copySelection : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          ColoredBox(
            color: 0xFFDCE4EE,
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
          Expanded(child: _content(document)),
        ],
      ),
    );
  }

  Widget _content(PdfDocument? document) {
    if (_isLoading) {
      return const Center(child: Text('Carregando PDF...', fontSize: 20));
    }
    final String? error = _error;
    if (error != null) {
      return Center(child: Text(error, fontSize: 14));
    }
    if (document == null) {
      return const Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: 0xFFFFFFFF,
            border: BoxBorder(color: 0xFFCBD5E1, width: 1),
            radius: 10,
          ),
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('Leitor de PDF', fontSize: 24),
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
      backgroundColor: 0xFFE9EEF5,
    );
  }
}
