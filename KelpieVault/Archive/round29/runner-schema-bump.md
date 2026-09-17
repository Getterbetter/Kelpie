# Schema re-vendor to v0.9.1 (protocol 22) — result

1. Copied `~/.kelpie/depwatch/cache/herdr-schema-v0.9.1.json` → `scripts/herdr-schema.json`. OK.
2. `generate-wire-types.py --schema scripts/herdr-schema.json`: wrote the file, exit 0.
   `--check`: "up to date", exit 0.
3. `git diff --stat`: only `scripts/herdr-schema.json` changed (+64/-0) among files I own; other diffs shown belong to other workers (Notifications/, plugin/). **`Sources/Heeler/Transport/Generated/HerdrAPITypes.swift` has ZERO diff** — `generated.diff` is empty.
   - Schema diff (89 lines, all additions, nothing removed): new request method `pane.link.resolve` (params `PaneLinkActivateParams`, an existing type), new `PaneLinkRegion` type, new success-response variant `pane_link_resolved`. Matches the expected shape exactly.
   - Counted via `schemas.request.oneOf` / `schemas.event.$defs.EventData.oneOf`: **103 request methods** (was 102 for 0.9.0 — the +1 is `pane.link.resolve`), **26 event kinds** (unchanged).
   - Why the generated Swift file didn't change: `generate-wire-types.py`'s `METHODS` list (line ~48) is a hand-curated subset of 22 methods (ping, agent.*, events.subscribe, tab.create, pane.read/close/process_info, session.snapshot, workspace.*, worktree.*) — it does not include `pane.link.resolve` and isn't derived from the schema's full method list. So a schema-only diff with no touched METHODS entry legitimately produces no Swift diff. Not a bug; flagging since the brief expected a `PaneLinkRegion` type to show up in the generated output and it doesn't (the type isn't pulled in until a curated method references it).
4. Build: `xcodebuild build ... -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**, no `error:` lines. Ran once, finished before the 600s mark (no second run needed).
   Test suite: `Tests/HeelerTests/GeneratedWireTypesTests.swift` exists (`@testable import Heeler`, `Testing` framework) but lives in the `HeelerTests` host-app target — needs a sim/device, not run per brief.
5. `rm -rf <folder>/build` done — confirmed gone (`du` reported "No such file or directory" after; was 532M before deletion).

Files touched (mine only): `scripts/herdr-schema.json`, `Sources/Heeler/Transport/Generated/HerdrAPITypes.swift` (no-op regeneration, content unchanged).
