# Mantel

A macOS notch app. The notch is an interactive surface; each capability is a
"block" that reacts to a system event (files dragged, screenshot taken).

Build plan and progress: https://claude.ai/artifact/CJvm9QRFba5KKMfgwaKENP

## Commands

Run from the repository root.

| Command | What it does |
|---|---|
| `make build` | Build the app (Debug) into `build/` |
| `make test` | Run the unit tests of both packages, one after another, then build the root `Package.swift` |
| `make test FILTER=NotchCoreTests` | Run one module's tests in `Packages/NotchKit` |
| `make test PKG=Packages/BlockKit [FILTER=BlockKitTests]` | Run one package's tests, optionally one target |
| `make run` | Build, quit any running copy, launch |
| `make quit` | Quit the running app |
| `make clean` | Delete build output, the root `.build` and each package's `.build` |

Use these, not bare `xcodebuild` or `swift test`.

After a change to the wire protocol (`BlockWire`), an existing build folder may
hold a stale nested block build. Run `make clean` once, then build again.

Launch argument `-devBlock <path to .mantelblock>` runs one block from where it
is, without installing it (sandboxed, no signature check): `make build`, then
`open build/Build/Products/Debug/Mantel.app --args -devBlock <path to .mantelblock>`.

## Layout and ownership

| Path | Owns | Must not |
|---|---|---|
| `App/` | Process start, wiring modules together | Hold any behaviour or UI logic |
| `Packages/NotchKit/Sources/NotchCore` | Block contract, event bus, arbiter (priority, then the owner's block order; the guard on `interactive`), which events have a listener | Import AppKit UI, any other module |
| `Packages/NotchKit/Sources/NotchShell` | Notch panel, idle/peek/expanded drawing, input forwarding | Know about any specific block |
| `Packages/NotchKit/Sources/EventSources` | System event sources that publish to the bus, started only while a turned-on block listens | Draw UI, call a block directly |
| `Packages/NotchKit/Sources/BlockHost` | Stand-ins for the block processes (`RemoteBlock`), process supervision, the sandbox each block runs under (`SandboxProfile`), each block's network gate (`NetworkGate`), the memory and processor watch (`ResourceWatch`), drawing a block's view from data (items, drag-out, Quick Look), package validation, the package signature check (`PackageSignature`), the owner's approvals (`ApprovalStore`) and blocks waiting for review (`PendingBlock`), what each event reveals (`EventCatalog`), install, update and remove (`BlockStore`) | Import `NotchShell`, `PlatformServices`, any block |
| `Packages/BlockKit` | Separate package: the wire protocol (`BlockWire`, `PROTOCOL.md`), the kit block authors write against (`BlockKit`, `BlockKitTesting`), the `HelloBlock` example (the template for new blocks) and `Scripts/package-block.sh`; see its `README.md` | Depend on `NotchKit`; import anything but Foundation in `BlockWire`, or anything but Foundation, CryptoKit and Dispatch in `BlockKit` |
| `Package.swift` (repository root) | The kit for authors who add it by URL (identity `mantel`): `BlockWire`, `BlockKit`, `BlockKitTesting` from `Packages/BlockKit/Sources` | Declare anything else; differ from `Packages/BlockKit/Package.swift` in targets, dependencies or settings (both change together) |
| "Build example block" build phase (`Mantel.xcodeproj`) | Builds `HelloBlock` from `Packages/BlockKit` and packages it with `package-block.sh` into `Contents/Resources/Examples/Hello.mantelblock`, signed with the app's identity; onboarding and the empty Blocks page offer it | Be skipped: it always runs |
| `Helpers/NowPlayingHelper.m` | Library loaded into `/usr/bin/perl` to read macOS Now Playing; built into the app by the "Build now-playing helper" phase | Be linked into the app or the package |
| `Packages/NotchKit/Sources/PlatformServices` | Menu bar item, settings window (including the Blocks page: install, update, remove through `BlockInstalling`), onboarding, launch at login | Import `NotchShell`, `BlockHost`, any block |
| `spikes/` | Throwaway experiments | Be imported by the app or the package |

Rules:

- The app ships with no blocks. The owner's blocks (Now Playing, Screenshot
  Names, Shelf) live in github.com/ytchou/mantel-blocks, cloned beside
  this repository (for example `~/project/mantel-blocks`), with the collision
  tests that run the real blocks behind their stand-ins. Run those with
  `MANTEL=<path to this checkout> make test` there.
- Every block runs as its own process, sandboxed, and talks to the app over the
  wire protocol. The app links no block code, and no target in this
  repository links a block. A block depends on `BlockKit` only. In the app it is represented by a `RemoteBlock` stand-in from
  `BlockHost`, which depends on `NotchCore` and `BlockWire` only.
- A new block starts from the `HelloBlock` example in `Packages/BlockKit`.
- A block's sandbox comes from its manifest's `access` list (`network`,
  `files.read`, `files.screenshots`). Reads come from an allow-list: system
  locations, the block's package, data folder and own temporary folder, and
  what its tokens open. Without a token it gets no network, no reads in the
  home folder and no writes outside its data folder and the temporary folder.
- `network` reaches only the hosts in the manifest's `hosts`, over HTTPS,
  through the block's `NetworkGate`. Name lookups are closed.
- Mantel's preferences domain, its preferences file and its support folder
  are closed to every block, `files.read` included, except the block's own
  package and data folder.
- The app's `<TMPDIR>/Mantel/` subtree is closed to reads and writes
  except the block's own `Mantel/Blocks/<id>/`. Files the app wrote for a
  drop are moved into that folder before the drop is sent. Dropped files the
  block's sandbox cannot read where they are are copied there.
- The limits the sandbox leaves are listed once, in `SandboxProfile`'s
  header and in `PROTOCOL.md` under "Sandbox".
- Between presentations of equal priority, the block higher in the owner's
  order on the Blocks page gets the notch. No order is written in code: with
  none stored, installed blocks rank in install order, which is stored at
  each install, then the development block. A new block goes to the end.
- There are two Swift packages, `Packages/NotchKit` and `Packages/BlockKit`,
  plus the root `Package.swift`, which declares the kit for authors. Parallel
  work stays inside one module directory. Only one worker at a time edits a
  `Package.swift` or `Mantel.xcodeproj`.
- Files added under `App/` are picked up by Xcode automatically (synchronized folder).

## Signing

- The app is not sandboxed, uses the hardened runtime, and targets macOS 26.
- It is signed with a stable Apple Development certificate. Do not switch to
  ad-hoc signing: macOS ties granted permissions to the signature and resets
  them when it changes.
- The team id lives in `Config/Local.xcconfig`, which is not committed. Copy
  `Config/Local.xcconfig.example` to create it.
- The bundle id is set in `Config/Signing.xcconfig`. Changing it also resets permissions.
  It was changed to `dev.mantel.Mantel` on 2026-11-22, before going public.
- The example block is signed with the app's identity: the "Build example
  block" phase passes `EXPANDED_CODE_SIGN_IDENTITY` to `package-block.sh` as
  `BLOCK_SIGN_IDENTITY`. Installed from onboarding or the Blocks page, it is
  an installed block like any other: approved for its exact build.
- An installed block runs only with the owner's approval of its exact build.
  The approval is a SHA-256 over the package, kept in `Approvals.json` in
  the support folder (`~/Library/Application Support/Mantel`). It is
  checked before every start.
- A package found in the Blocks folder without an approval waits as New. A
  package changed since its approval waits as Changed. Neither runs until
  the owner approves it.
- The signer is stored with the approval. An update must come from the same
  signer as the installed block. An unsigned or ad hoc package can be
  approved, for that exact build, but never as an update of a signed block.
- A package changed after signing is always refused. The signature check
  runs at install, at approval and at every launch.
- Blocks from earlier versions, whose signer was kept in the preferences,
  are approved once as they are when the signer still matches.
- `-devBlock` needs no approval and has no signature check.
- Never write a signing identity or team id into the repository, tests,
  commits or PR text. Tests sign ad hoc only.
