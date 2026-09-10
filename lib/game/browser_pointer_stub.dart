import 'browser_pointer_driver.dart';

BrowserPointerDriver createBrowserPointerDriver() => _NoBrowserPointer();

final class _NoBrowserPointer extends BrowserPointerDriver {
  @override
  bool get available => false;
  @override
  bool get touchPrimary => false;
  @override
  bool get locked => false;
  @override
  bool get mouseGesture => false;
  @override
  Future<void> request() async {}
  @override
  void release() {}
  @override
  void dispose() {}
}
