/// The explorer's palette follows the desktop's light/dark setting while it
/// runs, unless `--dark`/`--light` pinned it.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:file_explorer/src/engine/demo_disk.dart';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/ui/app.dart';
import 'package:file_explorer/src/ui/explorer_window.dart';
import 'package:test/test.dart';

/// The explorer under a [MediaQuery] the test controls - what the application
/// shell installs, and replaces when the system settings or the window size
/// change.
final class _Harness {
  _Harness({bool? dark}) {
    final ExplorerModel model = ExplorerModel(
      fs: demoDisk(),
      places: kDemoPlaces,
      start: const FolderLocation('/Users/ana/Documents'),
    );
    // One instance for the whole test, as the shell keeps the application
    // widget across every change of its query.
    app = PopupScope(
      host: InTreePopupHost(),
      child: FileExplorerApp(
        model: model,
        dark: dark,
        onReady: (ExplorerWindowState w) => window = w,
      ),
    );
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(1280, 800)),
      ),
    );
    show(Brightness.light, const Size(1280, 800));
  }

  late final Widget app;
  late final BuildOwner owner;
  late ExplorerWindowState window;

  void show(Brightness brightness, Size size) {
    owner.pipelineOwner.rootConstraints = BoxConstraints.tight(size);
    owner.updateRoot(MediaQuery(
      data: MediaQueryData(size: size, platformBrightness: brightness),
      child: app,
    ));
    for (var pass = 0; pass < 8; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }

  Theme get theme => Theme.maybeOf(window.context)!;
}

void main() {
  setUpAll(FrameworkFonts.install);

  test('the palette follows the system brightness live', () {
    final _Harness harness = _Harness();
    final ExplorerWindowState first = harness.window;
    expect(harness.theme.data.brightness, Brightness.light);

    harness.show(Brightness.dark, const Size(1280, 800));
    expect(harness.theme.data.brightness, Brightness.dark);
    expect(harness.window, same(first),
        reason: 'switching the palette must not throw the window state away');

    harness.show(Brightness.light, const Size(1280, 800));
    expect(harness.theme.data.brightness, Brightness.light);
  });

  test('a resize does not rebuild the themed subtree', () {
    final _Harness harness = _Harness();
    final Theme before = harness.theme;

    harness.show(Brightness.light, const Size(1000, 700));

    expect(harness.theme, same(before),
        reason: 'a new Theme on every resize step notifies every control in '
            'the window - the cost _FollowSystemBrightness exists to avoid');
  });

  test('--dark and --light pin the palette against the system', () {
    final _Harness dark = _Harness(dark: true);
    expect(dark.theme.data.brightness, Brightness.dark);
    dark.show(Brightness.light, const Size(1280, 800));
    expect(dark.theme.data.brightness, Brightness.dark);

    final _Harness light = _Harness(dark: false);
    light.show(Brightness.dark, const Size(1280, 800));
    expect(light.theme.data.brightness, Brightness.light);
  });
}
