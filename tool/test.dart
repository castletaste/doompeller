import 'dart:convert';
import 'dart:io';

/// Runs app tests in the checkout without bundling proprietary content.
///
/// Flutter validates every manifest asset before starting a test. The release
/// manifest intentionally names the developer-only IWAD and generated shader
/// directory, so synthetic tests create empty, temporary placeholders for those
/// two paths instead of copying the project or rewriting its manifest. The
/// placeholders are removed before this process exits.
///
/// Use --include-content with DOOM_WAD_PATH for original-content acceptance.
Future<void> main(List<String> arguments) async {
  final includeContent = arguments.contains('--include-content');
  final testArguments = arguments
      .where((arg) => arg != '--include-content')
      .toList();
  final root = File.fromUri(Platform.script).parent.parent;
  final packageConfig = File('${root.path}/.dart_tool/package_config.json');
  if (!packageConfig.existsSync()) {
    stderr.writeln('Run flutter pub get before tool/test.dart.');
    exitCode = 1;
    return;
  }
  final config =
      jsonDecode(packageConfig.readAsStringSync()) as Map<String, dynamic>;
  final packages = config['packages'] as List<dynamic>;
  final flutterPackage = packages.cast<Map<String, dynamic>>().singleWhere(
    (p) => p['name'] == 'flutter',
  );
  final flutterRoot = Directory.fromUri(
    packageConfig.uri.resolve(flutterPackage['rootUri'] as String),
  ).uri;
  final flutter =
      Platform.environment['FLUTTER'] ??
      flutterRoot.resolve('../../bin/flutter').toFilePath();
  File? requestedWad;
  if (includeContent) {
    final configured = Platform.environment['DOOM_WAD_PATH'];
    final wad = File(
      configured == null || configured.isEmpty
          ? '${root.path}/.local/doom/DOOM1.WAD'
          : configured,
    ).absolute;
    if (!wad.existsSync()) {
      stderr.writeln(
        '--include-content requires DOOM_WAD_PATH pointing to your local DOOM1.WAD.',
      );
      exitCode = 1;
      return;
    }
    requestedWad = wad;
  }

  final created = <File>[];
  final createdDirectories = <Directory>[];
  final manifestWad = File('${root.path}/.local/doom/DOOM1.WAD');
  File? movedManifestWad;
  try {
    // Never let a developer's original WAD enter the synthetic test asset
    // bundle. Move it aside for the duration of the run and restore it in the
    // finally block. Content tests read the moved path directly when needed.
    if (manifestWad.existsSync()) {
      final backup = File('${manifestWad.path}.test-backup');
      if (backup.existsSync()) {
        throw StateError(
          'A previous test run left ${backup.path}; restore it before testing.',
        );
      }
      manifestWad.renameSync(backup.path);
      movedManifestWad = backup;
    }
    _ensureDirectory(
      Directory('${root.path}/assets/shaders'),
      createdDirectories,
    );
    if (!manifestWad.existsSync()) {
      _ensureDirectory(manifestWad.parent, createdDirectories);
      manifestWad.writeAsBytesSync(const <int>[]);
      created.add(manifestWad);
    }
    final environment = <String, String>{
      if (requestedWad != null)
        'DOOM_WAD_PATH':
            requestedWad.path == manifestWad.path && movedManifestWad != null
            ? movedManifestWad.path
            : requestedWad.path,
    };
    final process = await Process.start(
      flutter,
      [
        'test',
        '--no-pub',
        if (!includeContent) ...['--exclude-tags', 'content'],
        ...testArguments,
      ],
      workingDirectory: root.path,
      environment: environment,
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await process.exitCode;
  } finally {
    for (final file in created.reversed) {
      if (file.existsSync()) file.deleteSync();
    }
    if (movedManifestWad != null && movedManifestWad.existsSync()) {
      movedManifestWad.renameSync(manifestWad.path);
    }
    for (final directory in createdDirectories.reversed) {
      if (directory.existsSync() && directory.listSync().isEmpty) {
        directory.deleteSync();
      }
    }
  }
}

void _ensureDirectory(Directory directory, List<Directory> created) {
  if (directory.existsSync()) return;
  final missing = <Directory>[];
  var current = directory;
  while (!current.existsSync()) {
    missing.add(current);
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  for (final item in missing.reversed) {
    item.createSync();
    created.add(item);
  }
}
