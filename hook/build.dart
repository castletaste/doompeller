import 'package:flutter_scene/build_hooks.dart';
import 'package:hooks/hooks.dart';

/// Compiles Doompeller's palette shader pair with the impellerc that ships with
/// the active engine, for every target flutter_scene supports (Metal on Apple,
/// GLSL ES for the web's WebGL2 backend). The output is generated and
/// gitignored under flutter_scene_generated/.
void main(List<String> args) async {
  await build(args, (input, output) async {
    await buildTargetShaderBundleJson(
      buildInput: input,
      buildOutput: output,
      manifestFileName: 'shaders/doom_palette.shaderbundle.json',
      // Match the engine bundle's GLES dialect.
      glesLanguageVersion: 300,
    );
  });
}
