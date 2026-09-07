import 'dart:typed_data';

import 'failures.dart';
import 'limits.dart';
import 'resources_model.dart';
import 'wad.dart';

/// Bytes in one PNAMES entry.
const int kPatchNameBytes = 8;

/// Bytes in one TEXTUREx patch record.
const int kTexturePatchBytes = 10;

/// Bytes in one TEXTUREx header record, excluding its patch list.
const int kTextureHeaderBytes = 22;

Playpal decodePlaypal(Uint8List lump) {
  final int available = lump.lengthInBytes ~/ kPaletteBytes;
  if (available < 1) {
    throw DoomFormatFailure(
      'PLAYPAL: ${lump.lengthInBytes} bytes holds no complete $kPaletteBytes byte palette',
    );
  }
  final List<Uint8List> palettes = <Uint8List>[];
  for (var i = 0; i < available; i++) {
    final Uint8List palette = Uint8List(kPaletteBytes);
    palette.setRange(0, kPaletteBytes, lump, i * kPaletteBytes);
    palettes.add(palette);
  }
  return Playpal(List<Uint8List>.unmodifiable(palettes));
}

Colormap decodeColormap(Uint8List lump) {
  final int available = lump.lengthInBytes ~/ kColormapBytes;
  if (available < 1) {
    throw DoomFormatFailure(
      'COLORMAP: ${lump.lengthInBytes} bytes holds no complete $kColormapBytes byte map',
    );
  }
  final List<Uint8List> maps = <Uint8List>[];
  for (var i = 0; i < available; i++) {
    final Uint8List map = Uint8List(kColormapBytes);
    map.setRange(0, kColormapBytes, lump, i * kColormapBytes);
    maps.add(map);
  }
  return Colormap(List<Uint8List>.unmodifiable(maps));
}

List<String> decodePatchNames(Uint8List? lump, DoomLimits limits) {
  if (lump == null) {
    return const <String>[];
  }
  if (lump.lengthInBytes < 4) {
    throw const DoomFormatFailure(
      'PNAMES: shorter than its 4 byte count field',
    );
  }
  final int count = ByteData.sublistView(lump).getInt32(0, Endian.little);
  if (count < 0) {
    throw DoomFormatFailure('PNAMES: negative count $count');
  }
  DoomLimits.check(count, limits.maxPatchNames, 'maxPatchNames');
  final int needed = 4 + count * kPatchNameBytes;
  if (needed > lump.lengthInBytes) {
    throw DoomFormatFailure(
      'PNAMES: $count names need $needed bytes but the lump is ${lump.lengthInBytes}',
    );
  }
  final List<String> names = <String>[];
  for (var i = 0; i < count; i++) {
    names.add(decodeLumpName(lump, 4 + i * kPatchNameBytes));
  }
  return names;
}

void readTextureDefinitions(
  Uint8List? lump,
  String lumpName,
  int patchNameCount,
  Map<String, TextureDef> out,
  List<String> order,
  DoomLimits limits,
) {
  if (lump == null) {
    return;
  }
  final int length = lump.lengthInBytes;
  if (length < 4) {
    throw DoomFormatFailure('$lumpName: shorter than its 4 byte count field');
  }
  final ByteData data = ByteData.sublistView(lump);
  final int count = data.getInt32(0, Endian.little);
  if (count < 0) {
    throw DoomFormatFailure('$lumpName: negative texture count $count');
  }
  DoomLimits.check(count, limits.maxTextures, 'maxTextures');
  final int tableEnd = 4 + count * 4;
  if (tableEnd > length) {
    throw DoomFormatFailure(
      '$lumpName: offset table needs $tableEnd bytes but the lump is $length',
    );
  }

  for (var i = 0; i < count; i++) {
    final int start = data.getInt32(4 + i * 4, Endian.little);
    if (start < 0 || start + kTextureHeaderBytes > length) {
      throw DoomFormatFailure(
        '$lumpName: texture $i header at $start is outside the $length byte lump',
      );
    }
    final String name = decodeLumpName(lump, start);
    final int width = data.getInt16(start + 12, Endian.little);
    final int height = data.getInt16(start + 14, Endian.little);
    if (width <= 0 || height <= 0) {
      throw DoomFormatFailure(
        '$lumpName: texture $name has size ${width}x$height',
      );
    }
    DoomLimits.check(
      width * height,
      limits.maxCompositePixels,
      'maxCompositePixels',
    );

    final int patchCount = data.getInt16(start + 20, Endian.little);
    if (patchCount < 0) {
      throw DoomFormatFailure(
        '$lumpName: texture $name has $patchCount patches',
      );
    }
    DoomLimits.check(
      patchCount,
      limits.maxPatchesPerTexture,
      'maxPatchesPerTexture',
    );
    final int patchesEnd =
        start + kTextureHeaderBytes + patchCount * kTexturePatchBytes;
    if (patchesEnd > length) {
      throw DoomFormatFailure(
        '$lumpName: texture $name patch list ends at $patchesEnd, past the $length byte lump',
      );
    }

    final List<TexturePatch> patches = <TexturePatch>[];
    for (var p = 0; p < patchCount; p++) {
      final int record = start + kTextureHeaderBytes + p * kTexturePatchBytes;
      final int patchIndex = data.getInt16(record + 4, Endian.little);
      if (patchIndex < 0 || patchIndex >= patchNameCount) {
        throw DoomFormatFailure(
          '$lumpName: texture $name references patch $patchIndex, outside PNAMES (0..${patchNameCount - 1})',
        );
      }
      patches.add(
        TexturePatch(
          originX: data.getInt16(record, Endian.little),
          originY: data.getInt16(record + 2, Endian.little),
          patchIndex: patchIndex,
        ),
      );
    }

    // R_InitTextures concatenates TEXTURE1 followed by TEXTURE2, and the
    // vanilla name lookup returns the first matching entry. The WAD-set
    // lookup above has already selected a later PWAD's whole TEXTUREx lump;
    // this only preserves first-wins *within* that effective pair.
    if (out.containsKey(name)) {
      continue;
    }
    order.add(name);
    out[name] = TextureDef(
      name: name,
      width: width,
      height: height,
      patches: List<TexturePatch>.unmodifiable(patches),
    );
  }
}
