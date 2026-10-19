# Contributing to Kodo

Thanks for helping out. This page covers building Kodo, how it works under the
hood, and how changes get released.

## Building

You need macOS 26 and Xcode 26 or later.

```bash
./scripts/build-app.sh            # builds build/Kodo.app
./scripts/build-app.sh --install  # also copies it to /Applications
swift test                        # runs the KodoCore tests
```

The app is ad-hoc signed, and macOS ties the system audio and microphone
permissions to the signature, so expect to grant them again after each rebuild.
Only one copy of Kodo runs at a time; quit the installed one before opening a
fresh build.

To work on the menu, open `Package.swift` in Xcode. `MenuContent` has SwiftUI
previews driven by the sample data in `Sources/Kodo/Preview/PreviewData.swift`.

Two flags help when something looks off, without touching any audio:

```bash
build/Kodo.app/Contents/MacOS/Kodo --list-devices  # outputs and inputs Kodo sees
build/Kodo.app/Contents/MacOS/Kodo --list-apps     # apps with audio, and which are playing
```

## Project layout

| Path | What's there |
|---|---|
| `Sources/KodoCore` | Signal processing with no Core Audio: the chirp, the cross-correlation that finds it, the delay line, and the alignment math. Unit tested. |
| `Sources/Kodo/Audio` | Core Audio: devices, process taps, the aggregate engine, and its real-time renderer. |
| `Sources/Kodo/Apps` | Finding which apps play audio, with helper processes grouped under their app. |
| `Sources/Kodo/Views` | The menu, one view per file, with shared sizes and timings in `Design.swift`. |
| `Sources/Kodo/KodoModel.swift` | App state, and the logic that decides what the engine needs to run. |

## How it works

**Capturing audio.** Kodo uses Core Audio process taps. A muted tap captures
audio and stops it from reaching the speakers directly, so Kodo can replay it
however it likes. With Speaker Sync on there's one global tap for everything,
plus a tap for each app whose volume you changed; the global tap excludes those
apps so nothing is captured twice. With Sync off there's no global tap, only
the adjusted apps, and everything else plays normally. When nothing needs Kodo,
no engine runs at all.

**Changing taps live.** A tap's exclusions can't change while it's in use, so
`TapRouter` builds a new global tap and swaps the aggregate's whole tap list in
one step. The aggregate keeps running through the swap, so playback and the
delay buffers carry on.

**Keeping speakers in step.** All outputs and taps join one private aggregate
device, which puts them on a single clock. Drift compensation resamples every
member except the clock device, so they stay aligned over long sessions. The
aggregate also pads faster members to match the slowest one's reported
latency, which gets speakers roughly in step before any measuring.

**Fine-tuning.** Reported latencies are approximate; the aggregate ignores the
built-in speakers' stream latency, for one. Fine-tuning plays a 0.4 s
logarithmic sweep through one speaker at a time and records the microphone in
a separate callback. Both sides are stamped with host time, so an FFT
cross-correlation gives each speaker's arrival time. Three runs per speaker,
combined by median, become a per-speaker delay in the shared delay line.

## Conventions

- Nothing on the audio thread allocates, locks, or touches the main actor. Its
  state is allocated up front in `RenderState`.
- Core Audio dictionary flags are numbers, as the headers document. A Swift
  `Bool` bridges to a `CFBoolean`, which some keys silently ignore.
- One type per file, and SwiftUI uses only macOS 26 APIs, Liquid Glass included.

## Branches and releases

`main` holds the released version, which is what the repository page shows.
Work happens on `dev`, so branch from `dev` and open pull requests against it;
every push there runs the tests. `main` only takes pull requests from `dev`
whose tests pass.

To release, bump `CFBundleShortVersionString` (and `CFBundleVersion`) in
`Resources/Info.plist` on `dev`, then open a pull request to `main`:

```bash
gh pr create --base main --head dev --fill
```

When it merges, CI builds `Kodo-<version>.dmg` and publishes it as a GitHub
release. Merging without a version bump publishes nothing.
