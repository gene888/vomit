# StageCue 0.1

Native, local macOS audio soundboard: SwiftUI, AVAudioEngine and Core Audio through Apple's audio engine. Apple Silicon only; macOS 14 or newer. No cloud services or third-party runtime dependencies. Video is outside version 0.1.

## Build and run

Use Xcode 26 or newer (Swift 6.2+). Validated with Xcode 26.6, build 17F113, on 9 October 2026. The deployment target remains macOS 14, but runtime compatibility with macOS 14 has not been tested on a separate machine.

Open `StageCue.xcodeproj`, select the shared `StageCue` scheme, choose My Mac and Run. It builds an actual macOS `.app`. The project uses an ad-hoc signing identity and does not require a paid developer account. App Sandbox is disabled so absolute media paths work; enabling sandboxing requires adding persistent security-scoped bookmarks first.

For reproducible command-line builds:

```sh
./Scripts/build.sh Debug
./Scripts/build.sh Release
```

The script selects `/Applications/Xcode.app/Contents/Developer` through `DEVELOPER_DIR`, builds for arm64, then ad-hoc signs and verifies the app. It does not change global `xcode-select` settings. Set `DEVELOPER_DIR` before invoking it to use another Xcode installation. Product: `work/DerivedData/Build/Products/Release/StageCue.app`.

`Package.swift` also builds the same sources, primarily to expose the core implementation to automated tests. There are no remote package dependencies. Swift 5 language mode with complete concurrency checking is used by the Xcode target; actor-isolated deinitializers require the Swift 6.2 compiler.

## Tests

In a normal macOS terminal:

```sh
./Scripts/test.sh
```

Tests use Apple's Swift Testing framework. They cover models, project files, real offline PCM rendering and one live-engine silent playback test. The suite does not emit audible test tones. It requires access to macOS audio component services, even for offline rendering. The shared Xcode application scheme has no Xcode test target; use the script to run the Swift package tests.

A restricted command runner may fail when creating an AVAudioMixerNode because it cannot reach macOS audio-component services. In that environment:

```sh
./Scripts/prepare-native-tests.sh
```

Open the generated `work/NativeValidation.app` in Finder to run the compiled suite with normal macOS application access. It requests no new permissions and performs no networking. Results: `work/native-tests.log`; exit status: `work/native-tests.exit` (zero is success). The window has Run Again for rerunning after rebuilding the test bundle. This runner is a developer tool, not part of the shipped app. Its preparation script also needs Python 3 to write the bundle plist.

## Performance workflow

- Drag one local audio file from Finder onto a pad to assign it. Empty pads create a cue named after the file. Assigned pads retain their name, gain, bus, looping and fade settings; their current playback stops only after the replacement validates. Drops never start playback. Invalid files, folders and multi-file drops leave the cue unchanged. Pads highlight while targeted. Browse remains available and uses the same validation.
- Select an empty pad and Create Cue. Browse for local audio, choose clip gain in dB and one of six buses, then configure One-shot or Toggle and optional looping/fades.
- Click the large pad or its configured Option shortcut to trigger. Option+1 through Option+9 are the defaults for the first nine pads. One-shot retriggers replace the prior voice for that pad. Toggle stops the active voice using its configured stop fade, or starts it if inactive. Toggling a loading cue cancels it. Different pads play concurrently.
- Edit selects a pad without playing it. Settings changes apply on the next trigger; bus/master faders apply live. Gains support −60 to +6 dB. −60 dB is attenuation, not an exact mute.
- Manual ▲ fades an active cue toward its configured level; ▼ fades to exact silence while playback continues; ■ fades then stops and releases the voice; ✕ stops immediately. Each cue has its own envelope. A new manual fade replaces its previous envelope continuously and takes ownership of the remaining playback, suppressing later automatic tail fades for that voice.
- Automatic fade-in begins at trigger. For a non-looping cue, auto fade-out begins near natural end. If the configured in/out durations together exceed the clip length, they are scaled proportionally to fit. Looping cues have an initial fade-in but no natural-end tail fade. Configured Stop uses fade-out settings for both looping and non-looping cues.
- FADE ALL cancels pending loads and independently fades every active voice to a stop. STOP ALL / Command+. cancel pending work and stop all active cues immediately. Command+Shift+F fades all to a stop. No stale decode/completion may restart a stopped cue.
- Preflight decodes each assigned asset in the background and checks media format, practical decoded size and engine status. It does not cache/preload media or prove your interface is audible. Run it again if the project changes during checking.
- Route/configuration changes stop cues and display a warning. Playback does not automatically resume. Check your output and explicitly retrigger. The engine attempts to restart on that next trigger; failures are visible.

## Persistence and media safety

Autosave is debounced and stored at `~/Library/Application Support/StageCue/autosave.json`. Project writes are serialized away from the UI thread and published atomically. Save explicitly updates autosave and the last opened/exported project file; ordinary edits update autosave only. Opening never rewrites an imported document. Export uses the native Save panel and its overwrite confirmation.

Malformed/future-version JSON is rejected. Older projects without the version field or optional settings are accepted; pad/bus counts and invalid settings are repaired, duplicate cue IDs replaced, and legacy unsupported Hold modes converted to One-shot. A corrupt autosave is not overwritten by ordinary edits or quitting; open a valid project or explicitly Save to resume normal saving. Errors are shown in the app. Shutdown makes a final synchronous autosave attempt because the process may exit before queued asynchronous work completes; an I/O failure during termination cannot be surfaced in a closed window.

Media references remain absolute paths. Projects save references, not copied audio. Moved/missing media is reported; use Browse to relink it. Only nonempty mono/stereo files decodable by AVAudioFile are supported. Each decoded clip is capped at 512 MiB; active voices plus reserved loads are capped at 1 GiB. This accounts for decoded PCM, not total process memory: the loader, preflight, framework nodes and temporary canceled work use additional memory. The loader serializes decoding. No buffers are cached; first-trigger decoding has latency. Long clips must be shortened or converted until streaming/preloading is implemented.

## Architecture

Codable value models feed ShowState (UI, project I/O) and a MainActor SoundEngine (graph and voice control). Media decode runs on a separate serial actor. Each active cue owns a player/mixer; six virtual stereo buses feed a master and the system default output. Zero-band AVAudioUnitEQ stages supply a fixed +6 dB gain while mixer attenuation stays within Apple's documented 0–1 range. Each source is converted by its mixer to a common 48 kHz stereo graph. All graph mutations remain on the UI actor; callbacks cross back using UUID/token identities, not mutable voice objects. Decode reservations and cancellation prevent queued work from publishing stale voices.

Fade envelopes use a common-mode 120 Hz control timer in live playback; offline tests drive the same envelope calculations using rendered sample time. Fades are control-rate, not sample accurate. The real output graph uses the system-selected output device; there is no device selector in the app.

See `Docs/VALIDATION.md` for evidence, hardware checks and remaining features. The local Git baseline preserves the original extraction. Development commits use an explicitly local tooling identity, not an inferred personal email. No commits have been pushed to GitHub.

Option-click any clip, bus or master gain slider to reset it to 0.0 dB. Normal dragging and keyboard adjustment remain available.

Click the project name to rename it. Return or leaving the field commits the name; Escape cancels. Empty names keep the previous title. The displayed name does not accept typing until clicked.

Selected pad shortcuts (also shown in the Performance menu):

- Option–Up Arrow: fade up to configured clip level.
- Option–Down Arrow: fade to silence, keeping playback running.
- Option–X: immediate stop.
- Option–Shift–X: fade out and stop.

Fades use the show manual fade duration. These commands affect only the selected pad (selected by clicking a pad, Edit, or its configured trigger shortcut); they never choose another playing pad or start an inactive cue. Commands are disabled for empty pads.

### Pad shortcuts and reordering

Click Edit beneath any pad. In Pad Settings, choose a Trigger shortcut: Option plus a letter or digit, or None. Keys used by other pads are omitted; X is reserved for stop. Each project saves its own assignments. Shortcuts are shown on the pads and in the Performance menu. All 32 pads can have distinct shortcuts. Configured Option shortcuts take priority over typing special characters in StageCue name fields; they are suspended while file dialogs/sheets are open. Held-key repeats are ignored.

To reorder, select a pad with Edit, choose a destination in Move to, then click Swap. An occupied destination swaps both cues; an empty destination moves the cue. Titles, media references, IDs and playback/fade settings are preserved. Active playback continues. The moved cue remains selected. Shortcuts belong to positions and stay in place when cues move. Pending file assignments on the two affected positions are canceled to prevent stale drops from replacing a swapped cue. Undo is not yet available; swapping the same positions again reverses the move.
