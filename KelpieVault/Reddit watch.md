---
note: The hourly watch on Kelpie's community posts, what it found, and who is still waiting on a reply.
---

# Reddit watch

The [[Kelpie]] beta went out to several communities in one evening, and not one
of them tells anyone when somebody replies. A comment on a beta post goes cold
inside a day. So there is a watcher: `scripts/redditwatch.py` reads every
watched post once an hour, works out which comments are new since the last run,
and writes the table below.

It never posts, votes, replies or logs in. Reddit is read through the public
Atom feed of a post, GitHub through `gh api graphql`. Where it finds a new
comment it asks one bounded headless Claude run for a draft reply, grounded in
[[Kelpie]]'s BrandScript and the get-noticed community-conduct rules, and leaves
it in `~/.kelpie/redditwatch/drafts/` marked `status: draft`. **Anthony edits
every draft and posts it by hand.** Nothing in the repo can post for him.

## What it watches

Seeded from the verdict log in `Embed Plan - Kelpie.md`:

- r/alphaandbetausers, the beta call.
- r/SideProject, the project share.
- herdr's GitHub Discussions, Show and tell, as a second source kind.

Add another with `/usr/bin/python3 scripts/redditwatch.py --add <url>`. It takes
Reddit post URLs and GitHub discussion URLs and works out which is which.

## How to read it

Each row is one watched post and what it looked like this hour.

- **New** is comments not seen on any previous run, ignoring anything written
  by Anthony's own accounts.
- **unreachable** means the post could not be read this run: Reddit rate
  limiting, its bot wall, or a server error. It is not an error and it does not
  stop the other posts; the next hour tries again. Nothing is marked seen for a
  post that could not be read, so nothing is silently missed.
- The first run seeds state and counts everything as new, and so does any
  post's first successful read: one that was unreachable at first, or added
  later with `--add`.
- **The waiting list does not clear itself.** Every new comment stays in the
  table above and in the morning brief until a reply has actually been posted
  and `scripts/redditwatch.py --answered <comment id>` says so. A comment that
  arrives at 23:00 is therefore still in the 06:05 brief.

## The source is the Atom feed, not the JSON view

The obvious way to read a Reddit post is `<post url>.json`. It does not work:
measured here on 2026-09-12, signed out, it answers **403** whatever User-Agent
is sent, and `old.reddit.com` redirects to a login page. The Atom feed at
`<post url>/.rss` answers **200** for the same posts with a browser User-Agent,
so that is what the watcher reads, parsed with `xml.etree` and `html.parser`.
The JSON view is kept as a fallback for the day Reddit relaxes again.

The feed costs three things, all recorded as null rather than guessed:

- **Depth and parent id.** The feed is flat, so a reply to a reply looks like a
  top-level comment. Thread shape has to be read on Reddit.
- **Score**, on the post and on each comment, so Reddit rows show `n/a`.
- **The post's own comment count.** The number in the table is what the feed
  carried, which is what the run read; the feed carries only a recent window,
  so a very busy post can out-run it.

None of that touches the job: say a new comment exists, quote it in full, link
straight to it.

Reddit's limiter is tight — one feed request succeeds, a second a second later
earns a 429 — so the watcher waits 20 seconds between posts and 30 before its
one retry. A row reading `unreachable` is usually that, and the next hour reads
cleanly. Running it by hand several times in a row will earn 429s.

A read-only OAuth credential would sidestep all of it, but it means the watch
holds a Reddit token: Anthony's call. Logging the job in was out of scope.

## Where things live

- State, config, reports, drafts and logs: `~/.kelpie/redditwatch/` — never in
  the repo.
- Latest report: `~/.kelpie/redditwatch/reports/latest.md`.
- Drafts waiting for approval: `~/.kelpie/redditwatch/drafts/`.
- Morning-brief handoff: `~/.memoryos/kelpie-redditwatch-briefing.json`, the
  same shape the [[Dependency watch]] hands over.
- The guide, including the load command: `docs/guides/reddit-watch.md`.

## How it was switched on

- 2026-09-12: built alongside the [[Dependency watch]], same conventions. First
  cut read the `.json` view and found every Reddit post walled behind a 403;
  switched to the Atom feed, which works. State seeded by manual runs: all three
  posts recorded, including the first real comment on the r/SideProject post
  (u/Training_Mail_973, asking how a pasted photo is resized before it goes over
  SSH). The launchd job `com.kelpie.redditwatch` was bootstrapped from
  `scripts/launchd/` the same day and has run hourly since (57 runs by
  2026-09-15; the earlier wording here said it was still waiting).

## Last run

<!-- redditwatch:start -->
_Last run: 2026-09-15T07-00-13Z UTC._

| Post | Comments | New | Score | State |
| --- | --- | --- | --- | --- |
| r/alphaandbetausers | 0 | 0 | n/a | ok |
| r/SideProject | 1 | 0 | n/a | ok |
| herdr Discussions, Show and tell | 0 | 0 | 1 | ok |
| r/herdr | n/a | 0 | n/a | unreachable |
| r/ClaudeCode | 99 | 0 | n/a | ok |
| r/herdr | 0 | 0 | n/a | ok |

Nothing new since the last run.
<!-- redditwatch:end -->
