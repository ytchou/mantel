# TopNotch

A macOS notch app. The notch is an interactive surface; each capability is a
"block" that reacts to a system event (files dragged, screenshot taken).

Build plan and progress: https://claude.ai/artifact/CJvm9QRFba5KKMfgwaKENP

## Commands

Run from the repository root.

| Command | What it does |
|---|---|
| `make build` | Build the app (Debug) into `build/` |
| `make test` | Run the unit tests of all three packages, one after another |
| `make test FILTER=NotchCoreTests` | Run one module's tests in `Packages/NotchKit` |
| `make test PKG=Packages/BlockKit [FILTER=BlockKitTests]` | Run one package's tests, optionally one target |
| `make run` | Build, quit any running copy, launch |
| `make quit` | Quit the running app |
| `make clean` | Delete build output |

Use these, not bare `xcodebuild` or `swift test`.

Launch argument `-devBlock <path to .topblock>` runs one outside block from where
it is, without installing it: `make build`, then
`open build/Build/Products/Debug/TopNotch.app --args -devBlock <path to .topblock>`.

## Layout and ownership

| Path | Owns | Must not |
|---|---|---|
| `App/` | Process start, wiring modules together | Hold any behaviour or UI logic |
| `Packages/NotchKit/Sources/NotchCore` | Block contract, event bus, arbiter | Import AppKit UI, any other module |
| `Packages/NotchKit/Sources/NotchShell` | Notch panel, idle/peek/expanded drawing, input forwarding | Know about any specific block |
| `Packages/NotchKit/Sources/EventSources` | System event sources that publish to the bus | Draw UI, call a block directly |
| `Packages/NotchKit/Sources/BlockHost` | Stand-ins for blocks that run in their own process (`RemoteBlock`), process supervision, drawing a block's view from data, package validation, install, update and remove (`BlockStore`) | Import `NotchShell`, `PlatformServices`, any block |
| `Packages/NotchKit/Sources/DemoBlock` | Demo block (hover, click and drop tester, on with `-demoBlock YES`); the template for new in-process blocks | Import `NotchShell`, any other block |
| `Packages/NotchKit/Sources/ShelfBlock` | Shelf block (drop, hold, drag out) | Import `NotchShell`, `RenameBlock` |
| `Packages/NotchKit/Sources/RenameBlock` | Screenshot rename block | Import `NotchShell`, `ShelfBlock` |
| `Packages/BlockKit` | Separate package: the wire protocol (`BlockWire`, `PROTOCOL.md`), the kit block authors write against (`BlockKit`, `BlockKitTesting`), the `HelloBlock` example (the template for outside blocks) and `Scripts/package-block.sh`; see its `README.md` | Depend on `NotchKit`; import anything but Foundation in `BlockWire`, or anything but Foundation, CryptoKit and Dispatch in `BlockKit` |
| `Blocks/NowPlaying` | Separate package: the now-playing block (track on a volume or track change), run as its own process and bundled in the app | Be linked into the app; depend on `NotchKit` |
| "Build bundled blocks" build phase (`TopNotch.xcodeproj`) | Builds `Blocks/NowPlaying` and packages it into `Contents/Resources/Blocks/NowPlaying.topblock`, signed | Be skipped: it always runs |
| `Helpers/NowPlayingHelper.m` | Library loaded into `/usr/bin/perl` to read macOS Now Playing; built into the app by the "Build now-playing helper" phase | Be linked into the app or the package |
| `Packages/NotchKit/Sources/PlatformServices` | Menu bar item, settings window (including the Blocks page: install, update, remove through `BlockInstalling`), onboarding, launch at login | Import `NotchShell`, `BlockHost`, any block |
| `spikes/` | Throwaway experiments | Be imported by the app or the package |

Rules:

- An in-process block depends on `NotchCore` only. It never touches the notch window or another block.
- A block that runs in its own process depends on `BlockKit` only. In the app it is
  represented by a `RemoteBlock` stand-in from `BlockHost`, which depends on
  `NotchCore` and `BlockWire` only.
- There are three Swift packages: `Packages/NotchKit`, `Packages/BlockKit` and
  `Blocks/NowPlaying`. Parallel work stays inside one module directory. Only one
  worker at a time edits a `Package.swift` or `TopNotch.xcodeproj`.
- Files added under `App/` are picked up by Xcode automatically (synchronized folder).

## Signing

- The app is not sandboxed, uses the hardened runtime, and targets macOS 26.
- It is signed with a stable Apple Development certificate. Do not switch to
  ad-hoc signing: macOS ties granted permissions to the signature and resets
  them when it changes.
- The team id lives in `Config/Local.xcconfig`, which is not committed. Copy
  `Config/Local.xcconfig.example` to create it.
- The bundle id is set in `Config/Signing.xcconfig`. Changing it also resets permissions.
