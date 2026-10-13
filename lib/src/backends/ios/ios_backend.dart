/// iOS, in the app's own process (ADR 0010).
///
/// The app's executable is the Dart AOT runtime built for iOS; its patch
/// handles the main isolate's messages on the main thread and, once the class
/// `DartUiAppDelegate` exists, runs `UIApplicationMain` with it. This backend
/// registers that class and the rest - the scene delegate and `DartUiView` -
/// so UIKit drives the application and calls back into Dart synchronously,
/// with `NativeCallable.isolateLocal`, on the thread the isolate lives on.
///
/// One window: the scene's. Menus and popups open inside it.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import '../../ffi/objc_runtime.dart';
import '../../foundation/diagnostics.dart';
import '../../platform/native_window.dart';
import '../../platform/text_input.dart';
import '../../platform/window_events.dart';
import 'ios_uikit.dart';
import 'ios_window.dart';

typedef _Id = Pointer<ObjCObject>;
typedef _Sel = Pointer<ObjCSelector>;
typedef _VoidImp = Void Function(_Id, _Sel);
typedef _BoolImp = Uint8 Function(_Id, _Sel);
typedef _ObjectImp = Void Function(_Id, _Sel, _Id);
typedef _TwoObjectsImp = Void Function(_Id, _Sel, _Id, _Id);
typedef _TwoObjectsBoolImp = Uint8 Function(_Id, _Sel, _Id, _Id);
typedef _ThreeObjectsImp = Void Function(_Id, _Sel, _Id, _Id, _Id);

final class IosWindowingBackend
    implements WindowingBackend, EventLoopWaitingBackend, TextInputProvider {
  IosWindowingBackend();

  /// The classes are process-wide; one backend registers them.
  static _Classes? _classes;
  static IosWindowingBackend? _active;

  /// A port this isolate sends to itself after every UIKit callback.
  ///
  /// UIKit calls into Dart outside any message: the isolate is entered on the
  /// main thread but not handling one, so whatever the callback scheduled -
  /// a future's completion, a stream event - waits in the microtask queue
  /// until the next message. Without this the scene's arrival would be seen
  /// at the next timer, seconds later. One empty message makes the runtime's
  /// loop turn, and the microtasks run at its end.
  static final RawReceivePort _kick = RawReceivePort((_) {}, 'dart_ui ios');

  static void _flushMicrotasks() => _kick.sendPort.send(null);

  final List<IosWindow> _windows = <IosWindow>[];
  final Completer<_Id> _scene = Completer<_Id>();
  Completer<void>? _waiter;
  var _nextWindowId = 1;
  var _quitRequested = false;

  @override
  String get name => 'ios';

  @override
  BackendProbeResult probe() {
    if (!Platform.isIOS) {
      return BackendProbeResult.unsupported(
        name,
        const BackendDiagnostic(
          kind: DiagnosticKind.missingLibrary,
          message: 'not iOS',
        ),
      );
    }
    return BackendProbeResult(
      backendName: name,
      supported: true,
      capabilities: const <Capability>{
        Capability.window,
        Capability.cpuPresentation,
        Capability.pointerInput,
        Capability.keyboardInput,
        Capability.textComposition,
        Capability.orderlyShutdown,
      },
      diagnostics: const <BackendDiagnostic>[
        BackendDiagnostic.note('UIKit on the main thread, through the runtime '
            'patch of ADR 0010; one window, menus inside it'),
      ],
    );
  }

  @override
  Future<void> initialize() async {
    _active = this;
    _classes ??= _Classes.register();
    final _Id? scene = _classes!.connectedScene;
    if (scene != null && !_scene.isCompleted) _scene.complete(scene);
    // UIApplicationMain starts once the delegate class exists; the scene
    // connects on a later turn of the run loop.
    await _scene.future.timeout(const Duration(seconds: 30));
  }

  void _sceneConnected(_Id scene) {
    if (!_scene.isCompleted) _scene.complete(scene);
    _flushMicrotasks();
  }

  @override
  Future<NativeWindow> createWindow(WindowOptions options) async {
    if (_windows.isNotEmpty) {
      throw UnsupportedError(
          'an iOS scene is one window; this backend has it already');
    }
    final _Id scene = await _scene.future;
    final _Id view = objcSendPointer(
        objcSendPointer(_classes!.view, objcSelector('alloc')),
        objcSelector('init'));
    final IosWindow window = IosWindow(
      id: NativeWindowId(_nextWindowId++),
      scene: scene,
      view: view,
      onClosed: _windows.remove,
      onEvent: _notify,
    );
    _windows.add(window);
    if (options.visible) window.show();
    return window;
  }

  IosWindow? _windowOf(_Id view) {
    for (final IosWindow window in _windows) {
      if (window.view.address == view.address) return window;
    }
    return null;
  }

  @override
  List<NativeWindow> get windows => List<NativeWindow>.unmodifiable(_windows);

  @override
  TextInputBackend get textInput => const IosTextInputBackend();

  /// UIKit delivers on this thread between Dart turns; nothing to wait on.
  @override
  bool pumpEvents({Duration timeout = Duration.zero}) => !_quitRequested;

  @override
  Future<void> waitForEvents(Duration timeout) {
    final Completer<void> waiter = _waiter ??= Completer<void>();
    final Timer timer = Timer(timeout, () {
      if (!waiter.isCompleted) waiter.complete();
    });
    return waiter.future.whenComplete(() {
      timer.cancel();
      if (identical(_waiter, waiter)) _waiter = null;
    });
  }

  void _notify() {
    final Completer<void>? waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    _flushMicrotasks();
  }

  @override
  void wake() => _notify();

  @override
  Future<void> shutdown() async {
    for (final IosWindow window in List<IosWindow>.of(_windows)) {
      window.dispose();
    }
    _quitRequested = true;
    if (identical(_active, this)) _active = null;
  }
}

/// The three classes UIKit instantiates or calls: the app delegate, the
/// scene delegate, and the view. Their methods are isolate-local callables:
/// UIKit invokes them on the main thread, where the isolate is entered.
final class _Classes {
  _Classes._(this.view);

  final _Id view;
  _Id? connectedScene;
  final List<Object> _callables = <Object>[];

  static _Classes register() {
    tryLoadObjCRuntime();
    uikit; // UIKit's classes must exist before they are subclassed.
    late final _Classes classes;

    NativeCallable<T> keep<T extends Function>(NativeCallable<T> callable) {
      classes._callables.add(callable);
      return callable;
    }

    final ObjCClassBuilder view = ObjCClassBuilder('DartUiView', 'UIView');
    classes = _Classes._(view.cls);

    void touches(String selector, int phase) {
      view.addMethod(
        selector: selector,
        typeEncoding: 'v@:@@',
        implementation: keep(NativeCallable<_TwoObjectsImp>.isolateLocal(
            (_Id self, _Sel _, _Id set, _Id event) => IosWindowingBackend
                ._active
                ?._windowOf(self)
                ?.touches(phase, set))).nativeFunction,
      );
    }

    touches('touchesBegan:withEvent:', 0);
    touches('touchesMoved:withEvent:', 1);
    touches('touchesEnded:withEvent:', 2);
    touches('touchesCancelled:withEvent:', 3);
    view
      ..addMethod(
        selector: 'layoutSubviews',
        typeEncoding: 'v@:',
        implementation: keep(NativeCallable<_VoidImp>.isolateLocal((_Id self,
                    _Sel _) =>
                IosWindowingBackend._active?._windowOf(self)?.layoutChanged()))
            .nativeFunction,
      )
      ..addMethod(
        selector: 'canBecomeFirstResponder',
        typeEncoding: 'B@:',
        implementation: keep(NativeCallable<_BoolImp>.isolateLocal(
                (_Id self, _Sel _) => 1,
                exceptionalReturn: 0))
            .nativeFunction,
      )
      ..addMethod(
        selector: 'hasText',
        typeEncoding: 'B@:',
        implementation: keep(NativeCallable<_BoolImp>.isolateLocal(
                (_Id self, _Sel _) => 1,
                exceptionalReturn: 0))
            .nativeFunction,
      )
      ..addMethod(
        selector: 'insertText:',
        typeEncoding: 'v@:@',
        implementation: keep(NativeCallable<_ObjectImp>.isolateLocal(
            (_Id self, _Sel _, _Id text) {
          final String value = objcReadCString(
              objcSendPointer(text, objcSelector('UTF8String')).cast());
          IosWindowingBackend._active?._windowOf(self)?.insertText(value);
        })).nativeFunction,
      )
      ..addMethod(
        selector: 'deleteBackward',
        typeEncoding: 'v@:',
        implementation: keep(NativeCallable<_VoidImp>.isolateLocal((_Id self,
                    _Sel _) =>
                IosWindowingBackend._active?._windowOf(self)?.deleteBackward()))
            .nativeFunction,
      );
    adoptProtocol(view.cls, 'UIKeyInput');
    view.register();

    final ObjCClassBuilder scene =
        ObjCClassBuilder('DartUiSceneDelegate', 'UIResponder')
          ..addMethod(
            selector: 'scene:willConnectToSession:options:',
            typeEncoding: 'v@:@@@',
            implementation: keep(NativeCallable<_ThreeObjectsImp>.isolateLocal(
                (_Id self, _Sel _, _Id scene, _Id session, _Id options) {
              classes.connectedScene = scene;
              IosWindowingBackend._active?._sceneConnected(scene);
            })).nativeFunction,
          );
    adoptProtocol(scene.cls, 'UIWindowSceneDelegate');
    scene.register();

    // Registered last: its existence is what lets the runtime start
    // UIApplicationMain, and by then every class above is in place.
    final ObjCClassBuilder app =
        ObjCClassBuilder('DartUiAppDelegate', 'UIResponder')
          ..addMethod(
            selector: 'application:didFinishLaunchingWithOptions:',
            typeEncoding: 'B@:@@',
            implementation: keep(
                    NativeCallable<_TwoObjectsBoolImp>.isolateLocal(
                        (_Id self, _Sel _, _Id app, _Id options) => 1,
                        exceptionalReturn: 0))
                .nativeFunction,
          );
    adoptProtocol(app.cls, 'UIApplicationDelegate');
    app.register();
    return classes;
  }
}

final class IosTextInputBackend implements TextInputBackend {
  const IosTextInputBackend();

  @override
  String get name => 'uikeyinput';

  @override
  bool get supportsComposition => true;

  @override
  bool get usesSurroundingText => false;

  @override
  TextInputConnection attach({
    required NativeWindow window,
    required TextInputClient client,
  }) {
    if (window is! IosWindow) {
      throw TextInputException(
        operation: 'attach',
        reason: 'the iOS keyboard needs the scene window; it was given a '
            '${window.runtimeType}',
        backend: name,
      );
    }
    final _IosTextInputConnection connection =
        _IosTextInputConnection(window, client);
    window.textInput = connection;
    return connection;
  }
}

final class _IosTextInputConnection
    implements TextInputConnection, IosImeHandler {
  _IosTextInputConnection(this._window, this._client);

  final IosWindow _window;
  final TextInputClient _client;
  bool _attached = true;
  bool _enabled = false;

  @override
  NativeWindowId get windowId => _window.id;

  @override
  bool get isAttached => _attached;

  @override
  bool get isEnabled => _enabled;

  @override
  void enable() {
    if (!_attached) return;
    _enabled = true;
    _window.showKeyboard(show: true);
  }

  @override
  void disable() {
    if (!_attached || !_enabled) return;
    _enabled = false;
    _window.showKeyboard(show: false);
  }

  @override
  void updateEditingState() {}

  @override
  void cancelComposition() {}

  @override
  void detach() {
    if (!_attached) return;
    disable();
    _attached = false;
    if (identical(_window.textInput, this)) _window.textInput = null;
  }

  @override
  void onCommit(String text) => _client.commitText(text);
}
