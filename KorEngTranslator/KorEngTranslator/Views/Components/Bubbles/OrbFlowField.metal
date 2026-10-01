#include <metal_stdlib>
using namespace metal;

// The debug "Flow (reel)" orb style's colors (OrbFlowStyle.swift): a handful of colors drifting
// around inside a square, every pixel a blend of all of them weighted by how close it is to each,
// so they melt into one soft, moving gradient. The motion matches the Remotion reel's flowing orb.

/// Where color `i` sits at phase `t`, in the square's unit coordinates (0...1, y up)
static float2 flowAnchor(int i, float t) {
    float offset = 0.37 * float(i);
    float speedX = 0.6 + fract(float(i) / 3.0) * 0.9;
    float speedY = 0.8 + fract(float(i + 1) / 4.0);
    return 0.5 + 0.5 * float2(sin(t * speedX + offset), cos(t * speedY + 1.5 * offset));
}

/// The field at `position` in a view of `size` points, its colors roaming a centered square of
/// `square` points. `time` is the field's own clock (seconds x speed). `colors` holds RGB triples,
/// sRGB-encoded; the blend happens in those values, like the reel's WebGL, and comes out opaque.
[[ stitchable ]] half4 orbFlowField(float2 position, half4 color, float2 size, float square, float time,
                                    float warp, float swirl, float sharpness,
                                    device const float *colors, int count) {
    // The square's units, centered, y up
    float2 p = (position - size * 0.5) / square;
    float2 uv = float2(p.x, -p.y) + 0.5;
    float phase = 0.5 * (time + 41.5);

    // A gentle domain warp, strongest in the middle and gone a square's width out
    float rim = smoothstep(0.0, 1.0, length(uv - 0.5));
    float bend = warp * (1.0 - rim);
    for (int k = 1; k <= 2; k++) {
        float n = float(k);
        float sy = smoothstep(0.0, 1.0, uv.y);
        uv.x += bend / n * sin(phase + n * 0.4 * sy) * cos(0.2 * phase + n * 2.4 * sy);
        float sx = smoothstep(0.0, 1.0, uv.x);
        uv.y += bend / n * cos(phase + n * 2.0 * sx);
    }

    // Swirl: the field twists more the farther out it is
    float turn = -3.0 * swirl * rim;
    float2 q = uv - 0.5;
    float c = cos(turn), s = sin(turn);
    uv = float2(c * q.x - s * q.y, s * q.x + c * q.y) + 0.5;

    // Every color counts, nearer ones far more (inverse distance ^ sharpness), out past the square too
    float3 sum = float3(0.0);
    float total = 0.0;
    int n = count / 3;
    for (int i = 0; i < n; i++) {
        float d = length(uv - flowAnchor(i, phase));
        float w = 1.0 / (powr(d, sharpness) + 0.001);
        sum += float3(colors[3 * i], colors[3 * i + 1], colors[3 * i + 2]) * w;
        total += w;
    }
    float3 rgb = sum / max(total, 1e-4);
    return half4(half3(rgb), 1.0h) * color.a;
}
