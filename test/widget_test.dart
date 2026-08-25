import 'package:doom_core/doom_core.dart' as core;
import 'package:doom_geometry/doom_geometry.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_app_controller.dart';
import 'package:doompeller/game/doom_hud.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:doompeller/ui/doom_app.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
    game: core.GameState.start(map, const core.GameConfig()),
  );
}

final class FakeRuntime implements DoomRuntimeView {
  final ValueNotifier<DoomHudSnapshot> notifier =
      ValueNotifier<DoomHudSnapshot>(const DoomHudSnapshot.initial());

  @override
  ValueListenable<DoomHudSnapshot> get hud => notifier;

  int clearInputCalls = 0;

  @override
  void addPointerYaw(double deltaX) {}

  @override
  void clearInput() => clearInputCalls++;

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
      secrets: old.secrets,
      paused: !old.paused,
      levelComplete: old.levelComplete,
      diagnostics: old.diagnostics,
    );
  }
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
