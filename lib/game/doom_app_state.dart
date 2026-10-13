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
    String? setupMessage,
    String? errorMessage,
  }) = DoomAppReady;

  DoomAppPhase get phase;
  PreparedDoomLevel? get level => null;
  String? get errorMessage => null;
  String? get setupMessage => null;
  bool get isFixture => level?.content.isFixture ?? false;
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
  const DoomAppReady(this.level, {this.setupMessage, this.errorMessage});

  @override
  DoomAppPhase get phase => level.content.isFixture
      ? DoomAppPhase.fixtureReady
      : DoomAppPhase.developerIwadReady;
  @override
  final PreparedDoomLevel level;
  @override
  final String? setupMessage;
  @override
  final String? errorMessage;
}
