# StageCue 0.4.1 — Performance Baseline and Architecture Audit

Measured 25 October 2026 on an Apple M4 Pro Mac mini, 12 CPU cores, 64 GiB RAM; Version 27.0.1 (Build 26A434). Source baseline: `af7d093106e8c094b0d8a20c8ed4cf688e577207` (`fix/persistent-video-hold`), plus the opt-in profiling instrumentation and harness in this working tree. Swift 6.4 / Xcode toolchain, macOS 14 deployment target, optimized Apple Silicon build. Final run began `2026-10-25T22:57:00Z` and completed successfully (native host exit 0).

The steady workload uses modest CPU and runs 1080p30 near its intended cadence. Two measured constraints deserve attention before broad optimization: **the 30 Hz video presentation ceiling**, and **main-actor command cost under dense real mixer automation**. Audio UI-trigger latency is measurable, but decoding alone is not its dominant component for short PCM files. No playback optimization or architectural rewrite was made.

[Raw samples](Performance/2026-10-25-results.json) · [Calculated statistics](Performance/2026-10-25-summary.json)

## 1. Audio trigger to rendered playback

All times in milliseconds. First nonzero main-mixer **render timestamp**, not tap callback arrival or a physical speaker measurement.

| Fixture | Trials | Median | P95 | Maximum |
|---|---:|---:|---:|---:|
| one-second.wav | 20 | 91.51 | 98.39 | 117.86 |
| sixty-seconds.wav | 10 | 98.90 | 113.09 | 113.09 |
| sixty-seconds.m4a | 10 | 118.80 | 144.92 | 144.92 |

Median breakdown (each column is independently summarized; medians need not sum):

| Fixture | Trigger → loader task | Inspection / actor return | Decode / actor return | Graph setup | Trigger → loads complete |
|---|---:|---:|---:|---:|---:|
| one-second.wav | 42.67 | 0.33 | 0.27 | 4.48 | 74.70 |
| sixty-seconds.wav | 43.43 | 0.34 | 4.34 | 8.06 | 81.77 |
| sixty-seconds.m4a | 41.83 | 0.62 | 28.15 | 6.04 | 101.64 |

The short WAV decodes in about 0.3 ms, whereas dispatch from the UI trigger to the loader task is about 43 ms. Additional actor/UI resumption and setup are included in total latency. This is evidence to compare direct-engine versus UI-trigger timing in a follow-up, not evidence that a new decoder or a complete engine rewrite is necessary. The benchmark audio output is 48 kHz; the output node reported 0.292 ms presentation latency. Hardware loopback is still needed for end-to-end output delay.

## 2. Video trigger to first visible software frame

Cut transitions, all times in milliseconds. Canvas timing waits for nonblack pixels from the real output-layer rendering path.

| Fixture / endpoint | Trials | Median | P95 | Maximum |
|---|---:|---:|---:|---:|
| 1080p30.mp4 — decoded image | 20 | 131.63 | 133.27 | 144.57 |
| 1080p60.mp4 — decoded image | 20 | 130.57 | 134.16 | 142.76 |
| 1080p30.mp4 — nonblack canvas | 20 | 132.99 | 136.87 | 192.31 |
| 1080p60.mp4 — nonblack canvas | 20 | 132.48 | 136.46 | 143.85 |

These results include file inspection, player readiness, frame conversion, and UI delivery. They exclude physical display/projector latency. The first-frame readiness loop currently polls at 20 ms intervals.

## 3. Memory with a large show loaded

| Checkpoint | Physical footprint MiB | Resident MiB |
|---|---:|---:|
| Fixture generation complete, before engines | 123.42 | 97.98 |
| Empty operator UI + engines + two additional canvases | 193.20 | 164.91 |
| Loaded 1,024-pad show; media validation complete | 124.16 | 206.28 |
| Eight sixty-second audio voices loaded | 505.53 | 421.23 |
| After all playback stopped, two-second settling | 142.88 | 236.22 |

During the 30-second simultaneous AV workload, physical footprint was **409.26 MiB median / 418.22 MiB maximum sampled**. Audio buffers alone occupied **175.78 MiB**. The graph returned to **16 permanent nodes** after stopping. No audio/video errors were reported.

Project JSON: 1,347,389 bytes; synchronous project-load time: **24.18 ms** (one load, not a distribution). This show contains 1,024 cues / 64 groups / 16 sequences, sharing two assets. It does not test 1,024 unique media files. The profiling host includes test libraries and fixture-generation caches. macOS footprint, RSS, GPU allocations, compression, and caching can move in different directions; the lower later footprint does not mean the large show uses negative memory. Do not subtract these checkpoints as a clean allocation accounting experiment.

## 4. CPU during simultaneous audio/video

Eight stereo loops across six buses + 1080p30 looping video + actual operator UI, built-in preview, additional program canvas and additional preview canvas, and lightweight scheduled bursts; 30 one-second samples.

| CPU endpoint | Result |
|---|---:|
| Mean | 47.68% of one core |
| Median | 47.59% of one core |
| P95 | 49.23% of one core |
| Maximum sampled | 49.28% of one core |
| Approximate share of 12 logical cores, mean | 3.97% |
| Large-show idle CPU, five-second window | 1.15% of one core |

The two stress workers and dense real bus-command scenario are excluded from this steady CPU distribution. It includes CPU in this process, not total GPU usage, WindowServer, or system decoder services.

## 5. Transition timing and frame delivery

Twelve one-second crossfades while all eight audio voices continued. Times in milliseconds.

| Endpoint | Trials | Median | P95 | Maximum |
|---|---:|---:|---:|---:|
| Trigger → incoming ready | 12 | 115.19 | 140.56 | 140.56 |
| Envelope start → completion observed | 12 | 1038.26 | 1042.49 | 1042.49 |
| Trigger → completion observed | 12 | 1133.29 | 1138.45 | 1138.45 |

Completion is observed by the harness after the engine retires the outgoing slot. It includes timer quantization and main-actor observer latency; it is not a direct measurement of the exact compositor presentation instant. A configured one-second fade begins after incoming media is ready, so trigger-to-completion is longer than one second.

| Workload | Seconds | Observed output fps | Unretrieved source frames / continuous PTS intervals | Gaps >50 ms | Largest gap ms | Loop resets |
|---|---:|---:|---:|---:|---:|---:|
| Steady 1080p30 + audio | 30.19 | 29.91 | 0 / 900 | 3 | 67.37 | 3 |
| 1080p60 through 30 Hz output | 9.97 | 29.90 | 297 / 594 | 1 | 65.35 | 1 |
| 1080p30 during real bus bursts | 3.27 | 25.10 | 16 / 98 | 14 | 110.28 | 0 |

The steady 30 fps sample had no skipped source frames within continuous PTS segments, but showed roughly 67 ms gaps around loop cycles. The 60 fps source lost roughly half its frames through the 30 Hz presentation path. Dense real bus automation also reduced observed video cadence. These counters measure the software output path; physical monitor/projector dropped refreshes and decoder-internal drops were not measured. Loop boundaries are deliberately not counted as within-segment source-frame skips.

## 6. Scheduler accuracy

Lateness relative to each actual monotonic deadline, in milliseconds. Four concurrent groups; each burst contains 16 actions per group, giving 64 near-simultaneous actions at each offset.

| Scenario | Actions measured | Median lateness | P95 | Maximum |
|---|---:|---:|---:|---:|
| AV + 2 CPU workers | 960 | 4.37 | 9.21 | 9.28 |
| AV + real mixer bus actions | 960 | 25.98 | 44.67 | 51.71 |
| AV loaded | 1920 | 1.32 | 8.09 | 8.32 |

Within one 16-action common-deadline burst, real mixer command dispatch spread was **9.80 ms median / 13.58 ms maximum**. Lightweight bursts were below 0.1 ms maximum spread. This separates scheduler wake/dispatch overhead from the cost of commands themselves. It does not establish simultaneous audible onset for file-loading actions.

An earlier completed native pass gave similar qualitative results: steady CPU around 48% of one core; real-bus lateness about 46 ms P95 / 56 ms maximum, versus about 8 ms P95 for lightweight dispatch. Only the final, instrument-refined run is used in the tables above; results from different harness versions are not pooled.

## What the measurements mean

This is an optimized software-pipeline baseline of the current StageCue source, hosted in a native macOS application with a normal AppKit event loop. It uses the actual `ShowState`, `MainView`, `SoundEngine`, `VideoEngine`, `ShowScheduler`, and two additional `VisualCanvas` views, alongside the built-in operator preview. It is not an Instruments capture of the distributed app binary. Test-framework loading, fixture generation, and measurement bookkeeping add some process memory; native decode/compositor service processes, WindowServer, GPU utilization, and other applications' CPU are outside the reported process CPU. The operator preview is 224×126 points; extra program and preview canvases are 960×540 and 480×270 points. This is a slightly heavier canvas workload than the usual built-in preview plus one program window. Absolute memory values therefore describe this host; use them as a repeatable baseline rather than an exact prediction of the shipping app's Activity Monitor reading.

- **Audio start:** time immediately before `ShowState.trigger(0)` to the audio timestamp of the first nonzero sample at the main mixer. The tap scans sample data, rather than relying on `active`, `isPlaying`, or completion of loading. Callback arrival is recorded separately: AVAudioEngine delivered 4,800-frame tap buffers despite a 256-frame request. A callback-only measurement would exaggerate latency. Mixer timestamps are not a measurement of sound reaching a speaker. The output node's reported presentation latency is included in the raw configuration, not blindly added to the result.
- **Video start:** trigger to publication of the first decoded image, plus a separate trigger-to-canvas result. The canvas result waits until an actual CALayer render produces nonblack pixels. It includes preparation and conversion; it does not measure projector scanout, HDMI buffering, or optical response. Cut transitions isolate startup from configured fade time.
- **Memory:** Mach `TASK_VM_INFO` resident size and physical footprint. The large show has the maximum 32 pages / 1,024 pads, 64 groups containing 1,024 actions, and 16 sequences containing 512 steps. Its references share two media assets. Normal media validation is allowed to finish. This exercises maximum pad/reference count, not thousands of unique files. Loaded-but-idle media is not decoded; playback uses eight distinct sixty-second audio voices, even though they reference the same file.
- **CPU:** changes in the process's user+system CPU time divided by monotonic wall time, sampled over 30 one-second intervals. 100% means one logical core; this Mac has 12. Eight looping stereo audio voices span six buses, with looping 1080p30 video, the full operator view, built-in preview, additional program canvas and additional preview canvas, and concurrent scheduler batches. The tap is removed before CPU measurements. The two synthetic CPU workers are used only for a separate scheduler stress scenario.
- **Frames:** source presentation timestamps returned by `AVPlayerItemVideoOutput`, paired with host timestamps after conversion. Gaps in PTS count source frames that the output pipeline did not retrieve. They are not proof of codec decoder failures or physical display dropped refreshes. Loop resets are counted separately and excluded from within-segment skipped-frame totals. Frame callback gaps include loop-boundary stalls.
- **Scheduler:** actual entry time into the playback driver minus each execution's own monotonic deadline. Four concurrent groups each schedule 16 actions at each of three offsets (0.2, 0.4, and 0.6 seconds): 192 actions per batch. Lightweight-driver scenarios isolate scheduler dispatch; the real-bus scenario delegates every action to `ShowState.execute`, including actual mixer changes and their UI/document side effects. Dispatch simultaneity is not sample-aligned audio onset.
- **Transitions:** twelve one-second video crossfades with all eight audio voices continuing. The envelope-start measurement begins at the engine's actual dissolve start, avoiding the error of starting a stopwatch after the first fade tick. Trigger-to-completion also includes media preparation.

Generated media: 48 kHz stereo float PCM WAV (1 second and 60 seconds), a 60-second AAC/M4A conversion, and 8-second H.264 MP4 clips at 1920×1080 / 30 and 60 fps. Video has changing color and a moving rectangle, with low spatial complexity and no soundtrack. It is not representative of every real-world codec, bitrate, or camera scene. Audio is generated at a very low output level; no microphone or user media is recorded. Fixtures are newly generated, but OS caches are warm; these are **not cold-cache** measurements. No cache purge or global system tuning was performed. Existing user applications were left running, and the user's open StageCue production was not edited.

P95 uses the nearest-rank definition. Small groups of ten trials have P95 equal to their maximum; these are observed samples, not guaranteed worst-case bounds.

## Architecture audit

### Audio preparation and resource use

`MediaLoader` serializes inspection and full-file decode away from the UI actor. Cancellation tokens, reservations against the 1 GiB active/loading budget, and per-voice tokens protect against stale loads and completion callbacks. Each voice attaches a player, mixer, and EQ/gain node. This is a sensible reliability baseline, and stopping the workload returned the graph to its 16 permanent nodes with no retained decoded audio voices.

Cues are not preloaded or streamed. Each trigger opens/inspects the file, decodes the whole file, and creates/connects the voice graph. `size()` and `load()` each call `inspect()`, so a trigger opens the file twice. The timing breakdown separates initial task dispatch, inspection/actor return, decoding/actor return, and synchronous graph setup. These observations do not justify attributing every millisecond to disk or to decoding. Repeated references do not share an active decoded buffer; eight sixty-second stereo float buffers consume exactly 175.78 MiB before graph and video resources.

Multiple group play actions are dispatched in order and begin asynchronous loading. Their `AVAudioPlayerNode.play()` calls are issued when each load is ready, without a shared future `AVAudioTime`. Therefore “simultaneous” currently means coordinated triggering, not sample-accurate synchronization. If future productions need musically aligned starts, measure an optional preparation/arming path and shared scheduled start time before considering an audio-engine rewrite.

References: `Sources/StageCue/AudioEngine.swift` (`MediaLoader.inspect/load`, `SoundEngine.play/start/detach`).

### Scheduler and command cost

The scheduler uses a monotonic `ContinuousClock` for waiting, a generation token for stale-wake protection, and deterministic deadline / group-launch / action ordering. The benchmark supplies `CACurrentMediaTime()` as its injectable monotonic time source so deadlines and observations share one directly comparable clock domain; the production sleep/arm/tick implementation is unchanged. Pending actions are canceled safely; manual overrides and resource leases remain intact.

Execution and state publication run on `MainActor`. The scheduler scans active runs and pending events, sorts due work, and then linearly finds/removes entries while executing each action. It is not a hard real-time scheduler and cannot preempt a long main-thread operation. A 25 ms maximum polling interval is used for playback completion; pending deadlines receive shorter waits, down to a 1 ms minimum. The 25 ms value should not be mistaken for a fixed dispatch delay.

A real mixer-bus command currently mutates `project.busDB` and calls `SoundEngine.applyMix(project)`. That method normalizes a complete `SoundProject` before applying seven mixer gains. For a large project this traverses cue, group, sequence, and page metadata repeatedly. Every project mutation also publishes a document change and restarts the autosave debounce. Dense real-command bursts are consequently a different workload from waking and dispatching a lightweight action. The measured distinction makes this a stronger candidate for a focused follow-up than replacing the scheduler clock.

References: `Sources/StageCue/ShowScheduler.swift` (`tick`, `arm`, `ShowState.execute`); `Sources/StageCue/AudioEngine.swift` (`applyMix`); `Sources/StageCue/StageCueApp.swift` (`scheduleAutosave`).

### Video presentation and UI coupling

The dual-player design prepares an incoming source before replacing the program image, preserving the outgoing picture during readiness. Held final frames have independently owned pixels and are not polled again. These properties should be preserved.

The presentation path is an `AVPlayerItemVideoOutput` → pixel buffer → Core Image → `CGImage` → CALayer pipeline. Frame conversion and visual envelope updates run on `MainActor` from a common-mode 30 Hz Timer. A 60 fps source cannot retain 60 fps motion through this path. Timer scheduling and main-thread work also influence transition quantization and frame gaps. Native AVPlayer audio and the soundboard's Core Audio graph use separate playback systems; video soundtrack routing still bypasses the six audio buses/master, as documented previously.

Each published video change causes `VisualCanvas` to enqueue a render on the next main turn. Several properties change per tick, so a canvas can receive more than one render request for a frame. Audio envelopes also publish per-voice levels at up to 120 Hz and forward engine changes to `ShowState`, potentially invalidating the operator view. These are architectural opportunities, not proven CPU hotspots from this audit: no time-profiler stack trace or allocation trace was captured. The steady CPU measurement alone does not justify restructuring them.

References: `Sources/StageCue/VideoEngine.swift` (`play`, `readFrame`, `tick`); `Sources/StageCue/VideoOutput.swift` (`VisualCanvas.connect/render`); `Sources/StageCue/StageCueApp.swift` (engine publication forwarding).

### Persistence and capacity

The JSON project limit is 2 MiB. A maximum-pad show with the benchmark's groups and sequences already occupies about 1.3 MiB despite sharing only two media assets. More unique manifest entries, longer paths, or many additional actions can reach the byte limit before the independent model-count limits. This is a capacity constraint to document and separately test. The current save error for exceeding this limit uses `.fileWriteOutOfSpace`, which may misleadingly suggest disk exhaustion.

Project decoding, normalization, path validation, and temporary construction influence loading memory. Media hashes are streamed on a library actor; large media is not eagerly retained simply because a project references it. The recorded load time is `ProjectStore.load` parsing/normalization/path resolution, separate from subsequent asynchronous media validation.

References: `Sources/StageCue/ProjectStore.swift` (`maximumBytes`, `load/save`); `Sources/StageCue/MediaLibrary.swift` (`catalog`, `fingerprint`).

## Recommended next steps

1. Preserve this baseline. No playback optimization or engine restructuring was made during this audit.
2. If dense mixer automation is a real production requirement, first benchmark a focused path that validates mixer settings without normalizing the entire project for every level change. Compare real-action lateness and video gaps against these results before accepting a change.
3. If 60 fps output is required, evaluate display-synchronized presentation and an AVFoundation/Metal-backed presentation path. This is a functional output-cadence decision, not something higher CPU priority will fix in a 30 Hz timer.
4. If current audio startup is perceptibly late in the actual production, first compare direct-engine and UI-trigger timing, then evaluate preparation/arming and caching. Maintain memory reservations, cancellation, and manual precedence. Do not assume full-file decode is the largest measured component.
5. Keep the current scheduler clock unless a production workload demonstrates inadequate timing after command costs are addressed. Explicitly distinguish dispatch timing from media readiness and sample-aligned playback.

## Limits and hardware follow-up

This run does not establish physical speaker or projector latency, HDMI/display missed refreshes, hardware audio underrun counts, audiovisual synchronization, performance on older Apple Silicon, external-drive cold reads, 4K/HEVC/ProRes or complex camera footage, thousands of unique asset files, memory-pressure behavior, or long-show leak freedom. No allocations/leaks instrument, GPU trace, or time-profiler stack capture was run. A short workload returning decoded resources and nodes is reassuring but is not a leak proof.

For production acceptance, repeat against a duplicate of a representative real show on the actual interface, projector, resolution/refresh mode, and media drive. Audio loopback capture can measure interface/output delay; optical measurement or high-speed video is required for actual projected-light latency. Run a longer transition/retrigger/automation soak while logging process footprint, output cadence, and audio underruns. Those tests require physical hardware and, for loopback recording, an explicit capture setup.

## Reproduce

1. In the StageCue repository run `Scripts/prepare-performance-profile.sh` using the installed Xcode toolchain.
2. Open `work/PerformanceProfile.app`. A launcher starts an optimized native AppKit host, which loads the benchmark entry point from the release test bundle. Temporary autosaves and generated media stay under `work/PerformanceBaseline/`; the normal StageCue autosave is not used.
3. Wait for a successful launcher exit status **and** `"status": "complete"` in `work/PerformanceBaseline/results.json`.
4. Run `Scripts/summarize-performance-profile.py`. It rejects an incomplete result and writes `summary.json` next to the raw data.
5. Archive results before rerunning. Compare identical workloads, hardware, flags, and endpoint definitions. Do not compile or run other tests during the timed workload.

Profiling hooks exist only under `STAGECUE_PROFILING`; ordinary Xcode and SwiftPM builds do not install a tap, collect timing callbacks, or include the benchmark. The release profile uses `-O`, `-enable-testing`, and no debug-symbol generation. Disabling nested SwiftPM/compiler-plugin sandboxing in the preparation script is a build-environment accommodation; it does not change application playback or system security settings. The benchmark is a separate entry point, not a new ordinary automated unit test.

## Validation of the audit tooling

The optimized profiling host exited 0 with a complete final result. The ordinary arm64 Xcode Release build succeeded with profiling disabled, and all **104 regression tests in 12 suites passed** in native macOS context (18.104 seconds). No existing regression test was disabled. Profiling is not installed into the normal app build. Source changes and this audit remain local; no commit or push was performed.
