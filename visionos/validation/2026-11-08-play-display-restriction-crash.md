# Play crash on a restricted PS5 screen

The installed build 2 (`b3605d06f9ee9b181533eaa82f53a07ae8758ba5`) terminated when Hunter tapped Play. Its crash report and app diagnostic bind the failure to the installed executable UUID `74fbe9db-4371-3208-b865-8c05d471c07d` and source digest `0749b642887a99cd586250e53e36ef4bb3790e123253701268842e5b6313522d`.

The faulting thread was the native control handshake. Its program counter was zero and its return address symbolicated to `ctrl_connect` immediately after the unguarded `display_sink.cantdisplay_cb(..., true)` call for `RP-Prohibit: 1`. The bridge never installed a display sink. The report's CODESIGNING/Invalid Page label was not evidence of corrupted signed bytes: the executable UUID matched and strict signature verification passed. The concrete defect was the missing callback.

The bridge now installs its display handler before starting the session. A prohibited-screen notification enters the existing asynchronous error/disconnect flow and explains that the user should return the PS5 to its home screen or a game before retrying. An allowed-screen notification makes no error. This preserves the current player, lighting and pairing UI.

A child-process regression initializes the real production bridge and session, substitutes only asynchronous network start, and delivers the same native display notification without contacting a console. Before the fix it terminates with signal 11. After the fix both allowed/prohibited notifications complete, and the existing input, lifecycle, ECDH and socket-signal regressions pass. The unchanged upstream native suite also passes 106/106 cases.

The device build rebuilds only `RemotePlayBridge.c.o`, verifies every other archive member is byte-identical, and links only the existing explicit target archives. Dependency headers are checked against their pinned commits. The native derivation, compiled object and final executable are recorded independently.

Raw crash SHA-256: `42169e2e3db0a11104d67cb6c5eae761753ae6d1fe9af23b37e5d15585f0f68a`. Raw reports, development signing data and device identifiers remain outside Git. This is a sanitized summary; it does not preserve original crash bytes. Physical Play acceptance on corrected build 3 remains a separate result.
