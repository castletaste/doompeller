import 'dart:math' as math;
import 'dart:typed_data';

import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:doom_core/doom_core.dart' as core;
import 'package:doom_wad/doom_wad.dart' as wad;
import 'package:doompeller/adapter/adapter.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_gpu_backend.dart';

void expectPackedAtlasRect(
  geometry.CompiledLevel level,
  geometry.VertexRange range,
  geometry.AtlasEntry entry,
) {
  final List<double> expected = <double>[
    entry.u0(level.atlas.pageSize),
    entry.v0(level.atlas.pageSize),
    entry.u1(level.atlas.pageSize),
    entry.v1(level.atlas.pageSize),
  ];
  final vertices = level.meshes[range.meshIndex].vertices;
  for (
    var vertex = range.firstVertex;
    vertex < range.firstVertex + range.vertexCount;
    vertex++
  ) {
    final int offset =
        vertex * geometry.DoomVertexAbi.floatsPerVertex +
        geometry.DoomVertexAbi.atlasRectOffset;
    expect(
      vertices.sublist(offset, offset + expected.length),
      expected,
      reason: 'mesh ${range.meshIndex} vertex $vertex atlas rect',
    );
  }
}

void main() {
  late FakeGpuBackend backend;
  late geometry.CompiledLevel level;
  late wad.WadResources resources;
  late wad.MapData map;

  setUp(() {
    backend = FakeGpuBackend();
    final set = wad.DoomFixtures.wadSet();
    resources = wad.WadResources.load(set);
    map = wad.MapData.load(set, wad.DoomFixtures.mapName);
    level = geometry.DoomGeometryCompiler.compile(map, resources);
  });

  test('production bridge preserves mesh identity and atlas bytes', () {
    final scene = DoomScene.fromCompiledLevel(level, resources);
    expect(
      scene.surfaceCount,
      level.meshes.length + (level.skyTextureEntry == null ? 0 : 1),
    );
    for (var i = 0; i < level.meshes.length; i++) {
      expect(
        identical(
          scene.surfaceForMesh(i).packedVertices,
          level.meshes[i].vertices,
        ),
        isTrue,
        reason: 'mesh $i must not be copied or merged again',
      );
    }

    final page = level.atlas.pages.first;
    final data = PaletteTextureData.fromDoomResources(
      page: page,
      resources: resources,
    );
    expect(identical(data.atlasRgba, page.pixels), isTrue);
    expect(data.atlasCoverageAt(0, 0), page.pixels[1]);
    expect(data.paletteRows, resources.playpal.palettes.length);
    expect(data.colorMapRows, resources.colormap.maps.length);
  });

  test('legitimate zero-atlas level publishes no dangling surface', () {
    final empty = geometry.CompiledLevel(
      meshes: const <geometry.PackedMesh>[],
      atlas: const geometry.IndexedAtlas(
        pages: <geometry.AtlasPage>[],
        pageSize: 2048,
        entries: <String, geometry.AtlasEntry>{},
        overflowed: <String>[],
        totalPixels: 0,
      ),
      floorPlanes: const <geometry.SectorPlaneRef>[],
      ceilingPlanes: const <geometry.SectorPlaneRef>[],
      wallBands: const <geometry.WallBandRef>[],
      report: level.report,
      skyTextureName: null,
    );
    final scene = DoomScene.fromCompiledLevel(empty, resources);
    expect(scene.surfaceCount, 0);
    expect(scene.root.children, isEmpty);
  });

  test('floor cycles touch exact ranges and never recreate a buffer', () {
    final diagnostics = RenderDiagnostics();
    final scene = DoomScene.fromCompiledLevel(
      level,
      resources,
      diagnostics: diagnostics,
    );
    for (final surface in scene.surfaces) {
      surface.resource;
    }
    final initialBuffers = backend.buffers.length;
    final plane = level.floorPlanes.first;
    final untouched = <int, Float32List>{};
    for (var i = 0; i < level.meshes.length; i++) {
      untouched[i] = Float32List.fromList(level.meshes[i].vertices);
    }

    for (var cycle = 1; cycle <= 12; cycle++) {
      final height = plane.baseHeight + cycle;
      expect(
        scene.updateSectorPlane(
          sectorIndex: plane.sector,
          height: height,
          isCeiling: false,
        ),
        isTrue,
      );
      expect(scene.flushPendingUploads(), plane.ranges.length);
      for (final range in plane.ranges) {
        final fake = backend.buffers[range.meshIndex];
        final upload = fake.writeRanges.last;
        expect(upload.$1, DoomVertexAbi.byteOffsetOf(range.firstVertex));
        expect(upload.$2, range.vertexCount * DoomVertexAbi.bytesPerVertex);
      }
    }

    final addressed = <int, Set<int>>{};
    for (final range in plane.ranges) {
      addressed
          .putIfAbsent(range.meshIndex, () => <int>{})
          .addAll(
            Iterable<int>.generate(
              range.vertexCount,
              (i) => range.firstVertex + i,
            ),
          );
    }
    for (var meshIndex = 0; meshIndex < level.meshes.length; meshIndex++) {
      final source = untouched[meshIndex]!;
      final now = level.meshes[meshIndex].vertices;
      for (
        var vertex = 0;
        vertex < level.meshes[meshIndex].vertexCount;
        vertex++
      ) {
        if (addressed[meshIndex]?.contains(vertex) ?? false) {
          continue;
        }
        final offset = vertex * DoomVertexAbi.floatsPerVertex;
        expect(
          now.sublist(offset, offset + DoomVertexAbi.floatsPerVertex),
          source.sublist(offset, offset + DoomVertexAbi.floatsPerVertex),
          reason: 'unrelated mesh $meshIndex vertex $vertex changed',
        );
      }
    }
    expect(backend.buffers.length, initialBuffers);
    expect(diagnostics.gpuBuffersCreated, initialBuffers);
  });

  test('animation and switch rewrite packed atlas rect values', () {
    final scene = DoomScene.fromCompiledLevel(level, resources);
    for (final surface in scene.surfaces) {
      surface.resource;
    }
    final int buffers = backend.buffers.length;
    final animation = level.animations.first;
    final geometry.AtlasEntry animated =
        animation.frames[animation.frameAt(animation.speed)];
    expect(scene.updateAnimationFrames(animation.speed), greaterThan(0));
    for (final geometry.VertexRange range in animation.ranges) {
      expectPackedAtlasRect(level, range, animated);
    }
    expect(scene.flushPendingUploads(), greaterThan(0));
    for (final geometry.VertexRange range in animation.ranges) {
      final FakeGpuBuffer buffer = backend.buffers[range.meshIndex];
      for (
        var vertex = range.firstVertex;
        vertex < range.firstVertex + range.vertexCount;
        vertex++
      ) {
        final int rectByteOffset =
            DoomVertexAbi.byteOffsetOf(vertex) +
            geometry.DoomVertexAbi.atlasRectOffset *
                Float32List.bytesPerElement;
        expect(
          <double>[
            for (var component = 0; component < 4; component++)
              buffer.floatAt(
                rectByteOffset + component * Float32List.bytesPerElement,
              ),
          ],
          <double>[
            animated.u0(level.atlas.pageSize),
            animated.v0(level.atlas.pageSize),
            animated.u1(level.atlas.pageSize),
            animated.v1(level.atlas.pageSize),
          ],
          reason: 'uploaded mesh ${range.meshIndex} vertex $vertex atlas rect',
        );
      }
    }
    expect(backend.buffers.length, buffers, reason: 'no buffer recreation');

    final geometry.WallBandRef switchBand = level.wallBands.firstWhere(
      (geometry.WallBandRef band) => band.textureName == 'SW1COMP',
    );
    expect(
      scene.updateSwitchTexture(
        core.SwitchTextureChange(
          linedef: switchBand.linedef,
          sidedef: switchBand.sidedef,
          slot: core.SwitchTextureSlot.middle,
          textureName: 'SW2COMP',
          tic: 1,
        ),
      ),
      geometry.WallBandRef.verticesPerQuad,
    );
    final geometry.AtlasEntry switched = level.atlas.entry('SW2COMP')!;
    final int rectOffset =
        switchBand.firstVertex * geometry.DoomVertexAbi.floatsPerVertex +
        geometry.DoomVertexAbi.atlasRectOffset;
    expect(
      level.meshes[switchBand.meshIndex].vertices[rectOffset],
      switched.u0(level.atlas.pageSize),
    );
    expect(scene.flushPendingUploads(), 1);
    expect(backend.buffers.length, buffers);
  });

  test('scrolling wall dirties and uploads only its four vertices', () {
    final geometry.WallBandRef source = level.wallBands.first;
    final geometry.WallBandRef scrolling = geometry.WallBandRef(
      linedef: source.linedef,
      sidedef: source.sidedef,
      textureName: source.textureName,
      band: source.band,
      frontSector: source.frontSector,
      backSector: source.backSector,
      meshIndex: source.meshIndex,
      firstVertex: source.firstVertex,
      lowerUnpegged: source.lowerUnpegged,
      upperUnpegged: source.upperUnpegged,
      textureHeight: source.textureHeight,
      textureWidth: 64,
      baseULeft: level.meshes[source.meshIndex].vertexU(source.firstVertex),
      baseURight: level.meshes[source.meshIndex].vertexU(
        source.firstVertex + 1,
      ),
      scrollsHorizontally: true,
      yOffset: source.yOffset,
      rawYOffset: source.rawYOffset,
      nearCeilingAnchor: source.nearCeilingAnchor,
      atlasV0: source.atlasV0,
      atlasV1: source.atlasV1,
      baseBottom: source.baseBottom,
      baseTop: source.baseTop,
    );
    final geometry.CompiledLevel scrollingLevel = geometry.CompiledLevel(
      meshes: level.meshes,
      atlas: level.atlas,
      floorPlanes: level.floorPlanes,
      ceilingPlanes: level.ceilingPlanes,
      wallBands: <geometry.WallBandRef>[scrolling, ...level.wallBands.skip(1)],
      animations: level.animations,
      switchFrames: level.switchFrames,
      report: level.report,
      skyTextureName: level.skyTextureName,
    );
    final DoomScene scene = DoomScene.fromCompiledLevel(
      scrollingLevel,
      resources,
    );
    for (final surface in scene.surfaces) {
      surface.resource;
    }

    expect(
      scene.updateTextureAnimations(1),
      geometry.WallBandRef.verticesPerQuad,
    );
    expect(scene.flushPendingUploads(), 1);
    final FakeGpuBuffer buffer = backend.buffers[scrolling.meshIndex];
    expect(buffer.writeRanges.last, (
      DoomVertexAbi.byteOffsetOf(scrolling.firstVertex),
      geometry.WallBandRef.verticesPerQuad * DoomVertexAbi.bytesPerVertex,
    ));
  });

  test(
    'floor-flat transfer dirties exact ranges without recreating buffers',
    () {
      final scene = DoomScene.fromCompiledLevel(level, resources);
      for (final surface in scene.surfaces) {
        surface.resource;
      }
      final int buffers = backend.buffers.length;
      final geometry.SectorPlaneRef plane = level.floorPlanes.firstWhere(
        (geometry.SectorPlaneRef item) => level.atlas.entries.values.any(
          (geometry.AtlasEntry entry) =>
              entry.name != item.textureName &&
              entry.tiling &&
              entry.width == 64 &&
              entry.height == 64 &&
              entry.page == level.meshes[item.ranges.first.meshIndex].atlasPage,
        ),
      );
      final geometry.AtlasEntry replacement = level.atlas.entries.values
          .firstWhere(
            (geometry.AtlasEntry entry) =>
                entry.name != plane.textureName &&
                entry.tiling &&
                entry.width == 64 &&
                entry.height == 64 &&
                entry.page ==
                    level.meshes[plane.ranges.first.meshIndex].atlasPage,
          );

      expect(
        scene.updateSectorFloorFlat(
          sectorIndex: plane.sector,
          flatName: replacement.name,
        ),
        plane.vertexCount,
      );
      for (final geometry.VertexRange range in plane.ranges) {
        expectPackedAtlasRect(level, range, replacement);
      }
      expect(scene.flushPendingUploads(), plane.ranges.length);
      expect(backend.buffers.length, buffers, reason: 'no buffer recreation');
    },
  );

  test('external plane and wall mutations keep cached positions coherent', () {
    final scene = DoomScene.fromCompiledLevel(level, resources);
    for (final surface in scene.surfaces) {
      surface
        ..positions
        ..resource;
    }
    final bufferCount = backend.buffers.length;
    final floor = level.floorPlanes.first;
    final floorHeight = floor.baseHeight + 17;
    scene.updateSectorPlane(
      sectorIndex: floor.sector,
      height: floorHeight,
      isCeiling: false,
    );
    for (final range in floor.ranges) {
      final surface = scene.surfaceForMesh(range.meshIndex);
      for (
        var vertex = range.firstVertex;
        vertex < range.firstVertex + range.vertexCount;
        vertex++
      ) {
        expect(surface.positions[vertex * 3 + 1], floorHeight);
        expect(
          surface.positions[vertex * 3 + 1],
          DoomVertexAbi.getY(surface.packedVertices, vertex),
        );
      }
    }

    final floors = <double>[
      for (final sector in map.sectors) sector.floorHeight.toDouble(),
    ];
    final ceilings = <double>[
      for (final sector in map.sectors) sector.ceilingHeight.toDouble(),
    ];
    floors[floor.sector] = floorHeight;
    final wall = level.wallBands.first;
    final sector = wall.frontSector;
    floors[sector] += 9;
    scene.updateWallsForSector(
      sectorIndex: sector,
      floorHeight: floors[sector],
      ceilingHeight: ceilings[sector],
      sectorFloors: floors,
      sectorCeilings: ceilings,
    );
    for (final band in level.wallBands) {
      if (band.frontSector != sector && band.backSector != sector) {
        continue;
      }
      final surface = scene.surfaceForMesh(band.meshIndex);
      for (
        var vertex = band.firstVertex;
        vertex < band.firstVertex + geometry.WallBandRef.verticesPerQuad;
        vertex++
      ) {
        expect(
          surface.positions[vertex * 3 + 1],
          DoomVertexAbi.getY(surface.packedVertices, vertex),
        );
      }
    }
    scene.flushPendingUploads();
    expect(backend.buffers.length, bufferCount);
  });

  test(
    'ceiling and wall cycles keep buffers flat and mark referenced quads',
    () {
      final scene = DoomScene.fromCompiledLevel(level, resources);
      for (final surface in scene.surfaces) {
        surface.resource;
      }
      final initialBuffers = backend.buffers.length;
      final ceiling = level.ceilingPlanes.first;
      final floors = <double>[
        for (final sector in map.sectors) sector.floorHeight.toDouble(),
      ];
      final ceilings = <double>[
        for (final sector in map.sectors) sector.ceilingHeight.toDouble(),
      ];
      final wall = level.wallBands.first;
      final wallSector = wall.frontSector;

      for (var cycle = 1; cycle <= 8; cycle++) {
        final ceilingHeight = ceiling.baseHeight - cycle;
        scene.updateSectorPlane(
          sectorIndex: ceiling.sector,
          height: ceilingHeight,
          isCeiling: true,
        );
        ceilings[ceiling.sector] = ceilingHeight;
        scene.flushPendingUploads();
        final floorHeight = floors[wallSector] + cycle;
        floors[wallSector] = floorHeight;
        final wallBuffer =
            scene.surfaceForMesh(wall.meshIndex).resource as FakeGpuBuffer;
        final writesBefore = wallBuffer.writeRanges.length;
        expect(
          scene.updateWallsForSector(
            sectorIndex: wallSector,
            floorHeight: floorHeight,
            ceilingHeight: ceilings[wallSector],
            sectorFloors: floors,
            sectorCeilings: ceilings,
          ),
          greaterThan(0),
        );
        scene.flushPendingUploads();
        if (cycle == 8) {
          final affected = <(int, int)>[
            for (final band in level.wallBands)
              if ((band.frontSector == wallSector ||
                      band.backSector == wallSector) &&
                  band.meshIndex == wall.meshIndex)
                (
                  band.firstVertex,
                  band.firstVertex + geometry.WallBandRef.verticesPerQuad - 1,
                ),
          ]..sort((a, b) => a.$1.compareTo(b.$1));
          final merged = <(int, int)>[];
          for (final range in affected) {
            if (merged.isEmpty || merged.last.$2 + 1 < range.$1) {
              merged.add(range);
            } else if (range.$2 > merged.last.$2) {
              merged[merged.length - 1] = (merged.last.$1, range.$2);
            }
          }
          expect(wallBuffer.writeRanges.sublist(writesBefore), <(int, int)>[
            for (final range in merged)
              (
                DoomVertexAbi.byteOffsetOf(range.$1),
                (range.$2 - range.$1 + 1) * DoomVertexAbi.bytesPerVertex,
              ),
          ]);
        }
      }

      expect(backend.buffers.length, initialBuffers);
    },
  );

  test(
    'sky is a fullbright camera-centred cube with world-fixed orientation',
    () {
      final skyName = level.atlas.entries.keys.first;
      final skyLevel = geometry.CompiledLevel(
        meshes: level.meshes,
        atlas: level.atlas,
        floorPlanes: level.floorPlanes,
        ceilingPlanes: level.ceilingPlanes,
        wallBands: level.wallBands,
        report: level.report,
        skyTextureName: skyName,
      );
      final scene = DoomScene.fromCompiledLevel(skyLevel, resources);
      final sky = scene.root.children.whereType<SkyMeshComponent>().single;
      final camera = CameraComponent3D(
        position: Vector3(4, 5, 6),
        target: Vector3(5, 5, 6),
      );
      sky.syncToCamera(camera);
      expect(sky.position, camera.position);
      final before = sky.rotation.clone();
      camera.target.setValues(4, 5, 5);
      sky.syncToCamera(camera);
      expect(sky.rotation, before, reason: 'sky orientation stays world-fixed');
      final surface = sky.mesh.surfaces.single as PackedFlameSurface;
      expect(surface.kind, DoomSurfaceKind.sky);
      expect(surface.vertexCount, 24);
      expect(surface.packedVertices[DoomVertexAbi.paramsOffset], 1);
      expect(surface.packedVertices[DoomVertexAbi.paramsOffset + 3], 1);
      final localUByFace = <List<double>>[
        for (var face = 0; face < 6; face++)
          <double>[
            for (var vertex = 0; vertex < 4; vertex++)
              surface.packedVertices[DoomVertexAbi.floatOffsetOf(
                    face * 4 + vertex,
                  ) +
                  DoomVertexAbi.texCoordOffset],
          ],
      ];
      expect(localUByFace[0], <double>[0, 0.25, 0.25, 0]);
      expect(localUByFace[3], <double>[0.25, 0.5, 0.5, 0.25]);
      expect(localUByFace[1], <double>[0.5, 0.75, 0.75, 0.5]);
      expect(localUByFace[2], <double>[0.75, 1, 1, 0.75]);
      expect(localUByFace[4], <double>[0, 1, 1, 0]);
      expect(localUByFace[5], <double>[0, 1, 1, 0]);
      for (var face = 0; face < 6; face++) {
        final params =
            DoomVertexAbi.floatOffsetOf(face * 4) + DoomVertexAbi.paramsOffset;
        expect(surface.packedVertices[params + 2], DoomVertexAbi.uvModeClamp);
      }
    },
  );

  test('weapon follows target-derived yaw and pitch', () {
    final mesh = Mesh();
    final weapon = ViewLockedWeaponComponent(mesh: mesh);
    final camera = CameraComponent3D(
      position: Vector3.zero(),
      target: Vector3(0, 0, -1),
    );
    weapon.syncToCamera(camera);
    final forward = camera.forward.normalized();
    expect(weapon.position.dot(forward), closeTo(weapon.weaponDistance, 1e-6));

    camera.target.setValues(1, 0, 0);
    weapon.syncToCamera(camera);
    expect(weapon.position.x, closeTo(weapon.weaponDistance, 1e-6));
    expect(weapon.position.z, closeTo(0, 1e-6));

    camera.target.setValues(0, 1, -1);
    weapon.syncToCamera(camera);
    expect(weapon.position.y, greaterThan(0));
    expect(weapon.position.z, lessThan(0));
  });

  test('billboard stays upright around four camera headings', () {
    final billboard = YawBillboardMeshComponent(
      mesh: Mesh(),
      position: Vector3.zero(),
    );
    final camera = CameraComponent3D();
    for (final point in <Vector3>[
      Vector3(10, 7, 0),
      Vector3(0, -3, 10),
      Vector3(-10, 100, 0),
      Vector3(0, 0, -10),
    ]) {
      camera.position.setFrom(point);
      billboard.syncToCamera(camera);
      final up = billboard.rotation.rotated(Vector3(0, 1, 0));
      expect(up.x, closeTo(0, 1e-6));
      expect(up.y, closeTo(1, 1e-6));
      expect(up.z, closeTo(0, 1e-6));
    }
  });

  test('actor API creates one masked yaw billboard per instance', () {
    final scene = DoomScene.fromCompiledLevel(
      level,
      resources,
      spritePrefixes: const <String>{'TEST'},
    );
    final before = scene.surfaceCount;
    final actor = scene.addActorSprite(
      const ActorSpriteInstance(
        spritePrefix: 'TEST',
        x: 10,
        y: 2,
        z: -4,
        width: 32,
        height: 56,
      ),
    );
    expect(scene.surfaceCount, before + 1);
    expect(actor.mesh.surfaces.single, isA<PackedFlameSurface>());
    expect(
      (actor.mesh.surfaces.single as PackedFlameSurface).kind,
      DoomSurfaceKind.sprite,
    );
    final vertices = actor.surface.packedVertices;
    expect(vertices[0], -16, reason: 'leftOffset scales with width override');
    expect(vertices[DoomVertexAbi.floatOffsetOf(1)], 16);
    expect(vertices[1], -3.5, reason: 'bottom is topOffset-height');
    expect(vertices[DoomVertexAbi.floatOffsetOf(2) + 1], 52.5);

    final native = scene.addActorSprite(
      const ActorSpriteInstance(spritePrefix: 'TEST', x: 0, y: 0, z: 0),
    );
    expect(native.surface.aabb.min.x, -32);
    expect(native.surface.aabb.max.x, 32);
    expect(native.surface.aabb.min.y, -4);
    expect(native.surface.aabb.max.y, 60);

    native.surface.resource;
    final buffers = backend.buffers.length;
    native.updateActor(
      x: 20,
      y: 3,
      z: -8,
      frame: 1,
      actorAngle: math.pi / 2,
      light: 0.4,
      fullBright: true,
    );
    final camera = CameraComponent3D(position: Vector3(20, 3, 24));
    native.syncToCamera(camera);
    native.surface.resource;
    expect(native.position, Vector3(20, 3, -8));
    expect(native.frame, 1);
    expect(native.actorAngle, math.pi / 2);
    expect(native.lumpName, 'TESTB0');
    expect(
      native.surface.packedVertices[DoomVertexAbi.lightOffset],
      closeTo(0.4, 1e-6),
    );
    expect(native.surface.packedVertices[DoomVertexAbi.paramsOffset], 1);
    expect(backend.buffers.length, buffers);
  });

  test(
    'actor view rotations update rect and mirror without buffer recreation',
    () {
      const names = <String>[
        'TROOA1',
        'TROOA2A8',
        'TROOA3A7',
        'TROOA4A6',
        'TROOA5',
      ];
      final rotated = wad.WadFile.parse(
        wad.buildWad(<wad.LumpSource>[
          wad.LumpSource.marker('S_START'),
          for (final name in names)
            wad.LumpSource(
              name,
              wad.encodeDoomPatch(wad.buildFixtureSprite(name)),
            ),
          wad.LumpSource.marker('S_END'),
        ]),
      );
      final set = wad.WadSet(<wad.WadFile>[wad.DoomFixtures.wad(), rotated]);
      final rotatedResources = wad.WadResources.load(set);
      final rotatedMap = wad.MapData.load(set, wad.DoomFixtures.mapName);
      final rotatedLevel = geometry.DoomGeometryCompiler.compile(
        rotatedMap,
        rotatedResources,
      );
      final scene = DoomScene.fromCompiledLevel(
        rotatedLevel,
        rotatedResources,
        spritePrefixes: const <String>{'TROO'},
      );
      final actor = scene.addActorSprite(
        const ActorSpriteInstance(
          spritePrefix: 'TROO',
          x: 0,
          y: 0,
          z: 0,
          actorAngle: 0,
        ),
      );
      actor.surface.resource;
      final bufferCount = backend.buffers.length;
      final camera = CameraComponent3D(target: Vector3(0, 0, -1));
      final seen = <String>{};
      var sawMirror = false;
      for (var i = 0; i < 8; i++) {
        camera.position.setValues(
          math.sin(i * math.pi / 4) * 32,
          16,
          math.cos(i * math.pi / 4) * 32,
        );
        scene.syncToCamera(camera);
        actor.surface.resource;
        seen.add(actor.lumpName);
        sawMirror = sawMirror || actor.mirrored;
      }
      expect(seen, containsAll(names));
      expect(sawMirror, isTrue);
      expect(backend.buffers.length, bufferCount);
    },
  );

  test('weapon frame swaps atlas rect without recreating its buffer', () {
    final scene = DoomScene.fromCompiledLevel(
      level,
      resources,
      spritePrefixes: const <String>{'TEST'},
    );
    final weapon = scene.addWeaponSprite(
      const WeaponSpriteInstance(
        lumpName: 'TESTA0',
        viewAnchorX: 0,
        viewAnchorY: 0,
      ),
    );
    weapon.surface.resource;
    expect(weapon.surface.packedVertices[DoomVertexAbi.paramsOffset + 3], -1);
    expect(weapon.surface.aabb.min.x, closeTo(-0.1, 1e-6));
    expect(weapon.surface.aabb.max.x, closeTo(0.1, 1e-6));
    expect(weapon.surface.aabb.min.y, closeTo(-0.02, 1e-6));
    expect(weapon.surface.aabb.max.y, closeTo(0.3, 1e-6));
    final buffers = backend.buffers.length;
    expect(weapon.setFrame('TESTB0'), isTrue);
    expect(weapon.surface.hasPendingUpload, isTrue);
    weapon.surface.resource;
    expect(backend.buffers.length, buffers);
    expect(weapon.lumpName, 'TESTB0');
  });

  test('weapon psprite anchor and frame swap honor patch offsets', () {
    wad.PatchImage patch(
      int width,
      int height,
      int leftOffset,
      int topOffset,
      int color,
    ) => wad.PatchImage(
      width: width,
      height: height,
      leftOffset: leftOffset,
      topOffset: topOffset,
      indices: Uint8List(width * height)..fillRange(0, width * height, color),
      coverage: Uint8List(width * height)..fillRange(0, width * height, 255),
    );

    final weaponWad = wad.WadFile.parse(
      wad.buildWad(<wad.LumpSource>[
        wad.LumpSource.marker('S_START'),
        wad.LumpSource('GUN1A0', wad.encodeDoomPatch(patch(20, 20, 5, 10, 31))),
        wad.LumpSource(
          'GUN1B0',
          wad.encodeDoomPatch(patch(30, 30, 12, 20, 63)),
        ),
        wad.LumpSource.marker('S_END'),
      ]),
    );
    final set = wad.WadSet(<wad.WadFile>[wad.DoomFixtures.wad(), weaponWad]);
    final weaponResources = wad.WadResources.load(set);
    final weaponMap = wad.MapData.load(set, wad.DoomFixtures.mapName);
    final weaponLevel = geometry.DoomGeometryCompiler.compile(
      weaponMap,
      weaponResources,
    );
    final scene = DoomScene.fromCompiledLevel(
      weaponLevel,
      weaponResources,
      spritePrefixes: const <String>{'GUN1'},
    );
    final weapon = scene.addWeaponSprite(
      const WeaponSpriteInstance(
        lumpName: 'GUN1A0',
        viewAnchorX: 0.25,
        viewAnchorY: -0.4,
        pixelScaleX: 0.01,
        pixelScaleY: 0.02,
      ),
    );
    expect(weapon.surface.aabb.min.x, closeTo(0.20, 1e-6));
    expect(weapon.surface.aabb.max.x, closeTo(0.40, 1e-6));
    expect(weapon.surface.aabb.min.y, closeTo(-0.60, 1e-6));
    expect(weapon.surface.aabb.max.y, closeTo(-0.20, 1e-6));
    weapon.surface.resource;
    final buffers = backend.buffers.length;

    expect(weapon.setFrame('GUN1B0'), isTrue);
    expect(weapon.surface.aabb.min.x, closeTo(0.13, 1e-6));
    expect(weapon.surface.aabb.max.x, closeTo(0.43, 1e-6));
    expect(weapon.surface.aabb.min.y, closeTo(-0.60, 1e-6));
    expect(weapon.surface.aabb.max.y, closeTo(0.00, 1e-6));
    weapon.surface.resource;
    expect(backend.buffers.length, buffers);
  });

  test('same atlas key with new textures never reuses stale bindings', () {
    final cache = PaletteMaterialCache();
    final first = DoomScene.fromCompiledLevel(
      level,
      resources,
      materials: cache,
    );
    final firstMaterial = first.surfaces.first.material as PaletteMaterial;

    final secondSet = wad.DoomFixtures.wadSet();
    final secondResources = wad.WadResources.load(secondSet);
    final secondMap = wad.MapData.load(secondSet, wad.DoomFixtures.mapName);
    final secondLevel = geometry.DoomGeometryCompiler.compile(
      secondMap,
      secondResources,
    );
    final second = DoomScene.fromCompiledLevel(
      secondLevel,
      secondResources,
      materials: cache,
    );
    final secondMaterial = second.surfaces.first.material as PaletteMaterial;
    expect(identical(firstMaterial, secondMaterial), isFalse);
    expect(identical(firstMaterial.textures, secondMaterial.textures), isFalse);
  });
}
