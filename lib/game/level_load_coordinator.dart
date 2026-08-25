import 'dart:async';

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

/// Generation-fenced, two-phase level loader.
///
/// [prepare] performs all asynchronous CPU work: parsing, resource decoding and
/// geometry compilation. [assemble] is deliberately synchronous. flame_3d
/// allocates buffers lazily on first draw, so a synchronous assembly followed
/// immediately by publication cannot be cancelled halfway through a native GPU
/// upload and leave an unreachable buffer behind.
///
/// Starting another load or calling [cancel] invalidates older generations.
/// Stale prepared data is handed to [discardPrepared] and never reaches
/// [assemble]. A failure never replaces [activeLevel].
///
/// This cannot prove deterministic GPU reclamation when a published level is
/// replaced: flame_3d 0.3.0 exposes no resource disposal API. The app therefore
/// keeps replacement rare and measures settled RSS across reload soaks.
final class LevelLoadCoordinator<Prepared, Level> {
  int _generation = 0;
  Level? _activeLevel;

  int get generation => _generation;
  Level? get activeLevel => _activeLevel;
  bool get hasActiveLevel => _activeLevel != null;

  Future<LevelLoadOutcome<Level>> load({
    required Future<Prepared> Function(LevelLoadToken token) prepare,
    required Level Function(Prepared prepared) assemble,
    void Function(Prepared prepared)? discardPrepared,
    void Function(Level previous)? onReplaced,
  }) async {
    final int loadGeneration = ++_generation;
    final token = LevelLoadToken._(
      loadGeneration,
      () => _generation == loadGeneration,
    );

    try {
      final Prepared prepared = await prepare(token);
      if (!token.isCurrent) {
        discardPrepared?.call(prepared);
        return LevelLoadStale<Level>(loadGeneration);
      }

      // This callback must stay synchronous. No other event-loop turn can
      // invalidate the token between the check and publication.
      final Level level = assemble(prepared);
      if (!token.isCurrent) {
        // Defensive against a re-entrant assemble callback that calls cancel.
        return LevelLoadStale<Level>(loadGeneration);
      }

      final Level? previous = _activeLevel;
      _activeLevel = level;
      if (previous != null && !identical(previous, level)) {
        onReplaced?.call(previous);
      }
      return LevelPublished<Level>(loadGeneration, level);
    } on LevelLoadCancelled {
      return LevelLoadStale<Level>(loadGeneration);
    } catch (error, stackTrace) {
      // A stale failure belongs to an obsolete generation; it must not surface
      // as the current load's error UI.
      if (!token.isCurrent) {
        return LevelLoadStale<Level>(loadGeneration);
      }
      return LevelLoadFailed<Level>(loadGeneration, error, stackTrace);
    }
  }

  /// Invalidates in-flight CPU work. The currently published level stays live.
  void cancel() {
    _generation++;
  }

  /// Drops the logical active level without claiming GPU resource reclamation.
  Level? detachActive() {
    final Level? previous = _activeLevel;
    _activeLevel = null;
    _generation++;
    return previous;
  }
}
