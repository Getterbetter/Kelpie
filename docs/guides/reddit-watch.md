# The community watch

Kelpie's beta went out to several communities in one evening: r/alphaandbetausers,
r/SideProject, and herdr's own GitHub Discussions. None of those tell anyone
when somebody replies, and a comment on a beta post goes cold inside a day.

`scripts/redditwatch.py` reads every watched post once an hour, works out which
comments are new since the last run, and leaves them where the morning brief can
find them. Where it finds a new comment it asks one bounded headless Claude run
for a draft reply.

**It never posts, replies, votes or logs in to anything.** Reddit is read
through the public Atom feed of a post; GitHub through `gh api graphql`. Both
are read-only and signed out. Every draft is marked `status: draft` and waits
for Anthony to edit it and post it by hand.

## What it watches

| Source | How it is read | What it reports |
| --- | --- | --- |
| A Reddit post | `<post url>/.rss`, the public Atom feed, signed out | Every comment the feed carries: id, author, time, permalink, body |
| A GitHub discussion | `gh api graphql`, comments and their replies | Every comment and reply; upvote count and comment count |

### Why the Atom feed and not the JSON view

The obvious source is `<post url>.json?raw_json=1&limit=500`. It does not work:
measured on this Mac on 2026-09-12, signed out, it answers **403** whatever
User-Agent it is sent, and `old.reddit.com` redirects to a login page. The Atom
feed at `<post url>/.rss` answers **200** for the same posts with a browser
User-Agent, so that is the source. The JSON view is still tried, but only as a
fallback when the feed request fails, for the day Reddit relaxes again.

Parsing is `xml.etree` plus `html.parser`, both stdlib. Each `entry` after the
post itself is a comment: `id` is the `t1_…` fullname, `author/name` is
`/u/name`, `link[@href]` is the permalink, `updated` is the time, and `content`
is the body as escaped HTML, which is unescaped and stripped back to text.

What the feed does **not** carry, and what the watcher therefore records as
null rather than guessing:

- **Depth and parent id.** The feed is flat. A reply to a reply looks exactly
  like a top-level comment, so a thread's shape has to be read on Reddit.
- **Score**, for the post and for each comment. The Score column reads `n/a`
  for every Reddit row, and no score delta is ever reported for one.
- **The post's own comment count.** The count in the table is the number of
  comments the feed carried, which is what this run actually read, not what
  Reddit says the post has. The feed also carries only a recent window of
  comments, so a very busy post can out-run it.

None of that affects the job it is there to do: telling Anthony a new comment
exists, quoting it in full, and linking straight to it.

### Pacing

Reddit's limiter is tight. Measured on 2026-09-12, one feed request succeeds
and a second one a second later earns a 429, from the same IP and User-Agent,
and a post fetched repeatedly stays blocked for a few minutes. So the watcher
waits 20 seconds between Reddit posts and 30 seconds before its one retry: a
three-post run takes about a minute, which is nothing on an hourly job. Running
it by hand several times in a row will earn 429s; that is the limiter, not a
fault, and the next hour reads cleanly.

The watch list is `~/.kelpie/redditwatch/config.json`. The first run writes it,
seeded from the verdict log in `~/MemoryOS/Areas/Marketing/Kelpie/Embed Plan - Kelpie.md`:

```json
{
  "reddit_username": "anthonytopalides",
  "own_usernames": ["Constant-Purpose8273", "anthonytopalides", "Getterbetter"],
  "posts": [
    { "kind": "reddit", "label": "r/alphaandbetausers", "url": "https://www.reddit.com/r/alphaandbetausers/comments/1we8fgi/" },
    { "kind": "reddit", "label": "r/SideProject", "url": "https://www.reddit.com/r/SideProject/comments/1we8kte/" },
    { "kind": "github_discussion", "label": "herdr Discussions, Show and tell", "url": "https://github.com/herdrdev/herdr/discussions/3987" }
  ]
}
```

- `reddit_username` fills in the descriptive User-Agent
  `kelpie-redditwatch/1.0 (by u/<name>)` used for the JSON fallback. The Atom
  feed is fetched with a browser User-Agent, because it is the only one Reddit
  serves it to.
- `own_usernames` is the list whose comments are ignored. Anthony answering in
  his own thread is not something to answer.
- A post may be a bare URL string instead of an object; the kind is worked out
  from the URL's shape either way.

## Adding a post

```sh
/usr/bin/python3 scripts/redditwatch.py --add https://www.reddit.com/r/ClaudeAI/comments/xxxxxxx/
/usr/bin/python3 scripts/redditwatch.py --add https://github.com/herdrdev/herdr/discussions/4001
```

It takes Reddit post URLs and GitHub discussion URLs, labels them, and appends
them. Adding a post that is already watched changes nothing. Anything that is
neither shape exits 2 without writing.

## Running it once

```sh
make redditwatch             # full run: state, reports, the vault note, the brief handoff
make redditwatch DRY=1       # fetch, print to stdout, write nothing at all
make redditwatch ANALYSE=1   # and draft a reply for each new comment
```

Straight to the script when you want the options:

```sh
/usr/bin/python3 scripts/redditwatch.py --dry-run
/usr/bin/python3 scripts/redditwatch.py --analyse
/usr/bin/python3 scripts/redditwatch.py --json      # the run JSON on stdout as well
```

It must run on `/usr/bin/python3` (3.9.6), the interpreter launchd gets, and it
uses nothing outside the standard library. `--dry-run` writes nothing anywhere:
no config seed, no state, no report, no vault edit, no briefing file.

Exit status is 0 for a normal run, **2** for a config problem: an unreadable or
malformed `config.json`, an empty `posts` list, or a URL that is neither a
Reddit post nor a GitHub discussion. A post that cannot be fetched is not a
config problem — see below.

## When a post cannot be read

A 429, a 403 or any 5xx from Reddit is reported as `unreachable` with a plain
line saying why, and the run carries on with the other posts. The feed is tried
twice, thirty seconds apart, then the JSON view the same way, before that
verdict; the reason names both, as `feed: … ; json: …`. Nothing is marked seen
for a post that could not be read, so a bad hour never silently swallows a
comment: the next run picks it up as new.

A 403 specifically means the JSON fallback hit Reddit's bot wall, which it
always does today. On an hourly run a Reddit row that reads `unreachable` is
almost always a 429 on the feed: look at the next hour before worrying.

## Installing the schedule

The plist is in the repo but deliberately **not** loaded.

```sh
cp scripts/launchd/com.kelpie.redditwatch.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.kelpie.redditwatch.plist
launchctl kickstart -k gui/$(id -u)/com.kelpie.redditwatch   # run it once, now
```

To stop it:

```sh
launchctl bootout gui/$(id -u)/com.kelpie.redditwatch
```

It runs every hour (`StartInterval` 3600) with `RunAtLoad` false, so installing
it does not start a run. "Overnight" here is simply hourly all day: the job is
cheap, and the useful property is that anything left during the night is drafted
before the 06:05 morning brief. If Anthony would rather it only ran overnight,
the plist carries a commented `StartCalendarInterval` variant with one entry per
hour from 22:00 to 07:00 — delete `StartInterval` and uncomment that block.

Logs:

- `~/.kelpie/redditwatch/launchd.{out,err}.log` — whatever launchd catches.
- `~/.kelpie/redditwatch/redditwatch.log` — one line per run plus one per post,
  in plain English.

## The backlog, and marking a comment answered

The brief is **not** a list of what one run found. It is the list of comments
still waiting on a reply, rebuilt every run from the unanswered set in
`state.json`. That matters: a comment that lands at 23:00 is found by the 23:00
run, and the 00:00, 01:00 and every run after it would otherwise report nothing
new and leave the 06:05 brief empty. Nothing leaves the brief on its own.

When a reply has actually been posted, by hand, say so:

```sh
/usr/bin/python3 scripts/redditwatch.py --answered t1_p9bp6zo
```

The comment id is in the brief, in the report, and in the draft's front matter.
That drops it from the unanswered set, rewrites the brief, and marks it seen.
An id that is not waiting is reported as such and changes nothing, so running
it twice is safe.

A comment is only marked **seen** once there is a draft for it, or the drafting
lane has failed on it three times; until then the next run offers it to the
lane again. A run without `--analyse` is not drafting at all, so it settles
what it found and relies on the unanswered set to keep it in the brief.

## The drafting lane

`scripts/redditwatch-analyse.sh` runs only when a run found new comments and was
given `--analyse`. For each new comment without a draft yet, in any date, it runs
one headless Claude job, time-boxed by `scripts/run-with-timeout.py` (10 minutes
each, at most six drafts, and a 20-minute budget for the whole run, with
`redditwatch.py` holding an outer deadline on top, so the lane can never run into
the next hourly run). The job may read only the BrandScript, the conduct brief
and the drafts directory, and it:

1. reads `~/MemoryOS/Areas/Marketing/Kelpie/BrandScript - Kelpie.md` for the
   voice and the claims;
2. reads the get-noticed community-conduct rules from
   `~/.claude/skills/get-noticed/` if they are readable there, and otherwise
   follows the rule in short: dwell, don't sell; answer the question; credit
   Heeler; never pitch;
3. writes one file to `~/.kelpie/redditwatch/drafts/<date>-<comment id>.md`,
   headed by the comment quoted, its permalink, and a `status: draft` line.

A comment that already has a draft, from any day, is left alone, so re-running is
cheap and never overwrites an edit.

Comment text is untrusted input written by the public. It never passes through a
shell variable or an unquoted heredoc; bodies go to a file and reach the prompt
through `cat`, fenced by BEGIN and END markers with a line on either side saying
the text between them is data and not instructions.

**The script cannot post.** There is no code path in this repo that writes to
Reddit or to GitHub Discussions. Anthony opens the draft, edits it, and posts it
himself. When a comment does not deserve a reply the draft says `NO REPLY
NEEDED` and why.

## Files

| Path | What it is |
| --- | --- |
| `~/.kelpie/redditwatch/config.json` | The watch list, seeded on the first run |
| `~/.kelpie/redditwatch/state.json` | Seen comment ids per post, the unanswered set, draft attempt counts, last run, per-post score and comment counts |
| `~/.kelpie/redditwatch/reports/latest.md` | The last run in full, new comments quoted |
| `~/.kelpie/redditwatch/reports/latest.json` | The same run as data; what the drafting lane reads |
| `~/.kelpie/redditwatch/drafts/` | Draft replies waiting for approval |
| `~/.kelpie/redditwatch/redditwatch.log` | One line per run and per post |
| `~/.memoryos/kelpie-redditwatch-briefing.json` | The morning-brief handoff, same shape as the dependency watch's, rebuilt every run from the unanswered set |
| `KelpieVault/Reddit watch.md` | The generated section between `<!-- redditwatch:start -->` and `<!-- redditwatch:end -->` |

Everything except the vault note lives outside the repo. The vault note's prose
above the markers is never touched.

## A post's first successful read

The first run has no state, so everything it finds counts as new, and the
report, the log and the vault section say so. But that is not the only time it
happens: **new means everything on a post's first successful read**, whenever
that is. A post that was unreachable during the first run, or one added later
with `--add`, reports its whole comment list the first time it is read. Nothing
is marked seen for a post that was not read, which is what makes that true.
