#!/bin/zsh
# Separate-process block spike. One command per measurement; output lines
# starting with RESULT are the numbers. Logs also go to .build/results/.
#
#   ./run.sh build                 release build (unsigned)
#   ./run.sh sign                  sign host + block with the Apple Development identity, hardened runtime
#   ./run.sh rtt                   pd-b1: cold start + 2000 round trips
#   ./run.sh view <option>         pd-b2: 200 hover/click/drag/resize; option = inproc|described|window|layer
#   ./run.sh crash <option> <how>  pd-b3: how = kill|fatal
#   ./run.sh hang <option>         pd-b3: block main thread sleeps 3 s
#   ./run.sh all                   everything above, unsigned
#   ./run.sh manual <option> [s]   hand check with the real pointer (default 60 s)
#
# The layer option uses the private CAContext/CALayerHost route with SwiftUI
# rendered by ImageRenderer ("snapshot"). Other routes: ROUTE=plain|reparent|window.
set -e -o pipefail
cd "${0:A:h}"
BIN=.build/release
ROUTE=${ROUTE:-snapshot}
mkdir -p .build/results

run() { local name=$1; shift; "$BIN/spike-host" "$@" 2>&1 | tee ".build/results/$name.txt" | grep -E "RESULT|EVENT|MANUAL|block:"; }

case "$1" in
  build) swift build -c release 2>&1 | tail -1 ;;
  sign)
    # Identity looked up at run time; never written to a file.
    ID=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
    [[ -n "$ID" ]] || { echo "no Apple Development identity"; exit 1; }
    for b in spike-block spike-host; do codesign --force --options runtime --timestamp=none -s "$ID" "$BIN/$b"; done
    for b in spike-block spike-host; do codesign -dv "$BIN/$b" 2>&1 | grep -E "^(Identifier|CodeDirectory|Runtime Version|flags)" | sed "s/^/$b: /"; done
    ;;
  rtt) run rtt rtt --n 2000 --launches 10 ;;
  view) run "view-$2" view --option "$2" --route "$ROUTE" --n "${N:-200}" ;;
  crash) run "crash-$2-$3" crash --option "$2" --how "$3" --route "$ROUTE" ;;
  hang) run "hang-$2" hang --option "$2" --route "$ROUTE" ;;
  manual) "$BIN/spike-host" manual --option "$2" --route "$ROUTE" --seconds "${3:-60}" 2>&1 | grep -E "RESULT|EVENT|MANUAL" ;;
  all)
    $0 rtt
    for o in inproc described window layer; do $0 view $o; done
    for o in described window layer; do $0 crash $o kill; $0 crash $o fatal; $0 hang $o; done
    ;;
  *) sed -n '2,17p' "$0" ;;
esac
pgrep -l spike-block && echo "WARNING: spike-block still running" || true
