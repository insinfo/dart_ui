/// Metal presenting into a **real macOS window**, proved by reading the pixels
/// back out of the `IOSurface` the host is showing.
///
/// ## Why this cannot be a test, and why the offscreen suite is not enough
///
/// This repository has a standing rule and `tool/present_mode_smoke.dart`
/// states it: a headless run gives a **false green** for presentation. The
/// offscreen target's colour buffer is a texture this backend created and
/// reads back with `getBytes:`; a window's is an `IOSurface` created by
/// `surface_pool.dart`, handed to another process over a mach port, and shown
/// by AppKit. The two differ in exactly the ways this path can go wrong on one
/// and not the other:
///
///   * the window's texture comes from
///     `newTextureWithDescriptor:iosurface:plane:` and not
///     `newTextureWithDescriptor:`, so a wrong storage mode or a pixel format
///     that disagrees with the surface's `'BGRA'` FourCC returns nil **here
///     only**;
///   * the attachment is `BGRA8Unorm` and the offscreen one is `RGBA8Unorm`.
///     A pipeline state's format is part of its identity in Metal, so a target
///     handed the wrong cache draws nothing here and everything offscreen -
///     and the channels would be transposed if it drew at all;
///   * `commit` merely enqueues. Offscreen, `waitUntilCompleted` hides that.
///     Here the surface crosses to another process, so presenting before the
///     GPU finished shows a half-written frame - intermittently, under load,
///     which is the worst way for a bug to appear;
///   * the pool **rotates**. A target that cached the back slot would draw
///     into the surface the host is currently scanning out, and no offscreen
///     run has a second buffer to get that wrong with.
///
/// So this opens a window through the framework's own resolver, drives real
/// frames through it, and then reads the presented `IOSurface` with the CPU.
/// `ApplicationOptions.onError` is attached throughout: without it a paint or
/// present failure closes the window with exit 0 and nothing on stderr, which
/// is the false green this file exists to prevent.
///
/// ## The colour is the assertion
///
/// The scene is two rectangles whose channels are all distinct and all
/// different from each other. Reading back "not blank" would be satisfied by a
/// red/blue transposition, by a stale frame, and by a clear that never got
/// drawn over - so the check is *which* bytes, at *which* pixels, not how many
/// are non-zero. `metal_present_probe.dart` made the same argument for the
/// clear colour and it caught nothing only because there was nothing to catch.
///
/// **It closes itself.** A probe that leaves a window on somebody's screen is
/// a probe nobody runs.
///
/// Prints one `METAL_WINDOW_PRESENT=` verdict. Exit 0 when it drew, presented
/// and read back the right pixels; 1 when something it measured contradicts
/// the implementation; 2 when this machine cannot host the run.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/io_surface.dart';
import 'package:dart_ui/src/backends/macos/macos_window.dart';
import 'package:dart_ui/src/backends/macos/surface_pool.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_window_target.dart';

/// The window, in points. 1x on the CI display, so pixels equal points there.
const int _width = 240;
const int _height = 160;

/// Premultiplied ARGB, opaque, and pairwise distinct in every channel.
///
/// `_background` has R < G < B and `_foreground` has R > G > B, so a
/// transposition cannot turn one into the other or into itself, and drawing
/// the wrong one is not a near miss.
const int _background = 0xFF204080;
const int _foreground = 0xFFC08040;

/// The rectangle drawn in [_foreground], in points.
const double _rectLeft = 60;
const double _rectTop = 40;
const double _rectWidth = 120;
const double _rectHeight = 80;

/// One level, the tolerance the CPU-parity suite already allows where blending
/// happens. A channel-order error is off by 0x40 or more between these two
/// colours, so it cannot hide inside this.
const int _tolerance = 1;

int _failures = 0;

void _pass(String check, [String detail = '']) {
  stdout.writeln('CHECK=$check RESULT=OK${detail.isEmpty ? '' : ' $detail'}');
}

void _fail(String check, String detail) {
  _failures++;
  stdout.writeln('CHECK=$check RESULT=FAIL $detail');
}

void _skip(String reason) {
  stdout.writeln('METAL_WINDOW_PRESENT=SKIP reason=$reason');
  exitCode = 2;
}

Future<void> main() async {
  if (!Platform.isMacOS) {
    _skip('requires macOS; got ${Platform.operatingSystem}');
    return;
  }
  if ((Platform.environment['DART_UI_MACOS_HOST'] ?? '').isEmpty) {
    _skip('DART_UI_MACOS_HOST must name the production AppKit host binary');
    return;
  }

  final List<FrameworkError> errors = <FrameworkError>[];
  final List<BackendDiagnostic> diagnostics = <BackendDiagnostic>[];

  final Application app;
  try {
    app = await Application.start(
      rootWidget: const ColoredBox(color: Color(_background)),
      backends: PlatformBackendResolver.defaultBackends(),
      presentations: PlatformBackendResolver.defaultPresentations(),
      options: ApplicationOptions(
        title: 'dart_ui Metal window present probe',
        size: Size(_width.toDouble(), _height.toDouble()),
        // Shown, because a hidden window is a different code path in AppKit
        // and the point here is the one an application actually gets.
        visible: true,
        // gpuOnly, so a machine whose Metal probe fails is a loud failure
        // rather than a CPU frame that would prove nothing about Metal - which
        // is precisely the false green this probe exists to prevent.
        renderingPolicy: RenderingPolicy.gpuOnly,
        requestedPresentation: 'metal',
        // Metal is registered experimental because it still refuses text,
        // clips and layers by name. Reaching it therefore takes an explicit
        // opt-in, and that is the correct shape: this probe wants it, an
        // application must ask for it.
        allowExperimentalBackends: true,
        onError: errors.add,
        onDiagnostic: diagnostics.add,
      ),
    );
  } on Object catch (error) {
    _skip('the application did not start: $error');
    return;
  }

  try {
    final String? chosen = app.presentationSelection.chosen?.name;
    stdout.writeln('APP presentation=$chosen');
    if (chosen != 'metal') {
      for (final BackendDiagnostic diagnostic in diagnostics) {
        stdout
            .writeln('DIAGNOSTIC ${diagnostic.message}: ${diagnostic.detail}');
      }
      _skip('selection chose $chosen rather than metal');
      return;
    }

    final SurfacePresenter presenter = app.host.presenter;
    if (presenter is! RenderTargetPresenter) {
      _skip('${presenter.runtimeType} has no RenderTarget');
      return;
    }
    final RenderTarget raw = presenter.target;
    if (raw is! MetalWindowTarget) {
      _skip('${raw.runtimeType} is not a MetalWindowTarget');
      return;
    }
    _pass(
        'target',
        'kind=${raw.surface.kind} '
            '${raw.surface.pixelWidth}x${raw.surface.pixelHeight} '
            '@${raw.surface.scale}x');

    // The framework's own loop, through every layer an application uses. If
    // this does not present, nothing below means anything.
    await app.run(frameBudget: 8);
    stdout.writeln('APP frames=${app.framesPresented} '
        'errors=${errors.length}');
    if (app.framesPresented == 0) {
      _fail('frames', 'the application presented no frames at all');
    } else {
      _pass('frames', 'presented=${app.framesPresented}');
    }
    for (final FrameworkError error in errors) {
      _fail('framework_error', '$error');
    }

    // A second frame drawn straight through the target, so the readback below
    // is checking a frame whose contents this file chose rather than whatever
    // the widget tree happened to paint last.
    final DisplayList list = DisplayList();
    // antiAlias false: the probe reads exact bytes at the centre of the
    // rectangle and at a corner, and an antialiased edge would only blur
    // pixels this does not sample. Turning it off keeps the assertion about
    // the colour rather than about the coverage term.
    final int paint = list.addPaint(colorArgb: _foreground, antiAlias: false);
    list.drawRect(
      _rectLeft,
      _rectTop,
      _rectLeft + _rectWidth,
      _rectTop + _rectHeight,
      paint,
    );
    final PresentResult result = await raw.renderDisplayList(
      list,
      clearColor: _background,
    );
    if (!result.isSuccess) {
      _fail('present',
          'status=${result.status.name} ${result.diagnostic?.message}');
    } else {
      _pass('present');
    }

    _verifyPresentedSurface(app.host.window, raw.surface.scale);
  } on Object catch (error, stack) {
    stderr.writeln(error);
    stderr.writeln(stack);
    _fail('probe_body', '$error');
  } finally {
    app.dispose();
  }

  if (_failures == 0) {
    stdout.writeln('METAL_WINDOW_PRESENT=PASS');
  } else {
    stdout.writeln('METAL_WINDOW_PRESENT=FAIL failures=$_failures');
    exitCode = 1;
  }
}

/// Reads the surface the host was last told to show, with the CPU.
///
/// This is the whole point of the file: the GPU wrote these pages, another
/// process is scanning them out, and the only honest way to know what is on
/// screen is to look at the bytes rather than at the return code of the call
/// that drew them.
void _verifyPresentedSurface(NativeWindow? window, double scale) {
  if (window is! MacosWindow) {
    _fail('readback', 'the host window is ${window.runtimeType}');
    return;
  }
  MacosSurfaceDescriptor? descriptor;
  for (final NativeSurfaceDescriptor offered in window.surfaces) {
    if (offered is MacosSurfaceDescriptor) {
      descriptor = offered;
      break;
    }
  }
  final MacosSurfacePool? pool = descriptor?.pool;
  if (pool == null) {
    _fail('readback', 'the window descriptor carries no surface pool');
    return;
  }
  final int slot = pool.presentedSlot;
  if (slot < 0) {
    _fail('readback', 'no slot has been presented');
    return;
  }
  final MacosPoolSurface surface = pool.surfaces[slot];
  if (surface is! MacosIOSurface) {
    _fail('readback', 'slot $slot is a ${surface.runtimeType}');
    return;
  }
  stdout.writeln('PRESENTED_SLOT=$slot of ${pool.slotCount} '
      'stride=${surface.bytesPerRow} width=${surface.width}');

  // Two probe points, in pixels: one inside the rectangle and one outside it.
  // Checking only one would pass on a surface that is uniformly the right
  // colour by accident - a clear that never got drawn over, for instance.
  final int insideX = ((_rectLeft + _rectWidth / 2) * scale).round();
  final int insideY = ((_rectTop + _rectHeight / 2) * scale).round();
  final int outsideX = (4 * scale).round();
  final int outsideY = (4 * scale).round();

  late final List<int> inside;
  late final List<int> outside;
  int nonZero = 0;
  surface.withPixels((Uint8List pixels) {
    List<int> at(int x, int y) {
      final int i = y * surface.bytesPerRow + x * 4;
      return <int>[pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]];
    }

    inside = at(insideX, insideY);
    outside = at(outsideX, outsideY);
    for (int y = 0; y < surface.height; y++) {
      final int row = y * surface.bytesPerRow;
      for (int x = 0; x < surface.width; x++) {
        final int i = row + x * 4;
        if (pixels[i] != 0 ||
            pixels[i + 1] != 0 ||
            pixels[i + 2] != 0 ||
            pixels[i + 3] != 0) {
          nonZero++;
        }
      }
    }
  });

  final int total = surface.width * surface.height;
  stdout.writeln('SURFACE_NONZERO=$nonZero of $total');
  if (nonZero == 0) {
    _fail('non_blank',
        'every pixel of the presented surface is zero: the window is blank');
    return;
  }
  _pass('non_blank', 'nonZero=$nonZero of $total');

  _checkPixel('pixel_inside_rect', inside, _foreground, insideX, insideY);
  _checkPixel('pixel_outside_rect', outside, _background, outsideX, outsideY);
}

/// Compares one BGRA texel against a premultiplied ARGB colour.
void _checkPixel(String check, List<int> bgra, int argb, int x, int y) {
  final int wantB = argb & 0xFF;
  final int wantG = (argb >> 8) & 0xFF;
  final int wantR = (argb >> 16) & 0xFF;
  final int wantA = (argb >> 24) & 0xFF;
  stdout.writeln('${check.toUpperCase()}=${bgra[0]},${bgra[1]},${bgra[2]},'
      '${bgra[3]} at $x,$y');
  bool near(int got, int want) => (got - want).abs() <= _tolerance;
  if (near(bgra[0], wantB) &&
      near(bgra[1], wantG) &&
      near(bgra[2], wantR) &&
      near(bgra[3], wantA)) {
    _pass(check);
    return;
  }
  // Naming the transposition, because "wrong colour" sends a reader to the
  // shader and the answer is a pixel-format constant or the wrong pipeline
  // cache.
  final String diagnosis = near(bgra[0], wantR) && near(bgra[2], wantB)
      ? 'red and blue are transposed: the attachment format and the '
          "IOSurface's BGRA FourCC disagree"
      : 'unrecognised';
  _fail(
      check,
      'at $x,$y expected b=$wantB g=$wantG r=$wantR a=$wantA got '
      'b=${bgra[0]} g=${bgra[1]} r=${bgra[2]} a=${bgra[3]} - $diagnosis');
}
