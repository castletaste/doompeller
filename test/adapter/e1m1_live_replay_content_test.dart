import 'package:doom_core/doom_core.dart';
import 'package:doom_geometry/doom_geometry.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:doompeller/adapter/adapter.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_input.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/e1m1_playthrough.dart';
import 'fake_gpu_backend.dart';

const int _productionCommandCount = 2151;
const int _productionHash = 0x36d1d056;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(FakeGpuBackend.new);

  test(
    'FakeGPU adapter update loop completes the production E1M1 replay',
    () async {
      final PreparedDoomLevel level = await _loadProductionE1m1();
      final E1m1PlaythroughResult route = E1m1PlaythroughRunner(
        level.map,
        gameConfig: const GameConfig(),
        seed: 0,
        includeArmor: true,
      ).run();
      expect(route.completed, isTrue);
      expect(route.commands, hasLength(_productionCommandCount));
      expect(route.tics, route.commands.length);
      expect(route.hash, _productionHash);

      DoomReplayResult? callbackResult;
      final DoomRuntimeGame runtime = DoomRuntimeGame(
        level,
        replayInput: DoomReplayInput(
          commands: route.commands,
          expectedFinalHash: _productionHash,
          onFinished: (DoomReplayResult result) => callbackResult = result,
        ),
      );
      for (final PackedFlameSurface surface in runtime.scene.surfaces) {
        surface.resource;
      }

      // Device state is deliberately hostile: replay mode must neither sample
      // it into TicCmd nor let its pause toggle stop the fixed loop.
      runtime.input
        ..press(DoomControl.forward)
        ..press(DoomControl.attack)
        ..triggerUse()
        ..triggerPause();
      runtime
        ..setPointerAttack(true)
        ..addPointerYaw(500)
        ..togglePause();

      for (
        var frame = 0;
        frame < 10000 && runtime.replayResult == null;
        frame++
      ) {
        runtime.update(1 / 60);
      }

      final DoomReplayResult result = runtime.replayResult!;
      debugPrint(
        'FakeGPU adapter replay result: status=${result.status.label} '
        'commands=${result.commandCount}/${result.commandTotal} '
        'tic=${result.gameTic} hash=0x${result.actualHash.toRadixString(16)}',
      );
      expect(identical(callbackResult, result), isTrue);
      expect(result.status, DoomReplayStatus.complete);
      expect(result.commandCount, _productionCommandCount);
      expect(result.commandTotal, _productionCommandCount);
      expect(result.gameTic, _productionCommandCount);
      expect(result.levelComplete, isTrue);
      expect(result.expectedHash, _productionHash);
      expect(result.actualHash, _productionHash);
      expect(runtime.gameState.levelComplete, isTrue);
      expect(runtime.gameState.hashState(), _productionHash);
      expect(runtime.tickDriver.droppedTics, 0);

      final int terminalTic = runtime.gameState.tic;
      runtime.update(1);
      expect(runtime.gameState.tic, terminalTic);
      expect(runtime.replayCommandCount, _productionCommandCount);
      expect(runtime.gameState.hashState(), _productionHash);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<PreparedDoomLevel> _loadProductionE1m1() async {
  final ByteData asset = await rootBundle.load(kDocumentedLocalWadPath);
  final Uint8List bytes = asset.buffer.asUint8List(
    asset.offsetInBytes,
    asset.lengthInBytes,
  );
  final WadSet wads = WadSet(<WadFile>[WadFile.parse(bytes)]);
  final WadResources resources = WadResources.load(wads);
  final MapData map = MapData.load(wads, 'E1M1');
  return PreparedDoomLevel(
    content: DoomContent(
      wads: wads,
      mapName: 'E1M1',
      origin: DoomContentOrigin.developerIwad,
      sourcePath: kDocumentedLocalWadPath,
    ),
    resources: resources,
    map: map,
    geometry: DoomGeometryCompiler.compile(map, resources),
    gameConfig: const GameConfig(),
    seed: 0,
  );
}
