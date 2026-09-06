import 'config.dart';

/// The inventory carried between maps, without position, keys or transient
/// weapon/actor state. A level restart reuses its entry inventory.
final class PlayerLoadout {
  PlayerLoadout({
    required this.health,
    required this.armor,
    required this.ammo,
    required this.weapon,
    required Set<Weapon> ownedWeapons,
  }) : ownedWeapons = Set<Weapon>.unmodifiable(ownedWeapons) {
    if (health <= 0 ||
        health > 200 ||
        armor < 0 ||
        armor > 200 ||
        ammo.bullets < 0 ||
        ammo.shells < 0 ||
        ammo.rockets < 0 ||
        !this.ownedWeapons.contains(weapon) ||
        !this.ownedWeapons.contains(Weapon.fist)) {
      throw ArgumentError('Invalid level-entry inventory');
    }
  }

  final int health;
  final int armor;
  final Ammo ammo;
  final Weapon weapon;
  final Set<Weapon> ownedWeapons;
}

/// Completion data emitted by the simulation, consumed by the episode shell.
final class LevelExit {
  const LevelExit({
    required this.mapName,
    required this.secret,
    required this.loadout,
  });

  final String mapName;
  final bool secret;
  final PlayerLoadout loadout;
}

/// Knee-Deep in the Dead, including the Military Base detour.
abstract final class DoomEpisode {
  static String? nextMap(String mapName, {required bool secret}) {
    if (mapName == 'E1M8') return null;
    if (mapName == 'E1M9') return 'E1M4';
    if (mapName == 'E1M3' && secret) return 'E1M9';
    final int? number = mapName.length == 4 && mapName.startsWith('E1M')
        ? int.tryParse(mapName.substring(3))
        : null;
    return number != null && number >= 1 && number < 8
        ? 'E1M${number + 1}'
        : null;
  }
}
