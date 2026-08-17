import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

T _find<T extends RenderBox>(RenderBox root) {
  T? result;
  void visit(RenderBox node) {
    if (node is T) result ??= node;
    if (result == null) node.visitChildren(visit);
  }

  visit(root);
  if (result == null) throw StateError('$T not found');
  return result!;
}

BuildOwner _mount(Widget root, {Size size = const Size(400, 300)}) {
  final BuildOwner owner = BuildOwner(
    pipelineOwner: PipelineOwner(
      rootConstraints: BoxConstraints.tight(size),
    ),
  )..updateRoot(root);
  owner.buildScope();
  owner.pipelineOwner.flushLayout();
  return owner;
}

void main() {
  test('bundled Roboto and Material Icons install without system fonts', () {
    final FontRegistry registry = FontRegistry(search: () => null);
    final FrameworkFontLoadResult result = FrameworkFonts.install(
      assetDirectory: 'assets/fonts',
      registry: registry,
    );

    expect(result.isComplete, isTrue);
    expect(registry.uiTypeface?.familyName, 'Roboto');
    final Typeface? icons = registry.faceFor(FrameworkFonts.iconFamily);
    expect(icons, isNotNull);
    expect(icons!.glyphForCodePoint(Icons.contentCopy.codePoint), isNot(0));
    expect(icons.glyphForCodePoint(Icons.zoomIn.codePoint), isNot(0));
  });

  test('modern ThemeData exposes Flutter-shaped semantic contracts', () {
    const ThemeData theme = ThemeData.materialDark;
    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.brightness, Brightness.dark);
    expect(theme.useMaterial3, isTrue);
    expect(theme.textTheme.titleLarge.fontWeight, FontWeight.w600);
    expect(theme.iconTheme.size, 20);
  });

  test('Text resolves style, colour, family and weight into RenderText', () {
    final BuildOwner owner = _mount(
      Theme(
        data: ThemeData.materialLight,
        child: const Text(
          'Portável',
          style: TextStyle(
            color: 0xFF123456,
            fontSize: 18,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
    addTearDown(owner.dispose);
    final RenderText text = _find<RenderText>(owner.renderRoot!);
    expect(text.color, 0xFF123456);
    expect(text.fontSize, 18);
    expect(text.fontFamily, 'Roboto');
    expect(text.fontWeight, 600);
  });

  test('circular progress has progress semantics and paints deterministically',
      () {
    final BuildOwner owner = _mount(
      const CircularProgressIndicator(
        value: 0.5,
        semanticsLabel: 'Carregando',
      ),
      size: const Size(48, 48),
    );
    addTearDown(owner.dispose);
    final RenderProgressIndicator progress =
        _find<RenderProgressIndicator>(owner.renderRoot!);
    expect(progress.describeSemantics().label, 'Carregando');
    expect(progress.describeSemantics().value, '50%');
    final DisplayList list = DisplayList();
    owner.pipelineOwner.flushPaint(list);
    expect(list.commandCount, greaterThan(0));
  });

  test('selectable PdfView installs a context-menu region', () {
    final PdfDocumentBuilder builder = PdfDocumentBuilder();
    builder
        .addPage(width: 200, height: 200)
        .drawText('Texto copiável', const Offset(20, 30));
    final PdfDocument document = PdfDocument.fromBytes(builder.build());
    final PdfViewController controller = PdfViewController();
    final BuildOwner owner = _mount(
      PdfView(
        document: document,
        controller: controller,
        enableTextSelection: true,
      ),
    );
    addTearDown(owner.dispose);

    expect(_find<RenderContextMenuRegion>(owner.renderRoot!), isNotNull);
    controller.selectAll(1);
    expect(controller.selectedText, contains('Texto'));
  });
}
