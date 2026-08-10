/// The Win32 backend's public surface.
///
/// Everything a caller outside this directory should need, and nothing that
/// would let it depend on the shape of a native struct. The FFI bindings, the
/// structs and the constants stay unexported on purpose: a caller that reaches
/// for `WndClassExW` is a caller that will break when the binding changes.
library;

export 'win32_backend.dart' show Win32WindowingBackend;
export 'win32_coordinates.dart' show Win32CoordinateSpace, win32ScaleForDpi;
export 'win32_cpu_presenter.dart' show Win32CpuPresenter;
export 'win32_diagnostics.dart' show Win32Failure, Win32HandlerFault;
export 'win32_dib_surface.dart' show Win32CpuSurface, Win32DibSurface;
export 'win32_window.dart' show Win32Window;
export 'win32_window_class.dart' show Win32WindowRegistry;
