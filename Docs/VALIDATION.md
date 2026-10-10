# StageCue 0.1 build and validation — 9 October 2026

## Result

A functioning Apple Silicon macOS app project now builds in both Debug and Release. The Release app is ad-hoc signed, verifies successfully, and was launched and exercised through the native UI. The final audio/model/persistence test run passed **36 tests in five suites**, exit status 0. This is a development build with physical audio validation still required, not a certified show-ready release.

Source remains in `/Users/genewilliams/Documents/Codex/Dev/StageCue-0.1`. A local Git repository preserves the original extraction as commit `46beb25`, followed by the implementation commit. Origin points to the inspected repository, `https://github.com/gene888/vomit.git`. Initial read-only remote inspection and clone found no commits/advertised refs. Nothing has been pushed. No unrelated projects were edited; the original source zip is preserved. Commits use the transparent tooling identity `StageCue Local Development <stagecue@localhost>` scoped to each commit command, without changing global Git identity.

## Build evidence

- Xcode 26.6, build 17F113; shared `StageCue` app scheme; macOS 14 deployment target; arm64 executable.
- `Scripts/build.sh Debug`: BUILD SUCCEEDED.
- `Scripts/build.sh Release`: BUILD SUCCEEDED.
- `codesign --verify --strict` succeeded for the Release bundle and its delivered copy.
- Complete Swift concurrency checking enabled in the Xcode target. No StageCue source compiler warnings remain. Xcode emits an unrelated AppIntents metadata warning because the app has no AppIntents dependency. Restricted command execution also emits simulator-service diagnostics; these do not prevent either macOS build.
- Swift Package Manager uses the same production Swift files and a local test target, with no remote dependencies. The package manifest requires Swift tools 6.2; source remains in Swift 5 language mode. The isolated deinitializers are why the newer compiler is required.

## Automated evidence

The log ends with `Test run with 36 tests in 5 suites passed`; the native runner wrote exit status `0`. Tests render the actual AVAudioEngine graph into PCM buffers and compare results against calculated gain values. Silence fixtures used with the live engine emit no audible signal.

| Area | Verified behavior |
| --- | --- |
| Cue settings | Gain conversion, finite/bounded values, 32 pads, six buses, duplicate-ID repair, legacy Hold conversion, repeatable normalization |
| Fade math | All curves in both directions, endpoints, monotonicity, zero duration, interrupted-envelope continuity, complementary equal-power fades, short-clip in/out duration fitting |
| Project files | All cue/mix settings and absolute paths round-trip; legacy/partial defaults; malformed/future JSON rejection; oversized input rejection; failed-write preservation; stale autosave revision rejection |
| Concurrent audio | Different cues sum correctly; clip, bus and master gain multiply correctly, including +6 dB boosts; all six buses route independently |
| Automatic fades | Initial fade-in and natural-end fade-out change rendered audio as expected; short clips remain audible with proportionally fitted durations |
| Manual fades | Independent cue envelopes; Fade to Silence keeps a loop active and silent; Fade In restores it; Fade Out & Stop detaches only the requested voice; replacing a stop envelope with fade-in cancels its stop |
| Transport | One-shot finishes; loops continue across file boundaries; Toggle performs configured faded stop; retriggers replace the same cue; canceled/stopped pending loads cannot create stale voices; fade-all with zero duration releases voices |
| Media | Missing/invalid media and four-channel inputs are rejected; mono/stereo and 44.1/48/96 kHz inputs produce finite audio through the common stereo graph |
| Resource controls | Sparse oversized media is rejected before PCM allocation; simultaneous load reservations respect a test budget; a rejected additional cue leaves existing audio active; stopping releases budget for later use |
| Cleanup | 100 repeated retrigger/render/stop cycles return attached node counts and decoded-buffer accounting to baseline |
| Interruptions | Simulated configuration change clears voices/resources and stops the engine; playback requires explicit retrigger |
| Live callbacks/timer | A real engine plays a silent one-shot to completion; live timed silence/fade-in/fade-stop produce expected active state and gain endpoints |

The tests originally could not create mixer components inside the restricted shell environment. They were moved to Apple's Swift Testing framework and executed through the included native test-runner app, with Xcode's test-framework search paths supplied. The final successful run used normal desktop application access. The initial failed attempts are not counted as successful validation.

## Release UI smoke test

Launched the delivered Release `.app` and inspected its 32-pad grid, six faders, master, inspector and transport controls. Opened a prepared local two-cue JSON referencing digital-silence WAVs on buses 1 and 6, triggered both, and verified both pads showed active green indicators. Initiated Fade to Silence for the first and Fade Out & Stop for the second: the first stayed green/active, while the second returned to its selected inactive color. Preflight decoded both media files and reported the engine running. Command+. stopped the remaining cue. The imported test JSON remained unchanged. The original empty show state was restored through the UI and the app was quit normally; no validation media remains assigned in autosave.

UI verification proves control/state behavior and successful launch. It is not an audible listening test.

## Reliability changes

Preserved the Codable project, ShowState, AVAudioEngine player/mixer model, six buses and master. Added bounded decoding on a serial actor with token-based cancellation and admission reservations; fixed all graph mutation to the main actor; removed mutable voice captures from cross-thread callbacks; bounded error history; and provided shutdown and device-change handling. Native zero-band gain stages keep mixer volumes inside Apple's documented range while supporting +6 dB user gain. Both attenuated and boosted rendered levels are tested.

Fades use explicit replaceable envelopes with a common-mode 120 Hz timer; natural-end tails use player playback time and avoid unintentional fade overlap on short clips. A manually triggered fade owns the remainder of the voice and suppresses later automatic tails. A silent loop remains active until explicitly stopped.

UI forwards nested engine changes, displays errors/loading, provides Edit without playback, hides unsupported Hold selection and uses Option-number shortcuts. Persistence validates inputs, debounces autosave, serializes atomic writes outside the UI actor, rejects stale writes and avoids rewriting imported documents during edits. Corrupt autosave is preserved until explicit recovery action.

## Physical validation and limitations

Before performance use, test the actual interface with audible clips: gain/headroom, all six buses, curve quality and independent fade behavior. Measure latency and glitches under show load; test USB removal/reconnection, default output changes, rate/buffer changes, sleep/wake and a prolonged run. Simulating the interruption handler does not validate physical device notifications or driver behavior. Control-rate fades are not sample accurate and can be delayed by a blocked UI thread.

Per-clip decoded media limit is 64 MiB; the active-plus-reserved budget is 256 MiB. These are buffer budgets, not process-memory ceilings. Decoding is not cached, so first-trigger latency remains. Long media streaming, preloading, metering/clipping protection, device selection, Hold, pause, portable media collection and sandbox bookmarks remain outstanding. Node/buffer accounting tests are not a full Instruments leak/CPU profile. The macOS 14 deployment target has not been tested on a separate macOS 14 machine. The app is ad-hoc signed, not notarized.

The complete remaining list is in `OUTSTANDING.md`. No Version 0.2 video functionality was added.

## Follow-up: Pad file drops

Pads accept one local file URL using SwiftUI native drop destinations and highlight the targeted pad. Media is decoded and checked off the UI actor before assignment. Empty pads use the filename; assigned pads preserve their ID, name and playback/gain/bus/fade settings. A successful replacement stops only that pad's current voice; drops never autoplay. Browse shares this validation. Failed validation does not change or stop the old cue. A newer drop supersedes pending validation, and cleared pads/opened projects invalidate stale assignments.

Release build and signature verification passed after this change. Four new native tests verify empty-pad creation without playback, settings-preserving replacement with independent audio, rejection of invalid/missing/folder/remote/multiple files, and superseded/cleared assignment cancellation. The full regression suite passed 36 tests in five suites. Test state uses an injected autosave location and never modifies the user's show.

An isolated UI harness displayed the actual pad/drop code, but the UI automation drag API repeatedly returned `noWindowsAvailable`. A physical Finder drag gesture was therefore not verified in this run. Assignment behavior is tested directly using the same URL handler invoked by the drop destination.
