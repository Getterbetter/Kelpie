---
note: Getting the Mac mini and the iPad talking — the steps that actually worked.
---

# Pairing and setup

Kelpie uses [[Heeler upstream|Heeler]]'s pairing flow unchanged: the **upstream** herdr plugin runs on the Mac mini and mints a Pairing Code; the app scans or pastes it, connects once with a single-use bootstrap key, enrols its own device key in `authorized_keys`, and from then on uses ordinary SSH public-key auth.

## On the Mac mini

**Prerequisites**

- herdr ≥ 0.7.5 running (`herdr --version`)
- Node.js ≥ 20 on `PATH` (`node --version`)
- An OpenSSH server: **System Settings → General → Sharing → Remote Login**. The Pairing Code pins this machine's SSH host-key fingerprint, so it must be running before the code is minted. The advertised SSH port is currently fixed at 22.

**Install the plugin and open the pairing popup**

```sh
herdr plugin install ZingerLittleBee/Heeler/plugin --ref main --yes
herdr plugin list --plugin heeler          # confirm installed and enabled
herdr plugin action invoke heeler.pair
```

herdr clones the plugin into its managed checkout and runs `npm ci` itself. Re-running the same `install` command updates it.

> **The popup opens inside herdr's TUI, not in the shell.** `plugin action invoke` returns to the prompt and the pane appears in the herdr client. If you are looking at a shell and nothing happens, look at herdr.

**In the popup:** arrows or `j`/`k` move, space toggles an address, `a` toggles all, **enter** mints a single-use Ed25519 Bootstrap Key and renders the QR, `q`/escape closes and revokes the key. On the QR screen **`c` copies the Pairing Code** (via `pbcopy` on macOS) and any other key closes. When a code expires, enter mints a fresh one. Once a device enrols, the QR is replaced by a success screen showing the enrolled key's fingerprint; `r` there revokes it.

## On the iPad

1. Open Kelpie. With no Hosts it shows the console's "No Hosts" onboarding — that path is deliberately unchanged.
2. Add the Host from the Pairing Code.
3. **Kelpie did not recognise the QR.** Pressing `c` in the popup to copy the Pairing Code and pasting it into Kelpie over the **iCloud universal clipboard** worked cleanly, first try. Use that route.
4. The code carries the machine's addresses, the SSH port, the username, the pinned host-key fingerprint, and the bootstrap key's seed and expiry — so there is no TOFU prompt to accept.
5. Kelpie then becomes the primary Host automatically (`kelpie.primary-host`, first Host by default) and opens straight onto herdr's TUI. Switch or change it later from **Switch Host** in the floating `ellipsis.circle` menu.

The Pairing Code itself is a single line, `HERDR-PAIR:1:<base64url(JSON)>`; the QR is only a rendering of it, which is why pasting is equivalent.

## Notifications

The upstream instructions say to enable Agent Notifications in Settings, grant the iOS permission, enable Notifications for the Host, and leave **Custom Push Relay** empty. **Do not expect this to work in Kelpie.** The production relay signs for bundle `dev.bybee.heeler` and Apple will reject a push aimed at `TME.Kelpie`. Kelpie needs its own relay deploy first — the full explanation is in [[Heeler upstream]], and it is item 3 in [[Open items]].

## Troubleshooting

**Plugin side — pairing or notification failures:**

```sh
herdr plugin log list --plugin heeler --limit 20
```

Other useful checks: `herdr plugin config-dir heeler` for where its state lives; re-running `herdr plugin install …` to update.

**App side:** the app surfaces preflight errors directly — a missing socket, a server that denies stream-local forwarding (OpenSSH allows it by default), or a `herdr` binary not on the non-interactive `PATH` (exit 127 → "herdr binary not found"; `HerdrHostPath` already appends the well-known install prefixes).

**Device side:** for launch-time problems, `xcrun devicectl` is the tool — see [[Build and deploy]].

Related: [[Architecture]] · [[herdr]] · [[Testing status]]
