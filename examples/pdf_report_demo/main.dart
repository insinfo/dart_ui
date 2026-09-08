import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/image_codecs.dart' as raster;
import 'package:dart_ui/pdf.dart';

const double _pageWidth = 595.28;
const double _pageHeight = 841.89;

void main(List<String> arguments) {
  final exampleDirectory = File.fromUri(Platform.script).parent;
  final repository = exampleDirectory.parent.parent;
  final output = File(
    arguments.isEmpty
        ? '${repository.path}${Platform.pathSeparator}output'
            '${Platform.pathSeparator}pdf${Platform.pathSeparator}'
            'dart_ui_relatorio_exemplo.pdf'
        : arguments.first,
  );
  output.parent.createSync(recursive: true);

  final typeface = Typeface.parse(
    File('${exampleDirectory.path}${Platform.pathSeparator}assets'
            '${Platform.pathSeparator}Inter-SemiBold.ttf')
        .readAsBytesSync(),
  );
  final jpeg = _createCoverJpeg();
  final builder = PdfDocumentBuilder(
    title: 'Relatório executivo — dart_ui PDF',
    author: 'dart_ui',
    creator: 'Exemplo PDF avançado',
  );
  final photo = builder.addJpeg(jpeg, name: 'DashboardPhoto');

  _buildOverviewPage(builder, typeface, photo);
  _buildDetailsPage(builder, typeface);

  final bytes = builder.build();
  final validation = const PdfValidator().validate(bytes);
  if (!validation.isValid) {
    throw StateError(
      'PDF inválido: ${validation.issues.map((issue) => issue.message).join('; ')}',
    );
  }
  output.writeAsBytesSync(bytes, flush: true);

  final parsed = PdfDocument.fromBytes(bytes);
  final images = const PdfImageInventory().inspect(parsed);
  stdout.writeln('PDF criado: ${output.absolute.path}');
  stdout.writeln(
    '${parsed.pageCount} páginas, ${images.length} JPEG, ${bytes.length} bytes',
  );
}

void _buildOverviewPage(
  PdfDocumentBuilder builder,
  Typeface typeface,
  String photo,
) {
  final page = builder.addPage(width: _pageWidth, height: _pageHeight);

  // O SVG permanece inline e passa pelo importador vetorial do dart_ui antes
  // de ser composto no mesmo content stream do restante da página.
  const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" width="595.28" height="841.89">
  <rect x="0" y="0" width="595.28" height="188" fill="#10253f"/>
  <path d="M 410 0 L 595.28 0 L 595.28 188 L 520 188 Z" fill="#087f5b"/>
  <path d="M 455 0 L 500 0 L 560 188 L 515 188 Z" fill="#15a97a"/>
  <path d="M 42 209 C 145 175, 210 250, 320 210 C 415 176, 490 224, 553 198"
        fill="none" stroke="#17a879" stroke-width="3"/>
</svg>
''';
  final vector = VectorSvgCodec.importFromSvg(svg);
  VectorPdfExporter.renderPage(vector, vector.getPage(0), page);

  _drawTypefaceText(
    page,
    typeface,
    'RELATÓRIO DE IMPACTO',
    const Offset(42, 70),
    25,
    0xFFFFFFFF,
  );
  page.drawText(
    'PDF nativo, vetores, imagem e dados em uma única composição',
    const Offset(43, 103),
    fontSize: 11,
    color: 0xFFDCEAF5,
  );
  page.drawText(
    'SETEMBRO 2026  /  DART_UI',
    const Offset(43, 141),
    fontSize: 9,
    color: 0xFF8DE2C1,
  );

  _sectionTitle(page, typeface, 'Visão geral', 42, 238);
  page.drawText(
    'Um exemplo completo criado apenas com APIs Dart. O cabeçalho decorativo',
    const Offset(42, 265),
    fontSize: 10.5,
    color: 0xFF34465C,
  );
  page.drawText(
    'veio de SVG inline; a fotografia abaixo está incorporada como JPEG.',
    const Offset(42, 282),
    fontSize: 10.5,
    color: 0xFF34465C,
  );

  page.drawImage(photo, const Rect.fromLTWH(42, 309, 318, 178));
  page.drawRect(
    const Rect.fromLTWH(42, 309, 318, 178),
    strokeColor: 0xFFD5DEE8,
    strokeWidth: 0.8,
  );

  _metricCard(page, typeface, 378, 309, '98,7%', 'integridade');
  _metricCard(page, typeface, 378, 371, '2,4×', 'mais rápido');
  _metricCard(page, typeface, 378, 433, '100%', 'Dart puro');

  _sectionTitle(page, typeface, 'Indicadores por trimestre', 42, 535);
  _drawTable(page);

  page.drawLine(
    const Offset(42, 792),
    const Offset(553, 792),
    strokeColor: 0xFFDDE4EC,
  );
  page.drawText(
    'Gerado com dart_ui • PDF 1.4 • JPEG DCT • SVG vetorial',
    const Offset(42, 812),
    fontSize: 8.5,
    color: 0xFF68788C,
  );
  page.drawText('01', const Offset(536, 812), fontSize: 8.5);
}

void _buildDetailsPage(PdfDocumentBuilder builder, Typeface typeface) {
  final page = builder.addPage(width: _pageWidth, height: _pageHeight);
  page.drawRect(
    const Rect.fromLTWH(0, 0, _pageWidth, 92),
    fillColor: 0xFFF0F6F4,
  );
  _drawTypefaceText(
    page,
    typeface,
    'COMO O DOCUMENTO FOI CONSTRUÍDO',
    const Offset(42, 54),
    19,
    0xFF10253F,
  );

  const entries = <(String, String)>[
    (
      '01  SVG inline',
      'Importado para VectorDocument e emitido como paths PDF.'
    ),
    (
      '02  JPEG',
      'Registrado como Image XObject com filtro DCTDecode, sem transcodificar.'
    ),
    (
      '03  Google Fonts',
      'Inter SemiBold é lida pelo Typeface e convertida em contornos.'
    ),
    (
      '04  Tabela',
      'Células, linhas, cores e tipografia são comandos vetoriais nativos.'
    ),
    (
      '05  Validação',
      'O arquivo final é reaberto e validado pelo próprio módulo PDF.'
    ),
  ];
  var y = 132.0;
  for (final entry in entries) {
    page.drawCircle(
      Offset(57, y + 8),
      13,
      fillColor: 0xFF087F5B,
    );
    page.drawText(
      entry.$1.substring(0, 2),
      Offset(51, y + 11),
      fontSize: 8,
      color: 0xFFFFFFFF,
    );
    _drawTypefaceText(
        page, typeface, entry.$1.substring(4), Offset(84, y), 13, 0xFF172B45);
    page.drawText(
      entry.$2,
      Offset(84, y + 24),
      fontSize: 9.5,
      color: 0xFF506176,
    );
    y += 88;
  }

  page.drawRect(
    const Rect.fromLTWH(42, 598, 511, 126),
    fillColor: 0xFF10253F,
  );
  _drawTypefaceText(
    page,
    typeface,
    'UM PIPELINE, VÁRIOS FORMATOS',
    const Offset(65, 638),
    17,
    0xFFFFFFFF,
  );
  page.drawText(
    'A mesma cena pode alimentar visualização, impressão, exportação e testes.',
    const Offset(65, 669),
    fontSize: 10,
    color: 0xFFDCEAF5,
  );
  page.drawText(
    'O exemplo também funciona como teste de integração legível por humanos.',
    const Offset(65, 689),
    fontSize: 10,
    color: 0xFFDCEAF5,
  );
  page.drawText('02', const Offset(536, 812), fontSize: 8.5);
}

void _sectionTitle(
  PdfCanvasRecorder page,
  Typeface typeface,
  String text,
  double x,
  double y,
) {
  page.drawRect(Rect.fromLTWH(x, y - 15, 4, 18), fillColor: 0xFF087F5B);
  _drawTypefaceText(page, typeface, text, Offset(x + 13, y), 15, 0xFF10253F);
}

void _metricCard(
  PdfCanvasRecorder page,
  Typeface typeface,
  double x,
  double y,
  String value,
  String caption,
) {
  page.drawRect(
    Rect.fromLTWH(x, y, 175, 52),
    fillColor: 0xFFF1F6F8,
    strokeColor: 0xFFD8E3E8,
    strokeWidth: 0.6,
  );
  _drawTypefaceText(
      page, typeface, value, Offset(x + 14, y + 24), 17, 0xFF087F5B);
  page.drawText(caption, Offset(x + 87, y + 24),
      fontSize: 9.5, color: 0xFF506176);
}

void _drawTable(PdfCanvasRecorder page) {
  const left = 42.0;
  const top = 558.0;
  const rowHeight = 34.0;
  const widths = <double>[180, 102, 112, 117];
  const rows = <List<String>>[
    ['Período', 'Documentos', 'Tempo médio', 'Conformidade'],
    ['1º trimestre', '18.420', '1,8 s', '97,2%'],
    ['2º trimestre', '23.105', '1,3 s', '98,1%'],
    ['3º trimestre', '31.870', '0,9 s', '98,7%'],
  ];
  var y = top;
  for (var row = 0; row < rows.length; row++) {
    var x = left;
    for (var column = 0; column < widths.length; column++) {
      final header = row == 0;
      page.drawRect(
        Rect.fromLTWH(x, y, widths[column], rowHeight),
        fillColor: header
            ? 0xFF10253F
            : row.isEven
                ? 0xFFF4F7F9
                : 0xFFFFFFFF,
        strokeColor: 0xFFD8E0E8,
        strokeWidth: 0.45,
      );
      page.drawText(
        rows[row][column],
        Offset(x + 10, y + 21),
        fontSize: header ? 9 : 9.5,
        color: header ? 0xFFFFFFFF : 0xFF26394F,
      );
      x += widths[column];
    }
    y += rowHeight;
  }
}

void _drawTypefaceText(
  PdfCanvasRecorder canvas,
  Typeface typeface,
  String text,
  Offset position,
  double size,
  int color,
) {
  final scale = size / typeface.unitsPerEm;
  var penX = position.dx;
  for (final rune in text.runes) {
    final glyph = typeface.glyphForCodePoint(rune);
    if (glyph != 0) {
      final transform = Transform2D(
        scale,
        0,
        0,
        -scale,
        penX,
        position.dy,
      );
      canvas.drawPath(typeface.outlineOf(glyph).transform(transform),
          fillColor: color);
    }
    penX += typeface.advanceOf(glyph) * scale;
  }
}

Uint8List _createCoverJpeg() {
  const width = 720;
  const height = 400;
  final image = raster.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final wave = math.sin(x / 48) * 14 + math.cos(y / 32) * 10;
      final glow = math.max(
          0,
          1 -
              math.sqrt(
                    math.pow(x - 520, 2) + math.pow(y - 120, 2),
                  ) /
                  390);
      image.setPixelRgb(
        x,
        y,
        (16 + glow * 25 + wave).clamp(0, 255).round(),
        (52 + glow * 125 + wave).clamp(0, 255).round(),
        (78 + glow * 94).clamp(0, 255).round(),
      );
    }
  }
  return raster.encodeJpg(image, quality: 88, chroma: raster.JpegChroma.yuv420);
}
