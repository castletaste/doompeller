import 'dart:typed_data';

import 'package:doom_geometry/doom_geometry.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

void main() {
  test('production atlas packs the E1M1-scale fixture across pages', () {
    final CompiledLevel level = _compile();

    expect(level.atlas.pageSize, 2048);
    expect(level.atlas.pageCount, greaterThanOrEqualTo(2));
    expect(level.atlas.pageCount, lessThanOrEqualTo(4));
    expect(level.atlas.overflowed, isEmpty);
    for (final AtlasEntry entry in level.atlas.entries.values) {
      expect(entry.page, inInclusiveRange(0, level.atlas.pageCount - 1));
      expect(entry.x, greaterThanOrEqualTo(0));
      expect(entry.y, greaterThanOrEqualTo(0));
      expect(entry.x + entry.width, lessThanOrEqualTo(level.atlas.pageSize));
      expect(entry.y + entry.height, lessThanOrEqualTo(level.atlas.pageSize));
    }
    _expectPackedAtlasRects(level);
  });

  test('BSP-first E1M1-scale fixture agrees with sector-loop oracle', () {
    final CompiledLevel level = _compile();
    final GeometryReport report = level.report;
    final double oracleArea = report.findings.fold<double>(
      0,
      (double sum, SectorFinding finding) => sum + finding.loopArea,
    );

    expect(report.validated, isTrue);
    expect(report.bspFirst, isTrue);
    expect(report.fallbackSectors, isEmpty);
    expect(report.budgetExhausted, isFalse);
    expect(report.tJunctionCount, 0);
    expect(report.degenerateTriangleCount, 0);
    expect(
      report.totalAreaDelta,
      lessThanOrEqualTo(oracleArea * 1e-6 + 1.0),
      reason: report.summary(),
    );
    expect(
      report.findings.where(
        (SectorFinding finding) => finding.issues.isNotEmpty,
      ),
      isEmpty,
      reason: report.summary(),
    );
  });

  test('E1M1-scale fixture stays within uint16 mesh limits', () {
    final CompiledLevel level = _compile();
    expect(level.meshes, isNotEmpty);
    for (final PackedMesh mesh in level.meshes) {
      expect(
        mesh.vertexCount,
        lessThanOrEqualTo(DoomVertexAbi.maxVerticesPerMesh),
      );
      expect(mesh.indices, everyElement(lessThan(mesh.vertexCount)));
    }
  });
}

CompiledLevel _compile() {
  final WadSet set = DoomScaleFixture.wadSet();
  return DoomGeometryCompiler.compile(
    MapData.load(set, DoomScaleFixture.mapName),
    WadResources.load(set),
  );
}

void _expectPackedAtlasRects(CompiledLevel level) {
  for (final PackedMesh mesh in level.meshes) {
    final Float32List vertices = mesh.vertices;
    for (var vertex = 0; vertex < mesh.vertexCount; vertex++) {
      final int o =
          vertex * DoomVertexAbi.floatsPerVertex +
          DoomVertexAbi.atlasRectOffset;
      expect(vertices[o], inInclusiveRange(0.0, 1.0));
      expect(vertices[o + 1], inInclusiveRange(0.0, 1.0));
      expect(vertices[o + 2], inInclusiveRange(0.0, 1.0));
      expect(vertices[o + 3], inInclusiveRange(0.0, 1.0));
      expect(vertices[o], lessThanOrEqualTo(vertices[o + 2]));
      expect(vertices[o + 1], lessThanOrEqualTo(vertices[o + 3]));
    }
  }
}
