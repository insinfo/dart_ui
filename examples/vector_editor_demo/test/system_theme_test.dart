/// "Follow the system" follows it while the editor runs.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';
import 'package:vector_editor_demo/src/ui/app.dart';
import 'package:vector_editor_demo/src/ui/editor_ui.dart';
import 'package:vector_editor_demo/src/ui/main_window.dart';

/// The editor under a [MediaQuery] the test controls, as the application
/// shell installs it and replaces it when the settings or the size change.
final class _Harness {
  _Harness() {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(1400, 880)),
      ),
    );
    show(Brightness.light, const Size(1400, 880));
  }

  /// One instance for the whole test, as the shell keeps the application
  /// widget across every change of its query.
  final Widget app = PopupScope(
    host: InTreePopupHost(),
    child: const VectorEditorApp(onReady: _remember),
  );
  late final BuildOwner owner;

  static MainWindowState? _last;
  static void _remember(MainWindowState window) => _last = window;
  MainWindowState get window => _last!;

  void show(Brightness brightness, Size size) {
    owner.pipelineOwner.rootConstraints = BoxConstraints.tight(size);
    owner.updateRoot(MediaQuery(
      data: MediaQueryData(size: size, platformBrightness: brightness),
      child: app,
    ));
    for (var pass = 0; pass < 10; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }
}

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  test('the system mode wears the live desktop brightness', () {
    final _Harness harness = _Harness();
    expect(harness.window.ui.themeMode, EditorThemeMode.system);
    expect(harness.window.ui.theme.name, ThemeData.studioLight.name);

    harness.show(Brightness.dark, const Size(1400, 880));
    expect(harness.window.ui.theme.name, ThemeData.studioDark.name);

    harness.show(Brightness.light, const Size(1400, 880));
    expect(harness.window.ui.theme.name, ThemeData.studioLight.name);
  });

  test('an explicit mode ignores the desktop', () {
    final _Harness harness = _Harness();
    expect(harness.window.registry.execute('theme.dark').ok, isTrue);
    harness.show(Brightness.light, const Size(1400, 880));
    expect(harness.window.ui.theme.name, ThemeData.studioDark.name);
  });

  test('a new query with the same brightness does not rebuild the window', () {
    final _Harness harness = _Harness();
    final MainWindowState window = harness.window;
    final int before = window.debugBuildCount;

    // What a resize does to the query, minus the resize itself (which moves
    // the canvas and rebuilds the window for reasons of its own): a new
    // object whose brightness is the same.
    harness.show(Brightness.light, const Size(1400, 880));
    expect(window.debugBuildCount, before);

    harness.show(Brightness.dark, const Size(1400, 880));
    expect(window.debugBuildCount, greaterThan(before));
    expect(harness.window, same(window),
        reason: 'the editor state survives a palette switch');
  });
}
