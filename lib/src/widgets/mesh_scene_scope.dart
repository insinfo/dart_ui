/// The ambient answer to "can anything here draw 3D, and with what?".
///
/// Installed by the application layer once per window, beside `ClipboardScope`
/// and `TextInputScope` and for the same reason those are installed there
/// rather than by the caller: a render object that wants to draw a mesh cannot
/// be handed the window's renderer by its parent, and an application that
/// forgot the wrapper would silently rasterise 450,000 triangles on the CPU
/// with nothing to grep for.
///
/// The scope is always present. What varies is [surface], and null is the
/// ordinary answer - a headless run, a web target, a CPU presentation path, or
/// a GPU backend whose mesh program the driver refused. [unavailable] then
/// carries which of those it was, so a viewer can say *why* it is on the CPU
/// instead of only that it is.
library;

import '../foundation/diagnostics.dart';
import '../rendering/mesh/mesh_scene_host.dart';
import 'widget.dart';

final class MeshSceneScope extends InheritedWidget {
  const MeshSceneScope({
    super.key,
    required this.surface,
    this.unavailable,
    required super.child,
  });

  /// This window's 3D surface, or null when nothing here draws 3D.
  final MeshSceneSurface? surface;

  /// Why [surface] is null, when there is a reason worth printing.
  ///
  /// Null alongside a null [surface] is itself an answer: nothing was ever
  /// asked, because this presentation path declares no 3D renderer at all -
  /// the CPU and headless paths. A non-null diagnostic means one was asked for
  /// and refused, which is the case worth showing a user, because it is the
  /// one a driver update might fix.
  final BackendDiagnostic? unavailable;

  /// The window's 3D surface, or null. The call a render object makes.
  static MeshSceneSurface? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MeshSceneScope>()
      ?.surface;

  /// The whole answer, including the reason there is no surface.
  static MeshSceneScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MeshSceneScope>();

  @override
  bool updateShouldNotify(MeshSceneScope oldWidget) =>
      !identical(surface, oldWidget.surface) ||
      unavailable != oldWidget.unavailable;
}
