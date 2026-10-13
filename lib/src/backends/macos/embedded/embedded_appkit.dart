/// The AppKit classes the embedded backend registers at runtime, and the
/// callbacks behind their methods.
///
/// Every method is a `NativeCallable.isolateLocal`: AppKit calls it on the
/// main thread, where the embedded runtime keeps the main isolate entered
/// (`embedded_runtime.dart`), so the call runs Dart synchronously and can
/// answer - `windowShouldClose:` returns NO, `acceptsFirstMouse:` YES. None
/// keeps the isolate alive: the program ends when its last port closes, as a
/// standalone one does, whatever AppKit still holds.
///
/// The classes are process-wide and registered once; [MacosEmbeddedClasses.sink]
/// says where their calls go.
library;

import 'dart:ffi';
import 'dart:io' show stderr;

import '../../../ffi/objc_runtime.dart';
import '../../apple/cocoa_ffi.dart';

typedef _Id = Pointer<ObjCObject>;
typedef _Sel = Pointer<ObjCSelector>;
typedef _VoidObjectImp = Void Function(_Id, _Sel, _Id);
typedef _BoolImp = Uint8 Function(_Id, _Sel);
typedef _BoolObjectImp = Uint8 Function(_Id, _Sel, _Id);
typedef _UIntObjectImp = UintPtr Function(_Id, _Sel, _Id);

/// The window notifications the backend follows. Each is a delegate method
/// of the same name, `window…:`, taking the notification.
enum MacosEmbeddedWindowNotification {
  didResize('windowDidResize:'),
  didMove('windowDidMove:'),
  didBecomeKey('windowDidBecomeKey:'),
  didResignKey('windowDidResignKey:'),
  didChangeBackingProperties('windowDidChangeBackingProperties:'),
  didMiniaturize('windowDidMiniaturize:'),
  didDeminiaturize('windowDidDeminiaturize:'),
  didEnterFullScreen('windowDidEnterFullScreen:'),
  didExitFullScreen('windowDidExitFullScreen:'),
  willStartLiveResize('windowWillStartLiveResize:'),
  didEndLiveResize('windowDidEndLiveResize:');

  const MacosEmbeddedWindowNotification(this.selector);

  final String selector;
}

/// The `NSEvent` methods of the content view, with the `NSEventType` each
/// one receives.
const Map<String, int> macosEmbeddedViewEvents = <String, int>{
  'mouseDown:': 1,
  'mouseUp:': 2,
  'rightMouseDown:': 3,
  'rightMouseUp:': 4,
  'mouseMoved:': 5,
  'mouseDragged:': 6,
  'rightMouseDragged:': 7,
  'mouseEntered:': 8,
  'mouseExited:': 9,
  'keyDown:': 10,
  'keyUp:': 11,
  'flagsChanged:': 12,
  'scrollWheel:': 22,
  'otherMouseDown:': 25,
  'otherMouseUp:': 26,
  'otherMouseDragged:': 27,
};

/// Where the classes' calls go: the active backend.
abstract interface class MacosEmbeddedSink {
  /// An `NSEvent` of [type] reached [view].
  void viewEvent(Pointer<ObjCObject> view, Pointer<ObjCObject> event, int type);

  /// [window] posted [notification].
  void windowNotification(
      Pointer<ObjCObject> window, MacosEmbeddedWindowNotification notification);

  /// The close button, Cmd+W or Window > Close. The window stays open; the
  /// framework decides.
  void windowCloseRequested(Pointer<ObjCObject> window);

  void applicationDidFinishLaunching();

  /// Cmd+Q or Quit: the framework is asked to close its windows instead.
  void applicationTerminateRequested();

  /// After every call from AppKit, so what it scheduled runs now.
  void afterNativeCall();
}

/// The classes, once per process.
final class MacosEmbeddedClasses {
  MacosEmbeddedClasses._(
    this.view,
    this.window,
    this.panel,
    this.windowDelegate,
    this.applicationDelegate,
  );

  /// `DartUiEmbeddedView`: the content view of every window.
  final Pointer<ObjCObject> view;

  /// `DartUiEmbeddedWindow`: a top-level window, which may become key even
  /// borderless.
  final Pointer<ObjCObject> window;

  /// `DartUiEmbeddedPanel`: a menu or tooltip, which never becomes key.
  final Pointer<ObjCObject> panel;

  /// `DartUiEmbeddedWindowDelegate`.
  final Pointer<ObjCObject> windowDelegate;

  /// `DartUiEmbeddedAppDelegate`.
  final Pointer<ObjCObject> applicationDelegate;

  static MacosEmbeddedClasses? _instance;

  /// Who receives the calls; the backend sets it in `initialize`.
  static MacosEmbeddedSink? sink;

  static final List<NativeCallable<Function>> _callables =
      <NativeCallable<Function>>[];

  /// Registers the classes the first time; AppKit must be loaded.
  static MacosEmbeddedClasses register() => _instance ??= _register();

  static NativeCallable<T> _keep<T extends Function>(
      NativeCallable<T> callable) {
    // AppKit holds these for the life of the process; the program's own
    // ports decide when it ends.
    callable.keepIsolateAlive = false;
    _callables.add(callable);
    return callable;
  }

  /// Runs [body] for AppKit, never letting an exception unwind into it: an
  /// uncaught one in an isolate-local callback ends the program.
  static void _guard(String what, void Function(MacosEmbeddedSink sink) body) {
    final MacosEmbeddedSink? target = sink;
    if (target == null) return;
    try {
      body(target);
    } on Object catch (error, stack) {
      stderr.writeln('dart_ui embedded: $what threw $error\n$stack');
    }
    try {
      target.afterNativeCall();
    } on Object {
      // Nothing to report from here that would not throw again.
    }
  }

  static MacosEmbeddedClasses _register() {
    final ObjCClassBuilder view =
        ObjCClassBuilder('DartUiEmbeddedView', 'NSView');
    for (final MapEntry<String, int> entry in macosEmbeddedViewEvents.entries) {
      final int type = entry.value;
      view.addMethod(
        selector: entry.key,
        typeEncoding: 'v@:@',
        implementation: _keep(NativeCallable<_VoidObjectImp>.isolateLocal(
            (_Id self, _Sel _, _Id event) => _guard(
                entry.key,
                (MacosEmbeddedSink sink) =>
                    sink.viewEvent(self, event, type)))).nativeFunction,
      );
    }
    view
      ..addMethod(
        selector: 'acceptsFirstResponder',
        typeEncoding: 'B@:',
        implementation: _keep(NativeCallable<_BoolImp>.isolateLocal(
                (_Id self, _Sel _) => 1,
                exceptionalReturn: 1))
            .nativeFunction,
      )
      // The first click on an inactive window, or on a menu panel that never
      // activates, is a click and not only an activation.
      ..addMethod(
        selector: 'acceptsFirstMouse:',
        typeEncoding: 'B@:@',
        implementation: _keep(NativeCallable<_BoolObjectImp>.isolateLocal(
                (_Id self, _Sel _, _Id event) => 1,
                exceptionalReturn: 1))
            .nativeFunction,
      );
    view.register();

    NativeCallable<_BoolImp> answer(bool value) => _keep(value
        ? NativeCallable<_BoolImp>.isolateLocal((_Id self, _Sel _) => 1,
            exceptionalReturn: 1)
        : NativeCallable<_BoolImp>.isolateLocal((_Id self, _Sel _) => 0,
            exceptionalReturn: 0));
    ObjCClassBuilder keyable(String name, String superclass, bool canBeKey) =>
        ObjCClassBuilder(name, superclass)
          ..addMethod(
            selector: 'canBecomeKeyWindow',
            typeEncoding: 'B@:',
            implementation: answer(canBeKey).nativeFunction,
          )
          ..addMethod(
            selector: 'canBecomeMainWindow',
            typeEncoding: 'B@:',
            implementation: answer(canBeKey).nativeFunction,
          );
    // A borderless NSWindow refuses the keyboard by default; an undecorated
    // top-level window still needs it.
    final Pointer<ObjCObject> window =
        keyable('DartUiEmbeddedWindow', 'NSWindow', true).register();
    // A menu leaves the keyboard with its owner, which forwards keys to it.
    final Pointer<ObjCObject> panel =
        keyable('DartUiEmbeddedPanel', 'NSPanel', false).register();

    final ObjCClassBuilder delegate =
        ObjCClassBuilder('DartUiEmbeddedWindowDelegate', 'NSObject');
    for (final MacosEmbeddedWindowNotification notification
        in MacosEmbeddedWindowNotification.values) {
      delegate.addMethod(
        selector: notification.selector,
        typeEncoding: 'v@:@',
        implementation: _keep(NativeCallable<_VoidObjectImp>.isolateLocal(
            (_Id self, _Sel _, _Id note) => _guard(
                notification.selector,
                (MacosEmbeddedSink sink) => sink.windowNotification(
                    objcSendPointer(note, objcSelector('object')),
                    notification)))).nativeFunction,
      );
    }
    delegate.addMethod(
      selector: 'windowShouldClose:',
      typeEncoding: 'B@:@',
      implementation: _keep(NativeCallable<_BoolObjectImp>.isolateLocal(
              (_Id self, _Sel _, _Id sender) {
        _guard('windowShouldClose:',
            (MacosEmbeddedSink sink) => sink.windowCloseRequested(sender));
        return 0;
      }, exceptionalReturn: 0))
          .nativeFunction,
    );
    adoptProtocol(delegate.cls, 'NSWindowDelegate');
    delegate.register();

    final ObjCClassBuilder application =
        ObjCClassBuilder('DartUiEmbeddedAppDelegate', 'NSObject')
          ..addMethod(
            selector: 'applicationDidFinishLaunching:',
            typeEncoding: 'v@:@',
            implementation: _keep(NativeCallable<_VoidObjectImp>.isolateLocal(
                (_Id self, _Sel _, _Id note) => _guard(
                    'applicationDidFinishLaunching:',
                    (MacosEmbeddedSink sink) =>
                        sink.applicationDidFinishLaunching()))).nativeFunction,
          )
          // NSTerminateCancel: the framework closes its windows, and the
          // program ends when they are gone.
          ..addMethod(
            selector: 'applicationShouldTerminate:',
            typeEncoding: 'Q@:@',
            implementation: _keep(NativeCallable<_UIntObjectImp>.isolateLocal(
                    (_Id self, _Sel _, _Id sender) {
              _guard(
                  'applicationShouldTerminate:',
                  (MacosEmbeddedSink sink) =>
                      sink.applicationTerminateRequested());
              return 0;
            }, exceptionalReturn: 0))
                .nativeFunction,
          )
          // Without it macOS 14+ warns that restorable state is insecure.
          ..addMethod(
            selector: 'applicationSupportsSecureRestorableState:',
            typeEncoding: 'B@:@',
            implementation: _keep(NativeCallable<_BoolObjectImp>.isolateLocal(
                    (_Id self, _Sel _, _Id app) => 1,
                    exceptionalReturn: 1))
                .nativeFunction,
          );
    adoptProtocol(application.cls, 'NSApplicationDelegate');
    application.register();

    return MacosEmbeddedClasses._(
      view.cls,
      window,
      panel,
      delegate.cls,
      application.cls,
    );
  }
}
