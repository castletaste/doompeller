/// Mutable renderer counters.
///
/// Every number here is a lifetime total of things Doompeller itself did. None
/// of them is a GPU measurement: flame_3d 0.3.0 exposes no per-resource
/// disposal and no live-resource counter, so [gpuBuffersCreated] is a count of
/// buffers this process asked for, not a count of buffers currently alive on
/// the GPU. A number that only ever grows is the honest thing to report.
final class RenderDiagnostics {
  /// Surfaces constructed.
  int surfacesCreated = 0;

  /// Triangles across all constructed surfaces.
  int triangles = 0;

  /// GPU buffers requested from the backend. Never decremented; see the class
  /// comment.
  int gpuBuffersCreated = 0;

  /// Bytes sent by initial buffer creation.
  int initialUploadBytes = 0;

  /// CPU-side dynamic mutations, whether or not they reached the GPU.
  int dynamicUpdates = 0;

  /// Partial re-uploads into an existing buffer.
  int dynamicUploads = 0;

  /// Bytes sent by partial re-uploads.
  int dynamicUploadBytes = 0;

  /// Meshes built by the scene.
  int meshesBuilt = 0;

  /// Components mounted by the scene.
  int componentsBuilt = 0;

  /// GPU textures created by the palette uploader.
  int texturesCreated = 0;

  void onSurfaceCreated({required int triangleCount}) {
    surfacesCreated++;
    triangles += triangleCount;
  }

  void onGpuBufferCreated({required int bytes}) {
    gpuBuffersCreated++;
    initialUploadBytes += bytes;
  }

  void onDynamicUpdate() => dynamicUpdates++;

  void onDynamicUpload({required int bytes}) {
    dynamicUploads++;
    dynamicUploadBytes += bytes;
  }

  void onMeshBuilt() => meshesBuilt++;

  void onComponentBuilt() => componentsBuilt++;

  void onTextureCreated() => texturesCreated++;

  /// Resets every counter. Used between levels and in tests.
  void reset() {
    surfacesCreated = 0;
    triangles = 0;
    gpuBuffersCreated = 0;
    initialUploadBytes = 0;
    dynamicUpdates = 0;
    dynamicUploads = 0;
    dynamicUploadBytes = 0;
    meshesBuilt = 0;
    componentsBuilt = 0;
    texturesCreated = 0;
  }

  /// An immutable copy for display or serialization.
  RenderDiagnosticsSnapshot snapshot() => RenderDiagnosticsSnapshot(
    surfacesCreated: surfacesCreated,
    triangles: triangles,
    gpuBuffersCreated: gpuBuffersCreated,
    initialUploadBytes: initialUploadBytes,
    dynamicUpdates: dynamicUpdates,
    dynamicUploads: dynamicUploads,
    dynamicUploadBytes: dynamicUploadBytes,
    meshesBuilt: meshesBuilt,
    componentsBuilt: componentsBuilt,
    texturesCreated: texturesCreated,
  );
}

/// An immutable [RenderDiagnostics] reading.
final class RenderDiagnosticsSnapshot {
  const RenderDiagnosticsSnapshot({
    required this.surfacesCreated,
    required this.triangles,
    required this.gpuBuffersCreated,
    required this.initialUploadBytes,
    required this.dynamicUpdates,
    required this.dynamicUploads,
    required this.dynamicUploadBytes,
    required this.meshesBuilt,
    required this.componentsBuilt,
    required this.texturesCreated,
  });

  final int surfacesCreated;
  final int triangles;
  final int gpuBuffersCreated;
  final int initialUploadBytes;
  final int dynamicUpdates;
  final int dynamicUploads;
  final int dynamicUploadBytes;
  final int meshesBuilt;
  final int componentsBuilt;
  final int texturesCreated;

  Map<String, int> toJson() => <String, int>{
    'surfacesCreated': surfacesCreated,
    'triangles': triangles,
    'gpuBuffersCreated': gpuBuffersCreated,
    'initialUploadBytes': initialUploadBytes,
    'dynamicUpdates': dynamicUpdates,
    'dynamicUploads': dynamicUploads,
    'dynamicUploadBytes': dynamicUploadBytes,
    'meshesBuilt': meshesBuilt,
    'componentsBuilt': componentsBuilt,
    'texturesCreated': texturesCreated,
  };

  @override
  String toString() =>
      'RenderDiagnosticsSnapshot(surfaces: $surfacesCreated, '
      'triangles: $triangles, buffersCreated: $gpuBuffersCreated, '
      'dynamicUploads: $dynamicUploads)';
}
