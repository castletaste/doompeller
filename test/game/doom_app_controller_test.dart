import 'dart:async';
import 'dart:typed_data';

import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_app_controller.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'absent bundled default fails instead of silently using fixture',
    () async {
      final controller = DoomAppController(
        contentSource: DoomContentSource(environment: const <String, String>{}),
      );
      addTearDown(controller.dispose);

      await controller.start();

      expect(controller.state.phase, DoomAppPhase.failure);
      expect(controller.state.level, isNull);
      expect(controller.state.errorMessage, contains('bundled DOOM1.WAD'));
    },
  );

  test('missing default content is an explicit startup failure', () async {
    final controller = DoomAppController(
      loadDeveloper: () async => const DoomContentPathMissing(
        autoLoadFixture: false,
        setupMessage: 'Bundled IWAD is unavailable.',
      ),
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.state.phase, DoomAppPhase.failure);
    expect(controller.state.level, isNull);
    expect(controller.state.errorMessage, 'Bundled IWAD is unavailable.');
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

  test('explicit in-memory IWAD replaces the running fixture', () async {
    final source = DoomContentSource(environment: const <String, String>{});
    final controller = DoomAppController(
      loadDeveloper: () async => const DoomContentPathMissing(),
      loadFixture: source.loadFixture,
      loadSelected: source.loadIwadBytes,
    );
    addTearDown(controller.dispose);
    await controller.start();
    expect(controller.state.phase, DoomAppPhase.fixtureReady);

    final Uint8List bytes = DoomFixtures.pwadBytes()
      ..setRange(0, 4, 'IWAD'.codeUnits);
    await controller.useSelectedIwad(bytes, mapName: DoomFixtures.mapName);

    expect(controller.state.phase, DoomAppPhase.developerIwadReady);
    expect(controller.state.level?.map.name, DoomFixtures.mapName);
    expect(controller.state.level?.content.sourcePath, isNull);
  });

  test('invalid selected IWAD retains the running level', () async {
    final source = DoomContentSource(environment: const <String, String>{});
    final controller = DoomAppController(
      loadDeveloper: () async => const DoomContentPathMissing(),
      loadFixture: source.loadFixture,
      loadSelected: source.loadIwadBytes,
    );
    addTearDown(controller.dispose);
    await controller.start();
    final activeLevel = controller.state.level;

    await controller.useSelectedIwad(Uint8List(12));

    expect(controller.state.phase, DoomAppPhase.fixtureReady);
    expect(controller.state.level, same(activeLevel));
    expect(controller.state.errorMessage, isNotEmpty);
  });

  test('selected IWAD prepare failure retains the running level', () async {
    final source = DoomContentSource(environment: const <String, String>{});
    final content = source.loadFixture();
    final preparer = DoomLevelPreparer();
    var prepareCalls = 0;
    final controller = DoomAppController(
      loadDeveloper: () async => DoomContentLoaded(content),
      loadSelected: (bytes, {mapName = 'E1M1', sourcePath}) =>
          DoomContentLoaded(content),
      prepare: (selected, token) {
        if (prepareCalls++ == 0) return preparer.prepare(selected, token);
        return Future<PreparedDoomLevel>.error(StateError('prepare failed'));
      },
    );
    addTearDown(controller.dispose);
    await controller.start();
    final activeLevel = controller.state.level;

    await controller.useSelectedIwad(Uint8List(0));

    expect(controller.state.phase, DoomAppPhase.fixtureReady);
    expect(controller.state.level, same(activeLevel));
    expect(controller.state.errorMessage, contains('prepare failed'));
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
