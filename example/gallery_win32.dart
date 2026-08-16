/// The gallery, in a real Win32 window, rasterized on the CPU.
///
/// The other half of the Fase 6 gate: the headless suite proves the gallery
/// builds, lays out and paints; this proves the *same widget tree*, unchanged,
/// drives a real window - real `WM_PAINT`, real mouse and keyboard messages,
/// real pixels through a DIB section - with no native control anywhere in it.
///
/// What used to be 286 lines of assembly is now two list entries: which
/// windowing backend, and how its pixels reach the screen. Everything else -
/// selection, the window, the scheduler, the owners, event routing, the frame
/// loop, teardown - is `lib/src/app/application.dart`, shared with every other
/// gallery in this directory.
///
/// ```
/// dart run example/gallery_win32.dart --frames 20
/// dart compile exe example/gallery_win32.dart -o gallery.exe
/// ```
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/win32.dart';

import 'gallery_shell.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    exitCode = reportUnavailable('this example needs Windows',
        what: 'the Win32 backend');
    return;
  }
  try {
    final application = await runApp(
      Gallery(model: GalleryModel(), theme: galleryTheme(arguments)),
      backends: <WindowingBackendEntry>[
        const WindowingBackendEntry(
          name: 'win32',
          create: Win32WindowingBackend.new,
        ),
      ],
      presentations: <PresentationPathEntry>[
        // The window owns the pixels here, not the renderer: the canonical
        // framebuffer is the DIB section, and `Win32CpuPresenter` retains the
        // display list so a resize can replay it into the replacement surface.
        PresentationPathEntry.retainedCpu(
          name: 'win32-dib',
          deviceDescription: 'GDI DIB section, BGRA8888 top-down',
          create: (NativeWindow window) {
            final presenter = Win32CpuPresenter(window as Win32Window);
            return (
              present: presenter.renderDisplayList,
              // The synchronous path, which is what makes live resize possible:
              // see `ApplicationOptions.liveResize`.
              presentNow: presenter.renderDisplayListNow,
              release: presenter.dispose,
            );
          },
        ),
      ],
      options: galleryOptions(arguments, title: 'dart_ui gallery - Win32 CPU'),
    );
    exitCode = reportGallery(application, tag: 'WIN32_GALLERY');
  } on BackendSelectionError catch (error) {
    exitCode = reportUnavailable(error, what: 'the Win32 backend');
  }
}
