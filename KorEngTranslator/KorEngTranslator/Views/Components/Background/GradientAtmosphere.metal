#include <metal_stdlib>
using namespace metal;

// Shaders behind GradientAtmosphere.swift. Numbers that matter for the look are passed in from
// Swift, so tuning happens in GradientAtmosphere.

/// White noise in 0...1 for an integer cell and a frame number. Integer mixing, so it stays
/// structureless at large pixel coordinates (a float hash streaks there).
static float hash21(float2 p, float frame) {
    uint2 v = uint2(int2(floor(p)) + 32768);
    uint f = uint(frame);
    v = v * 1664525u + 1013904223u;
    v.x += v.y * 1664525u + f * 2654435761u;
    v.y += v.x * 1664525u;
    v ^= v >> 16u;
    v.x += v.y * 1664525u;
    v.y += v.x * 1664525u;
    v ^= v >> 16u;
    return float(v.x ^ v.y) / 4294967295.0;
}

/// Where each destination pixel of the orb samples its colour from:
///  - warp: sine waves bend the image like liquid, strongest in the middle, nothing at the rim
///  - swirl: the image twists more toward the rim (none at the center, `swirl` radians at the rim)
///  - speckle: each pixel's sample point is nudged, which grains the edges between the colours
[[ stitchable ]] float2 liquidWarp(float2 position, float time, float2 size,
                                   float distortion, float swirl, float speckle) {
    float2 center = size * 0.5;
    float2 p = position - center;
    float radius = min(size.x, size.y) * 0.5;
    float r = length(p) / radius;                     // 0 center, 1 rim
    float2 uv = position / size;

    float2 wave;
    wave.x = sin(uv.y * 6.2832 * 1.3 + time * 0.55) + 0.6 * sin(uv.x * 6.2832 * 0.8 - time * 0.37);
    wave.y = cos(uv.x * 6.2832 * 1.1 - time * 0.47) + 0.6 * cos(uv.y * 6.2832 * 0.9 + time * 0.31);
    float middle = 1.0 - smoothstep(0.3, 1.0, r);
    float2 warp = wave * distortion * radius * 0.06 * middle;

    float angle = swirl * r * r;
    float c = cos(angle), s = sin(angle);
    float2 twisted = float2(p.x * c - p.y * s, p.x * s + p.y * c);

    float frame = floor(time * 24.0);
    float2 nudge = float2(hash21(position, frame), hash21(position.yx, frame + 977.0)) - 0.5;
    float2 grain = nudge * speckle * radius * 0.02;

    return center + twisted + warp + grain;
}

/// Black-and-white film grain mixed into the orb's own colour (only where the orb has colour).
[[ stitchable ]] half4 colorGrain(float2 position, half4 color, float time, float strength) {
    float n = hash21(position * 3.0, floor(time * 24.0)) - 0.5;
    half3 rgb = color.rgb + half3(half(n * strength)) * color.a;
    return half4(clamp(rgb, 0.0h, 1.0h), color.a);
}

/// Page-wide grain: mid grey with speckle, meant to sit over everything with the overlay blend
/// mode (mid grey is neutral there). `grainSize` is the speck size in points.
[[ stitchable ]] half4 pageGrain(float2 position, half4 color, float time, float grainSize) {
    float n = hash21(position / grainSize, floor(time * 24.0));
    return half4(half3(half(n)), color.a);
}
