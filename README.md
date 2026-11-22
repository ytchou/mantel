# Mantel

Mantel is a macOS app that turns the notch into an interactive surface.
Each capability is a block: a small program that reacts to a system event,
such as a screenshot taken or files dragged, and shows something in the
notch.

Mantel is source-available, under the Sustainable Use License. The kit
for block authors is MIT. See [Licenses](#licenses).

## Blocks

Mantel ships with no blocks. On first launch, onboarding and the empty
Blocks page offer the example block (Hello), which installs through the
same review sheet as any other block.

The owner's blocks (Now Playing, Screenshot Names, Shelf) live in their own
repository, [mantel-blocks](https://github.com/ytchou/mantel-blocks).
Its README says how to build, package and install them.

To write a block, read [Packages/BlockKit/README.md](Packages/BlockKit/README.md).
It starts from an empty folder.

## Build from source

Needs macOS 26, Xcode with Swift 6.2, and an Apple Development certificate.

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set
   your Apple team id in it. The file is not committed.
2. Build and test:

   ```sh
   make build   # the app (Debug) into build/
   make test    # the unit tests of every package
   ```

3. Open `build/Build/Products/Debug/Mantel.app`, or run `make run`.

The app is signed with a stable Apple Development certificate. macOS ties
the permissions you grant to the signature, so ad hoc signing resets them
at every build.

## Security model

Every block runs as its own process, under a sandbox the app builds from
the block's manifest. A block asks for what it needs in its manifest's
`access` list (`network`, `files.read`, `files.screenshots`). Without a
token it gets no network, no reads in the home folder, and no writes
outside its own folders. A block with `network` reaches only the hosts its
manifest names, over HTTPS, through a gate in the app.

An installed block runs only after the owner approves its exact build. A
changed package waits for approval again. An update must come from the
same signer as the installed block.

The sandbox stops the plain cases, such as sending a file away or reading
another block's data. It is not a guarantee against a determined attacker.
Its limits are listed in [PROTOCOL.md](Packages/BlockKit/PROTOCOL.md),
under "Sandbox".

### Risk: `sandbox-exec`

The sandbox uses `sandbox-exec`, which Apple has deprecated. It works on
macOS 26. If Apple removes it, the sandbox needs another mechanism.

## Licenses

- The app and everything else in this repository, except
  `Packages/BlockKit` and the root `Package.swift`: the Sustainable Use License, in
  [LICENSE.md](LICENSE.md). You may use, change and share Mantel for
  your own internal business purposes or for non-commercial or personal
  use. You may not sell it.
- `Packages/BlockKit` (the kit, the wire protocol and the Hello example)
  and the root `Package.swift` (the kit's manifest, for adding it by URL):
  MIT, in [Packages/BlockKit/LICENSE](Packages/BlockKit/LICENSE). A block
  compiled with the kit belongs to its author, who may share or sell it.

This summary is not legal advice; the license files are the terms.

## Contributing

Outside contributions are not open yet. See [CONTRIBUTING.md](CONTRIBUTING.md).
