/// The macOS backend's supported public surface.
///
/// Native bindings, host protocol internals and private-API experiments stay
/// unexported. Applications select a strategy through [MacosBackendOptions]
/// and interact with the common `WindowingBackend`/`NativeWindow` contracts.
library;

export 'macos_backend.dart' show MacosWindowingBackend;
export 'macos_backend_kind.dart' show MacosBackendKind;
export 'macos_backend_selection.dart' show MacosBackendOptions;
export 'macos_window.dart' show MacosWindow;
