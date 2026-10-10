# StageCue 0.3 validation

## Baseline and milestones

Version 0.2 baseline: commit 8aa581e; local annotated v0.2 tag. Release Xcode build and 51 native Swift Testing tests passed before modification. Branch feature/show-control-0.3 starts there. main stays at the audio baseline; stagecue-v0.2 remains unchanged.

0.3A: ca6607a, Release build and 64 tests passed. Native UI: group creation, editable actions and visible missing-reference error. Cancellation, simultaneous/delayed actions, monotonic worker-load test, pause/resume, stop modes, survivors, child cancellation/cycles, resource ownership, manual override and real offline PCM fade/pause coverage.

0.3B: cbc13ae, Release build and 73 tests passed. Native UI: sequence creation/step editing/Load for GO/error feedback. Manual/timed/natural Follow/explicit Follow advancement, timing across pause, stop/reset/restart, Skip/Back isolation, missing/failed media, persistence, persistent-target validation and explicit later stop ordering.

0.3C: final Release build succeeds, the actual Release app launches, and 88 tests in 11 suites pass in 11.492 seconds (native runner exit 0). Evidence accompanies the packaged application. All original audio/video tests remain, including real PCM mixing, buffers/limits, fades, MOV/MP4 native decoding, loop/pause, retained-frame pixel verification, backgrounds, transitions and missing-media preservation. Additional tests cover mode/page playback continuity, cross-page groups, saved show shortcuts, duplicate shortcut rejection, emergency cancellation, page/bus actions, canceled drops, inherited manual overrides, audio-device-change cancellation, child errors, stale advance commands, schema/page identity normalization, preflight reference/cycle checking, queued visual fades and fade-from-black cleanup. A retirement stress test launches 600 control groups and confirms current Follow state and errored ownership survive bounded history cleanup.

The ContinuousClock test schedules an 80 ms deadline with a detached 2-million-iteration arithmetic worker and requires dispatch within 230 ms (150 ms lateness tolerance), while other native suites run. This is a modest load test, not a real-time guarantee. Deterministic injected-clock tests verify exact logical deadline/pause/order rules; native media tests verify actual Apple framework playback/rendering.

## UI checks

An isolated app compiled from production sources uses only generated local silent audio, colored PNG and H.264 video fixtures. Its project/autosave is under ignored work/, preserving user projects. Verified: Show Mode list/current highlighting, mixed group GO, group/sequence Pause and Resume, mode switch while playback exists, Command-Option-P from the soundboard, Command-Option-G, timed countdown and automatic advancement, current visual preview and Command-period stop removing all program playback/running groups. The GO label was enlarged and checked again after screenshot review. Command-period was also verified with the shortcut editor sheet open: the sequence became Stopped and visual/owned group playback cleared. Editors and shortcut controls are also inspected in the native accessibility tree.

## Remaining acceptance checks

Physical listening/interface routing, projector visual quality, external display disconnect/reconnect, macOS Spaces, extended performance soak and CPU/GPU/memory profiling require operator hardware acceptance. No claim is made that these are covered by logical display-policy tests or silent fixtures. Video soundtrack routing and all 0.2 size/codec/SDR limitations remain. The app is ad-hoc signed, not notarized; macOS 14 compatibility remains a deployment target without a separate-machine acceptance run.

Run Scripts/build.sh for Xcode Release/Debug. Run Scripts/test.sh in a normal Terminal, or prepare-native-tests.sh and launch work/NativeValidation.app when a restricted runner cannot access Apple audio components. Native results are work/native-tests.log and work/native-tests.exit. A nonzero status is a failure; tests are not reported passed from compilation alone.
