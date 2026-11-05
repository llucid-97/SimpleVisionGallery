#include <metal_stdlib>
using namespace metal;

// Static softbox light on the backing plane only. No image or label is sampled.
[[ stitchable ]] half4 lightkeeperSurfaceLight(float2 position, half4 source, float2 size, float radius, float intensity) {
    float2 uv = position / max(size, float2(1.0));
    float2 keyDelta = (uv - float2(-0.08, -0.18)) * float2(0.9, 1.1);
    float key = exp(-dot(keyDelta, keyDelta) * 2.8);
    float2 fillDelta = (uv - float2(1.12, 0.40)) * float2(1.0, 0.8);
    float fill = exp(-dot(fillDelta, fillDelta) * 3.0);

    float2 q = abs(position - size * 0.5) - (size * 0.5 - radius);
    float distanceToEdge = -(length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius);
    float bevel = 1.0 - smoothstep(0.2, 1.5, distanceToEdge);
    float penumbra = 1.0 - smoothstep(1.5, 20.0, distanceToEdge);
    float occlusion = penumbra * (1.0 - key) * (1.0 - fill * 0.55);

    float3 rgb = float3(source.rgb);
    rgb += float3(0.15, 0.095, 0.045) * key * intensity * source.a;
    rgb += float3(0.025, 0.085, 0.105) * fill * intensity * source.a;
    rgb += float3(0.34, 0.25, 0.14) * bevel * key * intensity * source.a;
    rgb += float3(0.07, 0.17, 0.20) * bevel * fill * intensity * source.a;
    rgb -= float3(0.045, 0.048, 0.05) * occlusion * intensity * source.a;
    return half4(half3(clamp(rgb, 0.0, float(source.a))), source.a);
}
