# depwatch builder notes

## Facts gathered (2026-09-12)
- repo /Users/anthonytopalides/Developer/Kelpie, branch kelpie, remotes origin=Getterbetter/Kelpie, upstream=ZingerLittleBee/Heeler. One worktree only.
- schema: scripts/herdr-schema.json top keys [$schema, protocol(22), schema_version(1), schemas, title].
  schemas = error_response, event, request, subscription_event, success_response.
  methods: schemas.request.oneOf[].properties.method.const  (generate-wire-types.py generate(), line ~334)
  event kinds: schemas.event.$defs.EventKind.enum (snake_case, e.g. workspace_created)
  sub event kinds: schemas.subscription_event.$defs.SubscriptionEventKind.enum (dotted, pane.output_matched...)
  per-kind subtree for "changed": EventData.oneOf variant with properties.type.const == kind
- Kelpie used methods: 18 via grep -rhoE 'method: *"[a-z_.]+"' Sources
- Event kinds live in Sources/Heeler/Transport/HerdrEvents.swift (hand-written, DOTTED spellings),
  NOT in Sources/Heeler/Transport/Generated/ (that dir only has HerdrAPITypes.swift = data types).
  => cross-reference by scanning Sources for either spelling as a quoted literal.
- fetch-ghostty-artifact.sh: URL=.../releases/download/upstream.1.3.1/GhosttyKit.xcframework.zip, SHA=68156e...
- Packages/HeelerSSH/Sources.lock: LIBSSH2_COMMIT=c7557852..., OPENSSL_VERSION=3.6.3
- openssl releases: 3.6.4 (2026-08-25) newer than pinned 3.6.3 (2026-06-09) => low
- repo security-advisories endpoints return [] for both openssl and libssh2 (they publish elsewhere) -> note as limit
- gh run list -R Getterbetter/Kelpie == [] ; actions/workflows total_count 0 => ci-fork high
- relay origin: Sources/Heeler/Notifications/NotificationRelayEndpoint.swift productionBaseURLString
- ~/.ssh/config has Host kelpie-review
- xcodebuild: Xcode 26.4.1 / Build 17E202 ; ci.yml runs-on: macos-26
- plugin/package-lock.json exists; relay has none
- lock pattern copied from ~/.memoryos/territory-refresh.sh lines 40-60
- Makefile help awk: /^[a-z-]+:.*## / ; .PHONY line 21

## Progress
- [x] recon
- [x] scripts/depwatch.py (10 checks, pure/impure split)
- [x] scripts/depwatch_test.py (46 tests) + scripts/test-depwatch.sh
- [x] scripts/fixtures/depwatch/ (gh releases x3, npm audit, state.json, sources sample, vault sample)
- [x] scripts/depwatch.sh, scripts/depwatch-analyse.sh, scripts/launchd/com.kelpie.depwatch.plist
- [x] docs/guides/dependency-watch.md, KelpieVault/Dependency watch.md
- [x] Makefile target appended
- [x] verifications 1-6 all pass; outputs saved in this folder
DONE
