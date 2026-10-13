import 'dart:io';
import 'dart:typed_data';

import 'package:doompeller/adapter/adapter.dart';
import 'package:doompeller/adapter/scene_gpu.dart';
import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DoomVertexAbi pin', () {
    // THE TRIPWIRE.
    //
    // Geometry producers write the vertex record by hand, the GPU reads it
    // through doomVertexLayout, and the palette vertex shader names each
    // attribute. All three must agree float for float. If any side changes,
    // this fails and the renderer must be re-verified.
    const Map<String, (int, int, String)> fields = {
      // name: (float offset, components, GLSL type)
      'position': (DoomVertexAbi.positionOffset, 3, 'vec3'),
      'tex_coord': (DoomVertexAbi.texCoordOffset, 2, 'vec2'),
      'color': (DoomVertexAbi.colorOffset, 4, 'vec4'),
      'normal': (DoomVertexAbi.normalOffset, 3, 'vec3'),
      'atlas_rect': (DoomVertexAbi.atlasRectOffset, 4, 'vec4'),
      'params': (DoomVertexAbi.paramsOffset, 4, 'vec4'),
    };

    test('the record is 20 contiguous floats with documented offsets', () {
      expect(DoomVertexAbi.floatsPerVertex, 20);
      expect(DoomVertexAbi.bytesPerVertex, 80);
      expect(DoomVertexAbi.positionOffset, 0);
      expect(DoomVertexAbi.texCoordOffset, 3);
      expect(DoomVertexAbi.colorOffset, 5);
      expect(DoomVertexAbi.normalOffset, 9);
      expect(DoomVertexAbi.atlasRectOffset, 12);
      expect(DoomVertexAbi.paramsOffset, 16);
      var next = 0;
      for (final (offset, components, _) in fields.values) {
        expect(offset, next, reason: 'fields must tile the record');
        next += components;
      }
      expect(next, DoomVertexAbi.floatsPerVertex);
    });

    test('the GPU layout reads every field at its ABI offset', () {
      final buffers = doomVertexLayout.buffers;
      expect(buffers, hasLength(2));
      final vertex = buffers.first;
      expect(vertex.strideInBytes, DoomVertexAbi.bytesPerVertex);
      expect(vertex.stepMode, gpu.VertexStepMode.vertex);
      expect(vertex.attributes.map((a) => a.name), fields.keys);
      for (final attribute in vertex.attributes) {
        final (offset, components, _) = fields[attribute.name]!;
        expect(attribute.offsetInBytes, offset * 4, reason: attribute.name);
        expect(
          attribute.format.bytesPerElement,
          components * 4,
          reason: attribute.name,
        );
      }

      // flutter_scene's per-node instance record: model columns and colour.
      final instance = buffers.last;
      expect(instance.stepMode, gpu.VertexStepMode.instance);
      expect(instance.strideInBytes, 80);
      expect(instance.attributes.map((a) => a.name), const [
        'model_transform_0',
        'model_transform_1',
        'model_transform_2',
        'model_transform_3',
        'instance_color',
      ]);
    });

    test('the vertex shader declares the same attributes in order', () {
      final shader = File('shaders/doom_palette.vert').readAsStringSync();
      final declared = RegExp(r'^in (vec[234]) (\w+);', multiLine: true)
          .allMatches(shader)
          .map((m) => (m.group(2)!, m.group(1)!))
          .toList();
      expect(declared, [
        for (final MapEntry(:key, :value) in fields.entries) (key, value.$3),
        ('model_transform_0', 'vec4'),
        ('model_transform_1', 'vec4'),
        ('model_transform_2', 'vec4'),
        ('model_transform_3', 'vec4'),
        ('instance_color', 'vec4'),
      ]);
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
