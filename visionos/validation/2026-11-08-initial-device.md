# Initial physical-device qualification — 2026-11-08

**Later qualification correction:** the pairing investigation found that recursive native-archive packaging included a stale `libchiaki 2.a` backup alongside the intended target. The app's source metadata and signed executable digest below still identify that installed artifact, but they do not prove that every linked native object came from the advertised commit. See `2026-11-08-pairing-repair.md` for the reproduced packaging defect and corrected archive selection. Initial source-binding claims must be read with this limitation.

## Source binding

- Upstream repository: `https://github.com/chiaki-ng/chiaki-ng.git`
- Integration base: `main` at `43728af2e639fecb8a7af1cd68c29820a40de973`, freshly verified during preparation.
- Prototype repository: `https://github.com/huntereastman/chiaki-ng.git`
- Prototype branch: `codex/visionos-prototype`
- Installed runtime source commit: `a0fc4f1efeb99d68b6fbb9e4f1ef8afefc1b1ada`
- Installed runtime source tree: `a006170eb8daa136e3e28b7a2b561237bbb5598d`
- Runtime source digest: `650e2d32b98aa6131984111048a9cb5b6426c6bf36e2ac09e26b0b484b9fcb3b`
- Signed executable SHA-256: `47fd8f4478e1be6d8a329df151e31ce55551c1d820ec7ddecf796fdde9ca8e7e`
- Installed bundle: `dev.hunter.visionremoteplay`, version `0.1.0`, build `1`.
- Build: Xcode 27.2, physical visionOS/arm64 target, local Apple Development signing.

All runtime source changes were committed before this build. This qualification note and the Python bytecode ignore rule are later non-runtime changes; they do not describe a rebuilt or reinstalled app.

## Observed results

- The PS5 responded to a bounded local-network discovery request. Its address and device name are deliberately omitted here.
- All 106 upstream protocol tests passed, with zero skipped.
- The additional native bridge input/lifecycle and ECDH key-agreement test passed.
- Swift H.264 Annex B parsing boundary tests passed.
- The physical-device application compiled, was signed using an existing eligible development profile, and passed strict recursive code-signature verification.
- The guarded installer verified current source identity and executable digest before installation.
- The corrected app installed and launched on the already paired physical Vision Pro.
- A file retrieved from the installed app's own sandbox at `2026-11-08T08:19:16Z` reported `sceneActive: true` and the exact installed source SHA/digest above.

At that observation, the app reported `paired: false`, `connected: false`, no connected game controller, and zero video/audio/input counters. This proves application startup and source identity, not working Remote Play.

## Remaining hardware acceptance

Hunter has been asked to complete Sony sign-in and console registration in the app, pair a DualSense with Vision Pro, then select Play. Pending results are console pairing, visible gameplay, audible audio, controller response, sustained playback and reconnect behavior.

The Mac Device Hub reported Screen Sharing Unavailable for this headset session. The rendered application has not been visually inspected through the Mac viewer. User observation or a later working screen-share session is needed for visual acceptance.

The initial development launch failed because an unsigned Xcode debug dylib could not be loaded. The application now uses a monolithic executable, signs its built product outside the File Provider managed Documents directory, and verifies its complete signature before installation. A subsequent unsigned update attempt was rejected by device signature validation; the guarded installation entry point now rejects unqualified artifacts before attempting device installation.

## Scope and retention

This is a Chiaki-ng based AGPL prototype. It has not been uploaded to TestFlight, submitted to App Review, or publicly released as an app. No simulator was created or used, and no other app or device data was erased.

Raw local device receipts, the development provisioning profile, crash records and build products remain outside Git. This note is sanitized evidence and does not claim to preserve those original file bytes. Pairing keys, account IDs, OAuth tokens and passwords are not recorded in this note or diagnostic counters.

The checkout and its small build outputs remain active for the pending hardware test. The exact signed app path is recorded in the local build manifest under `visionos/build/xros/`; its task-owned staging directory is under `~/Library/Caches/codex-vision-remote-play/`. No human-only continuation timer is needed.
