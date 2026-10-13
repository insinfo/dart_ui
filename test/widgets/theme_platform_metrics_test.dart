import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('a compact theme takes the sizes of each desktop', () {
    final ThemeData mac =
        ThemeData.studioDark.adaptedToPlatform(DesktopPlatform.macos);
    expect(mac.fontSize, 13);
    expect(mac.effectiveControlHeight, 28);
    expect(mac.effectiveRowHeight, 24);
    expect(mac.iconTheme.size, 16);

    final ThemeData windows =
        ThemeData.studioDark.adaptedToPlatform(DesktopPlatform.windows);
    expect(windows.fontSize, 14);
    expect(windows.effectiveControlHeight, 32);
    expect(windows.effectiveRowHeight, 28);

    final ThemeData linux =
        ThemeData.studioLight.adaptedToPlatform(DesktopPlatform.linux);
    expect(linux.fontSize, 14);
    expect(linux.effectiveControlHeight, 32);
  });

  test('the look is kept: colours, corners and name', () {
    final ThemeData adapted =
        ThemeData.studioLight.adaptedToPlatform(DesktopPlatform.windows);
    expect(adapted.name, ThemeData.studioLight.name);
    expect(adapted.accent, ThemeData.studioLight.accent);
    expect(adapted.surface, ThemeData.studioLight.surface);
    expect(adapted.cornerRadius, ThemeData.studioLight.cornerRadius);
    expect(adapted.iconTheme.color, ThemeData.studioLight.iconTheme.color);
  });

  test('a theme drawn larger keeps its size', () {
    final ThemeData material =
        ThemeData.materialLight.adaptedToPlatform(DesktopPlatform.macos);
    expect(material.fontSize, ThemeData.materialLight.fontSize);
    expect(material.controlHeight, ThemeData.materialLight.controlHeight);
  });

  test('the host desktop can be overridden for a test', () {
    debugDesktopPlatformOverride = DesktopPlatform.windows;
    addTearDown(() => debugDesktopPlatformOverride = null);
    expect(hostDesktopPlatform, DesktopPlatform.windows);
    expect(ThemeData.studioDark.adaptedToPlatform().fontSize, 14);
  });
}
