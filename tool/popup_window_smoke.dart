/// Proves a popup is a *window* - against a real driver, on a real desktop.
///
/// Everything about popup windows is, at the moment this file was written,
/// proven by headless tests and byte-level fakes. This repository has already
/// paid twice for exactly that: `GlVideoDevice` raised `GL_INVALID_OPERATION`
/// on its first call the first time it met a driver, and the Wayland frame
/// pacing was complete, reviewed dead code with no caller anywhere in `lib/`.
/// A headless run cannot catch either, and it cannot catch any of the eight
/// things below either, for one reason each:
///
///   * the headless backend deliberately does not report
///     [Capability.nativePopups], so `Application.canOpenPopupWindows` is
///     false there and *every* menu is composited into the owner's surface -
///     which is precisely the behaviour this feature exists to replace. A
///     headless "popup test" therefore tests the fallback;
///   * there is no monitor, so [Application.screens] is synthesised from the
///     owner window and its work area *is* the owner's client area. A popup
///     placed against it can never leave the owner, so "the popup escaped"
///     is not even expressible;
///   * there is no swap chain, so a frame count says nothing about pixels,
///     and `WS_EX_NOACTIVATE` has nothing to refuse.
///
/// So this runs on Windows, opens a real window on a real GPU path, and
/// measures. Each check prints one `KEY=VALUE` line with `PASS`/`FAIL` and the
/// numbers that justify it, because a `PASS` with no number is just a word.
///
/// ```
/// dart run tool/popup_window_smoke.dart
/// dart compile exe tool/popup_window_smoke.dart -o build/popup_window_smoke.exe
/// ```
///
/// Exits 0 on `POPUP_WINDOW_SMOKE=PASS`, 1 on `=FAIL`, and 2 when the platform
/// or the backend cannot run it at all - the same three-way convention
/// `tool/present_mode_smoke.dart` and `tool/x11_backend_smoke.dart` use, so CI
/// can tell "this machine cannot" from "this build is broken".
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

/// Owner window geometry. Small on purpose: an anchor 24 logical pixels from
/// the right edge of a 560-wide window is unambiguously near the edge, and a
/// menu 220 wide cannot possibly fit inside after it.
const Size _ownerSize = Size(560, 380);
const Offset _ownerPosition = Offset(140, 120);

/// The popup's content size. Fixed rather than intrinsic so that the measured
/// size is a known number and the placement arithmetic can be checked by hand
/// from the printed rectangles.
const Size _menuSize = Size(220, 190);

/// How far from the owner's right and bottom edges the anchor sits.
const double _anchorInset = 24;

/// Open/close cycles timed for [_checkOpenCost].
const int _timedCycles = 20;

/// How long [_checkFrames] watches the popup present.
const Duration _frameWindow = Duration(seconds: 2);

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    stderr.writeln(
      'POPUP_WINDOW_SMOKE=SKIP platform=${Platform.operatingSystem}',
    );
    exitCode = 2;
    return;
  }

  final errors = <FrameworkError>[];
  final diagnostics = <BackendDiagnostic>[];

  Application? application;
  try {
    application = await Application.start(
      rootWidget: _ownerContent(),
      backends: PlatformBackendResolver.defaultBackends(),
      presentations: PlatformBackendResolver.defaultPresentations(),
      options: ApplicationOptions(
        title: 'dart_ui popup window smoke',
        size: _ownerSize,
        visible: false,
        arguments: arguments,
        environment: Platform.environment,
        // Installed before the first window exists, which is the point: a
        // failure inside a popup's own frame is reported through its owner's
        // reporter and would otherwise be swallowed into a count nobody
        // prints.
        onError: (FrameworkError error) {
          errors.add(error);
          stderr.writeln('POPUP_ERROR ${error.describe()}');
        },
        onDiagnostic: diagnostics.add,
      ),
    );
  } on Object catch (error, stackTrace) {
    stderr
      ..writeln('POPUP_WINDOW_SMOKE=FAIL the application would not start')
      ..writeln(error)
      ..writeln(stackTrace);
    exitCode = 1;
    return;
  }

  final app = application;
  var verdict = 'PASS';
  var reason = '';

  void record(String key, bool passed, String detail) {
    stdout.writeln('$key=${passed ? 'PASS' : 'FAIL'} $detail');
    if (!passed && verdict == 'PASS') {
      verdict = 'FAIL';
      reason = key;
    }
  }

  try {
    stdout.write(app.describeStartup());

    final ApplicationWindow owner = app.primaryWindow;
    owner.nativeWindow
      ..setBounds(Rect.fromLTWH(
        _ownerPosition.dx,
        _ownerPosition.dy,
        _ownerSize.width,
        _ownerSize.height,
      ))
      ..show();
    app.focusWindow(owner.id);
    await _pump(app, const Duration(milliseconds: 400));

    stdout.writeln('POPUP_HOST owner=${owner.id.value} '
        'canOpenPopupWindows=${app.canOpenPopupWindows} '
        'hasScreenCoordinates=${app.hasScreenCoordinates} '
        'policy=${app.options.popupPolicy.name} '
        'host=${owner.popupHost.runtimeType} '
        'escapesOwnerWindow=${owner.popupHost?.escapesOwnerWindow}');

    if (!app.canOpenPopupWindows) {
      record(
        'POPUP_WINDOW_SMOKE',
        false,
        'the ${app.backend.name} backend does not report '
            'Capability.nativePopups, so nothing below can run',
      );
      exitCode = 1;
      return;
    }

    // 8 first: every placement number below is read against these.
    _checkScreens(app, record);

    // 1, 2, 4, 5 all want one popup open, so they share it - and sharing is
    // not a shortcut, it is the honest configuration: the popup whose frames
    // are counted must be the same one whose rectangle escaped and whose
    // owner stayed active.
    final double coldOpenMs =
        await _checkEscapesDeviceFramesActivation(app, owner, errors, record);

    await _checkOpenCost(app, owner, coldOpenMs, record);
    await _checkChainAndDismiss(app, owner, record);
  } on Object catch (error, stackTrace) {
    stderr
      ..writeln('POPUP_WINDOW_SMOKE threw: $error')
      ..writeln(stackTrace);
    verdict = 'FAIL';
    if (reason.isEmpty) reason = 'threw ${error.runtimeType}';
  } finally {
    stdout.writeln('POPUP_DIAGNOSTICS count=${diagnostics.length}');
    for (final BackendDiagnostic diagnostic in diagnostics) {
      stdout.writeln('  $diagnostic');
    }
    app.dispose();
    await app.closed;
  }

  if (errors.isNotEmpty && verdict == 'PASS') {
    verdict = 'FAIL';
    reason = 'the error handler saw ${errors.length} framework errors';
  }
  stdout.writeln(
    'POPUP_WINDOW_SMOKE=$verdict${verdict == 'PASS' ? '' : ' $reason'}',
  );
  exitCode = verdict == 'PASS' ? 0 : 1;
}

// ---------------------------------------------------------------------------
// 8. The screens the placement arithmetic is done against
// ---------------------------------------------------------------------------

void _checkScreens(
  Application app,
  void Function(String, bool, String) record,
) {
  final List<ScreenInfo> screens = app.screens;
  for (var i = 0; i < screens.length; i++) {
    final ScreenInfo screen = screens[i];
    stdout.writeln('  screen[$i] name=${screen.name ?? 'none'} '
        'primary=${screen.isPrimary} scale=${screen.scale} '
        'bounds=${_rect(screen.bounds)} workArea=${_rect(screen.workArea)} '
        'reserved=${_reserved(screen)}');
  }
  // Real, not synthesised: a synthetic screen is named after the backend and
  // has workArea == bounds, and placing a popup against one cannot make it
  // leave the owner. So "the backend answered" is the property, not "a list
  // came back".
  final bool real = app.hasScreenCoordinates && screens.isNotEmpty;
  record(
    'POPUP_SCREENS',
    real,
    'count=${screens.length} fromBackend=${app.hasScreenCoordinates} '
        'synthetic=${screens.where((s) => s.name?.startsWith('synthetic-') ?? false).length}',
  );
}

String _reserved(ScreenInfo screen) =>
    'l=${screen.workArea.left - screen.bounds.left} '
    't=${screen.workArea.top - screen.bounds.top} '
    'r=${screen.bounds.right - screen.workArea.right} '
    'b=${screen.bounds.bottom - screen.workArea.bottom}';

// ---------------------------------------------------------------------------
// 1, 2, 4, 5. One popup, four measurements
// ---------------------------------------------------------------------------

/// Returns the milliseconds the **first** popup window of the process cost,
/// which is the only cold open there is: everything after it has the driver
/// loaded, the path chosen and the owner's glyphs already rasterised.
Future<double> _checkEscapesDeviceFramesActivation(
  Application app,
  ApplicationWindow owner,
  List<FrameworkError> errors,
  void Function(String, bool, String) record,
) async {
  final Size ownerLogical = owner.host.logicalSize;
  // Near the right edge *and* near the bottom edge, so the popup must both
  // slide left and flip up. Either alone would prove less: a menu that only
  // slid could still fit inside a wide window.
  final Rect anchor = Rect.fromLTWH(
    ownerLogical.width - _anchorInset,
    ownerLogical.height - _anchorInset,
    18,
    18,
  );

  final int errorsBefore = errors.length;
  final Stopwatch cold = Stopwatch()..start();
  final ApplicationWindow popup = await app.openPopup(
    owner: owner,
    anchorRect: anchor,
    content: _menuContent(),
    kind: PopupKind.menu,
  );
  cold.stop();
  await _pump(app, const Duration(milliseconds: 300));

  final Rect ownerScreen = _screenRect(owner);
  final Rect popupScreen = _screenRect(popup);

  // --- 1. the popup left the owner -------------------------------------
  //
  // What the in-tree host would have produced for the identical anchor, so
  // the difference is two rectangles rather than an assertion. Same
  // positioner, same request; only the work area differs - the owner's client
  // area against the monitor's work area - and that single substitution is
  // the whole feature.
  final PopupRequest request = PopupRequest(
    anchorRect: anchor,
    size: _menuSize,
    adjustments: const <PopupAdjustment>{
      PopupAdjustment.flipY,
      PopupAdjustment.flipX,
      PopupAdjustment.slideX,
      PopupAdjustment.slideY,
    },
  );
  final Offset ownerOrigin = owner.nativeWindow.clientToScreen(Offset.zero);
  const PopupPositioner positioner = PopupPositioner();
  final PopupPlacement inTree = positioner.place(
    request,
    Rect.fromLTWH(0, 0, ownerLogical.width, ownerLogical.height),
  );
  final Rect inTreeScreen = inTree.rect.shift(ownerOrigin);
  final Rect windowPlaced = app.placePopup(
    owner: owner,
    anchorRect: anchor,
    size: _menuSize,
  );

  final bool escaped = !_containsRect(ownerScreen, popupScreen);
  record(
    'POPUP_ESCAPES',
    escaped,
    'popup=${_rect(popupScreen)} owner=${_rect(ownerScreen)} '
        'outsideBy=${_outsideBy(ownerScreen, popupScreen)} '
        'inTreeWouldBe=${_rect(inTreeScreen)} '
        'againstWorkArea=${_rect(windowPlaced)} '
        'inTreeFlippedY=${inTree.flippedY} inTreeSlidX=${inTree.slidX} '
        'inTreeContained=${_containsRect(ownerScreen, inTreeScreen)}',
  );

  // --- 2. the popup renders through the owner's chosen path ------------
  final ApplicationRuntimeInfo ownerInfo = owner.runtimeInfo;
  final ApplicationRuntimeInfo popupInfo = popup.runtimeInfo;
  final SurfacePresenter ownerPresenter = owner.host.presenter;
  final SurfacePresenter popupPresenter = popup.host.presenter;
  final RenderDevice? ownerDevice =
      ownerPresenter is RenderTargetPresenter ? ownerPresenter.device : null;
  final RenderDevice? popupDevice =
      popupPresenter is RenderTargetPresenter ? popupPresenter.device : null;
  final bool sharedDevice =
      ownerDevice != null && identical(ownerDevice, popupDevice);
  // The path *names* alone would be close to a tautology - both read the
  // application's single `presentationSelection` - so the live renderers are
  // compared too: `runtimeInfo.renderer` is the attached device's own
  // `RendererInfo`, so a popup that had fallen back to another path would
  // differ here even though the selection did not.
  record(
    'POPUP_DEVICE',
    ownerInfo.presentationBackend == popupInfo.presentationBackend &&
        ownerInfo.presentationKind == popupInfo.presentationKind &&
        ownerInfo.renderer.name == popupInfo.renderer.name &&
        ownerInfo.renderer.rasterizationApproach ==
            popupInfo.renderer.rasterizationApproach,
    'ownerPath=${ownerInfo.presentationBackend}/'
        '${ownerInfo.presentationKind.name} '
        'popupPath=${popupInfo.presentationBackend}/'
        '${popupInfo.presentationKind.name} '
        'ownerDevice=${_device(ownerDevice)} popupDevice=${_device(popupDevice)} '
        'sharedDevice=$sharedDevice '
        'ownerRenderer=${ownerInfo.renderer.deviceDescription} '
        'popupRenderer=${popupInfo.renderer.deviceDescription} '
        'approach=${ownerInfo.renderer.rasterizationApproach.name}/'
        '${popupInfo.renderer.rasterizationApproach.name}',
  );

  // --- 5. the owner is still the active window -------------------------
  //
  // Read back from the application rather than from what was asked for. This
  // is what `WS_EX_NOACTIVATE` exists for, and the symptom of getting it
  // wrong is the one a user names without knowing why: the caret behind the
  // menu stops blinking.
  final bool ownerActive = owner.isActive;
  final bool popupActive = popup.isActive;
  final bool keyboardOnOwner = app.keyboardFocusWindow == owner.id;
  record(
    'POPUP_NOACTIVATE',
    ownerActive && !popupActive && keyboardOnOwner,
    'ownerActive=$ownerActive popupActive=$popupActive '
        'keyboardFocus=${app.keyboardFocusWindow?.value} '
        'owner=${owner.id.value} popup=${popup.id.value} '
        'ownerFocusManagerActive=${owner.buildOwner.focusManager.isWindowActive} '
        'popupKind=${popup.kind.name} takesActivation=${popup.kind.takesActivation}',
  );

  // --- 4. the popup actually presented ---------------------------------
  final int before = popup.framesPresented;
  final Stopwatch watch = Stopwatch()..start();
  await _pump(app, _frameWindow);
  watch.stop();
  final int frames = popup.framesPresented - before;
  final int errorCount = errors.length - errorsBefore;
  final double fps = frames == 0
      ? 0
      : frames * 1000 / watch.elapsedMilliseconds.clamp(1, 1 << 30);
  record(
    'POPUP_FRAMES',
    frames > 0 && errorCount == 0,
    'frames=$frames over=${watch.elapsedMilliseconds}ms '
        'fps=${fps.toStringAsFixed(1)} errors=$errorCount '
        'rejected=${popup.host.framesRejected} '
        'ownerFrames=${owner.framesPresented}',
  );

  app.closeWindow(popup.id);
  await _pump(app, const Duration(milliseconds: 200));
  return cold.elapsedMicroseconds / 1000;
}

// ---------------------------------------------------------------------------
// 3. What an open costs, and therefore whether a pool is worth its complexity
// ---------------------------------------------------------------------------

Future<void> _checkOpenCost(
  Application app,
  ApplicationWindow owner,
  double coldOpenMs,
  void Function(String, bool, String) record,
) async {
  final Size ownerLogical = owner.host.logicalSize;
  const Rect anchor = Rect.fromLTWH(24, 24, 18, 18);

  // [coldOpenMs] is the process's first popup window, paid by the check
  // above; everything timed here is warm, which is the state a menu is
  // actually opened in.
  final samples = <double>[];
  for (var i = 0; i < _timedCycles; i++) {
    final Stopwatch watch = Stopwatch()..start();
    final ApplicationWindow popup = await app.openPopup(
      owner: owner,
      anchorRect: anchor,
      content: _menuContent(),
      kind: PopupKind.menu,
    );
    watch.stop();
    samples.add(watch.elapsedMicroseconds / 1000);
    // Presented, not merely created: a number that stopped at `show()` would
    // charge nothing for the surface the driver still has to allocate.
    await _pump(app, const Duration(milliseconds: 40));
    app.closeWindow(popup.id);
    await _pump(app, const Duration(milliseconds: 40));
    // `ownerLogical` is read so a resize between cycles would be visible in
    // the anchor; keeping it out of the loop would silently anchor off-window.
    if (owner.host.logicalSize != ownerLogical) break;
  }

  // The half of an open a pool would remove. `openPopup` is four steps -
  // create the window hidden, measure the tree, place it, show it - and only
  // the first is what a pooled hidden popup already owns. So a bare
  // `WindowKind.popup` window with the same content, never measured, placed or
  // shown, isolates the platform-and-device half from the framework half, and
  // that ratio is what decides whether the pool is worth its complexity.
  final bare = <double>[];
  for (var i = 0; i < 5; i++) {
    final Stopwatch watch = Stopwatch()..start();
    final ApplicationWindow window = await app.openWindow(
      rootWidget: _menuContent(),
      size: _menuSize,
      visible: false,
      resizable: false,
      decorated: false,
      owner: owner.id,
      kind: WindowKind.popup,
      focus: false,
    );
    watch.stop();
    bare.add(watch.elapsedMicroseconds / 1000);
    app.closeWindow(window.id);
    await _pump(app, const Duration(milliseconds: 40));
  }
  bare.sort();

  final double first = samples.first;
  final List<double> reopens = samples.skip(1).toList()..sort();
  final double best = reopens.isEmpty ? first : reopens.first;
  final double median = reopens.isEmpty ? first : reopens[reopens.length ~/ 2];
  final double worst = reopens.isEmpty ? first : reopens.last;
  // No threshold is asserted here on purpose. The plan says the numbers
  // decide whether a hidden popup per owner becomes the design, and inventing
  // a bound would answer that question with a constant instead of a
  // measurement. It fails only when an open never completed.
  record(
    'POPUP_OPEN_MS',
    samples.length >= 2,
    'cold=${coldOpenMs.toStringAsFixed(2)} '
        'first=${first.toStringAsFixed(2)} '
        'reopenBest=${best.toStringAsFixed(2)} '
        'reopenMedian=${median.toStringAsFixed(2)} '
        'reopenWorst=${worst.toStringAsFixed(2)} '
        'cycles=${samples.length} '
        'bareWindowBest=${bare.first.toStringAsFixed(2)} '
        'bareWindowMedian=${bare[bare.length ~/ 2].toStringAsFixed(2)}',
  );
}

// ---------------------------------------------------------------------------
// 6 and 7. A popup owned by a popup, and the whole chain going at once
// ---------------------------------------------------------------------------

Future<void> _checkChainAndDismiss(
  Application app,
  ApplicationWindow owner,
  void Function(String, bool, String) record,
) async {
  final PopupHost? host = owner.popupHost;
  if (host == null) {
    record('POPUP_CHAIN', false, 'the owner window publishes no PopupHost');
    record('POPUP_DISMISS', false, 'no chain was opened');
    return;
  }

  // Through the seam a widget uses, not through `openPopup` directly: the
  // parent of the second popup has to be supplied by the host's own view of
  // itself, which is the part `openPopup(parentPopup:)` would bypass.
  final PopupHandle root = host.open(PopupSpec(
    anchorRect: const Rect.fromLTWH(40, 60, 18, 18),
    builder: (BuildContext context) => _menuContent(),
  ));
  await _pumpUntil(
    app,
    () => app.popupsOf(owner).isNotEmpty,
    const Duration(seconds: 3),
  );

  final List<ApplicationWindow> afterFirst = app.popupsOf(owner);
  PopupHandle? child;
  if (afterFirst.isNotEmpty) {
    final PopupHost? inner = afterFirst.last.popupHost;
    child = inner?.open(PopupSpec(
      anchorRect: const Rect.fromLTWH(160, 40, 18, 18),
      kind: PopupKind.submenu,
      builder: (BuildContext context) => _menuContent(),
    ));
    await _pumpUntil(
      app,
      () => app.popupsOf(owner).length >= 2,
      const Duration(seconds: 3),
    );
  }

  final List<ApplicationWindow> chain = app.popupsOf(owner);
  final parts = <String>[
    'owner=${owner.id.value}',
    for (var i = 0; i < chain.length; i++)
      'depth${i + 1}=${chain[i].id.value}'
          '(owner=${chain[i].ownerId?.value}, kind=${chain[i].popupKind?.name})',
  ];
  // Depth 2 is the property, and the second window's owner being the first
  // popup - not the top-level window - is what makes it a chain rather than
  // two siblings. Wayland turns that distinction into a protocol error that
  // kills every window of the process, which is why it is measured here on
  // the platform where it is merely wrong.
  final bool chained = chain.length >= 2 &&
      chain[1].ownerId == chain[0].id &&
      chain[0].ownerId == owner.id;
  record(
    'POPUP_CHAIN',
    chained,
    'depth=${chain.length} ${parts.join(' ')} '
        'hostOpenCount=${host.openCount} '
        'childHandleOpen=${child?.isOpen}',
  );

  // --- 7. closing the outermost takes the whole chain -------------------
  final int windowsBefore = app.windows.length;
  root.close();
  await _pumpUntil(
    app,
    () => app.popupsOf(owner).isEmpty,
    const Duration(seconds: 3),
  );
  await _pump(app, const Duration(milliseconds: 200));

  final int leftOpen = app.popupsOf(owner).length;
  final int windowsAfter = app.windows.length;
  record(
    'POPUP_DISMISS',
    leftOpen == 0 &&
        windowsAfter == 1 &&
        identical(app.windows.single, owner) &&
        host.openCount == 0 &&
        !(child?.isOpen ?? false),
    'windowsBefore=$windowsBefore windowsAfter=$windowsAfter '
        'popupsLeft=$leftOpen hostOpenCount=${host.openCount} '
        'rootOpen=${root.isOpen} childOpen=${child?.isOpen} '
        'remaining=[${app.windows.map((w) => w.id.value).join(',')}]',
  );
}

// ---------------------------------------------------------------------------
// The loop, driven by hand
// ---------------------------------------------------------------------------

/// Pumps the platform, yields to Dart, and draws, for [duration].
///
/// `Application.run()` is not usable here: it takes the loop for the rest of
/// the process, and this file's whole subject is *when* things happen - a
/// popup opens at a known moment, is measured, and is closed. That is the case
/// `runApp`'s own doc comment sends to `Application.start`.
///
/// The `Future.delayed(Duration.zero)` is not a pause. Window events arrive
/// through a broadcast `StreamController` whose listeners run on a later turn,
/// so a loop that pumped native messages without returning to the Dart event
/// loop would queue every message and deliver none - and the activation and
/// dismissal that checks 5 and 7 read arrive exactly that way.
Future<void> _pump(Application app, Duration duration) async {
  final DateTime deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    if (app.isDisposed) return;
    if (!app.backend.pumpEvents(timeout: const Duration(milliseconds: 4))) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
    app.requestFrame();
    await app.drawPendingFrames();
  }
}

/// Pumps until [predicate] holds or [timeout] expires. Does not throw: a
/// timeout is a measurement, and the check that called this prints it.
Future<void> _pumpUntil(
  Application app,
  bool Function() predicate,
  Duration timeout,
) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await _pump(app, const Duration(milliseconds: 16));
  }
}

// ---------------------------------------------------------------------------
// Content
// ---------------------------------------------------------------------------

/// The owner window: something with text in it, so the glyph atlas is warm
/// before a menu asks for the same font at the same size.
Widget _ownerContent() => const ColoredBox(
      color: Color(0xFF1B1D21),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: <Widget>[
            SizedBox(
              height: 36,
              child: ColoredBox(
                color: Color(0xFF2D6CDF),
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('popup window smoke - owner'),
                ),
              ),
            ),
            SizedBox(height: 12),
            Text('the menu below is anchored at the bottom right corner'),
          ],
        ),
      ),
    );

/// A menu, at a size the popup's own measurement will report exactly.
///
/// A fixed [SizedBox] rather than an intrinsic column, so that the placement
/// arithmetic in the printed rectangles can be checked by hand: the popup's
/// width and height are known constants and every other number is the
/// positioner's.
Widget _menuContent() => SizedBox(
      width: _menuSize.width,
      height: _menuSize.height,
      child: const ColoredBox(
        color: Color(0xFF2A2D33),
        child: Padding(
          padding: EdgeInsets.all(8),
          child: Column(
            children: <Widget>[
              _MenuItem(label: 'Cut'),
              _MenuItem(label: 'Copy'),
              _MenuItem(label: 'Paste'),
              _MenuItem(label: 'Select all'),
              _MenuItem(label: 'More'),
            ],
          ),
        ),
      ),
    );

final class _MenuItem extends StatelessWidget {
  const _MenuItem({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 32,
        child: ColoredBox(
          color: const Color(0xFF33373F),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Text(label),
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

/// A window's client area in screen coordinates, which is the only space in
/// which "the popup left the owner" can be asked.
Rect _screenRect(ApplicationWindow window) {
  final Offset origin = window.nativeWindow.clientToScreen(Offset.zero);
  final Size size = window.host.logicalSize;
  return Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height);
}

bool _containsRect(Rect outer, Rect inner) =>
    inner.left >= outer.left &&
    inner.top >= outer.top &&
    inner.right <= outer.right &&
    inner.bottom <= outer.bottom;

/// How far [inner] sticks out of [outer] on each side; zero everywhere is
/// containment.
String _outsideBy(Rect outer, Rect inner) {
  final double left = (outer.left - inner.left).clamp(0, double.infinity);
  final double top = (outer.top - inner.top).clamp(0, double.infinity);
  final double right = (inner.right - outer.right).clamp(0, double.infinity);
  final double bottom = (inner.bottom - outer.bottom).clamp(0, double.infinity);
  return 'l=$left,t=$top,r=$right,b=$bottom';
}

String _rect(Rect rect) => '${_n(rect.left)},${_n(rect.top)} '
    '${_n(rect.width)}x${_n(rect.height)}';

String _n(double value) => value == value.roundToDouble()
    ? '${value.round()}'
    : value.toStringAsFixed(1);

String _device(RenderDevice? device) => device == null
    ? 'none'
    : '${device.runtimeType}#${identityHashCode(device).toRadixString(16)}';
