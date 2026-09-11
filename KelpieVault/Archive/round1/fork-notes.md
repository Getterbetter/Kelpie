---
source: "delegate-20260910-191536/fork/notes.md — fork and rebrand build notes, 2026-09-10 20:00"
---

# Kelpie fork — running notes

Project: /Users/anthonytopalides/Developer/Kelpie
Upstream: https://github.com/ZingerLittleBee/Heeler.git (remote `upstream`, no `origin` added, nothing pushed)
Branch: `kelpie`

## Step 1 — clone/branch
- Full-history clone OK (first commit log: 90e01a9 "docs(readme): download buttons...").
- `git remote rename origin upstream` done. No other remote added.
- Created branch `kelpie` from that commit.

## Step 2 — tooling / docs read
- `brew install xcodegen` — installed 2.46.0 (was missing).
- Read project.yml, Makefile, CONTRIBUTING.md, CLAUDE.md.
- Repo layout per CONTRIBUTING.md: iOS app (Sources/, Packages/HeelerSSH), herdr
  plugin (plugin/, Node), stateless Push Relay (relay/, Node), marketing site
  (landing/, Astro). CI regenerates nothing; the committed Heeler.xcodeproj is
  what CI builds, so project.yml changes must be regenerated and the .xcodeproj
  committed alongside.
- Makefile: PROJECT=Heeler.xcodeproj, SCHEME=Heeler, APP_ID=dev.bybee.heeler.
  `make build-sim` / `make sim` are the simulator build targets. Did not edit
  the Makefile (not named in scope; app scheme/project name were left as
  Heeler — see below).

## Step 3 — rebrand edits made
Files edited (all under the Kelpie project folder):
- `project.yml`
  - `options.bundleIdPrefix`: `dev.bybee` -> `TME.Kelpie`
  - `settings.base.DEVELOPMENT_TEAM`: `9VM4RM39R3` -> `8JQWBQKEXX`
  - App target `Heeler`: `PRODUCT_BUNDLE_IDENTIFIER: TME.Kelpie`, added
    `PRODUCT_NAME: Kelpie` and `PRODUCT_MODULE_NAME: Heeler` (explicit, so the
    Swift module name / imports are unaffected), `INFOPLIST_KEY_CFBundleDisplayName: Kelpie`,
    `TARGETED_DEVICE_FAMILY: "1,2"` (was "1", comment "iPhone only" removed),
    added `INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents: YES`,
    app-group entitlement -> `group.TME.Kelpie.shared`.
  - `HeelerNotificationService` target: `PRODUCT_BUNDLE_IDENTIFIER: TME.Kelpie.NotificationService`,
    `TARGETED_DEVICE_FAMILY: "1,2"`, app-group entitlement -> `group.TME.Kelpie.shared`.
  - `HeelerWidgets` target: `PRODUCT_BUNDLE_IDENTIFIER: TME.Kelpie.Widgets`,
    `TARGETED_DEVICE_FAMILY: "1,2"`, app-group entitlement -> `group.TME.Kelpie.shared`.
  - `HeelerTests` target: `PRODUCT_BUNDLE_IDENTIFIER: TME.Kelpie.tests` (unchanged suffix `.tests`).
  - Did NOT rename `name: Heeler` at the top of project.yml — this drives the
    generated `.xcodeproj` filename and the `schemes.Heeler` scheme name (tied
    1:1 to the `Heeler` target name), and the brief said not to rename targets.
    So the project stays `Heeler.xcodeproj`, scheme `Heeler`.
- `Sources/Heeler/Heeler.entitlements` — app-group -> `group.TME.Kelpie.shared`.
- `Sources/HeelerNotificationService/HeelerNotificationService.entitlements` — same.
- `Sources/HeelerWidgets/HeelerWidgets.entitlements` — same.
- `Sources/HeelerNotificationCore/NotificationKeyStore.swift` line 38 —
  `sharedAccessGroup` constant -> `"group.TME.Kelpie.shared"`. This file is
  compiled directly into all three targets (app, NotificationService, Widgets
  each list `Sources/HeelerNotificationCore` in project.yml `sources:`), so
  one edit covers "every Swift reference to the old group string ... in all
  targets" as instructed.
- `scripts/ExportOptions.plist` — `teamID` -> `8JQWBQKEXX` (used by `make upload`/
  `make testflight`; in scope as a build-config file even though we don't run it).

### Grep audit — left untouched, with reasoning
- `Packages/HeelerSSH/Artifacts/*.xcframework/**/Info.plist` and
  `_CodeSignature/*` — prebuilt, checksummed, checked-in third-party binary
  artifacts (libssh2/OpenSSL). Their `dev.bybee`/`9VM4RM39R3` strings are the
  original signer identity baked into the binary; editing text in a
  CodeSignature file would corrupt the signature, and
  `Packages/HeelerSSH/Scripts/verify-native.sh` asserts that team ID against
  the actual codesign output (`verify-native.sh:129`) — changing it would just
  make verification fail against artifacts we didn't rebuild.
- `Packages/HeelerSSH/README.md` — documents that same vendored-artifact
  signer identity (provenance doc, not our app's config).
- `relay/wrangler.toml`, `relay/test/worker.test.js` — the upstream authors'
  own Cloudflare Worker deployment config/tests for **their** hosted Push
  Relay (APNS_TEAM_ID, APNS_TOPIC, custom domains on `bybee.dev`). We are not
  deploying our own relay (see Step 7), so changing these values would be
  misleading/inert. Left as-is; not part of the Xcode project or its build.
- `scripts/testdata/gate-2f50170.log` — a fixture/log snapshot, not config.
- Keychain **service** strings that are NOT the app-group/keychain-access-group
  (e.g. `DeviceKeyStore.swift` / `HostStore.swift` / `HostCredentialsProvider.swift`
  `KeychainSecretStore(service: "dev.bybee.heeler.ssh")`, the `AttachRestorationTrace.swift`
  logger subsystem string, `AppActivityCoordinator.swift` background-task name,
  `DNSServiceAddressResolver.swift` / `WeakNetworkProxy.swift` dispatch-queue
  labels, `DemoScreenshotMode.swift` UserDefaults suite name, and the three
  `Tests/HeelerTests/*.swift` keychain `service:` literals) — these are
  arbitrary internal identifier strings, not the app-group or
  keychain-access-group identifier (there is no separate
  `com.apple.security.keychain-access-groups` entitlement in this repo; the
  app-group entitlement doubles as the keychain access group per the
  project.yml comment). Brief said "Leave everything else as is. Do not
  change code logic," so these were left untouched.
- Extension `CFBundleDisplayName` values (`Heeler Notification Service`,
  and `Heeler` for Widgets/lock-screen fallback) were left unchanged — the
  brief's "Display name: Kelpie" / "PRODUCT_NAME: Kelpie" bullet names the
  app target only, and the NotificationService one is explicitly commented
  in project.yml as "never user-visible for this extension."

## Step 4 — xcodegen generate
- `xcodegen generate` succeeded, wrote `Heeler.xcodeproj` (project name in
  `project.yml` was left as `Heeler` — see reasoning above — so the file and
  the `Heeler` scheme keep their names; only bundle IDs / team / product name
  / module name / device family / app group changed).
- `xcodebuild -resolvePackageDependencies ...` (and later, package resolution
  as part of `build`/`-showBuildSettings`) hung indefinitely at "Resolve
  Package Graph" in this environment — see Step 5 below, this affected both
  steps identically.

## Step 5/6 — build + showBuildSettings
**Result: build did not complete — every attempt hangs at "Resolve Package
Graph" before any compilation starts. This reproduced identically for
`-resolvePackageDependencies`, `build`, and `-showBuildSettings` alike, so
Step 6 (showBuildSettings) could not be run either; the settings below are
confirmed instead by grepping the xcodegen-generated `Heeler.xcodeproj/project.pbxproj`.**

Three build attempts, each a genuine build-configuration change, all hung the
same way (never printed a compiler error — no text ever appeared past
"Resolve Package Graph"):
1. Plain `make`-equivalent build-sim command from the brief. Killed after
   ~16 min with zero progress.
2. Same, with `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
   CODE_SIGN_IDENTITY=""` (ruling out Automatic-signing/Apple-Developer-Portal
   round trips for our new, machine-unregistered team `8JQWBQKEXX`, since a
   simulator build needs no signing at all). Killed after ~5 min, no progress.
3. Same again, plus `-skipPackageUpdates -disableAutomaticPackageResolution`
   (the two packages were already fully git-cloned into
   `.ci/source-packages/checkouts` from attempt 1, and the repo ships a
   matching `Heeler.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`,
   so no network fetch should have been required). Killed after ~2 min, no
   progress.

Diagnosis: `sample`'d the attempt-3 process — its one thread was parked in
`mach_msg2_trap` (an IPC wait) the whole time, i.e. xcodebuild's package-graph
step is blocked waiting on a reply from an internal Xcode service
(XCBBuildService / DVTPortal-class helper) that never answers in this
environment, not on the network: plain `curl`/`git ls-remote` to
github.com, api.github.com and raw.githubusercontent.com all returned
instantly throughout. This is an environment/toolchain condition, not a
Swift-logic or rebrand-config problem, so per the brief I stopped after 3
build-configuration attempts and did not touch Swift code.

Confirmed settings by reading the generated `Heeler.xcodeproj/project.pbxproj`
(both Debug and Release build configurations, app target `Heeler` unless
noted):
- `TARGETED_DEVICE_FAMILY = "1,2"` — on all 8 configs it appears in (app,
  HeelerNotificationService, HeelerWidgets: Debug+Release each).
- `PRODUCT_BUNDLE_IDENTIFIER` — app: `TME.Kelpie`; HeelerNotificationService:
  `TME.Kelpie.NotificationService`; HeelerWidgets: `TME.Kelpie.Widgets`;
  HeelerTests: `TME.Kelpie.tests`.
- `DEVELOPMENT_TEAM = 8JQWBQKEXX` (project-level base setting, so every
  target inherits it — 2 occurrences, once per Debug/Release build config
  list entry).
- `PRODUCT_MODULE_NAME = Heeler` and `PRODUCT_NAME = Kelpie` — app target,
  both Debug and Release.
- `INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES` — app
  target, both Debug and Release.

Logs: `build-sim.log` in this folder holds attempt 3's output (the last
attempt run, per the brief's tee instruction — all three attempts show the
identical hang signature). `resolve.log`, `build-settings.log`,
`xcodegen.log`, `sample-xcodebuild.txt` (the diagnostic stack sample) are
also in this folder.

## Step 7 — push notification / relay / plugin investigation

**How a push reaches the phone (file paths):**
1. On the Mac, herdr fires the plugin's notify hook
   (`plugin/src/notify-hook.js`) on the `pane.agent_status_changed` event
   when an agent goes Blocked/Done. It encrypts the notification with the
   per-Host **Notification Key** (`plugin/src/notification-envelope.js`) —
   a symmetric key the app generated and copied to that Host over SSH
   (per `CLAUDE.md`; app-side counterpart is
   `Sources/HeelerNotificationCore/NotificationKeyStore.swift`) — then POSTs
   `{token, env, envelope, collapse}` to the Push Relay's `POST /push`.
2. The relay (`relay/src/worker.js`, a dependency-free Cloudflare Worker)
   signs an APNs provider JWT (`relay/src/apns-jwt.js`, using
   `APNS_TEAM_ID`/`APNS_KEY_ID`/`APNS_TOPIC` from `relay/wrangler.toml`),
   wraps the still-opaque ciphertext in a `mutable-content:1` alert push, and
   forwards it to `api.push.apple.com` / `api.sandbox.push.apple.com`. It is
   deliberately stateless: no accounts/DB/queue, never decrypts the envelope.
3. APNs delivers to the device. The app's Notification Service Extension
   (`Sources/HeelerNotificationService`, sharing
   `Sources/HeelerNotificationCore`) decrypts the envelope using the
   Notification Key from the shared Keychain (app-group
   `group.TME.Kelpie.shared` after our rebrand) and rewrites the generic
   alert into the real title/body before display.

**Hosted relay URL hardcoded in the app?** Yes —
`Sources/Heeler/Notifications/NotificationRelayEndpoint.swift`:
`productionBaseURLString = "https://heeler-apns.bybee.dev"`, plus two legacy
fallback URLs (`herdr-push-relay.69709991236.workers.dev`,
`herdr-apns.bybee.dev`) that are treated as aliases for the same production
default. The plugin carries the same default (per the file's own comment and
`plugin/README.md`: "Leave Custom Push Relay empty to use the production
endpoint"). `relay/wrangler.toml` is the Cloudflare Worker deploy config for
that same hosted origin (`heeler-apns.bybee.dev` / legacy
`herdr-apns.bybee.dev` custom domains).

**Would our new bundle ID break pushes through that relay?** Yes.
`relay/wrangler.toml` pins `APNS_TOPIC = "dev.bybee.heeler"` and signs every
provider JWT with the upstream authors' own APNs `.p8` key
(`APNS_TEAM_ID = 9VM4RM39R3`, `APNS_KEY_ID = RQQ8PA9A6G`) — both baked into
their Cloudflare Worker's `[vars]`, not something our rebrand touches or can
touch from the app side. APNs only delivers a push whose `apns-topic`
matches the receiving app's bundle ID and whose signing key is authorized
for that app's team, so a push aimed at bundle ID `TME.Kelpie` / team
`8JQWBQKEXX` sent with topic `dev.bybee.heeler` signed by team `9VM4RM39R3`
will be rejected by Apple outright. We would need to deploy our own copy of
`relay/` (our own `.p8`, `APNS_TEAM_ID = 8JQWBQKEXX`,
`APNS_TOPIC = TME.Kelpie`) and point `NotificationRelayEndpoint.productionBaseURLString`
(or the in-app "Custom Push Relay" setting) and the plugin's default at it —
none of which was done here per the brief (relay/plugin left untouched,
investigate-only).

**herdr plugin (`plugin/`) — what it installs on the Mac, and QR pairing:**
Installed via `herdr plugin install ZingerLittleBee/Heeler/plugin --ref main
--yes` (`plugin/README.md`): herdr clones `plugin/` — a Node.js, zero
external-framework herdr plugin (needs Node.js >= 20 on `PATH` and a running
local OpenSSH server) — into its own managed plugin checkout directory and
runs the manifest's `npm ci` there automatically (`plugin/herdr-plugin.toml`,
`plugin/package.json`); `herdr plugin link <path>` is the local-dev
equivalent. Pairing: `herdr plugin action invoke heeler.pair` opens a TUI
popup (`plugin/src/pair-action.js`, `plugin/src/pair-popup.js`) to pick which
of the Mac's network addresses to advertise, mints a single-use Ed25519
**Bootstrap Key** (`plugin/src/bootstrap-key.js`), and renders a QR encoding
a one-line **Pairing Code**: `HERDR-PAIR:<version>:<base64url(JSON)>` holding
`addrs`, `port`, `user`, the SSH host-key fingerprint `fp` (pinned, no TOFU
prompt), and the bootstrap key's seed + expiry (`plugin/src/copy-pairing-code.js`;
wire format documented at the top of `plugin/README.md`). Scanning it in the
app lets it connect over SSH once with the Bootstrap Key, submit its own
Device Key public line, and the plugin's enrollment path
(`plugin/src/pair-accept.js`, `plugin/src/authorized-keys.js`) appends that
line to the Mac's `authorized_keys` — future connections then use ordinary
SSH pubkey auth. Nothing under `plugin/` was executed, per the brief.
