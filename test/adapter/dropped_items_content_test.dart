import 'dart:math' as math;

import 'package:doom_core/doom_core.dart';
import 'package:doom_geometry/doom_geometry.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:doompeller/adapter/adapter.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_input.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_gpu_backend.dart';

const int _allSkills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;
const int _ticMicros = 28572;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(FakeGpuBackend.new);

  test(
    'original E1M4 renders and collects a dynamically dropped shotgun',
    () async {
      final PreparedDoomLevel original = await _loadOriginalE1m4();

      expect(
        original.map.things.where(
          (Thing thing) =>
              thing.type == 2001 &&
              (thing.flags & ThingFlags.medium) != 0 &&
              (thing.flags & ThingFlags.multiplayerOnly) == 0,
        ),
        isEmpty,
        reason: 'E1M4 has no eligible placed shotgun on the default skill',
      );
      expect(
        original.createGame().mobjs.where(
          (MobjView actor) => actor.sprite == 'SHOT',
        ),
        isEmpty,
      );

      final Thing player = original.map.things.singleWhere(
        (Thing thing) => thing.type == 1,
      );
      final double radians = player.angle * math.pi / 180;
      final Thing shotguy = Thing(
        x: player.x + (math.cos(radians) * 96).round(),
        y: player.y + (math.sin(radians) * 96).round(),
        angle: (player.angle + 180) % 360,
        type: 9,
        flags: _allSkills,
      );
      final PreparedDoomLevel encounter = _withThings(original, <Thing>[
        player,
        shotguy,
      ]);
      expect(encounter.initialSpritePrefixes, isNot(contains('SHOT')));

      final DoomRuntimeGame runtime = DoomRuntimeGame(encounter);
      runtime.input.press(DoomControl.attack);
      MobjView? drop;
      for (var tic = 0; tic < 350 && drop == null; tic++) {
        runtime.advanceMicrosForTest(_ticMicros);
        drop = runtime.gameState.mobjs
            .where((MobjView actor) => actor.sprite == 'SHOT')
            .firstOrNull;
      }
      runtime.input.release(DoomControl.attack);

      expect(drop, isNotNull, reason: 'the isolated shotguy must die');
      expect(drop!.flags & MobjFlags.dropped, isNot(0));
      final ActorSpriteComponent? component = runtime.actorComponentForTest(
        drop.id,
      );
      expect(component, isNotNull);
      expect(component!.lumpName, startsWith('SHOT'));
      expect(runtime.scene.isActorSpriteActive(component), isTrue);

      final int shellsBefore = runtime.gameState.player.ammo.shells;
      runtime.input.press(DoomControl.forward);
      for (
        var tic = 0;
        tic < 80 &&
            runtime.gameState.mobjs.any(
              (MobjView actor) => actor.id == drop!.id,
            );
        tic++
      ) {
        runtime.advanceMicrosForTest(_ticMicros);
      }
      runtime.input.release(DoomControl.forward);

      expect(
        runtime.gameState.mobjs.any((MobjView actor) => actor.id == drop!.id),
        isFalse,
      );
      expect(runtime.gameState.player.ammo.shells - shellsBefore, 4);
      expect(runtime.actorComponentForTest(drop.id), isNull);
      expect(runtime.scene.isActorSpriteActive(component), isFalse);
      for (
        var tic = 0;
        tic < 40 && runtime.gameState.player.weapon != Weapon.shotgun;
        tic++
      ) {
        runtime.advanceMicrosForTest(_ticMicros);
      }
      expect(runtime.gameState.player.weapon, Weapon.shotgun);
    },
  );
}

Future<PreparedDoomLevel> _loadOriginalE1m4() async {
  final ByteData asset = await rootBundle.load(kDocumentedLocalWadPath);
  final Uint8List bytes = asset.buffer.asUint8List(
    asset.offsetInBytes,
    asset.lengthInBytes,
  );
  final WadSet wads = WadSet(<WadFile>[WadFile.parse(bytes)]);
  final WadResources resources = WadResources.load(wads);
  final MapData map = MapData.load(wads, 'E1M4');
  return PreparedDoomLevel(
    content: DoomContent(
      wads: wads,
      mapName: 'E1M4',
      origin: DoomContentOrigin.developerIwad,
      sourcePath: kDocumentedLocalWadPath,
    ),
    resources: resources,
    map: map,
    geometry: DoomGeometryCompiler.compile(map, resources),
    gameConfig: const GameConfig(),
    seed: 7,
  );
}

PreparedDoomLevel _withThings(PreparedDoomLevel original, List<Thing> things) {
  final MapData source = original.map;
  return PreparedDoomLevel(
    content: original.content,
    resources: original.resources,
    map: MapData(
      name: source.name,
      vertices: source.vertices,
      linedefs: source.linedefs,
      sidedefs: source.sidedefs,
      sectors: source.sectors,
      segs: source.segs,
      subsectors: source.subsectors,
      nodes: source.nodes,
      things: things,
      blockmap: source.blockmap,
      reject: source.reject,
    ),
    geometry: original.geometry,
    gameConfig: const GameConfig(monsters: false),
    seed: original.seed,
  );
}
