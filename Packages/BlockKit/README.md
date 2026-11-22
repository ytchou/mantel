# BlockKit: write a TopNotch block

A block is a small program that adds one thing to the notch. Every block
runs as its own process, in a sandbox, and talks to TopNotch over the wire
protocol in [PROTOCOL.md](PROTOCOL.md). This kit does the talking for you.

This guide starts from an empty folder and ends with your block running in
TopNotch. It needs macOS 26 and Swift 6.2. Step 5 also needs a TopNotch
build: see the repository's [README](../../README.md).

The kit, the protocol and the Hello example are MIT ([LICENSE](LICENSE)).
A block you write with them is yours.

## 1. Make a package and add the kit by URL

```sh
mkdir -p ~/dev/my-hello && cd ~/dev/my-hello
mkdir -p Sources/MyHelloCore Sources/MyHello Tests/MyHelloTests
```

`Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyHello",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MyHello", targets: ["MyHello"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ytchou/topnotch.git", from: "0.1.0"),
    ],
    targets: [
        // The block itself, in a library so the tests can run it.
        .target(name: "MyHelloCore", dependencies: [
            .product(name: "BlockKit", package: "topnotch"),
        ]),
        // The entry point only.
        .executableTarget(name: "MyHello", dependencies: [
            "MyHelloCore",
            .product(name: "BlockKit", package: "topnotch"),
        ]),
        .testTarget(name: "MyHelloTests", dependencies: [
            "MyHelloCore",
            .product(name: "BlockKit", package: "topnotch"),
            .product(name: "BlockKitTesting", package: "topnotch"),
        ]),
    ]
)
```

The package is named `topnotch` after the repository; pass that as
`package:`. It has three products: `BlockKit` (what a block writes
against), `BlockKitTesting` (a fake app for tests) and `BlockWire` (the
protocol types, which `BlockKit` already brings in).

## 2. Copy Hello

Copy two files from this folder of the TopNotch repository:

- `Examples/HelloBlock/Hello.swift` to `Sources/MyHelloCore/Hello.swift`;
- `Examples/HelloBlock/manifest.json` to `manifest.json`, at the root of
  your package.

In `Hello.swift`, the block now lives in a library: remove `@main`, and
make the type and its initializer public:

```swift
public struct Hello: Block {
    public init() {}
    public func start(_ ctx: Context) { ... }
    ...
}
```

`Sources/MyHello/main.swift` runs it:

```swift
import BlockKit
import MyHelloCore

// Runs the block until the app sends `quit` or closes the socket.
await Hello.main()
```

In `manifest.json`, set `"id": "my-hello"`, `"name": "My Hello"` and
`"executable": "MyHello"` (the product name). Give every block its own id
and name: `hello` is the example's id, and TopNotch shows the example as
installed while any block with that id is present.

How a block is written:

- One type that conforms to `Block`. In `start(_ ctx:)`, listen with
  `ctx.on(.pointerHover) { event in ... }` and show a view with
  `ctx.present(peek: ViewSlot(...), for: seconds, dismissIfNotShown: true)`.
- Ignore events with `event.replay == true` for showing anything: they
  repeat state after a restart.
- Never write to stdout; use `ctx.log`.
- The view is data: a tree of nodes (`ViewNode`) that the app draws. The
  node kinds are in PROTOCOL.md under "View nodes".

## 3. Test with BlockKitTesting

`FakeHost` plays the app: it runs your block, answers its `hello`, sends it
events, and records what it sends back.

`Tests/MyHelloTests/HelloTests.swift`:

```swift
import BlockKit
import BlockKitTesting
import MyHelloCore
import Testing

struct HelloTests {
    @MainActor
    @Test func hoverShowsAPeek() async throws {
        let host = FakeHost()
        host.run(Hello())
        try await host.welcome()

        try host.send(.event(payload: .pointerHover(PointerHover(isInside: true)), replay: false))

        let shown = await host.waitFor { if case .present = $0 { true } else { false } }
        #expect(shown != nil)
    }
}
```

```sh
swift build
swift test
```

## 4. Package and sign

`swift build` checks the kit out into `.build/checkouts/topnotch`. The
packaging script is there:

```sh
swift build --product MyHello
.build/checkouts/topnotch/Packages/BlockKit/Scripts/package-block.sh \
  .build/debug/MyHello manifest.json build
```

This makes `build/MyHello.topblock`, a signed bundle named after the
manifest's `name` without spaces:

```
MyHello.topblock/Contents/Info.plist
MyHello.topblock/Contents/MacOS/MyHello
MyHello.topblock/Contents/Resources/manifest.json
```

The script signs with the identity in `BLOCK_SIGN_IDENTITY`. List yours
with `security find-identity -v -p codesigning`:

```sh
BLOCK_SIGN_IDENTITY="Apple Development: <your name> (<id>)" \
  .build/checkouts/topnotch/Packages/BlockKit/Scripts/package-block.sh \
  .build/debug/MyHello manifest.json build
```

Keep the identity in your shell, never in a file you commit.

Without `BLOCK_SIGN_IDENTITY` the package is signed ad hoc. The owner can
still approve it, but only that exact build: every rebuild waits for
approval again, and an ad hoc package can never update a signed block.
`BLOCK_SIGN_TIMESTAMP=none` signs without a secure timestamp, for offline
builds.

## 5. Run it without installing

In a TopNotch checkout:

```sh
make build
open build/Build/Products/Debug/TopNotch.app --args -devBlock ~/dev/my-hello/build/MyHello.topblock
```

The block runs from where it is, sandboxed, with no signature check and no
approval. Build, package and relaunch to try a change.

## 6. Install and approve

1. Copy the package into the Blocks folder:

   ```sh
   cp -R build/MyHello.topblock ~/Library/Application\ Support/TopNotch/Blocks/
   ```

2. Quit TopNotch and open it again.
3. Open Settings > Blocks. The block waits as New. Choose "Review…": the
   review sheet shows its signer, the events it listens to and what it may
   do. Choose "Approve and Turn On", and it runs.

"Install Block…" on the same page does steps 1 to 3 in one go: it shows
the same sheet and copies the package for you.

TopNotch runs an installed block only with the owner's approval of its
exact build, checked before every start. A package that changes after its
approval waits as Changed. A package changed after signing is refused.

To update, raise `version` in the manifest, package again with the same
signing identity, and use "Update…" on the block's row. Its settings and
data are kept: they belong to the block's id. An update signed by someone
else, or an unsigned update of a signed block, is refused. To change
signers, remove the block and install it again.

"Remove" deletes the package, its data folder
(`~/Library/Application Support/TopNotch/BlockData/<id>`) and its
settings.

## The manifest

`manifest.json` says what the block is. All fields are in PROTOCOL.md
under "Manifest".

- `id`: lowercase letters, digits and dashes. Not `block`, `onboarding`,
  `com`, `apple` or `ns`. Settings and data are kept by id.
- `name`, `version`, `executable`: what the owner sees, the block's own
  version (raise it for each update), the product name.
- `contract`: the protocol version, 1 to 3. Use 2 for drops, `item` nodes,
  Quick Look and the other version 2 parts; 3 to name `hosts`.
- `events`: the events the app sends the block.
- `settings`: toggles, choices and notes, drawn and stored by the app.
- `access` and `hosts`: below.

### `access`

What the block may do beyond the default sandbox. Leave it out when the
block needs none of it. The review sheet shows each token to the owner.

| Token | Lets the block |
|---|---|
| `network` | reach the hosts in `hosts`, over HTTPS, through the network gate |
| `files.read` | read files in the home folder and under `/Volumes` |
| `files.screenshots` | read and write in the screenshot folder |

### `hosts`

The hosts a block with `network` may reach: exact names, such as
`api.example.com`, or `*.` and a domain, such as `*.example.org`.
`network` without `hosts` is refused, and so is `hosts` without `network`.
A bare `*` and `*.com` are refused.

Make every request with `ctx.urlSession`. It goes through the block's
network gate, which lets through only HTTPS to the hosts listed. A
`URLSession` the block builds itself (`URLSession.shared` included) does
not work, and plain `http://` does not either.

### Events

| Event | Reveals | Permission |
|---|---|---|
| `pointerHover` | The pointer entered or left the notch | none |
| `dragStarted` | A drag is under way, and the kinds of things in it, never their content | none |
| `dragEnded` | A drag has ended, and the kinds of things in it, never their content | none |
| `screenshotCaptured` | The path and time of a new screenshot | the screenshot folder |
| `outputVolume` | The output volume and mute state | none |
| `nowPlaying` | Player, state, title, artist, artwork | none |

The review sheet shows the owner what each listed event reveals. The
payloads and the rules for a new event are in PROTOCOL.md under "Events".

A block that renames a screenshot sets the extended attribute
`com.topnotch.original-name` on the file, to the old name. A file with
this attribute is not reported as a new screenshot, so the renamed file
does not come back as `screenshotCaptured`.

## The sandbox and its limits

The app starts every block under a sandbox built from its manifest. Reads
come from an allow-list: the system locations a process needs, the block's
package, its data folder, its own temporary folder, and what its tokens
open. There is no network except the gate to the hosts in `hosts`, no name
lookups, no Apple events, no preference writes, and no writes outside the
block's data folder and the temporary folder.

TopNotch's own folders are closed whatever the tokens: the support folder
(`~/Library/Application Support/TopNotch`), the app's preferences, and the
`TopNotch` folder inside the temporary folder. Only the block's own
folders in them stay open.

The sandbox stops the plain cases, such as sending a file away or writing
over a document. It is not a guarantee against a determined attacker:
system services stay reachable. Each written limit is listed in
PROTOCOL.md under "Sandbox". The signature answers a different question:
who made the block.

The sandbox uses `sandbox-exec`, which Apple has deprecated. It works on
macOS 26. If Apple removes it, the sandbox needs another mechanism.

## More examples

The owner's blocks (Now Playing, Screenshot Names, Shelf) are in
[topnotch-blocks](https://github.com/ytchou/topnotch-blocks). Each follows
the layout above: a `<Name>Core` library, a `<Name>` executable, and tests
over `FakeHost`.
