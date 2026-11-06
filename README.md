# ELC Responsive

A native macOS app that turns music into a lighting show automatically and sends it as **sACN (E1.31)** to a **dmXLAN NodeGBx8**, which outputs it on a physical DMX port.

The music can come from:

- **Live input**: any audio input on the Mac, such as a feed from the DJ mixer or the FOH desk.
- **Setlist**: `.wav`, `.mp3`, `.aiff` or `.m4a` files played from inside the app. Each track is analysed in advance, so the show can see build-ups and drops coming.
- **Mood shows**: six self-running looping shows, ranging from very slow to fast. They need no audio.

## The rig

| # | Fixture | Mode | DMX address |
|---|---------|------|-------------|
| 1–6 | ADJ Focus Flex L7 (numbered left → right) | **16 ch "Basic"** | 1, 17, 33, 49, 65, 81 |
| 7–12 | ADJ Focus Hybrid 1–6 (V shape) | **19 ch** | 97, 116, 135, 154, 173, 192 |

Hybrid numbering follows the plot. 1/2 is the upstage pair, 3/4 is the middle pair and 5/6 is the downstage pair. Odd numbers are on the left.

The channel maps come from ADJ's official "DMX Traits" sheets for both fixtures.

**LED wall safety:** every pan/tilt position passes through a geometry clamp. A beam can never lean towards the LED wall further than the per-fixture "Max lean towards LED wall" setting. The default is 0° for the L7s and 5° for the Hybrids. The tilt towards the audience is limited too. The unit tests check this for every mood show.

## How the automatic show works

1. **Analysis**
   - Live input is analysed in real time: FFT, onset detection, tempo by autocorrelation, and a beat phase-locked loop. The app also tracks kick, snare and hi-hat hits, loudness relative to the recent past ("energy"), bar/downbeat estimation and section detection (ambient, groove, breakdown, build-up, drop, peak).
   - Setlist files get a full offline analysis: a beat grid (dynamic-programming beat tracker), downbeats, and sections. Drops and build-ups are known before they happen.
2. **Director:** energy and section choose a tier: Calm, Groove, High or Peak. Every few bars, aligned to the phrase, it changes one or two parts of the look: colour pattern, intensity chase, movement, Hybrid beam (gobo, prism or frost), and the palette. The show keeps evolving without jumping around.
3. **Special moments**
   - **Build-up:** chases speed up, beams rise and narrow, and colours move to the accent colour. Strobe joins in at the very end.
   - **Pre-drop gap:** a short blackout. Setlist mode only.
   - **Drop:** a full-rig impact flash, then straight into a peak look.
   - **Breakdown:** slow and wide, with frost on the Hybrids.
   - **Silence:** fades to an ambient brand-colour glow, or to blackout.
4. **Colours:** green and magenta/purple brand palettes by default. Under "Mostly brand", other palettes (ocean, sunset, fire, ice, toxic) are mixed in about 25% of the time. Hybrid colours map to the nearest colour-wheel slot.
5. **Strobe** is only used on build-ups, drops and short peak hits. It can be turned off completely, and it never runs longer than 4 seconds at a time.

## Mood shows (slow → fast)

| Show | BPM | Character |
|------|-----|-----------|
| Breathe | 60 | Very slow brand-colour fades, static beams up, frost |
| Aurora | 72 | Rolling waves of green / purple / blue, slow gobos |
| Lounge | 90 | Warm and magenta, slow gobo sweeps |
| Brand Pulse | 110 | Green/magenta chases, prisms, circles |
| Club | 124 | Driving looks, circles, prisms, narrow beams |
| Party Peak | 138 | Fast chases, ballyhoos, short strobe hits (if strobe is enabled) |

## Operator controls

- Master dimmer
- **Blackout** (⌘B)
- **Flash** and **Strobe**: hold the button
- **Next look** (⌘L) and **Hold look** (⇧⌘H)
- Tap tempo (⌘T), ½× / 2× tempo correction, "Set '1'" to align the bar, and beat nudge
- Play/pause (⌘↩) and next/previous track (⌘→ / ⌘←)
- **DMX monitor** window

## Setup

1. Set the fixtures to the right modes. The Flex L7s should be in **16-channel (Basic)** mode and the Focus Hybrids in **19-channel** mode, with the addresses listed above.
2. On the **NodeGBx8**, set the DMX port you use to **sACN input** with universe 1, or another universe you choose.
3. In the app, open **Settings → sACN Output**:
   - Enter the node's IP address. Unicast is the default.
   - Optionally, enter the Mac's local IP on the lighting network.
   - **Mirror universes** sends a copy of the rig universe to more universes or node ports.
4. Calibrate the fixtures in **Settings → Fixtures → Test selected fixture**:
   - "Straight up" must point the beam vertically.
   - "Forward 45°" must lean towards the audience.
   - If they don't, adjust *Pan home*, *Tilt for beam straight up* and the invert switches. This depends on how each fixture is mounted.
5. If flashes land after the kick, increase the latency compensation in **Settings → Audio Analysis**.

## Building

You need macOS 13 or later and Xcode 15 or later (or the matching command line tools).

```bash
./scripts/build_app.sh
```

```bash
open "build/ELC Responsive.app"
```

You can also open `Package.swift` in Xcode and run the `ELCResponsive` scheme.

The self-hosted runner workflow (`.github/workflows/build.yml`) runs the tests, builds the app on every push, and uploads `ELC-Responsive.zip` as a build artifact.

The first time the app starts, macOS asks for **microphone** access (for live input) and **local network** access (to send sACN). Allow both. The app is ad-hoc signed. If Gatekeeper complains about a downloaded build, right-click the app and choose **Open**.

## Project layout

```
Sources/ELCCore/         platform independent, unit tested
  DMX/                   sACN packet builder + UDP sender, 44 Hz output loop
  Fixtures/              patch, calibration, wall-safe geometry, L7/Hybrid encoders
  Analysis/              FFT, feature extraction, tempo/beat tracking, live + offline analysis
  Show/                  colours/palettes, patterns, show engine, mood shows
Sources/ELCResponsive/   SwiftUI macOS app (AVFoundation audio, CoreAudio devices)
Tests/ELCCoreTests/      sACN layout, channel maps, wall safety, tempo/drop detection, engine
```
