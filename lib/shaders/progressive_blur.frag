#version 460 core
#include <flutter/runtime_effect.glsl>

#define MAX_KERNEL_RADIUS 127

uniform sampler2D child_texture;
uniform vec2 child_size;

uniform sampler2D blur_texture;
uniform float blur_sigma;
uniform float blur_direction; // 0 for horizontal, 1 for vertical

uniform vec4 tint_color;

// Where the blur texture is laid out, in FlutterFragCoord pixels: xy is the
// origin and zw the size. A zero size lays it over the whole child.
uniform vec4 mask_rect;

// The pixels to blur, in FlutterFragCoord pixels: left, top, right, bottom.
// Pixels outside it are passed through. An empty rect blurs every pixel.
uniform vec4 blur_rect;

// When opaque enough to matter (alpha > 0), the vertical pass reads this
// color instead of the input above and below mask_rect.
uniform vec4 edge_color;

out vec4 frag_color;

void main() {
  vec2 frag_coord = FlutterFragCoord().xy;

  // When Impeller uses the OpenGL(ES) backend the y-axis is reversed, so a
  // shader used via ImageFilter.shader renders upside-down unless we invert it.
#ifdef IMPELLER_TARGET_OPENGLES
  frag_coord.y = child_size.y - frag_coord.y;
#endif

  vec2 uv = frag_coord / child_size;

  bool outside_blur_rect =
      blur_rect.z > blur_rect.x &&
      (frag_coord.x < blur_rect.x || frag_coord.y < blur_rect.y ||
       frag_coord.x > blur_rect.z || frag_coord.y > blur_rect.w);
  if (outside_blur_rect) {
    frag_color = texture(child_texture, uv);
    return;
  }

  vec2 mask_uv =
      mask_rect.z > 0.0 ? (frag_coord - mask_rect.xy) / mask_rect.zw : uv;

  // Squaring the blur texture value makes it look more consistent?
  float blur_value = pow(texture(blur_texture, mask_uv).r, 2.0);
  float sigma = blur_sigma * blur_value;

  if (sigma < 1e-5) {
    frag_color = texture(child_texture, uv);
    return;
  }

  // The kernel spans ceil(3 * sigma) texels on each side of the center, up to
  // MAX_KERNEL_RADIUS.
  // Kept as a float: SkSL has no integer min().
  float kernel_radius = min(ceil(3.0 * sigma), float(MAX_KERNEL_RADIUS));
  vec2 texel_step =
      (blur_direction == 0.0 ? vec2(1.0, 0.0) : vec2(0.0, 1.0)) / child_size;

  // Incremental Gaussian: with w(v) = exp(-v^2 / (2 sigma^2)), the ratio
  // w(v) / w(v - 1) = exp(-(2v - 1) / (2 sigma^2)) itself grows by a constant
  // factor exp(-1 / sigma^2) per tap, so no exp() is needed inside the loop.
  float exponent = -0.5 / (sigma * sigma);
  float weight = 1.0;
  float ratio = exp(exponent);
  float ratio_growth = ratio * ratio;

  bool read_edges = edge_color.a > 0.0 && blur_direction != 0.0;
  float rows_above = frag_coord.y - mask_rect.y;
  float rows_below = mask_rect.y + mask_rect.w - frag_coord.y;

  vec4 color = texture(child_texture, uv);
  float total_weight = 1.0;

  // Taps v and v + 1 are read with a single bilinear fetch between them, at
  // the position that weighs them w(v) and w(v + 1). child_texture must be
  // sampled with a linear filter (see the Dart side).
  for (int v = 1; v <= MAX_KERNEL_RADIUS; v += 2) {
    if (float(v) > kernel_radius) break;

    weight *= ratio;
    ratio *= ratio_growth;
    float near_weight = weight;
    weight *= ratio;
    ratio *= ratio_growth;
    float far_weight = float(v) < kernel_radius ? weight : 0.0;

    float pair_weight = near_weight + far_weight;
    float far_share = pair_weight > 0.0 ? far_weight / pair_weight : 0.0;
    vec2 near_offset = float(v) * texel_step;
    vec2 pair_offset = (float(v) + far_share) * texel_step;

    vec4 after;
    if (read_edges && float(v + 1) > rows_below) {
      after = (float(v) > rows_below
                   ? edge_color
                   : texture(child_texture, uv + near_offset)) *
                  near_weight +
              edge_color * far_weight;
    } else {
      after = texture(child_texture, uv + pair_offset) * pair_weight;
    }
    vec4 before;
    if (read_edges && float(v + 1) > rows_above) {
      before = (float(v) > rows_above
                    ? edge_color
                    : texture(child_texture, uv - near_offset)) *
                   near_weight +
               edge_color * far_weight;
    } else {
      before = texture(child_texture, uv - pair_offset) * pair_weight;
    }
    color += after + before;
    total_weight += 2.0 * pair_weight;
  }

  vec4 blurred = color / total_weight;
  float tint_strength = blur_value * tint_color.a;
  frag_color = mix(blurred, tint_color, tint_strength);
}
