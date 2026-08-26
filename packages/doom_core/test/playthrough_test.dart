import 'dart:math' as math;

import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

void main() {
  test('full synthetic level is completable and deterministic within budget', () {
    final MapData map = DoomPlaythroughFixture.map();
    final CommandReplay replay = DoomPlaythroughReplay.replay();
    final GameState first = GameState.start(
      map,
      const GameConfig(),
      seed: replay.seed,
    );
    final int initialActors = first.mobjs.length;
    final List<int> hashes = <int>[];
    for (var index = 0; index < replay.commands.length; index++) {
      first.runTic(replay.commands[index]);
      hashes.add(first.hashState());
    }

    print(
      'playthrough result: tics=${first.tic} hash=0x${hashes.last.toRadixString(16)} '
      'position=(${fixedToDouble(first.player.x).toStringAsFixed(1)}, '
      '${fixedToDouble(first.player.y).toStringAsFixed(1)}) '
      'sector=${first.playerSectorIndex} health=${first.player.health} '
      'kills=${first.killCount}/${first.totalKills} '
      'items=${first.itemCount}/${first.totalItems} '
      'secrets=${first.secretsFound}/${first.totalSecrets} '
      'keys=${first.player.keys}',
    );

    expect(first.levelComplete, isTrue);
    expect(first.killCount, first.totalKills);
    expect(first.totalKills, 2);
    expect(first.itemCount, first.totalItems);
    expect(first.totalItems, 1);
    expect(first.secretsFound, first.totalSecrets);
    expect(first.totalSecrets, 1);
    expect(first.player.keys, contains(Key.blue));
    expect(first.mobjs.length, lessThanOrEqualTo(initialActors));
    expect(hashes.last, 0xe0202f8e);

    final GameState second = GameState.start(
      map,
      const GameConfig(),
      seed: replay.seed,
    );
    expect(replay.run(second), hashes);

    final GameState timed = GameState.start(
      map,
      const GameConfig(),
      seed: replay.seed,
    );
    final List<int> micros = <int>[];
    for (final TicCmd command in replay.commands) {
      final Stopwatch stopwatch = Stopwatch()..start();
      timed.runTic(command);
      stopwatch.stop();
      micros.add(stopwatch.elapsedMicroseconds);
    }
    micros.sort();
    final int p95 =
        micros[math.min(micros.length - 1, (micros.length * 0.95).ceil() - 1)];
    print('playthrough tic budget: p95=${p95}us budget=28571us');
    expect(p95, lessThan(Duration.microsecondsPerSecond ~/ kTicRate));
  });
}
