# kodo

> 鼓動: heartbeat. Kodō is also the taiko group known for playing in perfect unison.

Play your Mac's audio through several Bluetooth speakers and the Mac's own
speakers at the same time, with no echo between them.

**Status: first working version.** A menu bar app for macOS 15+, untested on
more than one Bluetooth speaker so far.

## The problem

macOS can already send audio to more than one output (Audio MIDI Setup →
Multi-Output Device), but every Bluetooth speaker adds its own delay, usually
somewhere between 100 and 300 ms depending on the device and codec. Played
together, they echo against each other and against the built-in speakers.

## The idea

Measure each speaker's delay, then hold back the faster ones so everything
arrives at your ears together.

1. **Capture** the system audio (a Core Audio process tap, macOS 14.2+).
2. **Calibrate**: play a short chirp through one output at a time, record it
   with the Mac's mic, and cross-correlate the recording against the chirp to
   find when it actually arrived.
3. **Align**: give every output a delay buffer so it matches the slowest one.
4. **Stay aligned**: correct for clock drift between devices over long
   sessions, and re-calibrate when a speaker reconnects or gets moved.

## Using it

```bash
./scripts/build-app.sh            # builds build/Kodo.app
./scripts/build-app.sh --install  # also copies it to /Applications
open build/Kodo.app
```

1. Click the Kodo icon in the menu bar and tick the speakers to play through.
2. Turn Kodo on. macOS asks once for permission to record system audio.
3. Put the Mac where you usually listen and press **Calibrate**. Each speaker
   plays three short chirps; macOS asks once for the microphone.
4. Press **Test** to hear eight clicks through every speaker at once. Crisp
   single clicks mean they're aligned; a double tap means one is off. Nudge it
   in 2 ms steps with − / + and test again.
5. Click a speaker's volume icon to mute it, for example to hear one speaker
   on its own.

Turning Kodo off (or quitting it) hands audio straight back to macOS.

Diagnostics that don't need the menu:

```bash
build/Kodo.app/Contents/MacOS/Kodo --list-devices  # what Kodo can see
build/Kodo.app/Contents/MacOS/Kodo --smoke-test    # run the engine for 3 s, no chirps
```

## How it works

- **Capture.** A global, muted Core Audio process tap (`SystemAudioTap`) takes
  everything the Mac plays except Kodo itself, so nothing reaches the speakers
  directly.
- **One clock.** The tap and every chosen output join a private aggregate
  device (`UnisonEngine`). Core Audio's drift compensation resamples each output
  against the clock device (the built-in speakers when they're in the mix), so
  outputs that start aligned stay aligned. Members are switched to a sample rate
  they share and put back on teardown.
- **Delay.** One render callback writes the tap into a 4-second history
  (`DelayLine`) and each output reads it at its own delay and volume.
- **Calibrate.** The engine mutes the music, plays a 0.4 s log sweep (200 Hz to
  8 kHz) on one output at a time, and records the built-in mic in a separate
  callback (`MicrophoneRecorder`). Both sides stamp host time, so an FFT
  cross-correlation (`ArrivalDetector`) gives each output's latency. Three runs
  per output, interleaved, combined by median (`Calibrator`, `AlignmentPlan`).
- **Test.** A train of short 2.5 kHz clicks is fed into the delay line in place
  of the captured audio, so each speaker plays it through its own delay and
  volume, just like music.
- **Reconnects.** Settings are keyed by device UID. When a speaker drops out or
  comes back, the engine rebuilds and reuses the delay it measured last time.

`KodoCore` holds the signal processing and alignment math with no Core Audio
dependency; `swift test` covers it.

## Answers so far

- **One chirp or several?** Three per speaker, median. The spread shows in the
  delay tooltip, and turns orange past 3 ms.
- **Mic position?** It matters by about 3 ms per metre of path difference. Kodo
  measures at the Mac, and the nudge buttons cover the rest.
- **AirPlay?** Allowed: it listens 3 s longer when an AirPlay output is in the
  mix, and the 4 s history covers AirPlay's ~2 s buffer. Not tried yet.
- **UI?** A small menu: speakers, on/off, Calibrate, Test, volume, mute and nudge.

## Open questions

- Can it re-calibrate quietly while music plays, without an audible chirp?
- Should it re-measure on its own when a speaker reconnects, rather than trust
  the old number?
- Bluetooth headphones with a mic (AirPods) switch to the low-quality headset
  profile if their mic is opened. Kodo never picks a Bluetooth mic when another
  exists, but this is untested.
