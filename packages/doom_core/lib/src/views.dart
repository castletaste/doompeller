import 'config.dart';

/// Deterministic first-person weapon state, sampled after every 35 Hz tic.
///
/// The simulation owns this because its phase gates the next shot. The adapter
/// only maps its frame numbers to available WAD sprite lamps.
class WeaponAnimation {
  const WeaponAnimation({
    required this.weapon,
    this.phase = WeaponPhase.ready,
    this.frame = 0,
    this.tics = -1,
    this.y = 32,
    this.flashFrame = -1,
  });

  final Weapon weapon;
  final WeaponPhase phase;
  final int frame;
  final int tics;

  /// Classic psprite screen Y in map-independent screen units.
  final int y;

  /// A flash-lamp index, or -1 when there is no muzzle flash.
  final int flashFrame;
}

enum WeaponPhase { ready, lowering, raising, firing }

/// Immutable renderer-facing snapshot. Coordinates are 16.16 fixed point.
class PlayerView {
  const PlayerView({
    required this.x,
    required this.y,
    required this.z,
    required this.angle,
    required this.viewZ,
    required this.health,
    required this.armor,
    required this.ammo,
    required this.weapon,
    required this.bob,
    required this.keys,
    this.weaponAnimation = const WeaponAnimation(weapon: Weapon.pistol),
  });
  final int x, y, z, angle, viewZ, health, armor, bob;
  final Ammo ammo;
  final Weapon weapon;
  final Set<Key> keys;
  final WeaponAnimation weaponAnimation;
}

class MobjView {
  const MobjView({
    required this.id,
    required this.x,
    required this.y,
    required this.z,
    required this.angle,
    required this.sprite,
    required this.frame,
    required this.flags,
    required this.health,
    this.height = 0,
    this.fullBright = false,
    this.lightLevel = 255,
  });
  final int id, x, y, z, angle, frame, flags, health, height, lightLevel;
  final String sprite;
  final bool fullBright;
}

enum PlaneKind { floor, ceiling, light, floorFlat }

/// One record per sector property that changed during a tic. The adapter can
/// apply these directly to existing geometry buffers without rebuilding them.
class SectorChange {
  const SectorChange(this.sector, this.kind, this.value) : flatName = '';

  const SectorChange.floorFlat(this.sector, this.flatName)
    : kind = PlaneKind.floorFlat,
      value = 0;

  final int sector;
  final PlaneKind kind;
  final int value;
  final String flatName;
}
