# StageCue 0.3 operator guide

## Cue Groups (0.3A)

Assign media to ordinary pads first. Open Cue Groups, choose New and name the group. Add actions, select stable cue/group references, and set delays in seconds. Delay is measured from launch, not from the previous action. A Wait row adds its duration and delay to the offsets of later rows. Equal deadlines run in list order. Use the up/down buttons to order actions.

Play cue uses its saved loop, gain and fades; optional level and fade-in overrides belong only to that action. Cut and Crossfade require video or an image; Crossfade's Seconds value controls the incoming transition. Fade cue to dB changes audio amplitude (visual cues use picture opacity); Fade to silence keeps playback running. Fade and stop clears it. Set bus dB changes the live bus and project setting. Blackout masks the picture, leaving audio running. Trigger group starts a child instance. Cycles and excessive nesting/concurrency produce errors.

Select a pad with Edit, then choose Assign group. That ordinary pad and its Option shortcut trigger the entire group. Multiple instances may run concurrently. Group Pause freezes pending delays and owned media; Resume preserves the remaining intervals. Stop cancels all pending actions. Select Immediate, Fade and stop, or Cancel scheduled actions only in group settings. Playback survives group stop exempts that play action from media termination. Child groups normally follow parent stop/pause; a surviving child continues independently.

Automatic completion waits for all scheduled actions, child groups and owned media. Loops, still images and held video frames keep a group active until explicitly stopped; turn automatic completion off to keep a control-only group active. Errors cancel the remaining actions of that instance, retain its current picture/audio for operator recovery, and display an error. Stop still works on an errored instance.

Manual playback/fade/stop and gain changes take priority on that resource: pending conflicting actions in already running groups are skipped. A newly triggered group may automate it again. A newer automated playback start takes ownership; stopping an older group cannot stop the replacement. Unrelated audio remains independent. The video program is one shared resource with two transition slots, not multiple simultaneous screens.

Emergency STOP ALL / Command-period cancels scheduling and pending loads and stops both engines. Switching views, opening an editor and rearranging pads do not stop playback. Edits to a running group's definition apply only on its next launch. Save/Export saves definitions, not live execution state.

## Project compatibility

Schema 3 references existing media IDs without copying files. Schema 1/2 files migrate in memory; use Export to create a 0.3 file and preserve the original. Autosave uses autosave-v0.3.json. Keep the older app/project for rollback. Missing references report errors instead of starting another cue. Removing a referenced cue/group requires updating the referring action.

## Timing and hardware limits

The scheduler uses ContinuousClock and cancellable sleeps, independently of SwiftUI timers. Commands with equal deadlines execute in an ordered batch; this is not sample-accurate synchronized playback. First-trigger media decoding/readiness adds latency. Engine command delivery and existing audio/video fades use the main actor, so UI/main-thread stalls can delay them. Scheduling wakes at most every 25 ms for completion checks, or at an earlier action deadline. Pause/resume adjusts monotonic start times.

Prepare and preflight all media before the show. Exercise the actual audio interface and projector, hot-plug behavior and a long-show soak. Video soundtrack remains on the system audio output, outside audio bus/master gain. Existing 0.2 codec/size/30 fps SDR limits remain. No network, cloud, recording, streaming, MIDI, OSC or DMX support is added.
