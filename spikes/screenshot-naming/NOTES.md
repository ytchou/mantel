# Screenshot naming spike (NameSpike)

Throwaway SwiftPM command-line tool. It tests whether macOS 26 can detect a new
screenshot, read its text, name it on-device and rename it while keeping its dates.

Status: compiles (`swift build`, Swift 6.2, macOS SDK 26.2). **No subcommand has been
run yet.** Every statement about runtime behaviour below is "not verified" until the
orchestrator or a human runs the commands.

## How to run

```sh
cd spikes/screenshot-naming
swift build
B=.build/debug/NameSpike

$B selftest                                  # no human input; prints a table + JSON
$B watch --seconds 60                        # take a real screenshot while this runs
$B ocr ~/Desktop/Screenshot*.png
$B name <image> --length short|standard|detailed
$B name <image> --image-input                # reports "not supported on this SDK"
$B fallback <image> --app Safari
$B rename <file> "new base name"
$B undo <renamed-file>
```

Every subcommand prints human-readable lines, then one JSON object on the last line
(`... | tail -1 | jq .`).

## Subcommands

### watch [--seconds N]
Runs two detectors at the same time and prints each detection with its method and the
latency in ms between the file's creation date and the detection moment.

- **metadataQuery**: `NSMetadataQuery` with predicate `kMDItemIsScreenCapture == 1`,
  scope `NSMetadataQueryUserHomeScope` (plus the screenshot folder when it is outside
  home), `notificationBatchingInterval = 0.05`. Results of the initial gather are
  recorded and ignored. New items are taken from `NSMetadataQueryUpdateAddedItemsKey`
  and `...ChangedItemsKey`. The main run loop is run by the command itself.
- **dispatchSource**: `DispatchSource.makeFileSystemObjectSource` on the folder from
  `defaults read com.apple.screencapture location` (default `~/Desktop`), event mask
  `.write/.rename/.link`. Each event diffs the folder listing. Dot-files (the temporary
  `.Screenshot ...png` that macOS writes first) are logged and ignored; when the final
  name appears, the tool polls the xattr `com.apple.metadata:kMDItemIsScreenCapture`
  (binary plist bool) every 25 ms for up to 1 s. It reports `fileSeenLatencyMs`
  (file visible) and `latencyMs` (xattr confirmed), and `xattrWaitMs`.
- Summary per file: which methods fired, which one fired first, latency of each.

Caveat: the latency baseline is the final file's creation date. If macOS renames the
temp dot-file, the creation date is that of the temp file, so the number includes the
time to write the image. It is not the moment the user pressed the keys.

### ocr <image>
`VNRecognizeTextRequest`, `recognitionLevel = .accurate`, `usesLanguageCorrection = true`,
`automaticallyDetectsLanguage = true`, `recognitionLanguages = ["zh-Hant", "en-US"]`
(only those listed by `supportedRecognitionLanguages()`). Lines are sorted top to bottom
(Vision boxes have a bottom-left origin), then left to right. Prints text height in px
and confidence for each line, plus load and recognise time. Not verified: whether Vision
honours `recognitionLanguages` when `automaticallyDetectsLanguage` is on.

### name <image> [--length short|standard|detailed] [--image-input]
OCR, then `LanguageModelSession` with guided generation. One `@Generable` struct per
length (`ShortName`, `StandardName`, `DetailedName`), each with
`@Guide(description:, .count(2...4 | 4...6 | 6...9)) var words: [String]`, so the word
count is part of the schema. Sampling is `.greedy`. The words go through the shared
sanitiser. Output: availability (and reason), raw model output (`GeneratedContent.jsonString`),
sanitised name, word count in range or not, and timings: OCR, session creation, first
streamed snapshot (`streamResponse(to:generating:)`, used as "first token"), generation,
model total, end to end.

OCR text limit: **1200 characters**, whole lines top to bottom (`ocrCharLimit`). On
`GenerationError.exceededContextWindowSize` it retries once with 400 characters.

`--image-input` prints that the SDK has no image input and exits 2 (see below).

### fallback <image> [--app <name>]
No language model. Takes OCR lines in the top half of the image, ranks them by
`text height px x (0.5 + top position)`, keeps the 2 best, tokenises with `NLTokenizer`
(`.word`, which also segments Chinese), removes English/Chinese stop words, pure numbers
(dates, ids, times) and single ASCII letters, prefixes the app name, keeps 6 words,
sanitises. Empty result becomes `screenshot`.

### rename <file> <new-base-name> / undo <file>
Rename: sanitises the base, keeps the extension, appends `-2`, `-3` on collision,
writes the original name to xattr `com.topnotch.original-name` (only if not already
present, so repeated renames keep the first original name), `FileManager.moveItem`,
then compares creation and modification dates before and after (exact equality). If they
differ it sets them back with `setAttributes` and reports `datesRestoredExplicitly`.
Reads the xattr back. Undo reads the xattr, moves the file back (fails if the target
name exists), restores dates if needed and removes the xattr.

### selftest
Draws two 1400x800 PNGs with AppKit in a new temp folder (kept, path printed):
an English "Payment Failed / Invoice INV-20431" dialog, and a Traditional Chinese
"台北捷運時刻表" page (PingFang TC). For each: OCR (pass if the expected keyword is
read), name in all three lengths (SKIP if the model is unavailable), fallback,
rename (with a planted collision file so the `-2` path runs) and undo. Prints a table
and a JSON object with every timing and PASS/FAIL/SKIP flag. `watch` is not included.

### Shared sanitiser (`sanitizeFileName`)
Letters and digits are kept (ASCII lowercased, CJK kept). Every other character
(whitespace, `/`, `:`, punctuation, emoji, control characters) collapses to one hyphen.
Leading/trailing hyphens are removed. Capped at 60 characters, cut at a hyphen when the
hyphen is past the middle. This is stricter than "remove illegal characters": all
punctuation becomes a hyphen.

## FoundationModels findings (from the SDK interface)

Source: `MacOSX26.2.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface` (1536 lines).

| Question | Answer | Evidence (symbols) |
|---|---|---|
| Availability API | Yes | `SystemLanguageModel.default`, `.availability: Availability` (`@frozen enum`: `.available`, `.unavailable(UnavailableReason)`), `UnavailableReason`: `.deviceNotEligible`, `.appleIntelligenceNotEnabled`, `.modelNotReady`; also `isAvailable`, `supportedLanguages: Set<Locale.Language>`, `supportsLocale(_:)` |
| Guided generation | Yes | `@Generable`, `@Guide(description:_:)` macros; `GenerationGuide.count(ClosedRange<Int>)`, `.minimumCount`, `.maximumCount`, `.anyOf([String])`, `.pattern(Regex)`, `.constant`; `respond(to:generating:includeSchemaInPrompt:options:)`, `streamResponse(to:generating:...)` returning `ResponseStream<Content>` (AsyncSequence of `Snapshot { content: PartiallyGenerated, rawContent }`), `collect()` |
| Image input in prompts | **No** on this SDK | 0 matches for `image`, `CGImage`, `NSImage`, `pixel` in the interface. `Prompt.init(_: some PromptRepresentable)`; conformers are `String`, `Prompt`, `Array`, `ConvertibleToGeneratedContent`. `Transcript.Segment` has only `.text(TextSegment)` and `.structure(StructuredSegment)`. |
| Context window size | Not exposed | No `contextSize`/token-count symbol. Only `GenerationError.exceededContextWindowSize(Context)` and `GenerationOptions.maximumResponseTokens`. Apple's docs state 4096 tokens: not verified here. |
| Other | | `UseCase.general` / `.contentTagging`, `Guardrails.default` / `.permissiveContentTransformations`, `prewarm(promptPrefix:)`, errors `guardrailViolation`, `unsupportedLanguageOrLocale`, `rateLimited`, `concurrentRequests`, `refusal`, `assetsUnavailable`; `GenerationOptions(sampling: .greedy / .random(...), temperature:, maximumResponseTokens:)` |

Consequence: on macOS 26 the only naming input is OCR text (plus app name etc. as text).
The image itself cannot go to the on-device model.

## Not verified (needs a run)

- Whether the model is available on this Mac, and its reason if not.
- Whether `supportsLocale(zh-Hant-TW)` is true and whether Chinese prompts raise
  `unsupportedLanguageOrLocale`.
- Model timings, and whether the first streamed snapshot is close to the first token.
- Whether the model obeys "no dates" and the language rule; name quality in general.
- Whether `.contentTagging` use case gives better names than `.general` (not tried).
- Whether `prewarm()` reduces first-snapshot latency (not tried).
- Vision accuracy for Traditional Chinese with auto-detect on.
- Whether `moveItem` alone keeps creation/modification dates (expected yes for a
  same-volume rename) and whether the xattr survives the move.
- Every `watch` behaviour: which detector fires first, latencies, the dot-file
  sequence, when the screen-capture xattr appears, and whether NSMetadataQuery reports
  the file as "added" or "changed".

## What a human must check

1. Run `.build/debug/NameSpike watch --seconds 60`, then take at least three real
   screenshots: Cmd-Shift-3 (full screen), Cmd-Shift-4 (area), Cmd-Shift-5 (window).
   Check that both `metadataQuery` and `dispatchSource` lines appear for each, and note
   the latencies and which fired first.
2. Also try with the screenshot thumbnail preview on and off (Cmd-Shift-5 > Options >
   Show Floating Thumbnail): with the thumbnail on, macOS may write the file only after
   the thumbnail goes away (not verified).
3. Copy a non-screenshot PNG into the folder during `watch`: `dispatchSource` should
   report "kMDItemIsScreenCapture is false" or "without ... after 1 s", and
   `metadataQuery` should stay silent.
4. Run `name` and `fallback` on those real screenshots and judge name quality.
5. In Finder, Get Info on a renamed file: dates unchanged. Then run `undo`.
