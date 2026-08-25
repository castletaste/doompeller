import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:doom_wad/doom_wad.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/wad_report.dart' as wad_report;

const String _dart = '/Users/savva/fvm/versions/stable/bin/dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('doompeller-wad-report-');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('wad report returns READY for the synthetic fixture', () async {
    final ProcessResult result = await _run(<String>[]);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('VERDICT: READY'));
    expect(result.stderr, isEmpty);
    _expectNoWadContent(result);
  });

  test('wad report JSON is structured and preserves the verdict', () async {
    final ProcessResult result = await _run(<String>['--json']);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stderr, isEmpty);
    final Map<String, Object?> report = _json(result);
    expect(report['verdict'], 'READY');
    expect(report['container'], isA<Map<String, Object?>>());
    expect(report['resources'], isA<Map<String, Object?>>());
    expect(report['mapCounts'], isA<Map<String, Object?>>());
    expect(report['geometry'], isA<Map<String, Object?>>());
    expect(report['timingsMs'], isA<Map<String, Object?>>());
    expect(report['missingTextures'], isEmpty);
    expect(report['missingFlats'], isEmpty);
    _expectNoWadContent(result);
  });

  test('explicit existing and missing map names have clear outcomes', () async {
    final String path = _write(temp, 'fixture.wad', DoomFixtures.pwadBytes());

    final ProcessResult existing = await _run(<String>[
      '--map',
      DoomFixtures.mapName,
      path,
    ]);
    expect(
      existing.exitCode,
      0,
      reason: '${existing.stdout}\n${existing.stderr}',
    );
    expect(existing.stdout, contains('VERDICT: READY'));
    expect(existing.stdout, contains('map MAP01:'));
    expect(existing.stderr, isEmpty);

    final ProcessResult missing = await _run(<String>['--map', 'MAP99', path]);
    expect(missing.exitCode, 1);
    expect(missing.stdout, isEmpty);
    expect(missing.stderr, contains('PROBLEMS:'));
    expect(missing.stderr, contains('MAP99'));
    _expectNoWadContent(missing);
  });

  test('missing referenced texture produces PROBLEMS and exit 1', () async {
    final String path = _write(
      temp,
      'missing-texture.wad',
      _fixtureWithMissingTexture(),
    );
    final ProcessResult result = await _run(<String>['--map', 'MAP01', path]);

    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    expect(
      result.stdout,
      contains('missing textures: MISSING'),
      reason: '${result.stdout}\n${result.stderr}',
    );
    expect(result.stdout, contains('VERDICT: PROBLEMS'));
    expect(result.stderr, isEmpty);

    final ProcessResult jsonResult = await _run(<String>[
      '--json',
      '--map',
      'MAP01',
      path,
    ]);
    expect(jsonResult.exitCode, 1);
    expect(jsonResult.stderr, isEmpty);
    expect(_json(jsonResult)['verdict'], 'PROBLEMS');
    _expectNoWadContent(result);
    _expectNoWadContent(jsonResult);
  });

  test(
    'missing path, directory, and unreadable path are human-readable',
    () async {
      final String missingPath = '${temp.path}/missing.wad';
      final ProcessResult missing = await _run(<String>[missingPath]);
      expect(missing.exitCode, 1);
      expect(missing.stdout, isEmpty);
      expect(missing.stderr, contains('does not exist'));

      final ProcessResult directory = await _run(<String>[temp.path]);
      expect(directory.exitCode, 1);
      expect(directory.stdout, isEmpty);
      expect(directory.stderr, contains('directory'));

      final String symlinkPath = '${temp.path}/link.wad';
      Link(symlinkPath).createSync(missingPath);
      final ProcessResult symlink = await _run(<String>[symlinkPath]);
      expect(symlink.exitCode, 1);
      expect(symlink.stdout, isEmpty);
      expect(symlink.stderr, contains('symlink'));

      final String unreadablePath = _write(
        temp,
        'unreadable.wad',
        DoomFixtures.pwadBytes(),
      );
      final ProcessResult chmod = await Process.run('/bin/chmod', <String>[
        '000',
        unreadablePath,
      ]);
      expect(chmod.exitCode, 0, reason: '${chmod.stdout}\n${chmod.stderr}');
      final ProcessResult unreadable = await _run(<String>[unreadablePath]);
      // An elevated test runner can still read mode-000 files. In that case the
      // deterministic missing/directory checks above remain the portable cases.
      if (unreadable.exitCode == 0) {
        expect(unreadable.stdout, contains('VERDICT: READY'));
      } else {
        expect(unreadable.stdout, isEmpty);
        expect(unreadable.stderr, contains('cannot read WAD'));
        expect(unreadable.exitCode, 1);
      }
    },
  );

  test(
    'empty, truncated, bad directory, and non-WAD files fail cleanly',
    () async {
      final String empty = _write(temp, 'empty.wad', Uint8List(0));
      final String truncated = _write(temp, 'truncated.wad', Uint8List(11));
      final Uint8List badDirectory = Uint8List.fromList(
        DoomFixtures.pwadBytes(),
      );
      final ByteData directoryView = ByteData.sublistView(badDirectory);
      directoryView.setInt32(8, badDirectory.length + 1, Endian.little);
      final String badDirectoryPath = _write(
        temp,
        'bad-directory.wad',
        badDirectory,
      );
      final Uint8List badSignature = Uint8List.fromList(
        DoomFixtures.pwadBytes(),
      );
      badSignature[0] = 0x4E; // N
      final String badSignaturePath = _write(
        temp,
        'bad-signature.wad',
        badSignature,
      );

      for (final (String path, String needle) in <(String, String)>[
        (empty, 'empty'),
        (truncated, 'shorter than'),
        (badDirectoryPath, 'WAD parse failed'),
        (badSignaturePath, 'WAD parse failed'),
      ]) {
        final ProcessResult result = await _run(<String>[path]);
        expect(
          result.exitCode,
          1,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, isEmpty);
        expect(result.stderr, contains(needle));
        expect(result.stderr, isNot(contains('StackTrace')));
        _expectNoWadContent(result);
      }
    },
  );

  test('oversized input is rejected before read with an injected limit', () {
    final String path = _write(temp, 'oversized.wad', DoomFixtures.pwadBytes());

    expect(
      () => wad_report.readWadBytes(path, maxWadBytes: 12),
      throwsA(
        isA<wad_report.WadReportInputFailure>().having(
          (wad_report.WadReportInputFailure error) => error.message,
          'message',
          contains('exceeds the 12 byte limit'),
        ),
      ),
    );
  });

  test(
    'JSON errors are one structured PROBLEMS record with nonzero exit',
    () async {
      final String path = _write(
        temp,
        'not-wad.bin',
        Uint8List.fromList(<int>[1, 2, 3, 4]),
      );
      final ProcessResult result = await _run(<String>['--json', path]);

      expect(result.exitCode, 1);
      expect(result.stderr, isEmpty);
      final Map<String, Object?> report = _json(result);
      expect(report, containsPair('tool', 'wad_report'));
      expect(report, containsPair('verdict', 'PROBLEMS'));
      expect(report['error'], isA<String>());
      expect(report.keys, containsAll(<String>['tool', 'verdict', 'error']));
      _expectNoWadContent(result);
    },
  );
}

Future<ProcessResult> _run(List<String> args) => Process.run(
  _dart,
  <String>['run', 'tool/wad_report.dart', ...args],
  workingDirectory: Directory.current.path,
  environment: <String, String>{'DOOM_WAD_PATH': ''},
);

String _write(Directory directory, String name, List<int> bytes) {
  final File file = File('${directory.path}/$name');
  file.writeAsBytesSync(bytes);
  return file.path;
}

Uint8List _fixtureWithMissingTexture() {
  final Uint8List bytes = Uint8List.fromList(DoomFixtures.pwadBytes());
  final WadFile wad = WadFile.parse(bytes);
  final int sideDefs = wad.indexOfLump('SIDEDEFS')!;
  final int payloadOffset = wad.lumps[sideDefs].offset;
  // Doom SIDEDEFS stores upper/lower/middle names at offsets 4/12/20.
  for (var i = 0; i < 8; i++) {
    bytes[payloadOffset + 20 + i] = i < 7 ? 'MISSING'.codeUnitAt(i) : 0;
  }
  return bytes;
}

Map<String, Object?> _json(ProcessResult result) {
  final Object? decoded = jsonDecode(result.stdout as String);
  expect(decoded, isA<Map<String, Object?>>());
  return decoded! as Map<String, Object?>;
}

void _expectNoWadContent(ProcessResult result) {
  final String fixtureHash = fnv1a64(
    DoomFixtures.pwadBytes(),
  ).toRadixString(16);
  expect(result.stdout, isNot(contains(fixtureHash)));
  expect(result.stderr, isNot(contains(fixtureHash)));
  expect(result.stdout, isNot(contains('PAT1')));
  expect(result.stderr, isNot(contains('PAT1')));
}
