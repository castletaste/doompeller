import 'dart:io';

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln(
      'usage: dart run tool/finalize_wasm_web_build.dart BUILD_WEB',
    );
    exitCode = 64;
    return;
  }
  final Directory output = Directory(arguments.single);
  final File bootstrap = File('${output.path}/flutter_bootstrap.js');
  if (!bootstrap.existsSync()) {
    stderr.writeln('error: missing ${bootstrap.path}');
    exitCode = 1;
    return;
  }

  const String jsFallback =
      ',{"compileTarget":"dart2js","renderer":"canvaskit",'
      '"mainJsPath":"main.dart.js"}';
  final String source = bootstrap.readAsStringSync();
  if (!source.contains('"compileTarget":"dart2wasm"')) {
    stderr.writeln('error: flutter bootstrap has no dart2wasm build');
    exitCode = 1;
    return;
  }
  final int fallbackCount = jsFallback.allMatches(source).length;
  if (fallbackCount != 1) {
    stderr.writeln(
      'error: expected one pinned dart2js fallback, found $fallbackCount',
    );
    exitCode = 1;
    return;
  }
  bootstrap.writeAsStringSync(source.replaceFirst(jsFallback, ''));

  for (final String stalePath in <String>[
    '${output.path}/main.dart.js',
    '${output.path}/doom1.wad',
  ]) {
    final File stale = File(stalePath);
    if (stale.existsSync()) stale.deleteSync();
  }

  final String finalized = bootstrap.readAsStringSync();
  if (finalized.contains('"compileTarget":"dart2js"') ||
      File('${output.path}/main.dart.js').existsSync()) {
    stderr.writeln('error: dart2js fallback remains in the Wasm-only build');
    exitCode = 1;
    return;
  }
  stdout.writeln('Wasm-only bootstrap verified; dart2js fallback removed');
}
