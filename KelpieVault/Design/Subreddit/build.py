#!/usr/bin/env python3
"""Build r/KelpieConsole community icon + banners from Kelpie's app icon."""
import os
from PIL import Image, ImageDraw, ImageFont

SRC = "/Users/anthonytopalides/Developer/Kelpie/KelpieVault/Design/Icon/kelpie-icon-1024.png"
OUT = os.path.dirname(os.path.abspath(__file__))
SS = 4  # supersample for circle mask

BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
REG = "/System/Library/Fonts/Supplemental/Arial.ttf"
for cand in ("/System/Library/Fonts/HelveticaNeue.ttc",):
    if os.path.exists(cand):
        BOLD_TTC = cand
FONT_NOTE = "Helvetica Neue (Bold / Regular) from HelveticaNeue.ttc"


def font(size, bold):
    try:
        return ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size,
                                  index=10 if bold else 0)
    except Exception:
        return ImageFont.truetype(BOLD if bold else REG, size)


src = Image.open(SRC).convert("RGB")
W = src.width

# Gradient column sampled from the icon's own background (x=120 avoids the artwork).
col = [src.getpixel((120, y)) for y in range(W)]
EDGE_HEX = "#%02X%02X%02X" % src.getpixel((120, 512))
DARK = src.getpixel((512, 512))  # navy of the dog artwork


# square bounding box of the dark artwork, with a small breathing margin
_g = src.convert("L").point(lambda v: 255 if v < 150 else 0)
_bb = _g.getbbox()
_cx, _cy = (_bb[0] + _bb[2]) / 2, (_bb[1] + _bb[3]) / 2
_half = max(_bb[2] - _bb[0], _bb[3] - _bb[1]) / 2 * 1.04
ART_BOX = (int(_cx - _half), int(_cy - _half), int(_cx + _half), int(_cy + _half))


def circle_icon(size):
    """Full-bleed circle: icon content at ~82% of diameter over the icon's own gradient."""
    big = size * SS
    base = Image.new("RGB", (big, big))
    d = ImageDraw.Draw(base)
    for y in range(big):
        d.line([(0, y), (big, y)], fill=col[int(y * (W - 1) / (big - 1))])

    content = 0.82
    inner = int(big * content)
    # crop to the artwork's own bounding box so the dog fills 82% of the circle
    bb = ART_BOX
    art = src.crop(bb).resize((inner, inner), Image.LANCZOS)
    # keep only the dark artwork; drop its light background so the circle reads as one piece
    art_mask = Image.new("L", (inner, inner), 0)
    ap = art.load()
    mp = art_mask.load()
    for y in range(inner):
        for x in range(inner):
            r, g, b = ap[x, y]
            lum = (r * 299 + g * 587 + b * 114) / 1000
            mp[x, y] = 255 if lum < 140 else (0 if lum > 170 else int((170 - lum) / 30 * 255))
    off = (big - inner) // 2
    base.paste(art, (off, off), art_mask)

    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, big - 1, big - 1], fill=255)
    out = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    out.paste(base, (0, 0), mask)
    return out.resize((size, size), Image.LANCZOS)


icon1024 = circle_icon(1024)
icon1024.save(os.path.join(OUT, "icon-1024.png"))
icon1024.resize((256, 256), Image.LANCZOS).save(os.path.join(OUT, "icon-256.png"))
print("icons done", EDGE_HEX)


def banner(w, h, centred=False):
    img = Image.new("RGB", (w, h), DARK)
    d = ImageDraw.Draw(img)
    r, g, b = DARK
    for x in range(w):  # <=8% luminance drift left->right
        f = 1.0 + 0.08 * (x / (w - 1)) - 0.04
        d.line([(x, 0), (x, h)], fill=(min(255, int(r * f)), min(255, int(g * f)), min(255, int(b * f))))

    ic = int(h * 0.70)
    icon = circle_icon(ic)
    word_f = font(int(h * 0.40), True)
    sub_f = font(int(h * 0.40 * 0.36), False)
    gap = int(h * 0.06)
    wb = d.textbbox((0, 0), "Kelpie", font=word_f)
    sb = d.textbbox((0, 0), "herdr console for iPad and iPhone", font=sub_f)
    text_w = max(wb[2] - wb[0], sb[2] - sb[0])
    block_gap = int(h * 0.09)
    block_w = ic + block_gap + text_w

    x0 = (w - block_w) // 2 if centred else int(w * 0.04)
    img.paste(icon, (x0, (h - ic) // 2), icon)

    tx = x0 + ic + block_gap
    line_gap = int(h * 0.04)
    wh = wb[3] - wb[1]
    sh = sb[3] - sb[1]
    total = wh + line_gap + sh
    ty = (h - total) // 2
    d.text((tx - wb[0], ty - wb[1]), "Kelpie", font=word_f, fill=(244, 246, 249))
    sub_col = tuple(int(244 * 0.7 + r * 0.3) for r in (0, 0, 0))
    d.text((tx - sb[0], ty + wh + line_gap - sb[1]), "herdr console for iPad and iPhone",
           font=sub_f, fill=(178, 186, 196))
    del gap
    return img


banner(1920, 384).save(os.path.join(OUT, "banner-1920x384.png"))
banner(3840, 768).save(os.path.join(OUT, "banner-3840x768.png"))
banner(1920, 384, centred=True).save(os.path.join(OUT, "banner-mobile-1920x384.png"))
print("banners done")

# contact sheet
files = ["icon-256.png", "icon-1024.png", "banner-1920x384.png",
         "banner-mobile-1920x384.png", "banner-3840x768.png"]
PW, pad = 1400, 40
rows = []
lab_f = font(22, False)
for f in files:
    im = Image.open(os.path.join(OUT, f))
    sc = min(1.0, (PW - 2 * pad) / im.width, 400 / im.height)
    rows.append((f, im.convert("RGBA").resize((int(im.width * sc), int(im.height * sc)), Image.LANCZOS)))
PH = pad + sum(r[1].height + 34 + pad for r in rows)
sheet = Image.new("RGB", (PW, PH), (138, 138, 138))
sd = ImageDraw.Draw(sheet)
y = pad
for name, im in rows:
    sd.text((pad, y), "%s  %dx%d" % (name, Image.open(os.path.join(OUT, name)).width,
                                     Image.open(os.path.join(OUT, name)).height),
            font=lab_f, fill=(20, 20, 20))
    y += 34
    sheet.paste(im, (pad, y), im)
    y += im.height + pad
sheet.save(os.path.join(OUT, "preview.png"))
print("preview done", EDGE_HEX, DARK)
