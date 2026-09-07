import 'dart:typed_data';

import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:flame_3d/resources.dart';
import 'package:vector_math/vector_math.dart';

import 'packed_surface.dart';
import 'render_diagnostics.dart';
import 'vertex_abi.dart';

PackedFlameSurface buildSkySurface({
  required geometry.AtlasEntry entry,
  required int pageSize,
  required Material material,
  required RenderDiagnostics diagnostics,
}) {
  const extent = 500.0;
  final vertices = DoomVertexAbi.allocate(24);
  final indices = Uint16List(36);
  final u0 = entry.u0(pageSize);
  final v0 = entry.v0(pageSize);
  final u1 = entry.u1(pageSize);
  final v1 = entry.v1(pageSize);
  var vertexCursor = 0;
  var indexCursor = 0;

  void face(
    List<(double, double, double)> corners,
    (double, double, double) normal,
    double localU0,
    double localU1,
  ) {
    final localUvs = <(double, double)>[
      (localU0, 1),
      (localU1, 1),
      (localU1, 0),
      (localU0, 0),
    ];
    for (var i = 0; i < 4; i++) {
      final point = corners[i];
      final uv = localUvs[i];
      DoomVertexAbi.writeVertex(
        vertices,
        vertexCursor + i,
        x: point.$1,
        y: point.$2,
        z: point.$3,
        u: uv.$1,
        v: uv.$2,
        nx: normal.$1,
        ny: normal.$2,
        nz: normal.$3,
        atlasLeft: u0,
        atlasTop: v0,
        atlasRight: u1,
        atlasBottom: v1,
        // The four vertical faces consume one continuous panorama. Clamp is
        // essential: repeat would turn U=1 into U=0 and add another seam.
        // Top/bottom use the stable full-width mapping documented below.
        uvMode: DoomVertexAbi.uvModeClamp,
        fullBright: true,
        depthLayer: 1,
      );
    }
    indices.setRange(indexCursor, indexCursor + 6, <int>[
      vertexCursor,
      vertexCursor + 1,
      vertexCursor + 2,
      vertexCursor,
      vertexCursor + 2,
      vertexCursor + 3,
    ]);
    vertexCursor += 4;
    indexCursor += 6;
  }

  face(
    const [
      (-extent, -extent, -extent),
      (extent, -extent, -extent),
      (extent, extent, -extent),
      (-extent, extent, -extent),
    ],
    (0, 0, 1),
    0,
    0.25,
  );
  face(
    const [
      (extent, -extent, extent),
      (-extent, -extent, extent),
      (-extent, extent, extent),
      (extent, extent, extent),
    ],
    (0, 0, -1),
    0.5,
    0.75,
  );
  face(
    const [
      (-extent, -extent, extent),
      (-extent, -extent, -extent),
      (-extent, extent, -extent),
      (-extent, extent, extent),
    ],
    (1, 0, 0),
    0.75,
    1,
  );
  face(
    const [
      (extent, -extent, -extent),
      (extent, -extent, extent),
      (extent, extent, extent),
      (extent, extent, -extent),
    ],
    (-1, 0, 0),
    0.25,
    0.5,
  );
  face(
    const [
      (-extent, extent, -extent),
      (extent, extent, -extent),
      (extent, extent, extent),
      (-extent, extent, extent),
    ],
    (0, -1, 0),
    0,
    1,
  );
  face(
    const [
      (-extent, -extent, extent),
      (extent, -extent, extent),
      (extent, -extent, -extent),
      (-extent, -extent, -extent),
    ],
    (0, 1, 0),
    0,
    1,
  );

  return PackedFlameSurface(
    vertices: vertices,
    indices: indices,
    bounds: Aabb3.minMax(Vector3.all(-extent), Vector3.all(extent)),
    material: material,
    kind: DoomSurfaceKind.sky,
    diagnostics: diagnostics,
    debugLabel: 'sky:${entry.name}',
  );
}
