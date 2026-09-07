import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Canvas;

import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:flame/game.dart' as flame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:vector_math/vector_math.dart';

import 'doom_sprite_atlas.dart';
import 'doom_sprite_catalog.dart';
import 'packed_surface.dart';
import 'palette_material.dart';
import 'vertex_abi.dart';

/// A mesh that translates with the camera but does not rotate with it.
///
/// The sky and the weapon both need this: the sky must stay infinitely far
/// away, and the weapon must stay glued to the view. Following the camera's
/// position while keeping world orientation gives the sky its parallax-free
/// look without a separate render pass, which matters because flame_3d applies
/// blend and depth state per pass, not per object.
class CameraLockedMeshComponent extends MeshComponent {
  CameraLockedMeshComponent({required super.mesh});

  void syncToCamera(CameraComponent3D camera) {
    position.setFrom(camera.position);
  }

  /// Always drawn: a camera-locked mesh surrounds the view, so frustum culling
  /// it is both wrong and wasted work.
  @override
  bool isVisible(CameraComponent3D camera) => true;
}

/// Camera-centred sky with world-fixed orientation.
///
/// Only translation follows the camera, so yaw and pitch move the view across
/// the texture. The cube is emitted far behind world geometry and uses normal
/// depth testing, so it fills clear pixels without overwriting nearer world
/// fragments.
final class SkyMeshComponent extends CameraLockedMeshComponent {
  SkyMeshComponent({required super.mesh});
}

/// Weapon geometry locked to the camera's actual look basis.
///
/// CameraComponent3D renders from position/target/up; its `rotation` field is
/// not authoritative. Deriving the quaternion from forward/right/up keeps the
/// weapon stable through yaw and pitch even when `target` changes directly.
class ViewLockedWeaponComponent extends CameraLockedMeshComponent {
  ViewLockedWeaponComponent({required super.mesh, this.weaponDistance = 2});

  final double weaponDistance;

  @override
  void syncToCamera(CameraComponent3D camera) {
    final forward = camera.forward.normalized();
    final right = forward.cross(camera.up)..normalize();
    final up = right.cross(forward)..normalize();
    final verticalScale =
        2 * weaponDistance * math.tan(camera.fovY * math.pi / 360);
    final aspectRatio = _cameraAspectRatio(camera);
    position.setFrom(camera.position + forward * weaponDistance);
    // Weapon vertices are normalized 320x200 psprite coordinates: one local
    // unit spans the full viewport on either axis. Place the physical quad
    // beyond DoomCamera's near plane for Flame's pre-render AABB cull, then
    // scale it to the view plane so its projected size remains unchanged.
    scale.setValues(verticalScale * aspectRatio, verticalScale, verticalScale);
    rotation.setFrom(
      Quaternion.fromRotation(Matrix3.columns(right, up, -forward))
        ..normalize(),
    );
  }
}

double _cameraAspectRatio(CameraComponent3D camera) {
  // The runtime performs an initial camera sync in its constructor, before
  // Flame has received its first layout. MaxViewport tries to read the parent
  // game's canvas size in that state, which is not available yet.
  final parent = camera.parent;
  if (parent is flame.FlameGame && !parent.hasLayout) {
    return 4 / 3;
  }
  final size = camera.viewport.virtualSize;
  if (!size.x.isFinite || !size.y.isFinite || size.x <= 0 || size.y <= 0) {
    return 4 / 3;
  }
  return size.x / size.y;
}

/// Upright actor sprite that rotates only around world Y.
class YawBillboardMeshComponent extends MeshComponent {
  YawBillboardMeshComponent({required super.mesh, super.position});

  void syncToCamera(CameraComponent3D camera) {
    final dx = camera.position.x - position.x;
    final dz = camera.position.z - position.z;
    if (dx == 0 && dz == 0) {
      return;
    }
    rotation.setFrom(
      Quaternion.axisAngle(Vector3(0, 1, 0), math.atan2(dx, dz)),
    );
  }
}

/// Actor billboard that also selects classic view rotations in-place.
final class ActorSpriteComponent extends YawBillboardMeshComponent {
  ActorSpriteComponent({
    required super.mesh,
    required super.position,
    required this.surface,
    required this.spriteAtlas,
    required this.materialsByPage,
    required this.spritePrefix,
    required this.frame,
    required this.actorAngle,
    required this.width,
    required this.height,
    required this.light,
    required this.fullBright,
    required this.fuzz,
    required this._lumpName,
    required this._mirrored,
  });

  final PackedFlameSurface surface;
  final DoomSpriteAtlas spriteAtlas;
  final Map<int, PaletteMaterial> materialsByPage;
  final String spritePrefix;
  double actorAngle;
  int frame;
  final double? width;
  final double? height;
  double light;
  bool fullBright;
  bool fuzz;

  String _lumpName;
  bool _mirrored;
  bool _active = true;

  String get lumpName => _lumpName;
  bool get mirrored => _mirrored;
  bool get active => _active;

  void deactivate() => _active = false;

  void reactivate(ActorSpriteInstance actor, DoomSpriteSelection selection) {
    _active = true;
    updateActor(
      x: actor.x,
      y: actor.y,
      z: actor.z,
      frame: actor.frame,
      actorAngle: actor.actorAngle,
      light: actor.light,
      fullBright: actor.fullBright,
      fuzz: actor.fuzz,
    );
    applySelection(selection);
  }

  /// Updates the stable retained actor component for a new simulation view.
  void updateActor({
    required double x,
    required double y,
    required double z,
    required int frame,
    required double actorAngle,
    required double light,
    required bool fullBright,
    bool fuzz = false,
  }) {
    position.setValues(x, y, z);
    this.frame = frame;
    this.actorAngle = actorAngle;
    if (this.light == light &&
        this.fullBright == fullBright &&
        this.fuzz == fuzz) {
      return;
    }
    this.light = light;
    this.fullBright = fullBright;
    this.fuzz = fuzz;
    surface.updateVertices((vertices) {
      for (var vertex = 0; vertex < 4; vertex++) {
        final offset = DoomVertexAbi.floatOffsetOf(vertex);
        vertices[offset + DoomVertexAbi.lightOffset] = light;
        vertices[offset + DoomVertexAbi.alphaOffset] = fuzz ? 0.5 : 1;
        vertices[offset + DoomVertexAbi.paramsOffset] = fullBright ? 1 : 0;
      }
      surface.markVertexRangeDirty(0, 4);
    });
  }

  void applySelection(DoomSpriteSelection selection) {
    if (selection.lumpName == _lumpName && selection.mirrored == _mirrored) {
      return;
    }
    final entry = spriteAtlas.atlas.entry(selection.lumpName)!;
    final quad = actorSpriteQuad(entry, width: width, height: height);
    surface.material = materialsByPage[entry.page]!;
    _setSpriteSelection(
      surface,
      entry,
      spriteAtlas.atlas.pageSize,
      mirrored: selection.mirrored,
      quad: quad,
    );
    surface.setBounds(quad.bounds);
    mesh.updateBounds();
    markAabbDirty();
    _lumpName = selection.lumpName;
    _mirrored = selection.mirrored;
  }

  @override
  void update(double dt) {
    if (!_active) {
      return;
    }
    super.update(dt);
  }

  @override
  void renderTree(Canvas canvas) {
    // flame_3d 0.3.0 bypasses isVisible() when an AABB is fully inside the
    // frustum. Retained pooled actors therefore need a gate before Object3D's
    // culling fast path or their last PUFF/BEXP frame remains in the draw list.
    if (!_active) {
      return;
    }
    super.renderTree(canvas);
  }

  @override
  bool isVisible(CameraComponent3D camera) =>
      _active && super.isVisible(camera);

  @override
  void syncToCamera(CameraComponent3D camera) {
    if (!_active) {
      return;
    }
    super.syncToCamera(camera);
    final rotation = DoomSpriteCatalog.cameraRotation(
      actorAngle: actorAngle,
      actorX: position.x,
      actorZ: position.z,
      cameraX: camera.position.x,
      cameraZ: camera.position.z,
    );
    final selection = spriteAtlas.catalog.resolve(
      prefix: spritePrefix,
      frame: frame,
      rotation: rotation,
    );
    if (selection == null) {
      _active = false;
      return;
    }
    applySelection(selection);
  }
}

/// View-locked weapon quad whose exact WAD frame can change in-place.
final class ViewLockedWeaponSpriteComponent extends ViewLockedWeaponComponent {
  ViewLockedWeaponSpriteComponent({
    required super.mesh,
    required this.surface,
    required this.spriteAtlas,
    required this.materialsByPage,
    required this._lumpName,
    required this.viewAnchorX,
    required this.viewAnchorY,
    required this.pixelScaleX,
    required this.pixelScaleY,
  });

  final PackedFlameSurface surface;
  final DoomSpriteAtlas spriteAtlas;
  final Map<int, PaletteMaterial> materialsByPage;
  String _lumpName;
  double viewAnchorX;
  double viewAnchorY;
  final double pixelScaleX;
  final double pixelScaleY;
  bool _visible = true;

  String get lumpName => _lumpName;
  bool get visible => _visible;

  void setVisible(bool value) => _visible = value;

  @override
  void renderTree(Canvas canvas) {
    // See ActorSpriteComponent.renderTree: isVisible() is not a reliable
    // dynamic visibility gate in the pinned flame_3d release.
    if (!_visible) {
      return;
    }
    super.renderTree(canvas);
  }

  @override
  bool isVisible(CameraComponent3D camera) =>
      _visible && super.isVisible(camera);

  bool setFrame(String lumpName, {double? viewAnchorX, double? viewAnchorY}) {
    final selection = spriteAtlas.catalog.exact(lumpName);
    if (selection == null) {
      throw StateError('Weapon sprite $lumpName is not packed');
    }
    final double nextX = viewAnchorX ?? this.viewAnchorX;
    final double nextY = viewAnchorY ?? this.viewAnchorY;
    if (selection.lumpName == _lumpName &&
        nextX == this.viewAnchorX &&
        nextY == this.viewAnchorY) {
      return false;
    }
    final entry = spriteAtlas.atlas.entry(selection.lumpName)!;
    final quad = weaponSpriteQuad(
      entry,
      viewAnchorX: nextX,
      viewAnchorY: nextY,
      pixelScaleX: pixelScaleX,
      pixelScaleY: pixelScaleY,
    );
    surface.material = materialsByPage[entry.page]!;
    _setSpriteSelection(
      surface,
      entry,
      spriteAtlas.atlas.pageSize,
      mirrored: false,
      quad: quad,
    );
    surface.setBounds(quad.bounds);
    mesh.updateBounds();
    markAabbDirty();
    _lumpName = selection.lumpName;
    this.viewAnchorX = nextX;
    this.viewAnchorY = nextY;
    return true;
  }
}

/// Plain-data actor placement consumed by the scene.
final class ActorSpriteInstance {
  const ActorSpriteInstance({
    required this.spritePrefix,
    required this.x,
    required this.y,
    required this.z,
    this.frame = 0,
    this.actorAngle = 0,
    this.width,
    this.height,
    this.light = 1,
    this.fullBright = false,
    this.fuzz = false,
  });

  final String spritePrefix;
  final int frame;
  final double actorAngle;
  final double x;
  final double y;
  final double z;
  final double? width;
  final double? height;
  final double light;
  final bool fullBright;
  final bool fuzz;
}

/// One exact first-person weapon frame in the supplemental sprite atlas.
final class WeaponSpriteInstance {
  const WeaponSpriteInstance({
    required this.lumpName,
    required this.viewAnchorX,
    required this.viewAnchorY,
    this.pixelScaleX = 1 / 320,
    this.pixelScaleY = 1 / 200,
    this.fullBright = false,
    this.depthLayer = -1,
  });

  final String lumpName;

  /// Camera-local pivot position corresponding to the patch origin.
  final double viewAnchorX;
  final double viewAnchorY;

  /// Camera-local units per source patch pixel.
  final double pixelScaleX;
  final double pixelScaleY;
  final bool fullBright;
  final double depthLayer;
}

Float32List buildSpriteVertices({
  required SpriteQuad quad,
  required geometry.AtlasEntry entry,
  required int pageSize,
  required double light,
  required bool fullBright,
  double alpha = 1,
  double depthLayer = 0,
}) {
  final vertices = DoomVertexAbi.allocate(4);
  final u0 = entry.u0(pageSize);
  final v0 = entry.v0(pageSize);
  final u1 = entry.u1(pageSize);
  final v1 = entry.v1(pageSize);
  void write(int index, double x, double y, double u, double v) {
    DoomVertexAbi.writeVertex(
      vertices,
      index,
      x: x,
      y: y,
      z: 0,
      u: u,
      v: v,
      nz: 1,
      light: light,
      alpha: alpha,
      atlasLeft: u0,
      atlasTop: v0,
      atlasRight: u1,
      atlasBottom: v1,
      uvMode: DoomVertexAbi.uvModeClamp,
      fullBright: fullBright,
      depthLayer: depthLayer,
    );
  }

  write(0, quad.left, quad.bottom, 0, 1);
  write(1, quad.right, quad.bottom, 1, 1);
  write(2, quad.right, quad.top, 1, 0);
  write(3, quad.left, quad.top, 0, 0);
  return vertices;
}

void _setSpriteSelection(
  PackedFlameSurface surface,
  geometry.AtlasEntry entry,
  int pageSize, {
  required bool mirrored,
  SpriteQuad? quad,
}) {
  final u0 = entry.u0(pageSize);
  final v0 = entry.v0(pageSize);
  final u1 = entry.u1(pageSize);
  final v1 = entry.v1(pageSize);
  surface.updateVertices((vertices) {
    if (quad != null) {
      _writeSpriteQuadPositions(vertices, quad);
    }
    for (var vertex = 0; vertex < 4; vertex++) {
      final offset = DoomVertexAbi.floatOffsetOf(vertex);
      vertices[offset + DoomVertexAbi.atlasRectOffset] = u0;
      vertices[offset + DoomVertexAbi.atlasRectOffset + 1] = v0;
      vertices[offset + DoomVertexAbi.atlasRectOffset + 2] = u1;
      vertices[offset + DoomVertexAbi.atlasRectOffset + 3] = v1;
    }
    final leftU = mirrored ? 1.0 : 0.0;
    final rightU = mirrored ? 0.0 : 1.0;
    vertices[DoomVertexAbi.texCoordOffset] = leftU;
    vertices[DoomVertexAbi.floatOffsetOf(1) + DoomVertexAbi.texCoordOffset] =
        rightU;
    vertices[DoomVertexAbi.floatOffsetOf(2) + DoomVertexAbi.texCoordOffset] =
        rightU;
    vertices[DoomVertexAbi.floatOffsetOf(3) + DoomVertexAbi.texCoordOffset] =
        leftU;
    surface.markVertexRangeDirty(0, 4);
  });
}

void _writeSpriteQuadPositions(Float32List vertices, SpriteQuad quad) {
  final points = <(double, double)>[
    (quad.left, quad.bottom),
    (quad.right, quad.bottom),
    (quad.right, quad.top),
    (quad.left, quad.top),
  ];
  for (var vertex = 0; vertex < 4; vertex++) {
    final offset = DoomVertexAbi.floatOffsetOf(vertex);
    vertices[offset] = points[vertex].$1;
    vertices[offset + 1] = points[vertex].$2;
  }
}

SpriteQuad actorSpriteQuad(
  geometry.AtlasEntry entry, {
  double? width,
  double? height,
}) {
  final scaleX = width == null ? 1.0 : width / entry.width;
  final scaleY = height == null ? 1.0 : height / entry.height;
  return SpriteQuad(
    left: -entry.leftOffset * scaleX,
    right: (entry.width - entry.leftOffset) * scaleX,
    bottom: (entry.topOffset - entry.height) * scaleY,
    top: entry.topOffset * scaleY,
  );
}

SpriteQuad weaponSpriteQuad(
  geometry.AtlasEntry entry, {
  required double viewAnchorX,
  required double viewAnchorY,
  required double pixelScaleX,
  required double pixelScaleY,
}) => SpriteQuad(
  left: viewAnchorX - entry.leftOffset * pixelScaleX,
  right: viewAnchorX + (entry.width - entry.leftOffset) * pixelScaleX,
  bottom: viewAnchorY + (entry.topOffset - entry.height) * pixelScaleY,
  top: viewAnchorY + entry.topOffset * pixelScaleY,
);

final class SpriteQuad {
  const SpriteQuad({
    required this.left,
    required this.right,
    required this.bottom,
    required this.top,
  });

  final double left;
  final double right;
  final double bottom;
  final double top;

  Aabb3 get bounds =>
      Aabb3.minMax(Vector3(left, bottom, 0), Vector3(right, top, 0));
}
