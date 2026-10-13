import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('replay corpus keeps final hashes stable across repeated runs', () {
    for (final _ReplayCorpusCase replay in _corpus) {
      final MapData map = replay.usePlaythroughMap
          ? DoomPlaythroughFixture.map()
          : MapData.load(DoomFixtures.wadSet(), 'MAP01');
      final _ReplayRun first = _run(map, replay);
      final _ReplayRun second = _run(map, replay);

      expect(first.hashes, second.hashes, reason: replay.name);
      expect(first.finalHash, replay.expectedFinalHash, reason: replay.name);
      expect(first.finalHash, second.finalHash, reason: replay.name);
      debugPrint(
        'replay-corpus ${replay.name}: tics=${first.hashes.length} '
        'hash=0x${first.finalHash.toRadixString(16)}',
      );
    }
  });
}

final List<_ReplayCorpusCase> _corpus = <_ReplayCorpusCase>[
  _ReplayCorpusCase(
    name: 'synthetic-turn-and-fire',
    seed: 7,
    commands: List<TicCmd>.generate(
      20,
      (int i) => TicCmd(
        forwardMove: i.isEven ? 10 : 0,
        angleTurn: 0x200,
        buttons: i % 5 == 0 ? Buttons.attack : 0,
      ),
    ),
    expectedFinalHash: 0x0c13da39,
  ),
  _ReplayCorpusCase(
    name: 'synthetic-playthrough',
    seed: DoomPlaythroughReplay.seed,
    commands: DoomPlaythroughReplay.commands,
    expectedFinalHash: 0x4c4136d3,
    usePlaythroughMap: true,
  ),
];

_ReplayRun _run(MapData map, _ReplayCorpusCase replay) {
  final GameState game = GameState.start(
    map,
    const GameConfig(),
    seed: replay.seed,
  );
  final List<int> hashes = CommandReplay(
    seed: replay.seed,
    commands: replay.commands,
  ).run(game);
  return _ReplayRun(hashes: hashes, finalHash: game.hashState());
}

final class _ReplayCorpusCase {
  const _ReplayCorpusCase({
    required this.name,
    required this.seed,
    required this.commands,
    required this.expectedFinalHash,
    this.usePlaythroughMap = false,
  });

  final String name;
  final int seed;
  final List<TicCmd> commands;
  final int expectedFinalHash;
  final bool usePlaythroughMap;
}

final class _ReplayRun {
  const _ReplayRun({required this.hashes, required this.finalHash});

  final List<int> hashes;
  final int finalHash;
}
