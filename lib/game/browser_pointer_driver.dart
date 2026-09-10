import 'package:flutter/foundation.dart';

/// Small platform boundary; the session owns policy and level lifetimes.
abstract class BrowserPointerDriver {
  bool get available;
  bool get touchPrimary;
  bool get locked;
  bool get mouseGesture;
  ValueChanged<bool>? onLock;
  ValueChanged<double>? onTurn;
  ValueChanged<bool>? onAttack;
  VoidCallback? onBlur;
  VoidCallback? onError;
  Future<void> request();
  void release();
  void dispose();
}
