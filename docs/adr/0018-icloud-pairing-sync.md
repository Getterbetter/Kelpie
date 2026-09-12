---
status: accepted
---

# Pairings ride iCloud Keychain, and the Device Key is shared

## Context

Pairing is a physical ceremony: scan the Pairing Code the plugin renders on the
Mac, enrol this device's Device Key into `authorized_keys`, confirm the host
key, mint a Notification Key and write this device's APNs token into the Host's
`notifications.json` (ADR 0007, ADR 0008). All of that is per-device. Anthony
uses an iPad and an iPhone; pairing the same Host twice means walking back to
the Mac, and a Host added on the road is simply absent from the other device.

Everything a second device needs is either public (the Host's coordinates, its
host-key fingerprints, a public key line) or a secret the Host already holds
(the Notification Key). Nothing needs a server.

## Decision

Carry pairings between the user's own devices through **iCloud Keychain**:
`kSecAttrSynchronizable` generic-password items through the existing
`KeychainSecretStore`, which grew a `synchronizable` flag. No iCloud container,
no CloudKit, no new entitlement, no Kelpie-operated storage of any kind.

Two synced item kinds:

- **One shared Device Key** (service `dev.bybee.heeler.ssh`, account
  `device-ed25519-private-key`) — the synchronizable twin of the device-only
  slot `DeviceKeyStore` already reads. A device with no key of its own adopts
  it and inherits every `authorized_keys` line the sibling already holds.
- **One record per Host** (service `TME.Kelpie.pairing`, account = Host id)
  holding the `Host`, its known-hosts fingerprints, its Notification Key, and
  `pendingPublicKeys`.

`PairingSync` reconciles at launch and on every foreground: adopt the Hosts,
fingerprints and Notification Keys this device does not have, then publish its
own, comparing a content digest so an activation that changed nothing rewrites
nothing. Synchronizable items cannot be `ThisDeviceOnly`, so they take
`AfterFirstUnlock`; the device-only items keep `ThisDeviceOnly` unchanged.

### The sibling-enrolment fallback

A device that already minted its own Device Key before either device synced
must not have it replaced — that would revoke the device from every Host it is
enrolled on. Instead its public key line goes into the Host record's
`pendingPublicKeys`, and whichever sibling can already reach that Host appends
the line to `~/.ssh/authorized_keys` on its next successful connection
and then moves the line into the record's `authorizedPublicKeys`, so a device proposes its key only while it is in neither list and the two devices never ping-pong the same line (`Transport.appendAuthorizedKeyLine`, an atomic temp-file-plus-rename mirroring
the plugin's own `editAuthorizedKeys`) and empties the list. The same
post-connect hook runs `NotificationRegistrationCeremony.register` once for an
adopted Host, because the shared Notification Key is not an APNs token: the new
device still needs its own entry in the Host's `notifications.json`.

A saved Host password is deliberately not synced. It is a user secret with no
role in making a second device work, and a password Host still prompts.

## Consequences

- **The Device Key is no longer per-device.** Two devices present one SSH
  identity, so revoking that key on a Host revokes both. That is the price of
  not pairing twice, and it is what "the user's devices" already means to
  iCloud Keychain. The user-approved key replacement flow is unchanged and
  still affects every device that adopted the key.
- **iCloud Keychain off means no sync**, silently. A missing entitlement, a
  refusing Keychain or an unreachable Host is one logged line and nothing else:
  pairing by hand still works exactly as before, and nothing in the app blocks
  on a sync step.
- **Conflicts resolve by `updatedAt`, and adoption never edits an existing
  local Host.** A sibling that edited a Host more recently than this device
  last published keeps its version of the Host payload; fingerprints and
  pending public keys merge as unions, which is order-independent.
- **The toggle withdraws, but does not revoke.** Turning "Sync Pairings with
  iCloud" off removes the records this device published and stops adopting. It
  never deletes the shared Device Key, which siblings still depend on, and it
  never touches `authorized_keys` on any Host.

## Amendment — 2026-09-12: a newer record moves an existing Host

Adoption used to stop at unknown Hosts, so a Host that *moved* never reached
the sibling: Anthony's mini changed from its LAN address to its Tailscale one
(`100.65.54.52`, no subnet route advertised, so `192.168.x` is unreachable off
the LAN) and the iPhone kept an address it could not dial. `PairingSync` now
also takes a record's **address, port and username** onto a Host this device
already holds — those three and nothing else. The name, the session, the jump
host, the fingerprints, the Notification Key and every key line are untouched,
and nothing is ever deleted by adoption. This supersedes "adoption never edits
an existing local Host" above.

Last writer still wins by `updatedAt`, but it is now weighed against a real
local last-modified time rather than against when this device last published.
`Host` carries no such timestamp and did not grow one: `PairingSync` keeps its
own stamp per Host (`kelpie.pairing-sync.host-edits`) — a digest of the three
fields a record governs, and when this device first saw them — and a reconcile
that finds the digest changed stamps the Host as edited now. The digest covers
those three fields only: a rename is not a claim on the address, and stamping
one would both block a newer remote address and push the stale local one back
over it. Saving a Host runs the reconcile, so an edit republishes then rather
than only at the next launch or foreground. A Host that predates the stamp, or
one this device has never edited, is stamped `.distantPast`, so the
first record that disagrees with it wins. A record is adopted only when it is
**strictly newer** than that stamp, and this device republishes its own Host
payload only when its stamp is strictly newer than the record; equal never
overwrites either way. The cost of stamping at reconcile rather than at the
moment of editing is granularity: an edit is dated when the app next
reconciles — which a save now triggers — and that rounds in favour of the local
edit, never against it.

## Amendment — 2026-09-12: deletions travel, fingerprints follow coordinates, and the Console asks

A robustness review of identity and durable state found three ways the sync
above undid the user's own actions, all of them silent.

**A record's fingerprints travel with its coordinates.** The move amendment
above took a sibling's address, port and username onto an existing Host but
left its known-hosts pins behind — only the never-seen-before branch imported
them. So the Host arrived at an address this device had no trusted key for,
and every connection failed `hostKeyRejected`. `adoptCoordinates` now runs the
same import the add path does, for **endpoints it has no pin of its own for**:
a record may fill a gap, never retire a pin this device confirmed itself. That
distinction is what keeps a changed key a mismatch failure rather than a
silently accepted one.

**The Console asks about an unknown key instead of refusing it.** Its policy
was `{ _ in false }`, on the reasoning that the Console has no screen to ask
from. That was right while the only unpinned Host was one the user had never
confirmed anywhere, and wrong once a Host can arrive from a sibling or move to
a new address: the Host became unreachable until the user found Edit Host →
preflight, with no prompt anywhere on the root screen. `HostKeyConfirmationBroker`
carries the question to whichever screen applied `hostKeyConfirmation()`, using
preflight's own alert copy; with no screen mounted it declines at once, exactly
as before. A **mismatch** never reaches it — that is still a hard failure.

**A deletion is a fact, and it syncs.** Deleting a Host removed only this
device's record, so the sibling's next reconcile published it back and this
device re-adopted it, Notification Key and all. Deletion now writes a
**tombstone** — Host id and `deletedAt` — under a `deleted-<uuid>` account in
the same Keychain service. A build that predates tombstones ignores them (they
are not bare UUID accounts); a build that has them deletes the Host locally
when the tombstone is newer than its own last edit of it, through
`HostStore.remove`, so the password, the Notification Key and the device's
registration go with it. The same last-writer-wins rule as the coordinates: a
Host edited here *after* the deletion survives and is republished. Tombstones
expire after 30 days — longer than any device stays away, and an expired one
only stops suppressing a record nobody publishes any more. Turning sync off
withdraws this device's records but deliberately leaves tombstones: they can
only ever suppress, never resurrect. Re-pairing a deleted Host mints a new id,
which no tombstone names.

**A re-pair is an edit.** Pairing a machine this device already has updates
that Host in place and keeps its address, port and username, so the reconcile's
digest of those three fields does not change and the pairing was invisible to
the conflict rule — an older tombstone would then delete the Host that had just
been paired. The stamps moved out of `PairingSync` into `PairingSyncHostEdits`,
which the pairing ceremony writes too: a pairing that updates a row stamps it
"edited here, now", so it out-dates any tombstone and republishes. And
`publish` re-checks that the Host still exists, and that no tombstone names it,
after every suspension and immediately before writing its record: reading a
Host's fingerprints suspends, and a delete in that gap used to be answered with
a freshly stamped record that resurrected the Host on both devices.

### Still open

The conflict clock is unchanged, and is still last-writer-wins on each
device's own wall clock with no skew guard and no logical counter: a device
whose clock runs ahead wins every conflict, and can now win a deletion too.
Bounding an implausible future `updatedAt`, or carrying a monotonic revision
counter beside the timestamp, is the fix; it was set aside deliberately rather
than half-done, because the rule governs adoption, publication and deletion at
once and wants changing in one piece.
