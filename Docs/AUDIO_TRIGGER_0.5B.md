# StageCue 0.5B — Audio Trigger Responsiveness

Measured 25 October 2026, local time, on the same Apple M4 Pro Mac mini / 64 GiB RAM, using Swift 6.4, optimized arm64 Release `-O` with testability and opt-in profiling hooks. Raw timestamps are UTC and some runs fall on 26 October UTC. Development branch: `performance/audio-trigger-0.5b`; baseline 0.5A: `933e078`; detailed baseline instrumentation: `5349607`; implementation: `0afe52b`.

## Outcome

The demonstrated bottleneck was **main-actor UI invalidation ahead of the newly submitted audio task**, not short-file decoding. A focused presentation-notification relay reduced the one-second WAV median from **90.13 to 51.84 ms**, P95 from **100.41 to 56.28 ms**, and observed maximum from **115.67 to 56.32 ms**. Actual native Pad Button actions measured **47.25 ms median / 54.45 ms P95** in a separate ten-action check.

No PCM cache, preparation service, graph pool, streaming engine, new scheduler, or project format was introduced. The audio engine still decodes and validates fresh media for each trigger, retains the same reservations/tokens and buffer ownership, and uses the same graph, gain, fade and looping code. The 0.5A targeted mixer path is unchanged.

## Matched before-and-after measurements

All values below are milliseconds: **median / nearest-rank P95 / maximum**. Every automatic trial measures first nonzero **main-mixer rendered sample timestamp**, not the time a tap callback reaches the application. The tap receives 4,800-frame buffers despite a smaller requested size; callback arrival is retained separately in raw data and is not the onset endpoint.

| Scenario | Trials per revision | 0.5A baseline | 0.5B |
|---|---:|---:|---:|
| 1-second PCM WAV; repeated model triggers | 20 | 90.13 / 100.41 / 115.67 | 51.84 / 56.28 / 56.32 |
| Normal pad-action model path | 20 | 92.19 / 98.66 / 98.67 | 52.18 / 55.70 / 55.98 |
| Direct engine path | 20 | 91.37 / 98.74 / 99.56 | 52.29 / 54.98 / 55.45 |
| One audio action through Cue Group/scheduler | 20 | 92.69 / 97.20 / 97.25 | 50.78 / 54.68 / 56.30 |
| Six separate short WAV files, rotating pads | 18 | 92.13 / 110.67 / 110.67 | 51.28 / 59.45 / 59.45 |
| 60-second PCM WAV | 10 | 97.05 / 102.09 / 102.09 | 59.71 / 62.51 / 62.51 |
| 60-second AAC/M4A | 10 | 119.59 / 138.66 / 138.66 | 101.04 / 117.52 / 117.52 |
| Short WAV during looping 1080p30 video | 20 | 91.78 / 97.26 / 118.90 | 48.61 / 54.53 / 58.00 |
| Short WAV during 100 Hz varying mixer commands + video | 20 | 136.94 / 144.97 / 148.19 | 138.46 / 152.90 / 153.60 |
| First trigger after fresh project/UI/engine load | 10 | 98.73 / 102.06 / 102.06 | 52.76 / 55.90 / 55.90 |

The primary repeated-short test's sample standard deviation changed from 6.76 to 3.04 ms. These are finite observations, not hard real-time guarantees. Long WAV and AAC medians and tails improved; no new long-form playback mechanism was needed.

The stress case with continuously varying mixer commands at 100 updates/second did **not** improve materially: median stayed around 137–138 ms. Its maximum increased by about 5 ms in these runs, within a variable, heavily contended main-thread workload; no claim of improvement is made for it. Cue creation and actor resumptions still compete with immediate project/UI publications in that scenario. This is a remaining limitation, rather than a reason to hide the case or add a cache that would not address its underlying publication workload.

Automatic pad/model trials start at the model/action boundary, excluding OS input delivery. The baseline model route reproduces the old pad's redundant selection before `trigger`; production now centralizes that selection in `trigger`, while the matched test retains its model-entry route. Direct and scheduler routes retain the full hosted operator UI, so they are not artificially UI-free comparisons.

Fresh-project trials actually decode a saved project into a fresh `ShowState` and engine, install its `MainView` in the operator window, allow 300 ms for initial presentation/media checking, then measure the first trigger. **OS filesystem caches are warm**: no purge or cold-disk claim. Repeated and rotating-file cases are also uncached PCM loads with warm filesystem state. A decoded-cache-hit benchmark is **not applicable**, since no decoded cache exists.

### Actual native Pad Button actions

A separate isolated native operator window was controlled through the computer-use tool. Ten accessibility presses invoked the actual SwiftUI Pad Button action, rather than calling `ShowState.trigger` directly. Action-entry → rendered onset: **47.25 ms median / 54.45 ms P95 / 54.45 ms maximum**.

These actions were not hardware mouse presses. Coordinate injection for the workload window was unavailable, and no qualifying `NSEvent` timestamps were produced by accessibility activation. Therefore OS mouse-event delivery is **not measured** and is not silently included in the result. Instrumentation in the actual Button action records an event timestamp when a qualifying mouse-up/key event exists, so a physical-input study can extend the same timeline later.

### Concurrent four-voice groups

The simultaneous-group test adds per-player signal taps so each voice can be distinguished; these are **player-output endpoints**, not automatically interchangeable with the main-mixer endpoint above. Four different short-file paths are triggered at a common group offset; ten groups per revision.

| Metric | Baseline median / P95 / maximum ms | 0.5B median / P95 / maximum ms |
|---|---:|---:|
| First voice player-output onset | 89.75 / 98.44 / 98.44 | 54.04 / 58.56 / 58.56 |
| Last voice player-output onset | 141.40 / 148.60 / 148.60 | 86.04 / 90.56 / 90.56 |
| First-to-last voice onset spread | 53.33 / 53.36 / 53.36 | 32.00 / 32.00 / 32.00 |

Dispatch remains deterministic but actual nodes start when their media/graphs are ready. No shared future `AVAudioTime` arming was added, and **sample-aligned onset is not claimed**. The existing group/scheduler/lease/cancellation behavior is preserved.

## Where time was spent

Median phase durations for the matched one-second PCM case. Independently summarized columns need not sum exactly to total latency.

| Phase | Before ms | After ms |
|---|---:|---:|
| Cue lookup | 0.003 | 0.004 |
| Engine entry → task creation | 0.154 | 0.035 |
| Task stored → task entry | 43.550 | 0.024 |
| Initial file inspection | 0.313 | 0.470 |
| Inspection → MainActor return | 0.010 | 0.019 |
| Second file inspection | 0.105 | 0.228 |
| PCM read/decode | 0.086 | 0.161 |
| Loaded buffer → MainActor return | 0.008 | 0.016 |
| Graph setup before status publication | 0.680 | 1.314 |
| Engine active/level publication | 0.078 | 0.015 |
| AVAudioPlayerNode buffer scheduling | 0.005 | 0.009 |
| Player play() call | 2.309 | 6.709 |
| Play return → first nonzero mixer render timestamp | 42.853 | 42.865 |

The full timeline covers state entry, cue lookup, selection update, validation, manual override/submission, task creation/storage/entry, entry to each loader actor operation, file inspections, actual PCM read, return hops, graph setup, status publication, buffer scheduling and `play()`. All markers use a monotonic clock; loader events are recorded with a bounded lock-protected trace only in profiling builds. Per-phase work is not inferred solely from an `active` flag.

There is still an observed roughly **43 ms** between `play()` return and the main-mixer's first nonzero sample timestamp in this configuration. This study does not assign that interval to a particular hardware buffer or processing stage and does not claim it is a physical speaker delay. No gain-stage or audio-graph redesign was attempted to chase that remainder.

## Experiments and the chosen change

1. **Current baseline:** cue resolution and synchronous task submission were already sub-millisecond. All three hosted routes were around 90–93 ms, so bypassing the `ShowState` lookup alone did not solve the problem.
2. **Explicit task priority:** `.userInitiated` did not improve onset (short median about 93.5 ms). That one-line experiment was reverted. Production task priority remains unchanged.
3. **Notification-suppression probe:** a profiling-only switch temporarily stopped forwarding audio `objectWillChange` to the operator view, with the same loader/graph. Task-entry wait fell from **43.45 ms to 0.023 ms**, and direct rendered onset from **89.94 to 52.07 ms**. This is diagnostic evidence, not the shipped behavior: permanently hiding status updates was never an acceptable implementation.
4. **Bounded runtime presentation relay:** replace immediate forwarded invalidations with one pending monotonic notification deadline, combine audio/scheduler/sequence/selection updates, and keep actual values immediately readable. The initial 120 Hz probe kept short onset near 51 ms, but long-WAV P95 was about 104 ms with greater spread when UI work entered during preparation.
5. **Final 60 Hz relay:** a conventional presentation-frame interval (about 16.7 ms) kept short cues responsive and reduced the long-WAV P95 to 62.5 ms. The first event establishes an absolute `ContinuousClock` deadline; later events do not restart it. Continuous updates cannot postpone notification indefinitely.

`ShowState` stores at most one pending presentation task, captures itself weakly across the wait, reads no saved snapshot when notifying, and cancels on deinitialization/application termination. The task only calls `objectWillChange.send()`; it never starts, stops, fades, arms, or schedules media. Current selection changes synchronously, no-op selections do not notify, and the Pad action no longer selects a filled pad twice.

SoundEngine's published state and all engine/scheduler getters still change immediately. Only their forwarded invalidations of the operator view are combined. Video program state/presentation remains independent. Project publications, full project loading/validation, 0.5A live bus/master writes, and the 350 ms autosave policy are unchanged. There is no deferred document mirror, eventual gain flush, or alternate persisted source of truth.

## Why no preparation/cache or streaming system

Short PCM read/decode is approximately 0.1–0.2 ms here. The second file inspection is also small. Removing the demonstrated UI queue delay saved tens of milliseconds without retaining an additional buffer, defining cache identities, tracking file replacement, sharing playback lifetimes, or adding eviction and speculative preparation rules.

Project/page/sequence preloading strategies were evaluated against that timing breakdown and not implemented. Cache hit rate, eviction performance and preparation memory/CPU are **N/A**, not reported as fictitious improvements. Warm filesystem state must not be confused with a prepared PCM cache. Repeated same-file cues still decode fresh data.

`size()` and `load()` still each inspect/open the file. Consolidating them safely across the existing MainActor reservation boundary would introduce an inspected-file lifetime or revised budget protocol for a fraction of a millisecond in quiet short-cue operation. This milestone preserves the existing checks, reservation timing, expected-byte revalidation, cancellation tokens and graph cleanup instead. Under heavy UI contention those actor return hops can be much larger; the raw stress-case timeline exposes that rather than attributing it to decoding.

For long form, full-file decode and the existing 512 MiB per-clip / 1 GiB active-plus-loading limits remain. One-minute WAV/AAC results improved without a streaming rewrite. Very large concurrent reads on the serial loader can still delay a later short cue. A streaming or armed/prepared architecture would require its own workload, ownership and cancellation validation; the current measurements do not justify it as the first response to short-cue delay.

## Memory, compatibility and regression validation

No new PCM retention or media sharing was added. Each voice still owns its immutable decoded media. Project closure, relinking, stopping one voice, memory reservations and stale-load protection use the existing paths. The presentation relay retains no media and has a single pending task per `ShowState`.

- Baseline audio-matrix host footprint: 192.75 MiB before / 238.83 MiB after; permanent nodes after stop: 16.
- 0.5B audio-matrix host footprint: 193.33 MiB before / 311.88 MiB after; permanent nodes after stop: 16.

These absolute host memory figures include test libraries, generated fixtures, new-project UI instances and graphics caches, and are not a clean cache-allocation experiment or leak proof. Neither matched run reported audio/video errors. Cache memory is zero because no cache was introduced; active/loading buffer limits remain in force.

Before implementation, the 0.5A Release build succeeded and all 111 native tests passed. After implementation, the optimized macOS app build succeeded and **115 tests in 14 suites passed** (17.878 seconds). No test was disabled. Four added tests cover immediate getter state with one latest-state notification per burst, fixed-deadline delivery during continuous changes, cancellation/error visibility, and release of a project with pending UI notification work. A fixed 50 ms test wait was replaced with bounded observation because parallel AV setup can block MainActor; a presentation interval is not a hard real-time guarantee.

Existing tests retain PCM checks for independent gain, six buses/master, fades, silence versus fade-and-stop, looping/one-shot/toggle/retrigger, simultaneous playback, memory-budget/cancel safety, group/sequence/manual override behavior, missing/relinked media, project portability/migration, emergency stop, video output pixels/hold/transitions, and mode/page continuity. The legacy Hold mode remains decoded as one-shot and is not newly implemented as press/release playback.

App version is **0.5.1 (build 7)**, shown as **0.5B**. Project schema remains 4 and the existing autosave location is retained. The work stays on the dedicated feature branch; nothing is merged into main or pushed.

## Limits and next measurements

- Continuous 100 Hz mixer/project publication with video remains a main-thread contention case with ~138 ms median onset. This milestone does not throttle saved-project publication or redesign the mixer view. Profile that path separately before adding document synchronization complexity.
- The relay defers rendering notifications, not control state. Under other long MainActor work, UI notification delivery can be later than one frame. This is not a real-time preemption mechanism.
- Repeated automatic trials use explicit stop/settling between triggers. Rapid mid-playback retrigger behavior is regression-tested, but is not a separate latency distribution in this report.
- Group tests measure individual player outputs and are not a sample-alignment proof. No future shared-clock arming was added.
- No physical speaker/projector latency, hardware audio underrun counts, input-device latency, cold-disk/cache-purge experiment, or long-show soak was measured. A physical audio loopback setup is required for end-to-end speaker/interface timing.
- Synthetic fixtures are 48 kHz stereo float PCM, a generated AAC/M4A conversion and low-complexity H.264 video. Real productions, codecs, devices, drives and system pressure can differ. Other user applications were left running.

## Reproduce and inspect the evidence

`STAGECUE_PROFILE_MODE=audio Scripts/prepare-performance-profile.sh` builds the optimized audio matrix. Open `work/PerformanceProfile.app`; its isolated workload app uses temporary media/autosave under `work/PerformanceBaseline/`. Wait for a successful host exit and `status: complete` in `audio-trigger-results.json`, then run `Scripts/summarize-audio-trigger-profile.py`. Archive results before another run.

Modes `audio-probe` and `audio-interactive` enable the diagnostic suppression comparison and actual Button-action capture respectively. For interactive capture, use only the isolated Workload operator window, wait for each `readyForClick` trial, and activate its first pad ten times. Coordinate/event timestamps are optional; absence is explicitly retained. The profiling host has its own app identity and loads the test bundle off the main thread after AppKit launch, then starts measured work on MainActor; startup failures/expired probes were discarded, not counted as playback timings. These tools and traces are opt-in and are absent from normal app builds.

- [Matched baseline raw](Performance/0.5B-before/results.json) / [summary](Performance/0.5B-before/summary.json).
- [Final optimized raw](Performance/0.5B-after/results.json) / [summary](Performance/0.5B-after/summary.json).
- [Native Button-action raw](Performance/0.5B-ui-actions/results.json) / [summary](Performance/0.5B-ui-actions/summary.json).
- [Rejected priority probe](Performance/0.5B-priority-probe/summary.json).
- [Causal notification-suppression probe](Performance/0.5B-relay-probe/summary.json).
- [120 Hz notification probe](Performance/0.5B-120hz-probe/summary.json).
- [0.5A mixer benchmark baseline](MIXER_AUTOMATION_0.5A.md) and [original 0.4.1 audit](PERFORMANCE_AUDIT.md) remain preserved.

## Final mixer/AV confirmation

The completed full benchmark retained the 0.5A gain: **0.02075 ms median / 0.02396 ms P95** per real mixer command (960 commands). Real-command scheduler lateness was **6.83 ms median / 13.07 ms P95 / 40.43 ms maximum**; within-burst spread was **0.372 ms median / 0.469 ms maximum**. Dense automation CPU was **46.94% of one core**, and video cadence **27.37 fps**. These are consistent with the two 0.5A optimized runs; the isolated worst-case timing outlier and less-than-30-fps dense cadence remain.

Nodes remained **40 before/after the real mixer stage**, eight voices and the same decoded buffers continued, and stopping returned to **16 permanent nodes**. No audio/video errors were reported. The timed frame windows were 30.23 s and 9.97 s, with no overnight/sleep-sized gaps in those windows.

An intermittent profiler-host setup stall occurred outside the timed workloads. A temporary startup sample included dyld debugger-notification waits; that is diagnostic evidence, not a proven StageCue playback defect or an assertion that a host-loader change fixes all tooling stalls. Failed/expired setup attempts were not counted as playback data. The temporary sampler is not part of the application or retained profiling host.

[Full confirmation summary](Performance/0.5B-mixer-confirmation/summary.json) / [raw](Performance/0.5B-mixer-confirmation/results.json).
