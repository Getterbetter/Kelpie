# Kelpie

Kelpie is Anthony's private iPadOS fork of [[Heeler upstream|Heeler]], an open-source iOS SSH client for [[herdr]] — the terminal multiplexer that runs his AI coding agents on the Mac mini. Kelpie's job is to put herdr's own TUI on an 11-inch iPad Pro, full-bleed, and make a trackpad, a Magic Keyboard and ten fingers all work against it.

Named for the Australian kelpie, a herding dog — a sibling to Heeler.

## Status — 2026-09-11

- Branch `kelpie`, 17 commits on top of upstream Heeler. Remote `upstream` only. **Nothing has ever been pushed.**
- Round 1 (evening of 2026-09-10): rebrand, iPad device family, trackpad/mouse right-click reaching herdr, touch long-press as right-click, trackpad and wheel scrolling, split-view collapse. Built, reviewed, two fixes applied.
- Round 2 (2026-09-11): herdr's own client became the root screen, Heeler's console demoted behind a floating menu, automatic keyboard mode, tappable URLs, 12 pt default font on iPad. Built, reviewed, six fixes applied (`58199a7`).
- The round-2 Release build is installed on Anthony's iPad Pro and paired with the mini. **He is testing it now and will bring feedback** — record it in [[Feedback log]] before acting.
- Distribution: Xcode sideload today. TestFlight later, App Store possibly. No pull request upstream for now.

## The notes

| Note | What's in it |
| --- | --- |
| [[Decisions]] | Every decision, with date and rationale |
| [[Architecture]] | The stack, root navigation, key files, how input flows |
| [[herdr]] | What herdr is and the facts about it Kelpie depends on |
| [[Heeler upstream]] | The fork's parent: author, licence, differences, rebase and push relay |
| [[Build and deploy]] | The exact commands that work on this Mac, and the two quirks |
| [[Pairing and setup]] | Mini-side and iPad-side setup, the clipboard trick |
| [[Onboarding proposal]] | First-run Welcome screen proposal (round 3, not built) |
| [[Testing status]] | What is verified, what is only compiled, what nobody has seen run |
| [[Open items]] | The checklist, including reviewer nits not yet taken |
| [[Changelog]] | The 17 Kelpie commits, by round |
| [[Feedback log]] | Anthony's round-1 feedback, and a space for round 2 |

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
