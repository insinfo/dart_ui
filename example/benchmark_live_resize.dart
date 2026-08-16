/// What live resize costs, in microseconds per `WM_SIZE`.
///
/// [ApplicationOptions.liveResize] is a trade and the whole point of making it
/// an option is that the caller gets to decide it. A decision needs a number,
/// so this measures both sides of it on a real window with a real widget tree -
/// the gallery, the same one `gallery_win32.dart` runs.
///
/// ## What is being timed, and why it is `handleMessage`
///
/// A border drag on Windows is a modal loop *inside the OS*: between
/// `WM_ENTERSIZEMOVE` and `WM_EXITSIZEMOVE`, `DispatchMessageW` does not
/// return, and the loop delivers one `WM_SIZE` per mouse movement straight to
/// the `WndProc`. The number that decides whether a drag feels smooth is
/// therefore exactly "how long does one `WM_SIZE` take to handle", which is
/// what this loop measures: the messages go into the real handler of a real
/// HWND, in the real order the modal loop sends them.
///
/// Going through `SetWindowPos` instead would measure the same framework work
/// plus a variable amount of window-manager and DWM time, which is identical in
/// both configurations and would only blur the comparison.
///
/// ```
/// dart run example/benchmark_live_resize.dart
/// dart run example/benchmark_live_resize.dart --steps 400
/// ```
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/win32.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';

import 'gallery_shell.dart';

/// One `WM_SIZE` lParam: height in the high word, width in the low word.
int _size(int width, int height) =>
    ((height & 0xFFFF) << 16) | (width & 0xFFFF);

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    exitCode = reportUnavailable('this benchmark needs Windows',
        what: 'the Win32 backend');
    return;
  }
  final steps = intArgument(arguments, '--steps') ?? 200;

  final live = await _measure(arguments, steps: steps, liveResize: true);
  final dead = await _measure(arguments, steps: steps, liveResize: false);

  stdout
    ..writeln('LIVE_RESIZE_BENCHMARK')
    ..writeln('steps=$steps tree=gallery')
    ..writeln('liveResize=on  '
        'perMessage=${live.perMessageMicroseconds}us '
        'total=${live.totalMicroseconds}us '
        'frames=${live.frames} '
        'fps=${live.framesPerSecond}')
    ..writeln('liveResize=off '
        'perMessage=${dead.perMessageMicroseconds}us '
        'total=${dead.totalMicroseconds}us '
        'frames=${dead.frames} '
        'fps=${dead.framesPerSecond}');
  if (dead.frames != 0) {
    stderr.writeln('liveResize=off drew $dead.frames frames during the drag; '
        'it is meant to draw none');
    exitCode = 1;
  }
}

final class _Measurement {
  const _Measurement({
    required this.totalMicroseconds,
    required this.steps,
    required this.frames,
  });

  final int totalMicroseconds;
  final int steps;
  final int frames;

  int get perMessageMicroseconds => totalMicroseconds ~/ steps;

  /// What the drag would run at if every message produced a frame. Meaningless
  /// when [frames] is zero, and printed as zero there rather than as infinity.
  int get framesPerSecond => frames == 0 || totalMicroseconds == 0
      ? 0
      : 1000000 ~/ (totalMicroseconds ~/ steps);
}

Future<_Measurement> _measure(
  List<String> arguments, {
  required int steps,
  required bool liveResize,
}) async {
  final base = galleryOptions(arguments, title: 'live resize benchmark');
  final application = await Application.start(
    rootWidget: Gallery(model: GalleryModel(), theme: galleryTheme(arguments)),
    backends: <WindowingBackendEntry>[
      const WindowingBackendEntry(
        name: 'win32',
        create: Win32WindowingBackend.new,
      ),
    ],
    presentations: <PresentationPathEntry>[
      PresentationPathEntry.retainedCpu(
        name: 'win32-dib',
        deviceDescription: 'GDI DIB section, BGRA8888 top-down',
        create: (NativeWindow window) {
          final presenter = Win32CpuPresenter(window as Win32Window);
          return (
            present: presenter.renderDisplayList,
            presentNow: presenter.renderDisplayListNow,
            release: presenter.dispose,
          );
        },
      ),
    ],
    options: ApplicationOptions(
      title: 'live resize benchmark',
      size: base.size,
      liveResize: liveResize,
      showDevOverlay: false,
      windowBackgroundColor: base.windowBackgroundColor,
      minimumSize: base.minimumSize,
    ),
  );

  final window = application.window as Win32Window;
  // One real frame first, so the measurement is of resizing a live tree rather
  // than of mounting one. A drag never starts from an unmounted window.
  application.window.show();
  await application.drawFrame();

  final int framesBefore = application.framesPresented;
  final ({int width, int height}) start = window.pixelSize;
  final stopwatch = Stopwatch();

  window.handleMessage(window.handle, wmEntersizemove, 0, 0);
  stopwatch.start();
  for (var step = 0; step < steps; step++) {
    // A drag that actually changes the size every message: `_onSize` returns
    // immediately when the size is unchanged, and a benchmark that measured
    // that early return would measure nothing.
    final width = start.width + (step % 40) + 1;
    final height = start.height + ((step ~/ 40) % 20) + 1;
    window.handleMessage(
      window.handle,
      wmSize,
      sizeRestored,
      _size(width, height),
    );
  }
  stopwatch.stop();
  window.handleMessage(window.handle, wmExitsizemove, 0, 0);

  final measurement = _Measurement(
    totalMicroseconds: stopwatch.elapsedMicroseconds,
    steps: steps,
    frames: application.framesPresented - framesBefore,
  );
  application.dispose();
  await application.closed;
  return measurement;
}
