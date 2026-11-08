# Pairing termination investigation — 2026-11-08

Hunter reported that Sony sign-in completed but tapping Pair PS5 closed the app. A diagnostic retrieved from the original installed app confirmed the account-link success status; no identifiers or credentials were copied into this note.

## Evidence and repair

- A second attempt under `devicectl --console` terminated with signal 13 (`SIGPIPE`), with no core dump. The launch receipt binds this observation to the original executable documented in `2026-11-08-initial-device.md`.
- Native TCP socket setup left `SIGPIPE` enabled. A closed peer could therefore terminate the host process before the existing network-error handling ran.
- A host reproduction using the same socket setup and `chiaki_send_fully` terminated with signal 13. The new child-process regression also failed before the repair with `Closed-peer write terminated with signal 13 (nonblock=1)`.
- Apple socket setup now sets `SO_NOSIGPIPE` per socket. The process-wide signal disposition is unchanged. The behavior follows [Apple's POSIX socket guidance](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/NetworkingOverview/CommonPitfalls/CommonPitfalls.html).
- The regression verifies a successful write followed by a write to a closed peer, in both blocking modes, with the child's default signal disposition. Both now return the expected result without terminating the child.
- The complete host run passed: 106/106 upstream tests, zero skipped; native bridge/input/lifecycle/ECDH and closed-peer regressions; Swift Annex B parser tests.

The on-device debugger could attach but could not halt the launched process, and startup diagnostics did not advance during that attempt. It was detached and that app process was terminated before rebuilding. No failing on-device write stack was captured. The recorded termination signal and the matching host reproduction establish the signal-handling defect; the original headset pairing flow still requires acceptance on the repaired build.

## Delivery boundary

The first candidate advertised source `5a030ce9c59c3f5305a96dfb1fb4e4175db9540f`, runtime digest `13e73e38d6aed9f5126457cdcd8eff3b7bb0be7f1e9d6165a72c0ed79e688601`, and signed executable SHA-256 `7ed3cbd0377ef7cf20632640153ea0b00e0dd736113b28078da3c6ee4fb0ef74`. It built, installed and launched; its sandbox diagnostic at `2026-11-08T08:45:19Z` confirmed that metadata and an active scene. Hunter's pairing retry still terminated with signal 13. This was later traced to stale native-library packaging, so the metadata did not establish inclusion of the native fix.

An opt-in diagnostic launch now converts SIGPIPE to SIGABRT to obtain an interrupted call stack, and a Debug-only fixture driver can attempt registration with synthetic account/code data against a developer-supplied local test console. These diagnostic options are absent from ordinary launches. No real PlayStation account data is used by the fixture driver, and it does not save a pairing.

## Native archive selection defect

The diagnostic candidate advertised source `fe1c921f9fc4263dbb6af0f62f97c91b339fc33f` and had executable SHA-256 `0171c8225d67552cd04aff2f31531b3b0175656d49447264534725db7f50f912`. Its synthetic fixture attempt also exited with SIGPIPE before any fixture packet arrived. The expected C diagnostic marker was present in the fresh native archive and absent from the actual signed executable, while the new Swift fixture marker was present.

Recursive archive selection picked up both the intended `libchiaki.a` and a stale `libchiaki 2.a` backup. The stale copy sorted first and supplied the native definitions. Observed archive SHA-256 values were `502387ab0bd9fffcca93b16d8421d7aebd10693c4a0dacc5c5f77e82b0b161d0` for the stale copy and `7db62a8f33c2df0bf37108e2b08089ae15023fb24abfe2d80d0f48d7f4f08db8` for the fresh diagnostic archive. Source metadata alone did not catch this.

Packaging now selects only the eight explicit CMake target archives, fails if any is missing, and records their individual hashes plus the combined archive hash in the build manifest. A real compiler/linker regression creates fresh and stale implementations with different return values: the old recursive selector linked the stale value `99` instead of `7`; explicit target selection links the fresh value. The missing-target rejection test also passed. Both tests are included in the normal host validation command.

The next physical diagnostic must verify that the signed executable actually contains the fresh native diagnostic marker before installation, then repeat the controlled fixture attempt. The stale backup is preserved locally as investigation evidence and is no longer a linker input.

The exact remaining native failure, original pairing retry and gameplay acceptance remain pending. Sign-in and pairing Keychain items are preserved; the app is updated in place. No TestFlight upload, App Review submission, simulator creation or device reset is part of this repair.

Raw logs and device receipts remain ignored local evidence. This is a sanitized account and does not preserve their exact original bytes.
