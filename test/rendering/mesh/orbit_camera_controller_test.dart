/// The camera arithmetic behind the viewer's controls.
///
/// Interactive controls cannot be proven by a unit test — whether an orbit
/// *feels* right is a judgement a person makes with a mouse in their hand — but
/// the arithmetic under them can, and it is where the bugs are. Every case here
/// is a property somebody would otherwise discover by dragging:
///
///   * a pan that does not track the cursor (wrong scale, or scaled by the
///     width instead of the height);
///   * a pan that drifts, so returning the mouse to where it started does not
///     return the model;
///   * a zoom that reaches zero and takes the whole view with it;
///   * a zoom out that walks the model through the far plane, leaving a black
///     window and no clue why;
///   * a pitch that crosses the pole and rolls the model over.
///
/// The pan cases check the *projected* position, through the same view and
/// projection matrices the rasteriser uses and the same viewport mapping, so
/// they measure what the user would see rather than restating the formula the
/// implementation used.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:test/test.dart';

const double _width = 800;
const double _height = 600;

/// Where [point] lands on screen, in pixels, for [camera].
///
/// The same mapping `MeshRasterizer` applies: `(x/w + 1) * 0.5 * width` across
/// and `(1 - y/w) * 0.5 * height` down.
(double, double) _project(MeshCamera camera, Vector3 point) {
  final Matrix4 mvp =
      camera.projectionMatrix(_width / _height).multiply(camera.viewMatrix());
  final Float64List m = mvp.storage;
  final double x = m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12];
  final double y = m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13];
  final double w = m[3] * point.x + m[7] * point.y + m[11] * point.z + m[15];
  return ((x / w + 1) * 0.5 * _width, (1 - y / w) * 0.5 * _height);
}

/// A camera looking at a model that is not at the origin and not axis-aligned,
/// because both of those hide sign errors.
MeshCamera _camera({double distance = 6}) => MeshCamera(
      target: const Vector3(3, -2, 11),
      distance: distance,
      yaw: 0.9,
      pitch: 0.4,
    );

void main() {
  group('MeshCamera basis', () {
    test('is orthonormal and is the basis the view matrix uses', () {
      final MeshCamera camera = _camera();
      final Vector3 right = camera.rightAxis;
      final Vector3 up = camera.upAxis;
      final Vector3 back = camera.backAxis;

      expect(right.length, closeTo(1, 1e-12));
      expect(up.length, closeTo(1, 1e-12));
      expect(back.length, closeTo(1, 1e-12));
      expect(right.dot(up), closeTo(0, 1e-12));
      expect(right.dot(back), closeTo(0, 1e-12));
      expect(up.dot(back), closeTo(0, 1e-12));

      // The first three columns of the view matrix are the same basis. A pan
      // written against a *second* basis that merely agrees most of the time
      // slides diagonally near the poles.
      final Float64List m = camera.viewMatrix().storage;
      expect(m[0], closeTo(right.x, 1e-12));
      expect(m[4], closeTo(right.y, 1e-12));
      expect(m[8], closeTo(right.z, 1e-12));
      expect(m[1], closeTo(up.x, 1e-12));
      expect(m[5], closeTo(up.y, 1e-12));
      expect(m[9], closeTo(up.z, 1e-12));
      expect(m[2], closeTo(back.x, 1e-12));
      expect(m[6], closeTo(back.y, 1e-12));
      expect(m[10], closeTo(back.z, 1e-12));
    });

    test('stays orthonormal at the pitch clamp', () {
      final MeshCamera camera = _camera().withPitch(10);
      expect(camera.rightAxis.length, closeTo(1, 1e-12));
      expect(camera.upAxis.length, closeTo(1, 1e-12));
      expect(camera.rightAxis.dot(camera.upAxis), closeTo(0, 1e-12));
    });
  });

  group('MeshCamera.worldUnitsPerPixel', () {
    test('is the scale that puts a pixel offset where it was asked for', () {
      final MeshCamera camera = _camera();
      final double scale = camera.worldUnitsPerPixel(_height);
      const double px = 180;
      const double py = -90;
      final Vector3 point = camera.target +
          camera.rightAxis * (px * scale) +
          camera.upAxis * (-py * scale);
      final (double x, double y) = _project(camera, point);
      expect(x, closeTo(_width / 2 + px, 1e-9));
      expect(y, closeTo(_height / 2 + py, 1e-9));
    });

    test('scales with distance and only with the height', () {
      final MeshCamera near = _camera(distance: 4);
      final MeshCamera far = _camera(distance: 8);
      expect(
        far.worldUnitsPerPixel(_height),
        closeTo(near.worldUnitsPerPixel(_height) * 2, 1e-12),
      );
      // Nothing about a viewport's width may enter: the same drag in a wide
      // window and a tall one has to move the model the same distance.
      expect(near.worldUnitsPerPixel(600), isNot(near.worldUnitsPerPixel(300)));
      expect(near.worldUnitsPerPixel(0), 0);
    });
  });

  group('MeshCamera.pannedByPixels', () {
    test('moves the picture by exactly the drag', () {
      final MeshCamera before = _camera();
      final Vector3 point = before.target;
      final (double x0, double y0) = _project(before, point);

      const double dx = 137;
      const double dy = -64;
      final MeshCamera after =
          before.pannedByPixels(dx, dy, viewportHeight: _height);
      final (double x1, double y1) = _project(after, point);

      // The model follows the cursor: drag right and the model goes right.
      expect(x1 - x0, closeTo(dx, 1e-9));
      expect(y1 - y0, closeTo(dy, 1e-9));
    });

    test('moves twice as much world at twice the distance', () {
      const double dx = 100;
      final Vector3 nearMove = _camera(distance: 4)
              .pannedByPixels(dx, 0, viewportHeight: _height)
              .target -
          _camera(distance: 4).target;
      final Vector3 farMove = _camera(distance: 8)
              .pannedByPixels(dx, 0, viewportHeight: _height)
              .target -
          _camera(distance: 8).target;
      expect(farMove.length, closeTo(nearMove.length * 2, 1e-12));
    });

    test('a pan and its inverse return to the start', () {
      final MeshCamera start = _camera();
      final MeshCamera roundTrip = start
          .pannedByPixels(41, -73, viewportHeight: _height)
          .pannedByPixels(-41, 73, viewportHeight: _height);
      expect(roundTrip.target.x, closeTo(start.target.x, 1e-12));
      expect(roundTrip.target.y, closeTo(start.target.y, 1e-12));
      expect(roundTrip.target.z, closeTo(start.target.z, 1e-12));
    });

    test('changes nothing but the target', () {
      final MeshCamera start = _camera();
      final MeshCamera panned =
          start.pannedByPixels(50, 20, viewportHeight: _height);
      expect(panned.distance, start.distance);
      expect(panned.yaw, start.yaw);
      expect(panned.pitch, start.pitch);
      expect(panned.near, start.near);
      expect(panned.far, start.far);
      // The eye travels with the target: a pan is not an orbit.
      expect(
        (panned.eye - panned.target).length,
        closeTo((start.eye - start.target).length, 1e-12),
      );
    });

    test('a viewport with no height moves nothing', () {
      final MeshCamera start = _camera();
      final MeshCamera panned = start.pannedByPixels(50, 20, viewportHeight: 0);
      expect(panned.target.x, start.target.x);
      expect(panned.target.y, start.target.y);
      expect(panned.target.z, start.target.z);
    });
  });

  group('MeshCamera.zoomedBy', () {
    test('is multiplicative', () {
      final MeshCamera start = _camera(distance: 10);
      expect(start.zoomedBy(0.5).distance, closeTo(5, 1e-12));
      expect(start.zoomedBy(2).distance, closeTo(20, 1e-12));
      expect(
        start.zoomedBy(0.5).zoomedBy(0.5).distance,
        closeTo(start.zoomedBy(0.25).distance, 1e-12),
      );
    });

    test('never reaches zero or a negative distance', () {
      MeshCamera camera = _camera(distance: 10);
      for (int i = 0; i < 500; i++) {
        camera = camera.zoomedBy(0.1);
        expect(camera.distance, greaterThan(0));
        expect(camera.near, greaterThan(0));
        expect(camera.distance, greaterThan(camera.near));
      }
      // The floor is real: five hundred halvings of a halving would otherwise
      // be zero long before this, and the view basis collapses at zero.
      expect(camera.distance, greaterThanOrEqualTo(2e-4));
    });

    test('refuses a factor that is not a positive number', () {
      final MeshCamera start = _camera(distance: 10);
      expect(start.zoomedBy(0).distance, closeTo(10, 1e-12));
      expect(start.zoomedBy(-2).distance, closeTo(10, 1e-12));
      expect(start.zoomedBy(double.nan).distance, closeTo(10, 1e-12));
      expect(start.zoomedBy(double.infinity).distance, closeTo(10, 1e-12));
    });

    test('the far plane follows the camera out', () {
      // Zooming out with a fixed far plane walks the model straight through it
      // and the window goes black with nothing on screen to say why.
      MeshCamera camera = MeshCamera.frame(
        const Bounds3(Vector3(-1, -1, -1), Vector3(1, 1, 1)),
      );
      for (int i = 0; i < 20; i++) {
        camera = camera.zoomedBy(1.5);
        // The far side of a two-unit model, seen from `distance`, is at most
        // distance + 2 away; the far plane has to stay beyond it.
        expect(camera.far, greaterThan(camera.distance + 2));
      }
    });

    test('the near plane follows the camera in', () {
      MeshCamera camera = MeshCamera.frame(
        const Bounds3(Vector3(-1, -1, -1), Vector3(1, 1, 1)),
      );
      final double startNear = camera.near;
      for (int i = 0; i < 20; i++) {
        camera = camera.zoomedBy(0.5);
        expect(camera.near, lessThan(camera.distance));
      }
      expect(camera.near, lessThan(startNear));
    });
  });

  group('MeshCamera.withPitch', () {
    test('clamps short of both poles', () {
      final MeshCamera camera = _camera();
      expect(camera.withPitch(math.pi).pitch, lessThan(math.pi / 2));
      expect(camera.withPitch(-math.pi).pitch, greaterThan(-math.pi / 2));
      expect(camera.withPitch(100).pitch, camera.withPitch(1.6).pitch);
    });

    test('orbitedBy clamps too, however far the drag went', () {
      MeshCamera camera = _camera();
      for (int i = 0; i < 50; i++) {
        camera = camera.orbitedBy(yawDelta: 0.3, pitchDelta: 0.3);
      }
      expect(camera.pitch, lessThan(math.pi / 2));
      // Yaw is deliberately not wrapped: a turntable that has spun for a minute
      // must not jump when its angle crosses a multiple of 2π.
      expect(camera.yaw, greaterThan(2 * math.pi));
    });
  });

  group('OrbitCameraController', () {
    test('a drag of the viewport height turns a full circle', () {
      final OrbitCameraController controls = OrbitCameraController(
        camera: _camera(),
        enableDamping: false,
      );
      final double startYaw = controls.camera.yaw;
      controls.rotateByPixels(_height, 0, viewportHeight: _height);
      expect(controls.update(), isTrue);
      // Negative: dragging right turns the camera the way three.js turns it,
      // which is the direction every other 3D tool the user has opened turns.
      expect(controls.camera.yaw, closeTo(startYaw - 2 * math.pi, 1e-12));
    });

    test('pan through the controller is the camera pan', () {
      final OrbitCameraController controls = OrbitCameraController(
        camera: _camera(),
        enableDamping: false,
      );
      final MeshCamera expected =
          controls.camera.pannedByPixels(60, -25, viewportHeight: _height);
      controls.panByPixels(60, -25, viewportHeight: _height);
      controls.update();
      expect(controls.camera.target.x, closeTo(expected.target.x, 1e-12));
      expect(controls.camera.target.y, closeTo(expected.target.y, 1e-12));
      expect(controls.camera.target.z, closeTo(expected.target.z, 1e-12));
    });

    test(
        'damping applies a fraction and settles in a bounded number of '
        'frames', () {
      final OrbitCameraController controls = OrbitCameraController(
        camera: _camera(),
        dampingFactor: 0.2,
      );
      final double startYaw = controls.camera.yaw;
      controls.rotateByPixels(60, 0, viewportHeight: _height);
      const double wanted = -2 * math.pi * 60 / _height;

      expect(controls.update(), isTrue);
      final double first = controls.camera.yaw - startYaw;
      expect(first, closeTo(wanted * 0.2, 1e-12));

      // It must actually stop. Damping is exponential and never reaches zero,
      // so without the epsilon floor the viewer would report "something moved"
      // on every frame for the rest of the session and never go idle.
      int frames = 1;
      while (controls.isSettling && frames < 500) {
        controls.update();
        frames++;
      }
      expect(controls.isSettling, isFalse);
      expect(frames, lessThan(200));
      expect(controls.camera.yaw - startYaw, closeTo(wanted, 1e-4));
      expect(controls.update(), isFalse);
    });

    test('update reports nothing when nothing is pending', () {
      final OrbitCameraController controls =
          OrbitCameraController(camera: _camera());
      expect(controls.update(), isFalse);
      expect(controls.isSettling, isFalse);
    });

    test('the wheel pulls back on a scroll toward the user', () {
      final OrbitCameraController controls = OrbitCameraController(
        camera: _camera(distance: 10),
      );
      controls.zoomByWheel(1, viewportHeight: _height);
      expect(controls.camera.distance, greaterThan(10));
      final double out = controls.camera.distance;
      controls.zoomByWheel(-1, viewportHeight: _height);
      expect(controls.camera.distance, lessThan(out));
      // One notch out and one notch in is a round trip, because the steps are
      // multiplicative rather than additive.
      expect(controls.camera.distance, closeTo(10, 1e-9));
    });

    test('the wheel zooms about the pointer, not the centre', () {
      final OrbitCameraController controls = OrbitCameraController(
        camera: _camera(distance: 10),
      );
      const double focusX = 210;
      const double focusY = -140;
      final MeshCamera before = controls.camera;
      final double scale = before.worldUnitsPerPixel(_height);
      // The world point on the target plane under the pointer.
      final Vector3 point = before.target +
          before.rightAxis * (focusX * scale) +
          before.upAxis * (-focusY * scale);
      final (double x0, double y0) = _project(before, point);
      expect(x0, closeTo(_width / 2 + focusX, 1e-9));
      expect(y0, closeTo(_height / 2 + focusY, 1e-9));

      controls.zoomByWheel(
        -4,
        focusX: focusX,
        focusY: focusY,
        viewportHeight: _height,
      );
      expect(controls.camera.distance, lessThan(before.distance));

      final (double x1, double y1) = _project(controls.camera, point);
      expect(x1, closeTo(x0, 1e-6));
      expect(y1, closeTo(y0, 1e-6));
    });

    test('zooming about the centre leaves the target alone', () {
      final OrbitCameraController controls = OrbitCameraController(
        camera: _camera(distance: 10),
      );
      final Vector3 target = controls.camera.target;
      controls.zoomByWheel(-2, viewportHeight: _height);
      expect(controls.camera.target.x, target.x);
      expect(controls.camera.target.y, target.y);
      expect(controls.camera.target.z, target.z);
    });

    test('frame returns to the framing camera and drops pending input', () {
      const Bounds3 bounds = Bounds3(Vector3(-1, -1, -1), Vector3(1, 1, 1));
      final OrbitCameraController controls =
          OrbitCameraController.framing(bounds);
      controls
        ..panByPixels(400, 400, viewportHeight: _height)
        ..rotateByPixels(300, 120, viewportHeight: _height)
        ..zoomByWheel(12, viewportHeight: _height)
        ..update();
      expect(controls.camera.target.x, isNot(closeTo(0, 1e-6)));

      controls.frame();
      final MeshCamera framed = MeshCamera.frame(bounds);
      expect(controls.camera.target.x, closeTo(framed.target.x, 1e-12));
      expect(controls.camera.target.y, closeTo(framed.target.y, 1e-12));
      expect(controls.camera.target.z, closeTo(framed.target.z, 1e-12));
      expect(controls.camera.distance, closeTo(framed.distance, 1e-12));
      expect(controls.camera.yaw, closeTo(framed.yaw, 1e-12));
      expect(controls.camera.pitch, closeTo(framed.pitch, 1e-12));

      // The pending damped input is dropped, not left to drag the camera off
      // the framing it was just asked for.
      expect(controls.update(), isTrue); // the frame itself is one change
      expect(controls.camera.target.x, closeTo(framed.target.x, 1e-12));
      expect(controls.isSettling, isFalse);
    });

    test('a turntable spin is applied at once and reported once', () {
      final OrbitCameraController controls =
          OrbitCameraController(camera: _camera());
      final double startYaw = controls.camera.yaw;
      controls.spin(yawDelta: 0.012);
      expect(controls.camera.yaw, closeTo(startYaw + 0.012, 1e-12));
      expect(controls.update(), isTrue);
      expect(controls.update(), isFalse);
    });
  });
}
