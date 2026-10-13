/// Small monotonic fence for asynchronous work owned by one lifecycle.
///
/// A fence only answers whether a previously issued generation is still the
/// current one. Different owners keep separate fences, so invalidating a file
/// picker cannot cancel a level load and disposing a controller cannot make a
/// different controller's fence current.
final class GenerationFence {
  int _generation = 0;
  bool _closed = false;

  int get current => _generation;

  /// Issues a generation that is current until [invalidate] or [close].
  int issue() {
    if (_closed) {
      throw StateError('Cannot issue a generation from a closed fence');
    }
    return ++_generation;
  }

  /// Invalidates all issued generations while keeping the fence reusable.
  int invalidate() => ++_generation;

  bool isCurrent(int generation) => !_closed && generation == _generation;

  /// Permanently invalidates the fence. Repeated closes are harmless.
  void close() {
    if (_closed) return;
    _closed = true;
    _generation++;
  }
}
