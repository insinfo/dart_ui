/// CPU presentation for the in-process macOS backends.
///
/// SkyLight and the AppKit signal hijack draw in this process, so there is no
/// IOSurface pool shared with a host and no Metal layer to attach: the window
/// owns a framebuffer and shows it as an image. The contract is the shared
/// one in `retained_cpu_window.dart`; these names stay for the macOS code
/// that reads better with them. The native host keeps its own path
/// (`macos-iosurface` and Metal); these windows never offer a
/// `MacosSurfaceDescriptor`, which is what keeps those paths off them.
library;

import '../retained_cpu_window.dart';

export '../retained_cpu_window.dart';

typedef MacosCpuSurface = RetainedCpuSurface;
typedef MacosCpuWindow = RetainedCpuWindow;
typedef MacosCpuPresenter = RetainedCpuPresenter;

/// The `kind` every in-process macOS CPU surface reports.
const String macosCpuSurfaceKind = 'macos-cpu';
