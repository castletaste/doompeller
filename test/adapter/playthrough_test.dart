import 'package:doom_core/doom_core.dart';
import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:doom_wad/doom_wad.dart';
import 'package:doompeller/adapter/adapter.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_input.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

import 'fake_gpu_backend.dart';

Future<PreparedDoomLevel> playthroughLevel() async {
  final DoomContent content = DoomContentSource(
    environment: const <String, String>{},
  ).loadFixture();
  final WadResources resources = WadResources.load(
    DoomPlaythroughFixture.resourceWads(),
  );
  final MapData map = DoomPlaythroughFixture.map();
  return PreparedDoomLevel(
    content: content,
    resources: resources,
    map: map,
    geometry: geometry.DoomGeometryCompiler.compile(map, resources),
    gameConfig: const GameConfig(),
    seed: DoomPlaythroughReplay.seed,
  );
}

void queueCommand(DoomInputState input, TicCmd command) {
  expect(command.sideMove, 0);
  expect(command.forwardMove, anyOf(0, DoomInputState.moveSpeed));
  expect(command.buttons & Buttons.changeWeapon, 0);
  if (command.forwardMove == DoomInputState.moveSpeed) {
    input.press(DoomControl.forward);
  } else {
    input.release(DoomControl.forward);
  }
  if (command.attacking) {
    input.press(DoomControl.attack);
  } else {
    input.release(DoomControl.attack);
  }
  if (command.using) input.triggerUse();
  if (command.angleTurn != 0) input.addPointerTurn(command.angleTurn);
}

void runRuntimeReplay(DoomRuntimeGame runtime) {
  for (final TicCmd command in DoomPlaythroughReplay.commands) {
    queueCommand(runtime.input, command);
    expect(runtime.advanceMicrosForTest(28572), 1);
  }
  runtime.input
    ..release(DoomControl.forward)
    ..release(DoomControl.attack);
}

void expectCompleted(GameState game) {
  expect(game.levelComplete, isTrue);
  expect(game.killCount, 2);
  expect(game.totalKills, 2);
  expect(game.itemCount, 1);
  expect(game.totalItems, 1);
  expect(game.secretsFound, 1);
  expect(game.totalSecrets, 1);
  expect(game.player.keys, contains(Key.blue));
}

void main() {
  setUp(FakeGpuBackend.new);

  test(
    'production runtime completes the exact core replay without growth',
    () async {
      final PreparedDoomLevel prepared = await playthroughLevel();
      var completions = 0;
      final DoomRuntimeGame runtime = DoomRuntimeGame(
        prepared,
        onLevelComplete: (_) => completions++,
      );
      for (final PackedFlameSurface surface in runtime.scene.surfaces) {
        surface.resource;
      }

      runRuntimeReplay(runtime);
      expectCompleted(runtime.gameState);
      expect(completions, 1);
      final int firstHash = runtime.gameState.hashState();
      final RenderDiagnosticsSnapshot first = runtime.scene.diagnostics
          .snapshot();
      final int firstRegistry = runtime.scene.actorSurfaceRegistryCount;
      final int firstSurfaceCount = runtime.scene.surfaceCount;
      expect(first.dynamicUpdates, greaterThan(0));
      expect(
        runtime.gameState.sectors
            .elementAt(DoomPlaythroughFixture.liftSector)
            .floorHeight,
        toFixed(32),
      );

      runtime.restartLevel();
      runRuntimeReplay(runtime);
      expectCompleted(runtime.gameState);
      expect(completions, 2);
      expect(runtime.gameState.hashState(), firstHash);
      final RenderDiagnosticsSnapshot second = runtime.scene.diagnostics
          .snapshot();
      expect(second.surfacesCreated, first.surfacesCreated);
      expect(second.gpuBuffersCreated, first.gpuBuffersCreated);
      expect(second.texturesCreated, first.texturesCreated);
      expect(runtime.scene.actorSurfaceRegistryCount, firstRegistry);
      expect(runtime.scene.surfaceCount, firstSurfaceCount);

      debugPrint(
        'runtime playthrough: runs=2 tics=${runtime.gameState.tic} '
        'hash=0x${firstHash.toRadixString(16)} '
        'surfaces=${second.surfacesCreated} buffers=${second.gpuBuffersCreated} '
        'actorRegistry=$firstRegistry dynamicUpdates=${second.dynamicUpdates}',
      );
    },
  );
}
