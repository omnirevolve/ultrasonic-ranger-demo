#!/usr/bin/env bash
set -euo pipefail
# Demo: pipe ranger-u JSONL into ranger-can ISO-TP over vcan0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IFACE="${IFACE:-vcan0}"
TXID="${TXID:-0x701}"
RXID="${RXID:-0x700}"
DUR="${DUR_SEC:-10}"

# ensure vcan + isotp exist
sudo modprobe vcan can-isotp || true
ip link show "$IFACE" >/dev/null 2>&1 || { sudo ip link add dev "$IFACE" type vcan; sudo ip link set up "$IFACE"; }

# build tools
cmake -S "$ROOT" -B "$ROOT/build"
cmake --build "$ROOT/build" --target ranger-can ranger-u -- -j

# start receiver for demo
(isotprecv -s "$RXID" -d "$TXID" "$IFACE" | hexdump -C & echo $! > /tmp/isotprx.pid) || true
sleep 0.2

# run generator + ranger-u + pipe to ranger-can
sudo "$ROOT/scripts/pulse_gen_multi.sh" "0:1.0,1:1.6,2:0.8,3:2.2,4:0.35" & GEN_PID=$!
trap 'kill $GEN_PID 2>/dev/null || true; [ -f /tmp/isotprx.pid ] && kill $(cat /tmp/isotprx.pid) 2>/dev/null || true' EXIT

"$ROOT/build/ranger-u/ranger-u" \
  --chip /dev/$(gpiodetect | awk "/gpio-sim/ {print \$1}" | head -n1) \
  --lines 0,1,2,3,4 \
  --duration "$DUR" \
  --rate-hz 20 \
  --jsonl /proc/self/fd/1 --csv /dev/null \
| "$ROOT/build/ranger-can/ranger-can" --if "$IFACE" --tx "$TXID" --rx "$RXID" --rate-hz 20 --verbose

