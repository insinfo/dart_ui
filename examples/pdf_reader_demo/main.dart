import 'dart:typed_data';
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
  late final PdfDocument _pdfDocument;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPdf();
  }

  void _loadPdf() {
    // Cria um arquivo PDF dummy na memória
    final dummyPdfBytes = Uint8List.fromList([
      0x25,
      0x50,
      0x44,
      0x46,
      0x2D,
      0x31,
      0x2E,
      0x37,
      0x0A,
      0x78,
      0x72,
      0x65,
      0x66,
      0x0A,
      0x30,
      0x20,
      0x30,
      0x0A,
      0x74,
      0x72,
      0x61,
      0x69,
      0x6C,
      0x65,
      0x72,
      0x0A,
      0x3C,
      0x3C,
      0x3E,
      0x3E,
      0x0A,
      0x73,
      0x74,
      0x61,
      0x72,
      0x74,
      0x78,
      0x72,
      0x65,
      0x66,
      0x0A,
      0x39,
      0x0A,
      0x25,
      0x25,
      0x45,
      0x4F,
      0x46,
      0x0A
    ]);

    _pdfDocument = PdfDocument.fromBytes(dummyPdfBytes);
    setState(() {
      _isLoading = false;
    });
  }

  void _onSearch() {
    print('Procurando por: ${_searchController.value}');
    // Lógica real acionaria PdfTextSearcher e injetaria um HighlightAnnotation.
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const ColoredBox(
        color: 0xFFF1F5F9,
        child: Center(
          child: Text('Carregando PDF...', fontSize: 24),
        ),
      );
    }

    return ColoredBox(
      color: 0xFFF1F5F9, // Slate 100
      child: Column(
        children: [
          // Barra de Ferramentas Superior
          ColoredBox(
            color: 0xFFFFFFFF,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      // placeholder: 'Pesquisar no PDF...', // Assumindo que TextField pode ter placeholder
                    ),
                  ),
                  const SizedBox(width: 8),
                  Button(
                    label: 'Buscar',
                    onPressed: _onSearch,
                  ),
                ],
              ),
            ),
          ),

          // Visualizador de PDF (Preenche o resto da tela)
          Expanded(
            child: PdfView(
              document: _pdfDocument,
              // O Axis vem de package:dart_ui/dart_ui.dart caso exporte render_flex.dart
              scrollDirection: Axis.vertical,
              enableTextSelection: true,
              enablePinchZoom: true,
            ),
          ),
        ],
      ),
    );
  }
}
