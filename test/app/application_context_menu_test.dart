/// A right-click has to open a menu on the default path.
///
/// The clipboard bug this file's sibling covers had two halves, and only one
/// was the async chain: the other was that nothing installed the provider, so
/// every field fell back to an unavailable one. A `ContextMenuScope` is the
/// same shape of dependency - a `TextField` outside one answers a secondary
/// press by moving the caret and opening nothing, which reads as a broken
/// field rather than as a missing wrapper.
///
/// So these cases go through `Application.start` with **nothing configured**,
/// exactly as an application written against `runApp` would. A test that
/// installed its own scope would prove the menu works and say nothing about
/// whether anyone gets one.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('the default path', () {
    test('a window root carries a context menu scope', () async {
      final controller = TextEditingController('hello world');
      final application = await _start(controller);

      final ContextMenuController? menu =
          ContextMenuScope.maybeOf(_fieldContext(application));

      expect(
        menu,
        isNotNull,
        reason: 'runApp installs the scope, so a field never has to be told',
      );
      expect(menu!.isOpen, isFalse);

      await _stop(application);
    });

    test('each window owns its own controller, so one menu is one window',
        () async {
      final application = await _start(TextEditingController('a'));
      final second = await application.openWindow(
        rootWidget: ColoredBox(
            color: const Color(0xFF202020),
          child: TextField(controller: TextEditingController('b')),
        ),
        title: 'second',
        size: const Size(200, 60),
      );
      await application.drawPendingFrames();

      final ContextMenuController first =
          ContextMenuScope.of(_fieldContext(application));
      final ContextMenuController other =
          ContextMenuScope.of(_fieldContextOf(second));

      // Two controllers, not one. A menu has a position, and a position only
      // means something inside one window; sharing one would make closing the
      // owning window leave the other pointing at a dismissed popup.
      expect(identical(first, other), isFalse);

      await _stop(application);
    });
  });
}

/// The build context of the window's text field.
BuildContext _fieldContext(Application application) =>
    _fieldContextOf(application.primaryWindow);

BuildContext _fieldContextOf(ApplicationWindow window) {
  BuildContext? found;
  void visit(Element element) {
    if (found != null) return;
    if (element.widget is TextField) {
      found = element;
      return;
    }
    element.visitChildren(visit);
  }

  window.buildOwner.rootElement!.visitChildren(visit);
  if (found == null) {
    throw StateError('no TextField mounted in ${window.id}');
  }
  return found!;
}

Future<Application> _start(TextEditingController controller) async {
  final application = await Application.start(
    rootWidget: ColoredBox(
        color: const Color(0xFF101010),
      child: TextField(controller: controller),
    ),
    backends: <WindowingBackendEntry>[
      const WindowingBackendEntry(
        name: 'headless',
        create: HeadlessWindowingBackend.new,
      ),
    ],
    options: const ApplicationOptions(
      title: 'context menu',
      size: Size(200, 60),
    ),
  );
  await application.drawFrame();
  return application;
}

Future<void> _stop(Application application) async {
  application.dispose();
  await application.closed;
}
