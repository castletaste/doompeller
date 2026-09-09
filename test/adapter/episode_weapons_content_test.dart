@Tags(['content'])
library;

import 'dart:math' as math;

import 'package:doom_core/doom_core.dart';
import 'package:doom_geometry/doom_geometry.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:doompeller/adapter/adapter.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_input.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;

import 'fake_gpu_backend.dart';

import '../support/local_iwad.dart';

const int _allSkills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;
const int _ticMicros = 28572;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(FakeGpuBackend.new);

  test(
    'original WAD maps rocket and chainsaw frames, slots and missile lifetime',
    () async {
      final PreparedDoomLevel original = await _loadOriginalE1m1();
      final Thing player = _playerFacingOriginalWall(original.map);
      final PlayerLoadout loadout = PlayerLoadout(
        health: 100,
        armor: 0,
        ammo: const Ammo(bullets: 50, rockets: 2),
        weapon: Weapon.rocketLauncher,
        ownedWeapons: const <Weapon>{
          Weapon.fist,
          Weapon.pistol,
          Weapon.rocketLauncher,
          Weapon.chainsaw,
        },
      );
      final DoomRuntimeGame runtime = DoomRuntimeGame(
        _withThings(original, <Thing>[player], loadout: loadout),
      );

      expect(runtime.weaponFrame, 'MISGA0');
      expect(
        runtime.onKeyEvent(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.digit6,
            logicalKey: LogicalKeyboardKey.digit6,
            timeStamp: Duration.zero,
          ),
          <LogicalKeyboardKey>{LogicalKeyboardKey.digit6},
        ),
        KeyEventResult.handled,
      );
      _advance(runtime, 40);
      expect(runtime.gameState.player.weapon, Weapon.chainsaw);
      expect(runtime.weaponFrame, startsWith('SAWG'));
      expect(runtime.weaponFlashVisible, isFalse);

      expect(
        runtime.onKeyEvent(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.digit5,
            logicalKey: LogicalKeyboardKey.digit5,
            timeStamp: Duration.zero,
          ),
          <LogicalKeyboardKey>{LogicalKeyboardKey.digit5},
        ),
        KeyEventResult.handled,
      );
      _advance(runtime, 40);
      expect(runtime.gameState.player.weapon, Weapon.rocketLauncher);
      expect(runtime.weaponFrame, 'MISGA0');

      runtime.input.press(DoomControl.attack);
      ActorSpriteComponent? missileComponent;
      var sawRocketFlash = false;
      for (var tic = 0; tic < 40 && missileComponent == null; tic++) {
        runtime.advanceMicrosForTest(_ticMicros);
        sawRocketFlash |= runtime.weaponFlashFrame?.startsWith('MISF') ?? false;
        final Iterable<MobjView> missiles = runtime.gameState.mobjs.where(
          (MobjView actor) => actor.sprite == 'MISL',
        );
        if (missiles.isNotEmpty) {
          missileComponent = runtime.actorComponentForTest(missiles.first.id);
        }
      }
      expect(sawRocketFlash, isTrue);
      expect(missileComponent, isNotNull);
      expect(missileComponent!.lumpName, startsWith('MISL'));
      runtime.input.release(DoomControl.attack);

      for (
        var tic = 0;
        tic < 40 && runtime.paletteIndex == DoomPaletteVariant.normal;
        tic++
      ) {
        runtime.advanceMicrosForTest(_ticMicros);
      }
      expect(
        runtime.paletteIndex,
        inInclusiveRange(
          DoomPaletteVariant.damageFirst,
          DoomPaletteVariant.damageLast,
        ),
        reason: 'the nearby original E1M1 wall returns one rocket splash',
      );
      final int healthAfterSplash = runtime.gameState.player.health;
      expect(healthAfterSplash, inExclusiveRange(0, 100));

      for (
        var tic = 0;
        tic < 40 && runtime.paletteIndex != DoomPaletteVariant.normal;
        tic++
      ) {
        runtime.advanceMicrosForTest(_ticMicros);
        expect(runtime.gameState.player.health, healthAfterSplash);
      }
      expect(runtime.paletteIndex, DoomPaletteVariant.normal);
      expect(
        runtime.gameState.mobjs.where(
          (MobjView actor) => actor.sprite == 'MISL',
        ),
        isEmpty,
      );
      expect(runtime.scene.isActorSpriteActive(missileComponent), isFalse);
      expect(runtime.weaponFlashVisible, isFalse);
    },
  );

  test(
    'original weapon frames occupy the classic visible psprite window',
    () async {
      final PreparedDoomLevel original = await _loadOriginalE1m1();
      final DoomRuntimeGame runtime = DoomRuntimeGame(original);
      final weapon = runtime.scene.root.children
          .whereType<ViewLockedWeaponSpriteComponent>()
          .single;

      expect(runtime.weaponFrame, 'PISGA0');
      expect(weapon.viewAnchorX, -0.5);
      expect(weapon.viewAnchorY, closeTo(0.3425, 1e-9));
      expect(weapon.surface.aabb.min.x, closeTo(-0.10625, 1e-6));
      expect(weapon.surface.aabb.max.x, closeTo(0.071875, 1e-6));
      expect(weapon.surface.aabb.min.y, closeTo(-0.4975, 1e-6));
      expect(weapon.surface.aabb.max.y, closeTo(-0.1875, 1e-6));

      final camera = DoomCameraComponent(
        viewport: FixedResolutionViewport(resolution: Vector2(800, 600)),
        target: Vector3(0, 0, -1),
      );
      final weaponComponents = <ViewLockedWeaponSpriteComponent>[weapon];
      const prefixes = <String>{
        'PUNG',
        'PISG',
        'PISF',
        'SHTG',
        'SHTF',
        'CHGG',
        'CHGF',
        'MISG',
        'MISF',
        'SAWG',
      };
      final frames = original.resources.spriteNames
          .where((name) => prefixes.contains(name.substring(0, 4)))
          .toList(growable: false);
      expect(frames, hasLength(30));
      for (final frame in frames) {
        final component = runtime.scene.addWeaponSprite(
          WeaponSpriteInstance(
            lumpName: frame,
            viewAnchorX: -0.5,
            viewAnchorY: 0.3425,
          ),
        );
        weaponComponents.add(component);
      }
      runtime.scene.syncToCamera(camera);
      for (final component in weaponComponents) {
        expect(
          component.aabb.frustumCullTest(camera.frustum),
          isNot(CullResult.outside),
          reason: '${component.lumpName} is rejected by Object3D.renderTree',
        );
      }

      Vector4 projected(double x, double y) {
        final world = weapon.worldTransformMatrix * Vector4(x, y, 0, 1);
        final clip = camera.viewProjectionMatrix * world;
        return clip / clip.w;
      }

      final projectedMin = projected(
        weapon.surface.aabb.min.x,
        weapon.surface.aabb.min.y,
      );
      final projectedMax = projected(
        weapon.surface.aabb.max.x,
        weapon.surface.aabb.max.y,
      );
      expect(projectedMin.x, closeTo(weapon.surface.aabb.min.x * 2, 1e-6));
      expect(projectedMin.y, closeTo(weapon.surface.aabb.min.y * 2, 1e-6));
      expect(projectedMax.x, closeTo(weapon.surface.aabb.max.x * 2, 1e-6));
      expect(projectedMax.y, closeTo(weapon.surface.aabb.max.y * 2, 1e-6));

      runtime.input.press(DoomControl.attack);
      for (var tic = 0; tic < 12 && !runtime.weaponFlashVisible; tic++) {
        runtime.advanceMicrosForTest(_ticMicros);
      }
      final flash = runtime.weaponFlashComponentForTest;
      expect(flash, isNotNull);
      expect(flash!.visible, isTrue);
      expect(flash.viewAnchorX, weapon.viewAnchorX);
      expect(flash.viewAnchorY, weapon.viewAnchorY);
    },
  );

  test('original WAD pickup flash expires and restart clears it', () async {
    final PreparedDoomLevel original = await _loadOriginalE1m1();
    final Thing pickup = original.map.things.firstWhere(
      (Thing thing) => thing.type == 2015,
    );
    final Thing player = Thing(
      x: pickup.x,
      y: pickup.y,
      angle: 0,
      type: 1,
      flags: _allSkills,
    );
    PreparedDoomLevel pickupLevel() =>
        _withThings(original, <Thing>[player, pickup]);

    final DoomRuntimeGame expiring = DoomRuntimeGame(pickupLevel());
    expiring.advanceMicrosForTest(_ticMicros);
    expect(
      expiring.paletteIndex,
      inInclusiveRange(
        DoomPaletteVariant.itemPickupFirst,
        DoomPaletteVariant.itemPickupLast,
      ),
    );
    _advance(expiring, 5);
    expect(
      expiring.paletteIndex,
      inInclusiveRange(
        DoomPaletteVariant.itemPickupFirst,
        DoomPaletteVariant.itemPickupLast,
      ),
    );
    expiring.advanceMicrosForTest(_ticMicros);
    expect(expiring.paletteIndex, DoomPaletteVariant.normal);

    final DoomRuntimeGame restarting = DoomRuntimeGame(pickupLevel());
    restarting.advanceMicrosForTest(_ticMicros);
    expect(restarting.paletteIndex, isNot(DoomPaletteVariant.normal));
    restarting.restartLevel();
    expect(restarting.paletteIndex, DoomPaletteVariant.normal);
  });

  test(
    'original resource powerups drive palette and COLORMAP then expire',
    () async {
      final original = await _loadOriginalE1m1();
      final player = original.map.things.firstWhere((thing) => thing.type == 1);
      // Component probe: original geometry/art, authored pickup at the spawn.
      // This is deliberately not a claim of collecting these in a playthrough.
      for (final type in <int>[2025, 2022, 2045]) {
        final runtime = DoomRuntimeGame(
          _withThings(original, <Thing>[
            player,
            Thing(
              x: player.x,
              y: player.y,
              angle: 0,
              type: type,
              flags: _allSkills,
            ),
          ]),
        );
        _advance(runtime, 8);
        if (type == 2025) {
          expect(runtime.paletteIndex, DoomPaletteVariant.radiationSuit);
        } else {
          final row = type == 2022 ? 32 : 0;
          expect(
            runtime.scene.materials.materials.every(
              (m) => m.fixedColorMap == row,
            ),
            isTrue,
          );
        }
        _advance(runtime, 5000);
        expect(runtime.paletteIndex, DoomPaletteVariant.normal);
        expect(
          runtime.scene.materials.materials.every((m) => m.fixedColorMap == -1),
          isTrue,
        );
        runtime.restartLevel();
        expect(runtime.paletteIndex, DoomPaletteVariant.normal);
        expect(
          runtime.scene.materials.materials.every((m) => m.fixedColorMap == -1),
          isTrue,
        );
      }
    },
  );
}

void _advance(DoomRuntimeGame runtime, int tics) {
  for (var tic = 0; tic < tics; tic++) {
    runtime.advanceMicrosForTest(_ticMicros);
  }
}

Thing _playerFacingOriginalWall(MapData map) {
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
    return Thing(
      x: playerX,
      y: playerY,
      angle: angle,
      type: 1,
      flags: _allSkills,
    );
  }
  throw StateError('original E1M1 has no usable one-sided combat wall');
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
  final ByteData asset = await loadLocalIwad(kDocumentedLocalWadPath);
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
    gameConfig: const GameConfig(monsters: false),
    seed: 3,
  );
}

PreparedDoomLevel _withThings(
  PreparedDoomLevel original,
  List<Thing> things, {
  PlayerLoadout? loadout,
}) {
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
    entryLoadout: loadout,
  );
}
