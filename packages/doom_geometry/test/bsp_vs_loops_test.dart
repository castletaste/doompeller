import 'dart:typed_data';

import 'package:doom_geometry/doom_geometry.dart';
import 'package:doom_wad/doom_wad.dart' show BspNode;
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/synthetic_map.dart';

/// The M2 acceptance test: BSP-first geometry must agree with the sector-loop
/// oracle on covered area, with no gaps, on every shape E1M1 contains.
void main() {
  group('BSP agrees with the loop oracle', () {
    test('convex room', () {
      _expectAgreement(
        _room(<int>[0, 0, 256, 0, 256, 256, 0, 256]),
        expectedArea: 256 * 256,
      );
    });

    test('concave L-shaped room', () {
      _expectAgreement(
        _room(<int>[0, 0, 256, 0, 256, 128, 128, 128, 128, 256, 0, 256]),
        expectedArea: 256 * 256 - 128 * 128,
      );
    });

    test('concave U-shaped room', () {
      _expectAgreement(
        _room(<int>[
          0, 0, 384, 0, 384, 256, 256, 256, 256, 128, //
          128, 128, 128, 256, 0, 256,
        ]),
        expectedArea: 384 * 256 - 128 * 128,
      );
    });

    test('star-shaped room with many reflex corners', () {
      _expectAgreement(
        _room(<int>[
          256, 0, 320, 192, 512, 256, 320, 320, //
          256, 512, 192, 320, 0, 256, 192, 192,
        ]),
        // Two overlapping squares rotated 45 degrees: area computed by the
        // oracle itself, so only agreement is asserted here.
        expectedArea: null,
      );
    });

    test('very thin corridor', () {
      _expectAgreement(
        _room(<int>[0, 0, 1024, 0, 1024, 8, 0, 8]),
        expectedArea: 1024 * 8,
      );
    });

    test('room with a rectangular hole', () {
      final MapBuilder b = MapBuilder('HOLE');
      final int room = b.sector(floorHeight: 0, ceilingHeight: 128);
      final int pillar = b.sector(floorHeight: 128, ceilingHeight: 128);
      b.solidLoop(<int>[0, 0, 512, 0, 512, 512, 0, 512], room);
      b.twoSidedLoop(
        <int>[192, 192, 192, 320, 320, 320, 320, 192],
        room,
        pillar,
      );
      _expectAgreementFor(b.build(), room, 512 * 512 - 128 * 128);
    });

    test('room with two holes', () {
      final MapBuilder b = MapBuilder('HOLES2');
      final int room = b.sector();
      final int p1 = b.sector(floorHeight: 64);
      final int p2 = b.sector(floorHeight: 64);
      b.solidLoop(<int>[0, 0, 768, 0, 768, 512, 0, 512], room);
      b.twoSidedLoop(<int>[128, 128, 128, 256, 256, 256, 256, 128], room, p1);
      b.twoSidedLoop(<int>[448, 192, 448, 320, 576, 320, 576, 192], room, p2);
      _expectAgreementFor(b.build(), room, 768 * 512 - 2 * 128 * 128);
    });

    test('nested sectors three deep', () {
      final MapBuilder b = MapBuilder('NEST');
      final int outer = b.sector(floorHeight: 0);
      final int middle = b.sector(floorHeight: 16);
      final int inner = b.sector(floorHeight: 32);
      b.solidLoop(<int>[0, 0, 768, 0, 768, 768, 0, 768], outer);
      b.twoSidedLoop(
        <int>[128, 128, 128, 640, 640, 640, 640, 128],
        outer,
        middle,
      );
      b.twoSidedLoop(
        <int>[256, 256, 256, 512, 512, 512, 512, 256],
        middle,
        inner,
      );
      final MapData map = b.build();
      _expectAgreementFor(map, outer, 768 * 768 - 512 * 512);
      _expectAgreementFor(map, middle, 512 * 512 - 256 * 256);
      _expectAgreementFor(map, inner, 256 * 256);
    });

    test('diagonal walls', () {
      _expectAgreement(
        _room(<int>[0, 0, 512, 0, 384, 256, 128, 256]),
        // Trapezoid: (512 + 256) / 2 * 256.
        expectedArea: (512 + 256) ~/ 2 * 256,
      );
    });

    test('many small sectors in a grid', () {
      final MapBuilder b = MapBuilder('GRID');
      final List<int> cells = <int>[];
      for (var gx = 0; gx < 4; gx++) {
        for (var gy = 0; gy < 4; gy++) {
          final int s = b.sector(floorHeight: (gx + gy) * 8);
          cells.add(s);
          final int x = gx * 128;
          final int y = gy * 128;
          b.solidLoop(<int>[x, y, x + 128, y, x + 128, y + 128, x, y + 128], s);
        }
      }
      final MapData map = b.build();
      for (final int s in cells) {
        _expectAgreementFor(map, s, 128 * 128);
      }
    });
  });

  group('degenerate and hostile input', () {
    test('collinear BSP region is reported and never packed', () {
      final MapBuilder b = MapBuilder('COLLINEAR');
      final int s = b.sector();
      b.solidLoop(<int>[0, 0, 64, 0, 64, 64, 0, 64], s);
      final MapData original = b.build();
      final MapData map = MapData(
        name: original.name,
        vertices: original.vertices,
        linedefs: original.linedefs,
        sidedefs: original.sidedefs,
        sectors: original.sectors,
        segs: original.segs,
        subsectors: original.subsectors,
        // The only reachable leaf is squeezed between x<=0 and x>=0. This is
        // a malformed but bounded BSP whose recovered polygon is a line.
        nodes: <BspNode>[
          BspNode(
            x: 0,
            y: 0,
            dx: 0,
            dy: 1,
            rightBox: Int16List(4),
            leftBox: Int16List(4),
            rightChild: 0x8001,
            leftChild: 0x8000,
          ),
          BspNode(
            x: 0,
            y: 0,
            dx: 0,
            dy: 1,
            rightBox: Int16List(4),
            leftBox: Int16List(4),
            rightChild: 0,
            leftChild: 0x8001,
          ),
        ],
        things: original.things,
        blockmap: original.blockmap,
        reject: original.reject,
      );
      final BspRegionSet regions = BspRegionBuilder(
        map,
        GeometryOptions.defaults,
      ).build(CheckBudget(100000));
      expect(regions.regions, isNotEmpty);
      expect(regions.regions.single.isEmpty, isTrue);

      final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
        map,
        testTextures(),
      );
      expect(level.meshes, isNotEmpty, reason: 'the loop oracle must fallback');
      expect(level.report.fallbackSectors, contains(s));
      expect(
        level.report.findings.any(
          (SectorFinding f) => f.issues.contains(GeometryIssue.emptyRegion),
        ),
        isTrue,
      );
    });

    test('zero-length linedef is ignored, not fatal', () {
      final MapBuilder b = MapBuilder('ZEROLEN');
      final int s = b.sector();
      b.solidLoop(<int>[0, 0, 256, 0, 256, 256, 0, 256], s);
      final int v = b.vertex(64, 64);
      final int side = b.sidedef(sector: s, middle: 'STARTAN3');
      b.line(v1: v, v2: v, right: side);
      final MapData map = b.build();
      final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
        map,
        testTextures(),
      );
      expect(level.report.totalTriangles, greaterThan(0));
    });

    test('sector with no linedefs produces no geometry and no crash', () {
      final MapBuilder b = MapBuilder('ORPHAN');
      final int used = b.sector();
      b.sector(floorHeight: 64);
      b.solidLoop(<int>[0, 0, 256, 0, 256, 256, 0, 256], used);
      final MapData map = b.build();
      final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
        map,
        testTextures(),
      );
      expect(level.report.findings.length, 2);
      expect(level.report.findings[1].loopArea, 0);
    });

    test('map with no BSP at all falls back to loops for every sector', () {
      final MapBuilder b = MapBuilder('NOBSP');
      final int s = b.sector();
      b.solidLoop(<int>[0, 0, 256, 0, 256, 256, 0, 256], s);
      final MapData map = b.build(buildNodes: false);
      final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
        map,
        testTextures(),
      );
      expect(level.report.fallbackSectors, <int>[0]);
      expect(level.report.totalTriangles, greaterThan(0));
      // Falling back is not an error, and the report must not invent a gap.
      expect(level.report.totalAreaDelta, 0);
    });

    test(
      'open (unclosed) sector boundary is reported, not silently dropped',
      () {
        final MapBuilder b = MapBuilder('OPEN');
        final int s = b.sector();
        // Three walls of a square: the loop never closes.
        final int v0 = b.vertex(0, 0);
        final int v1 = b.vertex(256, 0);
        final int v2 = b.vertex(256, 256);
        final int v3 = b.vertex(0, 256);
        b.line(
          v1: v0,
          v2: v1,
          right: b.sidedef(sector: s, middle: 'STARTAN3'),
        );
        b.line(
          v1: v1,
          v2: v2,
          right: b.sidedef(sector: s, middle: 'STARTAN3'),
        );
        b.line(
          v1: v2,
          v2: v3,
          right: b.sidedef(sector: s, middle: 'STARTAN3'),
        );
        final MapData map = b.build();
        final List<SectorLoopResult> loops = SectorLoopBuilder(
          map,
          GeometryOptions.defaults,
        ).buildAll(CheckBudget(100000));
        expect(loops[s].openChains, greaterThan(0));
        expect(loops[s].isWellFormed, isFalse);
      },
    );
  });
}

MapData _room(List<int> points) {
  final MapBuilder b = MapBuilder('ROOM');
  final int s = b.sector(floorHeight: 0, ceilingHeight: 128);
  b.solidLoop(points, s);
  return b.build();
}

void _expectAgreement(MapData map, {int? expectedArea}) {
  _expectAgreementFor(map, 0, expectedArea);
}

void _expectAgreementFor(MapData map, int sector, int? expectedArea) {
  const GeometryOptions options = GeometryOptions.defaults;
  final BspRegionSet regions = BspRegionBuilder(
    map,
    options,
  ).build(CheckBudget(4000000));
  final List<SectorLoopResult> loops = SectorLoopBuilder(
    map,
    options,
  ).buildAll(CheckBudget(4000000));

  expect(regions.budgetExhausted, isFalse, reason: 'BSP budget exhausted');
  expect(regions.depthExceeded, isFalse, reason: 'BSP too deep');
  expect(regions.emptyRegions, 0, reason: 'a subsector clipped to empty');
  expect(loops[sector].openChains, 0, reason: 'sector boundary did not close');
  expect(
    loops[sector].isComplete,
    isTrue,
    reason: 'oracle triangulation incomplete',
  );

  final double loopArea = oracleArea(loops[sector]);
  final double bspArea = bspAreaOfSector(regions, sector);

  if (expectedArea != null) {
    expect(
      loopArea,
      closeTo(expectedArea.toDouble(), 1e-6),
      reason: 'oracle disagrees with the hand-computed area',
    );
  }
  // Tolerance is relative, not absolute. The BSP path reaches a vertex by
  // intersecting partition planes, so a coordinate on a diagonal wall is an
  // irrational-in-binary quotient that gets rounded twice: once by the
  // intersection arithmetic, once by the weld lattice. The oracle reaches the
  // same vertex straight from integer map data with no arithmetic at all. The
  // two therefore agree to floating-point precision rather than exactly, and
  // demanding more than that tests the tolerance rather than the geometry.
  //
  // 1e-6 relative is roughly 0.07 square units on a 65536-unit sector: far
  // below one pixel of coverage anywhere, and eight orders of magnitude tighter
  // than the smallest gap that could ever be visible.
  final double tolerance = loopArea * 1e-6 + 1e-6;
  expect(
    bspArea,
    closeTo(loopArea, tolerance),
    reason:
        'BSP and oracle disagree: gap of ${(bspArea - loopArea).abs()} '
        'on $loopArea (relative ${(bspArea - loopArea).abs() / loopArea})',
  );
}
