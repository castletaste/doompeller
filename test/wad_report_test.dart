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
    expect(result.stdout, contains('VERDICT: READY\n'));
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
    expect(report['gameplay'], isA<Map<String, Object?>>());
    expect(report['timingsMs'], isA<Map<String, Object?>>());
    expect(report['missingTextures'], isEmpty);
    expect(report['missingFlats'], isEmpty);
    final Map<String, Object?> gameplay =
        report['gameplay']! as Map<String, Object?>;
    final Map<String, Object?> lineSpecials =
        gameplay['linedefSpecials']! as Map<String, Object?>;
    final Map<String, Object?> sectorSpecials =
        gameplay['sectorSpecials']! as Map<String, Object?>;
    final Map<String, Object?> things =
        gameplay['things']! as Map<String, Object?>;
    final Map<String, Object?> progression =
        gameplay['progression']! as Map<String, Object?>;
    final Map<String, Object?> sounds =
        gameplay['sounds']! as Map<String, Object?>;
    final Map<String, Object?> animations =
        gameplay['animationsAndSwitches']! as Map<String, Object?>;
    expect(lineSpecials['unsupported'], isEmpty);
    expect(sectorSpecials['unsupported'], isEmpty);
    expect(things['playerStarts'], 1);
    expect(things['cooperativeStarts'], 1);
    expect(things['deathmatchStarts'], 0);
    expect(things['unknownTypes'], isEmpty);
    expect(progression['hasExit'], isTrue);
    expect(sounds['missing'], isEmpty);
    expect(animations['wad'], isA<Map<String, Object?>>());
    expect(animations['map'], isA<Map<String, Object?>>());
    _expectNoWadContent(result);
  });

  test('wad report proves the synthetic E1M1-scale fixture is READY', () async {
    final ProcessResult result = await _run(<String>[
      '--json',
      '--scale-fixture',
    ]);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stderr, isEmpty);
    final Map<String, Object?> report = _json(result);
    expect(report['source'], 'synthetic_e1m1_scale_fixture');
    expect(report['verdict'], 'READY');
    final Map<String, Object?> counts =
        report['mapCounts']! as Map<String, Object?>;
    expect(counts['linedefs'], greaterThanOrEqualTo(470));
    expect(counts['sectors'], greaterThanOrEqualTo(90));
    final Map<String, Object?> geometry =
        report['geometry']! as Map<String, Object?>;
    expect(geometry['fallbackSectorCount'], 0);
    final Map<String, Object?> gameplay =
        report['gameplay']! as Map<String, Object?>;
    final Map<String, Object?> sounds =
        gameplay['sounds']! as Map<String, Object?>;
    expect(sounds['missing'], isNotEmpty);
  });

  test(
    'gameplay gaps name unsupported specials and difficulty-missing keys',
    () async {
      final String path = _write(
        temp,
        'gameplay-gaps.wad',
        _fixtureWithGameplayGaps(),
      );

      final ProcessResult result = await _run(<String>[
        '--json',
        '--map',
        DoomFixtures.mapName,
        path,
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stderr, isEmpty);
      final Map<String, Object?> report = _json(result);
      expect(report['verdict'], 'READY WITH GAPS');
      final Map<String, Object?> gameplay =
          report['gameplay']! as Map<String, Object?>;
      final Map<String, Object?> lineSpecials =
          gameplay['linedefSpecials']! as Map<String, Object?>;
      final Map<String, Object?> progression =
          gameplay['progression']! as Map<String, Object?>;
      expect(lineSpecials['unsupported'], <Object?>[
        <String, Object?>{'number': 999, 'count': 1},
      ]);
      expect(progression['lockedDoorSpecials'], <Object?>[
        <String, Object?>{'number': 26, 'count': 1},
      ]);
      final Map<String, Object?> missing =
          progression['missingKeysBySkill']! as Map<String, Object?>;
      expect(missing['easy'], <String>['blue']);
      expect(missing['medium'], <String>['blue']);
      expect(missing['hard'], isEmpty);
      _expectNoWadContent(result);
    },
  );

  test('unknown thing types downgrade READY to READY WITH GAPS', () async {
    final String path = _write(
      temp,
      'unknown-thing.wad',
      _fixtureWithUnknownThing(),
    );

    final ProcessResult result = await _run(<String>[
      '--json',
      '--map',
      DoomFixtures.mapName,
      path,
    ]);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stderr, isEmpty);
    final Map<String, Object?> report = _json(result);
    expect(report['verdict'], 'READY WITH GAPS');
    final Map<String, Object?> gameplay =
        report['gameplay']! as Map<String, Object?>;
    final Map<String, Object?> things =
        gameplay['things']! as Map<String, Object?>;
    expect(things['unknownTypes'], <Object?>[
      <String, Object?>{'number': 9999, 'count': 1},
    ]);
    _expectNoWadContent(result, bytes: _fixtureWithUnknownThing());
  });

  test(
    'deathmatch start is known format metadata, not a spawned actor',
    () async {
      final String path = _write(
        temp,
        'deathmatch-start.wad',
        _fixtureWithThingType(11),
      );
      final ProcessResult result = await _run(<String>[
        '--json',
        '--map',
        DoomFixtures.mapName,
        path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final Map<String, Object?> gameplay =
          _json(result)['gameplay']! as Map<String, Object?>;
      final Map<String, Object?> things =
          gameplay['things']! as Map<String, Object?>;
      expect(things['deathmatchStarts'], 1);
      expect(things['unknownTypes'], isEmpty);
      expect(things['knownNonSpawning'], 1);
      _expectNoWadContent(result, bytes: _fixtureWithThingType(11));
    },
  );

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

Uint8List _fixtureWithGameplayGaps() {
  final Uint8List bytes = Uint8List.fromList(DoomFixtures.pwadBytes());
  final WadFile wad = WadFile.parse(bytes);
  final ByteData data = ByteData.sublistView(bytes);
  final int linedefsOffset = wad.lumps[wad.indexOfLump('LINEDEFS')!].offset;
  // Linedefs are 14 bytes; special is the uint16 at byte 6.
  data
    ..setUint16(linedefsOffset + 6, 999, Endian.little)
    ..setUint16(linedefsOffset + 14 + 6, 26, Endian.little);
  final int thingsOffset = wad.lumps[wad.indexOfLump('THINGS')!].offset;
  // THINGS are 10 bytes; entry 1 becomes a blue key only on hard skill.
  data
    ..setUint16(thingsOffset + 10 + 6, 5, Endian.little)
    ..setUint16(thingsOffset + 10 + 8, 4, Endian.little);
  return bytes;
}

Uint8List _fixtureWithUnknownThing() {
  return _fixtureWithThingType(9999);
}

Uint8List _fixtureWithThingType(int type) {
  final Uint8List bytes = Uint8List.fromList(DoomFixtures.pwadBytes());
  final WadFile wad = WadFile.parse(bytes);
  final int thingsOffset = wad.lumps[wad.indexOfLump('THINGS')!].offset;
  // Replace the fixture's cooperative start with an actor the runtime cannot
  // spawn. The report must surface the unknown type as a progression gap.
  ByteData.sublistView(
    bytes,
  ).setUint16(thingsOffset + 10 + 6, type, Endian.little);
  return bytes;
}

Map<String, Object?> _json(ProcessResult result) {
  final Object? decoded = jsonDecode(result.stdout as String);
  expect(decoded, isA<Map<String, Object?>>());
  return decoded! as Map<String, Object?>;
}

void _expectNoWadContent(ProcessResult result, {Uint8List? bytes}) {
  final Uint8List wadBytes = bytes ?? DoomFixtures.pwadBytes();
  final String fixtureHash = fnv1a64(wadBytes).toRadixString(16);
  final String output = '${result.stdout}\n${result.stderr}';
  expect(result.stdout, isNot(contains(fixtureHash)));
  expect(result.stderr, isNot(contains(fixtureHash)));
  // Dynamic tripwire: reject long raw-byte windows in common dump encodings.
  // Unlike checking one known lump name, this follows any fixture mutation and
  // catches whole-WAD or partial payload disclosure as hex, base64, or arrays.
  const int window = 24;
  for (var offset = 0; offset + window <= wadBytes.length; offset += window) {
    final List<int> chunk = wadBytes.sublist(offset, offset + window);
    final String hex = chunk
        .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    expect(output, isNot(contains(hex)), reason: 'hex WAD bytes at $offset');
    expect(
      output,
      isNot(contains(base64Encode(chunk))),
      reason: 'base64 WAD bytes at $offset',
    );
    expect(
      output,
      isNot(contains(chunk.join(','))),
      reason: 'compact byte array at $offset',
    );
    expect(
      output,
      isNot(contains(chunk.join(', '))),
      reason: 'byte array at $offset',
    );
  }
}
