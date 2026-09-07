/// One frame's [MeshScene], assembled from the world.
///
/// The seam between a simulation that knows nothing about drawing and a
/// renderer that knows nothing about the game. Everything above it deals in
/// positions and states; everything below it deals in triangles.
///
/// ## What is rebuilt and what is not
///
/// A [MeshScene] draws exactly one [Mesh3D], so every frame hands the renderer
/// one mesh containing the whole visible world. That does *not* mean every
/// frame rebuilds it: the GPU pipelines cache their vertex buffers keyed on
/// [MeshPrimitive] identity, so the level's primitives — the same objects
/// frame after frame — are uploaded once and the cache answers for them
/// thereafter. Only the cast is rebuilt, and the cast is deliberately small
/// enough that rebuilding it is free. [SceneStats.dynamicVertices] is the
/// number that says whether that is still true.
///
/// ## Culling is by the camera's window, not by a frustum
///
/// A side-scroller knows exactly what is on screen: an interval on x. Testing
/// each actor's centre against that interval is two comparisons and it removes
/// a hundred and twenty units of level from consideration before any of it is
/// built. A general frustum cull would do the same job less well here, because
/// it would run *after* the geometry was built — which is the cost this avoids.
library;

import 'dart:math' as math;

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_scene.dart';

import 'actors.dart';
import 'follow_camera.dart';
import 'level.dart';
import 'mesh_builder.dart';
import 'motion_state.dart';
import 'world.dart';

/// How far the camera sits from the plane the game is played in.
///
/// With a 45° vertical field of view this shows just under ten units of height
/// and sixteen across, which puts the 1.7-unit character at a sixth of the
/// screen and gives two seconds of running between one edge and the other.
/// Fifteen units back was tried first and is the mistake worth naming: the
/// character was a seventh of the frame, more than half of which was empty
/// sky, and the game read as something happening a long way away.
const double cameraDistance = 12.0;

/// A few degrees of yaw and pitch, and no more.
///
/// Straight on (`0, 0`) draws every box as a flat rectangle and the level looks
/// painted. These two angles are enough to show one side face and the top of
/// each platform — which is what tells the player a platform *has* a top — and
/// small enough that the parallax between the level and the character never
/// makes a jump ambiguous.
const double cameraYaw = 0.15;
const double cameraPitch = 0.17;

/// The vertical field of view the camera and the culling both assume.
const double cameraFovY = 0.7853981633974483;

/// What a frame's assembly cost, for the HUD and for the report.
final class SceneStats {
  const SceneStats({
    required this.dynamicVertices,
    required this.dynamicTriangles,
    required this.primitives,
    required this.buildMicroseconds,
  });

  static const SceneStats zero = SceneStats(
    dynamicVertices: 0,
    dynamicTriangles: 0,
    primitives: 0,
    buildMicroseconds: 0,
  );

  /// Vertices rebuilt this frame, which is the number that is re-uploaded to
  /// the GPU this frame. The one to watch: it is the cost the art direction
  /// was chosen to keep down.
  final int dynamicVertices;
  final int dynamicTriangles;

  /// Primitives in the whole scene, static and dynamic.
  final int primitives;

  final int buildMicroseconds;
}

/// Builds a [MeshScene] from a [GameWorld], and keeps what does not change.
final class GameSceneBuilder {
  GameSceneBuilder(this.level) : levelGeometry = LevelGeometry.build(level);

  final Level level;
  final LevelGeometry levelGeometry;

  final PlayerBuilders _player = PlayerBuilders();
  final EnemyBuilders _enemies = EnemyBuilders();
  final MeshBuilder _rings =
      MeshBuilder(const MeshMaterial(colorArgb: Palette.ring));

  SceneStats stats = SceneStats.zero;

  /// Last frame's dynamic primitives, wrapped so they can be handed to
  /// [MeshSceneSurface.discardMesh].
  ///
  /// Without this the GPU keeps a vertex buffer per dynamic primitive per
  /// frame until its budget evicts them — 384 MiB of device memory on the
  /// Direct3D 11 path before anything is released, reached in a few minutes of
  /// play. Handing back exactly the primitives that will never be drawn again
  /// keeps the resident set at one frame's worth. The wrapper holds *only* the
  /// dynamic primitives: passing the whole scene would discard the level too
  /// and re-upload it every frame, which is the opposite of the point.
  Mesh3D? retiredDynamics;

  /// Half the width of the view at the plane the game is played in.
  double halfViewWidth(double aspect) =>
      cameraDistance * math.tan(cameraFovY / 2) * aspect;

  double halfViewHeight() => cameraDistance * math.tan(cameraFovY / 2);

  /// The camera looking at where [camera] has arrived.
  MeshCamera cameraFor(FollowCamera camera) => MeshCamera(
        // Aimed a little above the character's centre, and only a little. The
        // aim point is what decides how much sky is on screen: raising it by a
        // unit pushes the ground a tenth of the frame further down, and the
        // version of this that aimed 2.6 units up drew two thirds sky.
        target: Vector3(camera.x, camera.y + 0.9, 0),
        distance: cameraDistance,
        yaw: cameraYaw,
        pitch: cameraPitch,
        fovYRadians: cameraFovY,
        near: 0.2,
        far: 220,
      );

  /// Moves [camera] to follow the world's player, and keeps it inside the
  /// level.
  ///
  /// Here and not in the widget because the clamp needs [halfViewWidth], which
  /// needs the aspect ratio, which the scene already has to know.
  void follow(
    FollowCamera camera,
    GameWorld world, {
    required double dt,
    required double aspect,
  }) {
    final double alpha = world.alpha;
    camera.follow(
      targetX: world.player.renderX(alpha),
      targetY: world.player.renderY(alpha),
      facing: world.player.facing,
      dt: dt,
      onGround: world.player.onGround,
    );
    final double half = halfViewWidth(aspect);
    camera.clampTo(
      minX: level.minX + half,
      maxX: level.maxX - half,
      // Below this the camera would show the underside of the world. Chosen
      // against the *picture* and not against the geometry: it is the height
      // that puts the ground two thirds of the way down the frame on the flat,
      // which is where a side-scroller's horizon belongs.
      minY: 2.0,
    );
  }

  /// Places [camera] on the player with no easing, for a spawn or a restart.
  void snap(FollowCamera camera, GameWorld world, {required double aspect}) {
    camera.snapTo(world.player.x, world.player.y, facing: world.player.facing);
    final double half = halfViewWidth(aspect);
    camera.clampTo(
      minX: level.minX + half,
      maxX: level.maxX - half,
      minY: 2.0,
    );
  }

  /// The scene for this frame.
  MeshScene build(
    GameWorld world,
    FollowCamera camera, {
    required double aspect,
    MeshShading shading = MeshShading.smooth,
  }) {
    final Stopwatch watch = Stopwatch()..start();
    final double alpha = world.alpha;
    final double clock = world.elapsed;

    _player.clear();
    _enemies.clear();
    _rings.clear();

    // The interval that is on screen, widened by the largest actor so that
    // something entering the view is already drawn when its centre arrives.
    final double half = halfViewWidth(aspect) + 2.5;
    final double left = camera.x - half;
    final double right = camera.x + half;

    for (final Ring ring in world.rings) {
      if (ring.taken) continue;
      if (ring.spawn.x < left || ring.spawn.x > right) continue;
      buildRing(
        _rings,
        x: ring.spawn.x,
        y: ring.spawn.y,
        phase: ring.phase,
        clock: clock,
      );
    }

    for (final Enemy enemy in world.enemies) {
      final double x = enemy.renderX(alpha);
      if (x < left || x > right) continue;
      buildEnemy(
        _enemies,
        x: x,
        y: enemy.renderY(alpha),
        facing: enemy.direction,
        alive: enemy.alive,
        dyingFor: enemy.dyingFor,
        clock: clock,
      );
    }

    // The invulnerability blink. Skipping the draw rather than fading is not a
    // shortcut: there is no alpha in this mesh path, and it is also what every
    // game of this shape does, so it reads immediately as "you were hit and are
    // safe for a moment" rather than as a rendering fault.
    final bool blinkedOut = world.player.invulnerable > 0 &&
        (clock * 14).floor().isEven &&
        world.outcome == GameOutcome.playing;
    if (!blinkedOut) {
      buildPlayer(
        _player,
        x: world.player.renderX(alpha),
        y: world.player.renderY(alpha),
        facing: world.player.facing,
        speed: world.player.velocityX.abs(),
        state: world.player.motion.state,
        clock: clock,
      );
    }

    final List<MeshPrimitive> dynamics = <MeshPrimitive>[];
    final MeshPrimitive? rings = _rings.build();
    if (rings != null) dynamics.add(rings);
    _enemies.emitInto(dynamics);
    _player.emitInto(dynamics);

    var vertices = 0;
    var triangles = 0;
    for (final MeshPrimitive primitive in dynamics) {
      vertices += primitive.vertexCount;
      triangles += primitive.triangleCount;
    }

    retiredDynamics = dynamics.isEmpty
        ? null
        : Mesh3D(
            name: 'side-scroller/dynamic',
            format: 'built-in',
            primitives: dynamics,
          );

    final Mesh3D mesh = Mesh3D(
      name: level.name,
      format: 'built-in',
      primitives: <MeshPrimitive>[...levelGeometry.primitives, ...dynamics],
    );

    stats = SceneStats(
      dynamicVertices: vertices,
      dynamicTriangles: triangles,
      primitives: mesh.primitives.length,
      buildMicroseconds: watch.elapsedMicroseconds,
    );

    return MeshScene(
      mesh: mesh,
      camera: cameraFor(camera),
      shading: shading,
      backgroundArgb: Palette.sky,
      // Down and from the left, so the front faces of the platforms — the ones
      // the player is looking at — are lit and the tops are brighter still.
      lightDirection: const Vector3(0.34, -0.82, -0.46),
      ambient: 0.30,
    );
  }

  /// The pose the player is in, for a HUD that names it.
  MotionState stateOf(GameWorld world) => world.player.motion.state;
}
