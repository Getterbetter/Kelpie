# Round 24 (Open item 43a) — fresh-context QA review

Scope reviewed: the uncommitted diff on the paths named in the brief, plus the
regenerated `Heeler.xcodeproj` entries for the new files. Tests were **not run**
(no device); every assertion below was hand-traced against the fixture with
python.

## Findings

### 1. CI pins an exact executed count for the lane the new E2E case joins — Confirmed, must fix

`scripts/run-ci-ios-tests.sh:1750`

```
run_suite SharedFixtureE2ETests 94 6 0 \
    HeelerSSHPTYE2ETests \
    HeelerSSHJumpHostGateE2ETests \
    HeelerSSHTransportBehaviorE2ETests \
    ...
```

`run_suite` (line 1560) greps for `"Test run with $expected_tests tests in
$expected_suites $noun passed"` and exits 1 otherwise. The new case
`HeelerSSHTransportBehaviorE2ETests.hostFileRangesPageThroughAStagedFile`
(`Tests/HeelerTests/HeelerSSHTransportBehaviorE2ETests.swift:1626`) makes the
lane execute 95, so the lane fails with "SharedFixtureE2ETests did not execute
all 94 tests".

The plan's Step 7 assumed CI "pins specific test names with `assert_behavior`,
so the new case does not disturb the counts". `assert_behavior` is name-based,
but `run_suite` is *additionally* count-based, and this suite is in a
`run_suite` lane.

Why it matters: the iOS CI lane goes red on the first push that carries these
paths (`.github/workflows/ci.yml` runs on app/simulator paths, which this diff
touches).

Fix: bump `94` to `95` at `scripts/run-ci-ios-tests.sh:1750`. Nothing else
changes — the skip budget stays 0 and the suite count stays 6, and the full
lane's provenance check is satisfied because the pinned lane runs the new test.

### 2. Fixture leaks one prompt-derived string: `slug` — Confirmed, low

`Tests/Fixtures/claude-transcript-v1.jsonl` (every envelope line),
`scripts/cut-transcript-fixture.py` (no `slug` handling)

Every line carries `"slug":"we-have-some-work-shimmying-hollerith"`, Claude
Code's session slug derived from the real first prompt. The cut script's own
docstring promises "text bodies become numbered placeholders" and the plan's
Step 6 redaction list covers text, thinking, tool inputs, images, attachments,
session ids and the home path — not `slug`.

Everything else is clean: `grep -c anthonytopalides` is 0, `cwd` is
`/Users/kelpie/...` throughout, the only `sessionId` is the fixed
`00000000-0000-4000-8000-000000000000`, and `gitBranch: kelpie` is public.
The 74 distinct `uuid`/`parentUuid` values are content-free random ids kept
deliberately ("every envelope key kept").

Fix: add `slug` to the redaction pass (e.g. a constant
`"fixture-session-slug"`) and re-cut. Low severity — it is a fragment of one
of Anthony's own prompts in his own repo, not third-party data.

### 3. `bytesConsumed` is not a resume point while an oversized line is being discarded — Confirmed, low

`Sources/Heeler/Chat/ClaudeTranscriptParser.swift:85-91` vs the doc comment at
`:38-39` ("Bytes consumed through the last complete line: the durable point to
resume a fresh parser from").

In the discard path `bytesConsumed += tail.count` advances past bytes that are
*not* a complete line. A fresh `ClaudeTranscriptParser(startingAt:
bytesConsumed)` then begins mid-line and drops the remainder as malformed
(`droppedLineCount` +1), which is the same outcome the in-flight parser would
have produced, but the comment claims more than the code delivers.

The accounting itself is exact — I traced `anOversizedLineIsDroppedWithExactAccounting`
(`Tests/HeelerTests/ClaudeTranscriptParserTests.swift:179`): huge(MAX+10) with
no newline → `bytesConsumed == MAX+10`, `discardingOversizedLine = true`; then
`"yyy\n"` → drop counted once, `bytesConsumed += 4`; then the user line →
`+len+1`. Total matches the assertion.

Fix: either amend the comment ("except while an oversized line is being
discarded, when it advances past the discarded bytes") or expose
`isDiscardingOversizedLine` so a resumer knows.

## What I traced and confirmed correct

**`ClaudeTranscriptParser.feed` byte accounting.** Partial-tail hold and
release (`bytesConsumed` 0 / `nextOffset` 20 / then `bytes.count + 1`), CRLF
(`\r` stripped in `consume`, still counted in `lineBytes`), empty lines skipped
and not counted as dropped, the oversized discard/resume path (above),
`init(startingAt:)` seeding. Mid-UTF-8 splits work because splitting is on
`0x0A` only and decoding happens after reassembly.

**`HostFileProbe.framedOutput`.** First begin marker (noise dropped), *last*
end marker via `.backwards` in `afterBegin..<endIndex` — so a body containing
the literal `\n__HEELER_FILE_END__=` survives whole; body is strictly between,
the printf's own `\n` excluded, so a body ending in `\n` is preserved; empty
body at EOF; empty and non-numeric size → `fileSize == nil`; arbitrary bytes
(0xFF 0xFE 0x00 0x0A 0x0D) pass through untouched.

**The shell command.** `tail -c +1` / `+4097` (1-based, offset clamped at 0),
`head -c` clamped to `1 << 20` with no overflow at `.max`, path only ever the
trailing positional `$1` (never interpolated into the script body), `wc -c <
"$1" | tr -d " "` runs *after* the body so a growing file cannot report a false
EOF. The whole script is single-quoted, so the outer login shell passes `"$1"`
and `$(...)` through verbatim; `HerdrHostPath.wrappingBareHerdr` is a no-op
because the command word is `/bin/sh`, and `cLocaleCommand` only prefixes
`LC_ALL=C`. `printf` of the begin marker cannot be confused by body content
because the format string has no `%` and the parser takes the *first* begin and
the *last* end. Exit status: missing file → `exit 0`, no output → `.notFound`;
unreadable file → `[ -f ]` true, `tail`/`wc` fail to **stderr** (`runHostCommand`
returns `result.stdout` only), `$(...)` empty → empty size → `.notReadable`.
Both match the plan.

**Every fixture-backed assertion.** 89 rows. `title == "Fixture session title"`
(4 `ai-title` lines, all the same). `permissionMode == .plan` (4
`permission-mode` lines). `version == "2.1.272"`. `lastTurnDurationMs` from row
76 (`durationMs: 81237`). Row 0 is the only non-meta `user` row, content the
bare string `"<prompt 1>"` with a timestamp — the `isMeta` rows 78 and 84 are
skipped, and every other `user` row is a `tool_result`. The first assistant row
merges rows 23/25/27 (all `msg_011Cf68PvMJ9WewpGb7dQ7oe`) into exactly 3
`toolUse` blocks with the `thinking` line 22 producing nothing, and rows
24/26/28 carry the matching `tool_use_id`s. Row 87's tool_result has
`media_type: "image/png"` with base64 that decodes to the `89 50 4E 47` PNG
signature; row 83 has `is_error: true`. Row ids are unique across the file
(6 message ids + distinct line uuids). `cost-state`, `away_summary` and
`scheduled_task_fire` are handled (the first in `skippedTypes`, the others by
the `system`-without-`turn_duration` branch), so `droppedLineCount == 0` holds.

**`fixtureParsesTheSameHoweverItIsChunked`** with chunk 1: `parse` feeds via
`data.subdata(in:)`, so each chunk is 0-based; after the first byte `partial`
is non-empty and `feed` rebuilds a 0-based buffer. Max line is 1676 bytes, so
the repeated `partial + chunk` copy is bounded per line — 52,717 one-byte feeds
is cheap enough for a device run.

**Hand-written parser cases.** Malformed-line count (`"{not json"` and
`{"no":"type"}` both fail `type`-required decoding = 2; the empty line is
skipped uncounted). Assistant merge + `msg_9-2` uniquing after an intervening
user row. Two results in one line → `u7`, `u7-1`. Truncation at 4096 with the
flag. Block-list result joining `"a"` + `"b"` to `"a\nb"` with
`tool_reference` ignored and the image appended second. `inputSummary` table
(including `Mystery` → sorted-key fallback `"first"` and the 200-char cap with
`…`).

**Locator.** Basename-exact matching rejects `/usr/bin/claude-wrapper` and
`codex` and reports `first.name`; empty and nil foreground lists both give
`.noForegroundProcess`; the encoding cases all check out (including `"~/x"` →
`"--x"` and the two-UTF-16-unit CJK case); `transcriptPath` refuses `""`,
`"../etc"` and `"a b"`; `ScriptedTransport` records match the asserted path,
offset 0 and `maximumSessionRecordBytes`.

**Generated types.** `python3 scripts/generate-wire-types.py --check --schema
scripts/herdr-schema.json` prints "up to date" — the generated file is not
hand-edited. The memberwise inits match the tests' call sites
(`PaneProcessInfo(paneID:foregroundProcesses:shellPid:)` and
`PaneProcessInfoProcess(name:pid:argv:argv0:cwd:)` both rely on defaults that
exist).

**Repo rules.** No force unwraps or `try!` in the new source files. All new
types are `Sendable` value types; `ScriptedTransport`'s additions follow the
file's record / `set…Failure` / `gateNext…` conventions exactly, including the
`pane_not_found` throw for an unscripted pane. `Packages/` is untouched.
`Transport`'s two new methods have throwing defaults in `extension Transport`,
so `DemoScreenshotMode`'s fake needs nothing (and the brief confirms
`build-for-testing` succeeds). `xcodegen` output is committed: all nine new
files and the fixture appear in `Heeler.xcodeproj/project.pbxproj`, and
`project.yml` adds the fixture with `buildPhase: resources` next to the
`plugin/test-vectors` entries, matching the `NotificationVectorFile` bundle
idiom the loader copies.

**E2E case.** `PreparedFile(fileURL:fileExtension:byteCount:)` matches
`Sources/Heeler/Files/FilePreparer.swift:8`. `StagedFile.path` is validated
absolute (`StagedHostPath.isValid` requires a `/` prefix), so
`resolvedHostFilePath` returns it unchanged and the expected
`HostFileDownloadError.notFound(path: staged.path + ".missing")` matches
exactly; `HostFileDownloadError` is `Equatable`. The 3000-byte pattern covers
all 256 byte values, which exercises the byte-exactness claim. 1000/1000/1000
split and `reachedEnd` only on the third all follow from the probe's clamps.
The case sits inside the suite's existing
`.enabled(if: RealSSHFixture.gate(...))` trait, so it skips on device.

## Optional (ignorable)

- `ClaudeTranscriptParser.swift:192` — a `tool_result` whose content list holds
  *only* an image (no `text` part) emits no `.toolResult` block, so that row
  loses its `tool_use_id` and `is_error` and cannot be paired with its call.
  The fixture's image row (87) has two text parts, so nothing fails today.
  Changing the condition to always insert the `.toolResult` block would close
  it; 43b's UI is when it would bite.
- `ClaudeTranscriptParser.swift:79` — `buffer.subdata(in:)` when `buffer` *is*
  `chunk` and `chunk` is a `Data` slice with a non-zero `startIndex`. Correct
  on Darwin Foundation as far as I can trace, and unreachable in production
  (`HostFileProbe`'s body and `ScriptedTransport`'s slices are both 0-based),
  but no test exercises it: every test chunk is either 0-based or arrives while
  `partial` is non-empty. One `parser.feed(whole[k...])` with an empty `partial`
  would pin it.
- `HostFileProbe.swift:26` — `maxBytes: 0` becomes `head -c 1`, so a zero-byte
  request returns one byte and `nextOffset` advances. Deliberate (`head -c 0`
  would loop a caller forever) and pinned by
  `HostFileProbeTests.swift:30`; worth a word in the doc comment.
- `ClaudeTranscriptParser.skippedTypes` adds `cost-state`, which the plan did
  not list. It is in the fixture (row 88) and skipping it is right; just note
  it in the round's Decisions entry so the deviation is recorded.
- `Tests/HeelerTests/Support/ClaudeTranscriptFixture.swift:25` — `lines` is a
  computed property that re-walks the whole file on every access, and
  `line(ofType:)` calls it once per candidate. Nothing uses either yet; if 43b
  does, make it a `static let`.

## What I could not check

- No test execution: `make test-device` has not run, so nothing here is
  device-confirmed. Finding 1 is about CI, not the device suite.
- I did not run the E2E case against a real sshd, so the staged-file read is
  reasoned, not observed.
- I did not re-derive the herdr schema or re-verify the `pane.process_info`
  shape against a live server; I took the committed snapshot and the plan's
  spike capture as given.
- The vault close-out (resume.md, Decisions, Changelog, Testing status, Open
  items) is not in this diff and was out of scope.

## Verdict

**ship-with-fixes** — one line in `scripts/run-ci-ios-tests.sh` (94 → 95), plus
the `slug` redaction and the `bytesConsumed` comment if you want them in this
round. The transport, the probe, the parser and the fixture are sound.
