import 'dart:async';

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

  test(
    '1000 replacements admit only active and latest pending CPU jobs',
    () async {
      final content = DoomContentSource(environment: const {}).loadFixture();
      final fixture = await _prepareFixture(content);
      final gates = [Completer<void>(), Completer<void>()];
      var calls = 0;
      var active = 0;
      var peak = 0;
      final preparer = DoomLevelPreparer(
        worker: (_) async {
          final index = calls++;
          active++;
          if (active > peak) peak = active;
          await gates[index].future;
          active--;
          return fixture;
        },
      );
      final coordinator = LevelLoadCoordinator<PreparedDoomLevel, String>();
      final outcomes = [
        for (var i = 0; i < 1000; i++)
          coordinator.load(
            prepare: (token) => preparer.prepare(content, token),
            assemble: (_) => '$i',
          ),
      ];
      expect(calls, 1);
      gates.first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      gates.last.complete();
      final results = await Future.wait(outcomes);
      expect(peak, 1);
      expect(results.whereType<LevelLoadStale<String>>(), hasLength(999));
      expect((results.last as LevelPublished<String>).level, '999');
    },
  );

  test(
    'cancelled pending work never starts and worker failure releases admission',
    () async {
      final content = DoomContentSource(environment: const {}).loadFixture();
      final fixture = await _prepareFixture(content);
      final gate = Completer<void>();
      var calls = 0;
      final preparer = DoomLevelPreparer(
        worker: (_) async {
          if (calls++ == 0) {
            await gate.future;
            throw StateError('worker failed');
          }
          return fixture;
        },
      );
      final coordinator = LevelLoadCoordinator<PreparedDoomLevel, String>();
      Future<LevelLoadOutcome<String>> load() => coordinator.load(
        prepare: (token) => preparer.prepare(content, token),
        assemble: (level) => level.map.name,
      );
      final first = load();
      final pending = load();
      coordinator.cancel();
      gate.complete();
      expect(await first, isA<LevelLoadStale<String>>());
      expect(await pending, isA<LevelLoadStale<String>>());
      expect(calls, 1);
      expect(await load(), isA<LevelPublished<String>>());
      expect(calls, 2);
    },
  );
}

Future<PreparedDoomLevel> _prepareFixture(DoomContent content) async {
  final result =
      await LevelLoadCoordinator<PreparedDoomLevel, PreparedDoomLevel>().load(
        prepare: (token) => DoomLevelPreparer().prepare(content, token),
        assemble: (level) => level,
      );
  return (result as LevelPublished<PreparedDoomLevel>).level;
}
