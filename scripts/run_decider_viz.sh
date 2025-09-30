#!/usr/bin/env bash
# Minimal demo runner: reload kernel module (via your reload_k.sh),
# optional pulse generator, then launch the TUI that reads debugfs.

set -euo pipefail
cd "$(dirname "$0")/.."

SYSFS_DIR="/sys/kernel/debug/ranger_k"
SYSFS_DIST="$SYSFS_DIR/distances"
SYSFS_STAT="$SYSFS_DIR/stats"

# Env knobs:
#   NO_GEN=1         - do not start pulse generator
#   MAP="0:1.0,1:1.6,2:0.8,3:2.2,4:0.35"
#   FRAME_S=0.080
#   GAP_S=0.002

require_debugfs() {
  if [ ! -d /sys/kernel/debug ]; then
    echo "[!] debugfs is not mounted (try: sudo mount -t debugfs none /sys/kernel/debug)" >&2
    exit 1
  fi
}

wait_for() {
  local path="$1" timeout="${2:-20}"
  while (( timeout-- > 0 )); do
    if [ -e "$path" ]; then return 0; fi
    sleep 0.2
  done
  return 1
}

require_debugfs

echo "[i] reload kernel module (via ranger-k/reload_k.sh) ..."
( cd ranger-k && ./reload_k.sh )

if ! wait_for "$SYSFS_DIST" 30; then
  echo "[!] $SYSFS_DIST did not appear after reload" >&2
  exit 1
fi

# Show a quick snapshot (what you see with watch)
echo "[i] debugfs snapshot:"
sudo awk 'NR<3{print}' "$SYSFS_STAT" || true
sudo awk 'NR<2{print}' "$SYSFS_DIST" || true

# Start pulse generator unless NO_GEN=1
if [ "${NO_GEN:-0}" = "0" ]; then
  MAP=${MAP:-"0:1.0,1:1.6,2:0.8,3:2.2,4:0.35"}
  FRAME_S=${FRAME_S:-0.080}
  GAP_S=${GAP_S:-0.002}
  echo "[i] start pulse generator: MAP='$MAP' FRAME_S=$FRAME_S GAP_S=$GAP_S"
  sudo env FRAME_S="$FRAME_S" GAP_S="$GAP_S" DEBUG="${DEBUG:-0}" \
    ./scripts/pulse_gen_multi.sh "$MAP" > /tmp/pulse_gen.log 2>&1 &
  GEN_PID=$!
  echo "[i] generator PID=$GEN_PID (log: /tmp/pulse_gen.log)"
else
  echo "[i] NO_GEN=1 — skipping pulse generator"
fi

echo "[i] launching TUI (source: $SYSFS_DIST)"
exec python3 ./tools/demo_decider_viz.py --sysfs "$SYSFS_DIST"
