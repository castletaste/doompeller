import 'dart:async';

import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_app_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('absent environment automatically prepares the safe fixture', () async {
    final controller = DoomAppController(
      contentSource: DoomContentSource(environment: const <String, String>{}),
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.state.phase, DoomAppPhase.fixtureReady);
    expect(controller.state.level?.map.name, 'MAP01');
    expect(controller.state.setupMessage, contains('DOOM_WAD_PATH'));
  });

  test('configured invalid path is an error with no silent fallback', () async {
    var fixtureLoads = 0;
    final source = DoomContentSource(environment: const <String, String>{});
    final controller = DoomAppController(
      loadDeveloper: () async =>
          const DoomContentLoadFailure('Configured IWAD is invalid.'),
      loadFixture: () {
        fixtureLoads++;
        return source.loadFixture();
      },
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.state.phase, DoomAppPhase.failure);
    expect(controller.state.errorMessage, contains('invalid'));
    expect(fixtureLoads, 0);
  });

  test('explicit fallback recovers a configured path failure', () async {
    final source = DoomContentSource(environment: const <String, String>{});
    final controller = DoomAppController(
      loadDeveloper: () async =>
          const DoomContentLoadFailure('Configured IWAD is invalid.'),
      loadFixture: source.loadFixture,
    );
    addTearDown(controller.dispose);

    await controller.start();
    await controller.useFixtureFallback();

    expect(controller.state.phase, DoomAppPhase.fixtureReady);
    expect(controller.state.setupMessage, contains('was not loaded'));
  });

  test('late result from an older request is rejected', () async {
    final first = Completer<DoomContentLoadResult>();
    final second = Completer<DoomContentLoadResult>();
    var call = 0;
    final source = DoomContentSource(environment: const <String, String>{});
    final controller = DoomAppController(
      loadDeveloper: () => call++ == 0 ? first.future : second.future,
      loadFixture: source.loadFixture,
    );
    addTearDown(controller.dispose);

    final older = controller.start();
    final newer = controller.start();
    second.complete(const DoomContentPathMissing());
    await newer;
    expect(controller.state.phase, DoomAppPhase.fixtureReady);

    first.complete(const DoomContentLoadFailure('obsolete failure'));
    await older;
    expect(controller.state.phase, DoomAppPhase.fixtureReady);
    expect(controller.state.errorMessage, isNull);
  });

  test('unexpected developer loader exception becomes failure state', () async {
    final controller = DoomAppController(
      loadDeveloper: () => Future<DoomContentLoadResult>.error(
        StateError('private implementation detail'),
      ),
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.state.phase, DoomAppPhase.failure);
    expect(
      controller.state.errorMessage,
      'Unexpected error while loading the configured developer IWAD.',
    );
  });

  test('unexpected fixture loader exception becomes failure state', () async {
    final controller = DoomAppController(
      loadDeveloper: () async => const DoomContentPathMissing(),
      loadFixture: () => throw StateError('fixture exploded'),
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.state.phase, DoomAppPhase.failure);
    expect(
      controller.state.errorMessage,
      'Could not create the synthetic test map.',
    );
  });

  test('explicit fallback catches a throwing fixture loader', () async {
    final controller = DoomAppController(
      initialState: const DoomAppState.failure('configured IWAD failed'),
      loadFixture: () => throw StateError('fixture exploded'),
    );
    addTearDown(controller.dispose);

    await controller.useFixtureFallback();

    expect(controller.state.phase, DoomAppPhase.failure);
    expect(
      controller.state.errorMessage,
      'Could not create the synthetic test map.',
    );
  });
}
