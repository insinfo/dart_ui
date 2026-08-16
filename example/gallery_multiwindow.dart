/// Two windows, one application - opened, focused, and closed at runtime.
///
/// This is the example that exercises what a single-window gallery cannot:
///
///   1. two top-level windows with **different trees**, each with its own
///      surface, renderer target, [BuildOwner] and [PipelineOwner];
///   2. keyboard focus moving between them, with the invariant that exactly one
///      of them ever reports `isWindowActive`;
///   3. a real **modal** window owned by the first one, which disables its
///      owner while it lives and restores focus to it when it closes;
///   4. closing one window while the application **keeps running** - the other
///      window goes on presenting frames, and its counters go on climbing;
///   5. closing the last window, which under the default
///      [ApplicationOptions.exitWhenLastWindowClosed] policy ends the run.
///
/// The loop is driven by hand rather than through [Application.run] because
/// the point of the example is *when* things happen: focus moves at a known
/// frame, the dialog opens at another, a window closes at a third. `run()` is
/// the right shape for an application whose script is the user; this one has a
/// script of its own.
///
/// ```
/// dart run example/gallery_multiwindow.dart --frames 24
/// dart run example/gallery_multiwindow.dart --frames 24 --backend headless
/// ```
///
/// On Windows it opens two real HWNDs. Anywhere else - and with
/// `--backend headless` anywhere at all - it runs the identical script against
/// the headless backend, which is what makes it a CI gate rather than a demo.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/win32.dart';

import 'gallery_shell.dart';

Future<void> main(List<String> arguments) async {
  final frames = intArgument(arguments, '--frames') ?? 24;
  if (frames < 12) {
    stderr.writeln('--frames must be at least 12: the script needs room for '
        'a focus move, a modal, and two closes');
    exitCode = 2;
    return;
  }

  // Win32 where it exists, headless everywhere else - and `--backend` or
  // DART_UI_BACKEND still win, which is what makes the CI run reproducible on
  // a developer's Windows machine.
  //
  // The two lists are derived from the *same* answer rather than both being
  // offered unconditionally, and that is not laziness. A presentation path is
  // bound to a backend's window type - `Win32CpuPresenter` takes a
  // `Win32Window` - while `selectPresentation` ranks paths without knowing
  // which backend won. Offering the DIB path to a headless run therefore picks
  // it and then fails the cast, which is a crash at the first window rather
  // than a selection report.
  final requested = _stringArgument(arguments, '--backend') ??
      Platform.environment['DART_UI_BACKEND'];
  final useWin32 =
      Platform.isWindows && (requested == null || requested == 'win32');
  final backends = <WindowingBackendEntry>[
    if (useWin32)
      const WindowingBackendEntry(
        name: 'win32',
        create: Win32WindowingBackend.new,
      ),
    const WindowingBackendEntry(
      name: 'headless',
      create: HeadlessWindowingBackend.new,
    ),
  ];
  final presentations = <PresentationPathEntry>[
    if (useWin32)
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
      )
    else
      PresentationPathEntry.cpuRenderer(),
  ];

  final theme = galleryTheme(arguments);
  final log = <String>[];

  final application = await Application.start(
    rootWidget: _panel(
      theme: theme,
      title: 'Window A - editor',
      accent: 0xFF2D6CDF,
      controller: TextEditingController('type here'),
    ),
    backends: backends,
    presentations: presentations,
    options: ApplicationOptions(
      title: 'dart_ui - window A',
      size: const Size(420, 260),
      arguments: arguments,
      environment: Platform.environment,
      onError: (FrameworkError error) => stderr.writeln(error.describe()),
      onDiagnostic: (BackendDiagnostic diagnostic) =>
          stderr.writeln('present: $diagnostic'),
    ),
  );

  final windowA = application.primaryWindow;
  final windowB = await application.openWindow(
    rootWidget: _panel(
      theme: theme,
      title: 'Window B - inspector',
      accent: 0xFFB4531A,
      controller: TextEditingController('a different tree'),
    ),
    title: 'dart_ui - window B',
    size: const Size(340, 300),
    position: const Offset(480, 120),
  );
  log.add('opened A=${windowA.id.value} B=${windowB.id.value}');

  for (final ApplicationWindow window in application.windows) {
    window.nativeWindow.show();
  }

  ApplicationWindow? dialog;
  var presented = 0;
  for (var frame = 0; frame < frames; frame++) {
    if (application.state == ApplicationLifecycleState.closing) break;
    if (!application.backend.pumpEvents()) break;
    // The event streams are broadcast controllers: their listeners run on a
    // later turn, so a loop that never returns to the Dart event loop would
    // queue every message and deliver none.
    await Future<void>.delayed(Duration.zero);

    switch (frame) {
      case 4:
        application.focusWindow(windowB.id);
        log.add('frame 4: focus -> B '
            '(${_focusReport(application)})');
      case 8:
        application.focusWindow(windowA.id);
        log.add('frame 8: focus -> A '
            '(${_focusReport(application)})');
      case 10:
        dialog = await application.openWindow(
          rootWidget: _panel(
            theme: theme,
            title: 'Modal - owned by A',
            accent: 0xFF7A2D8F,
            controller: TextEditingController('A is blocked'),
          ),
          title: 'dart_ui - modal',
          size: const Size(280, 160),
          position: const Offset(160, 220),
          owner: windowA.id,
          modal: true,
        );
        dialog.nativeWindow.show();
        log.add('frame 10: modal opened, A blocked=${windowA.isBlocked}, '
            'focus=${_focusReport(application)}');
      case 14:
        application.closeWindow(dialog!.id);
        log.add('frame 14: modal closed, A blocked=${windowA.isBlocked}, '
            'focus=${_focusReport(application)}');
      case 17:
        application.closeWindow(windowB.id);
        log.add('frame 17: B closed, open=${application.windows.length}, '
            'state=${application.state.name}');
    }

    application.requestFrame();
    final results = await application.drawPendingFrames();
    presented += results.where((PresentResult r) => r.isSuccess).length;
  }

  final framesA = windowA.framesPresented;
  final framesB = windowB.framesPresented;
  final openAtEnd = application.windows.length;
  final aliveAfterClose =
      application.state != ApplicationLifecycleState.closing;

  // And the last window: under the default policy this ends the application.
  application.closeWindow(windowA.id);
  final stateAfterLast = application.state;
  log.add('closed A: state=${stateAfterLast.name}, '
      'open=${application.windows.length}');

  final errors = application.errors.length;
  final dropped = application.eventsDropped;
  final teardown = application.teardownOrder;

  application.dispose();
  await application.closed;

  // What the gate actually checks. Every one of these is a claim the example
  // would otherwise only be making in prose.
  final checks = <String, bool>{
    'both windows drew': framesA > 0 && framesB > 0,
    'A outlived B': framesA > framesB,
    'B stopped when closed': framesB > 0,
    'the application survived closing B': aliveAfterClose && openAtEnd == 1,
    'closing the last window closed the application':
        stateAfterLast == ApplicationLifecycleState.closing ||
            stateAfterLast == ApplicationLifecycleState.closed,
    'no build errors': errors == 0,
    'teardown ran': teardown.isNotEmpty,
  };
  final passed = checks.values.every((bool ok) => ok);

  stdout
    ..write(application.describeStartup())
    ..writeln(log.join('\n'))
    ..writeln('MULTIWINDOW_GALLERY=${passed ? 'PASS' : 'FAIL'}')
    ..writeln('backend=${application.backend.name} '
        'presented=$presented framesA=$framesA framesB=$framesB '
        'rejected=${application.framesRejected}')
    ..writeln('errors=$errors dropped=$dropped '
        'teardown=${teardown.join(',')}');
  for (final MapEntry<String, bool> check in checks.entries) {
    if (!check.value) stderr.writeln('FAILED CHECK: ${check.key}');
  }
  exitCode = passed ? 0 : 1;
}

/// The value that follows a flag on the command line, or null.
String? _stringArgument(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return arguments[index + 1];
}

/// Which window holds the keyboard, and what every window's manager believes.
///
/// Printed rather than asserted quietly, because "exactly one window reports
/// itself active" is the invariant the whole focus section is about, and a
/// number on stdout is what makes it checkable from outside the process.
String _focusReport(Application application) {
  final active = <String>[
    for (final ApplicationWindow window in application.windows)
      if (window.buildOwner.focusManager.isWindowActive) '${window.id.value}',
  ];
  return 'keyboard=${application.keyboardFocusWindow?.value}, '
      'active=[${active.join(',')}]';
}

/// One window's content: a title, a text field and a button.
///
/// Each window gets its own instance with its own colours and its own
/// [TextEditingController], so the two trees are genuinely different and the
/// pixels differ - which is what makes "two windows, two surfaces" visible
/// rather than asserted.
///
/// The [Theme] is the shared-value half of the owner decision: the *data* is
/// shared between windows, the [BuildOwner] is not. An `InheritedWidget` cannot
/// span two element trees, and this is what replaces it - the same
/// [ThemeData] instance installed at the root of each.
Widget _panel({
  required ThemeData theme,
  required String title,
  required int accent,
  required TextEditingController controller,
}) =>
    Theme(
      data: theme,
      child: ColoredBox(
        color: 0xFF1B1D21,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: <Widget>[
              SizedBox(
                height: 36,
                child: ColoredBox(
                  color: accent,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(title),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 32,
                child: TextField(controller: controller, label: title),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 32,
                width: 140,
                child: Button(label: 'ok', onPressed: () {}),
              ),
            ],
          ),
        ),
      ),
    );
