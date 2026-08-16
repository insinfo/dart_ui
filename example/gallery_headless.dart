/// The gallery with no display system at all.
///
/// This is the example that runs everywhere - a CI container, a server, a
/// machine with no X server and no window manager - and it is the one to read
/// first, because it is the shortest complete application in the repository.
/// Note what it does *not* do differently from `gallery_win32.dart`: nothing,
/// except which backend it names. There is no headless code path in the
/// shell, no `if (testing)`, no mock. The headless backend implements the same
/// [WindowingBackend] contract Win32 and X11 do, so what runs here is the
/// production frame loop.
///
/// It also needs no presentation entry, because the default one is the
/// portable path: the CPU renderer over the memory surface the window offers.
///
/// ```
/// dart run example/gallery_headless.dart --frames 8
/// dart run example/gallery_headless.dart --frames 8 --scale 2 --png out.png
/// ```
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

import 'gallery_shell.dart';

Future<void> main(List<String> arguments) async {
  // A headless window never closes by itself and its event pump never blocks,
  // so a budget is not optional here the way it is on Win32: without one this
  // would spin forever at full speed.
  final frames = intArgument(arguments, '--frames') ?? 8;
  final scale = intArgument(arguments, '--scale') ?? 1;

  final application = await Application.start(
    rootWidget: Gallery(model: GalleryModel(), theme: galleryTheme(arguments)),
    backends: <WindowingBackendEntry>[
      WindowingBackendEntry(
        name: 'headless',
        create: () => HeadlessWindowingBackend(renderScale: scale.toDouble()),
      ),
    ],
    options: galleryOptions(
      arguments,
      title: 'dart_ui gallery - headless',
      frameBudget: frames,
    ),
  );
  await application.run();

  // Read the pixels before teardown: the framebuffer belongs to the render
  // target, and the target is released with everything else.
  final target = (application.host.presenter as RenderTargetPresenter).target
      as MemoryRenderTarget;
  final screenshot = HeadlessScreenshot.fromFramebuffer(target.framebuffer);
  final path = stringArgument(arguments, '--png');
  if (path != null) File(path).writeAsBytesSync(screenshot.toPng());

  application.dispose();
  await application.closed;

  stdout.writeln('pixels=${screenshot.width}x${screenshot.height} '
      'checksum=${screenshot.checksum}'
      '${path == null ? '' : ' png=$path'}');
  exitCode = reportGallery(application, tag: 'HEADLESS_GALLERY');
}

String? stringArgument(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return arguments[index + 1];
}
