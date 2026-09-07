import 'dart:convert';
import 'dart:io';

/// Runs app tests with Flutter's standard shader assets and without bundling
/// proprietary content. Use --include-content with DOOM_WAD_PATH for acceptance.
/// Resolve dependencies in the checkout before invoking this runner.
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
  final environment = <String, String>{};
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
    environment['DOOM_WAD_PATH'] = wad.path;
  }

  final scratch = Directory(
    Directory.systemTemp
        .createTempSync('doompeller-tests-')
        .resolveSymbolicLinksSync(),
  );
  try {
    // Copy code and configuration, including uncommitted work, so test tools
    // cannot rewrite the production manifest or publish local content.
    for (final name in ['lib', 'test', 'tool', 'packages', 'shaders', 'docs']) {
      final source = Directory('${root.path}/$name');
      if (source.existsSync()) {
        _copyDirectory(source, Directory('${scratch.path}/$name'));
      }
    }
    for (final name in [
      'pubspec.lock',
      'analysis_options.yaml',
      'dart_test.yaml',
    ]) {
      final source = File('${root.path}/$name');
      if (source.existsSync()) source.copySync('${scratch.path}/$name');
    }
    final manifest = File('${root.path}/pubspec.yaml').readAsStringSync();
    const localAsset = '    - .local/doom/DOOM1.WAD';
    if (!manifest.split('\n').contains(localAsset)) {
      throw StateError(
        'Update the test manifest projection after changing local IWAD packaging.',
      );
    }
    File('${scratch.path}/pubspec.yaml').writeAsStringSync(
      manifest.split('\n').where((line) => line != localAsset).join('\n'),
    );
    Directory('${scratch.path}/assets/shaders').createSync(recursive: true);
    Directory('${scratch.path}/.dart_tool').createSync();
    for (final entry in packages.cast<Map<String, dynamic>>()) {
      final original = packageConfig.uri.resolve(entry['rootUri'] as String);
      final relative = original.toFilePath().startsWith('${root.path}/')
          ? original.toFilePath().substring(root.path.length + 1)
          : null;
      entry['rootUri'] = relative == null
          ? original.toString()
          : scratch.uri.resolve(relative).toString();
    }
    File(
      '${scratch.path}/.dart_tool/package_config.json',
    ).writeAsStringSync(jsonEncode(config));
    final graph = File('${root.path}/.dart_tool/package_graph.json');
    if (graph.existsSync()) {
      graph.copySync('${scratch.path}/.dart_tool/package_graph.json');
    }
    final process = await Process.start(
      flutter,
      [
        'test',
        '--no-pub',
        if (!includeContent) ...['--exclude-tags', 'content'],
        ...testArguments,
      ],
      workingDirectory: scratch.path,
      environment: environment,
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await process.exitCode;
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

void _copyDirectory(Directory source, Directory destination) {
  destination.createSync(recursive: true);
  for (final entry in source.listSync(followLinks: false)) {
    final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
    if (['.dart_tool', 'build', '.local', 'coverage'].contains(name)) continue;
    final target = '${destination.path}/$name';
    if (entry is Directory) {
      _copyDirectory(entry, Directory(target));
    } else if (entry is File) {
      entry.copySync(target);
    }
  }
}
