import 'angles.dart';
import 'fixed.dart';
import 'mobj_info.dart';
import 'mobj_states.dart';

/// A live actor in the simulation: the player, a monster, a projectile, a
/// pickup, a decoration.
///
/// All positional state is fixed point so ticks are bit-reproducible. Rendering
/// reads interpolated doubles derived from [x], [y], [z] but never writes back.
class Mobj {
  Mobj({
    required this.id,
    required this.info,
    required this.x,
    required this.y,
    required this.z,
    required this.angle,
    required this.health,
    required this.sectorIndex,
  }) : radius = toFixed(info.radius),
       height = toFixed(info.height),
       flags = info.flags;

  final int id;
  final MobjInfo info;

  /// Fixed-point world position.
  int x;
  int y;
  int z;

  /// Fixed-point velocity per tic.
  int momX = 0;
  int momY = 0;
  int momZ = 0;

  /// BAM facing.
  int angle;

  final int radius;
  int height;

  int flags;
  int health;

  /// Sector the actor's centre currently sits in.
  int sectorIndex;

  /// Floor and ceiling the actor is currently standing between, updated by the
  /// movement code. Cached because gravity and step-up run every tic.
  int floorZ = 0;
  int ceilingZ = 0;

  /// Lowest adjacent floor reachable from the current position. Monsters refuse
  /// to walk off a drop taller than 24 units unless they are allowed to.
  int dropOffZ = 0;

  /// Sprite animation state. [frameState] is the exact table entry; [state]
  /// is its coarse behaviour phase.
  int frameState = -1;
  late String spriteName = info.spriteName;
  int spriteFrame = 0;
  bool fullBright = false;
  int stateTics = -1;
  MobjState state = MobjState.spawn;

  /// Ticks before the actor may act again.
  int reactionTime = 0;

  /// Countdown after being hurt, used to decide whether to keep chasing.
  int threshold = 0;

  /// Current movement direction for the coarse eight-way monster walk.
  int moveDir = kDirNone;
  int moveCount = 0;

  /// Index of the actor this one is currently fighting, or null.
  Mobj? target;

  /// Map-thing ambush flag. An ambush monster hears alerts, but requires sight
  /// before it commits to the source.
  bool ambush = false;

  /// Actor that spawned a projectile. Kept separate from [target] so collision
  /// never turns a projectile around onto its owner.
  Mobj? owner;

  /// Set when the actor has been removed and should be reaped after the tic.
  bool removed = false;

  bool get isOnGround => z <= floorZ;
  bool get isMissile => (flags & MobjFlags.missile) != 0;
  bool get isSolid => (flags & MobjFlags.solid) != 0;
  bool get isShootable => (flags & MobjFlags.shootable) != 0;
  bool get isCorpse => (flags & MobjFlags.corpse) != 0;

  /// Unbobbed eye height used for line-of-sight. The renderer-facing player
  /// view applies camera bob and the current sector ceiling clamp separately.
  int get viewZ => z + toFixed(41);

  /// Sets velocity from a speed and a direction.
  void thrust(int direction, int speed) {
    momX = wrap32(momX + fixedMul(speed, Trig.cos(direction)));
    momY = wrap32(momY + fixedMul(speed, Trig.sin(direction)));
  }
}

/// Coarse movement directions used by monster AI.
const int kDirEast = 0;
const int kDirNorthEast = 1;
const int kDirNorth = 2;
const int kDirNorthWest = 3;
const int kDirWest = 4;
const int kDirSouthWest = 5;
const int kDirSouth = 6;
const int kDirSouthEast = 7;
const int kDirNone = 8;

/// BAM angle for each of the eight walk directions.
const List<int> kDirAngles = <int>[
  0,
  kAng45,
  kAng90,
  kAng90 + kAng45,
  kAng180,
  kAng180 + kAng45,
  kAng270,
  kAng270 + kAng45,
];
