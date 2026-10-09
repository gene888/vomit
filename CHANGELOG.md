# StageCue 0.1 development build

- Added an Apple Silicon Xcode app target, shared scheme, reproducible build/test scripts and local version control.
- Validated the real audio graph with rendered PCM and native live-engine tests.
- Added background bounded decode, load reservations and reliable stop/retrigger cancellation.
- Added natural-end automatic fades, independent replaceable manual envelopes, correct complementary equal-power math and short-clip fade fitting.
- Preserved six stereo buses and master; supported full dB gain through native gain stages with documented mixer ranges.
- Added route-change stop/retrigger policy, resource cleanup, visible engine errors/loading and live pad status updates.
- Added project validation, compatible legacy decoding, duplicate-ID repair, debounced atomic autosave and explicit document-save semantics.
- Removed unsupported Hold selection and moved cue shortcuts to Option+1 through Option+9.
- Physical audio/interface validation remains required; video is outside this build.
