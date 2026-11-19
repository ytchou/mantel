# TopNotch

A macOS notch app. The notch is an interactive surface; each capability is a
"block" that reacts to a system event (files dragged, screenshot taken).

Build plan and progress: https://claude.ai/artifact/CJvm9QRFba5KKMfgwaKENP

## Commands

Run from the repository root.

| Command | What it does |
|---|---|
| `make build` | Build the app (Debug) into `build/` |
| `make test` | Run all package unit tests |
| `make test FILTER=NotchCoreTests` | Run one module's tests |
| `make run` | Build, quit any running copy, launch |
| `make quit` | Quit the running app |
| `make clean` | Delete build output |

Use these, not bare `xcodebuild` or `swift test`.

## Layout and ownership

| Path | Owns | Must not |
|---|---|---|
| `App/` | Process start, wiring modules together | Hold any behaviour or UI logic |
| `Packages/NotchKit/Sources/NotchCore` | Block contract, event bus, arbiter | Import AppKit UI, any other module |
| `Packages/NotchKit/Sources/NotchShell` | Notch panel, idle/peek/expanded drawing, input forwarding | Know about any specific block |
| `Packages/NotchKit/Sources/EventSources` | System event sources that publish to the bus | Draw UI, call a block directly |
| `Packages/NotchKit/Sources/DemoBlock` | Demo block (hover, click and drop tester, on with `-demoBlock YES`); the template for new blocks | Import `NotchShell`, any other block |
| `Packages/NotchKit/Sources/ShelfBlock` | Shelf block (drop, hold, drag out) | Import `NotchShell`, `RenameBlock` |
| `Packages/NotchKit/Sources/RenameBlock` | Screenshot rename block | Import `NotchShell`, `ShelfBlock` |
| `Packages/NotchKit/Sources/NowPlayingBlock` | Now-playing block (track on a volume or track change) | Import `NotchShell`, any other block |
| `Helpers/NowPlayingHelper.m` | Library loaded into `/usr/bin/perl` to read macOS Now Playing; built into the app by the "Build now-playing helper" phase | Be linked into the app or the package |
| `Packages/NotchKit/Sources/PlatformServices` | Menu bar item, settings window, onboarding, launch at login | Import `NotchShell`, any block |
| `spikes/` | Throwaway experiments | Be imported by the app or the package |

Rules:

- A block depends on `NotchCore` only. It never touches the notch window or another block.
- All modules are already declared in `Packages/NotchKit/Package.swift`. Parallel
  work stays inside one module directory and does not edit the manifest or
  `TopNotch.xcodeproj`.
- Files added under `App/` are picked up by Xcode automatically (synchronized folder).

## Signing

- The app is not sandboxed, uses the hardened runtime, and targets macOS 26.
- It is signed with a stable Apple Development certificate. Do not switch to
  ad-hoc signing: macOS ties granted permissions to the signature and resets
  them when it changes.
- The team id lives in `Config/Local.xcconfig`, which is not committed. Copy
  `Config/Local.xcconfig.example` to create it.
- The bundle id is set in `Config/Signing.xcconfig`. Changing it also resets permissions.
