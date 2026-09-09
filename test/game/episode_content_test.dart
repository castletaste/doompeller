@Tags(['content'])
library;

import 'dart:async';

import 'package:doom_core/doom_core.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_app_controller.dart';
import 'package:doompeller/game/level_load_coordinator.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doompeller/game/doom_hud.dart';
import 'package:doompeller/ui/doom_app.dart';

import '../widget_test.dart' show FakeRuntime, testSurface;

import '../support/local_iwad.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DoomContent content;
  late PreparedDoomLevel first;
  final DoomLevelPreparer preparer = DoomLevelPreparer();
  final PlayerLoadout loadout = PlayerLoadout(
    health: 66,
    armor: 45,
    ammo: const Ammo(bullets: 30, shells: 12),
    weapon: Weapon.shotgun,
    ownedWeapons: <Weapon>{Weapon.fist, Weapon.pistol, Weapon.shotgun},
  );
  LevelExit exitFor(String name) =>
      LevelExit(mapName: name, secret: false, loadout: loadout);

  setUpAll(() async {
    final ByteData data = await loadLocalIwad('.local/doom/DOOM1.WAD');
    final result =
        DoomContentSource(environment: const {}).loadIwadBytes(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            )
            as DoomContentLoaded;
    content = result.content;
    final controller = DoomAppController(loadDeveloper: () async => result);
    await controller.start();
    first = controller.state.level!;
    controller.dispose();
  });

  DoomAppController controller({PrepareDoomLevel? prepare}) =>
      DoomAppController(
        initialState: DoomAppState.ready(
          first,
          phase: DoomAppPhase.developerIwadReady,
        ),
        loadDeveloper: () async => DoomContentLoaded(content),
        prepare: prepare,
      );

  test(
    'original E1M2 is prepared from the same WAD with entry inventory',
    () async {
      final app = controller();
      addTearDown(app.dispose);
      await app.advanceLevel(first, exitFor('E1M1'));
      final PreparedDoomLevel second = app.state.level!;
      expect(second.map.name, 'E1M2');
      expect(second.content.wads, same(first.content.wads));
      final GameState state = second.createGame();
      expect(state.player.health, 66);
      expect(state.player.armor, 45);
      expect(state.player.weapon, Weapon.shotgun);
      expect(state.player.ammo.shells, 12);
      expect(state.player.keys, isEmpty);
      expect(second.createGame().hashState(), state.hashState());
    },
  );

  test(
    'duplicate continue prepares once and late completion cannot replace restart',
    () async {
      final gate = Completer<void>();
      var calls = 0;
      final app = controller(
        prepare: (content, token) async {
          calls++;
          if (content.mapName == 'E1M2') await gate.future;
          return preparer.prepare(content, token);
        },
      );
      addTearDown(app.dispose);
      final pending = app.advanceLevel(first, exitFor('E1M1'));
      await app.advanceLevel(first, exitFor('E1M1'));
      expect(calls, 1);
      expect(app.state.level, same(first));
      await app.start();
      final restarted = app.state.level;
      gate.complete();
      await pending;
      expect(app.state.level, same(restarted));
      expect(app.state.level!.map.name, 'E1M1');
    },
  );

  test(
    'prepares every original episode successor including the secret map',
    () async {
      final app = controller();
      addTearDown(app.dispose);
      for (final name in <String>[
        'E1M2',
        'E1M3',
        'E1M9',
        'E1M4',
        'E1M5',
        'E1M6',
        'E1M7',
        'E1M8',
      ]) {
        final previous = app.state.level!;
        await app.advanceLevel(
          previous,
          LevelExit(
            mapName: previous.map.name,
            secret: previous.map.name == 'E1M3',
            loadout: loadout,
          ),
        );
        expect(app.state.errorMessage, isNull, reason: name);
        expect(app.state.level!.map.name, name);
        expect(app.state.level!.content.wads, same(first.content.wads));
        expect(app.state.level!.createGame().player.ammo.shells, 12);
      }
      final terminal = app.state.level!;
      await app.advanceLevel(terminal, exitFor('E1M8'));
      expect(app.state.level, same(terminal));
    },
  );

  test('failed continuation retains the completed map and can retry', () async {
    var calls = 0;
    final app = controller(
      prepare: (content, token) {
        if (calls++ == 0) throw StateError('test preparation failure');
        return preparer.prepare(content, token);
      },
    );
    addTearDown(app.dispose);
    await app.advanceLevel(first, exitFor('E1M1'));
    expect(app.state.level, same(first));
    expect(app.state.errorMessage, contains('preparation failure'));
    await app.advanceLevel(first, exitFor('E1M1'));
    expect(app.state.level!.map.name, 'E1M2');
    expect(app.state.errorMessage, isNull);
  });

  test(
    'start cancels transition preparation before the IWAD loader resolves',
    () async {
      final transitionGate = Completer<void>();
      final startGate = Completer<DoomContentLoadResult>();
      late LevelLoadToken transitionToken;
      final app = DoomAppController(
        initialState: DoomAppState.ready(
          first,
          phase: DoomAppPhase.developerIwadReady,
        ),
        loadDeveloper: () => startGate.future,
        prepare: (content, token) async {
          if (content.mapName == 'E1M2') {
            transitionToken = token;
            await transitionGate.future;
          }
          return preparer.prepare(content, token);
        },
      );
      addTearDown(app.dispose);
      final transition = app.advanceLevel(first, exitFor('E1M1'));
      expect(transitionToken.isCurrent, isTrue);
      final starting = app.start();
      expect(transitionToken.isCancelled, isTrue);
      transitionGate.complete();
      await transition;
      expect(app.state.phase, DoomAppPhase.loading);
      startGate.complete(DoomContentLoaded(content));
      await starting;
      expect(app.state.level!.map.name, 'E1M1');
    },
  );

  test(
    'an exit from a different map does not advance the active map',
    () async {
      var calls = 0;
      final app = controller(
        prepare: (DoomContent content, LevelLoadToken token) {
          calls++;
          return preparer.prepare(content, token);
        },
      );
      addTearDown(app.dispose);
      await app.advanceLevel(first, exitFor('E1M3'));
      expect(app.state.level, same(first));
      expect(calls, 0);
    },
  );

  testWidgets('continue button replaces original E1M1 with original E1M2', (
    tester,
  ) async {
    // Native preparation has its own controller tests above. Prepare real E1M2
    // outside the fake widget clock, then explicitly control the UI async gap.
    final prepared = await tester.runAsync(() async {
      final loading = controller();
      try {
        await loading.advanceLevel(first, exitFor('E1M1'));
        return loading.state.level!;
      } finally {
        loading.dispose();
      }
    });
    final preparation = Completer<PreparedDoomLevel>();
    final app = controller(prepare: (_, _) => preparation.future);
    addTearDown(app.dispose);
    final runtime = FakeRuntime()..levelExit = exitFor('E1M1');
    runtime.notifier.value = DoomHudSnapshot(
      health: 66,
      armor: 45,
      bullets: 30,
      shells: 12,
      weapon: Weapon.shotgun,
      keys: const <Key>{},
      kills: 6,
      totalKills: 6,
      items: 3,
      totalItems: 37,
      secrets: 0,
      totalSecrets: 3,
      levelTime: 2151,
      paused: false,
      levelComplete: true,
      diagnostics: const DoomFrameDiagnosticsSnapshot(),
    );
    await tester.pumpWidget(
      DoomApp(
        controller: app,
        autoStart: false,
        runtimeFactory: (level) =>
            identical(level, first) ? runtime : FakeRuntime(),
        gameSurfaceBuilder: testSurface,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('CONTINUE TO E1M2'), findsOneWidget);
    expect(find.text('SELECT LOCAL IWAD'), findsNothing);
    await tester.tap(find.text('CONTINUE TO E1M2'));
    await tester.pump();
    expect(app.state.level, same(first));
    preparation.complete(prepared!);
    await tester.pumpAndSettle();
    expect(app.state.level!.map.name, 'E1M2');
    expect(find.text('DEVELOPER IWAD · E1M2'), findsOneWidget);
    expect(find.text('CONTINUE TO E1M2'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
