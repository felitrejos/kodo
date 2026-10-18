<p align="center">
  <img src="assets/logo.png" alt="Kodo logo: a smiling taiko drum with crossed drumsticks" width="160">
</p>

<h1 align="center">Kodo</h1>

<p align="center">
  Play your Mac's audio through several speakers at once, in perfect sync.
</p>

<p align="center">
  <a href="https://github.com/felitrejos/kodo/actions/workflows/ci.yml"><img src="https://github.com/felitrejos/kodo/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

> 鼓動 (kodō): heartbeat. Kodō is also the taiko group known for playing in perfect unison.

macOS can play to several outputs at once, but every Bluetooth speaker adds its
own delay, so together they echo. Kodo measures each speaker's delay with a
short chirp and holds back the faster ones, so everything arrives at once.

## Install

Download `Kodo-<version>.dmg` from
[Releases](https://github.com/felitrejos/kodo/releases/latest) and drag Kodo
into Applications.

Kodo isn't notarized, so macOS blocks the first launch. Open it once, then go to
System Settings → Privacy & Security and click **Open Anyway**.

To build it yourself instead, run `./scripts/build-app.sh --install`.

## Usage

- **Apps:** every app playing sound gets a volume slider. Click the speaker
  inside a slider to mute that app. This works with or without Speaker Sync.
- **Speakers:** with Speaker Sync off, click a speaker to play through it, like
  Control Center. Turn Sync on, click the speakers you want in the group, then
  press **Calibrate** with the Mac where you usually listen.
- **Details:** hover over a speaker and click ⓘ for its connection, sample
  rate, format, and delay, or to hide it from Kodo.

macOS asks once for system audio recording and once for the microphone.

## How it works

- A muted Core Audio process tap captures everything the Mac plays. An app you
  adjust gets a tap of its own, swapped in live without interrupting playback.
- The tap and the chosen speakers join one private aggregate device, so they
  share a clock and stay aligned over long sessions.
- Each speaker reads the captured audio from a shared buffer at its own delay.
- Calibration plays a sweep through one speaker at a time and times its arrival
  at the built-in mic with an FFT cross-correlation.

## Development

Requires Xcode 26 or later. Runs on macOS 26 or later.

```bash
swift test             # signal processing and alignment math
./scripts/release.sh   # build/Kodo-<version>.dmg
```

Work happens on `dev`. To release, bump `CFBundleShortVersionString` in
`Resources/Info.plist` and open a pull request from `dev` to `main`. Once the
tests pass and it's merged, CI builds the `.dmg` and publishes it as a GitHub
release.
