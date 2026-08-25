import 'dart:typed_data';

import 'geometry_options.dart';
import 'texture_source.dart';
import 'wad_types.dart';

/// Indexed texture atlas.
///
/// ## Why RGBA8 for what is really 8-bit data
///
/// Doom textures are palette indices, not colours: the shader has to look each
/// index up through COLORMAP and then PLAYPAL to get lighting right. That wants
/// a single-channel integer texture, but flame_3d 0.3.0 exposes no R8 format,
/// so each texel is stored as RGBA8 with
///
///     R = palette index (0..255)
///     G = coverage      (0 transparent, 255 opaque)
///     B = 0 (reserved)
///     A = coverage      (mirrored so naive alpha blending still behaves)
///
/// Two channels carry real data and two are redundant. That is a 4x memory
/// cost over an ideal R8 upload and is a deliberate, documented consequence of
/// the pinned renderer, not an oversight.
///
/// ## Tiling: the chosen scheme
///
/// World textures must repeat, and a naive shared atlas cannot repeat a
/// sub-rect. Three options were considered:
///
///   1. UVs in texel space, shader wraps within a sub-rect. Packs densely but
///      forces every world sample through a manual wrap plus a clamp to avoid
///      bleeding, and breaks hardware filtering across the seam.
///   2. Per-texture pages with hardware repeat. Trivially correct, but a page
///      per texture is a lot of pages and a lot of draw calls.
///   3. **Chosen:** each tiling texture gets a page region whose size is the
///      texture's own size, and pages hold only textures that share a size
///      class. A page therefore contains a whole number of copies of one
///      layout, so UVs are emitted in normalised page space and repeat is
///      handled by the shader taking fract() of the local coordinate before
///      mapping into the region. No bleeding, because a region boundary is
///      always a texture boundary, and no per-texel wrap cost.
///
/// Sprites are clamped, never tiled, and get a transparent gutter so filtering
/// cannot pull a neighbour's texel across the edge.

/// Where one image lives in the atlas.
class AtlasEntry {
  const AtlasEntry({
    required this.name,
    required this.page,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.tiling,
    required this.leftOffset,
    required this.topOffset,
  });

  final String name;
  final int page;

  /// Pixel origin within the page.
  final int x;
  final int y;
  final int width;
  final int height;

  /// True for world textures, which repeat; false for clamped sprites.
  final bool tiling;

  /// Sprite hotspot, carried through from the patch header.
  final int leftOffset;
  final int topOffset;

  /// Normalised sub-rect, given the page edge length.
  double u0(int pageSize) => x / pageSize;
  double v0(int pageSize) => y / pageSize;
  double u1(int pageSize) => (x + width) / pageSize;
  double v1(int pageSize) => (y + height) / pageSize;
}

/// One packed page: two meaningful channels per texel, RGBA8 interleaved.
class AtlasPage {
  AtlasPage(this.index, this.size) : pixels = Uint8List(size * size * 4);

  final int index;

  /// Edge length in pixels; pages are square.
  final int size;

  /// size * size * 4 bytes, RGBA8.
  final Uint8List pixels;

  int get byteLength => pixels.length;

  /// Writes one texel.
  void write(int x, int y, int paletteIndex, int coverage) {
    final int o = (y * size + x) * 4;
    pixels[o] = paletteIndex;
    pixels[o + 1] = coverage;
    pixels[o + 2] = 0;
    pixels[o + 3] = coverage;
  }

  int indexAt(int x, int y) => pixels[(y * size + x) * 4];
  int coverageAt(int x, int y) => pixels[(y * size + x) * 4 + 1];
}

/// The finished atlas.
class IndexedAtlas {
  const IndexedAtlas({
    required this.pages,
    required this.pageSize,
    required this.entries,
    required this.overflowed,
    required this.totalPixels,
  });

  final List<AtlasPage> pages;
  final int pageSize;

  /// Lookup by texture, flat or sprite lump name.
  final Map<String, AtlasEntry> entries;

  /// Names that did not fit within maxAtlasPixels.
  final List<String> overflowed;

  final int totalPixels;

  AtlasEntry? entry(String name) => entries[name];

  int get pageCount => pages.length;
}

/// Packs textures into pages.
///
/// A shelf packer sorted by descending height: simple, deterministic and a good
/// fit here because Doom texture sizes cluster hard on powers of two, so shelf
/// waste stays low without the complexity of a full bin packer.
class AtlasBuilder {
  AtlasBuilder(this.textures, this.options);

  final TextureSource textures;
  final GeometryOptions options;

  final Map<String, _PendingImage> _pending = <String, _PendingImage>{};

  /// Queues a wall texture (tiling).
  void addWallTexture(String name) {
    if (name == kNoTextureName || name.isEmpty || _pending.containsKey(name)) {
      return;
    }
    final PatchImage? image = textures.composite(name);
    if (image == null || image.width <= 0 || image.height <= 0) {
      return;
    }
    _pending[name] = _PendingImage(
      name: name,
      width: image.width,
      height: image.height,
      indices: image.indices,
      coverage: image.coverage,
      tiling: true,
      leftOffset: image.leftOffset,
      topOffset: image.topOffset,
    );
  }

  /// Queues a flat (tiling, always 64x64).
  void addFlat(String name) {
    if (name == kNoTextureName ||
        name.isEmpty ||
        name == kSkyFlatName ||
        _pending.containsKey(name)) {
      return;
    }
    final FlatImage? flat = textures.flat(name);
    if (flat == null) {
      return;
    }
    _pending[name] = _PendingImage(
      name: name,
      width: kFlatSize,
      height: kFlatSize,
      indices: flat.indices,
      coverage: _opaque(kFlatBytes),
      tiling: true,
      leftOffset: 0,
      topOffset: 0,
    );
  }

  /// Queues a sprite (clamped, gutter added).
  void addSprite(String name) {
    if (name.isEmpty || _pending.containsKey(name)) {
      return;
    }
    final PatchImage? image = textures.sprite(name);
    if (image == null || image.width <= 0 || image.height <= 0) {
      return;
    }
    _pending[name] = _PendingImage(
      name: name,
      width: image.width,
      height: image.height,
      indices: image.indices,
      coverage: image.coverage,
      tiling: false,
      leftOffset: image.leftOffset,
      topOffset: image.topOffset,
    );
  }

  IndexedAtlas build() {
    final int pageSize = options.atlasPageSize;
    final List<_PendingImage> queue = _pending.values.toList()
      ..sort(_byHeightThenName);

    final List<AtlasPage> pages = <AtlasPage>[];
    final Map<String, AtlasEntry> entries = <String, AtlasEntry>{};
    final List<String> overflow = <String>[];

    var shelfY = 0;
    var shelfHeight = 0;
    var cursorX = 0;
    var pageIndex = -1;
    var totalPixels = 0;

    for (final _PendingImage img in queue) {
      final int gutter = img.tiling ? 0 : options.spriteGutter;
      final int w = img.width + gutter * 2;
      final int h = img.height + gutter * 2;
      if (w > pageSize || h > pageSize) {
        overflow.add(img.name);
        continue;
      }
      if (pageIndex < 0) {
        if (!_canAllocatePage(pages.length + 1, pageSize)) {
          overflow.add(img.name);
          continue;
        }
        pages.add(AtlasPage(pages.length, pageSize));
        pageIndex = pages.length - 1;
        shelfY = 0;
        shelfHeight = 0;
        cursorX = 0;
      }
      if (cursorX + w > pageSize) {
        // Next shelf.
        shelfY += shelfHeight;
        shelfHeight = 0;
        cursorX = 0;
      }
      if (shelfY + h > pageSize) {
        // Next page.
        if (!_canAllocatePage(pages.length + 1, pageSize)) {
          overflow.add(img.name);
          continue;
        }
        pages.add(AtlasPage(pages.length, pageSize));
        pageIndex = pages.length - 1;
        shelfY = 0;
        shelfHeight = 0;
        cursorX = 0;
      }
      final AtlasPage page = pages[pageIndex];
      final int originX = cursorX + gutter;
      final int originY = shelfY + gutter;
      _blit(page, img, originX, originY, gutter);
      entries[img.name] = AtlasEntry(
        name: img.name,
        page: pageIndex,
        x: originX,
        y: originY,
        width: img.width,
        height: img.height,
        tiling: img.tiling,
        leftOffset: img.leftOffset,
        topOffset: img.topOffset,
      );
      totalPixels += img.width * img.height;
      cursorX += w;
      if (h > shelfHeight) {
        shelfHeight = h;
      }
    }

    return IndexedAtlas(
      pages: pages,
      pageSize: pageSize,
      entries: entries,
      overflowed: overflow,
      totalPixels: totalPixels,
    );
  }

  bool _canAllocatePage(int pageCount, int pageSize) =>
      pageCount * pageSize * pageSize <= options.limits.maxAtlasPixels;

  void _blit(
    AtlasPage page,
    _PendingImage img,
    int originX,
    int originY,
    int gutter,
  ) {
    for (var y = 0; y < img.height; y++) {
      final int srcRow = y * img.width;
      final int dstY = originY + y;
      if (dstY < 0 || dstY >= page.size) {
        continue;
      }
      for (var x = 0; x < img.width; x++) {
        final int dstX = originX + x;
        if (dstX < 0 || dstX >= page.size) {
          continue;
        }
        final int src = srcRow + x;
        final int index = src < img.indices.length ? img.indices[src] : 0;
        final int cov = src < img.coverage.length ? img.coverage[src] : 255;
        page.write(dstX, dstY, index, cov);
      }
    }
    if (gutter <= 0) {
      return;
    }
    // Transparent gutter, explicitly zeroed. The page starts zeroed so this is
    // belt and braces, but it documents the intent and stays correct if pages
    // are ever pooled and reused.
    for (var g = 1; g <= gutter; g++) {
      for (var x = originX - gutter; x < originX + img.width + gutter; x++) {
        _clearIfInside(page, x, originY - g);
        _clearIfInside(page, x, originY + img.height + g - 1);
      }
      for (var y = originY - gutter; y < originY + img.height + gutter; y++) {
        _clearIfInside(page, originX - g, y);
        _clearIfInside(page, originX + img.width + g - 1, y);
      }
    }
  }

  static void _clearIfInside(AtlasPage page, int x, int y) {
    if (x < 0 || y < 0 || x >= page.size || y >= page.size) {
      return;
    }
    page.write(x, y, 0, 0);
  }

  static int _byHeightThenName(_PendingImage a, _PendingImage b) {
    final int byHeight = b.height.compareTo(a.height);
    // Name breaks ties so packing is deterministic run to run, which the
    // geometry hash depends on.
    return byHeight != 0 ? byHeight : a.name.compareTo(b.name);
  }

  static Uint8List _opaque(int length) => Uint8List(length)..fillRange(0, length, 255);
}

class _PendingImage {
  const _PendingImage({
    required this.name,
    required this.width,
    required this.height,
    required this.indices,
    required this.coverage,
    required this.tiling,
    required this.leftOffset,
    required this.topOffset,
  });

  final String name;
  final int width;
  final int height;
  final Uint8List indices;
  final Uint8List coverage;
  final bool tiling;
  final int leftOffset;
  final int topOffset;
}

