import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:doompeller/adapter/adapter.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DoomVertexAbi pin', () {
    // THE TRIPWIRE.
    //
    // Doompeller writes flame_3d's interleaved vertex record by hand instead of
    // allocating Vertex objects. That is only safe while our layout and
    // flame_3d's agree exactly. If a flame_3d bump reorders, resizes or
    // reinterprets the record, this test fails and the renderer must be
    // re-verified before the pin moves.
    test('matches Vertex.storage float-for-float', () {
      final vertex = Vertex(
        position: Vector3(1.5, -2.25, 3.75),
        texCoord: Vector2(0.125, 0.875),
        color: const Color.fromARGB(255, 51, 102, 153),
        normal: Vector3(0, 1, 0),
        joints: Vector4(1, 2, 3, 4),
        weights: Vector4(0.1, 0.2, 0.3, 0.4),
      );

      final ours = DoomVertexAbi.allocate(1);
      DoomVertexAbi.writeFlameVertex(
        ours,
        0,
        x: 1.5,
        y: -2.25,
        z: 3.75,
        u: 0.125,
        v: 0.875,
        color: const Color.fromARGB(255, 51, 102, 153),
        nx: 0,
        ny: 1,
        nz: 0,
        joint0: 1,
        joint1: 2,
        joint2: 3,
        joint3: 4,
        weight0: 0.1,
        weight1: 0.2,
        weight2: 0.3,
        weight3: 0.4,
      );

      expect(
        vertex.storage.length,
        DoomVertexAbi.floatsPerVertex,
        reason: 'flame_3d changed its vertex float count',
      );
      expect(
        ours,
        orderedEquals(vertex.storage),
        reason: 'flame_3d changed its vertex field order or packing',
      );
    });

    test('matches the byte layout a Surface would upload', () {
      final vertex = Vertex(
        position: Vector3(4, 5, 6),
        texCoord: Vector2(0.25, 0.5),
        normal: Vector3(1, 0, 0),
      );
      final surface = Surface(
        vertices: [vertex],
        indices: const [0, 0, 0],
        calculateNormals: false,
      );

      expect(surface.verticesBytes, DoomVertexAbi.bytesPerVertex);
      expect(
        DoomVertexAbi.bytesPerVertex,
        80,
        reason: 'the vertex stride is baked into the compiled shader bundle',
      );
    });

    test('offsets address the documented fields', () {
      expect(DoomVertexAbi.positionOffset, 0);
      expect(DoomVertexAbi.texCoordOffset, 3);
      expect(DoomVertexAbi.colorOffset, 5);
      expect(DoomVertexAbi.normalOffset, 9);
      expect(DoomVertexAbi.jointsOffset, 12);
      expect(DoomVertexAbi.weightsOffset, 16);
      expect(DoomVertexAbi.atlasRectOffset, DoomVertexAbi.jointsOffset);
      expect(DoomVertexAbi.paramsOffset, DoomVertexAbi.weightsOffset);
    });
  });

  group('DoomVertexAbi writers', () {
    test('writeVertex fills every float of the record', () {
      final buffer = DoomVertexAbi.allocate(2);
      DoomVertexAbi.writeVertex(
        buffer,
        1,
        x: 10,
        y: 20,
        z: 30,
        u: 2.5,
        v: 0.5,
        nx: 0,
        ny: 0,
        nz: 1,
        light: 0.75,
        atlasLeft: 0.1,
        atlasTop: 0.2,
        atlasRight: 0.3,
        atlasBottom: 0.4,
        uvMode: DoomVertexAbi.uvModeClamp,
        fullBright: true,
      );

      final o = DoomVertexAbi.floatOffsetOf(1);
      expect(buffer.sublist(o, o + 5), [10, 20, 30, 2.5, 0.5]);
      expect(buffer[o + DoomVertexAbi.lightOffset], closeTo(0.75, 1e-6));
      expect(buffer[o + DoomVertexAbi.alphaOffset], 1);
      expect(buffer.sublist(o + 9, o + 12), [0, 0, 1]);
      expect(buffer.sublist(o + 12, o + 16).map((v) => (v * 10).round()), [
        1,
        2,
        3,
        4,
      ]);
      expect(buffer[o + 16], 1, reason: 'fullBright');
      expect(buffer[o + 18], DoomVertexAbi.uvModeClamp);

      // The untouched vertex 0 must stay zeroed.
      expect(
        buffer.sublist(0, DoomVertexAbi.floatsPerVertex).every((v) => v == 0),
        isTrue,
      );
    });

    test('setY, setV and setLight touch one float each', () {
      final buffer = DoomVertexAbi.allocate(1);
      DoomVertexAbi.writeVertex(buffer, 0, x: 1, y: 2, z: 3, u: 4, v: 5);

      DoomVertexAbi.setY(buffer, 0, 99);
      expect(DoomVertexAbi.getY(buffer, 0), 99);
      expect(buffer[0], 1, reason: 'x must not move');
      expect(buffer[2], 3, reason: 'z must not move');

      DoomVertexAbi.setV(buffer, 0, 0.25);
      expect(DoomVertexAbi.getV(buffer, 0), 0.25);
      expect(
        buffer[DoomVertexAbi.texCoordOffset],
        4,
        reason: 'u must not move',
      );

      DoomVertexAbi.setLight(buffer, 0, 0.5);
      expect(DoomVertexAbi.getLight(buffer, 0), 0.5);
      expect(
        buffer[DoomVertexAbi.alphaOffset],
        1,
        reason: 'alpha must not move',
      );
    });

    test('validation rejects partial records and stale indices', () {
      expect(
        () => DoomVertexAbi.validateVertexBuffer(Float32List(7)),
        throwsArgumentError,
      );
      expect(
        () => DoomVertexAbi.validateVertexBuffer(Float32List(0)),
        throwsArgumentError,
      );
      expect(
        () => DoomVertexAbi.validateIndexBuffer(
          Uint16List.fromList(const [0, 1, 5]),
          3,
        ),
        throwsRangeError,
      );
      expect(
        () => DoomVertexAbi.validateIndexBuffer(
          Uint16List.fromList(const [0, 1]),
          3,
        ),
        throwsArgumentError,
      );
    });

    test('pins the geometry producer boundary at 65535 vertices', () {
      final atLimit = DoomVertexAbi.allocate(65535);
      DoomVertexAbi.validateVertexBuffer(atLimit);
      expect(
        () => DoomVertexAbi.validateVertexBuffer(DoomVertexAbi.allocate(65536)),
        throwsRangeError,
      );
    });
  });
}
