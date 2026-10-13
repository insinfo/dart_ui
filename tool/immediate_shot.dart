/// Renders `example/immediate_demo.dart` headless, once per theme, to PNGs.
///
/// ```
/// dart run tool/immediate_shot.dart build/immediate
/// ```
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/immediate.dart';

import '../example/immediate_demo.dart' as demo;

Future<void> main(List<String> args) async {
  final String dir = args.isNotEmpty ? args.first : 'build/immediate';
  Directory(dir).createSync(recursive: true);
  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();
  const int width = 920, height = 640;
  for (final String name in demo.demoThemes.keys) {
    demo.demoTheme = name;
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints:
            BoxConstraints.tight(Size(width.toDouble(), height.toDouble())),
      ),
    );
    owner.updateRoot(const _Root());
    var list = DisplayList();
    // Panels size themselves from the previous frame: a few frames settle.
    for (var pass = 0; pass < 6; pass++) {
      list = DisplayList();
      owner.buildScope();
      owner.pipelineOwner.drawFrame(list);
      await Future<void>.delayed(Duration.zero);
    }
    final device = await const CpuRendererBackend().createDevice();
    final target = device.createTarget(
      const MemorySurfaceDescriptor(pixelWidth: width, pixelHeight: height),
    ) as MemoryRenderTarget;
    await target.renderDisplayList(list, clearColor: 0xFFFFFFFF);
    final String file = '$dir/${name.toLowerCase().replaceAll(' ', '_')}.png';
    File(file).writeAsBytesSync(
        HeadlessScreenshot.fromFramebuffer(target.framebuffer).toPng());
    stdout.writeln('wrote $file');
  }
}

final class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) => Theme(
      data: ThemeData.neutralLight,
      child: const ImmediateArea(builder: demo.build));
}
