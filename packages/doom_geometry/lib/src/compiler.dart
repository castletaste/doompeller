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

part 'compiler_packing.dart';

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
    final int compileMicroseconds = clock.elapsedMicroseconds;

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
      geometryHash: _geometryHash(meshes),
      compileMicroseconds: compileMicroseconds,
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
}
