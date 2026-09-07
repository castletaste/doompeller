import 'package:doom_core/doom_core.dart' as core;
import 'package:doom_geometry/doom_geometry.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:doompeller/adapter/adapter.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_app_controller.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:doompeller/ui/doom_app.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../adapter/fake_gpu_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PreparedDoomLevel level;

  setUpAll(() async {
    final asset = await rootBundle.load('.local/doom/DOOM1.WAD');
    final bytes = asset.buffer.asUint8List(
      asset.offsetInBytes,
      asset.lengthInBytes,
    );
    expect(bytes.length, 4196020);
    final wads = WadSet(<WadFile>[WadFile.parse(bytes)]);
    final resources = WadResources.load(wads);
    final map = MapData.load(wads, 'E1M1');
    level = PreparedDoomLevel(
      content: DoomContent(
        wads: wads,
        mapName: 'E1M1',
        origin: DoomContentOrigin.developerIwad,
      ),
      resources: resources,
      map: map,
      geometry: DoomGeometryCompiler.compile(map, resources),
      gameConfig: const core.GameConfig(),
      seed: 0,
    );
  });

  Future<DoomRuntimeGame> mount(WidgetTester tester) async {
    FakeGpuBackend();
    final runtime = DoomRuntimeGame(level);
    final controller = DoomAppController(
      initialState: DoomAppState.ready(
        level,
        phase: DoomAppPhase.developerIwadReady,
      ),
    );
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(390, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      DoomApp(
        controller: controller,
        autoStart: false,
        runtimeFactory: (_) => runtime,
        gameSurfaceBuilder: (_, _) => const ColoredBox(color: Colors.black),
      ),
    );
    await tester.pump();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      runtime.onRemove();
    });
    return runtime;
  }

  Future<void> enableTouch(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      const Offset(195, 250),
      pointer: 10,
      kind: PointerDeviceKind.touch,
    );
    await gesture.up();
    await tester.pump();
  }

  testWidgets('original E1M1 first touch enables controls without firing', (
    tester,
  ) async {
    final runtime = await mount(tester);
    expect(find.text('DEVELOPER IWAD · E1M1'), findsOneWidget);
    expect(find.byKey(const Key('touch-controls')), findsNothing);
    expect(find.text('SELECT LOCAL IWAD'), findsNothing);
    await enableTouch(tester);
    expect(find.byKey(const Key('touch-controls')), findsOneWidget);
    expect(runtime.input.consume().command, core.TicCmd.empty);
    expect(runtime.gameState.player.ammo.bullets, 50);
    expect(tester.takeException(), isNull);
  });

  testWidgets('original E1M1 stick cancel does not release held touch fire', (
    tester,
  ) async {
    final runtime = await mount(tester);
    await enableTouch(tester);
    final stick = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('touch-stick'))),
      pointer: 21,
      kind: PointerDeviceKind.touch,
    );
    await stick.moveBy(const Offset(0, -40));
    final fire = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('touch-fire'))),
      pointer: 22,
      kind: PointerDeviceKind.touch,
    );
    final moving = runtime.input.consume().command;
    expect(moving.forwardMove, greaterThan(0));
    expect(moving.attacking, isTrue);
    await stick.cancel();
    final stopped = runtime.input.consume().command;
    expect(stopped.forwardMove, 0);
    expect(stopped.attacking, isTrue);
    await fire.up();
    expect(runtime.input.consume().command, core.TicCmd.empty);
  });

  testWidgets('original E1M1 mouse fires after touch mode is enabled', (
    tester,
  ) async {
    final runtime = await mount(tester);
    await enableTouch(tester);
    final point = tester.getCenter(find.byKey(const Key('touch-look')));
    final mouse = await tester.startGesture(
      point,
      pointer: 41,
      kind: PointerDeviceKind.mouse,
    );
    expect(runtime.input.consume().command.attacking, isTrue);
    await mouse.up();
    expect(runtime.input.consume().command, core.TicCmd.empty);
    final finger = await tester.startGesture(
      point,
      pointer: 42,
      kind: PointerDeviceKind.touch,
    );
    await finger.moveBy(const Offset(20, 0));
    final lookOnly = runtime.input.consume().command;
    expect(lookOnly.attacking, isFalse);
    expect(lookOnly.angleTurn, lessThan(0));
    await finger.up();
    expect(runtime.input.consume().command, core.TicCmd.empty);
  });

  for (final reset in <String>['pause', 'focus', 'lifecycle']) {
    testWidgets('original E1M1 $reset clears input and stale finger capture', (
      tester,
    ) async {
      final runtime = await mount(tester);
      await enableTouch(tester);
      final stick = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('touch-stick'))),
        pointer: 31,
        kind: PointerDeviceKind.touch,
      );
      await stick.moveBy(const Offset(0, -40));
      expect(runtime.input.consume().command.forwardMove, greaterThan(0));
      switch (reset) {
        case 'pause':
          runtime.togglePause();
          runtime.advanceMicrosForTest(0);
        case 'focus':
          FocusManager.instance.primaryFocus?.unfocus();
        case 'lifecycle':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
      }
      await tester.pump();
      expect(runtime.input.consume().command, core.TicCmd.empty);
      if (reset == 'focus') {
        final focus = tester.widget<Focus>(
          find.byKey(const Key('doom-game-focus')),
        );
        expect(focus.focusNode!.hasFocus, isFalse);
      }
      if (reset == 'pause') {
        expect(find.byKey(const Key('pause-overlay')), findsOneWidget);
        expect(find.byKey(const Key('pause-touch-controls')), findsOneWidget);
        runtime.togglePause();
        runtime.advanceMicrosForTest(0);
      } else if (reset == 'lifecycle') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      await tester.pump();
      await stick.moveBy(const Offset(12, -12));
      expect(runtime.input.consume().command, core.TicCmd.empty);
      await stick.up();
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in <Size>[const Size(390, 780), const Size(844, 390)]) {
    testWidgets('original E1M1 touch layout stays above HUD at $size', (
      tester,
    ) async {
      final runtime = await mount(tester);
      await tester.binding.setSurfaceSize(size);
      tester.view.padding = const FakeViewPadding(
        top: 24,
        bottom: 24,
        left: 24,
        right: 24,
      );
      addTearDown(tester.view.resetPadding);
      await tester.pump();
      await enableTouch(tester);
      final hud = tester.getRect(find.byKey(const Key('status-bar')));
      for (final key in <String>[
        'touch-stick',
        'touch-fire',
        'touch-use',
        'touch-run',
        'touch-weapons',
        'touch-map',
        'touch-pause',
      ]) {
        final rect = tester.getRect(find.byKey(Key(key)));
        expect(rect.left, greaterThanOrEqualTo(0), reason: key);
        expect(rect.right, lessThanOrEqualTo(size.width), reason: key);
        expect(rect.top, greaterThanOrEqualTo(44), reason: key);
        expect(rect.bottom, lessThanOrEqualTo(hud.top), reason: key);
        expect(rect.width, greaterThanOrEqualTo(44), reason: key);
        expect(rect.height, greaterThanOrEqualTo(44), reason: key);
      }
      await tester.tap(find.byKey(const Key('touch-pause')));
      runtime.advanceMicrosForTest(0);
      await tester.pump();
      expect(find.byKey(const Key('pause-touch-controls')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pause-touch-controls')));
      await tester.pump();
      expect(find.byKey(const Key('touch-controls')), findsNothing);
      await tester.tap(find.byKey(const Key('overlay-action')));
      runtime.advanceMicrosForTest(0);
      await tester.pump();
      // Explicitly turning it off must survive later touch on the scene.
      await enableTouch(tester);
      expect(find.byKey(const Key('touch-controls')), findsNothing);
      expect(runtime.input.consume().command, core.TicCmd.empty);
      expect(tester.takeException(), isNull);
    });
  }
}
