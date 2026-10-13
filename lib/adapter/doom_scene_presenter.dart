import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart';

import 'doom_camera.dart';
import 'doom_gpu.dart';
import 'doom_scene.dart';
import 'packed_surface.dart';
import 'palette_material.dart';
import 'scene_gpu.dart';
import 'scene_object.dart';

/// Mirrors a [DoomScene] into a flutter_scene [Scene] once per frame.
///
/// The renderer core is plain data so it runs under tests without a GPU. This
/// is the only place that turns it into GPU objects: one node per mounted
/// object, one shader material per (palette material, culling) pair, and
/// geometries over the surfaces' own buffers. [sync] uploads only what
/// changed since the previous frame.
final class DoomScenePresenter {
  DoomScenePresenter() {
    configureDoomScene(scene);
  }

  /// The GPU scene the surface renders.
  final Scene scene = Scene();

  SceneGpu get _gpu => DoomGpu.instance as SceneGpu;

  DoomSceneRoot? _root;
  int _rootRevision = -1;
  final Map<DoomObject3D, _ObjectBinding> _objects = {};
  final Map<(PaletteMaterial, bool), _MaterialBinding> _materials = {};

  final Float32List _vertexInfo = Float32List(32);
  final Float32List _lastVertexInfo = Float32List(32);
  bool _vertexInfoValid = false;

  /// Objects that drew in the last [sync], before flutter_scene's own frustum
  /// culling.
  int get visibleObjectCount => _visibleObjects;
  int _visibleObjects = 0;

  /// Distinct GPU materials alive in [scene].
  int get materialCount => _materials.length;

  /// Brings [scene] in line with [doomScene] as seen from [camera].
  void sync(DoomScene doomScene, DoomCamera camera) {
    _reconcile(doomScene.root);

    _vertexInfo
      ..setAll(0, camera.viewMatrix.storage)
      ..setAll(16, camera.projectionMatrix.storage);
    final cameraChanged =
        !_vertexInfoValid || !sameFloats(_vertexInfo, _lastVertexInfo);
    if (cameraChanged) {
      _lastVertexInfo.setAll(0, _vertexInfo);
      _vertexInfoValid = true;
    }

    var visible = 0;
    for (final binding in _objects.values) {
      if (binding.sync(this)) visible++;
    }
    _visibleObjects = visible;

    for (final material in _materials.values) {
      material.sync(_vertexInfo, cameraChanged: cameraChanged);
    }
  }

  /// A flutter_scene camera matching [camera], used for engine-side frustum
  /// culling. Drawing uses [DoomCamera]'s own matrices, so only the frustum
  /// volume matters here, and a symmetric frustum is the same volume in
  /// either view-space handedness.
  Camera cullingCamera(DoomCamera camera) => PerspectiveCamera(
    fovRadiansY: camera.fovY * degrees2Radians,
    position: camera.position.clone(),
    target: camera.target.clone(),
    up: camera.up,
    fovNear: DoomCamera.distanceNear,
    fovFar: DoomCamera.distanceFar,
  );

  /// Releases every GPU object this presenter created.
  void dispose() {
    _objects.clear();
    _materials.clear();
    scene.removeAll();
    scene.dispose();
  }

  void _reconcile(DoomSceneRoot root) {
    if (identical(root, _root) && root.revision == _rootRevision) return;
    if (!identical(root, _root)) {
      _objects.clear();
      _materials.clear();
      scene.removeAll();
      _root = root;
    }
    _rootRevision = root.revision;
    final mounted = root.children;
    final keep = mounted.toSet();
    for (final object in _objects.keys.toList()) {
      if (!keep.contains(object)) {
        scene.remove(_objects.remove(object)!.node);
      }
    }
    for (final object in mounted) {
      if (_objects.containsKey(object)) continue;
      final binding = _ObjectBinding(object);
      _objects[object] = binding;
      scene.add(binding.node);
    }
  }

  _MaterialBinding _materialFor(PackedSurface surface) {
    final cull = surface.kind == DoomSurfaceKind.masked;
    return _materials.putIfAbsent(
      (surface.material, cull),
      () => _MaterialBinding(
        surface.material,
        _gpu.createMaterial(cullBackFaces: cull),
      ),
    );
  }

  static bool sameFloats(Float32List a, Float32List b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// One mounted object's node.
final class _ObjectBinding {
  _ObjectBinding(this.object)
    : node = Node()
        ..frustumCulled = object.frustumCulled
        ..shadowCastingMode = ShadowCastingMode.off
        ..visible = false;

  final DoomObject3D object;
  final Node node;
  final Matrix4 _transform = Matrix4.zero();
  final Matrix4 _lastTransform = Matrix4.zero();
  bool _hasTransform = false;
  final List<_SurfaceBinding> _surfaces = [];

  /// Returns whether the object draws this frame.
  bool sync(DoomScenePresenter presenter) {
    if (!object.visible) {
      node.visible = false;
      return false;
    }
    object.transformMatrix(_transform);
    if (!_hasTransform ||
        !DoomScenePresenter.sameFloats(
          _transform.storage,
          _lastTransform.storage,
        )) {
      _lastTransform.setFrom(_transform);
      _hasTransform = true;
      node.localTransform = _transform.clone();
    }

    final surfaces = object.mesh.surfaces;
    var meshChanged = surfaces.length != _surfaces.length;
    if (meshChanged) {
      _surfaces
        ..clear()
        ..addAll(surfaces.map(_SurfaceBinding.new));
    }
    for (final surface in _surfaces) {
      if (surface.sync(presenter)) meshChanged = true;
    }
    if (meshChanged) {
      node.mesh = Mesh.primitives(
        primitives: [
          for (final surface in _surfaces)
            MeshPrimitive(surface.geometry!, surface.material!.material),
        ],
      );
    }
    node.visible = true;
    return true;
  }
}

/// One surface's geometry and material binding.
final class _SurfaceBinding {
  _SurfaceBinding(this.surface);

  final PackedSurface surface;
  UnskinnedGeometry? geometry;
  _MaterialBinding? material;
  final Aabb3 _bounds = Aabb3();

  /// Uploads pending writes and returns whether the draw must be rebuilt.
  bool sync(DoomScenePresenter presenter) {
    // Reading the resource creates the GPU buffer once and flushes dirty
    // vertex ranges into it.
    final buffer = surface.resource as SceneSurfaceBuffer;
    var rebuilt = false;
    var current = geometry;
    if (current == null) {
      current = geometry = presenter._gpu.createGeometry(
        buffer,
        vertexCount: surface.vertexCount,
        indexCount: surface.indexCount,
      );
      rebuilt = true;
    }
    final aabb = surface.aabb;
    if (rebuilt || aabb.min != _bounds.min || aabb.max != _bounds.max) {
      _bounds.copyFrom(aabb);
      current.setLocalBounds(
        Aabb3.copy(aabb),
        Sphere.centerRadius(
          aabb.center,
          (aabb.max - aabb.min).length / 2,
        ),
      );
    }
    final wanted = presenter._materialFor(surface);
    if (!identical(wanted, material)) {
      material = wanted;
      rebuilt = true;
    }
    return rebuilt;
  }
}

/// A palette material's GPU form and its uniform upload state.
final class _MaterialBinding {
  _MaterialBinding(this.palette, this.material) {
    final textures = palette.textures;
    material
      ..setTexture('indexAtlas', _texture(textures.indexAtlas.resource))
      ..setTexture('colorMapLut', _texture(textures.colorMapLut.resource))
      ..setTexture('paletteLut', _texture(textures.paletteLut.resource));
  }

  final PaletteMaterial palette;
  final ShaderMaterial material;
  final Float32List _uniforms = Float32List(PaletteMaterial.uniformFloats);
  int _revision = -1;
  bool _hasVertexInfo = false;

  /// Uploads changed uniform blocks: the camera matrices when they moved or
  /// this material has none yet, and the palette block when it changed.
  void sync(Float32List vertexInfo, {required bool cameraChanged}) {
    if (cameraChanged || !_hasVertexInfo) {
      material.setUniformBlock(
        'VertexInfo',
        ByteData.sublistView(Float32List.fromList(vertexInfo)),
        stage: ShaderStage.vertex,
      );
      _hasVertexInfo = true;
    }
    if (palette.revision != _revision) {
      _revision = palette.revision;
      material.setUniformBlock(
        'DoomMaterial',
        ByteData.sublistView(
          Float32List.fromList(palette.writeUniforms(_uniforms)),
        ),
      );
    }
  }

  static Texture2D _texture(DoomGpuTexture texture) =>
      (texture as SceneTexture).texture;
}
