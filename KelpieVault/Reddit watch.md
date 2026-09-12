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
  SSH). The launchd job `com.kelpie.redditwatch` is **not loaded**: the plist is
  in `scripts/launchd/`, waiting on Anthony's yes.

## Last run

<!-- redditwatch:start -->
_Last run: 2026-09-12T22-25-04Z UTC._

| Post | Comments | New | Score | State |
| --- | --- | --- | --- | --- |
| r/alphaandbetausers | 0 | 0 | n/a | ok |
| r/SideProject | n/a | 0 | n/a | unreachable |
| herdr Discussions, Show and tell | 0 | 0 | 1 | ok |
| r/herdr | 7 | 7 | n/a | ok |
| r/ClaudeCode | 90 | 90 | n/a | ok |
| r/herdr | 0 | 0 | n/a | ok |

### Waiting on a reply

- **r/herdr**, u/Delicious-Charge9693 (14 days ago): It's awesome. I sent you a DM with some suggestions. This and Moshi are both top game, Moshi terribly overpriced though. — [comment](https://www.reddit.com/r/herdr/comments/1vxsh7w/i_built_an_ios_companion_for_herdr_because_i_kept/p6ner4k/)
- **r/herdr**, u/pth (18 days ago): Looks awesome, I will be checking it out. — [comment](https://www.reddit.com/r/herdr/comments/1vxsh7w/i_built_an_ios_companion_for_herdr_because_i_kept/p5sa2mp/)
- **r/herdr**, u/Briskfall (11 days ago): Can you add a button like on the iOS reddit app where it auto scrolls to the "next" entry? (but instead of going down, it'd be going UP). That would beat scrol… — [comment](https://www.reddit.com/r/herdr/comments/1vxsh7w/i_built_an_ios_companion_for_herdr_because_i_kept/p78wkup/)
- **r/herdr**, u/zingerlittlebee (10 days ago): Great idea! I’ll look into how we can implement jumping to the previous user message. — [comment](https://www.reddit.com/r/herdr/comments/1vxsh7w/i_built_an_ios_companion_for_herdr_because_i_kept/p7arqam/)
- **r/herdr**, u/Briskfall (5 days ago): Thank you for adding it! 🙏 It's so much more convenient now! 🥳 (You wouldn't mind if I sent more feature requests? Oh I feel so so greedy... 🤤) Jk, you actuall… — [comment](https://www.reddit.com/r/herdr/comments/1vxsh7w/i_built_an_ios_companion_for_herdr_because_i_kept/p8ets56/)
- **r/herdr**, u/zingerlittlebee (4 days ago): Haha please, be as greedy as you want! 😄 Good feature requests are exactly what makes the app better. The easiest way for me to track them is to open a GitHub… — [comment](https://www.reddit.com/r/herdr/comments/1vxsh7w/i_built_an_ios_companion_for_herdr_because_i_kept/p8h5ikd/)
- **r/herdr**, u/ctaloi (10 days ago): This is great - thank you. Love it. — [comment](https://www.reddit.com/r/herdr/comments/1vxsh7w/i_built_an_ios_companion_for_herdr_because_i_kept/p7gpuf7/)
- **r/ClaudeCode**, u/prsmstz (1 hours ago): Built Plyo (plyo.dev) a home for the stuff Claude Code builds. CC saves every version to a timeline as it works (MCP server, one paste to set up), one click to… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p9f6njc/)
- **r/ClaudeCode**, u/ImL1s (6 hours ago): Portable Resume — local skills that pull context from other agents' session files (Codex, Cursor, etc.) into a fresh Claude Code session without launching the… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p9daxzg/)
- **r/ClaudeCode**, u/CartographerNo3791 (12 hours ago): I'm building Session Orchestrator, a free, MIT-licensed workflow plugin for Claude Code. It gives my sessions a repeatable loop: inspect the repo and agree on… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p9bmzn9/)
- **r/ClaudeCode**, u/agentgrid (14 hours ago): We're building AgentGrid, a desktop canvas for running Claude Code, Codex and other coding agents together. I'm posting from the AgentGrid team account. A conc… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p9bbvwd/)
- **r/ClaudeCode**, u/CartographerNo3791 (12 hours ago): Reviewing the output. I'd want each review attached to the exact revision it checked, with the command and result beside it. Then mark that evidence stale when… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p9bn6pb/)
- **r/ClaudeCode**, u/agentgrid (12 hours ago): That makes the handoff much more concrete. For a dirty worktree, a commit SHA alone also isn't enough: capture the tested diff, plus the command, exit status a… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p9bnfnf/)
- **r/ClaudeCode**, u/Extension_Phrase_954 (14 hours ago): I'm the developer of TokenTracker, a native Mac app for Claude Code and other coding agents. The workflow: leave an agent running, check its activity in the me… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p9b872h/)
- **r/ClaudeCode**, u/FunCondition33 (16 hours ago): Always end up installing the same Skills again in new repos because I don't want them globally. So I built Skillverk. https://github.com/CyberStefNef/skillverk… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p9awd7y/)
- **r/ClaudeCode**, u/unknown (18 hours ago): [deleted] — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p9ae3yf/)
- **r/ClaudeCode**, u/fabiengreard (1 days ago): https://preview.redd.it/2sgi20q5dyoh1.png?width=1254&format=png&auto=webp&s=b3aaba1ce1c61c71a3239f6999c51c02adda3039 I built TouchGrassBar, a free, open-source… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p989c9e/)
- **r/ClaudeCode**, u/Grey_Grizzled_Bear (1 days ago): Tunaboat -- An SSH tunnel manager for macOS. It keeps your port forwards in one place, shows you at a glance whether each one is actually carrying traffic, and… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p96cva3/)
- **r/ClaudeCode**, u/allixsenos (1 days ago): I'm cross-referencing text OCRd with two separate methods and then cleaning it up with Opus. I was burning through my subscription in a very unpredictable mann… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p962ixk/)
- **r/ClaudeCode**, u/asalomonae (1 days ago): I wanted my Creator Micro to follow the work, not just one coding app. That became TactiCommand, a free, MIT-licensed macOS companion. This is a tool for Claud… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p962cxz/)
- **r/ClaudeCode**, u/SetAdministrative502 (1 days ago): Building Acres, a visual notes app where notes are markdown files on disk and claude code can build the whiteboards through an MCP server that ships inside the… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p957fzk/)
- **r/ClaudeCode**, u/puts_on_rddt (2 days ago): Nothing. The 5 hour limit keeps eating up all my tokens because I'm forced to stop mid task. — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p9199ea/)
- **r/ClaudeCode**, u/chuguchak_111 (2 days ago): I used Claude code to help analyze ~600k reddit posts and comments from r/foodnyc, and created a tool for exploring the outputs. So you can see which restauran… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p9035f1/)
- **r/ClaudeCode**, u/quietnightquietstars (2 days ago): This is really fun! Easy to use, most of the summaries matched my opinion too! I want one for Chicago now :) — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p905qky/)
- **r/ClaudeCode**, u/chuguchak_111 (2 days ago): Thank you! I specifically chose this idea because I think it is something of a gold mine. There's tons of info on reddit on many different subjects, but the qu… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p907w38/)
- **r/ClaudeCode**, u/sixothree (2 days ago): I was seeing what I could do with a long one-shot prompt. It did turn into a few more prompts though refining it some. https://clickprix.com/ Formula 1 qualify… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8yhlap/)
- **r/ClaudeCode**, u/CapnAppleJacks (2 days ago): I built a Claude Code plugin for creating travel guides: https://github.com/nickeng/safe-travels https://preview.redd.it/bji9h9yhfooh1.jpeg?width=1600&format=p… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8xhhrg/)
- **r/ClaudeCode**, u/sixothree (1 days ago): Ok. I have an update. This used all of my 5-hour usage and then when that cycled used almost all of my second 5-hour usage window. The results though were extr… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p97y7md/)
- **r/ClaudeCode**, u/CapnAppleJacks (5 hours ago): Thanks for the review!🙌 I’m assuming you’re on a pro account? When I have time to play with this again I’ll add a Sonnet version which in past testing can easi… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p9dsigm/)
- **r/ClaudeCode**, u/HuckleberryOk6181 (1 days ago): That plugin sounds awesome! Turning travel suggestions into visual guides is a really cool idea. — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p932s1c/)
- **r/ClaudeCode**, u/sixothree (2 days ago): I think this used my session limit in just a few minutes. I see some 100+ files it created in the process. It looks like it's going to succeed because the cont… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8z5ei0/)
- **r/ClaudeCode**, u/CapnAppleJacks (2 days ago): demo: https://reddit.com/link/p8xhki5/video/gq5v2jsmfooh1/player — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8xhki5/)
- **r/ClaudeCode**, u/mbittt (2 days ago): Got tired of checking which of my Claude Code and Codex accounts still had usage left, so I made magazine. It's a small CLI: mag limits shows usage across your… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8vtfof/)
- **r/ClaudeCode**, u/juanviera23 (3 days ago): I wanted to find an easy and intuitive way to share skills with teammates, and found that Github was too complicated So I built an app that allows you to store… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8rrnqk/)
- **r/ClaudeCode**, u/SnooGiraffes2912 (3 days ago): MagicVault - Let agents use credentials without seeing them https://github.com/MagicBeansAI/MagicVault — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8r0bfi/)
- **r/ClaudeCode**, u/NoEgg2932 (3 days ago): Browsentic the last agentic web browsing extension you would ever need to add your browser with connection/spawning to your Claude Code. Completely free and op… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8qhxo6/)
- **r/ClaudeCode**, u/sujee81 (3 days ago): Building macOS app for AI chat - https://www.vinaa.ai/ - Organise chats in Projects and nested folders - Cloud and Local models - MCP - Prompt templates — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8pxaeu/)
- **r/ClaudeCode**, u/RedDead707 (3 days ago): Hey all, I've been job hunting and got lost tracking all my applications and custom resumes, so I built the thing I wanted and just started adding more feature… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8pvhxl/)
- **r/ClaudeCode**, u/Able_Doubt_3591 (3 days ago): I'm making spool, a local-first canvas for prototyping with an agent. Your agent writes TSX frames into your project. You can put a few directions next to each… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8pj5pk/)
- **r/ClaudeCode**, u/CodeCombustion (2 days ago): Dogfooding your product is always the best way to build it IMO if you can. — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8ym5jq/)
- **r/ClaudeCode**, u/Lopsided_Scarcity979 (3 days ago): I'm building ThoughtDAG to make past agent conversations easier to revisit. It opens local Claude Code sessions as a graph in ThoughtDAG. I can return to an ea… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8pe42s/)
- **r/ClaudeCode**, u/420megadumper (3 days ago): 2 projects right now. First is https://www.tigweldingsecrets.com, a site that promotes and sells my Welding books and merch. Kind of a sales funnel disguised a… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8nrhue/)
- **r/ClaudeCode**, u/quietnightquietstars (3 days ago): Just so you know, on Expressbrake the second button in ("View services & pricing") the hero is completely white and illegible. "Services" also overlaps with th… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8okrx9/)
- **r/ClaudeCode**, u/420megadumper (3 days ago): hmm interesting. it all shows fine on all my devices. i dont use firefox tho, so i will look into it. thank you! — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8ovhtf/)
- **r/ClaudeCode**, u/PsychologicalHost624 (4 days ago): I’ve been building ComiKumi, an open-source comic lettering and localization workspace, with Claude Code as my main coding partner. It started as a relatively… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8mbq43/)
- **r/ClaudeCode**, u/mwiatruZ (4 days ago): You changed your Claude Code instructions. How did you check that the next session got the intended version? I’m building Guidefold, an open-source tool for mo… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8l3ysq/)
- **r/ClaudeCode**, u/lutian (4 days ago): just built myself a super youtube post-prod studio i just want to film myself rambling and all the cutting, grading, uploading, thumbs, short generation is don… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8k7mks/)
- **r/ClaudeCode**, u/claude_code_king (4 days ago): apparently karma is a prerequisite for product quality, so here i am against my will. anyways, built an agentic governance architecture for claude code that fi… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8j99sn/)
- **r/ClaudeCode**, u/Bodum1 (4 days ago): https://www.runolympics.com/ Rebooting early 2000s theme games similar to newgrounds, candystand. Simple fun games that you can play with your friends and easi… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8iefub/)
- **r/ClaudeCode**, u/rbtje (4 days ago): peon-poke (https://github.com/romeobravo/peon-poke) taps your MacBook's Force Touch trackpad when Claude Code finishes or needs your input. I built it because… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8hzstv/)
- **r/ClaudeCode**, u/CodeCombustion (2 days ago): Nice! I built something like this for my MX Master 4 mouse so the haptic pad starts buzzing. — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8ymogz/)
- **r/ClaudeCode**, u/ericatmumo (4 days ago): mumo — a multi-model deliberation platform, ~6 months, built almost entirely with Claude Code. Solo founder, product background; Claude does the implementation… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8hi6t1/)
- **r/ClaudeCode**, u/Hot-Sheepherder-8396 (4 days ago): I'm building Holt, a local tool that gives coding agents context about work happening in other Git worktrees. I started it after Claude Code duplicated work an… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8gy99w/)
- **r/ClaudeCode**, u/beingthecomedian (5 days ago): TokenTab. If you're on a flat plan and running Claude Code across a few repos, the invoice is one line for the month and there's no way to see which project at… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8ee3xe/)
- **r/ClaudeCode**, u/Input-X (5 days ago): Persistent Agent Workspace — AI agents that remember, collaborate, and never start from zero https://github.com/AIOSAI/AIPass — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8drms3/)
- **r/ClaudeCode**, u/mannyocean (5 days ago): https://datatorag.com The MCP gateway for your Google workspace. Claude’s google connector has gmail, drive and calendar. no sheets, no slides, and it can’t ed… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8d582x/)
- **r/ClaudeCode**, u/mshish (5 days ago): Hi all, I've been working on Shorthand, which connects live transcription to Claude Code so it can take live meeting notes directly in Obsidian. You can also u… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8czy7t/)
- **r/ClaudeCode**, u/Worried_Menu4016 (5 days ago): Forge native macOS batch converter for images, video, audio and PDF. The trick: the filename is the command rename a file holiday_10MB.jpg and it compresses un… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8cx4o0/)
- **r/ClaudeCode**, u/Salt_Plankton_5674 (5 days ago): That sounds like a really useful tool! Batch processing files like that can save so much time, especially with those extra features for privacy and compression. — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8ffhej/)
- **r/ClaudeCode**, u/Worried_Menu4016 (4 days ago): Yeah! Plus u can create and share different setting with a interactive menu so u can create custom action and apply for the files — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8g61al/)
- **r/ClaudeCode**, u/Databit (5 days ago): Framework with agents and humans working together and nobody knows which is which. Everyone is supposed to assume all others are humans. Don't pretend you are… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8cx4e2/)
- **r/ClaudeCode**, u/whynotmatt (5 days ago): Just launched UserHook to handle comments on Facebook and Instagram. Claude did the coding, but there was a lot of design and intention behind the product. Plu… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8csgkq/)
- **r/ClaudeCode**, u/jasonnellis (5 days ago): So ManyChat for Facebook/Instagram? — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8d199z/)
- **r/ClaudeCode**, u/whynotmatt (5 days ago): Yes. I needed it for other projects I run so I built my own version. I also saw there was a lot of backlash toward ManyChat’s recent pricing model change. So U… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8d6aqr/)
- **r/ClaudeCode**, u/gouldologist (5 days ago): A Dokan file system that points extension type to either SharePoint or cloudflare r2 bucket, with the idea to limit SharePoint storage and retain coauthoring a… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8cq411/)
- **r/ClaudeCode**, u/JDE-Projects (5 days ago): A whole fleet of small apps for my day job in IT, and a few personal apps, for stuff I do all the time. Some of my projects... -Simple UNA Log Viewer, for bett… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8ckbdq/)
- **r/ClaudeCode**, u/Equianox (5 days ago): Neely - club management for team sports and clubs (web + iOS + Android), currently focused on youth handball in Germany. Scheduling, attendance, rosters, payme… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8ck0vf/)
- **r/ClaudeCode**, u/tremendousquotes (5 days ago): I’m building Humla (https://github.com/michaelwilhelmsen/humla). A free and local AI meeting notes Mac app, open source. Also has agentic embedded chat across… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8chyyw/)
- **r/ClaudeCode**, u/90420znz (4 days ago): I installed this, gonna give it a test drive :) . I wish you could somehow allow summaries via claude , if thats possible. I have a plan and would've loved to… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8id2hg/)
- **r/ClaudeCode**, u/tremendousquotes (4 days ago): Great! Let me know how it goes 🙂 thanks for the feedback, Anthropic endpoint is probably a minor addition that I can add. Will add it as an issue to be looked… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8iefit/)
- **r/ClaudeCode**, u/90420znz (4 days ago): Do you have a guide you can point me to? Thanks btw! Going to record my first meeting. Will see how it goes. :) — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8ine2h/)
- **r/ClaudeCode**, u/tremendousquotes (4 days ago): No guide at the moment, but the MCP install is a terminal 1-liner. See screenshot. Afterwards, Claude will be able to read, search and act across all your note… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8ioo1l/)
- **r/ClaudeCode**, u/90420znz (4 days ago): Tried it out, i was able to get claude to summarize, it's pretty neat. Some things i noticed, my call on teams was 25mins long, but humla captured only 17 mins… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8j88bw/)
- **r/ClaudeCode**, u/tremendousquotes (4 days ago): That's great! I'm not sure why the capture was shorter, but if I'm to take a guess, it might be a permission issue due to it being your first meeting or possib… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8jbgkn/)
- **r/ClaudeCode**, u/90420znz (4 days ago): Thanks for the tip! I didn't have those enabled. But i did. It was odd that it clipped at 17mins, but i will continue to use it. It did me well. Any other sett… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8jc4ux/)
- **r/ClaudeCode**, u/tremendousquotes (4 days ago): Should be good 😄 . Just recommend going through the settings area as there are a few quality of life settings that improve the overall experience. For example:… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8jg0mh/)
- **r/ClaudeCode**, u/90420znz (4 days ago): thanks, i applied most of them, dont have an openAI key, and im guessing that needs money? :D , i'm happy with the claude summarization for now! Thanks for the… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8jtlvj/)
- **r/ClaudeCode**, u/pete716 (5 days ago): www.dewfront.com . It's a weather app with a focus on dew point because that tells more about the actual comfort level then humidity alone. I'm always wonderin… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8cg1hx/)
- **r/ClaudeCode**, u/unknown (5 days ago): [deleted] — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8cdx00/)
- **r/ClaudeCode**, u/JDE-Projects (5 days ago): Built something with Claude Code this week? Share it here. Seems the post already answers your question. — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8ckgrz/)
- **r/ClaudeCode**, u/Few_Doughnut4293 (5 days ago): Yes 😅 never mind. I'm glad I asked. — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8cksgj/)
- **r/ClaudeCode**, u/Dano63 (5 days ago): Been building this little hobby project of mine for past few months and learning a lot about game development, sprite creations etc It's a Team rokket Version… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8cc17l/)
- **r/ClaudeCode**, u/BrilliantWheel (5 days ago): Simple 1 liner: I built a system to provide stock trade recommendations based on various backtested strategies. Its more complex than the 1 liner suggests :) A… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8cbq1a/)
- **r/ClaudeCode**, u/LifeProject365 (5 days ago): If any of you are building games and can help me with a game (in terms of directing me on the best way to build it so I'm not going to have to pay a fortune to… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8cboij/)
- **r/ClaudeCode**, u/Human_Ad6195 (5 days ago): Simple geography category daily game https://sortlas.com — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8cac7a/)
- **r/ClaudeCode**, u/jack_inquiry (5 days ago): bookmarking this — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8clijn/)
- **r/ClaudeCode**, u/Equal_Animator7440 (5 days ago): https://namethatcountry.now A site to learn about countries around the world. + an interactive world map for country flags + different flag categories (by lett… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8c95o5/)
- **r/ClaudeCode**, u/jack_inquiry (5 days ago): bookmarking this — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8clcww/)
- **r/ClaudeCode**, u/Hronom (5 days ago): I’m building Hronaut, a local visible browser for Claude Code and other MCP clients. It keeps tabs, sign-ins, and storage in named workspaces across agent sess… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8c880z/)
- **r/ClaudeCode**, u/IamHuggos (5 days ago): Multiplayer tank shooter https://sweatypanzer.com/ — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8c75oo/)
- **r/ClaudeCode**, u/Redcxx (5 days ago): Building Brain - a minimal and extensible agent runtime for distributed tool calls - https://github.com/aexhq/brain — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8c6pao/)
- **r/ClaudeCode**, u/VoidEqualZero (5 days ago): https://reddit.com/link/p8c5lh4/video/4p1aw34m83oh1/player bough github.com/nickelsec/bough Visualizes your Claude Code history as a diagram of the work you ac… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8c5lh4/)
- **r/ClaudeCode**, u/EnvironmentalRice348 (5 days ago): Unashamedly written by claude for me as it is 10pm at night here and I am tired.... Sorry about the claudish... What I built: everlasting.email — messages that… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8c5kx2/)
- **r/ClaudeCode**, u/ugenedc (5 days ago): Built an Ai Marketing director called cleo that can do everything from strategy to creating and scheduling instagram facebook posts, to setting up and managing… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8c5hcj/)
- **r/ClaudeCode**, u/ZealousidealKale8228 (5 days ago): Built a SaaS to help run mine and others businesses and reduce vendor sprawl. https://consultos.sh — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8c4gk2/)
- **r/ClaudeCode**, u/mideps (5 days ago): Created plugin for Claude Code (npm package) which helps Claude read less and still get the same answer. Saves your tokens and usage limits. Used Claude Code t… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8c34ng/)
- **r/ClaudeCode**, u/GulfGulfinson (5 days ago): Build a pipeline to turn images into living portraits that react to mouse movement, check it out: Demo: https://pinacoteca.memormaneo.com/ Example: https://mem… — [comment](https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/p8c2ldj/)

Drafts, where the analyse lane wrote one, are in `~/.kelpie/redditwatch/drafts/`. Anthony posts every reply by hand.
<!-- redditwatch:end -->
