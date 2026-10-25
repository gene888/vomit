# StageCue 0.5A

The [0.5A mixer optimization](Docs/MIXER_AUTOMATION_0.5A.md) adds targeted bus/master gain updates and removes whole-project normalization from mixer control. Engine changes remain immediate; UI publication and the existing debounced save behavior are preserved.

The [persistent video hold fix](Docs/PERSISTENT_VIDEO_HOLD.md) keeps a completed video's final picture independent of audio-only actions. **FADE AUDIO** and Command-Shift-F now affect audio only; Performance > Fade All Media & Stop and Emergency Stop All are explicitly combined controls. See [control separation](AGENTS.md) for the rule used in further development.

Native, local macOS audio/video soundboard: SwiftUI, AVAudioEngine, AVPlayer and Core Audio. Apple Silicon only; macOS 14 or newer. No cloud services, third-party runtime dependencies, recording or streaming.

For setup, playback controls, Cue Groups, Sequences, Show Mode, keyboard shortcuts and troubleshooting, see the complete [Operator Manual](Docs/OPERATOR_MANUAL.md).

The manual is also available as a [printable PDF](Docs/StageCue-0.3-Operator-Manual.pdf) and an [editable Word document](Docs/StageCue-0.3-Operator-Manual.docx).

## Project portability in 0.4

Read the [0.4 portability operator guide](Docs/PORTABILITY_OPERATOR_GUIDE.md) for the distinction between a project file and a complete portable production, the three save/export operations, batch recovery and destination checks. The 0.3 manual remains the reference for unchanged performance controls; its absolute-path-only project guidance is superseded by the 0.4 guide.

A project file may reference media anywhere. Export Portable Project creates a new verified folder containing Project.stagecue, MediaManifest.json and collected media using project-relative paths. Copy the whole folder to the other Mac. Schema 1–3 migration preserves originals; schema 4 adds the shared manifest. See [architecture](Docs/PORTABILITY_ARCHITECTURE.md) and [validation](Docs/PORTABILITY_VALIDATION.md).

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

Media references remain absolute paths. Projects save references, not copied audio. Moved/missing media is reported; use Browse to relink it. Audio cues support nonempty mono/stereo files decodable by AVAudioFile. Each decoded clip is capped at 512 MiB; active voices plus reserved loads are capped at 1 GiB. This accounts for decoded PCM, not total process memory: the loader, preflight, framework nodes and temporary canceled work use additional memory. The loader serializes decoding. No buffers are cached; first-trigger decoding has latency. Long clips must be shortened or converted until streaming/preloading is implemented.

## Architecture

Codable value models feed ShowState (UI, project I/O) and a MainActor SoundEngine (graph and voice control). Media decode runs on a separate serial actor. Each active cue owns a player/mixer; six virtual stereo buses feed a master and the system default output. Zero-band AVAudioUnitEQ stages supply a fixed +6 dB gain while mixer attenuation stays within Apple's documented 0–1 range. Each source is converted by its mixer to a common 48 kHz stereo graph. All graph mutations remain on the UI actor; callbacks cross back using UUID/token identities, not mutable voice objects. Decode reservations and cancellation prevent queued work from publishing stale voices.

Fade envelopes use a common-mode 120 Hz control timer in live playback; offline tests drive the same envelope calculations using rendered sample time. Fades are control-rate, not sample accurate. The real output graph uses the system-selected output device; there is no device selector in the app.

See `Docs/VALIDATION.md` for evidence, hardware checks and remaining features. The local Git baseline preserves the original extraction. Development commits use an explicitly local tooling identity, not an inferred personal email. The validated 0.1/0.2 milestones are on GitHub; 0.3 work is committed locally until explicitly published.

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

## Version 0.2 visual cues

Drag MOV/MP4 or PNG/JPEG onto a pad, or use Browse. The cue type is detected from the media. Audio remains independently playable on the original six buses. Only one visual program is presented at a time; two players overlap for transitions. Choose Cut or Crossfade and visual fade durations in Pad Settings. Crossfade uses the incoming cue's fade-in duration; a cut ignores that duration. Video one-shots hold the final frame while their configured fade-out completes; looping seeks back to the beginning and is not guaranteed gapless. Still images remain until replaced/stopped.

Pause/Resume affects visual playback and transition clocks. Selected-pad Option shortcuts apply to audio or visual cues. Fade down retains playback; fade out/stop retires it. Blackout instantly masks the picture in preview and output; soundtrack and independent audio continue. Stop Video affects only the visual program; STOP ALL / Command-period also stop audio. Optional background PNG/JPEG appears when the program is empty or fades away. Blackout covers the background too.

Connect a separate display in extended desktop mode. Keep StageCue on the operator display, click Refresh, choose Output display and Show Output. The borderless presentation covers that display without taking keyboard focus. Close Output closes only the window, not playback. Playback is owned by ShowState and persists through selection/reordering/grid scrolling. Disconnecting the presentation display closes its window and reports the problem instead of moving it onto the operator screen. Reconnect, Refresh and Show Output explicitly. Presentation prevents idle display sleep while its window is open.

Soundtracks use AVPlayer volume (-60…0 dB) and the macOS default audio output. Select the external hardware interface in macOS before the show. They do not pass through the six audio buses or the audio master. Settings changes take effect on the next trigger. Blackout does not mute audio. Native decoding supports only codecs available on this Mac; MOV/MP4 is a container guarantee, not support for every possible codec. Video dimensions are limited to 4096 pixels per axis; PNG/JPEG to 32 megapixels with a 4096-pixel decode thumbnail. Shared output targets 30 fps SDR with aspect-fit letterboxing; HDR and frame-accurate/gapless output are not claimed.

In Version 0.2, Version 1 audio projects migrated in memory to schema 2. Version 0.3 imports both formats into schema 3; follow the Show Control guide below. Export a new 0.2 copy; opening a v1 project deliberately does not set it as the Save destination, protecting its original file. Schema 2 files cannot be opened by 0.1. Autosave uses `autosave-v0.2.json`, separate from the audio version's `autosave.json`. The local annotated v0.1 tag preserves the audio code; 0.2 development is on stagecue-v0.2. Keep the 0.1 app and project copies for rollback.

Architecture and current validation: Docs/VIDEO_ARCHITECTURE.md and Docs/VIDEO_VALIDATION.md. Physical projector/interface acceptance remains required.

### Hold a video's final frame

In a video pad's settings, enable Hold last frame when finished, then trigger the cue. At natural completion the soundtrack ends and the final video sample remains visible. Triggering another visual cue can cut/crossfade from this held frame; manual stop/fade-out-stop still clears it. The option is saved with the project, defaults off for existing cues, applies on the next trigger, and is disabled while Loop is enabled. Pause/resume does not restart an already finished held cue.

## Version 0.3 Show Control

Cue Groups, Cue Sequences and optional Show Mode extend the existing soundboard. Original audio/video projects migrate to schema 3 in memory; Export a new copy. Autosave is separate (autosave-v0.3.json). Development uses feature/show-control-0.3; local v0.2 preserves the prior working app.

Start with [Show Control operator guide](Docs/SHOW_CONTROL.md), [architecture](Docs/SHOW_CONTROL_ARCHITECTURE.md) and [validation](Docs/SHOW_CONTROL_VALIDATION.md). The earlier sections describe the 0.1/0.2 workflows retained in 0.3.

## Performance baseline

See the [25 October 2026 performance and architecture audit](Docs/PERFORMANCE_AUDIT.md) for measured audio/video startup, large-show memory, simultaneous-playback CPU, video cadence/transitions, scheduler timing, raw samples, and the opt-in reproduction procedure.
