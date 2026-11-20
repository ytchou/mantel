# Where screenshot naming time goes (DEV-2066)

Run on 2026-11-19: macOS 26.5.1, M1 Pro, Apple Intelligence on. Eight real
screenshots from the Desktop (two full screens, six regions; English, code and
Traditional Chinese), copied to a scratch folder and read only.

Bench: `Packages/NotchKit/Tests/RenameBlockTests/NamingBenchTests.swift`.

```sh
NAMING_BENCH_DIR=/folder/of/pngs make test FILTER=namingAfterIdle
NAMING_BENCH_VARIANTS=app,compact NAMING_BENCH_DIR=... make test FILTER=namingAfterIdle
NAMING_BENCH_LENGTHS=1 make test FILTER=namingLatencyByLength
```

Status words: **Measured** = observed in a run. **Not measured** = the reason
is given. The Mac was in use during the runs (load average 5 to 20), so single
numbers are noisy; conclusions rest on repeated runs.

## Result

- **Kept: the app no longer calls `prewarm()`.** Measured twice on the eight
  screenshots, each named after 15 s idle: total time (text reading plus
  model) summed to 73 s and 72 s without it, against 99 s and 99 s with it.
  Without it a name was faster on 5 of 8 screenshots in both runs. The names
  were identical (same prompt).
- **Not kept: a compact prompt, fewer response tokens, holding a session
  open, skipping the model.** None was reliably faster with names no worse.
- **The rest cannot be fixed from the app.** A name takes about 0.5 s when the
  model is loaded. macOS unloads it within 5 to 10 s of the last use, and
  loading it again costs 3 to 19 s. A screenshot almost always arrives after
  that.

## Timings per step

| Step | Status | Time |
|---|---|---|
| macOS saves the file after a capture (floating thumbnail) | Measured | about 6 s after the keys; nothing is on disk before that |
| File detected | Measured (phase 1) | 20 ms after it appears |
| Text reading (Vision, accurate) | Measured | 0.2 to 1.2 s; 3.5 to 7 s when `prewarm()` ran just before it (6 of 16 names) |
| Model: writing the name | Measured | about 50 ms (first token to last) |
| Model: reading the prompt, model loaded | Measured | 0.3 to 0.8 s for 80 to 2,000 characters; length makes almost no difference |
| Model: first token after 12 to 20 s idle | Measured | 3.7 to 19 s, once 28 s; median about 8 to 11 s |
| Rename | Measured (phase 1) | under 10 ms |

So the "15 to 20 s" seen in the app was almost all the model step after idle,
plus up to a few seconds of text reading stalled behind `prewarm()`.

## Why the model step is slow after idle

Read from the system log (`modelmanagerd`, `TGOnDeviceInferenceProviderService`)
with timestamps, during slow requests:

- Measured: about 5 s after a request ends, `modelmanagerd` logs "Transition
  assets that haven't been used for at least 5 seconds" and unloads the safety
  models, then the language model and its adapter.
- Measured: on the next request the assets are "loaded" again in about 1 s.
- Measured: the prompt is then processed in 64-token steps of about 30 ms
  each, but the first step in each compiled size (`extend_256_64`,
  `extend_512_64`, `extend_512_8`, ...) stalls for 3.05 s (1.55 s in one early
  run). A request touches one to six of these, which is why first-token times
  come in steps: 0.5, 3.6, 6.7, 9.8, 12.9 s.
- Measured: with requests back to back, nothing is unloaded and every request
  takes about 0.5 s.

## What was tried

| Idea | Status | Result |
|---|---|---|
| Remove `prewarm()` | Measured, kept | See Result. `prewarm()` 0.5 to 6 s before the request never made the first token reliably sooner, and text reading stalled behind it. |
| Shorter prompt (short instructions, about 110 tokens of text, under 256 tokens in all) | Measured, not kept | Back to back it is no faster (0.5 s either way). After idle it was faster in one run (median 9.5 s against 13 s) and slower in the next (6.6 s against 5.3 s). Names were worse on 3 of 8 ("python api" for "python wikipedia api"), and a screenshot in Chinese was refused with `unsupportedLanguageOrLocale` because less English surrounded it. |
| Fewer response tokens (16 for 32) | Measured, not kept | No difference; writing the name is 50 ms. |
| Keep one session alive for the whole run | Measured, not kept | 3.4 to 9.7 s (n=8) against about 9.5 s without. The model is still unloaded. Too small and uncertain to build on. |
| Use the model often enough that it is never unloaded | Measured in part, not kept | With 4 s between requests a name took 3.5 s; back to back, 0.5 s. Keeping it loaded would mean a request every few seconds all day. The energy and memory cost of that was not measured; it goes against the phase 4 idle-cost work. |
| Skip the model when the biggest text makes a good name | Measured, not kept | The no-model title was usable on 6 of 8, but worse than the model on 3 of them ("help", "api python ask", "big notation"). Saves the whole model step, at the cost of names. |
| Start during the 6 s the thumbnail floats | Measured, not possible without polling | During that time there was no image file in the user temp or cache folders, no hidden file in the screenshot folder, no distributed notification and no `NSWorkspace` launch notification for `screencaptureui`. Its process does exist for those seconds, so a poll of the process or window list once a second could see it. Not built: it adds idle cost. |

## Open

- Whether a different Mac (more memory, newer chip) keeps the model loaded
  longer: not measured.
- Turning off "Show Floating Thumbnail" (⇧⌘5, Options) still removes about
  5 s of the wait; the settings pane already says so.
