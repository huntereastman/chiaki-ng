# Extreme lighting prototype

Requested outcome: preserve Simple and add a first native Extreme treatment centered on the selected light sheet, fluid motion, and coordinated room lighting. Local development installation only.

Source baseline: `227f0b3224af443afba05074ede0e84d95e1ef01` on `codex/visionos-prototype`, repository `huntereastman/vision-remote-play`. Remote `main` was read separately as `43728af2e639fecb8a7af1cd68c29820a40de973`; this prototype is not represented as integrated or Apple-distribution-qualified.

Visual reference SHA-256: `6f6e6ddbf8ba464de25504b4dc720124d22c47e488e51c40b18ed6ec900809f7`. The accepted Simple source and signed app remain retained for comparison.

## Implemented

- Four curved 3D sheets, GPU mesh deformation, irregular fine filaments and broad flowing folds, additive transparent material.
- Three animated projective spotlights share the sheets' color and motion field: left, right, and lower/floor. Physical surroundings lighting uses the visionOS 27 component.
- Saved Simple/Extreme selection alongside the existing ambient on/off setting. The first Extreme prototype defaults to Extreme when no mode has been saved.
- Existing decoded-video palette, source fading, thermal suppression of room lighting, player, audio, controller, pairing and network paths retained. Reduce Motion freezes deformation phase.
- Bounded GPU submissions; disabled effects stop encoding. Metal resources are included in source and artifact digests. Native streaming libraries are reused only after source, submodule and archive digest checks.

## Local verification

- Physical visionOS target compiled during implementation; final signed installation has its own build/install receipts.
- Native macOS RealityRenderer preview renders the actual mesh/material/compute code from front and angled views. The refined preview shows wall and floor projection; this is a virtual-room test, not physical surroundings proof.
- 124 submitted/completed GPU frames with zero GPU failures in the preview; off-state check passes. Timing is Mac evidence only.
- Existing ambient palette and persisted on/off checks pass, extended for independent persisted Simple/Extreme selection. Build archive selection tests pass.
- Diff review: Simple renderer and core playback paths retained. UI changes are the mode selectors and a concise renderer-failure status; mesh placement measures the existing player rectangle.

## Headset acceptance still needed

Inspect fluid motion, stereo depth and player clearance, switching Simple/Extreme/off, and moving light on the actual walls/floor. The native preview does not qualify physical surroundings brightness or sustained playback performance. This first prototype is not the full customization editor or final reference match.

Apple API references: [spotlights](https://developer.apple.com/documentation/realitykit/spotlightcomponent), [projective textures](https://developer.apple.com/documentation/realitykit/spotlightcomponent/projectivetexture), [surroundings lights](https://developer.apple.com/documentation/realitykit/spotlightcomponent/surroundingslight).
