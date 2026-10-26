# StageCue 0.1 development build

- Added an Apple Silicon Xcode app target, shared scheme, reproducible build/test scripts and local version control.
- Validated the real audio graph with rendered PCM and native live-engine tests.
- Added background bounded decode, load reservations and reliable stop/retrigger cancellation.
- Added natural-end automatic fades, independent replaceable manual envelopes, correct complementary equal-power math and short-clip fade fitting.
- Preserved six stereo buses and master; supported full dB gain through native gain stages with documented mixer ranges.
- Added route-change stop/retrigger policy, resource cleanup, visible engine errors/loading and live pad status updates.
- Added project validation, compatible legacy decoding, duplicate-ID repair, debounced atomic autosave and explicit document-save semantics.
- Removed unsupported Hold selection and moved cue shortcuts to Option+1 through Option+9.
- Physical audio/interface validation remains required; video is outside this build.

## File-drop update

- Drop one local audio file onto a pad to create a cue or replace its media.
- Preserve existing cue settings and reject invalid media without interrupting its playback.
- Highlight drop targets, share validation with Browse, and cancel stale assignments.
- Release build passes; all 36 tests pass. Automated native drag gestures were unavailable in the UI tool.

## 0.2 development

- Tagged the validated audio baseline v0.1 locally and isolated video work on stagecue-v0.2.
- Added schema-2 audio/video/image cues with version-1 migration and separate protected autosave.
- Added dual-player MOV/MP4 playback, PNG/JPEG stills, cuts/crossfades, looping, pause/resume, fade-to-black and stop.
- Added preview, blackout, optional background and persistent borderless external output with disconnect safeguards.
- Extended pads, shortcuts, preflight and media assignment without changing the audio engine.
- 50 native tests pass; hardware acceptance requirements documented.

## 0.5A mixer performance

- Added bounded incremental bus/master updates and a seven-value engine restore snapshot; removed project-wide normalization from live mixer control.
- Preserved immediate gain application, synchronous project/UI consistency, existing 350 ms autosave debounce, manual precedence and audio/video separation.
- Release build and 111 native tests pass. Median measured real-command cost fell about 97%; both performance runs and remaining timing/cadence limitations are documented in Docs/MIXER_AUTOMATION_0.5A.md.

## 0.5B audio responsiveness

- Profiled UI/model, direct-engine, scheduler, loader/graph, and first-render boundaries before optimizing.
- Added bounded 60 Hz runtime presentation invalidation; engine/scheduler state remains immediate, project publication and autosave remain unchanged.
- Removed redundant filled-pad selection; retained the decoder, memory reservations, playback tokens, graph and 0.5A mixer path.
- Matched short-WAV median improved from 90.13 to 51.84 ms; P95 from 100.41 to 56.28 ms. All 115 regression tests pass.
- No PCM cache/preparation/streaming system added; dense 100 Hz mixer/project publication remains a documented responsiveness limit.
