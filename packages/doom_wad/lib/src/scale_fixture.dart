import 'dart:typed_data';

import 'bsp_builder.dart';
import 'fixture_map.dart' show buildFixtureBlockmap;
import 'fixtures.dart' show buildFixtureColormap, buildFixturePlaypal;
import 'map_loader.dart';
import 'map_model.dart';
import 'resources.dart' show kTextureHeaderBytes, kTexturePatchBytes;
import 'resources_model.dart';
import 'wad.dart';
import 'wad_builder.dart';

/// Parameters for the generated, legally clean E1M1-scale rehearsal map.
///
/// This is deliberately not a likeness of E1M1. Its job is to provide a
/// deterministic WAD-shaped workload with the kinds of topology and resource
/// pressure a small fixture cannot represent.
class ScaleFixtureConfig {
  const ScaleFixtureConfig({
    this.columns = 12,
    this.rows = 10,
    this.textureCount = 20,
    this.flatCount = 24,
    this.seed = 0x51ca1e,
  }) : assert(columns >= 3),
       assert(rows >= 3),
       assert(textureCount >= 20),
       assert(flatCount >= 20);

  /// The CI-sized profile: 120 sectors, well above E1M1's line/vertex scale.
  static const ScaleFixtureConfig e1m1Scale = ScaleFixtureConfig();

  final int columns;
  final int rows;
  final int textureCount;
  final int flatCount;
  final int seed;

  int get sectorCount => columns * rows;
}

/// Builds a deterministic synthetic PWAD at approximately E1M1 map scale.
///
/// Every byte, texture and flat is generated locally from [ScaleFixtureConfig].
/// It contains no commercial Doom content and is intended only for tests and
/// headless diagnostics.
abstract final class DoomScaleFixture {
  /// Separate MAPxx marker so WAD diagnostics discover it as a normal level.
  /// MAP01 remains the pinned small fixture.
  static const String mapName = 'MAP98';

  static Uint8List? _defaultBytes;

  static Uint8List pwadBytes([
    ScaleFixtureConfig config = ScaleFixtureConfig.e1m1Scale,
  ]) {
    if (identical(config, ScaleFixtureConfig.e1m1Scale)) {
      return _defaultBytes ??= _build(config);
    }
    return _build(config);
  }

  static WadFile wad([
    ScaleFixtureConfig config = ScaleFixtureConfig.e1m1Scale,
  ]) => WadFile.parse(pwadBytes(config));

  static WadSet wadSet([
    ScaleFixtureConfig config = ScaleFixtureConfig.e1m1Scale,
  ]) => WadSet.of(wad(config));

  static MapData map([
    ScaleFixtureConfig config = ScaleFixtureConfig.e1m1Scale,
  ]) => MapData.load(wadSet(config), mapName);

  static Uint8List _build(ScaleFixtureConfig config) {
    final _ScaleMap map = _ScaleMap(config)..build();
    final _MapLumps lumps = _serialiseMap(map);
    final List<String> patchNames = List<String>.generate(
      config.textureCount,
      _wallName,
      growable: false,
    );
    final List<String> flatNames = List<String>.generate(
      config.flatCount,
      _flatName,
      growable: false,
    );
    return buildWad(<LumpSource>[
      LumpSource('PLAYPAL', buildFixturePlaypal()),
      LumpSource('COLORMAP', buildFixtureColormap()),
      LumpSource('PNAMES', _pnames(patchNames)),
      LumpSource('TEXTURE1', _textures(patchNames)),
      LumpSource.marker(mapName),
      LumpSource('THINGS', lumps.things),
      LumpSource('LINEDEFS', lumps.linedefs),
      LumpSource('SIDEDEFS', lumps.sidedefs),
      LumpSource('VERTEXES', lumps.vertices),
      LumpSource('SEGS', lumps.segs),
      LumpSource('SSECTORS', lumps.subsectors),
      LumpSource('NODES', lumps.nodes),
      LumpSource('SECTORS', lumps.sectors),
      LumpSource('REJECT', lumps.reject),
      LumpSource('BLOCKMAP', lumps.blockmap),
      LumpSource.marker('P_START'),
      for (var i = 0; i < patchNames.length; i++)
        LumpSource(patchNames[i], encodeDoomPatch(_wallPatch(i, config.seed))),
      LumpSource.marker('P_END'),
      LumpSource.marker('F_START'),
      for (var i = 0; i < flatNames.length; i++)
        LumpSource(flatNames[i], _flat(i, config.seed)),
      LumpSource.marker('F_END'),
    ]);
  }
}

String _wallName(int index) => 'W${index.toString().padLeft(3, '0')}';

String _flatName(int index) => 'F${index.toString().padLeft(3, '0')}';

Uint8List _pnames(List<String> names) {
  final Uint8List bytes = Uint8List(4 + names.length * kLumpNameBytes);
  final ByteData data = ByteData.sublistView(bytes);
  data.setInt32(0, names.length, Endian.little);
  for (var i = 0; i < names.length; i++) {
    encodeLumpName(bytes, 4 + i * kLumpNameBytes, names[i]);
  }
  return bytes;
}

Uint8List _textures(List<String> names) {
  final int entryBytes = kTextureHeaderBytes + kTexturePatchBytes;
  final Uint8List bytes = Uint8List(
    4 + names.length * 4 + names.length * entryBytes,
  );
  final ByteData data = ByteData.sublistView(bytes);
  data.setInt32(0, names.length, Endian.little);
  var cursor = 4 + names.length * 4;
  for (var i = 0; i < names.length; i++) {
    data.setInt32(4 + i * 4, cursor, Endian.little);
    encodeLumpName(bytes, cursor, names[i]);
    data.setInt16(cursor + 12, 512, Endian.little);
    data.setInt16(cursor + 14, 512, Endian.little);
    data.setInt16(cursor + 20, 1, Endian.little);
    data.setInt16(cursor + kTextureHeaderBytes + 4, i, Endian.little);
    cursor += entryBytes;
  }
  return bytes;
}

PatchImage _wallPatch(int texture, int seed) {
  const int size = 512;
  final Uint8List indices = Uint8List(size * size);
  final Uint8List coverage = Uint8List(size * size)
    ..fillRange(0, size * size, 255);
  final int hue = (texture * 37 + seed) & 0x0f;
  for (var y = 0; y < size; y++) {
    final int row = y * size;
    for (var x = 0; x < size; x++) {
      // Large generated panels make page boundaries and UV rect mistakes easy
      // to spot without encoding any source artwork.
      final int band = ((x >> 5) ^ (y >> 5) ^ texture) & 0x0f;
      indices[row + x] = hue * 16 + band;
    }
  }
  return PatchImage(
    width: size,
    height: size,
    leftOffset: 0,
    topOffset: 0,
    indices: indices,
    coverage: coverage,
  );
}

Uint8List _flat(int flat, int seed) {
  final Uint8List bytes = Uint8List(kFlatBytes);
  final int hue = (flat * 19 + seed) & 0x0f;
  for (var y = 0; y < kFlatSize; y++) {
    for (var x = 0; x < kFlatSize; x++) {
      bytes[y * kFlatSize + x] = hue * 16 + ((x + y + flat) & 0x0f);
    }
  }
  return bytes;
}

class _ScaleMap {
  _ScaleMap(this.config);

  final ScaleFixtureConfig config;
  final List<MapVertex> vertices = <MapVertex>[];
  final List<Linedef> linedefs = <Linedef>[];
  final List<Sidedef> sidedefs = <Sidedef>[];
  final List<Sector> sectors = <Sector>[];
  final List<Thing> things = <Thing>[];
  final Map<int, int> _vertexIds = <int, int>{};

  static const int _pitch = 448;

  void build() {
    for (var i = 0; i < config.sectorCount; i++) {
      final int floor = (i % 6) * 8;
      sectors.add(
        Sector(
          floorHeight: floor,
          ceilingHeight: 128 + (i % 4) * 16,
          floorFlat: _flatName(i % config.flatCount),
          ceilingFlat: _flatName((i * 7 + 3) % config.flatCount),
          lightLevel: 112 + (i * 11) % 128,
          special: 0,
          tag: 0,
        ),
      );
    }

    for (var i = 0; i < config.sectorCount; i++) {
      final int x = (i % config.columns) * _pitch;
      final int y = (i ~/ config.columns) * _pitch;
      if (i == 0) {
        _disconnectedIslands(i, x, y);
      } else if (i == 1) {
        _concentricSteps(i, x, y);
      } else {
        // L-shaped rooms are corridors with a turn, not simple rectangles.
        _solidLoop(
          <int>[
            x,
            y,
            x + 320,
            y,
            x + 320,
            y + 128,
            x + 160,
            y + 128,
            x + 160,
            y + 320,
            x,
            y + 320,
          ],
          i,
          texture: _wallName(i % config.textureCount),
        );
      }
    }
    things.add(const Thing(x: 96, y: 96, angle: 0, type: 1, flags: 7));
  }

  void _disconnectedIslands(int sector, int x, int y) {
    _solidLoop(
      <int>[x, y, x + 256, y, x + 256, y + 256, x, y + 256],
      sector,
      texture: _wallName(0),
    );
    // One sector owns two disconnected walkable islands, a Doom-valid shape
    // that prevents implementations from assuming one loop per sector.
    _solidLoop(
      <int>[
        x + 288,
        y + 48,
        x + 400,
        y + 48,
        x + 400,
        y + 160,
        x + 344,
        y + 160,
        x + 344,
        y + 256,
        x + 288,
        y + 256,
      ],
      sector,
      texture: _wallName(1),
    );
  }

  void _concentricSteps(int outer, int x, int y) {
    _solidLoop(
      <int>[x, y, x + 352, y, x + 352, y + 352, x, y + 352],
      outer,
      texture: _wallName(2),
    );
    // The raised inner sector is a genuine two-sided ring with upper/lower
    // bands and a masked middle texture, rather than a standalone prop.
    final int inner = (outer + 1) % config.sectorCount;
    final List<int> ring = <int>[
      x + 96,
      y + 96,
      x + 96,
      y + 256,
      x + 256,
      y + 256,
      x + 256,
      y + 96,
    ];
    _twoSidedLoop(
      ring,
      inner,
      outer,
      upper: _wallName(3),
      lower: _wallName(4),
      middle: _wallName(5),
    );
  }

  int _vertex(int x, int y) {
    final int key = ((x & 0xffff) << 16) | (y & 0xffff);
    return _vertexIds.putIfAbsent(key, () {
      vertices.add(MapVertex(x, y));
      return vertices.length - 1;
    });
  }

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

  void _solidLoop(List<int> points, int sector, {required String texture}) {
    final List<int> ring = _orient(points, clockwise: true);
    final int count = ring.length ~/ 2;
    for (var i = 0; i < count; i++) {
      final int j = (i + 1) % count;
      linedefs.add(
        Linedef(
          v1: _vertex(ring[i * 2], ring[i * 2 + 1]),
          v2: _vertex(ring[j * 2], ring[j * 2 + 1]),
          flags: LinedefFlags.blocking,
          special: 0,
          tag: 0,
          rightSidedef: _side(sector, middle: texture),
          leftSidedef: kNoSidedef,
        ),
      );
    }
  }

  void _twoSidedLoop(
    List<int> points,
    int inner,
    int outer, {
    required String upper,
    required String lower,
    required String middle,
  }) {
    final List<int> ring = _orient(points, clockwise: true);
    final int count = ring.length ~/ 2;
    for (var i = 0; i < count; i++) {
      final int j = (i + 1) % count;
      linedefs.add(
        Linedef(
          v1: _vertex(ring[i * 2], ring[i * 2 + 1]),
          v2: _vertex(ring[j * 2], ring[j * 2 + 1]),
          flags: LinedefFlags.twoSided,
          special: 0,
          tag: 0,
          rightSidedef: _side(
            inner,
            upper: upper,
            lower: lower,
            middle: middle,
          ),
          leftSidedef: _side(outer, upper: upper, lower: lower, middle: middle),
        ),
      );
    }
  }
}

List<int> _orient(List<int> points, {required bool clockwise}) {
  var twiceArea = 0;
  final int count = points.length ~/ 2;
  for (var i = 0; i < count; i++) {
    final int j = (i + 1) % count;
    twiceArea +=
        points[i * 2] * points[j * 2 + 1] - points[j * 2] * points[i * 2 + 1];
  }
  if ((twiceArea < 0) == clockwise) return points;
  return <int>[
    for (var i = count - 1; i >= 0; i--) ...<int>[
      points[i * 2],
      points[i * 2 + 1],
    ],
  ];
}

class _MapLumps {
  const _MapLumps({
    required this.things,
    required this.linedefs,
    required this.sidedefs,
    required this.vertices,
    required this.segs,
    required this.subsectors,
    required this.nodes,
    required this.sectors,
    required this.reject,
    required this.blockmap,
  });

  final Uint8List things,
      linedefs,
      sidedefs,
      vertices,
      segs,
      subsectors,
      nodes,
      sectors,
      reject,
      blockmap;
}

_MapLumps _serialiseMap(_ScaleMap map) {
  final List<BspSeg> input = <BspSeg>[];
  for (var i = 0; i < map.linedefs.length; i++) {
    final Linedef line = map.linedefs[i];
    final MapVertex a = map.vertices[line.v1];
    final MapVertex b = map.vertices[line.v2];
    input.add(BspSeg(x1: a.x, y1: a.y, x2: b.x, y2: b.y, linedef: i, side: 0));
    if (line.leftSidedef != kNoSidedef) {
      input.add(
        BspSeg(x1: b.x, y1: b.y, x2: a.x, y2: a.y, linedef: i, side: 1),
      );
    }
  }
  final BspTree tree = buildBspTree(input);
  final List<MapVertex> vertices = List<MapVertex>.of(map.vertices);
  final Map<int, int> ids = <int, int>{
    for (var i = 0; i < vertices.length; i++)
      ((vertices[i].x & 0xffff) << 16) | (vertices[i].y & 0xffff): i,
  };
  int intern(int x, int y) =>
      ids.putIfAbsent(((x & 0xffff) << 16) | (y & 0xffff), () {
        vertices.add(MapVertex(x, y));
        return vertices.length - 1;
      });

  final Uint8List segs = Uint8List(tree.segs.length * kSegBytes);
  final ByteData segData = ByteData.sublistView(segs);
  for (var i = 0; i < tree.segs.length; i++) {
    final BspSeg seg = tree.segs[i];
    final Linedef line = map.linedefs[seg.linedef];
    final MapVertex anchor = map.vertices[seg.side == 0 ? line.v1 : line.v2];
    final int o = i * kSegBytes;
    segData
      ..setUint16(o, intern(seg.x1, seg.y1), Endian.little)
      ..setUint16(o + 2, intern(seg.x2, seg.y2), Endian.little)
      ..setUint16(o + 4, bamAngle(seg.dx, seg.dy), Endian.little)
      ..setUint16(o + 6, seg.linedef, Endian.little)
      ..setUint16(o + 8, seg.side, Endian.little)
      ..setInt16(
        o + 10,
        distanceBetween(anchor.x, anchor.y, seg.x1, seg.y1),
        Endian.little,
      );
  }
  final Uint8List subsectors = Uint8List(
    tree.subsectors.length * kSubsectorBytes,
  );
  final ByteData ssData = ByteData.sublistView(subsectors);
  for (var i = 0; i < tree.subsectors.length; i++) {
    ssData
      ..setUint16(
        i * kSubsectorBytes,
        tree.subsectors[i].segCount,
        Endian.little,
      )
      ..setUint16(
        i * kSubsectorBytes + 2,
        tree.subsectors[i].firstSeg,
        Endian.little,
      );
  }
  final Uint8List nodes = Uint8List(tree.nodes.length * kNodeBytes);
  final ByteData nodeData = ByteData.sublistView(nodes);
  for (var i = 0; i < tree.nodes.length; i++) {
    final BspNodeOut node = tree.nodes[i];
    final int o = i * kNodeBytes;
    nodeData
      ..setInt16(o, node.x, Endian.little)
      ..setInt16(o + 2, node.y, Endian.little)
      ..setInt16(o + 4, node.dx, Endian.little)
      ..setInt16(o + 6, node.dy, Endian.little);
    for (var b = 0; b < 4; b++) {
      nodeData
        ..setInt16(o + 8 + b * 2, node.rightBox[b], Endian.little)
        ..setInt16(o + 16 + b * 2, node.leftBox[b], Endian.little);
    }
    nodeData
      ..setUint16(o + 24, node.rightChild, Endian.little)
      ..setUint16(o + 26, node.leftChild, Endian.little);
  }
  return _MapLumps(
    things: _things(map.things),
    linedefs: _linedefs(map.linedefs),
    sidedefs: _sidedefs(map.sidedefs),
    vertices: _vertices(vertices),
    segs: segs,
    subsectors: subsectors,
    nodes: nodes,
    sectors: _sectors(map.sectors),
    reject: Uint8List((map.sectors.length * map.sectors.length + 7) ~/ 8),
    blockmap: buildFixtureBlockmap(vertices, map.linedefs),
  );
}

Uint8List _vertices(List<MapVertex> values) {
  final Uint8List out = Uint8List(values.length * kVertexBytes);
  final ByteData data = ByteData.sublistView(out);
  for (var i = 0; i < values.length; i++) {
    data
      ..setInt16(i * kVertexBytes, values[i].x, Endian.little)
      ..setInt16(i * kVertexBytes + 2, values[i].y, Endian.little);
  }
  return out;
}

Uint8List _linedefs(List<Linedef> values) {
  final Uint8List out = Uint8List(values.length * kLinedefBytes);
  final ByteData data = ByteData.sublistView(out);
  for (var i = 0; i < values.length; i++) {
    final int o = i * kLinedefBytes;
    final Linedef line = values[i];
    data
      ..setUint16(o, line.v1, Endian.little)
      ..setUint16(o + 2, line.v2, Endian.little)
      ..setUint16(o + 4, line.flags, Endian.little)
      ..setUint16(o + 6, line.special, Endian.little)
      ..setUint16(o + 8, line.tag, Endian.little)
      ..setUint16(o + 10, line.rightSidedef, Endian.little)
      ..setUint16(o + 12, line.leftSidedef & 0xffff, Endian.little);
  }
  return out;
}

Uint8List _sidedefs(List<Sidedef> values) {
  final Uint8List out = Uint8List(values.length * kSidedefBytes);
  final ByteData data = ByteData.sublistView(out);
  for (var i = 0; i < values.length; i++) {
    final int o = i * kSidedefBytes;
    final Sidedef side = values[i];
    data
      ..setInt16(o, side.xOffset, Endian.little)
      ..setInt16(o + 2, side.yOffset, Endian.little)
      ..setInt16(o + 28, side.sector, Endian.little);
    encodeLumpName(out, o + 4, side.upperTexture);
    encodeLumpName(out, o + 12, side.lowerTexture);
    encodeLumpName(out, o + 20, side.middleTexture);
  }
  return out;
}

Uint8List _sectors(List<Sector> values) {
  final Uint8List out = Uint8List(values.length * kSectorBytes);
  final ByteData data = ByteData.sublistView(out);
  for (var i = 0; i < values.length; i++) {
    final int o = i * kSectorBytes;
    final Sector sector = values[i];
    data
      ..setInt16(o, sector.floorHeight, Endian.little)
      ..setInt16(o + 2, sector.ceilingHeight, Endian.little)
      ..setInt16(o + 20, sector.lightLevel, Endian.little)
      ..setInt16(o + 22, sector.special, Endian.little)
      ..setInt16(o + 24, sector.tag, Endian.little);
    encodeLumpName(out, o + 4, sector.floorFlat);
    encodeLumpName(out, o + 12, sector.ceilingFlat);
  }
  return out;
}

Uint8List _things(List<Thing> values) {
  final Uint8List out = Uint8List(values.length * kThingBytes);
  final ByteData data = ByteData.sublistView(out);
  for (var i = 0; i < values.length; i++) {
    final int o = i * kThingBytes;
    final Thing thing = values[i];
    data
      ..setInt16(o, thing.x, Endian.little)
      ..setInt16(o + 2, thing.y, Endian.little)
      ..setInt16(o + 4, thing.angle, Endian.little)
      ..setUint16(o + 6, thing.type, Endian.little)
      ..setUint16(o + 8, thing.flags, Endian.little);
  }
  return out;
}
