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
    return advanceMicrosWhile(elapsedMicros, (TicCmd command) {
      run(command);
      return true;
    }, cmd);
  }

  /// Advances due tics while [run] returns true.
  ///
  /// A false result means the tic just run reached a terminal state. That tic
  /// is counted, later callbacks from the same elapsed interval are skipped,
  /// and their post-terminal time is not reported as dropped simulation work.
  /// The existing [advanceMicros] API is the always-continue form.
  int advanceMicrosWhile(
    int elapsedMicros,
    bool Function(TicCmd) run,
    TicCmd cmd,
  ) {
    if (elapsedMicros < 0) {
      throw ArgumentError.value(elapsedMicros, 'elapsedMicros');
    }
    _scaledRemainder += elapsedMicros * kTicRate;
    final int due = _scaledRemainder ~/ _microsPerSecond;
    _scaledRemainder %= _microsPerSecond;
    final int limit = due > maxTicsPerFrame ? maxTicsPerFrame : due;
    var executed = 0;
    var terminated = false;
    for (var i = 0; i < limit; i++) {
      final bool shouldContinue = run(cmd);
      executed++;
      if (!shouldContinue) {
        terminated = true;
        break;
      }
    }
    executedTics += executed;
    if (!terminated && due > executed) {
      droppedTics += due - executed;
    }
    return executed;
  }
}
