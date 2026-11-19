# Spike: a block in its own process

Question: can a block run in its own process, get events from the host, and
show its view inside the notch with input that still feels instant?

Run on 2026-11-19: macOS 26.5.1, Swift 6.2.4, Apple silicon M1 Pro, built-in
display only. Release builds. The user's TopNotch app was running at the same
time (not touched).

Status words: **Measured** = ran it and saw the result. **Not measured** =
not run; the reason is given.

**All latency numbers come from injected events, not the physical pointer.**
Clicks were `NSWindow.sendEvent` of a synthetic mouse-down/up inside the
process that owns the input surface. Hover and drag-over called the handler
directly, with a timestamp. Nothing system-wide was posted. The manual check
at the end is how a person confirms the feel.

## How to run

```sh
cd spikes/separate-process
./run.sh build                  # release build, unsigned
./run.sh rtt                    # pd-b1
./run.sh view inproc            # pd-b2 baseline (same view, in the host)
./run.sh view described         # pd-b2 option 1
./run.sh view window            # pd-b2 option 2
./run.sh view layer             # pd-b2 option 3 (private API, "snapshot" route)
./run.sh crash <described|window|layer> <kill|fatal>   # pd-b3
./run.sh hang  <described|window|layer>                # pd-b3
./run.sh all                    # all of the above, about 6 minutes
./run.sh sign                   # sign both with the Apple Development identity + hardened runtime
./run.sh manual <option> [seconds]                     # hand check, see the end
```

Output lines starting with `RESULT` are the numbers; full logs go to
`.build/results/`, window captures to `.build/captures/` (both git-ignored).
Each run shows a panel at the notch for under a minute and kills its block on
exit. A `fatal` crash run makes macOS write a `spike-block-*.ips` crash report
to `~/Library/Logs/DiagnosticReports/`; delete it afterwards.

### Layout

| Path | What |
|---|---|
| `Sources/spike-host` | Host: notch-like panel (same recipe as `notch-window`), spawns the block, runs the measurements |
| `Sources/spike-block` | Block process: `NSApplication`, accessory policy, no Dock icon |
| `Sources/SpikeShared` | Wire protocol, `Probe` (timing), `DemoState` + `NodeRootView` (the test view, used by every option) |
| `Sources/RemoteLayer` | PRIVATE `CAContext` / `CALayerHost` calls, looked up at run time |

The test view is DemoBlock's idea: an icon, "Clicks: N", a second line
(pointer inside / drag-over file name), a button. Every option draws this
same view with the same SwiftUI code, so differences are the process
boundary only.

### Transport (pd-b1): `socketpair(2)` + `posix_spawn`

The host makes an `AF_UNIX` stream socket pair and passes one end to the block
as fd 3. Messages are a 4-byte length plus JSON (`Codable` enum).

Why not XPC: an `NSXPCListener.anonymous()` endpoint can only be handed to a
process over an existing XPC connection, so it needs a launchd-known service.
An XPC service must be bundled in the app's `Contents/XPCServices`, is started
by launchd on demand, and can't be passed a block's own executable. A socket
pair needs no bundle, works for any executable path, and gives an immediate EOF
when the peer dies. It costs what XPC gives for free: no peer code-signing
check (`NSXPCConnection.setCodeSigningRequirement`) and no typed proxies. A
real plugin host should add a code-signature check of the child (see Signing).

### What "latency" covers (pd-b2)

Per input, in the process that draws:

- `t0`: the input arrived in the process that owns the input surface. For a
  click, the time `mouseDown` ran in the view. For hover, the time the
  pointer poll would have reported the change. For drag-over, the time the
  drag handler ran.
- `commit`: `t0` until the end of the main run-loop pass in which SwiftUI
  evaluated the body with the new state. It is taken from a `beforeWaiting`
  run-loop observer with the highest order, so it runs after Core Animation's
  commit observer. At that point the new layer tree has been sent to the
  render server. (`CATransaction` commit handlers are not public on macOS.)
  For cross-process options it includes the socket hop and the block's work.
  Times from both processes use `CACurrentMediaTime()`, which is the same
  system-wide clock.
- `frame-est`: the `targetTimestamp` of the first display-link tick after the
  commit, an estimate of when the frame is on the glass. **This is not
  reliable.** The same option gave a median of 4.7 ms in one run and 13.3 ms in
  another (inproc). This is probably the ProMotion display's refresh state. So
  compare options on `commit`, and add about one refresh (8 to 17 ms) for the
  time until the frame is on the glass.

Sanity checks, measured: in every run the body ran before the commit
(`bodyAfterCommit=0`), and no input timed out. Captures of the host window
show the updated content (for example "Clicks: 200" after 200 clicks).

## Results

### pd-b1: events to a block process. Measured.

| What | n | Median | p95 |
|---|---|---|---|
| Round trip, block answers on its socket reader thread (transport floor) | 2000 | 0.028 ms | 0.059 ms |
| Round trip, block answers on its main thread (where block code runs) | 2000 | 0.037 ms | 0.069 ms |
| Cold start: spawn to first message (before `NSApplication`) | 10 | 8.0 ms | 17.8 ms |
| Cold start: spawn to `applicationDidFinishLaunching` | 10 | 72.5 ms | 106 ms |
| Cold start: spawn to first main-thread reply | 10 | 73.4 ms | 107 ms |
| Spawn to block view ready (window, layer options) | 1 each | 93 to 126 ms | |

The first launch after every new build or re-sign took 385 to 570 ms instead
(seen 5 times). Later launches were back to normal. I did not check the cause
(probably first-launch code validation). Signed and hardened builds gave the
same numbers: 0.030/0.068 ms reader, 0.037/0.072 ms main, n=1000.

### pd-b2: the block's view in the notch. Commit latency, ms, median / p95, n=200 each

| Option | Status | Hover | Click | Drag-over | Notch resize |
|---|---|---|---|---|---|
| Baseline: same view in the host process | Measured | 1.55 / 2.32 | 1.39 / 2.18 | 1.29 / 2.08 | 0.68 / 1.00 |
| 1. Described view (block sends data, host draws) | Measured | 1.94 / 2.93 | 1.99 / 3.15 | 1.77 / 2.59 | 0.41 / 0.90 (host only) |
| 2. Block's own window over the notch | Measured | 1.67 / 2.55 (forwarded by host) | 1.32 / 2.26 (inside the block) | 1.25 / 2.02 (inside the block) | 1.68 / 3.07 |
| 3a. Remote layer, PRIVATE `CAContext`→`CALayerHost`, SwiftUI drawn with `ImageRenderer` | Measured | 5.19 / 7.12 | 3.68 / 6.75 | 3.47 / 7.23 | 3.63 / 7.34 (max 41) |
| 3b. Remote layer with the live `NSHostingView` layer (private) | Tried, does not work | | | | |
| 3c. ExtensionKit `EXHostViewController` (public) | Not measured | | | | |

The parts, measured:

- Option 1, host send to block reply arriving: hover 0.44/0.80, click
  0.55/1.17, drag 0.45/0.75 ms. The rest is the host's own SwiftUI update.
  A resize costs nothing extra because the description does not depend on size.
- Option 2, host send to block receipt (hover, resize): 0.22/0.41 and
  0.33/0.72 ms. Click and drag-over land on the block's window, so they never
  cross the process boundary. On resize, the block's commit came 1.20/2.48 ms
  (max 3.2) after the host's commit for the same step.
- Option 3a, block receipt: 0.16 to 0.27 ms median. The extra 2 to 3 ms is
  `ImageRenderer` drawing a bitmap. On resize, the block's commit came
  3.29/6.51 ms (max 41) after the host's.

What the numbers mean: options 1 and 2 add about 0.1 to 0.6 ms (median) over
in-process. That is far below one display refresh (8.3 ms at 120 Hz), so in
most cases the response lands in the same frame as it would in-process.
Option 3a adds 2 to 4 ms, which more often slips a frame.

#### What breaks, per option

| Concern | 1. Described | 2. Own window | 3a. Remote layer (snapshot) |
|---|---|---|---|
| Notch resize animation | Measured: one SwiftUI tree in the host, so the shape and content are always in the same transaction | Measured: the block window moves in a separate commit, 1.2/2.5 ms behind the host's. A spring animation would need two animations kept in sync across processes. Not checked by eye | Measured: the host resizes and clips the container in its own transaction, and the content redraw follows 3.3/6.5 ms later |
| Transparency and corner clipping | Host owns it | Measured: a transparent block window over the host's black shape composites correctly. The host **cannot clip** another process's window, so the block must keep inside the shape. Its hit area is its window rectangle | Measured: a host-side `cornerRadius` + `masksToBounds` clips the remote layer (rounded corners in `.build/captures/layer-plain-*.png`) |
| Window level and ordering | n/a | Measured with `CGWindowList`: block window at level 26 in front of the host panel at level 25, at the requested frame. Spaces and full-screen apps not measured (needs a person) | n/a, part of the host window |
| Files dropped into the view | Host is the drop target and passes file paths to the block (works because the block is not sandboxed). Only the message path measured | Block window registers its own drag types, so drops go straight to it. Only the handler measured. A real drag needs the manual check | Same as option 1 |
| Focus | Host only, never key | Panel is non-activating and can never become key. Whether a real click activates the block process is **not measured**: injected events skip the window server | Host only |
| What the block can draw | Only the node vocabulary (text, symbol, image data, button, stacks). No arbitrary SwiftUI, custom animation, gestures, or drag-out | Arbitrary AppKit/SwiftUI | Arbitrary SwiftUI rendered as a still bitmap. No live animation. Controls do not track the pointer; input must be forwarded as messages |

#### Option 3 details

- **3a works (private API).** Measured: a bare `CALayer` tree in the block,
  wrapped in `CAContext contextWithCGSConnection:options:`, shows inside the
  host through `CALayerHost` with the context id. A capture shows the red layer
  and its text from the block's pid inside the host's notch shape. Updates
  show up too: the host capture read "Clicks: 5" after 5 clicks. SwiftUI only
  gets there as `ImageRenderer` bitmaps (route `snapshot`, the default).
- **3b does not work (tried twice, then stopped).** (1) I made the
  `NSHostingView`'s layer the root of the remote context. (2) I first removed
  it from the window's layer tree and then made it the root. Both gave a
  context id, but the host showed nothing: 0 % bright pixels in the content
  area. A third variant, the window's own context via private
  `-[CALayer context]`, returned id 0. Run them with `ROUTE=reparent` or
  `ROUTE=window ./run.sh view layer`. Not explored: a private `NSRemoteView`
  or a CGS window-context lookup.
- **3c not measured, not attempted.** Hosting a scene with
  `EXHostViewController` (in the macOS SDK since 13.0) needs an app bundle that
  declares an extension point and an `.appex` in `Contents/Extensions`, found
  through `AppExtensionIdentity`. That is an Xcode-built bundle, not a spike
  executable. From Apple's documentation, not verified here: app extensions
  must be sandboxed, and the user must enable the extension. Both clash with
  blocks that need file access and with a zero-setup notch.

### pd-b3: a block that crashes or hangs. Measured

Each crash was done while the block's view was shown, after 10 inputs.

| Case | Described | Own window | Remote layer |
|---|---|---|---|
| `kill -9`: host sees socket EOF | 1.85 ms | 2.19 ms | 2.81 ms |
| `kill -9`: process exit (`DISPATCH_PROC_EXIT`) | 1.85 ms | 2.25 ms | 2.85 ms |
| `fatalError`: socket EOF (SIGTRAP) | 0.99 ms | 0.93 ms | 1.61 ms |
| Host keeps running and still draws | Yes | Yes | Yes |
| What the notch shows after | The last description stays until the host replaces it. The spike shows "Block stopped" | The block window is gone from the window list. The host's shape is empty | The empty black shape (`CALayerHost` of a dead context draws nothing) |
| Restart: spawn to first committed frame | kill 71 ms, fatal 72 ms | 101 / 115 ms | 123 / 172 ms |

Times are from the host's `kill()` call or crash request. `fatalError` was
noticed just as fast as `kill -9`: crash reporting did not keep the process
alive. Each one wrote a crash report file.

**Hang** (block main thread sleeps 3 s). Measured:

- Detection: the host pings the block's main thread every 50 ms and treats a
  ping unanswered for over 250 ms as a hang. Detected at 251 ms (311 ms once).
  Pings answered again at 3002 ms.
- The host stays responsive: 40 host-only shape resizes during the hang
  committed in 0.26 to 0.77 ms median (p95 at most 1.2 ms). The host
  main-thread 10 ms timer was at most 2.1 ms late, against 0.9 to 2.3 ms before.
- What the notch shows: options 1 and 3 freeze on the last content, and the
  host can replace or remove it (its own layer). In option 2, measured, the
  hung block's window **stays on screen, in front of the host panel**, and the
  host has no public API to hide or move another process's window. It can
  only kill the block.

### Resources of the extra process. Measured, idle 5 s, after the run

| Block process | Footprint | Resident | CPU |
|---|---|---|---|
| No window (`NSApplication` running), as used by option 1 | 6.5 MB | 23 to 28 MB | 0.00 to 0.01 % |
| Option 2, own window | 13.4 MB | 35 to 42 MB | 0.01 % |
| Option 3a, invisible window + remote context | 17.4 MB | 46 MB | 0.02 % |
| For comparison: the host itself (in-process view) | 14.7 MB | 46 MB | 0.04 % |

Display links were stopped before the sample. With a display link left
running, the host used 1.5 % CPU.

### Signing and hardened runtime. Measured

- Host and block both signed with the Apple Development identity and
  `--options runtime`, with no entitlements: spawn, socket, own window, and
  the private `CAContext`/`CALayerHost` route all worked, with the same numbers.
- A hardened host also started an **ad-hoc-signed** block, and the remote
  layer worked. The OS sets no rule that the helper is from the same team.
  Library validation covers loaded code, not spawned processes. So the host
  must check a block's signature itself before trusting it, for example with
  `SecStaticCodeCheckValidity` on the executable and a `SecCode` check on the
  pid. Not measured: that check, and Gatekeeper or quarantine on a block
  downloaded from the internet (it would need its own notarized signature).

## Manual pointer check (not done in this run, needs a person)

```sh
cd spikes/separate-process && ./run.sh build
./run.sh manual inproc 60       # baseline
./run.sh manual described 60    # option 1
./run.sh manual window 60       # option 2
./run.sh manual layer 60        # option 3a
```

In each 60 s run the host polls the real pointer at 120 Hz, as the shell does,
and prints an `EVENT` line with the latency of every hover, resize, click and
drop. Steps:

1. Move the pointer onto the notch. It expands (with a spring) and the line
   reads "Pointer inside". Move away; it collapses. Do this 10 times, slow and
   fast. Compare how it feels with `inproc`.
2. Click inside the expanded notch 10 times. "Clicks" counts up at once.
3. Drag a file from Finder over the notch, then drop it. The line shows
   "Drag over: <name>", then "dropped <name>".
4. Option 2 only: while clicking, watch the app name in the menu bar. It
   should not change to `spike-block`. During the expand and collapse
   animation, watch whether the content and the black shape move together.
5. Option 2 only: switch Spaces and open a full-screen app, then hover again.
   Check that the block's content is still over the notch.

## Recommendation for the plugin format

Use **option 1, a described view**, if blocks go out of process.

- It is public API. It adds about 0.4 ms median over in-process (well inside
  one frame). The host keeps the animation, clipping, focus and drop handling.
  A crash or hang can never leave anything on screen the host does not control.
- Cost: a block can't ship arbitrary SwiftUI. It is limited to a fixed
  vocabulary (text, symbols, images as data, buttons, stacks, maybe progress
  and lists), like WidgetKit. No custom animation, no gestures, and no
  drag-out of its items without host support. Every new UI need is a host
  change.

Option 2 is just as fast and allows arbitrary UI. But the block has to keep
its window's level, Space behaviour, hit area and frame in step with the host
by itself. The host cannot clip it, animate it with the shape, or hide it when
the block hangs. A misbehaving block can cover the menu bar.

Option 3 works only through private API. With SwiftUI it works only as
bitmaps, about 2 to 4 ms slower and with no live animation. Do not build on it.

## Could not do

- Physical pointer latency and feel: no permission to move the pointer or
  post input. Use the manual check above.
- Real cross-process drag and drop, focus on a real click, Spaces and
  full-screen behaviour of the block window: these need a person.
- Live `NSHostingView` through the private remote context (3b): two attempts
  failed, then stopped as the brief says.
- ExtensionKit (3c): needs an Xcode-built app and extension bundle, and a
  sandboxed extension. Not attempted.
- A photon-level frame time: `frame-est` is only an estimate and varied
  between runs.

Side finding: on `NSPanel`, setting `isFloatingPanel = true` resets `level`
to 3 (floating). The first window run here measured both panels at level 3
until the order was swapped. `spikes/notch-window/NotchPanel.swift` sets
`level` before `isFloatingPanel`, so that panel may be at level 3, not 25.
