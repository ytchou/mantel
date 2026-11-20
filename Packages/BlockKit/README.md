# BlockKit: write a TopNotch block

Every TopNotch block, the bundled ones included, runs as its own process in
a sandbox. It talks to the app over the wire protocol in
[PROTOCOL.md](PROTOCOL.md); this kit does that for you. `Examples/HelloBlock` is the template. Below, `TOPNOTCH` is the
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
hyphens; not `shelf`, `rename`, `nowplaying`, `block`, `onboarding`, `com`,
`apple`, `ns`), `name`, `version`, `contract` (1, or 2 to use drops, `item`
nodes, Quick Look and the other version 2 parts), `executable` (the product
name), `events`, `settings`, `permissions`, `access`. Raise `version` for each
update.

`access` lists what the block may do beyond the default sandbox: `network`
(open outbound connections), `files.read` (read files in the home folder),
`files.screenshots` (read and write in the screenshot folder). Leave it out
when the block needs none of them. The install sheet shows each token to the
owner.

## 3. Build and package

```sh
swift build -c debug
"$TOPNOTCH/Packages/BlockKit/Scripts/package-block.sh" .build/debug/MyHello manifest.json build
```

This prints `build/MyHello.topblock`, a signed bundle named after the
manifest's `name` without spaces:

```
MyHello.topblock/Contents/Info.plist
MyHello.topblock/Contents/MacOS/MyHello
MyHello.topblock/Contents/Resources/manifest.json
```

Without `BLOCK_SIGN_IDENTITY` the bundle is signed ad hoc; see "Sandbox and
signing". A package in the old flat layout (`manifest.json` beside the
executable) is refused: package it again with this script.

## 4. Run it without installing

```sh
cd "$TOPNOTCH" && make build
open build/Build/Products/Debug/TopNotch.app --args -devBlock ~/dev/hello-block/build/MyHello.topblock
```
The block runs from where it is, sandboxed, with no signature check.
Rebuild, package and relaunch to try a change.

## 5. Install, update, remove

Open TopNotch Settings, Blocks, then "Install Block…" and choose the
`.topblock` folder. The sheet shows what the block listens to and needs;
"Install and Turn On" copies it to
`~/Library/Application Support/TopNotch/Blocks/<id>.topblock`.

To update, build with a higher `version`, package again with the same
signing identity, and use "Update…" on the block's row (or "Install
Block…"). Its settings and data are kept.

"Remove" deletes the package, its data folder
(`~/Library/Application Support/TopNotch/BlockData/<id>`) and its settings.
A package built for another contract is refused with the version TopNotch supports.

## Sandbox and signing

The app starts every block under a sandbox profile built from its manifest:
no network, no Apple events, no reads in the home folder, and no writes
outside the block's data folder and the temporary folder, unless an `access`
token lifts that rule. This is a deny list, and it has a limit: it stops the
plain cases, such as sending a file away or writing over a document, but it
is not a guarantee against a determined attacker, because system services
stay reachable. The signature answers a different question: who made the
block.

To sign a package, set `BLOCK_SIGN_IDENTITY` to a code-signing identity in
your keychain when you run the script. `security find-identity -v -p
codesigning` lists them.

```sh
BLOCK_SIGN_IDENTITY="Apple Development: <your name> (<id>)" \
  "$TOPNOTCH/Packages/BlockKit/Scripts/package-block.sh" .build/debug/MyHello manifest.json build
```

Keep the identity in your shell, never in a file you commit.

- Without `BLOCK_SIGN_IDENTITY` the package is signed ad hoc. An ad hoc or
  unsigned package runs with `-devBlock`, but TopNotch installs it only when
  the owner turns on "Allow blocks without a signature" on the Blocks page.
- A package changed after signing is refused, at install and at every
  launch, whatever the switch says.
- The install sheet shows the signer and TopNotch stores it. An update must
  come from the same signer: an update signed by someone else, or not
  signed, is refused. To change signers, remove the block and install it
  again (its settings and data are deleted with it).
