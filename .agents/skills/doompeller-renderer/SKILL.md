---
name: doompeller-renderer
description: "Implement or debug Doompeller's flame_3d renderer: the vertex ABI pin, packed surfaces, indexed-palette shader, atlas and palette textures, scene composition, dynamic uploads, and frame telemetry. Excludes WAD parsing, geometry, and gameplay."
---

# Doompeller Renderer

`lib/adapter` is the only place allowed to import `package:flame_3d` or `flutter_gpu`, public paths only. See `flutter-gpu-rendering` for the platform-level rules this builds on.

- Pins are exact: Flutter 3.44.4, Flame 1.38.0, flame_3d 0.3.0, vector_math 2.2.0. **Forking flame_3d is forbidden** — on an unfixable upstream or adapter blocker, stop and revisit the plan with the user.
- `test/adapter/vertex_abi_test.dart` asserts the 20-float layout against a real flame_3d `Vertex`. That is the pin tripwire; never weaken it to make a bump pass. Floats 12..19 are the unused skinning slots repurposed as atlas rect and per-vertex params, so stride and declared shader attributes must stay identical.
- Lighting selects a COLORMAP row **before** the palette lookup, and PLAYPAL RGB is used verbatim. Multiplying RGB by a light factor afterwards gives modern smooth shading and loses the Doom look: treat it as a defect, not a preference.
- Masked pixels `discard` with normal depth writes. The 14 palette variants are texture rows chosen by a uniform, so screen flashes cost no texture work. Half-texel inset plus in-shader `fract` inside the vertex's atlas rect is what prevents bleed; the sampler is nearest/clamp and cannot wrap for us.
- Merge by atlas page and surface kind before any other optimization: surface count dominates because flame_3d has no batching and insertion-sorts visible draws.
- `tool/build_shaders.sh` produces the gitignored bundle and stays pinned to the SDK. macOS needs `FLTEnableImpeller` and `FLTEnableFlutterGPU` in `macos/Runner/Info.plist`.

Bumping a pin means re-running shader, packed-buffer, dynamic-upload, visual, reload, and performance probes. A build is not visual proof: check seams, cutouts, sky, depth order, and palette on a live macOS release target. `/private/tmp/doompeller-spike-01a03525` is evidence only; never copy spike code into production.
