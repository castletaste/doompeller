---
name: doompeller-wad
description: "Implement or debug Doompeller's pure-Dart WAD layer: container parsing, palette and colormap, patches, composites, flats, sprites, map lumps, blockmap, and the synthetic fixture PWAD. Excludes geometry, rendering, and gameplay."
---

# Doompeller WAD

`packages/doom_wad` is pure Dart: no `dart:ui`, `dart:ffi`, Flutter, or Flame. `docs/CONTRACTS.md` is the API contract.

- Hostile input never throws untyped errors. Emit `DoomFormatFailure`, `DoomLimitFailure`, `DoomMissingLumpFailure`, or `DoomMapFailure`, and check `DoomLimits` before allocating. New parsing work needs its own limit and a typed-failure test.
- Validate offsets and sizes against file bounds before reading. Names are 8 bytes NUL-padded, compared uppercase; `-` means no texture. `WadSet` resolves later entries first so a PWAD overrides an IWAD.
- Patch decoding handles column posts, the 0xFF terminator, and tall-patch delta rollover. Composites align against the size declared in TEXTURE1, which can differ from the pixels the patches cover.
- Missing flat or sprite markers degrade to "no such resource", never a whole-load failure. An unusable `BLOCKMAP` (leading 0x0000, trailing 0xFFFF, vanilla offset overflow) becomes `null` and the map still loads. Out-of-range map indices are `DoomMapFailure`.
- `DoomFixtures` is the CI backbone: byte-deterministic, hash-pinned, with a real NODES/SEGS/SSECTORS tree. No test may require a commercial IWAD, and a pinned-hash change must be deliberate.

Typed data, no per-pixel closures. From the package: `/Users/savva/fvm/versions/stable/bin/dart analyze` and `dart test`; system `dart` is older and fails. See `doompeller-content-license` before touching any real WAD.
