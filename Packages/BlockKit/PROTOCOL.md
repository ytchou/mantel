# TopNotch block protocol, version 2

A block is a separate program. The app starts it in a sandbox, sends it
events, and draws the view the block sends back as data. This file describes
the messages between the app and a block. `BlockWire` implements it;
`BlockKit` wraps it for Swift authors.

## Version

- The protocol version is one integer. This document is version 2.
- A block names its version in `manifest.json` (`contract`) and in `hello`.
- The app accepts versions 1 to 2. It refuses any other version and names the
  versions it supports.
- Version 2 is additive. Every version 1 frame is a valid version 2 frame
  with the same bytes; version 2 only adds node kinds, messages and optional
  fields. A field that is not set is left out, so a version 1 tree encodes as
  in version 1.
- The app sends version 2 messages and fields (`event` `seq`, the new `input`
  kinds) only to a block whose `hello` said 2.
- The test `wireV1MatchesGoldenFile` pins version 1 against
  `Tests/BlockWireTests/Fixtures/wire-v1.json`. `goldenV2RoundTrips` pins
  version 2 against `Tests/BlockWireTests/Fixtures/golden-v2.json`. Any other
  change to the bytes below is a new version.

## Transport

- The app creates a Unix stream socket pair. The block gets one end as file
  descriptor 3.
- The app starts the block as `/usr/bin/sandbox-exec -p <profile>
  <executable>`. The sandbox keeps file descriptor 3 open. See "Sandbox".
- Stdin and stdout are not used. A stray `print` cannot break the protocol.
- When the app closes its end, the block must exit.
- The environment holds `PATH`, `HOME`, `TMPDIR` (the app's temporary
  folder) and `TOPNOTCH_BLOCK_GENERATION`, the process generation.

## Frames

- A frame is a 4-byte length, little-endian, then a body of that many bytes.
- The body is one envelope, encoded as UTF-8 JSON.
- A body may be at most 4 MB (4,194,304 bytes). A larger length is refused
  from the header, before the body is read.
- A frame cut short, or a body that is not a valid envelope, is an error. It
  is never skipped. The app counts it as a block failure.

## Envelope

```json
{"generation": 7, "message": {"pong": {"seq": 3}}}
```

- `generation`: an integer. The app gives each block process a new one. It
  drops frames that carry an old generation.
- `message`: an object with exactly one key, the message name. Its value is
  an object with the message fields. A message with no fields has `{}`.
- The block sends `hello` with the generation from
  `TOPNOTCH_BLOCK_GENERATION` (0 when it is not set), and every later frame
  with the generation of the app's `welcome`.
- Fields that are not set are left out. Keys are written in sorted order.
- An enum value with fields is an object with one key, as a message is:
  `{"file": {"path": "/tmp/a.png"}}`. One without fields has `{}`:
  `{"click": {}}`.

## Block to app

| Message | Fields | Meaning |
|---|---|---|
| `hello` | `contract` int, `id` string, `version` string | The first frame. Sent before anything else. `id` must be the manifest's `id`. |
| `pong` | `seq` int | The answer to `ping`, with the same `seq`. |
| `present` | `priority`, `peek`?, `wing`?, `expanded`?, `opensAt`, `seconds`?, `dismissIfNotShown` bool, `accepts`? (v2), `answering`? (v2) | Ask for the notch. At least one slot is set. |
| `update` | `peek`?, `wing`?, `expanded`? (trees, no sizes) | Replace the trees of the current presentation. Sizes stay as presented. |
| `dismiss` | none | Give the notch back. |
| `asset` | `id` string, `bytes` base64 string | Image bytes (PNG or JPEG), referred to by `image` nodes and `item` drag images. |
| `actions` | `items`: list of `{id, title, enabled}` | The block's menu actions. Replaces the previous list. |
| `log` | `text` string | A line for the app's log. |
| `preview` (v2) | `paths`: list of strings | Show these files in Quick Look. Paths that are not absolute are ignored. |
| `settingNote` (v2) | `key` string, `text` string | Replace the text of the `note` setting `key`. Ignored when `key` is not a declared `note`. |

- `priority` is `ambient`, `standard` or `interactive`.
- `opensAt` is `peek` or `expanded`.
- `seconds` dismisses the presentation after that time, at most 3600. Without
  it, or when it is not a positive number, the presentation stays until
  `dismiss`.
- `accepts` is a list of drop kinds: `file`, `link`, `text`. While the
  presentation is on screen, things of those kinds dropped on the notch come
  as `input` with `drop`. Without it the presentation takes no drops.
- `answering` is the `seq` of the event this `present` answers. The kit sets
  it on a `present` made while it handles an event. See "Late answers".
- The app ignores `present`, `update`, `actions`, `preview` and `dismiss`
  before `welcome`.
- A `hello` whose `id` is not the manifest's `id` is a failure. A different
  `version` is only logged.
- With `dismissIfNotShown`, the app withdraws the presentation at once if it
  did not win the notch.
- A slot is `{width, height, root}`. `root` is a view node. The app clamps the
  size to its limits. For a wing, only the width is used, and 0 is allowed. A
  `present` with only a wing is valid.
- An `interactive` presentation counts as `interactive` only while the block
  is in an interaction: a drag is in progress, the pointer is on the notch and
  the block owns it, or less than 20 s have passed since either ended. Outside
  that it counts as `standard`. Between equal priorities the block higher in
  the owner's order on the Blocks page wins.

### Late answers

- The app numbers each event it sends to a version 2 block (`event` `seq`).
- The app drops a `present` that has `dismissIfNotShown` and an `answering`
  older than 2 s, and logs it. Shown that late it would answer nothing.
- A `present` without `dismissIfNotShown` is never dropped: a rename result
  may take 20 s.

## App to block

| Message | Fields | Meaning |
|---|---|---|
| `welcome` | `contract` int, `settings` object, `dataFolder` string | The answer to `hello`. The block starts now. |
| `ping` | `seq` int | A heartbeat, once per second. |
| `event` | `payload` `{name, value}`, `replay` bool, `seq`? int (v2) | A system event the block listens to. |
| `owner` | `owns` bool | Whether the block's presentation is on screen. |
| `input` | `input`: one of the inputs below | The user acted on the block's view. |
| `action` | `id` string | The user chose a menu action. |
| `setting` | `key` string, `value` | The user changed a setting. |
| `quit` | none | Stop. The block must exit. |

Inputs:

| Input | Fields | Meaning |
|---|---|---|
| `click` | none | A click on the view. |
| `button` | `id` string | A click on a `button` node. |
| `drop` (v2) | `items`: list of drops | Things dropped on a presentation that `accepts` their kind. |
| `item` (v2) | `id` string, `action` | A click, double-click or menu entry on the `item` node `id`. |
| `dragBegan` (v2) | `id` string | A drag-out of the `item` node `id` started. |
| `dragEnded` (v2) | `id` string, `succeeded` bool | That drag ended. `succeeded` is false when it was cancelled. |

- A drop is `{"file": {"path"}}`, `{"link": {"url"}}` or
  `{"text": {"string"}}`. A file path is absolute. Files the app wrote for a
  drop (a dragged image without a file, for example) are in the temporary
  folder, which every block may read and write.
- An item `action` is `{"click": {}}`, `{"doubleClick": {}}` or
  `{"menu": {"id": <menu entry id>}}`.
- The app sends `dragBegan` before the `dragStarted` event that the same drag
  causes. Both go down one socket, so the block sees them in that order and
  knows the drag is its own.
- `settings` holds every declared setting's current value, keyed without the
  block id. A toggle is `true` or `false`. A choice is a string.
- `dataFolder` is a folder the block may write to:
  `~/Library/Application Support/TopNotch/BlockData/<id>`. Remove deletes it.
- A block must answer `ping` from its main thread. No `pong` for 3 seconds
  after `welcome` is a hang; before `welcome` the block has 10 seconds to say
  `hello`. The app then stops the block and counts a failure.
- A block must keep reading its socket. A frame the app cannot write within
  0.5 s, or more than 16 MB of frames the app has not read yet, is a failure.
- `owner` with `owns: false` is the block's only signal that its time ran out
  or that another block took the notch.
- After `quit`, the app sends SIGTERM, then SIGKILL after 1 second.

## Events

An event payload is `{"name": <event name>, "value": <object>}`.

| Name | Value |
|---|---|
| `pointerHover` | `isInside` bool |
| `outputVolume` | `volume` number 0 to 1, `isMuted` bool |
| `nowPlaying` | `player`, `state` (`playing`, `paused`, `stopped`), `title`, `artist`, `album` strings; `artwork` base64 string, optional, up to 1 MB |
| `screenshotCaptured` | `path` string (absolute), `createdAt` number (seconds since 1970) |
| `dragStarted` | `kinds`: list of `file`, `link`, `text` |
| `dragEnded` | empty object |

- The app sends only the events the manifest lists. A system event source runs
  only while a turned-on block listens to its events.
- When a block starts, the app resends the latest event of each kind with
  `replay: true`, in the order they arrived; for `nowPlaying`, the latest of
  each player. The block updates its state and does not present. Events that
  happen while the block starts are sent after the replay with `replay: false`.

## View nodes

A node is `{"kind": {<kind>: {fields}}, "accessibilityLabel": string?,
"help": string? (v2)}`. Any node may carry an accessibility label, which
VoiceOver reads, and a tooltip, `help`, shown while the pointer rests on it.

### Version 1 kinds, with their version 2 fields

| Kind | Fields | Drawn as |
|---|---|---|
| `vstack` | `children` list, `spacing`?, `alignment`?, `padding`?, `offset`? (v2) | Children top to bottom. |
| `hstack` | `children` list, `spacing`?, `alignment`?, `padding`?, `offset`? (v2) | Children left to right. |
| `box` | `child` node, `width`?, `height`?, `cornerRadius`, `fillOpacity`, `color`? (v2), `stroke`? (v2) | A rounded rectangle filled with `color` (white when not set) at `fillOpacity`, with the child centred. Without a width or a height it takes the child's size on that axis. |
| `text` | `text` string, `style` | One line, truncated at the end. |
| `symbol` | `name` string, `size`, `opacity`?, `width`?, `color`? (v2), `weight`? (v2), `secondaryColor`? (v2) | An SF Symbol. `width` fixes the frame width. `secondaryColor` is used by palette symbols. |
| `image` | `asset` id, `size`, `cornerRadius` | A square image sent with `asset`, filled and clipped. |
| `progress` | `value` 0 to 1, `width`?, `color`? (v2), `drainsOver`? (v2), `track`? (v2) | A thin capsule bar, filled from the left. Without a width it fills the space it is given. With `drainsOver`, the bar empties from `value` to 0 over that many seconds; it does not move with Reduce Motion on. `track` colours the unfilled bar (white at 0.2 when not set). |
| `button` | `id` string, `title` string, `style`? (v2), `symbol`? (v2), `enabled`? (v2), `color`? (v2), `restOpacity`? (v2), `labelColor`? (v2), `label`? node (v2) | A button. A click sends `input` with `button`. |
| `spacer` | `minLength`? | Flexible space. |

- `alignment` of a stack is `start`, `center`, `end` or (v2)
  `firstTextBaseline`. In a `vstack` it is leading, centre or trailing. In an
  `hstack` it is top, centre or bottom; `firstTextBaseline` lines up the
  children's first text baselines. A `vstack` treats `firstTextBaseline` as
  `start`.
- `padding` is `{horizontal, vertical, top?, bottom?}` in points. `top` and
  `bottom` (v2), when set, replace `vertical` on that edge.
- `offset` is `{x, y}` in points, applied after layout; positive is right and
  down.
- `style` is `title` (15 pt semibold), `body` (12 pt medium) or `secondary`
  (11 pt, half opacity).
- `stroke` is `{color, width, dash?}`. `dash` is the lengths of dashes and
  gaps; solid when not set.
- `weight` is `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`,
  `bold`, `heavy` or `black`.
- A button's `style` is `capsule` (the version 1 look), `accent` (a capsule in
  the accent colour, or in `color`) or `plain` (no background). `symbol` is an
  SF Symbol: a `plain` button shows it alone, the others before the title.
  `enabled: false` draws the button at 0.4 opacity and ignores clicks. `restOpacity` is its opacity while the pointer is not on it.
  `labelColor` colours the title and symbol of an `accent` button. `label`,
  when set, is drawn instead of the title and symbol; the title is then what
  VoiceOver reads.

### Version 2 kinds

| Kind | Fields | Drawn as |
|---|---|---|
| `zstack` | `children` list, `alignment`? | Children on top of each other, first at the back. |
| `scroll` | `axis` (`horizontal`, `vertical`), `child` node | A scrolling area with no indicators. |
| `styledText` | `runs`: list of `{text, strikethrough?}`, `attributes` | Text made of runs that share `attributes`. |
| `capsule` | `child` node, `fill`? colour, `padding`?, `height`? | A capsule behind its child. |
| `spinner` | `size` (`small`, `mini`) | Indeterminate progress. |
| `sweep` | `color` | A 2 pt line that moves up and down its container; still with Reduce Motion on. |
| `frame` | `child` node, `width`?, `height`?, `fill`?, `alignment`? | A fixed size, or one that fills the space given on `fill`'s axes (`width`, `height`, `both`), with the child at `alignment` (centre when not set). |
| `item` | `id` string, `child` node, `hoverFill`? colour, `cornerRadius`?, `drag`?, `menu`?, `click`? bool, `doubleClick`? bool, `help`? string, `overlay`? node | One interactive element, drawn and handled by the app. |

- `alignment` of a `zstack` or `frame` is one of `topLeading`, `top`,
  `topTrailing`, `leading`, `center`, `trailing`, `bottomLeading`, `bottom`,
  `bottomTrailing`.
- `attributes` of a `styledText` is `{size?, weight?, color?, opacity?,
  lineLimit?, truncation?, monospacedDigits?, alignment?}`. Fields not set
  take the app's defaults: 12 pt, regular, white, opaque, one line, truncated
  at the end, lines lined up leading. `truncation` is `tail` or `middle`.
  `alignment` is `leading`, `center` or `trailing`, for the lines of
  multi-line text.
- An `item`:
  - is highlighted with `hoverFill`, rounded by `cornerRadius`, while the
    pointer is on it;
  - sends `input` with `item` and `{"click": {}}` or `{"doubleClick": {}}`
    only when `click` or `doubleClick` is `true`;
  - shows `menu`, a list of `{id, title, enabled}`, on a right-click; a
    choice sends `input` with `item` and `{"menu": {"id"}}`;
  - can be dragged out when `drag` is set: `{items, image?}`, where `items`
    is a list of drops (as in `input` `drop`) put on the pasteboard and
    `image` is an asset id shown under the pointer. The app builds the
    pasteboard and the dragging session and sends `dragBegan` and
    `dragEnded`;
  - draws `overlay` over itself, above the layer that takes its drags, so
    buttons in the overlay can be clicked. A button in the overlay is at its
    `restOpacity` while the pointer is not on the item, rather than not on
    the button. A button inside `child` cannot be clicked.

Colours are `{hex, opacity?}`: a hex string such as `"#F5A623"`, and an
opacity from 0 to 1 (opaque when not set).

### Limits

- One tree may hold at most 600 nodes. The app refuses a larger tree and
  counts a failure. The kit refuses it before sending and logs why.

## Images

- An image id is the first 16 hex characters of the SHA-256 of its bytes.
- A block sends `asset` before the first `present` or `update` that shows it.
- The app keeps the 64 images per block most recently sent or shown. After
  each `present` or `update`, it marks the images the trees refer to as used,
  in tree order (an `item`'s drag image before the images inside it), and
  only then lets go of the oldest beyond 64. A block sends an image again when
  it is no longer among those 64.
- An `asset` frame is limited like any frame, so an image over about 3 MB
  cannot be sent. The kit refuses it with a log line.

## Package

A package is a macOS bundle, signed as a whole:

```
<Name>.topblock/
  Contents/
    Info.plist                  made from the manifest
    MacOS/<executable>          the manifest's "executable"
    Resources/manifest.json
```

- `Scripts/package-block.sh` builds and signs this layout; see `README.md`.
- The signature seals the manifest with the executable. A package changed
  after signing is refused.
- A package in the version 1 flat layout (`manifest.json` and the executable
  at the top of the folder) is refused, with a message to package it again.

## Manifest

`Contents/Resources/manifest.json`:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | yes | Lowercase letters, digits and dashes. |
| `name` | string | yes | The name the user sees. |
| `version` | string | yes | The block's own version. |
| `contract` | int | yes | The protocol version. |
| `executable` | string | yes | Path of the executable, relative to `Contents/MacOS`. |
| `summary` | string | no | One sentence for the Blocks page. |
| `symbol` | string | no | SF Symbol name for the block's icon. |
| `trigger` | string | no | What makes the block show. |
| `permissions` | list of strings | no | Display-only text. |
| `access` | list of tokens | no | What the block may do beyond the default sandbox (v2). |
| `events` | list of event names | no | The events the app sends. |
| `settings` | list of settings | no | Drawn and stored by the app. |

A setting is `{key, type, title, default?, options?}`.

- `type` is `toggle`, `choice` or `note`.
- A toggle's `default` is a bool. A choice's `default` is one option's value.
- `options` is a list of `{value, title}`, for a choice.
- A note shows `title` as text and has no value. The block may replace the
  text with `settingNote`.
- The app stores a value as `<block id>.<key>` in its defaults.

### Access

| Token | Lets the block | Shown to the owner as |
|---|---|---|
| `network` | open outbound connections | "Use the network" |
| `files.read` | read files in the home folder | "Read your files" |
| `files.screenshots` | read and write in the screenshot folder | "Rename files in the screenshot folder" |

A manifest without `access` (every version 1 manifest) gets the default
sandbox. An unknown token is refused.

### Refusals

The app refuses a manifest, at install and at launch, when: a required field
is missing or has the wrong type; `id` breaks the rule above or is reserved
(`shelf`, `rename`, `nowplaying`, `block`, `onboarding`, `com`, `apple`,
`ns`; only a bundled block may use one); `contract` is not supported;
`executable` is outside `Contents/MacOS` or not executable; an event name is
unknown; an `access` token is unknown; or a setting is malformed. Each case
has its own message.

## Sandbox

Every block runs under a sandbox profile that the app builds from its
manifest. The profile allows everything by default, then denies:

- network connections, unless `network`;
- Apple events;
- file writes, except in the block's data folder, the temporary folder and
  `/dev`;
- file reads inside the home folder, unless `files.read`. The block's data
  folder and its own package stay readable.

`files.screenshots` allows reads and writes in the screenshot folder only.
Reading file metadata in the home folder is always allowed: the on-device
model (FoundationModels) needs it.

This is a deny list. It stops the plain cases: sending a file away, writing
over a document. It is not a guarantee against a determined attacker: system
services stay reachable. The signature answers who made the block.
