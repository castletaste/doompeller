import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/level_load_coordinator.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('synthetic PWAD reaches geometry and deterministic runtime', () async {
    final content = DoomContentSource(
      environment: const <String, String>{},
    ).loadFixture();
    final coordinator = LevelLoadCoordinator<PreparedDoomLevel, String>();
    late PreparedDoomLevel prepared;

    final outcome = await coordinator.load(
      prepare: (token) async {
        prepared = await DoomLevelPreparer(seed: 7).prepare(content, token);
        return prepared;
      },
      assemble: (level) => level.map.name,
    );

    expect(outcome, isA<LevelPublished<String>>());
    expect(prepared.map.name, 'MAP01');
    expect(prepared.geometry.report.fallbackSectors, isEmpty);
    expect(prepared.geometry.report.geometryHash, 0x50a4e123);
    expect(prepared.geometry.meshes, isNotEmpty);
    final first = prepared.createGame();
    final second = prepared.createGame();
    expect(first.player.health, 100);
    expect(second, isNot(same(first)));
    expect(
      prepared.initialSpritePrefixes,
      containsAll(<String>{'PLAY', 'POSS', 'TROO', 'SPOS'}),
    );
  });

  test('cancelled generation cannot publish a prepared level', () async {
    final content = DoomContentSource(
      environment: const <String, String>{},
    ).loadFixture();
    final coordinator = LevelLoadCoordinator<PreparedDoomLevel, String>();
    var assembled = false;

    final pending = coordinator.load(
      prepare: (token) async {
        await Future<void>.delayed(Duration.zero);
        return DoomLevelPreparer().prepare(content, token);
      },
      assemble: (level) {
        assembled = true;
        return level.map.name;
      },
    );
    coordinator.cancel();

    expect(await pending, isA<LevelLoadStale<String>>());
    expect(assembled, isFalse);
  });
}
