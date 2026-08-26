import 'package:doom_wad/doom_wad.dart';

/// Difficulty and simulation options. These are immutable so a replay has an
/// unambiguous ruleset as well as a seed and input stream.
enum Skill { easy, medium, hard }

class GameConfig {
  const GameConfig({
    this.skill = Skill.medium,
    this.maxCatchUpTics = 4,
    this.monsters = true,
    // Kept equal to DoomLimits.defaults.maxSectors. Dart constant evaluation
    // cannot use an instance-field read as a default parameter expression.
    this.maxSoundPropagationVisits = 65535,
    this.maxStairBuildVisits = 65535,
    this.maxDonutBuildVisits = 65535,
  }) : assert(maxSoundPropagationVisits > 0),
       assert(maxStairBuildVisits > 0),
       assert(maxDonutBuildVisits > 0);

  final Skill skill;
  final int maxCatchUpTics;
  final bool monsters;

  /// Maximum sectors one weapon-noise alert may visit. Loaded maps are already
  /// bounded by [DoomLimits.maxSectors], while this also bounds directly
  /// constructed maps used by embedders and adversarial tests.
  final int maxSoundPropagationVisits;

  /// Maximum sectors one stair-building activation may inspect and schedule.
  /// This protects the tic from cyclic or adversarial sector graphs.
  final int maxStairBuildVisits;

  /// Maximum sectors one donut/flat-model topology walk may inspect.
  final int maxDonutBuildVisits;
}

enum Weapon { fist, pistol, shotgun, chaingun }

/// The three Doom keys. A locked line consumes none of them; it only gates use.
enum Key { blue, yellow, red }

class Ammo {
  const Ammo({this.bullets = 50, this.shells = 0});
  final int bullets;
  final int shells;
}
