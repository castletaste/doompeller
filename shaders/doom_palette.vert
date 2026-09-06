#version 460 core

// Doompeller indexed-palette vertex stage.
//
// The attribute list must match flame_3d 0.3.0's pinned 20-float interleaved
// vertex record exactly, in this order, or the vertex stride changes and every
// buffer misreads. See lib/adapter/vertex_abi.dart.
//
// Doompeller never skins geometry, so the two skinning attributes are
// repurposed rather than dropped:
//   vertexJoints  -> atlas rect (u0, v0, u1, v1)
//   vertexWeights -> (fullBright, lightRowOverride, uvMode, unused)
// Declaring them keeps the 80-byte stride identical to flame_3d's own
// materials while giving every vertex its own atlas sub-rectangle. That is what
// allows one surface to cover a whole atlas page: flame_3d has no batching and
// insertion-sorts visible draws, so fewer, larger surfaces is the only way to
// keep frame cost flat.

in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec4 vertexColor;
in vec3 vertexNormal;
in vec4 vertexJoints;
in vec4 vertexWeights;

out vec2 fragTexCoord;
out vec4 fragAtlasRect;
out vec4 fragParams;
out vec3 fragNormal;
out float fragLight;
out float fragAlpha;
out float fragViewDepth;

uniform VertexInfo {
  mat4 model;
  mat4 view;
  mat4 projection;
} vertex_info;

void main() {
  vec4 worldPosition = vertex_info.model * vec4(vertexPosition, 1.0);
  vec4 viewPosition = vertex_info.view * worldPosition;
  gl_Position = vertex_info.projection * viewPosition;

  // depthLayer is the fourth repurposed weight. Sky is pinned just inside the
  // far clip plane so normal depth testing can only fill background pixels;
  // the first-person weapon is pinned just inside the near plane so nearby
  // world geometry cannot clip it. Impeller's clip-depth range is 0..w (not
  // OpenGL's -w..w), so a negative weapon depth is clipped before rasterizing.
  // World and actor vertices write 0.
  if (vertexWeights.w > 0.5) {
    gl_Position.z = gl_Position.w * 0.999999;
  } else if (vertexWeights.w < -1.5) {
    // Muzzle flash lies in front of the weapon even with strict less-than
    // depth comparison; draw ordering cannot erase overlapping flash pixels.
    gl_Position.z = gl_Position.w * 0.0000005;
  } else if (vertexWeights.w < -0.5) {
    gl_Position.z = gl_Position.w * 0.000001;
  }

  fragTexCoord = vertexTexCoord;
  fragAtlasRect = vertexJoints;
  fragParams = vertexWeights;

  // Doom's renderer does not light by normal, but the attribute must stay live:
  // an unused vertex input is stripped before reflection, which changes the
  // vertex descriptor and breaks the pinned 20-float stride.
  fragNormal = mat3(vertex_info.model) * vertexNormal;

  // Red carries the sector light level; alpha is reserved for geometry fades.
  fragLight = vertexColor.r;
  fragAlpha = vertexColor.a;

  // Distance along the view axis, used for Doom's light diminishing. Negated
  // because the view space used here looks down -Z.
  fragViewDepth = -viewPosition.z;
}
