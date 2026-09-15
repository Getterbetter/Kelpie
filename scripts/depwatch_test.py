#!/usr/bin/env python3
"""Unit tests for the pure half of scripts/depwatch.py.

No network, no git, no gh: every function under test takes data and returns
data. Run with scripts/test-depwatch.sh (which is what CI and `make` would
call) or directly:

    /usr/bin/python3 -m unittest discover -s scripts -p 'depwatch_test.py'
"""

from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS.parent
FIXTURES = SCRIPTS / "fixtures" / "depwatch"

sys.path.insert(0, str(SCRIPTS))

import depwatch  # noqa: E402


def load_fixture(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def real_schema():
    return json.loads((SCRIPTS / "herdr-schema.json").read_text(encoding="utf-8"))


def schema_variant(base):
    """The committed snapshot with one method removed, one added, one changed,
    and `protocol` bumped.

    Generated here rather than committed: a second copy of a 275 KB schema
    would be a fixture nobody could review.
    """
    variant = copy.deepcopy(base)
    variant["protocol"] = int(base["protocol"]) + 1

    request = variant["schemas"]["request"]
    one_of = request["oneOf"]
    removed = one_of.pop(0)["properties"]["method"]["const"]
    changed = one_of[0]["properties"]["method"]["const"]
    one_of[0]["properties"]["depwatch_marker"] = {"type": "string"}
    added = "depwatch.invented"
    one_of.append(
        {
            "properties": {
                "method": {"const": added, "type": "string"},
                "params": {"$ref": "#/schemas/request/$defs/EmptyParams"},
            },
            "required": ["method", "params"],
            "type": "object",
        }
    )

    kinds = variant["schemas"]["event"]["$defs"]["EventKind"]["enum"]
    removed_kind = kinds.pop(0)
    kinds.append("depwatch_invented")
    return variant, {
        "removed_method": removed,
        "changed_method": changed,
        "added_method": added,
        "removed_kind": removed_kind,
    }


class SemverTests(unittest.TestCase):
    def test_parses_tagged_and_bare_versions(self):
        self.assertEqual(depwatch.parse_semver("v0.9.0"), (0, 9, 0))
        self.assertEqual(depwatch.parse_semver("0.8.2"), (0, 8, 2))

    def test_rejects_non_versions(self):
        for tag in [
            "preview-2026-09-08-62431dbd033b",
            "upstream.1.3.1",
            "v0.9",
            "v0.9.0-rc1",
            "",
            None,
        ]:
            self.assertIsNone(depwatch.parse_semver(tag), tag)

    def test_dated_ghostty_tags_parse_but_are_never_compared_this_way(self):
        # `1.6.20260909` is shaped like a version, which is exactly why the
        # libghostty check orders releases by publication date instead.
        self.assertEqual(depwatch.parse_semver("1.6.20260909"), (1, 6, 20260909))

    def test_newer_only_between_two_real_versions(self):
        self.assertTrue(depwatch.semver_is_newer("v0.9.1", "v0.9.0"))
        self.assertTrue(depwatch.semver_is_newer("v0.10.0", "v0.9.9"))
        self.assertFalse(depwatch.semver_is_newer("v0.9.0", "v0.9.0"))
        self.assertFalse(depwatch.semver_is_newer("v0.8.2", "v0.9.0"))
        self.assertFalse(
            depwatch.semver_is_newer("preview-2026-09-08-62431dbd033b", "v0.9.0")
        )

    def test_latest_stable_skips_prereleases(self):
        releases = load_fixture("gh-herdr-releases.json")
        self.assertEqual(
            depwatch.latest_stable_release(releases)["tag_name"], "v0.9.0"
        )
        self.assertTrue(
            depwatch.latest_prerelease(releases)["tag_name"].startswith("preview-")
        )


class SchemaDriftTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = real_schema()
        cls.variant, cls.marks = schema_variant(cls.base)

    def test_snapshot_shape_matches_the_documented_counts(self):
        # CLAUDE.md: the 0.9.0 snapshot declares 102 request methods and
        # 26 event kinds, with 3 pane-scoped subscription kinds.
        self.assertEqual(len(depwatch.schema_methods(self.base)), 102)
        self.assertEqual(len(depwatch.schema_event_kinds(self.base)), 26)
        self.assertEqual(len(depwatch.schema_subscription_event_kinds(self.base)), 3)

    def test_identical_schemas_have_no_drift(self):
        drift = depwatch.schema_drift(self.base, copy.deepcopy(self.base))
        self.assertTrue(drift["identical"])
        self.assertFalse(drift["protocol_changed"])
        for group in ("methods", "events", "subscription_events"):
            for bucket in ("added", "removed", "changed"):
                self.assertEqual(drift[group][bucket], [], "%s/%s" % (group, bucket))

    def test_variant_drift_is_reported_exactly(self):
        drift = depwatch.schema_drift(self.base, self.variant)
        self.assertTrue(drift["protocol_changed"])
        self.assertEqual(drift["protocol_old"], self.base["protocol"])
        self.assertEqual(drift["protocol_new"], self.base["protocol"] + 1)
        self.assertEqual(drift["methods"]["removed"], [self.marks["removed_method"]])
        self.assertEqual(drift["methods"]["added"], [self.marks["added_method"]])
        self.assertEqual(drift["methods"]["changed"], [self.marks["changed_method"]])
        self.assertEqual(drift["events"]["removed"], [self.marks["removed_kind"]])
        self.assertEqual(drift["events"]["added"], ["depwatch_invented"])
        self.assertFalse(drift["identical"])

    def test_diff_maps_on_plain_dicts(self):
        drift = depwatch.diff_maps(
            {"keep": {"a": 1}, "gone": {}, "moved": {"a": 1}},
            {"keep": {"a": 1}, "moved": {"a": 2}, "fresh": {}},
        )
        self.assertEqual(drift, {"added": ["fresh"], "removed": ["gone"], "changed": ["moved"]})


class CrossReferenceTests(unittest.TestCase):
    def setUp(self):
        self.text = (FIXTURES / "sources-sample.swift").read_text(encoding="utf-8")

    def test_used_methods_are_the_string_literals(self):
        self.assertEqual(
            depwatch.used_methods(self.text),
            ["agent.list", "pane.read", "ping", "session.snapshot"],
        )

    def test_real_sources_declare_the_eighteen_methods(self):
        text = depwatch.sources_text(REPO_ROOT)
        methods = depwatch.used_methods(text)
        self.assertEqual(len(methods), 18)
        self.assertIn("events.subscribe", methods)

    def test_event_kinds_match_either_spelling(self):
        kinds = depwatch.used_event_kinds(
            self.text,
            ["pane_updated", "pane.agent_status_changed", "workspace_created"],
        )
        self.assertEqual(kinds, ["pane.agent_status_changed", "pane_updated"])

    def test_cross_reference_keeps_only_what_kelpie_uses(self):
        drift = {
            "methods": {"added": ["x.new"], "removed": ["agent.list"], "changed": ["tab.create"]},
            "events": {"added": [], "removed": ["pane_updated"], "changed": []},
            "subscription_events": {"added": [], "removed": [], "changed": []},
        }
        breaking = depwatch.cross_reference_drift(
            drift, ["agent.list", "ping"], ["pane_updated"]
        )
        self.assertEqual(breaking["methods"], ["agent.list"])
        self.assertEqual(breaking["kinds"], ["pane_updated"])


class SeverityTests(unittest.TestCase):
    def _drift(self, **overrides):
        drift = {
            "protocol_changed": False,
            "identical": False,
            "methods": {"added": [], "removed": [], "changed": []},
            "events": {"added": [], "removed": [], "changed": []},
            "subscription_events": {"added": [], "removed": [], "changed": []},
        }
        drift.update(overrides)
        return drift

    def test_herdr_release_severities(self):
        none_breaking = {"methods": [], "kinds": []}
        self.assertEqual(
            depwatch.herdr_release_severity(False, None, none_breaking), "info"
        )
        self.assertEqual(
            depwatch.herdr_release_severity(
                True, self._drift(identical=True), none_breaking
            ),
            "low",
        )
        self.assertEqual(
            depwatch.herdr_release_severity(
                True, self._drift(protocol_changed=True), none_breaking
            ),
            "high",
        )
        self.assertEqual(
            depwatch.herdr_release_severity(
                True, self._drift(), {"methods": ["agent.list"], "kinds": []}
            ),
            "high",
        )
        added_only = self._drift(
            methods={"added": ["x.new"], "removed": [], "changed": []}
        )
        self.assertEqual(
            depwatch.herdr_release_severity(True, added_only, none_breaking), "medium"
        )
        self.assertEqual(
            depwatch.herdr_release_severity(True, None, none_breaking), "medium"
        )

    def test_upstream_severities(self):
        self.assertEqual(depwatch.upstream_severity(0, [], []), "info")
        self.assertEqual(depwatch.upstream_severity(14, [], []), "low")
        self.assertEqual(depwatch.upstream_severity(14, [], ["CHANGELOG.md"]), "medium")
        self.assertEqual(depwatch.upstream_severity(14, ["CHANGELOG.md"], []), "medium")
        self.assertEqual(
            depwatch.upstream_severity(14, ["Sources/Heeler/App.swift"], []), "high"
        )
        self.assertEqual(depwatch.upstream_severity(3, ["project.yml"], []), "high")
        self.assertEqual(
            depwatch.upstream_severity(3, ["Packages/HeelerSSH/Sources.lock"], []), "high"
        )

    def test_ssh_pin_severities(self):
        self.assertEqual(depwatch.ssh_pins_severity(["GHSA-x"], False), "high")
        self.assertEqual(depwatch.ssh_pins_severity([], True), "low")
        self.assertEqual(depwatch.ssh_pins_severity([], False), "info")

    def test_node_severities(self):
        self.assertEqual(depwatch.node_severity({"critical": 1}), "high")
        self.assertEqual(depwatch.node_severity({"high": 2, "moderate": 5}), "high")
        self.assertEqual(depwatch.node_severity({"moderate": 1}), "medium")
        self.assertEqual(depwatch.node_severity({"low": 9, "info": 3}), "info")
        counts = load_fixture("npm-audit-plugin.json")["metadata"]["vulnerabilities"]
        self.assertEqual(depwatch.node_severity(counts), "info")

    def test_toolchain_severities(self):
        self.assertEqual(depwatch.toolchain_severity(False, 26, 26), "info")
        self.assertEqual(depwatch.toolchain_severity(True, 26, 26), "low")
        self.assertEqual(depwatch.toolchain_severity(False, 15, 26), "medium")
        self.assertEqual(depwatch.toolchain_severity(True, None, 26), "low")

    def test_ci_fork_severities(self):
        self.assertEqual(depwatch.ci_fork_severity(False, None), "high")
        self.assertEqual(depwatch.ci_fork_severity(True, "failure"), "medium")
        self.assertEqual(depwatch.ci_fork_severity(True, "success"), "info")

    def test_relay_severities(self):
        # The Worker 404s every path but /push, so 404 is healthy.
        self.assertEqual(depwatch.relay_severity(404, None), "info")
        self.assertEqual(depwatch.relay_severity(200, None), "info")
        self.assertEqual(depwatch.relay_severity(503, None), "high")
        self.assertEqual(depwatch.relay_severity(None, "URLError: timed out"), "high")


class PinParsingTests(unittest.TestCase):
    def test_shell_assignments_and_ghostty_tag(self):
        script = (REPO_ROOT / "scripts" / "fetch-ghostty-artifact.sh").read_text(
            encoding="utf-8"
        )
        pins = depwatch.parse_shell_assignments(script)
        self.assertTrue(pins["URL"].startswith("https://github.com/Lakr233/libghostty-spm/"))
        self.assertEqual(len(pins["SHA"]), 64)
        # The pin moves with every re-vendor (round 16 took it from upstream.1.3.1 to
        # upstream.82938b633ba6); assert the shape, and the exact value against a fixture.
        self.assertRegex(depwatch.ghostty_tag_from_url(pins["URL"]), r"^upstream\.[0-9a-f.]+$")
        self.assertEqual(
            depwatch.ghostty_tag_from_url(
                "https://github.com/Lakr233/libghostty-spm/releases/download/upstream.1.3.1/GhosttyKit.xcframework.zip"
            ),
            "upstream.1.3.1",
        )

    def test_sources_lock_parses(self):
        lock = depwatch.parse_shell_assignments(
            (REPO_ROOT / "Packages" / "HeelerSSH" / "Sources.lock").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(len(lock["LIBSSH2_COMMIT"]), 40)
        self.assertEqual(depwatch.openssl_line(lock["OPENSSL_VERSION"]), "3.6")

    def test_newest_release_per_family(self):
        families = depwatch.newest_release_per_family(
            load_fixture("gh-ghostty-releases.json")
        )
        self.assertTrue(families["upstream"]["tag_name"].startswith("upstream."))
        self.assertFalse(families["dated"]["tag_name"].startswith("upstream."))

    def test_openssl_line_selection_ignores_other_lines(self):
        releases = load_fixture("gh-openssl-releases.json")
        in_line = depwatch.openssl_releases_in_line(releases, "3.6")
        self.assertTrue(in_line)
        self.assertEqual(in_line[0]["tag_name"], "openssl-3.6.4")
        for release in in_line:
            self.assertTrue(release["tag_name"].startswith("openssl-3.6."))
        self.assertEqual(depwatch.openssl_releases_in_line(releases, None), [])

    def test_advisories_after_the_pin_date(self):
        advisories = [
            {"ghsa_id": "GHSA-old", "published_at": "2026-01-01T00:00:00Z"},
            {"ghsa_id": "GHSA-new", "published_at": "2026-09-01T00:00:00Z"},
            {"ghsa_id": "GHSA-undated", "published_at": None},
        ]
        after = depwatch.advisories_after(advisories, "2026-06-09T11:51:12Z")
        self.assertEqual(
            [a["ghsa_id"] for a in after], ["GHSA-new", "GHSA-undated"]
        )
        self.assertEqual(len(depwatch.advisories_after(advisories, None)), 3)

    def test_toolchain_version_parsing(self):
        self.assertEqual(depwatch.parse_xcode_major("Xcode 26.4.1"), 26)
        self.assertIsNone(depwatch.parse_xcode_major("Build version 17E202"))
        workflow = (REPO_ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )
        self.assertEqual(depwatch.parse_runner_major(workflow), 26)


class FingerprintTests(unittest.TestCase):
    def setUp(self):
        self.state = load_fixture("state.json")

    def test_unchanged_fingerprint_is_a_repeat_and_keeps_first_seen(self):
        finding = depwatch.make_finding(
            check="herdr-release",
            severity="info",
            fingerprint="v0.9.0|v0.9.0",
            title="herdr v0.9.0, snapshot current",
            summary="",
        )
        record = depwatch.mark_new(finding, self.state, "2026-09-12T05:45:00Z")
        self.assertFalse(finding["new"])
        self.assertEqual(record["first_seen"], "2026-09-10T05:45:02Z")
        self.assertEqual(record["last_seen"], "2026-09-12T05:45:00Z")

    def test_changed_fingerprint_is_new_and_resets_first_seen(self):
        finding = depwatch.make_finding(
            check="herdr-release",
            severity="high",
            fingerprint="v0.9.1|v0.9.0|23",
            title="herdr v0.9.1: protocol 22 -> 23",
            summary="",
            data={"stable_tag": "v0.9.1"},
        )
        record = depwatch.mark_new(finding, self.state, "2026-09-12T05:45:00Z")
        self.assertTrue(finding["new"])
        self.assertEqual(record["first_seen"], "2026-09-12T05:45:00Z")
        # Per-check data merges rather than replacing what the state held.
        self.assertEqual(record["data"]["snapshot_tag"], "v0.9.0")
        self.assertEqual(record["data"]["stable_tag"], "v0.9.1")

    def test_a_check_absent_from_state_is_new(self):
        finding = depwatch.make_finding(
            check="relay", severity="info", fingerprint="healthy|404", title="", summary=""
        )
        depwatch.mark_new(finding, self.state, "2026-09-12T05:45:00Z")
        self.assertTrue(finding["new"])

    def test_run_history_is_capped(self):
        runs = [{"ts": index} for index in range(45)]
        capped = depwatch.cap_runs(runs)
        self.assertEqual(len(capped), depwatch.RUN_HISTORY_LIMIT)
        self.assertEqual(capped[-1]["ts"], 44)
        self.assertEqual(capped[0]["ts"], 45 - depwatch.RUN_HISTORY_LIMIT)
        self.assertEqual(depwatch.cap_runs(self.state["runs"]), self.state["runs"])
        self.assertEqual(depwatch.cap_runs([]), [])


class RenderingTests(unittest.TestCase):
    def finding(self, **overrides):
        base = depwatch.make_finding(
            check="heeler-upstream",
            severity="medium",
            fingerprint="abc123",
            title="14 commits behind, 2 conflicting files",
            summary="Upstream moved.",
            evidence=["one", "two", "three", "four"],
            lane="manual",
            actions=["first action", "second action"],
        )
        base.update(overrides)
        return base

    def test_issue_title_builder(self):
        self.assertEqual(
            depwatch.issue_title("heeler-upstream", "14 commits behind, 2 conflicting files"),
            "depwatch: heeler-upstream: 14 commits behind, 2 conflicting files",
        )

    def test_report_carries_table_and_sections(self):
        findings = [self.finding(new=True)]
        report = depwatch.render_report(findings, "2026-09-12T05-45-00Z", "abc1234", 12.3)
        self.assertIn("| `heeler-upstream` | medium | new |", report)
        self.assertIn("## heeler-upstream — 14 commits behind", report)
        self.assertIn("1. first action", report)
        self.assertIn("- Repo: `abc1234`", report)

    def test_issue_body_names_the_script_and_fingerprint(self):
        body = depwatch.render_issue_body(self.finding(new=True), "2026-09-12T05:45:00Z")
        self.assertIn("**Lane**: `manual`", body)
        self.assertIn("scripts/depwatch.py", body)
        self.assertIn("abc123", body)

    def test_vault_splice_keeps_the_prose_on_both_sides(self):
        existing = (FIXTURES / "vault-note-sample.md").read_text(encoding="utf-8")
        section = depwatch.render_vault_section([self.finding(new=True)], "2026-09-12T05-45-00Z")
        spliced = depwatch.splice_vault_section(existing, section)
        self.assertIn("Hand-written prose the watcher must never touch.", spliced)
        self.assertIn("Also hand-written, also untouched.", spliced)
        self.assertNotIn("stale generated content", spliced)
        self.assertIn("14 commits behind", spliced)
        self.assertEqual(spliced.count(depwatch.VAULT_BEGIN), 1)
        self.assertEqual(spliced.count(depwatch.VAULT_END), 1)

    def test_vault_splice_is_idempotent(self):
        existing = (FIXTURES / "vault-note-sample.md").read_text(encoding="utf-8")
        section = depwatch.render_vault_section([self.finding(new=True)], "2026-09-12T05-45-00Z")
        once = depwatch.splice_vault_section(existing, section)
        twice = depwatch.splice_vault_section(once, section)
        self.assertEqual(once, twice)

    def test_vault_splice_appends_markers_to_a_note_without_them(self):
        spliced = depwatch.splice_vault_section("# Dependency watch\n\nProse.\n", "table")
        self.assertIn("Prose.", spliced)
        self.assertIn(depwatch.VAULT_BEGIN, spliced)
        self.assertIn(depwatch.VAULT_END, spliced)

    def test_default_note_splices_cleanly(self):
        section = depwatch.render_vault_section([self.finding(new=True)], "2026-09-12T05-45-00Z")
        spliced = depwatch.splice_vault_section(depwatch.default_vault_note(), section)
        self.assertIn("note:", spliced.splitlines()[1])
        self.assertIn("[[Kelpie]]", spliced)
        self.assertIn(depwatch.VAULT_END, spliced)

    def test_log_lines_shape(self):
        lines = depwatch.log_lines(
            [self.finding(new=True)],
            "2026-09-12T05:45:00Z",
            {"checks": 10, "new": 1, "high": 0, "medium": 1},
            "no",
            "no",
            21.4,
        )
        self.assertEqual(
            lines[0],
            "2026-09-12T05:45:00Z run checks=10 new=1 high=0 medium=1 publish=no prepare=no duration=21.4",
        )
        self.assertTrue(lines[1].startswith("2026-09-12T05:45:00Z heeler-upstream medium new "))


class BriefingTests(unittest.TestCase):
    def findings(self):
        return [
            depwatch.make_finding(
                check="ci-fork",
                severity="high",
                fingerprint="f1",
                title="no successful CI run on the fork",
                summary="",
                evidence=["e%d" % index for index in range(6)],
                actions=["a1", "a2"],
            ),
            depwatch.make_finding(
                check="node",
                severity="info",
                fingerprint="f2",
                title="npm audit clean",
                summary="",
            ),
            depwatch.make_finding(
                check="relay",
                severity="high",
                fingerprint="f3",
                title="relay unreachable",
                summary="",
            ),
        ]

    def test_only_new_medium_and_high_reach_the_brief(self):
        findings = self.findings()
        findings[0]["new"] = True
        findings[1]["new"] = True
        findings[2]["new"] = False  # a repeat stays out
        payload = depwatch.build_briefing(findings, "2026-09-12")
        self.assertEqual(payload["date"], "2026-09-12")
        self.assertEqual(len(payload["items"]), 1)
        item = payload["items"][0]
        self.assertTrue(item["title"].startswith("ci-fork: "))
        self.assertLessEqual(len(item["title"]), 80)
        self.assertEqual(len(item["headlines"]), 3)
        self.assertEqual(item["act"], ["a1", "a2"])

    def test_empty_items_when_nothing_is_new(self):
        payload = depwatch.build_briefing(self.findings(), "2026-09-12")
        self.assertEqual(payload["items"], [])

    def test_lengths_are_clamped(self):
        finding = depwatch.make_finding(
            check="heeler-upstream",
            severity="medium",
            fingerprint="f",
            title="x" * 200,
            summary="",
            evidence=["y" * 500],
            actions=["z" * 900],
        )
        finding["new"] = True
        item = depwatch.build_briefing([finding], "2026-09-12")["items"][0]
        self.assertEqual(len(item["title"]), 80)
        self.assertEqual(len(item["headlines"][0]), 220)
        self.assertEqual(len(item["act"][0]), 300)


class FindingShapeTests(unittest.TestCase):
    def test_every_registered_check_is_a_callable_with_a_unique_id(self):
        ids = [check_id for check_id, _ in depwatch.CHECKS]
        self.assertEqual(len(ids), len(set(ids)))
        for check_id, function in depwatch.CHECKS:
            self.assertTrue(callable(function), check_id)
            self.assertEqual(function.__name__, "check_" + check_id.replace("-", "_"))

    def test_a_raising_check_becomes_an_error_finding(self):
        def exploding(_ctx):
            raise RuntimeError("herdr fell over")

        finding = depwatch.run_check("herdr-release", exploding, None)
        self.assertEqual(finding["severity"], "error")
        self.assertEqual(finding["check"], "herdr-release")
        self.assertIn("herdr fell over", finding["evidence"][0])

    def test_a_timing_out_check_becomes_an_error_finding(self):
        def stalling(_ctx):
            raise depwatch.ToolTimeout("`gh api` exceeded 30s")

        finding = depwatch.run_check("relay", stalling, None)
        self.assertEqual(finding["severity"], "error")
        self.assertEqual(finding["fingerprint"], "timeout")

    def test_severity_rank_orders_the_scale(self):
        ranks = [depwatch.severity_rank(name) for name in depwatch.SEVERITY_ORDER]
        self.assertEqual(ranks, sorted(ranks))
        self.assertGreater(depwatch.severity_rank("high"), depwatch.severity_rank("medium"))


if __name__ == "__main__":
    unittest.main()
