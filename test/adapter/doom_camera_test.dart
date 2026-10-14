import 'dart:io';
import 'dart:math' as math;

import 'package:doompeller/adapter/doom_camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

void main() {
  DoomCamera camera() =>
      DoomCamera(target: Vector3(0, 0, -1))..setViewportSize(800, 600);

  Frustum frustumOf(Matrix4 projection, Matrix4 view) =>
      Frustum.matrix(projection * view);

  test(
    'far geometry is culled by a stock 1000-unit far plane but visible to Doom',
    () {
      final doom = camera();
      // The 0.01 / 1000 planes a general-purpose 3D camera defaults to.
      final stock = frustumOf(
        makePerspectiveMatrix(60 * degrees2Radians, 800 / 600, 0.01, 1000),
        doom.viewMatrix,
      );
      final distantBox = Aabb3.minMax(
        Vector3(-16, -16, -3016),
        Vector3(16, 16, -2984),
      );

      expect(stock.intersectsWithAabb3(distantBox), isFalse);
      expect(
        frustumOf(
          doom.projectionMatrix,
          doom.viewMatrix,
        ).intersectsWithAabb3(distantBox),
        isTrue,
      );
    },
  );

  test('sky and weapon clip depths bracket every playable world depth', () {
    const double skyNdcDepth = 0.999999;
    // flutter_scene clips depth to 0..w on every backend with reversed depth
    // off. Keeping the weapon barely above zero puts it in front without
    // clipping the quad.
    const double weaponNdcDepth = 0.000001;
    const double flashNdcDepth = 0.0000005;
    final doom = camera();

    double ndcDepthAt(double viewDistance) {
      final clip = doom.projectionMatrix * Vector4(0, 0, -viewDistance, 1);
      return clip.z / clip.w;
    }

    final maxMapDiagonal = math.sqrt(2) * 65535;
    expect(weaponNdcDepth, inInclusiveRange(0.0, 1.0));
    expect(flashNdcDepth, greaterThan(0));
    expect(flashNdcDepth, lessThan(weaponNdcDepth));
    expect(ndcDepthAt(maxMapDiagonal), lessThan(skyNdcDepth));
    expect(ndcDepthAt(16), greaterThan(weaponNdcDepth));

    final shader = File('shaders/doom_palette.vert').readAsStringSync();
    expect(shader, contains('gl_Position.z = gl_Position.w * 0.999999;'));
    expect(shader, contains('gl_Position.z = gl_Position.w * 0.000001;'));
    expect(shader, contains('gl_Position.z = gl_Position.w * 0.0000005;'));
    expect(shader, isNot(contains('gl_Position.z = -gl_Position.w')));
  });

  test('palette shader uses dithered COLORMAP approximation for spectres', () {
    final shader = File('shaders/doom_palette.frag').readAsStringSync();
    expect(shader, contains('bool fuzz = abs(fragAlpha - 0.5) < 0.01;'));
    expect(shader, contains('gl_FragCoord'));
    expect(shader, contains('lightRow = max(lightRow'));
    expect(shader, contains('float alpha = fuzz ? 1.0'));
  });
}
