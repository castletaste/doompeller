import 'dart:typed_data';

import 'failures.dart';
import 'limits.dart';

/// Container flavour declared by the four magic bytes at the head of a file.
enum WadKind {
  /// Standalone game data.
  iwad,

  /// Patch archive layered on top of an IWAD.
  pwad,
}

/// Bytes a lump name occupies in the directory.
const int kLumpNameBytes = 8;

/// Size of the fixed WAD header: magic, lump count, directory offset.
const int kWadHeaderBytes = 12;

/// Size of one directory record: offset, size, name.
const int kDirectoryEntryBytes = 16;

/// Normalises [name] the way vanilla lookups do: trimmed, clipped to eight
/// characters and uppercased.
String normaliseLumpName(String name) {
  var end = name.length;
  while (end > 0) {
    final int unit = name.codeUnitAt(end - 1);
    if (unit != 0x20 && unit != 0) {
      break;
    }
    end--;
  }
  if (end > kLumpNameBytes) {
    end = kLumpNameBytes;
  }
  return name.substring(0, end).toUpperCase();
}

/// Decodes the eight NUL-padded name bytes starting at [offset].
///
/// Bytes outside printable ASCII are folded to '_' so that hostile input can
/// never produce surrogate garbage or throw; the result stays deterministic.
String decodeLumpName(Uint8List bytes, int offset) {
  var length = 0;
  while (length < kLumpNameBytes && bytes[offset + length] != 0) {
    length++;
  }
  while (length > 0 && bytes[offset + length - 1] == 0x20) {
    length--;
  }
  if (length == 0) {
    return '';
  }
  final Uint8List scratch = Uint8List(length);
  for (var i = 0; i < length; i++) {
    int byte = bytes[offset + i];
    if (byte >= 0x61 && byte <= 0x7A) {
      byte -= 0x20;
    } else if (byte < 0x20 || byte > 0x7E) {
      byte = 0x5F;
    }
    scratch[i] = byte;
  }
  return String.fromCharCodes(scratch);
}

/// Writes [name] as eight NUL-padded uppercase bytes at [offset].
void encodeLumpName(Uint8List target, int offset, String name) {
  final String normalised = normaliseLumpName(name);
  for (var i = 0; i < kLumpNameBytes; i++) {
    target[offset + i] = i < normalised.length
        ? normalised.codeUnitAt(i) & 0x7F
        : 0;
  }
}

/// One directory record: a name plus a byte range inside its [WadFile].
class LumpEntry {
  const LumpEntry({
    required this.index,
    required this.name,
    required this.offset,
    required this.size,
  });

  /// Position of this record inside its own [WadFile].
  final int index;

  /// Uppercase, NUL-trimmed lump name.
  final String name;

  /// Byte offset of the payload from the start of the file.
  final int offset;

  /// Payload length in bytes.
  final int size;

  /// Vanilla uses zero-length lumps as section markers (F_START, S_END, map
  /// names). Their offset field is frequently garbage and must not be trusted.
  bool get isMarker => size == 0;

  @override
  String toString() => 'LumpEntry($index, $name, +$offset, $size)';
}

/// A single parsed WAD container.
///
/// [parse] validates the header, the directory and every lump range before any
/// payload is touched, so [lumpBytes] can hand out zero-copy views safely.
class WadFile {
  WadFile._(this._bytes, this.kind, this.lumps, this._lastByName);

  final Uint8List _bytes;

  /// IWAD or PWAD, as declared by the magic bytes.
  final WadKind kind;

  /// Directory records in file order.
  final List<LumpEntry> lumps;

  final Map<String, int> _lastByName;

  /// Total bytes of the backing buffer.
  int get byteLength => _bytes.lengthInBytes;

  /// Number of directory records.
  int get length => lumps.length;

  /// Parses [bytes] as a WAD container.
  ///
  /// Throws a [DoomFormatFailure] for structurally invalid input and a
  /// [DoomLimitFailure] when a budget in [limits] would be exceeded. It never
  /// throws an untyped error, however hostile the bytes are.
  static WadFile parse(
    Uint8List bytes, {
    DoomLimits limits = DoomLimits.defaults,
  }) {
    final int total = bytes.lengthInBytes;
    DoomLimits.check(total, limits.maxWadBytes, 'maxWadBytes');
    if (total < kWadHeaderBytes) {
      throw DoomFormatFailure(
        'wad is $total bytes, shorter than the $kWadHeaderBytes byte header',
      );
    }

    final WadKind kind = _readKind(bytes);
    final ByteData header = ByteData.sublistView(bytes, 0, kWadHeaderBytes);
    final int lumpCount = header.getInt32(4, Endian.little);
    final int directoryOffset = header.getInt32(8, Endian.little);

    if (lumpCount < 0) {
      throw DoomFormatFailure('negative lump count $lumpCount');
    }
    DoomLimits.check(lumpCount, limits.maxLumpCount, 'maxLumpCount');

    if (directoryOffset < 0) {
      throw DoomFormatFailure('negative directory offset $directoryOffset');
    }
    final int directoryEnd = directoryOffset + lumpCount * kDirectoryEntryBytes;
    if (directoryOffset > total || directoryEnd > total) {
      throw DoomFormatFailure(
        'directory spans $directoryOffset..$directoryEnd beyond the $total byte file',
      );
    }

    final ByteData data = ByteData.sublistView(bytes);
    final List<LumpEntry> lumps = <LumpEntry>[];
    final Map<String, int> lastByName = <String, int>{};
    for (var i = 0; i < lumpCount; i++) {
      final int record = directoryOffset + i * kDirectoryEntryBytes;
      final int offset = data.getInt32(record, Endian.little);
      final int size = data.getInt32(record + 4, Endian.little);
      final String name = decodeLumpName(bytes, record + 8);

      if (size < 0) {
        throw DoomFormatFailure('lump $i ($name) has negative size $size');
      }
      DoomLimits.check(size, limits.maxLumpBytes, 'maxLumpBytes');
      // Marker lumps carry a garbage offset in many real WADs; only ranges that
      // actually hold payload are bounds-checked.
      if (size > 0) {
        if (offset < 0 || offset > total || offset + size > total) {
          throw DoomFormatFailure(
            'lump $i ($name) spans $offset..${offset + size} beyond the $total byte file',
          );
        }
      }

      lumps.add(
        LumpEntry(
          index: i,
          name: name,
          offset: size > 0 ? offset : 0,
          size: size,
        ),
      );
      lastByName[name] = i;
    }

    return WadFile._(
      bytes,
      kind,
      List<LumpEntry>.unmodifiable(lumps),
      lastByName,
    );
  }

  static WadKind _readKind(Uint8List bytes) {
    final int b0 = bytes[0];
    final int b1 = bytes[1];
    final int b2 = bytes[2];
    final int b3 = bytes[3];
    final bool tail = b1 == 0x57 && b2 == 0x41 && b3 == 0x44; // 'WAD'
    if (tail && b0 == 0x49) {
      return WadKind.iwad;
    }
    if (tail && b0 == 0x50) {
      return WadKind.pwad;
    }
    final String magic = String.fromCharCodes(<int>[
      for (var i = 0; i < 4; i++)
        (bytes[i] >= 0x20 && bytes[i] <= 0x7E) ? bytes[i] : 0x3F,
    ]);
    throw DoomFormatFailure('bad magic "$magic", expected IWAD or PWAD');
  }

  /// Zero-copy view of lump [index].
  Uint8List lumpBytes(int index) {
    if (index < 0 || index >= lumps.length) {
      throw DoomFormatFailure(
        'lump index $index out of range (0..${lumps.length - 1})',
      );
    }
    final LumpEntry entry = lumps[index];
    if (entry.size == 0) {
      return Uint8List(0);
    }
    return Uint8List.sublistView(
      _bytes,
      entry.offset,
      entry.offset + entry.size,
    );
  }

  /// First lump named [name] at or after [from], or null.
  int? indexOfLump(String name, {int from = 0}) {
    final String wanted = normaliseLumpName(name);
    final int start = from < 0 ? 0 : from;
    for (var i = start; i < lumps.length; i++) {
      if (lumps[i].name == wanted) {
        return i;
      }
    }
    return null;
  }

  /// Last lump named [name], matching vanilla's override-friendly lookup.
  int? lastIndexOfLump(String name) => _lastByName[normaliseLumpName(name)];
}

/// An ordered stack of WADs presented as one flat namespace.
///
/// Lumps keep their file order, and lookups resolve to the *last* match, so a
/// PWAD appended after an IWAD transparently patches it.
class WadSet {
  WadSet(List<WadFile> wads)
    : wads = List<WadFile>.unmodifiable(wads),
      _wadIndex = Int32List(_countLumps(wads)),
      _localIndex = Int32List(_countLumps(wads)),
      _names = List<String>.filled(_countLumps(wads), '', growable: false),
      _lastByName = <String, int>{} {
    var global = 0;
    for (var w = 0; w < this.wads.length; w++) {
      final List<LumpEntry> lumps = this.wads[w].lumps;
      for (var l = 0; l < lumps.length; l++) {
        _wadIndex[global] = w;
        _localIndex[global] = l;
        _names[global] = lumps[l].name;
        _lastByName[lumps[l].name] = global;
        global++;
      }
    }
  }

  /// Convenience for the common single-file case.
  factory WadSet.of(WadFile wad) => WadSet(<WadFile>[wad]);

  static int _countLumps(List<WadFile> wads) {
    var total = 0;
    for (final WadFile wad in wads) {
      total += wad.lumps.length;
    }
    return total;
  }

  /// Source files, lowest priority first.
  final List<WadFile> wads;

  final Int32List _wadIndex;
  final Int32List _localIndex;
  final List<String> _names;
  final Map<String, int> _lastByName;

  /// Total lumps across every file.
  int get length => _names.length;

  /// Name of the lump at flat [index].
  String nameAt(int index) {
    _checkIndex(index);
    return _names[index];
  }

  /// Which file in [wads] owns flat [index]. Callers walking contiguous lumps
  /// use this to stop at a file boundary.
  int wadIndexAt(int index) {
    _checkIndex(index);
    return _wadIndex[index];
  }

  /// Directory record behind flat [index].
  LumpEntry entryAt(int index) {
    _checkIndex(index);
    return wads[_wadIndex[index]].lumps[_localIndex[index]];
  }

  /// Zero-copy payload view for flat [index].
  Uint8List bytesAt(int index) {
    _checkIndex(index);
    return wads[_wadIndex[index]].lumpBytes(_localIndex[index]);
  }

  /// Flat index of the highest-priority lump named [name], or null.
  int? indexOf(String name) => _lastByName[normaliseLumpName(name)];

  /// First lump named [name] at or after flat index [from], or null. Used to
  /// walk the lumps that follow a map marker.
  int? indexOfFrom(String name, int from) {
    final String wanted = normaliseLumpName(name);
    final int start = from < 0 ? 0 : from;
    for (var i = start; i < _names.length; i++) {
      if (_names[i] == wanted) {
        return i;
      }
    }
    return null;
  }

  /// Payload of the highest-priority lump named [name], or null when absent.
  Uint8List? read(String name) {
    final int? index = indexOf(name);
    return index == null ? null : bytesAt(index);
  }

  /// Payload of [name], or a [DoomMissingLumpFailure] when it is not present.
  Uint8List require(String name) {
    final Uint8List? bytes = read(name);
    if (bytes == null) {
      throw DoomMissingLumpFailure(normaliseLumpName(name));
    }
    return bytes;
  }

  /// Sorted, de-duplicated ExMy and MAPxx markers present in the set.
  List<String> mapNames() {
    final Set<String> found = <String>{};
    for (var i = 0; i < _names.length; i++) {
      final String name = _names[i];
      if (isMapMarkerName(name)) {
        found.add(name);
      }
    }
    final List<String> sorted = found.toList(growable: false)..sort();
    return sorted;
  }

  void _checkIndex(int index) {
    if (index < 0 || index >= _names.length) {
      throw DoomFormatFailure(
        'lump index $index out of range (0..${_names.length - 1})',
      );
    }
  }
}

/// True for ExMy (episode/mission) and MAPxx level markers.
bool isMapMarkerName(String name) {
  if (name.length == 4 &&
      name.codeUnitAt(0) == 0x45 &&
      name.codeUnitAt(2) == 0x4D &&
      _isDigit(name.codeUnitAt(1)) &&
      _isDigit(name.codeUnitAt(3))) {
    return true;
  }
  if (name.length == 5 &&
      name.codeUnitAt(0) == 0x4D &&
      name.codeUnitAt(1) == 0x41 &&
      name.codeUnitAt(2) == 0x50 &&
      _isDigit(name.codeUnitAt(3)) &&
      _isDigit(name.codeUnitAt(4))) {
    return true;
  }
  return false;
}

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;
