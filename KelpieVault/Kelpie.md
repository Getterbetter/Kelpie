# Kelpie

Kelpie is Anthony's private iPadOS fork of [[Heeler upstream|Heeler]], an open-source iOS SSH client for [[herdr]] — the terminal multiplexer that runs his AI coding agents on the Mac mini. Kelpie's job is to put herdr's own TUI on an 11-inch iPad Pro, full-bleed, and make a trackpad, a Magic Keyboard and ten fingers all work against it.

Named for the Australian kelpie, a herding dog — a sibling to Heeler.

## Status — 2026-09-12

- Branch `kelpie`, 69 commits on top of upstream Heeler `375267c`. Remotes `origin` (public github.com/Getterbetter/Kelpie, branch kelpie, pushed) and `upstream` (Heeler).
- Round 1 (evening of 2026-09-10): rebrand, iPad device family, trackpad/mouse right-click reaching herdr, touch long-press as right-click, trackpad and wheel scrolling, split-view collapse. Built, reviewed, two fixes applied.
- Round 2 (2026-09-11): herdr's own client became the root screen, Heeler's console demoted behind a floating menu, automatic keyboard mode, tappable URLs, 12 pt default font on iPad. Built, reviewed, six fixes applied (`58199a7`).
- Rounds 3 to 6 (2026-09-11): keys that reach herdr (Escape, Cmd+., Option word keys), Welcome screen and paste-first pairing, photos and files into a pane, all four orientations with a width-aware font, touch selection with handles and hold-then-drag. Round 7: rebase onto upstream `375267c`. Rounds 7b to 9: the App Store push (public repo, own push relay, tip jar, review host, 1.0 submitted 2026-09-12). The round-7c Release build (`a42e62e`) is installed on Anthony's iPad Pro and paired with the mini; the device checklist is in [[Open items]].
- Round 10 (2026-09-12): the [[Dependency watch]] runs daily at 05:45, opens one GitHub issue per moved dependency, and its first pass made CI real on the fork (PR #2: vendored libghostty fetched on the runner, iPad simulator, licence inventory and zoom tests fixed; 1648 tests green). The Mac mini's herdr version is watched through a dedicated key.
- Distribution: App Store 1.0 in preparation: ASC record filled, build 1 uploaded, three uploads and the submit remain — see [[App Store plan]]. No pull request upstream for now.

## The notes

| Note | What's in it |
| --- | --- |
| [[Decisions]] | Every decision, with date and rationale |
| [[Architecture]] | The stack, root navigation, key files, how input flows |
| [[herdr]] | What herdr is and the facts about it Kelpie depends on |
| [[Heeler upstream]] | The fork's parent: author, licence, differences, rebase and push relay |
| [[App Store plan]] | The path to a free Kelpie on the App Store: decisions, gates, status |
| [[Build and deploy]] | The exact commands that work on this Mac, and the two quirks |
| [[Pairing and setup]] | Mini-side and iPad-side setup, the clipboard trick |
| [[Onboarding proposal]] | First-run Welcome screen (round 3, built) |
| [[Mac vs iPad gaps]] | What the iPad still lacks versus sitting at the Mac, ranked |
| [[Window size workshop]] | Split View / Slide Over / Stage Manager: facts, options, recommendation |
| [[Testing status]] | What is verified on the device, what CI covers, what nobody has seen run |
| [[Dependency watch]] | What Kelpie depends on, the daily watch, and what to do when something moves |
| [[Open items]] | The checklist, including reviewer nits not yet taken |
| [[Changelog]] | Every Kelpie commit, by round |
| [[Feedback log]] | Anthony's feedback, verbatim, every round, with how it was read |

## Archive

Verbatim copies of every spec, review, scout report and build note the two rounds produced.

- Research: [[Archive/research/heeler-findings|Heeler architecture]] · [[Archive/research/herdr-findings|herdr]] · [[Archive/research/reddit-findings|the Reddit thread]] · [[Archive/research/inputmap|Heeler input map]] · [[Archive/research/navmap|round 2 navmap]] · [[Archive/research/ghostty-and-herdr-cli-findings|Ghostty and the herdr CLI]]
- Round 1: [[Archive/round1/SPEC|spec]] · [[Archive/round1/fork-notes|fork notes]] · [[Archive/round1/notes|build notes]] · [[Archive/round1/verify-notes|verification attempt]] · [[Archive/round1/review|review]]
- Round 2: [[Archive/round2/SPEC2|spec]] · [[Archive/round2/notes|build notes]] · [[Archive/round2/review|review]]

## Identity

| | |
| --- | --- |
| Bundle ID | `TME.Kelpie` (extensions `.NotificationService`, `.Widgets`, tests `.tests`) |
| Team | `8JQWBQKEXX` |
| App group | `group.TME.Kelpie.shared` |
| Display name / product | Kelpie (`Kelpie.app`) |
| Swift module, targets, project, scheme | still **Heeler** — deliberately, see [[Decisions]] |
| Repo | `~/Developer/Kelpie`, branch `kelpie` |
| Device | 11-inch iPad Pro (M4), id `09D7738D-2173-55EF-8966-A9C3EA1D0514` |

Working files in the repo that mirror parts of this vault: `resume.md` (session start point), `CLAUDE.md` (Kelpie section at the top), `CHANGELOG.md` (Kelpie section), `docs/adr/0016-ipad-pointer-input.md`, `docs/adr/0017-herdr-client-is-the-screen.md`.
