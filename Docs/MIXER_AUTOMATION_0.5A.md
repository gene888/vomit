# StageCue 0.5A — Incremental Mixer Automation

## Outcome

The focused change removes whole-project normalization from the engine's mixer path and adds targeted bus/master updates. With project publication and autosave behavior unchanged, median real-command execution cost fell from **0.655 ms to approximately 0.020 ms** (about **97% lower**, roughly **32× faster**). Real mixer scheduler P95 fell from **46.44 ms** to **14.53 ms** in the first optimized run and **9.42 ms** in confirmation.

No asynchronous UI/document mixer layer was added. The gain update reaches the engine immediately; the same validated value is then published in the project in the same MainActor call. Actual serialization retains its existing 350 ms debounce and writer actor. The measurements support keeping this smaller change rather than introducing additional ownership and synchronization rules.

Work is isolated on `performance/mixer-automation-0.5a`. App version: 0.5.0, build 6, displayed as 0.5A. Project schema remains 4; previous project formats and existing autosave location are preserved. Nothing was merged into main or pushed.

## Before and after

Apple M4 Pro Mac mini / 64 GiB, Swift 6.4, optimized arm64 `-O` profile with testability, normal native AppKit event loop. This is the same actual StageCue UI/engine harness and generated media as the [0.4.1 audit](PERFORMANCE_AUDIT.md), including the built-in operator preview and two additional canvases. No other compilation/tests ran during the timed workloads.

| Metric | Fresh unchanged baseline | Optimized run 1 | Optimized confirmation |
|---|---:|---:|---:|
| Scheduler median lateness ms | 27.386 | 6.576 | 7.112 |
| Scheduler P95 lateness ms | 46.438 | 14.529 | 9.421 |
| Scheduler maximum lateness ms | 53.229 | 15.472 | 40.848 |
| 16-action burst spread median ms | 9.931 | 0.354 | 0.367 |
| 16-action burst spread maximum ms | 13.658 | 0.466 | 0.461 |
| MainActor command cost median ms | 0.655 | 0.020 | 0.020 |
| MainActor command cost P95 ms | 0.838 | 0.024 | 0.029 |
| MainActor command cost maximum ms | 1.075 | 0.087 | 0.085 |
| Automation CPU percent of one core | 57.307 | 47.456 | 45.929 |
| Dense-automation video fps | 20.779 | 27.814 | 26.774 |
| Lightweight loaded scheduler P95 ms | 7.954 | 11.328 | 10.714 |
| Steady AV video fps | 29.900 | 28.747 | 29.900 |
| Memory before burst footprint MiB | 407.376 | 414.251 | 418.158 |
| Memory after burst footprint MiB | 415.798 | 415.205 | 410.736 |

Each run measured 960 real bus actions in five batches: four concurrent groups, each with sixteen actions at each of three common offsets. Burst spread measures the first-to-last entry within one sixteen-action exact-deadline set. Per-command time measures the synchronous `ShowState.execute` call, including engine gain update, project publication, and autosave scheduling; timer bookkeeping and app UI rendering after return are not included in that command-cost measurement. Automation CPU covers the complete real-action stage, including idle intervals and video/audio playback, using process user+system CPU time / monotonic wall time.

The original frozen audit recorded **44.67 ms P95 / 25.10 fps** for real mixer commands. The fresh unchanged comparison recorded **46.44 ms / 20.78 fps**. Desktop/run variation exists; both the original baseline and all new raw runs are retained. Do not compare the fresh baseline's frame rate directly to a selectively chosen original result. The two optimized runs use identical code and are reported separately, not pooled or selected by best result.

The 8–10 ms P95 aspiration was reached in confirmation, but not in the first optimized run. The confirmation's **40.85 ms maximum** is a real outlier and is retained. Dense video cadence improved to **26.77–27.81 fps**, but did not consistently restore 29.9 fps. Lightweight loaded scheduling also varied (roughly 8–11 ms P95), and first optimized steady AV cadence was lower than the other runs. These results do not establish a hard timing bound or prove all remaining delay comes from mixer publication.

## Architectural changes

### Full mixer restore

`SoundEngine.applyMix(project)` remains the initialization/project-load boundary. It constructs a private `MixerSettings` value containing only six bus gains and one master gain. It applies the existing -60…+6 dB bounds, 0 dB fallback for nonfinite input, and unity defaults for missing buses. Extra bus entries are ignored. It never normalizes or traverses cue, page, group, sequence, or media metadata.

The engine previously cached an entire normalized `SoundProject` for restart. It now caches those seven mixer values only. This is an engine restore snapshot, not another document source of truth. Full project validation/migration still belongs to `ProjectStore` and project normalization on document boundaries; it was never necessary inside a gain parameter update.

All former full-configuration callers were inspected: engine setup, `ShowState` initialization, project opening, and restart. The first three retain a full mixer restore; restart applies the small cached snapshot. No caller depended on the engine repairing non-mixer project data, because the former normalization operated on a private copy rather than changing the caller's document.

### Incremental engine commands

- `SoundEngine.setBusGain(index, decibels:)` validates the identifier, bounds the level, updates the restart snapshot, and writes only that bus mixer gain. Unsupported identifiers return nil without changing gains.
- `SoundEngine.setMasterGain(decibels:)` bounds the level, updates the restart snapshot, and writes only master gain.
- Both return the exact applied dB value for document synchronization. Gain conversion, fixed +6 dB boost stages, graph topology, clip levels, and audio envelopes are unchanged.

No nodes are attached/detached for mixer updates, no media is decoded, and no filesystem operation occurs synchronously in the live command. All graph/voice mutation remains on the existing MainActor; the audio render thread is not given project/UI work.

### Project and operator boundary

`ShowState.setBusGain` and `setMasterGain` are the live control boundary. A valid manual bus adjustment first establishes the existing `bus:index` scheduler override, applies engine gain immediately, then assigns that bounded value to the project. Automated bus commands use the same method with `manual: false`; they do not claim manual precedence. The master slider now uses the targeted setter directly, rather than an on-change callback that reapplies every bus.

`project` remains the persisted source of truth. These setters are synchronous with no suspension point or queued gain flush, so there is no pending document level to lose on cancellation, save, export, project closure, or termination. Future live mixer callers should use these setters; a complete project replacement must use full mixer restoration. Standalone engine clients can use the engine APIs without a document.

### Audio, UI, and persistence timing

These remain distinct operations:

1. **Engine:** apply the parameter immediately in the live command, before project publication. Never wait for a visual refresh or disk save.
2. **UI/document:** publish the same value synchronously, preserving existing operator feedback and model ownership. SwiftUI renders it on its normal schedule. This milestone introduces no throttling, deduplication, delayed project mirror, or new view model.
3. **Persistence:** the existing project observer cancels/restarts the 350 ms autosave task; the existing writer actor validates/serializes and atomically writes after the debounce. Repeated gain commands still schedule/cancel debounce tasks, but do not each perform a disk write. The final intended value is tested through actual autosave and reload.

Further separation was deliberately not implemented after measuring the focused optimization. A 32× command improvement with existing publication intact makes a second state layer unnecessary for this milestone's primary acceptance criterion. Remaining frame gaps and timing outliers should be profiled directly before choosing UI coalescing or document synchronization changes.

## Reliability validation

The unchanged baseline Release build succeeded and all **104 tests** passed before implementation. The updated ordinary arm64 Release build succeeded; all **111 tests in 13 suites passed** in native macOS context (18.059 seconds). No test was disabled. Seven added tests cover:

- Actual rendered PCM for independent bus/master changes, unchanged unrelated gain, and fixed graph/decoded-buffer counts.
- Bounds, nonfinite values, unsupported identifiers, minimum attenuation and restoration, positive gain, and engine restart retaining incremental settings.
- Rapid multi-bus updates while an actual clip fade runs; fade-to-silence, fade-in and fade-and-stop remain effective.
- Scheduled level steps, pause/resume, cancellation, manual precedence, and new runs after an override.
- Production scheduler manual override and sequence-triggered mixer group actions.
- Real final-value debounced autosave, project reload, and restored mixer values verified in rendered audio.
- Live audio continuity and actual red output-canvas pixels during rapid mixer changes, without blackout or graph changes.

Existing six-bus routing, simultaneous cues, group/sequence behavior, project migration, video playback/transitions/held frames, and soundboard/Show Mode regression tests all remain enabled.

Every profiling run retained **40 nodes / eight voices / 184,320,000 decoded bytes** through the real mixer workload and returned to **16 permanent nodes** after stopping. No audio/video errors were recorded. Memory checkpoints show no persistent increase attributable to this change, but are not an allocations/leaks proof: footprint includes native test libraries, generated-media caches and graphics allocations. No new production timer, task stream, or background service was introduced.

Existing bus/master minimum gain is -60 dB attenuation, not a newly introduced digital-mute state. Clip Fade to Silence continues to reach zero. Existing bus commands remain immediate level steps; this milestone adds neither bus fade features nor smoothing that would change their timing or sound.

## Remaining limitations

The scheduler and 30 Hz visual pipeline still share the MainActor with UI work. Dense state publication, autosave task churn, rendering and general OS scheduling can affect observed cadence and wake latency; this report does not assign an unmeasured percentage of the remainder to each. The scheduler clock, generation protection, event ordering, resource leases and cancellation code were not redesigned. Video rendering, audio preloading/caching and project format changes are out of scope and unchanged.

The reference benchmark repeatedly sets bus levels to the same target, as in the frozen audit. This still performs real engine assignments, document publications and debounce scheduling; the implementation does not skip equal values to make that workload artificially cheap. It is not a performance study of a new continuous bus-ramp API. Tests exercise varying levels and existing clip fades, but real-show automation patterns may differ.

Physical speaker/projector latency, audio-interface underrun counters, hardware listening for clicks, complex production footage, memory pressure and long-duration soak behavior were not measured here. Software PCM gain/fade checks pass; the existing hardware acceptance requirements remain. User media and the ordinary StageCue project/autosave were not used by the benchmark.

## Evidence and reproduction

- [Original 0.4.1 audit](PERFORMANCE_AUDIT.md) and its raw data remain unchanged.
- [Fresh baseline summary](Performance/0.5A-before/summary.json) / [raw](Performance/0.5A-before/results.json): production code from `5c458e6`, with per-command/CPU/graph instrumentation committed as `9c8e958`.
- [Optimized summary](Performance/0.5A-after/summary.json) / [raw](Performance/0.5A-after/results.json).
- [Confirmation summary](Performance/0.5A-after-repeat/summary.json) / [raw](Performance/0.5A-after-repeat/results.json).
- Optimized implementation and tests: `4f169a3`.

Use `Scripts/prepare-performance-profile.sh`, open `work/PerformanceProfile.app`, and wait for native host exit 0 plus `status: complete` in `work/PerformanceBaseline/results.json`. Run `Scripts/summarize-performance-profile.py`; archive each run before repeating. Both revisions use release `-O`, testability, `STAGECUE_PROFILING`, and the same hardware/workload. Profiling hooks and diagnostic buffers are absent from normal builds.

Normal build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project StageCue.xcodeproj -scheme StageCue -configuration Release -destination 'platform=macOS,arch=arm64' build`. In the restricted agent build environment the existing `-disable-sandbox` compiler-plugin accommodation and signing-disabled build followed by ad-hoc signing were used. Regression tests use `Scripts/prepare-native-tests.sh` and the native validation app, as in the baseline.
