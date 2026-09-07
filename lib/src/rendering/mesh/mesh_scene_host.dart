/// How an application reaches the running backend's 3D renderer, or learns
/// there is none.
///
/// `mesh_scene.dart` declares what a backend must implement to draw a
/// [MeshScene]; `gpu/d3d11/d3d11_mesh_pipeline.dart` and its OpenGL twin
/// implement it. Neither of those answers the question an application actually
/// asks, which is *"is there one here, and what do I hand it?"* - a
/// [MeshSceneRenderer] draws into a [RenderTarget], and a widget has no
/// [RenderTarget]: the window owns it, it is replaced by a resize and by a
/// device loss, and its pixel size is not the widget's logical size. This file
/// is the seam that closes that gap.
///
/// ## Why it is shaped like this and not like the alternatives
///
/// The shape is the one this repository already uses for a capability a
/// backend may or may not have: `NativeHandleWindow` and `ActivatableWindow`
/// are interfaces a backend *also* implements and a caller tests for with a
/// pattern, and `platformAccessibility` is null on every platform with no
/// bridge rather than throwing. Both rules are kept here:
///
///   * [MeshSceneSurface] is a capability, not a member of any contract every
///     backend implements. Adding `drawMesh` to `SurfacePresenter` or to
///     `RenderTarget` would break every presenter and every test double in the
///     suite at once for something two of them can do;
///   * **null is the ordinary answer.** A headless run, a web target, a CPU
///     presenter and a GPU backend whose mesh program the driver refused all
///     produce null, and an application that asks gets null plus the
///     [BackendDiagnostic] saying which of those happened. Nothing throws,
///     because the one thing a viewer must never do is lose its window over a
///     3D pipeline it can do without - it has a CPU rasteriser.
///
/// JavaFX arrived at the same two levels from the other direction and it is
/// worth naming, because it is the part of `prism` that answers exactly this
/// question: `GraphicsPipeline.getPipeline()` is a single installed object -
/// the one whose `init()` succeeded - and it answers `is3DSupported()` with a
/// bool, while the thing that actually makes GPU objects, `ResourceFactory`,
/// is obtained *from* it and is per adapter. [MeshSceneRendererFactory] is the
/// first level and [MeshSceneSurface] is the second. Where this differs is the
/// bool: `SubScene` asks `is3DSupported` and then degrades silently - no depth
/// buffer, a parallel camera instead of a perspective one, one line in the log
/// - which is a reasonable answer for a toolkit that must draw *something* and
/// a poor one for a viewer that has a working CPU rasteriser and needs to say
/// which path drew. So the answer here is the object or null with the
/// diagnostic attached, never a bool.
///
/// Two shapes were rejected:
///
///   * **a `RendererBackend.supportsMesh` flag.** It answers the wrong
///     question. What a caller needs is the *object*, and a bool that says one
///     exists still leaves it with no way to obtain one - and with the chance
///     of disagreeing with reality when the program compiles but the device
///     refuses it;
///   * **handing the widget the `MeshSceneRenderer` and the `RenderTarget`
///     directly.** That is what the render object needs, and it is exactly
///     what it must not hold: the target is replaced under it by a resize and
///     by device-loss recovery, so a widget that captured one would draw into
///     a freed swap chain the first time the window was dragged to another
///     monitor. [MeshSceneSurface] is resolved per call by the window that
///     owns both, which is the only object that can be right about it.
///
/// ## The ordering rule, and why it is not JavaFX's
///
/// JavaFX solved this exact problem and its answer is `SubScene`
/// (`javafx/scene/SubScene.java`, `com/sun/javafx/sg/prism/NGSubScene.java`):
/// the 3D view renders into a **render-to-texture of its own**, with its own
/// depth buffer, and `NGSubScene.renderContent` then hands that texture to the
/// 2D scene graph as an ordinary node - `g.drawTexture(rtt, ...)`. Three
/// consequences fall out of that one decision, and they are the three
/// decisions this seam has to make too:
///
///   1. **z-order is preserved.** A 2D node after the sub-scene draws over it
///      and a 2D node before it draws under it, with no special case;
///   2. **the clear is private.** `applyBackgroundFillPaint` clears the
///      sub-scene's own texture, transparent by default, and the scene's
///      surface is never touched by 3D;
///   3. **no state leaks.** `setDepthBuffer` is set on the texture's own
///      `Graphics`, so there is nothing to restore afterwards - and where
///      JavaFX does share a surface it refuses its own fast blit path while
///      `g.isDepthTest()`, which is the same worry from the other side.
///
/// **This framework cannot do (1) and (2) yet, and the reason is one missing
/// operation.** A display list here holds CPU pixels - `DisplayList.addImage`
/// takes a `Framebuffer` - and every backend in the tree reports
/// `supportsExternalTextures: false`, so there is no way to put a GPU texture
/// into a display list and let the 2D pass composite it. The only offscreen
/// GPU target that exists, `D3d11OffscreenTarget`, is one whose pixels come
/// back through the CPU: rendering the model into it and reading it back to
/// call `drawImage` would put a full GPU-to-CPU-to-GPU round trip in every
/// frame, which is precisely the cost that makes the CPU rasteriser 108 ms on
/// a 451,838-triangle model. Copying JavaFX's shape today would mean throwing
/// away the whole win to get it.
///
/// So the 3D goes into the window's own back buffer, and there is then exactly
/// one order that works: **the mesh draws first, from inside the paint pass,
/// and the frame's display list is submitted over it.** Both halves are
/// forced:
///
///   * `ClearRenderTargetView` takes no rectangle and ignores the scissor, so
///     a mesh pass sharing the window's surface cannot clear only its own
///     viewport. Whichever pass clears must therefore be first, and it has to
///     be the mesh: a 2D clear that ran afterwards would erase the model. So
///     this surface owns the frame's clear - see [MeshSceneSurface.draw] - and
///     the window suppresses its own for any frame in which a mesh drew;
///   * the interface has to be able to draw *over* the model - a status bar, a
///     menu opened across the viewport, the framework's own error banner.
///     Running the mesh last would put the model on top of every one of them.
///
/// It is also what the Direct3D 11 pipeline's own teardown already assumes:
/// `drawInto` finishes by unbinding the depth-stencil view and binding a
/// depth-off state, which is only of use to a 2D pass that comes *after* it. A
/// mesh frame that left a depth-stencil view bound makes every following dense
/// batch fail the depth test against a plane the model wrote, and the
/// interface disappears exactly where the model is.
///
/// **What this costs, stated rather than discovered:** 2D cannot be drawn
/// *under* the model, so a widget painted behind the mesh in the tree is
/// invisible, and a second mesh view in one window shares one clear. Both
/// disappear the day the display list can carry a GPU texture; that is the one
/// change that moves this seam to JavaFX's shape, and when it lands only
/// [MeshSceneSurface.draw] has to change.
///
/// ## The depth buffer, which is the one decision already made correctly
///
/// `NGSubScene` allocates the depth buffer with the sub-scene's target, keyed
/// to the *scaled* pixel size rather than the logical one, discards it when
/// that size changes and rebuilds it when the surface is reported lost. The
/// Direct3D 11 pipeline here does the same thing against the window target -
/// `_ensureDepth(targetWidth, targetHeight)`, reallocated when the target
/// grows - so nothing in this seam needs to own or size a depth buffer, and it
/// deliberately does not expose one. A caller that could ask for a depth
/// buffer of its own would be able to ask for one that disagrees with the
/// colour target, which Direct3D refuses at the output merger and which no
/// amount of care at this level could catch.
library;

import '../../geometry/rect.dart';
import '../../graphics/mesh/mesh3d.dart';
import '../renderer.dart';
import 'mesh_rasterizer.dart';
import 'mesh_scene.dart';

/// Builds the 3D renderer for [device], or says why it cannot.
///
/// Returns a [MeshSceneRenderer] or a [BackendDiagnostic], the shape
/// `D3d11MeshRenderer.create` already has and for the reason it gives: a
/// caller that cannot get a mesh pipeline wants to fall back to the CPU
/// rasteriser with something to print, not to lose its window.
///
/// Declared by a presentation path rather than by a device, and that is
/// deliberate. The device is the wrong place - `d3d11_mesh_pipeline.dart` says
/// in as many words that making `D3d11RenderDevice` know a mesh renderer
/// exists is "precisely the coupling this file avoids" - and the presentation
/// path is the right one, because a path is already the composition root's
/// statement of what this backend can do on this platform. A backend joins by
/// adding one field to its entry in `backends/default_platform_resolver.dart`,
/// which is the one file in the tree that is allowed to name a concrete
/// backend.
typedef MeshSceneRendererFactory = MeshSceneRenderer Function(
  RenderDevice device,
);

/// One window's 3D drawing surface, as a widget sees it.
///
/// Obtained from `MeshSceneScope.maybeOf(context)`, which answers null when
/// nothing here can draw 3D. Every method is safe to call from `paint`; none
/// of them is safe to call anywhere else, because the back buffer this draws
/// into belongs to the frame that is being painted.
abstract interface class MeshSceneSurface {
  /// What is drawing, for a status line and for a log: `direct3d11`, `opengl`.
  ///
  /// A viewer that says "the GPU drew this" and names nothing is unfalsifiable
  /// on a machine with two adapters and two candidate paths.
  String get rendererName;

  /// Draws [scene] into the frame being painted, or returns null when the
  /// hardware refused it and the caller has to draw it itself.
  ///
  /// [viewport] is in the **logical** units the render object was laid out in,
  /// with the origin at the window's top-left corner - the same coordinates
  /// `RenderBox.paint` is handed. The window scales it to device pixels,
  /// because the render scale is the one number a widget cannot be right about
  /// on a mixed-DPI desktop and the window is the authority on it. Null covers
  /// the whole surface.
  ///
  /// **The first call in a frame clears the whole surface** with
  /// [MeshScene.backgroundArgb], and later calls in the same frame do not,
  /// whatever their scene says - see the ordering rule in this library's
  /// comment for why the clear cannot belong to anybody else. A scene with a
  /// null background never clears, and then whatever the previous frame left
  /// in the back buffer shows through wherever no triangle covers, which on a
  /// flip-model swap chain is undefined memory.
  ///
  /// Null is returned, and no exception thrown, for every reason the hardware
  /// can decline: a device lost mid-frame, a target that belongs to another
  /// backend, a surface with no pixels yet. The caller draws the frame on the
  /// CPU and the window keeps its picture; that is the whole point of
  /// answering rather than throwing.
  MeshRenderStats? draw(MeshScene scene, {Rect? viewport});

  /// Forgets the GPU buffers cached for [mesh].
  ///
  /// A renderer keeps a mesh resident across frames - see
  /// [MeshSceneRenderer.discardMesh] - so a viewer that opens a second model
  /// has to say when the first is finished with, or a session of opening files
  /// grows the device's memory by one model each time.
  void discardMesh(Mesh3D mesh);
}
