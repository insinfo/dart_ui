/// The route from a pointer to the camera, driven through the real widget
/// tree.
///
/// The camera arithmetic has its own tests
/// (`test/rendering/mesh/orbit_camera_controller_test.dart`). This file tests
/// the half those cannot reach and the half that was actually broken: the
/// viewer had a working [MeshCamera] and no way to reach it. There was no pan
/// at all, no wheel handler, and orbit only through a drag nothing announced.
///
/// So every case here dispatches real `PointerDownEvent`/`PointerMoveEvent`/
/// `PointerScrollEvent`/`KeyDownEvent`s at the mounted viewer and then asks the
/// camera where it ended up — never the controller directly, which is exactly
/// the layer the bugs were not in.
///
/// What it still cannot prove is whether any of it *feels* right. That needs a
/// hand on a mouse.
library;

import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/graphics/mesh/mesh_loaders.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:test/test.dart';

import '../../examples/model_viewer_demo/main.dart';

const Size kWindowSize = Size(900, 700);

/// A two-unit cube at the origin, as an OBJ, so the loader is on the path too.
Mesh3D _cube() => loadMesh(
      Uint8List.fromList(
        ('v -1 -1 -1\nv 1 -1 -1\nv 1 1 -1\nv -1 1 -1\n'
                'v -1 -1 1\nv 1 -1 1\nv 1 1 1\nv -1 1 1\n'
                'f 1 3 2\nf 1 4 3\nf 5 6 7\nf 5 7 8\n'
                'f 1 2 6\nf 1 6 5\nf 2 3 7\nf 2 7 6\n'
                'f 3 4 8\nf 3 8 7\nf 4 1 5\nf 4 5 8\n')
            .codeUnits,
      ),
      name: 'cube.obj',
    );

void main() {
  setUpAll(() {
    FrameworkFonts.install();
  });
  tearDownAll(FontRegistry.instance.reset);

  test('the wheel zooms, which is what it did not do', () {
    final _Harness harness = _Harness();
    final double before = harness.camera.distance;

    harness.wheel(harness.viewCentre, -120);
    harness.frame();

    expect(harness.camera.distance, lessThan(before));

    // And back out again, by the same proportion: the step is multiplicative.
    harness.wheel(harness.viewCentre, 120);
    harness.frame();
    expect(harness.camera.distance, closeTo(before, 1e-9));
    harness.dispose();
  });

  test('the wheel zooms about the pointer', () {
    final _Harness harness = _Harness();
    final Vector3 target = harness.camera.target;

    harness.wheel(harness.viewCentre + const Offset(150, -80), -120);
    harness.frame();

    // The target slides to keep what was under the pointer under the pointer.
    // Zooming about the centre of the view would have left it exactly alone.
    expect(
      (harness.camera.target - target).length,
      greaterThan(1e-6),
      reason: 'the wheel must zoom toward the cursor, not the centre',
    );
    harness.dispose();
  });

  test('the right button pans and the model follows the cursor', () {
    final _Harness harness = _Harness();
    final MeshCamera before = harness.camera;
    final Size view = harness.session.viewportSize;
    expect(view.height, greaterThan(0));
    final (double x0, double y0) = _project(before, before.target, view);

    harness.drag(
      PointerButton.secondary,
      harness.viewCentre,
      const Offset(90, -40),
    );
    harness.settle();

    final (double x1, double y1) =
        _project(harness.camera, before.target, view);
    // The point that was under the cursor moved with it, to the pixel.
    expect(x1 - x0, closeTo(90, 0.5));
    expect(y1 - y0, closeTo(-40, 0.5));
    // A pan is not an orbit: the direction the camera looks from is untouched.
    expect(harness.camera.yaw, closeTo(before.yaw, 1e-12));
    expect(harness.camera.pitch, closeTo(before.pitch, 1e-12));
    expect(harness.camera.distance, closeTo(before.distance, 1e-12));
    harness.dispose();
  });

  test('the middle button pans too', () {
    final _Harness harness = _Harness();
    final Vector3 before = harness.camera.target;
    harness.drag(PointerButton.middle, harness.viewCentre, const Offset(60, 0));
    harness.settle();
    expect((harness.camera.target - before).length, greaterThan(1e-6));
    harness.dispose();
  });

  test('the left button orbits and moves nothing else', () {
    final _Harness harness = _Harness();
    final MeshCamera before = harness.camera;

    harness.drag(
      PointerButton.primary,
      harness.viewCentre,
      const Offset(70, 30),
    );
    harness.settle();

    expect(harness.camera.yaw, lessThan(before.yaw));
    expect(harness.camera.pitch, greaterThan(before.pitch));
    expect(harness.camera.target.x, closeTo(before.target.x, 1e-12));
    expect(harness.camera.target.y, closeTo(before.target.y, 1e-12));
    expect(harness.camera.distance, closeTo(before.distance, 1e-12));
    harness.dispose();
  });

  test('F frames the model again, from wherever the camera got to', () {
    final _Harness harness = _Harness();
    final MeshCamera framed = harness.camera;

    harness.drag(
      PointerButton.secondary,
      harness.viewCentre,
      const Offset(300, 200),
    );
    harness.wheel(harness.viewCentre, 600);
    harness.settle();
    expect(harness.camera.distance, isNot(closeTo(framed.distance, 1e-6)));

    harness.key(0x46); // F
    harness.settle();

    expect(harness.camera.distance, closeTo(framed.distance, 1e-9));
    expect(harness.camera.target.x, closeTo(framed.target.x, 1e-9));
    expect(harness.camera.target.y, closeTo(framed.target.y, 1e-9));
    expect(harness.camera.target.z, closeTo(framed.target.z, 1e-9));
    harness.dispose();
  });

  test('the viewer reports the path that drew the frame', () {
    final _Harness harness = _Harness();
    harness.tickAndFrame();
    // Read from the render object that did the drawing rather than asserted by
    // the status bar, so that a GPU path lands as a different answer here
    // instead of as a sentence nobody updated.
    expect(harness.session.drawPath, MeshDrawPath.cpu);
    expect(harness.session.stats.triangles, 12);
    harness.dispose();
  });
}

/// Where [point] lands in the model view for [camera], with the rasteriser's
/// mapping.
///
/// Against the *view's* size rather than the window's. They differ by the
/// panels above and below, and using the window's height here reported a
/// correct 90-pixel pan as 126 pixels — which is the same mistake as scaling
/// the pan by the wrong height in the first place.
(double, double) _project(MeshCamera camera, Vector3 point, Size view) {
  final double width = view.width;
  final double height = view.height;
  final Matrix4 mvp =
      camera.projectionMatrix(width / height).multiply(camera.viewMatrix());
  final Float64List m = mvp.storage;
  final double x = m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12];
  final double y = m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13];
  final double w = m[3] * point.x + m[7] * point.y + m[11] * point.z + m[15];
  return ((x / w + 1) * 0.5 * width, (1 - y / w) * 0.5 * height);
}

/// Mounts the real viewer headless and drives it like a window would.
final class _Harness {
  _Harness() {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(kWindowSize),
      ),
    );
    owner.updateRoot(
      AnimationScope(
        clock: clock,
        child: ModelViewerDemo(
          mesh: _cube(),
          error: null,
          sourcePath: 'cube.obj',
          loadTime: Duration.zero,
          session: session,
        ),
      ),
    );
    frame();
    // The turntable would move the camera under every assertion below.
    key(0x47); // G stops the spin
    settle();
  }

  late final BuildOwner owner;
  final AnimationClock clock = AnimationClock();
  final ViewerSession session = ViewerSession();

  MeshCamera get camera => session.controls!.camera;

  Offset get viewCentre =>
      Offset(kWindowSize.width / 2, kWindowSize.height / 2);

  int _millis = 0;
  int _pointerId = 0;

  Duration get _now => Duration(milliseconds: _millis += 16);

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the viewer never settled in $maxPasses passes');
  }

  /// One frame the way the application produces one: the clock first, then the
  /// tree. The ticker is what applies the damped input, so a test that never
  /// ticks sees a viewer that never moves.
  void tickAndFrame() {
    clock.tick(_now);
    frame();
  }

  /// Frames until the damped input has played out.
  void settle() {
    for (int i = 0; i < 300; i++) {
      tickAndFrame();
      if (!(session.controls?.isSettling ?? false)) return;
    }
    throw StateError('the camera never came to rest');
  }

  void wheel(Offset at, double delta) {
    owner.dispatchPointerEvent(PointerScrollEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      pointerId: _pointerId,
      kind: PointerKind.mouse,
      logicalPosition: at,
      scrollDelta: Offset(0, delta),
      scrollDeltaUnit: ScrollDeltaUnit.pixels,
    ));
  }

  void drag(PointerButton button, Offset from, Offset by) {
    owner.dispatchPointerEvent(PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      pointerId: _pointerId,
      kind: PointerKind.mouse,
      logicalPosition: from,
      button: button,
    ));
    owner.dispatchPointerEvent(PointerMoveEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      pointerId: _pointerId,
      kind: PointerKind.mouse,
      logicalPosition: from + by,
    ));
    owner.dispatchPointerEvent(PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      pointerId: _pointerId,
      kind: PointerKind.mouse,
      logicalPosition: from + by,
      button: button,
    ));
    _pointerId++;
  }

  void key(int logicalKey) {
    owner.dispatchKeyEvent(KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    ));
    owner.dispatchKeyEvent(KeyUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    ));
    frame();
  }

  void dispose() => owner.dispose();
}
