/// Doom's deterministic pseudo-random source.
///
/// The original uses a fixed 256-byte table indexed by a rolling counter. Two
/// properties matter for us: it is deterministic given a starting index, and it
/// is shared by every subsystem, so consumption order is part of the game state.
/// Reproducing the *structure* keeps replays and state hashes stable.
///
/// The table itself is generated here from a documented linear congruential
/// sequence rather than transcribed, and the exact byte values are not
/// behaviourally load-bearing for our own tuning — only determinism is.
class DoomRandom {
  DoomRandom({int index = 0}) : _index = index & 0xFF;

  static final List<int> _table = _buildTable();

  static List<int> _buildTable() {
    final List<int> table = List<int>.filled(256, 0);
    int state = 0x1234ABCD;
    for (int i = 0; i < 256; i++) {
      state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
      table[i] = (state >> 16) & 0xFF;
    }
    return table;
  }

  int _index;

  /// Current table position. Part of the serialised game state.
  int get index => _index;
  set index(int value) => _index = value & 0xFF;

  /// Next value in `[0, 255]`.
  int next() {
    _index = (_index + 1) & 0xFF;
    return _table[_index];
  }

  /// Signed difference of two draws, in `[-255, 255]`. This is the idiom the
  /// original uses for spread, damage variance and pain chance.
  int nextSigned() => next() - next();

  /// True with probability `chance / 256`.
  bool chance(int chance) => next() < chance;

  DoomRandom copy() => DoomRandom(index: _index);
}
