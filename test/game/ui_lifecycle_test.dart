import 'dart:async';
import 'dart:typed_data';

import 'package:doompeller/game/browser_wad_selection.dart';
import 'package:doom_core/doom_core.dart' as core;
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_app_controller.dart';
import 'package:doompeller/game/doom_automap.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:doompeller/ui/doom_app.dart';
import 'package:doompeller/ui/doom_game_view.dart';
import 'package:doompeller/adapter/doom_runtime_game.dart';
import '../adapter/fake_gpu_backend.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../widget_test.dart' as fixture;

void main() {
  test(
    'replay completion may dispose the runtime before frame publication',
    () async {
      FakeGpuBackend();
      final level = await fixture.fixtureLevel();
      late final DoomRuntimeGame runtime;
      runtime = DoomRuntimeGame(
        level,
        replayInput: DoomReplayInput(
          commands: const [core.TicCmd.empty],
          expectedFinalHash: 0,
          onFinished: (_) => runtime.dispose(),
        ),
      );
      runtime.update(1 / 60);
      runtime.update(0.1);
      expect(runtime.replayResult?.status, DoomReplayStatus.earlyEnd);
      expect(runtime.gameState.tic, 1);
      runtime.update(1);
      expect(runtime.gameState.tic, 1);
      await runtime.soundPlaybackIdleForTest;
    },
  );

  testWidgets('runtime factory ownership ends when its surface unmounts', (
    tester,
  ) async {
    FakeGpuBackend();
    final level = await fixture.fixtureLevel();
    final runtime = DoomRuntimeGame(level);
    final app = DoomAppController(
      initialState: DoomAppState.ready(level, phase: DoomAppPhase.fixtureReady),
    );
    await tester.pumpWidget(
      DoomApp(
        controller: app,
        autoStart: false,
        runtimeFactory: (_) => runtime,
        gameSurfaceBuilder: (_, _) => const SizedBox.expand(),
      ),
    );
    expect(runtime.advanceMicrosForTest(30000), 1);
    final tic = runtime.gameState.tic;
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
    runtime.onRemove();
    runtime.update(1);
    runtime.restartLevel();
    expect(runtime.advanceMicrosForTest(30000), 0);
    expect(runtime.gameState.tic, tic);
    await runtime.soundPlaybackIdleForTest;
    app.dispose();
  });

  testWidgets('HUD, automap and controls keep the game surface mounted', (
    tester,
  ) async {
    final level = await fixture.fixtureLevel();
    final runtime = fixture.FakeRuntime();
    final app = DoomAppController(
      initialState: DoomAppState.ready(level, phase: DoomAppPhase.fixtureReady),
    );
    var builds = 0;
    await tester.pumpWidget(
      DoomApp(
        controller: app,
        autoStart: false,
        runtimeFactory: (_) => runtime,
        gameSurfaceBuilder: (_, _) {
          builds++;
          return const SizedBox.expand();
        },
      ),
    );
    runtime.togglePause();
    await tester.pump();
    runtime.automapNotifier.value = const DoomAutomapSnapshot(
      isOpen: true,
      zoom: 1,
      playerX: 1,
      playerY: 0,
      playerAngle: 0,
      visitedLines: {},
    );
    await tester.pump();
    expect(builds, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    runtime.notifier.dispose();
    runtime.automapNotifier.dispose();
  });

  testWidgets('controller replacement detaches the injected predecessor', (
    tester,
  ) async {
    final first = DoomAppController(
      initialState: const DoomAppState.failure('FIRST'),
    );
    final second = DoomAppController(
      initialState: const DoomAppState.failure('SECOND'),
    );
    await tester.pumpWidget(DoomApp(controller: first, autoStart: false));
    await tester.pumpWidget(DoomApp(controller: second, autoStart: false));
    expect(find.text('SECOND'), findsOneWidget);
    expect(find.text('FIRST'), findsNothing);
    first.reportSelectedIwadFailure('STALE');
    await tester.pump();
    expect(find.text('SECOND'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    first.dispose();
    second.dispose();
  });

  testWidgets(
    'switching to a default controller leaves the injected one alive',
    (tester) async {
      final injected = DoomAppController();
      await tester.pumpWidget(DoomApp(controller: injected, autoStart: false));
      await tester.pumpWidget(const DoomApp(autoStart: false));
      expect(
        () => ChangeNotifier.debugAssertNotDisposed(injected),
        returnsNormally,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      injected.dispose();
    },
  );

  testWidgets('switching to injection disposes the app-owned controller', (
    tester,
  ) async {
    await tester.pumpWidget(const DoomApp(autoStart: false));
    final owned =
        tester
                .widget<ListenableBuilder>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is ListenableBuilder &&
                        widget.listenable is DoomAppController,
                  ),
                )
                .listenable
            as DoomAppController;
    final injected = DoomAppController();
    await tester.pumpWidget(DoomApp(controller: injected, autoStart: false));
    expect(
      () => ChangeNotifier.debugAssertNotDisposed(owned),
      throwsFlutterError,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    injected.dispose();
  });

  testWidgets('new callback closures update the surface without restarting', (
    tester,
  ) async {
    FakeGpuBackend();
    final level = await fixture.fixtureLevel();
    final app = DoomAppController(
      initialState: DoomAppState.ready(level, phase: DoomAppPhase.fixtureReady),
    );
    final runtimes = <DoomRuntimeGame>[];
    DoomApp buildApp(int build) => DoomApp(
      controller: app,
      autoStart: false,
      runtimeFactory: (level) {
        expect(build, greaterThanOrEqualTo(0));
        final runtime = DoomRuntimeGame(level);
        runtimes.add(runtime);
        return runtime;
      },
      gameSurfaceBuilder: (_, _) => Text('Surface $build'),
    );
    await tester.pumpWidget(buildApp(0));
    final runtime = runtimes.single;
    expect(runtime.advanceMicrosForTest(30000), 1);
    final tic = runtime.gameState.tic;
    await tester.pumpWidget(buildApp(1));
    expect(runtimes, hasLength(1));
    expect(runtime.gameState.tic, tic);
    expect(find.text('Surface 1'), findsOneWidget);
    expect(runtime.advanceMicrosForTest(30000), 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await runtime.soundPlaybackIdleForTest;
    app.dispose();
  });

  testWidgets('a directly embedded game view replaces its level and runtime', (
    tester,
  ) async {
    FakeGpuBackend();
    final first = await fixture.fixtureLevel();
    final second = PreparedDoomLevel(
      content: first.content,
      resources: first.resources,
      map: first.map,
      geometry: first.geometry,
      gameConfig: first.gameConfig,
      seed: first.seed + 1,
    );
    final runtimes = <DoomRuntimeGame>[];
    final inputs = <PreparedDoomLevel>[];
    Widget view(PreparedDoomLevel level) => MaterialApp(
      home: DoomGameView(
        level: level,
        synthetic: true,
        setupMessage: null,
        selectionErrorMessage: null,
        onLoadIwad: null,
        onContinue: (_) async {},
        runtimeFactory: (input) {
          inputs.add(input);
          final runtime = DoomRuntimeGame(input);
          runtimes.add(runtime);
          return runtime;
        },
        gameSurfaceBuilder: (_, _) => const SizedBox.expand(),
      ),
    );
    await tester.pumpWidget(view(first));
    await tester.pumpWidget(view(second));
    expect(inputs, [same(first), same(second)]);
    expect(runtimes.first.advanceMicrosForTest(30000), 0);
    expect(runtimes.last.advanceMicrosForTest(30000), 1);
    await tester.pumpWidget(const SizedBox.shrink());
    for (final runtime in runtimes) {
      await runtime.soundPlaybackIdleForTest;
    }
  });

  test('disposed controller never invokes content loaders', () async {
    var reads = 0;
    final app = DoomAppController(
      loadDeveloper: () async {
        reads++;
        return const DoomContentLoadFailure('fixture');
      },
      loadFixture: () {
        reads++;
        throw StateError('must not load');
      },
      loadSelected: (_, {mapName = 'E1M1', sourcePath}) {
        reads++;
        return const DoomContentLoadFailure('fixture');
      },
    );
    app.dispose();
    await app.start();
    await app.useFixtureFallback();
    await app.useSelectedIwad(Uint8List(0));
    expect(reads, 0);
  });

  test(
    'picker result cannot replace a newer request or detached owner',
    () async {
      var reads = 0;
      var ownerActive = true;
      final app = DoomAppController(
        loadSelected: (_, {mapName = 'E1M1', sourcePath}) {
          reads++;
          return const DoomContentLoadFailure('fixture');
        },
      );
      final pending = Completer<BrowserWadSelection?>();
      final pick = app.pickIwad(
        () => pending.future,
        isOwnerActive: () => ownerActive,
      );
      app.reportSelectedIwadFailure('NEWER');
      pending.complete(BrowserWadSelection(name: 'old', bytes: Uint8List(0)));
      await pick;
      expect(reads, 0);
      expect(app.state.errorMessage, 'NEWER');
      final detached = Completer<BrowserWadSelection?>();
      final next = app.pickIwad(
        () => detached.future,
        isOwnerActive: () => ownerActive,
      );
      ownerActive = false;
      detached.complete(BrowserWadSelection(name: 'old', bytes: Uint8List(0)));
      await next;
      expect(reads, 0);
      app.dispose();
    },
  );

  test(
    'cancelling a picker lets the existing load reach a terminal state',
    () async {
      final level = await fixture.fixtureLevel();
      final preparation = Completer<PreparedDoomLevel>();
      final started = Completer<void>();
      final app = DoomAppController(
        loadDeveloper: () async => DoomContentLoaded(level.content),
        prepare: (_, _) {
          started.complete();
          return preparation.future;
        },
      );
      final load = app.start();
      await started.future;
      await app.pickIwad(() async => null, isOwnerActive: () => true);
      preparation.complete(level);
      await load;
      expect(app.state.level, same(level));
      app.dispose();
    },
  );

  test(
    'displaced work on a shared preparer reports a retryable failure',
    () async {
      final level = await fixture.fixtureLevel();
      final active = Completer<PreparedDoomLevel>();
      var calls = 0;
      final preparer = DoomLevelPreparer(
        worker: (_) => calls++ == 0 ? active.future : Future.value(level),
      );
      DoomAppController controller() => DoomAppController(
        preparer: preparer,
        loadFixture: () => level.content,
      );
      final first = controller();
      final displaced = controller();
      final latest = controller();
      final firstLoad = first.useFixtureFallback();
      final displacedLoad = displaced.useFixtureFallback();
      final latestLoad = latest.useFixtureFallback();
      await displacedLoad;
      expect(displaced.state, isA<DoomAppFailure>());
      active.complete(level);
      await Future.wait([firstLoad, latestLoad]);
      expect(first.state.level, same(level));
      expect(latest.state.level, same(level));
      first.dispose();
      displaced.dispose();
      latest.dispose();
    },
  );
}
