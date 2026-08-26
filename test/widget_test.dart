import 'package:doom_core/doom_core.dart' as core;
import 'package:doom_geometry/doom_geometry.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_app_controller.dart';
import 'package:doompeller/game/doom_automap.dart';
import 'package:doompeller/game/doom_hud.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:doompeller/ui/doom_app.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<PreparedDoomLevel> fixtureLevel() async {
  final content = DoomContentSource(
    environment: const <String, String>{},
  ).loadFixture();
  final resources = WadResources.load(content.wads);
  final map = MapData.load(content.wads, content.mapName);
  return PreparedDoomLevel(
    content: content,
    resources: resources,
    map: map,
    geometry: DoomGeometryCompiler.compile(map, resources),
    gameConfig: const core.GameConfig(),
    seed: 0,
  );
}

final class FakeRuntime implements DoomRuntimeView {
  final ValueNotifier<DoomHudSnapshot> notifier =
      ValueNotifier<DoomHudSnapshot>(const DoomHudSnapshot.initial());

  @override
  ValueListenable<DoomHudSnapshot> get hud => notifier;

  final ValueNotifier<DoomAutomapSnapshot> automapNotifier = ValueNotifier(
    const DoomAutomapSnapshot(
      isOpen: false,
      zoom: DoomAutomapState.initialZoom,
      playerX: 0,
      playerY: 0,
      playerAngle: 0,
      visitedLines: <int>{},
    ),
  );

  @override
  ValueListenable<DoomAutomapSnapshot> get automap => automapNotifier;

  int clearInputCalls = 0;
  int restartCalls = 0;

  @override
  void addPointerYaw(double deltaX) {}

  @override
  void clearInput() => clearInputCalls++;

  @override
  void restartLevel() {
    restartCalls++;
    notifier.value = const DoomHudSnapshot.initial();
  }

  @override
  void setPointerAttack(bool pressed) {}

  @override
  void togglePause() {
    final old = notifier.value;
    notifier.value = DoomHudSnapshot(
      health: old.health,
      armor: old.armor,
      bullets: old.bullets,
      shells: old.shells,
      weapon: old.weapon,
      keys: old.keys,
      kills: old.kills,
      totalKills: old.totalKills,
      items: old.items,
      totalItems: old.totalItems,
      secrets: old.secrets,
      totalSecrets: old.totalSecrets,
      levelTime: old.levelTime,
      paused: !old.paused,
      levelComplete: old.levelComplete,
      diagnostics: old.diagnostics,
    );
  }

  @override
  void toggleAutomap() {}

  @override
  void zoomAutomap({required bool inwards}) {}
}

Widget testSurface(BuildContext context, DoomRuntimeView runtime) =>
    const ColoredBox(key: Key('fake-game-surface'), color: Colors.black);

void main() {
  testWidgets('loading and configured error states are explicit', (
    tester,
  ) async {
    final loading = DoomAppController();
    addTearDown(loading.dispose);
    await tester.pumpWidget(
      DoomApp(
        key: const Key('loading-app'),
        controller: loading,
        autoStart: false,
      ),
    );
    expect(find.byKey(const Key('loading-view')), findsOneWidget);

    final failed = DoomAppController(
      initialState: const DoomAppState.failure('bad configured IWAD'),
    );
    addTearDown(failed.dispose);
    await tester.pumpWidget(
      DoomApp(
        key: const Key('failed-app'),
        controller: failed,
        autoStart: false,
      ),
    );
    expect(find.text('IWAD LOAD FAILED'), findsOneWidget);
    expect(find.byKey(const Key('fixture-fallback')), findsOneWidget);
  });

  testWidgets('fallback button explicitly loads the fixture', (tester) async {
    final source = DoomContentSource(environment: const <String, String>{});
    final controller = DoomAppController(
      initialState: const DoomAppState.failure('bad configured IWAD'),
      loadFixture: source.loadFixture,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      DoomApp(
        controller: controller,
        autoStart: false,
        runtimeFactory: (_) => FakeRuntime(),
        gameSurfaceBuilder: testSurface,
      ),
    );

    await tester.tap(find.byKey(const Key('fixture-fallback')));
    await tester.pumpAndSettle();

    expect(find.text('SYNTHETIC TEST MAP'), findsOneWidget);
    expect(find.byKey(const Key('status-bar')), findsOneWidget);
  });

  for (final size in <Size>[const Size(360, 640), const Size(1000, 700)]) {
    testWidgets('fixture HUD adapts without overflow at ${size.width}', (
      tester,
    ) async {
      final level = await fixtureLevel();
      final controller = DoomAppController(
        initialState: DoomAppState.ready(
          level,
          phase: DoomAppPhase.fixtureReady,
          setupMessage: 'Set DOOM_WAD_PATH to your legally obtained DOOM.WAD.',
        ),
      );
      addTearDown(controller.dispose);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        DoomApp(
          controller: controller,
          autoStart: false,
          runtimeFactory: (_) => FakeRuntime(),
          gameSurfaceBuilder: testSurface,
        ),
      );

      expect(find.text('SYNTHETIC TEST MAP'), findsOneWidget);
      expect(find.byKey(const Key('status-bar')), findsOneWidget);
      expect(find.text('HEALTH'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('controls can hide and pause overlay resumes', (tester) async {
    final level = await fixtureLevel();
    final runtime = FakeRuntime();
    final controller = DoomAppController(
      initialState: DoomAppState.ready(level, phase: DoomAppPhase.fixtureReady),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      DoomApp(
        controller: controller,
        autoStart: false,
        runtimeFactory: (_) => runtime,
        gameSurfaceBuilder: testSurface,
      ),
    );

    await tester.tap(find.byKey(const Key('hide-controls')));
    await tester.pump();
    expect(find.byKey(const Key('controls-hint')), findsNothing);
    expect(find.byKey(const Key('show-controls')), findsOneWidget);

    await tester.tap(find.byKey(const Key('game-pause-button')));
    await tester.pump();
    expect(find.byKey(const Key('pause-overlay')), findsOneWidget);
    await tester.tap(find.byKey(const Key('overlay-action')));
    await tester.pump();
    expect(find.byKey(const Key('pause-overlay')), findsNothing);
  });

  testWidgets('death overlay is exclusive to a dead player and restarts', (
    tester,
  ) async {
    final level = await fixtureLevel();
    final runtime = FakeRuntime();
    final controller = DoomAppController(
      initialState: DoomAppState.ready(level, phase: DoomAppPhase.fixtureReady),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      DoomApp(
        controller: controller,
        autoStart: false,
        runtimeFactory: (_) => runtime,
        gameSurfaceBuilder: testSurface,
      ),
    );

    expect(find.byKey(const Key('death-overlay')), findsNothing);
    runtime.notifier.value = const DoomHudSnapshot(
      health: 0,
      armor: 0,
      bullets: 12,
      shells: 0,
      weapon: core.Weapon.pistol,
      keys: <core.Key>{},
      kills: 0,
      totalKills: 1,
      items: 0,
      totalItems: 0,
      secrets: 0,
      totalSecrets: 0,
      levelTime: 70,
      paused: false,
      levelComplete: false,
      diagnostics: DoomFrameDiagnosticsSnapshot(),
    );
    await tester.pump();

    expect(find.byKey(const Key('death-overlay')), findsOneWidget);
    expect(find.text('YOU DIED'), findsOneWidget);
    await tester.tap(find.byKey(const Key('overlay-action')));
    await tester.pump();
    expect(runtime.restartCalls, 1);
    expect(find.byKey(const Key('death-overlay')), findsNothing);
  });

  testWidgets('intermission shows final percentages and time after skip', (
    tester,
  ) async {
    final level = await fixtureLevel();
    final runtime = FakeRuntime();
    runtime.notifier.value = const DoomHudSnapshot(
      health: 87,
      armor: 25,
      bullets: 30,
      shells: 8,
      weapon: core.Weapon.shotgun,
      keys: <core.Key>{},
      kills: 3,
      totalKills: 4,
      items: 2,
      totalItems: 5,
      secrets: 1,
      totalSecrets: 2,
      levelTime: 105 * core.kTicRate,
      paused: false,
      levelComplete: true,
      diagnostics: DoomFrameDiagnosticsSnapshot(),
    );
    final controller = DoomAppController(
      initialState: DoomAppState.ready(level, phase: DoomAppPhase.fixtureReady),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      DoomApp(
        controller: controller,
        autoStart: false,
        runtimeFactory: (_) => runtime,
        gameSurfaceBuilder: testSurface,
      ),
    );

    expect(find.byKey(const Key('completion-overlay')), findsOneWidget);
    await tester.tap(find.byKey(const Key('intermission-skip')));
    await tester.pump();
    expect(find.text('75%'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('1:45'), findsOneWidget);
    await tester.tap(find.byKey(const Key('intermission-restart')));
    await tester.pump();
    expect(runtime.restartCalls, 1);
    expect(find.byKey(const Key('completion-overlay')), findsNothing);
  });

  testWidgets('intermission treats empty totals as 100 percent', (
    tester,
  ) async {
    final level = await fixtureLevel();
    final runtime = FakeRuntime();
    runtime.notifier.value = const DoomHudSnapshot(
      health: 100,
      armor: 0,
      bullets: 50,
      shells: 0,
      weapon: core.Weapon.pistol,
      keys: <core.Key>{},
      kills: 0,
      totalKills: 0,
      items: 0,
      totalItems: 0,
      secrets: 0,
      totalSecrets: 0,
      levelTime: 0,
      paused: false,
      levelComplete: true,
      diagnostics: DoomFrameDiagnosticsSnapshot(),
    );
    final controller = DoomAppController(
      initialState: DoomAppState.ready(level, phase: DoomAppPhase.fixtureReady),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      DoomApp(
        controller: controller,
        autoStart: false,
        runtimeFactory: (_) => runtime,
        gameSurfaceBuilder: testSurface,
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    for (final String row in <String>['kills', 'items', 'secrets']) {
      expect(tester.widget<Text>(find.byKey(Key('tally-$row'))).data, '100%');
    }
    expect(find.text('0:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('focus loss clears runtime input', (tester) async {
    final level = await fixtureLevel();
    final runtime = FakeRuntime();
    final controller = DoomAppController(
      initialState: DoomAppState.ready(level, phase: DoomAppPhase.fixtureReady),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      DoomApp(
        controller: controller,
        autoStart: false,
        runtimeFactory: (_) => runtime,
        gameSurfaceBuilder: testSurface,
      ),
    );
    final focus = tester.widget<Focus>(
      find.byKey(const Key('doom-game-focus')),
    );
    focus.focusNode!.requestFocus();
    await tester.pump();
    final before = runtime.clearInputCalls;

    focus.focusNode!.unfocus();
    await tester.pump();

    expect(runtime.clearInputCalls, before + 1);

    final beforeLifecycle = runtime.clearInputCalls;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(runtime.clearInputCalls, beforeLifecycle + 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets('custom runtime without surface shows explicit error', (
    tester,
  ) async {
    final level = await fixtureLevel();
    final controller = DoomAppController(
      initialState: DoomAppState.ready(level, phase: DoomAppPhase.fixtureReady),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      DoomApp(
        controller: controller,
        autoStart: false,
        runtimeFactory: (_) => FakeRuntime(),
      ),
    );

    expect(
      find.byKey(const Key('runtime-configuration-error')),
      findsOneWidget,
    );
    expect(
      find.text(
        'A custom Doom runtime requires a custom game surface builder.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
