/// The standard automation host: an application's commands, its menus and
/// one of its windows, for a [ControlServer].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../app/application.dart';
import '../commands/command.dart';
import '../commands/command_registry.dart';
import '../commands/menu_spec.dart';
import '../geometry/offset.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../graphics/image/png_encoder.dart';
import '../platform/input_events.dart';
import '../platform/window_events.dart';
import '../rendering/cpu_renderer.dart';
import '../rendering/framebuffer.dart';
import '../rendering/renderer.dart';
import 'control_server.dart';

/// Answers the control protocol for [window] and [registry]:
///
/// | method | params | result |
/// |---|---|---|
/// | `engine.commands` | | every command: id, label, shortcut, params, enabled |
/// | `engine.execute` | `{command, params?}` | the command's result |
/// | `engine.batch` | `{steps: [{command, params?}], label?}` | every step's result, as one undo step |
/// | `ui.menu.list` | | every menu row: path, label, command, enabled, checked |
/// | `ui.contextMenu.list` | | the right-click menu for the current state |
/// | `ui.inspect` | | window size, plus what the application adds |
/// | `document.inspect` | | what the application says its document is |
/// | `ui.pointer` | `{events: [{kind, x, y, button?}]}` | drives the pointer: `move`, `down`, `up`, `click`, `doubleclick`, `rightclick` |
/// | `ui.key` | `{key, shift?, alt?, ctrl?, meta?, cmd?}` | presses and releases a key |
/// | `ui.text` | `{text}` | types text into the focused field |
/// | `ui.screenshot` | `{path?}` | the window as PNG, written to `path` or returned as base64 |
///
/// Coordinates are the window's logical pixels, top-left origin. `cmd` is
/// the platform's command key: Command on a Mac, Control elsewhere.
final class WindowAutomation implements AutomationHost {
  WindowAutomation({
    required this.application,
    required this.window,
    required this.registry,
    this.menus,
    this.contextMenu,
    this.inspect,
    this.document,
  });

  final Application application;
  final ApplicationWindow window;
  final CommandRegistry registry;

  /// The menu bar, as menu descriptions.
  final List<SubmenuSpec> Function()? menus;

  /// The right-click menu for the current state.
  final List<MenuSpecEntry> Function()? contextMenu;

  /// What the application adds to `ui.inspect`.
  final Map<String, Object?> Function()? inspect;

  /// The application's answer to `document.inspect`.
  final Object? Function()? document;

  int _clock = 0;

  Duration get _now => Duration(milliseconds: _clock += 8);

  @override
  Iterable<String> get methods => const <String>[
        'app.methods',
        'engine.commands',
        'engine.execute',
        'engine.batch',
        'ui.menu.list',
        'ui.contextMenu.list',
        'ui.inspect',
        'document.inspect',
        'ui.pointer',
        'ui.key',
        'ui.text',
        'ui.screenshot',
      ];

  @override
  FutureOr<Object?> handle(String method, Map<String, Object?> params) {
    switch (method) {
      case 'engine.commands':
        return registry.describe();
      case 'engine.execute':
        final Object? command = params['command'];
        if (command is! String) {
          throw const CommandError('`command` names the command to run');
        }
        return _outcome(registry.execute(command, _map(params['params'])));
      case 'engine.batch':
        final Object? steps = params['steps'];
        if (steps is! List) {
          throw const CommandError('`steps` is a list of {command, params}');
        }
        return _outcome(registry.batch(
          <({String command, Map<String, Object?> params})>[
            for (final Object? step in steps)
              if (step is Map && step['command'] is String)
                (
                  command: step['command'] as String,
                  params: _map(step['params'])
                )
              else
                throw const CommandError('every step is {command, params?}'),
          ],
          label:
              params['label'] is String ? params['label']! as String : 'Batch',
        ));
      case 'ui.menu.list':
        final List<SubmenuSpec> Function()? bar = menus;
        if (bar == null) return const <Object?>[];
        return <Object?>[
          for (final MenuRow row in MenuBuilder(registry).flatten(bar()))
            row.toJson(),
        ];
      case 'ui.contextMenu.list':
        final List<MenuSpecEntry> Function()? context = contextMenu;
        if (context == null) return const <Object?>[];
        return <Object?>[
          for (final MenuRow row in MenuBuilder(registry).flatten(context()))
            row.toJson(),
        ];
      case 'ui.inspect':
        final Size size = window.host.logicalSize;
        return <String, Object?>{
          'width': size.width,
          'height': size.height,
          'scale': window.host.renderScale,
          ...?inspect?.call(),
        };
      case 'document.inspect':
        return document?.call();
      case 'ui.pointer':
        return _pointer(params);
      case 'ui.key':
        return _key(params);
      case 'ui.text':
        final Object? text = params['text'];
        if (text is! String) throw const CommandError('`text` is a string');
        application.handleEvent(TextInputEvent(
          windowId: window.id,
          generation: window.nativeWindow.generation,
          timestamp: _now,
          text: text,
        ));
        return null;
      case 'ui.screenshot':
        return _screenshot(params);
    }
    throw CommandError('unknown method `$method`; `app.methods` lists them');
  }

  static Map<String, Object?> _map(Object? value) {
    if (value == null) return const <String, Object?>{};
    if (value is Map<String, Object?>) return value;
    if (value is Map) {
      return <String, Object?>{
        for (final MapEntry<Object?, Object?> e in value.entries)
          '${e.key}': e.value,
      };
    }
    throw const CommandError('`params` must be an object');
  }

  static Object? _outcome(CommandOutcome outcome) {
    if (!outcome.ok) throw CommandError(outcome.error ?? 'failed');
    return outcome.result;
  }

  // --- pointer ----------------------------------------------------------------

  Object? _pointer(Map<String, Object?> params) {
    final Object? events = params['events'];
    if (events is! List) {
      throw const CommandError('`events` is a list of {kind, x, y}');
    }
    for (final Object? raw in events) {
      if (raw is! Map) throw const CommandError('an event is {kind, x, y}');
      final Object? kind = raw['kind'];
      final Object? x = raw['x'];
      final Object? y = raw['y'];
      if (kind is! String || x is! num || y is! num) {
        throw const CommandError('an event is {kind, x, y}');
      }
      final Offset at = Offset(x.toDouble(), y.toDouble());
      final PointerButton button = switch (raw['button']) {
        'right' => PointerButton.secondary,
        'middle' => PointerButton.middle,
        _ => kind == 'rightclick'
            ? PointerButton.secondary
            : PointerButton.primary,
      };
      switch (kind) {
        case 'move':
          _send(_move(at));
        case 'down':
          _send(_down(at, button, 1));
        case 'up':
          _send(_up(at, button));
        case 'click' || 'rightclick':
          _send(_down(at, button, 1));
          _send(_up(at, button));
        case 'doubleclick':
          _send(_down(at, button, 1));
          _send(_up(at, button));
          _send(_down(at, button, 2));
          _send(_up(at, button));
        default:
          throw CommandError('`kind` $kind is move, down, up, click, '
              'doubleclick or rightclick');
      }
    }
    return null;
  }

  void _send(PlatformWindowEvent event) => application.handleEvent(event);

  PointerMoveEvent _move(Offset at) => PointerMoveEvent(
        windowId: window.id,
        generation: window.nativeWindow.generation,
        timestamp: _now,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: at,
      );

  PointerDownEvent _down(Offset at, PointerButton button, int clicks) =>
      PointerDownEvent(
        windowId: window.id,
        generation: window.nativeWindow.generation,
        timestamp: _now,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: at,
        button: button,
        clickCount: clicks,
      );

  PointerUpEvent _up(Offset at, PointerButton button) => PointerUpEvent(
        windowId: window.id,
        generation: window.nativeWindow.generation,
        timestamp: _now,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: at,
        button: button,
      );

  // --- keyboard ---------------------------------------------------------------

  Object? _key(Map<String, Object?> params) {
    final Object? name = params['key'];
    if (name is! String) throw const CommandError('`key` names a key');
    final int? key = logicalKeyNamed(name);
    if (key == null) {
      throw CommandError('unknown key `$name`; a letter, a digit, F1-F24, '
          'Enter, Escape, Tab, Space, Backspace, Delete, Home, End, PageUp, '
          'PageDown or an arrow (ArrowLeft...)');
    }
    bool flag(String key) => params[key] == true;
    final bool mac = Platform.isMacOS;
    final Set<KeyModifier> modifiers = <KeyModifier>{
      if (flag('shift')) KeyModifier.shift,
      if (flag('alt')) KeyModifier.alt,
      if (flag('ctrl') || (flag('cmd') && !mac)) KeyModifier.control,
      if (flag('meta') || (flag('cmd') && mac)) KeyModifier.meta,
    };
    _send(KeyDownEvent(
      windowId: window.id,
      generation: window.nativeWindow.generation,
      timestamp: _now,
      physicalKey: key,
      logicalKey: key,
      modifiers: modifiers,
    ));
    _send(KeyUpEvent(
      windowId: window.id,
      generation: window.nativeWindow.generation,
      timestamp: _now,
      physicalKey: key,
      logicalKey: key,
      modifiers: modifiers,
    ));
    return null;
  }

  /// The logical key a request names, or null.
  static int? logicalKeyNamed(String name) {
    if (name.length == 1) {
      final int code = name.toUpperCase().codeUnitAt(0);
      if ((code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5A)) {
        return code;
      }
    }
    final RegExpMatch? function = RegExp(r'^F(\d{1,2})$').firstMatch(name);
    if (function != null) {
      final int n = int.parse(function.group(1)!);
      if (n >= 1 && n <= 24) return 0x6F + n;
    }
    return switch (name) {
      'Enter' || 'Return' => 0x0D,
      'Escape' || 'Esc' => 0x1B,
      'Tab' => 0x09,
      'Space' => 0x20,
      'Backspace' => 0x08,
      'Delete' => 0x2E,
      'Home' => 0x24,
      'End' => 0x23,
      'PageUp' => 0x21,
      'PageDown' => 0x22,
      'ArrowLeft' => 0x25,
      'ArrowUp' => 0x26,
      'ArrowRight' => 0x27,
      'ArrowDown' => 0x28,
      _ => null,
    };
  }

  // --- screenshot -------------------------------------------------------------

  Future<Object?> _screenshot(Map<String, Object?> params) async {
    final DisplayList? list = window.paintSnapshot();
    if (list == null) {
      throw const CommandError('the window has not drawn its first frame');
    }
    final Size size = window.host.logicalSize;
    final int width = size.width.round();
    final int height = size.height.round();
    if (width <= 0 || height <= 0) {
      throw const CommandError('the window has no size yet');
    }
    final device = await const CpuRendererBackend().createDevice();
    final target = device.createTarget(
      MemorySurfaceDescriptor(pixelWidth: width, pixelHeight: height),
    ) as MemoryRenderTarget;
    final result = await target.renderDisplayList(list, clearColor: 0xFF000000);
    if (!result.isSuccess) {
      throw CommandError('the screenshot could not be drawn: $result');
    }
    final Framebuffer framebuffer = target.framebuffer;
    final Uint8List png = encodePng(
      width: framebuffer.width,
      height: framebuffer.height,
      pixels: _packed(framebuffer),
      bgra: framebuffer.format == PixelFormat.bgra8888Premultiplied,
    );
    final Object? path = params['path'];
    if (path is String) {
      File(path).writeAsBytesSync(png);
      return <String, Object?>{
        'path': path,
        'width': framebuffer.width,
        'height': framebuffer.height,
      };
    }
    return <String, Object?>{
      'width': framebuffer.width,
      'height': framebuffer.height,
      'pngBase64': base64Encode(png),
    };
  }

  /// [framebuffer]'s rows without the padding a stride may add.
  static Uint8List _packed(Framebuffer framebuffer) {
    final int row = framebuffer.width * 4;
    if (framebuffer.bytesPerRow == row) return framebuffer.pixels;
    final Uint8List out = Uint8List(row * framebuffer.height);
    for (var y = 0; y < framebuffer.height; y++) {
      out.setRange(y * row, y * row + row, framebuffer.pixels,
          framebuffer.offsetOf(0, y));
    }
    return out;
  }
}
