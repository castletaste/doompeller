import 'ticcmd.dart';

/// Bridges an arbitrary render clock to integer 35 Hz simulation. Remainder is
/// deliberately retained; a slow frame reports dropped tics rather than
/// changing the length of any simulation tick.
class FixedTickDriver {
  FixedTickDriver({this.maxTicsPerFrame = 4}) : assert(maxTicsPerFrame > 0);
  final int maxTicsPerFrame;
  static const int _microsPerSecond = 1000000;
  int _scaledRemainder = 0;
  int droppedTics = 0;
  int executedTics = 0;

  /// Fraction [0, 1) expressed as a rational to avoid feeding a double back.
  int get interpolationNumerator => _scaledRemainder;
  int get interpolationDenominator => _microsPerSecond;
  double get interpolationAlpha => _scaledRemainder / _microsPerSecond;

  int advanceMicros(int elapsedMicros, void Function(TicCmd) run, TicCmd cmd) {
    if (elapsedMicros < 0) {
      throw ArgumentError.value(elapsedMicros, 'elapsedMicros');
    }
    _scaledRemainder += elapsedMicros * kTicRate;
    final int due = _scaledRemainder ~/ _microsPerSecond;
    _scaledRemainder %= _microsPerSecond;
    final int executed = due > maxTicsPerFrame ? maxTicsPerFrame : due;
    for (int i = 0; i < executed; i++) {
      run(cmd);
    }
    executedTics += executed;
    if (due > executed) {
      droppedTics += due - executed;
    }
    return executed;
  }
}
