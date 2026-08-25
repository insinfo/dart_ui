import 'dart:typed_data';
import '../format/pdf_limits.dart';
import '../format/pdf_object.dart';
import '../format/pdf_xref.dart';
import '../io/byte_reader.dart';
import 'pdf_page.dart';

/// Documento PDF completo com carregamento sob demanda, metadados e navegação de páginas.
class PdfDocument {
  final Uint8List rawBytes;
  final ByteReader reader;
  final PdfXRefTable _xref;
  final PdfLimits limits;

  PdfDict? _catalog;
  PdfDict? _info;
  final List<PdfPage> _pages = [];

  PdfDocument._(this.rawBytes, this.reader, this._xref, this.limits);

  /// Carrega um documento PDF a partir de um buffer de bytes na memória.
  factory PdfDocument.fromBytes(
    Uint8List bytes, {
    PdfLimits limits = const PdfLimits(),
  }) {
    final reader = ByteReader(bytes);
    final xref = PdfXRefTable(reader, limits: limits);
    xref.load();

    final doc = PdfDocument._(bytes, reader, xref, limits);
    doc._initialize();
    return doc;
  }

  void _initialize() {
    final trailer = _xref.trailer;
    if (trailer != null) {
      final rootObj = trailer.getResolved('Root', _xref);
      if (rootObj is PdfDict) {
        _catalog = rootObj;
      }

      final infoObj = trailer.getResolved('Info', _xref);
      if (infoObj is PdfDict) {
        _info = infoObj;
      }
    }

    _loadPagesTree();
  }

  void _loadPagesTree() {
    if (_catalog == null) return;
    final pagesRoot = _catalog!.getResolved('Pages', _xref);
    if (pagesRoot is PdfDict) {
      final pagesReference = _catalog!['Pages'];
      _traversePagesNode(
        pagesRoot,
        <String, PdfObject>{},
        pagesReference is PdfRef ? pagesReference : null,
        <int>{},
        0,
      );
    }
  }

  void _traversePagesNode(
    PdfDict node,
    Map<String, PdfObject> inheritedAttributes,
    PdfRef? nodeReference,
    Set<int> visitedReferences,
    int depth,
  ) {
    if (depth > limits.maxPageTreeDepth) {
      throw PdfFormatException(
        'page tree exceeds depth ${limits.maxPageTreeDepth}',
      );
    }
    if (nodeReference != null && !visitedReferences.add(nodeReference.objNum)) {
      return;
    }
    final currentInherited = Map<String, PdfObject>.from(inheritedAttributes);

    // Herança de atributos de nós pais (/MediaBox, /CropBox, /Rotate, /Resources)
    for (final attr in ['MediaBox', 'CropBox', 'Rotate', 'Resources']) {
      final val = node[attr];
      if (val != null) {
        currentInherited[attr] = val;
      }
    }

    final type = node.getName('Type', _xref)?.name;
    if (type == 'Pages') {
      final kids = node.getArray('Kids', _xref);
      if (kids != null) {
        for (var i = 0; i < kids.length; i++) {
          final kidReference = kids[i];
          final kidObj = kids.getResolved(i, _xref);
          if (kidObj is PdfDict) {
            _traversePagesNode(
              kidObj,
              currentInherited,
              kidReference is PdfRef ? kidReference : null,
              visitedReferences,
              depth + 1,
            );
          }
        }
      }
    } else if (type == 'Page' ||
        node.containsKey('Contents') ||
        node.containsKey('MediaBox')) {
      // Nó de página individual
      final pageDict = PdfDict(Map<String, PdfObject>.from(node.entries));

      // Aplica atributos herdados se ausentes
      for (final entry in currentInherited.entries) {
        if (!pageDict.containsKey(entry.key)) {
          pageDict[entry.key] = entry.value;
        }
      }

      final pageNumber = _pages.length + 1;
      if (pageNumber > limits.maxPages) {
        throw PdfFormatException('document exceeds ${limits.maxPages} pages');
      }
      _pages.add(PdfPage(
        pageNumber: pageNumber,
        dict: pageDict,
        resolver: _xref,
        reference: nodeReference,
      ));
    }
  }

  /// Quantidade total de páginas do documento.
  int get pageCount => _pages.length;

  /// Retorna a página no índice 1-based [pageNumber] (1..pageCount).
  PdfPage getPage(int pageNumber) {
    if (pageNumber < 1 || pageNumber > _pages.length) {
      throw RangeError.range(pageNumber, 1, _pages.length, 'pageNumber');
    }
    return _pages[pageNumber - 1];
  }

  /// Lista imutável de todas as páginas do documento.
  List<PdfPage> get pages => List.unmodifiable(_pages);

  /// Título do documento extraído do dicionário `/Info`.
  String? get title => _info?.getString('Title', _xref);

  /// Autor do documento.
  String? get author => _info?.getString('Author', _xref);

  /// Assunto do documento.
  String? get subject => _info?.getString('Subject', _xref);

  /// Criador / Aplicativo de autoria.
  String? get creator => _info?.getString('Creator', _xref);

  /// Produtor do PDF (ex: Quartz, Skia, etc.).
  String? get producer => _info?.getString('Producer', _xref);

  /// Data de criação do documento.
  String? get creationDate => _info?.getString('CreationDate', _xref);

  /// Dicionário `/Root` do Catálogo.
  PdfDict? get catalog => _catalog;

  /// Tabela XRef e resolvedor de objetos.
  PdfXRefTable get xref => _xref;

  @override
  String toString() =>
      'PdfDocument(pages: $pageCount, title: ${title ?? 'Sem título'})';
}
