import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

import 'specials_test.dart' show testMap;

const int _skills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

MapData _hitscanMap({
  required int monsterType,
  int playerX = 32,
  int monsterX = 224,
}) => testMap(
  vertices: const <MapVertex>[],
  lines: const <Linedef>[],
  sides: const <Sidedef>[],
  things: <Thing>[
    Thing(x: playerX, y: 64, angle: 0, type: 1, flags: _skills),
    Thing(x: monsterX, y: 64, angle: 180, type: monsterType, flags: _skills),
  ],
);

({int healthBefore, int healthAfter, List<MobjView> impacts})
_firstHitscanAction(GameState game, String sprite) {
  var previousFrame = game.mobjs
      .singleWhere((MobjView actor) => actor.sprite == sprite)
      .frame;
  for (var tic = 0; tic < 300; tic++) {
    final healthBefore = game.player.health;
    game.runTic(TicCmd.empty);
    final actor = game.mobjs.singleWhere(
      (MobjView candidate) => candidate.sprite == sprite,
    );
    if (actor.frame == 5 && previousFrame != 5) {
      return (
        healthBefore: healthBefore,
        healthAfter: game.player.health,
        impacts: game.mobjs
            .where(
              (MobjView candidate) =>
                  candidate.sprite == 'BLUD' || candidate.sprite == 'PUFF',
            )
            .toList(growable: false),
      );
    }
    previousFrame = actor.frame;
  }
  fail('$sprite never entered its hitscan action frame');
}

void main() {
  test('former human spread has deterministic seeded misses', () {
    final game = GameState.start(
      _hitscanMap(monsterType: 3004),
      const GameConfig(),
      seed: 0,
    );
    final shot = _firstHitscanAction(game, 'POSS');

    expect(shot.healthAfter, shot.healthBefore);
    expect(shot.impacts, isEmpty);
  });

  test('shotgun guy pellets follow independently spread rays', () {
    final game = GameState.start(
      _hitscanMap(monsterType: 9, monsterX: 112),
      const GameConfig(),
      seed: 0,
    );
    final shot = _firstHitscanAction(game, 'SPOS');
    final coordinates = <(int, int)>{
      for (final impact in shot.impacts) (impact.x, impact.y),
    };

    expect(shot.impacts, hasLength(3));
    expect(coordinates, hasLength(3));
  });

  test('shotgun guy consumes spread and damage RNG for missed pellets', () {
    final game = GameState.start(
      _hitscanMap(monsterType: 9),
      const GameConfig(),
      seed: 1,
    );
    final shot = _firstHitscanAction(game, 'SPOS');

    expect(shot.healthAfter, shot.healthBefore);
    expect(shot.impacts, isEmpty);
    expect(
      game.hashState(),
      0x6651337f,
      reason:
          'all three misses still consume six spread and three damage draws',
    );
  });

  test('hitscan damage runs once when the action frame is entered', () {
    final game = GameState.start(
      _hitscanMap(monsterType: 9, monsterX: 112),
      const GameConfig(),
      seed: 2,
    );
    final shot = _firstHitscanAction(game, 'SPOS');
    final healthAfterEntry = shot.healthAfter;
    expect(healthAfterEntry, lessThan(shot.healthBefore));

    var remainingActionFrameTics = 0;
    while (game.mobjs.singleWhere((actor) => actor.sprite == 'SPOS').frame ==
        5) {
      game.runTic(TicCmd.empty);
      remainingActionFrameTics++;
      if (game.mobjs.singleWhere((actor) => actor.sprite == 'SPOS').frame ==
          5) {
        expect(
          game.player.health,
          healthAfterEntry,
          reason: 'remaining tics in one action frame must not refire',
        );
      }
    }
    expect(remainingActionFrameTics, 10);
  });
}
