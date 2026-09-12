---
note: The exact commands that work on this Mac, and the two quirks that force them.
---

# Build and deploy

Project root `~/Developer/Kelpie`, branch `kelpie`. Everything goes through `xcodebuild` directly rather than Xcode's Run button — see [[#Why not Xcode's Run]].

## Build, install and launch on the iPad

The only path that actually works. Device id `09D7738D-2173-55EF-8966-A9C3EA1D0514` (Anthony's 11-inch iPad Pro, M4; confirm with `xcrun devicectl list devices` and look for a *physical*, *connected* row).

```sh
S=<a scratch dir>          # never the repo
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

The trigger is the remote `binaryTarget` in `libghostty-spm`. The fix is to vendor the package (commit `98cb6b6`): `Packages/GhosttyTerminal` holds the pinned commit `356f730b`, its binary target points at a local `Artifacts/GhosttyKit.xcframework`, and the fetch script above gets that file with `curl`.

Recorded in the user's memory as *Xcode binary artifact download hangs*.

### 2. The iOS simulator does not run reliably

Not enough RAM on this Mac. Installs and launches wedge with `Mach error -308 — (ipc/mig) server died`; a simulator has shut itself down mid-install unprompted; `xcrun simctl install` on a booted device has hung for over five minutes on its own. An authorised `simctl erase` + reboot did not help. Both rounds hit it, on both iPad and iPhone destinations.

**So: do not spend time on the simulator.** Build and run on the physical iPad. The cost is that the XCTest suite, which needs a host app, has effectively not been runnable — see [[Testing status]].

Recorded in the user's memory as *iOS simulator unusable, use the iPad*.

## Tests

```sh
xcodebuild test -project Heeler.xcodeproj -scheme Heeler \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' \
  -only-testing:HeelerTests \
  -clonedSourcePackagesDirPath "$S/kelpie-spm" -derivedDataPath "$S/kelpie-dd"
```

The recipe is the build recipe with `test` and a simulator destination — *if* a simulator ever boots. The test target **cannot** compile for a device destination at all: `SidebarConsoleIntegrationTests` uses `DemoScreenshotComposition`, which sits behind `#if DEBUG && targetEnvironment(simulator)`. That is pre-existing and applies to any change.

**Since 2026-09-12 the suite runs in GitHub Actions on the fork** (`.github/workflows/ci.yml`, macos-26 runner) on every pull request into `kelpie`, so the way to run the tests is to open a PR. Two Kelpie-specific steps make that work: the workflow fetches the vendored libghostty artifact before building (it is gitignored), and `scripts/run-ci-ios-tests.sh` boots an iPad simulator (`HEELER_CI_SIM_MODEL`, default `iPad Air 11-inch (M4)`) because Kelpie is iPad-only. The real-SSH fixtures are flaky on hosted runners: three of the first five runs failed on a different transient connection error each time, and upstream sees the same, so re-run a red run once before reading it as a regression. Details in [[Dependency watch]] and `docs/guides/dependency-watch.md`.

`TEST_HOST` is pinned in `project.yml` to `$(BUILT_PRODUCTS_DIR)/Kelpie.app/Kelpie`, because XcodeGen derives it from the *target* name (Heeler) while the product is `Kelpie.app`.

Related: [[Architecture]] · [[Testing status]] · [[Pairing and setup]] · [[Archive/round1/fork-notes|the original hang diagnosis]]
