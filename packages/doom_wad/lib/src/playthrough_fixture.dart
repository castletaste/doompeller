import 'fixtures.dart';
import 'map_model.dart';
import 'wad.dart';
import 'wad_builder.dart';

/// A compact, legally clean level used for end-to-end gameplay replays.
///
/// The route deliberately forces a return trip: the player reaches the locked
/// east door before the blue key, clears the guarded room behind the start, collects
/// its secret, returns to open the door, rides the lift, and uses the exit.
/// Geometry is kept independent of [DoomFixtures], so adding this map cannot
/// move the pinned MAP01 PWAD bytes.
abstract final class DoomPlaythroughFixture {
  static const String mapName = 'MAP97';
  static const int liftSector = 4;
  static WadFile? _spriteOverlay;

  /// Base synthetic resources plus the generated blue-key sprite used here.
  /// The overlay is separate so the byte-pinned [DoomFixtures] PWAD is stable.
  static WadSet resourceWads() => WadSet(<WadFile>[
    DoomFixtures.wad(),
    _spriteOverlay ??= WadFile.parse(
      buildWad(<LumpSource>[
        LumpSource.marker('S_START'),
        LumpSource('BKEYA0', encodeDoomPatch(buildFixtureSprite('BKEYA0'))),
        LumpSource.marker('S_END'),
      ]),
    ),
  ]);

  static MapData map() {
    final _PlaythroughMapBuilder builder = _PlaythroughMapBuilder();

    // 0: start corridor, 1: guarded key room behind the start,
    // 2: closed blue door, 3: lift approach, 4: lift, 5: exit room.
    builder
      ..sector()
      ..sector(special: 9)
      ..sector(ceilingHeight: 0)
      ..sector()
      ..sector(floorHeight: 32, tag: 7)
      ..sector(floorHeight: 32);

    // Outer walls, clockwise so each right/front side faces its sector.
    builder
      ..wall(0, 0, 128, 512, 128)
      ..wall(0, 512, 0, 0, 0)
      ..wall(1, -256, 0, -256, 128)
      ..wall(1, -256, 128, 0, 128)
      ..wall(1, 0, 0, -256, 0)
      ..wall(2, 512, 0, 544, 0)
      ..wall(2, 544, 128, 512, 128)
      ..wall(3, 544, 0, 768, 0)
      ..wall(3, 768, 128, 544, 128)
      ..wall(4, 768, 0, 896, 0)
      ..wall(4, 896, 128, 768, 128)
      ..wall(5, 896, 0, 1152, 0)
      ..wall(5, 1152, 128, 896, 128)
      ..wall(5, 1152, 128, 1152, 0, special: 11, texture: 'SW1COMP');

    // Shared openings. The blue door is a 32-unit slab whose ceiling starts
    // closed. The lift's west portal is its tag-0 use switch.
    builder
      ..portal(0, 0, 0, 128, front: 0, back: 1)
      ..portal(512, 128, 512, 0, front: 0, back: 2, special: 32)
      ..portal(544, 128, 544, 0, front: 2, back: 3)
      ..portal(768, 128, 768, 0, front: 3, back: 4, special: 21)
      ..portal(896, 128, 896, 0, front: 4, back: 5);

    const int allSkills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;
    builder
      ..thing(64, 64, 0, 1, allSkills)
      ..thing(-72, 64, 0, 3004, allSkills)
      ..thing(-136, 64, 0, 3004, allSkills)
      ..thing(-208, 64, 0, 5, allSkills)
      ..thing(-224, 64, 0, 2014, allSkills);

    return MapData(
      name: mapName,
      vertices: builder.vertices,
      linedefs: builder.linedefs,
      sidedefs: builder.sidedefs,
      sectors: builder.sectors,
      segs: const <Seg>[],
      subsectors: const <Subsector>[],
      nodes: const <BspNode>[],
      things: builder.things,
      blockmap: null,
      reject: null,
    );
  }
}

final class _PlaythroughMapBuilder {
  final List<MapVertex> vertices = <MapVertex>[];
  final List<Linedef> linedefs = <Linedef>[];
  final List<Sidedef> sidedefs = <Sidedef>[];
  final List<Sector> sectors = <Sector>[];
  final List<Thing> things = <Thing>[];
  final Map<(int, int), int> _vertexIndices = <(int, int), int>{};

  void sector({
    int floorHeight = 0,
    int ceilingHeight = 128,
    int special = 0,
    int tag = 0,
  }) {
    sectors.add(
      Sector(
        floorHeight: floorHeight,
        ceilingHeight: ceilingHeight,
        floorFlat: 'FLOOR0',
        ceilingFlat: 'CEIL0',
        lightLevel: 176,
        special: special,
        tag: tag,
      ),
    );
  }

  void thing(int x, int y, int angle, int type, int flags) {
    things.add(Thing(x: x, y: y, angle: angle, type: type, flags: flags));
  }

  void wall(
    int sector,
    int x1,
    int y1,
    int x2,
    int y2, {
    int special = 0,
    String texture = 'WALL1',
  }) {
    final int side = _side(sector, middle: texture);
    linedefs.add(
      Linedef(
        v1: _vertex(x1, y1),
        v2: _vertex(x2, y2),
        flags: LinedefFlags.blocking,
        special: special,
        tag: 0,
        rightSidedef: side,
        leftSidedef: kNoSidedef,
      ),
    );
  }

  void portal(
    int x1,
    int y1,
    int x2,
    int y2, {
    required int front,
    required int back,
    int special = 0,
  }) {
    linedefs.add(
      Linedef(
        v1: _vertex(x1, y1),
        v2: _vertex(x2, y2),
        flags: LinedefFlags.twoSided,
        special: special,
        tag: 0,
        rightSidedef: _side(front, upper: 'WALL2', lower: 'WALL2'),
        leftSidedef: _side(back, upper: 'WALL2', lower: 'WALL2'),
      ),
    );
  }

  int _vertex(int x, int y) => _vertexIndices.putIfAbsent((x, y), () {
    vertices.add(MapVertex(x, y));
    return vertices.length - 1;
  });

  int _side(
    int sector, {
    String upper = '-',
    String lower = '-',
    String middle = '-',
  }) {
    sidedefs.add(
      Sidedef(
        xOffset: 0,
        yOffset: 0,
        upperTexture: upper,
        lowerTexture: lower,
        middleTexture: middle,
        sector: sector,
      ),
    );
    return sidedefs.length - 1;
  }
}
