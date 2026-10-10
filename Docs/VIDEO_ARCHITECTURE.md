# StageCue 0.2 architecture

Baseline: local annotated v0.1 tag at 5ae4a12; remote main was confirmed at the same commit. Development branch: stagecue-v0.2. The audio engine, buses, buffer budgets and audio envelopes remain unchanged.

## Boundaries

Cue gains an explicit audio/video/image kind plus visual fade/transition and soundtrack settings. Version 1 projects decode as audio and migrate to schema 2 on save. Schema 2 is deliberately rejected by 0.1 to prevent silent loss of video settings. 0.2 uses a separate autosave file so the audio baseline autosave is preserved.

A main-actor VideoEngine owns exactly two AVPlayer slots and transition state. Asynchronous native asset inspection validates incoming media before replacing the current cue. Each video slot uses AVPlayerItemVideoOutput; decoded frames are shared with a lightweight layer-backed NSView used by both operator preview and output. This avoids attaching multiple AVPlayerLayers to one player (Apple documents that only the most recently created layer may display).

Cuts wait for incoming media readiness. Crossfades place the incoming frame above the opaque outgoing frame, animate its opacity and soundtrack volumes, then retire the old player. Interrupted transitions finish at the most recently accepted cue before preparing another. Loading generations and cancellation prevent stale requests from replacing newer triggers. Missing/unsupported media leaves the existing visual cue running. Still images are bounded/downsampled, not fully unbounded image allocations. Stop/fade-out, pause/resume, loop and blackout are separate controls. Blackout covers only the picture; it does not stop soundtrack or independent audio cues.

VideoOutputController owns a persistent borderless NSWindow. Only a display other than the operator window display can be selected. It does not become key or move the operator controls. Disconnecting its display closes the presentation instead of relocating it to the operator screen. Screen-change notifications refresh choices and geometry. Output is owned by ShowState, independent of pad view lifecycle.

## Audio boundary

AVPlayer soundtracks retain synchronized native playback and per-video volume. They use the system default audio output, which should be set to the external audio interface in macOS. They do not enter the AVAudioEngine buses or master. AVPlayer volume does not provide gain above unity. Routing/extraction into the existing engine would introduce a second clock and synchronization work and is deferred. No streaming or recording is provided; only local files are accepted.

## Validation and limits

Each milestone is compiled; schema/transition rules and native video/PCM fixtures are tested. Physical projector/display disconnect, interface routing, codec support, visual smoothness and long-show soak remain hardware acceptance checks. Frame sharing targets 30 fps SDR, aspect-fit with black letterboxing. HDR/color-managed professional output and frame-accurate transitions are not claimed. No soundboard page system exists yet; output remains persistent when selection/layout changes.
