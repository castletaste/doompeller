#version 460 core

// Doompeller indexed-palette fragment stage: atlas index -> COLORMAP -> PLAYPAL.
//
// This is the shader that makes the renderer look like Doom rather than like a
// modern engine drawing Doom art.
//
// The critical rule: lighting is applied by SELECTING a COLORMAP row, before
// the palette lookup. The final RGB comes straight out of PLAYPAL and is never
// scaled, tinted or blended afterwards. Multiplying RGB by a light factor after
// the lookup would produce smooth modern shading and leave the palette, which
// is precisely the wrong look. Doom's darkness is a palette remap, not a
// multiply.
//
// Texture formats: flame_3d 0.3.0 has no R8 format, so all three lookups are
// RGBA8. The atlas packs the palette index in red and mask coverage in alpha.
// The COLORMAP and PLAYPAL lookups store their payload in red / RGB.
//
// Sampling: the backend binds a nearest / clamp-to-edge sampler. Repeating is
// therefore done in the shader with fract() inside the vertex's atlas rect,
// which is also what keeps one atlas page from bleeding into its neighbours.

in vec2 fragTexCoord;
in vec4 fragAtlasRect;
in vec4 fragParams;
in vec3 fragNormal;
in float fragLight;
in float fragAlpha;
in float fragViewDepth;

out vec4 outColor;

uniform sampler2D indexAtlas;
uniform sampler2D colorMapLut;
uniform sampler2D paletteLut;

uniform DoomMaterial {
  // (atlasWidth, atlasHeight, colorMapRows, paletteRows)
  vec4 atlasSize;
  // (paletteIndex, lightScale, distanceScale, alphaThreshold)
  vec4 palette;
  // (maxLightRow, invulnerabilityRow, unused, unused)
  vec4 lighting;
} doom_material;

// Centre of texel `index` in a texture `size` texels wide. Sampling anywhere
// else in a nearest-filtered lookup table risks landing on the neighbouring
// entry once the rasterizer's interpolation is factored in.
float texelCenter(float index, float size) {
  return (index + 0.5) / size;
}

void main() {
  float fullBright = fragParams.x;
  float lightRowOverride = fragParams.y;
  float uvMode = fragParams.z;

  vec2 atlasMin = fragAtlasRect.xy;
  vec2 atlasMax = fragAtlasRect.zw;

  // Repeat mode tiles inside the vertex's own atlas rect; clamp mode keeps
  // sprites and the weapon quad strictly inside theirs. Doom's wall UVs run far
  // past 1.0, so fract() has to happen before the rect is applied.
  vec2 localUv = uvMode > 0.5
    ? fract(fragTexCoord)
    : clamp(fragTexCoord, vec2(0.0), vec2(1.0));

  vec2 atlasUv = mix(atlasMin, atlasMax, localUv);

  // Half-texel inset. Without it, a tile boundary can sample the first texel of
  // the next atlas entry and produce a bright seam along every wall edge.
  vec2 halfTexel = 0.5 / doom_material.atlasSize.xy;
  atlasUv = clamp(atlasUv, atlasMin + halfTexel, max(atlasMax - halfTexel, atlasMin + halfTexel));

  vec4 indexedTexel = texture(indexAtlas, atlasUv);

  // Masked pixels are cut out, never blended. Doom's midtextures and sprites
  // are binary stencils, and discarding keeps normal depth writes valid so a
  // sprite behind a grate still occludes correctly.
  float alphaThreshold = doom_material.palette.w;
  if (indexedTexel.a < alphaThreshold) {
    discard;
  }

  float sourceIndex = floor(indexedTexel.r * 255.0 + 0.5);

  // --- Light level selection: the entire lighting model. ---
  float colorMapRows = doom_material.atlasSize.z;
  float maxLightRow = doom_material.lighting.x;
  float lightRow;

  if (lightRowOverride >= 0.0) {
    // An explicit row, used by the invulnerability map and by any surface that
    // needs a fixed shade.
    lightRow = lightRowOverride;
  } else if (fullBright > 0.5) {
    // Row 0 is the undarkened map: sky, muzzle flashes and pickups.
    lightRow = 0.0;
  } else {
    // Doom picks one of 32 light levels from the sector's brightness, then
    // darkens further with distance. Brighter sector and closer surface both
    // mean a lower row index.
    float lightLevel = clamp(fragLight, 0.0, 1.0) * doom_material.palette.y;
    float distanceFalloff = fragViewDepth * doom_material.palette.z;
    float shade = (1.0 - lightLevel) * maxLightRow + distanceFalloff;
    lightRow = clamp(floor(shade + 0.5), 0.0, maxLightRow);
  }

  lightRow = clamp(lightRow, 0.0, max(colorMapRows - 1.0, 0.0));

  // COLORMAP maps (palette index, light level) to a darker palette index.
  float mappedIndex = floor(texture(colorMapLut, vec2(
    texelCenter(sourceIndex, 256.0),
    texelCenter(lightRow, colorMapRows)
  )).r * 255.0 + 0.5);

  // PLAYPAL turns that index into the final RGB. The 14 palette variants
  // (damage red, item pickup, radsuit green) are rows here, so a screen flash
  // costs one uniform change and no texture work.
  float paletteRows = doom_material.atlasSize.w;
  float paletteRow = clamp(
    floor(doom_material.palette.x + 0.5),
    0.0,
    max(paletteRows - 1.0, 0.0)
  );

  vec3 paletteColor = texture(paletteLut, vec2(
    texelCenter(mappedIndex, 256.0),
    texelCenter(paletteRow, paletteRows)
  )).rgb;

  // paletteColor is used verbatim. Do not tint it.
  float alpha = clamp(fragAlpha, 0.0, 1.0);

  // The render pass blends with premultiplied alpha, so premultiply here. With
  // the normal alpha of 1.0 this is an identity operation and the palette RGB
  // reaches the framebuffer bit-exact.
  outColor = vec4(paletteColor * alpha, alpha);
}
