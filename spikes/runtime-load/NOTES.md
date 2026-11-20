# Spike: load a block built outside the app (DEV-2065 phase 5, pd-a1..pd-a3)

Throwaway. Question: can a block that is built outside the app be loaded from a
folder at launch, and what does that cost in signing, versioning and safety?

Run on 2026-11-19: macOS 26.5.1, Apple silicon (M1 Pro), Xcode 26.3
(Swift 6.2.4). Second compiler: Xcode 26.6 (Swift 6.3.3).

Status words: **Measured** = observed in a run of `run.sh`. **Not measured** =
the reason is given.

## How to run

```sh
spikes/runtime-load/run.sh            # ~60 s; builds and runs everything
cat spikes/runtime-load/.build/results.txt
GATEKEEPER_TESTS=1 spikes/runtime-load/run.sh   # also other-team + quarantine cases (see warning)
```

- Uses the first "Apple Development" identity in the keychain, picked at run
  time (override with `SIGN_ID=<sha1>`, `OTHER_SIGN_ID=<sha1>`). Nothing about
  the identity is written to disk; team ids are masked in the output.
- Everything goes to `.build/` (git-ignored). Full logs: `.build/logs/`.
- **Warning:** `GATEKEEPER_TESTS=1` makes macOS show Gatekeeper dialogs and
  move the test plugins to the Trash. It is off by default for that reason.
- Crashing runs make macOS write crash reports to
  `~/Library/Logs/DiagnosticReports/tn-spike-*`; the script deletes the ones it
  caused.

## How it works

| Piece | What it is |
|---|---|
| `Sources/Contract/Contract.swift` | `libBlockContract.dylib`: small copy of the contract. `@MainActor` class-bound `PluginBlock` protocol, `BlockContext` protocol, value types `BlockInfo`, `NotchInput` (enum), `Presentation` with `makeView: () -> AnyView`. Variants for the skew tests are `-D` flags in the same file. |
| `Sources/Host/main.swift` | `tn-spike-host <folder>`: lists `*.topblock` bundles, reads the manifest (`Info.plist`: `TNBlockID`, `TNContractVersion`) without running plugin code, `dlopen(RTLD_NOW)`s the bundle executable, `dlsym`s `topnotch_block_entry`, casts the returned object to `any PluginBlock`, calls `id/title/info/activate/handle`, then renders the presented SwiftUI view with `ImageRenderer`. |
| `Sources/HelloPlugin/` | Well-behaved plugin, built as its own product against the contract. |
| `Sources/EvilPlugin/` | pd-a3 proofs (`EVIL_MODE=read|swizzle|hang|crash`) plus a C constructor. Touches only `.build/tmp/`. |
| `Sources/RealHost/`, `Sources/RealDemoPlugin/` | The **real** `NotchCore` sources compiled as a dylib with library evolution, the **real, unchanged** `DemoBlock.swift` built as a plugin against only the `.swiftinterface`, driven through the real `NotchRuntime`. |

Loader choice: **`dlopen` + one `@_cdecl` C entry symbol**, with the code in a
`.bundle`-shaped folder. Why: `dlopen` returns dyld's exact error text (needed
here, and useful in a "this block failed to load" UI); a C symbol does not
depend on the Objective-C runtime or `NSPrincipalClass`; the bundle shape gives
an `Info.plist` manifest the host reads before any plugin code runs, and is
what `codesign` signs as a unit. `Bundle.load()` would work too (it calls
`dlopen`), but hides the dyld message behind an `NSError`.

How the spike contract differs from real `NotchCore`: string ids instead of
`BlockID`; `handle` returns a `String` so misbehaviour is visible; no
`subscribe`/events, `dismiss`, `ownsNotch`, `actions`, `settingsPane`;
`Presentation` has one view instead of peek/wing/expanded; Swift 5 language
mode. The real-NotchCore run below covers the real shape.

## pd-a1: load a block from a folder at launch

| Check | Status | Result |
|---|---|---|
| Host finds plugin in a folder, loads it, creates the block, calls it, gets a SwiftUI view back | **Measured** | Hardened, Apple-Development-signed host loads a plugin signed with the same identity. `activate` presents; `handle(.click)` -> `click #1`; view rendered 200x40 px. |
| Load time, warm (runs 2-5) | **Measured** | `dlopen` 0.36-0.53 ms; entry + cast 0.07-0.10 ms; `activate` 0.04 ms; first SwiftUI render 38-50 ms; folder-to-rendered-view 38-50 ms. |
| Load time, first load of a new binary | **Measured** | `dlopen` 215 ms and 429 ms (two separate builds), folder-to-view 284 / 516 ms. The system log shows `syspolicyd` scanning the new binary (XProtect + an online notarization lookup) on first `dlopen`. Paid once per new binary, not per launch. |
| Real `NotchCore` + real `DemoBlock` loaded from a folder | **Measured** | `DemoBlock.topblock` built against only `NotchCore.swiftinterface` + `libNotchCore.dylib`; registered in the real `NotchRuntime`; hover -> owner `demo`, level `expanded`; 2 clicks + a file drop via `runtime.send`; rendered view shows "Clicks: 2 / Dropped: example.png" (`.build/tmp/demoblock.png`). `dlopen` 375 ms (first load). |

## pd-a2: what it needs

### Signing, hardened runtime, library validation

Host: `codesign --options runtime` (flags `0x10000(runtime)`), Apple
Development identity. Contract dylib signed with the same identity.

| Plugin signature | Host: hardened, library validation ON | Host: hardened + `com.apple.security.cs.disable-library-validation` |
|---|---|---|
| (a) unsigned (`codesign --remove-signature`) | **Measured: rejected.** `... not valid for use in process: Trying to load an unsigned library` | **Measured: rejected**, same text. Apple silicon never maps unsigned code. |
| linker-signed (what `swiftc` leaves; ad-hoc) | **Measured: rejected.** `... not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs` | **Measured: loads and works.** |
| (b) ad-hoc (`codesign -s -`) | **Measured: rejected**, same "different Team IDs" text. | **Measured: loads and works.** |
| (c) same Apple Development identity | **Measured: loads and works.** | **Measured: loads and works.** |
| (d) different identity, different team (an Apple Distribution certificate on this Mac) | **Measured (first run only): rejected** with `... not valid for use in process: library load disallowed by system policy`. `syspolicyd` logged `Attempting to move malware to trash`, moved the bundle to the Trash and showed a dialog. Took 6.4 s. | **Not measured:** the bundle had already been moved to the Trash by the LV-on run. |
| Quarantined (`com.apple.quarantine` xattr, as if downloaded) + same identity | **Measured (first run only): rejected**, `library load disallowed by system policy`; Gatekeeper dialog shown (`Prompt shown (6, 0)`); bundle later gone. 1.7 s. | **Not measured:** bundle gone before this run. |
| Quarantined + ad-hoc | **Measured (first run only): rejected**, `library load disallowed by system policy`; dialog; 4.9 s. | **Measured (first run only): rejected**, same text. DLV does not bypass Gatekeeper. |

The kernel log names the two separate gates: `AppleMobileFileIntegrity:
Library Validation failed ... reason: mapping process and mapped file have
different Team IDs` (library validation, turned off by the entitlement) and
`AppleSystemPolicy: Library load ... rejected` (Gatekeeper, not turned off by
the entitlement). No system security setting was changed.

Side effect to know: on the first run `syspolicyd` logged five
`Prompt shown ... waiting for response` (Gatekeeper dialogs on screen). It
logged moving the other-team bundle to the Trash; the two quarantined bundles
also disappeared from `.build/`, with no log line naming the cause (probably
the dialog's move-to-Trash button). `~/.Trash` is not readable from this
shell, so this is not confirmed and the Trash was not emptied. These cases are
now behind `GATEKEEPER_TESTS=1`.

### Version skew

The plugin binary is built once against contract v1. Then only the contract
dylib and the host are rebuilt with a change, and the old plugin is loaded.
No signing involved (host not hardened) to isolate the ABI effect.

| Change | Without library evolution | With `-enable-library-evolution` |
|---|---|---|
| none (v1 / v1) | **Measured:** works | **Measured:** works |
| (1) add protocol requirement with default impl (`priorityHint`) | **Measured: crash** (SIGSEGV, exit 139) when the host calls the new requirement through the old plugin's witness table. No message. | **Measured: works**; old plugin gets the default (`priorityHint=42`). |
| (2) add a stored property to a public struct (`BlockInfo.trigger`, old init kept) | **Measured: loaded and appeared to work** (`trigger=(default)`). The old plugin and the new library disagree on the struct's size; this is undefined behaviour that happened not to show. Not safe to rely on. | **Measured: works** (`trigger=(default)`). |
| (3) add an enum case (`NotchInput.hover`), sent to the old plugin | **Measured: crash** (SIGSEGV) when the new case reaches the old plugin's `switch`. | **Measured: works**; the old plugin's `@unknown default` handles it. |
| (4a) reorder: swap two struct fields and two protocol requirements | **Measured: loads and misbehaves silently:** `id=Hello title=hello` (id and title swapped). | **Measured: works** (correct values). |
| (4b) remove a method the plugin calls (`BlockContext.log`) | **Measured: crash** (SIGSEGV) when the plugin calls it. | **Measured: refused at load, no crash:** `Symbol not found: _$s13BlockContract0A7ContextP3logyySSFTj` / `Referenced from: <uuid> .../HelloPlugin` / `Expected in: <uuid> .../libBlockContract.dylib` |
| Compiler mismatch: plugin built by Swift 6.3.3, host + contract by 6.2.4 | **Measured: plugin does not build:** `module compiled with Swift 6.2.4 cannot be imported by the Swift 6.3.3 compiler` | **Measured: works** (plugin built from the `.swiftinterface`). Older compiler against a newer interface: **Not measured** (no older Xcode installed). Swift runtime mismatch: **Not measured**; both use the OS runtime in `/usr/lib/swift`. |

`blockContractVersion` is `@inlinable`, so the plugin reports the version it
was built against (`plugin-built-against-contract=1 host-contract=2`) and the
host can refuse old plugins before calling them. That check runs after
`dlopen`, so the plugin's static constructors have already run (see pd-a3);
the manifest version in `Info.plist` is the pre-load check.

### Real NotchCore as a shared dynamic library

| Check | Status | Result |
|---|---|---|
| Real `NotchCore/*.swift` builds as a dylib with `-enable-library-evolution` (Swift 6 mode) and emits a `.swiftinterface` | **Measured** | Builds, 0 warnings. |
| Real `DemoBlock.swift`, unchanged, builds against it in Swift 6 mode | **Measured: no.** | `error: switch covers known cases, but 'NotchInput' may have additional unknown values` (DemoBlock.swift:52) and the same for `DroppedItem` (line 78). With evolution, public enums are non-frozen, and Swift 6 requires `@unknown default`. In Swift 5 mode these are warnings and it builds. |
| It loads and runs through the real `NotchRuntime` | **Measured** | See pd-a1. |

What would have to change to ship this:

1. `NotchCore` becomes a dynamic library or framework built with library
   evolution (`BUILD_LIBRARY_FOR_DISTRIBUTION=YES`, or in `Package.swift`
   `.library(name: "NotchCore", type: .dynamic, ...)` plus
   `-enable-library-evolution`), embedded once in the app. The app, shell and
   built-in blocks must link that same copy. A second, static copy would make
   a second set of types; **Not measured** here.
2. For each public enum, decide: `@frozen` (can never gain a case) or
   non-frozen (every block needs `@unknown default`; built-in blocks need that
   change too).
3. Treat the `.swiftinterface` as public API: no removals or renames, new
   protocol requirements only with defaults.

### What a block author needs

**Measured** (that this set was enough): `NotchCore.swiftinterface` +
`libNotchCore.dylib` (no binary `.swiftmodule`, no sources), Xcode with a
Swift compiler at least as new as the one that produced the interface (6.3.3
read a 6.2.4 interface), the macOS 26 SDK, one exported C entry symbol, and a
bundle with an `Info.plist` manifest. Signing: see the table; with library
validation on, the block must be signed by the app's own team.

## pd-a3: what a bad block can do

All proofs ran with the plugin signed by the same identity, in a hardened host
with library validation on: signing says who built it, not what it does.

| Proof | Status | Result |
|---|---|---|
| Runs code before the host asks | **Measured** | A C `__attribute__((constructor))` wrote `.build/tmp/ctor-ran.txt` during `dlopen`, before the host looked up any symbol or checked any version. In every mode. |
| Reads any file the host can read, and writes elsewhere | **Measured** | Read `.build/tmp/host-secret.txt` (a canary the script created) and wrote it to `.build/tmp/exfil.txt`. A real block has the user's file access plus every TCC permission the app holds. TCC inheritance itself: **Not measured** (the spike host is a CLI; TCC charges the terminal). |
| Changes host internals | **Measured** | Replaced `TNHostLicense.isPro` through the Objective-C runtime: host printed `false` before load, `true` after. |
| Freezes the host | **Measured** | A 3 s sleep in `activate` blocked the host's main thread: `activate-ms=3005`. The host cannot interrupt a call into the block. |
| Takes the host down | **Measured** | `fatalError` in `activate` killed the host: exit 133 (SIGTRAP), `EvilBlock.swift:33: Fatal error: evil block crashed on purpose`. The skew crashes above (SIGSEGV) kill it the same way. |

Not demonstrated, but available to any in-process code: network access, reading
the host's memory and keychain items the app can reach, calling `exit()`,
swizzling AppKit/SwiftUI methods, starting other processes.

## Not measured, and why

- Different-team plugin and quarantined same-identity plugin with
  library validation disabled: macOS moved the bundles away during the first
  run; re-running shows more dialogs on the user's screen.
- A notarized plugin (would show whether notarization lets a quarantined
  plugin load): needs a Developer ID certificate and notarization, not
  available.
- A static and a dynamic copy of the contract in one process.
- Older compiler reading a newer interface; Swift runtime mismatch.
- TCC permissions inherited by a plugin in the real (app-bundle) host.
