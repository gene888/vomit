# Outstanding StageCue 0.1 work

## Release validation still required

- Audible validation on the intended interface: all buses, gain/headroom, curve quality, exact silence vs stopped transport, and independent fades. Summed/boosted signals can clip; there is no limiter or meter.
- Measure cue start latency and stop responsiveness under many simultaneous decodes, edits, native panels and continuous slider changes. Background decoding protects UI responsiveness but adds first-trigger latency.
- Physical USB disconnect/reconnect, default output switching, sample-rate/buffer-size changes, sleep/wake and interface driver recovery. The software interruption handler is tested; physical route events are not.
- Show-length soak and Instruments profiling for CPU, process memory, framework allocations and render glitches. Automated node/buffer accounting is not a proof of zero leaks or a measured process memory profile.
- Test the macOS 14 deployment target on a macOS 14 machine. Current runtime tests use the host system only.
- Independent user listening check before performance use. The automated live test schedules digital silence.

## Audio/workflow features deferred from this build

- Hold-to-play with pointer/key release and focus-loss cancellation. Hidden in the current UI; imported Hold values become One-shot with a repair notice.
- Dedicated output-device selection and more detailed hardware diagnostics.
- Clip preloading, bounded cache and disk streaming for long files. The current app uses per-trigger PCM decode with 512 MiB per-clip and 1 GiB combined active/load reservation limits.
- Sample-accurate envelopes/crossfades outside the UI control timer. Current timer handles modal tracking in common run-loop modes but can still stall if the UI thread is blocked.
- Meters, clipping indication, limiter, pause/resume, and live editing of active cue gain/bus settings (settings currently take effect on next trigger).
- Media collection/portable projects, automatic relinking and security-scoped bookmark support for sandboxed distribution.
- Undo/history, stronger document recovery/versioning, and a first-class Xcode test target (the tests currently run through Swift Package Manager).
- App icon, Developer ID signing and notarization if external distribution is later requested. The delivered app is locally ad-hoc signed.

## Outside 0.1

No video playback, video routing, HDMI/projector output or video preview was implemented. Version 0.2 video work remains separate.

## Version 0.3 follow-up priorities

The 0.1 list above is historical. Groups, sequences, Show Mode and soundboard pages now exist. Remaining priorities: real interface/projector acceptance and hot-plug checks; extended-show Instruments CPU/GPU/memory profiling; media preloading and synchronized starts; portable media/security bookmarks; timeline seeking; page deletion/undo and richer copy/edit tooling; explicit sleep/suspension recovery rather than dispatching overdue actions. Existing video soundtrack bus-routing and 30 fps SDR limitations remain. No out-of-scope network/MIDI/OSC/DMX features are added.


### 0.5D resource update

Concurrent voices now share immutable PCM for one unchanged filesystem source, with unique allocation/reservation accounting and no strong inactive cache. Project JSON capacity is 16 MiB. Long-form streaming, an armed/prepared cache, sample-synchronized starts, physical interface/projector acceptance and extended-show leak profiling remain separate future work; see [0.5D measurements](RESOURCE_EFFICIENCY_0.5D.md).
