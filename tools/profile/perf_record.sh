#!/usr/bin/env bash
set -euo pipefail
# Record perf for the user-space measurer (ranger-u).
DUR="${1:-10}"
BIN="${BIN:-./build/ranger-u/ranger-u}"
CHIP="${CHIP:-/dev/gpiochip1}"
LINES="${LINES:-0,1,2,3,4}"
PERF_OPTS="${PERF_OPTS:--F 999 -g}"

sudo perf record $PERF_OPTS -- \
  "$BIN" --chip "$CHIP" --lines "$LINES" --duration "$DUR" --rate-hz 20 --jsonl /dev/null --csv /dev/null
echo "[+] perf.data saved. View with: perf report"
