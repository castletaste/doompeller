import 'dart:typed_data';

import 'resources.dart';
import 'resources_model.dart';
import 'wad.dart';

/// Writers that produce WAD bytes. Used to build test fixtures in memory and
/// to round-trip the patch decoder against a known-good encoder.

/// One lump queued for [buildWad].
class LumpSource {
  const LumpSource(this.name, this.bytes);

  /// Zero-length marker lump such as F_START or a map name.
  LumpSource.marker(this.name) : bytes = Uint8List(0);

  final String name;
  final Uint8List bytes;
}

/// Serialises [lumps] into a WAD container.
///
/// Payloads are written first in the given order, then the directory, which is
/// the layout every real WAD uses. Output is byte-for-byte deterministic for a
/// given input, so fixtures can be hashed in tests.
Uint8List buildWad(List<LumpSource> lumps, {WadKind kind = WadKind.pwad}) {
  var payload = 0;
  for (final LumpSource lump in lumps) {
    payload += lump.bytes.lengthInBytes;
  }
  final int directoryOffset = kWadHeaderBytes + payload;
  final int total = directoryOffset + lumps.length * kDirectoryEntryBytes;

  final Uint8List out = Uint8List(total);
  final ByteData view = ByteData.sublistView(out);

  out[0] = kind == WadKind.iwad ? 0x49 : 0x50; // 'I' or 'P'
  out[1] = 0x57; // 'W'
  out[2] = 0x41; // 'A'
  out[3] = 0x44; // 'D'
  view.setInt32(4, lumps.length, Endian.little);
  view.setInt32(8, directoryOffset, Endian.little);

  var cursor = kWadHeaderBytes;
  var record = directoryOffset;
  for (final LumpSource lump in lumps) {
    final int size = lump.bytes.lengthInBytes;
    if (size > 0) {
      out.setRange(cursor, cursor + size, lump.bytes);
    }
    // Vanilla points markers at the current write position; keep that so the
    // output matches what real tools emit.
    view.setInt32(record, cursor, Endian.little);
    view.setInt32(record + 4, size, Endian.little);
    encodeLumpName(out, record + 8, lump.name);
    cursor += size;
    record += kDirectoryEntryBytes;
  }

  return out;
}

/// Encodes [image] into the column-post patch format.
///
/// Runs of opaque pixels become posts; transparent gaps are simply not
/// encoded. Posts longer than 254 rows are chunked, and images taller than 254
/// rows use the relative "tall patch" topdelta encoding that
/// [decodeDoomPatch] understands, inserting zero-length posts when a jump
/// cannot be expressed in one step.
Uint8List encodeDoomPatch(PatchImage image) {
  final int width = image.width;
  final int height = image.height;
  final Uint8List coverage = image.coverage;
  final Uint8List indices = image.indices;

  final List<Uint8List> columns = <Uint8List>[];
  final List<int> bytes = <int>[];
  for (var x = 0; x < width; x++) {
    bytes.clear();
    var prevTop = -1;
    var y = 0;
    while (y < height) {
      if (coverage[y * width + x] == 0) {
        y++;
        continue;
      }
      var run = 0;
      while (y + run < height && coverage[(y + run) * width + x] != 0) {
        run++;
      }
      var emitted = 0;
      while (emitted < run) {
        final int chunk = run - emitted > 254 ? 254 : run - emitted;
        final int top = y + emitted;
        prevTop = _writeTopDelta(bytes, top, prevTop);
        bytes.add(chunk);
        bytes.add(0); // leading pad byte
        for (var i = 0; i < chunk; i++) {
          bytes.add(indices[(top + i) * width + x]);
        }
        bytes.add(0); // trailing pad byte
        emitted += chunk;
      }
      y += run;
    }
    bytes.add(kPatchPostEnd);
    columns.add(Uint8List.fromList(bytes));
  }

  final int headerBytes = 8 + width * 4;
  var payload = 0;
  for (final Uint8List column in columns) {
    payload += column.lengthInBytes;
  }

  final Uint8List out = Uint8List(headerBytes + payload);
  final ByteData view = ByteData.sublistView(out);
  view.setInt16(0, width, Endian.little);
  view.setInt16(2, height, Endian.little);
  view.setInt16(4, image.leftOffset, Endian.little);
  view.setInt16(6, image.topOffset, Endian.little);

  var cursor = headerBytes;
  for (var x = 0; x < width; x++) {
    view.setInt32(8 + x * 4, cursor, Endian.little);
    out.setRange(cursor, cursor + columns[x].lengthInBytes, columns[x]);
    cursor += columns[x].lengthInBytes;
  }
  return out;
}

/// Appends whatever topdelta bytes are needed to move the decoder's running
/// top from [prevTop] to [top], and returns the new running top.
///
/// The decoder treats a topdelta greater than the running top as absolute and
/// anything else as relative, and 0xFF terminates the column, so a single
/// topdelta byte can carry at most 254.
///
/// Rows up to 254 are therefore one absolute byte. Higher rows are reached by
/// first jumping to 254 absolutely, then adding zero-length posts that each
/// advance by up to 254 until the target is within one step. Callers must emit
/// posts in increasing row order, which the encoder's scan guarantees.
int _writeTopDelta(List<int> bytes, int top, int prevTop) {
  if (top <= _maxTopDelta && top > prevTop) {
    bytes.add(top);
    return top;
  }
  var current = prevTop;
  if (current < _maxTopDelta) {
    // Absolute jump to the highest row a single byte can address.
    bytes.add(_maxTopDelta);
    _writeEmptyPost(bytes);
    current = _maxTopDelta;
  }
  while (top - current > _maxTopDelta) {
    bytes.add(_maxTopDelta);
    _writeEmptyPost(bytes);
    current += _maxTopDelta;
  }
  bytes.add(top - current);
  return top;
}

/// Largest value a topdelta byte can hold; 0xFF is the column terminator.
const int _maxTopDelta = 254;

/// Writes the body of a zero-length post: length, pad, no pixels, pad.
void _writeEmptyPost(List<int> bytes) {
  bytes.add(0);
  bytes.add(0);
  bytes.add(0);
}

/// 64-bit FNV-1a over [bytes].
///
/// Used to pin fixture output in tests. It is not a cryptographic hash; it is
/// stable, dependency-free and sensitive enough that any byte change shows up.
int fnv1a64(Uint8List bytes) {
  // BigInt keeps this exact on Flutter's Wasm build without relying on
  // web-number literals that cannot represent every 64-bit integer.
  // Convert the unsigned accumulator explicitly to the signed low-64 result
  // that the original VM bitwise implementation returned.
  var hash = BigInt.parse('CBF29CE484222325', radix: 16);
  final prime = BigInt.parse('100000001B3', radix: 16);
  final mask = BigInt.parse('FFFFFFFFFFFFFFFF', radix: 16);
  for (var i = 0; i < bytes.length; i++) {
    hash ^= BigInt.from(bytes[i]);
    hash = (hash * prime) & mask;
  }
  final signBit = BigInt.one << 63;
  final signed = hash >= signBit ? hash - (BigInt.one << 64) : hash;
  return signed.toInt();
}
