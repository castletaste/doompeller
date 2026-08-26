import 'dart:typed_data';
import 'dart:ui' show FrameTiming;

/// Rolling distribution of recent frame times.
///
/// ## What this actually measures
///
/// Every sample is Flutter's [FrameTiming.totalSpan]: the wall time from the
/// vsync that started a frame to the moment the raster thread finished it. That
/// is not the same as a presented frame and not the same as GPU time.
/// Specifically, this histogram does NOT measure:
///
/// - presented frames (a frame counted here may never reach the display),
/// - Metal GPU timestamps or any driver-side duration,
/// - frames the engine dropped before ever building them.
///
/// It is still the right signal for Doompeller, because it captures the work
/// the simulation and renderer put on Flutter's threads, which is the part this
/// project controls. Any claim stronger than that needs a real GPU capture.
final class FrameHistogram {
  FrameHistogram({
    this.capacity = 36000,
    this.deadlineMicros = 16667,
    this.hitchMicros = 50000,
  }) : assert(capacity > 0, 'capacity must be positive'),
       assert(deadlineMicros > 0, 'deadline must be positive'),
       assert(
         hitchMicros >= deadlineMicros,
         'a hitch cannot be shorter than a missed deadline',
       ),
       _totals = Int32List(capacity),
       _builds = Int32List(capacity),
       _rasters = Int32List(capacity);

  /// Samples retained before the oldest is overwritten. 36000 is ten minutes
  /// at 60 Hz.
  final int capacity;

  /// One 60 Hz frame, in microseconds. Spans above this missed the deadline.
  final int deadlineMicros;

  /// Spans above this are user-visible stalls rather than ordinary jitter.
  final int hitchMicros;

  /// Preallocated rings. Using [Int32List] keeps a ten-minute window at about
  /// 432 KB total and adds zero GC pressure while sampling.
  final Int32List _totals;
  final Int32List _builds;
  final Int32List _rasters;

  int _writeIndex = 0;
  int _length = 0;
  int _deadlineMisses = 0;
  int _hitches = 0;
  int _droppedByOverflow = 0;

  /// Samples currently retained.
  int get length => _length;

  /// Whether the ring has wrapped and is discarding old samples.
  bool get isSaturated => _length == capacity;

  /// Samples pushed out of the window by newer ones.
  int get droppedByOverflow => _droppedByOverflow;

  /// Records one frame.
  void addSample({
    required int totalMicros,
    int buildMicros = 0,
    int rasterMicros = 0,
  }) {
    if (totalMicros < 0) {
      throw ArgumentError.value(
        totalMicros,
        'totalMicros',
        'must not be negative',
      );
    }
    if (_length == capacity) {
      final evicted = _totals[_writeIndex];
      if (evicted > deadlineMicros) {
        _deadlineMisses--;
      }
      if (evicted > hitchMicros) {
        _hitches--;
      }
      _droppedByOverflow++;
    } else {
      _length++;
    }

    _totals[_writeIndex] = totalMicros;
    _builds[_writeIndex] = buildMicros;
    _rasters[_writeIndex] = rasterMicros;
    _writeIndex = (_writeIndex + 1) % capacity;

    if (totalMicros > deadlineMicros) {
      _deadlineMisses++;
    }
    if (totalMicros > hitchMicros) {
      _hitches++;
    }
  }

  /// Records a batch delivered by [SchedulerBinding.addTimingsCallback].
  void addTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      addSample(
        totalMicros: timing.totalSpan.inMicroseconds,
        buildMicros: timing.buildDuration.inMicroseconds,
        rasterMicros: timing.rasterDuration.inMicroseconds,
      );
    }
  }

  /// Discards every sample.
  void clear() {
    _writeIndex = 0;
    _length = 0;
    _deadlineMisses = 0;
    _hitches = 0;
    _droppedByOverflow = 0;
  }

  /// Summarizes the current window.
  ///
  /// Costs a sort of the retained samples, so call it on a timer or on demand
  /// rather than every frame.
  FrameSummary summarize() {
    if (_length == 0) {
      return FrameSummary.empty;
    }
    final totals = Int32List(_length);
    final builds = Int32List(_length);
    final rasters = Int32List(_length);
    totals.setRange(0, _length, _totals);
    builds.setRange(0, _length, _builds);
    rasters.setRange(0, _length, _rasters);
    _sort(totals);
    _sort(builds);
    _sort(rasters);

    var buildSum = 0;
    var rasterSum = 0;
    for (var i = 0; i < _length; i++) {
      buildSum += _builds[i];
      rasterSum += _rasters[i];
    }

    return FrameSummary(
      count: _length,
      p50Micros: _percentile(totals, 0.50),
      p95Micros: _percentile(totals, 0.95),
      p99Micros: _percentile(totals, 0.99),
      maxMicros: totals[_length - 1],
      p50BuildMicros: _percentile(builds, 0.50),
      p95BuildMicros: _percentile(builds, 0.95),
      p99BuildMicros: _percentile(builds, 0.99),
      maxBuildMicros: builds[_length - 1],
      p50RasterMicros: _percentile(rasters, 0.50),
      p95RasterMicros: _percentile(rasters, 0.95),
      p99RasterMicros: _percentile(rasters, 0.99),
      maxRasterMicros: rasters[_length - 1],
      meanBuildMicros: buildSum ~/ _length,
      meanRasterMicros: rasterSum ~/ _length,
      deadlineMisses: _deadlineMisses,
      hitches: _hitches,
      deadlineMicros: deadlineMicros,
      hitchMicros: hitchMicros,
    );
  }

  static void _sort(Int32List values) {
    // Int32List has no in-place sort, and going through a growable List would
    // allocate on every summarize().
    final view = values.toList(growable: false)..sort();
    values.setRange(0, values.length, view);
  }

  /// Nearest-rank percentile over an ascending list.
  static int _percentile(Int32List sorted, double fraction) {
    final index = ((sorted.length - 1) * fraction).ceil();
    return sorted[index];
  }
}

/// A summarized frame-time window.
///
/// All durations are Flutter [FrameTiming.totalSpan] values, not presented
/// frames and not GPU time. See [FrameHistogram].
final class FrameSummary {
  const FrameSummary({
    required this.count,
    required this.p50Micros,
    required this.p95Micros,
    required this.p99Micros,
    required this.maxMicros,
    required this.p50BuildMicros,
    required this.p95BuildMicros,
    required this.p99BuildMicros,
    required this.maxBuildMicros,
    required this.p50RasterMicros,
    required this.p95RasterMicros,
    required this.p99RasterMicros,
    required this.maxRasterMicros,
    required this.meanBuildMicros,
    required this.meanRasterMicros,
    required this.deadlineMisses,
    required this.hitches,
    required this.deadlineMicros,
    required this.hitchMicros,
  });

  static const FrameSummary empty = FrameSummary(
    count: 0,
    p50Micros: 0,
    p95Micros: 0,
    p99Micros: 0,
    maxMicros: 0,
    p50BuildMicros: 0,
    p95BuildMicros: 0,
    p99BuildMicros: 0,
    maxBuildMicros: 0,
    p50RasterMicros: 0,
    p95RasterMicros: 0,
    p99RasterMicros: 0,
    maxRasterMicros: 0,
    meanBuildMicros: 0,
    meanRasterMicros: 0,
    deadlineMisses: 0,
    hitches: 0,
    deadlineMicros: 16667,
    hitchMicros: 50000,
  );

  final int count;
  final int p50Micros;
  final int p95Micros;
  final int p99Micros;
  final int maxMicros;
  final int p50BuildMicros;
  final int p95BuildMicros;
  final int p99BuildMicros;
  final int maxBuildMicros;
  final int p50RasterMicros;
  final int p95RasterMicros;
  final int p99RasterMicros;
  final int maxRasterMicros;
  final int meanBuildMicros;
  final int meanRasterMicros;
  final int deadlineMisses;
  final int hitches;
  final int deadlineMicros;
  final int hitchMicros;

  double get p50Millis => p50Micros / 1000;
  double get p95Millis => p95Micros / 1000;
  double get p99Millis => p99Micros / 1000;
  double get maxMillis => maxMicros / 1000;

  /// Fraction of frames whose total span exceeded the deadline.
  double get deadlineMissRate => count == 0 ? 0 : deadlineMisses / count;

  Map<String, Object> toJson() => <String, Object>{
    'metric': 'flutter_frame_timing_total_span',
    'count': count,
    'p50_ms': p50Millis,
    'p95_ms': p95Millis,
    'p99_ms': p99Millis,
    'max_ms': maxMillis,
    'build_duration': <String, Object>{
      'metric': 'flutter_frame_timing_build_duration',
      'available': true,
      'p50_ms': p50BuildMicros / 1000,
      'p95_ms': p95BuildMicros / 1000,
      'p99_ms': p99BuildMicros / 1000,
      'max_ms': maxBuildMicros / 1000,
      'mean_ms': meanBuildMicros / 1000,
    },
    'raster_duration': <String, Object>{
      'metric': 'flutter_frame_timing_raster_duration',
      'available': true,
      'p50_ms': p50RasterMicros / 1000,
      'p95_ms': p95RasterMicros / 1000,
      'p99_ms': p99RasterMicros / 1000,
      'max_ms': maxRasterMicros / 1000,
      'mean_ms': meanRasterMicros / 1000,
    },
    'mean_build_ms': meanBuildMicros / 1000,
    'mean_raster_ms': meanRasterMicros / 1000,
    'deadline_ms': deadlineMicros / 1000,
    'deadline_misses': deadlineMisses,
    'deadline_miss_rate': deadlineMissRate,
    'hitch_ms': hitchMicros / 1000,
    'hitches': hitches,
  };

  @override
  String toString() =>
      'FrameSummary(n: $count, p50: ${p50Millis.toStringAsFixed(2)} ms, '
      'p95: ${p95Millis.toStringAsFixed(2)} ms, '
      'p99: ${p99Millis.toStringAsFixed(2)} ms, '
      'max: ${maxMillis.toStringAsFixed(2)} ms, '
      'misses: $deadlineMisses, hitches: $hitches)';
}
