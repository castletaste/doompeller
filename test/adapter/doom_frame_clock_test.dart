import 'package:doompeller/adapter/adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('deltas are exact differences of ticker elapsed time', () {
    final clock = DoomFrameClock();
    expect(clock.advance(const Duration(microseconds: 1000)), 0);
    // A 120 Hz display: every delta is one vsync period, regardless of when
    // in the frame the callback ran.
    for (var frame = 1; frame <= 120; frame++) {
      expect(
        clock.advance(Duration(microseconds: 1000 + frame * 8333)),
        closeTo(0.008333, 1e-9),
      );
    }
  });

  test('a restarted or rewound ticker yields zero, not a negative delta', () {
    final clock = DoomFrameClock()..advance(const Duration(seconds: 5));
    expect(clock.advance(const Duration(seconds: 1)), 0);
    expect(clock.advance(const Duration(seconds: 1, milliseconds: 10)), 0.01);
    clock.reset();
    expect(clock.advance(const Duration(seconds: 9)), 0);
  });
}
