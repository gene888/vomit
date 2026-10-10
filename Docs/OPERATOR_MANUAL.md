# StageCue Operator Manual

Version 0.3 Build 3

This manual explains how to prepare and operate StageCue for a live show. It covers the audio soundboard, video and images, external display output, Cue Groups, Sequences, Show Mode, project files, and keyboard controls. It describes the current working application as of 10 October 2026.

Prepare cues and rehearse their transitions before the audience arrives. During a performance, you can run the soundboard directly or use a prepared sequence. Manual controls take precedence over existing automation, and Emergency Stop All remains available in either mode.

## Finding what you need

| Section | Page |
|---|---|
| Quick start and emergency controls | 2 |
| Computer and hardware setup | 3 |
| Projects and backups | 4 |
| Pads and soundboard pages | 5 |
| Audio settings and mixer | 6 |
| Audio fades and playback | 7 |
| Video and still images | 8 |
| Projector output and blackout | 9 |
| Creating Cue Groups | 10 |
| Group action reference | 11 |
| Group transport and operator overrides | 12 |
| Group programming example | 13 |
| Creating and advancing Sequences | 14 |
| Sequence transport reference | 15 |
| Show Mode | 16 |
| Keyboard reference | 17 |
| Performance checklist | 18 |
| Troubleshooting | 19 |
| Limits and terminology | 20 |

**Edition note.** This manual describes the Version 0.3 application. Older 0.1 and 0.2 applications do not include Cue Groups, Sequences, or Show Mode. Screens and controls may change in later builds.

<!-- PAGE -->
## Quick start and emergency controls

### Start a simple soundboard

1. Connect your audio interface and select it as the Mac’s sound output. Start StageCue with the external mixer at a safe level.
2. Drag one audio file onto an empty pad. Wait for the assignment confirmation. Alternatively, click Edit, create a cue if needed, then choose Browse in Pad Settings.
3. Set the cue name, Clip level, and Bus. Start at a conservative level; a new audio cue defaults to −6 dB.
4. Click the large pad button to play. Click Edit beneath it to select its settings without triggering playback.
5. Use the mixer bus and MASTER sliders to balance the audio. Option-click a clip, bus, or master gain slider to reset it to 0.0 dB.
6. Choose Export to save a named project file. Run Preflight, then listen to the actual output.

### Know these controls before a show

| Control | Result |
|---|---|
| STOP ALL or Command + period | Stops all program audio and video and cancels show automation immediately |
| Fade All and Stop | Cancels automation and fades program playback out using Manual fade duration |
| Video Blackout | Covers the picture with black; playback and audio continue |
| Edit under a pad | Selects the pad without playing it |
| ▲ under a media pad | Fades existing playback up |
| ▼ under a media pad | Fades to silence or black while playback continues |
| ■ under a media pad | Fades out and stops |
| ✕ under a media pad | Stops immediately |

The selected pad is the one whose settings appear at the right. Selected-pad shortcuts affect that pad, which may differ from the cue currently playing. Several audio pads can play together, but there is one shared video output.

**Black after stopping.** STOP ALL removes the active video or image. An optional background image can remain visible. Turn on Blackout when you need a completely black output.

**Groups use different transport rules.** A group pad’s ✕ applies its configured group stop behavior; ■ forces its group fade-and-stop behavior. ▲ and ▼ do not fade an entire group. Use the group’s Pause, Resume, and Stop controls.

<!-- PAGE -->
## Computer and hardware setup

### Application requirements

StageCue 0.3 targets Apple Silicon Macs running macOS 14 or later. It uses native Apple audio and video frameworks and works entirely locally. An internet connection is not required for playback or project storage.

Quit an older StageCue application before opening the new build. Keep your previous application and original project files until you have rehearsed the new build. The distributed development build is ad hoc signed and is not notarized.

### Set the audio destination

Select the desired audio interface in macOS sound settings. Use Audio MIDI Setup when you need to configure the interface’s format or channel arrangement. StageCue has no audio-device selector of its own.

The six StageCue mixer buses feed one stereo master output. They are software mixing groups, not six separate physical outputs. Route that stereo feed to your external mixer. A video’s soundtrack also uses the Mac’s default sound output, but bypasses StageCue’s six audio buses and MASTER gain.

Connect and configure audio hardware before starting a show. A device configuration change cancels show automation and can stop the audio engine. Check the route and retrigger deliberately after any such change.

### Set the projector destination

Use macOS extended desktop so the operator interface and projector have separate displays. Mirroring does not provide an independent operator screen.

1. Connect the projector or external monitor.
2. Keep the StageCue control window on the operator’s display.
3. In the video controls, click Refresh and choose Output display.
4. Click Show Output. The presentation window is borderless and has no controls.
5. Trigger a test image or video and verify its framing on the real projector.

### Prepare the Mac for performance

Use reliable local media storage and power. Prevent computer sleep during the show and avoid system updates or other demanding tasks. Leave StageCue in the foreground for keyboard commands. Keep your emergency controls within reach.

Preflight verifies files and show references; it does not prove that the speakers or projector are working. Check the actual audio interface, external mixer, display connection, and audience output before every performance.

<!-- PAGE -->
## Projects and backups

### Name and save a project

Click the project title to edit it. Press Return or click outside to commit the name; Escape cancels the title edit. Renaming the title does not rename a file already saved on disk.

| Operation | What it does |
|---|---|
| Automatic save | Stores edits in the local Version 0.3 autosave |
| Save or Command + S | Saves the autosave and the current named file destination, if one exists |
| Export or Command + Shift + E | Chooses a JSON file destination and saves the project there |
| Open or Command + O | Loads a JSON project and stops existing playback after a valid project has loaded |

**Use Export for your first named save.** Without a named file destination, Save only updates the local autosave. Ordinary edits update autosave; use Save to update your named show file after changes.

The project includes pads, media paths, mixer levels, cue settings, groups, sequences, pages, Show Mode configuration, and keyboard assignments. It does not embed media or record the currently running show. Relaunching does not automatically restart playback; the soundboard returns to its first page and a saved sequence is prepared for GO.

### Open older projects safely

Version 0.3 reads Version 0.1 and 0.2 projects and migrates their settings in memory. Original pads become the Main page. Export a new Version 0.3 copy to keep the old file available for the older application. The new format is schema 3; older applications are not intended to read its show-control data.

### Keep media references intact

StageCue stores full file paths. Moving or renaming a media file can break its cue. Use Browse in Pad Settings to assign the replacement file, then save and rerun Preflight. Groups and sequences refer to cues by stable identifiers; they do not make extra media copies.

Back up both the JSON project and every referenced media file. A project file alone is not a complete show backup. For another Mac, copy the media, relink cues to their new paths, and rehearse again.

The autosave is stored under ~/Library/Application Support/StageCue/autosave-v0.3.json. A corrupt autosave is preserved for recovery; do not treat it as your only backup. A failed project load leaves the current project intact. Check the status message after Save or Export for any failure.

<!-- PAGE -->
## Pads and soundboard pages

### Assign and select cues

Each page has 32 pads. A pad can contain an audio file, video, still image, or Cue Group. Click its large button to trigger it. Edit beneath the pad selects it without starting playback.

Drop one local media file onto a pad, or use Browse in Pad Settings. StageCue checks the file before replacing an existing assignment. A failed assignment preserves the previous cue. A successful replacement stops the previous pad’s playback, retains its identifier and most settings, and does not automatically play the new file. Replacing a group pad with media removes its group assignment.

For a blank pad, Create Cue provides an editable cue. To use a prepared group, choose it in Assign group. Group actions themselves are edited in Cue Groups.

### Pad settings and editing

Edit the cue name directly in Pad Settings. Press Return or click outside a name or numeric field to finish editing. Check that the displayed value is what you intended before triggering. Most playback settings apply on the next trigger; audio Clip level and the currently playing video’s Soundtrack level update live.

Clear Pad removes the cue and stops its playback using that pad’s stop behavior. A group or sequence that referred to the cleared cue must be repaired. Recreating a cue with the same name does not restore the old identifier.

### Move a pad without rebuilding it

1. Select the source pad with Edit.
2. Choose a destination in Move to.
3. Click Swap.

Swap exchanges both cue assignments and preserves their settings and identifiers. Shortcuts stay with pad positions. Groups and sequences continue referring to the same cue even when it moves. Swap is within the current page; there is no cross-page move control.

### Use additional pages

Choose a page in the soundboard Page selector. New Page creates an empty 32-pad page; edit its name beside the selector. Up to 32 pages are available. There is currently no page deletion or undo interface.

Changing pages or switching between Soundboard and Show Mode leaves active playback running. Pad shortcuts apply to the displayed page. Groups and sequences can target cues on any page. A page change cancels unfinished file assignments so a delayed drop cannot populate the wrong page.

<!-- PAGE -->
## Audio settings and mixer

### Clip level and playback

Clip level controls an individual audio cue in decibels. Its range is −60 to +6 dB. A lower value is quieter; 0 dB is unity gain. Negative levels are useful when several cues will overlap. Gain above 0 dB or several loud cues combined can overload the output, so verify levels at the external mixer.

| Playback setting | Behavior |
|---|---|
| One-shot | Each trigger starts the cue from the beginning, replacing that cue’s previous playback |
| Toggle | A trigger starts it; triggering the same active cue again stops it using its configured fade |
| Loop continuously | Repeats until stopped; applies with either playback mode |

Different audio cues can play simultaneously. One cue identifier has one playback voice; repeated triggers of that cue do not stack extra voices. Separate pads assigned the same media file are separate cues and can overlap.

StageCue supports common native-decodable audio formats, including WAV, AIFF, and MP3. Actual support depends on the file’s encoding. Use Preflight to verify the exact files intended for the show.

### Route through a bus

Choose one bus in the cue’s Bus setting. Clip gain, bus gain, and MASTER gain combine to determine the audio output level.

| Bus number | Mixer label |
|---|---|
| 1 | Music |
| 2 | Ambience |
| 3 | Effects |
| 4 | Voice |
| 5 | Stingers |
| 6 | Special |

Changing a bus or MASTER slider adjusts playing audio immediately. Bus assignment changes apply when the cue is next triggered. Video soundtrack audio bypasses these buses and MASTER.

### Reset gain

Hold Option and click anywhere on an audio Clip level, mixer bus, or MASTER gain slider to reset it to 0.0 dB. The Soundtrack slider in video settings does not have this reset gesture.

−60 dB is a very low level, not a true mute. Use Fade to silence or Stop when you need exact silence. There are no output level meters in this build; use your mixer or interface metering and listen to the real output.

<!-- PAGE -->
## Audio fades and playback

### Automatic cue fades

Enable Auto fade in on play and enter In seconds to fade up when the audio cue starts. For a loop, this happens at its initial start, not at each repetition.

Enable Auto fade out at end / configured Stop and enter Out seconds. A non-looping clip fades near its natural end. For a loop, the cue keeps repeating until a configured Stop is requested. If fade-in and fade-out would overlap on a short clip, StageCue scales their durations to fit.

Choose Linear amplitude, Smooth S-curve, or Equal-power. These change the progression of the level during a fade. Equal-power here is a curve choice for the individual fade; it does not automatically pair two audio cues into a crossfade. Rehearse the result at performance levels.

### Independent manual fades

Manual fades work on existing playback and use Manual fade duration above the mixer. This is separate from the cue’s automatic fade settings. Zero seconds makes the change immediate.

| Pad control | Selected-pad shortcut | Result |
|---|---|---|
| ▲ | Option + Up Arrow | Fades to the configured clip level |
| ▼ | Option + Down Arrow | Fades to exact silence, keeps playback alive |
| ■ | Option + Shift + X | Fades to silence, then stops |
| ✕ | Option + X | Stops immediately |

After ▼, a looping cue continues silently and can be restored with ▲. A silent one-shot still reaches its natural end; ▲ cannot revive a clip that has already ended. Trigger the pad again to restart it.

A new manual fade replaces a previous fade from its current level. Changing Clip level while playing sets the new level immediately and overrides the previous fade. Manual fade up also replaces the current automatic fade behavior for that playback.

### Choose the right stop

Stop using cue’s fade setting in Pad Settings honors that audio cue’s automatic fade-out setting. The pad’s ✕ stops immediately regardless of that setting. ■ uses the global manual duration. Fade All and Stop fades all program playback using that same manual duration and cancels scheduled show actions.

Standalone audio pads have no separate Pause button. Audio pause and resume are available through group actions and through group or sequence transport. Emergency Stop All stops even cues marked to survive a group stop.

<!-- PAGE -->
## Video and still images

Assign MOV or MP4 video and PNG or JPEG images using a drop or Browse. The exact video codec must be supported by macOS. Audio cues remain independent while a visual cue changes.

There is one shared picture output. Triggering a new visual replaces the previous visual according to its transition. Two internal players allow video overlap during crossfades; they do not provide two independent projector programs.

### Picture transitions

| Transition | Appearance |
|---|---|
| Cut | Replaces the previous picture once the incoming media is ready |
| Crossfade | Overlaps the old and new pictures over Fade in seconds |
| Fade from black | Retires the old picture and fades in the new one over black or the optional background |

Fade out seconds controls the visual’s configured stop and its normal end behavior. A zero-duration fade is immediate. Assignment or loading failure leaves the previous working visual in place and reports an error.

One-shot retriggers a video from its beginning. Toggle starts a visual and stops it when triggered again. Loop continuously is available for video. An image remains displayed until replaced or stopped; it does not need a loop setting.

### Keep the final frame

For a non-looping video, enable Hold last frame when finished before triggering. At the end, its final frame remains on screen until another visual replaces it or you stop it. Its soundtrack has ended. Resume does not restart a completed held video; retrigger the pad to replay it. Loop takes priority and disables the hold control.

### Soundtrack and manual controls

Soundtrack adjusts a video’s audio from −60 to 0 dB. The playing video responds to changes immediately. Its audio goes directly through the Mac’s sound output, outside StageCue’s audio buses and MASTER.

Pause and Resume in the video controls freeze and continue visual playback and transitions. Stop Video removes the program picture. Pad ▲ and ▼ manually fade the picture up or down; ■ fades and stops; ✕ stops immediately. These manual pad fades use Manual fade duration.

**Picture fades also scale video soundtrack level.** Fading the picture down can quiet its soundtrack while playback continues. Blackout only covers the picture and leaves audio unchanged. Use Blackout when the audience should see black but still hear the video.

<!-- PAGE -->
## Projector output and blackout

### Show the external output

The video controls remain available in both application modes. The operator preview shows the program picture, including transitions, background, and blackout.

1. Keep the control window on your operator screen.
2. Click Refresh after connecting displays.
3. Select the intended external display in Output display.
4. Click Show Output. Check the real display for framing and brightness.
5. If you change the destination, click Update Output to move the presentation window.

The output fills the selected display without window borders or application controls. It preserves the picture’s aspect ratio; unmatched proportions produce unused black space. The output window remains present when you change soundboard pages, open cue settings, or switch application modes.

Close Output closes the presentation window without stopping media playback. It is useful during setup, but is not a transport Stop. Use Stop Video or STOP ALL to stop media.

### Blackout and background

Use the Blackout control or Command + Option + B to cover both the program picture and background with black. Triggering a cue while blackout is on can start playback behind the black cover. Turn blackout off when you want the current program to be visible again.

Blackout does not stop, pause, or mute media. Audio cues and video soundtrack continue. Blackout is a runtime control and is not restored as a saved project state.

Background lets you choose a PNG or JPEG to appear when no program visual is present or as the base beneath fades. Clear Background removes it. The background path is saved in the project. Stop Video and STOP ALL can leave this background visible; Blackout makes the entire output black.

### Display changes

If the output display disappears, StageCue closes the presentation window rather than moving it onto the operator screen. It also closes output if the operator control window moves onto the output display. Media can continue even though the presentation window has closed.

After reconnecting, put the controls on the correct operator screen, click Refresh, select the display, and explicitly choose Show Output again. Recheck output after any display arrangement change. The destination and open output window are not automatically restored on application relaunch.

Test your projector, adapters, macOS display arrangement, and disconnect/reconnect behavior in rehearsal. Software tests do not replace that hardware check.

<!-- PAGE -->
## Creating Cue Groups

A Cue Group launches several actions from one trigger. Actions can play audio and pictures, change levels, wait, trigger another group, or control the show. Multiple group instances may run concurrently.

### Build and assign a group

1. Open Cue Groups and click New.
2. Name the group. Choose Stop behavior and its fade duration.
3. Decide whether Automatic completion should be enabled.
4. Click Add action. Choose the action, target cue or group, Delay, and any applicable duration or level.
5. Add further rows. Use ↑ and ↓ to reorder them, Enabled to temporarily exclude a row, and Remove to delete it.
6. Click Trigger Group to rehearse. Review its state and test Pause, Resume, and Stop.
7. Close the editor with Done. Select a soundboard pad with Edit and choose the group in Assign group.
8. Save the project and rerun Preflight.

Duplicate makes a separate editable group definition. Delete removes the definition. An already running instance keeps its launch snapshot, but future references to a deleted group need repair. Group action edits take effect on the next group trigger.

### Read delays correctly

With no Wait actions, each Delay is measured from the group’s start. Several actions at Delay 0 are scheduled together. Delay 12 means twelve seconds after the trigger, regardless of earlier rows’ delays.

A Wait adds its Delay plus its Seconds duration to the time base for all following rows. Their Delay values are then measured from the end of that Wait. Reordering Wait rows therefore changes later timing. Disabled rows do not contribute to the schedule.

Actions with the same scheduled time execute in row order. Their media may become audible or visible at slightly different times because loading is not synchronized. Use short, rehearsed files when a tightly coordinated start matters.

### Settings for each action

Play cue uses the target cue’s settings unless Override cue level or Override fade-in is enabled. When enabled, the row’s dB or Seconds value supplies the override. Audio level changes clip gain; video level changes soundtrack gain. The target cue still supplies its loop setting. Group Play explicitly starts a cue; it does not toggle an already playing cue off.

Seconds applies to actions that have a duration. Merely entering Seconds does not make every action wait. Use Wait or Delay to schedule later operations.

<!-- PAGE -->
## Group action reference

Choose targets of the appropriate media type. The cue list contains media cues across all pages. Use Trigger group for a group definition.

| Action | Meaning and relevant settings |
|---|---|
| Play cue | Starts audio, video, or image; optional level and fade-in overrides |
| Stop cue | Stops the targeted media cue |
| Pause cue | Pauses targeted playback |
| Resume cue | Resumes targeted paused playback |
| Fade cue to dB | Changes an audio cue’s level over Seconds; for visuals, changes picture level within its supported range |
| Fade to silence | Fades audio to silence or the visual level to black without stopping playback |
| Fade and stop | Fades targeted media over Seconds, then stops it |
| Set bus dB | Sets the chosen audio mixer bus level |
| Cut to visual | Displays the chosen video or image with a cut |
| Crossfade to visual | Overlaps the previous and incoming visuals over Seconds |
| Fade to visual | Fades the incoming visual from black or background over Seconds |
| Video blackout | Uses Blackout on to enable or disable the black cover |
| Wait | Adds Delay plus Seconds to the time base of following rows |
| Trigger group | Starts another group when this row becomes due |
| Change page | Selects a soundboard page using its index |
| Advance sequence | Advances the loaded sequence when this row becomes due |

**Bus numbering.** Bus 1 is Music, 2 Ambience, 3 Effects, 4 Voice, 5 Stingers, and 6 Special. Set bus dB is a level change, not a timed bus fade; its Seconds field does not add a fade.

**Page numbering.** Change page uses 0 for the first page, 1 for the second, and so on. It does not stop active playback.

**Visual levels.** A visual Fade cue to dB controls picture opacity, not a separate soundtrack-only fade. A picture cannot become brighter than full opacity; positive levels are capped. Video picture fades also scale soundtrack audio. Use Play cue’s level override or the Soundtrack slider for soundtrack gain.

An Advance sequence action from an older sequence row is ignored once a newer row has taken over. A separately triggered group can advance the loaded sequence. Avoid overlapping advancement mechanisms unless their behavior is deliberate and rehearsed.

<!-- PAGE -->
## Group transport and operator overrides

### Pause and completion

Pause freezes the group’s remaining delays and its owned playback. Resume continues with the same timing relationships. These controls appear beside running groups in the group editor, group Pad Settings, and Show Mode.

Automatic completion finishes a group when its pending actions, owned playback, and dependent child groups have finished. A control-only group can complete after its final action. A looping cue, still image, held last frame, or child group with automatic completion disabled can keep a group active. Schedule an explicit stop or stop it manually when appropriate.

With Automatic completion off, the group stays active until stopped. Triggering its pad again launches another instance; it does not pause or stop the first instance.

### Three stop behaviors

| Stop behavior | Started playback | Pending actions |
|---|---|---|
| Immediate | Stops playback still owned by this group | Canceled |
| Fade and stop | Fades owned playback using the group’s stop fade duration, then stops | Canceled |
| Cancel scheduled actions only | Leaves started media playing | Canceled |

Playback survives group stop protects a started playback action or started child group from ordinary group termination. It does not allow an unexecuted action to start after the group has stopped. Emergency Stop All and Fade All and Stop affect all program playback, including survivors.

Group stop does not undo page changes, bus level changes, or blackout settings. Reset those explicitly when needed. A group pad’s ✕ stops all active instances of that group using its configured behavior; ■ forces Fade and stop using the group’s duration. Use group Stop controls rather than the media-only Stop using cue’s fade setting button.

### Ownership and conflicts

Groups stop and pause playback they started and still own. If another trigger replaces the same audio cue or shared video output, the old group no longer owns that replacement. For competing automated commands, the latest command on that resource takes precedence.

A manual pad command, gain change, page change, or video control overrides conflicting automation. Pending conflicting actions from existing execution can be skipped, including later automatic steps and child groups. Other resources continue. A fresh explicit pad or group trigger, or manual GO, authorizes new automation from the current operator state.

An Error cancels that group’s pending actions but can leave already playing media audible or visible. Inspect the error and stop the affected playback deliberately. STOP ALL is the comprehensive recovery control.

<!-- PAGE -->
## Group programming example

### The Séance Begins

Prepare ordinary pads for Existing Music, Séance Ambience, Candlelight Video, Distant Thunder, and Whispered Dialogue. Confirm their levels and media first. Then create a group named The Séance Begins.

For this example, do not insert Wait rows. Every Delay is measured from the group’s start.

| Delay | Action | Settings |
|---|---|---|
| 0 sec | Fade and stop Existing Music | Seconds 5 |
| 0 sec | Play Séance Ambience | Override level −18 dB; override fade-in 8 sec |
| 2 sec | Crossfade to Candlelight Video | Seconds 2 |
| 12 sec | Play Distant Thunder | Use the cue’s settings |
| 20 sec | Play Whispered Dialogue | Use the cue’s settings |
| 25 sec | Fade Séance Ambience to dB | −24 dB over 4 sec |

The Play cue override boxes must be enabled for the ambience row’s dB and fade-in values to take effect. For the final ambience fade, choose Fade cue to dB and enter both its level and duration.

Set the ambience cue to Loop continuously if it must continue beneath the scene. Give the candlelight video its own loop or last-frame setting. Choose Fade and stop as the group’s stop behavior and rehearse the desired group stop duration.

### Plan how the scene ends

A looping ambience keeps this group active even if Automatic completion is enabled. You can stop the group at the scene’s end, add explicit stop actions, or use a later scene group to replace or stop those cues.

The first action fades existing music that may have been started manually or by another group. That action controls the music but does not make this group its owner. Stopping The Séance Begins cancels its pending fade command if it has not run; it does not reverse a fade that already ran.

### Rehearse operator intervention

Trigger the group once. Confirm the thunder arrives after twelve seconds and dialogue after twenty. Pause before thunder, wait, then Resume and verify the remaining delay is preserved.

Next, manually adjust the ambience during the scene. Confirm that the scheduled ambience change no longer overrides your intervention. Stop the group and verify which media survives according to its settings. Finally, test Command + period and Blackout separately so you know the difference between stopping playback and covering the picture.

<!-- PAGE -->
## Creating and advancing Sequences

A Sequence is an ordered list of cues or groups for a structured show. Each row defines how the sequence advances after that row is triggered. Media from earlier rows can continue underneath later rows.

### Create a sequence

1. Open Sequences and click New. Enter a descriptive name.
2. Click Add step and name the row as the operator should see it.
3. Choose Type Cue or Group, then choose its target.
4. Choose its Advance mode and any applicable timing value.
5. Add the remaining rows. Drag rows to reorder them; Remove deletes a row.
6. Click Load for GO. Close with Done and rehearse using GO.

Duplicate creates a separate definition. Delete removes a saved definition; a loaded execution keeps its snapshot until another sequence is loaded. Edits do not change the loaded snapshot. Use Load for GO or Show Mode’s Reload / Reset to load the latest definition, which stops the previous sequence’s owned playback.

### Choose how each row advances

| Mode | When the next row is triggered |
|---|---|
| Manual | When the operator presses GO |
| Timed | After Delay seconds from the row’s trigger |
| Follow | When the row’s cue or group completes, or at its explicit Complete after time |

Timed begins counting at the trigger, not when media finishes loading. Follow with Complete after 0 uses natural completion. A positive Complete after value defines completion after that many seconds and advances without stopping the media.

Looping cues, images, held video frames, and groups that do not complete need an explicit completion rule. For persistent group playback, a later scheduled Stop or Fade and stop can provide that rule. An invalid natural Follow reports an error rather than waiting without a defined ending.

### Example opening sequence

Use rows named Curtain Closed, House Music, Opening Announcement, Curtain Opens, Theme Music, and Welcome. Each row can reference a prepared cue or group. A still Curtain Closed should normally use Manual; an announcement may use Follow; house music that loops needs Manual, Timed, or explicit Complete after.

Advancing does not automatically stop the previous row’s media. Include the intended stops or fades in subsequent groups. This lets ambience continue underneath dialogue while keeping changes deliberate.

<!-- PAGE -->
## Sequence transport reference

### GO and navigation

The first GO triggers the first prepared row. Subsequent GO presses mark the current row complete and trigger the next prepared row. GO does not resume a paused sequence; use Resume. An errored sequence requires correction and Reset or reload before continuing.

| Control | Behavior |
|---|---|
| GO | Triggers the next prepared row |
| Pause | Freezes advancement clocks, launched groups, and their owned media |
| Resume | Continues paused timing and owned playback |
| Stop | Cancels advancement and stops the sequence’s owned playback |
| Skip next | Marks the upcoming row completed without playing it |
| Back | Cancels the current row’s remaining group schedule and prepares the previous row for GO |
| Reset | Stops owned execution, clears progress, and prepares row one |
| Reload / Reset | Loads the latest saved definition and prepares row one |

### Understand Stop and Reset

GO after Stop continues with the next row. Use Reset to restart from row one. Stop and Reset affect sequence-owned groups and playback, not unrelated soundboard cues or media the operator has taken over. Playback marked to survive group termination can also continue. Use STOP ALL for a complete program stop.

After the last row completes, the sequence can show Completed while media from its rows continues. Stop or Reset can still stop media that remains owned by that sequence.

### Understand Skip and Back

Skip next does not trigger another row or stop the current media. If the current row has an active Timed or Follow rule, that rule can still advance to the next unskipped row. Pause first if you need time to change the plan.

Back prepares the preceding row but does not play it. It allows current media to continue and does not stop unrelated playback. Press GO when ready. Replaying a prior cue can replace its existing playback or the shared visual output. Other groups launched earlier can still be active; inspect the running-group list.

### Recover from an error

A missing cue or group, invalid Follow rule, or media failure sets Error and cancels advancement. Already started media may continue. Pause or stop affected groups as needed, repair the reference or file, and reload the sequence. Run Preflight and rehearse the corrected portion before resuming the show.

<!-- PAGE -->
## Show Mode

Show Mode presents the sequence for performance while retaining the soundboard. Choose Show Mode in the application header, select a saved Sequence, and confirm the next cue before pressing the large GO button.

Changing modes does not stop playback, cancel groups, or reset the loaded sequence. You can return to Soundboard for a manual cue and come back to the same execution.

### Read the performance display

| Display item | Operator meaning |
|---|---|
| Numbered cue list | The loaded sequence’s order and row names |
| Type indicators | Whether each row triggers media or a group |
| Current highlight | The row currently being handled |
| Next cue preview | The row prepared for the next GO |
| Elapsed time | Sequence execution timing |
| Countdown | Time until timed advancement or explicit Follow completion |
| Running groups | Active or errored group instances and their next scheduled event |

Natural Follow has no fixed countdown because its completion depends on playback. The same group can appear more than once when it has several running instances. Pause, Resume, and Stop beside a group act on that instance.

### Read execution states

Ready means prepared to start. Running means execution is underway. Paused means its clock and owned playback are frozen. Completed means its completion rule has been satisfied. Error requires operator review. Stopped means its schedule has been canceled.

Completed is not a universal indication of silence. A sequence can advance past a looping cue without stopping it, and survivors or manual overrides can leave media running. Check the program picture, soundboard indicators, external mixer, and group list.

### Controls available in both modes

Use the Performance menu for show commands. Open Shortcuts in Show Mode, or Configure Show Shortcuts in the menu, to customize their key assignments. The video preview and output controls remain available below either mode.

Keep the interface focused during the performance so its application keyboard commands are available. Editor sheets and file dialogs suspend ordinary pad and show shortcuts. Command + period remains the emergency shortcut even with those dialogs open.

Loading another sequence or using Reload / Reset stops the old sequence’s owned playback. Simply switching modes does not. Use that distinction when inspecting the soundboard during a running show.

<!-- PAGE -->
## Keyboard reference

Shortcuts operate while StageCue is the active application. Key repeats are ignored to reduce accidental repeated triggers. Command means ⌘ and Option means ⌥ on a Mac keyboard.

### Project and soundboard

| Command | Shortcut |
|---|---|
| Open project | Command + O |
| Save | Command + S |
| Export project | Command + Shift + E |
| Trigger pads 1 through 9 | Option + 1 through Option + 9 |
| Selected pad fade up | Option + Up Arrow |
| Selected pad fade to silence or black | Option + Down Arrow |
| Selected pad stop | Option + X |
| Selected pad fade and stop | Option + Shift + X |
| Fade All and Stop | Command + Shift + F |
| Emergency Stop All | Command + period |

Assign shortcuts for any of the 32 pads in Pad Settings using Trigger shortcut. Each page can use its own letters or digits. A key must be unique within that page; X is reserved for selected-pad stop. Pads above 9 have no default assignment. Selecting None disables that pad’s shortcut. Swap leaves shortcuts at their positions.

### Default show commands

| Command | Shortcut |
|---|---|
| GO | Command + Option + G |
| Pause or Resume sequence | Command + Option + P |
| Stop sequence | Command + Option + S |
| Skip next | Command + Option + ] |
| Previous row prepared for GO | Command + Option + [ |
| Emergency Stop All | Command + Option + period |
| Toggle Video Blackout | Command + Option + B |

Configure show commands in Shortcuts. Their modifiers remain Command + Option; choose a distinct offered key for each command or None to disable it. Assignments are saved with the project. The separate Command + period emergency shortcut cannot be disabled.

Ordinary pad and show shortcuts are suspended in editor sheets and modal dialogs. Command + period still stops everything. Text fields finish editing with Return or an outside click; Escape specifically cancels project-title editing. Option-click resets audio clip, bus, and MASTER gain to 0.0 dB.

<!-- PAGE -->
## Performance checklist

### Before rehearsal

1. Open the intended project and verify its title. Keep a named backup and all media available locally.
2. Check the Mac’s audio destination and the external mixer’s input route. Confirm both an audio cue and a video soundtrack reach the intended speakers.
3. Check the operator and projector displays are extended. Select the correct Output display and use Show Output.
4. Run Preflight. Repair missing files, missing cue or group references, invalid pages, and group cycles. Rerun it after edits.
5. Confirm pad shortcuts and Show shortcuts for this project. Test Emergency Stop All with safe test media.

### Rehearse the show

1. Play overlapping audio cues and check the combined level. Test loops, retriggers, automatic fades, and manual fades.
2. Check video cuts, crossfades, fade from black, stills, backgrounds, and held final frames on the projector.
3. Verify Blackout covers the picture while intended audio continues. Confirm STOP ALL can leave a background visible.
4. Trigger every group. Check delays, ownership, survival settings, pause timing, and all intended stop behavior.
5. Load the latest sequence definition. Check Manual, Timed, and Follow rows, especially loops, stills, and held frames.
6. Test manual overrides, Skip, Back, Stop, and Reset with representative media. Confirm no unexpected earlier media remains.
7. Run a full rehearsal long enough to reveal output, memory, and timing issues on the actual Mac and hardware.

### Immediately before the performance

1. Save the named project. Confirm there is no save error.
2. Select the starting page and load the intended sequence. Confirm its first and next rows.
3. Set initial clip, bus, MASTER, and soundtrack levels. Check the background and blackout state.
4. Ensure no rehearsal groups or media are still running. Use STOP ALL if needed, then prepare the intended starting picture.
5. Keep power connected, prevent sleep, close unnecessary demanding applications, and leave StageCue focused.

### After the performance

Stop all program playback and close the output window. Save any intended changes to the named project. Back up the project and media together. Record any cue timing or hardware issue so it can be reproduced before the next show.

Preflight checks media and references; it does not preload every cue for instant playback or certify external hardware. A clean result still requires a listening and visual check.

<!-- PAGE -->
## Troubleshooting

### A cue cannot find its file

Check whether the file or containing folder moved, was renamed, or is on a disconnected drive. Select the pad and use Browse to relink it. Save, rerun Preflight, and trigger it in rehearsal. If a group says Missing cue, reselect its target; a new pad with the same name is a different cue.

### Playback starts but there is no sound

Check the Mac’s output device, hardware mixer, Clip level, assigned bus, and MASTER. A cue faded to silence is still playing; use ▲ to restore it if it has not ended. A video soundtrack has its own level and bypasses the audio mixer. Blackout does not mute audio, but video picture fades can attenuate soundtrack audio.

### An audio file is rejected as too large

The limit applies to decoded audio, not the compressed file size. This build allows up to 512 MiB decoded per audio clip and has a 1 GiB combined active and reserved audio budget. Roughly 23 minutes of stereo 48 kHz float audio reaches the per-clip limit. Trim or split the material, reduce simultaneously active clips, or use an appropriate native-decodable file. Silent loops still occupy playback resources.

### The projector is black or missing

Check Blackout first. Confirm a visual is playing, the correct display is selected, and Show Output has been used. Use Refresh after reconnecting. Keep controls on a separate screen. Stop Video can leave only the background; a manually faded picture can remain black while its media continues.

### A group or sequence stays active

Check for looping media, an image, a held final frame, or Automatic completion turned off. Provide a scheduled stop or an explicit Follow completion time. Manual overrides can remove automation’s ownership or suppress a scheduled command. For a group, inspect its pending events and stop rules; for a sequence, use manual GO when appropriate.

### Shortcuts do not respond

Bring StageCue to the foreground, close editor sheets or dialogs, check the current page and selected pad, and verify project-specific assignments. GO does not resume a paused sequence. Command + period remains available in dialogs.

### A save or media operation reports an error

Read the status message; do not assume the operation succeeded. Check destination permissions, free space, and file availability. Keep the existing working project and media. Repair the problem and retry. If timing slips under load, stop competing tasks and rehearse; StageCue does not guarantee exact synchronized media starts.

<!-- PAGE -->
## Limits and terminology

### Current limits

| Item | Limit or behavior |
|---|---|
| Soundboard | 32 pads per page; up to 32 pages |
| Audio | Mono or stereo playback; stereo 48 kHz engine; six virtual buses |
| Audio memory | 512 MiB decoded per clip; 1 GiB active and reserved budget |
| Video | MOV and MP4 with native-supported codecs; maximum dimension 4096 pixels |
| Images | PNG and JPEG; maximum source area 33,554,432 pixels; downsampled to maximum dimension 4096 |
| Visual output | One program; 30 fps SDR rendering; no separate video programs |
| Groups | 256 definitions; 512 actions per group; 128 live instances; nesting depth 32 |
| Sequences | 256 definitions; 1,024 steps per sequence |
| Project file | JSON schema 3; maximum 2 MiB |

Initial decoding and video readiness can delay visible or audible starts. Scheduling uses a monotonic clock, but commands and fades can be delayed by a busy interface thread. It is not sample-accurate or frame-accurate synchronization. Loop boundaries are not guaranteed gapless. Sleep or suspension can cause elapsed scheduled deadlines to become due on resumption.

External-interface listening, projector quality, display reconnection, macOS Spaces, and long performance endurance need testing on your own hardware. The current build has automated playback and scheduler coverage, but that does not certify a venue setup.

Video soundtrack does not pass through the audio buses or MASTER. There is no built-in physical multichannel bus routing, media preloading, recording, streaming, cloud synchronization, MIDI, OSC, DMX, network show control, physical Stream Deck integration, or advanced video editing. There is no page deletion or general undo interface.

### Terms used in this manual

**Cue** is a saved media assignment with playback settings. **Pad** is its soundboard position. **Bus** is a software audio mixing group. **Group definition** is the saved action list; a **group instance** is one running trigger of it. **Sequence** is a prepared ordered list. **Ownership** determines which playback an automation instance may pause or stop. **Follow** advances when a row satisfies its completion rule. **Blackout** covers the output picture while playback continues.

This edition was checked against StageCue 0.3 build 3, source commit b292340. Keep the manual with the matching application and update it when controls change.
