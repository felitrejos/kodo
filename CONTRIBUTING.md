# Contributing to Kodo

Thanks for helping out. This page covers building Kodo, how it works under the
hood, and how changes get released.

## Building

You need macOS 26, Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) for the Control Center control.

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
| `Driver` | The audio driver behind Kodo's entry in the Sound output list, in C. |
| `Controls` | The Speaker Sync control for Control Center, an app extension. `project.yml` describes it for XcodeGen. |

## How it works

**Capturing audio.** Kodo uses Core Audio process taps. A muted tap captures
audio and stops it from reaching the speakers directly, so Kodo can replay it
however it likes. With Speaker Sync on there's one global tap for everything,
plus a tap for each app whose volume you changed; the global tap excludes those
apps so nothing is captured twice. With Sync off there's no global tap, only
the adjusted apps, and everything else plays normally. When nothing needs Kodo,
no engine runs at all.

**Engines.** Kodo runs an engine only when something needs one: one for Speaker
Sync or for adjusted apps on the Mac's output, plus one per speaker that an app
is sent to. Each engine has its own aggregate and taps, and the Sync engine's
global tap leaves out every app another engine captures.

**Changing taps live.** A tap's exclusions can't change while it's in use, so
`TapRouter` builds a new global tap and swaps the aggregate's whole tap list in
one step. The aggregate keeps running through the swap, so playback and the
delay buffers carry on.

**Keeping speakers in step.** All outputs and taps join one private aggregate
device, which puts them on a single clock. Drift compensation resamples every
member except the clock device, so they stay aligned over long sessions. The
clock is the group's lead speaker, which Kodo always picks: the wireless speaker with the
most delay, because a Bluetooth link is the part most likely to crackle when
its audio is resampled, while wired speakers take resampling in stride. Groups
with a wireless speaker also get a 1024-frame IO buffer for slack. Kodo watches
every device an engine plays through, and rebuilds the engine when one changes
its sample rate or channels mid-stream, as Bluetooth does when it renegotiates
its codec. The
aggregate also pads faster members to match the slowest one's reported
latency, which gets speakers roughly in step before any measuring.

**Volume.** Speaker sliders drive each device's own volume and mute. The volume
keys only change the Mac's output, so while Sync plays, Kodo watches that
device and applies the same change to the rest of the group, keeping each
speaker's share of the output's volume. Moving a speaker in Kodo sets a new
balance. A Bluetooth speaker reports a fast slider drag back late, up to 0.6 s
behind, so for 1.5 s after Kodo sets a speaker's volume its readings count as
echoes, not key presses.

**Kodo in the Sound list.** Only audio devices appear in Control Center's
Sound menu, so Kodo can install a small AudioServerPlugIn driver
(`Driver/KodoDriver.c`) into `/Library/Audio/Plug-Ins/HAL`. It adds a stereo
output called Kodo that plays nothing: it keeps time for the apps that play to
it, and carries a volume and a mute. Kodo's global tap captures those apps
anyway, so the device is a switch: picking Kodo turns Speaker Sync on, picking
any other output turns it off, and turning Sync on or off in Kodo moves the
Mac's output to match. Its volume and mute pass on to the group like the
volume keys do. Kodo sets the device's rate to the lead's, and hands the Mac
back to a real speaker when it quits so nothing is left silent. Installing
needs an administrator's password and restarts `coreaudiod`, after which Kodo
relaunches, since every device and tap it held is gone.

**The Control Center control.** `Controls` is a WidgetKit extension with one
`ControlWidgetToggle`. macOS only loads sandboxed extensions, so it can't
reach Kodo directly: Kodo writes whether Sync is on and the group's name to its
own preferences, which the extension may read through a read-only
shared-preference entitlement, and asks WidgetKit to reload the control. The
control switches Sync by opening `kodo://sync/on` or `kodo://sync/off`, which
also launches Kodo when it isn't running. Ad-hoc signing is enough for macOS to
list it under Edit Controls.

**Fine-tuning.** Reported latencies are approximate; the aggregate ignores the
built-in speakers' stream latency, for one. Fine-tuning plays a 0.4 s
logarithmic sweep through one speaker at a time and records the microphone in
a separate callback. Both sides are stamped with host time, so an FFT
cross-correlation gives each speaker's arrival time. Five runs per speaker,
combined by median, become a per-speaker delay in the shared delay line.
Results belong to the group, since the aggregate pads each speaker differently
depending on its company, and to the lead they were measured with, since
resampling adds a little delay to every other speaker. A speaker's runs must
agree: five chirps, at least three within 3 ms.

**Keep in Sync.** Every ten minutes while a fine-tuned group plays, Kodo records
three seconds of the microphone and compares it with what it played, using
GCC-PHAT, which keeps only the phase of the cross spectrum so every speaker's
arrival becomes a sharp spike even in music. To tell the spikes apart, it moves
one speaker 5 ms later per listen and watches which spike follows. It corrects
only when the answer is unambiguous and under 30 ms. Delay changes crossfade
over one buffer, so the moves don't click.

## Conventions

- Nothing on the audio thread allocates, locks, or touches the main actor. Its
  state is allocated up front in `RenderState`.
- Core Audio dictionary flags are numbers, as the headers document. A Swift
  `Bool` bridges to a `CFBoolean`, which some keys silently ignore.
- One type per file, and SwiftUI uses only macOS 26 APIs, Liquid Glass included.
- Give `Binding(get:set:)` a closure, `set: { model.choose($0) }`, never a bare
  method like `set: model.choose`. Swift 6.3, which CI uses, crashes while
  building the conversion for a main-actor method passed that way.

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
