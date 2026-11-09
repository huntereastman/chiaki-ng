# Extreme Play crash repair: build 4

November 8, 2026. Status: Hunter confirmed the real PS5 retry worked. The separate selected visual target is not yet fully qualified.

## Cause and change

Build 3 (`c581c1c437f54902319f6a4be46861f571a9af94`) terminated in `swift::_getWitnessTable` while `ExtremeLightRig` initialized `SpotLightComponent.ProjectiveTexture`. Two device crash reports reproduced the same stack. The headset runs visionOS 27.0 beta `24M5306i`; the build uses Xcode 27.2 `27B52`.

Build 4 checks the loaded public RealityKit API exports before touching either new light component, and keeps their type metadata access in separate non-inlined functions. The headset confirms it lacks the current ProjectiveTexture conformance, while the initializer, metadata and SurroundingsLight exports are present. An OS version check alone was insufficient.

The four flowing sheets remain enabled. This headset uses three bounded colored surroundings lights instead of animated projection textures. Their intensity follows Simple's scale, avoiding the much stronger white intensity intended for masked projections. The player shows the limitation inline; Simple remains selectable.

## Exact installed source

- Repository: https://github.com/huntereastman/vision-remote-play
- Branch: `codex/visionos-prototype`, remotely verified after push.
- Repair base: `c581c1c437f54902319f6a4be46861f571a9af94`.
- Build 4 source: `b0469677b430b834c404ff54303a456feb960e07`.
- Source tree: `53f6dae69e7f1523f7048f7c06257723b4cf33f7`.
- Runtime source digest: `8df2ea73c1bcc2aefe7ce66e577711905b26125ec2551b9ab5d74d1566515a94`.
- Signed executable SHA-256: `a66afd685a13ac76b3b25b5f8157c061a809f2907b41aebc4c1e3abf4a236246`.
- Executable UUID: `41CF7579-3FAC-3C37-B3A8-23AD1D544669`.
- Native archives reused only after source/submodule and exact digest checks; the earlier blocked-display crash repair remains included.
- Selected visual reference remains `extreme-lighting-selected-reference.png`, SHA-256 `6f6e6ddbf8ba464de25504b4dc720124d22c47e488e51c40b18ed6ec900809f7`.

## Evidence

Installed build readback identifies version 0.1.0, build 4. The physical device launch receipt records the installed executable path and process. Diagnostics match both the source SHA and digest above.

A deliberate `VRP_AMBIENT_PROOF=1` launch exercised the real immersive scene using synthetic H.264 frames. At 2026-11-09 01:09:39 UTC it recorded four active sheets, 1,387 completed GPU updates, zero GPU failures, zero skipped updates, three active colored room lights, and 494 queued synthetic video frames. Pairing remained saved. This proves the failing initialization now completes and the sheet workload runs on this headset. It does not prove visual quality, physical illumination, controller/audio behavior or real PS5 playback.

The lighting regression covers each missing API export and specifically a missing conformance with other exports present. Removing the conformance requirement makes it fail; the corrected version passes. Current-source Swift bitstream, ambient sampling/preferences, decoded-video integration and reset checks pass. The retained unchanged native test artifacts pass the earlier blocked-display, SIGPIPE and protocol regressions; upstream reports 106/106 successful. Build/archive selection reports 2/2 successful. The signed physical-device build succeeds.

The synthetic session was then stopped and the normal app was relaunched for the user's PS5 retry. No pairing reset, simulator creation, store upload or OS update was performed.

## Real PS5 retry accepted

Hunter replied “That worked” after the build 4 retry. A read-only device snapshot at 2026-11-09 01:14:49 UTC matches the installed source and contains no synthetic fixture marker. It records 1,265 queued video frames, 2,110,080 scheduled audio frames, 165 ambient color samples and 1,030 completed Extreme GPU updates with zero GPU failures. The snapshot was taken after the session had disconnected and become inactive; it does not claim the session remains connected.

This closes the reported Play crash. Hunter's statement confirms that the retry worked, not full visual parity or prolonged stability. Controller input was not observed in this snapshot. Animated room projection remains unavailable through this SDK's ProjectiveTexture conformance on the installed beta; the selected visual target remains a separate qualification.

The accepted signed app, source identity and crash evidence are retained. The cleanup check found no eligible candidate because DerivedData had changed within ten minutes. No cleanup timer was created.
