import 'package:flutter/foundation.dart';
import 'level_preparer.dart';

enum DoomAppPhase { loading, fixtureReady, developerIwadReady, failure }

/// Closed set of app states. Ready states always carry a prepared level.
@immutable
sealed class DoomAppState {
  const DoomAppState();
  const factory DoomAppState.loading() = DoomAppLoading;
  const factory DoomAppState.failure(String message) = DoomAppFailure;
  const factory DoomAppState.ready(
    PreparedDoomLevel level, {
    required DoomAppPhase phase,
    String? setupMessage,
    String? errorMessage,
  }) = DoomAppReady;

  DoomAppPhase get phase;
  PreparedDoomLevel? get level => null;
  String? get errorMessage => null;
  String? get setupMessage => null;
  bool get isFixture => phase == DoomAppPhase.fixtureReady;
}

final class DoomAppLoading extends DoomAppState {
  const DoomAppLoading();
  @override
  DoomAppPhase get phase => DoomAppPhase.loading;
}

final class DoomAppFailure extends DoomAppState {
  const DoomAppFailure(this.errorMessage);
  @override
  final String errorMessage;
  @override
  DoomAppPhase get phase => DoomAppPhase.failure;
}

final class DoomAppReady extends DoomAppState {
  const DoomAppReady(
    this.level, {
    required DoomAppPhase phase,
    this.setupMessage,
    this.errorMessage,
  }) : assert(
         phase == DoomAppPhase.fixtureReady ||
             phase == DoomAppPhase.developerIwadReady,
       ),
       _phase = phase;

  final DoomAppPhase _phase;
  @override
  DoomAppPhase get phase => switch (_phase) {
    DoomAppPhase.fixtureReady || DoomAppPhase.developerIwadReady => _phase,
    _ => throw StateError('A ready state requires a ready phase.'),
  };
  @override
  final PreparedDoomLevel level;
  @override
  final String? setupMessage;
  @override
  final String? errorMessage;
}
