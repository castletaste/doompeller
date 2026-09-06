import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// A timing regression on unchanged original content, not an E1M9 playthrough.
const Map<String, int> _walkCadence = <String, int>{
  'POSS': 4,
  'SPOS': 3,
  'TROO': 3,
  'SARG': 2,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('original E1M9 monsters do not chase between walk actions', () async {
    final ByteData asset = await rootBundle.load('.local/doom/DOOM1.WAD');
    final WadFile wad = WadFile.parse(
      asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
    );
    final MapData map = MapData.load(WadSet(<WadFile>[wad]), 'E1M9');
    final GameState game = GameState.start(map, const GameConfig(), seed: 0);
    final Map<int, int> lastMovement = <int, int>{};
    var comparedSteps = 0;
    var previous = <int, MobjView>{
      for (final MobjView actor in game.mobjs) actor.id: actor,
    };

    // Leave the sheltered spawn before waiting; an idle spawn-only probe can
    // see no pursuit and must not be allowed to pass vacuously.
    for (var tic = 0; tic < 110; tic++) {
      game.runTic(tic < 40 ? const TicCmd(forwardMove: 50) : TicCmd.empty);
      final current = <int, MobjView>{
        for (final MobjView actor in game.mobjs) actor.id: actor,
      };
      for (final MobjView actor in current.values) {
        final int? cadence = _walkCadence[actor.sprite];
        final MobjView? before = previous[actor.id];
        if (cadence == null ||
            before == null ||
            actor.health <= 0 ||
            (actor.x == before.x && actor.y == before.y)) {
          continue;
        }
        final int? priorStep = lastMovement[actor.id];
        if (priorStep != null) {
          comparedSteps++;
          expect(
            game.tic - priorStep,
            greaterThanOrEqualTo(cadence),
            reason:
                '${actor.sprite} #${actor.id} moved on tics '
                '$priorStep and ${game.tic}; walk action interval is $cadence',
          );
        }
        lastMovement[actor.id] = game.tic;
      }
      previous = current;
    }
    expect(comparedSteps, greaterThan(4), reason: 'must observe real pursuit');
  });
}
