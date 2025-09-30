#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# найдём gpio-sim chip и base
CHIP_LINK=$(ls -l /sys/class/gpio/ | awk '/gpiochip[0-9]+/ && $NF ~ /gpio-sim/{print $NF; exit}' || true)
if [[ -z "${CHIP_LINK:-}" ]]; then
  echo "[!] gpio-sim chip not found under /sys/class/gpio"; exit 1
fi

CHIP_DIR="/sys/class/gpio/${CHIP_LINK##*/}"
BASE=$(cat "$CHIP_DIR/base")
echo "[i] gpio-sim base=$BASE (label=$(cat "$CHIP_DIR/label"), ngpio=$(cat "$CHIP_DIR/ngpio"))"

# пересоберём и перезагрузим модуль
make -C . clean >/dev/null 2>&1 || true
make -C .
sudo rmmod ranger_k 2>/dev/null || true
sudo insmod ./ranger_k.ko line_gpios=$BASE,$(($BASE+1)),$(($BASE+2)),$(($BASE+3)),$(($BASE+4))

echo "[i] dmesg tail:"
sudo dmesg | tail -n 10
