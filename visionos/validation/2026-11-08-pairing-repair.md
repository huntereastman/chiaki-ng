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

The repaired physical-device build, installation, original pairing retry and gameplay acceptance are pending at this checkpoint. Sign-in and pairing Keychain items are preserved; the app is updated in place. No TestFlight upload, App Review submission, simulator creation or device reset is part of this repair.

Raw logs and device receipts remain ignored local evidence. This is a sanitized account and does not preserve their exact original bytes.
