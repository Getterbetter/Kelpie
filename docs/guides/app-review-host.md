# Stand Up a Review Host for App Review

Kelpie does nothing without a machine running herdr, and demo mode is compiled
out of every device build. This runbook stands up a throwaway Linux VPS that
*is* the herdr Host, so an App Review reviewer can pair with it and see the app
working. No Mac behind it, no reverse tunnel:

```text
Reviewer iPad -> VPS public TCP 22 -> herdr API socket + Attach PTY
```

For the NAT case (a Mac behind a jump host) use
[VPS Jump Host and Reverse-Tunnel Deployment](vps-jump-host.md) instead.
About 20 minutes end to end. Delete the VPS once the app is approved.

## Variables

| Placeholder | Example | Meaning |
|---|---|---|
| `VPS_IP` | `203.0.113.10` | Public IPv4 of the review host |
| `SSH_PORT` | `22` | Public SSH port; the plugin pins 22 (known limitation) |
| `REVIEW_USER` | `review` | Unprivileged account herdr runs as |
| `DEMO_DIR` | `/home/review/demo` | Working directory the panes open in |
| `HOST_FP` | `SHA256:...` | VPS SSH host key fingerprint, shown at pairing |
| `REVIEW_PW` | long random string | Only for the password fallback in step 4 |

Replace every uppercase placeholder before running a command. Do not paste a
command that still contains one.

## 1. Provision

Any provider works. Choose:

- **Image**: Ubuntu 24.04 LTS.
- **Size**: smallest instance, 1 vCPU / 1 GB RAM; take the default swap if
  offered.
- **Network**: a public IPv4. IPv6-only will not do — the Pairing Code carries
  addresses the iPad must reach directly.
- **Auth**: upload your SSH public key at create time, password login off.

Cost is about **US$4–6 a month** at this size (Hetzner CX22, DigitalOcean 1 GB,
Vultr 1 GB). Billing is hourly with most providers, so a two-week review window
costs a couple of dollars. **Delete the instance after approval** (step 7).

## 2. Harden

Runs on the VPS as root (`ssh root@VPS_IP`). Update, then create the
unprivileged account and give it your key:

```bash
apt update && apt -y full-upgrade
adduser --disabled-password --gecos '' review
install -d -m 700 -o review -g review /home/review/.ssh
install -m 600 -o review -g review /root/.ssh/authorized_keys /home/review/.ssh/authorized_keys
```

Write the SSH policy as a drop-in rather than editing `sshd_config`:

```bash
cat >/etc/ssh/sshd_config.d/10-kelpie-review.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers review
AllowStreamLocalForwarding yes
EOF
sshd -t && systemctl reload ssh
```

`AllowStreamLocalForwarding yes` is load-bearing: Kelpie reaches herdr's JSON
API over OpenSSH **direct-streamlocal** channels onto the Unix socket, with no
socat and no Host-side helper, and a server that denies stream-local forwarding
fails Kelpie's preflight rather than falling back. Do **not** set
`DisableForwarding`, and leave `MaxSessions` at its default of 10 — the RPC
queue and the Attach PTY are ordinary session channels and need the room.

Firewall, unattended security updates, and the fingerprint for the notes:

```bash
ufw default deny incoming && ufw default allow outgoing
ufw allow SSH_PORT/tcp && ufw --force enable && ufw status verbose

apt -y install unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades

ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub    # HOST_FP
```

Keep this root session open until step 6 has passed.

## 3. Install herdr, the plugin, and the demo panes

Everything here runs **as `review`** (`ssh review@VPS_IP`).

```bash
curl -fsSL https://herdr.dev/install.sh | sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"
herdr --version    # 0.8.x
```

The installer only drops a checksum-verified binary in `~/.local/bin`: no rc
file, no unit, no service (verified against `https://herdr.dev/install.sh`).
Config and the API socket live in `~/.config/herdr/` (`herdr.sock`).

The Heeler plugin needs Node 20+, then installs **from this repository**:

```bash
sudo apt -y install nodejs npm     # or nodesource for a current Node
node --version                     # >= 20
herdr plugin install Getterbetter/Kelpie/plugin --ref kelpie --yes
herdr plugin list --plugin heeler
```

If Kelpie is not pushed to GitHub yet, copy the tree up and link it instead
(`plugin link` runs no build command, so build first). From the Mac:

```bash
rsync -a --exclude node_modules ~/Developer/Kelpie/plugin/ review@VPS_IP:~/heeler-plugin/
ssh review@VPS_IP 'cd ~/heeler-plugin && npm ci && herdr plugin link "$PWD"'
```

### Keep the server alive after logout

`herdr` launches or attaches to a persistent background server and panes survive
client detach, but systemd-logind normally reaps a user's processes at logout.
Enable lingering and run `herdr server` — the documented supervised entry
point — as a user unit.

```bash
sudo loginctl enable-linger review
mkdir -p ~/.config/systemd/user
cat >~/.config/systemd/user/herdr.service <<'EOF'
[Unit]
Description=herdr server
[Service]
ExecStart=%h/.local/bin/herdr server
Restart=on-failure
[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now herdr
systemctl --user status herdr --no-pager
```

*Unverified*: herdr ships no unit of its own and its docs say nothing about
logout, lingering or autostart, so this unit comes from `herdr server`'s
documented purpose, not from upstream. Fallback if it misbehaves:
`tmux new -d -s herdr herdr`, lingering still enabled. Confirm by logging out,
back in, and running `herdr status server`.

### One workspace, one shell pane, optionally one agent

```bash
mkdir -p DEMO_DIR
herdr workspace create --cwd DEMO_DIR --label "Kelpie review"
herdr workspace list          # note the root pane id, e.g. w1:p1
```

`workspace create` returns a root pane already running the user's shell, so a
plain terminal needs no `agent start`. That pane alone lets the reviewer type
`ls`.

With an Anthropic API key, add one Claude Code agent. Install Claude Code per
Anthropic's current instructions, then **trust the directory first** — starting
claude in a cwd absent from `~/.claude.json` blocks on an in-TUI trust dialog
herdr cannot dismiss, and the agent wedges before its first prompt:

```bash
export ANTHROPIC_API_KEY=...      # also in ~/.bashrc, for the unit
cd DEMO_DIR && claude             # accept the trust prompt once, then exit
herdr agent start demo --kind claude --pane <root pane id>
herdr agent list
```

Skip the agent if no key is available; a shell pane demonstrates the app.

## 4. Produce the Pairing Code

The action opens a popup **inside herdr's own window**, not in the shell:

```bash
herdr                                      # attach the TUI
herdr plugin action invoke heeler.pair     # from the TUI, or a second shell
```

Space toggles which addresses go into the code (keep the public IPv4), Return
mints it and draws the QR. On Linux `c` prints the code for manual selection
(`pbcopy` is macOS only). Copy the single-line `HERDR-PAIR:1:...` string.

### The two-minute problem

From `plugin/src/pairing-session.js` and `pair-popup.js`:

- `PAIRING_TTL_SECONDS = 120` — the code's Bootstrap Key lives **two minutes**.
- It is **single use**: the `authorized_keys` line self-revokes the moment a
  device enrolls, and is removed when the TTL lapses or the popup exits.

A Pairing Code pasted into review notes is therefore dead long before a
reviewer opens the app. Mint one only when someone is watching the reviewer
pair in real time, and regenerate on any **Resubmit**. Otherwise use the
fallback.

### Fallback: SSH details the reviewer can type

Kelpie's Welcome screen offers **Add manually over SSH**, and the host form
supports password auth. For the review window only, allow passwords for this
one account:

```bash
sudo sh -c 'printf "\nMatch User review\n    PasswordAuthentication yes\n" >>/etc/ssh/sshd_config.d/10-kelpie-review.conf'
sudo sshd -t && sudo systemctl reload ssh
sudo passwd review        # REVIEW_PW, long and random
```

Remove this block at teardown. The reviewer confirms the host key fingerprint
(TOFU) on first connect, so put `HOST_FP` in the notes.

## 5. App Review notes

Paste into **App Review Information → Notes** (117 words):

> Kelpie is an iPad client for herdr, an open-source terminal workspace manager
> for AI coding agents. The app has no content of its own: it connects over SSH
> to a computer running herdr and shows that computer's session full screen. We
> have provided a review host, so no setup is needed.
>
> On first launch, tap "Paste Pairing Code" and paste the code below. Kelpie
> connects and the terminal appears within a few seconds.
>
> Pairing Code: <paste fresh code here>
>
> In the terminal, tap the screen and type `ls` then Return — the remote shell
> responds, which confirms the live connection.
>
> A screen recording of the same flow is attached.

Using the step 4 fallback, replace the two middle paragraphs with:

> On first launch, tap "Add manually over SSH" and enter address `VPS_IP`,
> port 22, user `review`, method Password, password `REVIEW_PW`. Accept the
> host key fingerprint `HOST_FP` when asked.

Attach a **30–60 second screen recording** of the real flow on the iPad:
Welcome screen, paste or enter, the terminal appearing, `ls` echoing back.
Reviewers often never get as far as the app; the video carries the submission.

## 6. Verify from the Mac before submitting

```bash
ssh review@VPS_IP 'herdr status server && herdr workspace list'
```

1. That command succeeds with key auth and reports a running server.
2. On the iPad, **delete and reinstall Kelpie** so it starts with no Hosts and
   a fresh Device Key, then pair exactly as the notes describe. herdr's screen
   must appear and `ls` must respond in the shell pane.
3. Log the SSH session out entirely, wait, and repeat — that is what proves the
   lingering unit.

If the terminal never appears, check `AllowStreamLocalForwarding` first; it is
the one setting that fails preflight outright.

## 7. Teardown, and doing it again

Once approved, close any open pairing popup, destroy the instance in the
provider console, and forget its host key:

```bash
ssh-keygen -R VPS_IP
```

Destroying the instance is the real revocation: the enrolled Device Key, the
fallback password, and any API key in `~/.bashrc` go with it. Rotate the
Anthropic API key anyway if one was used.

If Apple asks for access again — expedited review, rejected resubmission, a 1.x
update — do not keep a host running between submissions. Run this guide again
from step 1: about 20 minutes, and a fresh host carries no stale pairing state.
Mint the new Pairing Code, or reset `REVIEW_PW`, immediately before pressing
Submit.
