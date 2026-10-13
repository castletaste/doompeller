#version 460 core

// Doompeller indexed-palette vertex stage, run by a flutter_scene
// ShaderMaterial that owns both stages.
//
// The vertex record is Doompeller's 20-float (80-byte) ABI, bound through the
// caller-declared layout in lib/adapter/scene_gpu.dart. The attribute names
// below are that layout's contract; see lib/adapter/vertex_abi.dart:
//   atlas_rect -> per-vertex atlas sub-rectangle (u0, v0, u1, v1)
//   params     -> (fullBright, lightRowOverride, uvMode, depthLayer)
// Carrying the atlas rect per vertex is what lets one surface cover a whole
// atlas page.
//
// The model matrix is the node's own transform, delivered by flutter_scene as
// the instance-rate record after the vertex stream. View and projection come
// from VertexInfo, computed by DoomCamera with the same math the renderer has
// always used, so clip-space output does not depend on flutter_scene's camera
// conventions. FrameInfo and instance_color are engine bindings this stage
// does not need; each is referenced with a contribution far below float
// precision so the compiler keeps it and the engine's binds stay valid.

uniform FrameInfo {
  mat4 camera_transform;
  vec3 camera_position;
}
frame_info;

uniform VertexInfo {
  mat4 view;
  mat4 projection;
}
vertex_info;

in vec3 position;
in vec2 tex_coord;
in vec4 color;
in vec3 normal;
in vec4 atlas_rect;
in vec4 params;

in vec4 model_transform_0;
in vec4 model_transform_1;
in vec4 model_transform_2;
in vec4 model_transform_3;
in vec4 instance_color;

out vec2 fragTexCoord;
out vec4 fragAtlasRect;
out vec4 fragParams;
out vec3 fragNormal;
out float fragLight;
out float fragAlpha;
out float fragViewDepth;

void main() {
  mat4 model = mat4(model_transform_0, model_transform_1, model_transform_2,
                    model_transform_3);
  vec4 worldPosition = model * vec4(position, 1.0);
  vec4 viewPosition = vertex_info.view * worldPosition;
  gl_Position = vertex_info.projection * viewPosition;

  // depthLayer is the fourth parameter. Sky is pinned just inside the far
  // clip plane so normal depth testing can only fill background pixels; the
  // first-person weapon is pinned just inside the near plane so nearby world
  // geometry cannot clip it. Clip depth runs 0..w on every flutter_scene
  // backend (the web uses clip control) with Scene.reversedDepth off, so a
  // negative weapon depth would be clipped before rasterizing. World and
  // actor vertices write 0.
  if (params.w > 0.5) {
    gl_Position.z = gl_Position.w * 0.999999;
  } else if (params.w < -1.5) {
    // Muzzle flash lies in front of the weapon even with strict less-than
    // depth comparison; draw ordering cannot erase overlapping flash pixels.
    gl_Position.z = gl_Position.w * 0.0000005;
  } else if (params.w < -0.5) {
    gl_Position.z = gl_Position.w * 0.000001;
  }
  gl_Position.x += (frame_info.camera_position.x + instance_color.x) * 1e-30;

  fragTexCoord = tex_coord;
  fragAtlasRect = atlas_rect;
  fragParams = params;

  // Doom's renderer does not light by normal; the fragment stage keeps the
  // attribute live so the declared layout always matches the shader.
  fragNormal = mat3(model) * normal;

  // Red carries the sector light level; alpha is reserved for geometry fades.
  fragLight = color.r;
  fragAlpha = color.a;

  // Distance along the view axis, used for Doom's light diminishing. Negated
  // because the view space used here looks down -Z.
  fragViewDepth = -viewPosition.z;
}
