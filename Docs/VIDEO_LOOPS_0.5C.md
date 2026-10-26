# StageCue 0.5C — 30 fps video loop continuity

Development branch: `performance/video-loop-continuity-0.5c`. Baseline: 0.5B `ca56980`. The audio mixer optimization and runtime notification relay from 0.5A/B are preserved. App version 0.5.2, build 8; project schema remains 4. No changes are required to existing projects or portable packages.

## Measured outcome

All values below are milliseconds, **median / P95 / maximum** of the largest canvas interval in each seven-interval boundary neighborhood. Atmospheric and short-motion rows combine two repetitions (18 wraps per revision); long clips have only two measured wraps, so their P95 is simply the observed maximum. The soundtrack row has eight baseline and nine queue wraps within its fixed playback window.

| Footage | Existing seek loop | Native queue loop |
|---|---:|---:|
| Atmospheric, 4 s | 68.60 / 106.39 / 106.39 | 35.34 / 75.57 / 75.57 |
| Precise motion, 4 s | 68.59 / 122.08 / 122.08 | 34.79 / 48.21 / 48.21 |
| Precise motion, 32 s | 76.26 / 88.69 / 88.69 | 58.73 / 68.10 / 68.10 |
| Motion with AAC soundtrack, 4 s | 146.26 / 161.69 / 161.69 | 42.19 / 94.88 / 94.88 |

Decoded-frame boundary medians changed **67.31→34.47 ms** (atmospheric), **67.45→34.24 ms** (short motion), **80.64→52.07 ms** (long motion), and **136.57→36.76 ms** (soundtrack). Thus most of the improvement occurs before the canvas. The median decode-to-canvas interval remains approximately **10–11 ms** in this hosted operator UI; the optimization does not bypass or disguise that presentation delay.

The **exact last-to-first canvas interval** is a different metric: short motion was already around 33 ms median, because much of the old hesitation occurred on the subsequent frame. Its exact-wrap P95 improved **101.40→40.24 ms**. Soundtrack exact-wrap median/P95 improved **82.03/138.08→32.60/37.55 ms**. Reporting only the exact wrap would miss the old frame-one restart hesitation.

| Loaded-workload metric | Baseline | Queue |
|---|---:|---:|
| Overall canvas fps, atmospheric | 28.77 | 29.03 |
| Overall canvas fps, short motion | 28.82 | 28.89 |
| Overall canvas fps, long motion | 29.46 | 29.33 |
| Overall canvas fps, soundtrack | 28.09 | 29.51 |
| CPU, atmospheric (% of one core) | 51.88 | 51.86 |
| CPU, short motion | 51.75 | 51.97 |
| CPU, long motion | 52.39 | 52.24 |
| CPU, soundtrack | 51.63 | 52.27 |
| Missing/nil program pictures during timed playback | 0 | 0 |
| Visible looper replicas per active looping slot | 1 ordinary item | 3 replicas |
| Items retained after stopping all video | 0 | 0 |

**Output remains capped at 30 Hz; the loaded workload does not attain a perfectly steady 29.9 fps.** This is a more involved UI/group workload than the earlier 0.4.1 sample, not a replacement for its 29.91 fps result. Normal frame medians remain around 33.3 ms, but all-interval tails outside loop boundaries persist. The aggregate short-motion count over 50 ms was 93 before and 93 after, even though its boundary-neighborhood maximum fell below 50 ms. Within-iteration source samples not observed in that case rose 62→79; the seek baseline also spends time paused at each reset, so it presents fewer source-time opportunities in the same wall interval. No general reduction of main-thread scheduling jitter or source-frame loss is claimed.

Final five-second memory samples across cases were approximately **202–212 MiB footprint before**, **202–222 MiB after**. After stop, footprint/resident were **114.44/209.28 MiB before**, **110.52/200.53 MiB after**. These are process measurements including UI, test libraries and native graphics caches, not a decoder allocation census. Fixture generation happened before baseline timing; later runs reused those files, so startup/encoder cache peaks are not a fair leak comparison. Every timed queue sample retained three visible replicas/outputs; stop released them. There were no audio/video errors and four soundboard voices remained active throughout each case.

Baseline seek completion wall time was approximately **8–12 ms median**, with observed tails up to **54.89 ms**. The native queue has **no application seek/reset at a loop boundary**. Its observed MainActor replica-output selection work was approximately **0.01 ms median**, at most about **0.02 ms**. This is synchronous selection cost, not the duration of AVFoundation's internal preparation, and not directly comparable to seek wall time. Native internal decoder preparation is opaque. Queue item changes are observed on StageCue's next 30 Hz poll, not timestamped at an internal hardware boundary.

The small seek probe and first queue probe are preserved alongside the complete before/after matrix in `Docs/Performance/0.5C-*`. All completed measurement runs used exit status 0. The profiling helper initially stalled before loading its benchmark bundle, then recovered and completed a fresh 180-second moving-bar soak. Only the measured three-minute playback window is included, not the startup wait. The Mac was subsequently confirmed unlocked and the packaged 0.5C app launched successfully; a second continuous soak confirms behavior after unlocking. Neither stalled-startup nor stale result files are counted as successful measurements.

## Continuous loop validation

The recovered run (`0.5C-queue-soak-recovered`) completed **180.004 seconds / 45 wraps**, with four simultaneous soundboard audio loops and recurring six-action Cue Groups/page changes. Its canvas boundary-neighborhood gaps were **34.00 / 53.35 / 66.88 ms** (median/P95/max); exact-wrap gaps were **33.30 / 43.48 / 66.88 ms**. Overall canvas delivery was **29.09 fps**, and CPU was **51.81% of one core**. All 5,236 distinct decoded pictures reached the instrumented software canvas; there were zero nil/missing picture updates and no audio/video errors.

All 36 five-second memory samples retained **three replica items and three outputs**, with fixed soundtrack level. Footprint began at **197.55 MiB** and ended at **199.19 MiB**; the transient observed range was **196.75–305.74 MiB**, so this is not a claim of constant allocation size. After stop, replicas and outputs were zero and footprint was **106.92 MiB**. Sample spacing never exceeded **5.02 seconds**, and there was no sleep-length gap in the measured window. A finite soak establishes bounded observed behavior, not a general leak proof. The source has no soundtrack; the separate AAC matrix and regression test cover embedded-track operation.

The confirmation run after unlocking (`0.5C-queue-soak`, 16:59:57 UTC) completed **180.013 seconds / 45 wraps**, again with four audio loops, groups and page changes. Brief native UI inspection occurred during this run. Results:

| Metric | Unlocked confirmation |
|---|---:|
| Canvas boundary-neighborhood median / P95 / maximum | **44.82 / 66.70 / 79.86 ms** |
| Decoded boundary-neighborhood median / P95 / maximum | 34.02 / 66.68 / 66.83 ms |
| Exact-wrap canvas median / P95 / maximum | 33.24 / 66.70 / 79.86 ms |
| Overall software-canvas delivery | 29.20 fps |
| CPU (% of one core) | 53.38 |
| Decoded pictures / distinct canvas assignments | 5,257 / 5,256 |
| Missing/nil canvas updates; audio/video errors | 0; none |
| Replica items / outputs in every sample | 3 / 3 |
| Items / outputs after stop | 0 / 0 |
| Footprint, first / final timed sample | 198.00 / 209.05 MiB |
| Observed transient footprint range | 196.86–307.16 MiB |
| Footprint / resident after stop | 108.94 / 202.53 MiB |

The largest memory-sample interval was 5.024 seconds, with no sleep-length pause during the timed window. Both soaks used the same code and fixtures. Their differing tails and UI-to-canvas delays demonstrate scheduling/visibility sensitivity; **do not use the more favorable recovered run to promise a 34 ms maximum or perfectly steady output**. The unlocked run is the final confirmation. One decoded picture lacked a distinct recorded canvas assignment in its timed capture; no nil frame was substituted. Native queue looping substantially improves reset behavior, but occasional frame holds/skips under UI/automation load remain, including a 116.54 ms maximum interval away from the measured boundary neighborhoods. Physical projector acceptance and the “no perceptible hesitation” goal cannot be declared conclusively satisfied by these software measurements.

The packaged application launch check is retained in `Docs/Performance/0.5C-queue-full/launch-check.md`. The full 118-test suite and optimized build remain unchanged; only verification data/documentation were added after the reviewed build. Physical projector delivery, hot-plug and soundtrack listening remain unverified.


## Selected strategy

The previous end-of-file handler sought the current AVPlayer to zero and resumed playback. It preserved the last good picture and reused its player, but paused the media timeline at every boundary. Measurements isolate seek completion from the subsequent decoded picture and software-canvas assignment. They show delays larger than the seek itself, particularly with an embedded soundtrack.

An initial small experiment used `playImmediately(atRate:)` and submitted the first ready picture immediately after seek completion. It still produced approximately 67 ms median maximum gaps in boundary neighborhoods for both short footage types. The raw probe is retained; this strategy was discarded.

Each of the existing two transition slots now owns an AVQueuePlayer and, **only for looping video**, an AVPlayerLooper. AVFoundation prepares and advances its bounded replica set; StageCue no longer seeks/restarts at loop EOF. A crossfade still uses the same two slots. There is no alternating application-managed preload state machine, extra presentation timer, content crossfade at loop boundaries, or new media cache.

Apple documents that a looper does not copy AVPlayerItemVideoOutput attachments from its template. StageCue attaches an output to each replica, selects the output belonging to the queue's currentItem, and retains the last good CGImage until a valid next picture is available. Replica membership is reconciled when reading; removed attachments are detached. Stop/replacement pauses the player, disables/releases its looper, detaches outputs, empties the queue and clears owned pictures. No callback can restart a cleared looping slot. Non-looping items retain the existing pause-at-end / hold / explicit-final-sample path.

The 30 Hz `AVPlayerItemVideoOutput → Core Image → CGImage → CALayer` pipeline and aspect/opacity rules are preserved. No 60 fps output, Metal rewrite, interpolation, or automatic content blending was introduced.

References: [Apple AVPlayerLooper](https://developer.apple.com/documentation/avfoundation/avplayerlooper), [replica output ownership](https://developer.apple.com/documentation/avfoundation/avplayerlooper/loopingplayeritems).

## Measurement method

Measurements are optimized arm64 `-O`, opt-in `STAGECUE_PROFILING`, in the native AppKit host on the Apple M4 Pro / 64 GiB Mac used for 0.5A/B. They use the actual MainView operator preview and a separate 960×540-point VisualCanvas program window, four simultaneous soundboard audio loops, and Cue Groups executing six bus commands at 80 ms spacing every three seconds. Soundboard pages switch during playback. Software-canvas times record layer-content assignment after CATransaction commit; they do **not** measure WindowServer scanout, HDMI/projector latency or physical black flashes.

Locally generated, H.264 1920×1080 **30 fps** fixtures include:

- Four-second atmospheric grayscale blurred texture with slow closed-path advection against darkness.
- Four-second high-contrast vertical bar moving continuously across the frame and wrapping at the edge.
- A 32-second moving-bar clip.
- A four-second moving-bar MP4 with an AAC soundtrack derived from a quiet 220 Hz tone.

The atmospheric clip is a repeatable proxy, not real photographed smoke. The reference images supplied with the request were descriptions of desired test types, not source video files. No stock footage was downloaded or redistributed. Decode complexity is synthetic and is not representative of every camera codec, high-noise scene or production file. Check actual production media before a show.

The matched full matrix repeats atmospheric and short-motion cases twice, includes 70 seconds on the long clip and 36 seconds on the soundtrack clip, totaling approximately 250 seconds per revision. First-frame load/warmup is excluded. A separate continuous soak supplements the matrix.

Raw data records every decoded-frame PTS/monotonic arrival, every distinct corresponding canvas assignment, seek initiation/completion where applicable, queue-output selection cost, memory samples, item/output counts, errors and active audio voice count. A backwards source-PTS jump identifies an intentional loop. It is never counted as a source-frame drop. Frame intervals within iterations and around boundaries are reported separately.

`Scripts/summarize-video-loops.py` reports the exact last-to-first interval and the **maximum interval in a seven-interval neighborhood** around each wrap. The latter also catches a fast frame-zero arrival followed by a delayed frame one. Median/P95/max refer to observed samples (nearest-rank P95), not a real-time guarantee. All intervals over 50 ms are retained, including those outside boundaries; UI/automation contention is not attributed automatically to loop reset.

## Validation and operator behavior

The unchanged baseline passed 115 native tests. The queue implementation passed 118 tests in 14 suites (31.999 seconds). Added tests observe source-time wraps and actual rendered nonblack pixels across repeated boundaries, verify looping takes precedence over Hold Last Frame, bounded replica/output ownership, pause/resume, blackout, page/mode switching, soundtrack gain, persistence, crossfade to a still and stop. A cancellation test replaces/stops rapidly near EOF and checks that old work cannot restart playback. A third test includes an embedded audio track, checks stable configured soundtrack volume over a wrap, loop-to-loop crossfade ownership (up to six replicas), pause/resume, fade-and-stop cleanup and actual independent soundboard PCM after video stops. It does not capture physical soundtrack audio. Existing tests preserve simultaneous audio, one-shot/loop, fades/crossfades, manual/group/sequence commands, persistent held-frame pixels, display-disconnection policy, missing media, migrations/portability and emergency stop.

Operator controls are unchanged: enable **Loop** on a video cue; use Pause/Resume, Stop, fades or an explicit replacement normally. Hold Last Frame applies to non-looping video. Audio-only commands and page/mode selection do not clear program output. Blackout hides the picture; it does not mute soundtracks.

## Reproduction

```sh
STAGECUE_PROFILE_MODE=video-loop Scripts/prepare-performance-profile.sh
# Open work/PerformanceProfile.app; wait for exit status 0.
python3 Scripts/summarize-video-loops.py work/PerformanceBaseline/video-loops.json
# Modes video-loop-probe and video-loop-soak provide shorter comparison / 180-second continuous motion tests.
Scripts/prepare-native-tests.sh
# Open work/NativeValidation.app; require fresh log, exit 0 and complete test count.
```

The profiler uses an isolated autosave and local generated media. Preserve results before the next run overwrites them. Do not compile or run other test workloads during timed measurements. The native launcher mode is read on app launch, so close the parent before changing modes; Run Again retains its current mode.

## Limits and hardware acceptance

- A 30 Hz main-run-loop timer is not a hard real-time video clock. Heavy main-thread work and OS scheduling can still repeat or skip frames. Tail delays remain visible in raw results rather than being hidden by atmospheric footage.
- Source first/last-frame mismatches remain content discontinuities. StageCue does not disguise them with interpolation or blending.
- AVFoundation owns soundtrack synchronization on the same queued timeline. Soundtracks still bypass the soundboard's six buses/master, and follow the existing video soundtrack level and visual fade envelopes. Two players sound together only during an explicit crossfade. This work does not establish sample-perfect soundtrack loop seams or physical A/V synchronization; AAC priming/source edits and hardware buffering require listening tests.
- Only one 2560×1440-point screen was reported in this session; no separate physical projector/display was tested. Physical external-display hot-plug, projector frame delivery and real sound output require a hardware check. Software policy tests and local canvases do not establish physical-display acceptance.
- Before production: run both a real atmospheric loop and the moving-bar fixture on the target projector for several minutes, with normal audio/groups; check boundary hesitation, picture blackout, soundtrack seams, pause/resume, cut/crossfade, stop/retrigger, disconnect/reconnect, and non-looping held-frame persistence. After disconnect, reopening output remains an explicit operator action.
