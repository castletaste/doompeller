import 'dart:io';
import 'dart:typed_data';

Map<String, String> environment(String variableName, String localPath) {
  final result = Map<String, String>.of(Platform.environment);
  if (result[variableName]?.trim().isNotEmpty ?? false) return result;
  if (File(localPath).existsSync()) {
    result[variableName] = localPath;
    return result;
  }
  final String separator = Platform.pathSeparator;
  final String assetPath = localPath.replaceAll('/', separator);
  final String contentsPath = File(
    Platform.resolvedExecutable,
  ).parent.parent.path;
  final String bundledPath = <String>[
    contentsPath,
    'Frameworks',
    'App.framework',
    'Resources',
    'flutter_assets',
    assetPath,
  ].join(separator);
  if (File(bundledPath).existsSync()) {
    result[variableName] = bundledPath;
  }
  return result;
}

bool get autoLoadFixtureWhenPathMissing => false;

String missingContentMessage(String variableName, String localPath) =>
    'The bundled DOOM1.WAD is missing. Rebuild with $localPath available or '
    'set $variableName.';

Future<Uint8List> readBytes(String path) => File(path).readAsBytes();

Future<int> readLength(String path) => File(path).length();

bool isFileReadFailure(Object error) => error is FileSystemException;
