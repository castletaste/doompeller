---
name: doompeller-renderer
description: "Implement or debug Doompeller's flutter_scene renderer: the vertex ABI pin, packed surfaces, indexed-palette shader, atlas and palette textures, scene presentation, dynamic uploads, and frame telemetry. Excludes WAD parsing, geometry, and gameplay."
---

# Doompeller Renderer

`lib/adapter` is the only place allowed to import `package:flutter_scene` or `flutter_gpu`. Internal `package:flutter_scene/src/` imports (caller-managed buffers, culling enums) are confined to `lib/adapter/scene_gpu.dart`. See `flutter-gpu-rendering` for the platform-level rules this builds on.

- Pins are exact: Flutter 3.47.7, flutter_scene 0.24.3, flutter_gpu_shaders 0.5.2, hooks 2.0.2, vector_math 2.4.0. **Forking flutter_scene is forbidden** — on an unfixable upstream or adapter blocker, stop and revisit the plan with the user.
- The renderer core is plain data behind `DoomGpu`; only `DoomScenePresenter` and `scene_gpu.dart` create flutter_scene objects. Keep geometry, sprite, camera and upload rules testable with the recording fake in `test/adapter/fake_gpu_backend.dart`.
- `test/adapter/vertex_abi_test.dart` checks the 20-float record against `doomVertexLayout` and the attribute declarations in `shaders/doom_palette.vert`. That is the pin tripwire; never weaken it to make a bump pass.
- Lighting selects a COLORMAP row **before** the palette lookup, and PLAYPAL RGB is used verbatim. Multiplying RGB by a light factor afterwards gives modern smooth shading and loses the Doom look: treat it as a defect, not a preference. The shader sRGB-decodes the PLAYPAL byte because flutter_scene resolves linear HDR; `configureDoomScene` (linear tone mapping, exposure 1, no AA, render scale 1) makes the resolve re-encode the identical byte. Changing any of those settings breaks the palette.
- The palette shader draws with `DoomCamera`'s own view and projection and writes clip depth for sky, weapon and muzzle flash, which needs `Scene.reversedDepth = false`. flutter_scene's camera is used only for culling.
- Masked pixels `discard` with normal depth writes. Masked midtextures cull back faces so each side of a two-sided line shows only its own texture; other surfaces keep both faces. The 14 palette variants are texture rows chosen by a uniform, so screen flashes cost no texture work. Half-texel inset plus in-shader `fract` inside the vertex's atlas rect is what prevents bleed; the sampler is nearest/clamp without mips and cannot wrap for us.
- Merge by atlas page and surface kind before any other optimization: every surface is one draw.
- `hook/build.dart` compiles `shaders/` with the SDK's impellerc into the gitignored `flutter_scene_generated/` tree during every build and test. macOS needs `FLTEnableImpeller` and `FLTEnableFlutterGPU` in `macos/Runner/Info.plist`.

Bumping a pin means re-running shader, packed-buffer, dynamic-upload, visual, reload, and performance probes, including the exhaustive palette pattern from the flutter_scene spike (branch `codex/spike-flutter-scene`). A build is not visual proof: check seams, cutouts, sky, depth order, and palette on a live macOS release target and in a WebGL2 browser. Spike code is evidence only; never copy it into production.
