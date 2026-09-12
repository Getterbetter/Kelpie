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
