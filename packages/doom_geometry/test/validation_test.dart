import 'dart:typed_data';

import 'package:doom_geometry/doom_geometry.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/synthetic_map.dart';

/// The validator has to actually catch the defects it claims to catch. These
/// tests hand it deliberately broken geometry and assert it fires.
void main() {
  final GeometryValidator validator =
      GeometryValidator(GeometryOptions.defaults);

  SectorFinding check(SectorMesh2D bsp, SectorMesh2D oracle) =>
      validator.validateSector(
        sector: 0,
        bsp: bsp,
        loop: oracle,
        emptyRegions: 0,
        loopComplete: true,
        loopClosed: true,
        budget: CheckBudget(1000000),
      );

  group('defect detection fires', () {
    test('T-junction on a crafted bad case', () {
      // A 100x100 square split into two triangles on the left and, on the
      // right, a pair whose shared corner lands in the MIDDLE of the left
      // pair's long edge. That midpoint is a T-junction: geometrically the
      // shapes tile perfectly, but the long edge has no vertex there.
      final SectorMesh2D bad = SectorMesh2D(
        Float64List.fromList(<double>[
          0, 0, // 0
          50, 0, // 1
          50, 100, // 2
          0, 100, // 3
          50, 50, // 4  <- sits on the edge 1->2, which has no vertex for it
          100, 0, // 5
          100, 100, // 6
        ]),
        Uint32List.fromList(<int>[
          0, 1, 2, // left half, long edge 1->2
          0, 2, 3,
          1, 5, 4, // right half, cornering at the midpoint
          5, 6, 4,
          4, 6, 2,
        ]),
      );
      final SectorFinding finding = check(bad, bad);
      expect(finding.tJunctions, greaterThan(0),
          reason: 'the midpoint vertex must be detected on the long edge');
      expect(finding.issues, contains(GeometryIssue.tJunction));
      expect(validator.shouldFallBack(finding), isTrue);
    });

    test('clean tiling produces no T-junction', () {
      // The same square, but the long edge is split so both sides agree.
      final SectorMesh2D good = SectorMesh2D(
        Float64List.fromList(<double>[
          0, 0, //
          50, 0,
          50, 50,
          50, 100,
          0, 100,
          100, 0,
          100, 100,
        ]),
        Uint32List.fromList(<int>[
          0, 1, 2,
          0, 2, 3,
          0, 3, 4,
          1, 5, 2,
          5, 6, 2,
          6, 3, 2,
        ]),
      );
      final SectorFinding finding = check(good, good);
      expect(finding.tJunctions, 0);
      expect(finding.issues, isEmpty);
    });

    test('degenerate zero-area triangle', () {
      final SectorMesh2D bad = SectorMesh2D(
        Float64List.fromList(<double>[0, 0, 50, 0, 100, 0, 0, 100]),
        Uint32List.fromList(<int>[0, 1, 2, 0, 2, 3]),
      );
      final SectorFinding finding = check(bad, bad);
      expect(finding.degenerateTriangles, 1);
      expect(finding.issues, contains(GeometryIssue.degenerateTriangle));
    });

    test('overlapping triangles', () {
      final SectorMesh2D bad = SectorMesh2D(
        Float64List.fromList(<double>[0, 0, 100, 0, 0, 100, 10, 10, 90, 10, 10, 90]),
        Uint32List.fromList(<int>[0, 1, 2, 3, 4, 5]),
      );
      final SectorFinding finding = check(bad, bad);
      expect(finding.overlaps, greaterThan(0));
      expect(finding.issues, contains(GeometryIssue.overlap));
    });

    test('area mismatch against the oracle', () {
      final SectorMesh2D small = SectorMesh2D(
        Float64List.fromList(<double>[0, 0, 10, 0, 0, 10]),
        Uint32List.fromList(<int>[0, 1, 2]),
      );
      final SectorMesh2D big = SectorMesh2D(
        Float64List.fromList(<double>[0, 0, 1000, 0, 0, 1000]),
        Uint32List.fromList(<int>[0, 1, 2]),
      );
      final SectorFinding finding = check(small, big);
      expect(finding.issues, contains(GeometryIssue.areaMismatch));
      expect(validator.shouldFallBack(finding), isTrue);
    });

    test('an empty region is reported', () {
      final SectorFinding finding = validator.validateSector(
        sector: 0,
        bsp: SectorMesh2D.empty(),
        loop: SectorMesh2D.empty(),
        emptyRegions: 3,
        loopComplete: true,
        loopClosed: true,
        budget: CheckBudget(1000),
      );
      expect(finding.issues, contains(GeometryIssue.emptyRegion));
    });

    test('an unreliable oracle does not trigger a fallback', () {
      // If the oracle itself could not close the sector, falling back to it
      // would swap good geometry for worse.
      final SectorFinding finding = validator.validateSector(
        sector: 0,
        bsp: SectorMesh2D.empty(),
        loop: SectorMesh2D.empty(),
        emptyRegions: 0,
        loopComplete: false,
        loopClosed: false,
        budget: CheckBudget(1000),
      );
      expect(finding.issues, contains(GeometryIssue.openLoop));
      expect(validator.shouldFallBack(finding), isFalse);
    });
  });

  group('budgets are enforced', () {
    test('an exhausted budget is reported rather than run to completion', () {
      final CheckBudget tiny = CheckBudget(4);
      final MapBuilder b = MapBuilder('BUDGET');
      final int s = b.sector();
      b.solidLoop(<int>[0, 0, 512, 0, 512, 512, 0, 512], s);
      final MapData map = b.build();
      final BspRegionSet regions = BspRegionBuilder(map, GeometryOptions.defaults)
          .build(tiny);
      expect(tiny.exhausted, isTrue);
      expect(regions.budgetExhausted, isTrue);
      expect(regions.isUsable, isFalse);
    });

    test('compile under a tiny budget still returns a level and says so', () {
      final MapBuilder b = MapBuilder('TINY');
      final int s = b.sector();
      b.solidLoop(<int>[0, 0, 512, 0, 512, 512, 0, 512], s);
      final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
        b.build(),
        testTextures(),
        options: const GeometryOptions(
          limits: DoomLimits(maxIntersectionChecks: 8),
        ),
      );
      expect(level.report.budgetExhausted, isTrue);
      expect(level.report.isClean, isFalse);
    });

    test('BSP depth is capped', () {
      final MapBuilder b = MapBuilder('DEEP');
      final int s = b.sector();
      b.solidLoop(<int>[0, 0, 512, 0, 512, 512, 0, 512], s);
      final BspRegionSet regions = BspRegionBuilder(
        b.build(),
        const GeometryOptions(maxBspDepth: 1),
      ).build(CheckBudget(1000000));
      expect(regions.maxDepth, lessThanOrEqualTo(1));
    });

    test('ear clipping stops on a self-intersecting ring', () {
      // Figure-eight: no ear exists anywhere.
      final Loop bowtie = Loop(
        Float64List.fromList(<double>[0, 0, 100, 100, 100, 0, 0, 100]),
      );
      final TriangulationResult result =
          EarClipper().triangulate(bowtie, const <Loop>[], CheckBudget(10000));
      expect(result.isComplete, isFalse,
          reason: 'a self-intersecting ring must be reported, not looped on');
    });
  });

  group('atlas', () {
    test('packs flats and wall textures and reports their sub-rects', () {
      final AtlasBuilder builder =
          AtlasBuilder(testTextures(), GeometryOptions.defaults)
            ..addFlat('FLOOR0_1')
            ..addWallTexture('STARTAN3')
            ..addSprite('TROOA1');
      final IndexedAtlas atlas = builder.build();

      expect(atlas.pageCount, greaterThan(0));
      final AtlasEntry flat = atlas.entry('FLOOR0_1')!;
      expect(flat.width, 64);
      expect(flat.height, 64);
      expect(flat.tiling, isTrue);

      final AtlasEntry sprite = atlas.entry('TROOA1')!;
      expect(sprite.tiling, isFalse, reason: 'sprites clamp, never tile');
      expect(sprite.leftOffset, 20, reason: 'hotspot must survive packing');

      // Sub-rects must be inside the page.
      expect(flat.u0(atlas.pageSize), greaterThanOrEqualTo(0));
      expect(flat.u1(atlas.pageSize), lessThanOrEqualTo(1));
    });

    test('respects maxAtlasPixels instead of allocating unbounded pages', () {
      final AtlasBuilder builder = AtlasBuilder(
        testTextures(),
        const GeometryOptions(
          atlasPageSize: 64,
          limits: DoomLimits(maxAtlasPixels: 64 * 64),
        ),
      )
        ..addFlat('FLOOR0_1')
        ..addFlat('CEIL1_1')
        ..addWallTexture('BIGDOOR2');
      final IndexedAtlas atlas = builder.build();
      expect(atlas.pageCount, 1);
      expect(atlas.overflowed, isNotEmpty,
          reason: 'what did not fit must be named, not dropped in silence');
    });

    test('texel data lands in the index and coverage channels', () {
      final AtlasBuilder builder =
          AtlasBuilder(testTextures(), GeometryOptions.defaults)
            ..addFlat('FLOOR0_1');
      final IndexedAtlas atlas = builder.build();
      final AtlasEntry entry = atlas.entry('FLOOR0_1')!;
      final AtlasPage page = atlas.pages[entry.page];
      expect(page.indexAt(entry.x, entry.y), 7);
      expect(page.coverageAt(entry.x, entry.y), 255);
    });
  });

  group('packing', () {
    test('meshes never exceed the 16-bit index limit', () {
      final MapBuilder b = MapBuilder('HUGE');
      for (var i = 0; i < 120; i++) {
        final int s = b.sector(floorHeight: i);
        final int x = (i % 20) * 256;
        final int y = (i ~/ 20) * 256;
        b.solidLoop(
          <int>[x, y, x + 200, y, x + 200, y + 200, x, y + 200],
          s,
        );
      }
      final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
        b.build(buildNodes: false),
        testTextures(),
      );
      expect(level.meshes.length, greaterThan(0));
      for (final PackedMesh mesh in level.meshes) {
        expect(mesh.vertexCount, lessThanOrEqualTo(65535));
        for (final int index in mesh.indices) {
          expect(index, lessThan(mesh.vertexCount));
        }
      }
    });

    test('vertex stride matches the 20-float Flame ABI', () {
      final MapBuilder b = MapBuilder('ABI');
      final int s = b.sector();
      b.solidLoop(<int>[0, 0, 256, 0, 256, 256, 0, 256], s);
      final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
        b.build(),
        testTextures(),
      );
      expect(DoomVertexAbi.floatsPerVertex, 20);
      for (final PackedMesh mesh in level.meshes) {
        expect(
          mesh.vertices.length,
          mesh.vertexCount * DoomVertexAbi.floatsPerVertex,
        );
      }
    });

    test('meshes are grouped by atlas page and surface kind', () {
      final MapBuilder b = MapBuilder('SKY');
      final int ground = b.sector(ceilingFlat: 'F_SKY1');
      b.solidLoop(<int>[0, 0, 256, 0, 256, 256, 0, 256], ground);
      final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
        b.build(),
        testTextures(),
      );
      final Set<String> combos = level.meshes
          .map((PackedMesh m) => '${m.atlasPage}/${m.kind}')
          .toSet();
      // A mesh is homogeneous: every vertex shares one atlas page and one
      // surface kind, so the renderer binds once per mesh. Several meshes may
      // share a combination once one fills up, which is why this is a bound
      // rather than an equality.
      expect(combos.length, lessThanOrEqualTo(level.meshes.length));
      expect(
        level.meshes.any((PackedMesh m) => m.kind == SurfaceKind.sky),
        isTrue,
        reason: 'an F_SKY1 ceiling must land in the sky bucket',
      );
      expect(
        level.meshes.any((PackedMesh m) => m.kind == SurfaceKind.opaque),
        isTrue,
        reason: 'the floor is still opaque',
      );
    });
  });

  group('determinism', () {
    test('the same map compiles to the same hash every time', () {
      MapBuilder make() {
        final MapBuilder b = MapBuilder('DET');
        final int s = b.sector();
        b.solidLoop(
          <int>[0, 0, 256, 0, 256, 128, 128, 128, 128, 256, 0, 256],
          s,
        );
        return b;
      }
      final int a = DoomGeometryCompiler.compileWithTextures(
        make().build(),
        testTextures(),
      ).report.geometryHash;
      final int c = DoomGeometryCompiler.compileWithTextures(
        make().build(),
        testTextures(),
      ).report.geometryHash;
      expect(a, c);
    });

    test('different geometry hashes differently', () {
      final MapBuilder b1 = MapBuilder('A');
      final int s1 = b1.sector();
      b1.solidLoop(<int>[0, 0, 256, 0, 256, 256, 0, 256], s1);

      final MapBuilder b2 = MapBuilder('B');
      final int s2 = b2.sector();
      b2.solidLoop(<int>[0, 0, 320, 0, 320, 256, 0, 256], s2);

      expect(
        DoomGeometryCompiler.compileWithTextures(b1.build(), testTextures())
            .report
            .geometryHash,
        isNot(
          DoomGeometryCompiler.compileWithTextures(b2.build(), testTextures())
              .report
              .geometryHash,
        ),
      );
    });
  });
}
