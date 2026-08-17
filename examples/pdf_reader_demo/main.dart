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
  PdfDocument? _document;
  String? _fileName;
  String? _error;
  bool _isLoading = false;

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
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Não foi possível abrir o PDF: $error';
      });
    }
  }

  void _onSearch() {
    if (_document == null || _searchController.value.isEmpty) return;
    // PdfTextSearcher will consume this value when selection/search lands.
    print('Procurando por: ${_searchController.value}');
  }

  @override
  Widget build(BuildContext context) {
    final PdfDocument? document = _document;
    return ColoredBox(
      color: 0xFFF1F5F9,
      child: Column(
        children: <Widget>[
          ColoredBox(
            color: 0xFFFFFFFF,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: <Widget>[
                  Button(
                    label: _isLoading ? 'Abrindo...' : 'Abrir PDF',
                    onPressed: _isLoading ? null : _openPdf,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(controller: _searchController),
                  ),
                  const SizedBox(width: 8),
                  Button(
                    label: 'Buscar',
                    onPressed: document == null ? null : _onSearch,
                  ),
                ],
              ),
            ),
          ),
          if (_fileName != null)
            ColoredBox(
              color: 0xFFE2E8F0,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Text(
                  '$_fileName - ${document?.pageCount ?? 0} página(s)',
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
        child: Text('Clique em "Abrir PDF" para selecionar um documento.'),
      );
    }
    return PdfView(
      document: document,
      scrollDirection: Axis.vertical,
      enableTextSelection: true,
      enablePinchZoom: true,
    );
  }
}
