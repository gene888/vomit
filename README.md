# StageCue 0.1 — Audio-first macOS soundboard

A native SwiftUI/AVAudioEngine source project for personal live shows and gaming sessions.

## Requirements and opening

- macOS 14 or newer; Xcode 15 or newer.
- Open `Package.swift` in Xcode, select the `StageCue` executable scheme, and Run on My Mac.
- Alternatively, in Xcode create a macOS app project and add the three files under `Sources/StageCue` if your Xcode version does not generate a Run scheme for executable packages.
- This artifact was authored in a Linux environment and **has not been compiled or hardware-tested on macOS**.

## Basic workflow

1. Select an empty pad and click **Create Cue**.
2. Browse for an audio file. Set gain in dB, bus, loop, optional fade-in and stop fade-out, and fade curve.
3. Click its large pad to trigger it; mini-buttons under the pad do manual Fade In, Fade to Silence, Fade Out & Stop, or immediate Stop.
4. Use **Preflight** to find missing assets and verify the audio engine is running.
5. Autosave is stored at `~/Library/Application Support/StageCue/autosave.json`. Export saves portable JSON **references** to your media, not copied media files.
6. Cmd+. immediately stops all; Cmd+Shift+F fades everything and stops. Number keys 1–9 trigger the first nine cues; avoid typing into text fields while using those.

## Implemented in source

- 32 pads; six logical bus faders plus master; concurrent cue voices; saved project; per-cue gain; looping; toggle and one-shot playback; manually initiated fade in, fade to silence, fade out & stop; automatic fade-in; optional faded stop from inspector; fade curves; basic preflight.
- Playback uses in-memory decoded PCM buffers for short or moderate clips; choose files within available memory.

## Known limitations / next verification steps

- **No video output in v0.1**. Video architecture is planned for v0.2.
- There is **no dedicated output-device selector** yet; sound uses the macOS system default audio device. Route this to your interface in System Settings.
- Hold-to-play isn't wired to pointer/key release yet; selecting Hold currently behaves as single-start until stopped.
- Auto fade-out at natural end-of-file is not implemented; configured fade-out is used by the inspector's fade-stop command. Pad's square button uses the global manual fade time.
- No pause transport, metering, media packaging, disk-streaming of very long clips, or guaranteed sample-accurate crossfades yet.
- Fade envelopes are applied by a 60 Hz UI timer and are not sample accurate; benchmark with actual interface and stress-test concurrent playbacks.
- Streamed content can be huge in PCM. For very long ambiences, implement disk-backed streaming rather than decoding whole file into RAM.
- File references are absolute paths, so moving source audio causes preflight failures.
- The audio engine needs macOS compile verification and end-to-end live hardware testing before actual show use.
- A reliable 0.1 release should add automated compilation checks, audition tests and handling for audio-route changes, engine interruptions and loading errors.

## Future work

0.2: AVPlayer-based local video cues, private preview, and dedicated clean HDMI/projector window; ensure audio clips are not interrupted by video output changes.
