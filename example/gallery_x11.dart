/// The gallery in a real X11 window, rasterized on the CPU.
///
/// **Not executed.** This file was written on Windows and has never been run:
/// no X server was available to run it against. Everything in it is the same
/// shape as `gallery_win32.dart`, which *has* been run, and the X11 backend it
/// names has its own tests - but a working example is a claim about a live
/// display server, and that claim has not been checked. Treat the first run as
/// a bring-up, not a regression.
///
/// The presentation path is the core protocol's `PutImage`, which
/// `X11CpuPresenter` drives. It is the same retained-display-list shape the
/// Win32 DIB path uses: the canonical pixels live in the window's native
/// buffer, expose events upload them again, and a resize replays the retained
/// list into the surface created for the new generation. `xcb-shm` would
/// remove the upload copy and is detected but not yet used; see
/// `lib/src/backends/x11/x11_backend.dart`.
///
/// ```
/// dart run example/gallery_x11.dart --frames 20
/// DISPLAY=:0 dart run example/gallery_x11.dart
/// ```
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/x11/x11_backend.dart';
import 'package:dart_ui/src/backends/x11/x11_cpu_presenter.dart';
import 'package:dart_ui/src/backends/x11/x11_window.dart';

import 'gallery_shell.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isLinux) {
    exitCode = reportUnavailable('this example needs Linux with an X server',
        what: 'the X11 backend');
    return;
  }
  try {
    final application = await runApp(
      Gallery(model: GalleryModel(), theme: galleryTheme(arguments)),
      backends: <WindowingBackendEntry>[
        const WindowingBackendEntry(
            name: 'x11', create: X11WindowingBackend.new),
      ],
      presentations: <PresentationPathEntry>[
        PresentationPathEntry.retainedCpu(
          name: 'x11-putimage',
          deviceDescription: 'core protocol PutImage into a TrueColor visual',
          create: (NativeWindow window) {
            final presenter = X11CpuPresenter(window as X11Window);
            return (
              present: presenter.renderDisplayList,
              // No synchronous path here yet. X11 has no equivalent of the
              // modal resize loop that makes one necessary on Windows - the
              // window manager resizes, ConfigureNotify arrives on the socket
              // like any other event, and the ordinary frame loop draws it.
              presentNow: null,
              release: presenter.dispose,
            );
          },
        ),
      ],
      options: galleryOptions(arguments, title: 'dart_ui gallery - X11 CPU'),
    );
    exitCode = reportGallery(application, tag: 'X11_GALLERY');
  } on BackendSelectionError catch (error) {
    // Names the connection that failed and the DISPLAY it tried, because
    // "X11 unavailable" on a machine that has an X server is almost always an
    // authority or a socket problem rather than a missing library.
    exitCode = reportUnavailable(error, what: 'the X11 backend');
  }
}
