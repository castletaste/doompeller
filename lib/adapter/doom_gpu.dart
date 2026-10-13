import 'dart:typed_data';

/// The narrow GPU surface the renderer core uploads through.
///
/// Surfaces and textures create their GPU objects lazily, on first use by the
/// presenter, through the single active [DoomGpu]. Production installs the
/// flutter_scene implementation in `initializeDoomRenderer`; tests install a
/// recording fake. Keeping this seam narrow is what lets every geometry,
/// animation and upload rule run under `flutter test`, which has no GPU.
///
/// Exactly one implementation is active at a time: constructing one makes it
/// [instance], the same registration flame_3d's backend used.
abstract base class DoomGpu {
  DoomGpu() {
    _instance = this;
  }

  static DoomGpu? _instance;

  /// The active implementation.
  static DoomGpu get instance =>
      _instance ??
      (throw StateError(
        'No DoomGpu is installed. Await initializeDoomRenderer() first.',
      ));

  /// Whether an implementation has been installed.
  static bool get isInstalled => _instance != null;

  /// Allocates the vertex and index storage of one packed surface.
  ///
  /// The buffer addresses vertices at byte 0 and indices immediately after
  /// them, the same single-record layout the renderer has always uploaded.
  /// An implementation may keep the two regions in separate GPU buffers; the
  /// web's WebGL2 forbids one buffer serving both vertex and index bindings.
  DoomGpuBuffer createSurfaceBuffer({
    required int vertexBytes,
    required int indexBytes,
  });

  /// Allocates an RGBA8 texture of [width] x [height].
  DoomGpuTexture createTexture({required int width, required int height});
}

/// Vertex-then-index storage for one surface.
abstract interface class DoomGpuBuffer {
  /// Copies [data] to [destinationOffsetInBytes] within the combined record.
  void write(ByteData data, {int destinationOffsetInBytes = 0});
}

/// An RGBA8 texture whose single upload carries the whole image.
abstract interface class DoomGpuTexture {
  /// The texture's pixel format. Every renderer texture is RGBA8.
  DoomPixelFormat get format;

  /// Uploads tightly packed RGBA8 rows covering the whole texture.
  void write(ByteData data);
}

/// Pixel formats the renderer uploads.
enum DoomPixelFormat {
  /// Eight bits per channel, unsigned normalized, no sRGB decode.
  rgba8888,
}

/// A value whose GPU object is created on first access and then reused.
///
/// Mirrors flame_3d's `Resource` so ownership stays obvious: the CPU-side
/// object always exists, the GPU side appears when something draws it.
abstract class DoomGpuResource<T> {
  T? _resource;

  /// Whether the GPU object exists yet.
  bool get hasResource => _resource != null;

  /// The GPU object, created through [DoomGpu.instance] on first access.
  T get resource => _resource ??= createResource();

  /// Builds the GPU object. Called at most once per resource.
  T createResource();
}
