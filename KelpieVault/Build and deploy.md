---
note: The exact commands that work on this Mac, and the two quirks that force them.
---

# Build and deploy

Project root `~/Developer/Kelpie`, branch `kelpie`. Everything goes through `xcodebuild` directly rather than Xcode's Run button — see [[#Why not Xcode's Run]].

## Build, install and launch on the iPad

The only path that actually works. Device id `09D7738D-2173-55EF-8966-A9C3EA1D0514` (Anthony's 11-inch iPad Pro, M4; confirm with `xcrun devicectl list devices` and look for a *physical*, *connected* row).

```sh
S=~/Library/Caches/kelpie-build   # the one fixed build path; never the repo, never a session scratchpad
D=09D7738D-2173-55EF-8966-A9C3EA1D0514

xcodebuild build \
  -project Heeler.xcodeproj -scheme Heeler -configuration Release \
  -destination "platform=iOS,id=$D" \
  -clonedSourcePackagesDirPath "$S/kelpie-spm" \
  -derivedDataPath "$S/kelpie-dd" \
  -allowProvisioningUpdates

xcrun devicectl device install app --device "$D" \
  "$S/kelpie-dd/Build/Products/Release-iphoneos/Kelpie.app"

xcrun devicectl device process launch --device "$D" TME.Kelpie
```

- **One fixed build path, reused by every session** (2026-09-15). Session scratchpads under `/private/tmp/claude-501/` are never deleted, and building in them, one folder per session and per delegate worker, left 22 GB of dead derived data (81 folders across 9 sessions) and 3.2 GB free on the disk. A build that cannot use `$S` (a worktree, a delegate worker, a second build while another session's holds the lock) builds in its scratchpad and deletes its derived data, SPM clone and `.xcresult` as soon as it has installed or reported. After a re-vendor, delete `$S/kelpie-dd` as well.
- **Always pass both `-clonedSourcePackagesDirPath` and `-derivedDataPath`.** Two builds sharing one derived-data path lock each other out — a real failure seen during round 1, where a concurrent run deadlocked on `CompilationCache.noindex/generic/lock` and another died with "database is locked … two concurrent builds running in the same filesystem location".
- Run `xcodebuild` in the background, tee to a log file, and read only the tail. Its output is long and mostly noise.
- `-configuration Debug` works the same way; the product then lands in `Build/Products/Debug-iphoneos/`.
- Simulator builds (when one is ever wanted) use `-destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' CODE_SIGNING_ALLOWED=NO`. They compile fine; they just cannot be launched here. See [[Testing status]].

### Why not Xcode's Run

Xcode's Run builds Debug and attaches a debugger, which is slower to start and slower to use. The `xcodebuild` + `devicectl install` + `devicectl process launch` sequence against a Release build is what Anthony prefers and what he actually uses.

## Signing

| | |
| --- | --- |
| Team | `8JQWBQKEXX` (`DEVELOPMENT_TEAM`, project-level, inherited by every target) |
| Bundle IDs | `TME.Kelpie`, `.NotificationService`, `.Widgets`, `.tests` |
| App group / keychain access group | `group.TME.Kelpie.shared` |
| Device family | `"1,2"` on the app and both extensions |
| Provisioning | Automatic; `-allowProvisioningUpdates` registers what is missing |
| Export options | `scripts/ExportOptions.plist` already carries team `8JQWBQKEXX` (for a future `make testflight`) |

`INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents: YES` on the app target is what lets trackpad and mouse events reach the app at all.

## Regenerating the project

`Heeler.xcodeproj` is committed and CI builds it, so it must be regenerated and committed alongside any change to `project.yml` **or any new Swift file** — sources are folder-based but the file list is baked into the generated project.

```sh
xcodegen generate     # or: make generate  (also runs the Ghostty fetch below)
git add project.yml Heeler.xcodeproj
```

`xcodegen` 2.46.0, installed via Homebrew.

## The vendored libghostty artifact

```sh
scripts/fetch-ghostty-artifact.sh
```

Downloads `GhosttyKit.xcframework.zip` from the pinned libghostty-spm release, verifies SHA-256 `68156e6c…4ecb`, and unpacks it into `Packages/GhosttyTerminal/Artifacts/` — which is gitignored, so a fresh clone needs this before it can build. Idempotent: it exits immediately if the framework is already there. `make generate` runs it first.

## The two machine quirks

### 1. Xcode's downloader hangs on remote binary targets

Every `xcodebuild` invocation — `build`, `-resolvePackageDependencies`, even `-showBuildSettings` — hung indefinitely at "Resolve Package Graph", with no output ever appearing. Three distinct configurations were tried (default signing; signing disabled; `-skipPackageUpdates -disableAutomaticPackageResolution` against already-checked-out packages), all identical. A stack sample showed the process parked in `mach_msg2_trap`, waiting on an internal Xcode service that never answers — **not** the network: `curl` and `git ls-remote` to GitHub returned instantly throughout.

The trigger is the remote `binaryTarget` in `libghostty-spm`. The fix is to vendor the package (commit `98cb6b6`): `Packages/GhosttyTerminal` holds the pinned commit (`356f730b` at first; `7e45d27`, release 1.6.20260909, since round 16 on 2026-09-15, fetching `upstream.82938b633ba6`), its binary target points at a local `Artifacts/GhosttyKit.xcframework`, and the fetch script above gets that file with `curl`.

Recorded in the user's memory as *Xcode binary artifact download hangs*.

### 2. The iOS simulator does not run reliably

Not enough RAM on this Mac. Installs and launches wedge with `Mach error -308 — (ipc/mig) server died`; a simulator has shut itself down mid-install unprompted; `xcrun simctl install` on a booted device has hung for over five minutes on its own. An authorised `simctl erase` + reboot did not help. Both rounds hit it, on both iPad and iPhone destinations.

2026-09-15: every simulator was erased to free disk space (`xcrun simctl erase all`). The device definitions are kept, so recreate nothing; a destination boots empty.

**So: do not spend time on the simulator.** Build and run on the physical iPad. The cost is that the XCTest suite, which needs a host app, has effectively not been runnable — see [[Testing status]].

Recorded in the user's memory as *iOS simulator unusable, use the iPad*.

## Tests

```sh
xcodebuild test -project Heeler.xcodeproj -scheme Heeler \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' \
  -only-testing:HeelerTests \
  -clonedSourcePackagesDirPath "$S/kelpie-spm" -derivedDataPath "$S/kelpie-dd"
```

That is the simulator form, which never boots here. **The suite runs on the iPad** (since round 12c; 2058 tests in about 80 s plus the Debug build):

```sh
rm -rf "$S/HeelerTests.xcresult"   # xcodebuild refuses a result bundle path that already exists
xcodebuild test -project Heeler.xcodeproj -scheme Heeler \
  -destination 'platform=iOS,id=09D7738D-2173-55EF-8966-A9C3EA1D0514' \
  -only-testing:HeelerTests \
  -clonedSourcePackagesDirPath "$S/kelpie-spm" -derivedDataPath "$S/kelpie-dd" \
  -resultBundlePath "$S/HeelerTests.xcresult" -allowProvisioningUpdates > "$S/test.log" 2>&1
```

Read the `✘` lines and the `Test run with N tests` line from the log. A handful of tests cannot pass on hardware by design (they read source files from the Mac, or assume an iPhone destination, or need the software keyboard, which a docked Magic Keyboard hides); the current list is in [[Testing status]] under round 16. Never reuse a derived-data path from another checkout or worktree: the precompiled libghostty module is keyed to that tree's `ghostty.h` and the run fails before testing anything. And after a re-vendor, delete `Packages/GhosttyTerminal/Artifacts/GhosttyKit.xcframework` in every checkout and run the fetch script again: the binary is gitignored, so a checkout that did not build the re-vendor keeps the old one silently.

**Since 2026-09-12 the suite runs in GitHub Actions on the fork** (`.github/workflows/ci.yml`, macos-26 runner) on every pull request into `kelpie`, so the way to run the tests is to open a PR. Two Kelpie-specific steps make that work: the workflow fetches the vendored libghostty artifact before building (it is gitignored), and `scripts/run-ci-ios-tests.sh` boots an iPad simulator (`HEELER_CI_SIM_MODEL`, default `iPad Air 11-inch (M4)`) because Kelpie is iPad-only. The real-SSH fixtures are flaky on hosted runners: three of the first five runs failed on a different transient connection error each time, and upstream sees the same, so re-run a red run once before reading it as a regression. Details in [[Dependency watch]] and `docs/guides/dependency-watch.md`.

`TEST_HOST` is pinned in `project.yml` to `$(BUILT_PRODUCTS_DIR)/Kelpie.app/Kelpie`, because XcodeGen derives it from the *target* name (Heeler) while the product is `Kelpie.app`.

Related: [[Architecture]] · [[Testing status]] · [[Pairing and setup]] · [[Archive/round1/fork-notes|the original hang diagnosis]]

## TestFlight upload, the recipe that works (2026-09-13, build 3)

`make bump`, then `xcodebuild archive` for `generic/platform=iOS` with the session's path flags, then unlock the Thyme keychain (`~/Developer/maple-and-salt-agent/config/asc/thyme-dist.keychain-db`, password in `keychain-pass.txt`), then `xcodebuild -exportArchive -exportOptionsPlist scripts/ExportOptions-manual.plist` — the repo's automatic-signing `scripts/ExportOptions.plist` fails with "Failed to Use Accounts" on this Mac, the manual one names the three App Store profiles under `~/Library/MobileDevice/Provisioning Profiles/` — then `xcrun altool --upload-app -f Kelpie.ipa -t ios --apiKey NNU3BKC99D --apiIssuer 69a6de91-4abe-47e3-e053-5b8c7c11a4d1` (the `.p8` lives in `~/.appstoreconnect/private_keys/` or next to the keychain). Build 3's delivery id `7f51e9a6-f931-4ccd-a829-ec4fd2759940`.


### Re-vendoring the package

Clone `github.com/Lakr233/libghostty-spm` at the new commit, replace everything under `Packages/GhosttyTerminal` except `Artifacts/` (leave out `Example/`, `Patches/`, `Script/`, `build.sh`, `.github/`, `Package.local.swift`, `Package.swift.template`), point the binary target in `Package.swift` back at the local `Artifacts/GhosttyKit.xcframework` path with the upstream URL and checksum in a comment, put the new tag and checksum in `scripts/fetch-ghostty-artifact.sh`, delete the old xcframework and run the script (the checksum must verify; never edit it to match), update the comment in `project.yml`, `xcodegen generate`, then compile the app and the test target. Expect upstream's new non-open conformances or private selectors to collide with `HeelerTerminalView` overrides: round 16 hit three (an Escape selector, `UIDropInteractionDelegate`, `UIGestureRecognizerDelegate`), all fixed on Kelpie's side. Round 16's report: `KelpieVault/Archive/round16/revendor-report.md`.
