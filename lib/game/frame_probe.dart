import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import '../adapter/frame_histogram.dart';

/// Optional telemetry with the same lifetime as its runtime host.
final class DoomFrameProbe {
  DoomFrameProbe._() {
    SchedulerBinding.instance.addTimingsCallback(_record);
    _warmup = Timer(const Duration(seconds: 5), () {
      _histogram.clear();
      debugPrint('doompeller-web-frame: warmup complete');
    });
    _reporter = Timer.periodic(const Duration(seconds: 2), (_) => _report());
  }

  static DoomFrameProbe? startIfEnabled() =>
      const bool.fromEnvironment('DOOMPELLER_FRAME_PROBE')
      ? DoomFrameProbe._()
      : null;

  final FrameHistogram _histogram = FrameHistogram();
  late final Timer _warmup;
  late final Timer _reporter;
  void _record(List<FrameTiming> timings) => _histogram.addTimings(timings);

  void _report() {
    final summary = _histogram.summarize();
    if (summary.count == 0) return;
    debugPrint(
      'doompeller-web-frame: n=${summary.count} '
      'p50=${summary.p50Millis.toStringAsFixed(3)}ms '
      'p95=${summary.p95Millis.toStringAsFixed(3)}ms '
      'p99=${summary.p99Millis.toStringAsFixed(3)}ms '
      'build95=${(summary.p95BuildMicros / 1000).toStringAsFixed(3)}ms '
      'raster95=${(summary.p95RasterMicros / 1000).toStringAsFixed(3)}ms '
      'misses=${summary.deadlineMisses}',
    );
  }

  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_record);
    _warmup.cancel();
    _reporter.cancel();
  }
}
