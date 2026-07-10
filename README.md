# Mac Dial

macOS support for the Microsoft Surface Dial — including more than one at a time. Paired dials produce invalid mouse input on macOS; this app seizes the HID device and translates rotation and presses into smooth scrolling, media controls, app switching, or MIDI.

## Features

* **Multiple dials** — every connected Surface Dial is handled independently, each with its own mode.
* **Premium scrolling** — velocity-based acceleration with sub-pixel smoothing, delivered as a trackpad-style gesture stream (continuous pixel events with scroll phases). Slow turns are 1:1 precise; fast spins accelerate along a tunable curve.
* **App-switcher knob** — in scroll mode, press to summon the ⌘Tab switcher, turn to dial through apps (one haptic click per app), release to switch. A quick press toggles to the previous app.
* **Playback remote** — instant play/pause, hold to peek the menu bar Now Playing panel, hold-and-turn to skip tracks (one haptic click per song), rotate for velocity-accelerated volume.
* **Haptics = feel switch** — haptics on gives real detent clicks (choose the density in the menu); haptics off is a fine 360-step free spin. Scroll speed is identical either way. Gestures that step through items (songs, apps) always click while held, regardless of the toggle.
* **MIDI mode** — each dial appears as its own virtual CoreMIDI source. Rotation sends a relative CC (two's complement, CC 16+n), press sends note 60+n. Slots are stable per dial across reconnects.
* **Per-app profiles** — override the mode per frontmost app (e.g. scroll everywhere, MIDI when your DAW is in front).
* **Scroll Test window** — live velocity/jitter measurement plus sliders to tune the acceleration curve while you turn the dial.
* **Launch at Login** toggle in the menu.

## Gestures

| Mode | Turn | Press | Hold | Hold + turn |
|------|------|-------|------|-------------|
| Scroll | Accelerated scrolling | App switcher (quick press = previous app) | App switcher stays up | Dial through apps, release to switch |
| Playback | Volume (accelerated) | Play / pause (instant) | Peek Now Playing (closes on release) | Skip tracks, one click per song |
| MIDI | Relative CC 16+n | Note 60+n | — | — |

## Building

Plain Xcode project, no dependencies — open `MacDial.xcodeproj` and build (macOS 14+). The HID layer uses IOHIDManager directly; the old hidapi submodule is gone.

Run the scroll-math self-check with:

```sh
swiftc -o /tmp/scrollmath Tests/test_scroll_math.swift MacDial/ScrollMath.swift && /tmp/scrollmath
```

## Permissions

Posting scroll/key/media events requires **Accessibility** access (System Settings → Privacy & Security → Accessibility). The app prompts on first launch. Reading the dials and MIDI mode need no permissions.

## Usage

Pair the dial like any Bluetooth device. Click the Mac Dial menu bar icon to set each dial's mode (Scroll / Playback / MIDI), click density, scroll direction, per-app profiles, and to open the Scroll Test tuning window.
