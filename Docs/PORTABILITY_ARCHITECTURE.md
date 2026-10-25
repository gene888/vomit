# StageCue 0.4 portability architecture

## Inspection and baseline

Development branch: feature/project-portability-0.4. The local annotated v0.3 tag preserves 0edf90f, including the operator manual. No existing branches or tags are replaced.

Schema 3 stores cue.filePath and backgroundPath as absolute strings. ProjectStore reads/writes bounded JSON; ProjectWriter serializes atomic saves. ShowState owns Open, Save, Export and autosave. All soundboard pages supply stable cue IDs to groups/sequences, so indirect references ultimately reach ordinary media cues. Audio and visual loaders consume local paths. No persistent bookmarks or asset registry exist. The application is not sandboxed.

The baseline Xcode Release build succeeds with OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' in the restricted build environment, where the compiler macro helper cannot launch its own sandbox. The ordinary command-line audio tests need native application context. Baseline and milestone outcomes are recorded in PORTABILITY_VALIDATION.md.

## Plan and boundaries

1. **0.4A** introduces schema 4, shared manifest records, relative-path serialization and resolution, and transactional portable-folder export. A portable folder contains Project.stagecue, Media/Audio, Media/Video, Media/Images, and MediaManifest.json. An ordinary .stagecue or .json file may continue referencing external files. Exporting does not change the active document or its save destination.
2. **0.4B** adds a UI-independent asynchronous resolver. Relative paths take priority; valid existing paths, designated project folders, operator-selected folders, and bounded Spotlight queries follow. SHA-256 fingerprints are streamed, never whole-file loaded. Identity conflicts are unresolved or offered for explicit review. No filename-only automatic relinks.
3. **0.4C** reports unique assets, availability, automatic recovery, missing and ambiguous matches, shared cue/background uses, and expected metadata. Legacy files migrate in memory; explicit Export creates a new copy. Missing media does not block opening.
4. **0.4D** provides one Media management sheet with staged candidate decisions, folder and Spotlight searches, manual locate, apply/cancel, portable export progress/cancellation and preflight report access. Playback engines and show scheduling remain intact; relinking changes future playback references.

The runtime retains absolute playable paths. ProjectStore serializes relative paths only when media lies within the destination project folder; paths outside that folder stay absolute. Every load rebases relative paths against the actual opened document, not the original home directory. Autosave receives resolved paths so its separate directory does not accidentally become the media root. Manifest asset IDs and cue/group/sequence IDs survive packaging and relinking.

Export collects all media cues across all pages plus the background. Group and sequence media is included through its referenced cue IDs. Duplicate files use a single content fingerprint record/copy; distinct files with the same name get different safe destinations. Source files are never moved or changed. Copy to a hidden sibling staging folder, verify copied bytes and the reloaded project using that staging root, then publish with a same-volume rename. Reject existing destinations, missing/changed media, unsafe relative paths and symlinks escaping the package. Failure/cancellation removes staging and leaves the working project and destination intact.

## Acceptance tests

Use separate temporary trees simulating /Users/Alice and /Users/Bob, export under Alice, copy the entire package under Bob, then remove Alice's source and export trees before opening Bob's copy. Assert every media reference lies under Bob, cue settings and stable IDs survive, duplicate media is collected once, and generated audio/video/image fixtures still load and play. Also test folder-only recovery with Spotlight absent, ambiguity, incorrect same-name candidates, Unicode, missing drives, legacy import, cancellation, copy failure, traversal and symlink rejection, reopen after relinking, and source preservation.

Physical Mac-to-Mac transfer and venue hardware remain operator acceptance checks. No external-display identifier is currently persisted in 0.3; portable media cannot reproduce a hardware display arrangement on a different Mac. Select the intended display at the destination.
