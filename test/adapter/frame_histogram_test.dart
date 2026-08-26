import 'package:doompeller/adapter/adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FrameHistogram', () {
    test('an empty window summarizes to zero, not to a crash', () {
      expect(FrameHistogram().summarize().count, 0);
      expect(FrameHistogram().summarize().deadlineMissRate, 0);
    });

    test('computes nearest-rank percentiles', () {
      final histogram = FrameHistogram();
      for (var i = 1; i <= 100; i++) {
        histogram.addSample(totalMicros: i * 100);
      }

      final summary = histogram.summarize();
      expect(summary.count, 100);
      // Nearest rank over 100 ascending samples: index ceil(99 * p).
      expect(summary.p50Micros, 5100);
      expect(summary.p95Micros, 9600);
      expect(summary.p99Micros, 10000);
      expect(summary.maxMicros, 10000);
      expect(summary.p50Millis, 5.1);
    });

    test('counts deadline misses and hitches at the documented thresholds', () {
      final histogram = FrameHistogram();
      histogram
        ..addSample(totalMicros: 16667)
        ..addSample(totalMicros: 16668)
        ..addSample(totalMicros: 50000)
        ..addSample(totalMicros: 50001);

      final summary = histogram.summarize();
      expect(
        summary.deadlineMisses,
        3,
        reason: 'exactly 16.667 ms met the deadline; anything above missed it',
      );
      expect(summary.hitches, 1);
      expect(summary.deadlineMissRate, 0.75);
    });

    test('evicting a sample also removes its miss and hitch', () {
      final histogram = FrameHistogram(capacity: 2);
      histogram
        ..addSample(totalMicros: 60000)
        ..addSample(totalMicros: 1000);
      expect(histogram.summarize().hitches, 1);
      expect(histogram.isSaturated, isTrue);

      histogram.addSample(totalMicros: 1000);
      final summary = histogram.summarize();
      expect(summary.count, 2);
      expect(
        summary.hitches,
        0,
        reason: 'a stale hitch must leave the window with its sample',
      );
      expect(summary.deadlineMisses, 0);
      expect(histogram.droppedByOverflow, 1);
    });

    test('summarizes build and raster time separately', () {
      final histogram = FrameHistogram();
      histogram
        ..addSample(totalMicros: 3000, buildMicros: 1000, rasterMicros: 2000)
        ..addSample(totalMicros: 5000, buildMicros: 3000, rasterMicros: 4000);

      final summary = histogram.summarize();
      expect(summary.meanBuildMicros, 2000);
      expect(summary.meanRasterMicros, 3000);
      expect(summary.p50BuildMicros, 3000);
      expect(summary.p95BuildMicros, 3000);
      expect(summary.p50RasterMicros, 4000);
      expect(summary.p95RasterMicros, 4000);
    });

    test('clear resets derived counters too', () {
      final histogram = FrameHistogram()..addSample(totalMicros: 90000);
      expect(histogram.summarize().hitches, 1);
      histogram.clear();
      expect(histogram.length, 0);
      expect(histogram.summarize().hitches, 0);
      expect(histogram.summarize().deadlineMisses, 0);
    });

    test('rejects a negative span', () {
      expect(
        () => FrameHistogram().addSample(totalMicros: -1),
        throwsArgumentError,
      );
    });

    test('names the metric honestly in its JSON', () {
      final json = (FrameHistogram()..addSample(totalMicros: 1000))
          .summarize()
          .toJson();
      expect(
        json['metric'],
        'flutter_frame_timing_total_span',
        reason: 'this is not a presented-frame or GPU measurement',
      );
      expect(json['p50_ms'], 1.0);
      expect(json['deadline_ms'], closeTo(16.667, 0.001));
      expect(json['build_duration'], isA<Map<String, Object>>());
      expect(json['raster_duration'], isA<Map<String, Object>>());
    });
  });

  group('RenderDiagnostics', () {
    test('accumulates each counter independently', () {
      final diagnostics = RenderDiagnostics()
        ..onSurfaceCreated(triangleCount: 12)
        ..onSurfaceCreated(triangleCount: 8)
        ..onGpuBufferCreated(bytes: 4096)
        ..onDynamicUpdate()
        ..onDynamicUpload(bytes: 160)
        ..onMeshBuilt()
        ..onComponentBuilt()
        ..onTextureCreated();

      final snapshot = diagnostics.snapshot();
      expect(snapshot.surfacesCreated, 2);
      expect(snapshot.triangles, 20);
      expect(snapshot.gpuBuffersCreated, 1);
      expect(snapshot.initialUploadBytes, 4096);
      expect(snapshot.dynamicUpdates, 1);
      expect(snapshot.dynamicUploads, 1);
      expect(snapshot.dynamicUploadBytes, 160);
      expect(snapshot.meshesBuilt, 1);
      expect(snapshot.componentsBuilt, 1);
      expect(snapshot.texturesCreated, 1);
    });

    test('a snapshot does not move with later counting', () {
      final diagnostics = RenderDiagnostics()
        ..onSurfaceCreated(triangleCount: 1);
      final snapshot = diagnostics.snapshot();
      diagnostics.onSurfaceCreated(triangleCount: 1);
      expect(snapshot.surfacesCreated, 1);
      expect(diagnostics.surfacesCreated, 2);
    });

    test('reset clears everything', () {
      final diagnostics = RenderDiagnostics()
        ..onSurfaceCreated(triangleCount: 4)
        ..onGpuBufferCreated(bytes: 64)
        ..reset();
      expect(
        diagnostics.snapshot().toJson().values.every((v) => v == 0),
        isTrue,
      );
    });

    test('exposes counters as JSON for a diagnostics overlay', () {
      final json = RenderDiagnostics().snapshot().toJson();
      expect(json.keys, contains('gpuBuffersCreated'));
      expect(json.keys, contains('dynamicUploadBytes'));
    });
  });
}
