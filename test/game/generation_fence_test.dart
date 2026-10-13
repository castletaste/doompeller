import 'package:flutter_test/flutter_test.dart';

import 'package:doompeller/game/generation_fence.dart';

void main() {
  test('only the latest issued generation remains current', () {
    final fence = GenerationFence();
    final first = fence.issue();
    final second = fence.issue();

    expect(fence.isCurrent(first), isFalse);
    expect(fence.isCurrent(second), isTrue);
  });

  test('invalidate keeps the fence reusable and rejects older work', () {
    final fence = GenerationFence();
    final first = fence.issue();
    fence.invalidate();

    expect(fence.isCurrent(first), isFalse);
    final second = fence.issue();
    expect(fence.isCurrent(second), isTrue);
  });

  test('close permanently rejects generations', () {
    final fence = GenerationFence();
    final generation = fence.issue();
    fence.close();

    expect(fence.isCurrent(generation), isFalse);
    expect(() => fence.issue(), throwsStateError);
  });
}
