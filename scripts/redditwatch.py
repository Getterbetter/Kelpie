#!/usr/bin/env python3
"""Kelpie community watch: notice who replied, draft an answer for the morning.

Usage:
    scripts/redditwatch.py                  # fetch, write state/reports/vault/brief
    scripts/redditwatch.py --dry-run        # fetch, print, write nothing at all
    scripts/redditwatch.py --analyse        # after a run with new comments, draft replies
    scripts/redditwatch.py --add <url>      # add a post to the watch list
    scripts/redditwatch.py --answered <id>  # a reply was posted by hand; clear it

Kelpie's beta was announced in a handful of communities. Each of those posts is
a conversation Anthony has to answer within a day or it goes cold, and none of
them push a notification anywhere he reads. This watcher fetches every watched
post once an hour, works out which comments are new since the last run, and
leaves them where the morning brief can find them. A comment stays in the brief
until Anthony has answered it and said so with `--answered`: a reply found at
23:00 has to survive every run between then and breakfast.

It never posts, votes, replies or logs in. Reddit is read through the public
Atom feed of a post (`<post url>/.rss`), GitHub through `gh api graphql`; both
are read-only.
Replies are drafted by `scripts/redditwatch-analyse.sh` into
`~/.kelpie/redditwatch/drafts/` and are always posted by Anthony, by hand.

Everything the watcher owns lives outside the repo, under `--state-dir`
(default `~/.kelpie/redditwatch`). The only repo write is the generated section
of `KelpieVault/Reddit watch.md`.

Stdlib only, and it must run on /usr/bin/python3 (3.9). See
docs/guides/reddit-watch.md.
"""

from __future__ import annotations

import argparse
import datetime
import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree
from html.parser import HTMLParser
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

DEFAULT_STATE_DIR = Path.home() / ".kelpie" / "redditwatch"
DEFAULT_BRIEFING_PATH = Path.home() / ".memoryos" / "kelpie-redditwatch-briefing.json"
VAULT_NOTE = "KelpieVault/Reddit watch.md"
VAULT_BEGIN = "<!-- redditwatch:start -->"
VAULT_END = "<!-- redditwatch:end -->"

ANALYSE_SCRIPT = "scripts/redditwatch-analyse.sh"
# A comment is only marked seen once its draft exists or the drafting lane has
# failed on it this many times. Past that, a comment nobody can draft for would
# be offered to the lane every hour forever.
MAX_DRAFT_ATTEMPTS = 3
# The drafting lane's own budget is 20 minutes (redditwatch-analyse.sh). This is
# the outer deadline, so the hourly job can never run into the next hour.
ANALYSE_TOTAL_TIMEOUT = 20 * 60 + 30

HTTP_TIMEOUT = 20.0
GH_TIMEOUT = 60.0
# Reddit's limiter is tight: measured 2026-09-12, one feed request succeeds and
# a second one a second later earns a 429, from the same IP and User-Agent. So
# the fetches are spaced out rather than hurried. Three posts cost about a
# minute, which is nothing on an hourly job.
RETRY_PAUSE_SECONDS = 30.0
REDDIT_PAUSE_SECONDS = 20.0
RUN_HISTORY_LIMIT = 60

# Reddit answers 429 when it is rate limiting, 403 when a view is behind its bot
# wall, 5xx when it is simply unwell. None of those mean the post is gone, so
# they are reported as "unreachable" and retried next hour.
TRANSIENT_STATUS = {403, 429, 500, 502, 503, 504}

# The Atom feed is the source. The `.json` view answers 403 to a signed-out
# request from this Mac whatever User-Agent it sends (measured 2026-09-12), and
# old.reddit.com redirects to a login page; `<post url>/.rss` answers 200 with a
# browser User-Agent. So the feed is tried first and the JSON view is kept only
# as a fallback for the day Reddit relaxes again, or for a post the feed cannot
# serve. Both are signed out and read-only.
BROWSER_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/128.0 Safari/537.36"
)
USER_AGENT_TEMPLATE = "kelpie-redditwatch/1.0 (by u/%s)"
DEFAULT_REDDIT_USERNAME = "anthonytopalides"

ATOM = "{http://www.w3.org/2005/Atom}"

EXIT_OK = 0
EXIT_CONFIG = 2

# The posts the beta announcement went out to, from
# ~/MemoryOS/Areas/Marketing/Kelpie/Embed Plan - Kelpie.md (verdict log,
# 2026-09-12 evening). `--add` appends; nothing here is re-seeded once the
# config file exists.
SEED_POSTS = [
    {
        "kind": "reddit",
        "label": "r/alphaandbetausers",
        "url": "https://www.reddit.com/r/alphaandbetausers/comments/1we8fgi/",
    },
    {
        "kind": "reddit",
        "label": "r/SideProject",
        "url": "https://www.reddit.com/r/SideProject/comments/1we8kte/",
    },
    {
        "kind": "github_discussion",
        "label": "herdr Discussions, Show and tell",
        "url": "https://github.com/herdrdev/herdr/discussions/3987",
    },
]

# u/Constant-Purpose8273 is the account the posts went out from; anything it
# wrote is Anthony talking to himself, not something to answer.
SEED_OWN_USERNAMES = ["Constant-Purpose8273", "anthonytopalides", "Getterbetter"]

SEED_CONFIG = {
    "reddit_username": DEFAULT_REDDIT_USERNAME,
    "own_usernames": SEED_OWN_USERNAMES,
    "posts": SEED_POSTS,
}


class ConfigError(Exception):
    """The config file is missing something the run cannot invent."""


# ---------------------------------------------------------------------------
# Pure helpers: no network, no gh, no writes.
# ---------------------------------------------------------------------------


REDDIT_POST_URL = re.compile(
    r"^https?://(?:[a-z0-9-]+\.)?reddit\.com/r/([A-Za-z0-9_]+)/comments/([A-Za-z0-9]+)"
)
GITHUB_DISCUSSION_URL = re.compile(
    r"^https?://github\.com/([^/]+)/([^/]+)/discussions/(\d+)"
)


def classify_url(url):
    """`reddit` / `github_discussion` / None, from the URL's shape alone."""
    if not isinstance(url, str):
        return None
    if REDDIT_POST_URL.match(url.strip()):
        return "reddit"
    if GITHUB_DISCUSSION_URL.match(url.strip()):
        return "github_discussion"
    return None


def reddit_parts(url):
    """(subreddit, post id) for a Reddit post URL, else (None, None)."""
    match = REDDIT_POST_URL.match((url or "").strip())
    if match is None:
        return (None, None)
    return (match.group(1), match.group(2))


def github_parts(url):
    """(owner, repo, number) for a GitHub discussion URL, else (None, None, None)."""
    match = GITHUB_DISCUSSION_URL.match((url or "").strip())
    if match is None:
        return (None, None, None)
    return (match.group(1), match.group(2), int(match.group(3)))


def post_key(entry):
    """A stable key for state, independent of trailing slashes and titles."""
    url = (entry.get("url") or "").strip()
    kind = entry.get("kind") or classify_url(url)
    if kind == "reddit":
        subreddit, post_id = reddit_parts(url)
        if post_id:
            return "reddit:%s:%s" % (subreddit, post_id)
    if kind == "github_discussion":
        owner, repo, number = github_parts(url)
        if number:
            return "github:%s/%s#%d" % (owner, repo, number)
    return "url:%s" % url.rstrip("/")


def post_label(entry):
    label = (entry.get("label") or "").strip()
    if label:
        return label
    url = (entry.get("url") or "").strip()
    kind = entry.get("kind") or classify_url(url)
    if kind == "reddit":
        subreddit, post_id = reddit_parts(url)
        return "r/%s %s" % (subreddit, post_id)
    if kind == "github_discussion":
        owner, repo, number = github_parts(url)
        return "%s/%s discussion #%d" % (owner, repo, number)
    return url or "unknown post"


def normalise_config(raw, path):
    """Fill in the defaults and refuse a config that cannot be watched.

    Raises ConfigError for anything a run cannot proceed without: that is the
    one failure that exits 2, because a broken watch list is a silent watch.
    """
    if not isinstance(raw, dict):
        raise ConfigError("%s is not a JSON object" % path)
    posts = raw.get("posts")
    if posts is None:
        raise ConfigError("%s has no `posts` list" % path)
    if not isinstance(posts, list):
        raise ConfigError("%s: `posts` is %s, not a list" % (path, type(posts).__name__))

    username = raw.get("reddit_username") or DEFAULT_REDDIT_USERNAME
    if not isinstance(username, str) or not username.strip():
        raise ConfigError("%s: `reddit_username` must be a non-empty string" % path)
    username = username.strip().removeprefix("/u/").removeprefix("u/")

    own = raw.get("own_usernames")
    if own is None:
        own = [username]
    if not isinstance(own, list) or any(not isinstance(name, str) for name in own):
        raise ConfigError("%s: `own_usernames` must be a list of strings" % path)

    entries = []
    for index, entry in enumerate(posts):
        if isinstance(entry, str):
            entry = {"url": entry}
        if not isinstance(entry, dict):
            raise ConfigError("%s: posts[%d] is neither a URL nor an object" % (path, index))
        url = (entry.get("url") or "").strip()
        if not url:
            raise ConfigError("%s: posts[%d] has no url" % (path, index))
        kind = entry.get("kind") or classify_url(url)
        if kind not in ("reddit", "github_discussion"):
            raise ConfigError(
                "%s: posts[%d] (%s) is neither a Reddit post nor a GitHub discussion"
                % (path, index, url)
            )
        entries.append(
            {
                "kind": kind,
                "url": url,
                "label": (entry.get("label") or "").strip(),
                "key": post_key({"kind": kind, "url": url}),
            }
        )
    return {
        "reddit_username": username,
        "own_usernames": [
            name.strip().removeprefix("/u/").removeprefix("u/")
            for name in own
            if name.strip()
        ],
        "posts": entries,
    }


def reddit_json_url(url):
    """The public JSON view of a post: no auth, no API app, read only."""
    base = (url or "").strip().rstrip("/")
    return base + ".json?raw_json=1&limit=500"


def reddit_rss_url(url):
    """The public Atom feed of a post: no auth, no API app, read only."""
    base = (url or "").strip().rstrip("/")
    return base + "/.rss"


def user_agent(username):
    return USER_AGENT_TEMPLATE % (username or DEFAULT_REDDIT_USERNAME)


class _TextExtractor(HTMLParser):
    """Reddit's Atom `content` is escaped HTML; this turns it back into text."""

    def __init__(self):
        HTMLParser.__init__(self, convert_charrefs=True)
        self.chunks = []

    def handle_data(self, data):
        self.chunks.append(data)

    def handle_starttag(self, tag, attrs):
        if tag in ("br", "p", "div", "li", "blockquote", "pre"):
            self.chunks.append("\n")

    def handle_endtag(self, tag):
        if tag in ("p", "div", "li", "blockquote", "pre"):
            self.chunks.append("\n")

    def text(self):
        joined = "".join(self.chunks)
        # Reddit escapes the markup once and the body's own entities twice, so
        # one more unescape after the tags are gone finishes the job.
        joined = html.unescape(joined)
        joined = re.sub(r"[ \t]+\n", "\n", joined)
        joined = re.sub(r"\n{3,}", "\n\n", joined)
        return joined.strip()


def strip_html(markup):
    """Plain text from the escaped HTML in an Atom `content` element."""
    if not markup:
        return ""
    unescaped = html.unescape(markup)
    unescaped = re.sub(r"<!--.*?-->", "", unescaped, flags=re.DOTALL)
    parser = _TextExtractor()
    try:
        parser.feed(unescaped)
        parser.close()
    except Exception:
        # A malformed body is still worth reporting, just without the markup.
        return html.unescape(re.sub(r"<[^>]+>", " ", unescaped)).strip()
    return parser.text()


def normalise_feed_time(value):
    """`2026-09-12T10:10:25+00:00` -> `2026-09-12T10:10:25Z`, or None."""
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("+00:00"):
        return text[:-6] + "Z"
    return text


def parse_reddit_feed(xml_text, own_usernames):
    """Comments from a post's Atom feed.

    The feed carries one `entry` for the post itself and one per comment, with
    the comment's fullname in `id`, the author in `author/name` as `/u/name`,
    the permalink in `link[@href]`, the time in `updated`, and the body as
    escaped HTML in `content`. It does **not** carry depth, parent id, score or
    the post's own counts, so those are recorded as null rather than guessed.
    """
    own = {name.lower() for name in own_usernames or []}
    root = ElementTree.fromstring(xml_text)
    feed_title = root.findtext("%stitle" % ATOM)
    entries = root.findall("%sentry" % ATOM)

    # The post is the entry whose id is a `t3_` fullname. Falling back to "the
    # first entry" keeps a feed that stops carrying ids from being read as one
    # extra comment.
    comment_entries = [
        entry
        for entry in entries
        if (entry.findtext("%sid" % ATOM) or "").startswith("t1_")
    ]
    if not comment_entries and entries:
        comment_entries = entries[1:]

    comments = []
    for entry in comment_entries:
        author = entry.findtext("%sauthor/%sname" % (ATOM, ATOM)) or ""
        author = author.strip().removeprefix("/u/").removeprefix("u/")
        if author.lower() in own:
            continue
        link = entry.find("%slink" % ATOM)
        comments.append(
            {
                "id": (entry.findtext("%sid" % ATOM) or "").strip() or None,
                "type": "comment",
                "author": author or None,
                # The feed is flat: it says nothing about who replied to whom.
                "depth": None,
                "parent_id": None,
                "created_utc": None,
                "created_at": normalise_feed_time(entry.findtext("%supdated" % ATOM)),
                "permalink": (link.get("href") if link is not None else None),
                "body": strip_html(entry.findtext("%scontent" % ATOM)),
                "score": None,
            }
        )
    return {
        "comments": [c for c in comments if c["id"]],
        "title": feed_title,
    }


def flatten_reddit_comments(listing, own_usernames, depth=0, parent_id=None):
    """Every comment in the tree, depth first, plus a marker per `more` stub.

    Reddit nests replies inside each comment and truncates deep or busy threads
    with a `more` stub. The stub is kept as a record of its own so a run can say
    "N more not fetched" rather than quietly under-reporting.
    """
    own = {name.lower() for name in own_usernames or []}
    results = []
    children = ((listing or {}).get("data") or {}).get("children") or []
    for child in children:
        kind = child.get("kind")
        data = child.get("data") or {}
        if kind == "more":
            count = data.get("count") or len(data.get("children") or [])
            results.append(
                {
                    "id": "more:%s" % (data.get("id") or parent_id or "root"),
                    "type": "more",
                    "author": None,
                    "depth": depth,
                    "parent_id": parent_id,
                    "created_utc": None,
                    "permalink": None,
                    "body": "%d more not fetched" % int(count or 0),
                    "count": int(count or 0),
                }
            )
            continue
        if kind != "t1":
            continue
        author = data.get("author")
        comment_id = data.get("name") or ("t1_%s" % data.get("id"))
        permalink = data.get("permalink")
        record = {
            "id": comment_id,
            "type": "comment",
            "author": author,
            "depth": data.get("depth", depth),
            "parent_id": data.get("parent_id") or parent_id,
            "created_utc": data.get("created_utc"),
            "permalink": ("https://www.reddit.com" + permalink) if permalink else None,
            "body": data.get("body") or "",
            "score": data.get("score"),
        }
        if not (isinstance(author, str) and author.lower() in own):
            results.append(record)
        replies = data.get("replies")
        if isinstance(replies, dict):
            results.extend(
                flatten_reddit_comments(
                    replies, own_usernames, depth=record["depth"] + 1, parent_id=comment_id
                )
            )
    return results


def github_discussion_query():
    """One query for the discussion, its comments, and each comment's replies."""
    return (
        "query($owner:String!, $repo:String!, $number:Int!) {"
        "  repository(owner:$owner, name:$repo) {"
        "    discussion(number:$number) {"
        "      title upvoteCount"
        "      comments(first:100) {"
        "        totalCount"
        "        nodes {"
        "          id url createdAt body author { login }"
        "          replies(first:100) {"
        "            nodes { id url createdAt body author { login } }"
        "          }"
        "        }"
        "      }"
        "    }"
        "  }"
        "}"
    )


def flatten_github_comments(payload, own_usernames):
    """The discussion's comments and replies, in the same record shape."""
    own = {name.lower() for name in own_usernames or []}
    discussion = (
        ((payload or {}).get("data") or {}).get("repository") or {}
    ).get("discussion") or {}
    comments = (discussion.get("comments") or {}).get("nodes") or []
    results = []
    for comment in comments:
        for depth, node in [(0, comment)] + [
            (1, reply) for reply in ((comment.get("replies") or {}).get("nodes") or [])
        ]:
            author = ((node.get("author") or {}).get("login")) or None
            if isinstance(author, str) and author.lower() in own:
                continue
            results.append(
                {
                    "id": node.get("id"),
                    "type": "comment",
                    "author": author,
                    "depth": depth,
                    "parent_id": comment.get("id") if depth else None,
                    "created_at": node.get("createdAt"),
                    "permalink": node.get("url"),
                    "body": node.get("body") or "",
                }
            )
    return results, discussion


def new_comments(comments, seen_ids):
    """Comments whose id is not in state. `more` stubs never count as new."""
    seen = set(seen_ids or [])
    return [
        comment
        for comment in comments
        if comment.get("type") == "comment" and comment.get("id") not in seen
    ]


def merge_seen(seen_ids, comment_ids, limit=2000):
    """Ids to store: the old set plus the ones this run is finished with."""
    merged = list(seen_ids or [])
    known = set(merged)
    for cid in comment_ids:
        if cid and cid not in known:
            merged.append(cid)
            known.add(cid)
    return merged[-limit:]


def settled_comment_ids(comments, analysing, attempts, max_attempts=MAX_DRAFT_ATTEMPTS):
    """Which of this run's comments are finished with, and may be marked seen.

    A comment is only settled once there is something to show for it: a draft
    on disk, or enough failed attempts to stop trying. Anything else stays
    unseen so the next run offers it to the drafting lane again. When no
    drafting was asked for, nothing is pending, so everything settles — the
    unanswered set, not the seen set, is what keeps it in the brief.
    """
    settled = []
    for comment in comments:
        cid = comment.get("id")
        if not cid:
            continue
        if not analysing:
            settled.append(cid)
        elif comment.get("draft"):
            settled.append(cid)
        elif int((attempts or {}).get(cid, 0)) >= max_attempts:
            settled.append(cid)
    return settled


def delta(new_value, old_value):
    """Signed change as a string, or None when either side is unknown."""
    if not isinstance(new_value, int) or not isinstance(old_value, int):
        return None
    difference = new_value - old_value
    if difference == 0:
        return None
    return "%+d" % difference


def cap_runs(runs, limit=RUN_HISTORY_LIMIT):
    return list(runs or [])[-limit:]


def truncate(text, limit):
    text = " ".join(str(text or "").split())
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 1)].rstrip() + "…"


def utc_iso():
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_timestamp():
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H-%M-%SZ")


def local_date_string():
    return datetime.date.today().strftime("%Y-%m-%d")


def comment_age(comment):
    """How long ago a comment was written, in plain English."""
    created = comment.get("created_utc")
    if isinstance(created, (int, float)):
        when = datetime.datetime.utcfromtimestamp(created)
    else:
        text = comment.get("created_at")
        if not isinstance(text, str):
            return "unknown age"
        try:
            when = datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            return "unknown age"
    seconds = (datetime.datetime.utcnow() - when).total_seconds()
    if seconds < 0:
        return "just now"
    if seconds < 3600:
        return "%d minutes ago" % int(seconds // 60)
    if seconds < 86400:
        return "%d hours ago" % int(seconds // 3600)
    return "%d days ago" % int(seconds // 86400)


# --- rendering --------------------------------------------------------------


def render_table(results):
    rows = ["| Post | Comments | New | Score | State |", "| --- | --- | --- | --- | --- |"]
    for result in results:
        counts = result.get("counts") or {}
        score = counts.get("score")
        score_text = "n/a" if score is None else str(score)
        score_delta = delta(score, (result.get("previous") or {}).get("score"))
        if score_delta:
            score_text += " (%s)" % score_delta
        rows.append(
            "| %s | %s | %d | %s | %s |"
            % (
                result["label"].replace("|", "\\|"),
                counts.get("comments", "n/a"),
                len(result.get("new") or []),
                score_text,
                result.get("state", "ok"),
            )
        )
    return "\n".join(rows)


def render_report(results, timestamp, duration_seconds, first_run, notes):
    total_new = sum(len(result.get("new") or []) for result in results)
    lines = [
        "# redditwatch %s" % timestamp,
        "",
        "- Run: %s UTC" % timestamp,
        "- Posts watched: %d" % len(results),
        "- New comments: %d" % total_new,
        "- Duration: %.1fs" % duration_seconds,
        "",
    ]
    if first_run:
        lines.append(
            "First run: state was empty, so every comment below counts as new. "
            "From the next run on, new means new since the last run."
        )
        lines.append("")
    lines.append(render_table(results))
    lines.append("")
    for note in notes:
        lines.append("- %s" % note)
    if notes:
        lines.append("")
    for result in results:
        lines.append("## %s" % result["label"])
        lines.append("")
        lines.append(result["url"])
        lines.append("")
        if result.get("state") != "ok":
            lines.append("Not read this run: %s" % result.get("detail", result.get("state")))
            lines.append("")
            continue
        counts = result.get("counts") or {}
        previous = result.get("previous") or {}
        count = counts.get("comments")
        summary = "%s comment%s%s, %s new" % (
            "?" if count is None else count,
            "" if count == 1 else "s",
            " in the feed" if result.get("source") == "rss" else "",
            len(result.get("new") or []),
        )
        comment_delta = delta(counts.get("comments"), previous.get("comments"))
        if comment_delta:
            summary += " (%s since the last run)" % comment_delta
        if counts.get("score") is not None:
            summary += ", score %s" % counts["score"]
            score_delta = delta(counts.get("score"), previous.get("score"))
            if score_delta:
                summary += " (%s)" % score_delta
        lines.append(summary + ".")
        lines.append("")
        if result.get("more_pending"):
            lines.append(
                "%d replies were not fetched (Reddit truncated the tree); "
                "open the post if a thread looks cut off." % result["more_pending"]
            )
            lines.append("")
        if not result.get("new"):
            lines.append("Nothing new to answer.")
            lines.append("")
            continue
        for comment in result["new"]:
            lines.append(
                "### u/%s, %s" % (comment.get("author") or "unknown", comment_age(comment))
            )
            lines.append("")
            if comment.get("permalink"):
                lines.append(comment["permalink"])
                lines.append("")
            for body_line in (comment.get("body") or "").splitlines() or [""]:
                lines.append("> %s" % body_line)
            lines.append("")
            if comment.get("draft"):
                lines.append("Draft reply: `%s`" % comment["draft"])
                lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def render_vault_section(results, timestamp, first_run):
    total_new = sum(len(result.get("new") or []) for result in results)
    lines = ["_Last run: %s UTC._" % timestamp, "", render_table(results), ""]
    if first_run:
        lines.append("First run: state was seeded, so everything counted as new.")
        lines.append("")
    if total_new:
        lines.append("### Waiting on a reply")
        lines.append("")
        for result in results:
            for comment in result.get("new") or []:
                lines.append(
                    "- **%s**, u/%s (%s): %s%s"
                    % (
                        result["label"],
                        comment.get("author") or "unknown",
                        comment_age(comment),
                        truncate(comment.get("body"), 160),
                        (" — [comment](%s)" % comment["permalink"]) if comment.get("permalink") else "",
                    )
                )
        lines.append("")
        lines.append(
            "Drafts, where the analyse lane wrote one, are in "
            "`~/.kelpie/redditwatch/drafts/`. Anthony posts every reply by hand."
        )
        lines.append("")
    else:
        lines.append("Nothing new since the last run.")
        lines.append("")
    return "\n".join(lines).rstrip()


def splice_vault_section(existing_text, section):
    """Replace the text between the markers, leaving the prose above alone."""
    block = "%s\n%s\n%s" % (VAULT_BEGIN, section, VAULT_END)
    start = existing_text.find(VAULT_BEGIN)
    end = existing_text.find(VAULT_END)
    if start == -1 or end == -1 or end < start:
        prose = existing_text.rstrip()
        return (prose + "\n\n" + block + "\n") if prose else block + "\n"
    return existing_text[:start] + block + existing_text[end + len(VAULT_END) :]


def unanswered_total(state):
    """How many comments are still waiting on a reply, across every post."""
    return sum(
        len(record.get("unanswered") or {})
        for record in (state.get("posts") or {}).values()
    )


def clear_answered(state, comment_id):
    """Drop one comment from the unanswered set and stop reporting it as new.

    Returns the post label it was found under, or None. Marking it seen as well
    means answering a comment the drafting lane never managed to draft for does
    not leave it coming back every hour.
    """
    found = None
    for record in (state.get("posts") or {}).values():
        unanswered = record.get("unanswered") or {}
        if comment_id in unanswered:
            unanswered.pop(comment_id, None)
            (record.get("draft_attempts") or {}).pop(comment_id, None)
            record["seen"] = merge_seen(record.get("seen"), [comment_id])
            found = record.get("label") or record.get("url")
    return found


def build_briefing(state, date_string, drafts_dir):
    """The morning-brief handoff: every comment still waiting on a reply.

    Built from the **unanswered set in state**, never from one run's new list.
    A comment that arrived at 23:00 has to survive the 00:00, 01:00 and 02:00
    runs to reach the 06:05 brief, so nothing leaves this file until Anthony
    says so with `--answered <comment id>`.
    """
    items = []
    for record in (state.get("posts") or {}).values():
        label = record.get("label") or record.get("url") or "a watched post"
        for comment_id, comment in sorted(
            (record.get("unanswered") or {}).items(),
            key=lambda pair: pair[1].get("first_seen") or "",
        ):
            draft = comment.get("draft") or find_draft(drafts_dir, comment_id)
            act = []
            if draft:
                act.append("Read the draft reply at %s, edit it, post it by hand." % draft)
            else:
                act.append(
                    "No draft yet; answer it by hand or run `make redditwatch ANALYSE=1`."
                )
            if comment.get("permalink"):
                act.append("Comment: %s" % comment["permalink"])
            act.append(
                "When it is answered: `scripts/redditwatch.py --answered %s`." % comment_id
            )
            items.append(
                {
                    "title": truncate(
                        "%s: u/%s replied" % (label, comment.get("author") or "unknown"),
                        80,
                    ),
                    "headlines": [
                        truncate(comment.get("body"), 220),
                        "first seen %s" % (comment.get("first_seen") or "unknown"),
                    ],
                    "act": [truncate(line, 300) for line in act],
                }
            )
    return {"date": date_string, "items": items}


def log_lines(results, now_iso, duration_seconds, analyse_mode, first_run, waiting):
    total_new = sum(len(result.get("new") or []) for result in results)
    unreachable = sum(1 for result in results if result.get("state") != "ok")
    lines = [
        "%s  run: %d posts, %d new comment%s, %d still waiting on a reply, "
        "%d unreachable, analyse=%s%s, %.1fs"
        % (
            now_iso,
            len(results),
            total_new,
            "" if total_new == 1 else "s",
            waiting,
            unreachable,
            analyse_mode,
            ", first run (state seeded, everything counted as new)" if first_run else "",
            duration_seconds,
        )
    ]
    for result in results:
        counts = result.get("counts") or {}
        if result.get("state") != "ok":
            lines.append(
                "%s  %s: not read this run (%s)"
                % (now_iso, result["label"], result.get("detail", result.get("state")))
            )
            continue
        count = counts.get("comments")
        lines.append(
            "%s  %s: %s comment%s, %d new to answer, score %s"
            % (
                now_iso,
                result["label"],
                "?" if count is None else count,
                "" if count == 1 else "s",
                len(result.get("new") or []),
                "n/a" if counts.get("score") is None else counts["score"],
            )
        )
    return lines


# ---------------------------------------------------------------------------
# Impure: network, gh, and writes.
# ---------------------------------------------------------------------------


def load_config(state_dir, dry_run, notes):
    """Read the config, seeding it from SEED_CONFIG when it is not there yet."""
    path = state_dir / "config.json"
    if not path.exists():
        if dry_run:
            notes.append(
                "no config at %s; using the seeded watch list for this dry run "
                "and writing nothing" % path
            )
            return normalise_config(dict(SEED_CONFIG), path), path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(SEED_CONFIG, indent=2) + "\n", encoding="utf-8")
        notes.append("seeded a new config at %s from the embed plan" % path)
        return normalise_config(dict(SEED_CONFIG), path), path
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as error:
        raise ConfigError("%s is not valid JSON: %s" % (path, error))
    except OSError as error:
        raise ConfigError("%s could not be read: %s" % (path, error))
    return normalise_config(raw, path), path


def add_post(state_dir, url, dry_run):
    """Append one post to the config. Idempotent: a known post is left alone."""
    path = state_dir / "config.json"
    kind = classify_url(url)
    if kind is None:
        raise ConfigError(
            "%s is neither a Reddit post URL nor a GitHub discussion URL" % url
        )
    if path.exists():
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except ValueError as error:
            raise ConfigError("%s is not valid JSON: %s" % (path, error))
    else:
        raw = dict(SEED_CONFIG)
        raw["posts"] = []
    posts = raw.get("posts")
    if not isinstance(posts, list):
        raise ConfigError("%s: `posts` is not a list" % path)
    key = post_key({"kind": kind, "url": url})
    for entry in posts:
        existing = entry if isinstance(entry, dict) else {"url": entry}
        if post_key(existing) == key:
            print("redditwatch: %s is already watched" % url)
            return EXIT_OK
    entry = {"kind": kind, "url": url.strip()}
    if kind == "reddit":
        subreddit, _ = reddit_parts(url)
        entry["label"] = "r/%s" % subreddit
    else:
        owner, repo, number = github_parts(url)
        entry["label"] = "%s/%s discussion #%d" % (owner, repo, number)
    posts.append(entry)
    raw["posts"] = posts
    if dry_run:
        print("redditwatch: would add %s (%s) to %s" % (url, kind, path))
        return EXIT_OK
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(raw, indent=2) + "\n", encoding="utf-8")
    print("redditwatch: added %s (%s) to %s" % (url, kind, path))
    return EXIT_OK


def fetch_url(url, agent, verbose):
    """One GET with one retry. Returns (text, None) or (None, plain reason).

    A transient answer (429, 403, 5xx, a timeout) is retried once; anything
    else is reported straight away. Nothing here raises: a post that cannot be
    read must not stop the posts that can.
    """
    request = urllib.request.Request(url, headers={"User-Agent": agent})
    detail = "no attempt made"
    for attempt in (1, 2):
        if verbose:
            print("redditwatch: GET %s (attempt %d)" % (url, attempt), file=sys.stderr)
        try:
            with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
                return (response.read().decode("utf-8", errors="replace"), None)
        except urllib.error.HTTPError as error:
            detail = "HTTP %s from Reddit" % error.code
            if error.code not in TRANSIENT_STATUS:
                return (None, detail)
        except urllib.error.URLError as error:
            detail = "Reddit did not answer (%s)" % (error.reason,)
        except (ValueError, OSError) as error:
            detail = "Reddit's answer could not be read (%s)" % error
        if attempt == 1:
            time.sleep(RETRY_PAUSE_SECONDS)
    return (None, detail)


def fetch_reddit(entry, username, own_usernames, verbose):
    """One post's comments: the Atom feed first, the JSON view as a fallback.

    Returns a result dict; a failure is a state of `unreachable` with a plain
    reason, never an exception.
    """
    feed_text, feed_detail = fetch_url(
        reddit_rss_url(entry["url"]), BROWSER_USER_AGENT, verbose
    )
    if feed_text is not None:
        try:
            parsed = parse_reddit_feed(feed_text, own_usernames)
        except ElementTree.ParseError as error:
            feed_detail = "the Atom feed could not be parsed (%s)" % error
        else:
            return {
                "state": "ok",
                "source": "rss",
                "comments": parsed["comments"],
                # The feed carries no `more` stubs; it simply ends.
                "more_pending": 0,
                "counts": {
                    # Neither score nor the post's own comment count is in the
                    # feed. The count below is what the feed carried, which is
                    # the number this run actually read.
                    "score": None,
                    "comments": len(parsed["comments"]),
                    "title": parsed["title"],
                },
            }

    json_text, json_detail = fetch_url(
        reddit_json_url(entry["url"]), user_agent(username), verbose
    )
    if json_text is None:
        return {
            "state": "unreachable",
            "detail": "feed: %s; json: %s" % (feed_detail, json_detail),
        }
    try:
        payload = json.loads(json_text)
    except ValueError as error:
        return {
            "state": "unreachable",
            "detail": "feed: %s; json: unparsable (%s)" % (feed_detail, error),
        }
    if not isinstance(payload, list) or len(payload) < 2:
        return {
            "state": "unreachable",
            "detail": "feed: %s; json: unexpected shape" % feed_detail,
        }
    post_children = ((payload[0] or {}).get("data") or {}).get("children") or []
    post_data = (post_children[0] or {}).get("data") if post_children else {}
    comments = flatten_reddit_comments(payload[1], own_usernames)
    pending = sum(item.get("count", 0) for item in comments if item.get("type") == "more")
    return {
        "state": "ok",
        "source": "json",
        "comments": [c for c in comments if c.get("type") == "comment"],
        "more_pending": pending,
        "counts": {
            "score": (post_data or {}).get("score"),
            "comments": (post_data or {}).get("num_comments"),
            "title": (post_data or {}).get("title"),
        },
    }


def fetch_github_discussion(entry, own_usernames, verbose):
    """The discussion's comments through `gh api graphql`.

    A missing or failing `gh` is an info line: the Reddit posts still get read.
    """
    owner, repo, number = github_parts(entry["url"])
    if number is None:
        return {"state": "unreachable", "detail": "not a GitHub discussion URL"}
    argv = [
        "gh",
        "api",
        "graphql",
        "-f",
        "query=%s" % github_discussion_query(),
        "-F",
        "owner=%s" % owner,
        "-F",
        "repo=%s" % repo,
        "-F",
        "number=%d" % number,
    ]
    if verbose:
        print("redditwatch: %s" % " ".join(argv[:3]), file=sys.stderr)
    try:
        completed = subprocess.run(
            argv,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=GH_TIMEOUT,
        )
    except FileNotFoundError:
        return {"state": "unreachable", "detail": "gh is not on PATH"}
    except subprocess.TimeoutExpired:
        return {"state": "unreachable", "detail": "gh did not answer within %gs" % GH_TIMEOUT}
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip().splitlines()
        return {
            "state": "unreachable",
            "detail": "gh exited %d (%s)"
            % (completed.returncode, detail[-1][:160] if detail else "no output"),
        }
    try:
        payload = json.loads(completed.stdout or "{}")
    except ValueError as error:
        return {"state": "unreachable", "detail": "gh returned unparsable JSON (%s)" % error}
    comments, discussion = flatten_github_comments(payload, own_usernames)
    return {
        "state": "ok",
        "source": "gh",
        "comments": comments,
        "more_pending": 0,
        "counts": {
            "score": discussion.get("upvoteCount"),
            "comments": (discussion.get("comments") or {}).get("totalCount"),
            "title": discussion.get("title"),
        },
    }


def load_state(state_dir):
    path = state_dir / "state.json"
    if not path.exists():
        return {"version": 1, "posts": {}, "runs": [], "last_run": None}, True
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return {"version": 1, "posts": {}, "runs": [], "last_run": None}, True
    state.setdefault("posts", {})
    state.setdefault("runs", [])
    state.setdefault("last_run", None)
    return state, not state["posts"]


def write_state(state_dir, state):
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "state.json").write_text(
        json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def append_log(state_dir, lines):
    state_dir.mkdir(parents=True, exist_ok=True)
    with (state_dir / "redditwatch.log").open("a", encoding="utf-8") as handle:
        for line in lines:
            handle.write(line + "\n")


def write_reports(state_dir, timestamp, report_text, payload):
    reports = state_dir / "reports"
    reports.mkdir(parents=True, exist_ok=True)
    (reports / ("%s.md" % timestamp)).write_text(report_text, encoding="utf-8")
    (reports / "latest.md").write_text(report_text, encoding="utf-8")
    (reports / "latest.json").write_text(
        json.dumps(payload, indent=2) + "\n", encoding="utf-8"
    )


def default_vault_note():
    return (
        "---\n"
        "note: The hourly watch on Kelpie's community posts, what it found, and who is "
        "still waiting on a reply.\n"
        "---\n\n"
        "# Reddit watch\n\n"
        "The [[Kelpie]] beta was announced in a handful of places at once, and none of them "
        "tell anyone when somebody replies. `scripts/redditwatch.py` reads each of those posts "
        "once an hour, works out which comments are new, and writes the table below.\n\n"
        "It never posts, votes or logs in. Where it finds a new comment it asks a headless "
        "Claude run for a draft reply and leaves it in `~/.kelpie/redditwatch/drafts/`, for "
        "Anthony to edit and post by hand. The guide is `docs/guides/reddit-watch.md`.\n\n"
        "## Last run\n\n"
    )


def write_vault_note(repo, section):
    path = repo / VAULT_NOTE
    existing = path.read_text(encoding="utf-8") if path.exists() else default_vault_note()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(splice_vault_section(existing, section), encoding="utf-8")


def write_briefing(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def find_draft(drafts_dir, comment_id):
    """The draft for one comment, whatever day it was written.

    A comment that arrived at 23:00 is drafted under yesterday's date and is
    still waiting at breakfast, so the lookup is by id, not by today.
    """
    if not comment_id:
        return None
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", str(comment_id))
    directory = Path(drafts_dir)
    if not directory.exists():
        return None
    matches = sorted(directory.glob("*-%s.md" % safe))
    return str(matches[-1]) if matches else None


def attach_existing_drafts(results, drafts_dir):
    """Point each new comment at its draft, when one has been written."""
    for result in results:
        for comment in result.get("new") or []:
            comment["draft"] = find_draft(drafts_dir, comment.get("id"))


def run_analyse(repo, state_dir, notes):
    """Hand the run to the drafting lane. It writes drafts; it never posts."""
    script = repo / ANALYSE_SCRIPT
    if not script.exists():
        notes.append("no %s in the checkout, so no drafts were written" % ANALYSE_SCRIPT)
        return
    env = dict(os.environ)
    env["REDDITWATCH_STATE_DIR"] = str(state_dir)
    env["KELPIE_REPO"] = str(repo)
    try:
        completed = subprocess.run(
            ["/bin/bash", str(script)],
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            # The lane budgets itself to 20 minutes; this is the outer deadline,
            # so a wedged Claude call can never run into the next hourly run.
            timeout=ANALYSE_TOTAL_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        notes.append(
            "the drafting lane exceeded %gs and was stopped; the comments it did not "
            "reach are still unanswered and will be offered again next run"
            % ANALYSE_TOTAL_TIMEOUT
        )
        return
    except OSError as error:
        notes.append("the drafting lane could not be started (%s)" % error)
        return
    if completed.returncode != 0:
        notes.append(
            "the drafting lane exited %d; see %s/redditwatch.log"
            % (completed.returncode, state_dir)
        )
    else:
        notes.append("the drafting lane ran; drafts are in %s/drafts/" % state_dir)


# --- main -------------------------------------------------------------------


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description="Kelpie community watch")
    parser.add_argument("--dry-run", action="store_true", help="fetch, print, write nothing")
    parser.add_argument(
        "--analyse",
        action="store_true",
        help="draft replies for the new comments (scripts/redditwatch-analyse.sh)",
    )
    parser.add_argument("--add", metavar="URL", help="add a post to the watch list and exit")
    parser.add_argument(
        "--answered",
        metavar="ID",
        help="mark one comment answered: drop it from the brief and exit",
    )
    parser.add_argument("--json", action="store_true", help="also print the run JSON")
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR)
    parser.add_argument("--briefing-path", type=Path, default=DEFAULT_BRIEFING_PATH)
    parser.add_argument("--repo", type=Path, default=REPO_ROOT)
    parser.add_argument("--verbose", action="store_true", help="echo each fetch to stderr")
    return parser.parse_args(argv)


def main(argv=None):
    arguments = parse_arguments(argv)
    started = time.time()
    timestamp = utc_timestamp()
    now_iso = utc_iso()
    repo = arguments.repo.resolve()
    state_dir = arguments.state_dir.expanduser()
    notes = []

    if arguments.add:
        try:
            return add_post(state_dir, arguments.add, arguments.dry_run)
        except ConfigError as error:
            print("redditwatch: %s" % error, file=sys.stderr)
            return EXIT_CONFIG

    if arguments.answered:
        state, _ = load_state(state_dir)
        label = clear_answered(state, arguments.answered.strip())
        if label is None:
            print(
                "redditwatch: %s is not waiting on a reply (already answered, or not a "
                "comment id from the brief)" % arguments.answered
            )
            return EXIT_OK
        if arguments.dry_run:
            print("redditwatch: would mark %s answered (%s)" % (arguments.answered, label))
            return EXIT_OK
        write_state(state_dir, state)
        write_briefing(
            arguments.briefing_path.expanduser(),
            build_briefing(state, local_date_string(), state_dir / "drafts"),
        )
        append_log(
            state_dir,
            ["%s  answered: %s on %s; %d still waiting"
             % (utc_iso(), arguments.answered, label, unanswered_total(state))],
        )
        print(
            "redditwatch: %s marked answered (%s); %d still waiting"
            % (arguments.answered, label, unanswered_total(state))
        )
        return EXIT_OK

    try:
        config, config_path = load_config(state_dir, arguments.dry_run, notes)
    except ConfigError as error:
        print("redditwatch: %s" % error, file=sys.stderr)
        return EXIT_CONFIG

    state, first_run = load_state(state_dir)
    if not config["posts"]:
        print(
            "redditwatch: %s has an empty `posts` list; add one with --add <url>"
            % config_path,
            file=sys.stderr,
        )
        return EXIT_CONFIG

    results = []
    fetched_a_reddit_post = False
    for entry in config["posts"]:
        previous = (state.get("posts") or {}).get(entry["key"]) or {}
        if entry["kind"] == "reddit":
            if fetched_a_reddit_post:
                time.sleep(REDDIT_PAUSE_SECONDS)
            fetched_a_reddit_post = True
            fetched = fetch_reddit(
                entry, config["reddit_username"], config["own_usernames"], arguments.verbose
            )
        else:
            fetched = fetch_github_discussion(entry, config["own_usernames"], arguments.verbose)

        result = {
            "key": entry["key"],
            "kind": entry["kind"],
            "url": entry["url"],
            "label": post_label(entry),
            "state": fetched.get("state"),
            "source": fetched.get("source"),
            "detail": fetched.get("detail"),
            "counts": fetched.get("counts") or {},
            "previous": {
                "score": previous.get("score"),
                "comments": previous.get("comments"),
            },
            "more_pending": fetched.get("more_pending", 0),
            "comments": fetched.get("comments") or [],
        }
        if result["state"] == "ok":
            if not (result["counts"].get("title")) and previous.get("title"):
                result["counts"]["title"] = previous["title"]
            result["new"] = new_comments(result["comments"], previous.get("seen"))
        else:
            result["new"] = []
            notes.append("%s: %s" % (result["label"], result["detail"]))
        results.append(result)

    date_string = local_date_string()
    drafts_dir = state_dir / "drafts"
    attach_existing_drafts(results, drafts_dir)

    duration = time.time() - started
    report_text = render_report(results, timestamp, duration, first_run, notes)
    total_new = sum(len(result.get("new") or []) for result in results)

    print(report_text)
    if arguments.json:
        print(json.dumps(results, indent=2))

    if arguments.dry_run:
        print("Dry run: nothing was written (no state, no reports, no vault note, no brief).")
        return EXIT_OK

    payload = {
        "timestamp": timestamp,
        "generated": now_iso,
        "first_run": first_run,
        "new_total": total_new,
        "posts": [
            {
                "key": result["key"],
                "kind": result["kind"],
                "label": result["label"],
                "url": result["url"],
                "state": result["state"],
                "source": result.get("source"),
                "detail": result.get("detail"),
                "counts": result["counts"],
                "previous": result["previous"],
                "more_pending": result.get("more_pending", 0),
                "new": result.get("new") or [],
            }
            for result in results
        ],
        "notes": notes,
    }

    for result in results:
        if result["state"] != "ok":
            continue
        record = (state.setdefault("posts", {})).setdefault(result["key"], {})
        record["url"] = result["url"]
        record["label"] = result["label"]
        record["kind"] = result["kind"]
        record["score"] = result["counts"].get("score")
        record["comments"] = result["counts"].get("comments")
        record["title"] = result["counts"].get("title")
        record["last_seen"] = now_iso
        record.setdefault("seen", [])
        record.setdefault("draft_attempts", {})
        # Every new comment joins the unanswered set and stays there, through
        # every later run, until `--answered <id>` clears it. This is what the
        # 06:05 brief reads, so a comment left at 23:00 is still in it at
        # breakfast.
        unanswered = record.setdefault("unanswered", {})
        for comment in result.get("new") or []:
            cid = comment.get("id")
            if not cid or cid in unanswered:
                continue
            unanswered[cid] = {
                "author": comment.get("author"),
                "body": comment.get("body"),
                "permalink": comment.get("permalink"),
                "created_at": comment.get("created_at"),
                "created_utc": comment.get("created_utc"),
                "first_seen": now_iso,
                "draft": comment.get("draft"),
            }
    state["last_run"] = now_iso
    state["runs"] = cap_runs(
        list(state.get("runs") or [])
        + [
            {
                "ts": now_iso,
                "duration_s": round(duration, 1),
                "posts": len(results),
                "new": total_new,
                "unreachable": sum(1 for r in results if r["state"] != "ok"),
                "analyse": "yes" if arguments.analyse else "no",
            }
        ]
    )

    # The backlog and the reports go down before the drafting lane starts: the
    # lane reads reports/latest.json, and a comment must survive the lane
    # failing, timing out, or the machine going away mid-run.
    write_state(state_dir, state)
    write_reports(state_dir, timestamp, report_text, payload)

    if arguments.analyse and total_new:
        run_analyse(repo, state_dir, notes)
        attach_existing_drafts(results, drafts_dir)
    elif arguments.analyse:
        notes.append("nothing new, so no drafts were asked for")

    # Now that the drafts are in (or are not), settle what can be settled. A
    # comment with no draft and attempts left stays unseen, so the next run
    # offers it to the lane again.
    for result in results:
        if result["state"] != "ok":
            continue
        record = state["posts"][result["key"]]
        attempts = record.setdefault("draft_attempts", {})
        unanswered = record.setdefault("unanswered", {})
        for comment in result.get("new") or []:
            cid = comment.get("id")
            if not cid:
                continue
            if cid in unanswered:
                unanswered[cid]["draft"] = comment.get("draft")
            if arguments.analyse and not comment.get("draft"):
                attempts[cid] = int(attempts.get(cid, 0)) + 1
        settled = settled_comment_ids(
            result.get("new") or [], arguments.analyse, attempts
        )
        record["seen"] = merge_seen(record.get("seen"), settled)
        for cid in settled:
            attempts.pop(cid, None)

    duration = time.time() - started
    state["runs"][-1]["duration_s"] = round(duration, 1)
    payload["notes"] = notes
    report_text = render_report(results, timestamp, duration, first_run, notes)

    write_state(state_dir, state)
    write_reports(state_dir, timestamp, report_text, payload)
    append_log(
        state_dir,
        log_lines(
            results,
            now_iso,
            duration,
            "yes" if arguments.analyse else "no",
            first_run,
            unanswered_total(state),
        ),
    )
    write_vault_note(repo, render_vault_section(results, timestamp, first_run))
    write_briefing(
        arguments.briefing_path.expanduser(),
        build_briefing(state, date_string, drafts_dir),
    )
    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
