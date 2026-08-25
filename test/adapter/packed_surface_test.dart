import 'dart:typed_data';

import 'package:doompeller/adapter/adapter.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_gpu_backend.dart';

void main() {
  late FakeGpuBackend backend;

  setUp(() => backend = FakeGpuBackend());

  PackedFlameSurface buildQuad({
    RenderDiagnostics? diagnostics,
    double y = 0,
  }) {
    final vertices = DoomVertexAbi.allocate(4);
    DoomVertexAbi.writeVertex(vertices, 0, x: 0, y: y, z: 0, u: 0, v: 0);
    DoomVertexAbi.writeVertex(vertices, 1, x: 8, y: y, z: 0, u: 1, v: 0);
    DoomVertexAbi.writeVertex(vertices, 2, x: 8, y: y, z: 8, u: 1, v: 1);
    DoomVertexAbi.writeVertex(vertices, 3, x: 0, y: y, z: 8, u: 0, v: 1);
    return PackedFlameSurface(
      vertices: vertices,
      indices: Uint16List.fromList(const [0, 1, 2, 0, 2, 3]),
      bounds: Aabb3.minMax(Vector3(0, y, 0), Vector3(8, y, 8)),
      material: Material.defaultMaterial,
      diagnostics: diagnostics,
    );
  }

  group('geometry math', () {
    test('reports counts and byte sizes from the packed buffers', () {
      final surface = buildQuad();
      expect(surface.vertexCount, 4);
      expect(surface.indexCount, 6);
      expect(surface.triangleCount, 2);
      expect(surface.verticesBytes, 4 * DoomVertexAbi.bytesPerVertex);
      expect(surface.indicesBytes, 6 * Uint16List.bytesPerElement);
    });

    test('materializes positions lazily and keeps them in sync', () {
      final surface = buildQuad();
      expect(surface.positions, hasLength(12));
      expect(surface.positions.sublist(3, 6), [8, 0, 0]);

      surface.setVertexHeights(const [0, 1, 2, 3], 64);
      expect(
        surface.positions.sublist(1, 2),
        [64],
        reason: 'an existing positions view must follow later writes',
      );
    });

    test('rejects malformed buffers and bounds', () {
      expect(
        () => PackedFlameSurface(
          vertices: Float32List(13),
          indices: Uint16List.fromList(const [0, 0, 0]),
          bounds: Aabb3(),
          material: Material.defaultMaterial,
        ),
        throwsArgumentError,
      );
      expect(
        () => PackedFlameSurface(
          vertices: DoomVertexAbi.allocate(3),
          indices: Uint16List.fromList(const [0, 1, 9]),
          bounds: Aabb3(),
          material: Material.defaultMaterial,
        ),
        throwsRangeError,
      );
      expect(
        () => PackedFlameSurface(
          vertices: DoomVertexAbi.allocate(3),
          indices: Uint16List.fromList(const [0, 1, 2]),
          bounds: Aabb3.minMax(Vector3.all(5), Vector3.all(1)),
          material: Material.defaultMaterial,
        ),
        throwsArgumentError,
      );
    });
  });

  group('dynamic uploads', () {
    test('a moving floor reuses one GPU buffer', () {
      final diagnostics = RenderDiagnostics();
      final surface = buildQuad(diagnostics: diagnostics);

      final buffer = surface.resource;
      expect(backend.buffers, hasLength(1));
      expect(diagnostics.gpuBuffersCreated, 1);

      for (var height = 1; height <= 20; height++) {
        surface.setVertexHeights(const [0, 1, 2, 3], height.toDouble());
        surface.resource;
      }

      expect(
        backend.buffers,
        hasLength(1),
        reason: 'flame_3d cannot free GPU buffers, so none may be orphaned',
      );
      expect(identical(surface.resource, buffer), isTrue);
      expect(diagnostics.gpuBuffersCreated, 1);
      expect(diagnostics.dynamicUploads, 20);
    });

    test('uploads only the touched vertex range', () {
      final surface = buildQuad();
      surface.resource;
      final fake = backend.buffers.single;
      final baseline = fake.writeCount;

      // Touch vertices 1 and 2 only.
      surface.setVertexHeights(const [1, 2], 32);
      surface.resource;

      expect(fake.writeCount, baseline + 1);
      final (offset, length) = fake.writeRanges.last;
      expect(offset, DoomVertexAbi.byteOffsetOf(1));
      expect(
        length,
        2 * DoomVertexAbi.bytesPerVertex,
        reason: 'only the dirty span may be re-uploaded',
      );
      expect(
        fake.floatAt(DoomVertexAbi.byteOffsetOf(1) + 4),
        32,
        reason: 'the new height must reach the buffer',
      );
    });

    test('coalesces many writes in a tic into one upload', () {
      final diagnostics = RenderDiagnostics();
      final surface = buildQuad(diagnostics: diagnostics);
      surface.resource;
      final fake = backend.buffers.single;
      final baseline = fake.writeCount;

      surface.setVertexHeights(const [0], 1);
      surface.setVertexHeights(const [3], 2);
      surface.setVertexHeights(const [1], 3);
      expect(surface.hasPendingUpload, isTrue);
      expect(fake.writeCount, baseline, reason: 'nothing uploads before a draw');

      surface.resource;
      expect(fake.writeCount, baseline + 1);
      expect(diagnostics.dynamicUpdates, 3);
      expect(diagnostics.dynamicUploads, 1);
    });

    test('an unchanged height costs nothing', () {
      final surface = buildQuad(y: 12);
      surface.resource;
      final fake = backend.buffers.single;
      final baseline = fake.writeCount;

      expect(surface.setVertexHeights(const [0, 1, 2, 3], 12), isFalse);
      expect(surface.hasPendingUpload, isFalse);
      surface.resource;
      expect(fake.writeCount, baseline);
    });

    test('updateVertices writes in place and updates bounds', () {
      final surface = buildQuad();
      surface.resource;
      final original = surface.packedVertices;

      surface.updateVertices(
        (vertices) {
          DoomVertexAbi.setV(vertices, 2, 0.5);
          surface.markVertexDirty(2);
        },
        bounds: Aabb3.minMax(Vector3(0, -4, 0), Vector3(8, 4, 8)),
      );

      expect(identical(surface.packedVertices, original), isTrue);
      expect(DoomVertexAbi.getV(surface.packedVertices, 2), 0.5);
      expect(surface.aabb.min.y, -4);
      expect(surface.aabb.max.y, 4);
    });

    test('rejects out-of-range vertex indices', () {
      final surface = buildQuad();
      expect(() => surface.markVertexDirty(4), throwsRangeError);
      expect(() => surface.setVertexHeights(const [9], 1), throwsRangeError);
      expect(
        () => surface.setVertexHeights(const [0], double.nan),
        throwsArgumentError,
      );
    });

    test('flushPendingUpload is a no-op before the first draw', () {
      final surface = buildQuad();
      surface.setVertexHeights(const [0], 5);
      expect(surface.hasGpuBuffer, isFalse);
      expect(surface.flushPendingUpload(), isFalse);

      // The pending change is folded into the initial upload instead.
      surface.resource;
      expect(
        backend.buffers.single.floatAt(4),
        5,
        reason: 'pre-draw edits must still reach the first upload',
      );
    });

    test('recomputeBounds scans the live buffer', () {
      final surface = buildQuad();
      surface.updateVertices((vertices) {
        DoomVertexAbi.setY(vertices, 2, 40);
        surface.markVertexDirty(2);
      });
      final bounds = surface.recomputeBounds();
      expect(bounds.max.y, 40);
      expect(bounds.max.x, 8);
    });
  });
}
