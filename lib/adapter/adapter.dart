/// Doompeller's renderer adapter.
///
/// This library is the only part of the project allowed to import
/// package:flame_3d or flutter_gpu, per docs/CONTRACTS.md. Everything above it
/// consumes these types instead of the engine's.
library;

export 'doom_scene.dart';
export 'doom_runtime_game.dart';
export 'doom_camera.dart';
export 'doom_sprite_atlas.dart';
export 'doom_sprite_catalog.dart';
export 'frame_histogram.dart';
export 'packed_surface.dart';
export 'palette_material.dart';
export 'palette_textures.dart';
export 'render_diagnostics.dart';
export 'renderer_smoke_game.dart';
export 'vertex_abi.dart';
