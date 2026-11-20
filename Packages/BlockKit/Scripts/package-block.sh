#!/bin/sh
# Assembles a block package from a built executable and its manifest.
#
#   package-block.sh <executable> <manifest.json> [<output folder>]
#
# Creates <output folder>/<Name>.topblock, where <Name> is the manifest's
# "name" without spaces. Inside: manifest.json, and the executable at the
# path the manifest's "executable" field names. An existing package of the
# same name is replaced. The output folder defaults to the current folder.
#
# Example, from Packages/BlockKit:
#   swift build --product HelloBlock
#   Scripts/package-block.sh .build/debug/HelloBlock Examples/HelloBlock/manifest.json build
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

name=$(plutil -extract name raw -o - "$manifest" 2>/dev/null) || { echo "error: manifest has no \"name\"" >&2; exit 1; }
target=$(plutil -extract executable raw -o - "$manifest" 2>/dev/null) || { echo "error: manifest has no \"executable\"" >&2; exit 1; }
name=$(printf '%s' "$name" | tr -d ' ')

# The executable must stay inside the package.
case "$target" in
	/* | .. | ../* | */../* | */..) echo "error: \"executable\" must be a path inside the package: $target" >&2; exit 1 ;;
esac
[ -n "$name" ] || { echo "error: manifest \"name\" is empty" >&2; exit 1; }
# The name becomes a folder name in the output folder: no path separators,
# and not hidden or "." / "..".
case "$name" in
	*/* | .*) echo "error: manifest \"name\" must not contain \"/\" or start with \".\": $name" >&2; exit 1 ;;
esac

mkdir -p "$out"
package="$out/$name.topblock"
staging="$out/.$name.topblock.tmp"
rm -rf "$staging"
mkdir -p "$staging/$(dirname "$target")"
cp "$manifest" "$staging/manifest.json"
cp "$executable" "$staging/$target"
chmod 755 "$staging/$target"
rm -rf "$package"
mv "$staging" "$package"
echo "$package"
