/// How fast each GPU presentation path *draws*, as opposed to how fast it
/// opens a window.
///
/// ## Why this file exists
///
/// A set of popup-window **open** timings was read as a speed ranking:
///
/// ```
/// direct2d 6.46 ms, direct3d11 7.29 ms, direct3d12 14.28 ms, opengl 38.56 ms
/// ```
///
/// Those are one-time window and device creation costs. They say nothing about
/// throughput, and nothing in this repository measured throughput: `benchmark/`
/// is CPU-side, and every `tool/*_smoke.dart` is functional rather than
/// comparative - their frame counters all read exactly `60.0 fps` because they
/// are vsync-capped, which proves presentation happens and measures no
/// headroom at all. `tool/present_mode_smoke.dart` is the one exception and it
/// only ever unthrottled the GL path.
///
/// This file replays **one scene, byte for byte, the same number of times** on
/// every path, with vsync turned off wherever the framework exposes a way to
/// turn it off, and reports each scene separately.
///
/// ## What the numbers are worth
///
/// **One machine, one GPU, one driver.** These runs were developed against
/// Windows 11 on Intel UHD integrated graphics. A discrete GPU has a different
/// balance between fill rate, upload bandwidth and driver submission cost and
/// could reorder every row of the table. Nothing here generalises past the
/// machine it ran on, and the output repeats that.
///
/// **No single winner is computed, on purpose.** A path can win on filled
/// rectangles and lose badly on text, because text is the glyph atlas and
/// fills are the rasteriser. Averaging those into one score is how a benchmark
/// misleads, so this prints a table and refuses to reduce it.
///
/// **A fast path that drew less is not a fast path.** Every frame is wrapped:
/// a throw (`UnsupportedCapabilityError` is the expected one - Vulkan has no
/// glyph atlas and refuses text by name) is printed as `REFUSED` instead of a
/// number, non-`presented` results are counted, and every path also runs a
/// `clear` control scene with zero primitives. A scene whose frame time is
/// indistinguishable from `clear` did not draw, whatever it returned.
///
/// **Vsync is checked, not assumed.** A clear-only frame is thousands of
/// frames per second on any GPU when it is not paced, so a path whose control
/// scene lands near the refresh rate is reported `VSYNC-CAPPED` and its rows
/// are a floor, not a throughput measurement.
///
/// ```
/// dart run tool/render_throughput_bench.dart
/// dart compile exe tool/render_throughput_bench.dart -o build/rtb.exe
/// ```
///
/// Options: `--paths=direct3d11,opengl`, `--frames=300`, `--budget-ms=1200`,
/// `--warmup=20`, `--font=path/to.ttf`, `--width=`, `--height=`.
///
/// Exit codes follow the convention of `tool/present_mode_smoke.dart`: 0 when
/// every path that should run did run, 1 when one failed, 2 when the platform
/// cannot host the benchmark at all.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_window_target.dart';
import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_window_target.dart';

/// The paths compared, in the order the resolver registers them.
///
/// `vulkan` is last and is `experimental: true` in
/// `PlatformBackendResolver.defaultPresentations`. It is included so its
/// refusals are on the record rather than assumed.
const List<String> _defaultPaths = <String>[
  'direct3d11',
  'direct2d',
  'direct3d12',
  'opengl',
  'vulkan',
];

/// Logical window size. The scene is built at the resulting **pixel** size, and
/// a path whose surface came out a different size is reported and excluded,
/// because a comparison across two viewport sizes is not a comparison.
const double _logicalWidth = 960;
const double _logicalHeight = 540;

/// Frames per scene, and the wall-clock ceiling that stops a vsync-capped path
/// from spending five seconds per scene. Whichever comes first wins, and both
/// the frame count and the duration are printed so the arithmetic is checkable.
const int _defaultFrames = 300;
const int _defaultBudgetMs = 1200;
const int _defaultWarmup = 20;

/// Above this, a path is doing more than waiting for the display.
///
/// A clear-only present is thousands of frames per second unpaced even on
/// integrated graphics, so the threshold does not need to be near a refresh
/// rate to separate the two cases; it needs to be far from both.
const double _vsyncCeilingFps = 120;

const int _clearColor = 0xFF14181F;

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    stderr.writeln('RENDER_THROUGHPUT=SKIP platform=${Platform.operatingSystem}'
        ' reason=the paths compared here are Windows-only');
    exitCode = 2;
    return;
  }

  final _Options options;
  try {
    options = _Options.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln('RENDER_THROUGHPUT=SKIP reason=${error.message}');
    exitCode = 2;
    return;
  }

  _header(options);

  final backend = Win32WindowingBackend();
  try {
    await backend.initialize();
  } on Object catch (error) {
    stderr.writeln('RENDER_THROUGHPUT=SKIP reason=win32 backend would not '
        'initialize: $error');
    exitCode = 2;
    return;
  }

  final Map<String, PresentationPathEntry> registry =
      <String, PresentationPathEntry>{
    for (final PresentationPathEntry entry
        in PlatformBackendResolver.defaultPresentations())
      entry.name: entry,
  };
  stdout.writeln('REGISTERED paths=${registry.keys.join(',')}');

  final ScaledTypeface? font = _loadFont(options.fontPath);
  if (font == null) {
    stdout.writeln('FONT=MISSING the text scenes will be skipped; pass '
        '--font=<file.ttf> or run from the repository root');
  } else {
    stdout.writeln('FONT=${font.typeface} size=${options.fontSize}px');
  }

  final results = <_PathResult>[];
  var failed = false;
  List<_Scene>? scenes;
  int? sceneWidth;
  int? sceneHeight;

  for (final String name in options.paths) {
    final PresentationPathEntry? entry = registry[name];
    if (entry == null) {
      stdout.writeln('PATH=$name SKIP reason=not registered on this platform');
      continue;
    }

    final _Attachment? attached = await _attach(backend, entry, options);
    if (attached == null) {
      // `attach` already printed the reason. An experimental path that cannot
      // run is data; a path the resolver would hand a real application by
      // fallback failing to run is a failure of this build.
      if (!entry.experimental) failed = true;
      continue;
    }

    final NativeSurfaceDescriptor surface = attached.target.surface;
    scenes ??= _buildScenes(
      surface.pixelWidth,
      surface.pixelHeight,
      font,
      options,
    );
    sceneWidth ??= surface.pixelWidth;
    sceneHeight ??= surface.pixelHeight;

    if (surface.pixelWidth != sceneWidth ||
        surface.pixelHeight != sceneHeight) {
      stdout.writeln('PATH=$name SKIP reason=surface is '
          '${surface.pixelWidth}x${surface.pixelHeight} but the scene was '
          'built for ${sceneWidth}x$sceneHeight, and two viewport sizes are '
          'not a comparison');
      await attached.dispose();
      failed = true;
      continue;
    }

    final _PathResult result = await _runPath(
      backend: backend,
      name: name,
      attachment: attached,
      scenes: scenes,
      options: options,
    );
    results.add(result);
    await attached.dispose();
    // Between paths, so a window that is going away has drained its messages
    // before the next one opens over the same desktop.
    for (var i = 0; i < 8; i++) {
      backend.pumpEvents(timeout: const Duration(milliseconds: 4));
    }
  }

  await backend.shutdown();

  if (scenes == null || results.isEmpty) {
    stderr.writeln('RENDER_THROUGHPUT=FAIL no path produced a measurement');
    exitCode = 1;
    return;
  }

  _report(results, scenes, sceneWidth!, sceneHeight!, options);

  for (final _PathResult result in results) {
    if (result.scenes.values.every((_SceneResult r) => r.refusal != null)) {
      stdout.writeln('PATH=${result.name} FAIL every scene was refused');
      failed = true;
    }
  }

  stdout.writeln('RENDER_THROUGHPUT=${failed ? 'FAIL' : 'PASS'} '
      'paths=${results.length} scenes=${scenes.length}');
  exitCode = failed ? 1 : 0;
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

void _header(_Options options) {
  stdout
    ..writeln('RENDER_THROUGHPUT_BENCH')
    ..writeln('MACHINE os=${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion} '
        'cores=${Platform.numberOfProcessors} dart=${Platform.version}')
    ..writeln('CAVEAT one machine, one GPU, one driver. These numbers rank '
        'nothing beyond this desktop; a discrete GPU can reorder them '
        'entirely.')
    ..writeln('CAVEAT no scene is averaged into another. Read the table, not a '
        'winner.')
    ..writeln('METHOD frames<=${options.frames} budget=${options.budgetMs}ms '
        'warmup=${options.warmup} per scene; each frame is timed on its own '
        'and the message pump runs between frames, outside the timing, so '
        'duration is the sum of frame times rather than wall clock.')
    ..writeln('METHOD a path whose zero-primitive control scene runs below '
        '${_vsyncCeilingFps.toStringAsFixed(0)} fps is vsync-capped and its '
        'rows are a floor, not a throughput measurement.');
}

// ---------------------------------------------------------------------------
// Attaching a path
// ---------------------------------------------------------------------------

final class _Attachment {
  _Attachment({
    required this.presenter,
    required this.target,
    required this.window,
    required this.info,
    required this.vsyncNote,
    required this.vsyncOffRequested,
  });

  final SurfacePresenter presenter;
  final DisplayListRenderTarget target;
  final NativeWindow window;
  final RendererInfo info;

  /// What was done about vsync, in words, for the output.
  final String vsyncNote;

  /// Whether a way to turn vsync off existed at all on this path.
  final bool vsyncOffRequested;

  Future<void> dispose() async {
    presenter.dispose();
    window.close();
    window.dispose();
  }
}

Future<_Attachment?> _attach(
  Win32WindowingBackend backend,
  PresentationPathEntry entry,
  _Options options,
) async {
  final NativeWindow window;
  try {
    window = await backend.createWindow(
      WindowOptions(
        size: Size(options.logicalWidth, options.logicalHeight),
        title: 'dart_ui render throughput - ${entry.name}',
        position: const Offset(80, 80),
        resizable: false,
        backgroundColor: _clearColor,
      ),
    );
  } on Object catch (error) {
    stdout.writeln('PATH=${entry.name} SKIP reason=no window: $error');
    return null;
  }
  // Shown, never hidden: a driver is entitled to discard a present for a
  // window nobody can see - DXGI says so out loud with DXGI_STATUS_OCCLUDED -
  // and a benchmark that measured discarded presents would report a path as
  // fast for not drawing.
  window.show();
  // `activate` lives on the optional [ActivatableWindow] interface rather than
  // on every window, and this is the idiom its own doc comment prescribes. A
  // backend that cannot raise a window is not an error here: the benchmark
  // only needs the window visible, and activation is a best effort even where
  // it exists.
  if (window case final ActivatableWindow activatable) {
    activatable.activate();
  }
  for (var i = 0; i < 12; i++) {
    backend.pumpEvents(timeout: const Duration(milliseconds: 8));
  }

  final SurfacePresenter presenter;
  try {
    presenter = await entry.attach(window);
  } on Object catch (error) {
    stdout.writeln('PATH=${entry.name} SKIP'
        '${entry.experimental ? ' (experimental)' : ''} '
        'reason=attach failed: $error');
    window
      ..close()
      ..dispose();
    return null;
  }

  if (presenter is! RenderTargetPresenter) {
    stdout.writeln('PATH=${entry.name} SKIP reason=presents through '
        '${presenter.runtimeType}, which owns no RenderTarget this benchmark '
        'can drive a display list through');
    presenter.dispose();
    window
      ..close()
      ..dispose();
    return null;
  }

  final RenderTarget raw = presenter.target;
  if (raw is! DisplayListRenderTarget) {
    stdout.writeln('PATH=${entry.name} SKIP reason=${raw.runtimeType} is not a '
        'DisplayListRenderTarget');
    presenter.dispose();
    window
      ..close()
      ..dispose();
    return null;
  }

  final (String note, bool requested) = _disableVsync(raw);
  final RendererInfo info = presenter.info;
  stdout.writeln('PATH=${entry.name} OK renderer=${info.name} '
      'adapter="${info.deviceDescription}" '
      'driver=${info.driverVersion ?? 'unreported'} '
      'raster=${info.rasterizationApproach.name} '
      'target=${raw.runtimeType} '
      'surface=${raw.surface.kind} '
      '${raw.surface.pixelWidth}x${raw.surface.pixelHeight}'
      '@${raw.surface.scale}x');
  stdout.writeln('  vsync: $note');

  return _Attachment(
    presenter: presenter,
    target: raw,
    window: window,
    info: info,
    vsyncNote: note,
    vsyncOffRequested: requested,
  );
}

/// Turns vsync off through whatever the path actually exposes.
///
/// There is no one call for this, and the differences are the finding rather
/// than an inconvenience: only the GL window target implements [PresentPacer],
/// D3D11 and D3D12 expose a sync interval directly, and Direct2D and Vulkan
/// expose nothing at all from outside `lib/`.
(String, bool) _disableVsync(RenderTarget target) {
  if (target is D3d11WindowTarget) {
    final bool ok = target.swapChain.setSyncInterval(0);
    return (
      ok
          ? 'off - D3d11SwapChain.setSyncInterval(0), so Present(0, 0)'
          : 'REQUESTED BUT REFUSED - setSyncInterval(0) returned false',
      ok,
    );
  }
  if (target is D3d12WindowTarget) {
    target.syncInterval = 0;
    return ('off - D3d12WindowTarget.syncInterval = 0, so Present(0, 0)', true);
  }
  if (target case final PresentPacer pacer) {
    final PresentModeOutcome outcome =
        pacer.requestPresentMode(PresentMode.immediate);
    return (
      outcome.accepted
          ? 'off - PresentMode.immediate accepted: $outcome'
          : 'REQUESTED BUT REFUSED - $outcome',
      outcome.accepted,
    );
  }
  return (
    'NOT AVAILABLE - this target implements neither PresentPacer nor a sync '
        'interval, so nothing outside lib/ can unthrottle it',
    false,
  );
}

// ---------------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------------

final class _Scene {
  _Scene({
    required this.name,
    required this.primitives,
    required this.description,
    required this.list,
  });

  final String name;

  /// Draw commands in the list. Printed because "frames per second" without it
  /// is a number with no units.
  final int primitives;
  final String description;
  final DisplayList list;
}

List<_Scene> _buildScenes(
  int width,
  int height,
  ScaledTypeface? font,
  _Options options,
) {
  final w = width.toDouble();
  final h = height.toDouble();
  final scenes = <_Scene>[
    _clearScene(),
    _rectScene(w, h),
    _roundedScene(w, h),
  ];
  if (font != null) {
    scenes.add(_textScene(w, h, font));
  }
  scenes
    ..add(_imageScene(w, h))
    ..add(_mixedScene(w, h, font));
  return scenes;
}

/// Zero primitives. The control.
///
/// Every path must be able to clear, so a scene that costs the same as this
/// one did not draw, and a path whose frame rate here sits near a refresh rate
/// is paced by the display rather than limited by anything measured.
_Scene _clearScene() => _Scene(
      name: 'clear',
      primitives: 0,
      description: 'clear only, no draw commands - the control',
      list: DisplayList(),
    );

_Scene _rectScene(double w, double h) {
  final list = DisplayList();
  const int columns = 40;
  const int rows = 15;
  final double cellW = w / columns;
  final double cellH = h / rows;
  final paints = <int>[
    for (var i = 0; i < 8; i++)
      list.addPaint(
        colorArgb: _palette(i),
        antiAlias: false,
      ),
  ];
  var count = 0;
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < columns; x++) {
      final double left = x * cellW;
      final double top = y * cellH;
      list.drawRect(
        left + 1,
        top + 1,
        left + cellW - 1,
        top + cellH - 1,
        paints[(x + y) & 7],
      );
      count++;
    }
  }
  return _Scene(
    name: 'rects',
    primitives: count,
    description: '$count axis-aligned opaque fills, antialiasing off',
    list: list,
  );
}

_Scene _roundedScene(double w, double h) {
  final list = DisplayList();
  const int columns = 25;
  const int rows = 12;
  final double cellW = w / columns;
  final double cellH = h / rows;
  final fills = <int>[
    for (var i = 0; i < 8; i++) list.addPaint(colorArgb: _palette(i)),
  ];
  final int stroke = list.addPaint(
    colorArgb: 0xFFEFEFEF,
    style: paintStyleStroke,
    strokeWidth: 1.5,
  );
  var count = 0;
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < columns; x++) {
      final double left = x * cellW + 2;
      final double top = y * cellH + 2;
      final double radius = math.min(cellW, cellH) * 0.28;
      list
        ..drawRRectUniform(
          left,
          top,
          left + cellW - 4,
          top + cellH - 4,
          radius,
          radius,
          fills[(x * 3 + y) & 7],
        )
        ..drawRRectUniform(
          left + 3,
          top + 3,
          left + cellW - 7,
          top + cellH - 7,
          radius * 0.6,
          radius * 0.6,
          stroke,
        );
      count += 2;
    }
  }
  return _Scene(
    name: 'rrects-aa',
    primitives: count,
    description: '$count antialiased rounded rectangles, half of them stroked',
    list: list,
  );
}

/// The glyph atlas path, and the one Vulkan refuses by name.
_Scene _textScene(double w, double h, ScaledTypeface font) {
  final list = DisplayList();
  final painter = TextPainter();
  final int ink = list.addPaint(colorArgb: 0xFFEAEAEA);
  final int dim = list.addPaint(colorArgb: 0xFF8FA0B4);
  const String sample =
      'The quick brown fox jumps over the lazy dog 0123456789 - '
      'glyph atlas throughput';
  final double lineHeight = font.lineHeight;
  var runs = 0;
  var glyphs = 0;
  var y = lineHeight;
  while (y < h - lineHeight * 0.5) {
    final GlyphRun run = painter.paint(
      list,
      sample,
      font,
      Offset(12, y),
      runs.isEven ? ink : dim,
    );
    glyphs += run.length;
    runs++;
    y += lineHeight * 1.15;
  }
  return _Scene(
    name: 'text',
    primitives: runs,
    description: '$runs shaped runs, $glyphs glyphs, '
        '${font.pixelSize.toStringAsFixed(0)}px',
    list: list,
  );
}

_Scene _imageScene(double w, double h) {
  final Framebuffer image = _checkerImage(128);
  final list = DisplayList();
  final int id = list.addImage(image);
  final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
  const int columns = 16;
  const int rows = 9;
  final double cellW = w / columns;
  final double cellH = h / rows;
  var count = 0;
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < columns; x++) {
      final double left = x * cellW;
      final double top = y * cellH;
      list.drawImage(
        id,
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
        left,
        top,
        left + cellW,
        top + cellH,
        paint,
      );
      count++;
    }
  }
  return _Scene(
    name: 'images',
    primitives: count,
    description: '$count draws of one ${image.width}x${image.height} '
        'texture, scaled - one upload, $count samples',
    list: list,
  );
}

/// What a real interface actually costs: a background, cards, labels, icons.
_Scene _mixedScene(double w, double h, ScaledTypeface? font) {
  final Framebuffer icon = _checkerImage(64);
  final list = DisplayList();
  final painter = TextPainter();
  final int background = list.addPaint(colorArgb: 0xFF1B2027, antiAlias: false);
  final int card = list.addPaint(colorArgb: 0xFF2A323C);
  final int accent = list.addPaint(colorArgb: 0xFF3D7EFF);
  final int divider = list.addPaint(
    colorArgb: 0xFF3A424D,
    style: paintStyleStroke,
    strokeWidth: 1,
  );
  final int title = list.addPaint(colorArgb: 0xFFF2F4F7);
  final int body = list.addPaint(colorArgb: 0xFF9AA7B6);
  final int iconId = list.addImage(icon);
  final int iconPaint = list.addPaint(colorArgb: 0xFFFFFFFF);

  var count = 1;
  list.drawRect(0, 0, w, h, background);

  const int columns = 4;
  const int rows = 4;
  final double cellW = w / columns;
  final double cellH = h / rows;
  for (var row = 0; row < rows; row++) {
    for (var column = 0; column < columns; column++) {
      final double left = column * cellW + 10;
      final double top = row * cellH + 10;
      final double right = left + cellW - 20;
      final double bottom = top + cellH - 20;
      list
        ..drawRRectUniform(left, top, right, bottom, 8, 8, card)
        ..drawRRectUniform(left, top, left + 4, bottom, 2, 2, accent)
        ..drawImage(
          iconId,
          0,
          0,
          icon.width.toDouble(),
          icon.height.toDouble(),
          left + 14,
          top + 12,
          left + 46,
          top + 44,
          iconPaint,
        )
        ..drawRRectUniform(
          left + 14,
          bottom - 22,
          right - 14,
          bottom - 10,
          6,
          6,
          divider,
        );
      count += 4;
      if (font != null) {
        painter
          ..paint(list, 'Item ${row * columns + column}', font,
              Offset(left + 56, top + 30), title)
          ..paint(
              list, 'secondary label', font, Offset(left + 56, top + 52), body);
        count += 2;
      }
    }
  }
  return _Scene(
    name: 'mixed-ui',
    primitives: count,
    description: '$count commands - background, ${columns * rows} cards of '
        'rounded rectangles, icons'
        '${font == null ? ' (no text: no font)' : ' and two text runs each'}',
    list: list,
  );
}

int _palette(int index) => const <int>[
      0xFF2E7D32,
      0xFF1565C0,
      0xFFC62828,
      0xFF6A1B9A,
      0xFFEF6C00,
      0xFF00838F,
      0xFF4E342E,
      0xFF37474F,
    ][index & 7];

/// A checkerboard with a diagonal ramp, premultiplied BGRA.
///
/// Not a solid colour: a driver is free to notice a uniform texture, and a
/// benchmark that let it would be measuring the optimisation.
Framebuffer _checkerImage(int size) {
  final Framebuffer buffer = Framebuffer.allocate(width: size, height: size);
  final Uint8List pixels = buffer.pixels;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final int offset = (y * size + x) * 4;
      final bool light = ((x >> 3) + (y >> 3)).isEven;
      final int ramp = (x + y) * 255 ~/ (size * 2 - 2);
      pixels[offset] = light ? ramp : 255 - ramp; // B
      pixels[offset + 1] = light ? 200 : 60; // G
      pixels[offset + 2] = light ? 60 : 200; // R
      pixels[offset + 3] = 255; // A
    }
  }
  return buffer;
}

ScaledTypeface? _loadFont(String? explicit) {
  final candidates = <String>[
    if (explicit != null) explicit,
    'test/fonts/Roboto-Regular.ttf',
    '../test/fonts/Roboto-Regular.ttf',
    'test/fonts/DejaVuSans.ttf',
  ];
  for (final String path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      return Typeface.parse(file.readAsBytesSync()).atSize(16);
    } on Object catch (error) {
      stdout.writeln('FONT=UNREADABLE $path: $error');
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Measurement
// ---------------------------------------------------------------------------

final class _SceneResult {
  _SceneResult({
    required this.frames,
    required this.totalMicros,
    required this.bestMicros,
    required this.medianMicros,
    required this.notPresented,
    required this.diagnostics,
    required this.firstDiagnostic,
    required this.refusal,
  });

  final int frames;
  final int totalMicros;
  final int bestMicros;
  final int medianMicros;

  /// Frames whose [PresentResult] was not `presented`. A non-zero count means
  /// the row measured something other than drawing.
  final int notPresented;

  /// Frames that presented but carried a diagnostic - occlusion is the one
  /// that matters here, because an occluded present is discarded work.
  final int diagnostics;
  final String? firstDiagnostic;

  /// Non-null when the path would not draw this scene at all.
  final String? refusal;

  double get fps => totalMicros == 0 ? 0 : frames * 1000000 / totalMicros;
  double get medianMs => medianMicros / 1000;
  double get bestMs => bestMicros / 1000;
  double get bestFps => bestMicros == 0 ? 0 : 1000000 / bestMicros;
}

final class _PathResult {
  _PathResult({
    required this.name,
    required this.info,
    required this.vsyncNote,
    required this.vsyncOffRequested,
    required this.scenes,
  });

  final String name;
  final RendererInfo info;
  final String vsyncNote;
  final bool vsyncOffRequested;
  final Map<String, _SceneResult> scenes;

  /// The zero-primitive control, when it ran.
  _SceneResult? get control => scenes['clear'];

  bool get vsyncCapped {
    final _SceneResult? c = control;
    if (c == null || c.refusal != null) return false;
    return c.fps < _vsyncCeilingFps;
  }
}

Future<_PathResult> _runPath({
  required Win32WindowingBackend backend,
  required String name,
  required _Attachment attachment,
  required List<_Scene> scenes,
  required _Options options,
}) async {
  final measured = <String, _SceneResult>{};
  for (final _Scene scene in scenes) {
    final _SceneResult result = await _runScene(
      backend: backend,
      target: attachment.target,
      scene: scene,
      options: options,
    );
    measured[scene.name] = result;
    if (result.refusal != null) {
      stdout.writeln('  ${scene.name}: REFUSED ${result.refusal}');
    } else {
      stdout.writeln('  ${scene.name}: '
          '${result.fps.toStringAsFixed(1)} fps '
          'median ${result.medianMs.toStringAsFixed(3)} ms '
          'best ${result.bestMs.toStringAsFixed(3)} ms '
          'over ${result.frames} frames in '
          '${(result.totalMicros / 1000).toStringAsFixed(1)} ms'
          '${result.notPresented > 0 ? ' notPresented=${result.notPresented}' : ''}'
          '${result.diagnostics > 0 ? ' diagnostics=${result.diagnostics}' : ''}');
      if (result.firstDiagnostic != null) {
        stdout.writeln('    diagnostic: ${result.firstDiagnostic}');
      }
    }
  }
  return _PathResult(
    name: name,
    info: attachment.info,
    vsyncNote: attachment.vsyncNote,
    vsyncOffRequested: attachment.vsyncOffRequested,
    scenes: measured,
  );
}

Future<_SceneResult> _runScene({
  required Win32WindowingBackend backend,
  required DisplayListRenderTarget target,
  required _Scene scene,
  required _Options options,
}) async {
  // Warm-up is thrown away and it is not a formality: the first frame of a
  // scene uploads its texture, rasterises every glyph into the atlas, and on
  // D3D11 compiles shaders. Charging that to the scene would make whichever
  // path compiles most eagerly look slowest.
  for (var i = 0; i < options.warmup; i++) {
    try {
      await target.renderDisplayList(scene.list, clearColor: _clearColor);
    } on Object catch (error) {
      return _SceneResult(
        frames: 0,
        totalMicros: 0,
        bestMicros: 0,
        medianMicros: 0,
        notPresented: 0,
        diagnostics: 0,
        firstDiagnostic: null,
        refusal: _describe(error),
      );
    }
    if (i.isOdd) backend.pumpEvents();
  }

  final times = <int>[];
  final watch = Stopwatch();
  var total = 0;
  var notPresented = 0;
  var diagnostics = 0;
  String? firstDiagnostic;
  final int budget = options.budgetMs * 1000;

  for (var i = 0; i < options.frames; i++) {
    watch
      ..reset()
      ..start();
    final PresentResult result;
    try {
      result =
          await target.renderDisplayList(scene.list, clearColor: _clearColor);
    } on Object catch (error) {
      return _SceneResult(
        frames: times.length,
        totalMicros: total,
        bestMicros: times.isEmpty ? 0 : times.reduce(math.min),
        medianMicros: _median(times),
        notPresented: notPresented,
        diagnostics: diagnostics,
        firstDiagnostic: firstDiagnostic,
        refusal: _describe(error),
      );
    }
    watch.stop();
    final int micros = watch.elapsedMicroseconds;
    times.add(micros);
    total += micros;
    if (!result.isSuccess) notPresented++;
    if (result.diagnostic != null) {
      diagnostics++;
      firstDiagnostic ??= result.diagnostic.toString();
    }
    // Outside the timing: a window that never drains its queue stops being a
    // window, and charging the pump to a frame would charge it unevenly - the
    // faster the path, the more pumps per second it would pay for.
    if (i % 30 == 29) backend.pumpEvents();
    if (total >= budget) break;
  }

  return _SceneResult(
    frames: times.length,
    totalMicros: total,
    bestMicros: times.isEmpty ? 0 : times.reduce(math.min),
    medianMicros: _median(times),
    notPresented: notPresented,
    diagnostics: diagnostics,
    firstDiagnostic: firstDiagnostic,
    refusal: null,
  );
}

int _median(List<int> values) {
  if (values.isEmpty) return 0;
  final List<int> sorted = List<int>.of(values)..sort();
  return sorted[sorted.length ~/ 2];
}

String _describe(Object error) {
  final String text = error.toString();
  final String flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 220 ? flat : '${flat.substring(0, 217)}...';
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

void _report(
  List<_PathResult> results,
  List<_Scene> scenes,
  int width,
  int height,
  _Options options,
) {
  stdout
    ..writeln()
    ..writeln('SCENES viewport=${width}x$height');
  for (final _Scene scene in scenes) {
    stdout.writeln('  ${scene.name.padRight(11)} '
        'primitives=${scene.primitives.toString().padLeft(4)}  '
        '${scene.description}');
  }

  stdout
    ..writeln()
    ..writeln('RENDERERS');
  for (final _PathResult result in results) {
    stdout.writeln('  ${result.name.padRight(11)} '
        '${result.info.deviceDescription} '
        '[${result.info.rasterizationApproach.name}] '
        '${result.vsyncCapped ? 'VSYNC-CAPPED' : 'unthrottled'}');
    stdout.writeln('    ${result.vsyncNote}');
  }

  // The table. One row per scene, one column per path, and no column of
  // averages - see the library comment.
  stdout
    ..writeln()
    ..writeln('TABLE median milliseconds per frame (lower is better); '
        '"refused" means the path would not draw the scene at all')
    ..writeln();
  final int nameWidth = scenes
      .map((_Scene s) => s.name.length)
      .fold(5, (int a, int b) => math.max(a, b));
  final buffer = StringBuffer('  ${'scene'.padRight(nameWidth)}');
  for (final _PathResult result in results) {
    buffer.write(' | ${result.name.padLeft(12)}');
  }
  stdout
    ..writeln(buffer)
    ..writeln('  ${'-' * nameWidth}${'-+-------------' * results.length}');
  for (final _Scene scene in scenes) {
    final row = StringBuffer('  ${scene.name.padRight(nameWidth)}');
    for (final _PathResult result in results) {
      final _SceneResult? cell = result.scenes[scene.name];
      final String text;
      if (cell == null) {
        text = 'not run';
      } else if (cell.refusal != null) {
        text = 'refused';
      } else {
        text = '${cell.medianMs.toStringAsFixed(3)}'
            '${result.vsyncCapped ? '*' : ''}';
      }
      row.write(' | ${text.padLeft(12)}');
    }
    stdout.writeln(row);
  }
  stdout.writeln('  * paced by the display, not by the renderer - a floor');

  stdout
    ..writeln()
    ..writeln('TABLE frames per second, same runs');
  final header = StringBuffer('  ${'scene'.padRight(nameWidth)}');
  for (final _PathResult result in results) {
    header.write(' | ${result.name.padLeft(12)}');
  }
  stdout
    ..writeln(header)
    ..writeln('  ${'-' * nameWidth}${'-+-------------' * results.length}');
  for (final _Scene scene in scenes) {
    final row = StringBuffer('  ${scene.name.padRight(nameWidth)}');
    for (final _PathResult result in results) {
      final _SceneResult? cell = result.scenes[scene.name];
      final String text = cell == null
          ? 'not run'
          : cell.refusal != null
              ? 'refused'
              : '${cell.fps.toStringAsFixed(1)}'
                  '${result.vsyncCapped ? '*' : ''}';
      row.write(' | ${text.padLeft(12)}');
    }
    stdout.writeln(row);
  }

  _reportRefusals(results, scenes);
  _reportSuspiciouslyCheap(results, scenes);
  _reportNoise(results, scenes);

  stdout
    ..writeln()
    ..writeln('DOES NOT SUPPORT concluding that one path is "the fast one": '
        'the ranking changes by scene, and every row is one Intel integrated '
        'GPU on one driver.')
    ..writeln('DOES NOT SUPPORT anything about startup or window-open cost, '
        'which is what the popup timings measured and is a different '
        'question.')
    ..writeln('DOES NOT SUPPORT anything about a path that is VSYNC-CAPPED '
        'above its cap: those rows say only "at least this fast".')
    ..writeln('DOES NOT SUPPORT quality claims. Nothing here compares the '
        'pixels the paths produced, only how long they took to produce '
        'something.')
    ..writeln('METHOD frames were capped at ${options.frames} or '
        '${options.budgetMs} ms of frame time per scene, whichever came '
        'first; the counts above say which bound was hit.');
}

void _reportRefusals(List<_PathResult> results, List<_Scene> scenes) {
  final lines = <String>[];
  for (final _PathResult result in results) {
    for (final _Scene scene in scenes) {
      final String? refusal = result.scenes[scene.name]?.refusal;
      if (refusal != null) {
        lines.add('  ${result.name} refused ${scene.name}: $refusal');
      }
      final _SceneResult? cell = result.scenes[scene.name];
      if (cell != null && cell.notPresented > 0) {
        lines.add('  ${result.name} on ${scene.name}: ${cell.notPresented} of '
            '${cell.frames} frames did not present, so that row is not a '
            'measurement of drawing');
      }
      if (cell != null && cell.diagnostics > 0) {
        lines.add('  ${result.name} on ${scene.name}: ${cell.diagnostics} of '
            '${cell.frames} presents carried a diagnostic '
            '(${cell.firstDiagnostic})');
      }
    }
  }
  stdout
    ..writeln()
    ..writeln('REFUSALS AND WARNINGS');
  if (lines.isEmpty) {
    stdout.writeln('  none - every path drew every scene and every present '
        'was clean');
  } else {
    lines.forEach(stdout.writeln);
  }
}

/// The check that keeps a path from winning by drawing nothing.
///
/// The control scene has no draw commands. A scene with hundreds of them that
/// costs the same as the control was not rasterised, whatever the present
/// returned - so the row is flagged rather than ranked.
void _reportSuspiciouslyCheap(List<_PathResult> results, List<_Scene> scenes) {
  final lines = <String>[];
  for (final _PathResult result in results) {
    final _SceneResult? control = result.control;
    if (control == null || control.refusal != null) continue;
    if (result.vsyncCapped) continue; // Every scene is the same under a cap.
    for (final _Scene scene in scenes) {
      if (scene.primitives == 0) continue;
      final _SceneResult? cell = result.scenes[scene.name];
      if (cell == null || cell.refusal != null) continue;
      if (cell.medianMicros <= control.medianMicros * 1.05) {
        lines.add('  ${result.name} drew ${scene.name} '
            '(${scene.primitives} commands) in '
            '${cell.medianMs.toStringAsFixed(3)} ms, within 5% of its own '
            'empty control at ${control.medianMs.toStringAsFixed(3)} ms. '
            'Treat that as "did not draw it", not as speed.');
      }
    }
  }
  stdout
    ..writeln()
    ..writeln('DID-IT-ACTUALLY-DRAW CHECK (scene vs its own empty control)');
  if (lines.isEmpty) {
    stdout.writeln('  every scene cost measurably more than the empty control '
        'on every unthrottled path');
  } else {
    lines.forEach(stdout.writeln);
  }
}

/// Pairs whose medians are closer than the run-to-run spread of either.
///
/// Ranking two numbers that differ by less than the noise is the most common
/// way a benchmark invents a result, so the pairs are named and not ordered.
void _reportNoise(List<_PathResult> results, List<_Scene> scenes) {
  final lines = <String>[];
  for (final _Scene scene in scenes) {
    for (var i = 0; i < results.length; i++) {
      for (var j = i + 1; j < results.length; j++) {
        final _PathResult a = results[i];
        final _PathResult b = results[j];
        if (a.vsyncCapped != b.vsyncCapped) continue;
        final _SceneResult? ra = a.scenes[scene.name];
        final _SceneResult? rb = b.scenes[scene.name];
        if (ra == null || rb == null) continue;
        if (ra.refusal != null || rb.refusal != null) continue;
        if (ra.frames == 0 || rb.frames == 0) continue;
        // Spread within one run: median minus best. It is the cheapest honest
        // estimate of how much a repeat of this run could move the median,
        // and it needs no second run to compute.
        final int spread = math.max(
          ra.medianMicros - ra.bestMicros,
          rb.medianMicros - rb.bestMicros,
        );
        final int gap = (ra.medianMicros - rb.medianMicros).abs();
        if (gap <= spread) {
          lines.add('  ${scene.name}: ${a.name} '
              '${ra.medianMs.toStringAsFixed(3)} ms and ${b.name} '
              '${rb.medianMs.toStringAsFixed(3)} ms differ by '
              '${(gap / 1000).toStringAsFixed(3)} ms, which is inside the '
              '${(spread / 1000).toStringAsFixed(3)} ms spread of the runs '
              'themselves. They are not distinguishable here.');
        }
      }
    }
  }
  stdout
    ..writeln()
    ..writeln('WITHIN NOISE (do not rank these pairs)');
  if (lines.isEmpty) {
    stdout.writeln('  no pair was closer than the spread within its own run');
  } else {
    lines.forEach(stdout.writeln);
  }
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

final class _Options {
  _Options({
    required this.paths,
    required this.frames,
    required this.budgetMs,
    required this.warmup,
    required this.logicalWidth,
    required this.logicalHeight,
    required this.fontPath,
    required this.fontSize,
  });

  factory _Options.parse(List<String> arguments) {
    var paths = _defaultPaths;
    var frames = _defaultFrames;
    var budget = _defaultBudgetMs;
    var warmup = _defaultWarmup;
    var width = _logicalWidth;
    var height = _logicalHeight;
    String? font;
    for (final String argument in arguments) {
      final int split = argument.indexOf('=');
      if (!argument.startsWith('--') || split < 0) {
        throw FormatException('unrecognised argument "$argument"');
      }
      final String key = argument.substring(2, split);
      final String value = argument.substring(split + 1);
      switch (key) {
        case 'paths':
          paths = value.split(',').where((String s) => s.isNotEmpty).toList();
        case 'frames':
          frames = _positive(key, value);
        case 'budget-ms':
          budget = _positive(key, value);
        case 'warmup':
          warmup = int.tryParse(value) ??
              (throw const FormatException('--warmup needs an integer'));
        case 'width':
          width = _positive(key, value).toDouble();
        case 'height':
          height = _positive(key, value).toDouble();
        case 'font':
          font = value;
        default:
          throw FormatException('unknown option "--$key"');
      }
    }
    return _Options(
      paths: paths,
      frames: frames,
      budgetMs: budget,
      warmup: warmup,
      logicalWidth: width,
      logicalHeight: height,
      fontPath: font,
      fontSize: 16,
    );
  }

  static int _positive(String key, String value) {
    final int? parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0) {
      throw FormatException('--$key needs a positive integer, got "$value"');
    }
    return parsed;
  }

  final List<String> paths;
  final int frames;
  final int budgetMs;
  final int warmup;
  final double logicalWidth;
  final double logicalHeight;
  final String? fontPath;
  final double fontSize;
}
