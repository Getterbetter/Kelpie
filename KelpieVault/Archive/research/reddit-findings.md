---
source: "delegate-20260910-191536/reddit/findings.md — scout report on the r/herdr Heeler thread, 2026-09-10 19:19"
---

# Reddit r/herdr iOS thread findings (scout, 2026-09-10)

Post: u/zingerlittlebee, ~2026-08-25, "I built an iOS companion for herdr because I kept SSHing into my Mac just to check on agents."
App: Heeler, native iOS agent console for herdr. Priority-sorted agent list (Blocked first), live terminal steering,
keyboard toolbar (Esc/Tab/arrows), file/photo staging, E2E-encrypted push, Live Activities / Dynamic Island.
Connects: plain SSH + herdr's existing API (herdr.sock). Paired by QR code from a bundled herdr plugin. No server changes.
Open source: https://github.com/ZingerLittleBee/Heeler (tag v0.1.1). TestFlight beta only, no App Store link.
iPad: not mentioned anywhere in OP or comments.

Feature requests (~4 comments):
1. Briskfall: jump-to-previous-entry (up) button + jump-to-bottom. Dev: will do; later shipped. Dev asks for future requests as GitHub issues.
2. Delicious-Charge9693: suggestions via DM, not visible.
3. pth, ctaloi: praise only.

No mentions of iPad, right-click/context menu, mouse, Blink, tmux. Termius only in OP's aside about abandoning it.
Other subreddit posts skimmed (TermRover mobile, herdr-corral, dev-server workflow): nothing relevant.
Reddit blocked WebFetch/curl; scout used the Chrome browser tools.
