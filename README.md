# kodo

> 鼓動: heartbeat. Kodō is also the taiko group known for playing in perfect unison.

Play your Mac's audio through several Bluetooth speakers and the Mac's own
speakers at the same time, with no echo between them.

**Status: backlog idea.** No code yet.

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

## Open questions

- Is one chirp per speaker enough, or does it need a few runs averaged?
- Does the mic's position matter, compared with where you're sitting?
- Can it re-calibrate quietly while music plays, without an audible chirp?
- AirPods and AirPlay targets: in scope or not?
- Does it need a UI at all, or is one "calibrate" action enough?
