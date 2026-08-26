import 'dart:io';
import 'dart:math' as math;

import 'package:doompeller/adapter/doom_camera.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CameraComponent3D camera({required bool doomProjection}) {
    final viewport = FixedResolutionViewport(resolution: Vector2(800, 600));
    if (doomProjection) {
      return DoomCameraComponent(viewport: viewport, target: Vector3(0, 0, -1));
    }
    return CameraComponent3D(viewport: viewport, target: Vector3(0, 0, -1));
  }

  test('far geometry is culled by stock Flame 3D but visible to Doom', () {
    final stock = camera(doomProjection: false);
    final doom = camera(doomProjection: true);
    final distantBox = Aabb3.minMax(
      Vector3(-16, -16, -3016),
      Vector3(16, 16, -2984),
    );

    expect(stock.frustum.intersectsWithAabb3(distantBox), isFalse);
    expect(doom.frustum.intersectsWithAabb3(distantBox), isTrue);
  });

  test('sky and weapon clip depths bracket every playable world depth', () {
    const double skyNdcDepth = 0.999999;
    const double weaponNdcDepth = -0.999999;
    final doom = camera(doomProjection: true);

    double ndcDepthAt(double viewDistance) {
      final clip = doom.projectionMatrix * Vector4(0, 0, -viewDistance, 1);
      return clip.z / clip.w;
    }

    final maxMapDiagonal = math.sqrt(2) * 65535;
    expect(ndcDepthAt(maxMapDiagonal), lessThan(skyNdcDepth));
    expect(ndcDepthAt(16), greaterThan(weaponNdcDepth));

    final shader = File('shaders/doom_palette.vert').readAsStringSync();
    expect(shader, contains('gl_Position.z = gl_Position.w * 0.999999;'));
    expect(shader, contains('gl_Position.z = -gl_Position.w * 0.999999;'));
  });

  test('palette shader uses dithered COLORMAP approximation for spectres', () {
    final shader = File('shaders/doom_palette.frag').readAsStringSync();
    expect(shader, contains('bool fuzz = abs(fragAlpha - 0.5) < 0.01;'));
    expect(shader, contains('gl_FragCoord'));
    expect(shader, contains('lightRow = max(lightRow'));
    expect(shader, contains('float alpha = fuzz ? 1.0'));
  });
}
