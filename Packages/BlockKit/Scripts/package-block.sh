#!/bin/sh
# Assembles and signs a block package from a built executable and its manifest.
#
#   package-block.sh <executable> <manifest.json> [<output folder>]
#
# Creates <output folder>/<Name>.topblock, where <Name> is the manifest's
# "name" without spaces. The package is a macOS bundle:
#
#   <Name>.topblock/Contents/Info.plist              made from the manifest
#   <Name>.topblock/Contents/MacOS/<executable>      the manifest's "executable"
#   <Name>.topblock/Contents/Resources/manifest.json
#
# The bundle is then signed, so the signature seals the manifest with the
# executable. The identity is taken from the BLOCK_SIGN_IDENTITY environment
# variable; without it the bundle is signed ad hoc ("-"). The app runs an
# ad hoc package only after the owner approves that exact build, and never
# as an update of a signed block. Never write an identity into this file.
#
# BLOCK_SIGN_TIMESTAMP, optional, sets codesign's secure timestamp: "none"
# signs without one (no network needed, for local and offline builds); any
# other value is passed as the timestamp server URL. Unset keeps codesign's
# default.
#
# An existing package of the same name is replaced. The output folder
# defaults to the current folder.
#
# Example, from Packages/BlockKit:
#   swift build --product HelloBlock
#   Scripts/package-block.sh .build/debug/HelloBlock Examples/HelloBlock/manifest.json build
#   BLOCK_SIGN_IDENTITY="Apple Development: ..." Scripts/package-block.sh ...   # signed
set -eu

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
	echo "usage: $0 <executable> <manifest.json> [<output folder>]" >&2
	exit 64
fi
executable=$1
manifest=$2
out=${3:-.}

[ -f "$executable" ] && [ -x "$executable" ] || { echo "error: not an executable file: $executable" >&2; exit 1; }
[ -f "$manifest" ] || { echo "error: no manifest at $manifest" >&2; exit 1; }

field() {
	plutil -extract "$1" raw -o - "$manifest" 2>/dev/null || { echo "error: manifest has no \"$1\"" >&2; exit 1; }
}
name=$(field name)
id=$(field id)
version=$(field version)
target=$(field executable)
name=$(printf '%s' "$name" | tr -d ' ')

[ -n "$name" ] || { echo "error: manifest \"name\" is empty" >&2; exit 1; }
# The name becomes a folder name in the output folder: no path separators,
# and not hidden or "." / "..".
case "$name" in
	*/* | .*) echo "error: manifest \"name\" must not contain \"/\" or start with \".\": $name" >&2; exit 1 ;;
esac
# The id becomes part of the bundle identifier.
case "$id" in
	'' | *[!a-z0-9-]*) echo "error: manifest \"id\" must be lowercase letters, digits and dashes: $id" >&2; exit 1 ;;
esac
# The executable is a file name in Contents/MacOS (CFBundleExecutable).
case "$target" in
	'' | */* | . | ..) echo "error: \"executable\" must be a file name, without a folder: $target" >&2; exit 1 ;;
esac
[ -n "$version" ] || { echo "error: manifest \"version\" is empty" >&2; exit 1; }

mkdir -p "$out"
package="$out/$name.topblock"
staging="$out/.$name.topblock.tmp"
rm -rf "$staging"
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
cp "$manifest" "$staging/Contents/Resources/manifest.json"
cp "$executable" "$staging/Contents/MacOS/$target"
chmod 755 "$staging/Contents/MacOS/$target"

# Info.plist from the manifest. plutil writes the values, so no text from
# the manifest is pasted into XML.
plist="$staging/Contents/Info.plist"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict/>\n</plist>\n' > "$plist"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "$plist"
plutil -insert CFBundleIdentifier -string "dev.topnotch.block.$id" "$plist"
plutil -insert CFBundleExecutable -string "$target" "$plist"
plutil -insert CFBundleShortVersionString -string "$version" "$plist"
plutil -insert CFBundlePackageType -string "BNDL" "$plist"

# Copies can carry extended attributes, which codesign refuses.
xattr -cr "$staging"
timestamp=""
case "${BLOCK_SIGN_TIMESTAMP:-}" in
	'') ;;
	none) timestamp="--timestamp=none" ;;
	*) timestamp="--timestamp=$BLOCK_SIGN_TIMESTAMP" ;;
esac
codesign --force --sign "${BLOCK_SIGN_IDENTITY:--}" ${timestamp:+"$timestamp"} "$staging"

rm -rf "$package"
mv "$staging" "$package"
echo "$package"
