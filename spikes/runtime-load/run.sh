#!/bin/bash
# Runtime-load spike: builds a host, a shared contract library and plugins as
# separate products, then runs every scenario. All output goes to .build/.
# Summary: .build/results.txt. Full logs: .build/logs/.
#
# Signing identities are picked at run time from the keychain and never
# written anywhere. Override with SIGN_ID=<sha1> and OTHER_SIGN_ID=<sha1>.
# Optional: XCODE_OTHER=/Applications/Xcode-26.6.0.app for the compiler test.
set -u
cd "$(dirname "$0")" || exit 1
ROOT="$PWD"
B="$ROOT/.build"
SRC="$ROOT/Sources"
REAL="$ROOT/../../Packages/NotchKit/Sources"
TARGET=arm64-apple-macos26.0
RESULTS="$B/results.txt"
export SPIKE_TMP="$B/tmp"

rm -rf "$B"
mkdir -p "$B/logs" "$SPIKE_TMP"
: > "$RESULTS"
touch "$B/start-marker"

IDS=$(security find-identity -v -p codesigning)
DEV_ID="${SIGN_ID:-$(echo "$IDS" | awk '/Apple Development/ {print $2; exit}')}"
DEV_TEAM=$(echo "$IDS" | awk -v h="$DEV_ID" '$2==h' | grep -oE '\([A-Z0-9]{10}\)"' | head -1)
OTHER_ID="${OTHER_SIGN_ID:-$(echo "$IDS" | grep -E '^ *[0-9]+\)' | grep -v -F "$DEV_TEAM" | awk '{print $2; exit}')}"
SED_ARGS=(-e "s#$ROOT#.#g")
for t in $(echo "$IDS" | grep -oE '\([A-Z0-9]{10}\)"' | tr -d '()"' | sort -u); do
    SED_ARGS+=(-e "s/$t/<team>/g")
done
sanitize() { sed "${SED_ARGS[@]}"; }
say() { echo "$*" | tee -a "$RESULTS"; }

[ -n "$DEV_ID" ] || { say "No Apple Development identity found"; exit 1; }
say "identity: the Apple Development identity found; other-team identity found: $([ -n "$OTHER_ID" ] && echo yes || echo no)"

SWIFTC=(xcrun swiftc -target "$TARGET" -O)

# --- build helpers ---------------------------------------------------------

# build_contract <out-dir> <evo|noevo> [-D flags...]
build_contract() {
    local out="$1" evo="$2"; shift 2
    mkdir -p "$out"
    local extra=()
    [ "$evo" = evo ] && extra=(-enable-library-evolution -emit-module-interface-path "$out/BlockContract.swiftinterface")
    "${SWIFTC[@]}" -swift-version 5 -emit-library -module-name BlockContract \
        -emit-module -emit-module-path "$out/BlockContract.swiftmodule" ${extra[@]+"${extra[@]}"} \
        -Xlinker -install_name -Xlinker @rpath/libBlockContract.dylib \
        "$@" "$SRC/Contract/Contract.swift" -o "$out/libBlockContract.dylib" \
        > "$B/logs/build-contract-$(basename "$(dirname "$out")")-$(basename "$out").log" 2>&1 \
        || { say "BUILD FAILED contract $out"; cat "$B/logs/build-contract-"*"-$(basename "$out").log" | tail -5; exit 1; }
}

# build_host <out-dir> <lib-dir> [-D flags...]   (host at <out>/tn-spike-host, lib in <out>/lib)
build_host() {
    local out="$1" lib="$2"; shift 2
    mkdir -p "$out"
    "${SWIFTC[@]}" -swift-version 5 -module-name Host -I "$lib" -L "$lib" -lBlockContract \
        -Xlinker -rpath -Xlinker @executable_path/lib \
        "$@" "$SRC/Host/main.swift" -o "$out/tn-spike-host" > "$B/logs/build-host-$(echo "$out" | tr / _).log" 2>&1 \
        || { say "BUILD FAILED host $out"; tail -5 "$B/logs/build-host-$(echo "$out" | tr / _).log"; exit 1; }
    if [ "$lib" != "$out/lib" ]; then mkdir -p "$out/lib"; cp "$lib/libBlockContract.dylib" "$out/lib/"; fi
}

# build_plugin <bundle-path> <name> <lib-dir> <swiftc...> <sources...>
build_plugin() {
    local bundle="$1" name="$2" lib="$3"; shift 3
    mkdir -p "$bundle/Contents/MacOS"
    cp "$SRC/plist/$name.plist" "$bundle/Contents/Info.plist"
    "$@" -swift-version 5 -emit-library -module-name "$name" -I "$lib" -L "$lib" -lBlockContract \
        -o "$bundle/Contents/MacOS/$name" > "$B/logs/build-plugin-$name-$(basename "$(dirname "$bundle")").log" 2>&1 \
        || { say "BUILD FAILED plugin $bundle"; tail -5 "$B/logs/build-plugin-$name-$(basename "$(dirname "$bundle")").log"; return 1; }
}

sign() { codesign -f --timestamp=none "$@" > /dev/null 2>&1 || say "codesign failed: $*"; }

# run <label> <cmd...>: 20 s limit, prints the HOST/REAL/error lines.
run() {
    local label="$1"; shift
    local log="$B/logs/run-$label.log"
    perl -e 'alarm 20; exec @ARGV' "$@" > "$log" 2>&1
    local rc=$?
    local sig=""
    [ $rc -gt 128 ] && sig=", signal $((rc - 128))"
    say "## $label (exit $rc$sig)"
    grep -E '^(HOST|REAL|LOAD_FAIL)|Fatal error|rror:|Symbol not found|Referenced from|Expected in' "$log" | sanitize | sed 's/^/    /' | tee -a "$RESULTS"
}

# --- base build (library evolution on, the candidate format) ----------------
say ""
say "=== build ==="
BASE="$B/base"
build_contract "$BASE/lib" evo
build_host "$BASE" "$BASE/lib"
build_plugin "$B/plugins/hello/HelloPlugin.topblock" HelloPlugin "$BASE/lib" "${SWIFTC[@]}" "$SRC/HelloPlugin/HelloBlock.swift" || exit 1
xcrun clang -target "$TARGET" -c "$SRC/EvilPlugin/ctor.c" -o "$B/ctor.o"
build_plugin "$B/plugins/evil/EvilPlugin.topblock" EvilPlugin "$BASE/lib" "${SWIFTC[@]}" "$SRC/EvilPlugin/EvilBlock.swift" "$B/ctor.o" || exit 1
say "built: host, libBlockContract.dylib (library evolution), HelloPlugin, EvilPlugin"

# Hardened hosts: one with library validation (default), one with it disabled.
SIGNED="$B/signed"
mkdir -p "$SIGNED/lib"
cp "$BASE/tn-spike-host" "$SIGNED/tn-spike-host"
cp "$BASE/tn-spike-host" "$SIGNED/tn-spike-host-dlv"
cp "$BASE/lib/libBlockContract.dylib" "$SIGNED/lib/"
sign -s "$DEV_ID" "$SIGNED/lib/libBlockContract.dylib"
sign -s "$DEV_ID" --options runtime "$SIGNED/tn-spike-host"
sign -s "$DEV_ID" --options runtime --entitlements "$SRC/plist/dlv.entitlements" "$SIGNED/tn-spike-host-dlv"
say "host flags: $(codesign -dv "$SIGNED/tn-spike-host" 2>&1 | grep -oE 'flags=[^ ]+')"
say "dlv host entitlements: $(codesign -d --entitlements - --xml "$SIGNED/tn-spike-host-dlv" 2>/dev/null | grep -oE 'disable-library-validation')"

# Plugin signing variants.
P="$B/plugins/sig"
variant() { mkdir -p "$P/$1"; cp -R "$B/plugins/hello/HelloPlugin.topblock" "$P/$1/"; echo "$P/$1/HelloPlugin.topblock"; }
v=$(variant unsigned); codesign --remove-signature "$v/Contents/MacOS/HelloPlugin"
v=$(variant linker-signed)   # what swiftc leaves: linker ad-hoc signature
v=$(variant adhoc); sign -s - "$v"
v=$(variant same-identity); sign -s "$DEV_ID" "$v"
# These cases make Gatekeeper show a dialog on screen and move the plugin to
# the Trash (measured on the first run). Off unless GATEKEEPER_TESTS=1.
if [ "${GATEKEEPER_TESTS:-0}" = 1 ]; then
    if [ -n "$OTHER_ID" ]; then v=$(variant other-team); sign -s "$OTHER_ID" "$v"; fi
    QUAR="0081;$(printf %x "$(date +%s)");Safari;$(uuidgen)"
    v=$(variant quarantined-same-identity); sign -s "$DEV_ID" "$v"; xattr -r -w com.apple.quarantine "$QUAR" "$v"
    v=$(variant quarantined-adhoc); sign -s - "$v"; xattr -r -w com.apple.quarantine "$QUAR" "$v"
else
    say "skipped other-team and quarantine cases (they show Gatekeeper dialogs); set GATEKEEPER_TESTS=1 to run them"
fi
for d in "$P"/*; do
    say "plugin $(basename "$d"): $(codesign -dvv "$d/HelloPlugin.topblock" 2>&1 | grep -oE '(Signature=adhoc|Authority=Apple [A-Za-z]+|code object is not signed at all)' | head -1 | sed 's/Authority=//') $(xattr -p com.apple.quarantine "$d/HelloPlugin.topblock/Contents/MacOS/HelloPlugin" > /dev/null 2>&1 && echo '[quarantined]')"
done

# --- pd-a1: load from a folder, with timings ---------------------------------
say ""
say "=== pd-a1: hardened host loads a same-identity plugin from a folder ==="
for i in 1 2 3 4 5; do
    run "a1-run$i" "$SIGNED/tn-spike-host" "$P/same-identity"
done

# --- pd-a2: signing and library validation -----------------------------------
say ""
say "=== pd-a2 signing: host hardened, library validation ON ==="
for d in "$P"/*; do run "lv-$(basename "$d")" "$SIGNED/tn-spike-host" "$d"; done
say ""
say "=== pd-a2 signing: host hardened + disable-library-validation ==="
for d in "$P"/*; do run "dlv-$(basename "$d")" "$SIGNED/tn-spike-host-dlv" "$d"; done

# --- pd-a2: version skew -------------------------------------------------------
say ""
say "=== pd-a2 version skew: old v1 plugin binary, host + contract rebuilt ==="
for evo in noevo evo; do
    SK="$B/skew/$evo"
    build_contract "$SK/v1/lib" "$evo"
    build_plugin "$SK/plugin/HelloPlugin.topblock" HelloPlugin "$SK/v1/lib" "${SWIFTC[@]}" "$SRC/HelloPlugin/HelloBlock.swift" || continue
    for variant in v1 V2_ADDREQ V2_STRUCT V2_ENUM V2_REORDER V2_REMOVE; do
        flags=()
        [ "$variant" != v1 ] && flags=(-D "$variant")
        build_contract "$SK/$variant/lib" "$evo" "${flags[@]+"${flags[@]}"}"
        build_host "$SK/$variant" "$SK/$variant/lib" "${flags[@]+"${flags[@]}"}"
        run "skew-$evo-$variant" "$SK/$variant/tn-spike-host" "$SK/plugin"
    done
done

# --- pd-a2: compiler mismatch ------------------------------------------------------
say ""
say "=== pd-a2 compiler mismatch: plugin built by another Xcode's swiftc ==="
XO="${XCODE_OTHER:-/Applications/Xcode-26.6.0.app}"
if [ -d "$XO" ]; then
    say "host compiler: $(xcrun swiftc --version 2>&1 | grep -oE 'Apple Swift version [0-9.]+')"
    say "plugin compiler: $(DEVELOPER_DIR="$XO/Contents/Developer" xcrun swiftc --version 2>&1 | grep -oE 'Apple Swift version [0-9.]+')"
    for evo in noevo evo; do
        SK="$B/skew/$evo"
        if DEVELOPER_DIR="$XO/Contents/Developer" build_plugin "$B/plugins/compiler-$evo/HelloPlugin.topblock" HelloPlugin "$SK/v1/lib" \
            xcrun swiftc -target "$TARGET" -O "$SRC/HelloPlugin/HelloBlock.swift"; then
            run "compiler-$evo" "$SK/v1/tn-spike-host" "$B/plugins/compiler-$evo"
        else
            say "## compiler-$evo: plugin did not build against the other compiler's module:"
            grep -m2 -E 'error' "$B/logs/build-plugin-HelloPlugin-compiler-$evo.log" | sanitize | sed 's/^/    /' | tee -a "$RESULTS"
        fi
    done
else
    say "not measured: no second Xcode at $XO"
fi

# --- pd-a3: what a bad block can do ----------------------------------------------
say ""
say "=== pd-a3: misbehaving block (same identity, hardened host, LV on) ==="
sign -s "$DEV_ID" "$B/plugins/evil/EvilPlugin.topblock"
echo "spike-canary-$(uuidgen)" > "$SPIKE_TMP/host-secret.txt"
for mode in read swizzle hang crash; do
    rm -f "$SPIKE_TMP/ctor-ran.txt"
    EVIL_MODE=$mode run "evil-$mode" "$SIGNED/tn-spike-host" "$B/plugins/evil"
    [ -f "$SPIKE_TMP/ctor-ran.txt" ] && say "    ctor-ran.txt: $(cat "$SPIKE_TMP/ctor-ran.txt")"
done
[ -f "$SPIKE_TMP/exfil.txt" ] && say "    exfil.txt written by plugin: $(cat "$SPIKE_TMP/exfil.txt")"

# --- the real NotchCore as a dynamic library -------------------------------------------
say ""
say "=== real NotchCore built as a dynamic library with library evolution ==="
RC="$B/realcore"
mkdir -p "$RC/lib"
if "${SWIFTC[@]}" -swift-version 6 -emit-library -module-name NotchCore -enable-library-evolution \
    -emit-module -emit-module-path "$RC/lib/NotchCore.swiftmodule" -emit-module-interface-path "$RC/lib/NotchCore.swiftinterface" \
    -Xlinker -install_name -Xlinker @rpath/libNotchCore.dylib "$REAL"/NotchCore/*.swift -o "$RC/lib/libNotchCore.dylib" \
    > "$B/logs/build-realcore.log" 2>&1; then
    say "NotchCore dylib built; warnings: $(grep -c 'warning:' "$B/logs/build-realcore.log")"
    # Plugin authors get only the textual interface + the dylib: hide the binary module.
    mkdir -p "$RC/sdk"
    cp "$RC/lib/NotchCore.swiftinterface" "$RC/lib/libNotchCore.dylib" "$RC/sdk/"
    mkdir -p "$RC/plugins/DemoBlock.topblock/Contents/MacOS"
    cp "$SRC/plist/DemoBlock.plist" "$RC/plugins/DemoBlock.topblock/Contents/Info.plist"
    # DemoBlock.swift is compiled unchanged. Swift 6 mode first (what the package uses).
    build_demo() {
        "${SWIFTC[@]}" -swift-version "$1" -emit-library -module-name DemoBlock -I "$RC/sdk" -L "$RC/sdk" -lNotchCore \
            "$REAL/DemoBlock/DemoBlock.swift" "$SRC/RealDemoPlugin/Entry.swift" \
            -o "$RC/plugins/DemoBlock.topblock/Contents/MacOS/DemoBlock" > "$B/logs/build-realdemo-swift$1.log" 2>&1
    }
    if build_demo 6; then
        say "real DemoBlock built against NotchCore.swiftinterface in Swift 6 mode"
    else
        say "real DemoBlock does NOT build in Swift 6 mode against the evolution-enabled NotchCore:"
        grep -E '^/.*error:' "$B/logs/build-realdemo-swift6.log" | sanitize | sed 's/^/    /' | tee -a "$RESULTS"
        if build_demo 5; then
            say "real DemoBlock built in Swift 5 mode (same errors become warnings: $(grep -cE '^/.*warning:' "$B/logs/build-realdemo-swift5.log"))"
        else
            say "BUILD FAILED real DemoBlock plugin in Swift 5 mode too"; tail -5 "$B/logs/build-realdemo-swift5.log"
        fi
    fi
    "${SWIFTC[@]}" -swift-version 6 -module-name RealHost -I "$RC/lib" -L "$RC/lib" -lNotchCore \
        -Xlinker -rpath -Xlinker @executable_path/lib "$SRC/RealHost/main.swift" -o "$RC/tn-spike-realhost" \
        > "$B/logs/build-realhost.log" 2>&1 || { say "BUILD FAILED real host"; tail -5 "$B/logs/build-realhost.log"; }
    sign -s "$DEV_ID" "$RC/lib/libNotchCore.dylib"
    sign -s "$DEV_ID" "$RC/plugins/DemoBlock.topblock"
    sign -s "$DEV_ID" --options runtime "$RC/tn-spike-realhost"
    run "realcore" "$RC/tn-spike-realhost" "$RC/plugins"
else
    say "real NotchCore did not build as a dylib:"
    grep -m5 'error:' "$B/logs/build-realcore.log" | sanitize | tee -a "$RESULTS"
fi

# Crashed runs make macOS write crash reports; remove the ones this run caused.
REPORTS=$(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'tn-spike-*' -newer "$B/start-marker" 2>/dev/null)
say ""
say "crash reports written by macOS for this run: $(echo "$REPORTS" | grep -c . ) (deleted)"
[ -n "$REPORTS" ] && echo "$REPORTS" | while read -r f; do rm -f "$f"; done

say ""
say "done. Summary: .build/results.txt  Logs: .build/logs/"
