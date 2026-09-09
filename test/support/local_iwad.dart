import 'dart:io';
import 'dart:typed_data';

/// Content acceptance is opt-in and reads only the developer's local WAD.
/// Tests do not depend on the application's asset packaging or copy the IWAD.
Future<ByteData> loadLocalIwad(String fallbackPath) async {
  final configured = Platform.environment['DOOM_WAD_PATH'];
  final path = configured == null || configured.isEmpty
      ? fallbackPath
      : configured;
  final file = File(path);
  if (!await file.exists()) {
    throw StateError(
      'Content acceptance requires DOOM_WAD_PATH pointing to a local DOOM1.WAD. Run tool/test.dart for synthetic tests.',
    );
  }
  return ByteData.sublistView(await file.readAsBytes());
}
