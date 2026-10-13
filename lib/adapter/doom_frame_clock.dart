/// Turns the frame ticker's elapsed time into per-frame deltas.
///
/// The ticker's elapsed time comes from vsync timestamps, so consecutive
/// deltas are exact display periods. Measuring wall-clock time when the frame
/// callback happens to run instead adds the callback's position within the
/// frame, and the millisecond rounding of web clocks, to every delta. The
/// fixed 35 Hz simulation and its interpolated camera then advance unevenly
/// while the view is otherwise steady, which reads as stutter whenever the
/// player moves.
final class DoomFrameClock {
  Duration? _last;

  /// Seconds since the previous frame; zero on the first frame and if the
  /// ticker restarts behind the previous reading.
  double advance(Duration elapsed) {
    final last = _last;
    _last = elapsed;
    if (last == null || elapsed <= last) return 0;
    return (elapsed - last).inMicroseconds / Duration.microsecondsPerSecond;
  }

  /// Forgets the previous reading, for a new ticker or a new host.
  void reset() => _last = null;
}
