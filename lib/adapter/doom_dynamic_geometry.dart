import 'dart:typed_data';

import 'package:doom_core/doom_core.dart' as core;
import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:doom_wad/doom_wad.dart' as wad;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/resources.dart';

import 'packed_surface.dart';
import 'render_diagnostics.dart';

/// Applies simulation journals to retained world buffers and their GPU bindings.
/// Sprite lifecycle and scene assembly do not participate in these mutations.
final class DoomDynamicGeometry {
  DoomDynamicGeometry(
    this.level, {
    required Map<int, DoomGeometryBinding> bindings,
    required List<int> sectorLights,
    required this.diagnostics,
  }) : _geometryBindings = bindings,
       _sectorLights = List.of(sectorLights);

  final geometry.CompiledLevel level;
  final Map<int, DoomGeometryBinding> _geometryBindings;
  final List<int> _sectorLights;
  final RenderDiagnostics diagnostics;

  late final List<geometry.SectorPlaneRef> _planes = [
    ...level.floorPlanes,
    ...level.ceilingPlanes,
  ];
  late final Map<int, geometry.SectorPlaneRef> _floors = {
    for (final plane in level.floorPlanes) plane.sector: plane,
  };
  late final Map<int, geometry.SectorPlaneRef> _ceilings = {
    for (final plane in level.ceilingPlanes) plane.sector: plane,
  };
  late final Map<int, List<geometry.WallBandRef>> _wallsBySector =
      _indexWalls();
  late final Map<String, geometry.AnimatedSurfaceRef> _animationsByName =
      _indexAnimations();
  late final Map<geometry.AnimatedSurfaceRef, List<geometry.VertexRange>>
  _wallAnimations = _indexWallAnimations();
  late final List<geometry.WallBandRef> _scrollingWalls = [
    for (final band in level.wallBands)
      if (band.scrollsHorizontally) band,
  ];

  Map<int, List<geometry.WallBandRef>> _indexWalls() {
    final result = <int, List<geometry.WallBandRef>>{};
    for (final band in level.wallBands) {
      result.putIfAbsent(band.frontSector, () => []).add(band);
      if (band.backSector >= 0 && band.backSector != band.frontSector) {
        result.putIfAbsent(band.backSector, () => []).add(band);
      }
    }
    return result;
  }

  Map<String, geometry.AnimatedSurfaceRef> _indexAnimations() {
    final result = <String, geometry.AnimatedSurfaceRef>{};
    for (final animation in level.animations) {
      result.putIfAbsent(
        animation.frames[animation.initialFrame].name,
        () => animation,
      );
    }
    return result;
  }

  Map<geometry.AnimatedSurfaceRef, List<geometry.VertexRange>>
  _indexWallAnimations() {
    final planeRanges = {
      for (final plane in _planes)
        for (final range in plane.ranges)
          (range.meshIndex, range.firstVertex, range.vertexCount),
    };
    return {
      for (final animation in level.animations)
        animation: [
          for (final range in animation.ranges)
            if (!planeRanges.contains((
              range.meshIndex,
              range.firstVertex,
              range.vertexCount,
            )))
              range,
        ],
    };
  }

  /// Moves a floor or ceiling to [height].
  ///
  /// Writes in place and uploads only the touched vertex range, so a lift
  /// running every tic never recreates a GPU buffer. Returns whether anything
  /// moved.
  bool updateSectorPlane({
    required int sectorIndex,
    required double height,
    required bool isCeiling,
  }) {
    final compiled = level;
    final target = (isCeiling ? _ceilings : _floors)[sectorIndex];
    if (target == null || target.height == height) {
      return false;
    }
    if (!height.isFinite) {
      throw ArgumentError.value(height, 'height', 'must be finite');
    }
    if (isCeiling) {
      compiled.setCeilingHeight(sectorIndex, height);
    } else {
      compiled.setFloorHeight(sectorIndex, height);
    }
    for (final range in target.ranges) {
      final binding = _geometryBindings[range.meshIndex]!;
      binding.surface
        ..markVertexRangeDirty(range.firstVertex, range.vertexCount)
        ..expandBoundsY(height);
      binding.markBoundsDirty();
    }
    diagnostics.onDynamicUpdate();
    return true;
  }

  /// Advances classic texture/flat animations by rewriting atlas rectangles.
  /// Only ranges whose frame changed are dirtied; geometry and GPU buffers stay
  /// allocated. Frames are co-located on one page by the geometry compiler.
  int updateTextureAnimations(int levelTime) {
    final compiled = level;
    var touched = 0;
    void updateRanges(
      Iterable<geometry.VertexRange> ranges,
      geometry.AtlasEntry entry,
    ) {
      for (final range in ranges) {
        final mesh = compiled.meshes[range.meshIndex];
        final int rectOffset =
            range.firstVertex * geometry.DoomVertexAbi.floatsPerVertex +
            geometry.DoomVertexAbi.atlasRectOffset;
        final current = mesh.vertices[rectOffset];
        final next = entry.u0(compiled.atlas.pageSize);
        if (current == next &&
            mesh.vertices[rectOffset + 1] ==
                entry.v0(compiled.atlas.pageSize) &&
            mesh.vertices[rectOffset + 2] ==
                entry.u1(compiled.atlas.pageSize) &&
            mesh.vertices[rectOffset + 3] ==
                entry.v1(compiled.atlas.pageSize)) {
          continue;
        }
        _writeAtlasRect(
          mesh.vertices,
          range.firstVertex,
          range.vertexCount,
          entry,
          compiled.atlas.pageSize,
        );
        _geometryBindings[range.meshIndex]!.surface.markVertexRangeDirty(
          range.firstVertex,
          range.vertexCount,
        );
        touched += range.vertexCount;
      }
    }

    // Plane texture names are mutable. Resolve their current animation base
    // each frame so transferring onto or away from an animated flat cannot
    // leave the old range binding alive.
    for (final plane in _planes) {
      final selected = _animationsByName[plane.textureName];
      if (selected != null) {
        updateRanges(
          plane.ranges,
          selected.frames[selected.frameAt(levelTime)],
        );
      }
    }
    for (final animation in compiled.animations) {
      final entry = animation.frames[animation.frameAt(levelTime)];
      updateRanges(_wallAnimations[animation]!, entry);
    }
    for (final band in _scrollingWalls) {
      if (!band.applyHorizontalScroll(compiled.meshes, levelTime)) continue;
      _geometryBindings[band.meshIndex]!.surface.markVertexRangeDirty(
        band.firstVertex,
        geometry.WallBandRef.verticesPerQuad,
      );
      touched += geometry.WallBandRef.verticesPerQuad;
    }
    if (touched > 0) diagnostics.onDynamicUpdate();
    return touched;
  }

  int updateAnimationFrames(int levelTime) =>
      updateTextureAnimations(levelTime);

  int updateSectorFloorFlat({
    required int sectorIndex,
    required String flatName,
  }) {
    final compiled = level;
    final target = _floors[sectorIndex];
    if (target == null || target.textureName == flatName) return 0;
    final int touched = compiled.setFloorFlat(sectorIndex, flatName);
    for (final range in target.ranges) {
      _geometryBindings[range.meshIndex]!.surface.markVertexRangeDirty(
        range.firstVertex,
        range.vertexCount,
      );
    }
    if (touched > 0) diagnostics.onDynamicUpdate();
    return touched;
  }

  int updateSwitchTexture(core.SwitchTextureChange change) {
    final compiled = level;
    final geometry.AtlasEntry? entry = compiled.atlas.entry(change.textureName);
    if (entry == null) return 0;
    var touched = 0;
    for (final band in compiled.wallBands) {
      if (band.linedef != change.linedef ||
          band.sidedef != change.sidedef ||
          !_slotMatches(change.slot, band.band)) {
        continue;
      }
      if (compiled.meshes[band.meshIndex].atlasPage != entry.page) continue;
      _writeAtlasRect(
        compiled.meshes[band.meshIndex].vertices,
        band.firstVertex,
        geometry.WallBandRef.verticesPerQuad,
        entry,
        compiled.atlas.pageSize,
      );
      _geometryBindings[band.meshIndex]!.surface.markVertexRangeDirty(
        band.firstVertex,
        geometry.WallBandRef.verticesPerQuad,
      );
      touched += geometry.WallBandRef.verticesPerQuad;
    }
    if (touched > 0) diagnostics.onDynamicUpdate();
    return touched;
  }

  /// Recomputes every wall quad touching [sectorIndex] through geometry's
  /// pegging oracle, then marks only each referenced four-vertex quad dirty.
  int updateWallsForSector({
    required int sectorIndex,
    required double floorHeight,
    required double ceilingHeight,
    required List<double> sectorFloors,
    required List<double> sectorCeilings,
  }) {
    final compiled = level;
    final affected = _wallsBySector[sectorIndex] ?? const [];
    if (affected.isEmpty) {
      return 0;
    }
    for (final band in affected) {
      band.applySectorHeights(
        compiled.meshes,
        sectorIndex,
        floorHeight,
        ceilingHeight,
        sectorFloors,
        sectorCeilings,
      );
      final binding = _geometryBindings[band.meshIndex]!;
      binding.surface
        ..markVertexRangeDirty(
          band.firstVertex,
          geometry.WallBandRef.verticesPerQuad,
        )
        ..expandBoundsY(band.bottom)
        ..expandBoundsY(band.top);
      binding.markBoundsDirty();
    }
    diagnostics.onDynamicUpdate();
    return affected.length;
  }

  /// Rewrites the exact retained plane and near-wall vertices lit by a sector.
  ///
  /// Fake-contrast offsets already present on walls are retained. Only dirty
  /// ranges are marked; no mesh, surface, or GPU buffer is recreated.
  int updateSectorLight({required int sectorIndex, required int lightLevel}) {
    final compiled = level;
    if (sectorIndex < 0 || sectorIndex >= _sectorLights.length) {
      throw RangeError.index(sectorIndex, _sectorLights, 'sectorIndex');
    }
    if (lightLevel < 0 || lightLevel > 255) {
      throw RangeError.range(lightLevel, 0, 255, 'lightLevel');
    }
    final int previousLevel = _sectorLights[sectorIndex];
    if (previousLevel == lightLevel) {
      return 0;
    }
    _sectorLights[sectorIndex] = lightLevel;
    final double previous = previousLevel / 255.0;
    final double next = lightLevel / 255.0;
    var touched = 0;

    void updateRange(
      int meshIndex,
      int firstVertex,
      int vertexCount, {
      required bool preserveContrast,
    }) {
      final mesh = compiled.meshes[meshIndex];
      for (
        var vertex = firstVertex;
        vertex < firstVertex + vertexCount;
        vertex++
      ) {
        final offset =
            vertex * geometry.DoomVertexAbi.floatsPerVertex +
            geometry.DoomVertexAbi.colorOffset;
        final double value = preserveContrast
            ? (mesh.vertices[offset] - previous + next).clamp(0.0, 1.0)
            : next;
        mesh.setVertexLight(vertex, value);
      }
      _geometryBindings[meshIndex]!.surface.markVertexRangeDirty(
        firstVertex,
        vertexCount,
      );
      touched += vertexCount;
    }

    for (final plane in compiled.floorPlanes) {
      if (plane.sector != sectorIndex) {
        continue;
      }
      for (final range in plane.ranges) {
        updateRange(
          range.meshIndex,
          range.firstVertex,
          range.vertexCount,
          preserveContrast: false,
        );
      }
    }
    for (final plane in compiled.ceilingPlanes) {
      if (plane.sector != sectorIndex) {
        continue;
      }
      for (final range in plane.ranges) {
        updateRange(
          range.meshIndex,
          range.firstVertex,
          range.vertexCount,
          preserveContrast: false,
        );
      }
    }
    for (final band in compiled.wallBands) {
      if (band.frontSector != sectorIndex) {
        continue;
      }
      updateRange(
        band.meshIndex,
        band.firstVertex,
        geometry.WallBandRef.verticesPerQuad,
        preserveContrast: true,
      );
    }
    if (touched > 0) {
      diagnostics.onDynamicUpdate();
    }
    return touched;
  }

  /// Restores every runtime-mutated world surface to the source map state.
  ///
  /// This rewrites retained vertex buffers in place. It does not rebuild a
  /// mesh, material, texture, surface, component, or GPU buffer.
  void resetDynamicState(wad.MapData map) {
    final compiled = level;
    if (map.sectors.length != _sectorLights.length) {
      throw StateError('prepared map and retained scene sector counts differ');
    }

    final floors = <double>[
      for (final sector in map.sectors) sector.floorHeight.toDouble(),
    ];
    final ceilings = <double>[
      for (final sector in map.sectors) sector.ceilingHeight.toDouble(),
    ];
    for (var sector = 0; sector < map.sectors.length; sector++) {
      updateSectorPlane(
        sectorIndex: sector,
        height: floors[sector],
        isCeiling: false,
      );
      updateSectorPlane(
        sectorIndex: sector,
        height: ceilings[sector],
        isCeiling: true,
      );
      updateSectorFloorFlat(
        sectorIndex: sector,
        flatName: map.sectors[sector].floorFlat,
      );
      updateSectorLight(
        sectorIndex: sector,
        lightLevel: map.sectors[sector].lightLevel,
      );
    }
    for (var sector = 0; sector < map.sectors.length; sector++) {
      updateWallsForSector(
        sectorIndex: sector,
        floorHeight: floors[sector],
        ceilingHeight: ceilings[sector],
        sectorFloors: floors,
        sectorCeilings: ceilings,
      );
    }

    for (final band in compiled.wallBands) {
      final geometry.AtlasEntry? entry = compiled.atlas.entry(band.textureName);
      if (entry == null ||
          compiled.meshes[band.meshIndex].atlasPage != entry.page) {
        continue;
      }
      _writeAtlasRect(
        compiled.meshes[band.meshIndex].vertices,
        band.firstVertex,
        geometry.WallBandRef.verticesPerQuad,
        entry,
        compiled.atlas.pageSize,
      );
      _geometryBindings[band.meshIndex]!.surface.markVertexRangeDirty(
        band.firstVertex,
        geometry.WallBandRef.verticesPerQuad,
      );
    }
    updateTextureAnimations(0);
  }
}

final class DoomGeometryBinding {
  const DoomGeometryBinding({
    required this.surface,
    required this.mesh,
    required this.component,
  });

  final PackedFlameSurface surface;
  final Mesh mesh;
  final Component3D component;

  void markBoundsDirty() {
    mesh.updateBounds();
    component.markAabbDirty();
  }
}

void _writeAtlasRect(
  Float32List vertices,
  int firstVertex,
  int vertexCount,
  geometry.AtlasEntry entry,
  int pageSize,
) {
  final double u0 = entry.u0(pageSize);
  final double v0 = entry.v0(pageSize);
  final double u1 = entry.u1(pageSize);
  final double v1 = entry.v1(pageSize);
  for (var vertex = firstVertex; vertex < firstVertex + vertexCount; vertex++) {
    final int offset =
        vertex * geometry.DoomVertexAbi.floatsPerVertex +
        geometry.DoomVertexAbi.atlasRectOffset;
    vertices[offset] = u0;
    vertices[offset + 1] = v0;
    vertices[offset + 2] = u1;
    vertices[offset + 3] = v1;
  }
}

bool _slotMatches(core.SwitchTextureSlot slot, geometry.WallBandKind band) =>
    switch (slot) {
      core.SwitchTextureSlot.upper => band == geometry.WallBandKind.upper,
      core.SwitchTextureSlot.middle =>
        band == geometry.WallBandKind.middle ||
            band == geometry.WallBandKind.solid,
      core.SwitchTextureSlot.lower => band == geometry.WallBandKind.lower,
    };
