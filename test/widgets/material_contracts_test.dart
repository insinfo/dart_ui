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
  test('bundled UI and icon fonts install deterministically', () {
    final FontRegistry registry = FontRegistry(search: () => null);
    final FrameworkFontLoadResult result = FrameworkFonts.install(
      assetDirectory: 'assets/fonts',
      registry: registry,
    );

    expect(result.isComplete, isTrue);
    expect(result.uiVariantFontsLoaded, 2);
    expect(registry.uiTypeface?.familyName, 'Inter');
    expect(registry.faceFor('Inter', weight: 500)?.weightClass, 500);
    expect(registry.faceFor('Inter', weight: 600)?.weightClass, 600);
    final Typeface? material =
        registry.faceFor(FrameworkFonts.materialIconFamily);
    expect(material, isNotNull);
    expect(material!.glyphForCodePoint(Icons.contentCopy.codePoint), isNot(0));
    final Typeface? tabler = registry.faceFor(FrameworkFonts.iconFamily);
    expect(tabler, isNotNull);
    expect(tabler!.glyphForCodePoint(TablerIcons.copy.codePoint), isNot(0));
    expect(tabler.glyphForCodePoint(TablerIcons.zoomIn.codePoint), isNot(0));
    expect(result.phosphorIconFontLoaded, isTrue);
    final Typeface? phosphor =
        registry.faceFor(FrameworkFonts.phosphorIconFamily);
    expect(phosphor, isNotNull);
    expect(
      phosphor!.glyphForCodePoint(PhosphorIcons.floppyDisk.codePoint),
      isNot(0),
    );
    expect(
      phosphor.glyphForCodePoint(PhosphorIcons.magnifyingGlass.codePoint),
      isNot(0),
    );
  });

  test('modern ThemeData exposes Flutter-shaped semantic contracts', () {
    const ThemeData theme = ThemeData.materialDark;
    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.brightness, Brightness.dark);
    expect(theme.useMaterial3, isTrue);
    expect(theme.textTheme.titleLarge.fontWeight, FontWeight.w600);
    expect(theme.iconTheme.size, 20);
    expect(theme.scrollbarTheme.radius, greaterThan(100));
  });

  test('Text resolves style, colour, family and weight into RenderText', () {
    final BuildOwner owner = _mount(
      Theme(
        data: ThemeData.materialLight,
        child: const Text(
          'Portável',
          style: TextStyle(
            color: Color(0xFF123456),
            fontSize: 18,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
    addTearDown(owner.dispose);
    final RenderText text = _find<RenderText>(owner.renderRoot!);
    expect(text.color, const Color(0xFF123456));
    expect(text.fontSize, 18);
    expect(text.fontFamily, 'Roboto');
    expect(text.fontWeight, 600);
  });

  test('const text and icons follow a live light/dark theme switch', () {
    const Widget content = Column(
      children: <Widget>[
        Text('Sempre legível'),
        Icon(TablerIcons.folderOpen),
      ],
    );
    final BuildOwner owner = _mount(
      Theme(data: ThemeData.materialLight, child: content),
    );
    addTearDown(owner.dispose);

    final RenderText text = _find<RenderText>(owner.renderRoot!);
    final RenderIcon icon = _find<RenderIcon>(owner.renderRoot!);
    expect(text.color, ThemeData.materialLight.foreground);
    expect(
      icon.color,
      ThemeData.materialLight.iconTheme.color ??
          ThemeData.materialLight.foreground,
    );

    owner.updateRoot(Theme(data: ThemeData.materialDark, child: content));
    owner.buildScope();
    owner.pipelineOwner.flushLayout();

    expect(text.color, ThemeData.materialDark.foreground);
    expect(
      icon.color,
      ThemeData.materialDark.iconTheme.color ??
          ThemeData.materialDark.foreground,
    );
  });

  test('IconButton applies its one-pixel optical correction', () {
    final BuildOwner owner = _mount(
      Center(
        child: IconButton(
          icon: const Icon(TablerIcons.search),
          onPressed: () {},
        ),
      ),
      size: const Size(100, 100),
    );
    addTearDown(owner.dispose);
    final RenderIconButton button = _find<RenderIconButton>(owner.renderRoot!);
    final RenderIcon icon = _find<RenderIcon>(owner.renderRoot!);
    final Offset buttonCenter = button.localToGlobal(
      Offset(button.size.width / 2, button.size.height / 2),
    );
    final Offset iconCenter = icon.localToGlobal(
      Offset(icon.size.width / 2, icon.size.height / 2),
    );

    expect(iconCenter.dx, closeTo(buttonCenter.dx + 1, 0.01));
    expect(iconCenter.dy, closeTo(buttonCenter.dy + 1, 0.01));
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

  test('TextField accepts a caller-owned Flutter-shaped FocusNode', () {
    final FocusNode focusNode = FocusNode(debugLabel: 'external search');
    final TextEditingController controller = TextEditingController();
    final BuildOwner owner = _mount(
      TextField(controller: controller, focusNode: focusNode),
    );
    addTearDown(owner.dispose);
    addTearDown(focusNode.dispose);

    expect(focusNode.requestFocus(), isTrue);
    expect(focusNode.hasPrimaryFocus, isTrue);
    focusNode.unfocus();
    expect(focusNode.hasPrimaryFocus, isFalse);
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
