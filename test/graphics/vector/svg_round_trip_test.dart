/// The editor saves as SVG, so what it writes it must read back as the same
/// editable objects - and what other programs write it must read sensibly.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  VectorDocument sample() {
    final doc = VectorDocument(docUnits: DocUnit.mm);
    final methods = DocumentMethods(doc);
    final page = doc.getPage(0);
    final layer = doc.getPageLayers(page).first;
    methods.addObject(
        layer,
        VectorRectangle(
          startX: 10,
          startY: 20,
          rectWidth: 100,
          rectHeight: 50,
          corners: <double>[0.2, 0.2, 0.2, 0.2],
          style: const VectorStyle(
            fill: FillDescriptor(
              fillType: FillType.linearGradient,
              color: Color(0xFFFF0000),
              gradientStops: <GradientColorStop>[
                GradientColorStop(0, Color(0xFFFF0000)),
                GradientColorStop(1, Color(0x800000FF)),
              ],
            ),
            stroke: StrokeDescriptor(
                color: Color(0xFF000000), width: 2, join: LineJoin.round),
          ),
        ));
    methods.addObject(
        layer, methods.createCircle(cx: 200, cy: 100, rx: 40, ry: 20));
    methods.addObject(layer,
        methods.createPolygon(cx: 300, cy: 300, radius: 30, cornersNum: 6));
    methods.addObject(
        layer,
        VectorText(
          textContent: 'A & B <c>',
          trafo: <double>[0, 1, -1, 0, 50, 400],
          style: const VectorStyle(
            fill: FillDescriptor.solid(Color(0xFF123456)),
            textStyle: TextStyleDescriptor(fontSize: 18, bold: true),
          ),
        ));
    final hidden = doc.addLayer(page, name: 'Hidden & locked');
    hidden.properties[0] = false;
    methods.addObject(
        hidden, methods.createRectangle(x: 0, y: 0, width: 5, height: 5));
    doc.update();
    return doc;
  }

  test('every object comes back as itself, where it was', () {
    final original = sample();
    final svg = VectorSvgCodec.exportToSvg(original);
    final back = VectorSvgCodec.importFromSvg(svg);

    final page = back.getPage(0);
    final layers = page.children.whereType<VectorLayer>().toList();
    expect(layers.map((l) => l.name), contains('Hidden & locked'));
    expect(layers.firstWhere((l) => l.name == 'Hidden & locked').isVisible,
        isFalse,
        reason: 'a hidden layer is kept, not dropped');

    final before = original.getPageLayers(original.getPage(0)).first.children;
    final after = layers.first.children;
    expect(after.map((o) => o.runtimeType), before.map((o) => o.runtimeType));
    for (var i = 0; i < before.length; i++) {
      final a = before[i].cacheBbox;
      final b = after[i].cacheBbox;
      expect(b.left, closeTo(a.left, 0.01), reason: '${before[i]}');
      expect(b.top, closeTo(a.top, 0.01), reason: '${before[i]}');
      expect(b.width, closeTo(a.width, 0.01), reason: '${before[i]}');
      expect(b.height, closeTo(a.height, 0.01), reason: '${before[i]}');
    }

    final rect = after[0] as VectorRectangle;
    expect(rect.corners, <double>[0.2, 0.2, 0.2, 0.2]);
    expect(rect.style.fill.fillType, FillType.linearGradient);
    expect(rect.style.fill.gradientStops.last.color.alpha, closeTo(128, 1));
    expect(rect.style.stroke.join, LineJoin.round);
    expect((after[2] as VectorPolygon).cornersNum, 6);

    final text = after[3] as VectorText;
    expect(text.textContent, 'A & B <c>');
    expect(text.trafo, <double>[0, 1, -1, 0, 50, 400]);
    expect(text.style.textStyle.bold, isTrue);
    expect(text.style.textStyle.fontSize, 18);
  });

  test('a file from elsewhere: units, viewBox, transforms, CSS, shapes', () {
    const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape"
     width="210mm" height="297mm" viewBox="0 0 210 297">
  <defs>
    <radialGradient id="g" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" style="stop-color:#ffffff"/>
      <stop offset="100%" stop-color="rgb(0,0,255)"/>
    </radialGradient>
  </defs>
  <g inkscape:groupmode="layer" inkscape:label="Desenho" transform="translate(10,0)">
    <ellipse cx="50" cy="50" rx="20" ry="10" style="fill:url(#g);stroke:red;stroke-width:2"/>
    <g transform="rotate(90 100 100)" opacity="0.5">
      <line x1="80" y1="100" x2="120" y2="100" stroke="black"/>
      <polygon points="0,0 10,0 5,8" fill="green"/>
    </g>
    <rect x="0" y="0" width="10" height="10" display="none"/>
  </g>
</svg>''';
    final doc = VectorSvgCodec.importFromSvg(svg);
    final page = doc.getPage(0);
    expect(page.width, closeTo(PageFormats.a4.width, 0.5));
    expect(page.pageFormat.name, 'A4');
    expect(doc.docUnits, DocUnit.mm);

    final layer = page.children.whereType<VectorLayer>().first;
    expect(layer.name, 'Desenho');
    expect(layer.children, hasLength(2), reason: 'display:none is skipped');

    // 1 user unit = 1 mm = 2.8346 pt; the layer moved it 10 mm right.
    final ellipse = layer.children[0] as VectorCircle;
    const mm = 2.834645669291339;
    expect(ellipse.cacheBbox.center.dx, closeTo(60 * mm, 0.5));
    expect(ellipse.cacheBbox.center.dy, closeTo(50 * mm, 0.5));
    expect(ellipse.style.fill.fillType, FillType.radialGradient);
    expect(ellipse.style.stroke.color, const Color(0xFFFF0000));
    expect(ellipse.style.stroke.width, closeTo(2 * mm, 0.01));

    final group = layer.children[1] as VectorGroup;
    final line = group.children[0] as VectorCurve;
    // Rotated a quarter turn about (100,100): horizontal becomes vertical.
    expect(line.cacheBbox.height, greaterThan(line.cacheBbox.width * 5));
    expect(line.style.stroke.color.alpha, closeTo(128, 1));
    final triangle = group.children[1] as VectorCurve;
    expect(triangle.isClosed, isTrue);
  });

  test('text with markup characters stays valid XML', () {
    final doc = VectorDocument();
    final layer = doc.getPageLayers(doc.getPage(0)).first;
    DocumentMethods(doc)
        .addObject(layer, VectorText(textContent: 'Tom & Jerry <3'));
    final svg = VectorSvgCodec.exportToSvg(doc);
    expect(svg, contains('Tom &amp; Jerry &lt;3'));
    expect(() => VectorSvgCodec.importFromSvg(svg), returnsNormally);
  });
}
