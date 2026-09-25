# Round 33 — Builder D report (Open items 49, 53, 52)

Written by the orchestrator from Builder D's final message: the harness refused the builder's own write of this file.

Branch `round33-D`, three commits, each with its tests:

- `22f87b50` notifications: keep the banner's hold across a reconnect (Open item 49)
- `9ee9a836` console: retry agent.rename through a pending launch (Open item 53)
- `511c21ee` notifications: sweep stale temporary files after a replace (Open item 52)

`build-for-testing` (generic iOS) clean at each. The six touched suites on the iPad after the third commit: 155 tests, 0 issues, 0 skipped.

**49.** A cleared snapshot no longer cancels a pane's pending banner hold; if the hold expires while the pane is absent, the banner fires when the pane returns with the same status. A pane back with a different status, or still absent once its Host lists agents again, is dropped as before. The old test `aVanishedPaneCancelsItsPendingBanner` asserted the bug; it was rewritten, and the pane-gone and different-status cases added.

**53.** The only rename path is the Console's Rename Agent sheet; the new-agent form passes its name to `agent.start`, so nothing renames straight after a start. `HostConsoleProjection.renameAgent` retries on `agent_launch_pending` every second for up to 10 s, cancellable; still pending after that, `RenameStore` shows "The agent is still starting. Try renaming it again in a moment." `ScriptedTransport` gained scripted refusals.

**52.** HeelerSSH has no SFTP directory listing or file times, so the sweep lists the temp files with a `/bin/sh` command over SSH, using the Host's clock and GNU or BSD `stat` (script checked on this Mac). It runs in a detached task after a successful replace and ignores failure. Which files to delete is a pure function with its own tests (`NotificationTemporaryFileSweep`, in `NotificationRegistrationFile.swift`).

Builder's open points: nothing tests that the sweep runs only after a successful replace (the only seam is the local-sshd e2e tests); the sweep adds two SSH commands after each replace, so CI e2e tests that count execs or connections around a replace should be checked; `HeelerSSHTransport.swift` may conflict with other picks.
