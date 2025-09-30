#!/usr/bin/env bash
# End-to-end PC emulation: setup, start generator (sudo), run ranger-u.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 1) bring up sim (needs sudo)
sudo "$SCRIPT_DIR/setup_sim.sh"

# 2) distances (meters) "line:dist"
MAP=${1:-"0:1.0,1:1.6,2:0.8,3:2.2,4:0.35"}

# 3) detect chip
SIM_CHIP=$(gpiodetect | awk '/gpio-sim/ {print $1}' | head -n1)
[ -n "$SIM_CHIP" ] || { echo "[!] gpio-sim chip not found in gpiodetect"; exit 1; }
echo "[+] using $SIM_CHIP"

# 4) build
cmake -S "$ROOT" -B "$ROOT/build"
cmake --build "$ROOT/build" -- -j

# 5) start generator (root) in background
sudo DEBUG=${DEBUG:-0} "$SCRIPT_DIR/pulse_gen_multi.sh" "$MAP" & GEN_PID=$!
trap 'kill $GEN_PID 2>/dev/null || true' EXIT
echo "[+] pulse generator PID=$GEN_PID"

# 6) run ranger-u
"$ROOT/build/ranger-u/ranger-u" \
  --chip "/dev/$SIM_CHIP" \
  --lines 0,1,2,3,4 \
  --duration "${DUR_SEC:-10}" \
  --jsonl "$ROOT/data.jsonl" \
  --csv   "$ROOT/data.csv" \
  --rate-hz 20

echo "[OK] data -> $ROOT/data.jsonl, $ROOT/data.csv"
