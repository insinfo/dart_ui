/// Android, through the host activity that started this process.
///
/// The process is a child of `DartUiActivity` (`android/host/`): the activity
/// keeps Android's UI thread, its `SurfaceView` and its input, and this side
/// draws. The host passes the name of an abstract Unix socket in
/// `DART_UI_ANDROID_SOCKET`; everything after that is the protocol in
/// `android_host_protocol.dart`.
///
/// No JNI and no native library of our own: the Dart VM is a plain
/// executable the activity starts from its native-library directory, and the
/// host is Java. That keeps the roadmap's rule for the runtime (section 2.2)
/// and mirrors the macOS host of ADR 0001.
library;

import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../../foundation/diagnostics.dart';
import '../../platform/native_window.dart';
import '../../platform/text_input.dart';
import '../../platform/window_events.dart';
import '../wayland/wayland_libc.dart';
import '../wayland/wayland_transport.dart';
import 'android_host_protocol.dart';
import 'android_shared_memory.dart';
import 'android_text_input.dart';
import 'android_window.dart';

/// The environment variable that carries the host's socket name.
const String androidHostSocketVariable = 'DART_UI_ANDROID_SOCKET';

final class AndroidWindowingBackend
    implements WindowingBackend, AndroidHostLink, TextInputProvider {
  AndroidWindowingBackend({Map<String, String>? environment})
      : _environment = environment ?? Platform.environment;

  final Map<String, String> _environment;
  final List<AndroidWindow> _windows = <AndroidWindow>[];
  final ListQueue<AndroidHostEvent> _early = ListQueue<AndroidHostEvent>();
  final List<int> _receivedFds = <int>[];
  WaylandSocketTransport? _transport;
  late final AndroidHostDecoder _decoder = AndroidHostDecoder(_onHostEvent);
  AndroidHelloEvent? _hello;
  var _nextWindowId = 1;
  var _quitRequested = false;
  var _initialized = false;

  @override
  String get name => 'android';

  @override
  BackendProbeResult probe() {
    if (!Platform.isAndroid) {
      return BackendProbeResult.unsupported(
        name,
        const BackendDiagnostic(
          kind: DiagnosticKind.missingLibrary,
          message: 'not Android',
        ),
      );
    }
    final String? socket = _environment[androidHostSocketVariable];
    if (socket == null || socket.isEmpty) {
      return BackendProbeResult.unsupported(
        name,
        const BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'not started by the dart_ui Android host '
              '($androidHostSocketVariable is unset)',
        ),
      );
    }
    return BackendProbeResult(
      backendName: name,
      supported: true,
      capabilities: const <Capability>{
        Capability.window,
        Capability.cpuPresentation,
        Capability.keyboardInput,
        Capability.pointerInput,
        Capability.scrollInput,
        Capability.textComposition,
        Capability.orderlyShutdown,
      },
      diagnostics: <BackendDiagnostic>[
        BackendDiagnostic.note('host socket @$socket'),
        const BackendDiagnostic.note(
            'one window: the activity; menus open inside it'),
      ],
    );
  }

  /// Connects and waits for the host's banner.
  ///
  /// The socket is libc's, through the Wayland backend's transport, not
  /// `dart:io`'s: frames leave with shared-memory descriptors attached, and
  /// `dart:io` can attach only descriptors of files it opened itself - while
  /// SELinux forbids an app to reopen its own memfd through `/proc/self/fd`.
  @override
  Future<void> initialize() async {
    if (_initialized) return;
    final List<BackendDiagnostic> diagnostics = <BackendDiagnostic>[];
    final WaylandLibc? libc = WaylandLibc.open(diagnostics);
    if (libc == null) {
      throw StateError('Android host: libc unavailable '
          '(${diagnostics.map((d) => d.message).join('; ')})');
    }
    final String socketName = _environment[androidHostSocketVariable] ?? '';
    final WaylandTransportAttempt attempt =
        WaylandSocketTransport.open(libc: libc, socketPath: '@$socketName');
    final WaylandSocketTransport? transport =
        attempt.transport as WaylandSocketTransport?;
    if (transport == null) {
      throw StateError('Android host: '
          '${attempt.diagnostics.map((d) => '${d.message} ${d.detail ?? ''}').join('; ')}');
    }
    _transport = transport;
    final Stopwatch waited = Stopwatch()..start();
    while (_hello == null) {
      if (waited.elapsed > const Duration(seconds: 10)) {
        throw StateError('Android host sent no banner in 10 s');
      }
      transport.waitForActivity(100);
      if (!_receive()) throw StateError('Android host closed the socket');
      // Let the event loop breathe between polls of a slow host.
      await Future<void>.delayed(Duration.zero);
    }
    final AndroidHelloEvent hello = _hello!;
    if (hello.version != kAndroidHostProtocolVersion) {
      throw StateError('Android host speaks protocol ${hello.version}, '
          'this backend $kAndroidHostProtocolVersion');
    }
    _initialized = true;
  }

  /// Reads whatever arrived. False when the host is gone.
  bool _receive() {
    final WaylandSocketTransport? transport = _transport;
    if (transport == null) return false;
    final int received = transport.receiveBytes((Uint8List bytes, int length) {
      try {
        _decoder.add(Uint8List.sublistView(bytes, 0, length));
      } on FormatException {
        _quitRequested = true;
      }
    }, _receivedFds);
    // The host sends no descriptors; anything that arrives is closed.
    for (final int fd in _receivedFds) {
      transport.closeFd(fd);
    }
    _receivedFds.clear();
    if (received < 0) {
      // The host finished the activity: nothing left to draw into.
      _quitRequested = true;
      return false;
    }
    return true;
  }

  void _onHostEvent(AndroidHostEvent event) {
    if (event is AndroidHelloEvent) {
      _hello ??= event;
      return;
    }
    if (_windows.isEmpty) {
      // Before the window exists only the latest size matters.
      if (event is AndroidResizedEvent) _early.add(event);
      return;
    }
    for (final AndroidWindow window in List<AndroidWindow>.of(_windows)) {
      window.handle(event);
    }
  }

  @override
  void send(Uint8List frame, {AndroidSharedBuffer? buffer}) {
    final WaylandSocketTransport? transport = _transport;
    if (transport == null || !transport.isOpen) return;
    transport.queueMessage(frame, <int>[if (buffer != null) buffer.fd]);
    if (!transport.flush()) _quitRequested = true;
  }

  @override
  TextInputBackend get textInput => const AndroidTextInputBackend();

  @override
  Future<NativeWindow> createWindow(WindowOptions options) async {
    if (!_initialized) throw StateError('$name.createWindow before initialize');
    if (_windows.isNotEmpty) {
      throw UnsupportedError(
          'an Android activity is one window; this backend has it already');
    }
    final AndroidHelloEvent hello = _hello!;
    var widthPx = hello.widthPx;
    var heightPx = hello.heightPx;
    var density = hello.density;
    while (_early.isNotEmpty) {
      final AndroidHostEvent early = _early.removeFirst();
      if (early is AndroidResizedEvent) {
        widthPx = early.widthPx;
        heightPx = early.heightPx;
        density = early.density;
      }
    }
    final AndroidWindow window = AndroidWindow(
      id: NativeWindowId(_nextWindowId++),
      link: this,
      widthPx: widthPx,
      heightPx: heightPx,
      density: density,
      title: options.title,
      onClosed: _onWindowClosed,
    );
    _windows.add(window);
    if (options.visible) window.show();
    return window;
  }

  void _onWindowClosed(AndroidWindow window) {
    _windows.remove(window);
    if (_windows.isEmpty) {
      _quitRequested = true;
      send(AndroidHostEncoder.quit());
    }
  }

  @override
  List<NativeWindow> get windows => List<NativeWindow>.unmodifiable(_windows);

  /// Waits up to [timeout] for the host, then hands over what arrived.
  @override
  bool pumpEvents({Duration timeout = Duration.zero}) {
    final WaylandSocketTransport? transport = _transport;
    if (transport == null || _quitRequested) return false;
    transport.waitForActivity(timeout.inMilliseconds);
    _receive();
    return !_quitRequested;
  }

  @override
  void wake() => _transport?.signalWake();

  @override
  Future<void> shutdown() async {
    for (final AndroidWindow window in List<AndroidWindow>.of(_windows)) {
      window.dispose();
    }
    _transport?.flush();
    _transport?.dispose();
    _transport = null;
    _initialized = false;
  }
}
