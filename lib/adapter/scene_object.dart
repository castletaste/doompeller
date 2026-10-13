import 'dart:collection';

import 'package:vector_math/vector_math.dart';

import 'doom_camera.dart';
import 'packed_surface.dart';

/// The surfaces one object draws.
///
/// Every Doom object draws exactly one packed surface today, but the list form
/// keeps a merged level page and a sprite quad on the same path.
final class DoomMesh {
  DoomMesh([Iterable<PackedSurface> surfaces = const <PackedSurface>[]])
    : _surfaces = List<PackedSurface>.of(surfaces);

  final List<PackedSurface> _surfaces;

  /// A read-only view, read by the presenter every frame without copying.
  late final List<PackedSurface> surfaces = UnmodifiableListView(_surfaces);

  void addSurface(PackedSurface surface) => _surfaces.add(surface);
}

/// A positioned [DoomMesh]: the renderer's unit of placement and visibility.
///
/// This is plain data. The presenter mirrors it into the GPU scene each
/// frame, so geometry, sprite and camera rules run and test without a GPU.
/// The model matrix is translation x rotation x scale, the composition the
/// renderer has always used.
class DoomObject3D {
  DoomObject3D({required this.mesh, Vector3? position})
    : position = position?.clone() ?? Vector3.zero();

  final DoomMesh mesh;

  /// World translation. Mutated in place by billboard and camera locks.
  final Vector3 position;

  /// World orientation.
  final Quaternion rotation = Quaternion.identity();

  /// Local scale.
  final Vector3 scale = Vector3.all(1);

  /// Whether this object draws this frame.
  bool get visible => true;

  /// Whether the presenter may cull this object against the view frustum.
  ///
  /// Camera-locked meshes surround or face the eye, so culling them by their
  /// local bounds would be wrong as well as wasted.
  bool get frustumCulled => true;

  /// Aligns view-dependent placement with [camera]. Static geometry ignores
  /// it.
  void syncToCamera(DoomCamera camera) {}

  /// Writes this object's model matrix into [target] and returns it.
  Matrix4 transformMatrix([Matrix4? target]) =>
      (target ?? Matrix4.zero())
        ..setFromTranslationRotationScale(position, rotation, scale);
}

/// The level's object list, in mount order.
///
/// Mount order is draw-submission order for objects the GPU cannot otherwise
/// separate: sky first, weapon last, matching how Doom composites them.
final class DoomSceneRoot {
  final List<DoomObject3D> _children = <DoomObject3D>[];
  int _revision = 0;

  /// Every mounted object.
  List<DoomObject3D> get children => List.unmodifiable(_children);

  /// Changes whenever an object is mounted or unmounted, so the presenter can
  /// skip reconciling an unchanged tree.
  int get revision => _revision;

  void add(DoomObject3D object) {
    _children.add(object);
    _revision++;
  }

  bool remove(DoomObject3D object) {
    final removed = _children.remove(object);
    if (removed) _revision++;
    return removed;
  }
}
