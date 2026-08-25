import 'dart:typed_data';

import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:doompeller/adapter/adapter.dart' as adapter;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('geometry PackedMesh matches adapter ABI and shader UV convention', () {
    final geometry.MeshPacker packer = geometry.MeshPacker();
    packer.addPrimitive(
      page: 0,
      kind: geometry.SurfaceKind.opaque,
      positions: Float64List.fromList(<double>[
        1, 2, 3,
        4, 2, 3,
        1, 2, 6,
      ]),
      uvs: Float64List.fromList(<double>[0, 0.25, 1, 0.25, 0, 1]),
      indices: <int>[0, 1, 2],
      normalX: 0,
      normalY: 1,
      normalZ: 0,
      light: 0.5,
      atlasU0: 0.1875,
      atlasV0: 0.25,
      atlasU1: 0.21875,
      atlasV1: 0.5,
    );
    final geometry.PackedMesh mesh = packer.finish().single;

    expect(geometry.DoomVertexAbi.floatsPerVertex,
        adapter.DoomVertexAbi.floatsPerVertex);
    expect(geometry.DoomVertexAbi.positionOffset,
        adapter.DoomVertexAbi.positionOffset);
    expect(geometry.DoomVertexAbi.texCoordOffset,
        adapter.DoomVertexAbi.texCoordOffset);
    expect(geometry.DoomVertexAbi.colorOffset,
        adapter.DoomVertexAbi.colorOffset);
    expect(geometry.DoomVertexAbi.normalOffset,
        adapter.DoomVertexAbi.normalOffset);
    expect(geometry.DoomVertexAbi.atlasRectOffset,
        adapter.DoomVertexAbi.atlasRectOffset);
    expect(geometry.DoomVertexAbi.paramsOffset,
        adapter.DoomVertexAbi.paramsOffset);

    expect(
      mesh.vertices.sublist(0, 20),
      <double>[
        1, 2, 3,
        0, 0.25,
        0.5, 1, 1, 1,
        0, 1, 0,
        0.1875, 0.25, 0.21875, 0.5,
        0, -1, geometry.DoomVertexAbi.uvModeRepeat, 0,
      ],
    );

    // CPU oracle for the shader's mix(atlasMin, atlasMax, fract(localUv)).
    final double localU = mesh.vertices[geometry.DoomVertexAbi.texCoordOffset];
    final int rect = geometry.DoomVertexAbi.atlasRectOffset;
    final double resolvedU = mesh.vertices[rect] +
        (mesh.vertices[rect + 2] - mesh.vertices[rect]) *
            (localU - localU.floorToDouble());
    expect(resolvedU, 0.1875);
    expect(resolvedU, isNot(0.193359375));
  });
}
