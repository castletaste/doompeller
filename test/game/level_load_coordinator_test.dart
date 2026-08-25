import 'dart:async';

import 'package:doompeller/game/level_load_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LevelLoadCoordinator', () {
    test('publishes only a complete current generation', () async {
      final coordinator = LevelLoadCoordinator<String, int>();

      final outcome = await coordinator.load(
        prepare: (_) async => '123',
        assemble: int.parse,
      );

      expect(outcome, isA<LevelPublished<int>>());
      expect(coordinator.activeLevel, 123);
    });

    test('a newer load fences an older result', () async {
      final coordinator = LevelLoadCoordinator<String, int>();
      final firstGate = Completer<String>();
      var staleAssembled = false;
      var staleDiscarded = false;

      final first = coordinator.load(
        prepare: (_) => firstGate.future,
        assemble: (_) {
          staleAssembled = true;
          return 1;
        },
        discardPrepared: (_) => staleDiscarded = true,
      );
      final second = coordinator.load(
        prepare: (_) async => '2',
        assemble: int.parse,
      );
      expect(await second, isA<LevelPublished<int>>());

      firstGate.complete('1');
      expect(await first, isA<LevelLoadStale<int>>());
      expect(staleAssembled, isFalse);
      expect(staleDiscarded, isTrue);
      expect(coordinator.activeLevel, 2);
    });

    test('cancel makes checkpoints and eventual publication stale', () async {
      final coordinator = LevelLoadCoordinator<String, int>();
      final gate = Completer<void>();
      late LevelLoadToken captured;

      final pending = coordinator.load(
        prepare: (token) async {
          captured = token;
          await gate.future;
          token.throwIfCancelled();
          return '9';
        },
        assemble: int.parse,
      );

      coordinator.cancel();
      gate.complete();

      expect(captured.isCancelled, isTrue);
      expect(await pending, isA<LevelLoadStale<int>>());
      expect(coordinator.activeLevel, isNull);
    });

    test('failure never replaces the active level', () async {
      final coordinator = LevelLoadCoordinator<String, int>();
      await coordinator.load(prepare: (_) async => '7', assemble: int.parse);

      final outcome = await coordinator.load(
        prepare: (_) async => throw const FormatException('bad map'),
        assemble: int.parse,
      );

      expect(outcome, isA<LevelLoadFailed<int>>());
      expect(coordinator.activeLevel, 7);
    });

    test('re-entrant cancellation during assembly cannot publish', () async {
      final coordinator = LevelLoadCoordinator<String, int>();

      final outcome = await coordinator.load(
        prepare: (_) async => '5',
        assemble: (prepared) {
          coordinator.cancel();
          return int.parse(prepared);
        },
      );

      expect(outcome, isA<LevelLoadStale<int>>());
      expect(coordinator.activeLevel, isNull);
    });

    test('replacement callback sees only previously published level', () async {
      final coordinator = LevelLoadCoordinator<String, int>();
      final replaced = <int>[];
      await coordinator.load(prepare: (_) async => '1', assemble: int.parse);

      await coordinator.load(
        prepare: (_) async => '2',
        assemble: int.parse,
        onReplaced: replaced.add,
      );

      expect(replaced, <int>[1]);
      expect(coordinator.activeLevel, 2);
      expect(coordinator.detachActive(), 2);
      expect(coordinator.activeLevel, isNull);
    });
  });
}
