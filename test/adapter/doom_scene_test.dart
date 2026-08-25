import 'dart:typed_data';

import 'package:doompeller/adapter/adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_gpu_backend.dart';
import 'palette_textures_test.dart' show buildColorMaps, buildPalettes;

/// A flat quad at height [y], four vertices and two triangles.
SceneMeshInput quadMesh({
  required String page,
  required DoomSurfaceKind kind,
  double y = 0,
  double x = 0,
}) {
  final vertices = DoomVertexAbi.allocate(4);
  DoomVertexAbi.writeVertex(vertices, 0, x: x, y: y, z: 0, u: 0, v: 0);
  DoomVertexAbi.writeVertex(vertices, 1, x: x + 8, y: y, z: 0, u: 1, v: 0);
  DoomVertexAbi.writeVertex(vertices, 2, x: x + 8, y: y, z: 8, u: 1, v: 1);
  DoomVertexAbi.writeVertex(vertices, 3, x: x, y: y, z: 8, u: 0, v: 1);
  return SceneMeshInput(
    vertices: vertices,
    indices: Uint16List.fromList(const [0, 1, 2, 0, 2, 3]),
    atlasPage: page,
    kind: kind,
    bounds: SceneBounds(
      minX: x,
      minY: y,
      minZ: 0,
      maxX: x + 8,
      maxY: y,
      maxZ: 8,
    ),
  );
}

PaletteTextures buildTextures() => PaletteTextures(
  PaletteTextureData.encode(
    atlasWidth: 4,
    atlasHeight: 4,
    atlasIndices: Uint8List(16),
    colorMaps: buildColorMaps(34),
    palettes: buildPalettes(DoomPaletteVariant.count),
  ),
);

void main() {
  setUp(FakeGpuBackend.new);

  group('surface merging', () {
    test('merges meshes sharing an atlas page and kind into one surface', () {
      final textures = buildTextures();
      final diagnostics = RenderDiagnostics();
      final scene = DoomScene.build(
        CompiledLevelInput(
          meshes: [
            for (var i = 0; i < 6; i++)
              quadMesh(page: 'walls', kind: DoomSurfaceKind.opaque, x: i * 10),
          ],
          atlasPages: {'walls': textures},
        ),
        diagnostics: diagnostics,
      );

      expect(
        scene.surfaceCount,
        1,
        reason: 'flame_3d has no batching, so surface count is the draw cost',
      );
      expect(diagnostics.surfacesCreated, 1);
      expect(diagnostics.triangles, 12);
      expect(scene.surfaces.single.vertexCount, 24);
    });

    test('rebases indices when merging', () {
      final scene = DoomScene.build(
        CompiledLevelInput(
          meshes: [
            quadMesh(page: 'walls', kind: DoomSurfaceKind.opaque),
            quadMesh(page: 'walls', kind: DoomSurfaceKind.opaque, x: 40),
          ],
          atlasPages: {'walls': buildTextures()},
        ),
      );

      final surface = scene.surfaces.single;
      expect(surface.indices.sublist(0, 6), [0, 1, 2, 0, 2, 3]);
      expect(
        surface.indices.sublist(6, 12),
        [4, 5, 6, 4, 6, 7],
        reason: 'the second mesh must address its own merged vertices',
      );
      expect(surface.aabb.max.x, 48);
    });

    test('a single mesh is passed through without copying', () {
      final mesh = quadMesh(page: 'walls', kind: DoomSurfaceKind.opaque);
      final scene = DoomScene.build(
        CompiledLevelInput(
          meshes: [mesh],
          atlasPages: {'walls': buildTextures()},
        ),
      );
      expect(identical(scene.surfaces.single.packedVertices, mesh.vertices), isTrue);
    });

    test('keeps kinds apart so cutout mode stays correct', () {
      final scene = DoomScene.build(
        CompiledLevelInput(
          meshes: [
            quadMesh(page: 'walls', kind: DoomSurfaceKind.opaque),
            quadMesh(page: 'walls', kind: DoomSurfaceKind.masked),
          ],
          atlasPages: {'walls': buildTextures()},
        ),
      );

      expect(scene.surfaceCount, 2);
      final kinds = scene.surfaces.map((s) => s.kind).toSet();
      expect(kinds, {DoomSurfaceKind.opaque, DoomSurfaceKind.masked});
    });

    test('reuses one material per page and cutout mode', () {
      final textures = buildTextures();
      final scene = DoomScene.build(
        CompiledLevelInput(
          meshes: [
            quadMesh(page: 'walls', kind: DoomSurfaceKind.opaque),
            quadMesh(page: 'walls', kind: DoomSurfaceKind.sky),
            quadMesh(page: 'walls', kind: DoomSurfaceKind.masked),
            quadMesh(page: 'sprites', kind: DoomSurfaceKind.sprite),
          ],
          atlasPages: {'walls': textures, 'sprites': buildTextures()},
        ),
      );

      // walls opaque+sky share the non-cutout material; walls masked is a
      // second; sprites is a third.
      expect(scene.materials.length, 3);
    });

    test('composes every layer of a level', () {
      final diagnostics = RenderDiagnostics();
      final scene = DoomScene.build(
        CompiledLevelInput(
          meshes: [
            quadMesh(page: 'world', kind: DoomSurfaceKind.opaque),
            quadMesh(page: 'world', kind: DoomSurfaceKind.masked),
            quadMesh(page: 'world', kind: DoomSurfaceKind.sky),
            quadMesh(page: 'actors', kind: DoomSurfaceKind.sprite),
            quadMesh(page: 'actors', kind: DoomSurfaceKind.weapon),
          ],
          atlasPages: {'world': buildTextures(), 'actors': buildTextures()},
        ),
        diagnostics: diagnostics,
      );

      expect(scene.surfaceCount, 5);
      expect(diagnostics.meshesBuilt, 5);
      expect(diagnostics.componentsBuilt, 5);
      expect(scene.root.children.length, 5);

      // Sky and weapon must be camera-locked; nothing else may be.
      final locked = scene.root.children.whereType<CameraLockedMeshComponent>();
      expect(locked.length, 2);
    });

    test('fails loudly when an atlas page has no textures', () {
      expect(
        () => DoomScene.build(
          CompiledLevelInput(
            meshes: [quadMesh(page: 'missing', kind: DoomSurfaceKind.opaque)],
            atlasPages: const {},
          ),
        ),
        throwsStateError,
      );
    });
  });

  group('dynamic geometry', () {
    test('updateSectorPlane moves only the named sector', () {
      final scene = DoomScene.build(
        CompiledLevelInput(
          meshes: [
            quadMesh(page: 'flats', kind: DoomSurfaceKind.opaque),
            quadMesh(page: 'flats', kind: DoomSurfaceKind.opaque, x: 40),
          ],
          atlasPages: {'flats': buildTextures()},
          floorPlanes: const [
            SectorPlaneRef(
              sectorIndex: 3,
              atlasPage: 'flats',
              vertexIndices: [4, 5, 6, 7],
              bounds: SceneBounds(
                minX: 40,
                minY: 0,
                minZ: 0,
                maxX: 48,
                maxY: 0,
                maxZ: 8,
              ),
            ),
          ],
        ),
      );

      expect(
        scene.updateSectorPlane(
          sectorIndex: 3,
          height: 56,
          isCeiling: false,
        ),
        isTrue,
      );

      final vertices = scene.surfaces.single.packedVertices;
      expect(DoomVertexAbi.getY(vertices, 4), 56);
      expect(DoomVertexAbi.getY(vertices, 7), 56);
      expect(DoomVertexAbi.getY(vertices, 0), 0, reason: 'sector 3 only');
      expect(scene.surfaces.single.aabb.max.y, 56);

      // A ceiling update must not touch a floor plane.
      expect(
        scene.updateSectorPlane(sectorIndex: 3, height: 99, isCeiling: true),
        isFalse,
      );
    });

    test('updateWallBand re-anchors V only when unpegged', () {
      CompiledLevelInput level({required bool unpegged}) => CompiledLevelInput(
        meshes: [quadMesh(page: 'walls', kind: DoomSurfaceKind.opaque)],
        atlasPages: {'walls': buildTextures()},
        wallBands: [
          WallBandRef(
            linedefIndex: 7,
            atlasPage: 'walls',
            topVertexIndices: const [0, 1],
            bottomVertexIndices: const [2, 3],
            bounds: const SceneBounds(
              minX: 0,
              minY: 0,
              minZ: 0,
              maxX: 8,
              maxY: 0,
              maxZ: 8,
            ),
            unpegged: unpegged,
            textureHeight: 64,
          ),
        ],
      );

      final pegged = DoomScene.build(level(unpegged: false));
      expect(
        pegged.updateWallBand(
          linedefIndex: 7,
          topHeight: 64,
          bottomHeight: 0,
        ),
        isTrue,
      );
      final peggedVertices = pegged.surfaces.single.packedVertices;
      expect(DoomVertexAbi.getY(peggedVertices, 0), 64);
      expect(
        DoomVertexAbi.getV(peggedVertices, 2),
        1,
        reason: 'a pegged texture stretches with the band',
      );

      final unpegged = DoomScene.build(level(unpegged: true));
      unpegged.updateWallBand(
        linedefIndex: 7,
        topHeight: 32,
        bottomHeight: 0,
      );
      final unpeggedVertices = unpegged.surfaces.single.packedVertices;
      expect(DoomVertexAbi.getV(unpeggedVertices, 0), 0);
      expect(
        DoomVertexAbi.getV(unpeggedVertices, 2),
        closeTo(0.5, 1e-6),
        reason: '32 of a 64-unit texture stays anchored to the top edge',
      );
    });

    test('a level with no dynamic refs reports no change', () {
      final scene = DoomScene.build(
        CompiledLevelInput(
          meshes: [quadMesh(page: 'walls', kind: DoomSurfaceKind.opaque)],
          atlasPages: {'walls': buildTextures()},
        ),
      );
      expect(
        scene.updateSectorPlane(sectorIndex: 0, height: 1, isCeiling: false),
        isFalse,
      );
      expect(
        scene.updateWallBand(linedefIndex: 0, topHeight: 1, bottomHeight: 0),
        isFalse,
      );
    });
  });

  group('palette flashes', () {
    test('switch every material at once', () {
      final scene = DoomScene.build(
        CompiledLevelInput(
          meshes: [
            quadMesh(page: 'world', kind: DoomSurfaceKind.opaque),
            quadMesh(page: 'actors', kind: DoomSurfaceKind.sprite),
          ],
          atlasPages: {'world': buildTextures(), 'actors': buildTextures()},
        ),
      );

      scene.setPaletteIndex(DoomPaletteVariant.radiationSuit);
      expect(
        scene.materials.materials.every(
          (m) => m.paletteIndex == DoomPaletteVariant.radiationSuit,
        ),
        isTrue,
      );

      expect(
        () => scene.setPaletteIndex(99),
        throwsRangeError,
        reason: 'an out-of-range flash must not silently sample garbage',
      );
    });

    test('cutout mode follows the surface kind', () {
      final textures = buildTextures();
      final cache = PaletteMaterialCache();
      final opaque = cache.resolve(
        atlasKey: 'world',
        textures: textures,
        alphaCutout: false,
      );
      final masked = cache.resolve(
        atlasKey: 'world',
        textures: textures,
        alphaCutout: true,
      );

      expect(opaque.alphaThreshold, 0);
      expect(masked.alphaThreshold, 0.5);
      expect(identical(opaque, masked), isFalse);
      expect(cache.length, 2);
    });
  });
}
