#!/usr/bin/env python3
"""ghostty-override-diff.py — what a GhosttyTerminal re-vendor changes under Kelpie's feet.

Kelpie never edits the vendored package under Packages/GhosttyTerminal; it
subclasses UITerminalView (HeelerTerminalView, TerminalScreenView.swift) and
overrides the package's `open` members, calls its public API, and declares
members and protocol conformances of its own on the subclass. A new
libghostty-spm commit can silently break any of those: an override point
removed, renamed, closed (`open` → `public`), given a new signature or a new
body; a new upstream member or @objc selector with the same name as one of
Kelpie's (round 16: `handleEscapeKeyCommand`, `UIDropInteractionDelegate`,
`gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)`); a new conformance
Kelpie already declares itself. This script names every one before the build.

    python3 scripts/ghostty-override-diff.py                  # vendored copy vs upstream main
    python3 scripts/ghostty-override-diff.py --new 7e45d27    # vs a specific upstream ref
    python3 scripts/ghostty-override-diff.py --old kelpie:kelpie-pre-rebase-20260915 \
                                             --new kelpie:HEAD --kelpie-rev kelpie-pre-rebase-20260915
    python3 scripts/ghostty-override-diff.py --verbose        # also print body diffs

Sides:
  --old   default `worktree` (the vendored copy in this checkout). Also
          `kelpie:<rev>` (the vendored copy at a Kelpie commit) or any
          libghostty-spm ref.
  --new   default `main` of the bare libghostty-spm clone kept at
          $KELPIE_BUILD_CACHE/libghostty-spm.git (default
          ~/Library/Caches/kelpie-build), cloned on first use and fetched on
          every run unless --no-fetch. Also `kelpie:<rev>` or `worktree`.
  --kelpie-rev  read Kelpie's Sources/Heeler at a Kelpie commit instead of
          the checkout (for reproducing an old round).

Exit 0: nothing Kelpie relies on changed. Exit 1: findings (read them before
building). Exit 2: could not run. Stdlib only, /usr/bin/python3.
"""

import argparse
import difflib
import hashlib
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VENDORED = "Packages/GhosttyTerminal"
PKG_SOURCES = "Sources/GhosttyTerminal"
KELPIE_SOURCES = "Sources/Heeler"
UPSTREAM_URL = "https://github.com/Lakr233/libghostty-spm.git"
BASE_CLASS = "UITerminalView"

# Files whose wholesale change is worth a line even when no named member moved:
# these are the UIKit paths unit tests cannot reach (Testing status, round 20).
WATCHED_DIRS = ("Platform/UIKit/", "Platform/Shared/", "Surface/")


def die(msg):
    print("ghostty-override-diff: " + msg, file=sys.stderr)
    sys.exit(2)


def run(cmd, cwd=None, check=True):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and p.returncode != 0:
        die("%s failed: %s" % (" ".join(cmd), p.stderr.strip()))
    return p


# ---------------------------------------------------------------- sources

def cache_dir():
    return os.path.expanduser(os.environ.get("KELPIE_BUILD_CACHE", "~/Library/Caches/kelpie-build"))


def upstream_repo(fetch):
    repo = os.path.join(cache_dir(), "libghostty-spm.git")
    if not os.path.isdir(repo):
        os.makedirs(cache_dir(), exist_ok=True)
        print("cloning %s into %s" % (UPSTREAM_URL, repo), file=sys.stderr)
        run(["git", "clone", "--bare", "--quiet", UPSTREAM_URL, repo])
    elif fetch:
        p = run(["git", "fetch", "--quiet", "origin", "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"],
                cwd=repo, check=False)
        if p.returncode != 0:
            print("warning: fetch failed, using the clone as it is: %s" % p.stderr.strip(), file=sys.stderr)
    return repo


def git_tree_files(repo, rev, prefix):
    """{path relative to prefix: text} for every .swift file under prefix at rev."""
    p = run(["git", "ls-tree", "-r", "--name-only", rev, "--", prefix], cwd=repo, check=False)
    if p.returncode != 0:
        die("cannot read %s at %s in %s: %s" % (prefix, rev, repo, p.stderr.strip()))
    files = {}
    for path in p.stdout.split("\n"):
        if not path.endswith(".swift"):
            continue
        files[path[len(prefix):].lstrip("/")] = run(["git", "show", "%s:%s" % (rev, path)], cwd=repo).stdout
    if not files:
        die("no Swift files under %s at %s in %s" % (prefix, rev, repo))
    return files


def disk_tree_files(base):
    files = {}
    for dirpath, _, names in os.walk(base):
        for name in names:
            if name.endswith(".swift"):
                full = os.path.join(dirpath, name)
                with open(full, encoding="utf-8") as f:
                    files[os.path.relpath(full, base)] = f.read()
    if not files:
        die("no Swift files under %s" % base)
    return files


def package_files(side, fetch):
    """The vendored package's Sources/GhosttyTerminal for one side of the diff."""
    if side == "worktree":
        return disk_tree_files(os.path.join(ROOT, VENDORED, PKG_SOURCES)), "worktree (%s)" % VENDORED
    if side.startswith("kelpie:"):
        rev = side[len("kelpie:"):]
        short = run(["git", "rev-parse", "--short", rev], cwd=ROOT).stdout.strip()
        return git_tree_files(ROOT, rev, VENDORED + "/" + PKG_SOURCES), "kelpie %s (%s)" % (rev, short)
    repo = upstream_repo(fetch)
    short = run(["git", "rev-parse", "--short", side], cwd=repo, check=False)
    if short.returncode != 0:
        die("libghostty-spm has no ref %r (history rewritten? try kelpie:<rev> for the old side)" % side)
    return git_tree_files(repo, side, PKG_SOURCES), "libghostty-spm %s (%s)" % (side, short.stdout.strip())


def kelpie_files(rev):
    if rev is None:
        return disk_tree_files(os.path.join(ROOT, KELPIE_SOURCES))
    return git_tree_files(ROOT, rev, KELPIE_SOURCES)


# ---------------------------------------------------------------- parsing

def strip_noise(text):
    """Blank out comments and simple string literals so braces inside them do not count."""
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    text = re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), text)
    text = re.sub(r'"""(.*?)"""', lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', lambda m: " " * len(m.group(0)), text)
    return text


DECL_RE = re.compile(
    r"^(?P<indent>\s*)(?P<attrs>(?:@\w+(?:\([^)]*\))?\s+)*)"
    r"(?P<mods>(?:(?:open|public|internal|fileprivate|private|override|final|static|class|dynamic|"
    r"convenience|mutating|nonmutating|nonisolated|required|unowned|weak|lazy|optional)(?:\([^)]*\))?\s+)*)"
    r"(?P<kind>func|var|let|init|subscript)\b\s*(?P<name>[A-Za-z_]\w*)?")
TYPE_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:open|public|internal|fileprivate|private|final|indirect)\s+)*"
    r"(?P<kind>class|struct|enum|extension|protocol|actor)\s+(?P<name>[A-Za-z_][\w.]*)"
    r"(?:\s*<[^>]*>)?\s*(?::\s*(?P<conf>[^{]*?))?\s*(?:where[^{]*)?\{")


def labels_of(signature, kind):
    """Argument labels of a func/init signature: `position(from:offset:)`."""
    if kind not in ("func", "init", "subscript"):
        return ""
    m = re.search(r"\((.*)\)", signature, flags=re.S)
    if not m:
        return "()"
    depth, args, cur = 0, [], ""
    for ch in m.group(1):
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
        if ch == "," and depth == 0:
            args.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        args.append(cur)
    labels = []
    for a in args:
        head = a.strip().split(":")[0].strip().split()
        labels.append((head[0] if head else "_") + ":")
    return "(" + "".join(labels) + ")"


def body_span(lines, start):
    """(signature, body, end_line) for the declaration starting at lines[start]."""
    sig, i, brace_line = "", start, None
    while i < len(lines) and i < start + 12:
        line = lines[i]
        if "{" in line:
            sig += line[: line.index("{")]
            brace_line = i
            break
        sig += line + " "
        i += 1
        if i < len(lines) and (DECL_RE.match(lines[i]) or TYPE_RE.match(lines[i]) or lines[i].strip() == "}"):
            break
    if brace_line is None:
        return sig.strip(), None, start
    depth, j, body = 0, brace_line, []
    col = lines[brace_line].index("{")
    first = True
    while j < len(lines):
        line = lines[j] if not first else lines[j][col:]
        first = False
        for ch in line:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    body.append(line)
                    return sig.strip(), "\n".join(body), j
        body.append(line)
        j += 1
    return sig.strip(), "\n".join(body), j


def norm(text):
    text = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"\(\s+", "(", re.sub(r"\s+\)", ")", text))


class Member:
    __slots__ = ("file", "line", "kind", "name", "labels", "access", "attrs", "mods", "signature", "body", "owner")

    def __init__(self, **kw):
        for k in self.__slots__:
            setattr(self, k, kw.get(k))

    @property
    def key(self):
        return self.name + self.labels

    @property
    def body_hash(self):
        return hashlib.sha1(norm(self.body or "").encode()).hexdigest()[:10]

    def describe(self):
        acc = self.access or "internal"
        return "%s %s %s (%s:%d)" % (acc, self.kind, self.key, self.file, self.line)


def parse_file(path, text):
    """Members and type declarations in one Swift file.

    Returns (members, types) where members are the direct members of every
    type/extension body (nesting tracked by brace depth) and types are
    {(kind, name): [conformances]} for each declaration."""
    clean = strip_noise(text).split("\n")
    members, types = [], []
    stack = []  # (owner name, depth at which the body opened)
    depth = 0
    i = 0
    while i < len(clean):
        line = clean[i]
        tm = TYPE_RE.match(line)
        if tm:
            conf = [c.strip() for c in (tm.group("conf") or "").split(",") if c.strip()]
            types.append((tm.group("kind"), tm.group("name"), conf, i + 1))
            stack.append((tm.group("name"), depth))
            depth += line.count("{") - line.count("}")
            i += 1
            continue
        dm = DECL_RE.match(line)
        if dm and dm.group("name") is not None and stack and len(stack) == 1 and depth == stack[-1][1] + 1:
            sig, body, end = body_span(clean, i)
            mods = dm.group("mods").split()
            access = next((m for m in mods if m in ("open", "public", "internal", "fileprivate", "private")), None)
            members.append(Member(
                file=path, line=i + 1, kind=dm.group("kind"), name=dm.group("name"),
                labels=labels_of(sig, dm.group("kind")), access=access,
                attrs=norm(dm.group("attrs")), mods=" ".join(m for m in mods if m not in ("open", "public", "internal", "fileprivate", "private")),
                signature=norm(sig), body=body, owner=stack[-1][0]))
            # Skip the body so nested declarations (closures, local funcs) are not indexed.
            for k in range(i, end + 1):
                depth += clean[k].count("{") - clean[k].count("}")
            i = end + 1
            while stack and depth <= stack[-1][1]:
                stack.pop()
            continue
        depth += line.count("{") - line.count("}")
        while stack and depth <= stack[-1][1]:
            stack.pop()
        i += 1
    return members, types


def index_package(files):
    """Members of UITerminalView (class + extensions), every open/public member anywhere, conformances."""
    view_members, api, conformances, file_hashes = {}, {}, {}, {}
    for path in sorted(files):
        text = files[path]
        file_hashes[path] = hashlib.sha1(text.encode()).hexdigest()[:10]
        members, types = parse_file(path, text)
        for kind, name, conf, line in types:
            if name == BASE_CLASS and conf:
                for c in conf:
                    conformances.setdefault(c, []).append("%s:%d" % (path, line))
        for m in members:
            if m.owner == BASE_CLASS:
                view_members.setdefault(m.key, []).append(m)
            if m.access in ("open", "public"):
                api.setdefault((m.owner, m.key), []).append(m)
    return {"view": view_members, "api": api, "conformances": conformances, "files": file_hashes}


def kelpie_reliance(files):
    """What Kelpie's subclasses of UITerminalView override, declare, conform to, and call."""
    subclasses = set()
    all_types = {}
    parsed = {}
    for path in sorted(files):
        members, types = parse_file(path, files[path])
        parsed[path] = (members, types)
        for kind, name, conf, line in types:
            if kind == "class" and BASE_CLASS in conf:
                subclasses.add(name)
            all_types.setdefault(name, []).append((kind, conf, path, line))
    overrides, own, conformances = {}, {}, {}
    for path, (members, types) in parsed.items():
        for kind, name, conf, line in types:
            if name in subclasses and kind == "extension":
                for c in conf:
                    conformances.setdefault(c, []).append("%s:%d" % (path, line))
            if name in subclasses and kind == "class":
                for c in conf:
                    if c != BASE_CLASS:
                        conformances.setdefault(c, []).append("%s:%d" % (path, line))
        for m in members:
            if m.owner not in subclasses:
                continue
            target = overrides if "override" in (m.mods or "") else own
            target.setdefault(m.key, []).append(m)
    # Names that could also be @objc selectors / plain member names upstream may add.
    identifiers = set(re.findall(r"\b[A-Za-z_]\w*\b", strip_noise("\n".join(files.values()))))
    return {"subclasses": subclasses, "overrides": overrides, "own": own,
            "conformances": conformances, "identifiers": identifiers}


# ---------------------------------------------------------------- comparing

def first(members):
    return members[0] if members else None


def visible(m):
    """Visible from Kelpie's module: only open and public members can collide or be called."""
    return m.access in ("open", "public")


def compare(old, new, kelpie, verbose):
    findings, notes = [], []

    # 1. Override points: every member Kelpie overrides must still be an open member of UITerminalView.
    for key in sorted(kelpie["overrides"]):
        k = first(kelpie["overrides"][key])
        o, n = first(old["view"].get(key)), first(new["view"].get(key))
        where = "%s:%d" % (k.file, k.line)
        if o is None and n is None:
            # Inherited from UIKit (touchesBegan, becomeFirstResponder, ...): nothing upstream to break,
            # unless upstream *starts* overriding it, which the "new upstream override" pass below catches.
            continue
        if n is None:
            findings.append(("REMOVED", "%s: Kelpie overrides it at %s; %s had it as %s" % (key, where, "old", o.describe())))
            continue
        if o is None:
            findings.append(("NEW UPSTREAM OVERRIDE", "%s: upstream now declares %s; Kelpie's override at %s used to reach UIKit directly, now it reaches upstream's body (check super calls)" % (key, n.describe(), where)))
            continue
        if n.access != "open" and o.access == "open":
            findings.append(("CLOSED", "%s: was open, now %s (%s); Kelpie's override at %s will not compile" % (key, n.access or "internal", n.describe(), where)))
        elif n.access != "open":
            findings.append(("NOT OPEN", "%s: %s is not open on either side yet Kelpie overrides it at %s" % (key, n.describe(), where)))
        if o.signature != n.signature:
            findings.append(("SIGNATURE", "%s at %s\n      old: %s\n      new: %s" % (key, n.file, o.signature, n.signature)))
        elif o.body_hash != n.body_hash:
            findings.append(("BODY", "%s: upstream's implementation changed (%s:%d → %s:%d); Kelpie calls super here" % (
                key, o.file, o.line, n.file, n.line) if ("super." + k.name) in (k.body or "") else
                "%s: upstream's implementation changed (%s:%d → %s:%d); Kelpie replaces it without super, so behaviour Kelpie skips may have moved" % (
                key, o.file, o.line, n.file, n.line)))
            if verbose:
                findings.append(("", body_diff(o, n)))

    # 2. Collisions: a new upstream UITerminalView member with the same name as one Kelpie declares itself.
    for key in sorted(kelpie["own"]):
        k = first(kelpie["own"][key])
        if key in new["view"] and key not in old["view"]:
            n = first(new["view"][key])
            if visible(n) or "@objc" in (n.attrs or "") or "@objc" in (k.attrs or ""):
                findings.append(("COLLISION", "%s: Kelpie declares it at %s:%d without override; upstream now has %s" % (key, k.file, k.line, n.describe())))
            else:
                notes.append("shadow: Kelpie's %s (%s:%d) now has an invisible upstream twin, %s" % (key, k.file, k.line, n.describe()))
        else:
            # Same base name, different labels: an @objc selector clash or an overload ambiguity.
            for nk, nms in new["view"].items():
                if nk != key and nms[0].name == k.name and nk not in old["view"] and (visible(nms[0]) or "@objc" in (nms[0].attrs or "")):
                    findings.append(("NAME CLASH", "%s vs upstream's new %s (Kelpie at %s:%d)" % (key, nms[0].describe(), k.file, k.line)))
    # An upstream @objc selector Kelpie also uses by name (round 16's handleEscapeKeyCommand).
    for key, nms in new["view"].items():
        n = nms[0]
        if key in old["view"] or "@objc" not in (n.attrs or ""):
            continue
        if n.name in kelpie["identifiers"] and key not in kelpie["own"] and key not in kelpie["overrides"]:
            findings.append(("SELECTOR", "upstream added @objc %s; the name appears in Kelpie's sources and would clash as a selector" % n.describe()))

    # 3. Conformances: upstream now conforms UITerminalView to a protocol Kelpie also declares on its subclass.
    for proto in sorted(kelpie["conformances"]):
        if proto in new["conformances"] and proto not in old["conformances"]:
            findings.append(("CONFORMANCE", "%s: upstream now conforms UITerminalView (%s); Kelpie's own conformance at %s is redundant and its members collide" % (
                proto, ", ".join(new["conformances"][proto]), ", ".join(kelpie["conformances"][proto]))))
    for proto in sorted(new["conformances"]):
        if proto not in old["conformances"] and proto not in kelpie["conformances"]:
            notes.append("upstream UITerminalView newly conforms to %s (%s)" % (proto, ", ".join(new["conformances"][proto])))
    for proto in sorted(old["conformances"]):
        if proto not in new["conformances"]:
            notes.append("upstream UITerminalView no longer conforms to %s" % proto)

    # 4. Public API Kelpie calls (sendKey, sendMousePos, acquireProgrammaticFocus, ...).
    used = {}
    for (owner, key), ms in old["api"].items():
        m = ms[0]
        if owner in kelpie["subclasses"] or key in kelpie["overrides"]:
            continue
        # The member name and its owner type must both appear in Kelpie's sources (UITerminalView's
        # members count as reachable through the subclass).
        owner_named = owner == BASE_CLASS or owner in kelpie["identifiers"]
        if owner_named and m.name in kelpie["identifiers"]:
            used[(owner, key)] = m
    for owner, key in sorted(used):
        o, ns = used[(owner, key)], new["api"].get((owner, key))
        if not ns:
            findings.append(("API REMOVED", "%s.%s (%s) is gone; Kelpie's sources use the name" % (owner, key, o.describe())))
            continue
        n = ns[0]
        if o.signature != n.signature:
            findings.append(("API SIGNATURE", "%s.%s\n      old: %s\n      new: %s" % (owner, key, o.signature, n.signature)))
        elif o.body_hash != n.body_hash:
            notes.append("API body changed: %s.%s (%s:%d)" % (owner, key, n.file, n.line))

    # 5. Members upstream added to UITerminalView (context for anything it now does that Kelpie used to).
    added = [new["view"][k][0] for k in new["view"] if k not in old["view"]]
    removed = [old["view"][k][0] for k in old["view"] if k not in new["view"]]
    if added:
        notes.append("upstream added %d UITerminalView member(s): %s" % (len(added), ", ".join(sorted(m.key for m in added))))
    if removed:
        notes.append("upstream removed %d UITerminalView member(s): %s" % (len(removed), ", ".join(sorted(m.key for m in removed))))

    # 6. File-level churn on the UIKit paths.
    for d in WATCHED_DIRS:
        o = {p for p in old["files"] if p.startswith(d)}
        n = {p for p in new["files"] if p.startswith(d)}
        changed = sorted(p for p in o & n if old["files"][p] != new["files"][p])
        parts = []
        if n - o:
            parts.append("added " + ", ".join(sorted(p[len(d):] for p in n - o)))
        if o - n:
            parts.append("removed " + ", ".join(sorted(p[len(d):] for p in o - n)))
        if changed:
            parts.append("changed " + ", ".join(p[len(d):] for p in changed))
        if parts:
            notes.append("%s %s" % (d, "; ".join(parts)))
    return findings, notes


def body_diff(o, n):
    diff = difflib.unified_diff((o.body or "").split("\n"), (n.body or "").split("\n"),
                                fromfile="old %s:%d" % (o.file, o.line), tofile="new %s:%d" % (n.file, n.line), lineterm="", n=2)
    return "\n".join("      " + l for l in diff)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog="\n".join(__doc__.split("\n\n")[1:]))
    ap.add_argument("--old", default="worktree", help="vendored side: worktree (default), kelpie:<rev>, or a libghostty-spm ref")
    ap.add_argument("--new", default="main", help="candidate side: a libghostty-spm ref (default main), kelpie:<rev>, or worktree")
    ap.add_argument("--kelpie-rev", default=None, help="read Sources/Heeler at this Kelpie commit instead of the checkout")
    ap.add_argument("--no-fetch", action="store_true", help="do not fetch the upstream clone first")
    ap.add_argument("--verbose", "-v", action="store_true", help="print unified diffs of changed override bodies")
    args = ap.parse_args()

    old_files, old_label = package_files(args.old, fetch=not args.no_fetch)
    new_files, new_label = package_files(args.new, fetch=not args.no_fetch)
    kelpie = kelpie_reliance(kelpie_files(args.kelpie_rev))
    if not kelpie["subclasses"]:
        die("no class in %s subclasses %s" % (KELPIE_SOURCES, BASE_CLASS))

    old, new = index_package(old_files), index_package(new_files)
    findings, notes = compare(old, new, kelpie, args.verbose)

    print("GhosttyTerminal override-point diff")
    print("  old: %s" % old_label)
    print("  new: %s" % new_label)
    print("  Kelpie: %s (%s) — %d override point(s), %d own member(s), %d conformance(s)" % (
        ", ".join(sorted(kelpie["subclasses"])), args.kelpie_rev or "checkout",
        len(kelpie["overrides"]), len(kelpie["own"]), len(kelpie["conformances"])))
    print()
    real = [f for f in findings if f[0]]
    if real:
        print("%d finding(s) to read before the build:" % len(real))
        for tag, text in findings:
            print(("  - [%s] %s" % (tag, text)) if tag else text)
    else:
        print("No override point, collision, conformance or public API Kelpie relies on changed.")
    if notes:
        print()
        print("Context:")
        for n in notes:
            print("  - " + n)
    sys.exit(1 if real else 0)


if __name__ == "__main__":
    main()
