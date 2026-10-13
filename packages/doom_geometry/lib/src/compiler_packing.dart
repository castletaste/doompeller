part of 'compiler.dart';

extension _CompilerPacking on _Compiler {
  void _gatherBspMeshes(
    List<BspRegion> regions,
    List<SectorMesh2D> out,
    Int32List emptyPerSector,
    CheckBudget budget,
  ) {
    final int sectorCount = out.length;
    final List<List<double>> verts = List<List<double>>.generate(
      sectorCount,
      (int _) => <double>[],
      growable: false,
    );
    final List<List<int>> tris = List<List<int>>.generate(
      sectorCount,
      (int _) => <int>[],
      growable: false,
    );

    for (var r = 0; r < regions.length; r++) {
      final BspRegion region = regions[r];
      final int sector = region.sector;
      if (sector < 0 || sector >= sectorCount) {
        continue;
      }
      if (region.isEmpty) {
        emptyPerSector[sector]++;
        continue;
      }
      // Convex by construction. Fan from an inserted centre rather than a
      // boundary corner: every repaired boundary edge becomes one real
      // triangle, even when all four sides contain collinear inserted points.
      final int base = verts[sector].length ~/ 2;
      final TriangulationResult triangulation = triangulateConvexBoundary(
        region.xy,
        epsilon: options.epsilon * options.epsilon,
      );
      if (!triangulation.isComplete || triangulation.triangleCount == 0) {
        emptyPerSector[sector]++;
        budget.spend();
        continue;
      }
      verts[sector].addAll(triangulation.vertices);
      for (final int index in triangulation.indices) {
        tris[sector].add(base + index);
      }
      budget.spend();
    }
    for (var s = 0; s < sectorCount; s++) {
      out[s] = SectorMesh2D(
        Float64List.fromList(verts[s]),
        Uint32List.fromList(tris[s]),
      );
    }
  }

  SectorMesh2D _loopMesh(SectorLoopResult loop) {
    final List<double> verts = <double>[];
    final List<int> tris = <int>[];
    for (var i = 0; i < loop.triangulation.length; i++) {
      final TriangulationResult t = loop.triangulation[i];
      final int base = verts.length ~/ 2;
      for (var v = 0; v < t.vertices.length; v++) {
        verts.add(t.vertices[v]);
      }
      for (var k = 0; k < t.indices.length; k++) {
        tris.add(base + t.indices[k]);
      }
    }
    return SectorMesh2D(Float64List.fromList(verts), Uint32List.fromList(tris));
  }

  void _packPlanes(
    List<SectorMesh2D> sectorMeshes,
    IndexedAtlas atlas,
    List<SectorPlaneRef> floors,
    List<SectorPlaneRef> ceilings,
  ) {
    for (var s = 0; s < sectorMeshes.length; s++) {
      final SectorMesh2D mesh = sectorMeshes[s];
      if (mesh.triangleCount == 0) {
        continue;
      }
      final Sector sector = map.sectors[s];
      final double light = sector.lightLevel / 255.0;
      final SectorPlaneRef? floor = sector.floorIsSky
          ? null
          : _packPlane(
              mesh: mesh,
              sector: s,
              height: sector.floorHeight.toDouble(),
              flatName: sector.floorFlat,
              isCeiling: false,
              atlas: atlas,
              light: light,
            );
      if (floor != null) {
        floors.add(floor);
      }
      final SectorPlaneRef? ceiling = sector.ceilingIsSky
          ? null
          : _packPlane(
              mesh: mesh,
              sector: s,
              height: sector.ceilingHeight.toDouble(),
              flatName: sector.ceilingFlat,
              isCeiling: true,
              atlas: atlas,
              light: light,
            );
      if (ceiling != null) {
        ceilings.add(ceiling);
      }
    }
  }

  SectorPlaneRef? _packPlane({
    required SectorMesh2D mesh,
    required int sector,
    required double height,
    required String flatName,
    required bool isCeiling,
    required IndexedAtlas atlas,
    required double light,
  }) {
    final AtlasEntry? entry = atlas.entry(flatName);
    const SurfaceKind kind = SurfaceKind.opaque;
    final int page = entry?.page ?? 0;
    final int vertexCount = mesh.vertexCount;
    if (vertexCount == 0) {
      return null;
    }
    final Float64List positions = Float64List(vertexCount * 3);
    final Float64List uvs = Float64List(vertexCount * 2);
    final FlatUvMapper? mapper = entry == null
        ? null
        : FlatUvMapper(entry, atlas.pageSize);
    for (var v = 0; v < vertexCount; v++) {
      final double mx = mesh.xy[v * 2];
      final double my = mesh.xy[v * 2 + 1];
      positions[v * 3] = DoomVertexAbi.worldX(mx);
      positions[v * 3 + 1] = DoomVertexAbi.worldY(height);
      positions[v * 3 + 2] = DoomVertexAbi.worldZ(my);
      uvs[v * 2] = mapper == null ? 0 : mapper.u(mx);
      uvs[v * 2 + 1] = mapper == null ? 0 : mapper.v(my);
    }
    // Map winding is counter-clockwise seen from above. A floor is viewed from
    // above so it keeps that order with an up normal; a ceiling is viewed from
    // below, so its triangles are reversed and its normal points down.
    final List<int> indices = <int>[];
    for (var t = 0; t < mesh.indices.length; t += 3) {
      if (isCeiling) {
        indices
          ..add(mesh.indices[t])
          ..add(mesh.indices[t + 2])
          ..add(mesh.indices[t + 1]);
      } else {
        indices
          ..add(mesh.indices[t])
          ..add(mesh.indices[t + 1])
          ..add(mesh.indices[t + 2]);
      }
    }
    final List<VertexRange> ranges = _packer.addPrimitive(
      page: page,
      kind: kind,
      positions: positions,
      uvs: uvs,
      indices: indices,
      normalX: 0,
      normalY: isCeiling ? -1 : 1,
      normalZ: 0,
      light: light,
      // Flats tile: a floor's UVs run past 1 whenever the sector is bigger
      // than 64 units, and the shader wraps inside this rect.
      atlasU0: entry?.u0(atlas.pageSize) ?? 0,
      atlasV0: entry?.v0(atlas.pageSize) ?? 0,
      atlasU1: entry?.u1(atlas.pageSize) ?? 1,
      atlasV1: entry?.v1(atlas.pageSize) ?? 1,
      uvMode: DoomVertexAbi.uvModeRepeat,
      // Sky is drawn at full brightness; vanilla never darkens it with
      // distance the way it darkens walls and floors.
      fullBright: false,
    );
    return SectorPlaneRef(
      sector: sector,
      isCeiling: isCeiling,
      textureName: flatName,
      ranges: ranges,
      baseHeight: height,
    );
  }

  List<WallBandRef> _packWalls(WallSet walls, IndexedAtlas atlas) {
    final List<WallBandRef> bands = <WallBandRef>[];
    final Float64List positions = Float64List(12);
    final Float64List uvs = Float64List(8);
    const List<int> quadIndices = <int>[0, 1, 2, 0, 2, 3];

    for (var i = 0; i < walls.quads.length; i++) {
      final WallQuad quad = walls.quads[i];
      if (!quad.hasTexture || (quad.x1 == quad.x2 && quad.y1 == quad.y2)) {
        continue;
      }
      final AtlasEntry? entry = atlas.entry(quad.texture);
      final int page = entry?.page ?? 0;
      final int pageSize = atlas.pageSize;

      // Quad vertex order: 0 bottom-left, 1 bottom-right, 2 top-right,
      // 3 top-left, matching what WallBandRef rewrites in place.
      positions[0] = DoomVertexAbi.worldX(quad.x1);
      positions[1] = DoomVertexAbi.worldY(quad.bottom);
      positions[2] = DoomVertexAbi.worldZ(quad.y1);
      positions[3] = DoomVertexAbi.worldX(quad.x2);
      positions[4] = DoomVertexAbi.worldY(quad.bottom);
      positions[5] = DoomVertexAbi.worldZ(quad.y2);
      positions[6] = DoomVertexAbi.worldX(quad.x2);
      positions[7] = DoomVertexAbi.worldY(quad.top);
      positions[8] = DoomVertexAbi.worldZ(quad.y2);
      positions[9] = DoomVertexAbi.worldX(quad.x1);
      positions[10] = DoomVertexAbi.worldY(quad.top);
      positions[11] = DoomVertexAbi.worldZ(quad.y1);

      final double texW = quad.textureWidth > 0 ? quad.textureWidth : 64.0;
      final double texH = quad.textureHeight > 0 ? quad.textureHeight : 128.0;
      final double u0 = entry == null ? 0 : entry.u0(pageSize);
      final double uSpan = entry == null ? 1 : entry.width / pageSize;
      final double v0 = entry == null ? 0 : entry.v0(pageSize);
      final double vSpan = entry == null ? 1 : entry.height / pageSize;

      // Texture-local coordinates. Atlas rect mapping happens exactly once in
      // the shader, after repeat/clamp resolution.
      final double uA = quad.uLeft / texW;
      final double uB = quad.uRight / texW;
      final double vTop = quad.yOffset / texH;
      final double vBottom = (quad.yOffset + quad.height) / texH;

      uvs[0] = uA;
      uvs[1] = vBottom;
      uvs[2] = uB;
      uvs[3] = vBottom;
      uvs[4] = uB;
      uvs[5] = vTop;
      uvs[6] = uA;
      uvs[7] = vTop;

      // Wall normal: perpendicular to the linedef, pointing into the sector
      // this side faces. In world space the map direction (dx, dy) becomes
      // (dx, 0, -dy), whose right-hand perpendicular is (-dy, 0, -dx).
      final double dx = quad.x2 - quad.x1;
      final double dy = quad.y2 - quad.y1;
      final double len = _length(dx, dy);
      final double nx = len > 0 ? dy / len : 0;
      final double nz = len > 0 ? dx / len : 0;

      final List<VertexRange> ranges = _packer.addPrimitive(
        page: page,
        kind: quad.kind,
        positions: positions,
        uvs: uvs,
        indices: quadIndices,
        normalX: nx,
        normalY: 0,
        normalZ: nz,
        light: quad.lightLevel,
        // Walls tile horizontally across a long linedef and vertically when a
        // band is taller than its texture.
        atlasU0: u0,
        atlasV0: v0,
        atlasU1: u0 + uSpan,
        atlasV1: v0 + vSpan,
        uvMode: DoomVertexAbi.uvModeRepeat,
      );
      bands.add(
        WallBandRef(
          linedef: quad.linedef,
          sidedef: quad.sidedef,
          textureName: quad.texture,
          band: quad.band,
          frontSector: quad.frontSector,
          backSector: quad.backSector,
          meshIndex: ranges.single.meshIndex,
          firstVertex: ranges.single.firstVertex,
          lowerUnpegged: quad.lowerUnpegged,
          upperUnpegged: quad.upperUnpegged,
          textureHeight: texH,
          textureWidth: texW,
          baseULeft: uA,
          baseURight: uB,
          scrollsHorizontally:
              map.linedefs[quad.linedef].special == 48 &&
              quad.sidedef == map.linedefs[quad.linedef].rightSidedef,
          yOffset: quad.yOffset,
          rawYOffset: quad.rawYOffset,
          nearCeilingAnchor: quad.nearCeiling,
          atlasV0: v0,
          atlasV1: v0 + vSpan,
          baseBottom: quad.bottom,
          baseTop: quad.top,
        ),
      );
    }
    return bands;
  }

  List<AnimatedSurfaceRef> _buildAnimationRefs(
    DoomAnimationResolution resolution,
    IndexedAtlas atlas,
    List<SectorPlaneRef> floors,
    List<SectorPlaneRef> ceilings,
    List<WallBandRef> bands,
  ) {
    final List<AnimatedSurfaceRef> result = <AnimatedSurfaceRef>[];
    for (final DoomAnimation animation in resolution.animations) {
      final List<AtlasEntry?> resolvedFrames = <AtlasEntry?>[
        for (final String name in animation.frames) atlas.entry(name),
      ];
      // A real IWAD publishes many valid animation ranges that a particular
      // map never references. Only used ranges were queued into this level's
      // bounded atlas, so absent entries here mean "unused", not corruption.
      if (resolvedFrames.any((AtlasEntry? entry) => entry == null)) continue;
      final List<AtlasEntry> frames = resolvedFrames.cast<AtlasEntry>();
      atlas.requireSamePage(
        frames,
        description:
            'animation ${animation.definition.startName}->${animation.definition.endName}',
      );
      for (var initial = 0; initial < animation.frames.length; initial++) {
        final String name = animation.frames[initial];
        final List<VertexRange> ranges = <VertexRange>[
          for (final SectorPlaneRef plane in <SectorPlaneRef>[
            ...floors,
            ...ceilings,
          ])
            if (plane.textureName == name) ...plane.ranges,
          for (final WallBandRef band in bands)
            if (band.textureName == name)
              VertexRange(
                meshIndex: band.meshIndex,
                firstVertex: band.firstVertex,
                vertexCount: WallBandRef.verticesPerQuad,
              ),
        ];
        if (ranges.isNotEmpty) {
          result.add(
            AnimatedSurfaceRef(
              frames: frames,
              speed: animation.definition.speed,
              initialFrame: initial,
              ranges: ranges,
            ),
          );
        }
      }
    }
    return result;
  }

  List<List<String>> _flatTransferGroups() {
    const Set<int> frontModelSpecials = <int>{20, 22, 59};
    final List<List<int>> touching = List<List<int>>.generate(
      map.sectors.length,
      (_) => <int>[],
      growable: false,
    );
    for (var lineIndex = 0; lineIndex < map.linedefs.length; lineIndex++) {
      final Linedef line = map.linedefs[lineIndex];
      touching[map.sidedefs[line.rightSidedef].sector].add(lineIndex);
      if (line.leftSidedef != kNoSidedef) {
        touching[map.sidedefs[line.leftSidedef].sector].add(lineIndex);
      }
    }

    int? neighbor(int sector, int lineIndex) {
      final Linedef line = map.linedefs[lineIndex];
      if (line.leftSidedef == kNoSidedef) return null;
      final int front = map.sidedefs[line.rightSidedef].sector;
      final int back = map.sidedefs[line.leftSidedef].sector;
      if (front == sector) return back;
      if (back == sector) return front;
      return null;
    }

    final List<List<String>> groups = <List<String>>[];
    final Map<int, List<int>> sectorsByTag = <int, List<int>>{};
    for (var sector = 0; sector < map.sectors.length; sector++) {
      final int tag = map.sectors[sector].tag;
      if (tag != 0) {
        sectorsByTag.putIfAbsent(tag, () => <int>[]).add(sector);
      }
    }
    final List<int> generations = List<int>.filled(map.sectors.length, 0);
    var generation = 0;
    for (final Linedef trigger in map.linedefs) {
      if (frontModelSpecials.contains(trigger.special)) {
        final int source = map.sidedefs[trigger.rightSidedef].sector;
        for (final int target in sectorsByTag[trigger.tag] ?? const <int>[]) {
          groups.add(<String>[
            map.sectors[target].floorFlat,
            map.sectors[source].floorFlat,
          ]);
        }
      } else if (trigger.special == 37) {
        for (final int target in sectorsByTag[trigger.tag] ?? const <int>[]) {
          int? model;
          var lowest = map.sectors[target].floorHeight;
          for (final int lineIndex in touching[target]) {
            final int? other = neighbor(target, lineIndex);
            if (other != null && map.sectors[other].floorHeight < lowest) {
              lowest = map.sectors[other].floorHeight;
            }
          }
          for (final int lineIndex in touching[target]) {
            final int? other = neighbor(target, lineIndex);
            if (other != null && map.sectors[other].floorHeight == lowest) {
              model = other;
              break;
            }
          }
          if (model != null) {
            groups.add(<String>[
              map.sectors[target].floorFlat,
              map.sectors[model].floorFlat,
            ]);
          }
        }
      } else if (trigger.special == 9) {
        generation++;
        var visits = 0;
        bool visit(int sector) {
          if (generations[sector] == generation) return true;
          if (visits >= options.limits.maxSectors) return false;
          generations[sector] = generation;
          visits++;
          return true;
        }

        for (final int inner in sectorsByTag[trigger.tag] ?? const <int>[]) {
          if (visits >= options.limits.maxSectors) break;
          if (!visit(inner)) break;
          int? ring;
          for (final int lineIndex in touching[inner]) {
            final int? candidate = neighbor(inner, lineIndex);
            if (candidate != null && visit(candidate)) {
              ring = candidate;
              break;
            }
          }
          if (ring == null) continue;
          int? outer;
          for (final int lineIndex in touching[ring]) {
            final int? candidate = neighbor(ring, lineIndex);
            if (candidate != null && candidate != inner && visit(candidate)) {
              outer = candidate;
              break;
            }
          }
          if (outer != null) {
            groups.add(<String>[
              map.sectors[ring].floorFlat,
              map.sectors[outer].floorFlat,
            ]);
          }
        }
      }
    }
    return groups;
  }

  static double _length(double dx, double dy) {
    final double sq = dx * dx + dy * dy;
    return sq <= 0 ? 0 : math.sqrt(sq);
  }
}

/// Order-independent hash over emitted geometry, for regression pinning.
/// Quantised to the weld lattice before hashing so floating-point noise cannot
/// change the hash while the geometry is visually identical.
int _geometryHash(List<PackedMesh> meshes) {
  var hash = 0x811C9DC5;
  for (var m = 0; m < meshes.length; m++) {
    final PackedMesh mesh = meshes[m];
    hash = _geometryMix(hash, mesh.vertexCount);
    hash = _geometryMix(hash, mesh.indexCount);
    hash = _geometryMix(hash, mesh.atlasPage);
    hash = _geometryMix(hash, mesh.kind.index);
    for (var f = 0; f < mesh.vertices.length; f++) {
      hash = _geometryMix(hash, (mesh.vertices[f] * 128.0).round());
    }
    for (var i = 0; i < mesh.indices.length; i++) {
      hash = _geometryMix(hash, mesh.indices[i]);
    }
  }
  return hash & 0x7FFFFFFF;
}

int _geometryMix(int hash, int value) {
  var h = hash ^ (value & 0xFFFFFFFF);
  h = (h * 0x01000193) & 0xFFFFFFFF;
  return h;
}
