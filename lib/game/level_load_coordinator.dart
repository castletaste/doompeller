import 'dart:async';

import 'generation_fence.dart';

/// Checkpoint passed through asynchronous CPU preparation.
///
/// Work that can stop cheaply should call [throwIfCancelled] between parser,
/// resource and geometry stages. The generation fence remains the authority:
/// even code that forgets a checkpoint cannot publish stale output.
final class LevelLoadToken {
  LevelLoadToken._(this.generation, bool Function() isCurrent)
    : _isCurrent = isCurrent;

  final int generation;
  final bool Function() _isCurrent;

  bool get isCurrent => _isCurrent();
  bool get isCancelled => !isCurrent;

  void throwIfCancelled() {
    if (isCancelled) {
      throw LevelLoadCancelled(generation);
    }
  }
}

final class LevelLoadCancelled implements Exception {
  const LevelLoadCancelled(this.generation);

  final int generation;

  @override
  String toString() => 'LevelLoadCancelled(generation: $generation)';
}

sealed class LevelLoadOutcome<T> {
  const LevelLoadOutcome(this.generation);

  final int generation;
}

final class LevelPublished<T> extends LevelLoadOutcome<T> {
  const LevelPublished(super.generation, this.level);

  final T level;
}

final class LevelLoadStale<T> extends LevelLoadOutcome<T> {
  const LevelLoadStale(super.generation);
}

final class LevelLoadFailed<T> extends LevelLoadOutcome<T> {
  const LevelLoadFailed(super.generation, this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

/// Generation-fenced CPU level loader.
///
/// [prepare] performs all asynchronous CPU work: parsing, resource decoding and
/// geometry compilation. Publication is the only operation after preparation;
/// the app creates its runtime from the published value in the widget layer.
///
/// Starting another load or calling [cancel] invalidates older generations.
/// Stale prepared data is handed to [discardPrepared].
///
/// This cannot prove deterministic GPU reclamation when a published level is
/// replaced: flame_3d 0.3.0 exposes no resource disposal API. The app therefore
/// keeps replacement rare and measures settled RSS across reload soaks.
final class LevelLoadCoordinator<T> {
  // Owns CPU preparation publication. The controller's request generation is
  // checked before and after this coordinator, while this generation is the
  // only source of LevelLoadToken identities. The controller remains the
  // owner of the published level.
  final GenerationFence _fence = GenerationFence();

  int get generation => _fence.current;

  Future<LevelLoadOutcome<T>> load({
    required Future<T> Function(LevelLoadToken token) prepare,
    void Function(T prepared)? discardPrepared,
  }) async {
    final int loadGeneration = _fence.issue();
    final token = LevelLoadToken._(
      loadGeneration,
      () => _fence.isCurrent(loadGeneration),
    );

    try {
      final T prepared = await prepare(token);
      if (!token.isCurrent) {
        discardPrepared?.call(prepared);
        return LevelLoadStale<T>(loadGeneration);
      }

      return LevelPublished<T>(loadGeneration, prepared);
    } on LevelLoadCancelled {
      return LevelLoadStale<T>(loadGeneration);
    } catch (error, stackTrace) {
      // A stale failure belongs to an obsolete generation; it must not surface
      // as the current load's error UI.
      if (!token.isCurrent) {
        return LevelLoadStale<T>(loadGeneration);
      }
      return LevelLoadFailed<T>(loadGeneration, error, stackTrace);
    }
  }

  /// Invalidates in-flight CPU work. The controller's published level stays live.
  void cancel() {
    _fence.invalidate();
  }
}
