# r/KelpieConsole community assets

Built from the shipped app icon `KelpieVault/Design/Icon/kelpie-icon-1024.png`.

| File | Dimensions | Reddit slot |
| --- | --- | --- |
| `icon-256.png` | 256x256 | Community icon (Reddit's circular avatar; upload this one) |
| `icon-1024.png` | 1024x1024 | Community icon, master / high-DPI source |
| `banner-1920x384.png` | 1920x384 | Banner, "large" desktop size — icon + wordmark block in the left 60% |
| `banner-3840x768.png` | 3840x768 | Banner, "large" at 2x for retina uploads |
| `banner-mobile-1920x384.png` | 1920x384 | Banner alternative with the block centred, for the mobile centre crop |
| `preview.png` | 1400x2010 | Contact sheet on neutral grey; not for upload |

## Composition

- Circle icon: the dog artwork is cropped to its own bounding box and scaled to 82% of the
  circle diameter, centred, over the icon's own vertical gradient (sampled column, edge
  colour at mid-height `#CCD4DB`). Everything outside the circle is transparent, so Reddit's
  circular crop clips nothing.
- Banners: background is the icon's dark navy `#2D3742` with a ±4% horizontal luminance
  drift (8% total) and no other decoration. Wordmark "Kelpie" at 40% of banner height in
  Helvetica Neue Bold, near-white `#F4F6F9`; subtitle "herdr console for iPad and iPhone" at
  36% of the wordmark size in Helvetica Neue Regular at `#B2BAC4` (~70% of the wordmark
  white). Icon at 70% of banner height, left margin 4% of width.
- Deviation from the spec: the wordmark is 40% of banner height, not 45%. At 45% the
  icon+text block overran the left 60% and would have been cut by Reddit's mobile crop.

## Build

```sh
cd /private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/993528c4-f97e-4d8a-8fc7-e4a88beb4c1f/scratchpad/delegate-20260917T0948/assets
python3 -m venv .venv && .venv/bin/pip install pillow   # system python3 has no Pillow and is PEP-668 managed
.venv/bin/python3 build.py
```

`build.py` writes every PNG in this folder (sRGB, 8-bit).
