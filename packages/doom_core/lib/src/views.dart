import 'config.dart';

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
  });
  final int x, y, z, angle, viewZ, health, armor, bob;
  final Ammo ammo;
  final Weapon weapon;
  final Set<Key> keys;
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
  });
  final int id, x, y, z, angle, frame, flags, health;
  final String sprite;
}

enum PlaneKind { floor, ceiling, light }

/// One record per sector property that changed during a tic. The adapter can
/// apply these directly to existing geometry buffers without rebuilding them.
class SectorChange {
  const SectorChange(this.sector, this.kind, this.value);
  final int sector;
  final PlaneKind kind;
  final int value;
}
