---
name: doompeller-geometry
description: "Implement or debug Doompeller's pure-Dart level geometry: BSP subsector recovery, sector-loop oracle, wall bands and pegging, atlas packing, packed mesh emission, and gap validation. Excludes WAD parsing, GPU code, and gameplay."
---

# Doompeller Geometry

`packages/doom_geometry` is pure Dart over `doom_wad`. Highest-risk area in the project; `docs/PLAN.md` M2 holds the acceptance criteria and the kill condition.

- BSP-first hybrid. Vanilla SEGS omit minisegs, so a subsector's segs are an open chain: clip a map-sized quad against each partition plane from the root, then against the subsector's own segs. The seg pass pins floors to real linedefs; do not drop it as an optimization.
- Cracks come from inexact shared edges. Normalize each plane once and snap emitted intersections to the shared power-of-two `weldGrid` so two subsectors clipping one plane produce bit-identical points. Changing epsilon or the grid means re-running the gap tests.
- The sector-loop path is an independent oracle and the per-sector fallback, not dead code. Never silently drop geometry: a failing sector falls back to loops and is recorded in `GeometryReport.fallbackSectors`. A missing counter in that report means unverified, not zero.
- Walls come from linedefs/sidedefs/sectors, not segs. X offset is sidedef plus accumulated linedef length; Y offset follows lower/upper unpegged; sky-to-sky uppers are not drawn. Wrong pegging is the most visible defect.
- Emit packed `Float32List` in the 20-float ABI owned by `lib/adapter/vertex_abi.dart`, split under the uint16 vertex ceiling, grouped by atlas page and surface kind. `floorPlanes`, `ceilingPlanes`, and `wallBands` are index ranges so doors and lifts rewrite heights in place; never rebuild a level mesh for a moving sector.
- Atlas is RGBA8 index plus coverage (flame_3d 0.3.0 has no R8). World tiles, sprites clamp: test the UV convention rather than tuning by eye. Bound quadratic passes with `DoomLimits.maxIntersectionChecks`.

Test concave and holed sectors, two-sided steps, sky ceilings, pegging, BSP-versus-oracle agreement, a case that actually trips T-junction detection, limit exhaustion, deterministic hashes, and vertex-ceiling splitting. `/Users/savva/fvm/versions/stable/bin/dart analyze` and `dart test`.
