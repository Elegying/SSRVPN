#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform vec4 u_corner_radii;
uniform float u_refraction_height;
uniform float u_refraction_amount;
uniform float u_depth_effect;
uniform float u_chromatic_aberration;
uniform float u_saturation;
uniform float u_liquid_scale;
uniform sampler2D u_texture;

out vec4 frag_color;

float radiusAt(vec2 coord, vec4 radii) {
  if (coord.x >= 0.0) {
    if (coord.y <= 0.0) {
      return radii.y;
    }
    return radii.z;
  }
  if (coord.y <= 0.0) {
    return radii.x;
  }
  return radii.w;
}

float sdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
  vec2 cornerCoord = abs(coord) - (halfSize - vec2(radius));
  float outside = length(max(cornerCoord, 0.0)) - radius;
  float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
  return outside + inside;
}

float safeSign(float value) {
  return value < 0.0 ? -1.0 : 1.0;
}

vec2 safeNormalize(vec2 value, vec2 fallback) {
  float len = length(value);
  if (len > 0.001) {
    return value / len;
  }
  return fallback;
}

vec2 gradSdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
  vec2 cornerCoord = abs(coord) - (halfSize - vec2(radius));
  if (cornerCoord.x >= 0.0 || cornerCoord.y >= 0.0) {
    vec2 outside = max(cornerCoord, 0.0);
    float outsideLength = length(outside);
    if (outsideLength > 0.001) {
      return sign(coord) * outside / outsideLength;
    }
    float useX = step(cornerCoord.y, cornerCoord.x);
    return vec2(
      useX * safeSign(coord.x),
      (1.0 - useX) * safeSign(coord.y)
    );
  }
  float gradX = step(cornerCoord.y, cornerCoord.x);
  return sign(coord) * vec2(gradX, 1.0 - gradX);
}

float circleMap(float x) {
  x = clamp(x, 0.0, 1.0);
  return 1.0 - sqrt(max(0.0, 1.0 - x * x));
}

vec4 contentAt(vec2 coord) {
  vec2 uv = clamp(coord / u_size, 0.0, 1.0);
  return texture(u_texture, uv);
}

vec4 saturateColor(vec4 color, float saturation) {
  float luma = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
  color.rgb = mix(vec3(luma), color.rgb, saturation);
  return color;
}

float smoothStepRange(float a, float b, float t) {
  float x = clamp((t - a) / (b - a), 0.0, 1.0);
  return x * x * (3.0 - 2.0 * x);
}

vec2 liquidGlassCoord(vec2 coord, float amount) {
  vec2 uv = coord / u_size;
  vec2 centeredUv = uv - vec2(0.5);
  float distanceToEdge = sdRoundedRect(centeredUv, vec2(0.3, 0.2), 0.6);
  float displacement = smoothStepRange(0.8, 0.0, distanceToEdge - 0.15);
  float scale = smoothStepRange(0.0, 1.0, displacement);
  vec2 mapped = (centeredUv * scale + vec2(0.5)) * u_size;
  return mix(coord, mapped, clamp(amount, 0.0, 1.0));
}

void main() {
  vec2 coord = FlutterFragCoord().xy;
  vec2 halfSize = u_size * 0.5;
  vec2 centeredCoord = coord - halfSize;
  float radius = radiusAt(centeredCoord, u_corner_radii);

  float sd = sdRoundedRect(centeredCoord, halfSize, radius);
  vec2 refractedCoord = liquidGlassCoord(coord, u_liquid_scale);
  vec2 grad = vec2(0.0);
  float d = 0.0;

  if (u_refraction_height > 0.001 && abs(u_refraction_amount) > 0.001 && -sd < u_refraction_height) {
    float clippedSd = min(sd, 0.0);
    d = circleMap(1.0 - -clippedSd / u_refraction_height) * u_refraction_amount;
    float smoothRadius = max(radius * 1.5, 30.0);
    float gradRadius = min(smoothRadius, min(halfSize.x, halfSize.y));
    vec2 edgeGrad = gradSdRoundedRect(centeredCoord, halfSize, gradRadius);
    vec2 centerGrad = safeNormalize(centeredCoord, edgeGrad);
    grad = safeNormalize(edgeGrad + u_depth_effect * centerGrad, edgeGrad);
    refractedCoord += d * grad;
  }

  vec4 color;
  if (u_chromatic_aberration > 0.001 && abs(d) > 0.001) {
    float denom = max(halfSize.x * halfSize.y, 0.0001);
    float dispersionIntensity = u_chromatic_aberration * ((centeredCoord.x * centeredCoord.y) / denom);
    vec2 dispersedCoord = d * grad * dispersionIntensity;

    color = vec4(0.0);
    vec4 red = contentAt(refractedCoord + dispersedCoord);
    color.r += red.r / 3.5;
    color.a += red.a / 7.0;

    vec4 orange = contentAt(refractedCoord + dispersedCoord * (2.0 / 3.0));
    color.r += orange.r / 3.5;
    color.g += orange.g / 7.0;
    color.a += orange.a / 7.0;

    vec4 yellow = contentAt(refractedCoord + dispersedCoord * (1.0 / 3.0));
    color.r += yellow.r / 3.5;
    color.g += yellow.g / 3.5;
    color.a += yellow.a / 7.0;

    vec4 green = contentAt(refractedCoord);
    color.g += green.g / 3.5;
    color.a += green.a / 7.0;

    vec4 cyan = contentAt(refractedCoord - dispersedCoord * (1.0 / 3.0));
    color.g += cyan.g / 3.5;
    color.b += cyan.b / 3.0;
    color.a += cyan.a / 7.0;

    vec4 blue = contentAt(refractedCoord - dispersedCoord * (2.0 / 3.0));
    color.b += blue.b / 3.0;
    color.a += blue.a / 7.0;

    vec4 purple = contentAt(refractedCoord - dispersedCoord);
    color.r += purple.r / 7.0;
    color.b += purple.b / 3.0;
    color.a += purple.a / 7.0;
  } else {
    color = contentAt(refractedCoord);
  }

  frag_color = saturateColor(color, max(u_saturation, 0.0));
}
