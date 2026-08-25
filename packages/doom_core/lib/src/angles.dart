import 'fixed.dart';

/// Binary angle measurement. A full turn is 2^32, so angles wrap for free.
const int kAng45 = 0x20000000;
const int kAng90 = 0x40000000;
const int kAng180 = 0x80000000;
const int kAng270 = 0xC0000000;

/// Full circle. Angles are stored unsigned in `[0, 2^32)`.
const int kAngMax = 0x100000000;

/// Resolution of the trig tables.
const int kFineAngles = 8192;
const int kFineMask = kFineAngles - 1;

/// Shift from a BAM angle down to a trig table index.
const int kAngleToFineShift = 19;

/// Normalises any integer into the unsigned BAM range.
int normalizeAngle(int angle) => angle & 0xFFFFFFFF;

/// Signed difference `a - b` in the range `(-2^31, 2^31]`, which is what you
/// want for "which way should I turn".
int angleDelta(int a, int b) => wrap32(normalizeAngle(a) - normalizeAngle(b));

/// Converts whole degrees, as stored in THINGS lumps, to BAM.
int degreesToAngle(int degrees) {
  final int normalizedDegrees = ((degrees % 360) + 360) % 360;
  return normalizeAngle((normalizedDegrees * kAngMax) ~/ 360);
}

/// Integer-only CORDIC trig. No floating-point value participates in a tick.
abstract final class Trig {
  static const List<int> _atan = <int>[
    0x20000000,
    0x12e4051e,
    0x09fb385b,
    0x051111d4,
    0x028b0d43,
    0x0145d7e1,
    0x00a2f61e,
    0x00517c55,
    0x0028be53,
    0x00145f2f,
    0x000a2f98,
    0x000517cc,
    0x00028be6,
    0x000145f3,
    0x0000a2fa,
    0x0000517d,
  ];
  static const int _gainInverse = 39797;

  static ({int sin, int cos}) _rotate(int angle) {
    final int unsigned = normalizeAngle(angle);
    if (unsigned == 0) return (sin: 0, cos: kFracUnit);
    if (unsigned == kAng90) return (sin: kFracUnit, cos: 0);
    if (unsigned == kAng180) return (sin: 0, cos: -kFracUnit);
    if (unsigned == kAng270) return (sin: -kFracUnit, cos: 0);
    int z = unsigned <= kAng180 ? unsigned : unsigned - kAngMax;
    int sign = 1;
    if (z > kAng90) {
      z -= kAng180;
      sign = -1;
    } else if (z < -kAng90) {
      z += kAng180;
      sign = -1;
    }
    int x = _gainInverse;
    int y = 0;
    for (int i = 0; i < _atan.length; i++) {
      final int oldX = x;
      if (z >= 0) {
        x -= y >> i;
        y += oldX >> i;
        z -= _atan[i];
      } else {
        x += y >> i;
        y -= oldX >> i;
        z += _atan[i];
      }
    }
    return (sin: wrap32(y * sign), cos: wrap32(x * sign));
  }

  static int sin(int angle) => _rotate(angle).sin;
  static int cos(int angle) => _rotate(angle).cos;

  /// Fixed-point tangent, clamped to avoid infinities at the poles.
  static int tan(int angle) {
    final ({int sin, int cos}) value = _rotate(angle);
    final int c = value.cos;
    if (c == 0) {
      return value.sin < 0 ? -0x7FFFFFFF : 0x7FFFFFFF;
    }
    return fixedDiv(value.sin, c);
  }

  /// BAM angle of the vector `(x, y)`.
  static int atan2(int y, int x) {
    if (x == 0 && y == 0) {
      return 0;
    }
    if (y == 0) return x < 0 ? kAng180 : 0;
    if (x == 0) return y < 0 ? kAng270 : kAng90;
    int z = 0;
    int vx = x;
    int vy = y;
    if (vx < 0) {
      vx = -vx;
      vy = -vy;
      z = y >= 0 ? kAng180 : -kAng180;
    }
    for (int i = 0; i < _atan.length; i++) {
      if (vy == 0) break;
      final int oldX = vx;
      if (vy > 0) {
        vx += vy >> i;
        vy -= oldX >> i;
        z += _atan[i];
      } else {
        vx -= vy >> i;
        vy += oldX >> i;
        z -= _atan[i];
      }
    }
    return normalizeAngle(z);
  }

  /// BAM angle from point `(x1, y1)` to point `(x2, y2)`.
  static int pointToAngle(int x1, int y1, int x2, int y2) =>
      atan2(y2 - y1, x2 - x1);
}
