/// Barrel for the Wayland backend.
///
/// Exports the public seams of the backend - the windowing backend, the
/// window, the CPU presenter and the protocol layers a test or an embedder
/// composes them from. Nothing here is exported by `dart_ui.dart`; backends
/// are reached through `PlatformBackendResolver` and these types stay behind
/// the `src/` privacy convention.
library;

export 'wayland_backend.dart';
export 'wayland_clipboard.dart';
export 'wayland_connection.dart';
export 'wayland_cpu_presenter.dart';
export 'wayland_cursor.dart';
export 'wayland_cursor_theme.dart';
export 'wayland_dispatcher.dart';
export 'wayland_drag_drop.dart';
export 'wayland_drag_drop_backend.dart';
export 'wayland_events.dart';
export 'wayland_keymap.dart';
export 'wayland_memfd.dart';
export 'wayland_positioner.dart';
export 'wayland_protocol.dart';
export 'wayland_shm.dart';
export 'wayland_text_input.dart';
export 'wayland_transport.dart';
export 'wayland_window.dart';
export 'wayland_wire.dart';
export 'wayland_xcursor.dart';
