import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('the Fluent font is bundled and its glyphs draw', () {
    final FrameworkFontLoadResult fonts = FrameworkFonts.install();
    addTearDown(FontRegistry.instance.reset);
    expect(fonts.fluentIconFontLoaded, isTrue);
    for (final IconData icon in <IconData>[
      FluentIcons.folderFilled,
      FluentIcons.folder,
      FluentIcons.documentFilled,
      FluentIcons.cut,
      FluentIcons.home,
    ]) {
      expect(RenderIcon(icon, size: 20).hasGlyph, isTrue,
          reason: '0x${icon.codePoint.toRadixString(16)}');
    }
  });
}
