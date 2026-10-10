# StageCue 0.2 development validation — 10 October 2026

## Baseline and milestones

Remote main was inspected at 5ae4a12 with no existing v0.1 tag. Created local annotated v0.1 at that commit before changes and developed on stagecue-v0.2. The AudioEngine.swift file is unchanged from that tag. Milestones committed: schema/architecture, dual-slot visual engine/output integration, and reliability/UI/persistence refinements. No new branch or tag has been pushed.

## Automated validation

Release Xcode build and ad-hoc signature verification pass. SwiftPM native validation passes **50 tests in seven suites**, exit 0. All 41 prior audio/settings/persistence/layout/drop regressions pass. New tests use generated local H.264 MOV/MP4, PNG and JPEG fixtures.

- Schema 1 audio migration, schema 2 complete settings/background persistence, and rejection of future schemas.
- Dissolve endpoints/midpoint and finite/clamped visual settings.
- Real AVPlayer video frame decoding for MOV/MP4, pause clock retention, resume, looping across an end, natural one-shot end and item cleanup.
- Video changes while an independent AVAudioEngine loop stays active and renders PCM.
- Still cuts/crossfades, independent manual fade-to-black/restore and fade-out-stop, blackout without stopping playback.
- Missing video retains existing program; newer triggers win; Stop cancels loading; toggle while loading cancels without disturbing current program.
- Repeated still transitions retire old frames/IDs; player-item count returns to zero after stop. These counters do not substitute for Instruments profiling.
- Bounded background decode/clear and mixed-media assignment through ShowState.
- Pure display policy excludes operator screen, closes on disconnect or operator move, and requires a distinct display. This does not prove physical hotplug behavior.
- Mixed-media preflight completes while a movie is playing. Native asset inspection has a 10-second watchdog; first-frame preparation has a separate 10-second readiness limit.

## Native UI validation

Launched an isolated copy of the production UI with a separate fixture autosave. Verified Option triggers for two stills and a generated looping MOV, visible preview frames, cut/crossfade selection, pause/resume labels in operator/inspector, black preview during blackout and restoration afterward. Mixed-media preflight completed. The audio mixer remains outside the scrolling grid; inspector scrolls independently. No user show/project/autosave was changed. No separate external screen is exposed in this environment, so Show Output was safely disabled. Actual fullscreen presentation was not tested on physical hardware.

## Hardware acceptance still required

1. Connect projector/display in extended desktop mode; verify output fills only it, controls remain on operator screen and no app chrome appears. Test frame aspect, fade smoothness and long playback with representative resolution/codec clips.
2. Disconnect/reconnect output during playback and transitions; move operator window between screens, change display modes, Spaces and sleep/wake. Verify window closes safely and can be explicitly reopened.
3. Choose external audio interface as macOS default; audition per-video soundtrack level and transitions alongside bus audio. Verify system route changes, latency, clipping and clock behavior. Video soundtrack is not connected to bus/master gain.
4. Perform long-show soak and Instruments CPU/memory/GPU profiling, especially during high-resolution frames and simultaneous decode/UI activity. Both visual rendering and existing audio fade control remain on the UI actor; UI stalls can affect fades. No sample/frame-accurate guarantee.
5. Test macOS 14 on a separate machine. Build is ad-hoc signed, not notarized.

## Deliberate limitations

One visual program with two transition slots, 30 fps shared SDR frame rendering, native codec support, 4096 pixels per video axis; 32 megapixel image input downsampled to at most 4096 pixels. Rotation metadata is applied. No HDR pipeline, gapless looping, timeline/scrubbing, portable media collection, frame-accurate synchronization, or video soundtrack AVAudioEngine-bus routing. Crossfade timing uses the incoming cue; final-frame fade happens after movie end. Blackout masks picture only. Background remains after stop unless cleared or blacked out. Output device choice is runtime-only and does not auto-present on launch. No soundboard page system exists; output lifetime is independent of pad layout/selection. No recording or streaming.
