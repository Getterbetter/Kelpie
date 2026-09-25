#!/usr/bin/env python3
"""Kelpie dependency watch: notice what moved, turn it into tracked work.

Usage:
    scripts/depwatch.py                       # run every check, write state/reports
    scripts/depwatch.py --dry-run             # report to stdout, write nothing
    scripts/depwatch.py --publish             # open/update GitHub issues
    scripts/depwatch.py --prepare             # prepare mechanical fix branches
    scripts/depwatch.py --check herdr-release # only the named checks

Kelpie breaks when herdr's API moves, when Heeler upstream moves under the
fork, when a pinned native artifact moves, or when a piece of live
infrastructure stops answering. Each of those is a `check_<id>` function that
returns one Finding. Checks are independent: one raising is reported as a
finding of severity `error`, never a crash.

Everything the watcher owns lives outside the repo, under `--state-dir`
(default `~/.kelpie/depwatch`). The only repo writes are the vault note's
generated section, and — with `--prepare` — commits inside a temporary git
worktree. The checkout itself is never switched, stashed or committed to.

Stdlib only, and it must run on /usr/bin/python3 (3.9). See
docs/guides/dependency-watch.md.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

DEFAULT_STATE_DIR = Path.home() / ".kelpie" / "depwatch"
DEFAULT_BRIEFING_PATH = Path.home() / ".memoryos" / "kelpie-depwatch-briefing.json"
VAULT_NOTE = "KelpieVault/Dependency watch.md"
VAULT_BEGIN = "<!-- depwatch:begin -->"
VAULT_END = "<!-- depwatch:end -->"

# The herdr tag scripts/herdr-schema.json was exported from. The file carries
# `protocol` but no version, so the tag is seeded here and then tracked in
# state once a snapshot is refreshed. docs/research/herdr-0.9.0-compatibility.md
# documents the v0.9.0 export.
SNAPSHOT_TAG_SEED = "v0.9.1"

KELPIE_IPAD_UDID = "09D7738D-2173-55EF-8966-A9C3EA1D0514"  # Anthony's 11-inch iPad Pro
HERDR_REPO = "herdrdev/herdr"
FORK_REPO = "Getterbetter/Kelpie"
GHOSTTY_REPO = "Lakr233/libghostty-spm"
HERDR_SCHEMA_PATH_IN_REPO = "docs/next/api/herdr-api.schema.json"

DEFAULT_TIMEOUT = 60.0
NETWORK_TIMEOUT = 30.0
HTTP_TIMEOUT = 10.0
DEVICE_TIMEOUT = 15.0
COMPILE_TIMEOUT = 1200.0

RUN_HISTORY_LIMIT = 30
LOCK_STALE_MINUTES = 180  # documented in depwatch.sh, which owns the lock

SEVERITY_ORDER = ["info", "low", "medium", "high", "error"]

# `depwatch: <check>: <headline>` titles are searched by this prefix.
ISSUE_TITLE_PREFIX = "depwatch"


class ToolError(Exception):
    """A helper command failed in a way the check should report, not raise."""


class ToolTimeout(ToolError):
    pass


# ---------------------------------------------------------------------------
# Pure helpers. Everything below this line up to `# --- impure ---` is what
# scripts/depwatch_test.py exercises: no network, no git, no gh.
# ---------------------------------------------------------------------------


SEMVER_TAG = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")


def parse_semver(tag):
    """`v0.9.0` -> (0, 9, 0). Anything else (preview builds, dated tags) -> None."""
    if not isinstance(tag, str):
        return None
    match = SEMVER_TAG.match(tag.strip())
    if match is None:
        return None
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)))


def semver_is_newer(candidate, baseline):
    """True when `candidate` parses as a semver strictly above `baseline`."""
    left = parse_semver(candidate)
    right = parse_semver(baseline)
    if left is None or right is None:
        return False
    return left > right


def latest_stable_release(releases):
    """First entry that is neither a prerelease nor a draft."""
    for release in releases or []:
        if not release.get("prerelease") and not release.get("draft"):
            return release
    return None


def latest_prerelease(releases):
    for release in releases or []:
        if release.get("prerelease") and not release.get("draft"):
            return release
    return None


def schema_methods(schema):
    """Method name -> its JSON subtree.

    Mirrors generate-wire-types.py's `generate()`, which reads method names
    from `schemas.request.oneOf[].properties.method.const`. Nothing is
    imported from it; the two only have to agree on where methods live.
    """
    methods = {}
    request = (schema.get("schemas") or {}).get("request") or {}
    for variant in request.get("oneOf") or []:
        properties = variant.get("properties") or {}
        const = (properties.get("method") or {}).get("const")
        if isinstance(const, str):
            methods[const] = variant
    return methods


def schema_event_kinds(schema):
    """Event kind -> its EventData variant subtree (or {} when untyped).

    `schemas.event.$defs.EventKind.enum` is the kind list; the typed payload
    for a kind is the `EventData.oneOf` variant whose `type.const` matches.
    """
    event = (schema.get("schemas") or {}).get("event") or {}
    defs = event.get("$defs") or {}
    kinds = (defs.get("EventKind") or {}).get("enum") or []
    variants = {}
    for variant in (defs.get("EventData") or {}).get("oneOf") or []:
        properties = variant.get("properties") or {}
        const = (properties.get("type") or {}).get("const")
        if isinstance(const, str):
            variants[const] = variant
    return {kind: variants.get(kind, {}) for kind in kinds if isinstance(kind, str)}


def schema_subscription_event_kinds(schema):
    """Same shape for the pane-scoped subscription events."""
    sub = (schema.get("schemas") or {}).get("subscription_event") or {}
    defs = sub.get("$defs") or {}
    kinds = (defs.get("SubscriptionEventKind") or {}).get("enum") or []
    variants = {}
    for variant in (defs.get("SubscriptionEventData") or {}).get("oneOf") or []:
        properties = variant.get("properties") or {}
        const = (properties.get("type") or {}).get("const")
        if isinstance(const, str):
            variants[const] = variant
    return {kind: variants.get(kind, {}) for kind in kinds if isinstance(kind, str)}


def _canonical(node):
    return json.dumps(node, sort_keys=True)


def diff_maps(old, new):
    """Added / removed / changed keys between two name -> subtree maps."""
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    changed = sorted(
        name
        for name in set(old) & set(new)
        if _canonical(old[name]) != _canonical(new[name])
    )
    return {"added": added, "removed": removed, "changed": changed}


def schema_drift(old_schema, new_schema):
    """Everything that moved between two herdr API schema exports."""
    return {
        "protocol_old": old_schema.get("protocol"),
        "protocol_new": new_schema.get("protocol"),
        "protocol_changed": old_schema.get("protocol") != new_schema.get("protocol"),
        "methods": diff_maps(schema_methods(old_schema), schema_methods(new_schema)),
        "events": diff_maps(
            schema_event_kinds(old_schema), schema_event_kinds(new_schema)
        ),
        "subscription_events": diff_maps(
            schema_subscription_event_kinds(old_schema),
            schema_subscription_event_kinds(new_schema),
        ),
        "identical": _canonical(old_schema) == _canonical(new_schema),
    }


METHOD_LITERAL = re.compile(r'method: *"([a-z_.]+)"')


def used_methods(sources_text):
    """The `method: "<x>"` string literals under Sources/ (18 today)."""
    return sorted(set(METHOD_LITERAL.findall(sources_text)))


def used_event_kinds(sources_text, kinds):
    """Which schema event kinds Kelpie names.

    The kind enums are hand-written in Sources/Heeler/Transport/HerdrEvents.swift
    with dotted spellings (`pane.agent_status_changed`); the schema spells the
    global ones snake_case (`pane_agent_status_changed`) and
    `HerdrEventKind.init(wireName:)` maps between them. Accept either spelling
    as "used".
    """
    used = []
    for kind in kinds:
        dotted = kind.replace("_", ".", 1) if "." not in kind else kind
        if '"%s"' % kind in sources_text or '"%s"' % dotted in sources_text:
            used.append(kind)
    return sorted(set(used))


def cross_reference_drift(drift, used_method_names, used_kind_names):
    """The subset of the drift that touches something Kelpie actually uses."""
    used_methods_set = set(used_method_names)
    used_kinds_set = set(used_kind_names)
    breaking_methods = sorted(
        name
        for name in drift["methods"]["removed"] + drift["methods"]["changed"]
        if name in used_methods_set
    )
    breaking_kinds = sorted(
        name
        for name in (
            drift["events"]["removed"]
            + drift["events"]["changed"]
            + drift["subscription_events"]["removed"]
            + drift["subscription_events"]["changed"]
        )
        if name in used_kinds_set
    )
    return {"methods": breaking_methods, "kinds": breaking_kinds}


def herdr_release_severity(has_newer_tag, drift, breaking):
    """high: protocol bump or a used method/kind moved. medium: anything else
    changed or was added. low: newer tag, byte-identical schema. info: no
    newer stable tag."""
    if not has_newer_tag:
        return "info"
    if drift is None:
        # A newer tag whose schema could not be fetched is still worth a look.
        return "medium"
    if drift.get("protocol_changed") or breaking["methods"] or breaking["kinds"]:
        return "high"
    if drift.get("identical"):
        return "low"
    # Any byte difference is work to look at, even when no method or event
    # kind moved: $ref-internal changes are invisible to the method diff.
    return "medium"


def upstream_severity(commit_count, kelpie_count):
    """info at 0 unreviewed commits; low when none touch paths Kelpie runs;
    medium from one such commit; high from ten."""
    if commit_count == 0:
        return "info"
    if kelpie_count >= 10:
        return "high"
    if kelpie_count >= 1:
        return "medium"
    return "low"


# Paths of upstream Heeler that Kelpie still runs; everything else upstream
# changes is Console UI (hidden behind Kelpie's herdr client) or docs.
KELPIE_RUN_PATHS = (
    "Packages/HeelerSSH/",
    "Sources/Heeler/Transport/",
    "Sources/Heeler/Terminal/",
    "Sources/Heeler/Pairing/",
    "Sources/Heeler/Hosts/",
    "plugin/",
    "relay/",
    "Makefile",
    "scripts/",
)
REVIEWED_FILE = "scripts/heeler-upstream-reviewed"


def touches_kelpie_paths(paths):
    return any(path == prefix or (prefix.endswith("/") and path.startswith(prefix))
               for path in paths for prefix in KELPIE_RUN_PATHS)


def parse_reviewed_file(text):
    """Return (sha, problem): the full sha on the first non-comment line, or
    None and why not. Comment lines start with `#`."""
    if text is None:
        return None, "`%s` is missing" % REVIEWED_FILE
    lines = [line.strip() for line in text.splitlines()]
    lines = [line for line in lines if line and not line.startswith("#")]
    if not lines:
        return None, "`%s` names no commit" % REVIEWED_FILE
    sha = lines[0].lower()
    if len(sha) != 40 or any(c not in "0123456789abcdef" for c in sha):
        return None, "`%s` does not start with a full commit sha: `%s`" % (REVIEWED_FILE, lines[0][:60])
    return sha, None


def parse_upstream_log(text):
    """Parse `git log --no-merges --name-only --format=%x1e%H%x09%s` into
    [{"sha", "subject", "paths"}], newest first."""
    commits = []
    for record in text.split("\x1e"):
        record = record.strip("\n")
        if not record.strip():
            continue
        header, _, rest = record.partition("\n")
        sha, _, subject = header.partition("\t")
        paths = [line.strip() for line in rest.splitlines() if line.strip()]
        commits.append({"sha": sha.strip(), "subject": subject.strip(), "paths": paths})
    return commits


def upstream_finding(reviewed, head, commits, problem=None):
    """The heeler-upstream finding from the recorded reviewed commit, the
    upstream/main sha and the commits between them (pure: no git)."""
    if problem:
        return make_finding(
            check="heeler-upstream",
            severity="medium",
            fingerprint="reviewed-file:%s:%s" % (problem, head),
            title="cannot read the reviewed upstream commit",
            summary="Kelpie takes upstream Heeler fixes by cherry-pick; the check needs the last "
            "reviewed upstream commit to know what is new.",
            evidence=[problem, "upstream/main `%s`" % head[:12]],
            lane="manual",
            actions=[
                "Write the last reviewed upstream sha (full 40 characters) on the first line of "
                "`%s`; comment lines start with `#`." % REVIEWED_FILE,
            ],
            data={"reviewed": None, "head": head, "problem": problem},
        )
    runs = [c for c in commits if touches_kelpie_paths(c["paths"])]
    rest = [c for c in commits if not touches_kelpie_paths(c["paths"])]
    total, kelpie_count = len(commits), len(runs)

    def line(commit):
        return "`%s` %s" % (commit["sha"][:8], commit["subject"])

    evidence = [
        "`%s..upstream/main` (`--no-merges`): %d commits, head `%s`" % (reviewed[:8], total, head[:12]),
    ]
    if runs:
        evidence.append("in paths Kelpie runs (%d): %s" % (kelpie_count, "; ".join(line(c) for c in runs[:10])))
    if rest:
        evidence.append("Console and docs (%d): %s" % (len(rest), "; ".join(line(c) for c in rest[:5])))
    if total == 0:
        title = "no upstream commits to review"
    else:
        title = "%d upstream commit%s to review (%d in paths Kelpie runs)" % (
            total, "" if total == 1 else "s", kelpie_count)
    actions = [
        "Review them for cherry-picks: `git log --no-merges %s..upstream/main`, then "
        "`git cherry-pick -x <sha>` for each fix Kelpie wants, oldest first." % reviewed[:12],
        "Then move the recorded commit forward: put `%s` on the first line of `%s`." % (head, REVIEWED_FILE),
    ]
    return make_finding(
        check="heeler-upstream",
        severity=upstream_severity(total, kelpie_count),
        fingerprint="%s..%s" % (reviewed, head),
        title=title,
        summary="Kelpie is a hard fork of Heeler since 2026-09-23 and takes upstream fixes by "
        "cherry-pick, never by rebase; these are the upstream commits nobody has reviewed yet.",
        evidence=evidence,
        lane="manual" if total else "none",
        actions=actions if total else [],
        data={
            "reviewed": reviewed,
            "head": head,
            "commits": total,
            "kelpie_paths": [c["sha"] for c in runs],
        },
    )


def ssh_pins_severity(new_advisories, newer_patch_in_line):
    if new_advisories:
        return "high"
    if newer_patch_in_line:
        return "low"
    return "info"


def node_severity(counts):
    """npm audit `metadata.vulnerabilities` counts -> severity."""
    if counts.get("critical", 0) or counts.get("high", 0):
        return "high"
    if counts.get("moderate", 0):
        return "medium"
    return "info"


def toolchain_severity(changed, runner_major, local_major):
    if runner_major is not None and local_major is not None and runner_major != local_major:
        return "medium"
    return "low" if changed else "info"


def ci_fork_severity(has_successful_ci_run, latest_conclusion):
    if not has_successful_ci_run:
        return "high"
    if latest_conclusion not in (None, "success"):
        return "medium"
    return "info"


def relay_severity(status_code, error):
    """The Worker answers 404 for anything but /push (relay/src/worker.js),
    so a 404 is a healthy relay."""
    if error is not None:
        return "high"
    if status_code is not None and 200 <= status_code < 500:
        return "info"
    return "high"


def newest_release_per_family(releases):
    """Group libghostty-spm tags into `upstream.*` and the dated `1.x.*`
    families and keep the newest of each by publication date."""
    families = {}
    for release in releases or []:
        tag = release.get("tag_name")
        if not isinstance(tag, str):
            continue
        family = "upstream" if tag.startswith("upstream.") else "dated"
        published = release.get("published_at") or ""
        current = families.get(family)
        if current is None or published > (current.get("published_at") or ""):
            families[family] = release
    return families


def parse_shell_assignments(text):
    """`KEY="value"` lines from a POSIX shell file (Sources.lock, the two
    pinned lines in fetch-ghostty-artifact.sh)."""
    values = {}
    for match in re.finditer(r'^\s*([A-Z0-9_]+)="([^"]*)"', text, re.MULTILINE):
        values[match.group(1)] = match.group(2)
    return values


def ghostty_tag_from_url(url):
    match = re.search(r"/releases/download/([^/]+)/", url or "")
    return match.group(1) if match else None


def openssl_line(version):
    """`3.6.3` -> `3.6`; the release line a pin must stay inside."""
    parts = (version or "").split(".")
    if len(parts) < 2:
        return None
    return "%s.%s" % (parts[0], parts[1])


def openssl_releases_in_line(releases, line):
    """Stable `openssl-<line>.<patch>` releases, newest patch first."""
    if line is None:
        return []
    prefix = "openssl-%s." % line
    matching = [
        release
        for release in releases or []
        if isinstance(release.get("tag_name"), str)
        and release["tag_name"].startswith(prefix)
        and not release.get("prerelease")
        and not release.get("draft")
    ]

    def patch(release):
        tail = release["tag_name"][len(prefix) :]
        digits = re.match(r"^(\d+)", tail)
        return int(digits.group(1)) if digits else -1

    return sorted(matching, key=patch, reverse=True)


def advisories_after(advisories, pin_date):
    """Advisories published after the pin's date. `pin_date` is an ISO-8601
    string; missing dates mean "cannot rule it out", so they are included."""
    result = []
    for advisory in advisories or []:
        published = advisory.get("published_at")
        if pin_date is None or published is None or published > pin_date:
            result.append(advisory)
    return result


def parse_xcode_major(version_line):
    match = re.search(r"Xcode\s+(\d+)", version_line or "")
    return int(match.group(1)) if match else None


def parse_runner_major(workflow_text):
    match = re.search(r"runs-on:\s*macos-(\d+)", workflow_text or "")
    return int(match.group(1)) if match else None


def make_finding(
    check,
    severity,
    fingerprint,
    title,
    summary,
    evidence=None,
    lane="none",
    actions=None,
    data=None,
):
    return {
        "check": check,
        "severity": severity,
        "fingerprint": str(fingerprint),
        "new": False,
        "title": title,
        "summary": summary,
        "evidence": list(evidence or []),
        "lane": lane,
        "actions": list(actions or []),
        "data": dict(data or {}),
    }


def mark_new(finding, state, now_iso):
    """Set `new` from the fingerprint recorded for this check last run, and
    return the record to store. Unchanged fingerprints stay `repeat` and are
    never republished; `first_seen` survives across runs."""
    previous = (state.get("checks") or {}).get(finding["check"]) or {}
    is_new = previous.get("fingerprint") != finding["fingerprint"]
    finding["new"] = is_new
    record = {
        "fingerprint": finding["fingerprint"],
        "severity": finding["severity"],
        "first_seen": now_iso if is_new else previous.get("first_seen", now_iso),
        "last_seen": now_iso,
        "data": dict(previous.get("data") or {}),
    }
    record["data"].update(finding.get("data") or {})
    return record


def cap_runs(runs, limit=RUN_HISTORY_LIMIT):
    """Keep the most recent `limit` run records."""
    return list(runs or [])[-limit:]


def issue_title(check, headline):
    return "%s: %s: %s" % (ISSUE_TITLE_PREFIX, check, headline)


def truncate(text, limit):
    text = " ".join(str(text or "").split())
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 1)].rstrip() + "…"


def build_briefing(findings, date_string):
    """The morning-brief handoff: medium and high findings that are new."""
    items = []
    for finding in findings:
        if not finding.get("new"):
            continue
        if finding["severity"] not in ("high", "medium"):
            continue
        items.append(
            {
                "title": truncate("%s: %s" % (finding["check"], finding["title"]), 80),
                "headlines": [
                    truncate(line, 220) for line in finding.get("evidence", [])[:3]
                ],
                "act": [truncate(line, 300) for line in finding.get("actions", [])],
            }
        )
    return {"date": date_string, "items": items}


def severity_rank(severity):
    try:
        return SEVERITY_ORDER.index(severity)
    except ValueError:
        return 0


def render_table(findings):
    rows = ["| Check | Severity | State | Headline |", "| --- | --- | --- | --- |"]
    for finding in findings:
        rows.append(
            "| `%s` | %s | %s | %s |"
            % (
                finding["check"],
                finding["severity"],
                "new" if finding["new"] else "repeat",
                finding["title"].replace("|", "\\|"),
            )
        )
    return "\n".join(rows)


def render_report(findings, timestamp, repo_sha, duration_seconds):
    lines = [
        "# depwatch %s" % timestamp,
        "",
        "- Run: %s UTC" % timestamp,
        "- Repo: `%s`" % repo_sha,
        "- Duration: %.1fs" % duration_seconds,
        "",
        render_table(findings),
        "",
    ]
    for finding in findings:
        lines.append("## %s — %s" % (finding["check"], finding["title"]))
        lines.append("")
        lines.append(
            "Severity **%s**, %s, lane `%s`, fingerprint `%s`."
            % (
                finding["severity"],
                "new" if finding["new"] else "repeat",
                finding["lane"],
                finding["fingerprint"],
            )
        )
        lines.append("")
        if finding["summary"]:
            lines.append(finding["summary"])
            lines.append("")
        if finding["evidence"]:
            lines.append("Evidence:")
            lines.append("")
            for item in finding["evidence"]:
                lines.append("- %s" % item)
            lines.append("")
        if finding["actions"]:
            lines.append("Actions:")
            lines.append("")
            for index, item in enumerate(finding["actions"], start=1):
                lines.append("%d. %s" % (index, item))
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def render_issue_body(finding, timestamp):
    lines = [finding["summary"], ""]
    if finding["evidence"]:
        lines.append("**Evidence**")
        lines.append("")
        for item in finding["evidence"]:
            lines.append("- %s" % item)
        lines.append("")
    lines.append("**Lane**: `%s`" % finding["lane"])
    lines.append("")
    if finding["actions"]:
        lines.append("**Actions**")
        lines.append("")
        for index, item in enumerate(finding["actions"], start=1):
            lines.append("%d. %s" % (index, item))
        lines.append("")
    lines.append(
        "Opened by `scripts/depwatch.py` at %s; state in `~/.kelpie/depwatch/`. "
        "Fingerprint `%s`." % (timestamp, finding["fingerprint"])
    )
    return "\n".join(lines).rstrip() + "\n"


def render_vault_section(findings, timestamp):
    lines = ["_Last run: %s UTC._" % timestamp, "", render_table(findings), ""]
    attention = [f for f in findings if f["severity"] in ("high", "medium")]
    if attention:
        lines.append("### Needs attention")
        lines.append("")
        for finding in attention:
            first_action = finding["actions"][0] if finding["actions"] else "No action recorded."
            lines.append("- **%s** — %s" % (finding["title"], first_action))
        lines.append("")
    else:
        lines.append("Nothing needs attention.")
        lines.append("")
    return "\n".join(lines).rstrip()


def splice_vault_section(existing_text, section):
    """Replace the text between the markers, leaving the prose above alone.

    A note without markers gets them appended, so the first run is not a
    special case.
    """
    block = "%s\n%s\n%s" % (VAULT_BEGIN, section, VAULT_END)
    start = existing_text.find(VAULT_BEGIN)
    end = existing_text.find(VAULT_END)
    if start == -1 or end == -1 or end < start:
        prose = existing_text.rstrip()
        return (prose + "\n\n" + block + "\n") if prose else block + "\n"
    return existing_text[:start] + block + existing_text[end + len(VAULT_END) :]


def log_lines(findings, timestamp, counts, publish_mode, prepare_mode, duration_seconds):
    lines = [
        "%s run checks=%d new=%d high=%d medium=%d publish=%s prepare=%s duration=%.1f"
        % (
            timestamp,
            counts["checks"],
            counts["new"],
            counts["high"],
            counts["medium"],
            publish_mode,
            prepare_mode,
            duration_seconds,
        )
    ]
    for finding in findings:
        lines.append(
            "%s %s %s %s %s"
            % (
                timestamp,
                finding["check"],
                finding["severity"],
                "new" if finding["new"] else "repeat",
                finding["title"],
            )
        )
    return lines


# ---------------------------------------------------------------------------
# --- impure --- everything past here shells out, hits the network, or writes.
# ---------------------------------------------------------------------------


class Context:
    """Repo path, state, and the two helpers every check is allowed to use."""

    def __init__(self, repo, state, state_dir, worktree_root, dry_run, verbose):
        self.repo = repo
        self.state = state
        self.state_dir = state_dir
        self.worktree_root = worktree_root
        self.dry_run = dry_run
        self.verbose = verbose
        self._notes = []

    # -- the one command helper ------------------------------------------
    def run(self, argv, timeout=DEFAULT_TIMEOUT, cwd=None, env=None, tolerate=False):
        """Run one command with a hard deadline and captured output.

        A timeout raises ToolTimeout (the check wrapper turns it into an
        `error` finding) unless `tolerate` is set, in which case the caller
        gets a result with `timed_out` true. Nothing here ever inherits a tty.
        """
        merged = dict(os.environ)
        if env:
            merged.update(env)
        if self.verbose:
            print("depwatch: run %s" % " ".join(argv), file=sys.stderr)
        try:
            completed = subprocess.run(
                argv,
                cwd=str(cwd) if cwd else None,
                env=merged,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except FileNotFoundError:
            if tolerate:
                return {"code": 127, "out": "", "err": "%s not found" % argv[0], "timed_out": False}
            raise ToolError("%s is not on PATH" % argv[0])
        except subprocess.TimeoutExpired:
            if tolerate:
                return {"code": 124, "out": "", "err": "timed out", "timed_out": True}
            raise ToolTimeout("`%s` exceeded %gs" % (" ".join(argv[:4]), timeout))
        return {
            "code": completed.returncode,
            "out": completed.stdout or "",
            "err": completed.stderr or "",
            "timed_out": False,
        }

    def run_ok(self, argv, **kwargs):
        result = self.run(argv, **kwargs)
        if result["code"] != 0:
            raise ToolError(
                "`%s` exited %d: %s"
                % (" ".join(argv[:4]), result["code"], (result["err"] or result["out"]).strip()[:300])
            )
        return result["out"]

    def git(self, args, cwd=None, timeout=DEFAULT_TIMEOUT, tolerate=False):
        return self.run(["git", "-C", str(cwd or self.repo)] + args, timeout=timeout, tolerate=tolerate)

    def git_ok(self, args, cwd=None, timeout=DEFAULT_TIMEOUT):
        return self.run_ok(["git", "-C", str(cwd or self.repo)] + args, timeout=timeout).strip()

    # -- the one GitHub helper -------------------------------------------
    def gh_json(self, path, raw=False, tolerate=False):
        """`gh api <path>` parsed. `raw` asks for the raw blob media type."""
        argv = ["gh", "api"]
        if raw:
            argv += ["-H", "Accept: application/vnd.github.raw"]
        argv.append(path)
        result = self.run(argv, timeout=NETWORK_TIMEOUT, tolerate=tolerate)
        if result["code"] != 0:
            if tolerate:
                return None
            raise ToolError(
                "gh api %s exited %d: %s" % (path, result["code"], result["err"].strip()[:300])
            )
        if raw:
            return result["out"]
        try:
            return json.loads(result["out"] or "null")
        except ValueError as error:
            raise ToolError("gh api %s returned unparsable JSON: %s" % (path, error))

    def read_repo_text(self, relative):
        path = self.repo / relative
        if not path.exists():
            raise ToolError("%s is missing from the checkout" % relative)
        return path.read_text(encoding="utf-8", errors="replace")

    def check_data(self, check):
        return ((self.state.get("checks") or {}).get(check) or {}).get("data") or {}

    def note(self, text):
        self._notes.append(text)

    @property
    def notes(self):
        return list(self._notes)


def utc_timestamp():
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H-%M-%SZ")


def utc_iso():
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def sources_text(repo):
    """Every Swift source concatenated once, for the literal cross-references."""
    chunks = []
    sources = repo / "Sources"
    if sources.exists():
        for path in sorted(sources.rglob("*.swift")):
            try:
                chunks.append(path.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                continue
    return "\n".join(chunks)


# --- worktree helpers -------------------------------------------------------


def add_worktree(ctx, path, committish="kelpie"):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        remove_worktree(ctx, path)
    ctx.run_ok(["git", "-C", str(ctx.repo), "worktree", "add", "--detach", str(path), committish])
    return path


def remove_worktree(ctx, path):
    ctx.run(
        ["git", "-C", str(ctx.repo), "worktree", "remove", "--force", str(path)],
        tolerate=True,
    )
    if path.exists():
        shutil.rmtree(path, ignore_errors=True)
    ctx.run(["git", "-C", str(ctx.repo), "worktree", "prune"], tolerate=True)


def prune_worktrees(ctx):
    ctx.run(["git", "-C", str(ctx.repo), "worktree", "prune"], tolerate=True)


# --- checks -----------------------------------------------------------------


def check_herdr_release(ctx):
    releases = ctx.gh_json("repos/%s/releases?per_page=15" % HERDR_REPO) or []
    stable = latest_stable_release(releases)
    pre = latest_prerelease(releases)
    if stable is None:
        raise ToolError("no stable herdr release in the last 15 entries")
    stable_tag = stable.get("tag_name")
    snapshot_tag = ctx.check_data("herdr-release").get("snapshot_tag") or SNAPSHOT_TAG_SEED

    local_schema = json.loads(ctx.read_repo_text("scripts/herdr-schema.json"))
    evidence = [
        "latest stable herdr release `%s` (%s)" % (stable_tag, stable.get("published_at")),
        "committed snapshot `scripts/herdr-schema.json` is protocol %s, from `%s`"
        % (local_schema.get("protocol"), snapshot_tag),
    ]
    if pre is not None:
        evidence.append("latest prerelease `%s` (info only)" % pre.get("tag_name"))

    has_newer = semver_is_newer(stable_tag, snapshot_tag)
    if not has_newer:
        return make_finding(
            check="herdr-release",
            severity="info",
            fingerprint="%s|%s" % (stable_tag, snapshot_tag),
            title="herdr %s, snapshot current" % stable_tag,
            summary="No stable herdr release newer than the tag the committed schema snapshot came from.",
            evidence=evidence,
            lane="none",
            actions=[],
            data={"snapshot_tag": snapshot_tag, "stable_tag": stable_tag},
        )

    # A newer stable tag: fetch its schema and diff it against the snapshot.
    cache_dir = ctx.state_dir / "cache"
    cached = cache_dir / ("herdr-schema-%s.json" % stable_tag)
    new_schema = None
    if cached.exists():
        try:
            new_schema = json.loads(cached.read_text(encoding="utf-8"))
        except ValueError:
            new_schema = None
    if new_schema is None:
        blob = ctx.gh_json(
            "repos/%s/contents/%s?ref=%s" % (HERDR_REPO, HERDR_SCHEMA_PATH_IN_REPO, stable_tag),
            raw=True,
            tolerate=True,
        )
        if blob:
            try:
                new_schema = json.loads(blob)
            except ValueError:
                new_schema = None
            if new_schema is not None and not ctx.dry_run:
                cache_dir.mkdir(parents=True, exist_ok=True)
                cached.write_text(blob, encoding="utf-8")
    if new_schema is None:
        evidence.append(
            "could not read `%s` at `%s`" % (HERDR_SCHEMA_PATH_IN_REPO, stable_tag)
        )

    drift = schema_drift(local_schema, new_schema) if new_schema else None
    breaking = {"methods": [], "kinds": []}
    if drift is not None:
        text = sources_text(ctx.repo)
        kelpie_methods = used_methods(text)
        kelpie_kinds = used_event_kinds(
            text,
            list(schema_event_kinds(local_schema)) + list(schema_subscription_event_kinds(local_schema)),
        )
        breaking = cross_reference_drift(drift, kelpie_methods, kelpie_kinds)
        evidence.append(
            "protocol %s -> %s" % (drift["protocol_old"], drift["protocol_new"])
        )
        for group, label in (
            ("methods", "methods"),
            ("events", "event kinds"),
            ("subscription_events", "subscription event kinds"),
        ):
            bucket = drift[group]
            evidence.append(
                "%s: +%d -%d ~%d%s"
                % (
                    label,
                    len(bucket["added"]),
                    len(bucket["removed"]),
                    len(bucket["changed"]),
                    (" (" + ", ".join((bucket["removed"] + bucket["changed"])[:6]) + ")")
                    if (bucket["removed"] or bucket["changed"])
                    else "",
                )
            )
        evidence.append(
            "Kelpie uses %d methods; drift touches %s"
            % (
                len(kelpie_methods),
                ", ".join(breaking["methods"] + breaking["kinds"]) or "none of them",
            )
        )

    severity = herdr_release_severity(True, drift, breaking)

    # Regenerate the wire types in a throwaway worktree to size the change.
    regen = regenerate_wire_types(ctx, stable_tag, new_schema) if new_schema else None
    if regen:
        evidence.append(regen["summary"])

    actions = [
        "Mechanical: copy the `%s` schema over `scripts/herdr-schema.json`, run "
        "`python3 scripts/generate-wire-types.py --schema scripts/herdr-schema.json`, then "
        "`--check` to prove there is no drift, compile for `generic/platform=iOS`, and open the "
        "branch as a PR into `kelpie` so CI runs." % stable_tag,
        "Manual: re-verify the CLAUDE.md \"Load-bearing herdr facts\" still stamped with a version "
        "older than %s against a live server, and update the stamps." % stable_tag,
        "Manual: adjust `HeelerSSHTransport.minimumProtocolVersion` only per the floor rule in "
        "CLAUDE.md (`generatedProtocolVersion` stays advisory). Equality here made every 0.8.0 Host "
        "unusable (#140) — never restore it.",
        "Device build and the checklist in `KelpieVault/Open items.md` before merge.",
    ]
    headline = "herdr %s available (snapshot %s)" % (stable_tag, snapshot_tag)
    if drift is not None and drift.get("protocol_changed"):
        headline = "herdr %s: protocol %s -> %s" % (
            stable_tag,
            drift["protocol_old"],
            drift["protocol_new"],
        )
    return make_finding(
        check="herdr-release",
        severity=severity,
        fingerprint="%s|%s|%s"
        % (stable_tag, snapshot_tag, (drift or {}).get("protocol_new", "?")),
        title=headline,
        summary="herdr has a stable release newer than the tag Kelpie's committed schema snapshot "
        "came from. The schema drift below decides how much of it is mechanical.",
        evidence=evidence,
        lane="mechanical",
        actions=actions,
        data={
            # An identical schema means the snapshot already covers this tag,
            # so the recorded tag advances and the next run returns to info.
            "snapshot_tag": stable_tag if (drift and drift.get("identical")) else snapshot_tag,
            "stable_tag": stable_tag,
            "drift": drift,
            "breaking": breaking,
            "worktree": str(regen["worktree"]) if regen else None,
            "regen_ok": bool(regen and regen.get("ok")),
        },
    )


def regenerate_wire_types(ctx, tag, new_schema):
    """Copy the new schema into a detached worktree, regenerate, measure."""
    worktree = ctx.worktree_root / ("herdr-%s" % tag)
    try:
        add_worktree(ctx, worktree)
    except ToolError as error:
        ctx.note("worktree for %s could not be created: %s" % (tag, error))
        return None
    try:
        (worktree / "scripts" / "herdr-schema.json").write_text(
            json.dumps(new_schema, indent=2, sort_keys=False) + "\n", encoding="utf-8"
        )
        result = ctx.run(
            [
                sys.executable,
                "scripts/generate-wire-types.py",
                "--schema",
                "scripts/herdr-schema.json",
            ],
            cwd=worktree,
            tolerate=True,
        )
        if result["code"] != 0:
            summary = "regeneration failed in the worktree: %s" % (
                (result["err"] or result["out"]).strip()[:200]
            )
            return {"summary": summary, "worktree": worktree, "ok": False, "stat": ""}
        stat = ctx.git(["diff", "--stat"], cwd=worktree, tolerate=True)["out"].strip()
        numstat = ctx.git(
            ["diff", "--numstat", "--", "Sources/Heeler/Transport/Generated/"],
            cwd=worktree,
            tolerate=True,
        )["out"]
        changed_lines = 0
        for line in numstat.splitlines():
            fields = line.split("\t")
            if len(fields) >= 2:
                for value in fields[:2]:
                    if value.isdigit():
                        changed_lines += int(value)
        summary = "regenerated wire types in a worktree: %s changed lines under Generated/%s" % (
            changed_lines,
            ("; " + stat.replace("\n", "; ")) if stat else "",
        )
        return {"summary": summary, "worktree": worktree, "ok": True, "stat": stat}
    except OSError as error:
        ctx.note("regeneration in %s failed: %s" % (worktree, error))
        return None
    # The worktree is removed by the caller, or kept by --prepare as the fix branch.


def check_herdr_mini(ctx):
    config_path = ctx.state_dir / "config.json"
    host = None
    if config_path.exists():
        try:
            host = (json.loads(config_path.read_text(encoding="utf-8")) or {}).get("mini_host")
        except ValueError:
            host = None
    if not host:
        return make_finding(
            check="herdr-mini",
            severity="info",
            fingerprint="unconfigured",
            title="mini_host not configured",
            summary="No `mini_host` in `%s`, so the live herdr version on the Mac mini is not "
            "checked. See the guide for the one-time `ssh mac-mini` host-key accept." % config_path,
            evidence=["`mini_host` unset in %s" % config_path],
            lane="none",
        )
    result = ctx.run(
        # A non-interactive login shell has no Homebrew or ~/.local/bin on PATH
        # (the app's HerdrHostPath appends the same prefixes).
        [
            "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host,
            'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH" '
            "herdr --version",
        ],
        timeout=NETWORK_TIMEOUT,
        tolerate=True,
    )
    if result["code"] != 0:
        reason = (result["err"] or result["out"]).strip().splitlines()[-1:] or ["no output"]
        return make_finding(
            check="herdr-mini",
            severity="info",
            fingerprint="unreachable",
            title="%s unreachable" % host,
            summary="The Mac mini did not answer, so its herdr version is unknown. Not an error: "
            "the watch does not depend on the mini being up.",
            evidence=["ssh %s: %s" % (host, reason[0])],
            lane="none",
        )
    version_text = result["out"].strip()
    match = re.search(r"(\d+\.\d+\.\d+)", version_text)
    version = match.group(1) if match else version_text
    snapshot_tag = ctx.check_data("herdr-release").get("snapshot_tag") or SNAPSHOT_TAG_SEED
    ahead = semver_is_newer("v" + version, snapshot_tag) if match else False
    return make_finding(
        check="herdr-mini",
        severity="medium" if ahead else "info",
        fingerprint="%s|%s" % (version, snapshot_tag),
        title="mini runs herdr %s (snapshot %s)" % (version, snapshot_tag),
        summary="The Mac mini upgrades herdr through brew, so it can run ahead of the committed "
        "schema snapshot.",
        evidence=["`%s`: %s" % (host, version_text), "snapshot tag %s" % snapshot_tag],
        lane="manual" if ahead else "none",
        actions=(
            [
                "Re-verify the CLAUDE.md herdr facts against the mini's live server, then refresh "
                "the schema snapshot via the `herdr-release` mechanical lane."
            ]
            if ahead
            else []
        ),
        data={"mini_version": version},
    )


def check_heeler_upstream(ctx):
    ctx.run(["git", "-C", str(ctx.repo), "fetch", "upstream"], timeout=DEFAULT_TIMEOUT, tolerate=True)
    head = ctx.git(["rev-parse", "upstream/main"], tolerate=True)
    if head["code"] != 0:
        raise ToolError("no `upstream/main` ref: %s" % head["err"].strip()[:200])
    upstream_sha = head["out"].strip()
    try:
        text = (Path(ctx.repo) / REVIEWED_FILE).read_text()
    except OSError:
        text = None
    reviewed, problem = parse_reviewed_file(text)
    commits = []
    if reviewed:
        log = ctx.git(
            ["log", "--no-merges", "--name-only", "--format=%x1e%H%x09%s", "%s..upstream/main" % reviewed],
            tolerate=True,
        )
        if log["code"] != 0:
            problem = "`%s` names `%s`, which git cannot range from: %s" % (
                REVIEWED_FILE, reviewed[:12], log["err"].strip()[:160])
        else:
            commits = parse_upstream_log(log["out"])
    return upstream_finding(reviewed, upstream_sha, commits, problem)


def check_libghostty_spm(ctx):
    script = ctx.read_repo_text("scripts/fetch-ghostty-artifact.sh")
    pins = parse_shell_assignments(script)
    pinned_tag = ghostty_tag_from_url(pins.get("URL", ""))
    pinned_sha = pins.get("SHA", "")
    if pinned_tag is None:
        raise ToolError("could not read the pinned tag from scripts/fetch-ghostty-artifact.sh")

    releases = ctx.gh_json("repos/%s/releases?per_page=10" % GHOSTTY_REPO) or []
    families = newest_release_per_family(releases)
    pinned_release = ctx.gh_json(
        "repos/%s/releases/tags/%s" % (GHOSTTY_REPO, pinned_tag), tolerate=True
    )
    pinned_date = (pinned_release or {}).get("published_at")
    pinned_family = "upstream" if pinned_tag.startswith("upstream.") else "dated"
    newest_same_family = families.get(pinned_family)
    newer = bool(
        newest_same_family
        and newest_same_family.get("tag_name") != pinned_tag
        and (not pinned_date or (newest_same_family.get("published_at") or "") > pinned_date)
    )

    evidence = [
        "pinned `%s` (SHA256 `%s…`)%s"
        % (pinned_tag, pinned_sha[:12], (", published %s" % pinned_date[:10]) if pinned_date else ""),
    ]
    for family, release in sorted(families.items()):
        evidence.append(
            "newest `%s` family tag: `%s` (%s)"
            % (family, release.get("tag_name"), (release.get("published_at") or "")[:10])
        )
    return make_finding(
        check="libghostty-spm",
        severity="low" if newer else "info",
        fingerprint="%s|%s" % (pinned_tag, (newest_same_family or {}).get("tag_name")),
        title=(
            "libghostty %s pinned, %s available"
            % (pinned_tag, (newest_same_family or {}).get("tag_name"))
            if newer
            else "libghostty %s is current" % pinned_tag
        ),
        summary="The terminal engine is a vendored prebuilt xcframework; Xcode's downloader hangs on "
        "the remote binary on this Mac, so the pin is deliberate and moving it is a manual job.",
        evidence=evidence,
        lane="manual" if newer else "none",
        actions=(
            [
                "Never edit the vendored package under `Packages/GhosttyTerminal`; override its `open` "
                "members from `HeelerTerminalView` instead.",
                "First `make ghostty-override-diff NEW=<commit>`: it names every UITerminalView member "
                "Kelpie overrides, declares or calls that the new commit removes, closes, re-signs or "
                "collides with (Open item 40).",
                "Re-vendor from the new tag: update `URL` and `SHA` in `scripts/fetch-ghostty-artifact.sh`, "
                "then `make generate` to refetch and checksum-verify.",
                "Review the package's Swift sources and the XCFramework checksum before accepting the bump.",
                "Device build, then the pointer/long-press/trackpad-scroll checklist in "
                "`docs/adr/0016-ipad-pointer-input.md`.",
            ]
            if newer
            else []
        ),
        data={"pinned_tag": pinned_tag},
    )


def check_heeler_ssh_pins(ctx):
    lock = parse_shell_assignments(ctx.read_repo_text("Packages/HeelerSSH/Sources.lock"))
    libssh2_commit = lock.get("LIBSSH2_COMMIT", "")
    openssl_version = lock.get("OPENSSL_VERSION", "")
    line = openssl_line(openssl_version)

    evidence = [
        "pinned libssh2 `%s` (tag `%s`)" % (libssh2_commit[:12], lock.get("LIBSSH2_TAG")),
        "pinned OpenSSL `%s`" % openssl_version,
    ]

    libssh2_latest = ctx.gh_json("repos/libssh2/libssh2/releases/latest", tolerate=True) or {}
    commit = (
        ctx.gh_json("repos/libssh2/libssh2/commits/%s" % libssh2_commit, tolerate=True)
        if libssh2_commit
        else None
    ) or {}
    libssh2_pin_date = ((commit.get("commit") or {}).get("committer") or {}).get("date")
    master = ctx.gh_json("repos/libssh2/libssh2/commits/master", tolerate=True) or {}
    master_sha = master.get("sha") or ""
    evidence.append(
        "libssh2 latest release `%s` (%s); pinned commit dated %s"
        % (
            libssh2_latest.get("tag_name"),
            (libssh2_latest.get("published_at") or "")[:10],
            (libssh2_pin_date or "unknown")[:10],
        )
    )
    if master_sha:
        evidence.append("libssh2 master head `%s` (info only)" % master_sha[:12])

    openssl_releases = ctx.gh_json("repos/openssl/openssl/releases?per_page=30", tolerate=True) or []
    in_line = openssl_releases_in_line(openssl_releases, line)
    newest_in_line = in_line[0] if in_line else None
    pinned_release = next(
        (r for r in openssl_releases if r.get("tag_name") == lock.get("OPENSSL_TAG")), None
    )
    openssl_pin_date = (pinned_release or {}).get("published_at")
    newer_patch = bool(
        newest_in_line and newest_in_line.get("tag_name") != lock.get("OPENSSL_TAG")
    )
    evidence.append(
        "newest OpenSSL in the pinned %s line: `%s` (%s)"
        % (line, (newest_in_line or {}).get("tag_name"), ((newest_in_line or {}).get("published_at") or "")[:10])
    )
    other_lines = sorted(
        {
            r.get("tag_name")
            for r in openssl_releases[:8]
            if isinstance(r.get("tag_name"), str) and not r["tag_name"].startswith("openssl-%s." % line)
        }
    )
    if other_lines:
        evidence.append("other OpenSSL lines (info only): %s" % ", ".join(other_lines[:5]))

    openssl_advisories = ctx.gh_json(
        "repos/openssl/openssl/security-advisories?state=published&per_page=20", tolerate=True
    ) or []
    libssh2_advisories = ctx.gh_json(
        "repos/libssh2/libssh2/security-advisories?state=published&per_page=20", tolerate=True
    ) or []
    relevant = advisories_after(openssl_advisories, openssl_pin_date) + advisories_after(
        libssh2_advisories, libssh2_pin_date
    )
    advisory_ids = sorted(
        str(a.get("ghsa_id")) for a in relevant if a.get("ghsa_id")
    )
    evidence.append(
        "advisories published after the pins: %s"
        % (", ".join(advisory_ids) if advisory_ids else "none listed on either repo")
    )

    severity = ssh_pins_severity(advisory_ids, newer_patch)
    title = (
        "%d advisory/-ies after the SSH pins" % len(advisory_ids)
        if advisory_ids
        else (
            "OpenSSL %s pinned, %s in line"
            % (openssl_version, (newest_in_line or {}).get("tag_name"))
            if newer_patch
            else "SSH pins current"
        )
    )
    return make_finding(
        check="heeler-ssh-pins",
        severity=severity,
        fingerprint="%s|%s|%s" % (libssh2_commit[:12], openssl_version, ",".join(advisory_ids)),
        title=title,
        summary="libssh2 and OpenSSL are pinned by commit and tarball hash in "
        "`Packages/HeelerSSH/Sources.lock`; normal builds consume the checked-in XCFrameworks, so a "
        "pin move is a deliberate rebuild.",
        evidence=evidence,
        lane="manual",
        actions=[
            "Review the upstream source hashes and the committed XCFramework checksums before moving "
            "either pin (CLAUDE.md conventions).",
            "Update `Packages/HeelerSSH/Sources.lock`, then `make ssh-artifacts` and "
            "`make verify-ssh-artifacts`.",
            "`scripts/run-heelerssh-package-tests.sh` — the package suites are a separate test plan, not "
            "`-only-testing:HeelerTests/...`.",
            "PR into `kelpie` for CI, then a device build.",
        ],
        data={"advisory_ids": advisory_ids},
    )


def check_node(ctx):
    evidence = []
    worst_counts = {}
    details = []
    for package in ("plugin", "relay"):
        directory = ctx.repo / package
        if not directory.exists():
            evidence.append("`%s/` is not in the checkout" % package)
            continue
        if not (directory / "package-lock.json").exists():
            evidence.append("`%s/`: no lockfile; dependency-free by design" % package)
            continue
        result = ctx.run(
            ["npm", "audit", "--json", "--audit-level=low"],
            cwd=directory,
            timeout=NETWORK_TIMEOUT,
            tolerate=True,
        )
        if result["timed_out"]:
            raise ToolTimeout("`npm audit` in %s/ exceeded %gs" % (package, NETWORK_TIMEOUT))
        if result["code"] == 127:
            evidence.append("`%s/`: npm is not on PATH; audit skipped" % package)
            continue
        try:
            report = json.loads(result["out"] or "{}")
        except ValueError:
            evidence.append("`%s/`: npm audit produced unparsable JSON" % package)
            continue
        counts = (report.get("metadata") or {}).get("vulnerabilities") or {}
        total = counts.get("total", sum(v for k, v in counts.items() if k != "total"))
        evidence.append(
            "`%s/`: %d vulnerabilities (critical %d, high %d, moderate %d, low %d)"
            % (
                package,
                total,
                counts.get("critical", 0),
                counts.get("high", 0),
                counts.get("moderate", 0),
                counts.get("low", 0),
            )
        )
        for name in list((report.get("vulnerabilities") or {}))[:5]:
            entry = report["vulnerabilities"][name]
            details.append("%s/%s: %s" % (package, name, entry.get("severity")))
        for key, value in counts.items():
            if key == "total":
                continue
            worst_counts[key] = worst_counts.get(key, 0) + int(value or 0)
    evidence.extend(details)
    severity = node_severity(worst_counts)
    total = sum(worst_counts.values())
    return make_finding(
        check="node",
        severity=severity,
        fingerprint="|".join("%s=%d" % (k, worst_counts.get(k, 0)) for k in sorted(worst_counts))
        or "clean",
        title="npm audit: %d vulnerabilit%s" % (total, "y" if total == 1 else "ies"),
        summary="`plugin/` renders Pairing Codes and posts Agent Notifications; `relay/` is the "
        "stateless push relay. Both are audited read-only — the watch never runs `npm install`.",
        evidence=evidence,
        lane="mechanical" if severity != "info" else "none",
        actions=(
            [
                "On a branch: `npm audit fix` in the affected directory (never in the checkout from a "
                "watch run).",
                "`npm test` in that directory — the vectors in `plugin/test-vectors/` are shared with the "
                "Swift suite, so they move in lockstep.",
                "PR into `kelpie`; `.github/workflows/ci-node.yml` is the lane that verifies it.",
            ]
            if severity != "info"
            else []
        ),
    )


def pick_ipad_version(devices):
    """The OS version of the Kelpie iPad if devicectl lists it, else the first
    iPad, else the first iOS device. Returns the version string only, so a
    device rename never changes the fingerprint."""
    ranked = []
    for device in devices:
        properties = device.get("deviceProperties") or {}
        hardware = device.get("hardwareProperties") or {}
        version = properties.get("osVersionNumber")
        if hardware.get("platform") != "iOS" or not version:
            continue
        if hardware.get("udid") == KELPIE_IPAD_UDID:
            rank = 0
        elif "ipad" in str(hardware.get("marketingName") or "").lower():
            rank = 1
        else:
            rank = 2
        ranked.append((rank, str(version)))
    return min(ranked)[1] if ranked else None


def check_toolchain(ctx):
    version = ctx.run(["xcodebuild", "-version"], timeout=DEFAULT_TIMEOUT, tolerate=True)
    if version["code"] != 0:
        raise ToolError("xcodebuild -version failed: %s" % version["err"].strip()[:200])
    version_lines = [line.strip() for line in version["out"].splitlines() if line.strip()][:2]
    xcode_line = version_lines[0] if version_lines else ""
    build_line = version_lines[1] if len(version_lines) > 1 else ""

    ipad_version = None
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as handle:
        device_json = Path(handle.name)
    try:
        result = ctx.run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", str(device_json)],
            timeout=DEVICE_TIMEOUT,
            tolerate=True,
        )
        if result["code"] == 0 and device_json.exists():
            try:
                payload = json.loads(device_json.read_text(encoding="utf-8") or "{}")
            except ValueError:
                payload = {}
            ipad_version = pick_ipad_version((payload.get("result") or {}).get("devices") or [])
    finally:
        try:
            device_json.unlink()
        except OSError:
            pass

    workflow = ""
    workflow_path = ctx.repo / ".github/workflows/ci.yml"
    if workflow_path.exists():
        workflow = workflow_path.read_text(encoding="utf-8", errors="replace")
    runner_major = parse_runner_major(workflow)
    local_major = parse_xcode_major(xcode_line)

    fingerprint = "%s %s|%s" % (xcode_line, build_line, ipad_version or "no-device")
    previous = ((ctx.state.get("checks") or {}).get("toolchain") or {}).get("fingerprint")
    changed = previous is not None and previous != fingerprint

    evidence = ["`%s` / `%s`" % (xcode_line, build_line)]
    evidence.append(
        "connected device: %s" % (ipad_version or "none (devicectl listed no connected iOS device)")
    )
    evidence.append(
        "CI runner pin `macos-%s` vs local Xcode major %s" % (runner_major, local_major)
    )
    severity = toolchain_severity(changed, runner_major, local_major)
    actions = []
    if severity == "medium":
        actions.append(
            "The fork's CI runner image and the local Xcode major differ; align "
            "`runs-on: macos-%s` in `.github/workflows/ci.yml` or accept that CI compiles against a "
            "different toolchain than the device build." % runner_major
        )
    if changed:
        actions.append(
            "Run a device build and the device checklist in `KelpieVault/Open items.md` — the "
            "simulator does not run reliably on this Mac."
        )
    return make_finding(
        check="toolchain",
        severity=severity,
        fingerprint=fingerprint,
        title="%s%s" % (xcode_line or "Xcode unknown", (", %s" % ipad_version) if ipad_version else ""),
        summary="Kelpie only ever ships from a device build on this Mac, so the local Xcode and the "
        "iPad's OS are part of the dependency surface.",
        evidence=evidence,
        lane="infra",
        actions=actions,
    )


def check_ci_fork(ctx):
    workflows = ctx.gh_json("repos/%s/actions/workflows" % FORK_REPO, tolerate=True) or {}
    workflow_names = [
        "%s (%s)" % (w.get("name"), w.get("state"))
        for w in (workflows.get("workflows") or [])
    ]
    runs_result = ctx.run(
        [
            "gh",
            "run",
            "list",
            "-R",
            FORK_REPO,
            "--limit",
            "5",
            "--json",
            "name,status,conclusion,headBranch,createdAt",
        ],
        timeout=NETWORK_TIMEOUT,
        tolerate=True,
    )
    runs = []
    if runs_result["code"] == 0:
        try:
            runs = json.loads(runs_result["out"] or "[]")
        except ValueError:
            runs = []
    has_success = any(
        run.get("conclusion") == "success" and str(run.get("name", "")) == "CI"
        for run in runs
    )
    latest_conclusion = runs[0].get("conclusion") if runs else None

    evidence = [
        "workflows registered on the fork: %s"
        % (", ".join(workflow_names) or "none (Actions has never run here)"),
        "recent runs: %s"
        % (
            "; ".join(
                "%s %s/%s on %s"
                % (r.get("name"), r.get("status"), r.get("conclusion"), r.get("headBranch"))
                for r in runs[:5]
            )
            or "none"
        ),
    ]
    severity = ci_fork_severity(has_success, latest_conclusion)
    return make_finding(
        check="ci-fork",
        severity=severity,
        fingerprint="%s|%s|%s" % (len(workflow_names), has_success, latest_conclusion),
        title=(
            "no successful CI run on the fork"
            if not has_success
            else "fork CI latest: %s" % latest_conclusion
        ),
        summary=(
            "Every fix the watch prepares is verified by CI on the fork. While Actions has never "
            "run on `%s`, the verification ladder has a missing rung: the compile is the only gate a "
            "`Sources/` change would get, and CLAUDE.md forbids merging on that alone." % FORK_REPO
            if not has_success
            else "CI runs on the fork; the latest run on `%s` finished %s. The real-SSH suites are "
            "flaky on hosted runners (upstream sees the same), so a red run is re-run once before "
            "it counts as a regression." % (FORK_REPO, latest_conclusion)
        ),
        evidence=evidence,
        lane="infra",
        actions=[
            "Enable Actions on the fork: Settings -> Actions -> Allow all actions, or "
            "`gh api -X PUT repos/%s/actions/permissions -f enabled=true`." % FORK_REPO,
            "Open every fix branch as a PR into `kelpie`. `ci.yml`'s `pull_request` trigger has no "
            "branch filter, so a PR into `kelpie` runs it; the `push` trigger is `main`-only and never "
            "will.",
            "macOS minutes are free on a public repository, so the runner cost is not a reason to "
            "leave it off.",
        ],
    )


def check_relay(ctx):
    text = sources_text(ctx.repo)
    match = re.search(r'productionBaseURLString\s*=\s*"(https://[^"]+)"', text)
    if match is None:
        match = re.search(r'"(https://[^"]*workers\.dev[^"]*)"', text)
    if match is None:
        raise ToolError("no relay origin found under Sources/")
    origin = match.group(1).rstrip("/")
    probe = "%s/depwatch-probe" % origin
    status_code = None
    error = None
    try:
        request = urllib.request.Request(probe, method="GET", headers={"User-Agent": "kelpie-depwatch"})
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            status_code = response.getcode()
    except urllib.error.HTTPError as http_error:
        status_code = http_error.code
    except Exception as other:  # URLError, socket.timeout, ssl errors
        error = "%s: %s" % (type(other).__name__, other)

    severity = relay_severity(status_code, error)
    evidence = [
        "probed `%s`" % probe,
        "result: %s" % (error if error else "HTTP %s" % status_code),
        "the Worker answers 404 for any path but `/push` (`relay/src/worker.js`), so a 404 is healthy",
    ]
    return make_finding(
        check="relay",
        severity=severity,
        fingerprint="%s|%s" % ("unhealthy" if severity == "high" else "healthy", status_code or error),
        title=(
            "push relay unreachable"
            if severity == "high"
            else "push relay healthy (HTTP %s)" % status_code
        ),
        summary="Agent Notifications reach the iPad through this Cloudflare Worker. If it stops "
        "answering, notifications stop and nothing in the app says so.",
        evidence=evidence,
        lane="infra",
        actions=(
            [
                "Check the Worker in the Cloudflare dashboard and `wrangler tail` for the deployment "
                "behind `%s`." % origin,
                "Confirm the APNs key secret is still bound; `relay/` is dependency-free, so a failure "
                "is deploy or config, not a package.",
                "`npm test` in `relay/` before redeploying.",
            ]
            if severity == "high"
            else []
        ),
    )


def check_review_host(ctx):
    ssh_config = Path.home() / ".ssh" / "config"
    configured = False
    if ssh_config.exists():
        try:
            configured = bool(
                re.search(
                    r"^\s*Host\s+.*\bkelpie-review\b",
                    ssh_config.read_text(encoding="utf-8", errors="replace"),
                    re.MULTILINE,
                )
            )
        except OSError:
            configured = False
    if not configured:
        return make_finding(
            check="review-host",
            severity="info",
            fingerprint="absent",
            title="no review host configured",
            summary="`~/.ssh/config` has no `Host kelpie-review`, so the temporary App Review host is "
            "either already deleted or was never set up here.",
            evidence=["no `Host kelpie-review` in %s" % ssh_config],
            lane="none",
        )
    result = ctx.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "kelpie-review", "true"],
        timeout=NETWORK_TIMEOUT,
        tolerate=True,
    )
    reachable = result["code"] == 0
    if reachable:
        probe_evidence = "`ssh kelpie-review true`: ok"
    else:
        tail = (result["err"] or result["out"]).strip().splitlines()
        probe_evidence = "`ssh kelpie-review true`: %s" % (tail[-1] if tail else "failed")
    return make_finding(
        check="review-host",
        severity="info" if reachable else "medium",
        fingerprint="reachable" if reachable else "unreachable",
        title=("review host reachable" if reachable else "review host unreachable"),
        summary="The Hetzner box behind `kelpie-review` exists only so App Review has a herdr Host to "
        "connect to. See `docs/guides/app-review-host.md`.",
        evidence=[probe_evidence],
        lane="infra",
        actions=(
            [
                "Delete the Hetzner server once the App Store review is approved — it is a paid box kept "
                "alive only for review (`resume.md`, `docs/guides/app-review-host.md`)."
            ]
            if reachable
            else [
                "App Review may need this Host. Bring it back or confirm the submission no longer "
                "depends on it (`docs/guides/app-review-host.md`)."
            ]
        ),
    )


CHECKS = [
    ("herdr-release", check_herdr_release),
    ("herdr-mini", check_herdr_mini),
    ("heeler-upstream", check_heeler_upstream),
    ("libghostty-spm", check_libghostty_spm),
    ("heeler-ssh-pins", check_heeler_ssh_pins),
    ("node", check_node),
    ("toolchain", check_toolchain),
    ("ci-fork", check_ci_fork),
    ("relay", check_relay),
    ("review-host", check_review_host),
]


def run_check(check_id, function, ctx):
    """One failing check must not stop the others."""
    try:
        finding = function(ctx)
    except ToolTimeout as error:
        finding = make_finding(
            check=check_id,
            severity="error",
            fingerprint="timeout",
            title="check timed out",
            summary="The check exceeded its deadline. A timeout is reported, never waited on.",
            evidence=[str(error)],
            lane="none",
        )
    except Exception as error:  # a check must never crash the run
        finding = make_finding(
            check=check_id,
            severity="error",
            fingerprint="error:%s" % type(error).__name__,
            title="check failed: %s" % type(error).__name__,
            summary="The check could not run. Its dependency is unwatched until this is fixed.",
            evidence=[str(error)[:500]],
            lane="none",
        )
    finding["check"] = check_id
    return finding


# --- Stage A2: --prepare ----------------------------------------------------


def prepare_herdr_fix(ctx, finding, publish, dry_run, planned):
    """Branch, commit and verify the mechanical herdr schema refresh."""
    data = finding.get("data") or {}
    tag = data.get("stable_tag")
    worktree_path = data.get("worktree")
    if not tag or not worktree_path:
        planned.append("herdr-release: nothing to prepare (no regenerated worktree)")
        return None
    if not data.get("regen_ok"):
        planned.append("herdr-release: nothing to prepare (wire-type regeneration failed)")
        return None
    prepared = (ctx.state.get("prepared") or {}).get(tag)
    if prepared:
        planned.append(
            "herdr-release: %s was already prepared as `%s`%s"
            % (tag, prepared.get("branch"), (" (%s)" % prepared["pr"]) if prepared.get("pr") else "")
        )
        return None
    branch = "depwatch/herdr-%s" % tag
    worktree = Path(worktree_path)
    if dry_run:
        planned.append("would `git -C %s switch -c %s`" % (worktree, branch))
        planned.append(
            "would commit `scripts/herdr-schema.json` + `Sources/Heeler/Transport/Generated/`"
        )
        planned.append("would verify: generate-wire-types --check, fetch-ghostty, xcodegen, compile")
        planned.append("compile is skipped under --dry-run")
        if publish:
            planned.append("would `git push origin %s`" % branch)
            planned.append(
                "would `gh pr create --base kelpie --head %s --title \"chore(wire): herdr %s schema "
                "snapshot\" --body-file <report>`" % (branch, tag)
            )
        return None

    steps = []
    ctx.run_ok(["git", "-C", str(worktree), "switch", "-c", branch])
    ctx.run_ok(
        [
            "git",
            "-C",
            str(worktree),
            "add",
            "scripts/herdr-schema.json",
            "Sources/Heeler/Transport/Generated/",
        ]
    )
    issue_number = (ctx.state.get("issues") or {}).get("herdr-release", {}).get("number")
    message = (
        "chore(wire): herdr %s schema snapshot and regenerated wire types\n\n"
        "Automated by scripts/depwatch.py. refs depwatch%s"
        % (tag, (" #%s" % issue_number) if issue_number else "")
    )
    commit = ctx.run(["git", "-C", str(worktree), "commit", "-m", message], tolerate=True)
    steps.append("commit: %s" % ("ok" if commit["code"] == 0 else commit["err"].strip()[:160]))
    if commit["code"] != 0:
        finding["evidence"].append("prepare stopped at commit: %s" % commit["err"].strip()[:200])
        return None

    failed_at = None
    drift = ctx.run(
        [sys.executable, "scripts/generate-wire-types.py", "--check", "--schema", "scripts/herdr-schema.json"],
        cwd=worktree,
        tolerate=True,
    )
    steps.append("generate-wire-types --check: %s" % ("pass" if drift["code"] == 0 else "FAIL"))
    if drift["code"] != 0:
        failed_at = "generate-wire-types --check"

    if failed_at is None:
        vendored = ctx.repo / "Packages/GhosttyTerminal/Artifacts/GhosttyKit.xcframework"
        target = worktree / "Packages/GhosttyTerminal/Artifacts/GhosttyKit.xcframework"
        if vendored.exists() and not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(vendored, target)
            steps.append("libghostty artifact: copied from the checkout")
        else:
            fetch = ctx.run(["sh", "scripts/fetch-ghostty-artifact.sh"], cwd=worktree, timeout=600, tolerate=True)
            steps.append("fetch-ghostty-artifact.sh: %s" % ("ok" if fetch["code"] == 0 else "FAIL"))
            if fetch["code"] != 0:
                failed_at = "fetch-ghostty-artifact.sh"

    if failed_at is None:
        if shutil.which("xcodegen"):
            generate = ctx.run(["xcodegen", "generate"], cwd=worktree, timeout=300, tolerate=True)
            steps.append("xcodegen generate: %s" % ("ok" if generate["code"] == 0 else "FAIL"))
            if generate["code"] != 0:
                failed_at = "xcodegen generate"
        else:
            steps.append("xcodegen generate: skipped (not on PATH)")

    if failed_at is None:
        build_dir = ctx.state_dir / "build"
        build_dir.mkdir(parents=True, exist_ok=True)
        log_path = build_dir / ("xcodebuild-%s.log" % tag)
        compile_result = ctx.run(
            [
                "/bin/sh",
                "-c",
                "xcodebuild build -project Heeler.xcodeproj -scheme Heeler -configuration Debug "
                "-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "
                "-clonedSourcePackagesDirPath %s -derivedDataPath %s > %s 2>&1"
                % (shlex.quote(str(build_dir / "spm")), shlex.quote(str(build_dir / "dd")), shlex.quote(str(log_path))),
            ],
            cwd=worktree,
            timeout=COMPILE_TIMEOUT,
            tolerate=True,
        )
        tail = ""
        if log_path.exists():
            tail = "\n".join(log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-40:])
        steps.append(
            "xcodebuild (generic/platform=iOS): %s; log %s"
            % ("pass" if compile_result["code"] == 0 else "FAIL", log_path)
        )
        if compile_result["code"] != 0:
            failed_at = "xcodebuild"
            steps.append("last 40 log lines:\n```\n%s\n```" % tail)

    finding["evidence"].append("prepared branch `%s` in %s" % (branch, worktree))
    finding["evidence"].extend("prepare step — %s" % step for step in steps)
    record = {"branch": branch, "worktree": str(worktree), "steps": steps, "failed_at": failed_at}

    if publish and failed_at is None:
        push = ctx.run(["git", "-C", str(worktree), "push", "origin", branch], timeout=180, tolerate=True)
        if push["code"] == 0:
            body_path = ctx.state_dir / "reports" / ("pr-body-%s.md" % tag)
            body_path.parent.mkdir(parents=True, exist_ok=True)
            body_path.write_text(
                "Automated by `scripts/depwatch.py`.\n\n"
                + "\n".join("- %s" % item for item in finding["evidence"])
                + "\n\nMerge only after CI is green and a device build has run.\n",
                encoding="utf-8",
            )
            pr = ctx.run(
                [
                    "gh",
                    "pr",
                    "create",
                    "--base",
                    "kelpie",
                    "--head",
                    branch,
                    "--title",
                    "chore(wire): herdr %s schema snapshot" % tag,
                    "--body-file",
                    str(body_path),
                ],
                timeout=NETWORK_TIMEOUT,
                tolerate=True,
            )
            if pr["code"] == 0:
                record["pr"] = pr["out"].strip().splitlines()[-1:][0] if pr["out"].strip() else ""
                finding["evidence"].append("pull request: %s" % record["pr"])
        else:
            record["push_error"] = push["err"].strip()[:200]
    else:
        finding["evidence"].append(
            "branch left in the worktree at %s (no --publish, or a verification step failed)" % worktree
        )
    return record


# --- publishing -------------------------------------------------------------


def ensure_labels(ctx, dry_run, planned):
    commands = [
        [
            "gh",
            "label",
            "create",
            "depwatch",
            "--force",
            "--color",
            "1d76db",
            "--description",
            "Opened by scripts/depwatch.py",
        ],
        ["gh", "label", "create", "dependencies", "--force", "--color", "0366d6"],
    ]
    for argv in commands:
        if dry_run:
            planned.append("would run: %s" % " ".join(argv))
        else:
            ctx.run(argv + ["-R", FORK_REPO], timeout=NETWORK_TIMEOUT, tolerate=True)


def publish_findings(ctx, findings, timestamp, dry_run, planned):
    ensure_labels(ctx, dry_run, planned)
    issues = dict(ctx.state.get("issues") or {})
    for finding in findings:
        if finding["severity"] in ("high", "medium"):
            if not finding["new"]:
                continue
        elif finding["severity"] == "info" and finding["check"] in issues:
            # A check that fell back to info closes its issue.
            number = issues[finding["check"]].get("number")
            argv_comment = [
                "gh", "issue", "comment", str(number), "-R", FORK_REPO,
                "--body", "resolved by %s" % finding["fingerprint"],
            ]
            argv_close = ["gh", "issue", "close", str(number), "-R", FORK_REPO]
            if dry_run:
                planned.append("would run: %s" % " ".join(argv_comment))
                planned.append("would run: %s" % " ".join(argv_close))
            else:
                ctx.run(argv_comment, timeout=NETWORK_TIMEOUT, tolerate=True)
                ctx.run(argv_close, timeout=NETWORK_TIMEOUT, tolerate=True)
                issues.pop(finding["check"], None)
            continue
        else:
            continue

        title = issue_title(finding["check"], finding["title"])
        body = render_issue_body(finding, timestamp)
        body_path = ctx.state_dir / "reports" / ("issue-%s.md" % finding["check"])
        if dry_run:
            # The body still gets written, to a temp file, so the printed path
            # is something he can actually open and read.
            body_path = Path(tempfile.gettempdir()) / ("depwatch-issue-%s.md" % finding["check"])
        else:
            body_path.parent.mkdir(parents=True, exist_ok=True)
        body_path.write_text(body, encoding="utf-8")

        existing = find_open_issue(ctx, finding["check"], dry_run, planned)
        if existing is None:
            argv = [
                "gh", "issue", "create", "-R", FORK_REPO,
                "--title", title,
                "--label", "depwatch", "--label", "dependencies",
                "--body-file", str(body_path),
            ]
            if dry_run:
                planned.append("would run: %s  (body at %s)" % (" ".join(argv), body_path))
            else:
                result = ctx.run(argv, timeout=NETWORK_TIMEOUT, tolerate=True)
                url = result["out"].strip().splitlines()[-1:]
                number = url[0].rsplit("/", 1)[-1] if url else None
                if number:
                    issues[finding["check"]] = {"number": number, "url": url[0]}
        else:
            number = str(existing)
            argv_comment = [
                "gh", "issue", "comment", number, "-R", FORK_REPO, "--body-file", str(body_path),
            ]
            argv_edit = ["gh", "issue", "edit", number, "-R", FORK_REPO, "--title", title]
            if dry_run:
                planned.append("would run: %s  (body at %s)" % (" ".join(argv_comment), body_path))
                planned.append("would run: %s" % " ".join(argv_edit))
            else:
                ctx.run(argv_comment, timeout=NETWORK_TIMEOUT, tolerate=True)
                ctx.run(argv_edit, timeout=NETWORK_TIMEOUT, tolerate=True)
                issues[finding["check"]] = {"number": number}
    ctx.state["issues"] = issues


def find_open_issue(ctx, check, dry_run, planned):
    argv = [
        "gh", "issue", "list", "-R", FORK_REPO,
        "--label", "depwatch", "--state", "open",
        "--search", "%s: %s:" % (ISSUE_TITLE_PREFIX, check),
        "--json", "number,title",
    ]
    if dry_run:
        planned.append("would run: %s" % " ".join(argv))
        return None
    result = ctx.run(argv, timeout=NETWORK_TIMEOUT, tolerate=True)
    if result["code"] != 0:
        return None
    try:
        issues = json.loads(result["out"] or "[]")
    except ValueError:
        return None
    prefix = "%s: %s:" % (ISSUE_TITLE_PREFIX, check)
    for issue in issues:
        if str(issue.get("title", "")).startswith(prefix):
            return issue.get("number")
    return None


# --- state, reports, outputs ------------------------------------------------


def load_state(state_dir):
    path = state_dir / "state.json"
    if not path.exists():
        return {"version": 1, "checks": {}, "runs": [], "issues": {}, "prepared": {}}
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return {"version": 1, "checks": {}, "runs": [], "issues": {}, "prepared": {}}
    state.setdefault("checks", {})
    state.setdefault("runs", [])
    state.setdefault("issues", {})
    state.setdefault("prepared", {})
    return state


def write_state(state_dir, state):
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "state.json").write_text(
        json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def append_log(state_dir, lines):
    state_dir.mkdir(parents=True, exist_ok=True)
    with (state_dir / "depwatch.log").open("a", encoding="utf-8") as handle:
        for line in lines:
            handle.write(line + "\n")


def write_reports(state_dir, timestamp, report_text, findings):
    reports = state_dir / "reports"
    reports.mkdir(parents=True, exist_ok=True)
    (reports / ("%s.md" % timestamp)).write_text(report_text, encoding="utf-8")
    (reports / "latest.md").write_text(report_text, encoding="utf-8")
    (reports / "latest.json").write_text(
        json.dumps({"timestamp": timestamp, "findings": findings}, indent=2) + "\n",
        encoding="utf-8",
    )


def write_vault_note(repo, section):
    path = repo / VAULT_NOTE
    if path.exists():
        existing = path.read_text(encoding="utf-8")
    else:
        existing = default_vault_note()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(splice_vault_section(existing, section), encoding="utf-8")


def default_vault_note():
    return (
        "---\n"
        "note: What Kelpie depends on, what the daily watch checks, and what to do when one moves.\n"
        "---\n\n"
        "# Dependency watch\n\n"
        "[[Kelpie]] sits on top of things that move without asking: [[herdr]]'s socket API and CLI, "
        "[[Heeler upstream]], a vendored terminal engine, two pinned C libraries, a Node plugin and a "
        "Cloudflare Worker, Xcode itself, and a temporary App Review box.\n\n"
        "`scripts/depwatch.py` looks at all of them once a day at 05:45 and writes the table below. "
        "The full guide, including how to respond to each finding, is "
        "`docs/guides/dependency-watch.md`. Build commands live in [[Build and deploy]].\n\n"
        "## Last run\n\n"
    )


def write_briefing(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def local_date_string():
    return datetime.date.today().strftime("%Y-%m-%d")


# --- main -------------------------------------------------------------------


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description="Kelpie dependency watch")
    parser.add_argument("--dry-run", action="store_true", help="report to stdout, write nothing")
    parser.add_argument("--publish", action="store_true", help="open or update GitHub issues")
    parser.add_argument("--prepare", action="store_true", help="prepare mechanical fix branches")
    parser.add_argument("--check", nargs="+", metavar="ID", help="run only the named checks")
    parser.add_argument("--json", action="store_true", help="also print the findings JSON")
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR)
    parser.add_argument("--briefing-path", type=Path, default=DEFAULT_BRIEFING_PATH)
    parser.add_argument("--repo", type=Path, default=REPO_ROOT)
    parser.add_argument("--verbose", action="store_true", help="echo each command to stderr")
    return parser.parse_args(argv)


def main(argv=None):
    arguments = parse_arguments(argv)
    started = time.time()
    timestamp = utc_timestamp()
    now_iso = utc_iso()
    repo = arguments.repo.resolve()
    state_dir = arguments.state_dir.expanduser()

    state = load_state(state_dir)

    # A dry run must leave no trace, so its worktrees go to a temp directory
    # rather than the state dir (which it must not create).
    temp_worktrees = None
    if arguments.dry_run:
        temp_worktrees = Path(tempfile.mkdtemp(prefix="depwatch-dry-"))
        worktree_root = temp_worktrees
    else:
        worktree_root = state_dir / "worktrees"
        worktree_root.mkdir(parents=True, exist_ok=True)

    ctx = Context(
        repo=repo,
        state=state,
        state_dir=state_dir,
        worktree_root=worktree_root,
        dry_run=arguments.dry_run,
        verbose=arguments.verbose,
    )
    prune_worktrees(ctx)

    selected = [(cid, fn) for cid, fn in CHECKS if not arguments.check or cid in arguments.check]
    unknown = sorted(set(arguments.check or []) - {cid for cid, _ in CHECKS})
    if unknown:
        print("depwatch: unknown check(s): %s" % ", ".join(unknown), file=sys.stderr)

    findings = []
    for check_id, function in selected:
        findings.append(run_check(check_id, function, ctx))

    records = {}
    for finding in findings:
        records[finding["check"]] = mark_new(finding, state, now_iso)

    planned = []
    prepared_records = {}
    try:
        return finish_run(ctx, arguments, findings, records, planned, prepared_records, now_iso, timestamp, started)
    finally:
        # Worktrees the checks kept alive are removed unless --prepare owns them,
        # whatever happened in between (a raise in prepare or publish included).
        keep = arguments.prepare and prepared_records and not arguments.dry_run
        for finding in findings:
            path = (finding.get("data") or {}).get("worktree")
            if path and not keep:
                remove_worktree(ctx, Path(path))
        if temp_worktrees is not None:
            shutil.rmtree(temp_worktrees, ignore_errors=True)


def finish_run(ctx, arguments, findings, records, planned, prepared_records, now_iso, timestamp, started):
    repo = ctx.repo
    state = ctx.state
    state_dir = ctx.state_dir
    if arguments.prepare:
        for finding in findings:
            if finding["check"] != "herdr-release":
                continue
            if not finding["new"] or severity_rank(finding["severity"]) < severity_rank("medium"):
                planned.append(
                    "herdr-release: no preparation (finding is %s/%s)"
                    % (finding["severity"], "new" if finding["new"] else "repeat")
                )
                continue
            record = prepare_herdr_fix(ctx, finding, arguments.publish, arguments.dry_run, planned)
            if record:
                prepared_records[(finding.get("data") or {}).get("stable_tag")] = record

    if arguments.publish:
        publish_findings(ctx, findings, now_iso, arguments.dry_run, planned)

    duration = time.time() - started
    repo_sha = ctx.git(["rev-parse", "--short", "HEAD"], tolerate=True)["out"].strip() or "unknown"
    report_text = render_report(findings, timestamp, repo_sha, duration)
    counts = {
        "checks": len(findings),
        "new": sum(1 for f in findings if f["new"]),
        "high": sum(1 for f in findings if f["severity"] == "high"),
        "medium": sum(1 for f in findings if f["severity"] == "medium"),
    }
    publish_mode = "dry" if (arguments.publish and arguments.dry_run) else ("yes" if arguments.publish else "no")
    prepare_mode = "dry" if (arguments.prepare and arguments.dry_run) else ("yes" if arguments.prepare else "no")

    print(report_text)
    if ctx.notes:
        print("Notes:")
        for note in ctx.notes:
            print("- %s" % note)
    if planned:
        print("Would do:")
        for item in planned:
            print("- %s" % item)
    if arguments.json:
        print(json.dumps(findings, indent=2))

    if not arguments.dry_run:
        state["checks"].update(records)
        state["runs"] = cap_runs(
            list(state.get("runs") or [])
            + [
                {
                    "ts": now_iso,
                    "duration_s": round(duration, 1),
                    "checks": counts["checks"],
                    "new": counts["new"],
                    "high": counts["high"],
                    "medium": counts["medium"],
                    "publish": publish_mode,
                    "prepare": prepare_mode,
                }
            ]
        )
        for tag, record in prepared_records.items():
            if tag:
                state.setdefault("prepared", {})[tag] = record
        write_state(state_dir, state)
        write_reports(state_dir, timestamp, report_text, findings)
        append_log(
            state_dir,
            log_lines(findings, now_iso, counts, publish_mode, prepare_mode, duration),
        )
        write_vault_note(repo, render_vault_section(findings, timestamp))
        write_briefing(
            arguments.briefing_path.expanduser(), build_briefing(findings, local_date_string())
        )

        prune_worktrees(ctx)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
