import 'dart:math' as math;
import 'dart:typed_data';

import 'failures.dart';
import 'limits.dart';
import 'resources_model.dart';
import 'wad.dart';

/// Lumps that open the flat namespace. Vanilla only uses F_START, but PWADs
/// and merge tools emit the FF_ and F1_/F2_/F3_ variants.
const List<String> kFlatStartMarkers = <String>[
  'F_START',
  'FF_START',
  'F1_START',
  'F2_START',
  'F3_START',
];

/// Lumps that close the flat namespace.
const List<String> kFlatEndMarkers = <String>[
  'F_END',
  'FF_END',
  'F1_END',
  'F2_END',
  'F3_END',
];

/// Lumps that open the sprite namespace.
const List<String> kSpriteStartMarkers = <String>['S_START', 'SS_START'];

/// Lumps that close the sprite namespace.
const List<String> kSpriteEndMarkers = <String>['S_END', 'SS_END'];

/// Post terminator in the column-post patch encoding.
const int kPatchPostEnd = 0xFF;

/// Bytes in one PNAMES entry.
const int kPatchNameBytes = 8;

/// Bytes in one TEXTUREx patch record.
const int kTexturePatchBytes = 10;

/// Bytes in one TEXTUREx header record, excluding its patch list.
const int kTextureHeaderBytes = 22;

/// Decodes a Doom patch lump into a row-major [PatchImage].
///
/// The on-disk layout is a header, then one 32-bit file offset per column,
/// then each column as a chain of posts: a topdelta byte, a length byte, a
/// pad byte, the pixels, and a trailing pad byte. A topdelta of 0xFF ends the
/// column.
///
/// Two vanilla quirks are handled:
///
///  * Tall patches. The topdelta byte cannot address rows past 254, so patches
///    taller than that encode later posts as deltas relative to the previous
///    post: whenever a topdelta is not greater than the previous absolute top,
///    it is added to it instead of replacing it. Patches under 255 rows have
///    strictly increasing topdeltas and are unaffected.
///  * Posts that run past the declared height. Vanilla clips them; rows
///    outside the image are dropped rather than treated as corruption.
///
/// Throws [DoomFormatFailure] on a structurally invalid lump.
PatchImage decodeDoomPatch(
  Uint8List lump, {
  String? name,
  DoomLimits limits = DoomLimits.defaults,
}) {
  final String label = name ?? 'patch';
  final int length = lump.lengthInBytes;
  if (length < 8) {
    throw DoomFormatFailure('$label: only $length bytes, too short for a patch header');
  }
  final ByteData data = ByteData.sublistView(lump);
  final int width = data.getInt16(0, Endian.little);
  final int height = data.getInt16(2, Endian.little);
  final int leftOffset = data.getInt16(4, Endian.little);
  final int topOffset = data.getInt16(6, Endian.little);

  if (width <= 0 || height <= 0) {
    throw DoomFormatFailure('$label: bad dimensions ${width}x$height');
  }
  DoomLimits.check(width * height, limits.maxCompositePixels, 'maxCompositePixels');

  final int tableEnd = 8 + width * 4;
  if (tableEnd > length) {
    throw DoomFormatFailure(
      '$label: column table needs $tableEnd bytes but the lump is $length',
    );
  }

  final Uint8List indices = Uint8List(width * height);
  final Uint8List coverage = Uint8List(width * height);

  for (var x = 0; x < width; x++) {
    final int columnStart = data.getInt32(8 + x * 4, Endian.little);
    if (columnStart < 0 || columnStart >= length) {
      throw DoomFormatFailure(
        '$label: column $x points to $columnStart, outside the $length byte lump',
      );
    }
    var cursor = columnStart;
    var top = -1;
    while (true) {
      if (cursor >= length) {
        throw DoomFormatFailure('$label: column $x runs past the end of the lump');
      }
      final int topDelta = lump[cursor];
      if (topDelta == kPatchPostEnd) {
        break;
      }
      if (cursor + 3 > length) {
        throw DoomFormatFailure('$label: truncated post header in column $x');
      }
      final int postLength = lump[cursor + 1];
      // Tall-patch rule: a non-increasing topdelta continues the previous post.
      top = topDelta <= top ? top + topDelta : topDelta;
      final int pixels = cursor + 3;
      final int postEnd = pixels + postLength + 1;
      if (postEnd > length) {
        throw DoomFormatFailure(
          '$label: post in column $x ends at $postEnd, past the $length byte lump',
        );
      }
      // Clip to the declared height instead of rejecting overlong posts.
      var first = 0;
      if (top < 0) {
        first = -top;
      }
      var last = postLength;
      if (top + last > height) {
        last = height - top;
      }
      for (var i = first; i < last; i++) {
        final int target = (top + i) * width + x;
        indices[target] = lump[pixels + i];
        coverage[target] = 255;
      }
      cursor = postEnd;
    }
  }

  return PatchImage(
    width: width,
    height: height,
    leftOffset: leftOffset,
    topOffset: topOffset,
    indices: indices,
    coverage: coverage,
  );
}

/// Every decoded graphic in a [WadSet]: palettes, textures, flats and sprites.
///
/// Palettes, colormaps and the texture directory are decoded eagerly because
/// they are small and every consumer needs them. Patches, flats, sprites and
/// composite textures are decoded on first use and memoised, so loading a WAD
/// stays cheap even when a level only touches a handful of textures.
class WadResources {
  WadResources._({
    required WadSet wadSet,
    required DoomLimits budgets,
    required this.playpal,
    required this.colormap,
    required List<String> names,
    required Map<String, TextureDef> textureMap,
    required List<String> order,
    required Map<String, int> flats,
    required Map<String, int> sprites,
  })  : _set = wadSet,
        _limits = budgets,
        patchNames = List<String>.unmodifiable(names),
        _textures = textureMap,
        textureNames = List<String>.unmodifiable(order),
        _flatIndices = flats,
        _spriteIndices = sprites;

  final WadSet _set;
  final DoomLimits _limits;

  /// The 14 game palettes.
  final Playpal playpal;

  /// The 34 light and effect maps.
  final Colormap colormap;

  /// PNAMES contents, in index order. Texture patch references index this.
  final List<String> patchNames;

  final Map<String, TextureDef> _textures;

  /// Texture names in TEXTURE1-then-TEXTURE2 declaration order.
  final List<String> textureNames;

  final Map<String, int> _flatIndices;
  final Map<String, int> _spriteIndices;

  final Map<int, PatchImage?> _patchCache = <int, PatchImage?>{};
  final Map<String, PatchImage?> _compositeCache = <String, PatchImage?>{};
  final Map<String, FlatImage?> _flatCache = <String, FlatImage?>{};
  final Map<String, PatchImage?> _spriteCache = <String, PatchImage?>{};

  /// Decodes the resource lumps of [set].
  ///
  /// PLAYPAL and COLORMAP are mandatory and raise [DoomMissingLumpFailure] when
  /// absent. PNAMES and TEXTURE1/TEXTURE2 are optional so that a bare map PWAD
  /// still loads; the texture directory is then simply empty.
  static WadResources load(
    WadSet set, {
    DoomLimits limits = DoomLimits.defaults,
  }) {
    final Playpal playpal = _decodePlaypal(set.require('PLAYPAL'));
    final Colormap colormap = _decodeColormap(set.require('COLORMAP'));
    final List<String> patchNames = _decodePnames(set.read('PNAMES'), limits);

    final Map<String, TextureDef> textures = <String, TextureDef>{};
    final List<String> order = <String>[];
    _decodeTextureLump(set.read('TEXTURE1'), 'TEXTURE1', patchNames.length, textures, order, limits);
    _decodeTextureLump(set.read('TEXTURE2'), 'TEXTURE2', patchNames.length, textures, order, limits);
    DoomLimits.check(textures.length, limits.maxTextures, 'maxTextures');

    return WadResources._(
      wadSet: set,
      budgets: limits,
      playpal: playpal,
      colormap: colormap,
      names: patchNames,
      textureMap: textures,
      order: order,
      flats: _collectNamespace(set, kFlatStartMarkers, kFlatEndMarkers),
      sprites: _collectNamespace(set, kSpriteStartMarkers, kSpriteEndMarkers),
    );
  }

  /// Flat names found in the flat namespace, sorted.
  List<String> get flatNames {
    final List<String> names = _flatIndices.keys.toList(growable: false)..sort();
    return names;
  }

  /// Sprite lump names found in the sprite namespace, sorted.
  List<String> get spriteNames {
    final List<String> names = _spriteIndices.keys.toList(growable: false)..sort();
    return names;
  }

  /// Texture directory entry for [name], or null when it is unknown or '-'.
  TextureDef? textureDef(String name) {
    final String key = normaliseLumpName(name);
    if (key.isEmpty || key == kNoTextureName) {
      return null;
    }
    return _textures[key];
  }

  /// Composes [textureName] from its patch list, memoised.
  ///
  /// Returns null for '-' (the "no texture" sentinel) and for names absent from
  /// TEXTURE1/TEXTURE2. Patches the WAD set does not contain are skipped, which
  /// leaves that region transparent instead of failing the whole level.
  PatchImage? composite(String textureName) {
    final String key = normaliseLumpName(textureName);
    if (key.isEmpty || key == kNoTextureName) {
      return null;
    }
    final PatchImage? cached = _compositeCache[key];
    if (cached != null || _compositeCache.containsKey(key)) {
      return cached;
    }
    final TextureDef? def = _textures[key];
    if (def == null) {
      _compositeCache[key] = null;
      return null;
    }

    final int width = def.width;
    final int height = def.height;
    final Uint8List indices = Uint8List(width * height);
    final Uint8List coverage = Uint8List(width * height);

    for (final TexturePatch placement in def.patches) {
      final PatchImage? patch = patchAt(placement.patchIndex);
      if (patch == null) {
        continue;
      }
      _blit(patch, placement.originX, placement.originY, indices, coverage, width, height);
    }

    final PatchImage composed = PatchImage(
      width: width,
      height: height,
      leftOffset: 0,
      topOffset: 0,
      indices: indices,
      coverage: coverage,
    );
    _compositeCache[key] = composed;
    return composed;
  }

  /// Decoded patch for PNAMES entry [index], memoised. Null when the index is
  /// out of range or the named lump is not present in the set.
  PatchImage? patchAt(int index) {
    if (index < 0 || index >= patchNames.length) {
      return null;
    }
    final PatchImage? cached = _patchCache[index];
    if (cached != null || _patchCache.containsKey(index)) {
      return cached;
    }
    final int? lump = _set.indexOf(patchNames[index]);
    if (lump == null) {
      _patchCache[index] = null;
      return null;
    }
    final PatchImage decoded = decodeDoomPatch(
      _set.bytesAt(lump),
      name: patchNames[index],
      limits: _limits,
    );
    _patchCache[index] = decoded;
    return decoded;
  }

  /// Decoded patch for the PNAMES entry called [name], or null.
  PatchImage? patchByName(String name) {
    final String key = normaliseLumpName(name);
    final int index = patchNames.indexOf(key);
    return index < 0 ? null : patchAt(index);
  }

  /// 64x64 flat named [name], memoised.
  ///
  /// Looks in the flat namespace first, then falls back to a plain lump lookup
  /// so flats dropped outside F_START/F_END still resolve. Returns null for '-'
  /// and for names with no usable lump.
  FlatImage? flat(String name) {
    final String key = normaliseLumpName(name);
    if (key.isEmpty || key == kNoTextureName) {
      return null;
    }
    final FlatImage? cached = _flatCache[key];
    if (cached != null || _flatCache.containsKey(key)) {
      return cached;
    }
    int? lump = _flatIndices[key];
    lump ??= _set.indexOf(key);
    if (lump == null) {
      _flatCache[key] = null;
      return null;
    }
    final Uint8List bytes = _set.bytesAt(lump);
    if (bytes.lengthInBytes < kFlatBytes) {
      _flatCache[key] = null;
      return null;
    }
    final Uint8List plane = Uint8List(kFlatBytes);
    plane.setRange(0, kFlatBytes, bytes);
    final FlatImage decoded = FlatImage(name: key, indices: plane);
    _flatCache[key] = decoded;
    return decoded;
  }

  /// Sprite frame [lumpName] decoded as a patch, memoised.
  PatchImage? sprite(String lumpName) {
    final String key = normaliseLumpName(lumpName);
    if (key.isEmpty) {
      return null;
    }
    final PatchImage? cached = _spriteCache[key];
    if (cached != null || _spriteCache.containsKey(key)) {
      return cached;
    }
    final int? lump = _spriteIndices[key];
    if (lump == null) {
      _spriteCache[key] = null;
      return null;
    }
    final PatchImage decoded = decodeDoomPatch(
      _set.bytesAt(lump),
      name: key,
      limits: _limits,
    );
    _spriteCache[key] = decoded;
    return decoded;
  }

  /// Copies the opaque pixels of [patch] onto a composite canvas, clipping to
  /// the canvas on every edge. Kept as a flat loop over typed lists: this is
  /// the hottest path in resource loading.
  static void _blit(
    PatchImage patch,
    int originX,
    int originY,
    Uint8List indices,
    Uint8List coverage,
    int width,
    int height,
  ) {
    final int patchWidth = patch.width;
    final Uint8List src = patch.indices;
    final Uint8List srcCoverage = patch.coverage;
    final int firstX = math.max(0, -originX);
    final int lastX = math.min(patchWidth, width - originX);
    final int firstY = math.max(0, -originY);
    final int lastY = math.min(patch.height, height - originY);
    for (var y = firstY; y < lastY; y++) {
      final int srcRow = y * patchWidth;
      final int dstRow = (originY + y) * width + originX;
      for (var x = firstX; x < lastX; x++) {
        if (srcCoverage[srcRow + x] != 0) {
          final int target = dstRow + x;
          indices[target] = src[srcRow + x];
          coverage[target] = 255;
        }
      }
    }
  }

  static Playpal _decodePlaypal(Uint8List lump) {
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

  static Colormap _decodeColormap(Uint8List lump) {
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

  static List<String> _decodePnames(Uint8List? lump, DoomLimits limits) {
    if (lump == null) {
      return const <String>[];
    }
    if (lump.lengthInBytes < 4) {
      throw const DoomFormatFailure('PNAMES: shorter than its 4 byte count field');
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

  static void _decodeTextureLump(
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
        throw DoomFormatFailure('$lumpName: texture $name has size ${width}x$height');
      }
      DoomLimits.check(width * height, limits.maxCompositePixels, 'maxCompositePixels');

      final int patchCount = data.getInt16(start + 20, Endian.little);
      if (patchCount < 0) {
        throw DoomFormatFailure('$lumpName: texture $name has $patchCount patches');
      }
      DoomLimits.check(patchCount, limits.maxPatchesPerTexture, 'maxPatchesPerTexture');
      final int patchesEnd = start + kTextureHeaderBytes + patchCount * kTexturePatchBytes;
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

      if (!out.containsKey(name)) {
        order.add(name);
      }
      out[name] = TextureDef(
        name: name,
        width: width,
        height: height,
        patches: List<TexturePatch>.unmodifiable(patches),
      );
    }
  }

  /// Maps lump name to flat index for every payload lump between a start and an
  /// end marker. Later entries overwrite earlier ones, so a PWAD appended after
  /// an IWAD replaces the IWAD's flats and sprites.
  static Map<String, int> _collectNamespace(
    WadSet set,
    List<String> startMarkers,
    List<String> endMarkers,
  ) {
    final Map<String, int> found = <String, int>{};
    var depth = 0;
    for (var i = 0; i < set.length; i++) {
      final String name = set.nameAt(i);
      if (startMarkers.contains(name)) {
        depth++;
        continue;
      }
      if (endMarkers.contains(name)) {
        if (depth > 0) {
          depth--;
        }
        continue;
      }
      if (depth > 0 && set.entryAt(i).size > 0) {
        found[name] = i;
      }
    }
    return found;
  }
}
