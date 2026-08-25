/// Difficulty and simulation options. These are immutable so a replay has an
/// unambiguous ruleset as well as a seed and input stream.
enum Skill { easy, medium, hard }

class GameConfig {
  const GameConfig({
    this.skill = Skill.medium,
    this.maxCatchUpTics = 4,
    this.monsters = true,
  });

  final Skill skill;
  final int maxCatchUpTics;
  final bool monsters;
}

enum Weapon { fist, pistol, shotgun, chaingun }

/// The three Doom keys. A locked line consumes none of them; it only gates use.
enum Key { blue, yellow, red }

class Ammo {
  const Ammo({this.bullets = 50, this.shells = 0});
  final int bullets;
  final int shells;
}
