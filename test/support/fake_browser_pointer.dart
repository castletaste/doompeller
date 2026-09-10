import 'dart:async';
import 'package:doompeller/game/browser_pointer_driver.dart';

final class FakeBrowserPointer extends BrowserPointerDriver {
  @override
  bool available = true;
  @override
  bool touchPrimary = false;
  @override
  bool locked = false;
  @override
  bool mouseGesture = true;
  final requests = <Completer<void>>[];
  int releases = 0;
  bool disposed = false;
  @override
  Future<void> request() {
    final pending = Completer<void>();
    requests.add(pending);
    return pending.future;
  }

  void reportLock(bool owned) {
    locked = owned;
    onLock?.call(owned);
  }

  @override
  void release() {
    if (locked) releases++;
  }

  @override
  void dispose() => disposed = true;
}
