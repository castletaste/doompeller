// Headless, read-only WAD and geometry report.
//
// This tool deliberately keeps all WAD bytes in memory. It never extracts or
// writes Doom content, which keeps a developer-local IWAD outside the source
// tree and all build artifacts.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:doom_core/doom_core.dart';
import 'package:doom_geometry/doom_geometry.dart';
import 'package:doom_wad/doom_wad.dart';

const String _wadPathEnvironment = 'DOOM_WAD_PATH';
const int _okExitCode = 0;
const int _problemExitCode = 1;
const int _usageExitCode = 2;
const int _uint16VertexLimit = DoomVertexAbi.maxVerticesPerMesh;
const int defaultMaxWadBytes = 256 * 1024 * 1024;

/// A human-readable failure from the file-system preflight.
class WadReportInputFailure implements Exception {
  const WadReportInputFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads a regular WAD file after checking its type and size.
///
/// [maxWadBytes] is injectable so callers can exercise the same bounded-read
/// path with a tiny limit, without allocating a 256 MiB test file.
Uint8List readWadBytes(String path, {int maxWadBytes = defaultMaxWadBytes}) {
  if (maxWadBytes < 0) {
    throw ArgumentError.value(maxWadBytes, 'maxWadBytes');
  }

  final FileSystemEntityType type;
  try {
    type = FileSystemEntity.typeSync(path, followLinks: false);
  } on FileSystemException catch (error) {
    throw WadReportInputFailure(
      'cannot inspect WAD path "$path": ${error.message}',
    );
  }

  switch (type) {
    case FileSystemEntityType.notFound:
      throw WadReportInputFailure('WAD file does not exist: "$path"');
    case FileSystemEntityType.link:
      throw WadReportInputFailure(
        'WAD path is a symlink; provide the regular file directly: "$path"',
      );
    case FileSystemEntityType.directory:
      throw WadReportInputFailure(
        'WAD path is a directory, expected a regular file: "$path"',
      );
    case FileSystemEntityType.file:
      break;
    case FileSystemEntityType.pipe:
    case FileSystemEntityType.unixDomainSock:
      throw WadReportInputFailure(
        'WAD path is not a regular file ($type): "$path"',
      );
  }

  final File file = File(path);
  final int length;
  try {
    length = file.lengthSync();
  } on FileSystemException catch (error) {
    throw WadReportInputFailure(
      'cannot determine WAD size for "$path": ${error.message}',
    );
  }
  if (length == 0) {
    throw WadReportInputFailure('WAD file is empty: "$path"');
  }
  if (length < kWadHeaderBytes) {
    throw WadReportInputFailure(
      'WAD file is $length bytes, shorter than the $kWadHeaderBytes byte header: '
      '"$path"',
    );
  }
  if (length > maxWadBytes) {
    throw WadReportInputFailure(
      'WAD file is $length bytes, exceeds the $maxWadBytes byte limit: "$path"',
    );
  }

  try {
    return file.readAsBytesSync();
  } on FileSystemException catch (error) {
    throw WadReportInputFailure(
      'cannot read WAD file "$path": ${error.message}',
    );
  }
}

Future<void> main(List<String> arguments) async {
  final _Arguments? options = _Arguments.parse(arguments);
  if (options == null) {
    _printUsage();
    exit(_usageExitCode);
  }
  if (options.help) {
    _printUsage();
    return;
  }

  try {
    final _ReportResult result = _run(options);
    if (options.json) {
      stdout.writeln(jsonEncode(result.json));
    } else {
      stdout.write(result.text);
    }
    exit(result.exitCode);
  } on _ReportFailure catch (error) {
    if (options.json) {
      stdout.writeln(
        jsonEncode(<String, Object?>{
          'tool': 'wad_report',
          'verdict': 'PROBLEMS',
          'error': error.message,
        }),
      );
    } else {
      stderr.writeln('PROBLEMS: ${error.message}');
    }
    exit(_problemExitCode);
  } catch (error) {
    final String message = 'unexpected report failure: $error';
    if (options.json) {
      stdout.writeln(
        jsonEncode(<String, Object?>{
          'tool': 'wad_report',
          'verdict': 'PROBLEMS',
          'error': message,
        }),
      );
    } else {
      stderr.writeln('PROBLEMS: $message');
    }
    exit(_problemExitCode);
  }
}

void _printUsage() {
  stdout.writeln(
    'Usage: dart run tool/wad_report.dart [--scale-fixture] [--map E1M1] [--json] '
    '<path-to-wad>',
  );
  stdout.writeln(
    'Without a path, DOOM_WAD_PATH is used; without it, the synthetic fixture '
    'is reported.',
  );
}

class _Arguments {
  const _Arguments({
    required this.map,
    required this.json,
    required this.scaleFixture,
    required this.path,
    required this.help,
  });

  final String? map;
  final bool json;
  final bool scaleFixture;
  final String? path;
  final bool help;

  static _Arguments? parse(List<String> args) {
    String? map;
    String? path;
    var json = false;
    var scaleFixture = false;
    var help = false;
    for (var i = 0; i < args.length; i++) {
      final String arg = args[i];
      if (arg == '--json') {
        json = true;
      } else if (arg == '--scale-fixture') {
        scaleFixture = true;
      } else if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (arg == '--map') {
        if (i + 1 >= args.length || args[i + 1].startsWith('-')) {
          return null;
        }
        map = args[++i].toUpperCase();
      } else if (arg.startsWith('--map=')) {
        map = arg.substring('--map='.length).toUpperCase();
        if (map.isEmpty) {
          return null;
        }
      } else if (arg.startsWith('-')) {
        return null;
      } else if (path == null) {
        path = arg;
      } else {
        return null;
      }
    }
    if (scaleFixture && path != null) {
      return null;
    }
    return _Arguments(
      map: map,
      json: json,
      scaleFixture: scaleFixture,
      path: path,
      help: help,
    );
  }
}

class _ReportFailure implements Exception {
  const _ReportFailure(this.message);

  final String message;
}

class _ReportResult {
  const _ReportResult({
    required this.json,
    required this.text,
    required this.exitCode,
  });

  final Map<String, Object?> json;
  final String text;
  final int exitCode;
}

_ReportResult _run(_Arguments options, {int maxWadBytes = defaultMaxWadBytes}) {
  final String? configuredPath =
      options.path ?? Platform.environment[_wadPathEnvironment]?.trim();
  final String path = configuredPath ?? '';
  final bool fixture = path.isEmpty && !options.scaleFixture;
  final bool scaleFixture = options.scaleFixture;
  final String source = scaleFixture
      ? 'synthetic E1M1-scale fixture'
      : fixture
      ? 'synthetic fixture'
      : path;
  final String defaultMap = scaleFixture
      ? DoomScaleFixture.mapName
      : fixture
      ? DoomFixtures.mapName
      : 'E1M1';
  final String mapName = options.map ?? defaultMap;

  final Stopwatch parseClock = Stopwatch()..start();
  final WadFile wad;
  try {
    final Uint8List bytes = scaleFixture
        ? DoomScaleFixture.pwadBytes()
        : fixture
        ? DoomFixtures.pwadBytes()
        : readWadBytes(path, maxWadBytes: maxWadBytes);
    wad = WadFile.parse(bytes, limits: DoomLimits(maxWadBytes: maxWadBytes));
  } on WadReportInputFailure catch (error) {
    throw _ReportFailure('cannot read WAD $source: ${error.message}');
  } on FileSystemException catch (error) {
    throw _ReportFailure('cannot read WAD $source: ${error.message}');
  } on DoomFailure catch (error) {
    throw _ReportFailure('WAD parse failed: ${error.message}');
  }
  final WadSet set = WadSet.of(wad);

  final WadResources resources;
  final MapData map;
  try {
    resources = WadResources.load(set);
    map = MapData.load(set, mapName);
  } on DoomFailure catch (error) {
    throw _ReportFailure('map/resource parse failed: ${error.message}');
  }
  parseClock.stop();

  final _ResourceSummary resourceSummary;
  try {
    resourceSummary = _resourceSummary(resources, map);
  } on DoomFailure catch (error) {
    throw _ReportFailure('resource resolution failed: ${error.message}');
  }
  final Stopwatch compileClock = Stopwatch()..start();
  final CompiledLevel level;
  try {
    level = DoomGeometryCompiler.compile(map, resources);
  } on DoomFailure catch (error) {
    throw _ReportFailure('geometry compile failed: ${error.message}');
  }
  compileClock.stop();

  final GeometryReport report = level.report;
  final _GameplaySummary gameplaySummary = _gameplaySummary(
    map,
    resources,
    level,
  );
  final int maxSurfaceVertices = level.meshes.isEmpty
      ? 0
      : level.meshes
            .map((PackedMesh mesh) => mesh.vertexCount)
            .reduce((int a, int b) => a > b ? a : b);
  final bool uint16WithinLimit = level.meshes.every(
    (PackedMesh mesh) => mesh.vertexCount <= _uint16VertexLimit,
  );
  final List<int> fallbackSectors = report.fallbackSectors;
  final List<String> missingTextures = <String>{
    ...resourceSummary.missingTextures,
    ...report.missingTextures,
  }.toList()..sort();
  final List<String> missingFlats = resourceSummary.missingFlats;
  // A fallback is an explicit, reportable recovery path. Its comparison
  // issues (and area delta) are warnings, not a hard failure; only defects
  // that remain in the emitted BSP path make the verdict PROBLEMS.
  final bool hasResidualGeometryProblems = report.findings.any(
    (SectorFinding finding) =>
        !finding.usedFallback && finding.hasEmittedGeometryDefect,
  );
  final bool hasGeometryProblems =
      report.budgetExhausted || hasResidualGeometryProblems;
  final bool hasProblems =
      missingTextures.isNotEmpty ||
      missingFlats.isNotEmpty ||
      !uint16WithinLimit ||
      hasGeometryProblems;
  final bool hasGameplayGaps = gameplaySummary.hasProgressionGaps;
  final String verdict = hasProblems
      ? 'PROBLEMS'
      : hasGameplayGaps
      ? 'READY WITH GAPS'
      : fallbackSectors.isNotEmpty || report.animationFailures.isNotEmpty
      ? 'READY WITH FALLBACKS'
      : 'READY';
  final int exitCode = verdict == 'PROBLEMS' ? _problemExitCode : _okExitCode;
  final int parseMilliseconds = (parseClock.elapsedMicroseconds / 1000).round();
  final int compileMilliseconds = (compileClock.elapsedMicroseconds / 1000)
      .round();

  final Map<String, Object?> json = <String, Object?>{
    'tool': 'wad_report',
    'source': scaleFixture
        ? 'synthetic_e1m1_scale_fixture'
        : fixture
        ? 'synthetic_fixture'
        : configuredPath,
    'map': map.name,
    'requestedMap': mapName,
    'container': <String, Object?>{
      'kind': wad.kind.name.toUpperCase(),
      'lumps': wad.length,
      'bytes': wad.byteLength,
      'hasPLAYPAL': set.indexOf('PLAYPAL') != null,
      'hasCOLORMAP': set.indexOf('COLORMAP') != null,
      'maps': set.mapNames(),
    },
    'resources': resourceSummary.json,
    'gameplay': gameplaySummary.json,
    'mapCounts': <String, Object?>{
      'vertexes': map.vertices.length,
      'linedefs': map.linedefs.length,
      'sidedefs': map.sidedefs.length,
      'sectors': map.sectors.length,
      'things': map.things.length,
      'segs': map.segs.length,
      'ssectors': map.subsectors.length,
      'nodes': map.nodes.length,
      'hasBLOCKMAP': map.blockmap != null,
      'hasREJECT': map.reject != null,
    },
    'geometry': <String, Object?>{
      'report': _geometryJson(report),
      'fallbackSectors': fallbackSectors,
      'fallbackSectorCount': fallbackSectors.length,
      'totalAreaDelta': report.totalAreaDelta,
      'maxSurfaceVertices': maxSurfaceVertices,
      'uint16VertexLimit': _uint16VertexLimit,
      'uint16WithinLimit': uint16WithinLimit,
      'surfacesOverUint16Limit': <int>[
        for (var i = 0; i < level.meshes.length; i++)
          if (level.meshes[i].vertexCount > _uint16VertexLimit) i,
      ],
    },
    'timingsMs': <String, Object?>{
      'parse': parseMilliseconds,
      'geometryCompile': compileMilliseconds,
    },
    'missingTextures': missingTextures,
    'missingFlats': missingFlats,
    'staticAnimations': report.animationFailures,
    'verdict': verdict,
    'exitCode': exitCode,
  };

  final StringBuffer text = StringBuffer()
    ..writeln('wad_report: $source')
    ..writeln(
      'container: ${wad.kind.name.toUpperCase()}, ${wad.length} lumps, '
      '${wad.byteLength} bytes',
    )
    ..writeln(
      'PLAYPAL: ${set.indexOf('PLAYPAL') != null ? "yes" : "no"}; '
      'COLORMAP: ${set.indexOf('COLORMAP') != null ? "yes" : "no"}',
    )
    ..writeln('maps: ${set.mapNames().join(', ')}')
    ..writeln(
      'resources: patches ${resourceSummary.resolvedPatches}/'
      '${resourceSummary.patchCount}, composites '
      '${resourceSummary.resolvedTextures}/${resourceSummary.textureCount}, '
      'flats ${resourceSummary.resolvedFlats}/${resourceSummary.flatCount}, '
      'sprites ${resourceSummary.resolvedSprites}/${resourceSummary.spriteCount}',
    )
    ..writeln(
      'missing textures: '
      '${missingTextures.isEmpty ? "none" : missingTextures.join(', ')}',
    )
    ..writeln(
      'missing flats: '
      '${missingFlats.isEmpty ? "none" : missingFlats.join(', ')}',
    )
    ..writeln(
      'static animations: '
      '${report.animationFailures.isEmpty ? "none" : report.animationFailures.join(', ')}',
    )
    ..write(gameplaySummary.text)
    ..writeln(
      'map $mapName: vertices ${map.vertices.length}, '
      'linedefs ${map.linedefs.length}, sidedefs ${map.sidedefs.length}, '
      'sectors ${map.sectors.length}, things ${map.things.length}, '
      'segs ${map.segs.length}, ssectors ${map.subsectors.length}, '
      'nodes ${map.nodes.length}, BLOCKMAP ${map.blockmap != null ? "yes" : "no"}, '
      'REJECT ${map.reject != null ? "yes" : "no"}',
    )
    ..writeln(
      'geometry: triangles ${report.totalTriangles}, '
      'vertices ${report.totalVertices}, meshes ${report.meshCount}, '
      'atlas pages ${report.atlasPages}',
    )
    ..writeln(
      'geometry checks: area delta ${report.totalAreaDelta}, '
      'holes/unmatched edges ${_unmatchedEdges(report)}, '
      'degenerate triangles ${report.degenerateTriangleCount}, '
      'T-junctions ${report.tJunctionCount}, '
      'budget ${report.intersectionChecks}/${report.intersectionBudget}',
    )
    ..writeln(
      'uint16 surface limit: $maxSurfaceVertices/$_uint16VertexLimit '
      '${uint16WithinLimit ? "OK" : "EXCEEDED"}',
    )
    ..writeln(
      'fallbacks: ${fallbackSectors.length} sector(s), '
      'area delta ${report.totalAreaDelta}',
    )
    ..writeln(
      'timings: parse $parseMilliseconds ms, '
      'geometry compile $compileMilliseconds ms',
    )
    ..writeln('VERDICT: $verdict');

  return _ReportResult(json: json, text: text.toString(), exitCode: exitCode);
}

int _unmatchedEdges(GeometryReport report) => report.findings.fold<int>(
  0,
  (int total, SectorFinding finding) => total + finding.unmatchedEdges,
);

Map<String, Object?> _geometryJson(GeometryReport report) => <String, Object?>{
  'map': report.map,
  'totalTriangles': report.totalTriangles,
  'totalVertices': report.totalVertices,
  'meshCount': report.meshCount,
  'atlasPages': report.atlasPages,
  'subsectorCount': report.subsectorCount,
  'emptySubsectors': report.emptySubsectors,
  'maxBspDepth': report.maxBspDepth,
  'totalAreaDelta': report.totalAreaDelta,
  'tJunctions': report.tJunctionCount,
  'degenerateTriangles': report.degenerateTriangleCount,
  'fallbackSectors': report.fallbackSectors,
  'intersectionChecks': report.intersectionChecks,
  'intersectionBudget': report.intersectionBudget,
  'budgetExhausted': report.budgetExhausted,
  'missingTextures': report.missingTextures,
  'animationFailures': report.animationFailures,
  'geometryHash': '0x${report.geometryHash.toRadixString(16)}',
  'compileMicroseconds': report.compileMicroseconds,
  'repairedTJunctionVertices': report.repairedTJunctionVertices,
  'repairedRegions': report.repairedRegions,
  'findings': <Map<String, Object?>>[
    for (final SectorFinding finding in report.findings)
      <String, Object?>{
        'sector': finding.sector,
        'issues': finding.issues
            .map((GeometryIssue issue) => issue.name)
            .toList(),
        'areaDelta': finding.areaDelta,
        'bspArea': finding.bspArea,
        'loopArea': finding.loopArea,
        'degenerateTriangles': finding.degenerateTriangles,
        'tJunctions': finding.tJunctions,
        'unmatchedEdges': finding.unmatchedEdges,
        'overlaps': finding.overlaps,
        'emptyRegions': finding.emptyRegions,
        'usedFallback': finding.usedFallback,
        'bspEvaluated': finding.bspEvaluated,
        'oracleReliable': finding.oracleReliable,
      },
  ],
};

class _ResourceSummary {
  const _ResourceSummary({
    required this.patchCount,
    required this.resolvedPatches,
    required this.textureCount,
    required this.resolvedTextures,
    required this.flatCount,
    required this.resolvedFlats,
    required this.spriteCount,
    required this.resolvedSprites,
    required this.missingTextures,
    required this.missingFlats,
  });

  final int patchCount;
  final int resolvedPatches;
  final int textureCount;
  final int resolvedTextures;
  final int flatCount;
  final int resolvedFlats;
  final int spriteCount;
  final int resolvedSprites;
  final List<String> missingTextures;
  final List<String> missingFlats;

  Map<String, Object?> get json => <String, Object?>{
    'patches': <String, Object?>{
      'available': patchCount,
      'resolved': resolvedPatches,
    },
    'compositeTextures': <String, Object?>{
      'available': textureCount,
      'resolved': resolvedTextures,
    },
    'flats': <String, Object?>{
      'available': flatCount,
      'resolved': resolvedFlats,
    },
    'sprites': <String, Object?>{
      'available': spriteCount,
      'resolved': resolvedSprites,
    },
    'missingTextures': missingTextures,
    'missingFlats': missingFlats,
  };
}

_ResourceSummary _resourceSummary(WadResources resources, MapData map) {
  int resolvedPatches = 0;
  for (final String name in resources.patchNames) {
    if (resources.patchByName(name) != null) {
      resolvedPatches++;
    }
  }
  int resolvedTextures = 0;
  for (final String name in resources.textureNames) {
    final TextureDef? definition = resources.textureDef(name);
    if (definition != null &&
        definition.patches.every(
          (TexturePatch placement) =>
              resources.patchAt(placement.patchIndex) != null,
        ) &&
        resources.composite(name) != null) {
      resolvedTextures++;
    }
  }
  int resolvedFlats = 0;
  for (final String name in resources.flatNames) {
    if (resources.flat(name) != null) {
      resolvedFlats++;
    }
  }
  int resolvedSprites = 0;
  for (final String name in resources.spriteNames) {
    if (resources.sprite(name) != null) {
      resolvedSprites++;
    }
  }

  final Set<String> textureRefs = <String>{};
  for (final Sidedef sidedef in map.sidedefs) {
    for (final String name in <String>[
      sidedef.upperTexture,
      sidedef.lowerTexture,
      sidedef.middleTexture,
    ]) {
      if (name.isNotEmpty && name != kNoTextureName) {
        textureRefs.add(name);
      }
    }
  }
  final Set<String> flatRefs = <String>{};
  for (final Sector sector in map.sectors) {
    for (final String name in <String>[sector.floorFlat, sector.ceilingFlat]) {
      if (name.isNotEmpty && name != kSkyFlatName) {
        flatRefs.add(name);
      }
    }
  }
  final List<String> missingTextures = <String>[
    for (final String name in textureRefs)
      if (!_textureResolves(resources, name)) name,
  ]..sort();
  final List<String> missingFlats = <String>[
    for (final String name in flatRefs)
      if (resources.flat(name) == null) name,
  ]..sort();

  return _ResourceSummary(
    patchCount: resources.patchNames.length,
    resolvedPatches: resolvedPatches,
    textureCount: resources.textureNames.length,
    resolvedTextures: resolvedTextures,
    flatCount: resources.flatNames.length,
    resolvedFlats: resolvedFlats,
    spriteCount: resources.spriteNames.length,
    resolvedSprites: resolvedSprites,
    missingTextures: missingTextures,
    missingFlats: missingFlats,
  );
}

bool _textureResolves(WadResources resources, String name) {
  final TextureDef? definition = resources.textureDef(name);
  return definition != null &&
      definition.patches.every(
        (TexturePatch placement) =>
            resources.patchAt(placement.patchIndex) != null,
      ) &&
      resources.composite(name) != null;
}

/// Gameplay-format audit which intentionally consumes only doom_core's public
/// catalog. It never re-states the core's supported-special or sound lists.
_GameplaySummary _gameplaySummary(
  MapData map,
  WadResources resources,
  CompiledLevel level,
) {
  final _SpecialCoverage lineSpecials = _specialCoverage(
    <int>[for (final Linedef line in map.linedefs) line.special],
    <int>{
      ...DoomCoreCatalog.supportedLinedefSpecials,
      ...DoomGeometryCompiler.supportedLinedefSpecials,
    },
  );
  final _SpecialCoverage sectorSpecials = _specialCoverage(<int>[
    for (final Sector sector in map.sectors) sector.special,
  ], DoomCoreCatalog.supportedSectorSpecials);
  final _ThingSummary things = _thingSummary(map.things);
  final _ProgressionSummary progression = _progressionSummary(
    map.things,
    map.linedefs,
  );
  final _SoundSummary sounds = _soundSummary(resources);
  final _AnimationSummary animations = _animationSummary(resources, level);
  return _GameplaySummary(
    lineSpecials: lineSpecials,
    sectorSpecials: sectorSpecials,
    things: things,
    progression: progression,
    sounds: sounds,
    animations: animations,
  );
}

class _GameplaySummary {
  const _GameplaySummary({
    required this.lineSpecials,
    required this.sectorSpecials,
    required this.things,
    required this.progression,
    required this.sounds,
    required this.animations,
  });

  final _SpecialCoverage lineSpecials;
  final _SpecialCoverage sectorSpecials;
  final _ThingSummary things;
  final _ProgressionSummary progression;
  final _SoundSummary sounds;
  final _AnimationSummary animations;

  bool get hasProgressionGaps =>
      lineSpecials.unsupported.isNotEmpty ||
      sectorSpecials.unsupported.isNotEmpty ||
      things.unknownTypes.isNotEmpty ||
      progression.hasMissingKeys;

  Map<String, Object?> get json => <String, Object?>{
    'linedefSpecials': lineSpecials.json,
    'sectorSpecials': sectorSpecials.json,
    'things': things.json,
    'progression': progression.json,
    'sounds': sounds.json,
    'animationsAndSwitches': animations.json,
  };

  String get text {
    final StringBuffer text = StringBuffer()
      ..writeln(
        'linedef specials: ${lineSpecials.supportedUses}/${lineSpecials.uses} '
        'supported; unsupported ${_formatCounts(lineSpecials.unsupported)}',
      )
      ..writeln(
        'sector specials: ${sectorSpecials.supportedUses}/${sectorSpecials.uses} '
        'supported; unsupported ${_formatCounts(sectorSpecials.unsupported)}',
      )
      ..writeln(
        'things: player starts ${things.playerStarts}; co-op starts '
        '${things.coopStarts}; deathmatch starts ${things.deathmatchStarts}; '
        'known spawnable ${things.knownSpawnable}; '
        'known non-spawning ${things.knownNonSpawning}; unknown '
        '${_formatCounts(things.unknownTypes)}',
      )
      ..writeln('things by skill: ${things.skillText}')
      ..writeln(
        'exits: ${_formatCounts(progression.exitSpecials)}; locked doors '
        '${_formatCounts(progression.lockedDoorSpecials)}; '
        'missing keys ${progression.missingKeysText}',
      )
      ..writeln(
        'sounds: ${sounds.resolved.length}/${sounds.expected.length} expected '
        'DS* resolved; missing ${_formatNames(sounds.missing)}',
      )
      ..writeln(
        'animations in WAD: ${animations.resolvedSequences} resolved, '
        '${animations.degradedSequences.length} degraded; switches in WAD: '
        '${animations.resolvedSwitchPairs} resolved; map emits '
        '${animations.mapAnimationSequences} animations and '
        '${animations.mapSwitchPairs} switch pairs; static '
        '${_formatNames(animations.staticFailures)}',
      );
    return text.toString();
  }
}

class _SpecialCoverage {
  const _SpecialCoverage({
    required this.uses,
    required this.supportedUses,
    required this.supported,
    required this.unsupported,
  });

  final int uses;
  final int supportedUses;
  final Map<int, int> supported;
  final Map<int, int> unsupported;

  Map<String, Object?> get json => <String, Object?>{
    'uses': uses,
    'supportedUses': supportedUses,
    'supported': _jsonIntCounts(supported),
    'unsupported': _jsonIntCounts(unsupported),
  };
}

_SpecialCoverage _specialCoverage(Iterable<int> specials, Set<int> supported) {
  final Map<int, int> counts = _countInts(
    specials.where((int value) => value != 0),
  );
  final Map<int, int> supportedCounts = <int, int>{};
  final Map<int, int> unsupportedCounts = <int, int>{};
  for (final MapEntry<int, int> entry in counts.entries) {
    (supported.contains(entry.key)
            ? supportedCounts
            : unsupportedCounts)[entry.key] =
        entry.value;
  }
  return _SpecialCoverage(
    uses: counts.values.fold(0, (int total, int count) => total + count),
    supportedUses: supportedCounts.values.fold(
      0,
      (int total, int count) => total + count,
    ),
    supported: supportedCounts,
    unsupported: unsupportedCounts,
  );
}

class _ThingSummary {
  const _ThingSummary({
    required this.types,
    required this.playerStarts,
    required this.coopStarts,
    required this.deathmatchStarts,
    required this.knownSpawnable,
    required this.knownNonSpawning,
    required this.unknownTypes,
    required this.bySkill,
  });

  final List<Map<String, Object?>> types;
  final int playerStarts;
  final int coopStarts;
  final int deathmatchStarts;
  final int knownSpawnable;
  final int knownNonSpawning;
  final Map<int, int> unknownTypes;
  final Map<Skill, _SkillThingCounts> bySkill;

  Map<String, Object?> get json => <String, Object?>{
    'types': types,
    'playerStarts': playerStarts,
    'cooperativeStarts': coopStarts,
    'deathmatchStarts': deathmatchStarts,
    'knownSpawnable': knownSpawnable,
    'knownNonSpawning': knownNonSpawning,
    'unknownTypes': _jsonIntCounts(unknownTypes),
    'bySkill': <String, Object?>{
      for (final Skill skill in Skill.values) skill.name: bySkill[skill]!.json,
    },
  };

  String get skillText => Skill.values
      .map(
        (Skill skill) =>
            '${skill.name} monsters ${bySkill[skill]!.monsters}, items '
            '${bySkill[skill]!.items}',
      )
      .join('; ');
}

class _SkillThingCounts {
  _SkillThingCounts({
    required this.spawnable,
    required this.monsters,
    required this.items,
  });

  int spawnable;
  int monsters;
  int items;

  Map<String, int> get json => <String, int>{
    'spawnable': spawnable,
    'monsters': monsters,
    'items': items,
  };
}

_ThingSummary _thingSummary(List<Thing> things) {
  const Set<int> coopStartTypes = <int>{2, 3, 4};
  final Map<int, int> allTypes = _countInts(
    things.map((Thing thing) => thing.type),
  );
  final Map<int, int> unknown = <int, int>{};
  var playerStarts = 0;
  var coopStarts = 0;
  var deathmatchStarts = 0;
  var knownSpawnable = 0;
  var knownNonSpawning = 0;
  final Map<Skill, _SkillThingCounts> bySkill = <Skill, _SkillThingCounts>{
    for (final Skill skill in Skill.values)
      skill: _SkillThingCounts(spawnable: 0, monsters: 0, items: 0),
  };
  for (final Thing thing in things) {
    final MobjInfo? info = DoomCoreCatalog.infoForEdNum(thing.type);
    final bool isPlayerStart = thing.type == 1;
    final bool isCoopStart = coopStartTypes.contains(thing.type);
    final bool isDeathmatchStart = thing.type == 11;
    if (isPlayerStart) {
      playerStarts++;
    } else if (isCoopStart) {
      coopStarts++;
      knownNonSpawning++;
    } else if (isDeathmatchStart) {
      deathmatchStarts++;
      knownNonSpawning++;
    } else if (info == null) {
      unknown[thing.type] = (unknown[thing.type] ?? 0) + 1;
    } else {
      knownSpawnable++;
    }
    for (final Skill skill in Skill.values) {
      if (!_enabledForSkill(thing, skill) ||
          (thing.flags & ThingFlags.multiplayerOnly) != 0 ||
          isCoopStart ||
          isDeathmatchStart) {
        continue;
      }
      final _SkillThingCounts counts = bySkill[skill]!;
      if (isPlayerStart || info != null) counts.spawnable++;
      if (info?.isMonster ?? false) counts.monsters++;
      if (info?.isPickup ?? false) counts.items++;
    }
  }
  final List<Map<String, Object?>> types = <Map<String, Object?>>[
    for (final int type in allTypes.keys.toList()..sort())
      <String, Object?>{
        'type': type,
        'count': allTypes[type],
        'classification': type == 1
            ? 'playerStart'
            : coopStartTypes.contains(type)
            ? 'cooperativeStart'
            : type == 11
            ? 'deathmatchStart'
            : DoomCoreCatalog.infoForEdNum(type) == null
            ? 'unknown'
            : 'spawnable',
        'spawnableBySkill': <String, int>{
          for (final Skill skill in Skill.values)
            skill.name: things
                .where(
                  (Thing thing) =>
                      thing.type == type &&
                      !_isCoopStart(thing.type) &&
                      thing.type != 11 &&
                      _enabledForSkill(thing, skill) &&
                      (thing.flags & ThingFlags.multiplayerOnly) == 0 &&
                      (thing.type == 1 ||
                          DoomCoreCatalog.infoForEdNum(thing.type) != null),
                )
                .length,
        },
      },
  ];
  return _ThingSummary(
    types: types,
    playerStarts: playerStarts,
    coopStarts: coopStarts,
    deathmatchStarts: deathmatchStarts,
    knownSpawnable: knownSpawnable,
    knownNonSpawning: knownNonSpawning,
    unknownTypes: unknown,
    bySkill: bySkill,
  );
}

bool _isCoopStart(int type) => type == 2 || type == 3 || type == 4;

bool _enabledForSkill(Thing thing, Skill skill) {
  final int flag = switch (skill) {
    Skill.easy => ThingFlags.easy,
    Skill.medium => ThingFlags.medium,
    Skill.hard => ThingFlags.hard,
  };
  return thing.flags == 0 || (thing.flags & flag) != 0;
}

class _ProgressionSummary {
  const _ProgressionSummary({
    required this.exitSpecials,
    required this.lockedDoorSpecials,
    required this.keysBySkill,
    required this.missingKeysBySkill,
  });

  final Map<int, int> exitSpecials;
  final Map<int, int> lockedDoorSpecials;
  final Map<Skill, Set<Key>> keysBySkill;
  final Map<Skill, Set<Key>> missingKeysBySkill;

  bool get hasMissingKeys =>
      missingKeysBySkill.values.any((Set<Key> keys) => keys.isNotEmpty);

  Map<String, Object?> get json => <String, Object?>{
    'exitSpecials': _jsonIntCounts(exitSpecials),
    'hasExit': exitSpecials.isNotEmpty,
    'lockedDoorSpecials': _jsonIntCounts(lockedDoorSpecials),
    'keysBySkill': <String, Object?>{
      for (final Skill skill in Skill.values)
        skill.name: _keyNames(keysBySkill[skill]!),
    },
    'missingKeysBySkill': <String, Object?>{
      for (final Skill skill in Skill.values)
        skill.name: _keyNames(missingKeysBySkill[skill]!),
    },
  };

  String get missingKeysText => Skill.values
      .map(
        (Skill skill) =>
            '${skill.name} ${_formatNames(_keyNames(missingKeysBySkill[skill]!))}',
      )
      .join('; ');
}

_ProgressionSummary _progressionSummary(
  List<Thing> things,
  List<Linedef> lines,
) {
  const Set<int> exitSpecials = <int>{11, 51, 52, 124};
  final Map<int, int> exits = _countInts(
    lines
        .where((Linedef line) => exitSpecials.contains(line.special))
        .map((Linedef line) => line.special),
  );
  final Map<int, int> locked = <int, int>{};
  final Set<Key> required = <Key>{};
  for (final Linedef line in lines) {
    final Key? key = DoomCoreCatalog.requiredKeyForLineSpecial(line.special);
    if (key == null) continue;
    locked[line.special] = (locked[line.special] ?? 0) + 1;
    required.add(key);
  }
  final Map<Skill, Set<Key>> keysBySkill = <Skill, Set<Key>>{};
  final Map<Skill, Set<Key>> missingBySkill = <Skill, Set<Key>>{};
  for (final Skill skill in Skill.values) {
    final Set<Key> keys = <Key>{};
    for (final Thing thing in things) {
      if (!_enabledForSkill(thing, skill) ||
          (thing.flags & ThingFlags.multiplayerOnly) != 0) {
        continue;
      }
      final Key? key = DoomCoreCatalog.keyForEdNum(thing.type);
      if (key != null) keys.add(key);
    }
    keysBySkill[skill] = keys;
    missingBySkill[skill] = <Key>{...required}..removeAll(keys);
  }
  return _ProgressionSummary(
    exitSpecials: exits,
    lockedDoorSpecials: locked,
    keysBySkill: keysBySkill,
    missingKeysBySkill: missingBySkill,
  );
}

class _SoundSummary {
  const _SoundSummary({
    required this.expected,
    required this.resolved,
    required this.missing,
  });

  final List<String> expected;
  final List<String> resolved;
  final List<String> missing;

  Map<String, Object?> get json => <String, Object?>{
    'expected': expected,
    'resolved': resolved,
    'missing': missing,
  };
}

_SoundSummary _soundSummary(WadResources resources) {
  final List<String> expected = DoomCoreCatalog.soundIds.toList()..sort();
  final List<String> resolved = <String>[];
  final List<String> missing = <String>[];
  for (final String name in expected) {
    if (resources.sound(name) == null) {
      missing.add(name);
    } else {
      resolved.add(name);
    }
  }
  return _SoundSummary(
    expected: expected,
    resolved: resolved,
    missing: missing,
  );
}

class _AnimationSummary {
  const _AnimationSummary({
    required this.resolvedSequences,
    required this.degradedSequences,
    required this.resolvedSwitchPairs,
    required this.mapAnimationSequences,
    required this.mapSwitchPairs,
    required this.staticFailures,
  });

  final int resolvedSequences;
  final List<String> degradedSequences;
  final int resolvedSwitchPairs;
  final int mapAnimationSequences;
  final int mapSwitchPairs;
  final List<String> staticFailures;

  Map<String, Object?> get json => <String, Object?>{
    'wad': <String, Object?>{
      'resolvedAnimationSequences': resolvedSequences,
      'degradedAnimationSequences': degradedSequences,
      'resolvedSwitchPairs': resolvedSwitchPairs,
    },
    'map': <String, Object?>{
      'emittedAnimationSequences': mapAnimationSequences,
      'emittedSwitchPairs': mapSwitchPairs,
      'staticFailures': staticFailures,
    },
  };
}

_AnimationSummary _animationSummary(
  WadResources resources,
  CompiledLevel level,
) {
  final DoomAnimationResolution resolution = resolveDoomAnimations(resources);
  final List<String> degraded = <String>[
    for (final DoomAnimationFailure failure in resolution.failures)
      '${failure.definition.startName}->${failure.definition.endName}: ${failure.reason}',
  ]..sort();
  var resolvedSwitchPairs = 0;
  for (final DoomSwitchPair pair in vanillaDoomSwitches) {
    if (_textureResolves(resources, pair.offName) &&
        _textureResolves(resources, pair.onName)) {
      resolvedSwitchPairs++;
    }
  }
  return _AnimationSummary(
    resolvedSequences: resolution.animations.length,
    degradedSequences: degraded,
    resolvedSwitchPairs: resolvedSwitchPairs,
    mapAnimationSequences: level.animations.length,
    mapSwitchPairs: level.switchFrames.length ~/ 2,
    staticFailures: List<String>.of(level.report.animationFailures)..sort(),
  );
}

Map<int, int> _countInts(Iterable<int> values) {
  final Map<int, int> counts = <int, int>{};
  for (final int value in values) {
    counts[value] = (counts[value] ?? 0) + 1;
  }
  return counts;
}

List<Map<String, int>> _jsonIntCounts(Map<int, int> counts) =>
    <Map<String, int>>[
      for (final int value in counts.keys.toList()..sort())
        <String, int>{'number': value, 'count': counts[value]!},
    ];

List<String> _keyNames(Set<Key> keys) =>
    keys.map((Key key) => key.name).toList()..sort();

String _formatCounts(Map<int, int> counts) => counts.isEmpty
    ? 'none'
    : (counts.keys.toList()..sort())
          .map((int number) => '$number (${counts[number]})')
          .join(', ');

String _formatNames(Iterable<String> names) {
  final List<String> ordered = names.toList()..sort();
  return ordered.isEmpty ? 'none' : ordered.join(', ');
}
