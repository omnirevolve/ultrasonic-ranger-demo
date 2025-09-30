#!/usr/bin/env bash
set -euo pipefail
# Trace IRQ and scheduling for ranger_k.
DUR="${1:-5}"
EVENTS="${EVENTS:-irq:*,sched:*}"

sudo trace-cmd record -e "$EVENTS" -d "${DUR}s"
echo "[+] trace.dat saved. View with: trace-cmd report | less"
