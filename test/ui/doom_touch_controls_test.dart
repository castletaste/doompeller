import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:doompeller/game/doom_input.dart';
import 'package:doompeller/ui/doom_touch_controls.dart';
import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Callbacks {
  final List<(int, int, int)> moves = <(int, int, int)>[];
  final List<double> looks = <double>[];
  final List<(int, DoomControl)> controls = <(int, DoomControl)>[];
  final List<(int, bool)> ups = <(int, bool)>[];
  final List<int> weapons = <int>[];
  final List<bool> zooms = <bool>[];
  int uses = 0;
  int maps = 0;
  int pauses = 0;
}

Widget _controls(
  _Callbacks callbacks, {
  bool enabled = true,
  int resetGeneration = 0,
  bool mapOpen = false,
}) => MaterialApp(
  home: ColoredBox(
    color: Colors.black,
    child: DoomTouchControls(
      enabled: enabled,
      resetGeneration: resetGeneration,
      mapOpen: mapOpen,
      onMove: (pointer, forward, side) =>
          callbacks.moves.add((pointer, forward, side)),
      onLook: callbacks.looks.add,
      onControlDown: (pointer, control) =>
          callbacks.controls.add((pointer, control)),
      onPointerUp: (pointer, cancelled) =>
          callbacks.ups.add((pointer, cancelled)),
      onUse: () => callbacks.uses++,
      onSelectWeapon: callbacks.weapons.add,
      onToggleMap: () => callbacks.maps++,
      onZoomMap: callbacks.zooms.add,
      onPause: () => callbacks.pauses++,
    ),
  ),
);

Future<void> _setSize(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  testWidgets('move, look, and fire keep independent touch ownership', (
    tester,
  ) async {
    await _setSize(tester, const Size(800, 300));
    final callbacks = _Callbacks();
    await tester.pumpWidget(_controls(callbacks));

    final stick = tester.getRect(find.byKey(const Key('touch-stick')));
    final fire = tester.getRect(find.byKey(const Key('touch-fire')));
    final move = await tester.createGesture(
      pointer: 11,
      kind: PointerDeviceKind.touch,
    );
    final look = await tester.createGesture(
      pointer: 12,
      kind: PointerDeviceKind.touch,
    );
    final attack = await tester.createGesture(
      pointer: 13,
      kind: PointerDeviceKind.touch,
    );

    await move.down(stick.center);
    await move.moveTo(stick.center + const Offset(30, -34));
    await look.down(const Offset(430, 150));
    await look.moveBy(const Offset(18, 2));
    await attack.down(fire.center);
    await attack.moveBy(const Offset(-9, 0));

    expect(
      callbacks.moves.any(
        (value) => value.$1 == 11 && value.$2 > 0 && value.$3 > 0,
      ),
      isTrue,
    );
    expect(callbacks.looks, containsAllInOrder(<double>[18, -9]));
    expect(callbacks.controls, contains((13, DoomControl.attack)));

    await look.up();
    expect(callbacks.ups, contains((12, false)));
    expect(callbacks.ups, isNot(contains((11, false))));
    expect(callbacks.ups, isNot(contains((13, false))));

    await attack.up();
    await move.up();
    expect(callbacks.ups, containsAll(<(int, bool)>[(13, false), (11, false)]));
    expect(callbacks.moves.last, (11, 0, 0));
  });

  testWidgets('touch look stays look-only while primary mouse fires and yaws', (
    tester,
  ) async {
    await _setSize(tester, const Size(800, 300));
    final callbacks = _Callbacks();
    await tester.pumpWidget(_controls(callbacks));

    final touch = await tester.createGesture(
      pointer: 14,
      kind: PointerDeviceKind.touch,
    );
    await touch.down(const Offset(430, 150));
    await touch.moveBy(const Offset(12, 0));
    expect(callbacks.looks, <double>[12]);
    expect(callbacks.controls, isEmpty);
    await touch.up();

    final mouse = await tester.createGesture(
      pointer: 15,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await mouse.down(const Offset(430, 150));
    await mouse.moveBy(const Offset(-17, 0));
    expect(callbacks.controls, <(int, DoomControl)>[(15, DoomControl.attack)]);
    expect(callbacks.looks, <double>[12, -17]);
    await mouse.up();
    expect(callbacks.ups, containsAll(<(int, bool)>[(14, false), (15, false)]));
  });

  testWidgets('cancel and reset release only captured pointers as cancelled', (
    tester,
  ) async {
    await _setSize(tester, const Size(800, 300));
    final callbacks = _Callbacks();
    await tester.pumpWidget(_controls(callbacks));
    final stick = tester.getRect(find.byKey(const Key('touch-stick')));
    final run = tester.getRect(find.byKey(const Key('touch-run')));
    final move = await tester.createGesture(
      pointer: 21,
      kind: PointerDeviceKind.touch,
    );
    final runner = await tester.createGesture(
      pointer: 22,
      kind: PointerDeviceKind.touch,
    );

    await move.down(stick.center);
    await move.moveBy(const Offset(25, -25));
    await runner.down(run.center);
    await runner.cancel();
    expect(callbacks.ups, contains((22, true)));
    expect(callbacks.ups, isNot(contains((21, true))));

    await tester.pumpWidget(_controls(callbacks, resetGeneration: 1));
    expect(callbacks.ups, contains((21, true)));
    expect(callbacks.moves.last, (21, 0, 0));
    final moveCountAfterReset = callbacks.moves.length;
    final upCountAfterReset = callbacks.ups.length;

    await move.moveBy(const Offset(40, -10));
    await move.up();
    expect(callbacks.moves, hasLength(moveCountAfterReset));
    expect(callbacks.ups, hasLength(upCountAfterReset));
  });

  testWidgets('analog stick applies radial dead zone and bounded clamp', (
    tester,
  ) async {
    await _setSize(tester, const Size(360, 600));
    final callbacks = _Callbacks();
    await tester.pumpWidget(_controls(callbacks));
    final stick = tester.getRect(find.byKey(const Key('touch-stick')));
    final gesture = await tester.createGesture(
      pointer: 31,
      kind: PointerDeviceKind.touch,
    );

    await gesture.down(stick.center);
    await gesture.moveTo(stick.center + const Offset(4, -4));
    expect(callbacks.moves.last, (31, 0, 0));

    await gesture.moveTo(stick.center + const Offset(500, -500));
    final output = callbacks.moves.last;
    expect(output.$2, inInclusiveRange(-1000, 1000));
    expect(output.$3, inInclusiveRange(-1000, 1000));
    expect(
      math.sqrt(output.$2 * output.$2 + output.$3 * output.$3),
      closeTo(1000, 2),
    );
    await gesture.cancel();
  });

  testWidgets('use, weapon, map, zoom, and pause are one-shot controls', (
    tester,
  ) async {
    await _setSize(tester, const Size(360, 600));
    final callbacks = _Callbacks();
    await tester.pumpWidget(_controls(callbacks, mapOpen: true));

    await tester.tap(find.byKey(const Key('touch-use')));
    await tester.tap(find.byKey(const Key('touch-map')));
    await tester.tap(find.byKey(const Key('touch-map-zoom-in')));
    await tester.tap(find.byKey(const Key('touch-map-zoom-out')));
    await tester.tap(find.byKey(const Key('touch-pause')));
    await tester.tap(find.byKey(const Key('touch-weapons')));
    await tester.pump();

    expect(find.byKey(const Key('touch-weapon-0')), findsOneWidget);
    expect(find.byKey(const Key('touch-weapon-5')), findsOneWidget);
    await tester.tap(find.byKey(const Key('touch-weapon-4')));
    await tester.pump();

    expect(callbacks.uses, 1);
    expect(callbacks.maps, 1);
    expect(callbacks.zooms, <bool>[true, false]);
    expect(callbacks.pauses, 1);
    expect(callbacks.weapons, <int>[4]);
    expect(find.byKey(const Key('touch-weapon-4')), findsNothing);
  });

  testWidgets('controls stay bounded in portrait and short landscape regions', (
    tester,
  ) async {
    for (final size in <Size>[const Size(360, 600), const Size(800, 300)]) {
      await tester.binding.setSurfaceSize(size);
      final callbacks = _Callbacks();
      await tester.pumpWidget(_controls(callbacks, mapOpen: true));
      expect(tester.takeException(), isNull);
      final overlay = tester.getRect(find.byKey(const Key('touch-controls')));
      for (final key in <String>[
        'touch-stick',
        'touch-fire',
        'touch-use',
        'touch-run',
        'touch-weapons',
        'touch-map',
        'touch-map-zoom-in',
        'touch-map-zoom-out',
        'touch-pause',
      ]) {
        final rect = tester.getRect(find.byKey(Key(key)));
        expect(overlay.contains(rect.topLeft), isTrue, reason: '$key in $size');
        expect(
          overlay.contains(rect.bottomRight - const Offset(0.001, 0.001)),
          isTrue,
          reason: '$key in $size',
        );
      }
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('weapon picker wraps six 44px targets inside 272px', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final callbacks = _Callbacks();
    final sizes = <Size>[const Size(272, 600), const Size(272, 300)];
    for (var index = 0; index < sizes.length; index++) {
      final size = sizes[index];
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(_controls(callbacks, resetGeneration: index));
      await tester.tap(find.byKey(const Key('touch-weapons')));
      await tester.pump();

      final overlay = tester.getRect(find.byKey(const Key('touch-controls')));
      final rowTops = <double>{};
      for (var slot = 0; slot < 6; slot++) {
        final rect = tester.getRect(find.byKey(Key('touch-weapon-$slot')));
        expect(rect.width, greaterThanOrEqualTo(44));
        expect(rect.height, greaterThanOrEqualTo(44));
        expect(overlay.contains(rect.topLeft), isTrue);
        expect(
          overlay.contains(rect.bottomRight - const Offset(0.001, 0.001)),
          isTrue,
        );
        rowTops.add(rect.top);
      }
      expect(rowTops.length, greaterThan(1), reason: 'picker wraps at $size');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('disable clears held input and ignores later pointer movement', (
    tester,
  ) async {
    await _setSize(tester, const Size(800, 300));
    final callbacks = _Callbacks();
    await tester.pumpWidget(_controls(callbacks));
    final fire = tester.getRect(find.byKey(const Key('touch-fire')));
    final gesture = await tester.createGesture(
      pointer: 41,
      kind: PointerDeviceKind.touch,
    );
    await gesture.down(fire.center);

    await tester.pumpWidget(_controls(callbacks, enabled: false));
    expect(callbacks.ups, contains((41, true)));
    final looksAfterDisable = callbacks.looks.length;
    await gesture.moveBy(const Offset(20, 0));
    await gesture.up();
    expect(callbacks.looks, hasLength(looksAfterDisable));
    expect(callbacks.ups.where((value) => value.$1 == 41), hasLength(1));
  });

  testWidgets('cancelled one-shot controls never commit their actions', (
    tester,
  ) async {
    await _setSize(tester, const Size(800, 300));
    final callbacks = _Callbacks();
    await tester.pumpWidget(_controls(callbacks));

    final useGesture = await tester.createGesture(
      pointer: 51,
      kind: PointerDeviceKind.touch,
    );
    await useGesture.down(
      tester.getRect(find.byKey(const Key('touch-use'))).center,
    );
    await useGesture.cancel();

    final pauseGesture = await tester.createGesture(
      pointer: 52,
      kind: PointerDeviceKind.touch,
    );
    await pauseGesture.down(
      tester.getRect(find.byKey(const Key('touch-pause'))).center,
    );
    await pauseGesture.cancel();

    await tester.tap(find.byKey(const Key('touch-weapons')));
    await tester.pump();
    expect(find.byKey(const Key('touch-weapon-0')), findsOneWidget);
    final weaponGesture = await tester.createGesture(
      pointer: 53,
      kind: PointerDeviceKind.touch,
    );
    await weaponGesture.down(
      tester.getRect(find.byKey(const Key('touch-weapon-3'))).center,
    );
    await weaponGesture.cancel();
    await tester.pump();
    expect(find.byKey(const Key('touch-weapon-0')), findsNothing);
    expect(callbacks.uses, 0);
    expect(callbacks.pauses, 0);
    expect(callbacks.weapons, isEmpty);
    expect(
      callbacks.ups,
      containsAll(<(int, bool)>[(51, true), (52, true), (53, true)]),
    );
  });

  testWidgets('pending one-shot survives rebuild and commits on matching up', (
    tester,
  ) async {
    await _setSize(tester, const Size(800, 300));
    final callbacks = _Callbacks();
    await tester.pumpWidget(_controls(callbacks));
    await tester.tap(find.byKey(const Key('touch-weapons')));
    await tester.pump();
    final weaponGesture = await tester.createGesture(
      pointer: 61,
      kind: PointerDeviceKind.touch,
    );
    await weaponGesture.down(
      tester.getRect(find.byKey(const Key('touch-weapon-2'))).center,
    );
    expect(callbacks.weapons, isEmpty);

    await tester.pumpWidget(_controls(callbacks, mapOpen: true));
    await weaponGesture.up();
    await tester.pump();
    expect(callbacks.weapons, <int>[2]);
    expect(callbacks.ups, contains((61, false)));
  });

  testWidgets('dispose cancels held control', (tester) async {
    await _setSize(tester, const Size(800, 300));
    final callbacks = _Callbacks();
    await tester.pumpWidget(_controls(callbacks));

    final fire = tester.getRect(find.byKey(const Key('touch-fire')));
    final fireGesture = await tester.createGesture(
      pointer: 71,
      kind: PointerDeviceKind.touch,
    );
    await fireGesture.down(fire.center);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
    expect(callbacks.ups, contains((71, true)));
  });
}
