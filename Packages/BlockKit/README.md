# BlockKit: write a TopNotch block

A block that is not built into TopNotch runs as its own process. It talks to
the app over the wire protocol in [PROTOCOL.md](PROTOCOL.md); this kit does
that for you. `Examples/HelloBlock` is the template. Below, `TOPNOTCH` is the
path of your TopNotch checkout.

## 1. Make a package, anywhere

```sh
mkdir -p ~/dev/hello-block/Sources/MyHello && cd ~/dev/hello-block
cp "$TOPNOTCH/Packages/BlockKit/Examples/HelloBlock/Hello.swift" Sources/MyHello/
cp "$TOPNOTCH/Packages/BlockKit/Examples/HelloBlock/manifest.json" .
```

In `manifest.json`, set `"id": "my-hello"`, `"name": "My Hello"` and
`"executable": "MyHello"`. The target must not be named `HelloBlock`: the kit
already has a target with that name, and SwiftPM refuses the duplicate.

`Package.swift` depends on the kit by path, absolute or relative:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyHello",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "/Users/you/project/topnotch/Packages/BlockKit"),
    ],
    targets: [
        .executableTarget(name: "MyHello", dependencies: [.product(name: "BlockKit", package: "BlockKit")]),
    ]
)
```

## 2. Write the block

One type marked `@main` that conforms to `Block`. In `start(_ ctx:)`,
listen with `ctx.on(.pointerHover) { event in ... }` and show a view with
`ctx.present(peek: ViewSlot(...), for: seconds, dismissIfNotShown: true)`.
Do not name the file `main.swift`. Ignore events with `event.replay == true`
for showing anything: they repeat state after a restart. Never write protocol
data to stdout; use `ctx.log`.

`manifest.json` says what the block is: `id` (lowercase letters, digits,
hyphens; not `shelf`, `rename`, `demo`, `nowplaying`, `block`,
`onboarding`), `name`, `version`, `contract` (1), `executable` (the
product name), `events`, `settings`, `permissions`. Raise `version` for each
update.

## 3. Build and package

```sh
swift build -c debug
"$TOPNOTCH/Packages/BlockKit/Scripts/package-block.sh" .build/debug/MyHello manifest.json build
```

This prints `build/MyHello.topblock`: `manifest.json` and the executable.

## 4. Run it without installing

```sh
cd "$TOPNOTCH" && make build
open build/Build/Products/Debug/TopNotch.app --args -devBlock ~/dev/hello-block/build/MyHello.topblock
```
The block runs from where it is. Rebuild, package and relaunch to try a change.

## 5. Install, update, remove

Open TopNotch Settings, Blocks, then "Install Block…" and choose the
`.topblock` folder. The sheet shows what the block listens to and needs;
"Install and Turn On" copies it to
`~/Library/Application Support/TopNotch/Blocks/<id>.topblock`.

To update, build with a higher `version`, package again, and use "Update…" on
the block's row (or "Install Block…"). Its settings and data are kept.

"Remove" deletes the package, its data folder
(`~/Library/Application Support/TopNotch/BlockData/<id>`) and its settings.
A package built for another contract is refused with the version TopNotch supports.
