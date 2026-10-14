import 'dart:math' as math;

import 'package:vector_math/vector_math.dart';

/// The first-person view: a look-at camera with Doom's depth range.
///
/// Doom map coordinates are signed 16-bit values. The greatest possible
/// distance between two points in that square is about 92,680 map units, so a
/// 100,000-unit far plane covers every legal map without an excessive margin.
/// A 1-unit near plane keeps the far/near ratio at 100,000, which matters for
/// depth precision, while remaining far inside Doom's 16-unit player radius.
/// Camera-locked weapon vertices use a clip-space depth layer for world
/// occlusion, but their physical quad stays beyond the near plane so
/// bounds-based culling never drops it.
///
/// The sky shader pins sky vertices to clip depth 0.999999. With these planes
/// that depth corresponds to about 95,238 view units, still beyond the maximum
/// legal map diagonal; ordinary map geometry therefore remains in front of the
/// sky. See `shaders/doom_palette.vert`.
///
/// The view and projection use vector_math's right-handed look-at and
/// perspective helpers, the matrices this renderer has always drawn with.
/// They are handed to the palette shader directly, so the image does not
/// depend on any engine camera convention.
final class DoomCamera {
  DoomCamera({
    Vector3? position,
    Vector3? target,
    Vector3? up,
    this.fovY = defaultFovY,
  }) : position = position?.clone() ?? Vector3.zero(),
       target = target?.clone() ?? Vector3(0, 0, -1),
       _up = up?.clone() ?? Vector3(0, 1, 0);

  /// Vertical field of view in degrees.
  static const double defaultFovY = 60;

  static const double distanceNear = 1;
  static const double distanceFar = 100000;

  /// Aspect ratio used before the first layout reports a viewport.
  static const double initialAspectRatio = 4 / 3;

  /// Vertical field of view in degrees.
  double fovY;

  /// Eye position in world space.
  final Vector3 position;

  /// Look-at point in world space.
  final Vector3 target;

  final Vector3 _up;

  /// Normalized up hint.
  Vector3 get up => _up.normalized();
  set up(Vector3 value) => _up.setFrom(value);

  /// Unnormalized view direction.
  Vector3 get forward => target - position;

  /// Screen-right in world space for the right-handed view.
  Vector3 get right => forward.cross(up);

  double _aspectRatio = initialAspectRatio;

  /// Width over height of the viewport in logical pixels.
  double get aspectRatio => _aspectRatio;

  /// Records the laid-out viewport. Non-finite or empty sizes keep the
  /// previous ratio, so an unmounted view cannot produce a degenerate matrix.
  void setViewportSize(double width, double height) {
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return;
    }
    _aspectRatio = width / height;
  }

  /// World to view.
  Matrix4 get viewMatrix =>
      _viewMatrix..setFrom(makeViewMatrix(position, target, up));
  final Matrix4 _viewMatrix = Matrix4.zero();

  /// View to clip.
  Matrix4 get projectionMatrix => _projectionMatrix
    ..setFrom(
      makePerspectiveMatrix(
        fovY * degrees2Radians,
        _aspectRatio,
        distanceNear,
        distanceFar,
      ),
    );
  final Matrix4 _projectionMatrix = Matrix4.zero();

  /// Height of the view plane [distance] units ahead of the eye.
  double viewHeightAt(double distance) =>
      2 * distance * math.tan(fovY * math.pi / 360);
}
