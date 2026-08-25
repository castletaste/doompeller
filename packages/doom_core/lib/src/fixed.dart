/// Doom's 16.16 fixed-point arithmetic, reimplemented in Dart.
///
/// Why fixed point at all when Dart has doubles: the simulation must be
/// bit-for-bit reproducible so a recorded input stream always replays to the
/// same state hash. Doubles are reproducible in principle but every refactor
/// risks a reassociation that changes the last bit. Integers do not have that
/// problem.
///
/// Dart integers are 64-bit, while the original arithmetic wraps at 32 bits.
/// Every operation here therefore truncates back to signed 32-bit so overflow
/// behaves identically no matter how a value was produced.
library;

/// Number of fractional bits.
const int kFracBits = 16;

/// One whole unit in fixed point.
const int kFracUnit = 1 << kFracBits;

const int _mask32 = 0xFFFFFFFF;
const int _sign32 = 0x80000000;

/// Truncates [value] to a signed 32-bit integer, wrapping like C would.
int wrap32(int value) {
  final int masked = value & _mask32;
  return (masked & _sign32) != 0 ? masked - 0x100000000 : masked;
}

/// Fixed-point multiply.
int fixedMul(int a, int b) => wrap32((a * b) >> kFracBits);

/// Fixed-point divide. Mirrors the original's saturating guard: when the
/// magnitudes differ by more than 14 bits the result is clamped instead of
/// overflowing.
int fixedDiv(int a, int b) {
  a = wrap32(a);
  b = wrap32(b);
  if (b == 0) {
    return a < 0 ? -0x7FFFFFFF : 0x7FFFFFFF;
  }
  final int magnitudeA = a < 0 ? -a : a;
  final int magnitudeB = b < 0 ? -b : b;
  if ((magnitudeA >> 14) >= magnitudeB) {
    return (a ^ b) < 0 ? -0x7FFFFFFF : 0x7FFFFFFF;
  }
  return wrap32((a << kFracBits) ~/ b);
}

/// Converts a whole map unit to fixed point.
int toFixed(int units) => wrap32(units << kFracBits);

/// Converts fixed point back to whole map units, truncating toward negative
/// infinity so behaviour matches an arithmetic shift rather than Dart's
/// truncating integer division.
int fixedToInt(int value) => value >> kFracBits;

/// Converts fixed point to a double. Only for rendering and diagnostics; never
/// feed the result back into simulation state.
double fixedToDouble(int value) => value / kFracUnit;

/// Converts a double to fixed point. Only for importing map data and tuning
/// constants, never inside a tick.
int doubleToFixed(double value) => wrap32((value * kFracUnit).round());

/// Returns the fixed-point absolute value.
int fixedAbs(int value) {
  final int signed = wrap32(value);
  return signed < 0 ? -signed : signed;
}

/// Approximate 2D length. Uses the classic cheap estimate
/// `max + min / 2`, which is what the original movement code relies on, so
/// distances stay consistent with the tuning constants.
int approxDistance(int dx, int dy) {
  final int ax = fixedAbs(dx);
  final int ay = fixedAbs(dy);
  return ax < ay ? ax + ay - (ax >> 1) : ay + ax - (ay >> 1);
}
