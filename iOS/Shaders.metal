#include <metal_stdlib>
using namespace metal;

// The field, drawn from what is actually sounding.
//
// Each sounding voice is a soft bloom placed on the same ring geometry the HRTF
// stage uses — angle is scale degree with the tonic straight up, radius is
// octave — so what you see is where you would hear it. The blooms are driven by
// the engine's per-voice meters, and those are already modulated by the tremolo
// and filter LFOs running on distinct prime periods (11, 13, 17, 19, 23, 29 s).
// So the picture inherits "nothing repeats" for free rather than having its own
// decorative animation bolted alongside: two voices with a 41 s and a 67 s cycle
// return to the same arrangement every 2,747 s, and a screenful of them
// effectively never does.
//
// Cost matters more than cleverness here — this runs for hours on a battery. It
// is one full-screen pass, loops only over *sounding* voices, and the view feeds
// it a deliberately under-sampled drawable (see Visualizer.swift). Soft blooms
// are the one thing that upscales without anyone noticing.

struct Voice {
    float2 position;   // -1…1, ring geometry, y up
    float  level;      // 0…1, straight off the engine's meter
    float  hue;        // mode hue, so a modal change recolours the field
};

// Header and voices are bound separately, on purpose. Folding the array into
// this struct is the obvious thing and it is a trap: the Swift mirror of it then
// holds a Swift `Array`, which is a pointer to heap storage, so copying the
// struct's bytes to the GPU sends the *pointer* and the shader reads whatever
// happens to be at buffer offset 24. It compiles, it runs, and it draws
// garbage. Two bindings makes that mistake unrepresentable.
struct Header {
    float2 resolution;
    float  time;
    float  dim;        // idle fade, 0…1 — see the idle policy in FlowHost
    int    count;      // sounding voices; the loop bound, not a constant
    float  master;     // master peak, for the background wash
};

// Hue → RGB without a branch. Cheap, and smooth, which is all this needs.
static float3 hue2rgb(float h) {
    float3 k = fract(h + float3(0.0, 2.0 / 3.0, 1.0 / 3.0));
    return clamp(abs(k * 6.0 - 3.0) - 1.0, 0.0, 1.0);
}

// Value noise, used only for a very slow background grain.
static float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), f.x),
               mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), f.x), f.y);
}

vertex float4 field_vertex(uint vid [[vertex_id]]) {
    // Full-screen triangle pair from the vertex id — no vertex buffer to bind.
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    return float4(p, 0.0, 1.0);
}

fragment float4 field_fragment(float4 pos [[position]],
                               constant Header &u [[buffer(0)]],
                               constant Voice *voices [[buffer(1)]]) {
    // Aspect-corrected coordinates, shortest axis normalised to 1.
    float2 uv = (pos.xy * 2.0 - u.resolution) / min(u.resolution.x, u.resolution.y);
    uv.y = -uv.y;                       // Metal's y grows downward; ours grows up
    float r = length(uv);

    float3 colour = float3(0.0);

    // A drifting wash so the screen is never dead flat even in near-silence.
    float wash = noise(uv * 1.6 + float2(u.time * 0.013, u.time * -0.011));
    colour += float3(0.04, 0.045, 0.075) * (0.5 + 0.5 * wash) * (0.35 + u.master);

    for (int i = 0; i < u.count; ++i) {
        Voice v = voices[i];
        if (v.level <= 0.0009) continue;   // below this it is not on screen either

        float d = length(uv - v.position);

        // Two-lobe bloom: a tight core that tracks level sharply, and a wide
        // halo that lags into a glow. The halo is what makes a drone read as
        // continuous rather than as 32 separate dots.
        float core = exp(-d * d * 190.0) * v.level;
        float halo = exp(-d * d * 9.0) * v.level * 0.42;

        // Breathing radius. Slow, and keyed off the voice's own position so no
        // two blooms pulse together.
        float breathe = 0.85 + 0.15 * sin(u.time * 0.21 + v.position.x * 5.1 + v.position.y * 3.7);

        float3 tint = hue2rgb(v.hue) * 0.72 + 0.28;   // desaturated; long viewing
        colour += tint * (core + halo * breathe);
    }

    // Vignette, and a faint horizon so the ring has somewhere to sit.
    colour *= 1.0 - 0.42 * smoothstep(0.55, 1.35, r);
    colour += float3(0.02, 0.03, 0.05) * exp(-abs(uv.y) * 5.0) * 0.5;

    colour *= u.dim;

    // Filmic-ish curve so blooms pile up without flat-topping to white, and a
    // touch of dither — banding is very visible on a dark field held for hours.
    colour = colour / (1.0 + colour);
    colour = pow(colour, float3(0.86));
    colour += (hash(pos.xy + u.time) - 0.5) / 255.0;

    return float4(colour, 1.0);
}
