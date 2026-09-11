#!/usr/bin/env python3
"""Generate Kelpie's four store-panel artboards (.dc.html) + canvas.json.

Mirrors the Weights pipeline (WeightsVault/Design/Store Screenshots/
gen-panels.py): this file is the hand-tweakable REFERENCE canvas, and
compositor.swift is the production path that writes the exact-size PNGs
with the real system font. Keep the two in step — the numbers below are
the same constants compositor.swift uses.

Panels are 2752x2064, the ASC 13-inch iPad (APP_IPAD_PRO_3GEN_129)
landscape slot. Design ruled 2026-09-11: near-black ground in the
terminal's own colour family, one short white caption in SF Pro above,
the capture as a rounded-corner card scaled to fit with generous
margins. No device bezel, no other decoration.

Run:
    python3 gen-panels.py            # rotates raw/ -> canvas/, writes artboards
    swift compositor.swift           # writes final-13in/*.png
"""
import json
import os
import subprocess
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(BASE, "raw")
CANVAS = os.path.join(BASE, "canvas")

PW, PH = 2752, 2064
SIDE_MARGIN = 180
CAPTION_SIZE = 104
CAPTION_BASELINE = 266          # top-down baseline; the HTML block is placed off this
CARD_HEIGHT = 1540
CARD_TOP = 376
CARD_RADIUS = 40
GROUND = "#08080A"              # the terminal's #101010 family, a shade under it

# (output name, raw capture stem, caption) — order is the App Store order.
PANELS = [
    ("01-hero", "hero-tidepool", "herdr's console, full screen on your iPad"),
    ("02-split-panes", "infra", "Split panes. Keyboard, trackpad or touch."),
    ("03-menu", "menu-open", "Hosts, agents and settings, one tap away"),
    ("04-real-terminal", "notes-vim", "A real terminal for real tools"),
]

HEAD = """<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <style>
    body {{ margin: 0; background: {ground}; font-family: -apple-system, 'SF Pro Display', 'Helvetica Neue', Arial, sans-serif; }}
  </style>
</helmet>
"""

TAIL = """</x-dc>
</body>
</html>
"""


def artboard(capture_stem, caption):
    # The capture is landscape once uprighted; its aspect fixes the card width.
    width, height = png_size(os.path.join(CANVAS, capture_stem + "-landscape.png"))
    aspect = width / height
    card_h = CARD_HEIGHT
    card_w = card_h * aspect
    if card_w > PW - 2 * SIDE_MARGIN:
        card_w = PW - 2 * SIDE_MARGIN
        card_h = card_w / aspect
    card_x = (PW - card_w) / 2
    card_y = CARD_TOP + (CARD_HEIGHT - card_h) / 2
    # HTML has no baseline placement; sit the line box so its baseline lands
    # on CAPTION_BASELINE (SF Pro's ascent is ~0.75em at this weight).
    caption_top = CAPTION_BASELINE - CAPTION_SIZE * 0.75
    html = HEAD.format(ground=GROUND)
    html += (
        '<div style="position: relative; width: %dpx; height: %dpx; overflow: hidden; background: %s">\n'
        % (PW, PH, GROUND)
    )
    html += (
        '  <div style="position: absolute; left: %dpx; top: %.0fpx; width: %dpx; text-align: center; '
        'font-size: %dpx; font-weight: 600; letter-spacing: -1px; line-height: 1; color: #FFFFFF">%s</div>\n'
        % (SIDE_MARGIN, caption_top, PW - 2 * SIDE_MARGIN, CAPTION_SIZE, caption)
    )
    html += (
        '  <img src="%s-landscape.png" style="position: absolute; left: %.0fpx; top: %.0fpx; '
        'width: %.0fpx; height: %.0fpx; border-radius: %dpx; display: block">\n'
        % (capture_stem, card_x, card_y, card_w, card_h, CARD_RADIUS)
    )
    html += "</div>\n"
    return html + TAIL


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(33)
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


def main():
    os.makedirs(CANVAS, exist_ok=True)
    # The raw captures are portrait files holding the landscape UI a quarter
    # turn over. compositor.swift owns the rotation, so ask it for the
    # uprighted copies rather than re-deriving the direction here.
    subprocess.run(
        ["swift", os.path.join(BASE, "compositor.swift"), "--raw", RAW, "--export-landscape", CANVAS],
        check=True,
    )

    artboards = []
    for i, (name, stem, caption) in enumerate(PANELS):
        filename = "%s.dc.html" % name
        with open(os.path.join(CANVAS, filename), "w") as f:
            f.write(artboard(stem, caption))
        artboards.append({
            "file": filename,
            "title": "%d · %s" % (i + 1, caption),
            "x": i * (PW + 160),
            "y": 0,
            "w": PW,
            "h": PH,
        })

    canvas = {
        "artboards": artboards,
        "annotations": [{
            "id": "capture-note",
            "x": 0,
            "y": -420,
            "w": 1400,
            "text": (
                "13-inch iPad landscape set (APP_IPAD_PRO_3GEN_129), 2752x2064, sRGB, no alpha.\n"
                "This canvas is the reference; compositor.swift is the production path (it uses the real "
                "system font, which an HTML export substitutes away).\n"
                "Sources: raw/*.png are the on-device captures, portrait files holding the landscape UI a "
                "quarter turn over; compositor.swift uprights them.\n"
                "Design ruling 2026-09-11: near-black ground, one short white caption above, the capture as "
                "a rounded-corner card. No device bezel, no other decoration.\n"
                "notifications.png is NOT usable (it shows a private address). tip-sheet.png is the IAP "
                "review screenshot, uploaded by scripts/asc-kelpie.py --iap-screenshots."
            ),
        }],
        "launch": {"view": "canvas"},
    }
    with open(os.path.join(CANVAS, "canvas.json"), "w") as f:
        json.dump(canvas, f, indent=2)
    print("wrote %d artboards + canvas.json to %s" % (len(artboards), CANVAS))


if __name__ == "__main__":
    sys.exit(main())
