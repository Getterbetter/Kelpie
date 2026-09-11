# Driving the iPad

A UI-automation lane for seeing what Kelpie actually does on Anthony's iPad
without a person holding it. `Tests/HeelerUITests/Drive.swift` is not a
behaviour suite: its one test is a **driver** that replays a step script
handed in through `KELPIE_DRIVE_STEPS` and attaches a screenshot after every
step. `scripts/drive-ipad.sh` runs it and exports the screenshots as PNGs.

It is deliberately outside the normal test lanes. `make test` and
`.github/workflows/ci.yml` run `-scheme Heeler`, where the UI-test bundle is
listed **skipped**; the driver only runs through its own `HeelerUIDrive`
scheme, which `scripts/drive-ipad.sh` names.

## Running it

```sh
scripts/drive-ipad.sh "shot"                              # one screenshot of the root screen
scripts/drive-ipad.sh "menu:Settings;tap:Notifications;shot;dump"
scripts/drive-ipad.sh --dump                              # element tree + screenshot, no steps
```

`DEVICE` defaults to the 11-inch iPad Pro (`09D7738D-…`); override it for
another device. `KELPIE_SCRATCH` sets the build and output root.

**The run takes over the iPad.** It installs and launches Kelpie fresh, then
taps its way through the script, so don't use the iPad while it runs. The
device must be **plugged in and unlocked** for the whole run — a locked screen
fails the launch wait.

## Step grammar

Steps are separated by `;`, executed in order, and each one is followed by a
screenshot named `NN-<step>`. Any step that cannot find its element waits 10
seconds and then fails the run with a message naming what it looked for.

| Step | What it does |
| --- | --- |
| `shot` | Screenshot only. |
| `wait:<seconds>` | Sleep, e.g. `wait:3` — for a screen that loads. |
| `menu` | Tap the floating "Kelpie Menu" capsule. |
| `menu:<item>` | Open the menu and tap the item whose label starts with `<item>` (case-insensitive), e.g. `menu:Settings`, `menu:Setup`, `menu:Tip`. |
| `tap:<label>` | Tap the first hittable button / cell / switch / link / static text whose label starts with `<label>`. |
| `toggle:<label>` | Tap a switch by label prefix, with a screenshot either side. |
| `type:<text>` | Type into whatever has focus. |
| `key:<name>` | A hardware key: `return`, `escape`, `tab`, `space`, `delete`, arrows, or `mod+key` (`cmd+.`, `cmd+v`, `ctrl+c`; modifiers `cmd`, `ctrl`, `opt`, `shift`). |
| `back` | The navigation bar's back button, else `Done` / `Close` / `Back`. |
| `swipe:<up\|down\|left\|right>` | Swipe the main window. |
| `dump` | Attach the element tree (`app.debugDescription`) as text. |

An unknown step fails the run rather than being skipped.

## Where the screenshots land

`$KELPIE_SCRATCH/drive/<timestamp>/` — PNGs named after their step
(`01-shot.png`, `02-menu.png`, …), plus any `dump` tree as a `.txt` and the
exporter's `manifest.json`. The raw result bundle is
`$KELPIE_SCRATCH/drive/<timestamp>.xcresult` and the xcodebuild log is
`<timestamp>.log` next to it; the script prints only the tail.

## Finding labels

`tap:` and `menu:` match the **accessibility label**, prefix, case-insensitive.
When a step misses, run `--dump` (or end a script with `dump`) and read the
element tree from the export directory: it names every element the driver can
reach. The root screen itself is a terminal surface, so almost nothing inside
it is addressable — the addressable UI is the "Kelpie Menu" capsule and
everything the menu opens.
