import 'dart:typed_data';

final class BrowserWadSelection {
  const BrowserWadSelection({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

final class BrowserWadPickerFailure implements Exception {
  const BrowserWadPickerFailure(this.message);

  final String message;
}
