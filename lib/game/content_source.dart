import 'dart:io';
import 'dart:typed_data';

import 'package:doom_wad/doom_wad.dart';

/// Environment variable used for the developer's legally obtained Doom IWAD.
const String kDoomWadPathEnvironment = 'DOOM_WAD_PATH';

/// The documented local location. It is guidance only: the runtime never scans
/// or reads it implicitly, so a build cannot accidentally package local data.
const String kDocumentedLocalWadPath = '.local/doom/DOOM.WAD';

enum DoomContentOrigin {
  /// A generated, legally clean PWAD used by tests and renderer diagnostics.
  syntheticFixture,

  /// The developer's own IWAD, explicitly selected through DOOM_WAD_PATH.
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

/// The app has no content until the developer explicitly supplies a path.
final class DoomContentPathMissing extends DoomContentLoadResult {
  const DoomContentPathMissing();

  String get setupMessage =>
      'Set $kDoomWadPathEnvironment to your legally obtained DOOM.WAD. '
      'Recommended local path: $kDocumentedLocalWadPath';
}

final class DoomContentLoadFailure extends DoomContentLoadResult {
  const DoomContentLoadFailure(this.message, {this.cause});

  final String message;
  final Object? cause;
}

typedef ReadWadBytes = Future<Uint8List> Function(String path);
typedef ReadWadLength = Future<int> Function(String path);

/// Resolves developer content without scanning the filesystem or downloading
/// anything.
///
/// The only real-IWAD entry point is [kDoomWadPathEnvironment]. Tests and the
/// built-in diagnostic scene call [loadFixture], which is generated in Dart
/// and contains no commercial bytes.
final class DoomContentSource {
  DoomContentSource({
    Map<String, String>? environment,
    ReadWadBytes? readBytes,
    ReadWadLength? readLength,
    this.limits = DoomLimits.defaults,
  }) : _environment = environment ?? Platform.environment,
       _readBytes = readBytes ?? _fileBytes,
       _readLength = readLength ?? _fileLength;

  final Map<String, String> _environment;
  final ReadWadBytes _readBytes;
  final ReadWadLength _readLength;
  final DoomLimits limits;

  Future<DoomContentLoadResult> loadDeveloperIwad({
    String mapName = 'E1M1',
  }) async {
    final String? configured = _environment[kDoomWadPathEnvironment]?.trim();
    if (configured == null || configured.isEmpty) {
      return const DoomContentPathMissing();
    }
    final String selectedMap = mapName.trim().toUpperCase();
    if (!RegExp(r'^(E[1-9]M[1-9]|MAP[0-9]{2})$').hasMatch(selectedMap)) {
      return DoomContentLoadFailure('Invalid Doom map name "$selectedMap".');
    }

    try {
      final int byteLength = await _readLength(configured);
      DoomLimits.check(byteLength, limits.maxWadBytes, 'maxWadBytes');
      final Uint8List bytes = await _readBytes(configured);
      // Recheck because the file may have changed between stat and read.
      DoomLimits.check(bytes.lengthInBytes, limits.maxWadBytes, 'maxWadBytes');
      final WadFile wad = WadFile.parse(bytes, limits: limits);
      if (wad.kind != WadKind.iwad) {
        return DoomContentLoadFailure(
          'The file selected by $kDoomWadPathEnvironment is a PWAD, not a '
          'standalone IWAD.',
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
          sourcePath: configured,
        ),
      );
    } on DoomFailure catch (error) {
      return DoomContentLoadFailure(error.message, cause: error);
    } on FileSystemException catch (error) {
      return DoomContentLoadFailure(
        'Could not read the file selected by $kDoomWadPathEnvironment.',
        cause: error,
      );
    }
  }

  DoomContent loadFixture() => DoomContent(
    wads: DoomFixtures.wadSet(),
    mapName: DoomFixtures.mapName,
    origin: DoomContentOrigin.syntheticFixture,
  );

  static Future<Uint8List> _fileBytes(String path) => File(path).readAsBytes();

  static Future<int> _fileLength(String path) => File(path).length();
}
