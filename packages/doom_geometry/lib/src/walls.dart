import 'dart:math' as math;

import 'geometry_options.dart';
import 'packed_mesh.dart';
import 'texture_source.dart';
import 'wad_types.dart';

/// Wall geometry, derived from LINEDEFS and SIDEDEFS rather than SEGS.
///
/// Building walls from linedefs instead of segs is deliberate. Segs are split
/// by the node builder, so one wall would arrive as several fragments, each
/// needing its own texture offset continuation and each contributing extra
/// vertices and a seam. A linedef is the unit the texture was authored
/// against, so one linedef becomes one quad per visible band and the alignment
/// maths is the plain vanilla rule with nothing to reconcile.
///
/// ## Which bands exist
///
/// A one-sided linedef contributes a single [WallBandKind.solid] quad spanning
/// its sector's floor to ceiling.
///
/// A two-sided linedef contributes up to three:
///   * [WallBandKind.lower] where the far floor is higher than the near one,
///   * [WallBandKind.upper] where the far ceiling is lower than the near one,
///   * [WallBandKind.middle] whenever the sidedef names a middle texture,
///     drawn inside the opening and masked.
///
/// ## Texture alignment
///
/// Horizontal: texels advance with distance along the linedef from its start
/// vertex, offset by the sidedef's x offset. Because walls are whole linedefs
/// here, the accumulated distance is simply 0 at v1 and the linedef length at
/// v2.
///
/// Vertical: a texture normally hangs DOWN from the top of its band. The
/// unpegged flags move the anchor to the bottom instead:
///   * lower band, lower-unpegged: anchor at the near ceiling rather than the
///     higher floor, which is what stops a lift's side texture from sliding.
///   * upper band, upper-unpegged: anchor at the near ceiling, drawing
///     downwards, rather than hanging from the far ceiling.
///   * one-sided, lower-unpegged: anchor at the floor, so the texture's bottom
///     row sits on the floor regardless of room height.
/// The sidedef's y offset is added on top in every case.
///
/// ## Sky
///
/// When both sectors of a two-sided line have a sky ceiling, the upper band is
/// NOT drawn: vanilla lets the sky show through so a room boundary under open
/// sky has no visible lip. One-sided walls in a sky sector still draw normally.

/// One wall quad ready to be packed.
class WallQuad {
  const WallQuad({
    required this.linedef,
    required this.sidedef,
    required this.band,
    required this.kind,
    required this.frontSector,
    required this.backSector,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.bottom,
    required this.top,
    required this.texture,
    required this.textureWidth,
    required this.textureHeight,
    required this.uLeft,
    required this.uRight,
    required this.yOffset,
    required this.rawYOffset,
    required this.nearCeiling,
    required this.lowerUnpegged,
    required this.upperUnpegged,
    required this.lightLevel,
  });

  final int linedef;
  final int sidedef;
  final WallBandKind band;
  final SurfaceKind kind;
  final int frontSector;

  /// -1 for a one-sided wall.
  final int backSector;

  /// Endpoints in map space, ordered so the sector this side faces is on the
  /// right of v1 -> v2.
  final double x1;
  final double y1;
  final double x2;
  final double y2;

  final double bottom;
  final double top;

  /// Texture name, or '-' when the band has no texture.
  final String texture;
  final double textureWidth;
  final double textureHeight;

  /// Horizontal texel coordinates at the two ends, before atlas mapping.
  final double uLeft;
  final double uRight;

  /// Vertical texel coordinate at the TOP of the band.
  final double yOffset;

  /// Raw sidedef row offset, before band-specific pegging.
  final double rawYOffset;

  /// Near-sector ceiling used by lower-unpegged anchoring.
  final double nearCeiling;

  final bool lowerUnpegged;
  final bool upperUnpegged;

  /// 0..1 sector light with fake contrast already applied.
  final double lightLevel;

  double get height => top - bottom;
  bool get isDegenerate => height <= 0 || (x1 == x2 && y1 == y2);
  bool get hasTexture => texture != kNoTextureName && texture.isNotEmpty;
}

/// Result of a wall pass over a whole map.
class WallSet {
  const WallSet({
    required this.quads,
    required this.skippedSkyUppers,
    required this.missingTextures,
    required this.degenerateQuads,
  });

  final List<WallQuad> quads;

  /// Upper bands suppressed because both sides are sky.
  final int skippedSkyUppers;

  /// Texture names the map asked for that the WAD set does not contain.
  final Set<String> missingTextures;

  final int degenerateQuads;
}

/// Builds wall quads for a map.
class WallBuilder {
  WallBuilder(this.map, this.textures, this.options);

  final MapData map;
  final TextureSource textures;
  final GeometryOptions options;

  WallSet build() {
    final List<WallQuad> quads = <WallQuad>[];
    final Set<String> missing = <String>{};
    var skySkipped = 0;
    var degenerate = 0;

    for (var i = 0; i < map.linedefs.length; i++) {
      final Linedef line = map.linedefs[i];
      if (line.v1 < 0 ||
          line.v2 < 0 ||
          line.v1 >= map.vertices.length ||
          line.v2 >= map.vertices.length) {
        continue;
      }
      final MapVertex a = map.vertices[line.v1];
      final MapVertex b = map.vertices[line.v2];
      final double ax = a.x.toDouble();
      final double ay = a.y.toDouble();
      final double bx = b.x.toDouble();
      final double by = b.y.toDouble();
      final double length = math.sqrt(
        (bx - ax) * (bx - ax) + (by - ay) * (by - ay),
      );
      if (length <= 0) {
        degenerate++;
        continue;
      }
      final double contrast = _fakeContrast(bx - ax, by - ay);

      final Sidedef? front = _sidedef(line.rightSidedef);
      final Sidedef? back = _sidedef(line.leftSidedef);

      if (front != null && back == null) {
        _emitSolid(
          quads,
          missing,
          line: line,
          index: i,
          side: front,
          sidedefIndex: line.rightSidedef,
          ax: ax,
          ay: ay,
          bx: bx,
          by: by,
          length: length,
          contrast: contrast,
        );
        continue;
      }
      if (front == null) {
        continue;
      }
      if (back == null) {
        continue;
      }
      // Front side faces along v1 -> v2; the back side faces the other way, so
      // its quad is emitted with the endpoints swapped and that is what keeps
      // its texture running in the direction the author intended.
      skySkipped += _emitTwoSided(
        quads,
        missing,
        line: line,
        index: i,
        near: front,
        far: back,
        nearIndex: line.rightSidedef,
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
        length: length,
        contrast: contrast,
      );
      skySkipped += _emitTwoSided(
        quads,
        missing,
        line: line,
        index: i,
        near: back,
        far: front,
        nearIndex: line.leftSidedef,
        ax: bx,
        ay: by,
        bx: ax,
        by: ay,
        length: length,
        contrast: contrast,
      );
    }
    return WallSet(
      quads: quads,
      skippedSkyUppers: skySkipped,
      missingTextures: missing,
      degenerateQuads: degenerate,
    );
  }

  Sidedef? _sidedef(int index) {
    if (index == kNoSidedef || index < 0 || index >= map.sidedefs.length) {
      return null;
    }
    return map.sidedefs[index];
  }

  Sector? _sector(int index) {
    if (index == kNoSector || index < 0 || index >= map.sectors.length) {
      return null;
    }
    return map.sectors[index];
  }

  void _emitSolid(
    List<WallQuad> out,
    Set<String> missing, {
    required Linedef line,
    required int index,
    required Sidedef side,
    required int sidedefIndex,
    required double ax,
    required double ay,
    required double bx,
    required double by,
    required double length,
    required double contrast,
  }) {
    final Sector? sector = _sector(side.sector);
    if (sector == null) {
      return;
    }
    final double floor = sector.floorHeight.toDouble();
    final double ceiling = sector.ceilingHeight.toDouble();
    if (ceiling <= floor) {
      return;
    }
    final _TexSize size = _sizeOf(side.middleTexture, missing);
    // One-sided: pegged to the ceiling normally, to the floor when
    // lower-unpegged.
    final double top = line.lowerUnpegged
        ? side.yOffset + size.height - (ceiling - floor)
        : side.yOffset.toDouble();
    out.add(
      WallQuad(
        linedef: index,
        sidedef: sidedefIndex,
        band: WallBandKind.solid,
        kind: SurfaceKind.opaque,
        frontSector: side.sector,
        backSector: -1,
        x1: ax,
        y1: ay,
        x2: bx,
        y2: by,
        bottom: floor,
        top: ceiling,
        texture: side.middleTexture,
        textureWidth: size.width,
        textureHeight: size.height,
        uLeft: side.xOffset.toDouble(),
        uRight: side.xOffset + length,
        yOffset: top,
        rawYOffset: side.yOffset.toDouble(),
        nearCeiling: ceiling,
        lowerUnpegged: line.lowerUnpegged,
        upperUnpegged: line.upperUnpegged,
        lightLevel: _light(sector, contrast),
      ),
    );
  }

  /// Emits the bands visible from one side of a two-sided linedef.
  /// Returns the number of sky uppers suppressed.
  int _emitTwoSided(
    List<WallQuad> out,
    Set<String> missing, {
    required Linedef line,
    required int index,
    required Sidedef near,
    required Sidedef far,
    required int nearIndex,
    required double ax,
    required double ay,
    required double bx,
    required double by,
    required double length,
    required double contrast,
  }) {
    final Sector? nearSector = _sector(near.sector);
    final Sector? farSector = _sector(far.sector);
    if (nearSector == null || farSector == null) {
      return 0;
    }
    final double nearFloor = nearSector.floorHeight.toDouble();
    final double nearCeil = nearSector.ceilingHeight.toDouble();
    final double farFloor = farSector.floorHeight.toDouble();
    final double farCeil = farSector.ceilingHeight.toDouble();
    final double light = _light(nearSector, contrast);
    var skySkipped = 0;

    // Lower band: the far floor stands above the near one.
    final bool mayMove = line.special != 0 || line.tag != 0;
    if ((farFloor > nearFloor || mayMove) &&
        near.lowerTexture != kNoTextureName) {
      final _TexSize size = _sizeOf(near.lowerTexture, missing);
      // Pegged to the top of the step; lower-unpegged anchors at the near
      // ceiling instead, so a rising lift's texture stays put.
      final double top = line.lowerUnpegged
          ? near.yOffset + (nearCeil - farFloor)
          : near.yOffset.toDouble();
      out.add(
        WallQuad(
          linedef: index,
          sidedef: nearIndex,
          band: WallBandKind.lower,
          kind: SurfaceKind.opaque,
          frontSector: near.sector,
          backSector: far.sector,
          x1: ax,
          y1: ay,
          x2: bx,
          y2: by,
          bottom: nearFloor,
          top: farFloor > nearFloor ? farFloor : nearFloor,
          texture: near.lowerTexture,
          textureWidth: size.width,
          textureHeight: size.height,
          uLeft: near.xOffset.toDouble(),
          uRight: near.xOffset + length,
          yOffset: top,
          rawYOffset: near.yOffset.toDouble(),
          nearCeiling: nearCeil,
          lowerUnpegged: line.lowerUnpegged,
          upperUnpegged: line.upperUnpegged,
          lightLevel: light,
        ),
      );
    }

    // Upper band: the far ceiling hangs below the near one.
    if (farCeil < nearCeil || mayMove) {
      if (nearSector.ceilingIsSky && farSector.ceilingIsSky) {
        // Both sides open to sky: vanilla draws nothing here so the sky runs
        // continuously across the boundary.
        if (farCeil < nearCeil) {
          skySkipped++;
        }
      } else if (near.upperTexture != kNoTextureName) {
        final _TexSize size = _sizeOf(near.upperTexture, missing);
        // Hangs from the far ceiling; upper-unpegged anchors at the near
        // ceiling and draws downwards.
        final double top = line.upperUnpegged
            ? near.yOffset.toDouble()
            : near.yOffset + size.height - (nearCeil - farCeil);
        out.add(
          WallQuad(
            linedef: index,
            sidedef: nearIndex,
            band: WallBandKind.upper,
            kind: SurfaceKind.opaque,
            frontSector: near.sector,
            backSector: far.sector,
            x1: ax,
            y1: ay,
            x2: bx,
            y2: by,
            bottom: farCeil < nearCeil ? farCeil : nearCeil,
            top: nearCeil,
            texture: near.upperTexture,
            textureWidth: size.width,
            textureHeight: size.height,
            uLeft: near.xOffset.toDouble(),
            uRight: near.xOffset + length,
            yOffset: top,
            rawYOffset: near.yOffset.toDouble(),
            nearCeiling: nearCeil,
            lowerUnpegged: line.lowerUnpegged,
            upperUnpegged: line.upperUnpegged,
            lightLevel: light,
          ),
        );
      }
    }

    // Middle band: an optional masked texture hung in the opening.
    if (near.middleTexture != kNoTextureName) {
      final _TexSize size = _sizeOf(near.middleTexture, missing);
      final double openBottom = nearFloor > farFloor ? nearFloor : farFloor;
      final double openTop = nearCeil < farCeil ? nearCeil : farCeil;
      if ((openTop > openBottom || mayMove) && size.height > 0) {
        // A midtexture does not tile vertically in vanilla: it is drawn once,
        // clipped to the opening. Lower-unpegged hangs it from the bottom of
        // the opening upwards, otherwise from the top downwards.
        final double drawTop = line.lowerUnpegged
            ? openBottom + size.height + near.yOffset
            : openTop + near.yOffset;
        final double drawBottom = drawTop - size.height;
        final double clampedTop = drawTop < openTop ? drawTop : openTop;
        final double clampedBottom = drawBottom > openBottom
            ? drawBottom
            : openBottom;
        out.add(
          WallQuad(
            linedef: index,
            sidedef: nearIndex,
            band: WallBandKind.middle,
            kind: SurfaceKind.masked,
            frontSector: near.sector,
            backSector: far.sector,
            x1: ax,
            y1: ay,
            x2: bx,
            y2: by,
            bottom: clampedBottom,
            top: clampedTop,
            texture: near.middleTexture,
            textureWidth: size.width,
            textureHeight: size.height,
            uLeft: near.xOffset.toDouble(),
            uRight: near.xOffset + length,
            // Texel row at the clamped top, accounting for any part of the
            // texture clipped away above.
            yOffset: drawTop - clampedTop,
            rawYOffset: near.yOffset.toDouble(),
            nearCeiling: nearCeil,
            lowerUnpegged: line.lowerUnpegged,
            upperUnpegged: line.upperUnpegged,
            lightLevel: light,
          ),
        );
      }
    }
    return skySkipped;
  }

  _TexSize _sizeOf(String name, Set<String> missing) {
    if (name == kNoTextureName || name.isEmpty) {
      return const _TexSize(64, 128);
    }
    final TextureDef? def = textures.textureDef(name);
    if (def != null && def.width > 0 && def.height > 0) {
      return _TexSize(def.width.toDouble(), def.height.toDouble());
    }
    final PatchImage? image = textures.composite(name);
    if (image != null && image.width > 0 && image.height > 0) {
      return _TexSize(image.width.toDouble(), image.height.toDouble());
    }
    missing.add(name);
    // Vanilla's own fallback size, so alignment stays plausible on a missing
    // texture instead of collapsing to zero.
    return const _TexSize(64, 128);
  }

  double _light(Sector sector, double contrast) {
    final double base = sector.lightLevel / 255.0;
    final double lit = base + contrast;
    if (lit < 0) {
      return 0;
    }
    return lit > 1 ? 1 : lit;
  }

  /// Doom's fake contrast: walls running north-south read brighter, east-west
  /// darker, which fakes directional lighting without any light source.
  double _fakeContrast(double dx, double dy) {
    if (!options.fakeContrast) {
      return 0;
    }
    if (dy == 0) {
      return -16.0 / 255.0;
    }
    if (dx == 0) {
      return 16.0 / 255.0;
    }
    return 0;
  }
}

class _TexSize {
  const _TexSize(this.width, this.height);

  final double width;
  final double height;
}
