import 'dart:io';
import 'dart:typed_data';

Map<String, String> environment(String variableName, String localPath) {
  final result = Map<String, String>.of(Platform.environment);
  if ((result[variableName]?.trim().isEmpty ?? true) &&
      File(localPath).existsSync()) {
    result[variableName] = localPath;
  }
  return result;
}

bool get autoLoadFixtureWhenPathMissing => true;

String missingContentMessage(String variableName, String localPath) =>
    'Set $variableName or place DOOM1.WAD at $localPath.';

Future<Uint8List> readBytes(String path) => File(path).readAsBytes();

Future<int> readLength(String path) => File(path).length();

bool isFileReadFailure(Object error) => error is FileSystemException;
