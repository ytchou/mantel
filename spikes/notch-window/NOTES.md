# Spike: notch window (DEV-2058 phase 1)

Throwaway. Question: can we own an NSPanel that sits over the notch, expands on
hover, and never takes keyboard focus? And should we build on DynamicNotchKit instead?

Status of every claim below: **compiled only** (`swift build` passes, no warnings).
Nothing here has been run yet. Runtime behaviour is marked "not verified".

## How the spike works

- `main.swift`: `NSApplication.setActivationPolicy(.accessory)` (no Dock icon), then
  `SpikeController` as the delegate.
- `Geometry.swift`: notch rect from `NSScreen`: x = `auxiliaryTopLeftArea.maxX` ..
  `auxiliaryTopRightArea.minX`, height = `safeAreaInsets.top`, top flush with the screen.
  No notch, or `--force-pill`: a 200x32 pill centred 6 pt under the menu bar.
  Sizes: idle = notch, peek = +36 w / +6 h, expanded = 420x160 (hangs from the screen top).
- `NotchPanel.swift`: `NSPanel`, styleMask `[.borderless, .nonactivatingPanel]`,
  `canBecomeKey`/`canBecomeMain` = false, `hidesOnDeactivate = false`,
  collectionBehavior `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`,
  `constrainFrameRect` overridden to keep the frame inside the menu-bar strip.
  Shown with `orderFrontRegardless()` (no activation).
- **Resize vs large panel: large panel.** The panel is created once at expanded size
  + 30 pt shadow margin and never resized. Only the SwiftUI `UnevenRoundedRectangle`
  inside animates (spring). `NSHostingView.sizingOptions = []` so SwiftUI cannot
  resize the window.
- **Hit testing:** panel starts with `ignoresMouseEvents = true`. A 60 Hz timer polls
  `NSEvent.mouseLocation`; while the cursor is inside the current shape rect it sets
  `ignoresMouseEvents = false`, otherwise true. The transparent part of the panel
  never takes clicks. The same poll drives hover (enter -> peek, then expanded after
  0.25 s; exit -> idle). SwiftUI `.onHover` on the shape is logged separately as a
  second hover signal.
- **Window level:** default `.statusBar` (25), one above the menu bar (`.mainMenu`, 24).
  Selectable with `--level mainMenu|statusBar|popUpMenu|screenSaver|shielding` so the
  orchestrator can find the lowest level that draws over the notch. Which level is
  needed: **not verified**.
- Logging: one stdout line per event, `[HH:mm:ss.SSS +elapsed] event detail`: screen
  metrics, notch rect, panel frame, each state change (with frontmost app,
  `NSApp.isActive`, `panel.isKey`), each hover enter/exit (poll and SwiftUI),
  `NSWorkspace.didActivateApplication`, `NSApp` became/resigned active, panel became key.
- `--selftest [s]` (default 6, minimum 4.6): programmatic idle -> peek -> expanded ->
  idle, then warps the cursor to the notch centre with `CGWarpMouseCursorPosition`,
  restores it 1.2 s later, prints one JSON line and exits 0. JSON keys: `notchRect`,
  `panelFrame`, `windowLevel`, `frontmostBefore`, `frontmostAfter`, `appBecameActive`,
  `hoverFiredFromWarp` (poll), plus `swiftUIHoverFiredFromWarp`, `panelBecameKey`,
  `panelVisible`, `mode`, `screenHasNotch`, `statesVisited`.

## How to run

```sh
cd spikes/notch-window
swift build
.build/debug/NotchSpike --selftest            # 6 s scripted run, JSON on last line
.build/debug/NotchSpike --selftest 8 --level screenSaver
.build/debug/NotchSpike --quit-after 30       # hover by hand for 30 s
.build/debug/NotchSpike --force-pill --quit-after 30
.build/debug/NotchSpike                       # until Ctrl-C
```

Compare levels: run `--selftest` once per `--level` value and look at the notch.

## Check by eye (human)

1. Idle shape lines up with the physical notch (no visible black edge beside it).
   Not verified.
2. Panel draws over the menu bar / notch at `--level statusBar`; if not, which level
   is the lowest that does. Not verified.
3. Hover feel: peek is immediate, expand after 0.25 s feels right, no flicker at the
   shape edge, leaving collapses cleanly. Not verified.
4. Clicks on menu bar items next to the expanded shape still work (transparent part
   passes clicks through). Not verified.
5. Clicking the black shape does not change the frontmost app or the key window of
   the app below (watch the log: no `frontmost changed`, no `NSApp became ACTIVE`).
   Not verified.
6. Over a full-screen app (menu bar hidden): panel still shows, hover still works.
   Not verified.
7. Switching Spaces (Ctrl-arrow, Mission Control): panel stays put, no slide
   animation, not shown in Mission Control / Cmd-Tab. Not verified.
8. Expand animation is smooth (no tearing, shadow not clipped). Not verified.

## DynamicNotchKit (v1.1.0, commit cd0b3e5, read from source)

Paths are relative to `Sources/DynamicNotchKit/`.

- **(a) Hover-to-expand driven by the app: partly.** The library tracks hover with
  SwiftUI `.onHover` (`Views/NotchView.swift:100`) and publishes
  `DynamicNotch.isHovering` (`DynamicNotch/DynamicNotch.swift:85`), but hover only
  drives shadow/haptics/keep-visible (`DynamicNotch/DynamicNotchHoverBehavior.swift:27-36`).
  It never expands on hover itself. An app could observe `isHovering` and call
  `expand()`, but `updateHoverState` ignores hover while `state == .hidden`
  (`DynamicNotch.swift:159`), and in `.hidden` the window is destroyed
  (`DynamicNotch.swift:312`). So hover-to-expand only works from `.compact`.
- **(b) Drag destination: no built-in support.** No drop/drag code anywhere in the
  sources (grep for drop/drag: zero hits). `.onDrop` inside the app's own expanded or
  compact SwiftUI content might work, but nothing exists while hidden, so dragging a
  file onto a bare notch cannot be detected. Not verified.
- **(c) Persistent always-present idle content: no.** States are only
  `expanded | compact | hidden` (`DynamicNotch/DynamicNotchState.swift:17-25`).
  `hide()` fades out and closes the window (`DynamicNotch.swift:298-314`). `.compact`
  stays up, but only with leading/trailing content beside the notch; with none it
  calls `hide()` (`DynamicNotch.swift:231-234`). There is no "notch-sized idle" state.
- **(d) Arbitrary custom states and sizes: no / partly.** The state enum is fixed
  (`DynamicNotchState.swift`). Size follows the content's intrinsic size
  (`.fixedSize()`, `Views/NotchView.swift:89-99`), inside a panel fixed at half the
  screen width and height (`DynamicNotch.swift:368-383`). There is no "peek" state.
  Transitions go through `.hidden` unless `skipIntermediateHides` is set
  (`DynamicNotch.swift:197-211`).
- **(e) Window level / collection behavior:** `level = .screenSaver`,
  `collectionBehavior = [.canJoinAllSpaces, .stationary]`, `canBecomeKey = true`
  (`Utility/DynamicNotchPanel.swift:25-31`); styleMask `[.borderless, .nonactivatingPanel]`,
  shown with `orderFrontRegardless()` (`DynamicNotch.swift:360-365, 400`). No
  `.fullScreenAuxiliary`, no `.ignoresCycle`, no `ignoresMouseEvents` handling for the
  transparent half-screen panel. It also defaults to `NSScreen.screens[0]`
  (`DynamicNotch.swift:173`). Notch geometry uses the same NSScreen approach as this
  spike (`Utility/NSScreen+Extensions.swift:23-44`).

Reading of the source, not a run: DynamicNotchKit is a "show a notification from the
notch" library. TopNotch's always-present idle surface, peek state, and drop target
would need forking it rather than configuring it. Whether its large transparent
panel blocks clicks below it: not verified.
