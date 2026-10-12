/// Drops onto a macOS window, through the AppKit host.
///
/// The host's view is the `NSDraggingDestination`. While a drop target is
/// registered (`DROP_REGISTER`) it accepts file URLs and text, reports each
/// thing a drag carries as a `DRAG_ITEM` line and the drag itself as `DRAG=`
/// lines, and this file turns those into the [DropTargetHandler] calls every
/// backend makes - so the widget tree's `DropTarget`s work on the Mac exactly
/// as on Windows and Linux. Files arrive as `text/uri-list`, built by
/// [MemoryDragData.filePaths] as the Win32 backend builds it, and text as
/// `text/plain;charset=utf-8`.
///
/// ## The answer is one update behind
///
/// AppKit asks for the drag operation synchronously, from `draggingEntered:`
/// and every `draggingUpdated:`, and the handler's answer lives in this
/// process. Blocking the host's main thread on a reply would deadlock against
/// the thread that reads its commands, so the host answers with the last
/// operation sent here (`DROP_RESPONSE`), starting from an optimistic copy.
/// The cursor can therefore show the previous answer for one update; the drop
/// itself is decided by the latest one, because `prepareForDragOperation:`
/// refuses when it is none.
///
/// ## Not here
///
/// Dragging *out* of a macOS window: [MacosDragDropBackend.canStartDrag] is
/// false and [MacosDragDropBackend.startDrag] refuses by name. And, as on
/// Win32, the action [DropTargetHandler.onDrop] returns does not reach the
/// source - `performDragOperation:` has answered by then.
library;

import 'dart:convert';

import '../../geometry/offset.dart';
import '../../platform/drag_drop.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import 'host_protocol.dart';
import 'macos_input.dart' show macosKeyModifiers;

// NSDragOperation (AppKit/NSDragging.h).
const int _nsDragCopy = 1;
const int _nsDragLink = 2;
const int _nsDragGeneric = 4;
const int _nsDragMove = 16;

/// The window side a drop target needs. [MacosWindow] implements it.
abstract interface class MacosDropWindow {
  NativeWindowId get id;

  /// Sends one command line to the window's host. False when there is none.
  bool sendDropCommand(String command);

  /// Where the window hands its host's drag lines.
  MacosDropTarget? get dropTarget;
  set dropTarget(MacosDropTarget? target);
}

/// [DragDropBackend] over the host's `NSDraggingDestination`.
final class MacosDragDropBackend implements DragDropBackend {
  const MacosDragDropBackend();

  @override
  String get name => 'appkit';

  @override
  bool get canStartDrag => false;

  @override
  Future<DropTargetRegistration> registerDropTarget({
    required NativeWindow window,
    required DropTargetHandler handler,
  }) async {
    if (window is! MacosDropWindow) {
      throw DragDropException(
        operation: 'registerDropTarget',
        reason: 'AppKit drops need a macOS window; it was given a '
            '${window.runtimeType}',
        backend: name,
      );
    }
    final MacosDropWindow target = window as MacosDropWindow;
    if (target.dropTarget != null) {
      throw DragDropException(
        operation: 'registerDropTarget',
        reason: 'window ${window.id.value} already has a drop target; revoke '
            'it first',
        backend: name,
      );
    }
    final MacosDropTarget registration = MacosDropTarget(target, handler);
    target.dropTarget = registration;
    if (!target.sendDropCommand(HostCommands.dropRegister())) {
      target.dropTarget = null;
      throw DragDropException(
        operation: 'registerDropTarget',
        reason: 'the window has no AppKit host to register with',
        backend: name,
      );
    }
    return registration;
  }

  @override
  Future<DragAction> startDrag(DragRequest request) async =>
      throw DragDropException(
        operation: 'startDrag',
        reason: 'dragging out of a macOS window is not implemented; this '
            'backend receives drops only',
        backend: name,
      );
}

/// One window's drop target: the session assembled from the host's lines.
final class MacosDropTarget implements DropTargetRegistration {
  MacosDropTarget(this._window, this._handler);

  final MacosDropWindow _window;
  final DropTargetHandler _handler;
  bool _active = true;

  final List<String> _paths = <String>[];
  String? _text;
  MemoryDragData? _data;
  bool _inside = false;

  @override
  NativeWindowId get windowId => _window.id;

  @override
  bool get isActive => _active;

  @override
  Future<void> revoke() async {
    if (!_active) return;
    _active = false;
    if (_inside) {
      _inside = false;
      _handler.onDragLeave();
    }
    if (identical(_window.dropTarget, this)) {
      _window.dropTarget = null;
      _window.sendDropCommand(HostCommands.dropUnregister());
    }
  }

  /// A `DRAG_ITEM` line.
  void onItem(String kind, String base64Text) {
    final String text;
    try {
      text = utf8.decode(base64.decode(base64Text));
    } on FormatException {
      return;
    }
    if (kind == 'file') {
      _paths.add(text);
    } else if (kind == 'text') {
      _text = text;
    }
  }

  /// A `DRAG=` line.
  void onDrag(HostDragPhase phase, double x, double y, int mask, int flags) {
    if (!_active) return;
    switch (phase) {
      case HostDragPhase.enter:
        _data = _collect();
        _inside = true;
        _respond(_handler.onDragEnter(_event(x, y, mask, flags)));
      case HostDragPhase.over:
        if (!_inside) return;
        _respond(_handler.onDragOver(_event(x, y, mask, flags)));
      case HostDragPhase.leave:
        if (!_inside) return;
        _inside = false;
        _data = null;
        _handler.onDragLeave();
      case HostDragPhase.drop:
        if (!_inside) return;
        _inside = false;
        final DragSessionEvent event = _event(x, y, mask, flags);
        _data = null;
        // The action cannot reach the source: performDragOperation: has
        // answered. Awaited only so a failure is not an unhandled error.
        _handler.onDrop(event).catchError((Object _) => DragAction.none);
    }
  }

  MemoryDragData _collect() {
    final MemoryDragData data;
    if (_paths.isNotEmpty) {
      data = MemoryDragData.filePaths(List<String>.of(_paths));
    } else {
      data = MemoryDragData.text(_text ?? '');
    }
    _paths.clear();
    _text = null;
    return data;
  }

  DragSessionEvent _event(double x, double y, int mask, int flags) {
    final Set<DragAction> allowed = macosAllowedActions(mask);
    return DragSessionEvent(
      windowId: _window.id,
      position: Offset(x, y),
      data: _data ?? MemoryDragData.text(''),
      allowedActions: allowed,
      suggestedAction: macosSuggestedAction(allowed, flags),
      modifiers: macosKeyModifiers(flags),
    );
  }

  void _respond(DropResponse response) {
    _window.sendDropCommand(HostCommands.dropResponse(
      response.isAccepted ? macosDragOperation(response.action) : 0,
    ));
  }
}

/// The actions an `NSDragOperation` mask allows. Generic is the source saying
/// "whatever the destination thinks best", which for a drop is a move.
Set<DragAction> macosAllowedActions(int mask) => <DragAction>{
      if (mask & _nsDragCopy != 0) DragAction.copy,
      if (mask & _nsDragLink != 0) DragAction.link,
      if (mask & (_nsDragMove | _nsDragGeneric) != 0) DragAction.move,
    };

/// What the user asked for with the modifiers, as Finder reads them: Option
/// copies, Command moves, Option and Command together link. With none held,
/// copy when allowed - a drop into an application is a copy unless the user
/// says otherwise.
DragAction macosSuggestedAction(Set<DragAction> allowed, int flags) {
  const int option = 1 << 19;
  const int command = 1 << 20;
  final bool opt = flags & option != 0;
  final bool cmd = flags & command != 0;
  final DragAction wanted = opt && cmd
      ? DragAction.link
      : opt
          ? DragAction.copy
          : cmd
              ? DragAction.move
              : DragAction.copy;
  if (allowed.contains(wanted)) return wanted;
  for (final DragAction fallback in <DragAction>[
    DragAction.copy,
    DragAction.move,
    DragAction.link,
  ]) {
    if (allowed.contains(fallback)) return fallback;
  }
  return DragAction.none;
}

/// The `NSDragOperation` for [action]: what the host answers AppKit with.
int macosDragOperation(DragAction action) => switch (action) {
      DragAction.copy => _nsDragCopy,
      DragAction.link => _nsDragLink,
      DragAction.move => _nsDragMove,
      DragAction.ask || DragAction.none => 0,
    };
