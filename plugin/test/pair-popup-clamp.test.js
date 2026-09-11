import { test, suite } from "node:test";
import assert from "node:assert/strict";

import { clampPairingScreen } from "../src/pair-popup.js";

suite("clamp pairing screen", () => {
  const qrLines = ["q1", "q2", "q3", "q4", "q5"];
  const textLines = ["hint", "user", "host key", "addresses", "validity"];

  test("rows undefined returns everything uncut", () => {
    const { lines, qrTruncated } = clampPairingScreen({ qrLines, textLines, rows: undefined });
    assert.deepEqual(lines, [...qrLines, ...textLines]);
    assert.equal(qrTruncated, false);
  });

  test("rows larger than everything returns everything uncut", () => {
    const { lines, qrTruncated } = clampPairingScreen({ qrLines, textLines, rows: 100 });
    assert.deepEqual(lines, [...qrLines, ...textLines]);
    assert.equal(qrTruncated, false);
  });

  test("rows exactly the QR height returns the whole QR and no text", () => {
    const { lines, qrTruncated } = clampPairingScreen({ qrLines, textLines, rows: qrLines.length });
    assert.deepEqual(lines, [...qrLines]);
    assert.equal(qrTruncated, false);
  });

  test("rows between QR height and total returns the whole QR plus as much text as fits", () => {
    const rows = qrLines.length + 2;
    const { lines, qrTruncated } = clampPairingScreen({ qrLines, textLines, rows });
    assert.deepEqual(lines, [...qrLines, ...textLines.slice(0, 2)]);
    assert.equal(qrTruncated, false);
  });

  test("rows below QR height replaces the QR with a notice, never a cut QR", () => {
    const rows = qrLines.length - 1;
    const { lines, qrTruncated } = clampPairingScreen({ qrLines, textLines, rows });
    assert.equal(qrTruncated, true);
    assert.equal(lines.length, rows);
    for (const line of lines) {
      assert.equal(qrLines.includes(line), false);
    }
    assert.match(
      lines[0],
      /Pane too short for the QR code \(needs 5 rows, has 4\)\. Press c to copy the Pairing Code instead\./,
    );
  });

  test("rows of 1 still replaces the QR with a notice and drops all text", () => {
    const { lines, qrTruncated } = clampPairingScreen({ qrLines, textLines, rows: 1 });
    assert.equal(qrTruncated, true);
    assert.equal(lines.length, 1);
    assert.match(
      lines[0],
      /Pane too short for the QR code \(needs 5 rows, has 1\)\. Press c to copy the Pairing Code instead\./,
    );
  });
});
