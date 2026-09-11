# Kelpie App Store recon

## 1. Upload pipeline

- `Makefile:103-106` `archive`: `xcodebuild archive` Release config, `generic/platform=iOS`, `-allowProvisioningUpdates`, no explicit signing identity (relies on Xcode automatic signing / whichever Apple ID or Team is configured locally, team hardcoded downstream in ExportOptions).
- `Makefile:108-111` `upload`: `xcodebuild -exportArchive -exportOptionsPlist scripts/ExportOptions.plist -exportPath build/export -allowProvisioningUpdates`. This is the modern App Store Connect upload path (xcodebuild handles auth via Xcode's signed-in Apple ID / keychain, or ASC API key if configured in Xcode — no explicit `xcrun altool` or `notarytool` call, no `ASC_KEY_ID`/`ASC_ISSUER_ID` env vars referenced anywhere in Makefile or publish.sh).
- `scripts/ExportOptions.plist:5-14`: `method=app-store-connect`, `destination=upload` (i.e. xcodebuild uploads directly, no separate altool/transporter step), `teamID=8JQWBQKEXX` (matches Kelpie's stated team), `uploadSymbols=true`, `manageAppVersionAndBuildNumber=false` (so project.yml's versions are authoritative, not ASC auto-increment).
- `Makefile:113` `testflight: archive upload` — the interim-build path (`make bump && make testflight`).
- `Makefile:127-128` `publish` target shells to `scripts/publish.sh`.
- **Heeler/GitHub-specific assumptions baked into `scripts/publish.sh`:**
  - `scripts/publish.sh:27` `REMOTE="origin"` — **repo has no `origin` remote** (`git remote -v` shows only `upstream -> https://github.com/ZingerLittleBee/Heeler.git`). Every `git fetch/push` against `$REMOTE` (lines 74-76, 131, 226, 230) will fail outright with no `origin` configured — `make publish` cannot run as-is.
  - `scripts/publish.sh:26` `DEFAULT_BRANCH="main"` — current branch is `kelpie` (git status header); `publish.sh:71` `die`s unless `HEAD` is on `main`, so the fork's whole workflow (which lives on `kelpie`) is blocked by this check too.
  - `scripts/publish.sh:63-66` requires `gh` installed and authenticated; `scripts/publish.sh:233-238` runs `gh release create` + `gh release view` — this targets whatever GitHub repo `origin`/the `gh` context resolves to. If `origin` were later set to a personal Kelpie fork, this would create a real public GitHub release there; if accidentally pointed at `upstream` (ZingerLittleBee/Heeler) this would attempt (and likely fail on permissions, safely) to release into the upstream project.
  - `scripts/publish.sh:5-7,18-19` explicitly documents "CHANGELOG.md is the source"/"local build" convention — generic, not Heeler-branded, but entirely dependent on the GitHub remote/tag flow above.
  - No landing-site coupling found in publish.sh (no `landing/` or Cloudflare deploy step referenced).
- **What breaks for this fork today:** `make publish` fails immediately at the `origin` fetch/branch checks. `make bump && make testflight` (the interim path) does **not** touch git remotes and should work independently of the `origin`/`main` issue — it only rewrites `project.yml`, regenerates the project, archives, and uploads via ExportOptions.plist/teamID 8JQWBQKEXX.
- **Verdict so far:** `make bump && make testflight` (archive+upload only) is usable as-is for getting a build into TestFlight, provided local Xcode signing/ASC auth is set up for team 8JQWBQKEXX. Full `make publish` (versioned release + GitHub release) is not usable until either an `origin` remote is added and `DEFAULT_BRANCH` reconciled with `kelpie`/`main`, or the script is adapted for a no-GitHub-release fork workflow.


## 2. Versioning

- `project.yml:81-82` app target: `MARKETING_VERSION: "0.1.6"`, `CURRENT_PROJECT_VERSION: "18"`.
- `project.yml:153-154` HeelerNotificationService: same pair, `"0.1.6"` / `"18"`.
- `project.yml:201-202` HeelerWidgets: same pair, `"0.1.6"` / `"18"`.
- Extensions reference the app's version via `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` in their generated Info.plist (`project.yml:142-143`, `191-192`), but each target also **hardcodes** its own literal `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` settings (81-82, 153-154, 201-202) — all three currently agree (0.1.6/18), kept in lockstep manually.
- `Makefile:115-123` `bump`: `awk`/`sed -i` bumps every `CURRENT_PROJECT_VERSION: "N"` occurrence in `project.yml` by +1 in one pass (all three targets at once, `-E ... /g`), then re-runs `make generate`. Does not touch `MARKETING_VERSION`.
- `scripts/publish.sh:135-154,201-208` is the only path that changes `MARKETING_VERSION`, and it is CHANGELOG-driven: version comes from the newest `## [X.Y.Z]` heading in `CHANGELOG.md` (bumped patch) or an explicit `VERSION=`, then rewrites `MARKETING_VERSION` in all matching target lines and bumps `CURRENT_PROJECT_VERSION` by 1, asserting the rewrite count matches how many targets were found (3).
- `CHANGELOG.md` — checked `[Unreleased]` section state not required for this section; relevant fact: publish.sh dies if `[Unreleased]` is empty (see section 1).

## 3. Rebrand leftovers (Heeler / heeler / bybee / ZingerLittleBee / heeler.bybee.dev)

Counted 13 distinct source locations (excluding `.ci/`, `Packages/`, docs prose, and CLAUDE.md/ADR historical narrative which are internal-only and out of scope):

1. `project.yml:80` `INFOPLIST_KEY_CFBundleDisplayName: Kelpie` — fine (already Kelpie). But comment at `project.yml:79` "the App Store listing is 'Heeler for herdr'" — internal note only, not a file leftover, but signals ASC metadata (outside repo) may still say Heeler.
2. `project.yml:84` `INFOPLIST_KEY_NSCameraUsageDescription: "Heeler uses the camera to scan the Pairing Code..."` — **App-Review-visible** (shown in the camera permission system dialog). Says "Heeler" not "Kelpie".
3. `project.yml:146` HeelerNotificationService `CFBundleDisplayName: Heeler Notification Service` — internal only per the adjacent comment ("never user-visible for this extension"), required by App Store validation code 90360 but not shown to users/reviewers.
4. `project.yml:195` HeelerWidgets `CFBundleDisplayName: Heeler` — comment says "counts-only lock-screen fallback", i.e. **can be user-visible** (Lock Screen Live Activity fallback text / widget gallery entry could show "Heeler").
5. `Sources/Heeler/Settings/SettingsView.swift:61` `repositoryURL = "https://github.com/ZingerLittleBee/Heeler"` — **user-visible** (Settings/About link). This is legitimate upstream attribution if intended as "View on GitHub (upstream Heeler)", but as written it just looks like the app's own repo link with no Kelpie-specific fork link — worth a copy check.
6. `Sources/Heeler/Client/WelcomeView.swift:103` command string `"herdr plugin install ZingerLittleBee/Heeler/plugin --ref main --yes"` — **user-visible, copy/paste command** shown in the onboarding flow. This installs the upstream Heeler plugin (correct: Kelpie reuses Heeler's herdr plugin unmodified) — legitimate, not a leftover, but worth confirming Kelpie hasn't forked plugin/ independently (it hasn't; plugin/ is shared).
7. `Sources/Heeler/Notifications/NotificationPrivacyCopy.swift:58` `privacyPolicyURL = "https://github.com/ZingerLittleBee/Heeler/blob/main/PRIVACY.md"` — **user-visible** (Settings privacy link) AND **App-Review-visible** (App Store privacy policy URL must resolve and be accurate for this app). Points at upstream Heeler's PRIVACY.md, not a Kelpie-specific policy — needs a fork-specific privacy policy or explicit confirmation upstream's applies verbatim.
8. `Sources/Heeler/Notifications/NotificationRelayEndpoint.swift:7` `productionBaseURLString = "https://heeler-apns.bybee.dev"` — internal (network endpoint, not user-visible text, but functionally load-bearing — see section 5/Push mismatch finding).
9. `Sources/Heeler/Demo/DemoScreenshotMode.swift:262` `"dev.bybee.heeler.demo-screenshots.\(UUID())"` — internal, DEBUG+simulator-only, not shipped.
10. `Sources/Heeler/Transport/DeviceKeyStore.swift:19`, `Sources/Heeler/Hosts/HostCredentialsProvider.swift:17`, `Sources/Heeler/Hosts/HostStore.swift:34` — all `KeychainSecretStore(service: "dev.bybee.heeler.ssh")` — internal Keychain service identifier, not user-visible, but a namespace leftover (doesn't match bundle id `TME.Kelpie`).
11. `Sources/Heeler/Support/AppActivityCoordinator.swift:66` background task name `"dev.bybee.heeler.background-grace"` — internal (UIApplication background task identifier, not shown to users).
12. `Sources/Heeler/Console/AttachRestorationTrace.swift:26` `os.Logger` subsystem `"dev.bybee.heeler"` — internal (Console.app log subsystem only).
13. `Sources/HeelerNotificationCore/NotificationKeyStore.swift:40` Keychain `service = "dev.bybee.heeler.notifications"` — internal.
14. `Makefile:10` `APP_ID := dev.bybee.heeler` — used only by `make install`/`make sim` (device install/launch bundle id), **wrong bundle id** for this fork (actual bundle id is `TME.Kelpie`); this would make `make install`/`make sim`'s `devicectl device process launch`/`simctl launch` calls fail to find/launch the installed app (dev-workflow bug, not an App Store submission blocker, but likely breaks local dev "make install").

Legitimate, not-a-leftover: `Sources/Heeler/Resources/Notices/*` (libssh2, OpenSSL, libghostty-spm, GhosttyTheme, MSDisplayLink, IBMPlexMono, JetBrainsMono license texts) is exactly the desired Acknowledgements/third-party-notices content and correctly names the real upstream projects — not Heeler-branding, don't touch.

**Total distinct rebrand-leftover sites found: 13** (excluding the Notices/attribution content and the WelcomeView plugin-install command, which are legitimate). Of these, **3 are user-visible or App-Review-visible**: the camera usage description (#2), the Settings repository link (#5), and the privacy policy link (#7); the Widgets extension display name (#4) is conditionally user-visible (Lock Screen fallback).


## 4. Entitlements and capabilities

- App (`Sources/Heeler/Heeler.entitlements:5-10`): `aps-environment: development` (hardcoded; `project.yml:65-68` comment claims re-signing for App Store/TestFlight flips it to production automatically — standard for automatic signing but worth confirming on the actual archive), `com.apple.security.application-groups: [group.TME.Kelpie.shared]`. No keychain-access-groups entitlement key present in any of the three entitlements files (Keychain sharing likely implicit via the app-group + default team-qualified access, not an explicit `keychain-access-groups` array).
- HeelerNotificationService (`Sources/HeelerNotificationService/HeelerNotificationService.entitlements:5-8`): same app group only, no aps-environment key (extension doesn't need it directly).
- HeelerWidgets (`Sources/HeelerWidgets/HeelerWidgets.entitlements:5-8`): same app group only.
- All three identifiers (`group.TME.Kelpie.shared`, bundle ids `TME.Kelpie` / `TME.Kelpie.NotificationService` / `TME.Kelpie.Widgets`) are consistently under the `TME.Kelpie` namespace — **no cross-target identifier mismatch found in entitlements/bundle ids**.
- `project.yml:107` `INFOPLIST_KEY_NSSupportsLiveActivities: YES` (app target) — Live Activities declared.
- No `UIBackgroundModes` key found anywhere (grep across `project.yml`/`Sources`) — app declares no background modes in Info.plist.
- No `com.apple.developer.associated-domains` entitlement found in any of the three `.entitlements` files — no universal links / associated domains configured.
- Push permission is requested **lazily**, not at launch: `Sources/Heeler/Notifications/PushRegistrationStore.swift:56-58` calls `UNUserNotificationCenter.current().requestAuthorization(...)` inside `PushRegistrationStore`, invoked from `PushRegistrationStore.swift:125` (`if try await client.requestAuthorization()`), which is reached through the Notification Registration explainer flow, not `HeelerApp`'s launch path (no `requestAuthorization` call in `HeelerApp.swift`).

## 5. Push relay

- Default Push Relay URL, app side: `Sources/Heeler/Notifications/NotificationRelayEndpoint.swift:7` `productionBaseURLString = "https://heeler-apns.bybee.dev"`, with legacy defaults at lines 12-13 (`herdr-push-relay.69709991236.workers.dev`, `herdr-apns.bybee.dev`) that auto-migrate to the current default (`NotificationRelayEndpoint.swift:20-27` `resolve`/`isLegacyProductionBaseURL`).
- There is a user-facing **custom relay override**: `NotificationRelaySettings`/Settings surface (referenced by `NotificationRelayEndpoint.resolve(customBaseURL:)`) — a per-Host or app-wide "Custom Push Relay" field exists in Settings (not fully traced line-by-line here, but `resolve(customBaseURL:)`'s signature and the plugin's `relay_url` override, `plugin/README.md:452`, confirm the pattern is override-capable).
- Plugin side default, same host: `plugin/src/notification-config.js:4` `DEFAULT_RELAY_URL = "https://heeler-apns.bybee.dev"`, legacy set at lines 9-11 mirrors the app's.
- Worker/relay deployment: `relay/wrangler.toml:16` primary route pattern `heeler-apns.bybee.dev`, `:25` secondary `herdr-apns.bybee.dev`, `:31` `APNS_TOPIC = "dev.bybee.heeler"`.
- **Blocking mismatch for push functionality:** `relay/wrangler.toml:31` hardcodes `APNS_TOPIC = "dev.bybee.heeler"`, but Kelpie's actual bundle id (the value Apple requires as the `apns-topic` header) is `TME.Kelpie` (`project.yml:74`). APNs delivery requires the `apns-topic` to match the receiving app's bundle id exactly (or `<bundle-id>.push-type.liveactivity` for Live Activities, per `relay/test/worker.test.js:476`). As configured, the shared production relay (`heeler-apns.bybee.dev`) would send pushes addressed to topic `dev.bybee.heeler`, which will be **rejected by APNs / silently undelivered** to a `TME.Kelpie`-signed app. This affects both standard push notifications and Live Activity push updates. Either the relay needs a Kelpie-specific deployment/topic, or the app needs to point its default/production relay at an instance configured with `APNS_TOPIC = TME.Kelpie` (and a Live Activities variant), before push will work at all for Kelpie.
- What is sent to the relay: `plugin/src/notify-hook.js:240-247` and `plugin/src/activity-hook.js:359-366` POST `{relayUrl}/push` with an **encrypted envelope** plus device token — not raw content (`plugin/README.md:205`: "the Push Relay and APNs carry it opaquely"). `relay/src/worker.js` forwards token + envelope to APNs; `FALLBACK_ALERT` (`relay/src/worker.js:49`) is a generic `{title: "Heeler", body: "Agent update"}` shown only if the envelope can't be locally rendered — this fallback alert title is a further minor user-visible "Heeler" leftover in push banners, though this text lives in `relay/`, not the app bundle.
- App functions without push: yes by design — SSH/Attach/Console features don't depend on notifications; push is opt-in via Notification Registration (confirmed by lazy authorization request, section 4).

## 6. Privacy

- `Sources/Heeler/PrivacyInfo.xcprivacy` (full contents read): `NSPrivacyTracking = false`, `NSPrivacyTrackingDomains = []`, `NSPrivacyCollectedDataTypes = []` (empty — declares **no** collected data types). `NSPrivacyAccessedAPITypes` declares two required-reason API categories: `NSPrivacyAccessedAPICategoryUserDefaults` (reason `CA92.1`) and `NSPrivacyAccessedAPICategoryFileTimestamp` (reasons `C617.1`, `3B52.1`).
- No `PrivacyInfo.xcprivacy` found for `HeelerNotificationService` or `HeelerWidgets` targets in `project.yml`'s sources lists — only the app target's Sources/Heeler tree includes one; the extensions don't appear to bundle their own privacy manifest (Apple may require one per bundle that uses required-reason APIs — the extensions do touch UserDefaults/Keychain via `SecretStore`/`NotificationKeyStore`, worth verifying at archive time whether Xcode's manifest aggregation covers this or a separate manifest is needed for the two `.appex` targets).
- Data leaving the device: (a) to the user's own Host, over SSH (herdr JSON API traffic — session/agent data, by design, user-controlled); (b) to the Push Relay (`heeler-apns.bybee.dev`), an **encrypted envelope + device token** only, for pushes — see section 5; (c) no analytics, crash reporting, or third-party SDK calls found in this recon (no `Package.swift`/`project.yml` third-party analytics dependency — only packages are `HeelerSSH` (repo-local) and `GhosttyTerminal` (vendored terminal renderer), both listed in `project.yml:17-28`).
- No third-party SDKs beyond the two above (`project.yml:17-28` `packages:` block is exhaustive).
- No existing privacy-policy markdown found under `landing/` in this recon (only checked `landing/` incidentally via grep in section 3/1; no `landing/PRIVACY.md`-style hit surfaced) — the in-app privacy link instead points at the upstream GitHub repo's `PRIVACY.md` (`NotificationPrivacyCopy.swift:58`, see section 3 item 7), which is the document that would need adapting/forking for Kelpie's own App Store privacy-policy URL requirement.


**Correction/addition to section 6:** `PRIVACY.md:1-9` (repo root) exists and is current (last updated 2026-08-22 per line 3, most recent commit `25dfb63`), and states no accounts/ads/analytics/tracking and that SSH/terminal data never passes through the developer's service — consistent with the empty `NSPrivacyCollectedDataTypes` in the xcprivacy manifest. However it is written entirely in "Heeler" branding (`PRIVACY.md:5-9` "Heeler is a native iOS console...Heeler has no user accounts...Heeler's developer") and the in-app link (`NotificationPrivacyCopy.swift:58`) points at `github.com/ZingerLittleBee/Heeler/blob/main/PRIVACY.md` — since this fork has no `origin` GitHub remote (section 1), that link resolves to the **upstream** repo's copy of this file, not this fork's. Before submission: either publish this file somewhere reachable for Kelpie and repoint the link, or confirm upstream's hosted copy is acceptable as Kelpie's App Store privacy policy URL (it currently is Heeler-branded prose, which is a rebrand/accuracy concern for App Review, not a functional break).

## 7. App Review reviewability

- Core reviewability problem: the app is inert without a Host running herdr reachable over SSH — no bundled demo/sample data path in Release builds.
- `Sources/Heeler/Demo/DemoScreenshotMode.swift:1` — the entire file is gated `#if DEBUG && targetEnvironment(simulator)`, ending at line 504 (`#endif`). It provides a full demo composition root (`DemoScreenshotRootView`, line 21+) reusing the production Console/EventsSession/Transport/terminal surfaces with everything else (Hosts, secrets, settings, notifications, SSH) kept process-local — i.e. architecturally it already **is** a self-contained fake-data mode. But the `#if` condition excludes it from every Release build and from any physical device build (simulator-only, per repo convention "always the physical iPad, never the simulator" in CLAUDE.md) — so as shipped it cannot reach App Review at all; it is invoked only via `Sources/Heeler/HeelerApp.swift` under that same compile condition.
- Turning this into a reviewer-facing "Try the demo" path would require relaxing the compile condition (at minimum drop `targetEnvironment(simulator)`, keep some gate) and deciding whether `DEBUG` should also be dropped for a Release-build demo entry point — currently a two-line change in principle, but not present as shipped.
- No existing "App Review notes" document found in `docs/` (checked `docs/guides`, `docs/agents`, `docs/research`, `docs/design`; only tangential hits were unrelated design docs and `CHANGELOG.md`/`docs/guides/releasing.md`, neither of which addresses reviewer instructions).
- First-launch, zero-Hosts experience: `Sources/Heeler/Client/WelcomeView.swift` (root case, lines 33-38) is the app's root view with no Hosts — not a blank screen. It leads with `macSection`/`iPadSection` setup steps: enabling Remote Login (lines 92-98), installing the pairing plugin via a copyable shell command naming the upstream repo (`WelcomeView.swift:103`, see section 3 item 6), and making/scanning a Pairing Code (`WelcomeView.swift:105-111`). This is a real onboarding screen, but it still assumes the reviewer has (or can set up) a Mac running herdr with SSH enabled — nothing in it works standalone for a reviewer with no Mac/herdr access.
- **Reviewability blocker:** absent a demo mode reachable in Release/device builds, or explicit App Review notes providing a reachable test Host/credentials, App Review has no way to get past the Welcome screen to see any real functionality.

## 8. Icons and launch

- App icon: `Sources/Heeler/AppIcon.icon/` (modern Xcode 26 "Icon Composer" `.icon` package, not a classic `.xcassets/AppIcon.appiconset`) — `icon.json` + `Assets/heeler-side-profile.png` (single source image referenced by name `heeler-side-profile.png`).
- `git log --oneline --follow -- Sources/Heeler/AppIcon.icon` shows only 3 commits, all pre-dating/unrelated to Kelpie rebranding: `4d3a6ed feat(branding): use composed Heeler app icon`, `eb226fa feat(branding): add Heeler app icon`, `8feffa0 refactor: rename the app's own targets from Herdr to Heeler` — **no Kelpie-specific icon commit exists on this branch**; the app ships Heeler's icon (filename itself is `heeler-side-profile.png`) under the Kelpie product name/bundle id.
- No separate `.xcassets`/`AppIconset` found anywhere under `Sources` (confirmed via `find -iname "*.xcassets"` / `*.appiconset` — both empty) — the `.icon` package is the only icon asset in the repo. It is referenced only by the app target's sources; the two extensions (HeelerNotificationService, HeelerWidgets) have no explicit icon references in `project.yml` — Widgets extensions typically don't need a distinct icon (WidgetKit reuses the containing app's icon for the widget gallery), consistent with no dedicated Widgets/NotificationService icon assets existing.
- Whether the `.icon` package includes a full 1024pt marketing icon was not directly verified (only `icon.json` + one PNG were listed; `.icon` packages generate the marketing/App Store size from the composed layers at build/export time rather than storing a separate 1024px file — not independently confirmed here).
- Launch screen: `project.yml:92` `INFOPLIST_KEY_UILaunchScreen_Generation: YES` — auto-generated blank/system launch screen, no custom launch storyboard/assets found.

## 9. Info.plist keys likely required — presence/absence

Checked `project.yml` (all `INFOPLIST_KEY_*` settings) plus a repo-wide grep for each key name; `.ci/`, `Packages/`, `kelpie-spm`/DerivedData excluded per scope.

| Key | Present? | Evidence |
|---|---|---|
| `NSLocalNetworkUsageDescription` | **Absent** | No match anywhere in `project.yml`/`Sources`. App does SSH to LAN Macs (per CLAUDE.md); this key/local-network permission prompt is typically required for local-network *discovery* (Bonjour) rather than a direct outbound TCP/SSH connection to a known IP/hostname, which may not trigger it — but worth explicit verification since SSH may resolve to a `.local` mDNS hostname. |
| `NSPhotoLibraryUsageDescription` / `...AddUsageDescription` | **Absent**, but likely not needed | No match in `project.yml`; photo access happens via `Sources/Heeler/Images/PhotosPickerImageSelection.swift` using SwiftUI's `PhotosPicker` (also referenced in `HerdrClientRootView.swift`, `AgentTerminalView.swift`), which runs out-of-process and does not require an `NSPhotoLibrary*UsageDescription` per Apple's docs — consistent with its absence. |
| `NSCameraUsageDescription` | **Present** | `project.yml:84` — see section 3 item 2 for its Heeler-branded text. |
| `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` | **Absent** | No match found; app does not expose its container to Files.app. |
| `ITSAppUsesNonExemptEncryption` | **Present**, set `NO` | `project.yml:89`, with a comment explaining this avoids the TestFlight Missing Compliance prompt (standard SSH/CryptoKit encryption only). |
| `UIRequiresFullScreen` | **Absent, deliberately** | `project.yml:99` comment explicitly notes it is "deliberately absent" to preserve iPad multitasking (Split View/Slide Over/Stage Manager). |
| `UIApplicationSceneManifest` (multi-scene) | **Present** | `project.yml:93` `INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES` (auto-generated single-scene manifest; not verified whether multi-window/multiple-scenes is explicitly configured beyond the default). |
| `UIBackgroundModes` | **Absent** | No match anywhere — app declares no background execution modes. |

Also present, incidentally relevant to Review: `INFOPLIST_KEY_UISupportedInterfaceOrientations`/`..._iPad` (`project.yml:94-100`), `INFOPLIST_KEY_NSSupportsLiveActivities: YES` (`project.yml:107`), `INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents: YES` (`project.yml:105`, trackpad/mouse support).

## 10. Legal files

- `LICENSE` (repo root): Apache License 2.0 full text (confirmed first lines match Apache 2.0 header) — inherited from upstream Heeler, appropriate for a fork under the same license.
- `NOTICE`: **absent** — `ls NOTICE` returns "No such file or directory". Apache 2.0 doesn't strictly require a NOTICE file unless upstream shipped one with attribution notices that must be preserved (worth checking upstream Heeler's repo for whether it has a NOTICE that should have been carried over).
- Bundled third-party license texts, all under `Sources/Heeler/Resources/Notices/` (folder-referenced into the app bundle per `project.yml:56-58`, shown in-app via `AcknowledgementsView.swift`/`LicenseNotices.swift` reading `Notices/inventory.json`):
  - `libssh2-BSD-3-Clause.txt`, `libssh2-bcrypt_pbkdf-MIT.txt`, `libssh2-cipher-chachapoly-BSD-2-Clause.txt` (libssh2 and its bundled third-party components)
  - `OpenSSL-Apache-2.0.txt`
  - `libghostty-spm-MIT.txt`, `Ghostty-MIT.txt`, `GhosttyTheme-MIT.txt` (terminal engine and theme package)
  - `MSDisplayLink-MIT.txt`
  - `IBMPlexMono-OFL-1.1.txt`, `JetBrainsMono-OFL-1.1.txt` (bundled fonts)
  - `inventory.json` — the catalogue driving the in-app Acknowledgements list.
- This directly answers "does the app show third-party licenses anywhere": **yes**, Settings → About → Acknowledgements (`AcknowledgementsView.swift`), sourced from the bundled `Notices/inventory.json` + per-component `.txt` files, and is functioning/tested code (not a stub) per `LicenseNotices.swift`'s explicit error states for missing/malformed notices.

