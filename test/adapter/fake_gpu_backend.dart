import 'dart:typed_data';

import 'package:doompeller/adapter/adapter.dart';

/// A [DoomGpu] that records buffer traffic instead of touching a GPU.
///
/// Constructing it installs it as [DoomGpu.instance], exactly as production
/// installs the flutter_scene implementation.
final class FakeGpuBackend extends DoomGpu {
  final List<FakeGpuBuffer> buffers = [];
  final List<FakeGpuTexture> textures = [];

  @override
  FakeGpuBuffer createSurfaceBuffer({
    required int vertexBytes,
    required int indexBytes,
  }) {
    final buffer = FakeGpuBuffer(vertexBytes + indexBytes);
    buffers.add(buffer);
    return buffer;
  }

  @override
  FakeGpuTexture createTexture({required int width, required int height}) {
    final texture = FakeGpuTexture(width, height);
    textures.add(texture);
    return texture;
  }
}

/// Records every write so tests can assert upload counts and byte ranges.
final class FakeGpuBuffer implements DoomGpuBuffer {
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

final class FakeGpuTexture implements DoomGpuTexture {
  FakeGpuTexture(this.width, this.height);

  final int width;
  final int height;
  ByteData? written;

  @override
  DoomPixelFormat get format => DoomPixelFormat.rgba8888;

  @override
  void write(ByteData data) => written = data;
}
