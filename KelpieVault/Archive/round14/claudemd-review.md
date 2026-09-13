# CLAUDE.md review

## 1. Token table (words / tokens≈words×1.35)

| Scope | Words | Tokens |
|---|---|---|
| Whole file | 3080 | 4158 |
| Kelpie section (lines 1-51) | 749 | 1011 |
| Heeler section (lines 52-end) | 2331 | 3147 |
| — Root screen (7-20) | 131 | 177 |
| — Running it (21-29) | 151 | 204 |
| — Build quirks (30-36) | 112 | 151 |
| — Definition of done (37-51) | 285 | 385 |
| — Architecture (56-62) | 268 | 362 |
| — Load-bearing herdr facts (63-91) | 1609 | 2172 |
| — Conventions (92-106) | 368 | 497 |
| — Agent skills (107-end) | 45 | 61 |

## 2. Classification (paragraph/bullet level)

**Kelpie section**
- "Start here" pointer, "Kelpie is Anthony's iPadOS fork…" identity/remote line, `docs/adr/0017` cross-ref — (a) keep, short rules/pointers.
- Root screen paragraph (7-20) — (b) candidate: substance duplicated nowhere yet found in vault as architecture description; recommend moving prose to `docs/adr/0017-herdr-client-is-the-screen.md` (verified exists) with CLAUDE.md keeping only "root screen is `HerdrClientRootView`; behavior in ADR 0017."
- "Running it" whole block (21-29) — (d) duplicated near-verbatim in `KelpieVault/Build and deploy.md:7-108` (device id, xcodebuild/devicectl commands, clonedSourcePackagesDirPath rationale, exportOptions manual-signing path all present there). Keep only the "always physical iPad, never simulator" rule (a); move command block, pointing to `KelpieVault/Build and deploy.md`.
- Build quirks bullets (30-36): GhosttyTerminal vendoring/KELPIE-PATCHES.md — (a) keep (a rule: never edit vendored pkg). xcodegen-after-new-file / commit project — (a) keep, short. ADR 0016 pointer — (a) keep. depwatch bullet — (b)/(d): substance likely in `KelpieVault/Dependency watch.md` (per resume.md round 10) — candidate to shorten to a pointer.
- Definition of done (37-51) — (a) keep entirely: this is process instruction, not fact; it's the enforcement contract (script exists, hook exists, verified).

**Heeler section**
- Intro para — (a) keep (identity/vocabulary pointer).
- Architecture bullets (56-62) — (d) duplicated: stack/transport description overlaps `CONTEXT.md` and ADR 0001/0004/0011 (all exist). Candidate to trim to pointers.
- Load-bearing herdr facts (63-91, 1609 words — largest block): `KelpieVault/herdr.md` **explicitly declares** (line 66) it does NOT duplicate this list and defers to CLAUDE.md as canonical ("kept in the repo's CLAUDE.md, not duplicated here"). So per the vault's own design this section is (a) keep — it is the canonical home, not a duplicate to remove. Two bullets reference `docs/research/herdr-0.9.0-compatibility.md` (exists) — already pointer-style, fine as-is.
- Conventions (92-106) — mixed: `make` targets, test commands, CI description — (a) keep (rules). Swift 6/no force-unwrap, key policy — (a) keep.
- Agent skills (107-end) — (a) keep, already terse pointers to `docs/agents/*.md` and `CONTEXT.md`.

## 3. Verification results — no mismatches found
All checked: `Sources/Heeler/Client/HerdrClientRootView.swift`, `scripts/check-round-closeout.sh`, `.githooks/pre-push`, `scripts/depwatch.py`, `docs/guides/dependency-watch.md`, `Packages/GhosttyTerminal/KELPIE-PATCHES.md`, `docs/adr/0016-ipad-pointer-input.md`, `docs/adr/0017-herdr-client-is-the-screen.md` exist. Make targets `hooks`, `closeout-check`, `depwatch`, `generate` all present in Makefile. `kelpie.primary-host` key found in both `Sources/Heeler/Pairing/PairingSync.swift:112` and `Sources/Heeler/Client/PrimaryHostStore.swift:13` — same literal string in two files (not a contradiction of CLAUDE.md, but worth Anthony's eye as a duplicate constant). Bundle id `TME.Kelpie` and team `8JQWBQKEXX` confirmed in project.yml. Remotes confirmed: `origin` = Getterbetter/Kelpie, `upstream` = ZingerLittleBee/Heeler.

## 4. Recommendations (ordered by tokens saved, estimated)
1. Collapse "Running it" build-command block to the one-line simulator-ban rule + pointer to `KelpieVault/Build and deploy.md` — saves ~180 tokens.
2. Trim Architecture bullets (56-62) to stack names + ADR/CONTEXT.md pointers — saves ~250 tokens.
3. Shorten Root-screen paragraph to 2 lines + ADR 0017 pointer — saves ~130 tokens.
4. Shorten depwatch bullet to a pointer at `KelpieVault/Dependency watch.md` — saves ~40 tokens.
5. No cut recommended for "Load-bearing herdr facts" — it's the vault's designated canonical source; cutting it would break `herdr.md`'s own deferral.
6. Keep "Definition of done" and Conventions in full — these are enforced rules, not facts.
7. Flag (don't cut) the duplicate `kelpie.primary-host` constant across two Swift files for Anthony's judgment.
8. No stale/contradicted claims found to correct.

Estimated total saveable: ~600 tokens (~14% of whole file) without losing any enforced rule.
