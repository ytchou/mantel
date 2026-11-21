#!/bin/bash
# Throwaway: Quick Look thumbnails of a PNG, a text file and a PDF in the
# block's temp folder and a PNG in its data folder, unsandboxed and under
# the given profile (default allowlist).
#   ./thumbs.sh [profile]
cd "$(dirname "$0")"
P=${1:-allowlist}
B="$(realpath "$TMPDIR")/TopNotch/Blocks/dev.topnotch.spike"
D="$HOME/Library/Application Support/TopNotchSpike/BlockData/dev.topnotch.spike"
mkdir -p "$B" "$D"
[ -f "$B/pic.png" ] || sips -s format png /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns --out "$B/pic.png" >/dev/null
[ -f "$B/note.txt" ] || echo "hello thumbnail" > "$B/note.txt"
[ -f "$B/doc.pdf" ] || /usr/sbin/cupsfilter "$B/note.txt" > "$B/doc.pdf" 2>/dev/null
cp -f "$B/pic.png" "$D/pic.png"
for f in "$B/pic.png" "$B/note.txt" "$B/doc.pdf" "$D/pic.png"; do
  echo "== $(basename "$(dirname "$f")")/$(basename "$f") unsandboxed: $(.build/debug/sbspike thumb "$f")"
  echo "== $(basename "$(dirname "$f")")/$(basename "$f") $P: $(./run.sh "$P" thumb "$f")"
done
