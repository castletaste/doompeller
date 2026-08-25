// Headless, read-only WAD and geometry report.
//
// This tool deliberately keeps all WAD bytes in memory. It never extracts or
// writes Doom content, which keeps a developer-local IWAD outside the source
// tree and all build artifacts.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    'Usage: dart run tool/wad_report.dart [--map E1M1] [--json] '
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
    required this.path,
    required this.help,
  });

  final String? map;
  final bool json;
  final String? path;
  final bool help;

  static _Arguments? parse(List<String> args) {
    String? map;
    String? path;
    var json = false;
    var help = false;
    for (var i = 0; i < args.length; i++) {
      final String arg = args[i];
      if (arg == '--json') {
        json = true;
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
    return _Arguments(map: map, json: json, path: path, help: help);
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
  final bool fixture = path.isEmpty;
  final String source = fixture ? 'synthetic fixture' : path;
  final String defaultMap = fixture ? DoomFixtures.mapName : 'E1M1';
  final String mapName = options.map ?? defaultMap;

  final Stopwatch parseClock = Stopwatch()..start();
  final WadFile wad;
  try {
    final Uint8List bytes = fixture
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
        !finding.usedFallback && finding.issues.isNotEmpty,
  );
  final bool hasGeometryProblems =
      report.budgetExhausted || hasResidualGeometryProblems;
  final bool hasProblems =
      missingTextures.isNotEmpty ||
      missingFlats.isNotEmpty ||
      !uint16WithinLimit ||
      hasGeometryProblems;
  final String verdict = hasProblems
      ? 'PROBLEMS'
      : fallbackSectors.isNotEmpty
      ? 'READY WITH FALLBACKS'
      : 'READY';
  final int exitCode = verdict == 'PROBLEMS' ? _problemExitCode : _okExitCode;
  final int parseMilliseconds = (parseClock.elapsedMicroseconds / 1000).round();
  final int compileMilliseconds = (compileClock.elapsedMicroseconds / 1000)
      .round();

  final Map<String, Object?> json = <String, Object?>{
    'tool': 'wad_report',
    'source': fixture ? 'synthetic_fixture' : configuredPath,
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
