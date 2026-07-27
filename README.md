# Thrum

A macOS drone instrument. You set a key, a chord and a temperament in the app;
that harmony maps onto a Novation Launchpad X, and you build a drone out of it
by hand — tones swell in over seconds, hold indefinitely, and ride up and down
under your fingers. Any tone can be given a jawari buzz for a sitar edge.

The point is to make something a horn player or a guitarist can improvise over
for twenty minutes without it going anywhere or getting tiring.

`instructions.pdf` is the manual.

## Install

Grab `Thrum-1.0.zip` from the [latest
release](https://github.com/jeffehobbs/thrum/releases/latest), unzip it and drag
`Thrum.app` to `/Applications`. It's signed and notarized, so it opens without
any Gatekeeper detour. macOS 14+, Apple silicon or Intel.

A Novation Launchpad X is what makes it an instrument, but the app is playable
on its own — every control is in the window.

## Build from source

```
./build.sh            Release build
./build.sh run        Release, install to ~/Applications, launch
./build.sh debug      Debug build — for the debugger, not for the ears
./build.sh notarize   Release → Developer ID sign → notarize → dist/Thrum-<ver>.zip
```

Requires Xcode and `xcodegen`. macOS 14+.

Thrum is signed with the hardened runtime and no entitlements, because it needs
none — it opens CoreMIDI endpoints and an audio output unit, neither of which is
a restricted resource, and its only persisted state is a `UserDefaults`
dictionary. It is deliberately not sandboxed: the sandbox buys nothing for
Developer ID distribution here and gets in the way of talking to a
class-compliant USB controller.

> **Never listen to a Debug build.** The engine is ~40× slower under `-Onone`:
> 2× realtime with six voices (48% of a core) and *0.4×* with a full grid, so it
> misses the render deadline and crackles. Under `-O` the same code runs 84× and
> 16× realtime. This is why Release is the default — the failure doesn't look
> like a bug, it just sounds like a broken instrument.

---

## The sound

Thirty-two independent drone voices, one per grid pad. A voice is not a note:
it has no decay, and letting go of it is a slow fade rather than a note-off.

Each voice is up to **fourteen partials**, and every partial is **two
oscillators** offset by a fraction of a hertz. The offsets are in Hz, not cents,
which is the whole trick — a 0.3 Hz detune beats three times every ten seconds
whether it sits on the fundamental or the eleventh harmonic, so the entire
spectrum breathes at one slow rate instead of the top of it going ragged.
Partials are stretched by a per-timbre inharmonicity term, and the oscillator
pairs are panned slightly apart, so the beating rotates in the stereo field.

**Nothing repeats.** Every voice's pitch drift, tremolo, filter sweep, pan and
sitar swirl run off LFOs whose periods are distinct primes in seconds — 11, 13,
17, 19, 23, 29… A voice with a 41-second drift and a 67-second filter sweep
returns to the same state every 2,747 seconds. Two such voices, effectively
never.

**Eight timbres**, each a spectrum recipe rather than a preset of knobs:

| | |
|---|---|
| Harmonium | Warm odd-leaning reed spectrum with air behind it |
| Pipe Organ | A drawn registration — 16′ 8′ 4′ 2⅔′ 2′ 1⅗′ |
| Shruti Box | Dark, thick, beats hard |
| Bowed Strings | Full 1/n series under a soft filter |
| Bagpipe Drone | Cylindrical bore: odd harmonics dominate |
| Analog Bloom | Three-oscillator saw stack, lazy filter |
| Glass Choir | Stretched, hollow, mostly even partials |
| Tanpura | Fourteen partials and a jawari bridge |

**Jawari (sitar), per tone.** A four-stage allpass phaser swept on its own prime
period, plus a soft asymmetric shaper feeding a comb tuned to one period of the
fundamental. The comb reinforces the harmonic series instead of fighting it,
which is roughly what a flat sitar bridge does.

**The reverb is an FDN, not a Freeverb.** Comb banks turn metallic past three or
four seconds; this is an 8×8 Hadamard feedback delay network with modulated
fractional taps and per-line damping, fed through a pre-delay and four diffusion
allpasses. It holds a smooth 30-second tail. There are deliberately **no early
reflection taps** — early reflections tell the ear where the walls are, and the
point is that there aren't any. The whole field rotates left to right on a
97-second cycle.

**Spectral balance** is a fixed three-band shape: low shelf at 165 Hz for
weight, a dip at 3.2 kHz, a soft shelf at 9 kHz. The 3.2 kHz dip is the control
that matters — energy there is what makes a long drone tiring, so it has its own
slider called Presence Cut.

**Eight temperaments.** The tonal center is always at concert pitch, but every
interval above it comes from the chosen system's own cents table, so just
intonation really is just: 5-limit and 7-limit JI, Pythagorean, ¼-comma
meantone, 12-, 19- and 31-TET, and a harmonic-series mode that snaps each degree
to the nearest partial 16–32 of the root. Each pad shows how far its pitch sits
from 12-TET, in cents.

Changing key, mode or temperament while tones are sounding **glides** them to
their new pitches over half a second. It is a modulation, not an edit.

---

## Launchpad X

Programmer mode, all 81 keys.

```
  ◀KEY  KEY▶  ◀OCT  OCT▶  BANK  TIMB  TUNE  PANIC      top row, CC 91–98
 ┌────────────────────────────────────────────┐  ▓
 │ 8   tones — octave +3                      │  ▓     right column, CC 89…19:
 │ 7   tones — octave +2                      │  ▓     master-level ladder,
 │ 6   tones — octave +1                      │  ▓     eight steps, bottom = mute
 │ 5   tones — octave  0  (lowest)            │  ▓
 │ 4   timbre 1…8                             │  ▓
 │ 3   temperament 1…8                        │  ▓
 │ 2   sitar swell bloom air drift wide sat ✕ │  ▓
 │ 1   mode 1…8 of the current bank           │  ▓
 └────────────────────────────────────────────┘
                                        logo LED breathes with the output
```

Rows 8–5 are the mode laid out across four octaves — seven degrees plus the
octave, eight per row. Chord tones sit lit in amber when idle; everything else
is dim. Every pad is in the scale, so nothing you press is wrong.

- **Tap** a tone pad to swell it in, tap again to let it go. It's a latch, not a
  double-click — the second tap can come whenever.
- **Press into** a tone pad and its aftertouch rides that tone's level.
- Tone LEDs track the real envelopes, so the grid swells with the sound rather
  than snapping on at the tap.

A tap is a release inside 0.45 s with no real pressure behind it; anything
heavier or slower is read as a level ride and leaves the tone where your finger
left it. That means a deliberate, weighty press on a sounding pad won't remove
it — so **hold LET GO and tap** for a per-tone kill that never depends on
reading the gesture right. Holding LET GO to drop tones also consumes the press,
so lifting off doesn't take the rest of the drone with it.

Ways to take sound away, in order of violence: tap a tone off (fades over
**Fade**) · ride a tone to silence and lift · hold LET GO + tap tones · tap LET
GO for everything · press LET GO hard for a 1.2 s cut · **PANIC**, which kills
the voices *and* clears the reverb tail. The bottom pad of the right-hand ladder
is a mute rather than a removal — every tone keeps holding behind it.

Row 2 pads are all hold-and-press modifiers. They push a parameter while held
and put it back on release, so nothing is left somewhere you didn't intend:

| Pad | Held |
|---|---|
| SITAR | tone pads become jawari toggles; pressure sets the depth |
| SWELL | rides the whole drone up and down |
| BLOOM | opens the reverb — wet, size and decay together |
| AIR | brightens |
| DRIFT | more wander: drift, motion and beating |
| WIDE | opens the stereo field |
| SAT | more saturation |
| LET GO | tap to fade everything, press hard to cut it short, or hold and tap tones to drop just those |

---

## Launch Control

Not owned yet, so **every knob and slider lives in the Mac app** and always
will. The driver is written so the hardware needs nothing from you when it
arrives: plug it in and its knobs land on Thrum's parameters in the same order
the app shows them.

- Both the **Launch Control** (16 knobs) and the **Launch Control XL** (24 knobs
  + 8 faders) are recognised, and get different factory-template CC maps.
- **Soft takeover**: a knob does nothing until it passes through the
  parameter's current value, so grabbing one never jumps the sound.
- **MIDI learn**: click a parameter's name in the app, move a knob. The binding
  persists.
- Pads trigger the voicing presets.

---

## Voicings

Five starting points, because a good drone is a specific chord voicing and not
just "the notes of the chord":

- **Open Fifths** — root and fifth in three registers
- **Full Chord** — every chord tone, one per register
- **Modal Spread** — chord tones low, colour tones high
- **Tanpura** — the classic 5–1–1–1̇ cycle across all four registers
- **Pedal Root** — one low root and its octave

---

## Testing

`Tools/main.swift` renders the real engine offline to a WAV and reports whether
the result is actually a drone:

```sh
swiftc -O Shared/{Tuning,Harmony,Timbre,Events,Cathedral,DroneEngine}.swift \
       Tools/main.swift -o /tmp/thrumtest

/tmp/thrumtest out.wav 30           # a D Dorian drone in 5-limit JI
/tmp/thrumtest out.wav 20 stress    # all 32 voices, 14 partials, jawari on everything
/tmp/thrumtest out.wav 40 tail      # short note then nothing but reverb, measures RT60
```

It prints peak, RMS, non-finite count, slow-envelope fluctuation (the audible
beating), a one-third-octave spectrum tilt, a per-second envelope trace, and
realtime factor. Numbers on an M-series Mac, built `-O`:

- musical drone, 6 voices: **77× realtime**, 1.3% of one core
- stress, 32 voices with jawari: **15× realtime**, 6.6% of one core
- reverb: measured RT60 **14 s** against a 16 s setting, decay smooth to −145 dB

**Compile the harness the same way you ship the app.** Measuring `-O` and
shipping `-Onone` hides a 40× difference, which is exactly how a Debug build got
into a listener's hands sounding like it was falling apart.

The reported `peak` is *not* a clipping check — the output stage ends in
`tanhf()`, so `|out| < 1` is guaranteed and that assertion can never fail. Real
headroom has to be measured before the limiter.

`Tools/icon/` draws the app icon. `Tools/click/` posts real CGEvent clicks —
System Events' `click at` routes through accessibility and never reaches
SwiftUI gestures. `Tools/midilist/` and `Tools/midimon/` check what CoreMIDI
sees and decode incoming pad presses against the grid geometry.
`Tools/pdfpng/` and `Tools/pdftext/` rasterize and outline a PDF, which is how
the manual's page breaks get checked.

---

## The manual

`instructions.pdf` — 15 pages covering every control in the app and every key on
the Launchpad, plus the jawari explained in detail and a troubleshooting page.
Rebuild it after changing any control:

```sh
./Tools/manual/build-manual.sh      # renders Tools/manual/manual.html via headless Chrome
```

The Launchpad diagram is a CSS grid of **ten** tracks — row label, eight pads,
right-hand column. Every row has to supply exactly ten children or the whole
figure staircases diagonally.

---

## Layout

```
Shared/   Tuning       temperaments and pitch-class tables
          Harmony      key, mode, register → 32 grid pitches
          Timbre       the eight spectrum recipes
          Events       lock-free event queue, biquads
          DroneEngine  voices, partials, modulation, master chain
          Cathedral    the FDN reverb
          ThrumModel   instrument state; the only writer to the engine
App/      ThrumApp     AVAudioEngine host
          ThrumView    the interface
          MIDISurface  shared CoreMIDI plumbing
          LaunchpadController
          LaunchControlController
```
