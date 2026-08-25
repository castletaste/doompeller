---
name: doompeller-gameplay
description: "Implement or debug Doompeller's pure-Dart gameplay simulation: fixed-point math, BAM angles, the 35 Hz tick, movement and collision, sector effects, actors, AI, combat, and deterministic replay. Excludes WAD parsing, geometry, and GPU code."
---

# Doompeller Gameplay

`packages/doom_core` is pure Dart over `doom_wad`: a from-scratch classic-feel reimplementation. Constants may be re-derived from published data and the GPL source, but no C source is embedded, translated verbatim, or wrapped.

- Simulation state is integer-only: 16.16 fixed point through `fixedMul`/`fixedDiv` with `wrap32`, angles in BAM so they wrap for free. Doubles live only at the rendering and map-import boundary and never flow back into state, because a refactor that reassociates float math silently breaks replay.
- The tick is exactly 35 Hz with a retained remainder; rendering interpolates and never advances state. Dropped ticks are telemetry, not something to hide by scaling the step.
- `TicCmd` is the only input, so seed plus command stream is a complete replay and `hashState()` is the oracle. Every gameplay change needs a replay test; a hash change must be an explained, intentional diff.
- `DoomRandom` is a shared rolling-index table, so consumption order is game state. Adding a draw anywhere shifts everything downstream: budget for it and re-pin deliberately.
- Movement is classic: try the move, slide along blocking lines, step up within the limit, respect drop-off. Use the map's `BLOCKMAP` for broadphase; when it is `null`, fall back explicitly and say so.
- Sector effects drive the geometry layer's in-place plane updates. Manual doors carry tag 0, so classifying static versus dynamic by tag is wrong; classify by line special.
- `MobjInfo` is tuning data, behaviour is Dart against it. Keep them separate so tuning never touches state logic.

`/Users/savva/fvm/versions/stable/bin/dart analyze` and `dart test`. Cover fixed-point overflow and the divide guard, angle wrapping, tick accumulation under irregular frame times, collision against crafted geometry, and replay determinism across repeated and reordered runs.
