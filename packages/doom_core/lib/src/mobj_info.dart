import 'package:meta/meta.dart';

/// Static description of an actor class.
///
/// These are the tuning constants that make Doom feel like Doom: how much
/// health an imp has, how wide a demon is, how fast a rocket travels. The
/// numbers are re-derived from the published game data; no engine source is
/// embedded here, and the behaviour that consumes them is written from scratch.
@immutable
class MobjInfo {
  const MobjInfo({
    required this.id,
    required this.doomEdNum,
    required this.spawnHealth,
    required this.radius,
    required this.height,
    required this.mass,
    required this.speed,
    required this.reactionTime,
    required this.painChance,
    required this.damage,
    required this.spriteName,
    required this.flags,
    this.seeSound,
    this.attackSound,
    this.painSound,
    this.deathSound,
    this.activeSound,
  });

  final MobjType id;

  /// Thing type number as it appears in a THINGS lump, or -1 when the actor is
  /// only ever spawned by code (projectiles, puffs, blood).
  final int doomEdNum;

  final int spawnHealth;

  /// Collision radius in whole map units.
  final int radius;

  /// Collision height in whole map units.
  final int height;

  final int mass;

  /// Movement speed. Monsters move in whole units per move attempt;
  /// projectiles move in fixed-point units per tic.
  final int speed;

  final int reactionTime;

  /// Probability out of 256 of entering the pain state when damaged.
  final int painChance;

  /// Projectile damage multiplier.
  final int damage;

  /// Four-character sprite prefix, e.g. `TROO` for an imp.
  final String spriteName;

  final int flags;

  final String? seeSound;
  final String? attackSound;
  final String? painSound;
  final String? deathSound;
  final String? activeSound;

  bool get isMonster => (flags & MobjFlags.countKill) != 0;
  bool get isPickup => (flags & MobjFlags.special) != 0;
  bool get isShootable => (flags & MobjFlags.shootable) != 0;
  bool get isSolid => (flags & MobjFlags.solid) != 0;
  bool get isMissile => (flags & MobjFlags.missile) != 0;
}

/// Actor behaviour flags.
abstract final class MobjFlags {
  static const int special = 0x0001;
  static const int solid = 0x0002;
  static const int shootable = 0x0004;
  static const int noSector = 0x0008;
  static const int noBlockmap = 0x0010;
  static const int ambush = 0x0020;
  static const int justHit = 0x0040;
  static const int justAttacked = 0x0080;
  static const int spawnCeiling = 0x0100;
  static const int noGravity = 0x0200;
  static const int dropOff = 0x0400;
  static const int pickup = 0x0800;
  static const int noClip = 0x1000;
  static const int slide = 0x2000;
  static const int float = 0x4000;
  static const int teleport = 0x8000;
  static const int missile = 0x10000;
  static const int dropped = 0x20000;
  static const int shadow = 0x40000;
  static const int noBlood = 0x80000;
  static const int corpse = 0x100000;
  static const int inFloat = 0x200000;
  static const int countKill = 0x400000;
  static const int countItem = 0x800000;
  static const int skullFly = 0x1000000;
  static const int notDeathmatch = 0x2000000;
}

/// Actor classes needed for E1M1 plus the projectiles and effects they use.
enum MobjType {
  player,
  possessed,
  shotguy,
  troop,
  sergeant,
  troopshot,
  puff,
  blood,
  teleportFog,
  itemFog,
  bfgSpray,
  misc0,
  misc1,
  misc2,
  misc3,
  misc4,
  misc5,
  misc6,
  misc7,
  misc8,
  misc9,
  misc10,
  misc11,
  misc12,
  inv,
  misc13,
  ins,
  misc14,
  misc15,
  misc16,
  megaHealth,
  clip,
  misc17,
  misc18,
  misc19,
  misc20,
  misc21,
  misc22,
  misc23,
  chaingun,
  misc25,
  shotgun,
  misc27,
  misc28,
  barrel,
  misc29,
  misc30,
  misc31,
  misc32,
  misc33,
  misc34,
  misc35,
  misc36,
  misc37,
  misc38,
  misc39,
  misc40,
  misc41,
  misc42,
  misc43,
  misc44,
  misc45,
  misc46,
  misc47,
  misc48,
  misc49,
  misc50,
  misc51,
  misc52,
  misc53,
  misc54,
  misc55,
  misc56,
  misc57,
  misc58,
  misc59,
  misc60,
  misc61,
  misc62,
  misc63,
  misc64,
  misc65,
  misc66,
  misc67,
  misc68,
  misc69,
  teleportSpot,
}
