# Phase 1 spike findings

Run on 2026-11-18: macOS 26.5.1, Xcode 26.3, Apple silicon, built-in display
with a notch (1512x982 pt, notch 185x32 pt), no second display.

Each spike is a standalone Swift package in this folder. Nothing here is
imported by the app. Per-spike run instructions are in each `NOTES.md`; where a
`NOTES.md` says "not verified", this file has the measured result.

Status words: **Measured** = observed in a run. **Not checked** = needs a person
at the machine or a setting that is off.

## Decisions

| # | Decision | Chosen | Confidence |
|---|---|---|---|
| 1 | Own panel or DynamicNotchKit | Own panel | High |
| 2 | How to detect a drag | Global mouse monitor plus drag-pasteboard change count | Medium until a person runs the drag script |
| 3 | Naming pipeline on macOS 26 | Folder watcher, then Vision text, then on-device text model, with a no-model fallback | Medium: the model step could not be run |

### 1. Own panel, not DynamicNotchKit

The spike panel does everything the shell needs, in about 400 lines.
DynamicNotchKit (v1.1.0, read from source) would have to be forked:

- It has three fixed states (expanded, compact, hidden). There is no peek state.
- It closes its window when hidden, so there is no always-present idle surface
  to hover or drop onto.
- It has no drag or drop code.
- Its panel can become key, and it does not set `.fullScreenAuxiliary`.

Carry these choices into `NotchShell`:

- One large transparent panel created once; only the SwiftUI shape animates.
  The panel is never resized.
- `ignoresMouseEvents` is true except while the cursor is inside the current
  shape, so clicks on the transparent part reach the app below.
- Hover comes from polling the cursor position, not from SwiftUI `.onHover`.
  `.onHover` did not fire when the cursor arrived without mouse-move events.
- Window level `.statusBar`. `.mainMenu` also draws over the notch; `.statusBar`
  keeps the panel above menu bar items when expanded.

### 2. Drag detection without Accessibility

A drag session starts when both signals are seen after a mouse-down: a
`leftMouseDragged` event from a global monitor, and a change of
`NSPasteboard(name: .drag).changeCount`. It ends on mouse-up.

Setup is measured; the behaviour during a real drag is not. If the manual
script shows the global monitor is silent while another app runs its drag loop,
the fallback is the 50 ms mouse-button poll already in the spike.

### 3. Naming pipeline

1. Detect with a file-system watcher on the screenshot folder, and confirm with
   the `com.apple.metadata:kMDItemIsScreenCapture` extended attribute.
   Do not use `NSMetadataQuery`: it did not report either test capture.
2. Read text with Vision.
3. Name with the on-device text model (FoundationModels), using guided
   generation. The model cannot take an image on this SDK, so the text from
   step 2 is its only input.
4. When the model is unavailable, name from the text alone.
5. Rename with a same-folder move and store the original name in the
   `com.topnotch.original-name` extended attribute.

## Results

### A. Notch window (`notch-window/`)

| Check | Result |
|---|---|
| Panel draws over the notch | Measured. Works at `.statusBar` (25) and at `.mainMenu` (24). |
| Showing and expanding do not take focus | Measured. Frontmost app unchanged; the app never became active; the panel never became key. |
| Hover expands | Measured, with the cursor moved by code: idle to peek at once, expanded after 0.25 s. |
| Floating pill when there is no notch | Measured with `--force-pill`: pill sits under the menu bar and expands the same way. No real notchless display was available. |
| Expanded panel covers menu bar items | Measured. At 420 pt wide it hides menus and status items next to the notch. The shell needs a width limit or must accept this. |
| Clicks pass through the transparent area | Not checked. |
| Over a full-screen app, and when switching Spaces | Not checked. |
| Hover feel and animation smoothness | Not checked. |

### B. Drag in and out (`drag/`)

| Check | Result |
|---|---|
| Monitors install with Accessibility not granted | Measured. `AXIsProcessTrusted` false, global and local monitors installed. |
| Panel registers for files, links, text and promised files | Measured (registered types listed at launch). |
| A real drag starts a session; no pasteboard privacy prompt | Not checked. |
| Dropping a file, folder, text, link | Not checked. |
| Promised files from Safari or Photos | Not checked. |
| Dragging an item out to Finder | Not checked. |

All unchecked rows are covered by the manual script in `drag/NOTES.md`
(about five minutes).

### C. Screenshot naming (`screenshot-naming/`)

| Check | Result |
|---|---|
| Detect a new screenshot within 1 s | Measured: 19 ms and 43 ms after the file's creation date, with the folder watcher. The attribute was present within 1 ms. |
| `NSMetadataQuery` detection | Measured: did not fire within 8 s for either capture. |
| Vision text recognition | Measured: 0.9 s for a full 3024x1964 screen, 0.3 to 0.7 s for small test images. Traditional Chinese and English both read correctly. |
| On-device model naming and its latency | Not checked. Apple Intelligence is turned off on this Mac (`appleIntelligenceNotEnabled`). The model lists `zh-TW` and `en` as supported. |
| Image input to the model | Measured from the SDK interface: not available. Prompts accept text and structured content only. |
| Name with no model | Measured: good on a simple dialog (`safari-payment-failed-amount-due-date`), poor on a busy full-screen capture (`google-chrome-口`), and Chinese text is split badly (`台北-捷-運-時刻-表-首`). |
| Rename keeps dates; original name stored; undo | Measured: creation and modification dates identical before and after; attribute read back; undo restores the name. |

Limits of these measurements:

- Test captures came from the `screencapture` command, not the keyboard
  shortcut. With the shortcut, macOS shows a floating thumbnail and writes the
  file only after it goes away (about 5 s), so the rename will feel later than
  19 ms suggests. Not checked.
- The watcher ran from a terminal that already has Desktop access. The signed
  app will get its own folder permission prompt. Not checked.

## What this changes in the plan

- **The no-model fallback is not good enough to be the main path.** On real,
  busy screenshots it produces noise. The rename block should treat the model
  as the normal path and the fallback as "keep a tidy dated name" rather than
  a content name. Chinese fallback needs proper word splitting
  (`NLTokenizer`) if it is kept.
- **The model step is the open risk.** It must be measured before the rename
  block is designed in detail. Turning on Apple Intelligence and running
  `NameSpike selftest` takes a few minutes.
- **The contract needs a width or region limit for expanded content**, because
  the expanded panel covers menu bar items.

## Still to check by hand

1. Turn on Apple Intelligence (System Settings), then run
   `swift run NameSpike selftest` in `screenshot-naming/` and record the model
   timings and names.
2. Run the drag script in `drag/NOTES.md`.
3. Run `swift run NotchSpike --quit-after 60` in `notch-window/`; hover it,
   click beside it, open a full-screen app, switch Spaces.
4. Take a screenshot with Cmd-Shift-4 while `swift run NameSpike watch` runs.
