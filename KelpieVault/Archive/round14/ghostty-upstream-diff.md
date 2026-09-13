# GhosttyTerminal re-vendor survey (Open item 25)

Clone: `/private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/c01b525a-726c-4027-b9ac-80c757db6cd8/scratchpad/delegate-20260913T014330Z/scout-ghostty/libghostty-spm`
(full clone, not shallow; 276 commits on `main`, head `7e45d27` "release: 1.6.20260909", 2026-09-09).

## 1. Pin confirmation

`project.yml` line 25 names `356f730b` as the vendored commit. **That hash does not
exist anywhere in the clone's history** (`git log --all`, `git rev-list --all`
both come up empty). It is not a truncation-ambiguity problem — `git log --oneline`
over all 276 commits has no `356f730*` prefix at all. This matches project.yml's
own comment ("upstream removed its release tag"): the `1.4.0` tag is likewise gone
from `git tag -l` today, so the segment of history the pin names appears to have
been rewritten/force-pushed away upstream.

Reconstruction: `Packages/GhosttyTerminal/Ghostty.version` = `1.3.1` (the pinned
libghostty artifact's tag) and `Ghostty.ref` = `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
(the ghostty-core commit at that point) match `git show <tag>:Ghostty.ref` for tag
`upstream.1.3.1-3` (commit `f63f53a`) — but `f63f53a`'s tree differs enormously
from Kelpie's vendored copy (much later, post-refactor). The commit actually
tagged `release: 1.4.0` in the clone is **`701d3a5ed4b409c74ca6ae9ed8ff31429959d995`**
(2026-08-20), and diffing Kelpie's vendored `Packages/GhosttyTerminal` against
that commit's tree (excluding `KELPIE-PATCHES.md`, `Artifacts/`, `.build`, and
top-level scaffolding not vendored at all — `Example/`, `Patches/`, `Script/`,
`build.sh`, `.github/`, `Package.local.swift`, `Package.swift.template`) turns up:

- `Package.swift`: only the binary-target block differs, exactly as expected
  (Kelpie points at a local `Artifacts/GhosttyKit.xcframework` path; upstream at
  that commit points at `upstream.1.3.1`'s release URL + checksum — same as
  `scripts/fetch-ghostty-artifact.sh` fetches today).
- `Sources/GhosttyTerminal/Surface/TerminalSurface.swift`: differs by exactly the
  documented `KELPIE-PATCHES.md` patch (the public `sendMousePos(x:y:modifiers:)`
  wrapper), nothing else in the file.
- `Sources/GhosttyTerminal/Resources/Ghostty/shell-integration/`: Kelpie's copy
  carries `bash/ghostty.bash` and a full `zsh/` directory that
  `701d3a5`'s tree does not have. This is a real (if minor, resource-only)
  divergence — either the true `356f730b` sits a few commits after `701d3a5` (a
  zsh-integration addition not otherwise visible in this diff), or the vendoring
  step pulled these two files from a different point. Not an API-surface issue.

**Conclusion: the vendored tree is, modulo the documented sendMousePos patch and
that shell-integration resource wrinkle, consistent with the "reviewed 1.4.0
source commit" project.yml describes — but the literal `356f730b` hash cannot be
verified because it is unreachable in upstream's current history.** A re-vendor
cannot `git diff 356f730b..origin/main`; it must diff by content/tag as done here.

## 2. Commits since the pin

Using `701d3a5` (release 1.4.0, the best available proxy for the pin) as the
base: **78 commits** to `origin/main` (`7e45d27`). Release tags in that range, in
order: `1.5.0` → `1.5.1` → `1.5.2` → `1.5.20260903` → `1.5.20260906` →
`1.6.20260909` (head). (`upstream.1.3.1` — what `fetch-ghostty-artifact.sh`
downloads today — sits *before* the pin's own tree state.)

Commits touching the four watched paths, `701d3a5..origin/main`:

- **`Sources/GhosttyTerminal/Platform/UIKit/`**: 22 commits, most relevantly
  `d22fa8e` (tap clicks/pointer scroll/file pastes/sticky keys), `d65adaf` (key
  path for hosts), `96f5ce6`/`8051615` (host seams / platform-branch guard),
  `3fdf2f0` (expose surface+selection publicly), `2f2ba29`/`bf81cd4` (synthetic
  key release, long-press anchor fix), **`eb4107b` (first-class pointer input)**,
  and later pure refactors (`fb3b1d0`, `a200caa`, `1d3cc9c`, `4fa38f5`) that move
  code between files without changing signatures (verified below).
- **`Surface/TerminalSurface.swift`**: 4 commits — `3fdf2f0`, `6215870`,
  `eb4107b`, `4fa38f5`.
- **`Package.swift`**: 9 commits — mostly release-version/checksum bumps
  (`41e83fd`, `4a92e01`, `a2565cc`, `7e45d27`) and the Ghostty-core rebases
  (`c655243` adding visionOS slices, `e6255b4`/`7a9d833` dropping bundled
  GPL resources and shipping MIT shell integration instead, `f4d9fbd`,
  `eb4107b`).

## 3. `open`/`public` UIKit member changes, pin → head

`UITerminalView+Interaction.swift` at the pin (`701d3a5`) declares as
`open`/`public`: `touchesBegan/Moved/Ended/Cancelled`, `copy(_:)`, `paste(_:)`,
`canPerformAction(_:withSender:)`, `gestureRecognizerShouldBegin(_:)`,
`contextMenuInteraction(...)`. At head, the same file only still holds
`touchesBegan/Moved/Ended/Cancelled` and `gestureRecognizerShouldBegin(_:)` —
`copy`/`paste`/`canPerformAction`/`contextMenuInteraction` **moved** to a new
`UITerminalView+Clipboard.swift` (pure file-split refactor: `fb3b1d0`/`a200caa`),
`selectionMenuPoint(at:)` lives in `UITerminalView.swift` throughout. Diffed the
retained members' full signatures pin vs. head: **byte-identical** (no renames,
no parameter changes) for `touchesBegan/Moved/Ended/Cancelled`,
`gestureRecognizerShouldBegin`, `copy(_:)`, `paste(_:)`, `canPerformAction`,
`contextMenuInteraction`, `selectionMenuPoint(at:)`.

`eb4107b` itself adds new members rather than changing old ones: `TerminalSurface`
gains `sendMouseButton(state:button:modifiers:)`, `sendMousePos(x:y:modifiers:)`,
`sendMouseScroll(x:y:mods:)` (default-valued overloads of the existing internal
calls) and `isMouseCaptured: Bool`; UIKit gains a `UIPointerInteraction` wired up
internally (line ~125 of the interaction file, trackpad hover/cursor shape) plus
new files `TerminalPointerPolicy.swift` and additions to
`UITerminalView+PublicInput.swift`/`TerminalViewState.swift`.

### Kelpie overrides vs. upstream change

`grep override Sources/Heeler/Terminal/` turns up ~60 overrides, all on
`HeelerTerminalView: UITerminalView` (in `TerminalScreenView.swift`) plus
unrelated overrides on Kelpie's own view classes (`TerminalAgentSwitcher`,
`TerminalSelectionOverlayView`, `TerminalKeyboard`, `TerminalKeyBar`,
`TerminalTextSelectionPresenter` — not `UITerminalView` subclass members, out of
scope here).

| Kelpie override (on `UITerminalView`) | Upstream pin→head change |
|---|---|
| `touchesBegan/Moved/Ended/Cancelled` | Untouched (signature-identical) |
| `gestureRecognizerShouldBegin(_:)` | Untouched |
| `contextMenuInteraction(...)` | Untouched (only relocated file) |
| `selectionMenuPoint(at:)` | Untouched |
| `canPerformAction(_:withSender:)` | Untouched (only relocated file) |
| `copy(_:)` / `paste(_:)` | Untouched (only relocated file); note `sendMousePos` calls (line ~2265/2276 of `TerminalScreenView.swift`) are Kelpie's own patch call sites, unaffected |

No Kelpie override is broken (nothing it overrides was removed, renamed, or
resignatured). None is duplicated either: Kelpie's own pointer work (ADR 0016 —
trackpad right-click, long-press-to-right-click, two-finger long-press
selection, wheel scrolling) is built on hand-encoded SGR mouse reports
(`TerminalMouseReporting`, `TerminalTouchScroll` sending `.wheelUp/.wheelDown`
button reports) and the OSC 8 link query (`TerminalSurfaceLinkQuery`,
`HeelerTerminalView.surfaceLinkURL(at:)`), not on `UIPointerInteraction`.
`grep -rn "UIPointerInteraction\|pointerInteraction" Sources/Heeler/Terminal/`
returns nothing — Kelpie never touches the new pointer-interaction path
upstream added, so no functional overlap exists to reconcile, and nothing in
`eb4107b` needs adapting around.

## 4. `sendMousePos` signature verdict

Upstream `eb4107b` (`Sources/GhosttyTerminal/Surface/TerminalSurface.swift`):
```swift
public func sendMousePos(
    x: Double,
    y: Double,
    modifiers: TerminalInputModifiers = []
)
```
Kelpie's `KELPIE-PATCHES.md` patch:
```swift
public func sendMousePos(x: Double, y: Double, modifiers: TerminalInputModifiers)
```
**Identical parameter list, labels and types** (`x: Double, y: Double,
modifiers: TerminalInputModifiers`); the only difference is upstream gives
`modifiers` a `= []` default value, which is additive and does not break any
call that (like Kelpie's) passes all three arguments explicitly. A re-vendor
past `eb4107b` can drop the local patch and `KELPIE-PATCHES.md` outright — call
sites need no change.

## 5. Head release / binary target

Newest tag: **`1.6.20260909`** (2026-09-09), same commit as `origin/main` head
(`7e45d27`). `Package.swift` at head:
```swift
url: "https://github.com/Lakr233/libghostty-spm/releases/download/upstream.82938b633ba6/GhosttyKit.xcframework.zip"
checksum: "2d9a26e80c3836c450f03ea2cf9d191841d9093d4f61c1cea466d2fc8e215dbb"
```
vs. today's `scripts/fetch-ghostty-artifact.sh`:
```
URL="https://github.com/Lakr233/libghostty-spm/releases/download/upstream.1.3.1/GhosttyKit.xcframework.zip"
SHA="68156e6c8f384816a6fa9703a589f82cebd16702887aa4073ee06b7943ec4ecb"
```
**Both the release tag and the checksum changed** — the prebuilt libghostty
itself moved forward (`Ghostty.ref` went from `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
to `82938b633ba646db38591d969c3c526332bd7e65`, i.e. two ghostty-core bumps: an
intermediate `c4e16970a803` release and then `82938b633ba6` at head). A
re-vendor past `eb4107b` must update both the URL and the checksum in
`scripts/fetch-ghostty-artifact.sh` (and `Package.swift`'s binary-target comment)
to the `upstream.82938b633ba6` tag's asset — this is a materially larger jump
than a same-libghostty bump, consistent with the round-13 note that Anthony
deliberately deferred the "larger, unaudited 1.5.1 source and binary update."

## Not done (per brief)

Did not clone or inspect the ghostty core itself.
