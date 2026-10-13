import 'dart:async';

import 'package:doompeller/game/level_load_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LevelLoadCoordinator', () {
    test('publishes only a complete current generation', () async {
      final coordinator = LevelLoadCoordinator<int>();

      final outcome = await coordinator.load(prepare: (_) async => 123);

      expect(outcome, isA<LevelPublished<int>>());
    });

    test('a newer load fences an older result', () async {
      final coordinator = LevelLoadCoordinator<String>();
      final firstGate = Completer<String>();
      var staleDiscarded = false;

      final first = coordinator.load(
        prepare: (_) => firstGate.future,
        discardPrepared: (_) => staleDiscarded = true,
      );
      final second = coordinator.load(prepare: (_) async => '2');
      expect(await second, isA<LevelPublished<String>>());

      firstGate.complete('1');
      expect(await first, isA<LevelLoadStale<String>>());
      expect(staleDiscarded, isTrue);
    });

    test('cancel makes checkpoints and eventual publication stale', () async {
      final coordinator = LevelLoadCoordinator<String>();
      final gate = Completer<void>();
      late LevelLoadToken captured;

      final pending = coordinator.load(
        prepare: (token) async {
          captured = token;
          await gate.future;
          token.throwIfCancelled();
          return '9';
        },
      );

      coordinator.cancel();
      gate.complete();

      expect(captured.isCancelled, isTrue);
      expect(await pending, isA<LevelLoadStale<String>>());
    });

    test('failure is reported for the current generation', () async {
      final coordinator = LevelLoadCoordinator<String>();
      final outcome = await coordinator.load(
        prepare: (_) async => throw const FormatException('bad map'),
      );

      expect(outcome, isA<LevelLoadFailed<String>>());
    });

    test('replacement publishes the newest prepared value', () async {
      final coordinator = LevelLoadCoordinator<String>();
      final first = await coordinator.load(prepare: (_) async => '1');
      final second = await coordinator.load(prepare: (_) async => '2');

      expect((first as LevelPublished<String>).level, '1');
      expect((second as LevelPublished<String>).level, '2');
    });

    test(
      'controlled completion order keeps only the newest generation',
      () async {
        for (final List<int> completionOrder in <List<int>>[
          <int>[2, 1, 0],
          <int>[0, 1, 2],
        ]) {
          final coordinator = LevelLoadCoordinator<int>();
          final gates = <Completer<int>>[
            Completer<int>(),
            Completer<int>(),
            Completer<int>(),
          ];
          var discarded = 0;
          final futures = <Future<LevelLoadOutcome<int>>>[
            for (var i = 0; i < gates.length; i++)
              coordinator.load(
                prepare: (_) => gates[i].future,
                discardPrepared: (_) => discarded++,
              ),
          ];

          for (final int index in completionOrder) {
            gates[index].complete(index);
          }

          final outcomes = await Future.wait(futures);
          expect(outcomes.whereType<LevelPublished<int>>(), hasLength(1));
          expect(outcomes.whereType<LevelLoadStale<int>>(), hasLength(2));
          expect(discarded, 2);
        }
      },
    );
  });
}
