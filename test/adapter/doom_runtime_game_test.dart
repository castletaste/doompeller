import 'dart:math' as math;

import 'package:doom_core/doom_core.dart';
import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:doom_wad/doom_wad.dart';
import 'package:doompeller/adapter/adapter.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_input.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import 'fake_gpu_backend.dart';

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
    geometry: geometry.DoomGeometryCompiler.compile(map, resources),
    game: GameState.start(map, const GameConfig(), seed: 3),
  );
}

Future<PreparedDoomLevel> fixtureExitLevel() async {
  final base = await fixtureLevel();
  final source = base.map;
  final linedefs = List<Linedef>.of(source.linedefs);
  final int exitIndex = linedefs.indexWhere((line) {
    final a = source.vertices[line.v1];
    final b = source.vertices[line.v2];
    return a.y == 256 &&
        b.y == 256 &&
        128 >= math.min(a.x, b.x) &&
        128 <= math.max(a.x, b.x);
  });
  if (exitIndex < 0) throw StateError('fixture north wall not found');
  final old = linedefs[exitIndex];
  var v1 = old.v1;
  var v2 = old.v2;
  final a = source.vertices[v1];
  final b = source.vertices[v2];
  if ((b.x - a.x) * (200 - a.y) > 0) {
    final swap = v1;
    v1 = v2;
    v2 = swap;
  }
  linedefs[exitIndex] = Linedef(
    v1: v1,
    v2: v2,
    flags: old.flags,
    special: LineSpecial.exitSwitchOnce,
    tag: old.tag,
    rightSidedef: old.rightSidedef,
    leftSidedef: old.leftSidedef,
  );
  final map = MapData(
    name: source.name,
    vertices: source.vertices,
    linedefs: linedefs,
    sidedefs: source.sidedefs,
    sectors: source.sectors,
    segs: source.segs,
    subsectors: source.subsectors,
    nodes: source.nodes,
    things: const <Thing>[Thing(x: 128, y: 200, angle: 90, type: 1, flags: 7)],
    blockmap: source.blockmap,
    reject: source.reject,
  );
  return PreparedDoomLevel(
    content: base.content,
    resources: base.resources,
    map: map,
    geometry: base.geometry,
    game: GameState.start(map, const GameConfig()),
  );
}

void main() {
  setUp(FakeGpuBackend.new);

  test('chunked elapsed time advances exactly 35 simulation tics', () async {
    final runtime = DoomRuntimeGame(await fixtureLevel());

    for (var i = 0; i < 10; i++) {
      runtime.advanceMicrosForTest(100000);
    }

    expect(runtime.gameState.tic, 35);
    expect(runtime.tickDriver.executedTics, 35);
    expect(runtime.tickDriver.droppedTics, 0);
  });

  test('camera interpolation never advances simulation state', () async {
    final runtime = DoomRuntimeGame(await fixtureLevel());
    runtime.input.press(DoomControl.forward);
    runtime.advanceMicrosForTest(28572);
    final tic = runtime.gameState.tic;

    runtime.renderCameraAtForTest(0);
    final previous = runtime.cameraSnapshot;
    runtime.renderCameraAtForTest(1);
    final current = runtime.cameraSnapshot;

    expect(runtime.gameState.tic, tic);
    expect((current.x, current.z), isNot((previous.x, previous.z)));
  });

  test('Escape key is a one-shot runtime pause toggle', () async {
    final runtime = DoomRuntimeGame(await fixtureLevel());
    runtime.onKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.escape,
        logicalKey: LogicalKeyboardKey.escape,
        timeStamp: Duration.zero,
      ),
      <LogicalKeyboardKey>{LogicalKeyboardKey.escape},
    );
    runtime.advanceMicrosForTest(0);
    expect(runtime.isPaused, isTrue);
    final pausedAt = runtime.gameState.tic;
    runtime.advanceMicrosForTest(100000);
    expect(runtime.gameState.tic, pausedAt);
  });

  test(
    'Tab toggles the UI-only automap and leaves replay identity unchanged',
    () async {
      final runtime = DoomRuntimeGame(await fixtureLevel());
      final before = runtime.gameState.hashState();

      runtime.onKeyEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.tab,
          logicalKey: LogicalKeyboardKey.tab,
          timeStamp: Duration.zero,
        ),
        <LogicalKeyboardKey>{LogicalKeyboardKey.tab},
      );
      expect(runtime.automap.value.isOpen, isTrue);

      for (var i = 0; i < 100; i++) {
        runtime.zoomAutomap(inwards: i.isEven);
      }
      expect(runtime.gameState.hashState(), before);

      runtime.onKeyEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.tab,
          logicalKey: LogicalKeyboardKey.tab,
          timeStamp: Duration.zero,
        ),
        <LogicalKeyboardKey>{LogicalKeyboardKey.tab},
      );
      expect(runtime.automap.value.isOpen, isFalse);
    },
  );

  test('focus loss clears held W and Ctrl before the next TicCmd', () async {
    final runtime = DoomRuntimeGame(await fixtureLevel());
    runtime.onKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyW,
        logicalKey: LogicalKeyboardKey.keyW,
        timeStamp: Duration.zero,
      ),
      <LogicalKeyboardKey>{LogicalKeyboardKey.keyW},
    );
    runtime.onKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.controlLeft,
        logicalKey: LogicalKeyboardKey.controlLeft,
        timeStamp: Duration.zero,
      ),
      <LogicalKeyboardKey>{
        LogicalKeyboardKey.keyW,
        LogicalKeyboardKey.controlLeft,
      },
    );

    runtime.clearInput();

    expect(runtime.input.consume().command, TicCmd.empty);
  });

  test('actor sync adds, updates and removes stable components', () async {
    final runtime = DoomRuntimeGame(await fixtureLevel());
    const first = MobjView(
      id: 90,
      x: 10 * kFracUnit,
      y: 20 * kFracUnit,
      z: 3 * kFracUnit,
      angle: 0,
      sprite: 'TEST',
      frame: 0,
      flags: 0,
      health: 1,
    );
    runtime.syncActorViewsForTest(const <MobjView>[first]);
    expect(runtime.actorIds, contains(90));
    expect(runtime.actorPositionForTest(90), (x: 10, y: 3, z: -20));

    const moved = MobjView(
      id: 90,
      x: 12 * kFracUnit,
      y: 24 * kFracUnit,
      z: 4 * kFracUnit,
      angle: kAng90,
      sprite: 'TEST',
      frame: 1,
      flags: 0,
      health: 1,
    );
    runtime.syncActorViewsForTest(const <MobjView>[moved]);
    expect(runtime.actorComponentCount, 1);
    expect(runtime.actorPositionForTest(90), (x: 12, y: 4, z: -24));

    runtime.syncActorViewsForTest(const <MobjView>[]);
    expect(runtime.actorIds, isEmpty);
  });

  test('actor pool stays flat across 100 spawn/remove cycles', () async {
    final runtime = DoomRuntimeGame(await fixtureLevel());
    const actor = MobjView(
      id: 91,
      x: 10 * kFracUnit,
      y: 20 * kFracUnit,
      z: 3 * kFracUnit,
      angle: 0,
      sprite: 'TEST',
      frame: 0,
      flags: 0,
      health: 1,
    );
    runtime.syncActorViewsForTest(const <MobjView>[actor]);
    final warmedRegistry = runtime.scene.actorSurfaceRegistryCount;
    final retained = runtime.actorComponentForTest(91);
    for (final surface in runtime.scene.surfaces) {
      surface.resource;
    }
    runtime.syncActorViewsForTest(const <MobjView>[]);
    final baselineSurfaces = runtime.scene.surfaceCount;
    final warmedBuffers = runtime.scene.diagnostics.gpuBuffersCreated;

    for (var cycle = 0; cycle < 100; cycle++) {
      runtime.syncActorViewsForTest(const <MobjView>[actor]);
      expect(runtime.actorComponentForTest(91), same(retained));
      runtime.syncActorViewsForTest(const <MobjView>[]);
    }

    expect(runtime.scene.actorSurfaceRegistryCount, warmedRegistry);
    expect(runtime.scene.activeActorSurfaceCount, 0);
    expect(runtime.scene.pooledActorSurfaceCount, warmedRegistry);
    expect(runtime.scene.surfaceCount, baselineSurfaces);
    expect(runtime.scene.flushPendingUploads(), 0);
    expect(runtime.scene.diagnostics.gpuBuffersCreated, warmedBuffers);
  });

  test(
    'missing prefix or frame hides stale actor and valid state reuses it',
    () async {
      final runtime = DoomRuntimeGame(await fixtureLevel());
      const valid = MobjView(
        id: 92,
        x: 10 * kFracUnit,
        y: 20 * kFracUnit,
        z: 3 * kFracUnit,
        angle: 0,
        sprite: 'TEST',
        frame: 0,
        flags: 0,
        health: 1,
      );
      runtime.syncActorViewsForTest(const <MobjView>[valid]);
      final warmedRegistry = runtime.scene.actorSurfaceRegistryCount;
      final retained = runtime.actorComponentForTest(92);
      expect(retained, isNotNull);
      expect(runtime.scene.isActorSpriteActive(retained!), isTrue);

      const missingPrefix = MobjView(
        id: 92,
        x: 10 * kFracUnit,
        y: 20 * kFracUnit,
        z: 3 * kFracUnit,
        angle: 0,
        sprite: 'NOPE',
        frame: 0,
        flags: 0,
        health: 1,
      );
      runtime.syncActorViewsForTest(const <MobjView>[missingPrefix]);
      expect(runtime.actorIds, isEmpty);
      expect(runtime.scene.isActorSpriteActive(retained), isFalse);

      runtime.syncActorViewsForTest(const <MobjView>[valid]);
      expect(runtime.actorComponentForTest(92), same(retained));
      expect(runtime.scene.isActorSpriteActive(retained), isTrue);

      const missingFrame = MobjView(
        id: 92,
        x: 10 * kFracUnit,
        y: 20 * kFracUnit,
        z: 3 * kFracUnit,
        angle: 0,
        sprite: 'TEST',
        frame: 25,
        flags: 0,
        health: 1,
      );
      runtime.syncActorViewsForTest(const <MobjView>[missingFrame]);
      expect(runtime.actorIds, isEmpty);
      expect(runtime.scene.isActorSpriteActive(retained), isFalse);

      runtime.syncActorViewsForTest(const <MobjView>[valid]);
      expect(runtime.actorComponentForTest(92), same(retained));
      expect(runtime.scene.actorSurfaceRegistryCount, warmedRegistry);
    },
  );

  test('Doom actor yaw basis selects front, back and side buckets', () {
    final yaw = DoomRuntimeGame.worldActorYawForBam(0);
    expect(yaw, closeTo(math.pi / 2, 1e-12));
    expect(
      DoomSpriteCatalog.cameraRotation(
        actorAngle: yaw,
        actorX: 0,
        actorZ: 0,
        cameraX: 10,
        cameraZ: 0,
      ),
      1,
      reason: 'camera along the actor +X facing sees its front bucket',
    );
    expect(
      DoomSpriteCatalog.cameraRotation(
        actorAngle: yaw,
        actorX: 0,
        actorZ: 0,
        cameraX: -10,
        cameraZ: 0,
      ),
      5,
    );
    expect(
      DoomSpriteCatalog.cameraRotation(
        actorAngle: yaw,
        actorX: 0,
        actorZ: 0,
        cameraX: 0,
        cameraZ: 10,
      ),
      7,
    );
  });

  test(
    'sector light touches exact plane and near-wall retained ranges',
    () async {
      final prepared = await fixtureLevel();
      final scene = DoomScene.fromCompiledLevel(
        prepared.geometry,
        prepared.resources,
        sectorLights: <int>[
          for (final sector in prepared.map.sectors) sector.lightLevel,
        ],
      );
      for (final surface in scene.surfaces) {
        surface.resource;
      }
      final sector = prepared.geometry.floorPlanes.first.sector;
      final beforeBuffers = scene.diagnostics.gpuBuffersCreated;
      final expected =
          prepared.geometry.floorPlanes
              .where((plane) => plane.sector == sector)
              .fold<int>(0, (sum, plane) => sum + plane.vertexCount) +
          prepared.geometry.ceilingPlanes
              .where((plane) => plane.sector == sector)
              .fold<int>(0, (sum, plane) => sum + plane.vertexCount) +
          prepared.geometry.wallBands
                  .where((band) => band.frontSector == sector)
                  .length *
              geometry.WallBandRef.verticesPerQuad;

      expect(
        scene.updateSectorLight(sectorIndex: sector, lightLevel: 73),
        expected,
      );
      expect(scene.flushPendingUploads(), greaterThan(0));
      expect(scene.diagnostics.gpuBuffersCreated, beforeBuffers);
      expect(scene.updateSectorLight(sectorIndex: sector, lightLevel: 73), 0);
    },
  );

  test('level completion callback fires once and stops further tics', () async {
    var completions = 0;
    final runtime = DoomRuntimeGame(
      await fixtureExitLevel(),
      onLevelComplete: (_) => completions++,
    );
    runtime.input.triggerUse();
    runtime.advanceMicrosForTest(28572);

    expect(runtime.gameState.levelComplete, isTrue);
    expect(completions, 1);
    final completedAt = runtime.gameState.tic;
    runtime.advanceMicrosForTest(500000);
    expect(runtime.gameState.tic, completedAt);
    expect(completions, 1);
  });
}
