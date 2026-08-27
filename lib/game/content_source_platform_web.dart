import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

const String _bundledIwadPath = 'doom1.wad';
const int _expectedIwadBytes = 4196020;

final Map<String, Future<Uint8List>> _downloads = <String, Future<Uint8List>>{};

Map<String, String> environment(String variableName, String localPath) =>
    <String, String>{variableName: _bundledIwadPath};

bool get autoLoadFixtureWhenPathMissing => false;

String missingContentMessage(String variableName, String localPath) =>
    'The bundled DOOM1.WAD could not be loaded.';

Future<Uint8List> readBytes(String path) =>
    _downloads.putIfAbsent(path, () => _fetchBytes(path));

Future<int> readLength(String path) async => (await readBytes(path)).length;

bool isFileReadFailure(Object error) => error is _BundledIwadReadFailure;

Future<Uint8List> _fetchBytes(String path) async {
  try {
    final web.Response response = await web.window.fetch(path.toJS).toDart;
    if (!response.ok) {
      throw _BundledIwadReadFailure(
        'HTTP ${response.status} while loading $path.',
      );
    }
    final ByteBuffer buffer = (await response.arrayBuffer().toDart).toDart;
    final Uint8List bytes = buffer.asUint8List();
    if (bytes.lengthInBytes != _expectedIwadBytes) {
      throw _BundledIwadReadFailure(
        'Expected $_expectedIwadBytes bytes, received ${bytes.lengthInBytes}.',
      );
    }
    return bytes;
  } on _BundledIwadReadFailure {
    rethrow;
  } on Object catch (error) {
    throw _BundledIwadReadFailure('Could not load $path.', cause: error);
  }
}

final class _BundledIwadReadFailure implements Exception {
  const _BundledIwadReadFailure(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}
