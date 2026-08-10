//
//  Grain.metal
//
//  Optional. Add this file to the same target as PagerView.swift, then set
//  `useMetalGrain = true`.
//
//  Why bother: the grain on the real object is *signal-dependent*. It's
//  strongest in the midtones and collapses in the deep shadows and the blown
//  highlights — which is the actual reason the texture appears to "fade out"
//  near the edges of each surface, since those edges are darker from shading
//  falloff. Geometric masking alone (SurfaceFade) gets you the boundary;
//  this gets you the amplitude.
//
//  The 4·L·(1−L) term is a parabola peaking at mid-grey and hitting zero at
//  both ends. Uniform-opacity noise is the single biggest tell that a
//  synthetic surface was assembled rather than photographed.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

[[ stitchable ]]
half4 grain(float2 pos, half4 color, float amount, float size, float seed) {
    // Quantise position before hashing: this is what sets grain cluster size.
    // size ≈ 1.6 gives ~1.5–2px clusters — correlated, not per-pixel white
    // noise, which would read as digital dirt instead of bead-blasted mould.
    float2 p = floor(pos / max(size, 0.0001));

    float n = fract(sin(dot(p + seed, float2(12.9898, 78.233))) * 43758.5453);

    half lum = dot(color.rgb, half3(0.299h, 0.587h, 0.114h));
    half falloff = 4.0h * lum * (1.0h - lum);

    half g = half(n - 0.5) * half(amount) * falloff;

    // Premultiplied: scale the perturbation by alpha so masked-out regions
    // stay clean.
    return half4(color.rgb + g * color.a, color.a);
}
