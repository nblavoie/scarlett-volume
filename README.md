<p align="center"><img src="assets/icon_1024.png" width="160" alt="Scarlett Volume icon"></p>

# Scarlett Volume

macOS utility for controlling the volume of an audio interface that has no
software volume (Focusrite Scarlett 2i2 4th Gen, etc.) — a free alternative to
SoundSource for this use case. Volume keys, **native** macOS HUD, Control
Center: everything shows "Scarlett Volume".

## How it works

macOS refuses to control the Scarlett's volume because the interface exposes no
USB gain control: the Mac sends it a raw signal at full volume.

Two pieces:

1. **`Scarlett Volume.driver`** — a custom build of
   [BlackHole](https://github.com/ExistentialAudio/BlackHole) (GPL-3.0),
   renamed "Scarlett Volume" and compiled from `driver/BlackHole.c` by
   `build.sh`. It's a virtual output device that exposes **native** volume and
   mute (−64 dB → 0 dB curve, applied to the stream by the driver). macOS sees
   it as a standard output: volume keys, system HUD, and Control Center work
   natively.
2. **`Scarlett Volume.app`** — the menu-bar app. It sets the virtual device as
   the default output, creates a private CoreAudio aggregate device (virtual +
   Scarlett, clocked on the Scarlett, with drift compensation) and copies the
   stream to the Scarlett in real time at unity gain (bit-perfect: the volume is
   already applied by the driver). It persists the volume across sessions and
   handles plug/unplug events and sample-rate changes.

The device name — hence what macOS displays everywhere — is "Scarlett Volume"
(UID `Scarlett Volume_UID`, defined in `build.sh`).

## Installation

The easiest way: download the **.pkg** from the
[latest release](https://github.com/nblavoie/scarlett-volume/releases) —
it installs the app and the driver, restarts the audio service, and launches
the app. (Not notarized: right-click → Open if macOS blocks it.)

From source:

```bash
./build.sh
cp -R "build/Scarlett Volume.app" /Applications/
open "/Applications/Scarlett Volume.app"
```

To build the .pkg installer yourself:

```bash
./package.sh 1.0.0   # → build/Scarlett-Volume-1.0.0.pkg
```

The driver is bundled inside the app. At launch, if it isn't installed (or if
only an old "BlackHole 2ch" is present), the app offers to install it: native
macOS password prompt, replacement of the old BlackHole if applicable,
automatic restart of `coreaudiod` (sound cuts out for a second or two), then
automatic start of the engine.

Required permission: **Microphone** — this is macOS's generic label for any
audio capture; it is used solely to read back the stream from the virtual
device (the system audio). No physical microphone is ever opened, nothing is
recorded. The orange capture dot stays visible while the engine is running:
that's normal.

The Accessibility permission is **no longer needed**: the volume keys are
handled natively by macOS. (The app keeps a fallback mode — event tap + custom
HUD — in case the detected virtual device has no native volume, e.g. an old
standard BlackHole.)

After a rebuild (`./build.sh`), the ad hoc signature changes: macOS may ask for
the microphone permission again.

## Usage

- **Volume +/− and mute keys**: native, with the usual system HUD.
- **Control Center / Settings → Sound**: active slider, device
  "Scarlett Volume".
- **Menu-bar icon**: slider (synced with the system), mute, restart the engine,
  open at login, quit.
- On quit, the app sets the system output back to the Scarlett.
- Scarlett unplugged → switches to the internal speakers, resumes automatically
  when it comes back.
- The Scarlett's physical knob still works (it acts downstream).

## Notes

- **Quit SoundSource**: the two would fight over the default output.
- If the app crashes or is force-quit, the output may stay on the virtual
  device (silence): relaunch the app or select the Scarlett in
  Settings → Sound.
- The old `BlackHole2ch.driver` installed by Homebrew is removed when the driver
  is installed; the `blackhole-2ch` brew entry may remain in `brew list` —
  `brew uninstall --cask blackhole-2ch` to clean it up (otherwise harmless).
- Volume at 100% = bit-perfect passthrough (unity gain in the driver and in the
  bridge).

## Files

- `main.swift` — the app (~800 lines)
- `driver/BlackHole.c` + `driver/Info.plist` — the virtual driver (BlackHole
  0.7.x source, GPL-3.0, © Existential Audio)
- `Info.plist` — LSUIElement (no Dock icon), microphone description
- `build.sh` — compiles driver + app, bundles the driver into the app
- `package.sh` + `installer/` — builds the .pkg installer (app + driver +
  postinstall that restarts coreaudiod and launches the app)
- `assets/make_icon.swift` — draws the icon in Core Graphics
  (`swift make_icon.swift` then `iconutil` to regenerate `AppIcon.icns`)

## Requirements

- macOS 13+ (developed and tested on macOS 26)
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc` and `clang`

## License

GPL-3.0 (see `LICENSE`). The virtual driver is a renamed build of
[BlackHole](https://github.com/ExistentialAudio/BlackHole)
© [Existential Audio Inc.](https://existential.audio), distributed under GPL-3.0 —
the driver's source code is included as is in `driver/`, only compilation
constants (name, UID, bundle ID) are customized via `build.sh`. The menu-bar app
(`main.swift`) is likewise under GPL-3.0.
