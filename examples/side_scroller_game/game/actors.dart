/// The cast, posed. One branch per [MotionState] the machine can name.
///
/// This is the file that turns a simulation into a game you can read. The
/// physics already knows the character is airborne and rising; nothing about
/// the physics says the character should therefore be a spinning ball, and that
/// decision — one per state, taken here — is the whole difference between
/// watching numbers and playing something.
///
/// ## Mirroring is a rotation, never a negative scale
///
/// A character facing left is drawn by turning it half a turn about Y. The
/// obvious alternative — scaling X by -1 — reverses the winding of every
/// triangle in the model, the back-face cull then throws all of them away, and
/// the character vanishes the first time the player presses left. It is a
/// spectacular failure with a one-character cause, so [_facingTurn] is the only
/// place in this game that mirrors anything.
///
/// ## Why an actor is several builders pushed in step
///
/// A [MeshPrimitive] carries one material, so a character in four colours is
/// four primitives, and a pose is a transform that has to reach all four at
/// once. [ActorBuilders.push] therefore pushes every builder in the group
/// together. Posing them one at a time is the bug that leaves the shoes
/// standing still while the legs walk away.
library;

import 'dart:math' as math;

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';

import 'level.dart';
import 'mesh_builder.dart';
import 'motion_state.dart';

/// Every colour the game draws, named once.
///
/// A palette in one place because the level, the cast and the HUD have to
/// agree — a ring drawn in the same yellow as the goal flag reads as a second
/// goal — and because the alternative is a hex literal per call site and no way
/// to tell which of the eleven browns is the ground.
abstract final class Palette {
  static const int sky = 0xFF2C6FA8;

  static const int grass = 0xFF4FA83F;
  static const int soil = 0xFF7A4B2A;
  static const int stoneTop = 0xFFBFA98A;
  static const int stoneBody = 0xFF7E6E5A;
  static const int wall = 0xFF5C6472;

  static const int hillNear = 0xFF27594B;
  static const int hillFar = 0xFF4B7FAC;

  static const int quills = 0xFF2A63E0;
  static const int skin = 0xFFF2C79C;
  static const int shoes = 0xFFE0392C;
  static const int eyeWhite = 0xFFFAFAFA;
  static const int pupil = 0xFF14203A;

  static const int enemyHull = 0xFF525C6B;
  static const int enemyShell = 0xFFC0392B;
  static const int enemyEye = 0xFFFFC93C;
  static const int enemyTread = 0xFF2B303A;

  static const int ring = 0xFFFFC61A;
  static const int goalPost = 0xFFD8DEE9;
  static const int goalFlag = 0xFF2ECC71;

  /// The HUD's colours, which are the display list's rather than the mesh's.
  static const int hudPanel = 0xD2101725;
  static const int hudText = 0xFFEAF1FB;
  static const int hudMuted = 0xFF8FA3BE;
  static const int hudWarning = 0xFFE0754A;
}

/// Half the depth every actor is given.
///
/// The game is played in the `z == 0` plane and the level's slabs run from
/// [levelBackZ] to [levelFrontZ], so an actor half this deep sits *inside* the
/// slab's front face. That is deliberate: a platform in front of the character
/// then occludes it, which is the depth cue that tells a player they are behind
/// a platform rather than on it. Pushing the cast forward of the level instead
/// makes every jump look like it cleared everything.
const double actorHalfDepth = 0.35;

/// How far the level's geometry extends toward the camera.
const double levelFrontZ = 0.5;

/// And away from it. Deep enough that the slabs read as ground rather than as
/// cardboard, shallow enough that the far faces are never on screen.
const double levelBackZ = -3.2;

/// A half turn about Y for a character facing left, nothing for one facing
/// right. See the library comment for what the obvious alternative destroys.
Matrix4 _facingTurn(double facing) =>
    facing < 0 ? rotationY(math.pi) : Matrix4.identity();

/// A group of builders that are pushed, popped and emitted as one actor.
abstract base class ActorBuilders {
  /// The builders, in the order their primitives are emitted.
  List<MeshBuilder> get builders;

  void push(Matrix4 transform) {
    for (final MeshBuilder builder in builders) {
      builder.push(transform);
    }
  }

  void pop() {
    for (final MeshBuilder builder in builders) {
      builder.pop();
    }
  }

  void withTransform(Matrix4 transform, void Function() body) {
    push(transform);
    try {
      body();
    } finally {
      pop();
    }
  }

  void clear() {
    for (final MeshBuilder builder in builders) {
      builder.clear();
    }
  }

  /// Appends whatever was built to [out], skipping the colours nothing used.
  void emitInto(List<MeshPrimitive> out) {
    for (final MeshBuilder builder in builders) {
      final MeshPrimitive? primitive = builder.build();
      if (primitive != null) out.add(primitive);
    }
  }
}

// ---------------------------------------------------------------------------
// The player
// ---------------------------------------------------------------------------

final class PlayerBuilders extends ActorBuilders {
  PlayerBuilders();

  final MeshBuilder quills =
      MeshBuilder(const MeshMaterial(colorArgb: Palette.quills));
  final MeshBuilder skin =
      MeshBuilder(const MeshMaterial(colorArgb: Palette.skin));
  final MeshBuilder shoes =
      MeshBuilder(const MeshMaterial(colorArgb: Palette.shoes));
  final MeshBuilder eyes =
      MeshBuilder(const MeshMaterial(colorArgb: Palette.eyeWhite));
  final MeshBuilder pupils =
      MeshBuilder(const MeshMaterial(colorArgb: Palette.pupil));

  @override
  late final List<MeshBuilder> builders = <MeshBuilder>[
    quills,
    skin,
    shoes,
    eyes,
    pupils,
  ];
}

/// Draws the player at ([x], [y]) in the state its machine reports.
///
/// [clock] is the world's simulated time and not a wall clock, so a scripted
/// run replays the same poses — which is what makes the state at step 400
/// comparable between two runs at all.
void buildPlayer(
  PlayerBuilders into, {
  required double x,
  required double y,
  required double facing,
  required double speed,
  required MotionState state,
  required double clock,
}) {
  final Matrix4 place =
      Matrix4.translation(Vector3(x, y, 0)).multiply(_facingTurn(facing));

  switch (state) {
    case MotionState.jump:
    case MotionState.fall:
      // The signature move, and the reason the state machine splits airborne
      // from grounded at all: airborne is a ball. It rolls the way the
      // character is travelling — the mirror has already turned the model, so
      // the sign here is the same either way.
      _buildBall(into, place, roll: -clock * 13.0);
    case MotionState.dead:
      into.withTransform(
        place
            .multiply(Matrix4.translation(const Vector3(0, -0.45, 0)))
            .multiply(rotationZ(1.45)),
        () => _buildFigure(into, legAngle: 0.6, armAngle: -1.9, lean: 0),
      );
    case MotionState.hurt:
      into.withTransform(
        place.multiply(rotationZ(-0.45)),
        () => _buildFigure(into, legAngle: 0.7, armAngle: -2.1, lean: 0),
      );
    case MotionState.run:
      // The stride's frequency follows the speed, so slowing down slows the
      // legs instead of playing the same loop more quietly. Clamped at the
      // bottom because a character sliding to a halt at 0.4 units a second
      // would otherwise take four seconds to complete one step.
      final double cadence = math.max(2.6, speed * 1.7);
      final double phase = clock * cadence;
      final double swing = math.sin(phase) * 0.95;
      into.withTransform(
        Matrix4.translation(Vector3(0, math.sin(phase * 2).abs() * 0.05, 0))
            .multiply(place),
        () => _buildFigure(
          into,
          legAngle: swing,
          armAngle: -swing * 0.8,
          lean: 0.20,
        ),
      );
    case MotionState.idle:
      final double bob = math.sin(clock * 2.4) * 0.028;
      into.withTransform(
        Matrix4.translation(Vector3(0, bob, 0)).multiply(place),
        () => _buildFigure(into, legAngle: 0, armAngle: 0.12, lean: 0),
      );
  }
}

/// The standing figure, in the group's current transform.
void _buildFigure(
  PlayerBuilders into, {
  required double legAngle,
  required double armAngle,
  required double lean,
}) {
  // The lean is taken about the hips, which is where a running body actually
  // pivots; leaning about the centre buries the feet in the floor at the same
  // angle.
  final Matrix4 body = Matrix4.translation(const Vector3(0, -0.5, 0))
      .multiply(rotationZ(-lean))
      .multiply(Matrix4.translation(const Vector3(0, 0.5, 0)));

  into.push(body);

  final MeshBuilder q = into.quills;
  q.addSphere(const Vector3(0, 0.06, 0), 0.44, 10, 6);
  q.addSphere(const Vector3(0, 0.60, 0), 0.34, 10, 6);
  // Three quills off the back of the head, fanned. The back is -X because the
  // model is built facing +X and the mirror turns the whole thing.
  for (var i = 0; i < 3; i++) {
    final double angle = 2.5 + i * 0.42;
    q.addSpike(
      const Vector3(-0.18, 0.62, 0),
      Vector3(-0.18 + math.cos(angle) * 0.62, 0.62 + math.sin(angle) * 0.62, 0),
      0.09,
    );
  }

  into.skin.addSphere(const Vector3(0.26, 0.50, 0.02), 0.19, 8, 5);
  // The eyes have to *clear* the head, not sit inside it: a sphere of radius
  // 0.11 centred 0.27 from a head of radius 0.34 pokes out by four
  // hundredths, which at this camera distance is one pixel and reads as no
  // eyes at all. The pupils are the same argument one level down.
  for (final double side in <double>[0.155, -0.155]) {
    into.eyes.addSphere(Vector3(0.25, 0.68, side), 0.125, 7, 5);
    into.pupils.addSphere(Vector3(0.34, 0.68, side), 0.062, 6, 4);
  }

  // Each limb is a *rotation about its joint*, which is why it is a push and
  // not an offset: a limb translated instead of rotated slides out of its
  // socket at the extremes of the swing.
  _arm(into, const Vector3(0, 0.30, 0.42), armAngle);
  _arm(into, const Vector3(0, 0.30, -0.42), -armAngle);
  _leg(into, const Vector3(0, -0.22, 0.16), legAngle);
  _leg(into, const Vector3(0, -0.22, -0.16), -legAngle);

  into.pop();
}

void _arm(PlayerBuilders into, Vector3 pivot, double angle) {
  final Matrix4 joint = Matrix4.translation(pivot).multiply(rotationZ(angle));
  into.skin.withTransform(joint, () {
    into.skin
      ..addBoxCentred(
          const Vector3(0, -0.21, 0), const Vector3(0.09, 0.21, 0.09))
      ..addSphere(const Vector3(0, -0.42, 0), 0.12, 6, 4);
  });
}

void _leg(PlayerBuilders into, Vector3 pivot, double angle) {
  final Matrix4 joint = Matrix4.translation(pivot).multiply(rotationZ(angle));
  into.skin.withTransform(joint, () {
    into.skin.addBoxCentred(
      const Vector3(0, -0.22, 0),
      const Vector3(0.09, 0.22, 0.09),
    );
  });
  // The shoe hangs off the end of the leg and is counter-rotated back to level:
  // a shoe that turns with the thigh points at the sky at the top of a stride.
  into.shoes.withTransform(
    joint
        .multiply(Matrix4.translation(const Vector3(0, -0.44, 0)))
        .multiply(rotationZ(-angle)),
    () => into.shoes.addBoxCentred(
      const Vector3(0.06, -0.11, 0),
      const Vector3(0.20, 0.11, 0.13),
    ),
  );
}

/// The airborne ball: a sphere, five quills radiating, and the shoes tucked in.
void _buildBall(PlayerBuilders into, Matrix4 place, {required double roll}) {
  final Matrix4 spin = place.multiply(rotationZ(roll));
  into.quills.withTransform(spin, () {
    into.quills.addSphere(Vector3.zero, 0.50, 12, 8);
    for (var i = 0; i < 5; i++) {
      final double angle = i * (2 * math.pi / 5);
      final double cx = math.cos(angle);
      final double sy = math.sin(angle);
      into.quills.addSpike(
        Vector3(cx * 0.44, sy * 0.44, 0),
        Vector3(cx * 0.88, sy * 0.88, 0),
        0.10,
      );
    }
  });
  into.shoes.withTransform(spin, () {
    into.shoes
      ..addBoxCentred(
        const Vector3(0.30, -0.34, 0.17),
        const Vector3(0.19, 0.11, 0.12),
      )
      ..addBoxCentred(
        const Vector3(0.30, -0.34, -0.17),
        const Vector3(0.19, 0.11, 0.12),
      );
  });
}

// ---------------------------------------------------------------------------
// The enemies
// ---------------------------------------------------------------------------

final class EnemyBuilders extends ActorBuilders {
  EnemyBuilders();

  final MeshBuilder hull =
      MeshBuilder(const MeshMaterial(colorArgb: Palette.enemyHull));
  final MeshBuilder shell =
      MeshBuilder(const MeshMaterial(colorArgb: Palette.enemyShell));
  final MeshBuilder eye =
      MeshBuilder(const MeshMaterial(colorArgb: Palette.enemyEye));
  final MeshBuilder tread =
      MeshBuilder(const MeshMaterial(colorArgb: Palette.enemyTread));

  @override
  late final List<MeshBuilder> builders = <MeshBuilder>[
    hull,
    shell,
    eye,
    tread
  ];
}

/// How long a stomped enemy takes to flatten out of existence.
const double enemyDeathSeconds = 0.42;

/// Draws one enemy, flattening it if it has been stomped.
///
/// Returns false once it has finished dying and must not be drawn at all, which
/// is what stops a squashed enemy leaving a permanent smear on the floor.
bool buildEnemy(
  EnemyBuilders into, {
  required double x,
  required double y,
  required double facing,
  required bool alive,
  required double dyingFor,
  required double clock,
}) {
  if (!alive && dyingFor >= enemyDeathSeconds) return false;

  // A stomp squashes vertically and spreads horizontally, which is the cartoon
  // convention and, more usefully, is instantly distinguishable from an enemy
  // that simply disappeared because of a bug.
  final double squash =
      alive ? 1.0 : math.max(0.06, 1 - dyingFor / enemyDeathSeconds);
  // Scaled about the enemy's *base* and not its centre, so a flattening body
  // stays on the floor instead of sinking through it.
  final Matrix4 place = Matrix4.translation(Vector3(x, y - 0.6, 0))
      .multiply(Matrix4.scale(Vector3(1 + (1 - squash) * 0.7, squash, 1)))
      .multiply(Matrix4.translation(const Vector3(0, 0.6, 0)))
      .multiply(_facingTurn(facing));

  into.push(place);

  into.hull.addBoxCentred(
    const Vector3(0, -0.14, 0),
    const Vector3(0.70, 0.26, actorHalfDepth),
  );
  into.shell.addSphere(const Vector3(0, 0.06, 0), 0.46, 12, 6, stackTo: 3);
  into.eye.addSphere(const Vector3(0.40, 0.16, 0), 0.15, 8, 5);
  into.tread.addBoxCentred(
    const Vector3(0, -0.46, 0),
    const Vector3(0.74, 0.14, actorHalfDepth * 0.8),
  );
  // Two wheels turning at the speed the enemy is travelling. They are the only
  // moving part on a patrolling enemy, and without them a badnik sliding along
  // a floor looks like a bug in the collision.
  final double roll = alive ? -clock * 5.2 : 0;
  for (final double offset in <double>[-0.42, 0.42]) {
    into.tread.withTransform(
      Matrix4.translation(Vector3(offset, -0.46, 0)).multiply(rotationZ(roll)),
      () => into.tread.addSphere(Vector3.zero, 0.19, 8, 5),
    );
  }

  into.pop();
  return true;
}

// ---------------------------------------------------------------------------
// The rings
// ---------------------------------------------------------------------------

/// Draws one ring, spun about its vertical axis by [clock] and its own phase.
void buildRing(
  MeshBuilder into, {
  required double x,
  required double y,
  required double phase,
  required double clock,
}) {
  into.withTransform(
    Matrix4.translation(Vector3(x, y, 0))
        .multiply(rotationY(clock * 3.1 + phase)),
    () => into.addRing(Vector3.zero, 0.34, 0.10, 12, 6),
  );
}

// ---------------------------------------------------------------------------
// The level, which is built once
// ---------------------------------------------------------------------------

/// Every primitive the level contributes, built once and kept.
///
/// Kept, and that is the whole point of the class: the GPU pipelines cache
/// their vertex buffers keyed on [MeshPrimitive] identity, so these objects
/// being the *same objects* every frame is what stops the level's geometry
/// being re-uploaded a hundred times a second. Rebuilding them would be
/// invisible in the picture and would be most of the frame's cost.
final class LevelGeometry {
  LevelGeometry._(this.primitives);

  factory LevelGeometry.build(Level level) {
    final MeshBuilder grass =
        MeshBuilder(const MeshMaterial(colorArgb: Palette.grass));
    final MeshBuilder soil =
        MeshBuilder(const MeshMaterial(colorArgb: Palette.soil));
    final MeshBuilder stoneTop =
        MeshBuilder(const MeshMaterial(colorArgb: Palette.stoneTop));
    final MeshBuilder stoneBody =
        MeshBuilder(const MeshMaterial(colorArgb: Palette.stoneBody));
    final MeshBuilder wall =
        MeshBuilder(const MeshMaterial(colorArgb: Palette.wall));
    final MeshBuilder goal =
        MeshBuilder(const MeshMaterial(colorArgb: Palette.goalPost));
    final MeshBuilder flag =
        MeshBuilder(const MeshMaterial(colorArgb: Palette.goalFlag));
    final MeshBuilder hills =
        MeshBuilder(const MeshMaterial(colorArgb: Palette.hillNear));
    final MeshBuilder distance =
        MeshBuilder(const MeshMaterial(colorArgb: Palette.hillFar));

    // How much of a slab is drawn in its surface colour.
    const double cap = 0.34;

    for (final Solid solid in level.solids) {
      final bool walkable =
          solid.kind == SolidKind.ground || solid.kind == SolidKind.platform;
      final MeshBuilder top = switch (solid.kind) {
        SolidKind.ground => grass,
        SolidKind.platform => stoneTop,
        SolidKind.wall || SolidKind.hazardEdge => wall,
      };
      final MeshBuilder side = switch (solid.kind) {
        SolidKind.ground => soil,
        SolidKind.platform => stoneBody,
        SolidKind.wall || SolidKind.hazardEdge => wall,
      };
      final double split = solid.box.top - math.min(cap, solid.box.height);
      top.addBox(
        Vector3(solid.box.left, split, levelBackZ),
        Vector3(solid.box.right, solid.box.top, levelFrontZ),
      );
      if (split > solid.box.bottom) {
        side.addBox(
          Vector3(solid.box.left, solid.box.bottom, levelBackZ),
          Vector3(solid.box.right, split, levelFrontZ),
        );
      }
      // A lip along the front of every walkable slab. Without it a platform
      // seen almost face-on is one flat rectangle of colour and the eye cannot
      // tell where its top surface is — which matters, because that surface is
      // the thing the player has to land on.
      if (walkable) {
        side.addBox(
          Vector3(solid.box.left, solid.box.top - cap * 1.5, levelFrontZ),
          Vector3(solid.box.right, solid.box.top - cap, levelFrontZ + 0.18),
        );
      }
    }

    // The goal: a post with a flag, at the x the world calls finished.
    goal.addBox(
      Vector3(level.finishX - 0.12, 0, -0.3),
      Vector3(level.finishX + 0.12, 6.4, 0.3),
    );
    for (var i = 0; i < 3; i++) {
      flag.addBox(
        Vector3(level.finishX + 0.12, 5.2 - i * 0.5, -0.06),
        Vector3(level.finishX + 1.9, 5.6 - i * 0.5, 0.06),
      );
    }

    // Two ranges of hills behind everything, at depths the camera's small yaw
    // parallaxes against the level. They are what makes the world read as a
    // place rather than as boxes on a colour.
    // Far enough back that they never crowd the character's silhouette, which
    // the first attempt did: a range at z = -13 put green cones directly
    // behind a green-lit blue character and the eye lost him against them
    // every time he jumped.
    final int ranges = ((level.maxX - level.minX) / 6.2).ceil() + 4;
    for (var i = 0; i < ranges; i++) {
      final double at = level.minX - 9 + i * 6.2;
      hills.addSpike(
        Vector3(at, -7, -19),
        Vector3(at, -0.4 + (i.isEven ? 2.2 : 0.6), -19),
        3.4,
      );
      distance.addSpike(
        Vector3(at + 3.1, -9, -34),
        Vector3(at + 3.1, 1.6 + (i % 3) * 1.6, -34),
        5.6,
      );
    }

    final List<MeshPrimitive> primitives = <MeshPrimitive>[];
    for (final MeshBuilder builder in <MeshBuilder>[
      distance,
      hills,
      soil,
      grass,
      stoneBody,
      stoneTop,
      wall,
      goal,
      flag,
    ]) {
      final MeshPrimitive? primitive = builder.build();
      if (primitive != null) primitives.add(primitive);
    }
    return LevelGeometry._(primitives);
  }

  final List<MeshPrimitive> primitives;

  int get triangleCount {
    var total = 0;
    for (final MeshPrimitive primitive in primitives) {
      total += primitive.triangleCount;
    }
    return total;
  }
}
