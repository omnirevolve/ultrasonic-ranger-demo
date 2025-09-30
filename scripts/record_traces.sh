#!/usr/bin/env bash
set -euo pipefail
trace-cmd record -e irq -e sched -- sleep 5
perf record -g -- ./build/ranger-u/ranger-u --duration 5 || true
