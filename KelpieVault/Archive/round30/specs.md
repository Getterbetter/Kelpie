# Round 30 — worker briefs (2026-09-17)

Delegated from the main session (Fable 5.1 as manager); three Opus builders in parallel, one Opus reviewer, the device suite run by the manager. The briefs as given, condensed.

## Item 19 — the in-app banner never shows while Kelpie is foregrounded (opus-builder)

Find the cause by reading the code, fix, cover with unit tests. Candidates in order: (a) the Console's Agent list not refreshing while the herdr client owns the screen; (b) the preference gate failing closed on unconfirmed notify flags; (c) the 3 s hold cancelled by a cleared snapshot; (d) presented-Agent suppression matching on the root screen. Smallest fix in the owning files only; stop and write options if the cause needs a transport-model decision. Build check once with `build-for-testing` on the iPad in a scratch derived-data path, deleted after. Return: diagnosis, files, tests, build result. Second pass after review: the fallback must not fire for a Host whose Notifications toggle the user turned off (the surviving Notification Key is the discriminator `flagsToCarry` already uses); log the fallback once per Host per state change.

## Composer — soft newline and responder-flow coverage (opus-builder)

Decided design: a soft newline commits the field's current line and starts a fresh field line, like submit but sending `\` then CR (Claude Code inserts a prompt line break). Trigger: a pinned `return.left` key beside the composer toggle in the key bar pill, visible only while the composer is on; no sticky-modifier path; no Shift+Return (the composer is off with a hardware keyboard); no newline inside the field. Tests for focus/resign, the keyboard claim, the handoff freeze and release, `typeIntoField`, control keys, backspace on an empty field, Return and pasted blocks; assert behaviour, main-actor, no sleeps. Files: TerminalComposer.swift, TerminalKeyBar.swift, HeelerTerminalView (handler only), TerminalComposerTests.swift, CHANGELOG.md.

## TCP keepalive and the primary-host constant (opus-builder)

`SO_KEEPALIVE` on, `TCP_KEEPALIVE` 15 s, `TCP_KEEPINTVL` 5 s, `TCP_KEEPCNT` 3, through one public helper in HeelerSSH called from the socket setup after connect; best effort, a failure logged and swallowed; a getsockopt read-back test in HeelerTests (the package's own tests need a simulator). `PrimaryHostStore.defaultsKey` becomes the one internal definition and PairingSync refers to it.

## Review (opus-reviewer)

All three diffs, fresh context: must-fix / should-fix / nit with file:line and evidence, a verdict per piece. Result in `review.md`.
