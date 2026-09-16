#!/usr/bin/env python3
"""Cut a redacted Claude Code transcript fixture from real transcript files.

Kelpie Chat (ADR 0019) parses `~/.claude/projects/<cwd>/<session>.jsonl`.
The format is Claude Code's own and unversioned in shape, so the parser's
fixture is cut from real lines, not written by hand, and re-cut with this
script when the format moves. Every envelope key is kept; only bodies are
replaced.

Selection: the first tool-using turn of the first file (a `user` prompt
through its `system turn_duration`, kept contiguous so ordering assertions
hold), then the first line of every (type, subtype, content shape, is_error,
isMeta) combination not yet covered, from every file given, in order.

Redaction: text bodies become numbered placeholders, thinking is emptied,
signatures and request ids are constants, tool inputs keep their keys with
shortened values, images become one 1x1 PNG, attachments keep only their
kind, session ids become one fixed UUID, and the home directory is rewritten
in every string. Check the output with `grep -c <your username>`: it must
print 0.

Usage:
    scripts/cut-transcript-fixture.py FILE.jsonl [FILE.jsonl ...] > Tests/Fixtures/claude-transcript-v1.jsonl
"""

import json
import os
import sys

SESSION_ID = "00000000-0000-4000-8000-000000000000"
HOME = os.path.expanduser("~")
FAKE_HOME = "/Users/kelpie"
# Claude Code's project-directory encoding of the home path (every
# non-alphanumeric character becomes "-"), so encoded paths are rewritten too.
ENCODED_HOME = "".join(c if c.isalnum() else "-" for c in HOME)
ENCODED_FAKE_HOME = "".join(c if c.isalnum() else "-" for c in FAKE_HOME)
# A 1x1 opaque red PNG.
PNG_1X1 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/"
    "q842iQAAAABJRU5ErkJggg=="
)

counter = {"text": 0}


def placeholder(kind):
    counter["text"] += 1
    return f"<{kind} {counter['text']}>"


def shape_key(line):
    t = line.get("type")
    key = [t]
    if t == "system":
        key.append(line.get("subtype"))
    if t in ("user", "assistant"):
        content = (line.get("message") or {}).get("content")
        if isinstance(content, str):
            key.append("string")
        elif isinstance(content, list):
            parts = []
            for block in content:
                bt = block.get("type")
                if bt == "tool_result":
                    inner = block.get("content")
                    if isinstance(inner, list):
                        inner_types = ",".join(sorted({b.get("type", "?") for b in inner}))
                    else:
                        inner_types = "string"
                    parts.append(f"tool_result[{inner_types}]:err={block.get('is_error')}")
                else:
                    parts.append(bt or "?")
            key.append("+".join(sorted(set(parts))))
        key.append(f"meta={line.get('isMeta')}")
    return tuple(key)


def redact_block(block):
    bt = block.get("type")
    if bt == "text":
        block["text"] = placeholder("text")
    elif bt == "thinking":
        block["thinking"] = ""
        if "signature" in block:
            block["signature"] = "<sig>"
    elif bt == "tool_use":
        inp = block.get("input")
        if isinstance(inp, dict):
            block["input"] = {
                k: (v[:60] if isinstance(v, str) else v if isinstance(v, (int, float, bool)) or v is None else placeholder("input"))
                for k, v in inp.items()
            }
    elif bt == "tool_result":
        inner = block.get("content")
        if isinstance(inner, str):
            block["content"] = placeholder("result")
        elif isinstance(inner, list):
            for part in inner:
                redact_block(part)
    elif bt == "image":
        source = block.get("source") or {}
        source["data"] = PNG_1X1
        source["media_type"] = "image/png"
        block["source"] = source
    return block


def redact(line):
    t = line.get("type")
    msg = line.get("message")
    if isinstance(msg, dict):
        content = msg.get("content")
        if isinstance(content, str):
            msg["content"] = placeholder("prompt")
        elif isinstance(content, list):
            for block in content:
                redact_block(block)
    if t == "attachment":
        att = line.get("attachment") or {}
        line["attachment"] = {"type": att.get("type")}
        line["rendered"] = []
    if t == "last-prompt":
        line["lastPrompt"] = placeholder("prompt")
    if t == "queue-operation":
        line["content"] = placeholder("queued")
    if t == "system" and isinstance(line.get("content"), str):
        line["content"] = placeholder("system")
    if t == "ai-title":
        line["aiTitle"] = "Fixture session title"
    if t == "agent-name":
        line["agentName"] = "fixture-agent"
    if "toolUseResult" in line:
        line["toolUseResult"] = {}
    if "wireToolInputs" in line:
        line["wireToolInputs"] = {}
    if "requestId" in line:
        line["requestId"] = "req_redacted"
    if "slug" in line:
        line["slug"] = "fixture-slug"
    for key in ("sessionId", "session_id"):
        if key in line:
            line[key] = SESSION_ID
    if t in ("file-history-snapshot", "file-history-delta"):
        if "snapshot" in line:
            line["snapshot"] = {}
        if "backup" in line:
            line["backup"] = {}
    return rewrite_home(line)


def rewrite_home(value):
    if isinstance(value, str):
        return value.replace(HOME, FAKE_HOME).replace(ENCODED_HOME, ENCODED_FAKE_HOME)
    if isinstance(value, list):
        return [rewrite_home(v) for v in value]
    if isinstance(value, dict):
        return {k: rewrite_home(v) for k, v in value.items()}
    return value


def first_tool_turn(lines):
    """Indices of the first `user` prompt through its `turn_duration`, if a
    tool call happens in between."""
    start = None
    for i, line in enumerate(lines):
        t = line.get("type")
        content = (line.get("message") or {}).get("content")
        if t == "user" and isinstance(content, str) and not line.get("isMeta"):
            start = i
        elif t == "system" and line.get("subtype") == "turn_duration" and start is not None:
            turn = lines[start : i + 1]
            has_tool = any(
                b.get("type") == "tool_use"
                for l in turn
                if l.get("type") == "assistant"
                for b in ((l.get("message") or {}).get("content") or [])
                if isinstance(b, dict)
            )
            if has_tool:
                return list(range(start, i + 1))
            start = None
    return []


def main(paths):
    seen = set()
    out = []
    for n, path in enumerate(paths):
        with open(path, encoding="utf-8") as f:
            lines = [json.loads(l) for l in f if l.strip()]
        chosen = first_tool_turn(lines) if n == 0 else []
        for i in chosen:
            seen.add(shape_key(lines[i]))
            out.append(lines[i])
        for i, line in enumerate(lines):
            key = shape_key(line)
            if key in seen or i in chosen:
                continue
            seen.add(key)
            out.append(line)
    for line in out:
        sys.stdout.write(json.dumps(redact(line), separators=(",", ":")) + "\n")
    sys.stderr.write(f"{len(out)} lines, {len(seen)} shapes\n")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        sys.exit(2)
    main(sys.argv[1:])
