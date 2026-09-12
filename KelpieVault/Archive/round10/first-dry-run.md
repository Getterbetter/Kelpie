# depwatch 2026-09-12T02-28-51Z

- Run: 2026-09-12T02-28-51Z UTC
- Repo: `694774c`
- Duration: 18.7s

| Check | Severity | State | Headline |
| --- | --- | --- | --- |
| `herdr-release` | info | new | herdr v0.9.0, snapshot current |
| `herdr-mini` | info | new | mini_host not configured |
| `heeler-upstream` | info | new | level with upstream/main |
| `libghostty-spm` | low | new | libghostty upstream.1.3.1 pinned, upstream.82938b633ba6 available |
| `heeler-ssh-pins` | low | new | OpenSSL 3.6.3 pinned, openssl-3.6.4 in line |
| `node` | info | new | npm audit: 0 vulnerabilities |
| `toolchain` | info | new | Xcode 26.4.1, MomentRender2 26.4.1 |
| `ci-fork` | high | new | no successful CI run on the fork |
| `relay` | info | new | push relay healthy (HTTP 404) |
| `review-host` | info | new | review host reachable |

## herdr-release — herdr v0.9.0, snapshot current

Severity **info**, new, lane `none`, fingerprint `v0.9.0|v0.9.0`.

No stable herdr release newer than the tag the committed schema snapshot came from.

Evidence:

- latest stable herdr release `v0.9.0` (2026-09-07T19:21:31Z)
- committed snapshot `scripts/herdr-schema.json` is protocol 22, from `v0.9.0`
- latest prerelease `preview-2026-09-08-62431dbd033b` (info only)

## herdr-mini — mini_host not configured

Severity **info**, new, lane `none`, fingerprint `unconfigured`.

No `mini_host` in `/Users/anthonytopalides/.kelpie/depwatch/config.json`, so the live herdr version on the Mac mini is not checked. See the guide for the one-time `ssh mac-mini` host-key accept.

Evidence:

- `mini_host` unset in /Users/anthonytopalides/.kelpie/depwatch/config.json

## heeler-upstream — level with upstream/main

Severity **info**, new, lane `none`, fingerprint `375267c5d00c031e01405657c52646b8852c53f8`.

Heeler upstream moves daily and Kelpie is a rebasing fork, so the cost of the next rebase is worth knowing before it is forced.

Evidence:

- `kelpie..upstream/main`: 0 commits, head `375267c5d00c`
- merge-base `375267c5d00c`
- collision set (0 files both sides touched): empty
- dry-run rebase: skipped (0 commits behind)
- upstream releases: v0.1.6 (2026-09-08), v0.1.5 (2026-09-03), v0.1.4 (2026-08-31)

## libghostty-spm — libghostty upstream.1.3.1 pinned, upstream.82938b633ba6 available

Severity **low**, new, lane `manual`, fingerprint `upstream.1.3.1|upstream.82938b633ba6`.

The terminal engine is a vendored prebuilt xcframework; Xcode's downloader hangs on the remote binary on this Mac, so the pin is deliberate and moving it is a manual job.

Evidence:

- pinned `upstream.1.3.1` (SHA256 `68156e6c8f38…`), published 2026-08-20
- newest `dated` family tag: `1.6.20260909` (2026-09-09)
- newest `upstream` family tag: `upstream.82938b633ba6` (2026-09-09)

Actions:

1. Never edit the vendored package under `Packages/GhosttyTerminal`; override its `open` members from `HeelerTerminalView` instead.
2. Re-vendor from the new tag: update `URL` and `SHA` in `scripts/fetch-ghostty-artifact.sh`, then `make generate` to refetch and checksum-verify.
3. Review the package's Swift sources and the XCFramework checksum before accepting the bump.
4. Device build, then the pointer/long-press/trackpad-scroll checklist in `docs/adr/0016-ipad-pointer-input.md`.

## heeler-ssh-pins — OpenSSL 3.6.3 pinned, openssl-3.6.4 in line

Severity **low**, new, lane `manual`, fingerprint `c7557852f1b7|3.6.3|`.

libssh2 and OpenSSL are pinned by commit and tarball hash in `Packages/HeelerSSH/Sources.lock`; normal builds consume the checked-in XCFrameworks, so a pin move is a deliberate rebuild.

Evidence:

- pinned libssh2 `c7557852f1b7` (tag `master-c755785`)
- pinned OpenSSL `3.6.3`
- libssh2 latest release `libssh2-1.11.1` (2024-10-16); pinned commit dated 2026-08-29
- libssh2 master head `b937ded9f02b` (info only)
- newest OpenSSL in the pinned 3.6 line: `openssl-3.6.4` (2026-08-25)
- other OpenSSL lines (info only): openssl-3.0.22, openssl-3.4.7, openssl-3.5.8, openssl-4.0.1, openssl-4.0.2
- advisories published after the pins: none listed on either repo

Actions:

1. Review the upstream source hashes and the committed XCFramework checksums before moving either pin (CLAUDE.md conventions).
2. Update `Packages/HeelerSSH/Sources.lock`, then `make ssh-artifacts` and `make verify-ssh-artifacts`.
3. `scripts/run-heelerssh-package-tests.sh` — the package suites are a separate test plan, not `-only-testing:HeelerTests/...`.
4. PR into `kelpie` for CI, then a device build.

## node — npm audit: 0 vulnerabilities

Severity **info**, new, lane `none`, fingerprint `critical=0|high=0|info=0|low=0|moderate=0`.

`plugin/` renders Pairing Codes and posts Agent Notifications; `relay/` is the stateless push relay. Both are audited read-only — the watch never runs `npm install`.

Evidence:

- `plugin/`: 0 vulnerabilities (critical 0, high 0, moderate 0, low 0)
- `relay/`: no lockfile; dependency-free by design

## toolchain — Xcode 26.4.1, MomentRender2 26.4.1

Severity **info**, new, lane `infra`, fingerprint `Xcode 26.4.1 Build version 17E202|MomentRender2 26.4.1`.

Kelpie only ever ships from a device build on this Mac, so the local Xcode and the iPad's OS are part of the dependency surface.

Evidence:

- `Xcode 26.4.1` / `Build version 17E202`
- connected device: MomentRender2 26.4.1
- CI runner pin `macos-26` vs local Xcode major 26

## ci-fork — no successful CI run on the fork

Severity **high**, new, lane `infra`, fingerprint `0|False|None`.

Every fix the watch prepares is verified by CI on the fork. While Actions has never run on `Getterbetter/Kelpie`, the verification ladder has a missing rung: the compile is the only gate a `Sources/` change would get, and CLAUDE.md forbids merging on that alone.

Evidence:

- workflows registered on the fork: none (Actions has never run here)
- recent runs: none

Actions:

1. Enable Actions on the fork: Settings -> Actions -> Allow all actions, or `gh api -X PUT repos/Getterbetter/Kelpie/actions/permissions -f enabled=true`.
2. Open every fix branch as a PR into `kelpie`. `ci.yml`'s `pull_request` trigger has no branch filter, so a PR into `kelpie` runs it; the `push` trigger is `main`-only and never will.
3. macOS minutes are free on a public repository, so the runner cost is not a reason to leave it off.

## relay — push relay healthy (HTTP 404)

Severity **info**, new, lane `infra`, fingerprint `healthy|404`.

Agent Notifications reach the iPad through this Cloudflare Worker. If it stops answering, notifications stop and nothing in the app says so.

Evidence:

- probed `https://kelpie-apns.getter-tilbury-0m.workers.dev/depwatch-probe`
- result: HTTP 404
- the Worker answers 404 for any path but `/push` (`relay/src/worker.js`), so a 404 is healthy

## review-host — review host reachable

Severity **info**, new, lane `infra`, fingerprint `reachable`.

The Hetzner box behind `kelpie-review` exists only so App Review has a herdr Host to connect to. See `docs/guides/app-review-host.md`.

Evidence:

- `ssh kelpie-review true`: ok

Actions:

1. Delete the Hetzner server once the App Store review is approved — it is a paid box kept alive only for review (`resume.md`, `docs/guides/app-review-host.md`).

