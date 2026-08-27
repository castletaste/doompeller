import 'dart:typed_data';

import 'package:doom_wad/doom_wad.dart';

import 'content_source_platform_stub.dart'
    if (dart.library.io) 'content_source_platform_io.dart'
    if (dart.library.js_interop) 'content_source_platform_web.dart'
    as platform;

/// Environment variable used to override the default desktop IWAD.
const String kDoomWadPathEnvironment = 'DOOM_WAD_PATH';

/// Exact developer-local source packaged by Flutter for the default release.
/// Only this path is checked; no directory scan is performed.
const String kDocumentedLocalWadPath = '.local/doom/DOOM1.WAD';

enum DoomContentOrigin {
  /// A generated PWAD used by unit tests and renderer diagnostics.
  syntheticFixture,

  /// The developer's IWAD, loaded from the default bundle or an explicit path.
  developerIwad,
}

/// Parsed content held in memory. No lump or extracted image is written out.
final class DoomContent {
  const DoomContent({
    required this.wads,
    required this.mapName,
    required this.origin,
    this.sourcePath,
  });

  final WadSet wads;
  final String mapName;
  final DoomContentOrigin origin;
  final String? sourcePath;

  bool get isFixture => origin == DoomContentOrigin.syntheticFixture;
}

sealed class DoomContentLoadResult {
  const DoomContentLoadResult();
}

final class DoomContentLoaded extends DoomContentLoadResult {
  const DoomContentLoaded(this.content);

  final DoomContent content;
}

/// No default content path was available for this platform.
final class DoomContentPathMissing extends DoomContentLoadResult {
  const DoomContentPathMissing({
    this.autoLoadFixture = true,
    this.setupMessage =
        'Set DOOM_WAD_PATH or place DOOM1.WAD at '
        '.local/doom/DOOM1.WAD.',
  });

  final bool autoLoadFixture;
  final String setupMessage;
}

final class DoomContentLoadFailure extends DoomContentLoadResult {
  const DoomContentLoadFailure(this.message, {this.cause});

  final String message;
  final Object? cause;
}

typedef ReadWadBytes = Future<Uint8List> Function(String path);
typedef ReadWadLength = Future<int> Function(String path);

/// Resolves the default IWAD without scanning directories.
///
/// Desktop accepts [kDoomWadPathEnvironment] and the one exact ignored local
/// default. Web loads the release-bundled
/// `assets/.local/doom/DOOM1.WAD`; an explicitly selected replacement can
/// still enter through [loadIwadBytes]. Tests and the diagnostic scene use
/// [loadFixture].
final class DoomContentSource {
  DoomContentSource({
    Map<String, String>? environment,
    ReadWadBytes? readBytes,
    ReadWadLength? readLength,
    this.limits = DoomLimits.defaults,
  }) : _environment =
           environment ??
           platform.environment(
             kDoomWadPathEnvironment,
             kDocumentedLocalWadPath,
           ),
       _readBytes = readBytes ?? platform.readBytes,
       _readLength = readLength ?? platform.readLength;

  final Map<String, String> _environment;
  final ReadWadBytes _readBytes;
  final ReadWadLength _readLength;
  final DoomLimits limits;

  Future<DoomContentLoadResult> loadDeveloperIwad({
    String mapName = 'E1M1',
  }) async {
    final String? configured = _environment[kDoomWadPathEnvironment]?.trim();
    if (configured == null || configured.isEmpty) {
      return DoomContentPathMissing(
        autoLoadFixture: platform.autoLoadFixtureWhenPathMissing,
        setupMessage: platform.missingContentMessage(
          kDoomWadPathEnvironment,
          kDocumentedLocalWadPath,
        ),
      );
    }
    try {
      final int byteLength = await _readLength(configured);
      DoomLimits.check(byteLength, limits.maxWadBytes, 'maxWadBytes');
      final Uint8List bytes = await _readBytes(configured);
      // Recheck because the file may have changed between stat and read.
      return loadIwadBytes(bytes, mapName: mapName, sourcePath: configured);
    } on DoomFailure catch (error) {
      return DoomContentLoadFailure(error.message, cause: error);
    } on Object catch (error) {
      if (platform.isFileReadFailure(error)) {
        return DoomContentLoadFailure(
          'Could not read the file selected by $kDoomWadPathEnvironment.',
          cause: error,
        );
      }
      rethrow;
    }
  }

  /// Parses an explicitly user-selected IWAD already held in memory.
  ///
  /// This is the browser entry point: the DOM file picker supplies [bytes]
  /// directly, so no path, upload, cache or extracted resource is involved.
  DoomContentLoadResult loadIwadBytes(
    Uint8List bytes, {
    String mapName = 'E1M1',
    String? sourcePath,
  }) {
    final String selectedMap = mapName.trim().toUpperCase();
    if (!RegExp(r'^(E[1-9]M[1-9]|MAP[0-9]{2})$').hasMatch(selectedMap)) {
      return DoomContentLoadFailure('Invalid Doom map name "$selectedMap".');
    }
    try {
      DoomLimits.check(bytes.lengthInBytes, limits.maxWadBytes, 'maxWadBytes');
      final WadFile wad = WadFile.parse(bytes, limits: limits);
      if (wad.kind != WadKind.iwad) {
        return const DoomContentLoadFailure(
          'The selected file is a PWAD, not a standalone IWAD.',
        );
      }
      final WadSet set = WadSet(<WadFile>[wad]);
      if (!set.mapNames().contains(selectedMap)) {
        return DoomContentLoadFailure(
          'The selected IWAD does not contain $selectedMap.',
        );
      }
      return DoomContentLoaded(
        DoomContent(
          wads: set,
          mapName: selectedMap,
          origin: DoomContentOrigin.developerIwad,
          sourcePath: sourcePath,
        ),
      );
    } on DoomFailure catch (error) {
      return DoomContentLoadFailure(error.message, cause: error);
    }
  }

  DoomContent loadFixture() => DoomContent(
    wads: DoomFixtures.wadSet(),
    mapName: DoomFixtures.mapName,
    origin: DoomContentOrigin.syntheticFixture,
  );
}
