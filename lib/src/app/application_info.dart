/// Runtime and renderer information exposed to every application widget.
library;

import '../platform/backend_selection.dart';
import '../rendering/renderer.dart';
import '../widgets/widget.dart';

/// The Dart execution mode used by this process.
enum DartRuntimeMode {
  jit,
  aot;

  /// `dart run` uses the development VM, while `dart compile exe` produces a
  /// product AOT runtime. The environment constant is folded by the compiler,
  /// so it does not rely on executable names or command-line heuristics.
  static const DartRuntimeMode current =
      bool.fromEnvironment('dart.vm.product') ? aot : jit;

  String get label => switch (this) {
        DartRuntimeMode.jit => 'JIT',
        DartRuntimeMode.aot => 'AOT',
      };
}

/// Immutable identity of the runtime and presentation path of one window.
final class ApplicationRuntimeInfo {
  const ApplicationRuntimeInfo({
    required this.dartRuntimeMode,
    required this.windowingBackend,
    required this.presentationBackend,
    required this.presentationKind,
    required this.renderer,
    required this.renderScale,
    required this.desktopScale,
  });

  final DartRuntimeMode dartRuntimeMode;
  final String windowingBackend;
  final String presentationBackend;
  final PresentationKind presentationKind;
  final RendererInfo renderer;
  final double renderScale;
  final double desktopScale;

  String get shortDescription =>
      '${dartRuntimeMode.label} • ${presentationKind.name.toUpperCase()}/'
      '$presentationBackend • $windowingBackend';

  String get detailedDescription =>
      '$shortDescription • ${renderer.deviceDescription} • '
      '${renderer.rasterizationApproach.name} • '
      '${renderScale}x render/${desktopScale}x desktop';

  @override
  bool operator ==(Object other) =>
      other is ApplicationRuntimeInfo &&
      other.dartRuntimeMode == dartRuntimeMode &&
      other.windowingBackend == windowingBackend &&
      other.presentationBackend == presentationBackend &&
      other.presentationKind == presentationKind &&
      other.renderer.name == renderer.name &&
      other.renderer.deviceDescription == renderer.deviceDescription &&
      other.renderer.driverVersion == renderer.driverVersion &&
      other.renderer.rasterizationApproach == renderer.rasterizationApproach &&
      other.renderScale == renderScale &&
      other.desktopScale == desktopScale;

  @override
  int get hashCode => Object.hash(
        dartRuntimeMode,
        windowingBackend,
        presentationBackend,
        presentationKind,
        renderer.name,
        renderer.deviceDescription,
        renderer.driverVersion,
        renderer.rasterizationApproach,
        renderScale,
        desktopScale,
      );

  @override
  String toString() => detailedDescription;
}

/// Publishes the active window's [ApplicationRuntimeInfo] to its widget tree.
final class ApplicationInfo extends InheritedWidget {
  const ApplicationInfo({
    super.key,
    required this.data,
    required super.child,
  });

  final ApplicationRuntimeInfo data;

  static ApplicationRuntimeInfo of(BuildContext context) {
    final ApplicationRuntimeInfo? result = maybeOf(context);
    if (result == null) {
      throw StateError('ApplicationInfo.of() called outside an Application');
    }
    return result;
  }

  static ApplicationRuntimeInfo? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ApplicationInfo>()?.data;

  @override
  bool updateShouldNotify(ApplicationInfo oldWidget) => data != oldWidget.data;
}
