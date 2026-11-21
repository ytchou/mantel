#!/bin/bash
# Throwaway: run sbspike under /usr/bin/sandbox-exec the way BlockProcess starts
# a block (argv: sandbox-exec -p <profile> <executable>; environment: PATH,
# HOME, TMPDIR = the block's own temp folder, TOPNOTCH_BLOCK_GENERATION).
#
#   ./run.sh <profile> <sbspike args...>      run one probe
#   ./run.sh <profile> --print                print the profile text
#
# Profiles (all keep the current write, network and Apple-event rules):
#   denylist   today's SandboxProfile text (no token)
#   allowlist  (deny file-read*) + SYSTEM_READS + package, data, block temp,
#              + (allow file-read-metadata (subpath home))
#   allowlist-tmp  allowlist plus reads of the whole per-user temp folder
#   gate       allowlist + (deny network*) (allow network-outbound (remote tcp "localhost:$PORT"))
#   gate-dns   gate + (deny mach-lookup (global-name "com.apple.dnssd.service"))
#   gate-dns-prefs  gate-dns + deny of ~/Library/Preferences/dev.topnotch.TopNotch.plist
#              + (deny mach-lookup cfprefsd daemon and agent)
#   prefs-file  allowlist + the preferences file denied (no cfprefsd deny)
# Variables: PORT (default 8899), EXTRA (SBPL appended last).
set -euo pipefail
cd "$(dirname "$0")"

ID=dev.topnotch.spike
SCRATCH=${SCRATCH:-/private/tmp/sbspike}
PKG="$SCRATCH/Spike.topblock"
DATA="$HOME/Library/Application Support/TopNotchSpike/BlockData/$ID"
SHARED=$(realpath "${TMPDIR:-/tmp}")
APPTMP="$SHARED/TopNotch"
BTMP="$APPTMP/Blocks/$ID"
PORT=${PORT:-8899}
PREFS="$HOME/Library/Preferences/dev.topnotch.TopNotch.plist"

mkdir -p "$PKG" "$DATA" "$BTMP"
cp -f .build/debug/sbspike "$PKG/sbspike"

q() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

# macOS system locations a block may read. Narrowed by measurement (FINDINGS.md).
SYSTEM_READS='(allow file-read*
  (literal "/")
  (literal "/etc")
  (literal "/var")
  (literal "/tmp")
  (subpath "/System")
  (subpath "/usr")
  (subpath "/bin")
  (subpath "/sbin")
  (subpath "/Library/Apple")
  (subpath "/Library/Preferences")
  (subpath "/private/etc")
  (subpath "/private/var/db/timezone")
  (subpath "/private/var/db/dyld")
  (subpath "/private/var/db/eligibilityd")
  (subpath "/dev"))'
SYSTEM_READS=${SYSTEM_READS_OVERRIDE:-$SYSTEM_READS}

base_rules() {
  cat <<EOF
(version 1)
(allow default)
(deny network*)
(deny appleevent-send)
(deny file-write*)
(allow file-write* (subpath $(q "$DATA")) (subpath $(q "$SHARED")) (subpath "/dev"))
(deny file-read* file-write* (subpath $(q "$APPTMP")))
(allow file-read* file-write* (subpath $(q "$BTMP")))
EOF
}

allowlist_rules() {
  base_rules
  echo "(deny file-read*)"
  echo "$SYSTEM_READS"
  echo "(allow file-read* (subpath $(q "$PKG")) (subpath $(q "$DATA")) (subpath $(q "$BTMP")))"
  echo "(allow file-read-metadata (subpath $(q "$HOME")))"
}

profile() {
  case "$1" in
    denylist)
      base_rules
      echo "(deny file-read* (subpath $(q "$HOME")))"
      echo "(allow file-read* (subpath $(q "$DATA")) (subpath $(q "$PKG")))"
      echo "(allow file-read-metadata (subpath $(q "$HOME")))" ;;
    allowlist) allowlist_rules ;;
    allowlist-tmp)
      allowlist_rules
      echo "(allow file-read* (subpath $(q "$SHARED")))"
      echo "(deny file-read* (subpath $(q "$APPTMP")))"
      echo "(allow file-read* (subpath $(q "$BTMP")))" ;;
    gate)
      allowlist_rules
      echo "(deny network*)"
      echo "(allow network-outbound (remote tcp \"localhost:$PORT\"))" ;;
    gate-dns)
      profile gate
      echo '(deny mach-lookup (global-name "com.apple.dnssd.service"))' ;;
    prefs-file)
      allowlist_rules
      echo "(deny file-read* file-write* (literal $(q "$PREFS")))" ;;
    gate-dns-prefs)
      profile gate-dns
      echo "(deny file-read* file-write* (literal $(q "$PREFS")))"
      echo '(deny mach-lookup (global-name "com.apple.cfprefsd.daemon") (global-name "com.apple.cfprefsd.agent"))' ;;
    *) echo "unknown profile $1" >&2; exit 2 ;;
  esac
  [ -n "${EXTRA:-}" ] && echo "$EXTRA"
  return 0
}

name=$1; shift
text=$(profile "$name")
if [ "${1:-}" = "--print" ]; then echo "$text"; exit 0; fi

exec env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" TMPDIR="$BTMP/" \
  TOPNOTCH_BLOCK_GENERATION=1 \
  /usr/bin/sandbox-exec -p "$text" "$PKG/sbspike" "$@"
