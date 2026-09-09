@Tags(['content'])
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:doom_core/doom_core.dart';
import 'package:doom_geometry/doom_geometry.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:doompeller/adapter/adapter.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_input.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'adapter/fake_gpu_backend.dart';

import 'support/local_iwad.dart';

const String _defaultWadPath = '.local/doom/DOOM1.WAD';
const int _allSkills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(FakeGpuBackend.new);

  test(
    'original E1M1 puff and barrel explosion leave no renderable billboard',
    () async {
      final PreparedDoomLevel original = await _loadOriginalE1m1();
      final ({
        Thing player,
        Thing barrel,
        int wallLine,
        MapVertex wallA,
        MapVertex wallB,
      })
      setup = _combatSetup(original.map);
      expect(
        (
          setup.wallA.x,
          setup.wallA.y,
          setup.wallB.x,
          setup.wallB.y,
          setup.wallLine,
        ),
        (64, -3648, -640, -3648, 125),
      );

      final DoomRuntimeGame puffRuntime = DoomRuntimeGame(
        _withThings(original, <Thing>[setup.player]),
      );
      puffRuntime.input.press(DoomControl.attack);
      ActorSpriteComponent? puffComponent;
      MobjView? puffActor;
      ViewLockedWeaponSpriteComponent? flashComponent;
      for (var tic = 0; tic < 40 && puffComponent == null; tic++) {
        puffRuntime.advanceMicrosForTest(28572);
        if (puffRuntime.weaponFlashVisible) {
          flashComponent = puffRuntime.weaponFlashComponentForTest;
        }
        final Iterable<MobjView> puffs = puffRuntime.gameState.mobjs.where(
          (MobjView actor) => actor.sprite == 'PUFF',
        );
        if (puffs.isNotEmpty) {
          puffActor = puffs.first;
          puffComponent = puffRuntime.actorComponentForTest(puffActor.id);
        }
      }
      expect(puffComponent, isNotNull);
      expect(puffActor, isNotNull);
      expect(
        _distanceToSegmentMapUnits(
          fixedToDouble(puffActor!.x),
          fixedToDouble(puffActor.y),
          setup.wallA.x.toDouble(),
          setup.wallA.y.toDouble(),
          setup.wallB.x.toDouble(),
          setup.wallB.y.toDouble(),
        ),
        inInclusiveRange(3, 5),
        reason:
            'classic PUFF sits four map units in front of the original E1M1 '
            'wall so its billboard is visible without becoming a mid-air hit',
      );
      expect(flashComponent, isNotNull);
      puffRuntime.input.release(DoomControl.attack);
      for (var tic = 0; tic < 40; tic++) {
        puffRuntime.advanceMicrosForTest(28572);
      }
      expect(
        puffRuntime.gameState.mobjs.where(
          (MobjView actor) => actor.sprite == 'PUFF',
        ),
        isEmpty,
      );
      expect(puffRuntime.scene.isActorSpriteActive(puffComponent!), isFalse);
      _expectInactiveRenderTreeIsSkipped(puffComponent);
      expect(puffRuntime.weaponFlashVisible, isFalse);
      _expectHiddenWeaponRenderTreeIsSkipped(flashComponent!);

      final DoomRuntimeGame barrelRuntime = DoomRuntimeGame(
        _withThings(original, <Thing>[setup.player, setup.barrel]),
      );
      barrelRuntime.input.press(DoomControl.attack);
      ActorSpriteComponent? explosionComponent;
      for (var tic = 0; tic < 160 && explosionComponent == null; tic++) {
        barrelRuntime.advanceMicrosForTest(28572);
        final Iterable<MobjView> explosions = barrelRuntime.gameState.mobjs
            .where((MobjView actor) => actor.sprite == 'BEXP');
        if (explosions.isNotEmpty) {
          explosionComponent = barrelRuntime.actorComponentForTest(
            explosions.first.id,
          );
        }
      }
      expect(explosionComponent, isNotNull);
      barrelRuntime.input.release(DoomControl.attack);
      for (var tic = 0; tic < 80; tic++) {
        barrelRuntime.advanceMicrosForTest(28572);
      }
      expect(
        barrelRuntime.gameState.mobjs.where(
          (MobjView actor) => actor.sprite == 'BEXP',
        ),
        isEmpty,
      );
      expect(
        barrelRuntime.scene.isActorSpriteActive(explosionComponent!),
        isFalse,
      );
      _expectInactiveRenderTreeIsSkipped(explosionComponent);
    },
  );
}

({Thing player, Thing barrel, int wallLine, MapVertex wallA, MapVertex wallB})
_combatSetup(MapData map) {
  for (var lineIndex = 0; lineIndex < map.linedefs.length; lineIndex++) {
    final Linedef line = map.linedefs[lineIndex];
    if (line.isTwoSided) continue;
    final MapVertex a = map.vertices[line.v1];
    final MapVertex b = map.vertices[line.v2];
    final int dx = b.x - a.x;
    final int dy = b.y - a.y;
    final double length = math.sqrt(dx * dx + dy * dy);
    if (length < 512) continue;
    final double midX = (a.x + b.x) / 2;
    final double midY = (a.y + b.y) / 2;
    final int playerX = (midX + dy * 64 / length).round();
    final int playerY = (midY - dx * 64 / length).round();
    if (_sectorAt(map, playerX, playerY) !=
        map.sidedefs[line.rightSidedef].sector) {
      continue;
    }
    final int angle =
        (math.atan2(midY - playerY, midX - playerX) * 180 / math.pi).round() %
        360;
    final double radians = angle * math.pi / 180;
    return (
      player: Thing(
        x: playerX,
        y: playerY,
        angle: angle,
        type: 1,
        flags: _allSkills,
      ),
      barrel: Thing(
        x: playerX + (math.cos(radians) * 32).round(),
        y: playerY + (math.sin(radians) * 32).round(),
        angle: 0,
        type: 2035,
        flags: _allSkills,
      ),
      wallLine: lineIndex,
      wallA: a,
      wallB: b,
    );
  }
  throw StateError('original E1M1 has no usable one-sided combat wall');
}

double _distanceToSegmentMapUnits(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final double dx = bx - ax;
  final double dy = by - ay;
  final double lengthSquared = dx * dx + dy * dy;
  final double projection = lengthSquared == 0
      ? 0
      : (((px - ax) * dx + (py - ay) * dy) / lengthSquared).clamp(0, 1);
  final double closestX = ax + dx * projection;
  final double closestY = ay + dy * projection;
  final double ox = px - closestX;
  final double oy = py - closestY;
  return math.sqrt(ox * ox + oy * oy);
}

int _sectorAt(MapData map, int x, int y) {
  int child = map.bspRoot;
  var guard = 0;
  while ((child & kSubsectorBit) == 0 && guard++ <= map.nodes.length) {
    final BspNode node = map.nodes[child];
    final int side = (x - node.x) * node.dy - (y - node.y) * node.dx;
    child = side >= 0 ? node.rightChild : node.leftChild;
  }
  final Subsector subsector = map.subsectors[child & ~kSubsectorBit];
  final Seg seg = map.segs[subsector.firstSeg];
  final Linedef line = map.linedefs[seg.linedef];
  final int sidedef = seg.side == 0 ? line.rightSidedef : line.leftSidedef;
  return map.sidedefs[sidedef].sector;
}

Future<PreparedDoomLevel> _loadOriginalE1m1() async {
  final ByteData asset = await loadLocalIwad(_defaultWadPath);
  final Uint8List bytes = asset.buffer.asUint8List(
    asset.offsetInBytes,
    asset.lengthInBytes,
  );
  final WadFile wad = WadFile.parse(bytes);
  final WadSet set = WadSet(<WadFile>[wad]);
  final WadResources resources = WadResources.load(set);
  final MapData map = MapData.load(set, 'E1M1');
  return PreparedDoomLevel(
    content: DoomContent(
      wads: set,
      mapName: 'E1M1',
      origin: DoomContentOrigin.developerIwad,
      sourcePath: _defaultWadPath,
    ),
    resources: resources,
    map: map,
    geometry: DoomGeometryCompiler.compile(map, resources),
    gameConfig: const GameConfig(monsters: false),
    seed: 3,
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

void _expectInactiveRenderTreeIsSkipped(ActorSpriteComponent component) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  expect(
    () => component.renderTree(canvas),
    returnsNormally,
    reason: 'inactive retained billboard must not reach Flame 3D draw submit',
  );
  recorder.endRecording();
}

void _expectHiddenWeaponRenderTreeIsSkipped(
  ViewLockedWeaponSpriteComponent component,
) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  expect(
    () => component.renderTree(canvas),
    returnsNormally,
    reason: 'hidden weapon flash must not reach Flame 3D draw submit',
  );
  recorder.endRecording();
}
