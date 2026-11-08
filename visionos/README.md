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

Internet traversal, PSN cloud gaming, HDR, frame generation, upscaling, immersive curved screens, haptics and adaptive triggers are outside this first prototype. The local-only target excludes the PSN/UPnP/TLS traversal stack and rejects non-private IPv4 console addresses. That restriction does not change the upstream desktop build.

This is development software. Successful compilation and unit tests do not establish console pairing, visible video, audible sound, responsive control or session reliability. Record those results separately after real-device tests.

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

Host validation runs the upstream protocol tests, local-only bridge validation and ECDH key agreement, and Swift Annex B parser boundary tests.

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

## Initial use

1. Enable Remote Play on the PS5 and keep both devices on the same network.
2. Launch the prototype on Vision Pro and enter the PS5's local IP address.
3. Sign in on Sony's website in the account sheet, or enter a previously obtained numeric/Base64 account ID under Advanced. The app retrieves the account ID; it does not save the Sony password or OAuth tokens.
4. On PS5, open Settings → System → Remote Play → Link Device. Enter the fresh eight-digit code and select Pair PS5.
5. Pair a physical controller to Vision Pro, then select Play.

Disconnect ends the stream without putting the console to sleep. Forget Console deletes only this prototype's saved console pairing. Closing/backgrounding the app stops the stream.

## Runtime evidence

The app writes `Documents/diagnostics.json` in its own sandbox. It distinguishes session connection, video buffers enqueued, audio frames scheduled and controller input events; those counters alone are not an end-to-end latency or visual-quality measurement. Read the actual headset display and test gameplay before claiming playback quality.

Keep raw diagnostic files, temporary auth material and crash reports outside Git. Retain only sanitized qualification notes with exact source/artifact hashes. The prototype preserves the AGPL licence and attribution; commercial App Store distribution is separate work.
