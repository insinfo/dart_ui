/// Renders the explorer with no window, on the made-up disk, to a PNG.
///
/// ```
/// dart run tool/headless_shot.dart out.png [scenario] [--dark] [--lang=pt]
/// ```
///
/// Scenarios: home, details (the default), icons, tiles, rename, search,
/// thispc, details-pane, pictures, properties, properties-folder.
library;

import 'dart:io';
import 'dart:typed_data';

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
    child: DialogLayer(
      child: FileExplorerApp(
        model: model,
        dark: dark,
        thumbnailLoader: _paintedThumbnail,
        onReady: (ExplorerWindowState w) => window = w,
      ),
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
      if (pass > 3 && !owner.hasScheduledBuilds) break;
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
    case 'properties':
      registry
        ..execute('select.byName', <String, Object?>{'prefix': 'annual'})
        ..execute('file.properties');
    case 'properties-folder':
      registry
        ..execute('select.byName', <String, Object?>{'prefix': 'project'})
        ..execute('file.properties');
    case 'pictures':
      registry
        ..execute('nav.go', <String, Object?>{'path': '/Users/ana/Pictures'})
        ..execute('view.largeIcons');
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

/// The made-up disk holds no pixels, so every picture is painted: a
/// landscape gradient whose hue comes from the name.
Future<DecodedImage?> _paintedThumbnail(String path) async {
  const int w = 256;
  const int h = 170;
  final int hue = path.hashCode;
  final Uint8List pixels = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final int i = (y * w + x) * 4;
      pixels[i] = (hue + x) & 0xFF; // blue
      pixels[i + 1] = (hue >> 8) + y & 0xFF;
      pixels[i + 2] = (hue >> 16) + x ~/ 2 & 0xFF;
      pixels[i + 3] = 255;
    }
  }
  return DecodedImage(
    width: w,
    height: h,
    order: ImageChannelOrder.bgra,
    pixels: pixels,
    hasAlpha: false,
  );
}
