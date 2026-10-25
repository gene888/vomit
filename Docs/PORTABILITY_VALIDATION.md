# StageCue 0.4 validation

## Baseline and milestones

Baseline 0edf90f is preserved by local annotated tag v0.3. Development uses feature/project-portability-0.4. Existing remote branches and tags are not changed. Baseline native test run: 88 tests in 11 suites passed in 11.719 seconds. Baseline Xcode Release build passed.

0.4A commit 5225872: schema 4, relative serialization, deduplicated manifest, streamed fingerprints, transactional portable folders. Release Xcode build and five focused portability tests passed.

0.4B commit 6a9d62a: actor-based folder recovery, fingerprint confidence, bounded cancellable Spotlight queries. Release Xcode build and eight focused portability tests passed. Tests found and corrected path assertions involving macOS /var and /private/var aliases; containment assertions now use canonical media paths.

0.4C commit aa108c6: open/save migration, manifest-aware preflight, missing-cue guards, UTI, and real media relocation playback. Release Xcode build passed; 98 tests in 12 suites passed in native context in 11.774 seconds.

0.4D adds staged media management, Apply/Cancel protection, progress and export cancellation, explicit save/export options, Finder document registration, report access, and operator guidance. Final Release Xcode build succeeds. All 102 tests in 12 suites pass in 11.645 seconds; native runner exit 0. This includes the application-level portable export/open flow after deleting the source root. Package evidence accompanies the deliverable.

## Relocation acceptance evidence

Tests create separate temporary trees representing Users/Alice and Users/Bob. They export in Alice, copy the entire portable folder into Bob, delete Alice's source and exported tree, and open Bob's Project.stagecue. Assertions verify paths under the new tree, preserved IDs/settings/groups/sequences, unique shared asset records, byte identity, no Alice references in exported JSON, and a readable manifest.

A native test generates actual WAV, H.264 MP4 and PNG assets, includes a shared background, and repeats the same export/copy/delete/open procedure. It plays relocated audio through offline AVAudioEngine rendering and relocated image/video through VideoEngine, confirming audio remains active across the visual change. This is not just reopening at the export location.

Other tests cover relative-first lookup over an existing source location, same-name/same-size wrong-content rejection, folder-only recovery with no Spotlight provider, ambiguous legacy candidates, disconnected-drive references, schema migration without rewriting the original, unsupported manifest versions, distinct same-name exports, shared cue references, cancellation before export, interruption at the second file, injected out-of-space failure, preservation of original bytes and existing destinations, traversal and symlink escape rejection, reopening after relinking, staged manual confirmation, stale Apply rejection and canceled model operations. All original audio, video, group, sequence, emergency and mode-continuity suites remain enabled.

## Build and test environment

Xcode's macro helper cannot launch its nested sandbox from the restricted shell. The build succeeds with the compiler-plugin flag OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'; this is a build invocation option, not an application security entitlement change. A normal user Xcode session can use the regular build script.

The restricted command-line test process cannot instantiate system audio components. Scripts/prepare-native-tests.sh builds the tests and native validation app; launch that app and read work/native-tests.log and work/native-tests.exit. The runner now supports both observed SwiftPM bundle layouts and includes the current Xcode XCTest support library path. Only an actual completed exit 0 and passed test report count as success.

The Xcode-built Release application launched and its Media sheet was inspected with the existing 26-asset show, all assets available. The sheet's counts, filter, candidate/locate controls, Apply, and Cancel are present and readable; Cancel returned to the soundboard. No show media was triggered or manually relinked during this inspection. A separate standalone UI harness crashed in an existing MainActor.assumeIsolated audio timer callback on macOS 27.0.1 in both unoptimized and optimized builds; the Xcode Release app did not reproduce that failure. Production audio/video engine source is preserved. Use the Xcode-built app for this iteration; standalone UI harness compatibility needs further investigation.

## Remaining physical acceptance

Two actual Macs, AirDrop/removable-drive transfer, physical listening/projector output, permission-denied destinations, real low-disk conditions, Spotlight index availability, device/display reconnection, and a long live-show soak remain hardware/operator acceptance. Automated tests simulate different user roots and an out-of-space error; they do not claim to replace those checks. A power failure can leave a hidden staging folder, but no success is reported until the final rename and verification. No main-branch merge or push is part of this iteration.
