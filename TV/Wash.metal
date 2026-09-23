#include <metal_stdlib>
using namespace metal;

// The wash: what is sounding, as slowly interfering colour across the whole screen.
//
// After Dark's Satori is the reference — no objects, no edges, just a field of
// colour rippling as waves cross one another and the palette drifts. Here each
// sounding voice is one wave. Its direction is the voice's scale degree (the
// tonic runs one way, the fifth another), its wavelength is its octave (low
// voices are broad, slow swells; high voices ripple finer), its strength is the
// engine's per-voice meter, which is already breathing on the tremolo and
// filter LFOs (11, 13, 17, 19, 23, 29 s). Where a chord sounds, its waves
// interfere, and the interference is the picture. A mode change re-tints it;
// a swell in the sound is a swell in the wash. Nothing here has its own
// decorative animation — the drift you see is the drone's.
//
// Two sums are taken from the same waves with different phases: one bends the
// hue, one lifts the brightness, so colour and light move against each other
// rather than in lockstep, which is what keeps it from reading as a single
// pulsing gradient. Saturation is held moderate, the output is wide-gamut P3
// but SDR (tvOS allows a Metal layer nothing brighter — see the end of the
// fragment), and this is looked at for hours in a dim room — the anti-fatigue
// rule that shapes the sound (Presence Cut) applies to the screen too.

struct Voice {
    float2 anchor;   // x: scale degree, -0.82…0.82 across the mode; y: tier position (unused here)
    float2 lh;       // level 0…1, hue 0…1
    float2 sp;       // seed 0…1, tier 0 (low) / 1 (high)
};

struct Header {
    float2 resolution;
    float  time;
    float  dim;      // eased: 1 while playing, low glow while idle
    int    count;
    float  master;   // master peak
    float  headroom; // EDR headroom, ≥ 1; 1 on an SDR set
    float  pad;
};

static float3 hue2rgb(float h) {
    float3 k = fract(h + float3(0.0, 2.0 / 3.0, 1.0 / 3.0));
    return clamp(abs(k * 6.0 - 3.0) - 1.0, 0.0, 1.0);
}

static float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

vertex float4 wash_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    return float4(p, 0.0, 1.0);
}

fragment float4 wash_fragment(float4 pos [[position]],
                              constant Header &u [[buffer(0)]],
                              constant Voice *voices [[buffer(1)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    float2 uv = (pos.xy * 2.0 - u.resolution) / u.resolution.y;   // x ±aspect, y ±1
    uv.y = -uv.y;
    float t = u.time;

    // A very slow bend of the plane itself, so straight wavefronts never stay
    // straight — Satori's ripple rather than a plasma's stripes.
    float2 p = uv;
    p += 0.18 * float2(sin(p.y * 1.3 + t * 0.031), sin(p.x * 1.1 - t * 0.027));

    float hueSum = 0.0, lightSum = 0.0, weight = 0.0, energy = 0.0;
    float hueBase = 0.0;
    for (int i = 0; i < u.count; ++i) {
        Voice v = voices[i];
        float level = v.lh.x;
        if (level <= 0.0009) continue;
        float seed = v.sp.x;
        float tier = v.sp.y;

        // Direction from the degree: the mode fans across a half-turn, so a
        // tonic and its fifth cross at an angle rather than lying parallel.
        float a = v.anchor.x * 1.9 + seed * 0.35;
        float2 d = float2(cos(a), sin(a));
        // Wavelength from the octave: low tier ~0.8 cycles per screen height,
        // high tier ~1.6, each voice a little different so nothing aliases.
        float k = (tier < 0.5 ? 0.8 : 1.6) * (0.85 + 0.3 * seed);
        // Half planar, half rings from a centre that wanders — the rings are
        // what make it Satori rather than a plasma, and a wandering centre is
        // what keeps them from ever settling into a bullseye.
        float2 c = float2(cos(seed * 6.2832 + t * 0.012 * (0.5 + seed)),
                          sin(seed * 4.1 - t * 0.009 * (0.7 + seed))) * float2(aspect, 1.0) * 0.8;
        float shape = mix(dot(p, d), length(p - c), 0.55);
        // Phase drift: slow, and distinct per voice.
        float speed = 0.035 + 0.05 * seed;
        float phase = shape * k * 3.14159 + t * speed + seed * 6.2832;

        hueSum   += level * sin(phase);
        lightSum += level * sin(phase * 0.71 + 2.1 + seed * 3.7);
        weight   += level;
        energy   += level * level;
        hueBase   = v.lh.y;
    }

    float hueShift, light;
    if (weight > 0.0) {
        // Normalise by the *energy* of what is sounding, not the weight. N
        // waves of equal amplitude summed and divided by N have an amplitude of
        // about 1/√N — with eight voices the picture sat at a third of its range,
        // which Jeff saw as "a murky cloud". Dividing by √Σlevel² keeps the sum's
        // RMS constant however many voices there are, and the soft S-curve then
        // spends that range on contrast rather than letting the rare in-phase
        // peak set the scale.
        float norm = 1.0 / max(sqrt(energy), 1e-4);
        // Gains set by ear-for-the-eye: 1.5 on the light was "arguably a little
        // too much contrast", the un-normalised sum "a murky cloud"; this sits
        // between them, as asked.
        hueShift = tanh(hueSum * norm * 0.9);        // -1…1
        light    = tanh(lightSum * norm * 1.05);
    } else {
        // Nothing sounding: a single broad wave in the default hue, so the
        // screen is a quiet wash rather than black before the first press.
        hueBase  = 0.62;
        hueShift = sin(dot(p, float2(0.8, 0.6)) * 2.2 + t * 0.03);
        light    = sin(dot(p, float2(-0.5, 0.9)) * 1.6 - t * 0.02 + 1.0);
    }

    // Palette: Thrum's own, so the three apps read as one instrument.
    //
    //   Ink.bg     (0.043, 0.039, 0.058)   the Mac window's plum-black ground
    //   Ink.mode   hue · sat 0.62 · bri 0.85   the mode's colour on the Mac
    //   Ink.amber  (0.98, 0.72, 0.36)       the core glow — icon, pad, tap tempo
    //
    // The phone's field tints its blooms `hue2rgb(hue) * 0.72 + 0.28`, which is
    // the same mode hue at much the same saturation. Here the wash runs from
    // the Mac's ground up to the Mac's mode colour, the interference bending the
    // hue only a few degrees either way — the mode's colour stays the mode's
    // colour, as it does on the Mac's grid and the phone's field — and where
    // the waves cross in phase the crest warms toward the amber, the way a held
    // pad glows on the Mac. Sixteen modes, sixteen hues, one look.
    const float3 inkBg    = float3(0.043, 0.039, 0.058);
    const float3 inkAmber = float3(0.98, 0.72, 0.36);
    float hue = hueBase + 0.05 * hueShift + 0.01 * sin(t * 0.011);
    float3 modeColour = 0.85 * mix(float3(1.0), hue2rgb(hue), 0.62);   // Ink.mode(hue)
    float3 modeDeep   = 0.42 * mix(float3(1.0), hue2rgb(hue), 0.70);   // the Mac pad, low level
    float3 modeLit    = 1.00 * mix(float3(1.0), hue2rgb(hue), 0.50);   // the Mac pad, lit
    float l = 0.5 + 0.5 * light;                                        // 0…1 across the wash
    l = l * (0.85 + 0.15 * u.master);
    // Four stops, the Mac's own: ground, pad at rest, mode colour, pad lit —
    // with the ends pulled in. The troughs stop a third of the way up from the
    // ground and the peaks halfway to the lit pad; the full spread read as too
    // much on a large panel, and none of it as murk.
    float3 floorColour = mix(inkBg, modeDeep, 0.35);
    float3 peakColour  = mix(modeColour, modeLit, 0.5);
    float3 colour = mix(floorColour, modeDeep, smoothstep(0.0, 0.42, l));
    colour = mix(colour, modeColour, smoothstep(0.38, 0.78, l));
    colour = mix(colour, peakColour, smoothstep(0.74, 1.0, l));

    // The crest: waves crossing in phase warm toward the amber core.
    float crestIn = max(hueShift * light, 0.0);
    colour = mix(colour, inkAmber * 0.9, 0.22 * crestIn * crestIn);

    // Gentle vignette, then the idle dim.
    float rr = length(uv / float2(aspect, 1.0));
    colour *= 1.0 - 0.28 * smoothstep(0.7, 1.4, rr);
    colour *= u.dim;

    // Output. The layer is Display P3 in sixteen-bit float, so these values
    // are P3-encoded (the wash's saturated blues and greens live outside sRGB)
    // and the panel gets a ten-bit ramp — hence no dither. A soft knee so
    // nothing flat-tops, as before.
    //
    // Not HDR, and not for want of trying: tvOS gives a Metal layer no way to
    // opt into extended dynamic range (`wantsExtendedDynamicRangeContent` and
    // `CAEDRMetadata` are unavailable there; only HDR video goes above
    // reference white on an Apple TV), so `u.headroom` arrives as 1 and the
    // crest lift below is a no-op. It is left in as the shape of the thing,
    // should a future tvOS open that door: crests where the waves cross in
    // phase would rise above white to a fraction of the headroom, the average
    // level staying put — this is looked at for hours in a dark room.
    float3 shaped = colour / (1.0 + colour * 0.55);
    float peak = clamp(u.headroom, 1.0, 4.0);
    float lift = 1.0 + (peak - 1.0) * 0.4;
    float crest = smoothstep(0.55, 1.05, dot(shaped, float3(0.2126, 0.7152, 0.0722)));
    shaped *= mix(1.0, lift, crest * u.dim);
    shaped = min(shaped, float3(peak));
    shaped = pow(max(shaped, 0.0), float3(0.90));

    return float4(shaped, 1.0);
}
