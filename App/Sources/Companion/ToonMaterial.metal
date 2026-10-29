#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

// Cel shading for the RealityKit companion renderer. Mirrors the SceneKit modifier in ToonShading.swift:
// three bands from a fixed light plus a soft rim. The palette colour arrives as the material's base colour
// tint; `custom_parameter().w` is a display gain that makes the unlit output match the palette (the
// RealityKit pipeline darkens emissive output; measured in the renderer). `custom_parameter().xyz` is the unit
// direction toward the light in WORLD space (the renderer turns
// the fixed view-space light into world space each frame so the light stays put relative to the camera).
[[visible]]
void toonSurface(realitykit::surface_parameters params)
{
    float3 n = normalize(params.geometry().normal());
    float3 v = normalize(params.geometry().view_direction());
    float3 lightDir = normalize(params.uniforms().custom_parameter().xyz);

    float d = dot(n, lightDir);
    float band = d > 0.55 ? 1.0 : (d > 0.15 ? 0.86 : 0.66);
    float rim = smoothstep(0.65, 1.0, 1.0 - clamp(dot(n, v), 0.0, 1.0)) * 0.15;

    float3 base = float3(params.material_constants().base_color_tint());
    float gain = params.uniforms().custom_parameter().w;
    half3 lit = half3(clamp((base * band + rim) * gain, 0.0, 1.0));
    params.surface().set_base_color(lit);
    params.surface().set_emissive_color(lit);
    params.surface().set_opacity(1.0h);
}

// Inverted-hull outline: push every vertex out along its normal by `custom_parameter().x` (model space).
// Used with front-face culling so only the shell's back faces draw, as a flat ink silhouette.
[[visible]]
void outlineGeometry(realitykit::geometry_parameters params)
{
    float width = params.uniforms().custom_parameter().x;
    params.geometry().set_model_position_offset(params.geometry().normal() * width);
}

// Flat ink colour for the outline hull.
[[visible]]
void outlineSurface(realitykit::surface_parameters params)
{
    params.surface().set_base_color(half3(params.material_constants().base_color_tint()));
    params.surface().set_opacity(1.0h);
}

// Flat feathered ground disc: constant colour (base tint x gain), alpha only varies. `custom_parameter().x` is
// the centre alpha, `.w` the same display gain as the toon shader. Plateau out to 85% of the radius, then a smooth fade.
[[visible]]
void groundSurface(realitykit::surface_parameters params)
{
    float2 uv = params.geometry().uv0();
    float r = length((uv - 0.5) * 2.0);
    float profile = 1.0 - smoothstep(0.85, 1.0, r);
    float alpha = params.uniforms().custom_parameter().x * profile;
    float gain = params.uniforms().custom_parameter().w;
    // RealityKit composites premultiplied: scale the colour by alpha so a faded pixel is never over-bright.
    half3 colour = half3(clamp(float3(params.material_constants().base_color_tint()) * gain * alpha, 0.0, 1.0));
    params.surface().set_base_color(colour);
    params.surface().set_emissive_color(colour);
    params.surface().set_opacity(half(alpha));
}
