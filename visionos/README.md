# Native visionOS Remote Play prototype

A native SwiftUI front end for the Chiaki-ng Remote Play core, for a developer-owned PS5 and Apple Vision Pro on the same local network. This prototype reuses Chiaki-ng's C protocol implementation; it is not an independent rewrite of that implementation.

Source: <https://github.com/huntereastman/chiaki-ng/tree/codex/visionos-prototype/visionos>

## Scope

- PS5 registration using a PSN account ID and an eight-digit Link Device code.
- H.264 video at a requested 1080p/60 or 720p/60, shown in a native visionOS window.
- Opus audio decoded to PCM and played through AVAudioEngine.
- Physical game controller input through Apple's Game Controller framework.
- Account IDs and console pairing keys stored in the device's Keychain.
- Local diagnostic counters and build provenance, without account IDs, pairing codes, OAuth tokens or console keys.
- An ambient-lighting proof with a saved on/off toggle, directional screen glow, and a mixed-space player. On visionOS 27 it also uses two bounded surroundings lights.

Internet traversal, PSN cloud gaming, HDR, frame generation, upscaling, immersive curved screens, haptics and adaptive triggers are outside this first prototype. The local-only target excludes the PSN/UPnP/TLS traversal stack and rejects non-private IPv4 console addresses. That restriction does not change the upstream desktop build.

This is development software. Successful compilation and unit tests do not establish console pairing, visible video, audible sound, responsive control or session reliability. Record those results separately after real-device tests.

On November 8, 2026, the user confirmed successful playback from their real PS5 on their Vision Pro. Device diagnostics independently confirmed saved pairing, 1,057 queued video frames and audio pipeline activity. See the [physical-device acceptance record](validation/2026-11-08-successful-playback.md) for the exact installed source, artifact and remaining qualification limits.

## Source and dependencies

Integration base: `chiaki-ng/chiaki-ng`, `main`, commit `43728af2e639fecb8a7af1cd68c29820a40de973`.

The fork adds the native application under `visionos/`, a local-only library build profile, mbedTLS 3.x compatibility in the crypto adapter, and a correction to the mbedTLS key-import implementation. The upstream known-answer tests cover the key-import and cryptographic operations.

Additional pinned dependencies:

- mbedTLS v3.6.7: `068ff080b369adfac81509f9b57b2afabaf82dc5`
- Opus v1.6.1: `22244de5a79bd1d6d623c32e72bf1954b56235be`

Chiaki-ng's existing nanopb, Jerasure and GF-Complete submodules are retained. Their original licences and copyright notices, plus the AGPL text, are included in `Resources/ThirdPartyNotices.txt` and the app bundle.

## Build and host validation

Requirements: Xcode with the visionOS SDK, XcodeGen, `protoc`, Python 3 and a local Apple Development signing identity. The build script installs its pinned CMake and protobuf tools in an isolated `.build-tools` environment when needed.

From the repository root, initialize only the required submodules:

```sh
git submodule update --init --depth 1 third-party/nanopb third-party/jerasure third-party/gf-complete test/munit visionos/Dependencies/mbedtls visionos/Dependencies/opus
git -C visionos/Dependencies/mbedtls submodule update --init --depth 1 framework
python3 visionos/build.py host
```

Host validation runs the upstream protocol tests, local-only bridge validation and ECDH key agreement, stream/datagram EPIPE regressions, Swift Annex B parser boundary tests, and real-link archive-selection regressions. Ambient tests exercise actual color extraction, saved on/off preferences, stopping sampling, a synthetic H.264 stream through the shared decoder, and rejecting old decoded output after reset. They do not establish headset appearance or streaming performance.

For the physical Vision Pro:

```sh
python3 visionos/build.py device --device YOUR_ALREADY_PAIRED_VISION_PRO_UDID
```

The script builds for a physical `visionOS/arm64` destination. It creates no simulator. Device signing uses an existing, unexpired local wildcard development profile that already covers the specified device and a matching signing identity. It does not register a device, create an App ID, refresh a profile or upload a build. The current project selects Hunter's existing development team; another developer should change the team/profile selection for their own environment.

The unsigned build product is under `visionos/DerivedData/Build/Products/Debug-xros/`. The signed app is staged in a task-owned directory under `~/Library/Caches/codex-vision-remote-play/` to avoid File Provider metadata being attached during signing. Its exact path, build source and executable hashes are recorded in `visionos/build/xros/build-manifest.json`. The app's Info.plist carries the source SHA and source digest. No TestFlight or public distribution is part of this workflow.

Install and launch with the guarded entry point, which checks source freshness, embedded source identity and the signed executable digest before any device mutation:

```sh
python3 visionos/install.py --device YOUR_ALREADY_PAIRED_VISION_PRO_UDID --host YOUR_PS5_LOCAL_IP
```

Use `--no-launch` to install the qualified app while leaving launch for an unlocked headset.

## Initial use

1. Enable Remote Play on the PS5 and keep both devices on the same network.
2. Launch the prototype on Vision Pro and enter the PS5's local IP address.
3. Sign in on Sony's website in the account sheet, or enter a previously obtained numeric/Base64 account ID under Advanced. The app retrieves the account ID; it does not save the Sony password or OAuth tokens.
4. On PS5, open Settings → System → Remote Play → Link Device. Enter the fresh eight-digit code and select Pair PS5.
5. Pair a physical controller to Vision Pro, then select Play.

Disconnect ends the stream without putting the console to sleep. Forget Console deletes only this prototype's saved console pairing. Closing/backgrounding the app stops the stream.

## Ambient-lighting proof

`Ambient lighting` is the single saved setting beside picture quality. With it enabled, Play opens a mixed immersive player with a soft directional halo. The compact playback strip fades after four seconds; tap the player to reveal it. VoiceOver keeps the strip available. Toggle lighting during play to compare off/on; the Window button returns to ordinary window playback. Canceling immersive presentation retains window playback.

The halo follows four sampled image-edge colors with time-based smoothing. The image remains unobscured. Sampling runs at up to 5 Hz on a separate queue, has at most one analysis in flight, stops when lighting is off/inactive, and fades to black when video stalls. The visionOS 27 lights are bounded and removed under serious thermal pressure; older supported systems retain the halo.

The first path tries the renderer's displayed pixel buffer. Apple's API returns nil at nonzero renderer rates; a native macOS probe observes rate 1 and no buffers. After three unavailable samples on a fresh stream, the app switches to one VideoToolbox decoder and shares its output with the display and color sampler. It flushes the renderer's compressed path, waits for an IDR, bounds in-flight decode work, and discards prior-session output. It does not run a second full-rate decoder for the lights. Once selected, that decoder remains the playback path for the session; switching the lighting off stops optional sampling, without switching decoders mid-game.

For a synthetic headset check without contacting a PS5, install the Debug build and launch it explicitly with `VRP_AMBIENT_PROOF=1`. The fixture loops app-owned H.264 color frames and never changes account or pairing data. It is excluded from Release code and has no customer-facing demo control. Normal launches do not use it.

```sh
xcrun devicectl device process launch --device YOUR_ALREADY_PAIRED_VISION_PRO_UDID --terminate-existing --environment-variables '{"VRP_AMBIENT_PROOF":"1"}' dev.hunter.visionremoteplay
```

`Tests/GenerateAmbientFixture.swift` reproduces `Resources/AmbientProof.h264frames`. `Tests/RendererReadbackTests.swift` optionally takes an output folder as its second argument to render the actual halo component on/off with decoded synthetic pixels. Those native previews are not headset captures. Qualify real PS5 playback, the on/off setting, room spill, comfort and frame pacing separately on physical Vision Pro.

## Runtime evidence

The app writes `Documents/diagnostics.json` in its own sandbox. It distinguishes session connection, video buffers enqueued, audio frames scheduled and controller input events; those counters alone are not an end-to-end latency or visual-quality measurement. Read the actual headset display and test gameplay before claiming playback quality.

Keep raw diagnostic files, temporary auth material and crash reports outside Git. Retain only sanitized qualification notes with exact source/artifact hashes. The prototype preserves the AGPL licence and attribution; commercial App Store distribution is separate work.
