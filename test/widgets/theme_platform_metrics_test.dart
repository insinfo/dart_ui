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

  test('the desktop a theme was adapted to is recorded; a built-in has none',
      () {
    expect(ThemeData.fluentLight.desktop, isNull);
    expect(
      ThemeData.fluentLight.adaptedToPlatform(DesktopPlatform.macos).desktop,
      DesktopPlatform.macos,
    );
    final ThemeData windows =
        ThemeData.fluentLight.adaptedToPlatform(DesktopPlatform.windows);
    expect(windows.desktop, DesktopPlatform.windows);
    expect(windows.copyWith(fontSize: 15).desktop, DesktopPlatform.windows,
        reason: 'kept through a later copyWith');
    expect(
        windows == windows.copyWith(desktop: DesktopPlatform.macos), isFalse);
  });

  test("a macOS theme's menus take AppKit's shape, every other keeps its own",
      () {
    final MenuLook mac = MenuLook.of(
        ThemeData.fluentLight.adaptedToPlatform(DesktopPlatform.macos));
    expect(mac.radius, 12);
    expect(mac.verticalPadding, 5);
    expect(mac.rowPadding, 16);
    expect(mac.highlightInset, 5);
    expect(mac.separatorInset, 10);
    expect(mac.filledHighlight, isTrue);

    final ThemeData fluent =
        ThemeData.fluentLight.adaptedToPlatform(DesktopPlatform.windows);
    final MenuLook windows = MenuLook.of(fluent);
    expect(windows.radius, fluent.cornerRadiusLarge);
    expect(windows.verticalPadding, 4);
    expect(windows.rowPadding, fluent.effectiveControlPadding);
    expect(windows.highlightInset, 4);
    expect(windows.filledHighlight, isFalse);

    // A theme nobody adapted draws the same menu on every host.
    expect(MenuLook.of(ThemeData.neutralLight).filledHighlight, isFalse);
  });
}
