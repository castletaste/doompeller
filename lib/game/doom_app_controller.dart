import 'package:flutter/foundation.dart';
import 'package:doom_core/doom_core.dart';

import 'content_source.dart';
import 'browser_wad_selection.dart';
import 'doom_app_state.dart';
import 'level_load_coordinator.dart';
import 'level_preparer.dart';

export 'doom_app_state.dart';

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
  factory DoomAppController({
    DoomContentSource? contentSource,
    DoomLevelPreparer? preparer,
    LoadDeveloperContent? loadDeveloper,
    LoadFixtureContent? loadFixture,
    LoadSelectedContent? loadSelected,
    PrepareDoomLevel? prepare,
    DoomAppState initialState = const DoomAppState.loading(),
  }) {
    final source = contentSource ?? DoomContentSource();
    return DoomAppController._(
      loadDeveloper ?? source.loadDeveloperIwad,
      loadFixture ?? source.loadFixture,
      loadSelected ?? source.loadIwadBytes,
      prepare ?? (preparer ?? DoomLevelPreparer()).prepare,
      initialState,
    );
  }

  DoomAppController._(
    this._loadDeveloper,
    this._loadFixture,
    this._loadSelected,
    this._prepare,
    this._state,
  );

  final LoadDeveloperContent _loadDeveloper;
  final LoadFixtureContent _loadFixture;
  final LoadSelectedContent _loadSelected;
  final PrepareDoomLevel _prepare;
  final LevelLoadCoordinator<PreparedDoomLevel, PreparedDoomLevel>
  _coordinator = LevelLoadCoordinator<PreparedDoomLevel, PreparedDoomLevel>();

  DoomAppState _state;
  int _requestGeneration = 0;
  bool _disposed = false;
  int? _transitionRequest;

  DoomAppState get state => _state;

  /// Keep the completed level mounted until the successor is fully prepared.
  /// A failed load is retryable; a newer start/import invalidates this request.
  Future<void> advanceLevel(PreparedDoomLevel from, LevelExit exit) async {
    if (_disposed ||
        !identical(_state.level, from) ||
        exit.mapName != from.map.name ||
        _transitionRequest == _requestGeneration) {
      return;
    }
    final String? next = DoomEpisode.nextMap(exit.mapName, secret: exit.secret);
    if (next == null) return;
    final DoomAppState retained = _state;
    final int request = ++_requestGeneration;
    _transitionRequest = request;
    final DoomContent content = DoomContent(
      wads: from.content.wads,
      mapName: next,
      origin: from.content.origin,
      sourcePath: from.content.sourcePath,
    );
    try {
      await _load(
        content,
        request: request,
        retainOnFailure: retained,
        entryLoadout: exit.loadout,
      );
    } finally {
      if (_transitionRequest == request) _transitionRequest = null;
    }
  }

  Future<void> start() async {
    if (_disposed) return;
    final int request = ++_requestGeneration;
    _coordinator.cancel();
    _publish(const DoomAppState.loading());
    if (!_isCurrent(request)) return;
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
    if (_disposed) return;
    final int request = ++_requestGeneration;
    _coordinator.cancel();
    _publish(const DoomAppState.loading());
    if (!_isCurrent(request)) return;
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
    if (_disposed) return;
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

  /// Owns the complete selection request, including the native chooser gap.
  /// [isOwnerActive] fences an embedding widget without disposing an injected
  /// controller that may outlive that widget.
  Future<void> pickIwad(
    Future<BrowserWadSelection?> Function() picker, {
    required bool Function() isOwnerActive,
  }) async {
    if (_disposed || !isOwnerActive()) return;
    final request = ++_requestGeneration;
    _coordinator.cancel();
    bool current() => _isCurrent(request) && isOwnerActive();
    try {
      final selection = await picker();
      if (selection == null || !current()) return;
      await useSelectedIwad(selection.bytes, sourceLabel: selection.name);
    } on BrowserWadPickerFailure catch (error) {
      if (current()) reportSelectedIwadFailure(error.message);
    } on Object {
      if (current()) {
        reportSelectedIwadFailure(
          'The browser could not open the selected IWAD.',
        );
      }
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
    PlayerLoadout? entryLoadout,
  }) async {
    // Injected sources and listeners may synchronously start another request.
    // A stale caller must not advance the coordinator generation.
    if (!_isCurrent(request)) return;
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
            entryLoadout == null ? level : level.withEntryLoadout(entryLoadout),
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
    _coordinator.detachActive();
    super.dispose();
  }
}
