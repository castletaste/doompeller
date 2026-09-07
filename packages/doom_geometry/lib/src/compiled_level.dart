import 'atlas.dart';
import 'geometry_report.dart';
import 'packed_mesh.dart';
import 'wad_types.dart';

/// The compiled level: packed meshes plus the handles the runtime needs.
class CompiledLevel {
  const CompiledLevel({
    required this.meshes,
    required this.atlas,
    required this.floorPlanes,
    required this.ceilingPlanes,
    required this.wallBands,
    this.animations = const <AnimatedSurfaceRef>[],
    this.switchFrames = const <String, AtlasEntry>{},
    required this.report,
    required this.skyTextureName,
  });

  final List<PackedMesh> meshes;
  final IndexedAtlas atlas;

  /// One per sector that has floor geometry, in sector order.
  final List<SectorPlaneRef> floorPlanes;
  final List<SectorPlaneRef> ceilingPlanes;

  /// One per emitted wall quad, for door and lift updates.
  final List<WallBandRef> wallBands;
  final List<AnimatedSurfaceRef> animations;

  /// Alternate atlas entries for switch textures, keyed by original name.
  final Map<String, AtlasEntry> switchFrames;

  final GeometryReport report;

  /// Packed classic sky texture for the renderer-owned camera-centred cube.
  /// Null when the source does not provide the configured texture.
  final String? skyTextureName;

  /// A runtime owns all mutable vertex buffers and update handles. Atlas pixels,
  /// topology and lookup data remain shared and must be treated as read-only.
  /// Copy once at assembly, never during a tic or restart.
  CompiledLevel copyForRuntime() => CompiledLevel(
    meshes: [for (final mesh in meshes) mesh.copyForRuntime()],
    atlas: atlas,
    floorPlanes: [for (final plane in floorPlanes) plane.copyForRuntime()],
    ceilingPlanes: [for (final plane in ceilingPlanes) plane.copyForRuntime()],
    wallBands: [for (final band in wallBands) band.copyForRuntime()],
    animations: animations,
    switchFrames: switchFrames,
    report: report,
    skyTextureName: skyTextureName,
  );

  AtlasEntry? get skyTextureEntry =>
      skyTextureName == null ? null : atlas.entry(skyTextureName!);

  int get triangleCount {
    var total = 0;
    for (var i = 0; i < meshes.length; i++) {
      total += meshes[i].triangleCount;
    }
    return total;
  }

  /// Moves a sector's floor. Returns vertices rewritten, 0 if nothing changed.
  int setFloorHeight(int sector, double height) =>
      _applyPlane(floorPlanes, sector, height);

  /// Changes a compiled floor's atlas rectangle without rebuilding geometry.
  int setFloorFlat(int sector, String flatName) {
    final AtlasEntry? entry = atlas.entry(flatName);
    if (entry == null) throw DoomMissingLumpFailure(flatName);
    for (final SectorPlaneRef plane in floorPlanes) {
      if (plane.sector == sector) {
        return plane.applyTexture(meshes, entry, atlas.pageSize);
      }
    }
    return 0;
  }

  /// Moves a sector's ceiling.
  int setCeilingHeight(int sector, double height) =>
      _applyPlane(ceilingPlanes, sector, height);

  int _applyPlane(List<SectorPlaneRef> planes, int sector, double height) {
    for (var i = 0; i < planes.length; i++) {
      if (planes[i].sector == sector) {
        return planes[i].applyHeight(meshes, height);
      }
    }
    return 0;
  }

  /// Re-derives every wall band touching [sector] after its heights changed.
  ///
  /// This is the door and lift path: the caller moves the planes, then calls
  /// this with the new heights so the wall quads that span the moved sector
  /// follow, re-pegged. No mesh is rebuilt and nothing is reallocated.
  int updateWallsForSector(
    int sector,
    double floorHeight,
    double ceilingHeight,
    List<double> sectorFloors,
    List<double> sectorCeilings,
  ) {
    var updated = 0;
    for (var i = 0; i < wallBands.length; i++) {
      final WallBandRef band = wallBands[i];
      if (band.frontSector != sector && band.backSector != sector) {
        continue;
      }
      band.applySectorHeights(
        meshes,
        sector,
        floorHeight,
        ceilingHeight,
        sectorFloors,
        sectorCeilings,
      );
      updated++;
    }
    return updated;
  }
}
