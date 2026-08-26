import 'dart:io';
import 'dart:typed_data';

import 'package:doom_geometry/doom_geometry.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/synthetic_map.dart';

final bool _stressEnabled = Platform.environment['DOOM_SCALE_STRESS'] == '1';

void main() {
  test('packed triangles retain their own unique vertices', () {
    final _PackedTriangles result = _packSeparateTriangles(8);

    // This deliberately stays small for normal CI, but verifies the address
    // each index resolves to rather than merely that it is in bounds.
    _expectTriangleAddresses(result);
  });

  test(
    'stress: separate primitives split only at mesh boundaries',
    () {
      final _PackedTriangles result = _packSeparateTriangles(24000);

      // 24,000 triangles have 72,000 distinct vertices, so this assertion
      // proves the fixture actually crosses the uint16 vertex ceiling.
      expect(result.meshes.length, greaterThan(1));
      _expectMeshLimits(result.meshes);
      _expectTriangleAddresses(result);
    },
    skip: !_stressEnabled,
  );

  test(
    'stress: a triangle soup flushes before a triangle crosses a mesh',
    () {
      // 21,846 unique triangles need 65,538 vertices. This is intentionally
      // one addPrimitive call, exercising its pre-flush branch directly.
      final _PackedTriangles result = _packTriangleSoup(21846);

      expect(result.meshes.length, greaterThan(1));
      _expectMeshLimits(result.meshes);
      _expectTriangleAddresses(result);
    },
    skip: !_stressEnabled,
  );

  test(
    'stress: compiler splits a map while keeping planes and wall quads whole',
    () {
      const int sectorCount = 3000;
      final MapBuilder builder = MapBuilder('SPLIT');
      for (var sector = 0; sector < sectorCount; sector++) {
        final int index = builder.sector();
        final int x = sector * 256;
        builder.solidLoop(<int>[x, 0, x + 128, 0, x + 128, 128, x, 128], index);
      }
      final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
        builder.build(buildNodes: false),
        testTextures(),
        options: const GeometryOptions(
          bspFirst: false,
          validateAgainstLoops: false,
        ),
      );

      expect(level.meshes.length, greaterThan(1));
      expect(level.report.totalTriangles, sectorCount * 12);
      for (final SectorPlaneRef plane in <SectorPlaneRef>[
        ...level.floorPlanes,
        ...level.ceilingPlanes,
      ]) {
        expect(plane.ranges, hasLength(1));
        final VertexRange range = plane.ranges.single;
        expect(range.vertexCount, 4);
        expect(
          range.firstVertex + range.vertexCount,
          lessThanOrEqualTo(level.meshes[range.meshIndex].vertexCount),
        );
      }
      for (final WallBandRef band in level.wallBands) {
        expect(
          band.firstVertex + WallBandRef.verticesPerQuad,
          lessThanOrEqualTo(level.meshes[band.meshIndex].vertexCount),
        );
      }
      _expectMeshLimits(level.meshes);
    },
    skip: !_stressEnabled,
  );
}

_PackedTriangles _packSeparateTriangles(int triangleCount) {
  final MeshPacker packer = MeshPacker();
  final List<_ExpectedTriangle> expected = <_ExpectedTriangle>[];
  final List<VertexRange> ranges = <VertexRange>[];

  for (var triangle = 0; triangle < triangleCount; triangle++) {
    final _ExpectedTriangle input = _triangle(triangle);
    expected.add(input);
    final List<VertexRange> primitiveRanges = packer.addPrimitive(
      page: 0,
      kind: SurfaceKind.opaque,
      positions: input.positions,
      uvs: _uvs,
      indices: const <int>[0, 1, 2],
      normalX: 0,
      normalY: 1,
      normalZ: 0,
      light: 1,
      atlasU0: 0,
      atlasV0: 0,
      atlasU1: 1,
      atlasV1: 1,
    );
    // A one-triangle primitive must never be cut between meshes.
    expect(primitiveRanges, hasLength(1));
    ranges.add(primitiveRanges.single);
  }

  return _PackedTriangles(
    meshes: packer.finish(),
    expected: expected,
    ranges: ranges,
  );
}

_PackedTriangles _packTriangleSoup(int triangleCount) {
  final Float64List positions = Float64List(triangleCount * 9);
  final List<int> indices = <int>[];
  final List<_ExpectedTriangle> expected = <_ExpectedTriangle>[];
  for (var triangle = 0; triangle < triangleCount; triangle++) {
    final _ExpectedTriangle input = _triangle(triangle);
    expected.add(input);
    positions.setRange(triangle * 9, triangle * 9 + 9, input.positions);
    final int firstVertex = triangle * 3;
    indices.addAll(<int>[firstVertex, firstVertex + 1, firstVertex + 2]);
  }
  final MeshPacker packer = MeshPacker();
  final List<VertexRange> ranges = packer.addPrimitive(
    page: 0,
    kind: SurfaceKind.opaque,
    positions: positions,
    uvs: _repeatedUvs(triangleCount),
    indices: indices,
    normalX: 0,
    normalY: 1,
    normalZ: 0,
    light: 1,
    atlasU0: 0,
    atlasV0: 0,
    atlasU1: 1,
    atlasV1: 1,
  );
  return _PackedTriangles(
    meshes: packer.finish(),
    expected: expected,
    ranges: ranges,
  );
}

void _expectMeshLimits(List<PackedMesh> meshes) {
  for (final PackedMesh mesh in meshes) {
    expect(
      mesh.vertexCount,
      lessThanOrEqualTo(DoomVertexAbi.maxVerticesPerMesh),
    );
    expect(mesh.indices.length, mesh.indexCount);
    expect(mesh.indices, everyElement(lessThan(mesh.vertexCount)));
    expect(mesh.indexCount % 3, 0);
  }
}

void _expectTriangleAddresses(_PackedTriangles result) {
  final List<List<int>> rangeOwnerByMesh = result.meshes
      .map((PackedMesh mesh) => List<int>.filled(mesh.vertexCount, -1))
      .toList();
  for (var rangeIndex = 0; rangeIndex < result.ranges.length; rangeIndex++) {
    final VertexRange range = result.ranges[rangeIndex];
    expect(range.meshIndex, inInclusiveRange(0, result.meshes.length - 1));
    expect(range.vertexCount, greaterThan(0));
    expect(
      range.firstVertex + range.vertexCount,
      lessThanOrEqualTo(result.meshes[range.meshIndex].vertexCount),
    );
    final List<int> owners = rangeOwnerByMesh[range.meshIndex];
    final int end = range.firstVertex + range.vertexCount;
    for (var vertex = range.firstVertex; vertex < end; vertex++) {
      expect(owners[vertex], -1, reason: 'VertexRanges must not overlap');
      owners[vertex] = rangeIndex;
    }
  }

  var triangle = 0;
  for (var meshIndex = 0; meshIndex < result.meshes.length; meshIndex++) {
    final PackedMesh mesh = result.meshes[meshIndex];
    for (var index = 0; index < mesh.indexCount; index += 3) {
      expect(triangle, lessThan(result.expected.length));
      final List<int> triangleIndices = <int>[
        mesh.indices[index],
        mesh.indices[index + 1],
        mesh.indices[index + 2],
      ];
      final List<int> owners = triangleIndices
          .map((int vertex) => rangeOwnerByMesh[meshIndex][vertex])
          .toList();
      // Every triangle belongs entirely to exactly one returned VertexRange.
      // Therefore its three vertices cannot be split across meshes either.
      expect(owners, everyElement(greaterThanOrEqualTo(0)));
      expect(owners.toSet(), hasLength(1));

      final _ExpectedTriangle input = result.expected[triangle];
      for (var corner = 0; corner < 3; corner++) {
        final int packedOffset =
            triangleIndices[corner] * DoomVertexAbi.floatsPerVertex +
            DoomVertexAbi.positionOffset;
        final int expectedOffset = corner * 3;
        expect(mesh.vertices[packedOffset], input.positions[expectedOffset]);
        expect(
          mesh.vertices[packedOffset + 1],
          input.positions[expectedOffset + 1],
        );
        expect(
          mesh.vertices[packedOffset + 2],
          input.positions[expectedOffset + 2],
        );
      }
      triangle++;
    }
  }
  expect(triangle, result.expected.length);
}

_ExpectedTriangle _triangle(int triangle) {
  final double id = triangle.toDouble() * 10;
  return _ExpectedTriangle(
    Float64List.fromList(<double>[
      id + 0,
      100000 + id + 0,
      -100000 - id - 0,
      id + 1,
      100000 + id + 1,
      -100000 - id - 1,
      id + 2,
      100000 + id + 2,
      -100000 - id - 2,
    ]),
  );
}

final Float64List _uvs = Float64List.fromList(<double>[0, 0, 1, 0, 0, 1]);

Float64List _repeatedUvs(int triangleCount) {
  final Float64List uvs = Float64List(triangleCount * 6);
  for (var triangle = 0; triangle < triangleCount; triangle++) {
    uvs.setRange(triangle * 6, triangle * 6 + 6, _uvs);
  }
  return uvs;
}

class _PackedTriangles {
  const _PackedTriangles({
    required this.meshes,
    required this.expected,
    required this.ranges,
  });

  final List<PackedMesh> meshes;
  final List<_ExpectedTriangle> expected;
  final List<VertexRange> ranges;
}

class _ExpectedTriangle {
  const _ExpectedTriangle(this.positions);

  final Float64List positions;
}
