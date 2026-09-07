/// What a 3D draw asks for, and the contract a renderer fills to do it.
///
/// `mesh_rasterizer.dart` draws a [Mesh3D] on the CPU and hands the result to a
/// backend as one image. §8.1.1 of the roadmap says the CPU draws only when the
/// hardware cannot, when the target is off-screen, or when the library user
/// asked for it - and a 3D viewer on a machine with a working Direct3D 11
/// device is none of the three. This file is the seam that lets a backend draw
/// the triangles itself.
///
/// ## Why the contract is here and not in a backend
///
/// Two backends fill it - `D3d11MeshRenderer` in
/// `gpu/d3d11/d3d11_mesh_pipeline.dart` and `GlMeshRenderer` in
/// `gpu/gl/gl_mesh_renderer.dart` - and a contract that lived in one of them
/// would be the other's dependency. Worse, it would be shaped by whichever API was
/// written first: a `drawScene` taking a `Pointer<Void>` render-target view is
/// a perfectly good Direct3D 11 method and is not a contract, because nothing
/// else can implement it. So [MeshSceneRenderer] names only types this layer
/// already has - a [RenderTarget], a [MeshScene], a [Rect] - and each backend
/// works out for itself which of its own target types it was handed.
///
/// ## The vocabulary is the CPU rasteriser's, deliberately
///
/// [MeshCamera], [MeshShading] and [MeshRenderStats] come from
/// `mesh_rasterizer.dart` rather than being restated here. The point of the
/// exercise is that the two paths draw *the same picture*: a GPU path with its
/// own camera type could not be held against the CPU one pixel by pixel,
/// because the comparison would first have to convert between two spellings of
/// the same thing and any bug in that conversion would be indistinguishable
/// from a bug in the shader.
library;

import '../../geometry/rect.dart';
import '../../graphics/mesh/mesh3d.dart';
import '../renderer.dart';
import 'mesh_rasterizer.dart';

/// A model, a camera and how to light it: one frame's worth of 3D.
///
/// The field-for-field twin of [MeshRasterizer.render]'s named arguments, so
/// that a caller can render the same scene either way by passing this to one
/// and destructuring it into the other. That is what the parity tests do.
final class MeshScene {
  const MeshScene({
    required this.mesh,
    required this.camera,
    this.shading = MeshShading.smooth,
    this.backgroundArgb = 0xFF10151F,
    this.lightDirection = const Vector3(-0.4, -0.8, -0.45),
    this.ambient = 0.22,
  });

  final Mesh3D mesh;
  final MeshCamera camera;
  final MeshShading shading;

  /// The colour the target is cleared to before the model is drawn, or null to
  /// draw over what is already there.
  ///
  /// Null has no counterpart in [MeshRasterizer.render], which always clears -
  /// on the CPU the framebuffer is the renderer's own and drawing over the
  /// previous frame would leave the silhouette of where the model used to be.
  /// A GPU path draws into a surface that a 2D pass may already have painted,
  /// so "do not clear" is a real request there and is the only field of this
  /// class the CPU path cannot honour.
  ///
  /// **The clear covers the whole target, not
  /// [MeshSceneRenderer.drawScene]'s `viewport`.** That is a contract and not
  /// an accident of one backend: Direct3D 11's `ClearRenderTargetView` takes
  /// no rectangle and ignores the scissor, so a renderer that clipped the
  /// clear could not be the same renderer on both APIs, and two backends that
  /// draw a *different picture* from the same [MeshScene] is the one outcome
  /// this whole file exists to prevent. The GL path therefore clears with the
  /// scissor test switched off to match.
  ///
  /// So a caller drawing a 3D view inside an interface passes null here and
  /// clears the surface itself. That is what null is for; it is not a
  /// micro-optimisation.
  final int? backgroundArgb;

  /// The direction light travels in, normalised by the renderer.
  final Vector3 lightDirection;

  /// How much of the base colour survives where no light reaches.
  final double ambient;
}

/// A renderer that draws a [MeshScene] with the hardware.
///
/// One implementation per GPU backend. The CPU rasteriser deliberately does
/// *not* implement it: it has no [RenderTarget] to draw into - it fills a
/// `Framebuffer` that a backend then presents - and pretending otherwise would
/// put a software path behind an interface whose whole purpose is to say that
/// the triangles reached a driver.
abstract interface class MeshSceneRenderer {
  /// Draws [scene] into [target], covering [viewport] or the whole surface.
  ///
  /// Issues the draw immediately against the target's current colour buffer;
  /// it does not present. A caller that mixes 2D and 3D therefore controls the
  /// order by when it calls this, which is the only arrangement that works for
  /// both a 3D view inside an interface and an interface drawn over a model.
  ///
  /// [viewport] is in target pixels with the origin at the top-left corner.
  /// The projection's aspect ratio comes from it, so a scene drawn into a
  /// narrow strip is not stretched. It bounds the *draws*; it does not bound
  /// the clear - see [MeshScene.backgroundArgb].
  ///
  /// Returns [MeshRenderStats.zero] without submitting anything when the
  /// implementation was handed a [RenderTarget] belonging to another backend,
  /// when the device is lost, or when the target could not be given a depth
  /// buffer. A renderer that drew anyway would produce a model with its far
  /// side over its near side and no error anywhere, which is the failure mode
  /// both implementations are built to make loud.
  MeshRenderStats drawScene(
    RenderTarget target,
    MeshScene scene, {
    Rect? viewport,
  });

  /// Forgets the GPU buffers cached for [mesh].
  ///
  /// A renderer keeps a mesh's vertices and indices resident across frames -
  /// re-uploading a 451,838-triangle model at 60 Hz is about 200 MB/s of
  /// traffic for geometry that never changed - so a viewer that opens a second
  /// model has to say when the first one is finished with. A renderer is free
  /// to evict on its own under memory pressure; this is the caller saying it
  /// knows sooner.
  void discardMesh(Mesh3D mesh);

  /// Releases every GPU object this renderer owns.
  void dispose();
}

/// How many triangles a GPU renderer submitted, in the CPU rasteriser's own
/// shape.
///
/// [MeshRenderStats] has five counters and a GPU can honestly fill two of them.
/// This exists so that the three it cannot fill are zeroed in one place with
/// the reason attached, rather than in each backend with a different guess:
///
///   * `culled` and `clipped` happen inside fixed-function hardware, which
///     reports neither. A pipeline-statistics query could count the primitives
///     the rasteriser accepted, but reading it back stalls the frame it
///     measures, which is the one thing a GPU path exists to avoid.
///   * `pixels` is the same story for the depth test's survivors: an occlusion
///     query per primitive would cost more than the draw.
///
/// So a GPU frame reports what it *submitted* and how long submitting took,
/// and a reader comparing those against a CPU frame's is comparing two
/// different measurements. The zeros say which.
MeshRenderStats gpuMeshStats({
  required int triangles,
  required int microseconds,
}) =>
    MeshRenderStats(
      triangles: triangles,
      drawn: triangles,
      culled: 0,
      clipped: 0,
      pixels: 0,
      microseconds: microseconds,
    );
