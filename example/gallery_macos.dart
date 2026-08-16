/// The gallery in a real AppKit window, rasterized on the CPU.
///
/// **Not executed.** This file was written on Windows and has never been run
/// on a Mac. The macOS backend has its own tests and its own spike documents
/// (`doc/SPIKE_MACOS_MAIN_THREAD.md`, `doc/MACOS_TRES_BACKENDS.md`), but a
/// working example is a claim about a live `NSApplication`, a host process and
/// a shared surface handshake, and none of that has been checked from here.
/// Treat the first run as a bring-up.
///
/// ## Why this file is longer than `gallery_x11.dart`
///
/// Win32 and X11 each ship a retained CPU presenter - `Win32CpuPresenter`,
/// `X11CpuPresenter` - that owns the display list and replays it into the
/// replacement surface after a resize. macOS has no equivalent yet; what it
/// has is `MacosWindow.drawAndPresent`, which hands the back buffer's own
/// memory to a callback. So the adapter is written out here instead of being
/// one line, and that difference is the point: this example is the smallest
/// honest statement of what a `MacosCpuPresenter` would have to do, and the
/// place to delete once one exists.
///
/// The gap it leaves, said plainly: an expose or a resize that arrives while
/// no frame is being drawn does *not* repaint here, because nothing retains
/// the last display list. The shell asks for a fresh frame on both events, so
/// the window recovers - one frame later than the other two backends do.
///
/// ```
/// dart run example/gallery_macos.dart --frames 20
/// ```
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/macos.dart';

import 'gallery_shell.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isMacOS) {
    exitCode = reportUnavailable('this example needs macOS',
        what: 'the AppKit backend');
    return;
  }
  try {
    final application = await runApp(
      Gallery(model: GalleryModel(), theme: galleryTheme(arguments)),
      backends: <WindowingBackendEntry>[
        const WindowingBackendEntry(
          name: 'macos',
          // The default options refuse both the private SkyLight API and the
          // signal-handler backend. Neither is a fallback anything may take
          // silently; see `macos_backend_selection.dart`.
          create: MacosWindowingBackend.new,
        ),
      ],
      presentations: <PresentationPathEntry>[
        PresentationPathEntry.retainedCpu(
          name: 'macos-iosurface',
          deviceDescription: 'IOSurface back buffer presented by the host',
          create: (NativeWindow window) {
            final macosWindow = window as MacosWindow;
            return (
              present: (
                DisplayList list, {
                int? clearColor,
                Transform2D? deviceTransform,
                Rect? damage,
              }) =>
                  macosWindow.drawAndPresent(
                    (Framebuffer buffer) => rasterizeDisplayList(
                      list,
                      buffer,
                      clearColor: clearColor,
                      damage: damage,
                      deviceTransform: deviceTransform ??
                          Transform2D.scaling(
                            macosWindow.renderScale,
                            macosWindow.renderScale,
                          ),
                    ),
                    // The window's own generation, so a frame that was begun
                    // before a resize is rejected by the surface pool as well as
                    // by the shell's WindowHost. Two independent checks of the
                    // same rule, which is correct: they guard different windows of
                    // time.
                    frameGeneration: macosWindow.generation,
                  ),
              release: macosWindow.dispose,
            );
          },
        ),
      ],
      options: galleryOptions(arguments, title: 'dart_ui gallery - AppKit CPU'),
    );
    exitCode = reportGallery(application, tag: 'MACOS_GALLERY');
  } on BackendSelectionError catch (error) {
    exitCode = reportUnavailable(error, what: 'the AppKit backend');
  }
}
