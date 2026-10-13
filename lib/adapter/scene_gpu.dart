import 'dart:typed_data';

import 'package:flutter/painting.dart' show FilterQuality;
import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
// Caller-managed vertex and index buffers, partial buffer writes and the
// material face-culling enums are not in flutter_scene's public barrels in
// 0.24.3. This file and doom_scene_presenter.dart are the only users; the
// pin and the renderer probes guard a bump.
// ignore: implementation_imports
import 'package:flutter_scene/src/gpu/gpu.dart' as shim;

import 'doom_gpu.dart';
import 'vertex_abi.dart';

/// Loads flutter_scene and the palette shaders, then installs [SceneGpu].
///
/// Must complete before the first scene surface mounts.
Future<void> initializeDoomRenderer() async {
  await Scene.initializeStaticResources();
  final library = await gpu.loadShaderLibraryAsync(
    await gpu.resolveShaderBundleKey(SceneGpu.shaderBundle),
  );
  final vertex = library?[SceneGpu.vertexEntryPoint];
  final fragment = library?[SceneGpu.fragmentEntryPoint];
  if (vertex == null || fragment == null) {
    throw StateError(
      'The ${SceneGpu.shaderBundle} shader bundle is missing. hook/build.dart '
      'compiles it; rebuild the app.',
    );
  }
  SceneGpu(vertexShader: vertex, fragmentShader: fragment);
}

/// The production [DoomGpu]: flutter_scene's GPU layer, which is Flutter GPU
/// on native targets and a WebGL2 backend on the web.
final class SceneGpu extends DoomGpu {
  SceneGpu({required this.vertexShader, required this.fragmentShader});

  /// The bundle hook/build.dart compiles from shaders/.
  static const String shaderBundle = 'doom_palette';
  static const String vertexEntryPoint = 'DoomPaletteVertex';
  static const String fragmentEntryPoint = 'DoomPaletteFragment';

  final gpu.Shader vertexShader;
  final gpu.Shader fragmentShader;

  @override
  SceneSurfaceBuffer createSurfaceBuffer({
    required int vertexBytes,
    required int indexBytes,
  }) => SceneSurfaceBuffer._(
    vertexBytes,
    shim.gpuContext.createDeviceBuffer(
      shim.StorageMode.hostVisible,
      vertexBytes,
    ),
    shim.gpuContext.createDeviceBuffer(
      shim.StorageMode.hostVisible,
      indexBytes,
    ),
  );

  @override
  SceneTexture createTexture({required int width, required int height}) =>
      SceneTexture._(width, height);

  /// A palette material in its GPU form.
  ///
  /// Masked midtextures cull back faces: a two-sided line emits one face per
  /// side, and only the face toward the viewer may draw, as in the original
  /// renderer. Everything else keeps both faces, matching the geometry
  /// compiler's contract.
  ShaderMaterial createMaterial({required bool cullBackFaces}) =>
      ShaderMaterial(
        vertexShader: vertexShader,
        fragmentShader: fragmentShader,
        cullingMode: cullBackFaces
            ? shim.CullMode.backFace
            : shim.CullMode.none,
        windingOrder: shim.WindingOrder.counterClockwise,
        isOpaqueOverride: true,
      );

  /// A geometry reading [buffer] through [doomVertexLayout].
  UnskinnedGeometry createGeometry(
    SceneSurfaceBuffer buffer, {
    required int vertexCount,
    required int indexCount,
  }) => UnskinnedGeometry()
    ..setVertexLayout(doomVertexLayout)
    ..setVertices(
      shim.BufferView(
        buffer._vertices,
        offsetInBytes: 0,
        lengthInBytes: buffer._vertexBytes,
      ),
      vertexCount,
    )
    ..setIndices(
      shim.BufferView(
        buffer._indices,
        offsetInBytes: 0,
        lengthInBytes: indexCount * Uint16List.bytesPerElement,
      ),
      gpu.IndexType.int16,
    );
}

/// One surface's vertex and index storage on the GPU.
///
/// The combined record keeps the renderer's single-buffer addressing, while
/// the two regions live in separate GPU buffers: WebGL2 forbids one buffer
/// serving both vertex and index bindings.
final class SceneSurfaceBuffer implements DoomGpuBuffer {
  SceneSurfaceBuffer._(this._vertexBytes, this._vertices, this._indices);

  final int _vertexBytes;
  final shim.DeviceBuffer _vertices;
  final shim.DeviceBuffer _indices;

  @override
  void write(ByteData data, {int destinationOffsetInBytes = 0}) {
    final end = destinationOffsetInBytes + data.lengthInBytes;
    if (destinationOffsetInBytes < _vertexBytes) {
      if (end > _vertexBytes) {
        throw RangeError(
          'A write may not span the vertex and index regions '
          '($destinationOffsetInBytes..$end, split at $_vertexBytes)',
        );
      }
      _overwrite(_vertices, data, destinationOffsetInBytes);
    } else {
      _overwrite(_indices, data, destinationOffsetInBytes - _vertexBytes);
    }
  }

  static void _overwrite(shim.DeviceBuffer buffer, ByteData data, int offset) {
    if (!buffer.overwrite(data, destinationOffsetInBytes: offset)) {
      throw StateError(
        'GPU buffer write of ${data.lengthInBytes} bytes failed',
      );
    }
  }
}

/// An RGBA8 lookup texture: nearest filtering, clamp-to-edge, no mips, no
/// colour decode. Palette indices and coverage must reach the shader as
/// stored bytes.
final class SceneTexture implements DoomGpuTexture {
  SceneTexture._(this.width, this.height);

  final int width;
  final int height;
  Texture2D? _texture;

  @override
  DoomPixelFormat get format => DoomPixelFormat.rgba8888;

  /// The uploaded texture. Throws before [write].
  Texture2D get texture =>
      _texture ?? (throw StateError('Texture used before upload'));

  @override
  void write(ByteData data) {
    _texture = Texture2D.fromPixels(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      width,
      height,
      content: TextureContent.data,
      sampling: const TextureSampling(
        mipmaps: false,
        minFilter: gpu.MinMagFilter.nearest,
        magFilter: gpu.MinMagFilter.nearest,
        mipFilter: gpu.MipFilter.nearest,
        maxAnisotropy: 1,
        addressMode: gpu.SamplerAddressMode.clampToEdge,
      ),
    );
  }
}

/// Doompeller's 20-float vertex record, then flutter_scene's per-node
/// instance record (model matrix columns and instance colour).
///
/// Attribute names are the contract with shaders/doom_palette.vert; offsets
/// come from [DoomVertexAbi], and test/adapter/vertex_abi_test.dart checks
/// both.
const VertexLayoutDescriptor doomVertexLayout = VertexLayoutDescriptor(
  buffers: [
    VertexBufferDescriptor(
      strideInBytes: DoomVertexAbi.bytesPerVertex,
      attributes: [
        VertexAttributeDescriptor(
          name: 'position',
          format: gpu.VertexFormat.float32x3,
          offsetInBytes: DoomVertexAbi.positionOffset * 4,
        ),
        VertexAttributeDescriptor(
          name: 'tex_coord',
          format: gpu.VertexFormat.float32x2,
          offsetInBytes: DoomVertexAbi.texCoordOffset * 4,
        ),
        VertexAttributeDescriptor(
          name: 'color',
          format: gpu.VertexFormat.float32x4,
          offsetInBytes: DoomVertexAbi.colorOffset * 4,
        ),
        VertexAttributeDescriptor(
          name: 'normal',
          format: gpu.VertexFormat.float32x3,
          offsetInBytes: DoomVertexAbi.normalOffset * 4,
        ),
        VertexAttributeDescriptor(
          name: 'atlas_rect',
          format: gpu.VertexFormat.float32x4,
          offsetInBytes: DoomVertexAbi.atlasRectOffset * 4,
        ),
        VertexAttributeDescriptor(
          name: 'params',
          format: gpu.VertexFormat.float32x4,
          offsetInBytes: DoomVertexAbi.paramsOffset * 4,
        ),
      ],
    ),
    VertexBufferDescriptor(
      strideInBytes: 80,
      stepMode: gpu.VertexStepMode.instance,
      attributes: [
        VertexAttributeDescriptor(
          name: 'model_transform_0',
          format: gpu.VertexFormat.float32x4,
        ),
        VertexAttributeDescriptor(
          name: 'model_transform_1',
          format: gpu.VertexFormat.float32x4,
          offsetInBytes: 16,
        ),
        VertexAttributeDescriptor(
          name: 'model_transform_2',
          format: gpu.VertexFormat.float32x4,
          offsetInBytes: 32,
        ),
        VertexAttributeDescriptor(
          name: 'model_transform_3',
          format: gpu.VertexFormat.float32x4,
          offsetInBytes: 48,
        ),
        VertexAttributeDescriptor(
          name: 'instance_color',
          format: gpu.VertexFormat.float32x4,
          offsetInBytes: 64,
        ),
      ],
    ),
  ],
);

/// Scene settings under which flutter_scene's resolve pass is an exact sRGB
/// re-encode of the palette shader's output, with no effect on any pixel.
void configureDoomScene(Scene scene) {
  scene
    // The palette shader writes clip depth itself (sky, weapon, flash), in
    // the standard 0..w mapping.
    ..reversedDepth = false
    ..fitNearPlane = false
    ..coplanarTieBreak = false
    ..toneMapping = ToneMappingMode.linear
    ..exposure = 1
    ..antiAliasingMode = AntiAliasingMode.none
    ..renderScale = 1
    ..filterQuality = FilterQuality.none;
  scene.renderQuality.adaptive = false;
}
