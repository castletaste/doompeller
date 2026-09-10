import 'package:doompeller/game/browser_input.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/fake_browser_pointer.dart';

void main() {
  test(
    'relative look and fire require acknowledged capture and remain separate',
    () async {
      final driver = FakeBrowserPointer();
      final session = DoomBrowserInput(driver: driver);
      final turns = <double>[];
      final attacks = <bool>[];
      var pauses = 0;
      final lease = session.acquire(
        onTurn: turns.add,
        onAttack: attacks.add,
        onPause: () => pauses++,
      );
      lease.capture();
      lease.capture();
      expect(driver.requests, hasLength(1));
      driver.requests.single.complete();
      await Future<void>.value();
      driver.onTurn?.call(12);
      expect(turns, isEmpty);
      driver.reportLock(true);
      driver.onTurn?.call(12);
      expect(turns, [12]);
      expect(attacks, isEmpty);
      driver.onAttack?.call(true);
      driver.onAttack?.call(false);
      expect(attacks, [true, false]);
      driver.reportLock(false);
      driver.reportLock(false);
      driver.onTurn?.call(9);
      expect(pauses, 1);
      expect(turns, [12]);
      session.dispose();
      expect(driver.disposed, isTrue);
    },
  );
  test('late acquisition cannot belong to a replacement level', () {
    final driver = FakeBrowserPointer();
    final session = DoomBrowserInput(driver: driver);
    final oldTurns = <double>[], newTurns = <double>[];
    final old = session.acquire(
      onTurn: oldTurns.add,
      onAttack: (_) {},
      onPause: () {},
    );
    old.capture();
    old.dispose();
    final next = session.acquire(
      onTurn: newTurns.add,
      onAttack: (_) {},
      onPause: () {},
    );
    next.capture();
    expect(driver.requests, hasLength(1));
    driver.reportLock(true);
    expect(session.captured, isFalse);
    expect(driver.releases, 1);
    driver.onTurn?.call(3);
    expect(oldTurns, isEmpty);
    expect(newTurns, isEmpty);
    driver.reportLock(false);
    next.capture();
    driver.reportLock(true);
    old.release();
    old.dispose();
    expect(session.captured, isTrue);
    driver.onTurn?.call(4);
    expect(newTurns, [4]);
    session.dispose();
    driver.reportLock(false);
    expect(driver.disposed, isTrue);
  });
  test(
    'dispose waits only for a pending acquisition to release its late lock',
    () {
      final driver = FakeBrowserPointer();
      final session = DoomBrowserInput(driver: driver);
      session
          .acquire(
            onTurn: (_) => fail('retired input'),
            onAttack: (_) {},
            onPause: () => fail('retired pause'),
          )
          .capture();
      session.dispose();
      expect(driver.disposed, isFalse);
      driver.reportLock(true);
      expect(driver.releases, 1);
      driver.onTurn?.call(3);
      driver.reportLock(false);
      expect(driver.disposed, isTrue);
    },
  );
  test(
    'failure allows retry; stale Promise rejection cannot reject its successor',
    () async {
      final driver = FakeBrowserPointer();
      final session = DoomBrowserInput(driver: driver);
      final lease = session.acquire(
        onTurn: (_) {},
        onAttack: (_) {},
        onPause: () {},
      );
      driver.mouseGesture = false;
      lease.capture();
      expect(driver.requests, isEmpty);
      driver.mouseGesture = true;
      lease.capture();
      driver.onError?.call();
      expect(session.errorMessage, contains('keyboard or touch'));
      lease.capture();
      driver.requests.first.completeError(StateError('old rejection'));
      await Future<void>.value();
      expect(session.errorMessage, isNull);
      driver.reportLock(true);
      expect(session.captured, isTrue);
      session.dispose();
      driver.reportLock(false);
    },
  );
}
