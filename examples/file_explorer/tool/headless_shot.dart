/// Renders the explorer with no window, on the made-up disk, to a PNG.
///
/// ```
/// dart run tool/headless_shot.dart out.png [scenario] [--dark] [--lang=pt]
/// ```
///
/// Scenarios: home, details (the default), icons, tiles, rename, search,
/// thispc, details-pane.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:file_explorer/src/engine/demo_disk.dart';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/engine/strings.dart';
import 'package:file_explorer/src/ui/app.dart';
import 'package:file_explorer/src/ui/explorer_window.dart';

Future<void> main(List<String> args) async {
  final String path = args.isNotEmpty ? args[0] : 'shot.png';
  final List<String> rest = args.skip(1).toList();
  final String scenario =
      rest.where((String a) => !a.startsWith('--')).firstOrNull ?? 'details';
  final bool dark = rest.contains('--dark');
  final ExplorerStrings strings = rest.contains('--lang=pt')
      ? ExplorerStrings.portuguese
      : ExplorerStrings.english;
  const int width = 1280;
  const int height = 800;

  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();

  final ExplorerModel model = ExplorerModel(
    fs: demoDisk(),
    places: kDemoPlaces,
    strings: strings,
    start: scenario == 'home'
        ? null
        : const FolderLocation('/Users/ana/Documents'),
  );
  ExplorerWindowState? window;
  final BuildOwner owner = BuildOwner(
    pipelineOwner: PipelineOwner(
      rootConstraints:
          BoxConstraints.tight(Size(width.toDouble(), height.toDouble())),
    ),
  );
  owner.updateRoot(PopupScope(
    host: InTreePopupHost(),
    child: FileExplorerApp(
      model: model,
      dark: dark,
      onReady: (ExplorerWindowState w) => window = w,
    ),
  ));

  Future<DisplayList> settle() async {
    var list = DisplayList();
    for (var pass = 0; pass < 12; pass++) {
      await Future<void>.delayed(Duration.zero);
      await model.idle;
      list = DisplayList();
      owner.buildScope();
      owner.pipelineOwner.drawFrame(list);
      if (!owner.hasScheduledBuilds) break;
    }
    return list;
  }

  await settle();
  final CommandRegistry registry = window!.registry;
  switch (scenario) {
    case 'icons':
      registry
        ..execute('view.largeIcons')
        ..execute('select.paths', <String, Object?>{
          'paths': <String>['/Users/ana/Documents/Project Files']
        });
    case 'tiles':
      registry.execute('view.tiles');
    case 'rename':
      registry
        ..execute('select.byName', <String, Object?>{'prefix': 'license'})
        ..execute('file.rename');
    case 'search':
      registry.execute('nav.search', <String, Object?>{'query': 'report'});
    case 'thispc':
      registry.execute('nav.thisPc');
    case 'details-pane':
      registry
        ..execute('select.byName', <String, Object?>{'prefix': 'annual'})
        ..execute('view.detailsPane');
    default:
      registry.execute('select.paths', <String, Object?>{
        'paths': <String>[
          '/Users/ana/Documents/Focus Sessions.xlsx',
          '/Users/ana/Documents/Annual Report 2025.pdf',
        ],
      });
  }
  final DisplayList list = await settle();

  final device = await const CpuRendererBackend().createDevice();
  final MemoryRenderTarget target = device.createTarget(
    const MemorySurfaceDescriptor(pixelWidth: width, pixelHeight: height),
  ) as MemoryRenderTarget;
  final result = await target.renderDisplayList(list, clearColor: 0xFF202020);
  final HeadlessScreenshot shot =
      HeadlessScreenshot.fromFramebuffer(target.framebuffer);
  File(path).writeAsBytesSync(shot.toPng());
  stdout.writeln('render ${result.isSuccess ? 'ok' : 'FAILED'} -> $path');
  exit(0);
}
