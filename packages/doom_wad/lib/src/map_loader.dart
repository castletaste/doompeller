import 'dart:typed_data';

import 'failures.dart';
import 'limits.dart';
import 'map_model.dart';
import 'wad.dart';

/// Bytes per record in each map lump.
const int kVertexBytes = 4;
const int kLinedefBytes = 14;
const int kSidedefBytes = 30;
const int kSectorBytes = 26;
const int kSegBytes = 12;
const int kSubsectorBytes = 4;
const int kNodeBytes = 28;
const int kThingBytes = 10;

/// The lumps that belong to a map, in the order vanilla writes them.
const List<String> kMapLumpNames = <String>[
  'THINGS',
  'LINEDEFS',
  'SIDEDEFS',
  'VERTEXES',
  'SEGS',
  'SSECTORS',
  'NODES',
  'SECTORS',
  'REJECT',
  'BLOCKMAP',
];

/// Lumps that may follow a map marker without ending the map. BEHAVIOR marks a
/// Hexen-format map, which this loader rejects rather than misparsing.
const List<String> _kOptionalMapLumps = <String>['BEHAVIOR', 'SCRIPTS', 'GL_VERT'];

/// The map lumps of one level, resolved to flat [WadSet] indices.
class _MapLumps {
  _MapLumps(this.markerIndex);

  final int markerIndex;
  final Map<String, int> indices = <String, int>{};

  int? operator [](String name) => indices[name];
}

/// Reads [mapName] from [set].
///
/// The map's lumps are the contiguous run following its marker: reading stops
/// at the first lump that is neither a known map lump nor an accepted optional
/// one, which is how vanilla delimits levels. A BLOCKMAP that cannot be trusted
/// is reported as null instead of failing the level, because several shipped
/// maps have a broken one and the game still runs.
MapData loadMapData(
  WadSet set,
  String mapName, {
  DoomLimits limits = DoomLimits.defaults,
}) {
  final String name = normaliseLumpName(mapName);
  final _MapLumps lumps = _findMapLumps(set, name);

  if (lumps['BEHAVIOR'] != null) {
    throw DoomMapFailure('$name is a Hexen-format map, which is not supported');
  }

  final List<MapVertex> vertices = _readVertices(set, lumps, name, limits);
  final List<Sector> sectors = _readSectors(set, lumps, name, limits);
  final List<Sidedef> sidedefs = _readSidedefs(set, lumps, name, limits, sectors.length);
  final List<Linedef> linedefs =
      _readLinedefs(set, lumps, name, limits, vertices.length, sidedefs.length);
  final List<Seg> segs = _readSegs(set, lumps, name, limits, vertices.length, linedefs.length);
  final List<Subsector> subsectors = _readSubsectors(set, lumps, name, limits, segs.length);
  final List<BspNode> nodes = _readNodes(set, lumps, name, limits, subsectors.length);
  final List<Thing> things = _readThings(set, lumps, name, limits);

  final int? rejectIndex = lumps['REJECT'];
  Uint8List? reject;
  if (rejectIndex != null) {
    final Uint8List bytes = set.bytesAt(rejectIndex);
    // A short REJECT is common in PWADs; treat it as absent rather than fatal.
    final int needed = (sectors.length * sectors.length + 7) ~/ 8;
    if (bytes.lengthInBytes >= needed && needed > 0) {
      reject = bytes;
    }
  }

  final int? blockmapIndex = lumps['BLOCKMAP'];
  final Blockmap? blockmap =
      blockmapIndex == null ? null : parseBlockmap(set.bytesAt(blockmapIndex), linedefs.length);

  return MapData(
    name: name,
    vertices: vertices,
    linedefs: linedefs,
    sidedefs: sidedefs,
    sectors: sectors,
    segs: segs,
    subsectors: subsectors,
    nodes: nodes,
    things: things,
    blockmap: blockmap,
    reject: reject,
  );
}

_MapLumps _findMapLumps(WadSet set, String name) {
  // Search from the end so a PWAD's replacement map wins over the IWAD's.
  var marker = -1;
  for (var i = set.length - 1; i >= 0; i--) {
    if (set.nameAt(i) == name) {
      marker = i;
      break;
    }
  }
  if (marker < 0) {
    throw DoomMissingLumpFailure(name);
  }

  final _MapLumps lumps = _MapLumps(marker);
  final int owner = set.wadIndexAt(marker);
  for (var i = marker + 1; i < set.length; i++) {
    // A map never spans two files.
    if (set.wadIndexAt(i) != owner) {
      break;
    }
    final String lumpName = set.nameAt(i);
    final bool known = kMapLumpNames.contains(lumpName);
    if (!known && !_kOptionalMapLumps.contains(lumpName)) {
      break;
    }
    // Keep the first occurrence: a second THINGS means the next map started.
    if (known && lumps.indices.containsKey(lumpName)) {
      break;
    }
    lumps.indices[lumpName] = i;
  }

  for (final String required in const <String>[
    'LINEDEFS',
    'SIDEDEFS',
    'VERTEXES',
    'SECTORS',
  ]) {
    if (lumps[required] == null) {
      throw DoomMapFailure('$name is missing its $required lump');
    }
  }
  return lumps;
}

/// Throws unless [bytes] holds a whole number of [recordBytes] sized records.
int _recordCount(Uint8List bytes, int recordBytes, String mapName, String lumpName) {
  final int length = bytes.lengthInBytes;
  if (length % recordBytes != 0) {
    throw DoomMapFailure(
      '$mapName/$lumpName: $length bytes is not a multiple of the $recordBytes byte record',
    );
  }
  return length ~/ recordBytes;
}

void _checkIndex(int value, int count, String mapName, String lumpName, String field) {
  if (value < 0 || value >= count) {
    throw DoomMapFailure(
      '$mapName/$lumpName: $field is $value, outside the valid range 0..${count - 1}',
    );
  }
}

List<MapVertex> _readVertices(WadSet set, _MapLumps lumps, String name, DoomLimits limits) {
  final Uint8List bytes = set.bytesAt(lumps['VERTEXES']!);
  final int count = _recordCount(bytes, kVertexBytes, name, 'VERTEXES');
  DoomLimits.check(count, limits.maxVertices, 'maxVertices');
  final ByteData data = ByteData.sublistView(bytes);
  final List<MapVertex> out = List<MapVertex>.generate(
    count,
    (int i) => MapVertex(
      data.getInt16(i * kVertexBytes, Endian.little),
      data.getInt16(i * kVertexBytes + 2, Endian.little),
    ),
    growable: false,
  );
  return out;
}

List<Sector> _readSectors(WadSet set, _MapLumps lumps, String name, DoomLimits limits) {
  final Uint8List bytes = set.bytesAt(lumps['SECTORS']!);
  final int count = _recordCount(bytes, kSectorBytes, name, 'SECTORS');
  DoomLimits.check(count, limits.maxSectors, 'maxSectors');
  final ByteData data = ByteData.sublistView(bytes);
  final List<Sector> out = <Sector>[];
  for (var i = 0; i < count; i++) {
    final int o = i * kSectorBytes;
    out.add(
      Sector(
        floorHeight: data.getInt16(o, Endian.little),
        ceilingHeight: data.getInt16(o + 2, Endian.little),
        floorFlat: decodeLumpName(bytes, o + 4),
        ceilingFlat: decodeLumpName(bytes, o + 12),
        lightLevel: data.getInt16(o + 20, Endian.little),
        special: data.getInt16(o + 22, Endian.little),
        tag: data.getInt16(o + 24, Endian.little),
      ),
    );
  }
  return List<Sector>.unmodifiable(out);
}

List<Sidedef> _readSidedefs(
  WadSet set,
  _MapLumps lumps,
  String name,
  DoomLimits limits,
  int sectorCount,
) {
  final Uint8List bytes = set.bytesAt(lumps['SIDEDEFS']!);
  final int count = _recordCount(bytes, kSidedefBytes, name, 'SIDEDEFS');
  DoomLimits.check(count, limits.maxSidedefs, 'maxSidedefs');
  final ByteData data = ByteData.sublistView(bytes);
  final List<Sidedef> out = <Sidedef>[];
  for (var i = 0; i < count; i++) {
    final int o = i * kSidedefBytes;
    final int sector = data.getInt16(o + 28, Endian.little);
    _checkIndex(sector, sectorCount, name, 'SIDEDEFS', 'sidedef $i sector');
    out.add(
      Sidedef(
        xOffset: data.getInt16(o, Endian.little),
        yOffset: data.getInt16(o + 2, Endian.little),
        upperTexture: decodeLumpName(bytes, o + 4),
        lowerTexture: decodeLumpName(bytes, o + 12),
        middleTexture: decodeLumpName(bytes, o + 20),
        sector: sector,
      ),
    );
  }
  return List<Sidedef>.unmodifiable(out);
}

List<Linedef> _readLinedefs(
  WadSet set,
  _MapLumps lumps,
  String name,
  DoomLimits limits,
  int vertexCount,
  int sidedefCount,
) {
  final Uint8List bytes = set.bytesAt(lumps['LINEDEFS']!);
  final int count = _recordCount(bytes, kLinedefBytes, name, 'LINEDEFS');
  DoomLimits.check(count, limits.maxLinedefs, 'maxLinedefs');
  final ByteData data = ByteData.sublistView(bytes);
  final List<Linedef> out = <Linedef>[];
  for (var i = 0; i < count; i++) {
    final int o = i * kLinedefBytes;
    final int v1 = data.getUint16(o, Endian.little);
    final int v2 = data.getUint16(o + 2, Endian.little);
    _checkIndex(v1, vertexCount, name, 'LINEDEFS', 'linedef $i v1');
    _checkIndex(v2, vertexCount, name, 'LINEDEFS', 'linedef $i v2');

    final int right = _sidedefRef(data.getInt16(o + 10, Endian.little));
    final int left = _sidedefRef(data.getInt16(o + 12, Endian.little));
    if (right != kNoSidedef) {
      _checkIndex(right, sidedefCount, name, 'LINEDEFS', 'linedef $i right sidedef');
    }
    if (left != kNoSidedef) {
      _checkIndex(left, sidedefCount, name, 'LINEDEFS', 'linedef $i left sidedef');
    }
    if (right == kNoSidedef && left == kNoSidedef) {
      throw DoomMapFailure('$name/LINEDEFS: linedef $i has no sidedef on either side');
    }

    out.add(
      Linedef(
        v1: v1,
        v2: v2,
        flags: data.getUint16(o + 4, Endian.little),
        special: data.getUint16(o + 6, Endian.little),
        tag: data.getUint16(o + 8, Endian.little),
        rightSidedef: right,
        leftSidedef: left,
      ),
    );
  }
  return List<Linedef>.unmodifiable(out);
}

/// Vanilla writes "no sidedef" as 0xFFFF; read as signed that is -1.
int _sidedefRef(int raw) => raw == 0xFFFF || raw == -1 ? kNoSidedef : raw;

List<Seg> _readSegs(
  WadSet set,
  _MapLumps lumps,
  String name,
  DoomLimits limits,
  int vertexCount,
  int linedefCount,
) {
  final int? index = lumps['SEGS'];
  if (index == null) {
    return const <Seg>[];
  }
  final Uint8List bytes = set.bytesAt(index);
  final int count = _recordCount(bytes, kSegBytes, name, 'SEGS');
  DoomLimits.check(count, limits.maxSegs, 'maxSegs');
  final ByteData data = ByteData.sublistView(bytes);
  final List<Seg> out = <Seg>[];
  for (var i = 0; i < count; i++) {
    final int o = i * kSegBytes;
    final int v1 = data.getUint16(o, Endian.little);
    final int v2 = data.getUint16(o + 2, Endian.little);
    final int linedef = data.getUint16(o + 6, Endian.little);
    _checkIndex(v1, vertexCount, name, 'SEGS', 'seg $i v1');
    _checkIndex(v2, vertexCount, name, 'SEGS', 'seg $i v2');
    _checkIndex(linedef, linedefCount, name, 'SEGS', 'seg $i linedef');
    final int side = data.getUint16(o + 8, Endian.little);
    if (side != 0 && side != 1) {
      throw DoomMapFailure('$name/SEGS: seg $i has side $side, expected 0 or 1');
    }
    out.add(
      Seg(
        v1: v1,
        v2: v2,
        angle: data.getUint16(o + 4, Endian.little),
        linedef: linedef,
        side: side,
        offset: data.getInt16(o + 10, Endian.little),
      ),
    );
  }
  return List<Seg>.unmodifiable(out);
}

List<Subsector> _readSubsectors(
  WadSet set,
  _MapLumps lumps,
  String name,
  DoomLimits limits,
  int segCount,
) {
  final int? index = lumps['SSECTORS'];
  if (index == null) {
    return const <Subsector>[];
  }
  final Uint8List bytes = set.bytesAt(index);
  final int count = _recordCount(bytes, kSubsectorBytes, name, 'SSECTORS');
  DoomLimits.check(count, limits.maxSubsectors, 'maxSubsectors');
  final ByteData data = ByteData.sublistView(bytes);
  final List<Subsector> out = <Subsector>[];
  for (var i = 0; i < count; i++) {
    final int o = i * kSubsectorBytes;
    final int segs = data.getUint16(o, Endian.little);
    final int first = data.getUint16(o + 2, Endian.little);
    if (segs <= 0) {
      throw DoomMapFailure('$name/SSECTORS: subsector $i has $segs segs');
    }
    if (first < 0 || first + segs > segCount) {
      throw DoomMapFailure(
        '$name/SSECTORS: subsector $i covers segs $first..${first + segs - 1}, outside 0..${segCount - 1}',
      );
    }
    out.add(Subsector(segCount: segs, firstSeg: first));
  }
  return List<Subsector>.unmodifiable(out);
}

List<BspNode> _readNodes(
  WadSet set,
  _MapLumps lumps,
  String name,
  DoomLimits limits,
  int subsectorCount,
) {
  final int? index = lumps['NODES'];
  if (index == null) {
    return const <BspNode>[];
  }
  final Uint8List bytes = set.bytesAt(index);
  final int count = _recordCount(bytes, kNodeBytes, name, 'NODES');
  DoomLimits.check(count, limits.maxNodes, 'maxNodes');
  final ByteData data = ByteData.sublistView(bytes);
  final List<BspNode> out = <BspNode>[];
  for (var i = 0; i < count; i++) {
    final int o = i * kNodeBytes;
    final Int16List rightBox = Int16List(4);
    final Int16List leftBox = Int16List(4);
    for (var b = 0; b < 4; b++) {
      rightBox[b] = data.getInt16(o + 8 + b * 2, Endian.little);
      leftBox[b] = data.getInt16(o + 16 + b * 2, Endian.little);
    }
    final int rightChild = data.getUint16(o + 24, Endian.little);
    final int leftChild = data.getUint16(o + 26, Endian.little);
    _checkChild(rightChild, count, subsectorCount, name, 'node $i right child');
    _checkChild(leftChild, count, subsectorCount, name, 'node $i left child');
    out.add(
      BspNode(
        x: data.getInt16(o, Endian.little),
        y: data.getInt16(o + 2, Endian.little),
        dx: data.getInt16(o + 4, Endian.little),
        dy: data.getInt16(o + 6, Endian.little),
        rightBox: rightBox,
        leftBox: leftBox,
        rightChild: rightChild,
        leftChild: leftChild,
      ),
    );
  }
  return List<BspNode>.unmodifiable(out);
}

void _checkChild(int child, int nodeCount, int subsectorCount, String mapName, String field) {
  if ((child & kSubsectorBit) != 0) {
    final int target = child & ~kSubsectorBit;
    _checkIndex(target, subsectorCount, mapName, 'NODES', '$field subsector');
  } else {
    _checkIndex(child, nodeCount, mapName, 'NODES', '$field node');
  }
}

List<Thing> _readThings(WadSet set, _MapLumps lumps, String name, DoomLimits limits) {
  final int? index = lumps['THINGS'];
  if (index == null) {
    return const <Thing>[];
  }
  final Uint8List bytes = set.bytesAt(index);
  final int count = _recordCount(bytes, kThingBytes, name, 'THINGS');
  DoomLimits.check(count, limits.maxThings, 'maxThings');
  final ByteData data = ByteData.sublistView(bytes);
  final List<Thing> out = <Thing>[];
  for (var i = 0; i < count; i++) {
    final int o = i * kThingBytes;
    out.add(
      Thing(
        x: data.getInt16(o, Endian.little),
        y: data.getInt16(o + 2, Endian.little),
        angle: data.getInt16(o + 4, Endian.little),
        type: data.getUint16(o + 6, Endian.little),
        flags: data.getUint16(o + 8, Endian.little),
      ),
    );
  }
  return List<Thing>.unmodifiable(out);
}

/// Parses a BLOCKMAP lump, or returns null when it cannot be trusted.
///
/// Layout: a four-word header (origin x, origin y, column count, row count),
/// then one 16-bit *word* offset per cell, then each cell's linedef list. A
/// cell list starts with a 0x0000 pad and ends with 0xFFFF.
///
/// Vanilla quirks handled here:
///
///  * The leading 0x0000 pad and trailing 0xFFFF terminator are stripped.
///  * Large maps overflow the 16-bit offset field, so a cell offset can wrap
///    and point backwards. Such a cell is left empty rather than read from a
///    wrong location.
///  * Blockmaps whose header is impossible, or whose offset table does not fit,
///    yield null. A missing blockmap costs the caller a slower broadphase; a
///    wrong one costs correctness.
Blockmap? parseBlockmap(Uint8List bytes, int linedefCount) {
  final int length = bytes.lengthInBytes;
  if (length < 8 || length.isOdd) {
    return null;
  }
  final ByteData data = ByteData.sublistView(bytes);
  final int originX = data.getInt16(0, Endian.little);
  final int originY = data.getInt16(2, Endian.little);
  final int columns = data.getUint16(4, Endian.little);
  final int rows = data.getUint16(6, Endian.little);
  if (columns <= 0 || rows <= 0) {
    return null;
  }

  final int cellCount = columns * rows;
  final int words = length ~/ 2;
  // Header is 4 words; the offset table needs one word per cell.
  if (4 + cellCount > words) {
    return null;
  }

  final List<Uint16List> cells = List<Uint16List>.filled(cellCount, _emptyCell, growable: false);
  final List<int> scratch = <int>[];
  for (var i = 0; i < cellCount; i++) {
    final int offset = data.getUint16(8 + i * 2, Endian.little);
    // The list must start after the offset table; a smaller value is the
    // 16-bit overflow wrapping around, so skip the cell.
    if (offset < 4 + cellCount || offset >= words) {
      continue;
    }
    scratch.clear();
    var cursor = offset;
    // Vanilla writes a 0x0000 pad first. Some node builders omit it.
    if (data.getUint16(cursor * 2, Endian.little) == 0) {
      cursor++;
    }
    var terminated = false;
    while (cursor < words) {
      final int value = data.getUint16(cursor * 2, Endian.little);
      cursor++;
      if (value == 0xFFFF) {
        terminated = true;
        break;
      }
      // Drop references the map cannot satisfy instead of failing the level.
      if (value < linedefCount) {
        scratch.add(value);
      }
    }
    if (!terminated) {
      // A run to the end of the lump means the offsets are unusable.
      return null;
    }
    if (scratch.isNotEmpty) {
      cells[i] = Uint16List.fromList(scratch);
    }
  }

  return Blockmap(
    originX: originX,
    originY: originY,
    columns: columns,
    rows: rows,
    cells: cells,
  );
}

final Uint16List _emptyCell = Uint16List(0);
