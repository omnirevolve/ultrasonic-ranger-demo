#!/usr/bin/env bash
set -euo pipefail
CHIP=/sys/devices/platform/gpio-sim.0/gpiochip1  # у тебя так
LINE=${1:-0}
P="$CHIP/sim_gpio${LINE}/pull"
[[ -e "$P" ]] || { echo "[!] $P not found"; exit 1; }

echo pull-up   | sudo tee "$P" >/dev/null
sleep 0.01
echo pull-down | sudo tee "$P" >/dev/null
