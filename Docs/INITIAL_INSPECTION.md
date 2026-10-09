# StageCue 0.1 initial inspection — 9 October 2026

## Verified baseline

Inspected every supplied file in `/Users/genewilliams/Documents/Codex/Dev/StageCue-0.1`: Package.swift, README.md, Models.swift, AudioEngine.swift, and StageCueApp.swift. There are no third-party dependencies, tests, resources, Xcode project, workspace, or app-bundle configuration. The original zip and source remain unchanged.

The original source compiled successfully for arm64 with Xcode 26.6 (17F113), Swift tools version 5.9, deployment target macOS 14. Two warnings report non-Sendable Voice objects captured by asynchronous callbacks. The executable was packaged as an ad-hoc signed baseline app. Native UI inspection verified its StageCue window, pad grid, settings, six bus faders, and master fader. Clicking Preflight reported that the audio engine was running. No audio cue playback or audible output has yet been tested. This is a baseline diagnostic app, not a validated release.

The active system developer directory is Command Line Tools. Build commands select the installed Xcode using DEVELOPER_DIR, without changing xcode-select globally. `xcodebuild -list` in the source directory fails because no Xcode project/workspace is supplied. Swift package compilation succeeds; this does not establish the requested reproducible Xcode app build.

## Git inspection

The source directory and chat directory are not Git repositories. Git's system configuration contains the macOS keychain credential helper; no global .gitconfig exists. Read-only `git ls-remote --symref` and a clone into the chat's work/repository-inspection both succeeded. The remote https://github.com/gene888/vomit.git has no advertised refs; Git explicitly reported an empty repository. Its clone has no commits. No remote content was modified and nothing was pushed. No repository identity was invented.

## Architecture

SoundProject and Cue are Codable value models. ShowState owns the project, panels, persistence, and SoundEngine. SoundEngine is main-actor isolated and owns AVAudioEngine, one master mixer, six bus mixers, and one player/mixer pair per active cue. Pad UUIDs permit simultaneous different cues; one-shot retriggers replace the same cue's voice, Toggle stops it, and Hold currently starts without release handling. Decoded files are scheduled as complete in-memory PCM buffers. Voice identity checks protect retriggers from stale completion callbacks. Detach stops players and invalidates fade timers.

Preserving this graph and model structure is reasonable. Local reliability improvements should precede streaming, routing, or other architectural expansion. No video changes are planned.

## Findings prioritized for reliability

1. Media decode and full-buffer allocation occur synchronously on the main actor. A large file can block emergency stop/UI input. The UInt32 frame limit permits enormous allocations and does not provide a practical memory budget. Preload/cache bounded media off the UI thread and reject excessive decoded sizes before allocation.
2. Project normalization only adjusts array lengths. It does not validate bus indices, duplicate cue UUIDs, gain/duration ranges, or finite numeric values. Short arrays passed directly to applyMix cause indexed access failures. Imported duplicate UUIDs conflate pads. Validate at persistence and engine boundaries.
3. UI views observe ShowState, not its nested SoundEngine. Engine active/errors changes do not automatically propagate to those views. Playback indicators may remain stale, and engine errors are never shown to users.
4. Fade timers run on the default run-loop mode, capture Voice across concurrency boundaries, and update gain through asynchronous main-actor tasks. Busy UI/modal panels can delay fades. Use weak/identity-based callbacks, common-mode scheduling, explicit cancellation, and tests. Timer control still cannot guarantee sample accuracy.
5. Automatic fade-out at natural end is missing. The current setting only affects the inspector stop command. Tail-fade scheduling must account for overlapping fades and loop semantics.
6. Hold mode is exposed but does not handle release. Either implement press/release with keyboard/pointer cancellation or remove this option from the 0.1 UI until supported.
7. No engine configuration-change/route-loss handling exists. Device changes can stop the engine while active cue state remains misleading. Test recovery and define whether interruption stops or resumes cues; prefer explicit user retrigger over unexpected sound after reconnection.
8. Clip settings are snapshots taken at trigger time. Changing gain or bus during playback does not update an existing voice. Define and document whether edits apply immediately or on next trigger.
9. Persistence uses atomic writes, but silently ignores autosave read/decode/directory errors. UI edits can issue repeated synchronous writes, and Save also rewrites the last imported/exported project file. Add visible errors, debounced autosave, recovery, and explicit save semantics.
10. Absolute media paths are retained; moved files fail. Preflight checks existence only, not decodability, duration, available memory, or supported channel formats. Add media validation and relinking. No sandbox bookmarks are supplied; app sandboxing should not be enabled casually.
11. Equal-power uses the same sine interpolation in both directions. Its complementary fade-out is not a cosine equal-power envelope. Define the curve mathematically and test both directions, endpoints, zero duration, and interrupted fades.
12. Number-key shortcuts can interfere with text editing. Force-unwrapped inspector bindings should capture a stable slot and handle a cleared cue safely. Clear Pad is the only convenient selection/edit flow without triggering an assigned pad.

## Required validation still outstanding

- Reproducible Xcode application target and shared build scheme; versioned build scripts and initial local Git baseline.
- Automated tests for settings normalization, gain conversion, all envelope curves and cancellation, project round-trip/invalid imports, and missing media references.
- Offline AVAudioEngine rendering tests for simultaneous voices, six-bus routing, clip/bus/master gain, looping/one-shots, natural-end fades, independent manual fades, silence without stop, fade-stop, retrigger races, and graph cleanup.
- Repeated playback/stop tests with resource measurements and mixed formats/sample rates/channels.
- Physical interface validation: audible gain/fade results, clipping/headroom, latency, USB disconnect/reconnect, default-device changes, different sample rates and buffer sizes, sleep/wake, and sustained concurrent playback while editing/opening panels.

Metering, dedicated output-device selection, media collection/portable projects, long-file streaming, pause, and sample-accurate fades remain outstanding 0.1 considerations. Video remains outside scope. Software checks must be reported separately from hardware listening tests.

This checkpoint completes the requested inspection and baseline build/launch validation. Substantial implementation changes and audio correctness testing remain pending.
