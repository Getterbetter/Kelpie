# Robustness review

Anthony, 2026-09-12: "the issue of not registering the ios app for notifications has me slightly concerned that the app is not robust ... can we review properly and fix the gaps?" Four fresh-context reviews, one per subsystem, coverage first; full findings in [[Archive/round12/notifications|notifications]], [[Archive/round12/identity|identity]], [[Archive/round12/transport|transport]], [[Archive/round12/screen|screen]].

## The verdict, in one paragraph

All four reviewers reached the same conclusion independently: the hard parts (the SSH transport, the Keychain split, the resize coalescer, the fail-closed notification semantics) are careful work with real tests, not "quickly put together". The weakness is one shape repeated at the edges of every lifecycle: **a fact about the outside world is captured once and never re-read, retired or carried along** — the push entry on the host, the APNs environment, the hardware-keyboard answer, the Host's session name, the fingerprint that does not travel with an adopted address, the Notification Key that outlives its Host, the reconnect that resets the banner baseline. The fix is a habit, not a rewrite: revalidate on launch and foreground, carry state with the record it belongs to, retire it with the record, and say so on screen when a neighbour is unhealthy.

## Ranked gaps

Must-fix (round 12c builders, 2026-09-12):

| # | Area | Gap | Where |
|---|---|---|---|
| 1 | identity | Adopting a synced address carries no fingerprint; the sibling is rejected with no prompt after the Tailscale switch | `PairingSync.adoptCoordinates` |
| 2 | notifications | A Release build on a dev profile writes `production` with a sandbox token (`#if DEBUG`, not the entitlement) | `PushRegistrationStore` |
| 3 | notifications | `willPresent` discards every push in the foreground even when the in-app banner cannot fire | `AgentNotificationCenterDelegate` |
| 4 | notifications | Every reconnect resets the banner baseline; a Blocked/Done across sleep or a Wi-Fi switch never surfaces | `HostConsoleProjection`, `AgentNotificationBannerStore` |
| 5 | notifications | Permission revoked in iOS Settings is never noticed; Settings says Ready forever | `PushRegistrationStore.refresh` |
| 6 | identity | Deleting a Host leaves no tombstone; the sibling resurrects it | `PairingSync` |
| 7 | identity | Deleting a Host keeps its Notification Key and its entry on the host | `HostStore` removal |
| 8 | client | The herdr session name is snapshotted at view construction; edits take effect only after relaunch | `HerdrClientRootView`, `HerdrClientStore` |
| 9 | client | Wind-down awaits terminal idle unbounded on the chain that ends at the background assertion | `EventsSession.windDown` |

Should-fix, taken in the same round: no path monitor (S1) and attach death not marking the transport suspect (S2); `rejoinRequired` with no overlay and Reconnect a no-op (S3); unbounded `prepareForConsole` with no UI (S4); `open(nil)` deep link does nothing (N5); a health line in Notification settings — entry env vs build env, refresh on foreground (N6, N7); swallowed side-path errors (N8); re-pairing duplicates the Host (I4); adopted password Host with no hint (I5); newer catalog version blocks all writes (I6); one bad known-hosts value wipes every pin (I8); sticky modifier outliving the key bar (Sc2); hardware-keyboard state not re-read on foreground (Sc3); host-path tap swallowing herdr clicks (Sc5); the shadow line desync that the double-space fix counts against (Sc6); capsule and key bar under 44 pt, no Dynamic Type (Sc7, Sc8).

Set aside for now: LWW on wall clocks (I7), the reattach freeze leash (Sc4 — measure with the key trace first), Client-layer test coverage (S5 — builders add tests for what they touch), and every nit; they stay in the archive files.

Related: [[Open items]] · [[Decisions]] · [[Testing status]]
