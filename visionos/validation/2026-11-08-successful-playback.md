# First successful PS5 playback — 2026-11-08

The user reported “It’s working!” after being asked to pair with a fresh PS5 Link Device code and select Play on the physical Vision Pro. This establishes user-confirmed playback for the local-network prototype; it is not App Store or production qualification.

## Installed source and artifact

- Repository: `https://github.com/huntereastman/chiaki-ng.git`.
- Branch: `codex/visionos-prototype`.
- Installed runtime commit: `d2dfaa5ccfdce9472495df648ba178067b5fe289`.
- Runtime source digest: `57785be18c619e9677f083b98650af55606b3c62137a337f6ae3f6fb09332fcc`.
- Signed executable SHA-256: `2872bdcc58ea6cbf527135fb2474713a7e379f89bd5699bf4c774d8bd64d7c2d`.
- Bundle: `dev.hunter.visionremoteplay`, version `0.1.0`, build `1`.
- Target: physical visionOS/arm64, local Apple Development installation.

The source and executable digest were matched against the retained installation manifest when this evidence was retrieved. Subsequent qualification-document changes do not describe a rebuilt executable. The archive selection correction and failed-candidate history are recorded in `2026-11-08-pairing-repair.md`.

## Observed device evidence

A diagnostic copied from the installed app's own sandbox at `2026-11-08T09:17:54Z` reported the exact installed source SHA and digest above, with:

- `paired: true`.
- `videoFramesEnqueued: 1057`.
- `audioFramesScheduled: 868320`.
- `lostFramesReported: 4`.
- `sceneActive: true`.
- `controllerConnected: false`, `controllerInputEvents: 0`.
- `connected: false`, status `Disconnected.` in this snapshot after the playback attempt.

The user report confirms successful playback, and the counters independently establish saved registration and video/audio pipeline activity. Audio scheduling does not independently establish audible sound; queued video buffers alone do not establish visual quality. No controller connected to Vision Pro was observed in this snapshot. No launch, disconnect, install or other device mutation was performed while collecting this success evidence.

## Acceptance and remaining limits

The core feasibility milestone is achieved: a native visionOS client based on Chiaki-ng paired with the local PS5 and played its stream on the user's Vision Pro. The initial UDP discovery termination and stale native-archive packaging defects are repaired and covered by the regression evidence in the pairing investigation.

Audible audio, controller input through the Vision Pro, measured latency, sustained-session quality and reconnect reliability have not been individually accepted. These are further qualification work, not reasons to withhold the successful core milestone. No TestFlight upload, App Review submission or public app release was performed.

The installed app, Keychain pairing, repository source, signed product and original local test evidence remain preserved. The public note is sanitized: it contains no PSN account identifier, code, pairing key, OAuth token, console address or hardware identifier. Raw diagnostics and the original manifest remain ignored local files.
