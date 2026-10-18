<p align="center">
  <img src="assets/logo.png" alt="Kodo logo: a smiling taiko drum with crossed drumsticks" width="160">
</p>

<h1 align="center">Kodo</h1>

<p align="center">
  Play your Mac's audio through several speakers at once, in perfect sync.
</p>

<p align="center">
  <a href="https://github.com/felitrejos/kodo/actions/workflows/ci.yml"><img src="https://github.com/felitrejos/kodo/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black" alt="macOS 15+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

> 鼓動 (kodō): heartbeat. Kodō is also the taiko group known for playing in perfect unison.

macOS can play to several outputs at once, but every Bluetooth speaker adds its
own delay, so together they echo. Kodo measures each speaker's delay with a
short chirp and holds back the faster ones, so everything arrives at once.

## Usage

```bash
./scripts/build-app.sh --install   # builds Kodo.app and copies it to /Applications
```

1. Click the Kodo icon in the menu bar and tick the speakers to play through.
2. Turn Kodo on, then press **Calibrate** with the Mac where you usually listen.
3. Fine-tune a speaker by ear with − / +, or mute it from its volume icon.

macOS asks once for system audio recording and once for the microphone.
Turning Kodo off hands audio straight back to macOS.

## How it works

- A muted Core Audio process tap captures everything the Mac plays.
- The tap and the chosen speakers join one private aggregate device, so they
  share a clock and stay aligned over long sessions.
- Each speaker reads the captured audio from a shared buffer at its own delay.
- Calibration plays a sweep through one speaker at a time and times its arrival
  at the built-in mic with an FFT cross-correlation.

## Development

Requires Xcode 26 or later. Runs on macOS 15 or later.

```bash
swift test                     # signal processing and alignment math
scripts/make-icon.py           # rebuild the app icon from assets/logo.png (needs Pillow)
```
