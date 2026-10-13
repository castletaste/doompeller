import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:doom_core/doom_core.dart';

import 'content_source.dart';
import 'browser_wad_selection.dart';
import 'doom_app_state.dart';
import 'generation_fence.dart';
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

enum _ContentLoadMode { startup, selection }

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
  final LevelLoadCoordinator<PreparedDoomLevel> _coordinator =
      LevelLoadCoordinator<PreparedDoomLevel>();

  DoomAppState _state;
  // Fences app-level source reads and publication decisions. It is separate
  // from the coordinator generation because a request can be superseded
  // before it starts CPU preparation.
  final GenerationFence _requestFence = GenerationFence();
  // Fences browser chooser results only; opening or dismissing a chooser does
  // not cancel the current level preparation.
  final GenerationFence _pickerFence = GenerationFence();
  bool _disposed = false;
  int? _transitionRequest;

  DoomAppState get state => _state;

  /// Keep the completed level mounted until the successor is fully prepared.
  /// A failed load is retryable; a newer start/import invalidates this request.
  Future<void> advanceLevel(PreparedDoomLevel from, LevelExit exit) async {
    if (_disposed ||
        !identical(_state.level, from) ||
        exit.mapName != from.map.name ||
        _transitionRequest == _requestFence.current) {
      return;
    }
    final String? next = DoomEpisode.nextMap(exit.mapName, secret: exit.secret);
    if (next == null) return;
    final DoomAppState retained = _state;
    final int request = _beginLoad();
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
    final int request = _beginLoad(showLoading: true);
    if (!_isCurrent(request)) return;
    final result = await _readContent(
      request: request,
      mode: _ContentLoadMode.startup,
      read: _loadDeveloper,
    );
    if (result == null) return;
    await _applyContentResult(
      result,
      request: request,
      mode: _ContentLoadMode.startup,
    );
  }

  Future<void> useFixtureFallback() async {
    if (_disposed) return;
    final int request = _beginLoad(showLoading: true);
    if (!_isCurrent(request)) return;
    final fixture = _tryLoadFixture(request);
    if (fixture == null) return;
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
    final int request = _beginLoad();
    final result = await _readContent(
      request: request,
      mode: _ContentLoadMode.selection,
      retained: retained,
      read: () =>
          _loadSelected(bytes, mapName: mapName, sourcePath: sourceLabel),
    );
    if (result == null) return;
    await _applyContentResult(
      result,
      request: request,
      mode: _ContentLoadMode.selection,
      retained: retained,
    );
  }

  /// Owns the complete selection request, including the native chooser gap.
  /// [isOwnerActive] fences an embedding widget without disposing an injected
  /// controller that may outlive that widget.
  Future<void> pickIwad(
    Future<BrowserWadSelection?> Function() picker, {
    required bool Function() isOwnerActive,
  }) async {
    if (_disposed || !isOwnerActive()) return;
    // Opening or cancelling a chooser does not cancel an existing level load.
    // A later chooser still supersedes an earlier chooser, while any explicit
    // load invalidates both through the main request generation.
    final request = _requestFence.current;
    final pickerRequest = _pickerFence.issue();
    bool current() =>
        _isCurrent(request) &&
        _pickerFence.isCurrent(pickerRequest) &&
        isOwnerActive();
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
    _invalidateLoad();
    _publishSelectionFailure(retained, message);
  }

  Future<DoomContentLoadResult?> _readContent({
    required int request,
    required _ContentLoadMode mode,
    required FutureOr<DoomContentLoadResult> Function() read,
    DoomAppState? retained,
  }) async {
    try {
      final result = await read();
      return _isCurrent(request) ? result : null;
    } catch (_) {
      if (!_isCurrent(request)) return null;
      final String message = switch (mode) {
        _ContentLoadMode.startup =>
          'Unexpected error while loading the configured developer IWAD.',
        _ContentLoadMode.selection =>
          'Unexpected error while reading the selected IWAD.',
      };
      if (retained == null) {
        _publish(DoomAppState.failure(message));
      } else {
        _publishSelectionFailure(retained, message);
      }
      return null;
    }
  }

  Future<void> _applyContentResult(
    DoomContentLoadResult result, {
    required int request,
    required _ContentLoadMode mode,
    DoomAppState? retained,
  }) async {
    switch (result) {
      case DoomContentLoaded(:final content):
        await _load(content, request: request, retainOnFailure: retained);
      case DoomContentPathMissing(:final setupMessage, :final autoLoadFixture):
        if (mode == _ContentLoadMode.selection) {
          _publishSelectionFailure(retained!, 'No browser IWAD was selected.');
          return;
        }
        if (!autoLoadFixture) {
          _publish(DoomAppState.failure(setupMessage));
          return;
        }
        final fixture = _tryLoadFixture(request);
        if (fixture == null) return;
        await _load(fixture, request: request, setupMessage: setupMessage);
      case DoomContentLoadFailure(:final message):
        if (mode == _ContentLoadMode.selection) {
          _publishSelectionFailure(retained!, message);
        } else {
          _publish(DoomAppState.failure(message));
        }
    }
  }

  DoomContent? _tryLoadFixture(int request) {
    try {
      return _loadFixture();
    } catch (_) {
      if (_isCurrent(request)) {
        _publish(
          const DoomAppState.failure(
            'Could not create the synthetic test map.',
          ),
        );
      }
      return null;
    }
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
    );
    if (!_isCurrent(request)) {
      return;
    }
    switch (outcome) {
      case LevelPublished<PreparedDoomLevel>(:final level):
        _publish(
          DoomAppState.ready(
            entryLoadout == null ? level : level.withEntryLoadout(entryLoadout),
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
        // This controller's request is still current. A shared preparer may
        // nevertheless displace its pending job on behalf of another owner.
        // Give this owner a retryable terminal state instead of a stuck spinner.
        _publishSelectionFailure(
          retainOnFailure ?? _state,
          'Level preparation was superseded by another load. Try again.',
        );
    }
  }

  bool _isCurrent(int request) =>
      !_disposed && _requestFence.isCurrent(request);

  int _beginLoad({bool showLoading = false}) {
    final int request = _requestFence.issue();
    _coordinator.cancel();
    if (showLoading) {
      _publish(const DoomAppState.loading());
    }
    return request;
  }

  void _invalidateLoad() {
    _requestFence.invalidate();
    _coordinator.cancel();
  }

  void _publishSelectionFailure(DoomAppState retained, String message) {
    final level = retained.level;
    if (level == null) {
      _publish(DoomAppState.failure(message));
      return;
    }
    _publish(
      DoomAppState.ready(
        level,
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
    _requestFence.close();
    _pickerFence.close();
    _coordinator.cancel();
    super.dispose();
  }
}
