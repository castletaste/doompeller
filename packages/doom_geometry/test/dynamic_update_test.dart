import 'package:doom_geometry/doom_geometry.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/synthetic_map.dart';

/// In-place height updates: the hard requirement that doors and lifts must not
/// rebuild meshes.
void main() {
  test('moving a floor rewrites vertices without touching mesh identity', () {
    final CompiledLevel level = _compile();
    final PackedMesh mesh = level.meshes.first;
    final int vertexCountBefore = mesh.vertexCount;
    final int indexCountBefore = mesh.indexCount;
    final Object identityBefore = mesh.vertices;

    final int touched = level.setFloorHeight(0, 64);

    expect(touched, greaterThan(0));
    expect(level.meshes.first.vertexCount, vertexCountBefore);
    expect(level.meshes.first.indexCount, indexCountBefore);
    expect(
      identical(level.meshes.first.vertices, identityBefore),
      isTrue,
      reason: 'the buffer must be rewritten in place, not reallocated',
    );
  });

  test('floor vertices actually carry the new height', () {
    final CompiledLevel level = _compile();
    final SectorPlaneRef floor = level.floorPlanes.firstWhere(
      (SectorPlaneRef p) => p.sector == 0,
    );
    expect(floor.height, 0);

    level.setFloorHeight(0, 72);
    expect(floor.height, 72);

    for (final VertexRange range in floor.ranges) {
      final PackedMesh mesh = level.meshes[range.meshIndex];
      for (
        var v = range.firstVertex;
        v < range.firstVertex + range.vertexCount;
        v++
      ) {
        expect(mesh.vertexHeight(v), 72);
      }
    }
  });

  test('ceiling moves independently of the floor', () {
    final CompiledLevel level = _compile();
    level.setCeilingHeight(0, 200);
    final SectorPlaneRef floor = level.floorPlanes.firstWhere(
      (SectorPlaneRef p) => p.sector == 0,
    );
    final SectorPlaneRef ceiling = level.ceilingPlanes.firstWhere(
      (SectorPlaneRef p) => p.sector == 0,
    );
    expect(ceiling.height, 200);
    expect(floor.height, 0);
  });

  test('setting the same height twice is a no-op', () {
    final CompiledLevel level = _compile();
    expect(level.setFloorHeight(0, 40), greaterThan(0));
    expect(level.setFloorHeight(0, 40), 0);
  });

  test('floor transfer rewrites only the retained plane atlas rectangles', () {
    final MapBuilder b = MapBuilder('FLATXFER');
    final int source = b.sector(floorFlat: 'FLOOR4_8');
    final int target = b.sector(floorFlat: 'FLOOR0_1', tag: 7);
    b.solidLoop(<int>[0, 0, 128, 0, 128, 128, 0, 128], source);
    b.solidLoop(<int>[128, 0, 256, 0, 256, 128, 128, 128], target);
    final int v1 = b.vertex(128, 128);
    final int v2 = b.vertex(128, 0);
    b.line(
      v1: v1,
      v2: v2,
      right: b.sidedef(sector: source),
      left: b.sidedef(sector: target),
      special: 59,
      tag: 7,
    );
    final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
      b.build(buildNodes: false),
      testTextures(),
    );
    final SectorPlaneRef plane = level.floorPlanes.firstWhere(
      (SectorPlaneRef item) => item.sector == target,
    );
    final AtlasEntry sourceEntry = level.atlas.entry('FLOOR4_8')!;
    expect(
      level.atlas.entry('FLOOR0_1')!.page,
      sourceEntry.page,
      reason: 'runtime-mutated flat pair must share one material page',
    );

    expect(level.setFloorFlat(target, 'FLOOR4_8'), plane.vertexCount);
    expect(plane.textureName, 'FLOOR4_8');
    for (final VertexRange range in plane.ranges) {
      final PackedMesh mesh = level.meshes[range.meshIndex];
      for (
        var vertex = range.firstVertex;
        vertex < range.firstVertex + range.vertexCount;
        vertex++
      ) {
        final int offset =
            vertex * DoomVertexAbi.floatsPerVertex +
            DoomVertexAbi.atlasRectOffset;
        expect(mesh.vertices.sublist(offset, offset + 4), <double>[
          sourceEntry.u0(level.atlas.pageSize),
          sourceEntry.v0(level.atlas.pageSize),
          sourceEntry.u1(level.atlas.pageSize),
          sourceEntry.v1(level.atlas.pageSize),
        ]);
      }
    }
  });

  test('floor-transfer co-location overflow is a typed compile failure', () {
    final MapBuilder b = MapBuilder('FLATXFERLIMIT');
    final int source = b.sector(floorFlat: 'FLOOR4_8');
    final int target = b.sector(floorFlat: 'FLOOR0_1', tag: 7);
    b.solidLoop(<int>[0, 0, 64, 0, 64, 64, 0, 64], source);
    b.solidLoop(<int>[64, 0, 128, 0, 128, 64, 64, 64], target);
    final int v1 = b.vertex(64, 64);
    final int v2 = b.vertex(64, 0);
    b.line(
      v1: v1,
      v2: v2,
      right: b.sidedef(sector: source),
      left: b.sidedef(sector: target),
      special: 59,
      tag: 7,
    );
    expect(
      () => DoomGeometryCompiler.compileWithTextures(
        b.build(buildNodes: false),
        testTextures(),
        options: const GeometryOptions(atlasPageSize: 64),
      ),
      throwsA(isA<DoomLimitFailure>()),
    );
  });

  test('cross-page floor mutation is a typed failure', () {
    final CompiledLevel level = _compile();
    final SectorPlaneRef floor = level.floorPlanes.first;
    final int currentPage =
        level.meshes[floor.ranges.first.meshIndex].atlasPage;
    final AtlasEntry crossPage = AtlasEntry(
      name: 'CROSS',
      page: currentPage + 1,
      x: 0,
      y: 0,
      width: 64,
      height: 64,
      tiling: true,
      leftOffset: 0,
      topOffset: 0,
    );
    final CompiledLevel malformed = CompiledLevel(
      meshes: level.meshes,
      atlas: IndexedAtlas(
        pages: level.atlas.pages,
        pageSize: level.atlas.pageSize,
        entries: <String, AtlasEntry>{
          ...level.atlas.entries,
          crossPage.name: crossPage,
        },
        overflowed: level.atlas.overflowed,
        totalPixels: level.atlas.totalPixels,
      ),
      floorPlanes: level.floorPlanes,
      ceilingPlanes: level.ceilingPlanes,
      wallBands: level.wallBands,
      animations: level.animations,
      switchFrames: level.switchFrames,
      report: level.report,
      skyTextureName: level.skyTextureName,
    );
    expect(
      () => malformed.setFloorFlat(floor.sector, crossPage.name),
      throwsA(isA<DoomFormatFailure>()),
    );
  });

  test('an open door\'s upper band tracks the ceiling as it closes', () {
    // A door is compiled in its CLOSED state and opened at runtime, not the
    // other way around. That is not a test convenience, it is the requirement:
    // a band only exists if it had non-zero height at compile time, so a door
    // authored fully open would have no upper band for the runtime to move and
    // the doorway would render as a hole. Vanilla maps follow the same rule.
    final MapBuilder b = MapBuilder('DOOR');
    final int room = b.sector(floorHeight: 0, ceilingHeight: 128);
    final int door = b.sector(floorHeight: 0, ceilingHeight: 0);
    b.solidLoop(<int>[0, 0, 256, 0, 256, 256, 0, 256], room);
    final int v1 = b.vertex(256, 0);
    final int v2 = b.vertex(256, 256);
    final int frontSide = b.sidedef(
      sector: room,
      upper: 'BIGDOOR2',
      lower: 'BIGDOOR2',
    );
    final int backSide = b.sidedef(
      sector: door,
      upper: 'BIGDOOR2',
      lower: 'BIGDOOR2',
    );
    b.line(v1: v2, v2: v1, right: frontSide, left: backSide);
    b.solidLoop(<int>[256, 0, 512, 0, 512, 256, 256, 256], door);

    final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
      b.build(),
      testTextures(),
    );

    final WallBandRef upper = level.wallBands.firstWhere(
      (WallBandRef w) => w.band == WallBandKind.upper && w.frontSector == room,
    );
    // Closed: the upper band spans the whole doorway.
    expect(upper.bottom, 0);
    expect(upper.top, 128);

    final List<double> floors = <double>[0, 0];
    final List<double> ceilings = <double>[128, 0];

    // Open it: the door's ceiling rises to meet the room's, so the band that
    // was covering the doorway shrinks to nothing.
    ceilings[door] = 128;
    level.setCeilingHeight(door, 128);
    final int updated = level.updateWallsForSector(
      door,
      0,
      128,
      floors,
      ceilings,
    );
    expect(updated, greaterThan(0));
    expect(upper.top, upper.bottom, reason: 'a fully open door shows no upper');

    // Halfway shut again.
    ceilings[door] = 64;
    level.setCeilingHeight(door, 64);
    level.updateWallsForSector(door, 0, 64, floors, ceilings);
    expect(upper.bottom, 64);
    expect(upper.top, 128);
  });

  test('a wall band re-pegs its texture when it moves', () {
    final CompiledLevel level = _compile();
    final WallBandRef band = level.wallBands.first;
    final PackedMesh mesh = level.meshes[band.meshIndex];
    final double vBefore = mesh.vertexV(band.firstVertex);

    band.applyHeights(level.meshes, 0, 64);

    expect(mesh.vertexHeight(band.firstVertex + 2), 64);
    expect(
      mesh.vertexV(band.firstVertex),
      isNot(vBefore),
      reason: 'a shorter wall shows a different slice of its texture',
    );
  });

  test('lower-unpegged wall recomputes from the raw sidedef offset', () {
    final MapBuilder b = MapBuilder('LIFT');
    final int room = b.sector(floorHeight: 0, ceilingHeight: 128);
    final int lift = b.sector(floorHeight: 128, ceilingHeight: 128);
    b.solidLoop(<int>[0, 0, 128, 0, 128, 128, 0, 128], room);
    final int v1 = b.vertex(128, 0);
    final int v2 = b.vertex(128, 128);
    final int front = b.sidedef(sector: room, lower: 'STARTAN3', yOffset: 0);
    final int back = b.sidedef(sector: lift, lower: 'STARTAN3');
    b.line(
      v1: v2,
      v2: v1,
      right: front,
      left: back,
      flags: LinedefFlags.lowerUnpegged,
      special: 62,
    );
    b.solidLoop(<int>[128, 0, 256, 0, 256, 128, 128, 128], lift);
    final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
      b.build(),
      testTextures(),
    );
    final WallBandRef lower = level.wallBands.firstWhere(
      (WallBandRef w) => w.band == WallBandKind.lower && w.frontSector == room,
    );
    final List<double> floors = <double>[0, 128];
    final List<double> ceilings = <double>[128, 128];
    for (final double height in <double>[64, 128, 64]) {
      floors[lift] = height;
      level.updateWallsForSector(lift, height, 128, floors, ceilings);
      final PackedMesh mesh = level.meshes[lower.meshIndex];
      final double topV = mesh.vertexV(lower.firstVertex + 2);
      expect(topV, closeTo((128 - height) / 128, 1e-6));
    }
  });

  test('manual door special tag zero precreates its collapsed upper band', () {
    final MapBuilder b = MapBuilder('MANUALDOOR');
    final int room = b.sector(floorHeight: 0, ceilingHeight: 128);
    final int door = b.sector(floorHeight: 0, ceilingHeight: 128);
    b.solidLoop(<int>[0, 0, 128, 0, 128, 128, 0, 128], room);
    final int v1 = b.vertex(128, 0);
    final int v2 = b.vertex(128, 128);
    final int front = b.sidedef(sector: room, upper: 'BIGDOOR2');
    final int back = b.sidedef(sector: door, upper: 'BIGDOOR2');
    b.line(v1: v2, v2: v1, right: front, left: back, special: 1, tag: 0);
    b.solidLoop(<int>[128, 0, 256, 0, 256, 128, 128, 128], door);
    final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
      b.build(),
      testTextures(),
    );
    final WallBandRef upper = level.wallBands.firstWhere(
      (WallBandRef w) => w.band == WallBandKind.upper && w.frontSector == room,
    );
    expect(upper.top, upper.bottom);
    final List<double> floors = <double>[0, 0];
    final List<double> ceilings = <double>[128, 128];
    ceilings[door] = 64;
    level.updateWallsForSector(door, 0, 64, floors, ceilings);
    expect(upper.bottom, 64);
    expect(upper.top, 128);
  });

  test('an inverted opening collapses rather than inverting', () {
    final CompiledLevel level = _compile();
    final WallBandRef band = level.wallBands.first;
    final bool visible = band.applyHeights(level.meshes, 100, 40);
    expect(visible, isFalse);
    expect(
      band.top,
      band.bottom,
      reason: 'top below bottom must clamp, not flip the quad',
    );
  });

  test('updates survive a mesh split boundary', () {
    // Enough geometry to cross 65535 vertices and force several meshes.
    final MapBuilder b = MapBuilder('BIG');
    for (var i = 0; i < 40; i++) {
      final int s = b.sector(floorHeight: i);
      final int x = i * 256;
      b.solidLoop(<int>[x, 0, x + 200, 0, x + 200, 200, x, 200], s);
    }
    final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
      b.build(buildNodes: false),
      testTextures(),
    );
    for (final SectorPlaneRef plane in level.floorPlanes) {
      final int touched = level.setFloorHeight(plane.sector, 999);
      expect(touched, greaterThan(0));
      for (final VertexRange range in plane.ranges) {
        expect(range.meshIndex, lessThan(level.meshes.length));
        expect(
          range.firstVertex + range.vertexCount,
          lessThanOrEqualTo(level.meshes[range.meshIndex].vertexCount),
        );
      }
    }
  });
}

CompiledLevel _compile() {
  final MapBuilder b = MapBuilder('UPD');
  final int s = b.sector(floorHeight: 0, ceilingHeight: 128);
  b.solidLoop(<int>[0, 0, 256, 0, 256, 256, 0, 256], s);
  return DoomGeometryCompiler.compileWithTextures(b.build(), testTextures());
}
