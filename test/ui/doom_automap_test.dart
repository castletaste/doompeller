import 'package:doom_core/doom_core.dart' hide Key;
import 'package:doom_core/doom_core.dart' as core show Key;
import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:doom_wad/doom_wad.dart';
import 'package:doompeller/adapter/adapter.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_app_controller.dart';
import 'package:doompeller/game/doom_automap.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:doompeller/ui/doom_app.dart';
import 'package:doompeller/ui/doom_automap.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../adapter/fake_gpu_backend.dart';

const PlayerView _player = PlayerView(
  x: 0,
  y: 0,
  z: 0,
  angle: 0,
  viewZ: 0,
  health: 100,
  armor: 0,
  ammo: Ammo(bullets: 0, shells: 0),
  weapon: Weapon.pistol,
  bob: 0,
  keys: <core.Key>{},
);

MapData _map() => MapData(
  name: 'AUTOMAP',
  vertices: const <MapVertex>[
    MapVertex(0, 0),
    MapVertex(64, 0),
    MapVertex(128, 0),
    MapVertex(192, 0),
    MapVertex(256, 0),
    MapVertex(320, 0),
    MapVertex(384, 0),
    MapVertex(-10000, 100),
    MapVertex(2000, 100),
  ],
  linedefs: const <Linedef>[
    Linedef(
      v1: 0,
      v2: 1,
      flags: LinedefFlags.blocking,
      special: 0,
      tag: 0,
      rightSidedef: 0,
      leftSidedef: kNoSidedef,
    ),
    Linedef(
      v1: 1,
      v2: 2,
      flags: LinedefFlags.twoSided,
      special: 0,
      tag: 0,
      rightSidedef: 1,
      leftSidedef: 2,
    ),
    Linedef(
      v1: 2,
      v2: 3,
      flags: LinedefFlags.twoSided,
      special: 0,
      tag: 0,
      rightSidedef: 3,
      leftSidedef: 5,
    ),
    Linedef(
      v1: 3,
      v2: 4,
      flags: LinedefFlags.twoSided | LinedefFlags.secret,
      special: 0,
      tag: 0,
      rightSidedef: 3,
      leftSidedef: 4,
    ),
    Linedef(
      v1: 4,
      v2: 5,
      flags: LinedefFlags.blocking | LinedefFlags.dontDraw,
      special: 0,
      tag: 0,
      rightSidedef: 0,
      leftSidedef: kNoSidedef,
    ),
    Linedef(
      v1: 5,
      v2: 6,
      flags: LinedefFlags.blocking | LinedefFlags.mapped,
      special: 0,
      tag: 0,
      rightSidedef: 0,
      leftSidedef: kNoSidedef,
    ),
    Linedef(
      v1: 7,
      v2: 8,
      flags: LinedefFlags.blocking,
      special: 0,
      tag: 0,
      rightSidedef: 0,
      leftSidedef: kNoSidedef,
    ),
  ],
  sidedefs: const <Sidedef>[
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: 'WALL',
      sector: 0,
    ),
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: '-',
      sector: 0,
    ),
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: '-',
      sector: 1,
    ),
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: '-',
      sector: 0,
    ),
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: '-',
      sector: 2,
    ),
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: '-',
      sector: 3,
    ),
  ],
  sectors: const <Sector>[
    Sector(
      floorHeight: 0,
      ceilingHeight: 128,
      floorFlat: 'FLOOR',
      ceilingFlat: 'CEIL',
      lightLevel: 160,
      special: 0,
      tag: 0,
    ),
    Sector(
      floorHeight: 24,
      ceilingHeight: 128,
      floorFlat: 'FLOOR',
      ceilingFlat: 'CEIL',
      lightLevel: 160,
      special: 0,
      tag: 0,
    ),
    Sector(
      floorHeight: 24,
      ceilingHeight: 96,
      floorFlat: 'FLOOR',
      ceilingFlat: 'CEIL',
      lightLevel: 160,
      special: 0,
      tag: 0,
    ),
    Sector(
      floorHeight: 0,
      ceilingHeight: 96,
      floorFlat: 'FLOOR',
      ceilingFlat: 'CEIL',
      lightLevel: 160,
      special: 0,
      tag: 0,
    ),
  ],
  segs: const <Seg>[],
  subsectors: const <Subsector>[],
  nodes: const <BspNode>[],
  things: const <Thing>[],
  blockmap: null,
  reject: null,
);

MapData _mapWithSpecial(MapData map, int lineIndex, int special) => MapData(
  name: map.name,
  vertices: map.vertices,
  linedefs: <Linedef>[
    for (var index = 0; index < map.linedefs.length; index++)
      if (index == lineIndex)
        Linedef(
          v1: map.linedefs[index].v1,
          v2: map.linedefs[index].v2,
          flags: map.linedefs[index].flags,
          special: special,
          tag: map.linedefs[index].tag,
          rightSidedef: map.linedefs[index].rightSidedef,
          leftSidedef: map.linedefs[index].leftSidedef,
        )
      else
        map.linedefs[index],
  ],
  sidedefs: map.sidedefs,
  sectors: map.sectors,
  segs: map.segs,
  subsectors: map.subsectors,
  nodes: map.nodes,
  things: map.things,
  blockmap: map.blockmap,
  reject: map.reject,
);

DoomAutomapSnapshot _snapshot(
  MapData map, {
  Set<int> visited = const <int>{},
}) => DoomAutomapSnapshot(
  isOpen: false,
  zoom: DoomAutomapState.initialZoom,
  playerX: 0,
  playerY: 0,
  playerAngle: 0,
  visitedLines: visited,
  sectorFloors: <double>[
    for (final sector in map.sectors) sector.floorHeight.toDouble(),
  ],
  sectorCeilings: <double>[
    for (final sector in map.sectors) sector.ceilingHeight.toDouble(),
  ],
);

Future<PreparedDoomLevel> _fixtureLevel() async {
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
    game: GameState.start(map, const GameConfig()),
  );
}

/// A render-free GameWidget surface that exercises Flame's real keyboard focus
/// path while delegating input to the production runtime.
final class _AutomapKeyGame extends FlameGame with KeyboardEvents {
  _AutomapKeyGame(this.runtime);

  final DoomRuntimeGame runtime;

  @override
  KeyEventResult onKeyEvent(
    KeyEvent event,
    Set<LogicalKeyboardKey> keysPressed,
  ) => runtime.onKeyEvent(event, keysPressed);
}

void main() {
  test('painter classifies one-sided and height-transition lines', () {
    final map = _map();
    final snapshot = _snapshot(map);

    expect(
      DoomAutomapPainter.colorForLine(map, snapshot, 0),
      DoomAutomapPainter.oneSidedColor,
    );
    expect(
      DoomAutomapPainter.colorForLine(map, snapshot, 1),
      DoomAutomapPainter.floorStepColor,
    );
    expect(
      DoomAutomapPainter.colorForLine(map, snapshot, 2),
      DoomAutomapPainter.ceilingStepColor,
    );
    expect(
      DoomAutomapPainter.colorForLine(map, snapshot, 3),
      DoomAutomapPainter.oneSidedColor,
      reason: 'a two-sided secret hides its floor and ceiling transitions',
    );
    expect(DoomAutomapPainter.colorForLine(map, snapshot, 4), isNull);
  });

  test(
    'painter classifies a two-sided teleporter before height transitions',
    () {
      final map = _mapWithSpecial(_map(), 1, 39);

      expect(
        DoomAutomapPainter.colorForLine(map, _snapshot(map), 1),
        DoomAutomapPainter.teleporterColor,
      );
    },
  );

  test('fog hides an unvisited line and reveals touching sector lines', () {
    final map = _map();
    final automap = DoomAutomapState(map, _player);
    addTearDown(automap.dispose);

    expect(
      DoomAutomapPainter(
        map: map,
        snapshot: automap.value,
      ).visibleLineIndices(),
      contains(5),
      reason: 'map-authored mapped lines are visible before a sector visit',
    );

    automap.updatePlayer(_player, sectorIndex: 0);
    expect(
      DoomAutomapPainter(
        map: map,
        snapshot: automap.value,
      ).visibleLineIndices(),
      containsAll(<int>[0, 1, 2, 3, 5]),
    );
    expect(automap.value.visitedLines, contains(3));
    expect(
      DoomAutomapPainter(
        map: map,
        snapshot: automap.value,
      ).visibleLineIndices(),
      contains(3),
      reason: 'secret lines remain a visible ordinary wall',
    );
    expect(
      automap.value.visitedLines,
      contains(6),
      reason: 'a long boundary is discovered by its nearest segment point',
    );
  });

  test('current runtime heights, not loaded map heights, determine colour', () {
    final map = _map();
    final automap = DoomAutomapState(map, _player);
    addTearDown(automap.dispose);

    automap.updateSectorHeights(
      sectorIndex: 1,
      floorHeight: 0,
      ceilingHeight: 128,
    );
    expect(DoomAutomapPainter.colorForLine(map, automap.value, 1), isNull);

    automap.updateSectorHeights(
      sectorIndex: 1,
      floorHeight: 0,
      ceilingHeight: 96,
    );
    expect(
      DoomAutomapPainter.colorForLine(map, automap.value, 1),
      DoomAutomapPainter.ceilingStepColor,
    );
  });

  test('fixed player position converts to map units before projection', () {
    final map = _map();
    const player = PlayerView(
      x: 512 << 16,
      y: 384 << 16,
      z: 0,
      angle: 0,
      viewZ: 0,
      health: 100,
      armor: 0,
      ammo: Ammo(bullets: 0, shells: 0),
      weapon: Weapon.pistol,
      bob: 0,
      keys: <core.Key>{},
    );
    final automap = DoomAutomapState(map, _player);
    addTearDown(automap.dispose);
    automap.updatePlayer(player, sectorIndex: 0);
    final painter = DoomAutomapPainter(map: map, snapshot: automap.value);
    final point = painter.projectVertex(
      const MapVertex(576, 416),
      const Offset(400, 300),
      0.5,
    );
    expect(point.dx, closeTo(432, 0.001));
    expect(point.dy, closeTo(284, 0.001));
  });

  test('discovery measures distance to a line segment, not its vertices', () {
    final map = _map();
    final automap = DoomAutomapState(map, _player);
    addTearDown(automap.dispose);

    automap.updatePlayer(_player, sectorIndex: 0);

    expect(
      automap.value.visitedLines,
      contains(6),
      reason:
          'the segment passes 100 units away, while its endpoints and midpoint '
          'are farther than the 1536-unit discovery radius',
    );
  });

  test(
    'fixture start room reveals every touching wall within the discovery radius',
    () {
      final map = MapData.load(DoomFixtures.wadSet(), DoomFixtures.mapName);
      const player = PlayerView(
        x: 128 << 16,
        y: 128 << 16,
        z: 0,
        angle: 0,
        viewZ: 0,
        health: 100,
        armor: 0,
        ammo: Ammo(bullets: 0, shells: 0),
        weapon: Weapon.pistol,
        bob: 0,
        keys: <core.Key>{},
      );
      final automap = DoomAutomapState(map, player);
      addTearDown(automap.dispose);

      automap.updatePlayer(player, sectorIndex: 0);
      final touching = <int>{
        for (var index = 0; index < map.linedefs.length; index++)
          if (map.sidedefs[map.linedefs[index].rightSidedef].sector == 0 ||
              (map.linedefs[index].leftSidedef != kNoSidedef &&
                  map.sidedefs[map.linedefs[index].leftSidedef].sector == 0))
            index,
      };
      expect(automap.value.visitedLines, containsAll(touching));
    },
  );

  test('same-sector idle ticks avoid discovery scans and publications', () {
    final automap = DoomAutomapState(_map(), _player);
    addTearDown(automap.dispose);
    automap.updatePlayer(_player, sectorIndex: 0);
    final scans = automap.discoveryScanCount;
    final publications = automap.publicationCount;

    for (var i = 0; i < 100; i++) {
      automap.updatePlayer(_player, sectorIndex: 0);
    }
    expect(automap.discoveryScanCount, scans);
    expect(automap.publicationCount, publications);
  });

  test('zoom is bounded at both ends', () {
    final automap = DoomAutomapState(_map(), _player);
    addTearDown(automap.dispose);

    for (var i = 0; i < 50; i++) {
      automap.zoomIn();
    }
    expect(automap.value.zoom, DoomAutomapState.maxZoom);
    for (var i = 0; i < 100; i++) {
      automap.zoomOut();
    }
    expect(automap.value.zoom, DoomAutomapState.minZoom);
  });

  test('painter does not repaint for an unchanged snapshot', () {
    final map = _map();
    final snapshot = _snapshot(map);
    expect(
      DoomAutomapPainter(
        map: map,
        snapshot: snapshot,
      ).shouldRepaint(DoomAutomapPainter(map: map, snapshot: snapshot)),
      isFalse,
    );
  });

  testWidgets('overlay is a Flutter CustomPaint layer, not a 3D surface', (
    tester,
  ) async {
    final automap = DoomAutomapState(_map(), _player)..toggle();
    addTearDown(automap.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DoomAutomapOverlay(map: _map(), snapshot: automap.value),
        ),
      ),
    );

    expect(find.byKey(const Key('doom-automap')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('doom-automap')),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Tab reaches the focused live GameWidget and keeps game focus', (
    tester,
  ) async {
    FakeGpuBackend();
    final level = await _fixtureLevel();
    final runtime = DoomRuntimeGame(level);
    final surfaceFocusNode = FocusNode(debugLabel: 'Automap test surface');
    final keyGame = _AutomapKeyGame(runtime);
    final controller = DoomAppController(
      initialState: DoomAppState.ready(level, phase: DoomAppPhase.fixtureReady),
    );
    addTearDown(() {
      surfaceFocusNode.dispose();
      controller.dispose();
    });

    await tester.pumpWidget(
      DoomApp(
        controller: controller,
        autoStart: false,
        runtimeFactory: (_) => runtime,
        gameSurfaceBuilder: (_, _) => GameWidget<_AutomapKeyGame>(
          key: const Key('doom-game-widget'),
          game: keyGame,
          focusNode: surfaceFocusNode,
          backgroundBuilder: (_) => const ColoredBox(color: Colors.black),
        ),
      ),
    );
    await tester.pump();

    final gameWidget = tester.widget<GameWidget<_AutomapKeyGame>>(
      find.byKey(const Key('doom-game-widget')),
    );
    final focusNode = gameWidget.focusNode!;
    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasPrimaryFocus, isTrue);

    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(handled, isTrue);
    expect(runtime.automap.value.isOpen, isTrue);
    expect(find.byKey(const Key('doom-automap')), findsOneWidget);
    expect(focusNode.hasPrimaryFocus, isTrue);
  });
}
