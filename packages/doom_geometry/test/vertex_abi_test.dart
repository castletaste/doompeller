import 'dart:typed_data';

import 'package:doom_geometry/doom_geometry.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/synthetic_map.dart';

/// Tripwire for the vertex ABI shared with lib/adapter.
///
/// doom_geometry is pure Dart and cannot import flame_3d, so it cannot assert
/// against a real Vertex the way the adapter's own tripwire does. What it CAN
/// do is pin the field meanings it writes, so that if the adapter's layout ever
/// moves, exactly one of these fails and names the field rather than the level
/// rendering as garbage.
///
/// The adapter's lib/adapter/vertex_abi.dart is the authority. These constants
/// must mirror it exactly.
void main() {
  test('offsets match lib/adapter/vertex_abi.dart', () {
    expect(DoomVertexAbi.floatsPerVertex, 20);
    expect(DoomVertexAbi.positionOffset, 0);
    expect(DoomVertexAbi.texCoordOffset, 3);
    expect(DoomVertexAbi.colorOffset, 5);
    expect(DoomVertexAbi.normalOffset, 9);
    expect(DoomVertexAbi.atlasRectOffset, 12);
    expect(DoomVertexAbi.paramsOffset, 16);
    expect(DoomVertexAbi.uvModeClamp, 0);
    expect(DoomVertexAbi.uvModeRepeat, 1);
    expect(DoomVertexAbi.lightRowAutomatic, -1);
  });

  test('every emitted vertex is a well-formed record', () {
    final MapBuilder b = MapBuilder('ABI');
    final int s = b.sector(lightLevel: 192);
    b.solidLoop(<int>[0, 0, 256, 0, 256, 256, 0, 256], s);
    final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
      b.build(),
      testTextures(),
    );

    expect(level.meshes, isNotEmpty);
    for (final PackedMesh mesh in level.meshes) {
      expect(
        mesh.vertices.length,
        mesh.vertexCount * DoomVertexAbi.floatsPerVertex,
        reason: 'buffer length must be an exact multiple of the stride',
      );
      for (var v = 0; v < mesh.vertexCount; v++) {
        final int o = v * DoomVertexAbi.floatsPerVertex;

        // Colour record: light in red, 1 in green and blue, alpha 1.
        final double light = mesh.vertices[o + 5];
        expect(light, inInclusiveRange(0, 1));
        expect(mesh.vertices[o + 6], 1.0);
        expect(mesh.vertices[o + 7], 1.0);
        expect(mesh.vertices[o + 8], 1.0);

        // Normal must be unit length; a zero normal would black out lighting.
        final double nx = mesh.vertices[o + 9];
        final double ny = mesh.vertices[o + 10];
        final double nz = mesh.vertices[o + 11];
        expect(nx * nx + ny * ny + nz * nz, closeTo(1.0, 1e-5));

        // Atlas rect must be a real, non-inverted sub-rectangle of the page.
        final double u0 = mesh.vertices[o + 12];
        final double v0 = mesh.vertices[o + 13];
        final double u1 = mesh.vertices[o + 14];
        final double v1 = mesh.vertices[o + 15];
        expect(u0, inInclusiveRange(0, 1));
        expect(v0, inInclusiveRange(0, 1));
        expect(u1, greaterThan(u0));
        expect(v1, greaterThan(v0));

        // Params: fullBright is a flag, uvMode is one of the two modes.
        expect(mesh.vertices[o + 16], anyOf(0.0, 1.0));
        expect(
          mesh.vertices[o + 18],
          anyOf(DoomVertexAbi.uvModeClamp, DoomVertexAbi.uvModeRepeat),
        );
        expect(mesh.vertices[o + 19], 0.0);
      }
    }
  });

  test('packed local UV is mapped through atlas rect exactly once', () {
    final MapBuilder b = MapBuilder('LOCALUV');
    final int s = b.sector();
    b.solidLoop(<int>[0, 0, 64, 0, 64, 64, 0, 64], s);
    final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
      b.build(),
      testTextures(),
    );
    final VertexRange range = level.floorPlanes.single.ranges.single;
    final Float32List vertices = level.meshes[range.meshIndex].vertices;
    var vertex = range.firstVertex;
    while (vertex < range.firstVertex + range.vertexCount &&
        vertices[vertex * DoomVertexAbi.floatsPerVertex +
                DoomVertexAbi.texCoordOffset]
            .abs() >
            1e-9) {
      vertex++;
    }
    expect(vertex, lessThan(range.firstVertex + range.vertexCount));
    final int o = vertex * DoomVertexAbi.floatsPerVertex;
    final double localU = vertices[o + DoomVertexAbi.texCoordOffset];
    final double left = vertices[o + DoomVertexAbi.atlasRectOffset];
    final double right = vertices[o + DoomVertexAbi.atlasRectOffset + 2];
    final double resolved =
        left + (right - left) * (localU - localU.floorToDouble());
    expect(localU, 0);
    expect(resolved, closeTo(left, 1e-9));
  });

  test('a sky ceiling is emitted full bright', () {
    final MapBuilder b = MapBuilder('SKY');
    final int s = b.sector(ceilingFlat: kSkyFlatName);
    b.solidLoop(<int>[0, 0, 256, 0, 256, 256, 0, 256], s);
    final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
      b.build(),
      testTextures(),
    );
    final PackedMesh sky = level.meshes.firstWhere(
      (PackedMesh m) => m.kind == SurfaceKind.sky,
    );
    expect(
      sky.vertices[16],
      1.0,
      reason: 'vanilla never darkens the sky with distance',
    );
  });

  test('floors face up and ceilings face down', () {
    final MapBuilder b = MapBuilder('NORMALS');
    final int s = b.sector();
    b.solidLoop(<int>[0, 0, 256, 0, 256, 256, 0, 256], s);
    final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
      b.build(),
      testTextures(),
    );

    final SectorPlaneRef floor = level.floorPlanes.single;
    final VertexRange fr = floor.ranges.single;
    expect(
      level.meshes[fr.meshIndex].vertices[fr.firstVertex *
              DoomVertexAbi.floatsPerVertex +
          10],
      1.0,
    );

    final SectorPlaneRef ceiling = level.ceilingPlanes.single;
    final VertexRange cr = ceiling.ranges.single;
    expect(
      level.meshes[cr.meshIndex].vertices[cr.firstVertex *
              DoomVertexAbi.floatsPerVertex +
          10],
      -1.0,
    );
  });

  test('world space is (mapX, height, -mapY)', () {
    // The Y negation preserves map winding when viewed from above. Without it
    // every floor would face away from the camera.
    expect(DoomVertexAbi.worldX(10), 10);
    expect(DoomVertexAbi.worldY(20), 20);
    expect(DoomVertexAbi.worldZ(30), -30);
  });
}
