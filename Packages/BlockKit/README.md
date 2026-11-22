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
`apple`, `ns`), `name`, `version`, `contract` (1; 2 to use drops, `item`
nodes, Quick Look and the other version 2 parts; 3 to name `hosts`),
`executable` (the product name), `events`, `settings`, `permissions`,
`access`, `hosts`. Raise `version` for each update.

`access` lists what the block may do beyond the default sandbox: `network`
(reach the hosts in `hosts`, over HTTPS), `files.read` (read files in the
home folder and under `/Volumes`), `files.screenshots` (read and write in
the screenshot folder). Leave it out when the block needs none of them. The
install sheet shows each token to the owner.

`hosts` lists the hosts a block with `network` may reach: exact names, such
as `api.example.com`, or `*.` and a domain, such as `*.example.org`.
`network` without `hosts` is refused, and so is `hosts` without `network`.
A bare `*` and `*.com` are refused.

Make every request with `ctx.urlSession`. It goes through the app's network
gate, which lets through only HTTPS to the hosts listed. A `URLSession` the
block builds itself (`URLSession.shared` included) does not work, and plain
`http://` does not either.

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
The block runs from where it is, sandboxed, with no signature check and no
approval. Rebuild, package and relaunch to try a change.

## 5. Install, update, remove

Open TopNotch Settings, Blocks, then "Install Block…" and choose the
`.topblock` folder. The sheet shows what the block listens to and needs;
"Install and Turn On" copies it to
`~/Library/Application Support/TopNotch/Blocks/<id>.topblock` and approves
that build.

The folder may have any name that ends in `.topblock`; the block's id comes
from the manifest.

A package put in the Blocks folder by hand does not run at once. It waits
on the Blocks page as New until the owner chooses "Review…" and approves it.
A package that changed after its approval waits as Changed and is asked
about again.

To update, build with a higher `version`, package again with the same
signing identity, and use "Update…" on the block's row (or "Install
Block…"). Its settings and data are kept.

"Remove" deletes the package, its data folder
(`~/Library/Application Support/TopNotch/BlockData/<id>`) and its settings.
A package built for another contract is refused with the version TopNotch supports.

## Sandbox and signing

The app starts every block under a sandbox profile built from its manifest.
Reads are allowed only from an allow-list: the system locations a process
needs, the block's package, its data folder, its own temporary folder, and
what its tokens open. There is no network except the gate to the hosts in
`hosts`, no name lookups, no Apple events, no preference writes, and no
writes outside the block's data folder and the temporary folder.

TopNotch's folders are closed whatever the tokens: the support folder
(`~/Library/Application Support/TopNotch`, with other blocks' packages and
data and the approvals), the app's preferences, and the `TopNotch` folder
inside the temporary folder, where dropped files and other blocks'
temporary folders are. Only the block's own folders in them stay open.

The sandbox has limits: it stops the plain cases, such as sending a file
away or writing over a document, but it is not a guarantee against a
determined attacker, because system services stay reachable. PROTOCOL.md
lists each limit under "Sandbox". The signature answers a different
question: who made the block.

To sign a package, set `BLOCK_SIGN_IDENTITY` to a code-signing identity in
your keychain when you run the script. `security find-identity -v -p
codesigning` lists them.

```sh
BLOCK_SIGN_IDENTITY="Apple Development: <your name> (<id>)" \
  "$TOPNOTCH/Packages/BlockKit/Scripts/package-block.sh" .build/debug/MyHello manifest.json build
```

Keep the identity in your shell, never in a file you commit.

- Without `BLOCK_SIGN_IDENTITY` the package is signed ad hoc. An ad hoc or
  unsigned package can be installed: the owner approves that exact build,
  and any change to it asks again.
- A package changed after signing is refused, at install and at every
  launch.
- The install sheet shows the signer and TopNotch stores it with the
  approval. An update must come from the same signer: an update signed by
  someone else, or an unsigned update of a signed block, is refused. To
  change signers, remove the block and install it again (its settings and
  data are deleted with it).
