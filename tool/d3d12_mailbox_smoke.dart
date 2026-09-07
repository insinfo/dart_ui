/// Proves `PresentMode.mailbox` is real on Direct3D 12, in a real window.
///
/// ## Why this cannot be a test
///
/// `test/rendering/present_mode_test.dart` holds the pacers to the refusal
/// rules with injected doubles, and it cannot say anything about this one. A
/// headless run in this repository gives a **false green** for presentation:
/// the offscreen target's surface is not a window's back buffer and there is
/// no swap chain, so "the request returned accepted" proves that a Dart method
/// returned a value. Every observable that separates mailbox from fifo -
/// `DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT` being accepted, the
/// waitable object signalling, `Present` no longer blocking - exists only on a
/// swap chain a driver created for a window that is on screen.
///
/// ## What it measures, and one thing it disproved
///
/// The obvious hypothesis - "without a waitable object the producer blocks
/// inside `Present`" - is **false on Direct3D 12**, and this tool measured it
/// false before the verdict below was written. On a flip-model swap chain
/// `Present` hands the frame over and returns in a few hundred microseconds in
/// every mode; the throttle surfaces later and elsewhere, inside the frame
/// ring's fence wait, where the application cannot see it, name it, or do
/// anything during it. So the measurement is not "did `Present` stop
/// blocking". It is **where the frame's idle time went**, over a fixed number
/// of frames of one identical scene:
///
///   * **frame interval** - the cadence. fifo and mailbox are both tear-free
///     and must both sit at the panel's refresh rate; immediate must not. A
///     mailbox run *faster* than the display would mean the sync interval was
///     dropped somewhere, which is immediate wearing mailbox's name.
///   * **the frame-latency wait** against **everything else in the frame**.
///     Under mailbox the idle time is inside one named call at the top of the
///     frame, which an application is free to spend on work instead; under
///     fifo the same idle time is inside the frame's own machinery. Same
///     cadence, and the producer's stall moved somewhere it can be used.
///
/// ## The measurement that is missing, and why
///
/// The number an application really wants is the **queue depth** - DXGI queues
/// three frames by default, `SetMaximumFrameLatency(1)` queues one, and that
/// is how far behind the mouse the picture is. `GetLastPresentCount` minus
/// `DXGI_FRAME_STATISTICS.PresentCount` looks like it, and it was implemented,
/// measured and **removed**: on a window the desktop compositor is compositing
/// - which is every window this framework opens - `PresentCount` falls behind
/// `GetLastPresentCount` monotonically, by 4 after three frames and by 56
/// after 180, because it counts presents that reached the *monitor* and the
/// compositor is between the swap chain and the monitor. The difference is
/// therefore drift plus queue depth with no way to separate them. A number
/// that cannot be interpreted is worse than no number, so this tool reports
/// none, and `SetMaximumFrameLatency(1)` is asserted from the API contract
/// rather than measured here. Measuring it needs a photodiode or a
/// full-screen-exclusive swap chain, and this framework has neither.
///
/// The tool also **resizes the window while mailbox is in force** and measures
/// again. `ResizeBuffers` must be given the waitable flag back; a call that
/// passes `0` returns `S_OK` and leaves the waitable object dead, so the wait
/// then runs to its full timeout on every frame. That is the bug this feature
/// ships with by default, and a run where the post-resize wait jumps to
/// hundreds of milliseconds is that bug, caught.
///
/// ```
/// dart run tool/d3d12_mailbox_smoke.dart
/// ```
///
/// Options: `--frames=240`, `--width=`, `--height=`.
///
/// Exit codes follow `tool/present_mode_smoke.dart`: 0 when mailbox was
/// honoured and behaved, 1 when something measured contradicts the
/// implementation, 2 when this machine cannot host the run at all - no
/// Windows, no Direct3D 12, no window. A refusal of the waitable flag by the
/// driver is **not** a failure of this tool: it is reported by name, with the
/// fallback the target chose, and exits 2.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_window_target.dart';

const int _defaultFrames = 240;
const double _defaultWidth = 900;
const double _defaultHeight = 560;
const int _clearColor = 0xFF10141B;

/// Frames dropped from the front of every measurement.
///
/// The first present after a swap chain is created or resized is not paced by
/// anything yet - the queue is empty, so it returns immediately and would
/// otherwise pull the median of a short run towards zero and make fifo look
/// like mailbox.
const int _warmup = 12;

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    stderr.writeln(
        'D3D12_MAILBOX=SKIP platform=${Platform.operatingSystem} reason=DXGI '
        'is the only API here that can express mailbox outside Vulkan');
    exitCode = 2;
    return;
  }

  final int frames = _intOption(arguments, '--frames=') ?? _defaultFrames;
  final double width =
      _intOption(arguments, '--width=')?.toDouble() ?? _defaultWidth;
  final double height =
      _intOption(arguments, '--height=')?.toDouble() ?? _defaultHeight;

  final errors = <FrameworkError>[];
  final diagnostics = <BackendDiagnostic>[];

  final Application app;
  try {
    app = await Application.start(
      rootWidget: const ColoredBox(color: Color(_clearColor)),
      backends: PlatformBackendResolver.defaultBackends(),
      presentations: PlatformBackendResolver.defaultPresentations(),
      options: ApplicationOptions(
        title: 'dart_ui Direct3D 12 mailbox smoke',
        size: Size(width, height),
        // Shown, never hidden. DXGI is entitled to answer a present for an
        // invisible window with DXGI_STATUS_OCCLUDED and to stop signalling
        // the frame-latency object entirely, and a run that measured that
        // would report mailbox as a 1000 ms stall per frame.
        visible: true,
        // gpuOnly, so a machine whose Direct3D 12 probe fails is a loud
        // failure instead of a CPU frame that would prove nothing about a
        // swap chain.
        renderingPolicy: RenderingPolicy.gpuOnly,
        requestedPresentation: 'direct3d12',
        // Without this a paint or present failure closes the window with exit
        // 0 and nothing on stderr - the memory rule this whole file exists to
        // obey.
        onError: errors.add,
        onDiagnostic: diagnostics.add,
      ),
    );
  } on Object catch (error) {
    stderr.writeln('D3D12_MAILBOX=SKIP reason=the application would not '
        'start: $error');
    exitCode = 2;
    return;
  }

  var ok = true;
  try {
    // The framework's own loop first, through every layer an application uses.
    // If this does not present, nothing measured below means anything.
    await app.run(frameBudget: 20);
    stdout.writeln('APP presentation=${app.presentationSelection.chosen?.name} '
        'frames=${app.framesPresented} errors=${errors.length}');
    if (app.presentationSelection.chosen?.name != 'direct3d12') {
      stderr.writeln('D3D12_MAILBOX=SKIP reason=selection chose '
          '${app.presentationSelection.chosen?.name}, not direct3d12');
      exitCode = 2;
      return;
    }

    final SurfacePresenter presenter = app.host.presenter;
    if (presenter is! RenderTargetPresenter) {
      stderr.writeln('D3D12_MAILBOX=SKIP reason=${presenter.runtimeType} owns '
          'no RenderTarget');
      exitCode = 2;
      return;
    }
    final RenderTarget raw = presenter.target;
    if (raw is! D3d12WindowTarget) {
      stderr.writeln('D3D12_MAILBOX=SKIP reason=${raw.runtimeType} is not a '
          'D3d12WindowTarget');
      exitCode = 2;
      return;
    }

    // The type test `present_mode.dart` prescribes, applied through the erased
    // type an owner really holds so the check is the runtime one rather than a
    // tautology the analyser folds away.
    final RenderTarget erased = raw;
    if (erased is! PresentPacer) {
      stderr.writeln('D3D12_MAILBOX=FAIL the Direct3D 12 window target is not '
          'a PresentPacer, so no application can ask it for a mode');
      exitCode = 1;
      return;
    }
    final PresentPacer pacer = erased as PresentPacer;

    final int pixelWidth = raw.surface.pixelWidth;
    final int pixelHeight = raw.surface.pixelHeight;
    stdout.writeln('TARGET ${pixelWidth}x$pixelHeight '
        'buffers=${raw.bufferCount} flags=0x'
        '${raw.swapChainFlags.toRadixString(16)} '
        'mode=${pacer.presentMode.name} '
        'supported=${_names(pacer.supportedPresentModes)}');

    final DisplayList scene =
        _scene(pixelWidth.toDouble(), pixelHeight.toDouble());

    final results = <PresentMode, _Run>{};
    for (final PresentMode mode in PresentMode.values) {
      final PresentModeOutcome outcome = pacer.requestPresentMode(mode);
      stdout.writeln('REQUEST ${mode.name}: $outcome');
      if (outcome.diagnostic case final BackendDiagnostic diagnostic) {
        stdout.writeln('  ${diagnostic.message}');
        if (diagnostic.detail case final String detail) {
          stdout.writeln('  $detail');
        }
      }
      if (!outcome.accepted) {
        if (mode == PresentMode.mailbox) {
          stderr.writeln('D3D12_MAILBOX=SKIP reason=this adapter refused the '
              'frame-latency waitable object; the target fell back to '
              '${outcome.applied.name} by name, which is the contract');
          exitCode = 2;
          return;
        }
        stderr.writeln('D3D12_MAILBOX=FAIL ${mode.name} was refused and this '
            'backend can do it');
        ok = false;
        continue;
      }
      if (mode == PresentMode.mailbox && !raw.hasFrameLatencyWaitableObject) {
        stderr.writeln('D3D12_MAILBOX=FAIL mailbox was accepted with no '
            'waitable object, so nothing is pacing the producer');
        ok = false;
      }
      final _Run run = await _measure(app, raw, scene, frames);
      results[mode] = run;
      stdout.writeln('  ${run.describe(mode.name)}');
      stdout.writeln('  buffers=${raw.bufferCount} flags=0x'
          '${raw.swapChainFlags.toRadixString(16)} '
          'waitable=${raw.hasFrameLatencyWaitableObject}');
    }

    // The resize, with mailbox still in force. This is the half that catches
    // a `ResizeBuffers` that dropped the flag.
    final PresentModeOutcome again =
        pacer.requestPresentMode(PresentMode.mailbox);
    if (!again.accepted) {
      stderr.writeln('D3D12_MAILBOX=FAIL mailbox could not be re-entered: '
          '$again');
      exitCode = 1;
      return;
    }
    final int resizedWidth = pixelWidth - 60;
    final int resizedHeight = pixelHeight - 40;
    raw.resize(resizedWidth, resizedHeight, raw.surface.scale);
    stdout.writeln('RESIZE ${resizedWidth}x$resizedHeight '
        'buffers=${raw.bufferCount} flags=0x'
        '${raw.swapChainFlags.toRadixString(16)} '
        'waitable=${raw.hasFrameLatencyWaitableObject} '
        'mode=${pacer.presentMode.name}');
    if (!raw.hasFrameLatencyWaitableObject ||
        raw.swapChainFlags == 0 ||
        pacer.presentMode != PresentMode.mailbox) {
      stderr.writeln('D3D12_MAILBOX=FAIL ResizeBuffers dropped the waitable '
          'flag, which is the bug this mode always ships with');
      ok = false;
    }
    final DisplayList resizedScene =
        _scene(resizedWidth.toDouble(), resizedHeight.toDouble());
    final _Run afterResize = await _measure(app, raw, resizedScene, frames);
    stdout.writeln('  ${afterResize.describe('mailbox-after-resize')}');
    // A dead waitable object does not fail: it runs to the wait's full
    // timeout, every frame. Anything past a slow panel's refresh is that.
    if (afterResize.medianWaitUs > 100000) {
      stderr.writeln('D3D12_MAILBOX=FAIL the frame-latency wait after the '
          'resize is ${_ms(afterResize.medianWaitUs)}ms, which is a waitable '
          'object that stopped signalling rather than a display');
      ok = false;
    }

    ok = _verdict(results, afterResize, errors, ok);
  } finally {
    for (final FrameworkError error in errors) {
      stderr.writeln('  error: $error');
    }
    app.dispose();
    await app.closed;
  }
  exitCode = ok ? 0 : 1;
}

/// Compares the modes against one another rather than against a constant.
///
/// No absolute frame time is asserted anywhere: the panel decides the cadence
/// and this machine's is not the next machine's. What is asserted is the
/// *relation* the implementation claims, which is portable.
bool _verdict(
  Map<PresentMode, _Run> results,
  _Run afterResize,
  List<FrameworkError> errors,
  bool soFar,
) {
  final _Run? fifo = results[PresentMode.fifo];
  final _Run? mailbox = results[PresentMode.mailbox];
  final _Run? immediate = results[PresentMode.immediate];
  if (fifo == null || mailbox == null || immediate == null) {
    stderr.writeln('D3D12_MAILBOX=FAIL a mode produced no measurement');
    return false;
  }
  // Seeded with what the caller already found, so the banner at the bottom
  // of the output is the verdict of the whole run and not of this function.
  var ok = soFar;

  // 1. The producer's stall moved into the named wait. Under fifo the frame's
  //    idle time is inside the frame's own machinery with no way to use it;
  //    under mailbox most of the frame is the wait, and the rest of the frame
  //    is short. Half is a wide margin on purpose: this is a claim about where
  //    a stall is, not a throughput number, and it must not fail on a busy
  //    machine.
  if (mailbox.medianWaitUs < mailbox.medianFrameUs ~/ 2) {
    stderr.writeln('D3D12_MAILBOX=FAIL the frame-latency wait is only '
        '${_ms(mailbox.medianWaitUs)}ms of a ${_ms(mailbox.medianFrameUs)}ms '
        'frame, so the producer is being paced by something other than the '
        'waitable object');
    ok = false;
  }
  if (mailbox.medianWorkUs >= fifo.medianWorkUs) {
    stderr.writeln('D3D12_MAILBOX=FAIL the frame outside the wait costs '
        '${_ms(mailbox.medianWorkUs)}ms under mailbox against '
        '${_ms(fifo.medianWorkUs)}ms under fifo, so the stall did not move '
        'into the wait - it is still buried in the frame');
    ok = false;
  }

  // 2. Mailbox is tear-free, so it is still paced by the display. A mailbox
  //    run substantially faster than fifo would be immediate under another
  //    name, which is the standard way this feature is mis-implemented.
  if (mailbox.medianFrameUs < fifo.medianFrameUs * 0.7) {
    stderr.writeln('D3D12_MAILBOX=FAIL mailbox ran at '
        '${_fps(mailbox.medianFrameUs)} fps against fifo\'s '
        '${_fps(fifo.medianFrameUs)}, which is a dropped sync interval rather '
        'than mailbox');
    ok = false;
  }

  // 3. Immediate must actually be unpaced, or the run proves nothing about
  //    what pacing looks like on this machine.
  if (immediate.medianFrameUs >= fifo.medianFrameUs * 0.7) {
    stderr.writeln('D3D12_MAILBOX=WARN immediate ran at '
        '${_fps(immediate.medianFrameUs)} fps against fifo\'s '
        '${_fps(fifo.medianFrameUs)}: this scene is GPU-bound below the '
        'refresh rate, so the cadence comparison above is weak evidence');
  }

  if (errors.isNotEmpty) {
    stderr.writeln('D3D12_MAILBOX=FAIL ${errors.length} framework errors');
    ok = false;
  }

  stdout
    ..writeln('')
    ..writeln('| mode | fps | frame | latency wait | rest of frame | Present |')
    ..writeln('|---|---|---|---|---|---|');
  for (final MapEntry<PresentMode, _Run> entry in results.entries) {
    stdout.writeln(entry.value.row(entry.key.name));
  }
  stdout
    ..writeln(afterResize.row('mailbox-after-resize'))
    ..writeln('')
    ..writeln('D3D12_MAILBOX=${ok ? 'PASS' : 'FAIL'}');
  return ok;
}

// ---------------------------------------------------------------------------
// Measuring
// ---------------------------------------------------------------------------

final class _Run {
  _Run(this.frameUs, this.presentUs, this.waitUs, this.notPresented);

  final List<int> frameUs;
  final List<int> presentUs;
  final List<int> waitUs;

  final int notPresented;

  int get medianFrameUs => _median(frameUs);
  int get medianPresentUs => _median(presentUs);
  int get medianWaitUs => _median(waitUs);

  /// The frame minus the frame-latency wait: everything the producer spent on
  /// the frame itself, including whatever it blocked on that was not the
  /// explicit wait.
  int get medianWorkUs => _median(<int>[
        for (var i = 0; i < frameUs.length; i++)
          frameUs[i] - waitUs[i] < 0 ? 0 : frameUs[i] - waitUs[i],
      ]);

  String describe(String name) => '$name: ${_fps(medianFrameUs)} fps, '
      'frame ${_ms(medianFrameUs)}ms (p95 ${_ms(_p95(frameUs))}ms), '
      'latency wait ${_ms(medianWaitUs)}ms, '
      'rest of frame ${_ms(medianWorkUs)}ms, '
      'Present ${_ms(medianPresentUs)}ms, '
      'frames=${frameUs.length} notPresented=$notPresented';

  String row(String name) => '| $name | ${_fps(medianFrameUs)} | '
      '${_ms(medianFrameUs)} ms | ${_ms(medianWaitUs)} ms | '
      '${_ms(medianWorkUs)} ms | ${_ms(medianPresentUs)} ms |';
}

Future<_Run> _measure(
  Application app,
  D3d12WindowTarget target,
  DisplayList scene,
  int frames,
) async {
  final frameUs = <int>[];
  final presentUs = <int>[];
  final waitUs = <int>[];
  var notPresented = 0;
  final clock = Stopwatch()..start();
  for (var i = 0; i < frames + _warmup; i++) {
    final int start = clock.elapsedMicroseconds;
    final PresentResult result =
        await target.renderDisplayList(scene, clearColor: _clearColor);
    final int elapsed = clock.elapsedMicroseconds - start;
    if (i < _warmup) continue;
    if (result.status != PresentStatus.presented) notPresented++;
    frameUs.add(elapsed);
    presentUs.add(target.presentMicroseconds);
    waitUs.add(target.frameLatencyWaitMicroseconds);
    // The window still has a message queue and a user watching it. Zero
    // timeout, so this costs the measurement nothing it would not have paid
    // anyway - a window that stops answering is a window the compositor stops
    // presenting, which would corrupt every number here.
    app.backend.pumpEvents(timeout: Duration.zero);
  }
  return _Run(frameUs, presentUs, waitUs, notPresented);
}

// ---------------------------------------------------------------------------
// The scene
// ---------------------------------------------------------------------------

/// One scene, drawn identically in every mode.
///
/// Deliberately cheap: this file measures *pacing*, and a scene heavy enough
/// to be GPU-bound below the refresh rate would hide the very difference it is
/// looking for behind the GPU's own cost.
DisplayList _scene(double width, double height) {
  final list = DisplayList();
  const int columns = 24;
  const int rows = 14;
  final double cellW = width / columns;
  final double cellH = height / rows;
  final paints = <int>[
    for (var i = 0; i < 6; i++)
      list.addPaint(colorArgb: _palette(i), antiAlias: false),
  ];
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < columns; x++) {
      list.drawRect(
        x * cellW + 2,
        y * cellH + 2,
        x * cellW + cellW - 2,
        y * cellH + cellH - 2,
        paints[(x + y) % 6],
      );
    }
  }
  return list;
}

int _palette(int index) => const <int>[
      0xFF4C8DFF,
      0xFF37C2A6,
      0xFFF2B441,
      0xFFE2604F,
      0xFF9B6BD6,
      0xFF6FCF6A,
    ][index % 6];

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

int _median(List<int> values) {
  if (values.isEmpty) return 0;
  final sorted = List<int>.of(values)..sort();
  return sorted[sorted.length ~/ 2];
}

int _p95(List<int> values) {
  if (values.isEmpty) return 0;
  final sorted = List<int>.of(values)..sort();
  final int index = ((sorted.length - 1) * 95) ~/ 100;
  return sorted[index];
}

String _ms(int microseconds) => (microseconds / 1000).toStringAsFixed(2);

String _fps(int microseconds) =>
    microseconds == 0 ? 'inf' : (1000000 / microseconds).toStringAsFixed(1);

String _names(Set<PresentMode> modes) =>
    modes.map((PresentMode mode) => mode.name).join(',');

int? _intOption(List<String> arguments, String prefix) {
  for (final String argument in arguments) {
    if (argument.startsWith(prefix)) {
      return int.tryParse(argument.substring(prefix.length));
    }
  }
  return null;
}
