# StageCue 0.5D — Shared PCM ownership and project capacity

Branch: `performance/resource-efficiency-0.5d`. Baseline 0.5C: `e9d91fb`; baseline instrumentation: `a754702`. Version 0.5.3, build 9. No main merge or GitHub push. Schema remains **4**, media manifest remains **1**.

## What changed

Concurrent audio voices referencing one unchanged local file now share one immutable decoded PCM allocation. Each voice still owns its own AVAudioPlayerNode, mixer, gain stage, position, loop state, envelope, routing, pause state and completion token. The six buses, master, 0.5A mixer path, 0.5B presentation relay and 0.5C two-slot native video looping are preserved.

There is **no strong inactive cache**, streaming engine, preloader, transcoding, project schema change or scheduler change. This is in-use allocation sharing. After every voice, scheduled callback and native owner releases a buffer, it can be deallocated. Retriggering after that point decodes again. Quickly retriggering while a previous native schedule is retiring can reuse the still-live immutable PCM.

Project JSON capacity increases **2→16 MiB**, with an accurate capacity error. File size is checked before reading; reads themselves stop at the limit plus one byte, protecting against a file growing after the metadata check. Encoding remains bounded before atomic replacement. Existing normalization, media-manifest validation, traversal/symlink protections, migration, bookmarks and portable references remain in place.

## Ownership and memory budget

- The existing serial MediaLoader actor performs file inspection and synchronous decode. Its non-suspending decode section reserves bytes before allocation. Queued callers do not allocate until they enter this actor; they cannot bypass reservations by cancelling a MainActor task.
- A weak reuse index identifies live PCM by local device/inode, file byte size, nanosecond modification **and change** times, frame count, native processing format and channel-layout tag. Canonical/symlink paths resolve to their local target. No content hash is computed per trigger. Different files with identical bytes remain distinct assets unless they are aliases of the same filesystem object.
- File stamps are checked before opening, after opening and after decoding. Replaced/relinked/modified media receives a new identity. Old voices keep their original immutable audio; the next trigger loads the new generation. Metadata checks do not provide atomic editing semantics for a file being continuously rewritten externally.
- `LoadedMedia` owns PCM strongly. Its buffer is file-private and has no cross-file sample mutation API. Each Voice retains its own LoadedMedia reference, and the schedule completion closure retains it through completion/stop retirement.
- A separate weak allocation ledger follows the **AVAudioPCMBuffer object itself**, including a possible native owner outliving its LoadedMedia wrapper. It is keyed by PCM object identity, preventing a recycled wrapper address from hiding an old allocation. Lookup eviction cannot erase live allocated PCM from budget accounting. A native-retained buffer can be rewrapped without copying its samples.
- The **512 MiB per-clip** and **1 GiB unique-live-plus-reserved PCM** limits remain. Unique buffers are charged once, not once per voice. Per-voice graph nodes, native decoder/framework allocations, graphics and the process heap are outside this logical PCM budget.
- Only weak lookup/allocation records remain when media is idle; dead records are pruned on the next lookup/snapshot. No PCM survives merely because it was triggered earlier. Explicit reuse-index invalidation does not affect a voice or native schedule that still owns its PCM.

The loader's snapshot distinguishes unique live bytes/buffers, outstanding reservations, peak charged bytes, hits, misses, successful reads and budget rejections. Active-only `decodedBytes` is kept separate from the authoritative loader ledger, which may also contain retiring native buffers. Per-voice referenced bytes and graph nodes are recorded separately. Inactive cache bytes are **zero by policy**, rather than an unmeasured LRU cache. Serial decode reservations may be too brief to appear in an asynchronous snapshot; deterministic cancellation tests and peak accounting exercise them.

Preflight still validates decoding; it does not arm or retain an inactive buffer cache. Its combined-memory warning counts unique source identities, avoiding repeated charges for the same file. A serial decoder's in-progress read remains non-preemptible; cancellation is checked before reading, after reading and before publication. Stale cue tokens still prevent cancelled work from creating a voice.

## Long-form policy

Full-file decoding remains. At 48 kHz stereo Float32, 60 seconds costs 23,040,000 bytes (21.97 MiB), one hour costs about 1.29 GiB, and the 512 MiB clip limit corresponds to about 23 minutes. A compressed MP3's on-disk size is not its decoded size.

Sharing removes multiplication when several voices use one bed. It does not make an over-limit source playable or reduce memory for genuinely different sources. 0.5B introduced no preparation/cache or streaming system to extend. Streaming would need separate validation of read-ahead, underruns, looping seams, fades, seeks, sample-rate conversion, simultaneous cues, cancellation and scheduling. It is deliberately deferred.

## Capacity policy and errors

The original store used size checks both before/after reading and before writing; it did not inspect free disk capacity. Those checks function as input-allocation/round-trip guards. The original commit contains no deeper documented rationale for choosing exactly 2 MiB. Treating its save threshold as disk exhaustion was incorrect.

16 MiB provides eight times the prior encoded capacity, with room for measured large productions containing 1,024 cues/assets, long relative paths, automation and bookmarks. It remains a finite encoded-input bound. Existing model-count normalization is independent; 16 MiB does not promise that every theoretical combination of maximum group/sequence counts and arbitrarily long metadata will fit. JSON decoding still materializes an object graph, so process memory can exceed encoded bytes; sampled measurements and limitations are reported below.

Errors distinguish:

- Supported project-size capacity exceeded, on both read and write.
- Malformed/incompatible field data.
- Unsupported project version or media-manifest version.
- Serialization failure, such as nonfinite media metadata.
- Real filesystem/access errors, preserved as their native error rather than relabelled “capacity.” Actual disk-full failures from atomic file writing remain disk-full errors.

A failed oversized save preserves the prior file. No data format or media placement changed. Older builds still enforce their 2 MiB ceiling: a larger 0.5D file needs 0.5D or newer even though its schema is unchanged. Ordinary project files may reference media anywhere; portable folders still collect everything required elsewhere.

## Method and archived evidence

Measurements use the same Apple M4 Pro / 64 GiB Mac, optimized arm64 Release `-O`, native AppKit host, actual MainView and opt-in instrumentation as prior milestones. The matched resource matrix repeats eight voices on one 60-second stereo WAV and eight distinct WAV files twice, followed by twenty stop/start cycles. It records actual decode-read events, unique media identities/bytes, per-voice bytes, nodes, process physical footprint/resident memory, batch load/graph time, first nonzero main-mixer render timestamp and CPU (% of one core). This is not a physical speaker or input-device latency measurement.

Project fixtures contain 32, 256 and 1,024 cues; hundreds/1,024 unique asset records; long paths; 64×32 group actions; 16×64 sequence steps; and up to 2,048 bookmark bytes per asset. Exact encoded fixture sizes are 111,530; 1,627,329; 2,752,399; 3,478,415; and 5,575,567 bytes. The largest three exceed the old cap. All direct JSON round trips already worked before the store change; the old store rejected these larger documents at save time.

The store canonicalizes media-relative metadata on save. Consequently the baseline's literal `roundTripEqual` flag is false where an optional relative path was added; this does not represent lost cues or media. Current `restorationEquivalent` compares against that existing canonical form. Tests assert complete settings, IDs, actions, sequence rows, bookmarks and resolved paths.

A 5 ms background sampler records approximate capacity-operation memory peaks in the final run. It can miss shorter peaks; the baseline recorded before/after parsing snapshots, not sampled peaks, so no fictitious baseline-peak comparison is made. Project work is performed after audio stops. Process measurements include test libraries, UI and native caches, not just JSON or PCM allocations.

`Docs/Performance/0.5D-baseline` preserves the unchanged build, 118-test result and raw measurements. `0.5D-first-pass` preserves the initial implementation measurement and its 131-test result. The final pass adds direct native-PCM retirement accounting and a dedicated lifetime test. Raw timing and resource data are retained, including unfavorable results.

## Before/after results

Two repetitions per audio scenario; values below are medians of those two observations, not a statistically strong P95 estimate. CPU includes the same output tap and independent fade exercise. The same-file PCM reduction is exact for these fixtures: **184,320,000→23,040,000 bytes, 87.5% less** (175.78→21.97 MiB). Eight independent files still allocate 184,320,000 bytes.

| Metric | 0.5C baseline | 0.5D |
|---|---:|---:|
| Same source: decoded reads / unique buffers | 8 / 8 | 1 / 1 |
| Same source: voices / graph nodes | 8 / 40 | 8 / 40 |
| Same source: process footprint | 261.81 MiB | 107.44 MiB |
| Same source: resident memory | 341.60 MiB | 187.37 MiB |
| Same source: CPU (% of one core) | 17.89 | 18.20 |
| Same source: all eight loads/graphs ready | 232.16 ms | 207.25 ms |
| Same source: first nonzero mixer render timestamp | 170.42 ms | 175.10 ms |
| Eight distinct files: unique PCM | 175.78 MiB | 175.78 MiB |
| Eight distinct files: process footprint | 261.70 MiB | 261.20 MiB |
| Eight distinct files: resident memory | 339.88 MiB | 339.45 MiB |
| Eight distinct files: CPU (% of one core) | 18.23 | 18.04 |
| Eight distinct files: all loads/graphs ready | 211.41 ms | 220.67 ms |
| Eight distinct files: first mixer render timestamp | 151.82 ms | 161.35 ms |
| Nodes after stop | 16 | 16 |
| Unique live/retiring PCM and reservations after stop | 0 in old active counter | 0 in actual PCM ledger |

This is principally a memory improvement. Batch onset did not improve; the distinct-file load/onset observations were about 9–10 ms slower in this small sample. No general latency improvement or sample-aligned triggering is claimed. Existing independent play/fade/stop behavior is checked against real offline PCM. Per-voice referenced bytes still total 175.78 MiB in the shared scenario, while allocated unique PCM is 21.97 MiB. Hits are seven per same-file batch; misses/reads are one. Distinct-file batches have eight reads. Cache snapshots and per-case counters are retained in raw data.

Twenty start/stop cycle samples returned to zero active PCM and 16 permanent graph nodes; the actual PCM ledger was additionally checked after each eight-voice case and at final stress cleanup; raw process snapshots are retained to expose any heap high-water effects. The finite 60.016-second AV/show-control stress kept four voices / 28 audio nodes, a three-replica looping video and a timed Cue Group sequence (step 29 reached). It reported no audio/video errors. CPU was 89.27% of one core. Its 550 real mixer-command costs were **0.0639 / 0.1070 / 0.1607 ms median/P95/max**. This differs from the 0.5A dense-command workload; it is not a new matched 0.5A speedup claim. Stop returned unique PCM, reservations and video items to zero, with 16 permanent audio nodes.

### Short-cue responsiveness

The focused existing 0.5B native harness ran 20 normal direct-engine short-cue trials with the real operator UI, plus 20 diagnostic publication-suppressed trials. Normal **rendered** onset was **53.34 / 55.72 / 56.54 ms median/P95/max**. The historical 0.5B direct-engine reference was **52.29 / 54.98 / 55.45 ms**. This is a separate-run reference, not a new matched 0.5C short-cue baseline; the approximately 1 ms difference is exposed rather than described as a speedup. It provides no evidence of a material loss of the earlier responsiveness gain, but is not a hard real-time guarantee.

The suppressed diagnostic was 53.46 / 57.17 / 57.67 ms. No `loader.shared.hit` events occurred in these separated trials: they decoded afresh after stop, as intended with no inactive cache. There were no audio/video errors; the corrected final probe recorded **16 nodes, zero unique PCM and zero reservations after explicit stop**. Physical input delivery and speaker buffering are excluded.

The first probe's onset measurements are also preserved. Its old helper branch labelled the still-playing final cue as “audioNodesAfterStop” (19 nodes) without actually stopping it. The helper now stops and waits for retirement before recording this field; the confirmation returned 16. This was a profiling-label/setup defect, not evidence of a three-node app leak.

### Project capacity

Each row is one measured fixture, with timings in milliseconds. Save/load include the existing path canonicalization and validation. Parse/normalize are measured separately on the encoded JSON. Peak columns are **5 ms sampled total-process peaks**, not exact allocation counts; the baseline had no equivalent peak sampler.

| Cues / unique assets | Bookmark bytes/asset | Encoded bytes | Before | 0.5D save / load | Parse / normalize | Sampled peak footprint / resident MiB |
|---|---:|---:|---|---:|---:|---:|
| 32 | 0 | 111,530 | Supported | 2.86 / 6.21 | 1.00 / 0.03 | 85.92 / 164.22 |
| 256 | 0 | 1,627,329 | Supported | 22.90 / 49.70 | 11.40 / 0.36 | 104.95 / 183.23 |
| 1,024 | 0 | 2,752,399 | Rejected as disk full | 56.69 / 166.73 | 18.34 / 0.71 | 118.09 / 196.38 |
| 1,024 | 512 | 3,478,415 | Rejected as disk full | 57.79 / 167.42 | 19.07 / 0.71 | 132.49 / 210.80 |
| 1,024 | 2,048 | 5,575,567 | Rejected as disk full | 63.07 / 172.20 | 20.46 / 0.70 | 164.69 / 242.98 |

All five final fixtures restored correctly against canonical saved metadata. For the already-supported 32/256 cases, baseline save/load was **2.62/6.55 ms** and **21.72/49.11 ms** respectively. Schema 4 and original cue/media/group/sequence IDs survive. Exact 16 MiB input/output boundaries and oversized/malformed cases are covered separately in tests, not extrapolated from the five profile sizes.

### Measurement correction

The original baseline started with no resource-test autosave. Early repeated runs inadvertently restored the previous test autosave, causing background media resolution and a roughly 45–50 MiB idle host offset. Those **diagnostic** datasets are preserved in `0.5D-first-pass` and `0.5D-reused-autosave-diagnostic`, and are excluded from this matched table. The final harness deletes only its own isolated `work/PerformanceBaseline/resource-autosave.json` before constructing ShowState. Baseline/final idle footprint before the first batch is then **79.44/78.97 MiB**, respectively. The correction changes the measurement setup, not the application's source-cache behavior. Old unfavorable observations were not silently removed or attributed to the PCM cache.

## Validation and reproduction

The baseline Release build succeeded and all 118 tests passed. The final optimized build succeeds, the packaged 0.5D app launches with the expected interface, and **132 tests in 16 suites pass (31.802 seconds)**. Added tests cover shared identities and eight-voice single-buffer budget admission, independent PCM positions/gain/pause/fades/buses, one-shot completion without stopping a shared loop, eviction while playback continues, unique-file budget rejection, same-size edits with restored modification time, symlink identity, cancellation during a reserved decode, mutation during decode, actual project replacement, engine configuration restart, shutdown and native PCM outliving its wrapper.

Capacity tests cover a production over 2 MiB with 1,024 assets, exact 16 MiB acceptance, one-byte-over rejection on read/write, prior-file preservation, malformed/future/serialization/access error distinctions, legacy formats, and a portable package moved between different directory roots with the source removed. Existing audio/video/show-control/portability regressions remain enabled. Two original budget-rejection tests now use distinct physical files; separate tests verify the newly intended same-file sharing behavior.

```sh
Scripts/prepare-native-tests.sh
# Open work/NativeValidation.app; require fresh complete log and exit 0.
STAGECUE_PROFILE_MODE=resources Scripts/prepare-performance-profile.sh
# Open work/PerformanceProfile.app; wait for completion; preserve resources.json before another run.
# Close the launcher before changing modes.
STAGECUE_PROFILE_MODE=audio-probe Scripts/prepare-performance-profile.sh
# Open the launcher for the focused audio-trigger check.
```

The additional finite AV stress uses four audio voices sharing one source, looping 1080p30 video, real mixer commands and a timed sequence of Cue Groups. It is a short integration/endurance check, not proof of long-show leak freedom, sample-synchronized starts, or hardware acceptance. External audio interfaces, projector hot-plug, hours-long rehearsals and separate macOS 14 runtime acceptance remain recommended. No new physical hardware test is claimed.
