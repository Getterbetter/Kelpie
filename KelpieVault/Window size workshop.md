---
note: Workshop for Anthony's request (2026-09-11) — "reducing the size of the window and how that works in side-by-side viewing" — Split View, Slide Over and Stage Manager. Facts from Archive/round3/narrow-window-facts.md; options and a recommendation below; nothing built yet.
---

# Window size workshop

## What happens today

- **Split View and Slide Over already work**: nothing in the project forbids them (`UIRequiresFullScreen` is unset). **Stage Manager** gives one resizable Kelpie window, never two (`UIApplicationSupportsMultipleScenes` is unset).
- **Every resize goes straight to the mini.** A size change becomes an SSH window-change request; nothing coalesces them. Dragging the Split View divider fires one request per layout pass, serialised over SSH, and herdr re-lays out for each. Expect a stutter during the drag and a settle afterwards.
- **The font stays at 12 pt whatever the width.** The default keys off "is an iPad", not window size. Estimated columns at 12 pt: Slide Over (320 pt) ≈ 44, half of the 11-inch in landscape (≈ 590 pt) ≈ 80, two-thirds ≈ 110, full width ≈ 166. These are estimates from a 0.6 × pt cell width, not measured.
- **herdr has its own narrow layout.** At or below **64 columns** it switches to a single-column mobile layout; above that the sidebar collapses to compact (18 columns minimum) rather than hiding. Nothing on the client can force that mode; it is width-driven.
- **Kelpie's chrome does not adapt**: the host capsule and the keyboard inset are the same at every width.

So a 50/50 Split View on the 11-inch is already usable: about 80 columns, herdr's sidebar compact, a pane of roughly 55 columns. Slide Over drops below herdr's mobile threshold and becomes a one-pane view, which is fine for watching an agent and typing prompts, and poor for anything wider.

## Options

| | Option | What it buys | Effort |
|---|---|---|---|
| A | **Coalesce resizes** — send the first size at once, then only the last size after the drag has been quiet for ~80 ms | No stutter during divider drags, fewer SSH round trips, herdr redraws once | S |
| B | **Width-aware font** — pick the default size from window width (e.g. 12 pt at ≥ 700 pt, 11 pt at ≥ 500 pt, 10 pt below), keeping the user's zoom as an offset on top | Slide Over gains ~10 columns, half-width ~10; keeps herdr above its mobile threshold in Slide Over | S |
| C | **Compact chrome** — icon-only capsule under 500 pt, keyboard inset unchanged | Less of herdr's tab strip covered when it has the least to spare | S |
| D | **Stage Manager multi-window** — one window per Host (or per herdr session) | Two Macs side by side, or herdr next to its own Agents cover | M–L, and a Transport serves one Attach at a time per Host, so per-Host windows only |
| E | **Tell herdr the intent** — none available; the mobile threshold is a mini-side config (`ui.mobile_width_threshold`, default 64) | Could be lowered in `config.toml` so 50/50 keeps the sidebar | config only, not code |

## Recommendation

A + B + C as one small round ("compact widths"): they are independent of each other, each is a day or less, and together they make Split View feel deliberate rather than tolerated. D waits until there is a second Host worth a window. Skip E unless he wants the sidebar in a 50/50 split more than the columns.

## Questions for Anthony

1. Which arrangement does he actually use: Split View with another app beside Kelpie, Slide Over on top of something, or Stage Manager windows? The answer sets whether B matters (Slide Over) or only A (Split View).
2. In a narrow window, does he want herdr's mobile single-column layout, or the sidebar kept and the pane squeezed? That is the E setting.

Related: [[Mac vs iPad gaps]] · [[Open items]] · [[Feedback log]]
