import 'package:flutter/foundation.dart';

import 'content_source.dart';
import 'level_load_coordinator.dart';
import 'level_preparer.dart';

enum DoomAppPhase { loading, fixtureReady, developerIwadReady, failure }

@immutable
final class DoomAppState {
  const DoomAppState._({
    required this.phase,
    this.level,
    this.errorMessage,
    this.setupMessage,
  });

  const DoomAppState.loading() : this._(phase: DoomAppPhase.loading);

  const DoomAppState.failure(String message)
    : this._(phase: DoomAppPhase.failure, errorMessage: message);

  const DoomAppState.ready(
    PreparedDoomLevel level, {
    required DoomAppPhase phase,
    String? setupMessage,
    String? errorMessage,
  }) : this._(
         phase: phase,
         level: level,
         setupMessage: setupMessage,
         errorMessage: errorMessage,
       );

  final DoomAppPhase phase;
  final PreparedDoomLevel? level;
  final String? errorMessage;
  final String? setupMessage;

  bool get isFixture => phase == DoomAppPhase.fixtureReady;
}

typedef LoadDeveloperContent = Future<DoomContentLoadResult> Function();
typedef LoadFixtureContent = DoomContent Function();
typedef LoadSelectedContent =
    DoomContentLoadResult Function(
      Uint8List bytes, {
      String mapName,
      String? sourcePath,
    });
typedef PrepareDoomLevel =
    Future<PreparedDoomLevel> Function(
      DoomContent content,
      LevelLoadToken token,
    );

/// App-facing load state with an outer request fence and CPU generation fence.
final class DoomAppController extends ChangeNotifier {
  DoomAppController({
    DoomContentSource? contentSource,
    DoomLevelPreparer? preparer,
    LoadDeveloperContent? loadDeveloper,
    LoadFixtureContent? loadFixture,
    LoadSelectedContent? loadSelected,
    PrepareDoomLevel? prepare,
    DoomAppState initialState = const DoomAppState.loading(),
  }) : _loadDeveloper =
           loadDeveloper ??
           (contentSource ?? DoomContentSource()).loadDeveloperIwad,
       _loadFixture =
           loadFixture ?? (contentSource ?? DoomContentSource()).loadFixture,
       _loadSelected =
           loadSelected ?? (contentSource ?? DoomContentSource()).loadIwadBytes,
       _prepare = prepare ?? (preparer ?? DoomLevelPreparer()).prepare,
       _state = initialState;

  final LoadDeveloperContent _loadDeveloper;
  final LoadFixtureContent _loadFixture;
  final LoadSelectedContent _loadSelected;
  final PrepareDoomLevel _prepare;
  final LevelLoadCoordinator<PreparedDoomLevel, PreparedDoomLevel>
  _coordinator = LevelLoadCoordinator<PreparedDoomLevel, PreparedDoomLevel>();

  DoomAppState _state;
  int _requestGeneration = 0;
  bool _disposed = false;

  DoomAppState get state => _state;

  Future<void> start() async {
    final int request = ++_requestGeneration;
    _publish(const DoomAppState.loading());
    DoomContentLoadResult result;
    try {
      result = await _loadDeveloper();
    } catch (_) {
      if (_isCurrent(request)) {
        _publish(
          const DoomAppState.failure(
            'Unexpected error while loading the configured developer IWAD.',
          ),
        );
      }
      return;
    }
    if (!_isCurrent(request)) {
      return;
    }
    switch (result) {
      case DoomContentLoaded(:final content):
        await _load(content, request: request);
      case DoomContentPathMissing(:final setupMessage, :final autoLoadFixture):
        if (!autoLoadFixture) {
          _publish(DoomAppState.failure(setupMessage));
          return;
        }
        DoomContent fixture;
        try {
          fixture = _loadFixture();
        } catch (_) {
          if (_isCurrent(request)) {
            _publish(
              const DoomAppState.failure(
                'Could not create the synthetic test map.',
              ),
            );
          }
          return;
        }
        await _load(fixture, request: request, setupMessage: setupMessage);
      case DoomContentLoadFailure(:final message):
        _publish(DoomAppState.failure(message));
    }
  }

  Future<void> useFixtureFallback() async {
    final int request = ++_requestGeneration;
    _coordinator.cancel();
    _publish(const DoomAppState.loading());
    DoomContent fixture;
    try {
      fixture = _loadFixture();
    } catch (_) {
      if (_isCurrent(request)) {
        _publish(
          const DoomAppState.failure(
            'Could not create the synthetic test map.',
          ),
        );
      }
      return;
    }
    await _load(
      fixture,
      request: request,
      setupMessage:
          'The default IWAD was not loaded. Set '
          '$kDoomWadPathEnvironment and restart to use another file.',
    );
  }

  /// Loads an IWAD selected explicitly by the user, including a browser file.
  Future<void> useSelectedIwad(
    Uint8List bytes, {
    String mapName = 'E1M1',
    String? sourceLabel,
  }) async {
    final DoomAppState retained = _state;
    final int request = ++_requestGeneration;
    _coordinator.cancel();
    DoomContentLoadResult result;
    try {
      result = _loadSelected(bytes, mapName: mapName, sourcePath: sourceLabel);
    } catch (_) {
      if (_isCurrent(request)) {
        _publishSelectionFailure(
          retained,
          'Unexpected error while reading the selected IWAD.',
        );
      }
      return;
    }
    if (!_isCurrent(request)) return;
    switch (result) {
      case DoomContentLoaded(:final content):
        await _load(content, request: request, retainOnFailure: retained);
      case DoomContentPathMissing():
        _publishSelectionFailure(retained, 'No browser IWAD was selected.');
      case DoomContentLoadFailure(:final message):
        _publishSelectionFailure(retained, message);
    }
  }

  void reportSelectedIwadFailure(String message) {
    if (_disposed) return;
    final DoomAppState retained = _state;
    _requestGeneration++;
    _coordinator.cancel();
    _publishSelectionFailure(retained, message);
  }

  Future<void> _load(
    DoomContent content, {
    required int request,
    String? setupMessage,
    DoomAppState? retainOnFailure,
  }) async {
    final outcome = await _coordinator.load(
      prepare: (token) => _prepare(content, token),
      assemble: (prepared) => prepared,
    );
    if (!_isCurrent(request)) {
      return;
    }
    switch (outcome) {
      case LevelPublished<PreparedDoomLevel>(:final level):
        _publish(
          DoomAppState.ready(
            level,
            phase: content.isFixture
                ? DoomAppPhase.fixtureReady
                : DoomAppPhase.developerIwadReady,
            setupMessage: setupMessage,
          ),
        );
      case LevelLoadFailed<PreparedDoomLevel>(:final error):
        final message = 'Could not prepare the level: $error';
        if (retainOnFailure == null) {
          _publish(DoomAppState.failure(message));
        } else {
          _publishSelectionFailure(retainOnFailure, message);
        }
      case LevelLoadStale<PreparedDoomLevel>():
        break;
    }
  }

  bool _isCurrent(int request) => !_disposed && request == _requestGeneration;

  void _publishSelectionFailure(DoomAppState retained, String message) {
    final level = retained.level;
    if (level == null ||
        (retained.phase != DoomAppPhase.fixtureReady &&
            retained.phase != DoomAppPhase.developerIwadReady)) {
      _publish(DoomAppState.failure(message));
      return;
    }
    _publish(
      DoomAppState.ready(
        level,
        phase: retained.phase,
        setupMessage: retained.setupMessage,
        errorMessage: message,
      ),
    );
  }

  void _publish(DoomAppState next) {
    if (_disposed) {
      return;
    }
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _requestGeneration++;
    _coordinator.cancel();
    super.dispose();
  }
}
