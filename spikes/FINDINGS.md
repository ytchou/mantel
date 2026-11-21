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
| 2 | How to detect a drag | Global mouse monitor plus drag-pasteboard change count | High: 5 of 5 real drags detected, no false starts |
| 3 | Naming pipeline on macOS 26 | Folder watcher, then Vision text, then on-device text model, with a no-model fallback | High that it works; the model is slow (1 to 10 s) |

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

Measured with real drags from Finder and Chrome with Accessibility not
granted. The 50 ms mouse-button poll stays as a second source of mouse-up.

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
| Clicks pass through the transparent area | Measured by hit test, not by a real click (`probe/probe.swift hit`). A point inside the panel frame but outside the shape resolves to the app below. A point 70 pt under the notch resolves to the app below while idle, to the panel while expanded, and to the app below again after collapse. |
| Over a full-screen app, and when switching Spaces | Checked by hand: the panel stays over the notch and expands on hover in a full-screen app and after switching Spaces. The automated probe could not show this (macOS would not bring its window forward). |
| Hover feel and animation smoothness | Not checked. |

### B. Drag in and out (`drag/`)

| Check | Result |
|---|---|
| Monitors install with Accessibility not granted | Measured. `AXIsProcessTrusted` false, global and local monitors installed. |
| Panel registers for files, links, text and promised files | Measured (registered types listed at launch). |
| Global monitor sees another app's mouse-down, drag and mouse-up | Measured, with Accessibility not granted (a real click in another app was logged). |
| Drag pasteboard changes when another app starts a drag, and its types can be read | Measured with `probe/probe.swift drag file`: change count went 726 to 727 and the file types were read. |
| A real drag starts a session (both signals together) | Measured by hand: 5 of 5 real drags started a session, 73 to 168 ms after mouse-down. About 30 plain clicks and text selections in between started none. |
| Dropping a file, folder, text, link | Measured by hand: all four accepted, each as the right kind. Files and folders from Finder; link and text from Chrome. |
| Promised files | Measured by hand: an image dragged out of a web page in Chrome arrived as a promised file and was written in 286 ms. Safari and Photos were not tried. |
| Dragging an item out to Finder | Measured by hand: a file dragged from the panel to the Desktop was copied there, with the app not frontmost. |

Shelf behaviour asked for during the hand test, for phase 3:

- An item leaves the shelf after a successful drop elsewhere. The spike keeps
  it on purpose; the real block must not.
- Items are shown as real thumbnails and file icons with the name, not as
  coloured boxes.

### C. Screenshot naming (`screenshot-naming/`)

| Check | Result |
|---|---|
| Detect a new screenshot within 1 s | Measured: 19 ms and 43 ms after the file's creation date, with the folder watcher. The attribute was present within 1 ms. |
| `NSMetadataQuery` detection | Measured: did not fire within 8 s for either capture. |
| Vision text recognition | Measured: 0.9 s for a full 3024x1964 screen, 0.3 to 0.7 s for small test images. Traditional Chinese and English both read correctly. |
| On-device model naming | Measured after Apple Intelligence was turned on. Names describe the content: `acme-cloud-billing-payment-failed-error-402-invoice`, `taipei-metro-train-schedule-ticket-price-no-food-in-car`. Chinese screenshots get English names. |
| Model latency | Measured: 0.8 s to 10 s per name in settled runs, and up to 44 s in the first minutes after the model download while the Mac was under load (load average 9). Almost all of it is the wait for the first token; creating a session takes 3 ms. Not yet known: the steady-state figure on an idle Mac, and whether `prewarm()` helps. |
| Requested name length is respected | Measured: no. "Short" (2 to 4 words) and "standard" (4 to 6) returned 8 to 10 words. The array count guide holds, but the model puts several words in one element. The name must be cut to length in code. |
| Image input to the model | Measured from the SDK interface: not available. Prompts accept text and structured content only. |
| Name with no model | Measured: good on a simple dialog (`safari-payment-failed-amount-due-date`), poor on a busy full-screen capture (`google-chrome-口`), and Chinese text is split badly (`台北-捷-運-時刻-表-首`). |
| Rename keeps dates; original name stored; undo | Measured: creation and modification dates identical before and after; attribute read back; undo restores the name. |

Limits of these measurements:

- The first test captures came from `screencapture` with a file path, which
  skips the floating thumbnail. A further capture used `screencapture -u`,
  which goes through the system thumbnail and default naming like the keyboard
  shortcut does. Measured: the file appeared about 6 s after the capture was
  taken and was detected 20 ms after it appeared. So the rename can start no
  sooner than about 6 s after the user presses the keys, unless the thumbnail
  is clicked away or turned off. The key press itself was not used.
- The watcher ran from a terminal that already has Desktop access. The signed
  app will get its own folder permission prompt. Not checked.

## Why some rows are not checked

- **No synthetic input.** The session that ran these spikes has no permission
  to post mouse or key events, so it could not click, hold a drag, or press the
  screenshot shortcut. `probe/probe.swift` goes as far as is possible without
  that permission: it starts a real drag session from its own window, but with
  no button held the session ends without a drop (operation 0).
- **Apple Intelligence was off at first.** The owner turned it on during the
  run, so the model rows above are measured.

## What this changes in the plan

- **The no-model fallback is not good enough to be the main path.** On real,
  busy screenshots it produces noise. The rename block should treat the model
  as the normal path and the fallback as "keep a tidy dated name" rather than
  a content name. Chinese fallback needs proper word splitting
  (`NLTokenizer`) if it is kept.
- **Model naming takes seconds, not milliseconds.** The rename block cannot
  rename before the user sees the file. It should show "naming" in the notch,
  rename when the model answers, and give up to the fallback after a time
  limit (about 10 s). Undo matters more because the rename arrives late.
- **Name length must be enforced in code**, and the block needs a setting for
  the language of names, because Chinese content is named in English.
- **The model needs Apple Intelligence turned on**, plus a download of the
  model that took about seven minutes here. Onboarding must explain this and
  the block must work, with the fallback, while the model is not ready.
- **The contract needs a width or region limit for expanded content**, because
  the expanded panel covers menu bar items.

## Still to check

Nothing blocks phase 2. Two lower-value items remain:

1. Steady-state model timings on an idle Mac, and whether `prewarm()` helps.
2. Promised files from Safari and Photos, and the folder permission prompt
   for the signed app.

---

# Phase 5 spike findings: how an outside block gets into the app

Run on 2026-11-19: macOS 26.5.1, Xcode 26.3 (Swift 6.2.4), M1 Pro, built-in
display. Two spikes, each a standalone folder here. Full tables, exact error
text and run commands are in each `NOTES.md`; this section is the summary and
the recommendation for the plugin format (plan task pd-3).

Status words as above: **Measured** = observed in a run. **Not measured** = the
reason is given.

Run twice. Each spike was run once when it was written. On 20 Nov
`runtime-load/run.sh` was run again and every row of table A came out the same
(the two Gatekeeper cases are off by default and were not repeated). For
`separate-process`, the round trip was run again (0.069 ms median, 0.085 ms
p95, on battery); the view, crash and hang rows were not, because the lid was
closed and they need the display.

## A. Load a block at runtime (`runtime-load/`)

| Task | Status | Finding |
|---|---|---|
| pd-a1 A block built outside the app is loaded from a folder at launch | Measured | Yes. A hardened, signed host lists `*.topblock` bundles, reads each `Info.plist` before any block code runs, `dlopen`s the code and calls one C entry symbol. `dlopen` 0.4 to 0.5 ms warm; 215 to 429 ms the first time macOS sees a new binary. The real `NotchCore` built as a dynamic library, and the real, unchanged `DemoBlock` built against only its interface file, ran through the real `NotchRuntime` (hover, 2 clicks, a drop). |
| pd-a2 Signing under the hardened runtime | Measured | With library validation on (today's setting), only a block signed by the app's own team loads. Unsigned: `Trying to load an unsigned library`. Ad-hoc or another team: `mapping process and mapped file (non-platform) have different Team IDs`. With the `com.apple.security.cs.disable-library-validation` entitlement, ad-hoc blocks load; unsigned ones never do. A quarantined (downloaded) block is refused by Gatekeeper with a dialog in both settings. |
| pd-a2 A block built against one contract version, loaded in the next | Measured | Without library evolution: adding a protocol requirement or an enum case crashes (SIGSEGV), and reordering fields gives silently wrong values. With library evolution: all additions work, and a removed method is refused at load with `Symbol not found`. A block built by Swift 6.3.3 loaded in a 6.2.4 host only with library evolution. |
| pd-a3 What a bad block could do | Measured | Everything the app can. A block signed by the app's own team ran code during `dlopen` before any check, read a file the host could read, replaced a host method, froze the host's main thread for 3 s, and killed the host with `fatalError`. |

Not measured: a notarized block (no Developer ID certificate); another-team
and quarantined blocks with library validation off (macOS had already removed
the test bundles); permissions inherited by a block inside the real app bundle.

What it would take to ship:

1. `NotchCore` becomes one dynamic framework built with library evolution. The
   app, the shell and every built-in block link that one copy.
2. Every public enum is either `@frozen` or every block gets `@unknown
   default`. Measured: today's `DemoBlock` does not compile in Swift 6 mode
   against `NotchCore` built that way.
3. The interface file is public API: nothing removed or renamed.
4. A signing choice: own-team blocks only, or library validation off.

## B. A block in its own process (`separate-process/`)

All latency numbers come from events injected inside the spike's own
processes, not the physical pointer. The hand check is in `NOTES.md`.

| Task | Status | Finding |
|---|---|---|
| pd-b1 A block in its own process gets events from the app | Measured | Yes, over a Unix socket pair given to the block at start. Round trip 0.037 ms median, 0.069 ms p95 (n=2000). Start to first reply 73 ms median. |
| pd-b2 Its view is shown inside the notch | Measured | Three ways tried; see the table below. Sending the view as data costs about 0.4 ms over in-process. |
| pd-b3 A crashing block does not take the app down | Measured | `kill -9` noticed in 1.9 to 2.8 ms, `fatalError` in 0.9 to 1.6 ms; the host kept running and restarted the block in 71 to 172 ms. A hung block was detected in 251 ms by a 50 ms heartbeat, and the host stayed responsive. |

Time from an input arriving to the frame with the change being sent to the
screen, ms, median / p95, n=200 each:

| How the view gets into the notch | Hover | Click | Drag-over | What it costs |
|---|---|---|---|---|
| In-process (baseline) | 1.55 / 2.32 | 1.39 / 2.18 | 1.29 / 2.08 | |
| 1. Block sends its view as data, host draws it | 1.94 / 2.93 | 1.99 / 3.15 | 1.77 / 2.59 | A fixed set of elements (text, symbol, image, button, stacks). No arbitrary SwiftUI, custom animation, gestures or drag-out unless the host adds it. |
| 2. Block owns a window placed over the notch | 1.67 / 2.55 | 1.32 / 2.26 | 1.25 / 2.02 | Any UI, but the host cannot clip it, animate it with the shape, or remove it when the block hangs. Measured: a hung block's window stays on screen in front of the notch. |
| 3. Remote layer (private API) | 5.19 / 7.12 | 3.68 / 6.75 | 3.47 / 7.23 | Private API, and SwiftUI arrives only as still bitmaps. A live SwiftUI view did not show (two attempts). |

The extra process: 6.5 MB footprint and about 0 % CPU idle for way 1.

Not measured: the feel with the real pointer; a real file drag between
processes; Spaces and full-screen behaviour of way 2; ExtensionKit (needs an
Xcode-built app extension, which must be sandboxed); Gatekeeper on a
downloaded block executable; a check of the block's signature by the host
(macOS does not do it: a hardened host started an ad-hoc-signed block).

Side finding: `isFloatingPanel = true` resets an `NSPanel`'s level to 3. The
phase 1 `notch-window` spike sets the level first, so its "level 25" row above
is doubtful. The app sets the level afterwards since PR #7.

## pd-3: the plugin format

**Decided on 20 Nov by the owner: B, a separate process with the view sent as
data.** The reasons given: a broken block must not break other blocks or the
app, and people must be able to download blocks without changing the app.
The table and recommendation below are what the decision was made from.

| Choice | What you get | What it costs |
|---|---|---|
| **A. Load at runtime** (a bundle in the app's process) | Blocks keep the full contract and any SwiftUI. No extra process, no latency. | `NotchCore` rebuilt as a dynamic framework with library evolution, which touches the app, the shell and all four blocks. A block has all of the app's access. One crash or hang takes the app down, so plan task pi-6 ("a block that crashes or hangs is turned off, and the app keeps running") cannot be met. Blocks from other people need library validation turned off, and downloaded ones still hit Gatekeeper. |
| **B. Separate process, view sent as data** | A crash or hang cannot touch the app (measured). The app decides everything that is drawn. No change to how the app or the built-in blocks are built. | A wire protocol to design and version. A block's UI is limited to the elements the host knows; the shelf (drag out, live thumbnails) does not fit without host work. Each running block adds about 6.5 MB. The block process still has the user's file access unless it is sandboxed (not measured), and the host must check its signature itself. |
| **C. Both, by trust** (own-team blocks in-process, everyone else out of process) | Full UI for trusted blocks, isolation for the rest. | Both lists of costs, two formats to build, document and keep working. |

**Recommended: B, as the only install format for now.**

- It is the only choice that meets pi-6, and it leaves the working app alone.
- The now-playing block already fits the element set (image, two lines of
  text), so it can be the block that proves the format. That means changing
  pi-7 from "move the shelf or the renamer out" to "move the now-playing
  block out". The shelf and the renamer stay compiled in.
- Take A later, and only when a block someone wants needs UI that cannot be
  described as data. The measurements here say what A will cost then.

What would make this recommendation wrong: if the blocks you expect people to
write look like the shelf (custom views, dragging) and not like now-playing
(a line of status and a button). Then B is too small and C is the honest
answer. The hand check of real-pointer feel in `separate-process/NOTES.md`
should also be done before building on B.

**Note, 20 Nov (Phase 6 build).** Two differences from the spike are
deliberate for Phase 6. The heartbeat pings every 1 s and calls a block hung
after 3 s without an answer, timed on a clock that stops while the Mac sleeps;
the spike's 50 ms ping was for measuring, not for running all day. The app does
not check a block's signature: Phase 6 installs only the owner's own blocks
(design decision D1), and signature checks and Gatekeeper are Phase 7 work.
The hand check of real-pointer feel (hover and click through a block process,
next to an in-app block) is still waiting for the owner.

# One tier of blocks: the sandbox probe

Probed on this Mac (macOS 26, 2026-11-20) with a command-line process under
`/usr/bin/sandbox-exec` and the deny-list profile `SandboxProfile` now builds
(allow by default; deny network, Apple events, writes outside the data and
temporary folders, and reads in the home folder).

- Under the profile, a read and a write in the home folder, a network request
  and an Apple event were refused. A write in the data folder worked.
- FoundationModels needs `file-read-metadata` on the home folder. Without it
  the on-device model reports "Apple Intelligence not enabled"; with it the
  model answered in 7.6 s. The line is in every profile.
- File descriptor 3 survives `sandbox-exec`: the block gets its socket and
  says `hello` (process test from the test runner). No launcher with
  `sandbox_init_with_parameters` was needed. The same from the signed app is
  part of the owner's check at `make run`.
- Limit: a deny list stops the plain cases, not a determined attacker; system
  services stay reachable.

## Sandbox rules, 21 Nov

Measured on this Mac (macOS 26.5.1, Apple Intelligence on) with
`spikes/sandbox-rules`: the executable `sbspike` (one subcommand per probe,
each prints one `RESULT <probe> OK|FAIL` line) copied into a stand-in
package folder `Spike.topblock/` and started by `run.sh` the way
`BlockProcess` starts a block: `env -i PATH=... HOME=... TMPDIR=<block temp>
TOPNOTCH_BLOCK_GENERATION=1 /usr/bin/sandbox-exec -p <profile> <executable>`.
The block's temp folder was `<TMPDIR>/TopNotch/Blocks/dev.topnotch.spike/`, its
data folder a throwaway one under `~/Library/Application Support/`. All
commands run from `spikes/sandbox-rules` after `swift build`; `./run.sh
<profile> --print` prints a profile. Sandbox violations are not logged for
`sandbox-exec` here, so each needed location was found by adding one
`(allow file-read* ...)` at a time through `EXTRA=`.

1. **Read allow-list (measured).** The allow-list below lets FoundationModels
   answer and Quick Look make thumbnails. Commands: `./run.sh allowlist fm`
   (model answered in 7.5 s) and `./thumbs.sh allowlist` (PNG, text and PDF in
   the block's temp folder and a PNG in its data folder: all `thumbnail`
   representations, same sizes as unsandboxed). Two entries were not
   obvious: without `/private/var/db/eligibilityd` the model reports
   `deviceNotEligible` (`EXTRA='(allow file-read* (subpath "/private/var/db/eligibilityd"))'`
   was the narrowest fix; `os_eligibility`, `AppleIntelligencePlatform` and
   `com.apple.modelcatalog` were not enough); without the root symbolic links
   `/etc`, `/var`, `/tmp` `getaddrinfo` fails even with the network open
   (`EXTRA='(allow network*)' ./run.sh allowlist dns www.apple.com`, fixed by
   `(literal "/etc") (literal "/var") (literal "/tmp")`). `/Library/Apple` and
   `/Library/Preferences` were not narrowed further. With the list, `/Applications`,
   `/Library/Application Support`, `/private/tmp` and `~/Library/Preferences`
   are refused (`./run.sh allowlist read <path>`).
2. **Per-user temp folder (measured): yes, reads can be closed.** Under the
   allow-list, a file in `<TMPDIR>` outside `TopNotch/`, a listing of `<TMPDIR>`
   and another block's folder are refused, the block's own folder reads
   (`./run.sh allowlist read <path>`), and question 1 passes with it, because
   nothing in that list opens `<TMPDIR>`. Writes into `<TMPDIR>` stay open
   (the current write rule); only reads were asked. Control: `allowlist-tmp`
   (the same plus `<TMPDIR>` readable) and `denylist` (today's profile) both
   read the outside file.
3. **Network gate (measured): yes.** Command `./q3.sh gate` (starts two copies
   of `proxy.py`, a 30-line CONNECT proxy, on 8899 and 8898). Under the gate
   profile: TCP to `127.0.0.1:8899` and `localhost:8899` connects; TCP to
   `127.0.0.1:8898` (another local listener) and to `17.253.144.10:443` is
   refused (`EPERM`); a direct `URLSession` GET of `https://www.apple.com/`
   fails (`EPERM`). A `URLSession` GET through the proxy on 8899 returns 200
   with both `connectionProxyDictionary` (`kCFNetworkProxiesHTTPSEnable/Proxy/Port`,
   proxy host `127.0.0.1`) and `proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy:)]`;
   the proxy logged `CONNECT www.apple.com:443 HTTP/1.1` for each. The same
   session aimed at 8898 fails (CFNetwork 310) and that proxy logged nothing.
   The block itself needs no name lookup: the proxy resolves.
4. **Name lookups (measured).** Two paths. `getaddrinfo` uses the
   `/private/var/run/mDNSResponder` socket, which `(deny network*)` already
   closes: under the gate it fails in 0 ms for `www.apple.com` and an unknown
   name (`./run.sh gate dns <name>`), and resolves once that socket is allowed
   (`EXTRA='(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))'`);
   the dnssd deny does not stop that path. `URLSession` (Network framework)
   resolves through the `com.apple.dnssd.service` Mach service, which the gate
   leaves open: under `gate`, `https://www.apple.com/` fails at the connect
   (`EPERM`) while an unknown name fails with -1003, so a query went out.
   With `(deny mach-lookup (global-name "com.apple.dnssd.service"))` (profile
   `gate-dns`), `www.apple.com` also fails with -1003: no lookup. Proxy
   requests still return 200 (`./q3.sh gate-dns`), and question 1 still
   passes (`./run.sh gate-dns fm`, 7.6 s; `./thumbs.sh gate-dns`, all four).
5. **Preferences service (measured): yes, the file deny alone does not stop
   it.** Under `denylist`, `allowlist` and `prefs-file` (the allow-list plus
   `(deny file-read* file-write* (literal "~/Library/Preferences/dev.topnotch.TopNotch.plist"))`)
   a direct read of the file is refused, yet `./run.sh <profile> prefs-read dev.topnotch.TopNotch`
   gets all 8 keys through `UserDefaults(suiteName:)` and `CFPreferences`
   (values not printed), and `./run.sh <profile> prefs-write dev.topnotch.SpikeTest`
   writes keys that `defaults read dev.topnotch.SpikeTest` sees from outside.
   So a block can also write any other app's preferences. Denying the Mach
   services `com.apple.cfprefsd.daemon` and/or `com.apple.cfprefsd.agent`
   (either one alone, or both: profile `gate-dns-prefs`) stops the read and
   the persisted write, but breaks FoundationModels (`appleIntelligenceNotEnabled`);
   thumbnails and the proxy still work. The narrower SBPL operations do the job
   without breakage: `(deny user-preference-write)` plus
   `(deny user-preference-read (preference-domain "dev.topnotch.TopNotch"))`
   (`EXTRA='<those two>' ./run.sh gate-dns ...`): the TopNotch domain reads
   nothing, writes to any domain do not persist, the model answers (7.3 s)
   and all four thumbnails work. Denying every preference read breaks the
   model again (`appleIntelligenceNotEnabled`); reads of other apps' domains
   (`com.apple.finder`: 80 keys) stay open, a written limit.

**Not asked, found on the way (measured).** Quick Look bypasses the read
allow-list: `./run.sh allowlist thumb <path>` made a full thumbnail of a PNG
in the home folder that `./run.sh allowlist read <path>` refuses, and of
`~/Library/Preferences/.GlobalPreferences.plist`; a missing path gives
"doesn't exist". So a block can see a picture of any file it can name and
learn whether it exists (metadata reads in the home folder already allow the
second). Not closed here.

Profile that passed question 1 (`./run.sh allowlist --print`; `<HOME>`,
`<TMPDIR>` (real path) and `<PKG>` stand for this Mac's paths):

```
(version 1)
(allow default)
(deny network*)
(deny appleevent-send)
(deny file-write*)
(allow file-write* (subpath "<HOME>/Library/Application Support/TopNotchSpike/BlockData/dev.topnotch.spike") (subpath "<TMPDIR>") (subpath "/dev"))
(deny file-read* file-write* (subpath "<TMPDIR>/TopNotch"))
(allow file-read* file-write* (subpath "<TMPDIR>/TopNotch/Blocks/dev.topnotch.spike"))
(deny file-read*)
(allow file-read*
  (literal "/")
  (literal "/etc")
  (literal "/var")
  (literal "/tmp")
  (subpath "/System")
  (subpath "/usr")
  (subpath "/bin")
  (subpath "/sbin")
  (subpath "/Library/Apple")
  (subpath "/Library/Preferences")
  (subpath "/private/etc")
  (subpath "/private/var/db/timezone")
  (subpath "/private/var/db/dyld")
  (subpath "/private/var/db/eligibilityd")
  (subpath "/dev"))
(allow file-read* (subpath "<PKG>/Spike.topblock") (subpath "<HOME>/Library/Application Support/TopNotchSpike/BlockData/dev.topnotch.spike") (subpath "<TMPDIR>/TopNotch/Blocks/dev.topnotch.spike"))
(allow file-read-metadata (subpath "<HOME>"))
```

Profile that passed question 3 (`./run.sh gate --print`): the question 1
profile followed by

```
(deny network*)
(allow network-outbound (remote tcp "localhost:8899"))
```

Measured together with question 1 and the proxy (questions 4 and 5): the
question 3 profile plus `(deny mach-lookup (global-name "com.apple.dnssd.service"))`,
`(deny user-preference-write)` and
`(deny user-preference-read (preference-domain "dev.topnotch.TopNotch"))`
(`EXTRA='<the two preference rules>' ./q3.sh gate-dns`, `./run.sh gate-dns fm`,
`./thumbs.sh gate-dns`: all as in questions 3 and 1).
