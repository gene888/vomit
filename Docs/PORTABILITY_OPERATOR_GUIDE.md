# StageCue 0.4 project portability and media management

This guide updates the project, export, and media instructions in the StageCue 0.3 Operator Manual. Existing soundboard, mixer, fade, video, Cue Group, Sequence, Show Mode, and emergency controls remain available.

For 0.4.1, also read [Persistent video hold](PERSISTENT_VIDEO_HOLD.md): FADE AUDIO and Command-Shift-F affect audio only; the combined fade remains explicitly labeled Fade All Media & Stop in the Performance menu.

## A project file and a portable production are different

A **project file** (.stagecue or older .json) contains show settings and references to media. Files may remain anywhere on the Mac, including an external drive. Saving a project does not copy its media. Sending this file alone does not send the production's media.

A **portable project folder** contains the project, a versioned media manifest, and copies of all referenced media, including the background and media targeted through groups and sequences on every page. Copy the entire folder to the other Mac. The project uses relative references within that folder, so it does not depend on the original username, home directory, drive name, or export location.

## Choose the right save or export operation

| Operation | Result | Media copied |
|---|---|---|
| Save Project | Updates local autosave and the current named project destination, if one exists | No |
| Export Project Only | Chooses a new .stagecue destination and records media identity metadata for recovery | No |
| Export Portable Project | Creates a new self-contained folder and verifies its copied media and project references | Yes |

The header has Open, Save, an Export menu, and Media. The File menu also offers the project operations, Relink Missing Media, and View Media Preflight Report. Command-S remains Save; Command-Shift-E selects Export Project Only.

**First named save.** Use Export Project Only if you have not chosen a named file destination. Save without such a destination updates only local autosave. Ordinary edits update autosave; explicitly Save to update the named file.

**Older projects.** Versions 0.1 through 0.3 open without rewriting their original files. References and cue IDs are preserved; missing files do not prevent opening. Use Export Project Only to save a new 0.4 copy. Keep the old application and original project for rollback. Version 0.4 uses schema 4 and a separate autosave-v0.4.json; on first use it can restore the previous 0.3 autosave without overwriting it.

## Move a complete production

1. Open the intended project. Run Preflight and repair unresolved files or show references.
2. Choose Export > Export Portable Project. Enter a **new folder name** at the destination. Existing folders are never replaced or merged.
3. Watch progress in the status area. You can cancel a long operation. Do not transfer the folder until the application reports that the portable project was verified.
4. Copy the **whole portable folder** using Finder, AirDrop, an external drive, or ordinary file sharing.
5. On the destination Mac, open StageCue 0.4 and choose Open. Select Project.stagecue inside the copied folder. Finder can also associate .stagecue files with the application.
6. Open Media and check the asset report. Run Preflight, then test actual playback, mixer routing, and projector output on the destination hardware.

Typical contents:

```text
My Show Portable/
    Project.stagecue
    MediaManifest.json
    Media/
        Audio/<asset identifier>/Opening Theme.wav
        Video/<asset identifier>/Curtain.mp4
        Images/<asset identifier>/Background.png
```

Asset subdirectories prevent collisions between different files with the same name. Byte-identical files of the same media type are collected once even when many cues use them. Playback settings, cue IDs, pages, groups, sequences, and show shortcuts remain in the project. Source files are copied without transcoding, moving, or deleting them.

Portable export does not switch the active show to the exported copy or change its Save destination. Open the exported Project.stagecue explicitly if you want to edit that copy. Saving that opened copy updates its project file; it does not recollect new external files. Export a new portable folder whenever you need a newly self-contained production after adding outside media.

## Resolve missing media

On opening, StageCue checks project-relative references first, then valid existing locations and supported bookmarks, the project Media directory, and Spotlight. File searches and fingerprinting run away from the interface thread. The app checks accessibility; an indexed result alone is not enough.

Open **Media** for the unique asset count, Available, Automatically Relinked, Missing, and Ambiguous Matches. Each row shows its expected filename, location, type, and shared cue references. Filter by filename or original location to work through a large show.

1. Choose **Relink Missing Media** or **Locate Media Folder**. Select a replacement folder; StageCue searches it recursively for all missing assets.
2. If helpful, choose **Search with Spotlight**. Spotlight may be disabled, unindexed, or unable to access a file. Folder-based recovery works without it.
3. Review candidates. Exact content fingerprints are reliable enough for automatic recovery. A matching name and size with different contents needs explicit confirmation. Filename-only legacy candidates are never silently accepted.
4. Choose **Use This File** for an offered candidate, or **Choose File** for a different file. An explicit choice may accept changed content after media-type validation. Associated cues update together. The chosen file's containing folder is also searched for other missing media.
5. Click **Apply Reliable Matches and Choices** to keep the staged changes, then Save Project. You can apply the resolved assets while leaving others unresolved.

**Cancel** closes the Media window without applying staged changes. Cancel Operation stops a search or copy operation. A copy already completely published remains valid; incomplete exports are cleaned up and never presented as successful portable folders.

If the project changes while the Media window is open, Apply refuses to overwrite those edits. Cancel and reopen Media against the current show. Apply staged choices before exporting a portable folder from the active project.

## Read preflight and unavailable cue indicators

Preflight now checks asset identity as well as the existing native audio/video/image validation and show references. Its dialog provides direct access to the Media report and relinking window. Missing, changed, or unverified assets are marked with a warning on their pads; affected triggers report an error while accessible cues remain usable.

Save does not replace source media. Moving a pad with Swap retains its cue ID, so groups, sequences, and shared asset associations continue to refer to it. Clearing or replacing a cue deliberately changes its media association; repair any deleted cue references in groups or sequences.

The project JSON is the authoritative saved media registry. MediaManifest.json is an export-time inventory for inspection; saving subsequent edits in the portable copy updates Project.stagecue, not this inventory snapshot. Re-export for a new fully verified portable production.

## Practical limits and destination checks

- Hashing and verifying large videos reads their bytes in bounded chunks; it can take time and storage bandwidth. It does not load whole files into memory for identity checks. Do large exports between performances.
- Folder searches are limited to 100,000 entries per selected root and skip hidden entries, packages, and symlink descendants. Choose a narrower or directly accessible folder if necessary. Searches primarily find the expected filename; locate renamed files explicitly.
- Spotlight searches cover at most 512 distinct filenames and 5,000 returned candidates, with an eight-second wait. Unindexed media is recoverable through folder search. Candidate lists show up to 100 review entries per asset.
- Legacy files that were already missing have no known content fingerprint. Select their replacements explicitly; subsequent saves retain fingerprints for future recovery.
- External display IDs and audio hardware arrangements are specific to each Mac. The earlier build did not persist a display destination; select the correct output display and macOS audio interface after moving. Video soundtrack still bypasses the audio buses and MASTER.
- Existing playback format, decoded audio memory, 30 fps SDR visual output, scheduling, and project-size limits remain. Portable export verifies copied bytes and project references; Preflight and rehearsal remain necessary to check actual decoding and performance.
- The application remains unsandboxed and ad hoc signed. Security-scoped bookmarks are supported where available; enabling App Sandbox would require a broader lifetime/access review. It is not a notarized distribution.

## Transfer acceptance check

For a meaningful rehearsal, copy the portable folder to a genuinely different parent directory, make the original media location unavailable, and open the copied Project.stagecue. Confirm every asset connects without relinking and play representative audio, video, and stills. Merely reopening the export beside its original media does not prove portability.
