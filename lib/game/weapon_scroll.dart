/// A wheel notch or a short trackpad stroke selects one weapon. Horizontal
/// swipes remain available to mobile controls. Excess deltas are bounded.
final class DoomWeaponScroll {
  double _distance = 0;
  int add(double vertical) {
    if (!vertical.isFinite || vertical == 0) return 0;
    if (_distance.sign != vertical.sign) _distance = 0;
    _distance += vertical.clamp(-288.0, 288.0);
    final steps = (_distance / 48).truncate();
    _distance -= steps * 48;
    return steps;
  }

  void clear() => _distance = 0;
}
