# Thrum

A macOS drone instrument. You set a key, a chord and a temperament in the app;
that harmony maps onto a Novation Launchpad X, and you build a drone out of it
by hand — tones swell in over seconds, hold indefinitely, and ride up and down
under your fingers. Any tone can be given a jawari buzz for a sitar edge.

There is also a **pulse** — a tapped tempo and four arpeggiators that work the
chord you are already holding, at four different rates at once — and a
**spatial** mode that places every tone around your head and keeps it there when
you turn, on AirPods Pro or AirPods Max.

Or press the **☯** and let the instrument play itself.

`instructions.pdf` is the manual.

## Install

Grab `Thrum-1.4.0.zip` from the [latest
release](https://github.com/jeffehobbs/thrum/releases/latest), unzip it and drag
`Thrum.app` to `/Applications`. It's signed and notarized, so it opens without
any Gatekeeper detour. macOS 14+, universal — Apple silicon and Intel.

From 1.4.0 on it updates itself: Thrum checks for new releases and offers to
install them, and there's a **Check for Updates…** item in the app menu. The first
launch asks before it ever phones home, and declining is remembered. If you're on
1.3.2 or earlier there's no updater in that build to tell you this one exists, so
this download is a one-time manual step.

A Novation Launchpad X is what makes it an instrument, but the app is playable
on its own — every control is in the window.

## Build from source

```
./build.sh            Release build
./build.sh run        Release, install to ~/Applications, launch
./build.sh debug      Debug build — for the debugger, not for the ears
./build.sh notarize   Release → Developer ID sign → notarize → dist/Thrum-<ver>.zip
                      → docs/appcast.xml
./build.sh appcast    Regenerate docs/appcast.xml from the existing zip
./build.sh testflight ThrumFlow (iOS/iPadOS) → archive → App Store IPA
```

There are two targets. **Thrum** is the Mac instrument. **ThrumFlow** is the passive
iOS/iPadOS build — the same engine with Flow playing it and a Metal field showing
what it's doing, no instrument surface at all. Both share `Shared/` verbatim; only
`AudioRoute` is platform-split, since macOS reconstructs the route from a CoreAudio
transport code and iOS just asks `AVAudioSession`. One build covers iPhone and iPad
(`TARGETED_DEVICE_FAMILY "1,2"`), so there is no separate iPadOS target.

Installing on a device needs no Xcode GUI and no cable if the phone is paired over
Wi-Fi — Developer Mode on, an *Apple Development* certificate (separate from the
Developer ID used for notarising), then:

```
xcodebuild -project Thrum.xcodeproj -scheme ThrumFlow -sdk iphoneos \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcrun devicectl device install app --device <id> <path>/ThrumFlow.app
```

Use `generic/platform=iOS`, not a specific device: a device destination fails with
"developer disk image could not be mounted", which looks like an SDK-version problem
and isn't. The real error is `kAMDMobileImageMounterDeviceLocked` — **unlock the
phone.** Reading the device log needs USB *and* admin, and `log` may be shadowed in
your shell, so use `/usr/bin/log`.

### TestFlight

`./build.sh testflight` archives, exports an App Store IPA to `dist/ios/`, validates
it, and uploads. Signing is Cloud Managed, so Apple holds the distribution
certificate and none of your local certificate slots is spent.

Credentials come from the environment and either kind works:

```sh
export ASC_APPLE_ID="you@example.com"        # your Apple ID email; not a secret

# Once, ever — the password then lives in the keychain and build.sh finds it:
xcrun altool --store-password-in-keychain-item --item thrum-asc \
  -u "$ASC_APPLE_ID" -p abcd-efgh-ijkl-mnop   # --item is required; altool's usage omits it

# …or an API key instead, with the .p8 in ~/.appstoreconnect/private_keys/
export ASC_KEY_ID=<id> ASC_ISSUER_ID=<uuid>
```

The app-specific password comes from
[appleid.apple.com](https://appleid.apple.com) → Sign-In and Security →
App-Specific Passwords — **not** App Store Connect. It is per Apple ID rather than
per app, so one made for another project works here unchanged; `build.sh` probes a
few likely keychain item names for exactly that reason.

**Apple shows that password once and it can never be retrieved** — not from the
website, not from anywhere. Store it at the moment you create it or you will be
generating another one. `ASC_APP_PASSWORD` in the environment still works and takes
precedence, but the keychain keeps it out of your shell history.

With no credentials at all it still archives, exports and stops with the IPA on
disk, which is the useful half of a dry run.

**The one thing that can't be scripted** is the App Store Connect app record, at
[appstoreconnect.apple.com/apps](https://appstoreconnect.apple.com/apps): the API has
no create-app endpoint. One web visit, once, bundle id `com.jeffhobbs.thrumflow`.

Every upload needs a build number App Store Connect has not seen, and it rejects a
repeat *after* the upload and a processing wait. Bump `CURRENT_PROJECT_VERSION`, or
pass one: `./build.sh testflight $(date +%s)` sidesteps the bookkeeping entirely.

Two declarations that gate uploads rather than merely warning:

- `ITSAppUsesNonExemptEncryption` is `false` in `project.yml`, so export compliance
  doesn't ask on every build.
- **`iOS/PrivacyInfo.xcprivacy` is required, not optional.** Flow persists
  `flow.lastKey` to UserDefaults so a relaunch can't open in the key the last session
  used, and UserDefaults is a required-reason API — an upload with no declaration
  gets ITMS-91053. The manifest declares that one category with reason `CA92.1` and
  nothing else, because nothing is collected and nothing leaves the device. Add to it
  if the target ever reads file timestamps, disk space, boot time or the active
  keyboard. It is not needed for the Mac app, which ships Developer ID rather than
  through the store.

`altool --validate-app` runs before every upload on purpose: it catches that whole
ITMS-9xxxx family in about a minute, against finding out by email a quarter of an
hour later.

The iOS app icon is a *separate* catalog from the Mac one and that's deliberate: iOS
refuses any alpha channel (ITMS-90717) and masks its own corners, where the macOS icon
is an inset tile with rounded corners baked in. `Tools/icon --ios` renders the
full-bleed opaque variant.

Requires Xcode and `xcodegen`. macOS 14+.

`build.sh` passes `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` and then **checks the
result with `lipo`**, failing the build if the binary isn't universal. Both halves
matter: xcodebuild defaults to `ONLY_ACTIVE_ARCH=YES` for a local build, so
leaving it implicit quietly produces a host-only binary — Thrum shipped arm64-only
from 1.0 through 1.3.1 while the README claimed Apple silicon *or* Intel, and
nothing in the pipeline noticed. Note that the published performance figures were
all measured on arm64.

The version lives in **`project.yml` only** — `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION`. `App/Info.plist` is regenerated by `xcodegen` on every
build and its two version keys are `$(MARKETING_VERSION)` /
`$(CURRENT_PROJECT_VERSION)` so they follow. Don't edit the plist: XcodeGen's own
default for those keys is a hardcoded `1.0` / `1`, so a hand-edit is overwritten
on the next generate, and bumping `MARKETING_VERSION` alone used to notarize a
correctly-built app that still called itself 1.0. `build.sh` takes the release
filename from the *bundle*, so check `dist/Thrum-<ver>.zip` is the version you
meant before shipping.

## Shipping a release

Updates go out through [Sparkle](https://sparkle-project.org). Installed copies
poll `docs/appcast.xml`, served at
`https://jeffehobbs.github.io/thrum/appcast.xml` by GitHub Pages, and refuse any
archive not signed by Thrum's Ed25519 key.

1. Bump **both** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `project.yml`. Sparkle compares `CURRENT_PROJECT_VERSION` (`CFBundleVersion`) to
   decide whether an update exists, so forgetting it ships a release nobody is
   offered — the app is new, the feed says it isn't.
2. Optionally write `notes/<version>.html` — Sparkle shows it in the update
   dialog. Without one the dialog shows version numbers and nothing else.
3. `./build.sh notarize`
4. Create the GitHub release **tagged `v<version>`** and attach
   `dist/Thrum-<version>.zip`. The tag has to match: the appcast's download URL is
   built as `…/releases/download/v<version>/Thrum-<version>.zip`, and a mismatch is
   a 404 that only shows up when someone tries to update.
5. Commit and push `docs/appcast.xml`. **Do this after step 4** — the feed
   advertises a download that has to already exist.

One-time setup, already done: `generate_keys` created the Ed25519 keypair,
`SUPublicEDKey` in `project.yml` is its public half, and GitHub Pages needs to be
serving from `/docs` on `main`.

The private key lives in the login keychain and is the one thing here that cannot
be replaced. Installed copies trust that key and nothing else, so losing it strands
every copy in the field on whatever version it has — there is no recovery path
short of everyone manually downloading a build signed with a new key. Back it up:

```
build/sparkle-tools/2.9.4/generate_keys -x thrum-sparkle-key.txt
```

Thrum is signed with the hardened runtime and no entitlements. CoreMIDI
endpoints and an audio output unit are not restricted resources, and its only
persisted state is a `UserDefaults` dictionary. It is deliberately not sandboxed:
the sandbox buys nothing for Developer ID distribution here and gets in the way
of talking to a class-compliant USB controller.

The one thing it can be *denied* is head tracking, which reads AirPods
orientation through CoreMotion and so carries an `NSMotionUsageDescription` and
raises a Motion & Fitness prompt the first time you turn it on. Everything
degrades to a head-locked field if you say no; nothing else in the app asks for
anything.

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

**Hold BANK** and the whole board becomes the arpeggiator page instead — see
[Pulse](#pulse--arpeggios-over-the-drone). Nothing below is taken away for it.

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
- Pads trigger the first six voicings, plus let-go and panic. Capped at six on
  purpose — there are fifteen voicings, and letting them fill all eight pads
  would cost the panic button.

---

## Voicings

Fifteen starting points, because a good drone is a specific chord voicing and
not just "the notes of the chord":

- **Open Fifths** — root and fifth in three registers
- **Full Chord** — every chord tone, one per register
- **Modal Spread** — chord tones low, colour tones high
- **Tanpura** — the classic 5–1–1–1̇ cycle across all four registers
- **Pedal Root** — one low root and its octave

Ten more are borrowed from traditions that have been holding drones for a very
long time. What is worth stealing from each is not its scale — Thrum already has
the modes — but **which intervals it leaves out, and which register it puts the
rest in**:

| | | |
|---|---|---|
| **Highland** | Scotland | Great Highland pipes: a bass drone an octave under two tenors, and no fifth anywhere |
| **Uilleann** | Ireland | Three drones an octave apart, with the regulators' triad on top |
| **Gaida** | Bulgaria | The tonic under a second, in the same register — the rub village singing is built on |
| **Aitake** | Japan | The shō's gagaku cluster: fourths and seconds over two octaves, every pipe the same weight, nothing in the bass |
| **Launeddas** | Sardinia | The triple pipe — the tumbu's low drone with a fourth and a fifth over it |
| **Georgian** | Georgia | Village polyphony over the bass: fifth, fourth, bare seventh, and no third at all |
| **Didgeridoo** | Australia | One fundamental and its own harmonic series, at harmonic-series levels |
| **Hardanger** | Norway | The hardingfele's sympathetic understrings, ringing quietly in one high register |
| **Gyütö** | Tibet | The fifth down in the lowest register, where nobody else puts one |
| **Guqin** | China | The qin's open strings — pentatonic, no fourth and no seventh, over four octaves |

Each is described in *scale degrees*, and not every mode has the flavour of
fourth or fifth the original was built on — so every degree has a fallback, and
failing that takes whichever degree simply sits in that position. Two degrees
can still collapse onto one pad in a mode that hasn't got both (whole tone has
no perfect fourth or fifth, only the tritone between them); the louder ask wins
rather than whichever was listed last.

Some of these want other settings moved with them. **Gaida** is a beating
interval by design, so turn *Beating* down or the second and the tonic fight
twice over. **Hardanger** and **Aitake** deliberately hold nothing in the bottom
octave — reach for *Warmth* if the room needs a floor.

---

## Pulse — arpeggios over the drone

An arpeggio in Thrum is not a sequence of notes. It is an **accent on a voice
that is already sounding**: the drone keeps holding exactly as it was, and the
pulse rides a fast attack-decay envelope on top of whichever voice it is
pointing at. Tap in a chord, press Run, and the chord starts to shimmer through
itself. Nothing is muted, nothing is retriggered, and letting the pulse go
leaves the drone standing.

Because the accent is additive, a tone that is *not* held will sound only for
as long as its ring — so a lane can play degrees that aren't in the drone at
all, over the top of the ones that are.

**Tap tempo.** Tap four times in time with the room. The last tap is the
downbeat, and it drops every lane back onto beat zero, so re-aligning to a
drummer is one gesture. ⌘K taps; ⌥⌘P runs and stops.

**Four lanes.** Each one has:

| | |
|---|---|
| **Source** | Held · Chord · Scale · Root · Colour — always drawn from the mode and chord already loaded |
| **Pattern** | Up · Down · Up·Down · Down·Up · Converge · Diverge · Pinwheel · Scatter · Chord |
| **Rate** | ×½ ×¾ ×1 ×1½ ×2 ×3 ×4 ×6 steps per beat |
| **Register** | which of the four octaves it works in |
| **Offset** | quarter-beat shifts, so lanes chase rather than lock |
| **Level** | how far that lane sits above the drone |

Rates are **ratios rather than note values**, because the interesting ones here
are the ones that fight. A lane at ×1 against a lane at ×1½ takes six beats to
come back around; ×1 against ×6 with a five-note set and a seven-step accent
takes long enough that you stop hearing a loop. That drift is the whole point.

*Source* works in scale degrees, not pads. **Held** means "the degrees you are
holding" — so one chord tapped in low can arpeggiate in all four octaves at
once, one lane per register, without tapping it in four times. **Colour** is the
degrees the chord leaves out: the tension notes, which is where the good lanes
usually are.

Eight presets — *Pulse, Three : Two, Tanpura, Gamelan, Phase, Rain, Undertow,
Swarm* — set all four lanes and a tempo at once. They live in the Pulse menu and
in the panel's Presets button.

**Strike** and **Ring** in the parameter column are the accent's attack and
decay. Short strike and short ring is a marimba inside the drone; long ring
(past a couple of seconds) stops the notes being separate at all and just makes
the chord breathe. **Unsteady** puts a repeatable wobble in the velocities,
which a long cycle needs or it reads as a machine.

Arming a tone's jawari and then arpeggiating it is worth doing on purpose: a
plucked note through the bridge buzz is what a sitar actually is.

PANIC stops the clock as well as the voices.

### On the Launchpad

**Hold BANK** and the whole board becomes the arp page. Nothing was taken away
to make room for it — tapping BANK still cycles the mode bank, and it only
cycles if you let go without having pressed anything else.

```
  BPM− BPM+ BPM−5 BPM+5 [BANK] TAP SWING PANIC
 ┌────────────────────────────────────────────┐
 │ 8   lane 4 — rate ×½ … ×6                  │
 │ 7   lane 3 — rate                          │
 │ 6   lane 2 — rate                          │
 │ 5   lane 1 — rate   (press the lit one = off)
 │ 4   pattern ×4 · register ×4               │
 │ 3   offset  ×4 · source   ×4               │
 │ 2   tap run off align ÷2 ×2 swing unsteady │
 │ 1   presets 1…8                            │
 └────────────────────────────────────────────┘
```

Lane N is column N throughout rows 3 and 4, so the four lanes read as four
vertical stripes whichever row you are on, in the same four colours the app
uses. Picking a rate arms that lane; pressing the lit rate turns it off. The
selected rate flashes as the lane strikes.

### How it is put together

The clock runs on its own serial queue at `.userInteractive`, not on the main
thread, so the pulse does not stutter when the window redraws. It is handed a
*resolved* plan — a plain list of pad numbers per lane — whenever the harmony,
the held notes or a lane setting moves, so it never reaches back into the model
or SwiftUI to decide what to play, and the only thing it touches is the engine's
lock-free event queue.

Steps land on a 4 ms grid and the engine picks them up at the next render block.
Against a strike time measured in tens of milliseconds that is inaudible, and it
is why the whole feature costs one `Float` per voice in the render loop.

Step numbers are absolute positions on the clock rather than a running index, so
a lane stays phase-locked no matter what changes underneath it — add a note to
the chord mid-figure and the lane keeps its place in the bar.

---

## Flow

Press the **☯** in the top bar (or `⌥⌘F`) and Thrum takes itself somewhere. Modes
turn over, voicings rebuild, timbres change, arpeggios arrive and leave, and two
dozen controls are sliding at any moment. It is meant to be worked through — put
it on and go read something.

The whole design is in the transitions, not the destinations. Two rules:

- **Nothing is ever set, only ramped.** Every change is a slide of twenty to
  ninety seconds on a smootherstep curve — zero velocity *and* zero acceleration
  at both ends — so a change has no edge to notice at either side. The shortest
  slide Flow will open is nine seconds.
- **Nothing is hidden, either.** Swapping a timbre used to be the one genuinely
  discontinuous edit — every partial of every voice changing level in the same
  sample — and Flow covered it by dipping the whole drone to 0.22 first, changing
  the reeds while it was down, and bringing it back. That was the wrong shape of
  fix and a listener caught it: the dip is itself an event, so it drew attention
  to the very moment it was covering, and −13 dB was never enough to cover a
  spectrum swap anyway. The engine crossfades its own spectrum now over fourteen
  seconds (`timbreSeconds`), no partial ever steps, and Flow simply asks for the
  new timbre. The general lesson: hiding a discontinuity under a gesture makes the
  gesture the event — remove the discontinuity instead.

Every gesture runs on its own clock at its own tempo, so nothing lines up:
parameters drift every ten seconds or so, voicings turn over every two to four
minutes, temperament shifts maybe twice an hour. That is the same idea as the
engine's prime-numbered modulation, one level up.

**The key never moves, and neither does the register.** Both were built and both
were wrong: moving the key glides every sounding pitch by a fourth or a fifth,
moving the register does it by an octave, and no amount of stretching the glide
or hiding it under a breath stops that reading as an event nobody asked for. Flow
stays in the key it was handed and finds its variety inside it — modes, voicings,
which octaves the voicing occupies, temperaments, timbres, arpeggios. There is a
test that holds it to that.

**It is a different journey every time** — the generator is reseeded on every
start, not just at launch.

Two more things Flow will not do. It never touches **Output**, because the volume
is yours. And **Presence Cut** has a floor of 0.45, because energy around 3 kHz is
what makes a long drone tiring and Flow is the one mode that runs for hours
unattended. Turning Flow off leaves everything exactly where it drifted to, which
is often a better patch than the one you started from.

---

## The transport (ThrumFlow)

One tap on the ☯ starts a session, and that is the last time you see it. From then on
the centre control is **play/pause** — because pausing is not un-starting, and putting
the ☯ back would be offering to begin something already under way.

Pause holds the journey rather than ending it. `AVAudioEngine.pause()` keeps the render
graph and every node's state intact, so resuming picks the voices up mid-envelope;
`stop()` tears that state down and comes back to silence that has to be rebuilt. Flow's
clock stops with it, so a fifty-second slide that was thirty seconds in is still thirty
seconds in when the sound returns — **wall-clock time passing while nothing is audible
is not time this instrument has lived through.** It is deliberately not a fade: letting
go is what stopping does, and swelling every voice back in would be an event at both
ends.

**Interruptions pause and resume by themselves.** Siri reading a message, a phone call,
a timer: the engine and Flow's clock stop together and come back where they left off.
This used to be empty — the `.began` case did nothing on the grounds that the session
was already gone — which meant the graph was still nominally running through the
interruption, so the recovery path saw `audio.isRunning == true` and declined to
restart anything. The drone never came back.

`.shouldResume` is advisory and frequently absent for a notification read aloud.
Honouring it strictly is right for a music player, where the listener may have moved
on, and wrong for a drone deliberately left running in a room — so what decides it here
is our own record of whether an interruption is what stopped us. A pause you asked for
is never undone by Siri finishing a sentence.

Play and pause mean the same thing everywhere: on screen, on the lock screen, in
Control Centre and in the car. Pause was once wired straight to `stop()`, which faded
every voice and ended the session, so pressing play afterwards began a whole new
journey in a different key.

---

## Taste — the thumbs (ThrumFlow)

The iOS app has two more controls either side of play/pause: **thumbs up** and **thumbs
down**. Both also appear in the car, on `CPNowPlayingTemplate`.

On the **lock screen** they arrive in disguise, and that is the API's doing rather
than a choice. `MPFeedbackCommand` is the only rating control Now Playing has: iOS
draws its `like` as a **★**, and gives its `dislike` no slot at all. So the lock
screen is **★ = more like this**, and **⏭ = less like this**.

Repurposing ⏭ is normally a bad idea, but the usual objection doesn't apply: there
is no next track in a continuous drone, so ⏭ has no honest meaning to displace —
and what it means to a listener, *"enough of this one, move along"*, is exactly what
a thumbs-down does. It routes through the same `moveOn` as the on-screen button, so
it still changes one quality on that quality's own ramp; nothing reached from the
lock screen arrives more abruptly than Flow's own gestures. What is lost is
discoverability, and it can't be bought back: `localizedTitle` is a
`MPFeedbackCommand` property, not an `MPRemoteCommand` one, so a transport button
cannot be relabelled — it draws as ⏭ and reads as "Next Track" to VoiceOver.

The car gets **both** — the real 👍 👎 glyphs on `CPNowPlayingTemplate`, *and* the
same ⏭ mapping, which is the control a driver's hand already knows where to find.

Everything else in the transport is explicitly disabled, including
`skipForward`/`skipBackward` — they default to *enabled* and are what iOS falls back
to drawing for a live stream, so leaving them alone put two dead ⏪ ⏩ on the lock
screen of something with nowhere to seek to. Disabling next/previous is not enough
on its own.

Two labelled thumbs on the lock screen itself would need a Live Activity with
interactive App Intent buttons — a widget extension, a new target and a new signing
surface. Not done.

They are not a rating of a track — there is no track. Over months they change what
Flow chooses.

**The hard part is not storing the votes, it is deciding what they were about.** A
thumbs-up arrives with no explanation, and at that moment thirty things are true of
the drone at once: a key, a mode, a temperament, a timbre, a voicing and two dozen
sliders. So a vote is not recorded against "the drone" — there is no such object to
keep — but spread across *every quality that was audible when it was cast*. One vote
says almost nothing. Fifty say a great deal, because the qualities that keep turning
up in liked drones accumulate, while the ones that were merely along for the ride
appear on both sides of the ledger and cancel. Nothing is ever interpreted; the noise
is left to average itself out.

What that buys, per kind of quality:

- **Discrete things** — key, mode, temperament, timbre, voicing — get a smoothed
  score from their up and down weight, which becomes a multiplier on Flow's draw. A
  liked mode comes up about twice as often; a disliked timbre about a third as often.
- **Continuous controls** — every slider Flow drives — learn *where* you like them.
  Flow's roam band for that control is narrowed toward the middle of your liked
  settings and away from your disliked ones.

Four rules it holds to, each of which could have gone the other way:

- **Nothing is ever ruled out.** Every weight has a floor, so a disliked timbre
  becomes rare rather than unreachable. A catalogue pruned to a favourite handful is
  a worse instrument even if everything left in it scores well — and a trait that can
  never be chosen can never be re-rated, so a hard exclusion is also permanent.
- **An untaught Taste is invisible.** Every weight is exactly 1.0 and every roam band
  comes back exactly as it went in. A fresh install behaves identically to the app
  before any of this existed.
- **It never stops moving.** A learned band is never narrower than a third of the one
  it replaced, always stays inside Flow's own pleasant range — a hundred thumbs-up
  cannot push Presence Cut below its anti-fatigue floor — and one drift in six
  ignores what has been learned entirely. That last one is not a hedge: a control
  kept inside its learned band never gets heard anywhere else, so it never gets rated
  there, so the band could only ever tighten.
- **Old votes fade**, on a 150-day half-life. Taste in a drone is not a fact about a
  person, it is where they are this year.

**The two thumbs are deliberately not symmetrical** in what they do to the sound,
only in what they teach:

- **Thumbs-up changes nothing.** It is filed, and that is all. An earlier version
  pushed the disruptive gestures out so a praised drone would last longer; it was
  wrong for a reason worth keeping written down. Saying you like something should
  not be a thing you think twice about pressing. The moment approving of a drone
  also silently rearranges it, the button has a cost — and a rating button with a
  cost gets used less and teaches less. There is a test that holds it to this.
- **Thumbs-down brings the next change forward.** Not a new or special change:
  whichever one Flow had already planned next, simply sooner. That keeps every
  transition on the rails it was always going to run on — the crossfade in `apply`,
  the glide in `setMode`, the fourteen-second spectrum crossfade around a timbre —
  and means the button can never invent an event of its own. What arrives is still
  shaped by the vote, because every choice Flow makes is weighted by taste.
  Measured: it changes the drone's character 40 times out of 40, and ten impatient
  presses in a row do not stack up a queue of changes.

**Reversing a thumb within five seconds is a correction, not a second opinion.**
These buttons get pressed in a pocket, in the dark, one-handed, 22 points apart;
hitting the wrong one and the right one a second later is one listener holding one
opinion, and filing both would put real evidence against every quality of that
drone *and* its opposite. So a vote is **held for five seconds before it is written
down** — and thumbs-down does not hurry the next change along either, because the
whole point of a correction is that the mistaken press leaves no trace, and an
audible consequence is a trace. The screen says "Corrected — more like this". The
acknowledgement is immediate; only the consequence waits, and what it triggers is a
fourteen-second crossfade nobody is timing. Changing your mind *later* is still two
genuine opinions and both are recorded, which is what the harness's control run
checks. Measured: a taken-back thumbs-down changes the drone within twelve seconds
5 times in 30, against 7 in 30 for no press at all and 29 in 30 for a real one.

That second one has a consequence worth knowing about. Flow's four "change the
character" gestures now **always land on something different from what is sounding**.
A weighted draw over eight timbres picks the current one about an eighth of the time,
and a change-the-timbre gesture that changes it to itself is one that quietly did
nothing — invisible when it only fired on its own timer, and a button press producing
silence once thumbs-down can pull it forward.

**The key is the exception**, and for the reason the rest of Flow is built on: it is
never moved mid-session, so a thumbs-down cannot move it either. A disliked key is
still recorded, and acted on where it can be — the next session opens somewhere else.

The line under the buttons says what has been learned so far ("leaning toward Gyütö,
Lydian · away from Glass Choir"), or how many ratings it is still waiting on.
Long-press it to forget everything. The database is a JSON file at
`Library/Application Support/Thrum/taste.json`; the Mac app deliberately gets an
in-memory one that learns nothing, so the offline harnesses keep measuring Flow
rather than Flow plus whatever was liked last week.

---

## Spatial — the drone around you

Sixteen mono buses placed around your head and rendered binaurally, instead of
one stereo mix. `⌥⌘S` toggles it.

The grid already has two axes worth putting in a room, so the mapping is a fact
about the music rather than a decoration: the **eight columns are compass
points** with the tonic dead ahead, and the **four rows are two rings** — the low
two octaves slung below the ear line, the high two lifted above it. An arpeggio
walking up a column therefore climbs as well as rises in pitch, and a lane
walking across the mode orbits you. Four lanes at four rates become four orbits
at four speeds.

**Head tracking** (`⌥⌘H`) reads AirPods orientation and counter-rotates the
listener, so the drone stays where it is in the room when you turn your head.
**Recenter** (`⌥⌘R`) takes wherever you are looking as straight ahead — AirPods
yaw drifts, so this is the button you will actually use.

Recenter earns its keep for a second reason. "Straight ahead" is captured the
moment tracking starts, so if you were looking down at the screen at the time,
every angle afterwards is measured from there — and a head that is nodding
around 60° of *relative* pitch is much closer to vertical than it feels. That
used to matter a great deal: tilting through vertical made the field lurch, and
Thrum heard it as a real head movement. It no longer does, because the transport
carries the rotation itself rather than three Euler angles — see
[Head tracking is a rotation, not three numbers](#head-tracking-is-a-rotation-not-three-numbers).

Two things to get right or it won't sound like anything:

- **Turn macOS's own Spatial Audio off** for the AirPods. Two lots of HRTF smear
  each other.
- **Turn Wet down.** The reverb tail deliberately bypasses the spatial stage — a
  thirty-second diffuse tail has no location to be placed at — so it stays a
  stereo bed and does not rotate with your head. The more of it you have, the
  less the field localizes.

### How it is put together

`DroneEngine` gets a second master chain. Voices still sum to stereo, because
that is what feeds the reverb, but each voice *also* writes mono into its own
bus, and each bus gets its own EQ and saturation before being handed to
`AVAudioEnvironmentNode` with a position. The wet tail is extracted by
subtraction — Cathedral is additive, so processed-minus-send is exactly the tail,
with no change to the reverb.

There is **one limiter for the whole field**, detected on the mono sum and applied
equally to every bus. A per-bus limiter would pump the image sideways every time
one compass point got loud. The ceiling is a smooth `tanh(x)/x` ratio rather than
a clamp, for the reason in the code comment.

Seventeen source nodes mean seventeen render callbacks per cycle, but the engine
must render once: the first callback to see a new `mSampleTime` does the work and
the rest copy their slice. Nominating a "leader" node would be wrong — callback
order between mixer inputs is not guaranteed.

Costs, measured (`Tools/spatial`): the engine's spatial chain runs at ~18×
realtime with a full grid and jawari on everything, and the sixteen HRTF
instances add about **0.2% of one core** on top. That number is why the graph is
built up front rather than lazily — see below.

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

`Tools/pulse/` is the arpeggiator's harness — it renders the engine offline and
checks what actually comes out:

```sh
swiftc -O -o /tmp/thrumpulse \
  Shared/{Tuning,Harmony,Timbre,Events,Cathedral,DroneEngine,Pulse}.swift \
  Tools/pulse/main.swift
/tmp/thrumpulse
```

It asserts that an accent on an *unheld* voice sounds and then falls to true
silence and releases the voice; that an accent on a *held* voice rises above the
drone and leaves it bit-identical once it has rung out; that Strike and Ring
match the times they claim; that the real clock fires the right number of notes
in two seconds of wall clock; and that every pattern covers its whole set
without ever indexing out of range at any size.

The held-voice test runs the same timeline **twice, with and without the
accent**, and compares. The drone's tremolo and filter sweep move its level
around on prime periods, so a bare before/after measurement drifts by 40% on its
own and will happily report a bug that isn't there.

`Tools/spatial/` is the spatial harness. It checks that each pad lands on exactly
its own bus; that the wet bed is silent at Wet=0 and that the dry is unaffected by
the reverb setting; that limiting is *uniform*, by running the same field twice at
different levels and confirming the ratio between two buses survives; and — via a
manual-rendering `AVAudioEngine` carrying the app's real graph — what the
**post-HRTF** output actually peaks at, which is the only measurement that can
answer "does it clip".

```sh
swiftc -O -o /tmp/thrumspatial \
  Shared/{Tuning,Harmony,Timbre,Events,Cathedral,DroneEngine,Spatial}.swift \
  Tools/spatial/{ablholder,binaural,main}.swift
/tmp/thrumspatial
```

`Tools/flow/` drives Flow through hours of compressed time and checks the things
it promises: that no control ever moves more than a few percent of its travel in
one tick, that something is moving on essentially every tick, that nothing leaves
its range, that Output is untouched and Presence Cut holds its floor, that
Beating/Drift/Motion never go dead, and that two runs end up somewhere different.

```sh
swiftc -O -o /tmp/thrumflow \
  Shared/{Tuning,Harmony,Timbre,Events,Cathedral,DroneEngine,Pulse,Spatial,ThrumModel,Flow}.swift \
  Tools/flow/main.swift
/tmp/thrumflow
```

It earned its keep immediately: it caught the preset tempo arriving as a 23% jump
and a two-second fade that was quicker than the mode's own floor.

`Tools/taste/` is the thumbs' harness, and it exists because a preference system is
unusually easy to get wrong in a way nobody notices — the failure mode is not a
crash, it is an app that claims to be learning and either isn't, or is over-learning
so hard it plays one drone forever. Both sound plausible from the sofa. So it teaches
a simulated listener's opinions to a real `Taste`, runs real Flow against it, and
counts what comes out: that an untaught database returns every weight as exactly 1.0
and every roam band untouched; that a liked mode's share of Flow's time rises (10.7%
→ 22.5%) and a disliked timbre's falls (10.5% → 7.0%); that eighteen hours of Flow
still visits all eight restful modes, twelve voicings and the disliked timbre; that a
learned band stays inside Flow's range and never collapses; that Flow still wanders
outside it; that thumbs-up measurably reduces upheaval and thumbs-down always changes
something within thirty seconds *without ever moving the key*; that old votes fade and
six recent ones can overturn fifteen old ones; and that the file round-trips.

```sh
swiftc -O -o /tmp/thrumtaste Shared/*.swift \
  Tools/spatial/ablholder.swift Tools/taste/main.swift
/tmp/thrumtaste
```

It also checks the transport: that pausing is a state of a *running* session rather
than a stopped one, that nothing drifts through ten minutes of paused time, that the
drone is the same one when it comes back, and that resuming keeps the session's key —
which is the difference between resume and restart, and the bug that was on the lock
screen.

Two of those found real defects the moment they were written. `advance()` drove
`tick()` straight past the pause check, so pause was a property of the timer rather
than of the director; and the check for "thumbs-down always changes something" caught
that the voicing gesture sometimes swells in one extra tone instead of rebuilding the
stack — audible, but invisible to a comparison that only looked at the four named
qualities, which would have reported a working button as broken.

`Tools/axis/` measures `AVAudioEnvironmentNode`'s sign conventions by asking which
ear a single source lands in. Do not derive these by hand: positive listener yaw
turns the listener *clockwise*, the opposite handedness from CoreMotion, and
getting it wrong makes head tracking swing the wrong way while still looking
correct in the readout.

### Head tracking is a rotation, not three numbers

For several versions Thrum smoothed and rate-limited `CMAttitude`'s `yaw`, `pitch`
and `roll` as three independent signals. They are not independent. CMAttitude
reports Tait-Bryan angles in Z-X-Y order, so **pitch is the middle axis**, and as
pitch approaches ±90° yaw and roll stop being separable — the same physical
rotation can be written with wildly different pairs of them.

ThrumFlow's flight recorder caught the consequence on a hike: yaw and roll taking
equal-magnitude steps of up to **168° in a single 20 ms sample**, agreeing with
each other to within 0.02%, while pitch moved at an ordinary 240°/s. On the very
same lines `overruns` was 0 and the motion stream was a perfect 50 Hz, so neither
the render path nor Bluetooth was involved. The rotation was smooth the whole
time; only its decomposition was degenerate.

The reason it was *audible* is the guard that was supposed to prevent exactly this
kind of thing. `maxDegreesPerSecond` caught the 168° phantom step and paid it out
at 400°/s, so instead of one click the entire sixteen-bus field swept 168° over
nearly half a second and swept back — heard as a warble, worst in the high end
where elevation is carried by pinna notches at 5–10 kHz. A limiter doing its job
on a lie is indistinguishable from a DSP bug.

The transport now carries a quaternion: `CMAttitude.quaternion` in, `simd_slerp`
for the one-pole, geodesic rate for the limit, and `listenerVectorOrientation`
out, so no Euler angle is formed anywhere between the sensor and the node. Three
things worth not re-deriving:

- **The handedness fix is a pure change of frame.** The long-standing
  `(-yaw, -pitch, -roll)` is exactly a 180° rotation about (0, 1, 1)/√2, which
  sends CoreMotion's (right, forward, up) onto the node's (−x, z, y). It is now one
  conjugation in `HeadSmoother.toListener` rather than a negation in each host.
- **Ask the node rather than the documentation.** Setting
  `listenerAngularOrientation` and reading `listenerVectorOrientation` back makes
  `AVAudioEnvironmentNode` state its own mapping: `Ry(−yaw)·Rx(pitch)·Rz(−roll)`.
  That is how the frame change above was derived, how the equivalence was proved to
  Float32 epsilon across 400 random combined rotations — which is what makes this
  safe to ship into an app whose spatial image was tuned by ear — and how
  CMAttitude's Euler order was identified as Z-X-Y (the only one of six that
  matched).
- **The rate in the flight log is one number now, not three.** Per-axis rates were
  a property of the chart, not of the head, which is why they read 8352°/s during
  an ordinary walk. `clamped` staying at zero through a session that used to warble
  is the check that the fix took.

`Tools/spatial` drives the whole trajectory offline, and — following the lesson
below — first asserts that the test trajectory *does* contain the bug: the head
turns 60° in total while its Euler angles jump 180° in one sample. A version of
this check that measured Euler angles rather than the vectors the node is driven
with would have called the artifact a real movement, and the fix a regression.

Two lessons from this suite that cost real time:

- **A test can pass for the wrong reason.** The first crackle detector scored a
  known-bad limiter and a good one identically, because the material's own second
  difference was ~0.5 of peak and swamped what it was looking for — and because it
  measured the first sample of each window against zeroed history. Always A/B a
  detector against the bug it claims to catch.
- **Measure before optimising.** The spatial graph was originally built lazily to
  avoid sixteen idle HRTFs, which turned out to cost 0.2% of a core — while the
  lazy build attached seventeen nodes to a *running* engine on every first toggle,
  which is exactly the kind of live reconfiguration that glitches the render
  thread. It is built up front now.

`Tools/icon/` draws the app icon. `Tools/click/` posts real CGEvent clicks —
System Events' `click at` routes through accessibility and never reaches
SwiftUI gestures. `Tools/midilist/` and `Tools/midimon/` check what CoreMIDI
sees and decode incoming pad presses against the grid geometry.
`Tools/pdfpng/` and `Tools/pdftext/` rasterize and outline a PDF, which is how
the manual's page breaks get checked.

---

## The manual

`instructions.pdf` — 22 pages covering every control in the app and every key on
the Launchpad, plus the pulse, the spatial field, all fifteen voicings, the jawari
explained in detail and a troubleshooting page. Rebuild it after changing any control:

```sh
./Tools/manual/build-manual.sh      # renders Tools/manual/manual.html via headless Chrome
```

There are two Launchpad diagrams — the normal layer and the BANK-held arp page —
and each is a CSS grid of **ten** tracks: row label, eight pads, right-hand
column. Every row has to supply exactly ten children or the whole figure
staircases diagonally.

Check the page count after editing. Chrome silently spills an over-long
`.page` onto a second sheet rather than complaining, and the only symptom is a
page with no header on it: `Tools/pdfpng/` plus a glance is the check.

---

## Layout

```
Shared/   Tuning       temperaments and pitch-class tables
          Harmony      key, mode, register → 32 grid pitches
          Timbre       the eight spectrum recipes
          Events       lock-free event queue, biquads
          DroneEngine  voices, partials, modulation, master chain
          Cathedral    the FDN reverb
          Pulse        tempo, tap tempo, the four arpeggiator lanes
          Spatial      the ring geometry, and AirPods head tracking
          AudioRoute   what the output actually is; the only per-platform file
          Flow         the director that plays the instrument itself
          Taste        what the thumbs have taught, and how Flow leans on it
          ThrumModel   instrument state; the only writer to the engine
App/      ThrumApp     AVAudioEngine host                        (macOS)
          ThrumView    the interface
          MIDISurface  shared CoreMIDI plumbing
          LaunchpadController
          LaunchControlController
iOS/      ThrumFlowApp the scene, and FlowHost.shared            (iOS/iPadOS)
          FlowHost     AVAudioSession host, Now Playing, the thumbs' entry point
          FlowView     start, stop, two thumbs, and nothing else
          Visualizer   the Metal field
          Shaders      its fragment shader
          FieldArtwork the same field in Core Graphics, for the car
          CarPlay      the templates
```
