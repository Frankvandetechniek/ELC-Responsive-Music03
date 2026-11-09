# ELC Responsive

A native macOS app that turns music into a lighting show automatically and sends it as **sACN (E1.31)** to a **dmXLAN NodeGBx8**, which outputs it on a physical DMX port.

The music can come from:

- **Live input**: any audio input on the Mac, such as a feed from the DJ mixer or the FOH desk.
- **Setlist**: `.wav`, `.mp3`, `.aiff` or `.m4a` files played from inside the app. Each track is analysed in advance, so the show can see build-ups and drops coming.
- **Mood shows**: six self-running looping shows, ranging from very slow to fast. They need no audio.

## The rig

| # | Fixture | Mode | DMX address |
|---|---------|------|-------------|
| 1–6 | ADJ Focus Flex L7 (numbered left → right) | **50 ch "Extended 7"** | 1, 51, 101, 151, 201, 251 |
| 7–12 | ADJ Focus Hybrid 1–6 (V shape) | **25 ch** | 301, 326, 351, 376, 401, 426 |

The app uses everything these modes add:
- **16-bit pan, tilt, dimmer and zoom** on both fixture types, for smooth slow moves and fades with no stepping.
- **7 individually controlled RGB+Lime pixels** in every L7. The six bars act as one 42-pixel line.

Settings saved with the old 16/19-channel patch move to the new addresses automatically on first launch. Each fixture keeps its calibration.

Hybrid numbering follows the plot. 1/2 is the upstage pair, 3/4 is the middle pair and 5/6 is the downstage pair. Odd numbers are on the left.

The channel maps come from ADJ's official "DMX Traits" sheets for both fixtures.

**LED wall safety:** every pan/tilt position passes through a geometry clamp. A beam can never lean towards the LED wall further than the per-fixture "Max lean towards LED wall" setting. The default is 0° for the L7s and 5° for the Hybrids. The tilt towards the audience is limited too. The unit tests check this for every mood show.

## How the automatic show works

The goal is a show that looks programmed by a lighting designer, not an audio visualiser.

1. **Analysis**
   - Live input is analysed in real time for tempo, beat phase, bar/downbeat, energy and sections (groove, breakdown, build-up, drop, peak).
   - Setlist files are analysed once in advance. That gives an exact beat grid and sections, so drops and build-ups are known before they happen.
2. **Vibe detection** works out the genre and mood of the music, entirely on the Mac with no internet:
   - **A neural genre/mood network:** a Swift port of **MusiCNN** by Pons & Serra (Music Technology Group, UPF; ISC license), trained on the Million Song Dataset.
     - It predicts 50 tags. Genres include pop, rock, Hip-Hop, rnb, House, dance, electronic, acoustic, folk, soul, indie pop and metal. Moods include happy, sad, Mellow, chill, party, catchy and beautiful.
     - The port was checked against the original TensorFlow model (`Tests/ELCCoreTests/MusiCNNTests.swift`).
     - Setlist tracks are tagged as a whole when they are analysed. Live input is tagged every 5 s, with about 30 s of smoothing.
   - **Apple's built-in neural sound classifier** (SoundAnalysis) for instruments and vocals.
   - **Rhythm and harmony descriptors:** key/mode, four-on-the-floor, backbeat, syncopation and tempo. These are only used to break ties, for example House vs EDM, Drum & Bass tempo, or Latin percussion.

   The result is one of 9 lighting styles plus a mood (arousal/valence). The top tags are shown in the Vibe panel, and you can force a style manually.
3. **Lighting personality per style.** Each style has its own phrase length, fade times, movement speed, accents (for example on the backbeat in rock and hip-hop, half-time movement in DnB and trap, a soft pulse in house) and strobe policy. Palettes follow the mood, with brand colours always favoured.
4. **Snare-driven chases.** The app learns where the snare or clap falls in the bar, on a 16th-note grid. In styles with a clear snare groove (pop, rock, hip-hop, EDM, DnB, Latin), the L7s often:
   - **chase one fixture per snare hit**,
   - **bump on the snare**, or
   - **alternate on the snare**.

   These patterns follow the learned groove on the beat clock, so they land exactly on the hit with no detection delay. The learned pattern is shown in the Music panel.
5. **Programmed like a lighting designer would.** These rules come from pro programming practice: Susan Rose (HARMAN), Matt Hemmele (TFWM), Brad Schiller (HARMAN) and PLSN.
   - **One look per song section.** Looks change only on musical boundaries: a new section (verse → chorus, build → drop, breakdown) or, on live input, a clear step in energy confirmed over two bar lines. They never change in the middle of a chorus. On very long sections without any boundary, a look develops on a 16-bar line after 64 bars, as a safety net.
   - **Repeated sections reuse their look.** Verse 2 looks like verse 1 and every chorus or drop gets the same look. The **last chorus/drop** gets the biggest version: bigger movement and accents ("don't peak too early").
   - **Dynamic contrast.** In low sections one fixture group carries the look and the other stays in the background ("darkness is free"). Choruses and drops use the full rig.
   - **Hits.** A one-beat hit marks the arrival of a big section, and a full impact marks a drop ("jump to a 10, don't land on it"). Live drops hit on the next beat.
   - **Drive.** How dynamic a song is lit, from ballad to festival EDM. It comes from the style plus the mood (arousal/valence) and how electronic the music is according to the neural tags. A high drive means faster and bigger movement, deeper beat pulses, stronger accents, tighter beams and punchier fades. EDM drops get beat pulses, colour swaps on the bar, flying beams and strobe stabs.
6. **L7 pixel effects.** Each look can add an effect *inside* the bars:
   - colour split or gradient per bar
   - a slow gradient drifting across the whole 42-pixel line
   - a soft wave rolling along the line
   - a band travelling from the centre of the rig outwards once per bar (high energy)
   - bars opening from their centre on every beat (EDM drops)

   Following the "effects continue the look" rule, only one layer moves at a time. A chase across the bars gets static pixels, and a moving pixel effect sits on steady bars. During build-ups the bars **charge up from their centre outwards** until the drop.
7. **Smooth output**
   - A phase-locked beat clock follows the music without jumping or stepping back.
   - Pan/tilt run through a critically damped spring with a speed limit.
   - Intensity is limited per style by attack and release times.
8. **Special moments, lit the way the style expects**
   - **EDM, house and DnB** get real drops: a riser build-up where the bars charge up, a short pre-drop blackout, a strobe burst and an impact flash.
   - **Pop, rock, hip-hop and Latin:** the big section is a *chorus*. It gets the chorus look and a one-beat hit as it arrives. There's no blackout, strobe or riser, and the build-up is only a gentle lift.
   - **Ballads and ambient** fade smoothly between sections with no hits.
   - When the music stops, the rig fades to an ambient brand-colour glow.
9. **Strobe** is only used on drops and the last beat before a known drop, plus short peak hits for EDM. It is never used for ballads or ambient music, can be switched off, and never runs longer than 4 seconds.

## Song structure (setlist)

Looks follow the song's real structure: intro, verse, chorus, bridge, build-up, drop, outro.
- **Boundaries** sit where the energy, bass or drum activity really changes, refined to the exact beat. Normal variation inside a verse doesn't create a new section, such as a drum fill or a vocal swell.
- **Build-ups** are only detected where the music actually rises into a clearly bigger section, never just because a verse comes before a chorus.
- **Ambient** means quiet *and* no beat. A quiet verse with drums is a verse, so every verse gets the same look.
- **Tempo:** if busy hi-hats make a slow song read at double tempo, a backbeat check corrects it. You can also right-click a track and choose **Tempo fix** (Half / Double / Automatic) to re-analyse it at the right tempo.

## Timing

Every timing-critical path is covered by regression tests that run on synthetic music:
- **Live input:** the beat clock is within ±5 ms of the kick, with 1–3 ms jitter, from 122 to 174 BPM. It uses comb-correlation phase tracking over the last ~6 s of onsets, with fine tempo refinement, and free-runs through drumless breakdowns.
- **Setlist tracks:** the beat grid is within ±2 ms of the kick. Section boundaries are refined to the exact beat where the energy and bass jump, and drops land on "the 1".
- **Live drops:** a dedicated detector recognises the kick and bass slamming back after a stretch without bass. It fires the drop on the beat it landed on, typically within 250 ms.

If the lights still trail the sound because of your audio interface, network or fixtures, increase *Settings → Audio Analysis → lights ahead by*.

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

- **Pause show** (⌘P): freezes the lights exactly where they are.
- **Static look** on/off (⌘D): fades to a calm default brand look (green/magenta, no movement) and back.
- Lighting style: Auto (detected) or forced
- Master dimmer
- **Blackout** (⌘B)
- **Flash** and **Strobe**: hold the button
- **Next look** (⌘L) and **Hold look** (⇧⌘H)
- Tap tempo (⌘T), ½× / 2× tempo correction, "Set '1'" to align the bar, and beat nudge
- Play/pause (⌘↩) and next/previous track (⌘→ / ⌘←)
- **DMX monitor** window

## Setup

1. Set the fixtures to the right modes. The Flex L7s should be in **50-channel (Extended 7)** mode and the Focus Hybrids in **25-channel** mode, with the addresses listed above.
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
