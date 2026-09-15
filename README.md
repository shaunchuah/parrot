# parrot

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

This is [shaunchuah/parrot](https://github.com/shaunchuah/parrot), a fork of [digimata/parrot](https://github.com/digimata/parrot). It adds a menu-bar input-device picker that records through AUHAL so the chosen microphone is honoured — `AVAudioEngine`'s input node always follows the macOS default, which Apple Continuity Microphone (iPhone / "CS Microphone") often steals.

## Microphone

Capture is pinned to a CoreAudio device, not the system default.

1. Click the parrot icon in the menu bar → **Input**.
2. Pick **Yeti Nano** (or **Blue Yeti**). A checkmark marks the pinned device.
3. Hold `fn` and dictate as usual. stderr (or `/tmp/parrot.err.log` under launchd) prints `● recording · Yeti Nano`.

On first launch, if a Yeti / Yeti Nano is plugged in, parrot pins it automatically. Continuity / CS Microphone / iPhone / iPad mics are hidden from the list and never auto-selected — including when "Same as System" would otherwise follow a Continuity default.

The choice is stored at `~/Library/Application Support/parrot/input-device.json` and survives relaunches. Delete that file to reset (Yeti will be auto-pinned again if present).

## Install from source (Apple Silicon)

This fork is meant to be built on a Mac. There is no Linux/macOS cross-compile of the ANE/CoreML stack.

```sh
git clone https://github.com/shaunchuah/parrot.git
cd parrot
swift build -c release --arch arm64
```

The binary lands at one of:

- `.build/arm64-apple-macosx/release/parrot`
- `.build/release/parrot`

Xcode works too: `open Package.swift` and build the `parrot` executable target.

### Replace `/usr/local/bin/parrot` and the LaunchAgent

Stop the running daemon before overwriting the binary — launchd keeps the old process in memory otherwise.

```sh
# stop a LaunchAgent install, if any
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.digimata.parrot.plist 2>/dev/null || true
pkill -x parrot 2>/dev/null || true

BIN=.build/arm64-apple-macosx/release/parrot
[ -x "$BIN" ] || BIN=.build/release/parrot

sudo mkdir -p /usr/local/bin
sudo cp "$BIN" /usr/local/bin/parrot
sudo chmod +x /usr/local/bin/parrot

parrot setup                       # skip if mic + accessibility are already granted
parrot install --launch-at-login   # rewrite + bootstrap the LaunchAgent
```

Confirm the new binary is the one running:

```sh
which parrot          # /usr/local/bin/parrot
parrot --help
tail -f /tmp/parrot.err.log
```

Replacing an unsigned binary at the same path sometimes drops the Accessibility grant. If `fn` stops working, run `parrot setup` again (or toggle the terminal / `parrot` in System Settings → Privacy & Security → Accessibility).

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML.

Upstream still ships a curl installer (`https://digimata.github.io/parrot/install.sh`) that does **not** include this picker.

## How to use

1. **Run it.** Either `parrot install --launch-at-login` (daemonized, runs forever, lives in the menu bar), or `parrot` in any terminal tab.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold the `fn` key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** when you release. Usually within 200-300ms.

That's it. There is no record button, no stop button, no "send" — `fn` is the whole interface. Pin the mic once from the menu bar as above.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to flip it back to plain `fn`.

## CLI

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time setup: permissions + model download
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --uninstall             # remove the LaunchAgent
parrot doctor                          # check permissions + fn key setting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --hotkey right-option           # change the push-to-talk key
parrot --no-overlay                    # disable the bottom-of-screen pill
```

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **AUHAL** (`kAudioUnitSubType_HALOutput`) — mic capture, pinned to a chosen device
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

See [Install from source](#install-from-source-apple-silicon). In short, on an Apple Silicon Mac:

```sh
swift build -c release --arch arm64
.build/arm64-apple-macosx/release/parrot --help
```
