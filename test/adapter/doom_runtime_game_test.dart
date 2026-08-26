import 'dart:math' as math;
import 'dart:typed_data';

import 'package:doom_core/doom_core.dart';
import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:doom_wad/doom_wad.dart';
import 'package:doompeller/adapter/adapter.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_automap.dart';
import 'package:doompeller/game/doom_input.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:doompeller/game/sound_playback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;

import 'fake_gpu_backend.dart';

void expectRuntimeAtlasRect(
  geometry.CompiledLevel level,
  geometry.VertexRange range,
  geometry.AtlasEntry entry,
) {
  final List<double> expected = <double>[
    entry.u0(level.atlas.pageSize),
    entry.v0(level.atlas.pageSize),
    entry.u1(level.atlas.pageSize),
    entry.v1(level.atlas.pageSize),
  ];
  final vertices = level.meshes[range.meshIndex].vertices;
  for (
    var vertex = range.firstVertex;
    vertex < range.firstVertex + range.vertexCount;
    vertex++
  ) {
    final int offset =
        vertex * geometry.DoomVertexAbi.floatsPerVertex +
        geometry.DoomVertexAbi.atlasRectOffset;
    expect(
      vertices.sublist(offset, offset + expected.length),
      expected,
      reason: 'runtime mesh ${range.meshIndex} vertex $vertex atlas rect',
    );
  }
}

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
    gameConfig: const GameConfig(),
    seed: 3,
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
    gameConfig: const GameConfig(),
    seed: 0,
  );
}

Future<PreparedDoomLevel> fixtureSoundLevel() async {
  final base = await fixtureLevel();
  final source = base.map;
  final map = MapData(
    name: source.name,
    vertices: source.vertices,
    linedefs: source.linedefs,
    sidedefs: source.sidedefs,
    sectors: source.sectors,
    segs: source.segs,
    subsectors: source.subsectors,
    nodes: source.nodes,
    things: const <Thing>[
      Thing(x: 220, y: 128, angle: 0, type: 1, flags: 7),
      Thing(x: 180, y: 128, angle: 0, type: 3004, flags: 7),
    ],
    blockmap: source.blockmap,
    reject: source.reject,
  );
  return PreparedDoomLevel(
    content: base.content,
    resources: base.resources,
    map: map,
    geometry: base.geometry,
    gameConfig: const GameConfig(),
    seed: 3,
  );
}

Future<PreparedDoomLevel> fixtureAutomapRestartLevel() async {
  final base = await fixtureLevel();
  final source = base.map;
  final map = MapData(
    name: source.name,
    vertices: source.vertices,
    linedefs: source.linedefs,
    sidedefs: source.sidedefs,
    sectors: source.sectors,
    segs: source.segs,
    subsectors: source.subsectors,
    nodes: source.nodes,
    things: const <Thing>[Thing(x: 220, y: 128, angle: 0, type: 1, flags: 7)],
    blockmap: source.blockmap,
    reject: source.reject,
  );
  return PreparedDoomLevel(
    content: base.content,
    resources: base.resources,
    map: map,
    geometry: base.geometry,
    gameConfig: const GameConfig(monsters: false),
    seed: 3,
  );
}

Future<PreparedDoomLevel> fixtureVisualCombatLevel(List<Thing> things) async {
  final base = await fixtureLevel();
  final source = base.map;
  final map = MapData(
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
  );
  return PreparedDoomLevel(
    content: base.content,
    resources: base.resources,
    map: map,
    geometry: base.geometry,
    gameConfig: const GameConfig(monsters: false),
    seed: 3,
  );
}

Future<PreparedDoomLevel> fixtureFloorTransferLevel() async {
  final PreparedDoomLevel base = await fixtureLevel();
  final MapData source = base.map;
  final List<Linedef> linedefs = List<Linedef>.of(source.linedefs);
  final int triggerIndex = linedefs.indexWhere(
    (Linedef line) => line.special == LineSpecial.doorOpenWaitClose,
  );
  if (triggerIndex < 0) throw StateError('fixture manual door not found');
  final Linedef trigger = linedefs[triggerIndex];
  linedefs[triggerIndex] = Linedef(
    v1: trigger.v1,
    v2: trigger.v2,
    flags: trigger.flags,
    special: LineSpecial.switchFloorRaiseToNextHigherAndChangeOnce,
    tag: 7,
    rightSidedef: trigger.rightSidedef,
    leftSidedef: trigger.leftSidedef,
  );
  final List<Sector> sectors = List<Sector>.of(source.sectors);
  final Sector target = sectors[1];
  sectors[1] = Sector(
    floorHeight: target.floorHeight,
    ceilingHeight: target.ceilingHeight,
    floorFlat: target.floorFlat,
    ceilingFlat: target.ceilingFlat,
    lightLevel: target.lightLevel,
    special: target.special,
    tag: 7,
  );
  final MapData map = MapData(
    name: source.name,
    vertices: source.vertices,
    linedefs: linedefs,
    sidedefs: source.sidedefs,
    sectors: sectors,
    segs: source.segs,
    subsectors: source.subsectors,
    nodes: source.nodes,
    things: const <Thing>[Thing(x: 220, y: 128, angle: 0, type: 1, flags: 7)],
    blockmap: source.blockmap,
    reject: source.reject,
  );
  return PreparedDoomLevel(
    content: base.content,
    resources: base.resources,
    map: map,
    geometry: geometry.DoomGeometryCompiler.compile(map, base.resources),
    gameConfig: const GameConfig(monsters: false),
    seed: 3,
  );
}

Future<PreparedDoomLevel> fixtureDeathLevel() async {
  final base = await fixtureLevel();
  final source = base.map;
  final map = MapData(
    name: source.name,
    vertices: source.vertices,
    linedefs: source.linedefs,
    sidedefs: source.sidedefs,
    sectors: source.sectors,
    segs: source.segs,
    subsectors: source.subsectors,
    nodes: source.nodes,
    things: const <Thing>[
      Thing(x: 32, y: 64, angle: 180, type: 1, flags: 7),
      Thing(x: 72, y: 64, angle: 180, type: 3001, flags: 7),
      Thing(x: 76, y: 40, angle: 180, type: 3001, flags: 7),
      Thing(x: 76, y: 88, angle: 180, type: 3001, flags: 7),
    ],
    blockmap: source.blockmap,
    reject: source.reject,
  );
  return PreparedDoomLevel(
    content: base.content,
    resources: base.resources,
    map: map,
    geometry: base.geometry,
    gameConfig: const GameConfig(),
    seed: 3,
  );
}

Future<PreparedDoomLevel> fixtureLifecycleLevel() async {
  final base = await fixtureLevel();
  final source = base.map;
  final linedefs = List<Linedef>.of(source.linedefs);
  final int switchIndex = linedefs.indexWhere((line) {
    final a = source.vertices[line.v1];
    final b = source.vertices[line.v2];
    return line.leftSidedef == kNoSidedef &&
        a.y == 256 &&
        b.y == 256 &&
        math.min(a.x, b.x) == 0 &&
        math.max(a.x, b.x) == 256;
  });
  if (switchIndex < 0) throw StateError('fixture north wall not found');
  final oldSwitch = linedefs[switchIndex];
  linedefs[switchIndex] = Linedef(
    v1: oldSwitch.v1,
    v2: oldSwitch.v2,
    flags: oldSwitch.flags,
    special: LineSpecial.switchFloorRaiseToNextHigherOnce,
    tag: 7,
    rightSidedef: oldSwitch.rightSidedef,
    leftSidedef: oldSwitch.leftSidedef,
  );
  final sidedefs = List<Sidedef>.of(source.sidedefs);
  final oldSide = sidedefs[oldSwitch.rightSidedef];
  sidedefs[oldSwitch.rightSidedef] = Sidedef(
    xOffset: oldSide.xOffset,
    yOffset: oldSide.yOffset,
    upperTexture: oldSide.upperTexture,
    lowerTexture: oldSide.lowerTexture,
    middleTexture: 'SW1COMP',
    sector: oldSide.sector,
  );
  final sectors = List<Sector>.of(source.sectors);
  final oldSector = sectors[0];
  sectors[0] = Sector(
    floorHeight: oldSector.floorHeight,
    ceilingHeight: oldSector.ceilingHeight,
    floorFlat: oldSector.floorFlat,
    ceilingFlat: oldSector.ceilingFlat,
    lightLevel: oldSector.lightLevel,
    special: oldSector.special,
    tag: 7,
  );
  final map = MapData(
    name: source.name,
    vertices: source.vertices,
    linedefs: linedefs,
    sidedefs: sidedefs,
    sectors: sectors,
    segs: source.segs,
    subsectors: source.subsectors,
    nodes: source.nodes,
    things: const <Thing>[
      Thing(x: 220, y: 220, angle: 0, type: 1, flags: 7),
      Thing(x: 220, y: 220, angle: 0, type: 2014, flags: 7),
      Thing(x: 220, y: 240, angle: 270, type: 3004, flags: 7),
      Thing(x: 160, y: 220, angle: 0, type: 3001, flags: 7),
      Thing(x: 220, y: 160, angle: 90, type: 3001, flags: 7),
      Thing(x: 160, y: 160, angle: 45, type: 3001, flags: 7),
    ],
    blockmap: source.blockmap,
    reject: source.reject,
  );
  return PreparedDoomLevel(
    content: base.content,
    resources: base.resources,
    map: map,
    geometry: geometry.DoomGeometryCompiler.compile(map, base.resources),
    gameConfig: const GameConfig(),
    seed: 3,
  );
}

void advanceUntilDead(DoomRuntimeGame runtime) {
  for (var tic = 0; tic < 2500 && runtime.gameState.player.health > 0; tic++) {
    runtime.advanceMicrosForTest(28572);
  }
  expect(runtime.gameState.player.health, 0);
}

void warmActiveBuffers(DoomRuntimeGame runtime) {
  for (final surface in runtime.scene.surfaces) {
    surface.resource;
  }
}

void exerciseLifecycle(DoomRuntimeGame runtime) {
  expect(runtime.gameState.player.health, 100);
  expect(runtime.gameState.itemCount, 0);
  final int initialDoorCeiling = runtime.gameState.sectors
      .elementAt(1)
      .ceilingHeight;
  final int initialFloor = runtime.gameState.sectors.first.floorHeight;

  runtime.input.triggerUse();
  runtime.advanceMicrosForTest(28572);
  runtime.advanceMicrosForTest(28572);
  expect(
    runtime.gameState.sectors.elementAt(1).ceilingHeight,
    greaterThan(initialDoorCeiling),
  );
  expect(runtime.gameState.itemCount, 1);

  runtime.input
    ..addPointerTurn(0x4000)
    ..triggerUse();
  runtime.advanceMicrosForTest(28572);
  runtime.advanceMicrosForTest(28572);
  expect(
    runtime.gameState.sectors.first.floorHeight,
    greaterThan(initialFloor),
  );

  runtime.toggleAutomap();
  runtime.zoomAutomap(inwards: true);
  expect(runtime.automap.value.isOpen, isTrue);
  expect(runtime.automap.value.zoom, greaterThan(DoomAutomapState.initialZoom));

  runtime.input.press(DoomControl.attack);
  for (
    var tic = 0;
    tic < 100 &&
        runtime.gameState.killCount == 0 &&
        runtime.gameState.player.health > 0;
    tic++
  ) {
    runtime.advanceMicrosForTest(28572);
  }
  runtime.input.release(DoomControl.attack);
  expect(runtime.gameState.killCount, greaterThanOrEqualTo(1));
  advanceUntilDead(runtime);
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

  test('production runtime advances packed texture animation frames', () async {
    final PreparedDoomLevel prepared = await fixtureLevel();
    final runtime = DoomRuntimeGame(prepared);
    final geometry.AnimatedSurfaceRef animation =
        prepared.geometry.animations.first;

    for (var tic = 0; tic < animation.speed; tic++) {
      runtime.advanceMicrosForTest(28572);
    }

    expect(runtime.gameState.levelTime, greaterThanOrEqualTo(animation.speed));
    final geometry.AtlasEntry expected =
        animation.frames[animation.frameAt(runtime.gameState.levelTime)];
    for (final geometry.VertexRange range in animation.ranges) {
      expectRuntimeAtlasRect(prepared.geometry, range, expected);
    }
  });

  test(
    'production runtime uploads a floor-flat transfer to the GPU buffer',
    () async {
      final FakeGpuBackend backend = FakeGpuBackend();
      final PreparedDoomLevel prepared = await fixtureFloorTransferLevel();
      final DoomRuntimeGame runtime = DoomRuntimeGame(prepared);
      final geometry.SectorPlaneRef target = prepared.geometry.floorPlanes
          .firstWhere((geometry.SectorPlaneRef plane) => plane.sector == 1);
      final geometry.AtlasEntry replacement = prepared.geometry.atlas.entry(
        'NUKAGE1',
      )!;
      expect(target.textureName, 'FLAT1');
      for (final surface in runtime.scene.surfaces) {
        surface.resource;
      }
      final List<int> writesBefore = <int>[
        for (final FakeGpuBuffer buffer in backend.buffers) buffer.writeCount,
      ];

      runtime.input.triggerUse();
      runtime.advanceMicrosForTest(28572);

      expect(runtime.gameState.sectors.elementAt(1).floorFlat, 'NUKAGE1');
      expect(target.textureName, 'NUKAGE1');
      for (final geometry.VertexRange range in target.ranges) {
        expectRuntimeAtlasRect(prepared.geometry, range, replacement);
      }
      expect(runtime.scene.flushPendingUploads(), greaterThan(0));
      for (final geometry.VertexRange range in target.ranges) {
        final FakeGpuBuffer buffer = backend.buffers[range.meshIndex];
        expect(buffer.writeCount, greaterThan(writesBefore[range.meshIndex]));
        for (
          var vertex = range.firstVertex;
          vertex < range.firstVertex + range.vertexCount;
          vertex++
        ) {
          final int byteOffset =
              DoomVertexAbi.byteOffsetOf(vertex) +
              geometry.DoomVertexAbi.atlasRectOffset *
                  Float32List.bytesPerElement;
          expect(
            <double>[
              for (var component = 0; component < 4; component++)
                buffer.floatAt(
                  byteOffset + component * Float32List.bytesPerElement,
                ),
            ],
            <double>[
              replacement.u0(prepared.geometry.atlas.pageSize),
              replacement.v0(prepared.geometry.atlas.pageSize),
              replacement.u1(prepared.geometry.atlas.pageSize),
              replacement.v1(prepared.geometry.atlas.pageSize),
            ],
          );
        }
      }
    },
  );

  test('runtime routes fire, door, and death journals to backend', () async {
    final FakeAudioBackend backend = FakeAudioBackend();
    final runtime = DoomRuntimeGame(
      await fixtureSoundLevel(),
      audioBackend: backend,
    );

    runtime.input.triggerUse();
    runtime.advanceMicrosForTest(28572);
    runtime.input.addPointerTurn(0x8000);
    runtime.input.press(DoomControl.attack);
    for (var i = 0; i < 20; i++) {
      runtime.advanceMicrosForTest(28572);
    }
    runtime.input.release(DoomControl.attack);
    await runtime.soundPlaybackIdleForTest;

    final List<String> sounds = <String>[
      for (final call in backend.playCalls) call.soundId,
    ];
    expect(sounds, contains('DSDOROPN'));
    expect(sounds, contains('DSPISTOL'));
    expect(runtime.gameState.soundJournal, isEmpty);
    expect(
      backend.playCalls
          .where((call) => call.soundId == 'DSDOROPN')
          .single
          .volume,
      closeTo(1 - 36 / 1200, 1e-12),
      reason: 'listener PlayerView fixed-point coordinates become map units',
    );
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

  test('restart clears automap fog, zoom, and open state', () async {
    final prepared = await fixtureAutomapRestartLevel();
    final runtime = DoomRuntimeGame(prepared);
    final Set<int> initiallyMapped = <int>{
      for (var index = 0; index < prepared.map.linedefs.length; index++)
        if ((prepared.map.linedefs[index].flags & LinedefFlags.mapped) != 0)
          index,
    };

    runtime.input.triggerUse();
    for (var tic = 0; tic < 50; tic++) {
      runtime.advanceMicrosForTest(28572);
    }
    runtime.input.press(DoomControl.forward);
    for (var tic = 0; tic < 20; tic++) {
      runtime.advanceMicrosForTest(28572);
    }
    runtime.input.release(DoomControl.forward);
    expect(runtime.gameState.playerSectorIndex, 1);
    expect(
      runtime.automap.value.visitedLines.length,
      greaterThan(initiallyMapped.length),
    );

    runtime.toggleAutomap();
    runtime.zoomAutomap(inwards: true);
    expect(runtime.automap.value.isOpen, isTrue);
    expect(
      runtime.automap.value.zoom,
      greaterThan(DoomAutomapState.initialZoom),
    );

    runtime.restartLevel();

    expect(runtime.automap.value.isOpen, isFalse);
    expect(runtime.automap.value.zoom, DoomAutomapState.initialZoom);
    expect(runtime.automap.value.visitedLines, initiallyMapped);
  });

  test(
    'Shift runs, coexists with automap zoom, and focus loss clears it',
    () async {
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
          physicalKey: PhysicalKeyboardKey.shiftLeft,
          logicalKey: LogicalKeyboardKey.shiftLeft,
          timeStamp: Duration.zero,
        ),
        <LogicalKeyboardKey>{
          LogicalKeyboardKey.keyW,
          LogicalKeyboardKey.shiftLeft,
        },
      );
      runtime.onKeyEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyD,
          logicalKey: LogicalKeyboardKey.keyD,
          timeStamp: Duration.zero,
        ),
        <LogicalKeyboardKey>{
          LogicalKeyboardKey.keyW,
          LogicalKeyboardKey.keyD,
          LogicalKeyboardKey.shiftLeft,
        },
      );
      runtime.onKeyEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.equal,
          logicalKey: LogicalKeyboardKey.add,
          timeStamp: Duration.zero,
        ),
        <LogicalKeyboardKey>{
          LogicalKeyboardKey.keyW,
          LogicalKeyboardKey.keyD,
          LogicalKeyboardKey.shiftLeft,
          LogicalKeyboardKey.add,
        },
      );
      final running = runtime.input.consume().command;
      expect(running.forwardMove, DoomInputState.runMoveSpeed);
      expect(running.sideMove, DoomInputState.runStrafeSpeed);
      expect(
        runtime.automap.value.zoom,
        greaterThan(DoomAutomapState.initialZoom),
      );

      runtime.onKeyEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.shiftRight,
          logicalKey: LogicalKeyboardKey.shiftRight,
          timeStamp: Duration.zero,
        ),
        <LogicalKeyboardKey>{
          LogicalKeyboardKey.keyW,
          LogicalKeyboardKey.keyD,
          LogicalKeyboardKey.shiftLeft,
          LogicalKeyboardKey.shiftRight,
        },
      );
      runtime.onKeyEvent(
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.shiftLeft,
          logicalKey: LogicalKeyboardKey.shiftLeft,
          timeStamp: Duration.zero,
        ),
        <LogicalKeyboardKey>{
          LogicalKeyboardKey.keyW,
          LogicalKeyboardKey.keyD,
          LogicalKeyboardKey.shiftRight,
        },
      );
      expect(
        runtime.input.consume().command.forwardMove,
        DoomInputState.runMoveSpeed,
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
    },
  );

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
    expect(runtime.actorComponentForTest(90)?.lumpName, 'TESTB0');

    runtime.syncActorViewsForTest(const <MobjView>[]);
    expect(runtime.actorIds, isEmpty);
  });

  test(
    'production ticks carry actor frames into the retained sprite',
    () async {
      final runtime = DoomRuntimeGame(await fixtureLevel());
      final MobjView zombie = runtime.gameState.mobjs.firstWhere(
        (MobjView actor) => actor.sprite == 'POSS',
      );
      expect(runtime.actorComponentForTest(zombie.id)?.lumpName, 'POSSA0');

      for (var step = 0; step < 12; step++) {
        runtime.advanceMicrosForTest(28572);
      }

      final MobjView animated = runtime.gameState.mobjs.firstWhere(
        (MobjView actor) => actor.id == zombie.id,
      );
      final String frameLetter = String.fromCharCode(65 + animated.frame);
      expect(animated.frame, isNot(0));
      expect(
        runtime.actorComponentForTest(zombie.id)?.lumpName,
        'POSS${frameLetter}0',
      );
    },
  );

  test(
    'runtime preserves actor light and fullbright into vertex params',
    () async {
      final runtime = DoomRuntimeGame(await fixtureLevel());
      const actor = MobjView(
        id: 93,
        x: 10 * kFracUnit,
        y: 20 * kFracUnit,
        z: 3 * kFracUnit,
        angle: 0,
        sprite: 'BAL1',
        frame: 0,
        flags: 0,
        health: 1,
        lightLevel: 16,
        fullBright: true,
      );
      runtime.syncActorViewsForTest(const <MobjView>[actor]);
      final component = runtime.actorComponentForTest(93)!;
      expect(component.light, closeTo(16 / 255, 1e-12));
      expect(component.fullBright, isTrue);
      expect(
        component.surface.packedVertices[geometry.DoomVertexAbi.paramsOffset],
        1,
      );
    },
  );

  test(
    'runtime marks shadow actors for the shader fuzz approximation',
    () async {
      final runtime = DoomRuntimeGame(await fixtureLevel());
      const actor = MobjView(
        id: 94,
        x: 10 * kFracUnit,
        y: 20 * kFracUnit,
        z: 3 * kFracUnit,
        angle: 0,
        sprite: 'SARG',
        frame: 0,
        flags: MobjFlags.shadow,
        health: 150,
      );
      runtime.syncActorViewsForTest(const <MobjView>[actor]);
      final component = runtime.actorComponentForTest(94)!;
      expect(component.fuzz, isTrue);
      expect(
        component.surface.packedVertices[geometry.DoomVertexAbi.colorOffset +
            3],
        0.5,
      );
    },
  );

  test(
    'production firing syncs body, flash, puff and blood lifecycles',
    () async {
      final bloodRuntime = DoomRuntimeGame(
        await fixtureVisualCombatLevel(const <Thing>[
          Thing(x: 128, y: 128, angle: 0, type: 1, flags: 7),
          Thing(x: 192, y: 128, angle: 180, type: 3004, flags: 7),
        ]),
      );
      expect(bloodRuntime.weaponFrame, 'PISGA0');
      bloodRuntime.input.press(DoomControl.attack);
      bloodRuntime.advanceMicrosForTest(28572);
      expect(bloodRuntime.weaponFrame, 'PISGA0');
      expect(bloodRuntime.weaponFlashVisible, isFalse);
      expect(
        bloodRuntime.gameState.mobjs.where(
          (MobjView actor) => actor.sprite == 'BLUD',
        ),
        isEmpty,
      );
      for (var tic = 0; tic < 4; tic++) {
        bloodRuntime.advanceMicrosForTest(28572);
      }
      expect(bloodRuntime.weaponFrame, 'PISGB0');
      expect(bloodRuntime.weaponFlashFrame, 'PISFA0');
      expect(bloodRuntime.weaponFlashVisible, isTrue);
      final int bloodId = bloodRuntime.gameState.mobjs
          .firstWhere((MobjView actor) => actor.sprite == 'BLUD')
          .id;
      expect(bloodRuntime.actorComponentForTest(bloodId), isNotNull);

      bloodRuntime.input.release(DoomControl.attack);
      for (var tic = 0; tic < 6; tic++) {
        bloodRuntime.advanceMicrosForTest(28572);
        expect(bloodRuntime.weaponFlashVisible, isTrue);
      }
      bloodRuntime.advanceMicrosForTest(28572);
      expect(bloodRuntime.weaponFlashVisible, isFalse);
      for (var tic = 0; tic < 30; tic++) {
        bloodRuntime.advanceMicrosForTest(28572);
      }
      expect(bloodRuntime.actorComponentForTest(bloodId), isNull);

      final puffRuntime = DoomRuntimeGame(
        await fixtureVisualCombatLevel(const <Thing>[
          Thing(x: 220, y: 128, angle: 0, type: 1, flags: 7),
        ]),
      );
      puffRuntime.input.press(DoomControl.attack);
      for (var tic = 0; tic < 5; tic++) {
        puffRuntime.advanceMicrosForTest(28572);
      }
      final int puffId = puffRuntime.gameState.mobjs
          .firstWhere((MobjView actor) => actor.sprite == 'PUFF')
          .id;
      expect(puffRuntime.actorComponentForTest(puffId), isNotNull);
      puffRuntime.input.release(DoomControl.attack);
      for (var tic = 0; tic < 20; tic++) {
        puffRuntime.advanceMicrosForTest(28572);
      }
      expect(puffRuntime.actorComponentForTest(puffId), isNull);
    },
  );

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
    final initialHash = runtime.gameState.hashState();
    runtime.input.triggerUse();
    runtime.advanceMicrosForTest(28572);

    expect(runtime.gameState.levelComplete, isTrue);
    expect(completions, 1);
    final completedAt = runtime.gameState.tic;
    runtime.advanceMicrosForTest(500000);
    expect(runtime.gameState.tic, completedAt);
    expect(completions, 1);

    runtime.restartLevel();
    expect(runtime.gameState.levelComplete, isFalse);
    expect(runtime.gameState.player.health, 100);
    expect(runtime.gameState.hashState(), initialHash);
  });

  test(
    'restart restores simulation, geometry, hash, and clears input',
    () async {
      final prepared = await fixtureDeathLevel();
      final runtime = DoomRuntimeGame(prepared);
      final initialHash = runtime.gameState.hashState();
      final initialPlayer = runtime.gameState.player;
      final initialActors = <(int, String, int, int, int)>[
        for (final actor in runtime.gameState.mobjs)
          (actor.id, actor.sprite, actor.x, actor.y, actor.health),
      ];
      final floor = prepared.geometry.floorPlanes.first;
      final initialFloor = floor.height;
      final switchBand = prepared.geometry.wallBands.firstWhere(
        (band) => band.textureName == 'SW1COMP',
      );
      final switched = prepared.geometry.atlas.entry('SW2COMP')!;
      runtime.scene.updateSectorPlane(
        sectorIndex: floor.sector,
        height: initialFloor + 24,
        isCeiling: false,
      );
      runtime.scene.updateSwitchTexture(
        SwitchTextureChange(
          linedef: switchBand.linedef,
          sidedef: switchBand.sidedef,
          slot: SwitchTextureSlot.middle,
          textureName: switched.name,
          tic: 1,
        ),
      );
      runtime.input
        ..press(DoomControl.forward)
        ..press(DoomControl.attack)
        ..triggerUse()
        ..addPointerTurn(1234);

      runtime.advanceMicrosForTest(28572);
      runtime.input
        ..release(DoomControl.forward)
        ..release(DoomControl.attack);
      advanceUntilDead(runtime);
      expect(runtime.gameState.hashState(), isNot(initialHash));
      runtime.input.triggerPause();

      runtime.restartLevel();

      expect(runtime.gameState.hashState(), initialHash);
      expect(runtime.gameState.player.health, 100);
      expect(runtime.gameState.player.x, initialPlayer.x);
      expect(runtime.gameState.player.y, initialPlayer.y);
      expect(runtime.gameState.player.angle, initialPlayer.angle);
      expect(<(int, String, int, int, int)>[
        for (final actor in runtime.gameState.mobjs)
          (actor.id, actor.sprite, actor.x, actor.y, actor.health),
      ], orderedEquals(initialActors));
      expect(floor.height, initialFloor);
      final rectOffset =
          switchBand.firstVertex * geometry.DoomVertexAbi.floatsPerVertex +
          geometry.DoomVertexAbi.atlasRectOffset;
      final original = prepared.geometry.atlas.entry('SW1COMP')!;
      expect(
        prepared.geometry.meshes[switchBand.meshIndex].vertices[rectOffset],
        original.u0(prepared.geometry.atlas.pageSize),
      );
      final input = runtime.input.consume().command;
      expect(input.forwardMove, 0);
      expect(input.sideMove, 0);
      expect(input.angleTurn, 0);
      expect(input.buttons, 0);
      expect(runtime.input.takePauseToggle(), isFalse);

      runtime.toggleAutomap();
      runtime.zoomAutomap(inwards: true);
      expect(runtime.automap.value.isOpen, isTrue);
      expect(runtime.automap.value.zoom, isNot(DoomAutomapState.initialZoom));
      runtime.restartLevel();
      expect(runtime.automap.value.isOpen, isFalse);
      expect(runtime.automap.value.zoom, DoomAutomapState.initialZoom);

      final fresh = DoomRuntimeGame(await fixtureDeathLevel());
      expect(runtime.gameState.hashState(), fresh.gameState.hashState());
    },
  );

  test(
    'diverse death restart cycles retain scene resources and notifier identities',
    () async {
      final prepared = await fixtureLifecycleLevel();
      final initialSpritePrefixes = prepared.initialSpritePrefixes;
      expect(
        initialSpritePrefixes,
        containsAll(<String>{'PLAY', 'BON1', 'POSS', 'TROO'}),
      );
      final runtime = DoomRuntimeGame(prepared);
      final hud = runtime.hud;
      final automap = runtime.automap;
      void hudListener() {}
      void automapListener() {}
      hud.addListener(hudListener);
      automap.addListener(automapListener);
      expect(runtime.hudListenerCountForTest, 1);
      expect(runtime.automapListenerCountForTest, 1);
      exerciseLifecycle(runtime);
      warmActiveBuffers(runtime);
      expect(
        runtime.onKeyEvent(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.controlLeft,
            logicalKey: LogicalKeyboardKey.controlLeft,
            timeStamp: Duration.zero,
          ),
          <LogicalKeyboardKey>{LogicalKeyboardKey.controlLeft},
        ),
        KeyEventResult.handled,
      );
      expect(runtime.gameState.player.health, 100);
      warmActiveBuffers(runtime);
      final initialHash = runtime.gameState.hashState();
      final registry = runtime.scene.actorSurfaceRegistryCount;
      final surfaces = runtime.scene.surfaceCount;
      final actors = runtime.actorComponentCount;
      final diagnostics = runtime.scene.diagnostics.snapshot();

      for (var cycle = 0; cycle < 30; cycle++) {
        exerciseLifecycle(runtime);
        warmActiveBuffers(runtime);
        runtime.restartLevel();
        warmActiveBuffers(runtime);
        expect(
          runtime.gameState.hashState(),
          initialHash,
          reason: 'cycle $cycle',
        );
        expect(runtime.hud, same(hud));
        expect(runtime.automap, same(automap));
        expect(runtime.hudListenerCountForTest, 1);
        expect(runtime.automapListenerCountForTest, 1);
        expect(runtime.scene.actorSurfaceRegistryCount, registry);
        expect(runtime.scene.surfaceCount, surfaces);
        expect(runtime.actorComponentCount, actors);
        final after = runtime.scene.diagnostics.snapshot();
        expect(after.surfacesCreated, diagnostics.surfacesCreated);
        expect(after.meshesBuilt, diagnostics.meshesBuilt);
        expect(after.componentsBuilt, diagnostics.componentsBuilt);
        expect(after.texturesCreated, diagnostics.texturesCreated);
        expect(after.gpuBuffersCreated, diagnostics.gpuBuffersCreated);
      }
      // ignore: avoid_print
      print(
        'lifecycle plateau after 30 cycles: '
        'surfaces=$surfaces, buffers=${diagnostics.gpuBuffersCreated}, '
        'components=${diagnostics.componentsBuilt}, actors=$actors, '
        'actorRegistry=$registry, hudListeners=1, automapListeners=1',
      );

      hud.removeListener(hudListener);
      automap.removeListener(automapListener);
      expect(runtime.hudListenerCountForTest, 0);
      expect(runtime.automapListenerCountForTest, 0);

      final secondRuntime = DoomRuntimeGame(prepared);
      expect(secondRuntime.gameState.player.health, 100);
      expect(secondRuntime.gameState.hashState(), initialHash);
      expect(prepared.initialSpritePrefixes, initialSpritePrefixes);
    },
  );
}
