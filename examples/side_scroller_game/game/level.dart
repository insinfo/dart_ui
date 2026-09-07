/// The level, as data.
///
/// Separate from the simulation so that the simulation can be tested against a
/// three-box level stated inline, rather than against the real one — a physics
/// test that depends on where a designer put a platform is a test that breaks
/// when the level is edited, and everybody learns to ignore it.
///
/// ## The units
///
/// One unit is roughly a third of the character's height: the player's box is
/// 1.7 units tall and 0.9 wide. Everything else is quoted in those, and the
/// models are scaled to fit them at load ([ActorModel]) rather than the world
/// being scaled to fit the models — because there are four models from four
/// sources and they disagree by factors of a hundred about what a unit is.
library;

import 'collision.dart';

/// What a solid box is for, which is only ever about how it is drawn.
///
/// The simulation treats every [Solid] identically. The distinction is here so
/// that the ground, the platforms and the scenery can be given different
/// colours and heights without the physics growing a switch it does not need.
enum SolidKind { ground, platform, wall, hazardEdge }

final class Solid {
  const Solid(this.box, this.kind);

  final Aabb box;
  final SolidKind kind;
}

final class RingSpawn {
  const RingSpawn(this.x, this.y);

  final double x;
  final double y;
}

final class EnemySpawn {
  const EnemySpawn({
    required this.x,
    required this.y,
    required this.patrolMin,
    required this.patrolMax,
    this.speed = 1.9,
  });

  final double x;
  final double y;

  /// The ends of the patrol, as the centre's x. An enemy turns around here and
  /// never asks the level whether there is floor ahead — a patrol stated as an
  /// interval cannot walk off a platform, and a patrol derived from the floor
  /// can, the first time a designer moves a box.
  final double patrolMin;
  final double patrolMax;

  final double speed;
}

final class Level {
  Level({
    required this.name,
    required this.solids,
    required this.rings,
    required this.enemies,
    required this.spawnX,
    required this.spawnY,
    required this.checkpoints,
    required this.finishX,
    required this.killY,
    required this.minX,
    required this.maxX,
  });

  final String name;
  final List<Solid> solids;
  final List<RingSpawn> rings;
  final List<EnemySpawn> enemies;

  final double spawnX;
  final double spawnY;

  /// Ascending x positions the player respawns at, once passed.
  final List<double> checkpoints;

  final double finishX;

  /// Below this the player has fallen out of the world. Well under the lowest
  /// floor, so that a body pushed a fraction below a floor by the resolver
  /// cannot trigger it.
  final double killY;

  final double minX;
  final double maxX;

  /// Every solid's box, which is what the resolver is handed.
  ///
  /// Built once and kept, because [moveAndCollide] scans the whole list per
  /// substep and rebuilding it per step would allocate a list a hundred times
  /// a second for a level that never changes.
  ///
  /// An instance field and emphatically not a static one: two levels loaded in
  /// one process — which is exactly what a test file does — would otherwise
  /// share the first one's floors, and the second level's player would fall
  /// through everything while standing on geometry from a level it cannot see.
  List<Aabb> get boxes => _boxes ??= <Aabb>[
        for (final Solid solid in solids) solid.box,
      ];

  List<Aabb>? _boxes;
}

/// A box from a left edge, a top surface and a width.
///
/// Levels are written in terms of the surface you stand on, because that is
/// what a designer is placing. Quoting `bottom` instead means computing the
/// top in your head for every platform, and the one you get wrong is a step
/// the player cannot make.
Solid _slab(
  double left,
  double top,
  double width,
  SolidKind kind, {
  double thickness = 1.0,
}) =>
    Solid(
      Aabb(
        left: left,
        bottom: top - thickness,
        right: left + width,
        top: top,
      ),
      kind,
    );

/// The one level this demo ships.
///
/// It is a run to the right, in four movements: flat ground to learn the
/// controls, a gap and a rising staircase, a stretch with two patrolling
/// tanks, and a descent to the finish. Nothing about the shape is load-bearing
/// for anything else in the program.
Level buildDemoLevel() {
  final List<Solid> solids = <Solid>[
    // A wall behind the spawn: without it the player can walk left forever off
    // the start of the level, and the camera clamp then shows an empty world.
    const Solid(
      Aabb(left: -3, bottom: -6, right: -1.4, top: 6),
      SolidKind.wall,
    ),

    _slab(-1.4, 0, 20.4, SolidKind.ground, thickness: 3),
    // First gap: 3.2 units, comfortably inside one jump.
    _slab(22.2, 0, 12, SolidKind.ground, thickness: 3),

    // The staircase.
    _slab(35.5, 1.6, 4.2, SolidKind.platform),
    _slab(41.5, 3.2, 4.2, SolidKind.platform),
    _slab(47.5, 4.8, 6.5, SolidKind.platform),

    // The tank stretch, back at ground level with a floating platform over it.
    _slab(56.5, 0, 26, SolidKind.ground, thickness: 3),
    _slab(63.0, 4.4, 7.0, SolidKind.platform),

    // Second gap, wider: 4.4 units, which needs the run-up.
    _slab(86.9, 0, 18, SolidKind.ground, thickness: 3),
    _slab(92.0, 3.0, 4.0, SolidKind.platform),
    _slab(98.5, 5.2, 4.0, SolidKind.platform),

    _slab(107.5, 0, 16, SolidKind.ground, thickness: 3),
  ];

  return Level(
    name: 'Corrida do Lobo',
    solids: solids,
    rings: const <RingSpawn>[
      RingSpawn(6.5, 1.6),
      RingSpawn(8.5, 1.6),
      RingSpawn(10.5, 1.6),
      RingSpawn(20.4, 2.6),
      RingSpawn(21.3, 3.1),
      RingSpawn(37.6, 3.1),
      RingSpawn(43.6, 4.7),
      RingSpawn(50.7, 6.3),
      RingSpawn(59.5, 1.5),
      RingSpawn(66.5, 5.9),
      RingSpawn(68.5, 5.9),
      RingSpawn(78.0, 1.5),
      RingSpawn(84.5, 2.9),
      RingSpawn(85.7, 3.4),
      RingSpawn(94.0, 4.5),
      RingSpawn(100.5, 6.7),
      RingSpawn(110.0, 1.5),
      RingSpawn(113.0, 1.5),
    ],
    enemies: const <EnemySpawn>[
      EnemySpawn(x: 26.5, y: 0.75, patrolMin: 23.4, patrolMax: 32.5),
      EnemySpawn(
          x: 62.0, y: 0.75, patrolMin: 57.6, patrolMax: 68.0, speed: 2.3),
      EnemySpawn(x: 76.0, y: 0.75, patrolMin: 70.0, patrolMax: 80.5),
      EnemySpawn(
        x: 112.0,
        y: 0.75,
        patrolMin: 108.6,
        patrolMax: 121.0,
        speed: 2.6,
      ),
    ],
    spawnX: 1.5,
    spawnY: 1.2,
    checkpoints: const <double>[35.0, 60.0, 90.0],
    finishX: 121.0,
    killY: -12,
    minX: -1.4,
    maxX: 123.5,
  );
}
