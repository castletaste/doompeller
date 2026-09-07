import 'dart:math' as math;
import 'dart:typed_data';

import 'atlas.dart';
import 'compiled_level.dart';
import 'bsp_regions.dart';
import 'geometry_options.dart';
import 'geometry_report.dart';
import 'geometry_validation.dart';
import 'mesh_packer.dart';
import 'packed_mesh.dart';
import 'sector_loops.dart';
import 'texture_source.dart';
import 'tjunction.dart';
import 'triangulate.dart';
import 'walls.dart';
import 'wad_types.dart';

export 'compiled_level.dart';

/// Compiles map data into packed GPU meshes.
///
/// Pipeline:
///   1. BSP-first floor/ceiling regions, per subsector (primary).
///   2. Sector-loop triangulation, per sector (oracle and fallback).
///   3. Per-sector validation; failing sectors emit the oracle's geometry.
///   4. Walls from linedefs.
///   5. Atlas packing, then vertex packing split by page, kind and 65535.
class DoomGeometryCompiler {
  /// Visual linedef specials implemented by compiled geometry/the adapter.
  static const Set<int> supportedLinedefSpecials = <int>{48};

  /// Compiles a map against a parsed WAD's resources.
  ///
  /// This is the contract entry point.
  static CompiledLevel compile(
    MapData map,
    WadResources res, {
    GeometryOptions options = GeometryOptions.defaults,
  }) => _Compiler(map, ResourceTextureSource(res), options).run();

  /// Compiles against any [TextureSource].
  ///
  /// Used by tests, which supply a few synthetic textures directly rather than
  /// building a WAD container to hold them.
  static CompiledLevel compileWithTextures(
    MapData map,
    TextureSource textures, {
    GeometryOptions options = GeometryOptions.defaults,
  }) => _Compiler(map, textures, options).run();
}

class _Compiler {
  _Compiler(this.map, this.textures, this.options);

  final MapData map;
  final TextureSource textures;
  final GeometryOptions options;

  final MeshPacker _packer = MeshPacker();

  CompiledLevel run() {
    final Stopwatch clock = Stopwatch()..start();
    final CheckBudget budget = CheckBudget(
      options.limits.maxIntersectionChecks,
    );
    final int sectorCount = map.sectors.length;

    // 1. Oracle. Always built when validation or fallback might need it.
    final bool needLoops = options.validateAgainstLoops || !options.bspFirst;
    final List<SectorLoopResult> loops = needLoops
        ? SectorLoopBuilder(map, options).buildAll(budget)
        : const <SectorLoopResult>[];

    // 2. BSP regions.
    // MapData.hasBsp insists on a non-empty NODES lump, but a map small enough
    // to be one convex cell legitimately has zero nodes and one subsector. The
    // region builder handles that as the root leaf, so the gate here is just
    // "is there a subsector partition of the level at all".
    final bool useBsp =
        options.bspFirst && map.subsectors.isNotEmpty && map.segs.isNotEmpty;
    final BspRegionSet regions = useBsp
        ? BspRegionBuilder(map, options).build(budget)
        : const BspRegionSet(
            regions: <BspRegion>[],
            emptyRegions: 0,
            maxDepth: 0,
            depthExceeded: false,
            budgetExhausted: false,
            visitedNodes: 0,
            duplicateLeaves: 0,
          );

    // 3. Per-sector meshes from each path, then validate.
    final List<SectorMesh2D> bspMeshes = List<SectorMesh2D>.filled(
      sectorCount,
      SectorMesh2D.empty(),
    );
    final Int32List emptyPerSector = Int32List(sectorCount);
    var repairedVertices = 0;
    var repairedRegions = 0;
    if (useBsp) {
      // Close T-junction cracks before the regions become triangles. A
      // partition that ends where a wall ends leaves one cell with a long edge
      // and its neighbour with two short ones; inserting the neighbour's corner
      // into the long edge keeps the shape and area identical while making both
      // sides agree vertex for vertex, which is what stops a hairline seam from
      // opening between them at raster time.
      final TJunctionRepairResult repair = repairTJunctions(
        regions.regions,
        options,
        budget,
      );
      repairedVertices = repair.insertedVertices;
      repairedRegions = repair.repairedRegions;
      _gatherBspMeshes(repair.regions, bspMeshes, emptyPerSector, budget);
    }
    final List<SectorMesh2D> loopMeshes = List<SectorMesh2D>.filled(
      sectorCount,
      SectorMesh2D.empty(),
    );
    if (needLoops) {
      for (var s = 0; s < sectorCount; s++) {
        loopMeshes[s] = _loopMesh(loops[s]);
      }
    }

    final GeometryValidator validator = GeometryValidator(options);
    final List<SectorFinding> findings = <SectorFinding>[];
    final List<int> fallbacks = <int>[];
    final List<SectorMesh2D> chosen = List<SectorMesh2D>.filled(
      sectorCount,
      SectorMesh2D.empty(),
    );

    for (var s = 0; s < sectorCount; s++) {
      if (!useBsp) {
        chosen[s] = loopMeshes[s];
        findings.add(
          SectorFinding(
            sector: s,
            issues: const <GeometryIssue>{},
            bspArea: 0,
            loopArea: loopMeshes[s].area,
            bspTriangles: 0,
            loopTriangles: loopMeshes[s].triangleCount,
            degenerateTriangles: 0,
            tJunctions: 0,
            unmatchedEdges: 0,
            overlaps: 0,
            emptyRegions: 0,
            usedFallback: true,
            bspEvaluated: false,
          ),
        );
        fallbacks.add(s);
        continue;
      }
      if (!options.validateAgainstLoops) {
        chosen[s] = bspMeshes[s];
        findings.add(
          SectorFinding(
            sector: s,
            issues: const <GeometryIssue>{},
            bspArea: bspMeshes[s].area,
            loopArea: 0,
            bspTriangles: bspMeshes[s].triangleCount,
            loopTriangles: 0,
            degenerateTriangles: 0,
            tJunctions: 0,
            unmatchedEdges: 0,
            overlaps: 0,
            emptyRegions: emptyPerSector[s],
            usedFallback: false,
          ),
        );
        continue;
      }
      final SectorLoopResult loop = loops[s];
      final SectorFinding finding = validator.validateSector(
        sector: s,
        bsp: bspMeshes[s],
        loop: loopMeshes[s],
        emptyRegions: emptyPerSector[s],
        loopComplete: loop.isComplete,
        loopClosed: loop.openChains == 0,
        budget: budget,
      );
      // Fall back when validation says the BSP result is untrustworthy, and
      // also when the BSP produced nothing at all for a sector the oracle can
      // see. Never drop geometry silently: if both paths are empty the sector
      // genuinely has no area.
      final bool loopHasGeometry = loopMeshes[s].triangleCount > 0;
      final bool bspHasGeometry = bspMeshes[s].triangleCount > 0;
      final bool fallBack =
          loopHasGeometry &&
          (validator.shouldFallBack(finding) || !bspHasGeometry);
      chosen[s] = fallBack ? loopMeshes[s] : bspMeshes[s];
      if (fallBack) {
        fallbacks.add(s);
      }
      findings.add(
        SectorFinding(
          sector: finding.sector,
          issues: finding.issues,
          bspArea: finding.bspArea,
          loopArea: finding.loopArea,
          bspTriangles: finding.bspTriangles,
          loopTriangles: finding.loopTriangles,
          degenerateTriangles: finding.degenerateTriangles,
          tJunctions: finding.tJunctions,
          unmatchedEdges: finding.unmatchedEdges,
          overlaps: finding.overlaps,
          emptyRegions: finding.emptyRegions,
          usedFallback: fallBack,
          oracleReliable: finding.oracleReliable,
        ),
      );
    }

    // 4. Walls.
    final WallSet walls = WallBuilder(map, textures, options).build();

    var triangleEstimate = 0;
    for (var s = 0; s < chosen.length; s++) {
      final Sector sector = map.sectors[s];
      final int planeCount =
          (sector.floorIsSky ? 0 : 1) + (sector.ceilingIsSky ? 0 : 1);
      triangleEstimate += chosen[s].triangleCount * planeCount;
    }
    triangleEstimate +=
        walls.quads.where((WallQuad quad) => quad.hasTexture).length * 2;
    DoomLimits.check(
      triangleEstimate,
      options.limits.maxTriangles,
      'maxTriangles',
    );

    // 5. Atlas.
    final AtlasBuilder atlasBuilder = AtlasBuilder(textures, options);
    final List<List<String>> flatTransferGroups = _flatTransferGroups();
    var usesSky = false;
    for (var s = 0; s < sectorCount; s++) {
      usesSky =
          usesSky || map.sectors[s].floorIsSky || map.sectors[s].ceilingIsSky;
      atlasBuilder
        ..addFlat(map.sectors[s].floorFlat)
        ..addFlat(map.sectors[s].ceilingFlat);
    }
    for (var i = 0; i < walls.quads.length; i++) {
      atlasBuilder.addWallTexture(walls.quads[i].texture);
    }
    final DoomAnimationResolution animationResolution =
        textures.animationResolution;
    final Set<String> usedPictures = <String>{
      for (final Sector sector in map.sectors) ...<String>[
        sector.floorFlat,
        sector.ceilingFlat,
      ],
      for (final WallQuad quad in walls.quads) quad.texture,
    };
    for (final DoomAnimation animation in animationResolution.animations) {
      if (!animation.frames.any(usedPictures.contains)) continue;
      for (final String frame in animation.frames) {
        if (animation.definition.kind == DoomAnimationKind.flat) {
          atlasBuilder.addFlat(frame);
        } else {
          atlasBuilder.addWallTexture(frame);
        }
      }
      atlasBuilder.addCoLocated(animation.frames);
    }
    for (final List<String> group in flatTransferGroups) {
      for (final String flat in group) {
        atlasBuilder.addFlat(flat);
      }
      atlasBuilder.addCoLocated(group);
    }
    for (final DoomSwitchPair pair in textures.switchPairs) {
      if (!usedPictures.contains(pair.offName) &&
          !usedPictures.contains(pair.onName)) {
        continue;
      }
      atlasBuilder
        ..addWallTexture(pair.offName)
        ..addWallTexture(pair.onName)
        ..addCoLocated(<String>[pair.offName, pair.onName]);
    }
    if (usesSky) {
      atlasBuilder.addWallTexture(options.skyTextureName);
    }
    final IndexedAtlas atlas = atlasBuilder.build();
    if (atlas.overflowed.isNotEmpty) {
      throw DoomLimitFailure(
        'maxAtlasPixels: atlas overflowed for ${atlas.overflowed.join(', ')}',
        limitName: 'maxAtlasPixels',
        limit: options.limits.maxAtlasPixels,
      );
    }
    for (final List<String> group in flatTransferGroups) {
      final List<AtlasEntry> entries = <AtlasEntry>[
        for (final String name in group)
          if (atlas.entry(name) case final AtlasEntry entry) entry,
      ];
      if (entries.length > 1) {
        atlas.requireSamePage(
          entries,
          description: 'floor transfer ${group.join('->')}',
        );
      }
    }
    final Set<String> missingTextures = <String>{...walls.missingTextures};
    for (var s = 0; s < sectorCount; s++) {
      if (chosen[s].triangleCount == 0) {
        continue;
      }
      final Sector sector = map.sectors[s];
      if (!sector.floorIsSky && atlas.entry(sector.floorFlat) == null) {
        missingTextures.add(sector.floorFlat);
      }
      if (!sector.ceilingIsSky && atlas.entry(sector.ceilingFlat) == null) {
        missingTextures.add(sector.ceilingFlat);
      }
    }
    if (atlas.pageCount == 0 && missingTextures.isNotEmpty) {
      throw DoomMissingLumpFailure(missingTextures.first);
    }

    // 6. Pack.
    final List<SectorPlaneRef> floors = <SectorPlaneRef>[];
    final List<SectorPlaneRef> ceilings = <SectorPlaneRef>[];
    _packPlanes(chosen, atlas, floors, ceilings);
    final List<WallBandRef> bands = _packWalls(walls, atlas);
    final List<AnimatedSurfaceRef> animations = _buildAnimationRefs(
      animationResolution,
      atlas,
      floors,
      ceilings,
      bands,
    );
    final Map<String, AtlasEntry> switchFrames = <String, AtlasEntry>{};
    final List<String> animationFailures = <String>[
      for (final DoomAnimationFailure failure in animationResolution.failures)
        '${failure.definition.startName}->${failure.definition.endName}: ${failure.reason}',
    ];
    for (final DoomSwitchPair pair in textures.switchPairs) {
      final AtlasEntry? off = atlas.entry(pair.offName);
      final AtlasEntry? on = atlas.entry(pair.onName);
      if (off == null || on == null) {
        if (usedPictures.contains(pair.offName) ||
            usedPictures.contains(pair.onName)) {
          animationFailures.add(
            '${pair.offName}<->${pair.onName}: missing frame',
          );
        }
        continue;
      }
      atlas.requireSamePage(<AtlasEntry>[
        off,
        on,
      ], description: 'switch ${pair.offName}<->${pair.onName}');
      switchFrames[pair.offName] = on;
      switchFrames[pair.onName] = off;
    }

    final List<PackedMesh> meshes = _packer.finish();
    clock.stop();

    final GeometryReport report = GeometryReport(
      map: map.name,
      findings: findings,
      fallbackSectors: fallbacks,
      totalTriangles: _packer.totalTriangles,
      totalVertices: _packer.totalVertices,
      meshCount: meshes.length,
      atlasPages: atlas.pageCount,
      subsectorCount: map.subsectors.length,
      emptySubsectors: regions.emptyRegions,
      maxBspDepth: regions.maxDepth,
      intersectionChecks: budget.used,
      intersectionBudget: budget.limit,
      bspFirst: options.bspFirst,
      validated: options.validateAgainstLoops,
      budgetExhausted: budget.exhausted,
      missingTextures: missingTextures.toList()..sort(),
      geometryHash: _hash(meshes),
      compileMicroseconds: clock.elapsedMicroseconds,
      animationFailures: List<String>.unmodifiable(animationFailures),
      repairedTJunctionVertices: repairedVertices,
      repairedRegions: repairedRegions,
    );

    return CompiledLevel(
      meshes: meshes,
      atlas: atlas,
      floorPlanes: floors,
      ceilingPlanes: ceilings,
      wallBands: bands,
      animations: animations,
      switchFrames: Map<String, AtlasEntry>.unmodifiable(switchFrames),
      report: report,
      skyTextureName: atlas.entry(options.skyTextureName) == null
          ? null
          : options.skyTextureName,
    );
  }

  /// Merges every subsector polygon of a sector into one triangle soup.
  void _gatherBspMeshes(
    List<BspRegion> regions,
    List<SectorMesh2D> out,
    Int32List emptyPerSector,
    CheckBudget budget,
  ) {
    final int sectorCount = out.length;
    final List<List<double>> verts = List<List<double>>.generate(
      sectorCount,
      (int _) => <double>[],
      growable: false,
    );
    final List<List<int>> tris = List<List<int>>.generate(
      sectorCount,
      (int _) => <int>[],
      growable: false,
    );

    for (var r = 0; r < regions.length; r++) {
      final BspRegion region = regions[r];
      final int sector = region.sector;
      if (sector < 0 || sector >= sectorCount) {
        continue;
      }
      if (region.isEmpty) {
        emptyPerSector[sector]++;
        continue;
      }
      // Convex by construction. Fan from an inserted centre rather than a
      // boundary corner: every repaired boundary edge becomes one real
      // triangle, even when all four sides contain collinear inserted points.
      final int base = verts[sector].length ~/ 2;
      final TriangulationResult triangulation = triangulateConvexBoundary(
        region.xy,
        epsilon: options.epsilon * options.epsilon,
      );
      if (!triangulation.isComplete || triangulation.triangleCount == 0) {
        emptyPerSector[sector]++;
        budget.spend();
        continue;
      }
      verts[sector].addAll(triangulation.vertices);
      for (final int index in triangulation.indices) {
        tris[sector].add(base + index);
      }
      budget.spend();
    }
    for (var s = 0; s < sectorCount; s++) {
      out[s] = SectorMesh2D(
        Float64List.fromList(verts[s]),
        Uint32List.fromList(tris[s]),
      );
    }
  }

  SectorMesh2D _loopMesh(SectorLoopResult loop) {
    final List<double> verts = <double>[];
    final List<int> tris = <int>[];
    for (var i = 0; i < loop.triangulation.length; i++) {
      final TriangulationResult t = loop.triangulation[i];
      final int base = verts.length ~/ 2;
      for (var v = 0; v < t.vertices.length; v++) {
        verts.add(t.vertices[v]);
      }
      for (var k = 0; k < t.indices.length; k++) {
        tris.add(base + t.indices[k]);
      }
    }
    return SectorMesh2D(Float64List.fromList(verts), Uint32List.fromList(tris));
  }

  void _packPlanes(
    List<SectorMesh2D> sectorMeshes,
    IndexedAtlas atlas,
    List<SectorPlaneRef> floors,
    List<SectorPlaneRef> ceilings,
  ) {
    for (var s = 0; s < sectorMeshes.length; s++) {
      final SectorMesh2D mesh = sectorMeshes[s];
      if (mesh.triangleCount == 0) {
        continue;
      }
      final Sector sector = map.sectors[s];
      final double light = sector.lightLevel / 255.0;
      final SectorPlaneRef? floor = sector.floorIsSky
          ? null
          : _packPlane(
              mesh: mesh,
              sector: s,
              height: sector.floorHeight.toDouble(),
              flatName: sector.floorFlat,
              isCeiling: false,
              atlas: atlas,
              light: light,
            );
      if (floor != null) {
        floors.add(floor);
      }
      final SectorPlaneRef? ceiling = sector.ceilingIsSky
          ? null
          : _packPlane(
              mesh: mesh,
              sector: s,
              height: sector.ceilingHeight.toDouble(),
              flatName: sector.ceilingFlat,
              isCeiling: true,
              atlas: atlas,
              light: light,
            );
      if (ceiling != null) {
        ceilings.add(ceiling);
      }
    }
  }

  SectorPlaneRef? _packPlane({
    required SectorMesh2D mesh,
    required int sector,
    required double height,
    required String flatName,
    required bool isCeiling,
    required IndexedAtlas atlas,
    required double light,
  }) {
    final AtlasEntry? entry = atlas.entry(flatName);
    const SurfaceKind kind = SurfaceKind.opaque;
    final int page = entry?.page ?? 0;
    final int vertexCount = mesh.vertexCount;
    if (vertexCount == 0) {
      return null;
    }
    final Float64List positions = Float64List(vertexCount * 3);
    final Float64List uvs = Float64List(vertexCount * 2);
    final FlatUvMapper? mapper = entry == null
        ? null
        : FlatUvMapper(entry, atlas.pageSize);
    for (var v = 0; v < vertexCount; v++) {
      final double mx = mesh.xy[v * 2];
      final double my = mesh.xy[v * 2 + 1];
      positions[v * 3] = DoomVertexAbi.worldX(mx);
      positions[v * 3 + 1] = DoomVertexAbi.worldY(height);
      positions[v * 3 + 2] = DoomVertexAbi.worldZ(my);
      uvs[v * 2] = mapper == null ? 0 : mapper.u(mx);
      uvs[v * 2 + 1] = mapper == null ? 0 : mapper.v(my);
    }
    // Map winding is counter-clockwise seen from above. A floor is viewed from
    // above so it keeps that order with an up normal; a ceiling is viewed from
    // below, so its triangles are reversed and its normal points down.
    final List<int> indices = <int>[];
    for (var t = 0; t < mesh.indices.length; t += 3) {
      if (isCeiling) {
        indices
          ..add(mesh.indices[t])
          ..add(mesh.indices[t + 2])
          ..add(mesh.indices[t + 1]);
      } else {
        indices
          ..add(mesh.indices[t])
          ..add(mesh.indices[t + 1])
          ..add(mesh.indices[t + 2]);
      }
    }
    final List<VertexRange> ranges = _packer.addPrimitive(
      page: page,
      kind: kind,
      positions: positions,
      uvs: uvs,
      indices: indices,
      normalX: 0,
      normalY: isCeiling ? -1 : 1,
      normalZ: 0,
      light: light,
      // Flats tile: a floor's UVs run past 1 whenever the sector is bigger
      // than 64 units, and the shader wraps inside this rect.
      atlasU0: entry?.u0(atlas.pageSize) ?? 0,
      atlasV0: entry?.v0(atlas.pageSize) ?? 0,
      atlasU1: entry?.u1(atlas.pageSize) ?? 1,
      atlasV1: entry?.v1(atlas.pageSize) ?? 1,
      uvMode: DoomVertexAbi.uvModeRepeat,
      // Sky is drawn at full brightness; vanilla never darkens it with
      // distance the way it darkens walls and floors.
      fullBright: false,
    );
    return SectorPlaneRef(
      sector: sector,
      isCeiling: isCeiling,
      textureName: flatName,
      ranges: ranges,
      baseHeight: height,
    );
  }

  List<WallBandRef> _packWalls(WallSet walls, IndexedAtlas atlas) {
    final List<WallBandRef> bands = <WallBandRef>[];
    final Float64List positions = Float64List(12);
    final Float64List uvs = Float64List(8);
    const List<int> quadIndices = <int>[0, 1, 2, 0, 2, 3];

    for (var i = 0; i < walls.quads.length; i++) {
      final WallQuad quad = walls.quads[i];
      if (!quad.hasTexture || (quad.x1 == quad.x2 && quad.y1 == quad.y2)) {
        continue;
      }
      final AtlasEntry? entry = atlas.entry(quad.texture);
      final int page = entry?.page ?? 0;
      final int pageSize = atlas.pageSize;

      // Quad vertex order: 0 bottom-left, 1 bottom-right, 2 top-right,
      // 3 top-left, matching what WallBandRef rewrites in place.
      positions[0] = DoomVertexAbi.worldX(quad.x1);
      positions[1] = DoomVertexAbi.worldY(quad.bottom);
      positions[2] = DoomVertexAbi.worldZ(quad.y1);
      positions[3] = DoomVertexAbi.worldX(quad.x2);
      positions[4] = DoomVertexAbi.worldY(quad.bottom);
      positions[5] = DoomVertexAbi.worldZ(quad.y2);
      positions[6] = DoomVertexAbi.worldX(quad.x2);
      positions[7] = DoomVertexAbi.worldY(quad.top);
      positions[8] = DoomVertexAbi.worldZ(quad.y2);
      positions[9] = DoomVertexAbi.worldX(quad.x1);
      positions[10] = DoomVertexAbi.worldY(quad.top);
      positions[11] = DoomVertexAbi.worldZ(quad.y1);

      final double texW = quad.textureWidth > 0 ? quad.textureWidth : 64.0;
      final double texH = quad.textureHeight > 0 ? quad.textureHeight : 128.0;
      final double u0 = entry == null ? 0 : entry.u0(pageSize);
      final double uSpan = entry == null ? 1 : entry.width / pageSize;
      final double v0 = entry == null ? 0 : entry.v0(pageSize);
      final double vSpan = entry == null ? 1 : entry.height / pageSize;

      // Texture-local coordinates. Atlas rect mapping happens exactly once in
      // the shader, after repeat/clamp resolution.
      final double uA = quad.uLeft / texW;
      final double uB = quad.uRight / texW;
      final double vTop = quad.yOffset / texH;
      final double vBottom = (quad.yOffset + quad.height) / texH;

      uvs[0] = uA;
      uvs[1] = vBottom;
      uvs[2] = uB;
      uvs[3] = vBottom;
      uvs[4] = uB;
      uvs[5] = vTop;
      uvs[6] = uA;
      uvs[7] = vTop;

      // Wall normal: perpendicular to the linedef, pointing into the sector
      // this side faces. In world space the map direction (dx, dy) becomes
      // (dx, 0, -dy), whose right-hand perpendicular is (-dy, 0, -dx).
      final double dx = quad.x2 - quad.x1;
      final double dy = quad.y2 - quad.y1;
      final double len = _length(dx, dy);
      final double nx = len > 0 ? dy / len : 0;
      final double nz = len > 0 ? dx / len : 0;

      final List<VertexRange> ranges = _packer.addPrimitive(
        page: page,
        kind: quad.kind,
        positions: positions,
        uvs: uvs,
        indices: quadIndices,
        normalX: nx,
        normalY: 0,
        normalZ: nz,
        light: quad.lightLevel,
        // Walls tile horizontally across a long linedef and vertically when a
        // band is taller than its texture.
        atlasU0: u0,
        atlasV0: v0,
        atlasU1: u0 + uSpan,
        atlasV1: v0 + vSpan,
        uvMode: DoomVertexAbi.uvModeRepeat,
      );
      bands.add(
        WallBandRef(
          linedef: quad.linedef,
          sidedef: quad.sidedef,
          textureName: quad.texture,
          band: quad.band,
          frontSector: quad.frontSector,
          backSector: quad.backSector,
          meshIndex: ranges.single.meshIndex,
          firstVertex: ranges.single.firstVertex,
          lowerUnpegged: quad.lowerUnpegged,
          upperUnpegged: quad.upperUnpegged,
          textureHeight: texH,
          textureWidth: texW,
          baseULeft: uA,
          baseURight: uB,
          scrollsHorizontally:
              map.linedefs[quad.linedef].special == 48 &&
              quad.sidedef == map.linedefs[quad.linedef].rightSidedef,
          yOffset: quad.yOffset,
          rawYOffset: quad.rawYOffset,
          nearCeilingAnchor: quad.nearCeiling,
          atlasV0: v0,
          atlasV1: v0 + vSpan,
          baseBottom: quad.bottom,
          baseTop: quad.top,
        ),
      );
    }
    return bands;
  }

  List<AnimatedSurfaceRef> _buildAnimationRefs(
    DoomAnimationResolution resolution,
    IndexedAtlas atlas,
    List<SectorPlaneRef> floors,
    List<SectorPlaneRef> ceilings,
    List<WallBandRef> bands,
  ) {
    final List<AnimatedSurfaceRef> result = <AnimatedSurfaceRef>[];
    for (final DoomAnimation animation in resolution.animations) {
      final List<AtlasEntry?> resolvedFrames = <AtlasEntry?>[
        for (final String name in animation.frames) atlas.entry(name),
      ];
      // A real IWAD publishes many valid animation ranges that a particular
      // map never references. Only used ranges were queued into this level's
      // bounded atlas, so absent entries here mean "unused", not corruption.
      if (resolvedFrames.any((AtlasEntry? entry) => entry == null)) continue;
      final List<AtlasEntry> frames = resolvedFrames.cast<AtlasEntry>();
      atlas.requireSamePage(
        frames,
        description:
            'animation ${animation.definition.startName}->${animation.definition.endName}',
      );
      for (var initial = 0; initial < animation.frames.length; initial++) {
        final String name = animation.frames[initial];
        final List<VertexRange> ranges = <VertexRange>[
          for (final SectorPlaneRef plane in <SectorPlaneRef>[
            ...floors,
            ...ceilings,
          ])
            if (plane.textureName == name) ...plane.ranges,
          for (final WallBandRef band in bands)
            if (band.textureName == name)
              VertexRange(
                meshIndex: band.meshIndex,
                firstVertex: band.firstVertex,
                vertexCount: WallBandRef.verticesPerQuad,
              ),
        ];
        if (ranges.isNotEmpty) {
          result.add(
            AnimatedSurfaceRef(
              frames: frames,
              speed: animation.definition.speed,
              initialFrame: initial,
              ranges: ranges,
            ),
          );
        }
      }
    }
    return result;
  }

  List<List<String>> _flatTransferGroups() {
    const Set<int> frontModelSpecials = <int>{20, 22, 59};
    final List<List<int>> touching = List<List<int>>.generate(
      map.sectors.length,
      (_) => <int>[],
      growable: false,
    );
    for (var lineIndex = 0; lineIndex < map.linedefs.length; lineIndex++) {
      final Linedef line = map.linedefs[lineIndex];
      touching[map.sidedefs[line.rightSidedef].sector].add(lineIndex);
      if (line.leftSidedef != kNoSidedef) {
        touching[map.sidedefs[line.leftSidedef].sector].add(lineIndex);
      }
    }

    int? neighbor(int sector, int lineIndex) {
      final Linedef line = map.linedefs[lineIndex];
      if (line.leftSidedef == kNoSidedef) return null;
      final int front = map.sidedefs[line.rightSidedef].sector;
      final int back = map.sidedefs[line.leftSidedef].sector;
      if (front == sector) return back;
      if (back == sector) return front;
      return null;
    }

    final List<List<String>> groups = <List<String>>[];
    final Map<int, List<int>> sectorsByTag = <int, List<int>>{};
    for (var sector = 0; sector < map.sectors.length; sector++) {
      final int tag = map.sectors[sector].tag;
      if (tag != 0) {
        sectorsByTag.putIfAbsent(tag, () => <int>[]).add(sector);
      }
    }
    final List<int> generations = List<int>.filled(map.sectors.length, 0);
    var generation = 0;
    for (final Linedef trigger in map.linedefs) {
      if (frontModelSpecials.contains(trigger.special)) {
        final int source = map.sidedefs[trigger.rightSidedef].sector;
        for (final int target in sectorsByTag[trigger.tag] ?? const <int>[]) {
          groups.add(<String>[
            map.sectors[target].floorFlat,
            map.sectors[source].floorFlat,
          ]);
        }
      } else if (trigger.special == 37) {
        for (final int target in sectorsByTag[trigger.tag] ?? const <int>[]) {
          int? model;
          var lowest = map.sectors[target].floorHeight;
          for (final int lineIndex in touching[target]) {
            final int? other = neighbor(target, lineIndex);
            if (other != null && map.sectors[other].floorHeight < lowest) {
              lowest = map.sectors[other].floorHeight;
            }
          }
          for (final int lineIndex in touching[target]) {
            final int? other = neighbor(target, lineIndex);
            if (other != null && map.sectors[other].floorHeight == lowest) {
              model = other;
              break;
            }
          }
          if (model != null) {
            groups.add(<String>[
              map.sectors[target].floorFlat,
              map.sectors[model].floorFlat,
            ]);
          }
        }
      } else if (trigger.special == 9) {
        generation++;
        var visits = 0;
        bool visit(int sector) {
          if (generations[sector] == generation) return true;
          if (visits >= options.limits.maxSectors) return false;
          generations[sector] = generation;
          visits++;
          return true;
        }

        for (final int inner in sectorsByTag[trigger.tag] ?? const <int>[]) {
          if (visits >= options.limits.maxSectors) break;
          if (!visit(inner)) break;
          int? ring;
          for (final int lineIndex in touching[inner]) {
            final int? candidate = neighbor(inner, lineIndex);
            if (candidate != null && visit(candidate)) {
              ring = candidate;
              break;
            }
          }
          if (ring == null) continue;
          int? outer;
          for (final int lineIndex in touching[ring]) {
            final int? candidate = neighbor(ring, lineIndex);
            if (candidate != null && candidate != inner && visit(candidate)) {
              outer = candidate;
              break;
            }
          }
          if (outer != null) {
            groups.add(<String>[
              map.sectors[ring].floorFlat,
              map.sectors[outer].floorFlat,
            ]);
          }
        }
      }
    }
    return groups;
  }

  static double _length(double dx, double dy) {
    final double sq = dx * dx + dy * dy;
    return sq <= 0 ? 0 : math.sqrt(sq);
  }

  /// Order-independent hash over emitted geometry, for regression pinning.
  ///
  /// Quantised to the weld lattice before hashing so a bit of floating-point
  /// noise cannot change the hash while the geometry is visually identical.
  static int _hash(List<PackedMesh> meshes) {
    var hash = 0x811C9DC5;
    for (var m = 0; m < meshes.length; m++) {
      final PackedMesh mesh = meshes[m];
      hash = _mix(hash, mesh.vertexCount);
      hash = _mix(hash, mesh.indexCount);
      hash = _mix(hash, mesh.atlasPage);
      hash = _mix(hash, mesh.kind.index);
      for (var f = 0; f < mesh.vertices.length; f++) {
        hash = _mix(hash, (mesh.vertices[f] * 128.0).round());
      }
      for (var i = 0; i < mesh.indices.length; i++) {
        hash = _mix(hash, mesh.indices[i]);
      }
    }
    return hash & 0x7FFFFFFF;
  }

  static int _mix(int hash, int value) {
    var h = hash ^ (value & 0xFFFFFFFF);
    h = (h * 0x01000193) & 0xFFFFFFFF;
    return h;
  }
}
