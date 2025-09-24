⸻

Mac Dial Midi

macOS support for the Surface Dial.
While macOS can pair with the Surface Dial, all input is misinterpreted as invalid mouse events.
Mac Dial reads the raw HID reports directly and translates them into smooth scrolling, media keys, and MIDI signals for creative apps like Traktor.

⸻

🙏 Shout Out

Big thanks to @andreasjhkarlsson for the original Mac Dial program.
This project builds on that foundation with additional modes (smooth scrolling, improved playback, MIDI).

⸻

✨ Features
**Scroll Mode**
Turn the dial to scroll smoothly (trackpad-like pixel scrolling with acceleration).
Press the dial to send a mouse click at the cursor.
	
**Playback Mode**
Turn the dial to adjust macOS system volume (fine detents, smoothing, acceleration).
single click → Play/Pause.
Double click → Next track.
	
**MIDI Mode**
Each dial can appear as a CoreMIDI virtual device.
Sends CC messages (configurable as relative or absolute) for mapping in Traktor or any DAW.

⸻

🔧 Building
	1.	Clone the repo with submodules:

git clone --recursive https://github.com/andreasjhkarlsson/mac-dial


	2.	Build the hidapi static library:

cd mac-dial/lib/hidapi
mkdir build && cd build
cmake ..
make

This produces libhidapi.a, which must be linked in Xcode.

	3.	Open the Xcode project and build.
	•	Remove any .dylib references and link libhidapi.a instead.
	•	Add lib/hidapi to your Header Search Paths.

Universal builds may be found under Releases, but they can lag behind the latest source.

⸻

▶️ Usage
	1.	Pair the Surface Dial as a standard Bluetooth device in macOS.
	2.	Launch Mac Dial. It will automatically detect connected dials.
	3.	Use the menu bar icon to switch modes:
	•	Scroll Mode → Smooth trackpad-like scrolling.
	•	Playback Mode → Volume & media key control.
	•	MIDI Mode → Virtual MIDI knobs for music software.

For auto-start on login, add Mac Dial manually to your Login Items in System Preferences.

⸻

🚀 Roadmap
	•	Hot-swap between modes directly on the dial (without menu bar).
	•	Advanced MIDI configuration (per-dial CC mapping).
	•	More creative control modes (zoom, brush size, scrubbing).
	•	Smarter device discovery (✅ now improved).

⸻

👥 Contributors
	•	@andreasjhkarlsson — Original creator of Mac Dial.
	•	@codychunyu — Enhancements: smooth scrolling, refined playback, MIDI output, dual-dial support, and performance improvements.

