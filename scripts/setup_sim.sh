#!/usr/bin/env bash
set -euo pipefail

echo "[+] Preparing kernel modules & filesystems (requires root/privileged)..."

modprobe configfs || true
mount | grep -q " on /sys/kernel/config type configfs " \
  || mount -t configfs none /sys/kernel/config || true

modprobe vcan || true
ip link show vcan0 >/dev/null 2>&1 || { ip link add dev vcan0 type vcan; ip link set up vcan0; }
modprobe can-isotp || true

modprobe gpio-sim || true
SIMROOT="/sys/kernel/config/gpio-sim/sim0"
mkdir -p "${SIMROOT}/bank0"

# Turn live off before reconfig
echo 0 | tee "${SIMROOT}/live" >/dev/null || true

# num-lines vs num_lines (handle both)
if [ -e "${SIMROOT}/bank0/num-lines" ]; then
  echo 8 | tee "${SIMROOT}/bank0/num-lines" >/dev/null
elif [ -e "${SIMROOT}/bank0/num_lines" ]; then
  echo 8 | tee "${SIMROOT}/bank0/num_lines" >/dev/null
else
  echo "[!] Neither num-lines nor num_lines exist under ${SIMROOT}/bank0" >&2
  ls -l "${SIMROOT}/bank0" || true
  exit 1
fi

# Go live
echo 1 | tee "${SIMROOT}/live" >/dev/null

echo "[+] gpiodetect:"
gpiodetect || true

CHIP_DIR=$(find /sys/devices/platform/gpio-sim.0 -maxdepth 2 -type d -name "gpiochip*" 2>/dev/null | head -n1 || true)
if [ -n "${CHIP_DIR:-}" ]; then
  echo "[+] sim_gpio* under: ${CHIP_DIR}"
  find "${CHIP_DIR}" -maxdepth 1 -type d -name "sim_gpio*" -print || true
else
  echo "[!] Could not locate /sys/devices/platform/gpio-sim.0/gpiochip*/sim_gpio*"
fi

cat <<'EOF'

[OK] gpio-sim + vcan + isotp ready.

Quick GPIO edge check (adjust chip if needed):

  gpiodetect   # look for 'gpio-sim...'
  gpiomon --rising --falling gpiochip1 0 1 &
  echo pull-up   | sudo tee /sys/devices/platform/gpio-sim.0/gpiochip1/sim_gpio0/pull >/dev/null
  echo pull-down | sudo tee /sys/devices/platform/gpio-sim.0/gpiochip1/sim_gpio0/pull >/dev/null
  fg

EOF
