import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';

/// The Flame 3D camera projection adapted to Doom's map coordinate range.
///
/// Doom map coordinates are signed 16-bit values. The greatest possible
/// distance between two points in that square is about 92,680 map units, so a
/// 100,000-unit far plane covers every legal map without an excessive margin.
/// A 1-unit near plane keeps the far/near ratio at 100,000 instead of the
/// 10,000,000 ratio that Flame 3D's 0.01 near plane would produce here. This is
/// important for depth precision, while remaining far inside Doom's 16-unit
/// player radius. Camera-locked weapon vertices use a clip-space depth layer
/// for world occlusion, but their physical quad remains beyond this near plane
/// because flame_3d AABB-culls objects before executing the vertex shader.
///
/// The sky shader pins sky vertices to NDC Z 0.999999. With these planes that
/// depth corresponds to about 95,238 view units, still beyond the maximum
/// legal map diagonal; ordinary map geometry therefore remains in front of
/// the sky. See `shaders/doom_palette.vert`.
final class DoomCameraComponent extends CameraComponent3D {
  DoomCameraComponent({
    super.fovY,
    super.position,
    super.rotation,
    super.target,
    super.up,
    super.projection,
    super.world,
    super.viewport,
    super.viewfinder,
    super.backdrop,
    super.hudComponents,
  });

  static const double distanceNear = 1;
  static const double distanceFar = 100000;

  @override
  Matrix4 get projectionMatrix => switch (projection) {
    CameraProjection.perspective =>
      _projectionMatrix..setAsPerspective(
        fovY,
        viewport.virtualSize.x / viewport.virtualSize.y,
        distanceNear,
        distanceFar,
      ),
    CameraProjection.orthographic =>
      _projectionMatrix..setAsOrthographic(
        fovY,
        viewport.virtualSize.x / viewport.virtualSize.y,
        distanceNear,
        distanceFar,
      ),
  };

  final Matrix4 _projectionMatrix = Matrix4.zero();
}
