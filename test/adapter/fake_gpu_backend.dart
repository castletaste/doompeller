import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/graphics.dart';

/// A GPU backend that records buffer traffic instead of touching a GPU.
///
/// Only the entry points the adapter actually uses are implemented; anything
/// else throws so an accidental new dependency on real GPU state is loud.
final class FakeGpuBackend extends GpuBackend {
  final List<FakeGpuBuffer> buffers = [];
  final List<FakeGpuTexture> textures = [];

  @override
  GpuBuffer createBuffer({
    required GpuStorageMode storageMode,
    required int sizeInBytes,
  }) {
    final buffer = FakeGpuBuffer(sizeInBytes);
    buffers.add(buffer);
    return buffer;
  }

  @override
  GpuTexture createTexture({
    required GpuStorageMode storageMode,
    required int width,
    required int height,
    required GpuPixelFormat format,
  }) {
    final texture = FakeGpuTexture(width, height, format);
    textures.add(texture);
    return texture;
  }

  @override
  GpuPipeline createPipeline({
    required GpuShader vertexShader,
    required GpuShader fragmentShader,
  }) => throw UnimplementedError('pipelines need a real GPU');

  @override
  GpuRenderTarget createRenderTarget({
    required int width,
    required int height,
    required Color clearValue,
  }) => throw UnimplementedError('render targets need a real GPU');

  @override
  GpuFrame beginFrame() => throw UnimplementedError('frames need a real GPU');

  @override
  GpuShaderLibrary loadShaderLibrary(String assetName) =>
      throw UnimplementedError('shader libraries need a real GPU');
}

/// Records every write so tests can assert upload counts and byte ranges.
final class FakeGpuBuffer implements GpuBuffer {
  FakeGpuBuffer(this.sizeInBytes) : bytes = Uint8List(sizeInBytes);

  final int sizeInBytes;
  final Uint8List bytes;
  final List<(int, int)> writeRanges = [];

  int get writeCount => writeRanges.length;

  /// Bytes written after the initial vertex and index uploads.
  int get dynamicBytes =>
      writeRanges.skip(2).fold(0, (sum, range) => sum + range.$2);

  @override
  void write(ByteData data, {int destinationOffsetInBytes = 0}) {
    final source = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    bytes.setRange(
      destinationOffsetInBytes,
      destinationOffsetInBytes + source.length,
      source,
    );
    writeRanges.add((destinationOffsetInBytes, source.length));
  }

  /// Reads back a float from the recorded buffer contents.
  double floatAt(int byteOffset) =>
      bytes.buffer.asByteData().getFloat32(byteOffset, Endian.little);
}

final class FakeGpuTexture implements GpuTexture {
  FakeGpuTexture(this.width, this.height, this.format);

  final int width;
  final int height;
  final GpuPixelFormat format;
  ByteData? written;

  @override
  void write(ByteData data) => written = data;

  @override
  Never asImage() => throw UnimplementedError('images need a real GPU');
}
