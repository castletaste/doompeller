import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

import 'specials_test.dart' show testMap;

const int _skills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

MapData _pickupMap(List<int> types, {int sectorSpecial = 0}) => testMap(
  sectors: <Sector>[
    Sector(
      floorHeight: 0,
      ceilingHeight: 128,
      floorFlat: 'F',
      ceilingFlat: 'C',
      lightLevel: 160,
      special: sectorSpecial,
      tag: 0,
    ),
  ],
  things: <Thing>[
    const Thing(x: 64, y: 64, angle: 0, type: 1, flags: _skills),
    for (final int type in types)
      Thing(x: 64, y: 64, angle: 0, type: type, flags: _skills),
  ],
);

MapData _monsterAimMap(int monsterEdNum, {required bool invisible}) => testMap(
  vertices: const <MapVertex>[],
  lines: const <Linedef>[],
  sides: const <Sidedef>[],
  things: <Thing>[
    const Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
    Thing(x: 200, y: 64, angle: 180, type: monsterEdNum, flags: _skills),
    if (invisible)
      const Thing(x: 32, y: 64, angle: 0, type: 2024, flags: _skills),
  ],
);

MobjView _advanceToFrame(GameState game, String sprite, int frame) {
  for (var tic = 0; tic < 300; tic++) {
    game.runTic(TicCmd.empty);
    final MobjView actor = game.mobjs.firstWhere(
      (MobjView candidate) => candidate.sprite == sprite,
    );
    if (actor.frame == frame) return actor;
  }
  fail('$sprite never reached attack frame $frame');
}

({MobjView source, MobjView missile}) _advanceToImpMissile(GameState game) {
  for (var tic = 0; tic < 300; tic++) {
    game.runTic(TicCmd.empty);
    final List<MobjView> missiles = game.mobjs
        .where((MobjView candidate) => candidate.sprite == 'BAL1')
        .toList();
    if (missiles.isNotEmpty) {
      return (
        source: game.mobjs.firstWhere(
          (MobjView candidate) => candidate.sprite == 'TROO',
        ),
        missile: missiles.first,
      );
    }
  }
  fail('imp never spawned a missile');
}

void main() {
  test('power pickups expose deterministic 35 Hz timers and durable flags', () {
    final GameState game = GameState.start(
      _pickupMap(<int>[2022, 2023, 2024, 2025, 2026, 2045]),
      const GameConfig(monsters: false),
    );
    game.runTic(TicCmd.empty);

    expect(game.player.powers.invulnerabilityTics, 30 * kTicRate);
    expect(game.player.powers.invisibilityTics, 60 * kTicRate);
    expect(game.player.powers.radiationSuitTics, 60 * kTicRate);
    expect(game.player.powers.lightAmplificationTics, 120 * kTicRate);
    expect(game.player.powers.computerMap, isTrue);
    expect(game.player.powers.berserk, isTrue);
    expect(
      game.mobjs.singleWhere((MobjView m) => m.sprite == 'PLAY').flags &
          MobjFlags.shadow,
      isNot(0),
    );

    for (var tic = 0; tic < 60 * kTicRate; tic++) {
      game.runTic(TicCmd.empty);
    }
    expect(game.player.powers.invulnerabilityTics, 0);
    expect(game.player.powers.invisibilityTics, 0);
    expect(game.player.powers.radiationSuitTics, 0);
    expect(game.player.powers.lightAmplificationTics, 60 * kTicRate);
    expect(
      game.mobjs.singleWhere((MobjView m) => m.sprite == 'PLAY').flags &
          MobjFlags.shadow,
      0,
    );
  });

  test('radiation suit blocks sector damage until its timer expires', () {
    final GameState game = GameState.start(
      _pickupMap(<int>[2025], sectorSpecial: SectorSpecial.damage10),
      const GameConfig(monsters: false),
    );
    game.runTic(TicCmd.empty);
    for (var tic = 0; tic < 60 * kTicRate - 1; tic++) {
      game.runTic(TicCmd.empty);
    }
    expect(game.player.health, 100);
    while (game.player.health == 100) {
      game.runTic(TicCmd.empty);
    }
    expect(game.player.health, 90);
  });

  test('invulnerability prevents ordinary damage until its timer expires', () {
    final GameState game = GameState.start(
      _pickupMap(<int>[2022], sectorSpecial: SectorSpecial.damage10),
      const GameConfig(monsters: false),
    );
    game.runTic(TicCmd.empty);
    for (var tic = 0; tic < 30 * kTicRate - 1; tic++) {
      game.runTic(TicCmd.empty);
    }
    expect(game.player.health, 100);
    while (game.player.health == 100) {
      game.runTic(TicCmd.empty);
    }
    expect(game.player.health, 90);
  });

  test('sector 11 waits out invulnerability then exits without killing', () {
    final GameState game = GameState.start(
      _pickupMap(<int>[2022], sectorSpecial: SectorSpecial.damage20),
      const GameConfig(monsters: false),
    );
    game.runTic(TicCmd.empty);
    expect(game.player.powers.invulnerabilityTics, 30 * kTicRate);
    game.runTic(TicCmd.empty);
    expect(game.player.powers.invulnerabilityTics, 30 * kTicRate - 1);
    while (game.player.powers.invulnerabilityTics > 0) {
      game.runTic(TicCmd.empty);
    }
    expect(game.player.health, 100);
    while (!game.levelComplete) {
      game.runTic(TicCmd.empty);
    }
    expect(game.player.health, 1);
    expect(game.levelExit, isNotNull);
  });

  test('invisibility deterministically perturbs monster hitscan aim', () {
    final GameState visible = GameState.start(
      _monsterAimMap(3004, invisible: false),
      const GameConfig(),
      seed: 3,
    );
    final GameState shadowA = GameState.start(
      _monsterAimMap(3004, invisible: true),
      const GameConfig(),
      seed: 3,
    );
    final GameState shadowB = GameState.start(
      _monsterAimMap(3004, invisible: true),
      const GameConfig(),
      seed: 3,
    );

    final MobjView visibleShooter = _advanceToFrame(visible, 'POSS', 5);
    final MobjView shadowShooterA = _advanceToFrame(shadowA, 'POSS', 5);
    final MobjView shadowShooterB = _advanceToFrame(shadowB, 'POSS', 5);
    final int visibleDirect = Trig.atan2(
      visible.player.y - visibleShooter.y,
      visible.player.x - visibleShooter.x,
    );
    final int shadowDirect = Trig.atan2(
      shadowA.player.y - shadowShooterA.y,
      shadowA.player.x - shadowShooterA.x,
    );

    expect(visibleShooter.angle, visibleDirect);
    expect(shadowShooterA.angle, isNot(shadowDirect));
    // Seed 3 gives a visible hit but a deterministic shadow miss. The
    // contract is the repeatable perturbation, not that every shadow shot
    // must miss.
    expect(shadowShooterA.angle, 0x81e00000);
    expect(shadowShooterA.angle, shadowShooterB.angle);
    expect(shadowA.hashState(), shadowB.hashState());
    expect(visible.player.health, lessThan(100));
    expect(shadowA.player.health, 100);
  });

  test('invisibility deterministically spoils monster missile aim', () {
    final GameState visible = GameState.start(
      _monsterAimMap(3001, invisible: false),
      const GameConfig(),
      seed: 7,
    );
    final GameState shadowA = GameState.start(
      _monsterAimMap(3001, invisible: true),
      const GameConfig(),
      seed: 7,
    );
    final GameState shadowB = GameState.start(
      _monsterAimMap(3001, invisible: true),
      const GameConfig(),
      seed: 7,
    );

    final visibleShot = _advanceToImpMissile(visible);
    final shadowShotA = _advanceToImpMissile(shadowA);
    final shadowShotB = _advanceToImpMissile(shadowB);
    final int visibleDirect = Trig.atan2(
      visible.player.y - visibleShot.source.y,
      visible.player.x - visibleShot.source.x,
    );
    final int shadowDirect = Trig.atan2(
      shadowA.player.y - shadowShotA.source.y,
      shadowA.player.x - shadowShotA.source.x,
    );

    expect(visibleShot.source.angle, visibleDirect);
    expect(visibleShot.missile.angle, visibleDirect);
    expect(shadowShotA.source.angle, isNot(shadowDirect));
    expect(shadowShotA.missile.angle, isNot(shadowDirect));
    expect(shadowShotA.source.angle, 0x96000000);
    expect(shadowShotA.missile.angle, 0x83c00000);
    expect(shadowShotA.source.angle, shadowShotB.source.angle);
    expect(shadowShotA.missile.angle, shadowShotB.missile.angle);
    expect(shadowA.hashState(), shadowB.hashState());
  });
}
