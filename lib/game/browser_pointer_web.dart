import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'browser_pointer_driver.dart';

// Pointer Lock is event-based in browsers which still return undefined here.
extension type _PointerTarget(JSObject _) implements JSObject {
  external JSAny? requestPointerLock();
}

BrowserPointerDriver createBrowserPointerDriver() => _WebPointerDriver();

final class _WebPointerDriver extends BrowserPointerDriver {
  _WebPointerDriver() {
    final options = web.AddEventListenerOptions(signal: _events.signal);
    web.document.addEventListener(
      'pointerlockchange',
      ((web.Event _) {
        onLock?.call(locked);
      }).toJS,
      options,
    );
    web.document.addEventListener(
      'pointerlockerror',
      ((web.Event _) {
        onError?.call();
      }).toJS,
      options,
    );
    web.document.addEventListener(
      'mousemove',
      ((web.MouseEvent event) {
        if (locked) onTurn?.call(event.movementX.toDouble());
      }).toJS,
      options,
    );
    web.document.addEventListener(
      'pointerdown',
      ((web.PointerEvent event) {
        _mouseGesture = event.isTrusted && event.pointerType == 'mouse';
        if (locked && event.pointerType == 'mouse' && event.button == 0) {
          onAttack?.call(true);
        }
      }).toJS,
      web.AddEventListenerOptions(capture: true, signal: _events.signal),
    );
    web.document.addEventListener(
      'pointerup',
      ((web.PointerEvent event) {
        if (locked && event.pointerType == 'mouse' && event.button == 0) {
          onAttack?.call(false);
        }
      }).toJS,
      options,
    );
    web.document.addEventListener(
      'pointercancel',
      ((web.PointerEvent _) {
        onAttack?.call(false);
      }).toJS,
      options,
    );
    web.document.addEventListener(
      'keydown',
      ((web.Event _) {
        _mouseGesture = false;
      }).toJS,
      web.AddEventListenerOptions(capture: true, signal: _events.signal),
    );
    web.window.addEventListener(
      'blur',
      ((web.Event _) {
        _mouseGesture = false;
        onBlur?.call();
      }).toJS,
      options,
    );
    web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) {
        if (web.document.hidden) onBlur?.call();
      }).toJS,
      options,
    );
  }

  final _events = web.AbortController();
  final _target = web.document.documentElement!;
  bool _mouseGesture = false;
  bool _releasing = false;
  @override
  bool get available => true;
  @override
  bool get touchPrimary => web.window.matchMedia('(pointer: coarse)').matches;
  @override
  bool get locked => web.document.pointerLockElement == _target;
  @override
  bool get mouseGesture => _mouseGesture && web.document.hasFocus();

  @override
  Future<void> request() async {
    _mouseGesture = false;
    final result = _PointerTarget(_target).requestPointerLock();
    if (result != null && result.isA<JSPromise<JSAny?>>()) {
      await (result as JSPromise<JSAny?>).toDart;
    }
  }

  @override
  void release() {
    if (!locked || _releasing) return;
    _releasing = true;
    Timer.run(() {
      _releasing = false;
      if (locked) web.document.exitPointerLock();
    });
  }

  @override
  void dispose() => _events.abort();
}
