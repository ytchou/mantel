#!/bin/bash
# Throwaway: questions 3 and 4. Starts two test proxies (8899 = the gate
# port, 8898 = another local listener), runs the probes under the given
# profile (default gate), prints each proxy's log, stops the proxies.
#   ./q3.sh [profile]
cd "$(dirname "$0")"
P=${1:-gate}
LOGS=${SCRATCH:-/private/tmp/sbspike}
mkdir -p "$LOGS"
python3 -I proxy.py 8899 > "$LOGS/proxy-8899.log" 2>&1 & P1=$!
python3 -I proxy.py 8898 > "$LOGS/proxy-8898.log" 2>&1 & P2=$!
trap 'kill $P1 $P2 2>/dev/null' EXIT
sleep 1
probes=(
  "tcp 127.0.0.1 8899"
  "tcp localhost 8899"
  "tcp 127.0.0.1 8898"
  "tcp 17.253.144.10 443"
  "url https://www.apple.com/"
  "proxy 8899 https://www.apple.com/ dict"
  "proxy 8899 https://www.apple.com/ config"
  "proxy 8898 https://www.apple.com/ dict"
  "dns www.apple.com"
  "dns spike-$RANDOM.example.org"
)
for c in "${probes[@]}"; do
  # shellcheck disable=SC2086
  out=$(./run.sh "$P" $c < /dev/null 2>&1 | grep RESULT)
  echo "$P | $c | $out"
done
echo "--- proxy 8899 (gate port) requests:"; grep REQUEST "$LOGS/proxy-8899.log"
echo "--- proxy 8898 (other port) requests:"; grep REQUEST "$LOGS/proxy-8898.log"
true
