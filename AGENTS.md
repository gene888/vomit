# StageCue control separation

Audio commands affect audio. Visual commands affect visuals. Combined Cue Groups affect both only when explicitly instructed.

- Audio-only pad triggers, gain/fade/stop controls, and audio-only groups or sequences must not clear, replace, fade, black out, or relinquish ownership of the visual program.
- Selection, soundboard page changes, and switching Soundboard/Show Mode must not change program output.
- A completed video with Hold Last Frame enabled is persistent visual program content. Retain independently owned final-frame pixels until an explicit visual action replaces or clears them; do not keep refreshing a held picture from decoder output.
- Explicit all-media emergency controls and explicitly combined group/sequence actions may affect both domains. Label combined controls clearly. Keep Command-period Emergency Stop All immediately available.
- Preserve existing project formats and the working audio engine. Keep fixes focused and validate real rendered pixels, not only cue IDs or playback flags. Include audio-only groups, pages/modes, loop/non-hold behavior, transitions, manual visual stop and blackout in regression coverage when relevant.
