import 'dart:typed_data';

Map<String, String> environment(String variableName, String localPath) =>
    const <String, String>{};

bool get autoLoadFixtureWhenPathMissing => false;

String missingContentMessage(String variableName, String localPath) =>
    'The default IWAD is unavailable on this platform.';

Future<Uint8List> readBytes(String path) =>
    Future<Uint8List>.error(UnsupportedError('File paths are unavailable.'));

Future<int> readLength(String path) =>
    Future<int>.error(UnsupportedError('File paths are unavailable.'));

bool isFileReadFailure(Object error) => error is UnsupportedError;
