# Drag spike (DragSpike)

Throwaway. It answers three questions for the shelf block:

1. Can the app notice that a drag started anywhere on screen without Accessibility permission?
2. Can a small always-on-top non-activating panel accept drops of files, folders, text, links and promised files?
3. Can the user drag those items back out to Finder or another app?

Status: the spike compiles. Nothing below has been observed on a real run yet. Each
expectation is marked **not verified** until the orchestrator or a human runs the script.

## How it works

| File | Role |
|---|---|
| `Sources/DragSpike/main.swift` | Arguments, `.accessory` app, `ShelfPanel` (borderless, `.nonactivatingPanel`, `canBecomeKey` false, level `.statusBar`, `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`), selftest JSON |
| `Sources/DragSpike/DragMonitor.swift` | Drag-start detection: signal A (mouse events), signal B (drag pasteboard poll), combined session |
| `Sources/DragSpike/ShelfView.swift` | `NSDraggingDestination` content view; file promise receipt |
| `Sources/DragSpike/ChipView.swift` | One item chip; `NSDraggingSource` for drag-out |
| `Sources/DragSpike/Log.swift` | `<ISO8601> +<seconds since launch>s [TAG] message`, one line per event |

### Drag session definition

- **Signal A** `[SIG-A]`: `NSEvent.addGlobalMonitorForEvents` for `.leftMouseDown`, `.leftMouseDragged`
  and `.leftMouseUp`. A local monitor with the same mask covers drags that start in this app (global
  monitors never see our own events). Global *mouse* monitors are documented as not needing
  Accessibility. Only key-event monitors need it.
- **Signal B** `[SIG-B]`: a 50 ms timer, in `.common` run loop mode, reads
  `NSPasteboard(name: .drag).changeCount`. When the count changes, it logs the pasteboard types.
  The same timer watches `NSEvent.pressedMouseButtons` and logs `[POLL]` lines. This is a fallback
  for mouse-down and mouse-up if the global monitor misses them during another app's modal drag loop.
- **Combined** `[SESSION]`: a mouse-down arms the detector and snapshots the change count. The
  session **starts** when, since that mouse-down, we have seen BOTH a `leftMouseDragged` event AND a
  change-count bump. The session **ends** on the first `leftMouseUp` (monitor) or on the button-up
  seen by the poller. A click-drag with no pasteboard write (text selection, window move, rubber-band)
  logs `mouse released with no drag session` and never highlights the panel.
- Session start turns the panel blue (`[PANEL] highlight ON`). Session end restores it. Hovering a
  drop over the panel turns it green.

### Non-activating mouse-down (chips)

What the code does to let a chip receive a mouse-down while another app is frontmost:

1. `acceptsFirstMouse(for:)` returns true on `ChipView` and `ShelfView`. The panel can never become
   key, so without this the first click would be consumed as a window-activation click.
2. `ChipView.hitTest` returns the chip itself, so its label subviews do not take the `mouseDown`.
3. `panel.hidesOnDeactivate = false`. The NSPanel default is true, and an `.accessory` app is
   almost never active, so the panel would otherwise hide.
4. The `.nonactivatingPanel` style mask, so the click does not activate the app.

The `[CHIP] mouseDown ... appActive=false windowKey=false` log line shows the state at click time.
Whether all four are *necessary* is **not verified**. They have not been toggled one at a time.

### Drops

- Registered types: `public.file-url`, `public.url`, `public.utf8-plain-text`, plus
  `NSFilePromiseReceiver.readableDraggedTypes`. The selftest prints the exact list.
- `performDragOperation` logs each pasteboard item's types, then calls `enumerateDraggingItems` with
  classes in the order `[NSFilePromiseReceiver, NSURL, NSString]`. Each item becomes one chip, read
  as the first class that can read it. Promises come first because image drags can carry both a
  promise and a URL.
- File URL: `isDirectory` resource value gives `file` or `folder`. Non-file URL gives `link`. String
  gives `text`.
- Promises: `receivePromisedFiles(atDestination:)` writes into
  `$TMPDIR/DragSpike/promises/<uuid>/` (`FileManager.default.temporaryDirectory`) on a private
  `OperationQueue`. Logs `[PROMISE] receiving`, then `received after <ms> url=...` or `FAILED`.
- Why AppKit instead of SwiftUI `onDrop`: per-phase callbacks, raw pasteboard types per item,
  first-class `NSFilePromiseReceiver`, and direct `acceptsFirstMouse` control. The longer note is in
  `ShelfView.swift`.

### Drag out

- File, folder and promised file: `NSURL` file URL. Link: `NSURL`. Text: `NSString`.
- `sourceOperationMaskFor` returns `[.copy, .generic]` outside the app and `[]` inside it. Copy only,
  so Finder never moves the original file off its volume location.
- Logs `[DRAGOUT] BEGIN ...` and `[DRAGOUT] END ... operation=<copy|generic|none> (raw N)`.

## How to run

```sh
cd spikes/drag
swift build
swift run DragSpike --selftest          # setup check, 4 s, prints JSON, exit 0
swift run DragSpike --selftest 8        # same, 8 s
swift run DragSpike --quit-after 180    # manual test session, exits after 180 s
swift run DragSpike                     # runs until Ctrl-C
```

Selftest output is one JSON object with these keys: `axTrusted`, `globalMonitorInstalled`,
`localMonitorInstalled`, `dragPasteboardChangeCount`, `registeredTypes`, `panelFrame`, `panelVisible`,
`panelLevel`. It proves only setup. Real drags need a human.

Note: `swift run` starts the binary as a child of the terminal. Permission attribution (for
example, whether `AXIsProcessTrusted` reflects the terminal's grant) may follow the terminal app,
not the binary. To prove "no Accessibility", run from a terminal that does not have Accessibility,
and check that `[LAUNCH] AXIsProcessTrusted=false` is printed. **not verified**.

## Manual test script

Start `swift run DragSpike --quit-after 300 | tee $TMPDIR/dragspike.log`. Confirm the first line is
`[LAUNCH] ... AXIsProcessTrusted=false`, and that a dark 360x120 panel appears just below the notch.
Keep the terminal in the background and make Finder frontmost.

| # | Action | Expected log lines (all **not verified**) |
|---|---|---|
| 0 | Click and drag on empty Desktop (rubber-band), release | `[SIG-A] global leftMouseDown`, `[SIG-A] global first leftMouseDragged`, `[SIG-A] global leftMouseUp`, `[SESSION] mouse released with no drag session`. No `SIG-B` and no highlight. |
| 1 | Drag one file from Finder; pause mid-screen; drop on the panel | `SIG-A` down/dragged, `[SIG-B] drag pasteboard changeCount=N ... types=[public.file-url, ...]`, `[SESSION] drag session STARTED dtFromDown=..ms`, `[PANEL] highlight ON`; over the panel `[DROP] draggingEntered`; on drop `[DROP] item[0] types=[...]`, `[DROP] ACCEPTED kind=file value="/path"`; then `[SESSION] drag session ENDED`, `[PANEL] highlight OFF`. A blue chip appears. |
| 2 | Drag a folder from Finder onto the panel | As in 1, with `ACCEPTED kind=folder`. A teal chip appears. |
| 3 | Drag 2 files at once onto the panel | `performDragOperation items=2`, two `ACCEPTED` lines, `handled=2`. |
| 4 | In TextEdit, select text, then drag the selection onto the panel | `SIG-B` types include `public.utf8-plain-text` (and probably `public.rtf`), `ACCEPTED kind=text`. An orange chip appears. If the text is a URL, it may be read as `link` because NSURL is tried before NSString. |
| 5 | In Safari, drag the URL from the address bar onto the panel | `SIG-B` types include `public.url`, `ACCEPTED kind=link value="https://..."`. A purple chip appears. |
| 6 | In Safari, drag an image from a web page onto the panel | Either `[PROMISE] item[0] receiving fileTypes=[...]` then `[PROMISE] item[0] received after Nms url=$TMPDIR/DragSpike/promises/<uuid>/<name>` and `ACCEPTED kind=promised file`, or `ACCEPTED kind=link` if Safari offers no promise. Record which one. |
| 7 | In Photos, drag a photo onto the panel | `[PROMISE] receiving` then `received`, and `ACCEPTED kind=promised file`. A pink chip appears. Record the latency in `received after`. |
| 8 | Start a drag (as in 1), then press Esc or drop back on Finder, not on the panel | `SESSION STARTED`, then `SESSION ENDED`, highlight OFF; no `DROP ACCEPTED`. Check which signal ended it: `by=global leftMouseUp` or `by=poller saw button up`. |
| 9 | With Finder still frontmost, drag each chip to the Desktop | `[CHIP] mouseDown kind=... appActive=false windowKey=false`, `[DRAGOUT] BEGIN kind=...`, `[DRAGOUT] END ... operation=copy`. File, folder or promised file: a copy appears on the Desktop and the original stays. Text: Finder makes a text clipping. Link: Finder makes a `.webloc`. The local-monitor lines `[SIG-A] local ...` and `SESSION STARTED` also appear, because our own drag writes the drag pasteboard. |
| 10 | Drag the text chip into a TextEdit document; drag the link chip into the Safari address bar | `[DRAGOUT] END ... operation=copy` (or `generic`); the content is inserted or the page loads. |
| 11 | Drag a chip and drop it back onto the panel | `[DRAGOUT] END ... operation=none`; no new chip, because the within-app mask is `[]`. |

For each row, write down what was seen: the `dtFromDown` of `SESSION STARTED`, whether `SIG-A`
or `SIG-B` came first, and whether the session ended through the monitor or the poller.

## Open questions (all not verified)

- Whether the global monitor delivers `.leftMouseDragged` and `.leftMouseUp` while another app owns
  a drag session. The poller fallback exists in case it does not.
- Whether the drag pasteboard change count bumps only for real drags, and not for other writes to
  the drag pasteboard (for example, Finder pre-writing it on mouse-down).
- Latency between mouse-down and `SESSION STARTED`. The 50 ms poll adds up to 50 ms.
- Whether reading the drag pasteboard *types* during another app's drag is allowed without prompts
  on macOS 26. Pasteboard privacy prompts are documented for the general pasteboard. Behaviour for
  `.drag` is not verified.
- Whether Safari web images arrive as a promise, a URL, or both.
- Whether `acceptsFirstMouse` alone is enough for the chip drag, without the other measures.
- Behaviour in full-screen spaces and on a second display.
