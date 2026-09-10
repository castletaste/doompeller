import 'dart:async';
import 'package:flutter/foundation.dart';
import 'browser_pointer_driver.dart';
import 'browser_pointer_stub.dart'
    if (dart.library.js_interop) 'browser_pointer_web.dart'
    as platform;

/// App-owned browser listener lifetime with one revocable level lease.
final class DoomBrowserInput extends ChangeNotifier {
  DoomBrowserInput({BrowserPointerDriver? driver})
    : _driver = driver ?? platform.createBrowserPointerDriver() {
    _driver
      ..onLock = _lockChanged
      ..onError = _failed
      ..onBlur = _blurred
      ..onTurn = (dx) {
        if (captured && dx.isFinite) _owner?.onTurn(dx);
      }
      ..onAttack = (pressed) {
        if (captured) _owner?.onAttack(pressed);
      };
  }

  final BrowserPointerDriver _driver;
  DoomBrowserInputLease? _owner;
  Object? _pending;
  bool _wanted = false;
  bool _locked = false;
  bool _disposed = false;
  bool _driverDisposed = false;
  String? _error;
  bool get available => _driver.available;
  bool get touchPrimary => _driver.touchPrimary;
  bool get captured => !_disposed && _wanted && _locked;
  String? get errorMessage => _error;

  DoomBrowserInputLease acquire({
    required ValueChanged<double> onTurn,
    required ValueChanged<bool> onAttack,
    required VoidCallback onPause,
  }) {
    if (_disposed) throw StateError('Browser input is disposed.');
    _release();
    return _owner = DoomBrowserInputLease._(this, onTurn, onAttack, onPause);
  }

  void _capture(DoomBrowserInputLease owner) {
    if (_disposed ||
        !identical(owner, _owner) ||
        !available ||
        !_driver.mouseGesture ||
        captured) {
      return;
    }
    if (_pending != null || _driver.locked) {
      _error = 'Finishing the previous mouse capture. Click again to play.';
      notifyListeners();
      return;
    }
    final ticket = Object();
    _pending = ticket;
    _wanted = true;
    _error = null;
    notifyListeners();
    unawaited(
      _driver.request().catchError((Object error) {
        if (identical(_pending, ticket)) _failed();
      }),
    );
    // Even a resolved Promise is not proof of capture. Some browsers return
    // void; only the document's ownership notification admits relative input.
  }

  void _failed() {
    if (_pending == null) return;
    _pending = null;
    if (!_disposed && _wanted) {
      _error =
          'Mouse capture is unavailable. Use the keyboard or touch controls, '
          'or click the game to try again.';
    }
    _wanted = false;
    _changed();
  }

  void _lockChanged(bool locked) {
    final wasWanted = _wanted;
    _locked = locked;
    _pending = null;
    if (locked && (!_wanted || _disposed || _owner == null)) {
      _driver.release();
    } else if (!locked) {
      _wanted = false;
      if (wasWanted) _owner?.onPause();
    }
    _changed();
  }

  void _blurred() {
    if (_disposed) return;
    _owner?.onPause();
    _release();
  }

  void _release() {
    _wanted = false;
    _owner?.onAttack(false);
    _driver.release();
    // Keep an in-flight acquisition fenced until its document event arrives.
    // A replacement level cannot inherit it or issue an overlapping request.
  }

  void _changed() {
    if (!_disposed) {
      notifyListeners();
    } else if (_pending == null && !_driver.locked && !_driverDisposed) {
      _driverDisposed = true;
      _driver.dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _release();
    _owner = null;
    _disposed = true;
    _changed();
    super.dispose();
  }
}

final class DoomBrowserInputLease {
  DoomBrowserInputLease._(
    this._session,
    this.onTurn,
    this.onAttack,
    this.onPause,
  );
  final DoomBrowserInput _session;
  final ValueChanged<double> onTurn;
  final ValueChanged<bool> onAttack;
  final VoidCallback onPause;
  void capture() => _session._capture(this);
  void release() {
    if (identical(_session._owner, this)) _session._release();
  }

  void dispose() {
    if (!identical(_session._owner, this)) return;
    _session._release();
    _session._owner = null;
  }
}
