#!/usr/bin/env bash
# Generates a repeating pulse on bank0/lineN by toggling pull-up/down
set -euo pipefail
BANK=/sys/devices/platform/gpio-sim.0/sim_gpio_bank.0
LINE=${1:-0}
HI=1e-3   # 1 ms HIGH
LO=2e-3   # 2 ms LOW
while true; do
  echo pull-up > $BANK/sim_gpio$LINE/pull
  usleep $(awk -v s=$HI 'BEGIN{printf("%d", s*1e6)}')
  echo pull-down > $BANK/sim_gpio$LINE/pull
  usleep $(awk -v s=$LO 'BEGIN{printf("%d", s*1e6)}')
done
