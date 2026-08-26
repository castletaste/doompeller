import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

void main() {
  test('35 Hz collision workload stays inside one tic on the scale fixture', () {
    const ScaleFixtureConfig smallConfig = ScaleFixtureConfig(
      columns: 6,
      rows: 5,
    );
    // Keep JIT warm-up out of the small-versus-scale comparison.
    _sample(smallConfig);
    final _SimulationSample small = _sample(smallConfig);
    final _SimulationSample scale = _sample(ScaleFixtureConfig.e1m1Scale);

    const int ticBudgetMicros = 1000000 ~/ kTicRate;
    expect(scale.averageMicros, lessThan(ticBudgetMicros));
    // candidateLines deliberately unions all canonical linedefs for fail-closed
    // correctness. This is therefore expected to be linear, not constant, but
    // a 4x larger line set must not show a quadratic rise in tick cost.
    expect(
      scale.averageMicros,
      lessThanOrEqualTo(small.averageMicros * 8 + 100),
      reason:
          '${small.lines} lines: ${small.averageMicros} us/tic; '
          '${scale.lines} lines: ${scale.averageMicros} us/tic',
    );
    expect(scale.finalX, lessThan(scale.startX + 256 * 65536));
  });
}

class _SimulationSample {
  const _SimulationSample({
    required this.lines,
    required this.averageMicros,
    required this.startX,
    required this.finalX,
  });

  final int lines;
  final int averageMicros;
  final int startX;
  final int finalX;
}

_SimulationSample _sample(ScaleFixtureConfig config) {
  final WadSet set = DoomScaleFixture.wadSet(config);
  final MapData map = MapData.load(set, DoomScaleFixture.mapName);
  final GameState game = GameState.start(
    map,
    const GameConfig(monsters: false),
    seed: 7,
  );
  const TicCmd collideEast = TicCmd(forwardMove: 50);
  final int startX = game.player.x;
  for (var tic = 0; tic < 35; tic++) {
    game.runTic(collideEast);
  }
  const int timedTics = 350;
  final Stopwatch watch = Stopwatch()..start();
  for (var tic = 0; tic < timedTics; tic++) {
    game.runTic(collideEast);
  }
  watch.stop();
  return _SimulationSample(
    lines: map.linedefs.length,
    averageMicros: watch.elapsedMicroseconds ~/ timedTics,
    startX: startX,
    finalX: game.player.x,
  );
}
