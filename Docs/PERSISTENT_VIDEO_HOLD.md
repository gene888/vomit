# StageCue 0.4.1 persistent video hold fix

## Operator rule

Audio commands affect audio. Visual commands affect visuals. Cue Groups and Sequences affect both only through explicitly configured actions. The selected pad is not the projector's program state.

A non-looping video with Hold Last Frame When Finished enabled now retains independently owned final-frame pixels. Audio pads, their gain/fade/stop commands, audio-only group and sequence transport, page changes, and switching Soundboard/Show Mode leave the picture intact. No project conversion or new cue setting is required.

The held picture remains until a new video/image or an explicit visual cut/fade/crossfade replaces it, a visual stop clears it, or Blackout covers it. Blackout retains the underlying program so removing blackout can reveal it again. Non-hold videos still use their existing end fade/stop behavior, and looping video still loops instead of entering hold.

## Fade controls

- **FADE AUDIO**, also Performance > Fade Audio & Stop and Command-Shift-F, fades and stops audio cues only. It overrides their existing audio automation without canceling visual ownership or pending explicit visual actions.
- **Performance > Fade All Media & Stop** remains the explicitly combined fade. It affects audio/video and cancels show automation.
- **STOP ALL**, Command-period, and the configured Emergency Stop All shortcut remain explicitly combined emergency controls. They immediately stop both audio and visual playback and cancel automation. Their tooltip identifies the scope.
- Selected audio-pad arrows, fade-and-stop, and Stop remain audio-only. Selected visual-pad controls remain visual controls. Group Stop follows that group's explicitly configured playback ownership and stop behavior.

A prepared sequence can still execute its next explicit visual action when its advancement rule is satisfied. Audio fade does not erase or cancel the operator's programmed visual timeline.

## Implementation findings

Inspection found that ordinary audio triggers already call SoundEngine rather than VideoEngine, and page/mode selection does not directly stop visuals. There was no direct audio-trigger call that cleared the projector layer. The old hold path did, however, continue polling AVPlayerItemVideoOutput on every rendering tick after the video ended. A retained decoder frame could therefore be replaced after completion. The old FADE ALL control also explicitly called video.stop.

The fix uses the existing slot's holdingEnd state. On completion, it materializes the picture into an owned bitmap, seeks once to the final sample as before, materializes that final sample, and excludes the held slot from subsequent decoder polling. Both preview and output continue to render the same persistent image. Stale completion callbacks are guarded by player-item identity; repeated end notifications do not restart the hold operation. No video-player recreation, new scheduler, audio-engine change, or persistence-format change is introduced.

The normal fade control now calls an audio-only command. The existing combined method remains available under an explicit all-media label. AGENTS.md records the separation rule for subsequent development.

## Regression validation

Native tests generate a video whose final frame alone is red. They allow natural completion, verify the held pixels, attach the same VisualCanvas used by projector output, trigger three real silent audio cues, fade/stop audio, execute an audio-only group with delayed play/fade/silence/pause/resume/stop actions, operate an audio-only sequence in Show Mode, and change pages/modes. At every checkpoint, both frame identity and rendered red canvas pixels remain unchanged.

The regression then replaces the hold with a looping video, replaces that with a crossfaded still, verifies blackout renders black, and verifies explicit visual Stop clears output. A second test confirms audio fade preserves an already displayed still and pending explicit visual automation, while the combined all-media fade still clears it. Existing final-frame, non-hold, MOV/MP4, transitions, loading, looping, manual-stop, project migration/portability, group, sequence, and emergency tests remain enabled.

All 104 tests in 12 suites passed in the final native runner in 18.201 seconds with exit 0. The Xcode Release build and signature verification succeeded. The actual 0.4.1 application launched; FADE AUDIO, its scope tooltip, the explicit combined Performance menu action, and the emergency control were verified in the native interface. Test and build logs accompany the deliverable.

The reported failure was not reproduced on a physical projector; automated assertions cover actual Core Animation canvas pixels and native media playback. Rehearse the supplied acceptance sequence with the production projector and audio interface before the next show. Existing code-signing, hardware-routing, and scheduling limitations remain.
