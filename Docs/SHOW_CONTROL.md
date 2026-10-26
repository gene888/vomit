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

## Cue Sequences (0.3B)

Open Sequences, create/name a sequence and add rows. A row references one ordinary media cue or one group. Drag rows to reorder (or use the list's native move action). Duplicate creates a separate definition with fresh row IDs. Delete removes only the definition; a loaded execution keeps its snapshot until another sequence is loaded.

Load for GO snapshots the definition and stops the previously loaded sequence's owned playback. First GO triggers the first row. Further GO commands mark the current row complete and trigger the next. Manual waits for GO; Timed advances after the row's delay; Follow waits for natural cue/group completion. Follow's Complete after (zero = natural) explicitly defines completion for loops, stills, held final frames and non-completing groups. The completion time advances without stopping playback. Natural Follow is rejected if a persistent target has no later scheduled stop. Operator overrides may remove that stop; GO remains the operator's recovery path.

Pause freezes sequence clocks, launched groups and their owned media. Resume preserves delays. Stop cancels sequence advancement and stops only its owned group instances. GO after Stop continues with the next row; Reset stops and prepares row one. Skip next marks the upcoming row skipped without playing it. Back cancels the current group's remaining schedule, lets its media continue, and prepares the previous row for GO. Skip/Back never automatically trigger a cue or stop unrelated playback. Reset deliberately stops sequence-owned playback; manually taken-over playback is outside its ownership.

A missing reference or loading failure sets Error and requires Reset/reload after correction. Edits apply when Load for GO is used again. The last row's completion marks the sequence Completed; lingering media remains available until Stop/Reset/STOP ALL. Advance sequence actions from a previous sequence row are ignored after a newer row takes over; standalone groups may advance the loaded sequence.

## Show Mode and soundboard pages (0.3C)

Choose Show Mode in the header, select a saved sequence, and use GO. Reload / Reset explicitly loads the latest definition and stops the old sequence's owned media. The dark view displays numbered rows, type icons, Ready/Running/Paused/Completed/Error states, current/next cues, elapsed time, timed/explicit Follow countdowns, and each running or errored group with its next scheduled event. Natural Follow has no countdown because completion depends on playback. Switching back to Soundboard keeps the execution running.

The Soundboard Page selector switches between 32-pad pages. New Page creates an empty page; edit its name beside the selector. Up to 32 pages are supported. Original schema 1/2 pads become Main. Shortcuts belong to positions on each page. Groups/sequences can reference cues on any page by ID, regardless of the displayed page. A Change page action uses zero for Main, one for the second page, and so on. Page changes cancel pending file assignments to protect against a drop arriving on the wrong page; active playback continues. There is no page deletion/undo UI yet.

Open Shortcuts in Show Mode or Configure Show Shortcuts in the Performance menu. Choose one key per command; show commands use Command + Option. They work in both modes, including when a text field has focus. Ordinary Option pad shortcuts remain unchanged. Repeats are suppressed. Show/pad shortcuts are suspended in modal dialogs and editor sheets; Command-period emergency stop remains active even there. These are application shortcuts, not global macOS shortcuts.

Default commands:

| Command | Shortcut |
|---|---|
| GO | Command-Option-G |
| Pause / Resume | Command-Option-P |
| Stop sequence | Command-Option-S |
| Skip next | Command-Option-] |
| Previous (prepare for GO) | Command-Option-[ |
| Emergency Stop All | Command-Option-period, and invariant Command-period |
| Video Blackout | Command-Option-B |

Cut immediately replaces the visual after readiness. Fade to visual fades the incoming visual from black/background and retires the outgoing visual; Crossfade overlaps the two. A fade commanded during loading applies when the new visual/audio is ready. Individual video soundtrack level overrides remain distinct from picture-opacity fades.

Manual overrides carry into delayed child groups and later automatic sequence steps. A new explicit pad/group trigger or manual GO authorizes automation again from the current override state. Preflight checks all pages and missing show references/cyclic group triggers in addition to media. Audio device configuration changes cancel show automation before the original engine stops; retrigger deliberately after checking the route.

Limits: at most 256 group definitions, 512 actions per group, 256 sequences, 1,024 steps per sequence, 128 live group instances and 32 trigger nesting levels. Terminal execution history is bounded; current Follow state and errored instances that still own playback are retained. JSON is bounded to 16 MiB as of 0.5D (the 0.3–0.5C limit was 2 MiB); see [resource and capacity notes](RESOURCE_EFFICIENCY_0.5D.md). Groups are snapshots at launch; sequences are snapshots at load. Navigation and timed advancement do not automatically stop media from previous rows. Sleep/suspension and heavy main-thread stalls are unsuitable during a live show: elapsed continuous-clock deadlines become due when execution resumes. Preloading, sample-synchronized starts and a long-soak profiling pass are recommended future improvements.
