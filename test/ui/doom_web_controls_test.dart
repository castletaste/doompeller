import 'package:doom_core/doom_core.dart' show Buttons, TicCmd;
import 'package:doompeller/adapter/adapter.dart';
import 'package:doompeller/game/browser_input.dart';
import 'package:doompeller/game/doom_app_controller.dart';
import 'package:doompeller/ui/doom_app.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../adapter/fake_gpu_backend.dart';
import '../support/fake_browser_pointer.dart';
import '../widget_test.dart' show fixtureLevel, testSurface;

void main() {
  Future<DoomRuntimeGame> mount(
    WidgetTester tester,
    FakeBrowserPointer driver,
  ) async {
    FakeGpuBackend();
    final level = await fixtureLevel();
    final runtime = DoomRuntimeGame(level);
    final controller = DoomAppController(
      initialState: DoomAppState.ready(level, phase: DoomAppPhase.fixtureReady),
    );
    final input = DoomBrowserInput(driver: driver);
    addTearDown(controller.dispose);
    addTearDown(input.dispose);
    await tester.pumpWidget(
      DoomApp(
        controller: controller,
        autoStart: false,
        browserInput: input,
        runtimeFactory: (_) => runtime,
        gameSurfaceBuilder: testSurface,
      ),
    );
    await tester.pump();
    return runtime;
  }

  testWidgets(
    'capture click does not fire; relative look uses session sensitivity',
    (tester) async {
      final driver = FakeBrowserPointer();
      final runtime = await mount(tester, driver);
      await tester.tap(
        find.byKey(const Key('game-input-surface')),
        kind: PointerDeviceKind.mouse,
      );
      expect(driver.requests, hasLength(1));
      expect(runtime.input.consume().command.attacking, isFalse);
      driver.reportLock(true);
      driver.onTurn?.call(10);
      final first = runtime.input.consume().command;
      expect(first.angleTurn, -240);
      expect(first.attacking, isFalse);
      driver.onAttack?.call(true);
      expect(runtime.input.consume().command.attacking, isTrue);
      driver.reportLock(false);
      await tester.pump();
      expect(runtime.isPaused, isTrue);
      expect(runtime.input.consume().command.attacking, isFalse);
      runtime.onKeyEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.escape,
          logicalKey: LogicalKeyboardKey.escape,
          timeStamp: Duration.zero,
        ),
        {},
      );
      expect(runtime.isPaused, isTrue);
      final slider = find.byKey(const Key('mouse-sensitivity'));
      tester.widget<Slider>(slider).onChanged!(2);
      await tester.pump();
      await tester.tap(find.byKey(const Key('overlay-action')));
      driver.reportLock(true);
      driver.onTurn?.call(10);
      expect(runtime.input.consume().command.angleTurn, -480);
      driver.reportLock(false);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('wheel and trackpad select owned weapons above the status bar', (
    tester,
  ) async {
    final runtime = await mount(tester, FakeBrowserPointer());
    final position = tester.getCenter(find.byKey(const Key('status-bar')));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: position, scrollDelta: const Offset(0, 48)),
    );
    var cmd = runtime.input.consume().command;
    expect(cmd.buttons & Buttons.changeWeapon, isNot(0));
    expect((cmd.buttons >> Buttons.weaponShift) & 7, 0);
    final trackpad = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await trackpad.panZoomStart(position);
    await trackpad.panZoomUpdate(position, pan: const Offset(0, -20));
    expect(runtime.input.consume().command.buttons & Buttons.changeWeapon, 0);
    await trackpad.panZoomUpdate(position, pan: const Offset(0, -50));
    cmd = runtime.input.consume().command;
    expect((cmd.buttons >> Buttons.weaponShift) & 7, 1);
    await trackpad.panZoomEnd();
    runtime.setPaused(true);
    await tester.pump();
    await tester.sendEventToBinding(
      PointerScrollEvent(position: position, scrollDelta: const Offset(0, 120)),
    );
    expect(runtime.input.consume().command, TicCmd.empty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'coarse pointer starts with touch and explicit override wins later touch',
    (tester) async {
      final driver = FakeBrowserPointer()
        ..touchPrimary = true
        ..mouseGesture = false;
      final runtime = await mount(tester, driver);
      expect(find.byKey(const Key('touch-controls')), findsOneWidget);
      await tester.tap(find.byKey(const Key('touch-pause')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pause-touch-controls')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('overlay-action')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('game-input-surface')));
      await tester.pump();
      expect(find.byKey(const Key('touch-controls')), findsNothing);
      expect(driver.requests, isEmpty);
      expect(runtime.isPaused, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'hints hide on actual movement and return after six idle seconds',
    (tester) async {
      final runtime = await mount(tester, FakeBrowserPointer());
      expect(find.byKey(const Key('controls-hint')), findsOneWidget);
      runtime.addPointerYaw(10);
      runtime.advanceMicrosForTest(30000);
      await tester.pump();
      expect(find.byKey(const Key('controls-hint')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(const Key('controls-hint')), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('controls-hint')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
