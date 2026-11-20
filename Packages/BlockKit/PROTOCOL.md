# TopNotch block protocol, version 1

A block is a separate program. The app starts it, sends it events, and draws
the view the block sends back as data. This file describes the messages
between the app and a block. `BlockWire` implements it; `BlockKit` wraps it
for Swift authors.

## Version

- The protocol version is one integer. This document is version 1.
- A block names its version in `manifest.json` (`contract`) and in `hello`.
- The app accepts versions 1 to 1. It refuses any other version and names the
  version it supports.
- Any change to the bytes below is a new version. The test
  `wireV1MatchesGoldenFile` pins version 1 against
  `Tests/BlockWireTests/Fixtures/wire-v1.json`.

## Transport

- The app creates a Unix stream socket pair. The block gets one end as file
  descriptor 3.
- Stdin and stdout are not used. A stray `print` cannot break the protocol.
- When the app closes its end, the block must exit.
- The app sets the environment variable `TOPNOTCH_BLOCK_GENERATION` to the
  process generation.

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

## Block to app

| Message | Fields | Meaning |
|---|---|---|
| `hello` | `contract` int, `id` string, `version` string | The first frame. Sent before anything else. `id` must be the manifest's `id`. |
| `pong` | `seq` int | The answer to `ping`, with the same `seq`. |
| `present` | `priority`, `peek`?, `wing`?, `expanded`?, `opensAt`, `seconds`?, `dismissIfNotShown` bool | Ask for the notch. At least one slot is set. |
| `update` | `peek`?, `wing`?, `expanded`? (trees, no sizes) | Replace the trees of the current presentation. Sizes stay as presented. |
| `dismiss` | none | Give the notch back. |
| `asset` | `id` string, `bytes` base64 string | Image bytes (PNG or JPEG), referred to by `image` nodes. |
| `actions` | `items`: list of `{id, title, enabled}` | The block's menu actions. Replaces the previous list. |
| `log` | `text` string | A line for the app's log. |

- `priority` is `ambient`, `standard` or `interactive`.
- `opensAt` is `peek` or `expanded`.
- `seconds` dismisses the presentation after that time, at most 3600. Without
  it, or when it is not a positive number, the presentation stays until
  `dismiss`.
- The app ignores `present`, `update`, `actions` and `dismiss` before `welcome`.
- A `hello` whose `id` is not the manifest's `id` is a failure. A different
  `version` is only logged.
- With `dismissIfNotShown`, the app withdraws the presentation at once if it
  did not win the notch.
- A slot is `{width, height, root}`. `root` is a view node. The app clamps the
  size to its limits. For a wing, only the width is used, and 0 is allowed. A
  `present` with only a wing is valid.

## App to block

| Message | Fields | Meaning |
|---|---|---|
| `welcome` | `contract` int, `settings` object, `dataFolder` string | The answer to `hello`. The block starts now. |
| `ping` | `seq` int | A heartbeat, once per second. |
| `event` | `payload` `{name, value}`, `replay` bool | A system event the block listens to. |
| `owner` | `owns` bool | Whether the block's presentation is on screen. |
| `input` | `input`: `{"click": {}}` or `{"button": {"id": ...}}` | A click on the view, or on one of its buttons. |
| `action` | `id` string | The user chose a menu action. |
| `setting` | `key` string, `value` | The user changed a setting. |
| `quit` | none | Stop. The block must exit. |

- `settings` holds every declared setting's current value, keyed without the
  block id. A toggle is `true` or `false`. A choice is a string.
- `dataFolder` is a folder the block may write to. Remove deletes it.
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

- The app sends only the events the manifest lists.
- When a block starts, the app resends the latest event of each kind with
  `replay: true`, in the order they arrived; for `nowPlaying`, the latest of
  each player. The block updates its state and does not present. Events that
  happen while the block starts are sent after the replay with `replay: false`.

## View nodes

A node is `{"kind": {<kind>: {fields}}, "accessibilityLabel": string?}`. Any
node may carry an accessibility label.

| Kind | Fields | Drawn as |
|---|---|---|
| `vstack` | `children` list, `spacing`?, `alignment`?, `padding`? | Children top to bottom. |
| `hstack` | `children` list, `spacing`?, `alignment`?, `padding`? | Children left to right. |
| `box` | `child` node, `width`, `height`, `cornerRadius`, `fillOpacity` | A rounded rectangle in white at `fillOpacity`, with the child centred. |
| `text` | `text` string, `style` | One line, truncated at the end. |
| `symbol` | `name` string, `size`, `opacity`?, `width`? | An SF Symbol. `width` fixes the frame width. |
| `image` | `asset` id, `size`, `cornerRadius` | A square image sent with `asset`, filled and clipped. |
| `progress` | `value` 0 to 1, `width` | A thin capsule bar, filled from the left. |
| `button` | `id` string, `title` string | A capsule button. A click sends `input` with `button`. |
| `spacer` | `minLength`? | Flexible space. |

- `alignment` is `start`, `center` or `end`. In a `vstack` it is leading,
  centre or trailing. In an `hstack` it is top, centre or bottom.
- `padding` is `{horizontal, vertical}` in points.
- `style` is `title` (15 pt semibold), `body` (12 pt medium) or `secondary`
  (11 pt, half opacity).
- One tree may hold at most 200 nodes. The app refuses a larger tree and
  counts a failure. The kit refuses it before sending and logs why.

## Images

- An image id is the first 16 hex characters of the SHA-256 of its bytes.
- A block sends `asset` before the first `present` or `update` that shows it.
- The app keeps the 8 images per block most recently sent or shown. After each
  `present` or `update`, it marks the images the trees refer to as used, in
  tree order, and only then lets go of the oldest beyond 8. A block sends an
  image again when it is no longer among those 8.
- An `asset` frame is limited like any frame, so an image over about 3 MB
  cannot be sent. The kit refuses it with a log line.

## Manifest

A package is a folder `<Name>.topblock`. It holds `manifest.json` and the
executable.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | yes | Lowercase letters, digits and dashes. |
| `name` | string | yes | The name the user sees. |
| `version` | string | yes | The block's own version. |
| `contract` | int | yes | The protocol version. |
| `executable` | string | yes | Path of the executable, inside the package. |
| `summary` | string | no | One sentence for the Blocks page. |
| `symbol` | string | no | SF Symbol name for the block's icon. |
| `trigger` | string | no | What makes the block show. |
| `permissions` | list of strings | no | Display-only text. |
| `events` | list of event names | no | The events the app sends. |
| `settings` | list of settings | no | Drawn and stored by the app. |

A setting is `{key, type, title, default?, options?}`.

- `type` is `toggle`, `choice` or `note`.
- A toggle's `default` is a bool. A choice's `default` is one option's value.
- `options` is a list of `{value, title}`, for a choice.
- A note shows `title` as text and has no value.
- The app stores a value as `<block id>.<key>` in its defaults.

The app refuses a manifest, at install and at launch, when: a required field
is missing or has the wrong type; `id` breaks the rule above or is reserved
(`shelf`, `rename`, `demo`, `nowplaying`, `block`, `onboarding`); `contract`
is not supported; `executable` is outside the package or not executable; or
an event name is unknown. Each case has its own message.
