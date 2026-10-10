# StageCue 0.3 architecture and implementation plan

Baseline: v0.2 at 8aa581e, Release build and 51 native tests pass. Development stays on feature/show-control-0.3. Neither main nor the audio/video branch is modified.

A separate execution coordinator owns group instances, ordered scheduled actions, resource leases and sequence state. ContinuousClock wakes a cancellable task; scheduling never depends on a SwiftUI timer. Engine calls remain brief MainActor operations because Apple's existing engines already require that isolation. Decode remains asynchronous. Deadlines are not frame/sample accurate: main-actor contention and media readiness can delay presentation, and simultaneous commands mean one ordered batch, not synchronized sample starts.

Actions reference stable cue/group identifiers, never duplicate media. Delay is measured from group start; Wait adds its duration to subsequent action offsets. Equal deadlines execute in group launch order then action-list order. New automated commands replace old commands on a resource; ownership follows the latest playback start. Manual commands invalidate that resource for already running groups; a newly triggered group can acquire it again. Stop/pause/resume affects only currently owned playback, never replacement playback or unrelated cues. Surviving actions relinquish ownership on termination. Emergency stop cancels scheduling and loads before stopping both engines.

Schema 3 adds groups, sequences, additional soundboard pages and show configuration. Schema 1/2 imports retain media IDs and defaults. Imported older documents require Export to avoid overwriting originals. 0.3 autosave is separate. Missing references become execution errors, not crashes. UI edits apply to the next group launch; active instances keep immutable definitions.

0.3A: model/migration, scheduler, audio pause/arbitrary gain fade, group editing/pad assignment, ownership/override tests and regression suite. Commit validated milestone.
0.3B: sequence definitions/editor, manual/timed/follow advancement, explicit completion duration for persistent media/groups, navigation/pause/restart tests. Commit validated milestone.
0.3C: optional low-light show view, configurable show shortcuts, running-group overview and countdowns, continuous playback/mode-switch/emergency tests; documentation and packaged app/source.

Physical audio interfaces, external displays/hot-plug and extended show soak remain hardware acceptance checks. Native video soundtrack routing remains system output, outside the six audio buses. No network/MIDI/OSC/DMX/recording/streaming/cloud additions.
