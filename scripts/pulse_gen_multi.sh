#!/usr/bin/env bash
# Fast HC-SR04-like pulse generator for gpio-sim (root only, no sudo tee).
# Usage:
#   sudo ./scripts/pulse_gen_multi.sh "0:1.0,1:1.6,2:0.8,3:2.2,4:0.35"
# Env:
#   DEBUG=1     # optional verbose logs
#
# Note: we intentionally avoid `set -e`/`pipefail` to keep running despite single write errors.

set -u
export LC_ALL=C

[ "$(id -u)" -eq 0 ] || { echo "[!] Run as root: sudo $0 \"0:...\"" >&2; exit 1; }

MAP=${1:-"0:1.0,1:1.6,2:0.8,3:2.2,4:0.35"}
C=343.0              # m/s (speed of sound)
FRAME_S=0.080        # 80 ms frame (room for 5 pulses)
GAP_S=0.002          # 2 ms gap between lines (readability)

cleanup() { [ "${DEBUG:-0}" != "0" ] && echo "[i] exit"; }
trap 'cleanup; exit 0' INT TERM

# --- find gpio-sim chip path (wait up to 3s if not ready) ---
find_chip_dir() {
  local tries=30
  while [ $tries -gt 0 ]; do
    local d
    d="$(find /sys/devices/platform/gpio-sim.0 -maxdepth 2 -type d -name 'gpiochip*' 2>/dev/null | head -n1 || true)"
    if [ -n "${d:-}" ] && [ -d "$d" ]; then
      echo "$d"
      return 0
    fi
    sleep 0.1
    tries=$((tries-1))
  done
  return 1
}

CHIP_DIR="$(find_chip_dir || true)"
if [ -z "${CHIP_DIR:-}" ]; then
  echo "[!] gpio-sim chip not found (is setup_sim.sh loaded?)" >&2
  exit 1
fi

# --- parse "L:D,L:D,..." -> arrays ---
declare -a LINES DISTS PULLS
IFS=',' read -r -a PAIRS <<< "$MAP"
for p in "${PAIRS[@]}"; do
  IFS=':' read -r line dist <<< "$p"
  [[ -n "${line:-}" && -n "${dist:-}" ]] || continue
  LINES+=("$line")
  DISTS+=("$dist")
  PULLS+=("${CHIP_DIR}/sim_gpio${line}/pull")
done

[ "${#PULLS[@]}" -gt 0 ] || { echo "[!] no valid line:dist pairs in MAP='$MAP'"; exit 1; }

if [ "${DEBUG:-0}" != "0" ]; then
  echo "[debug] CHIP_DIR=${CHIP_DIR}"
  for i in "${!LINES[@]}"; do
    echo "[debug] line=${LINES[$i]} pull=${PULLS[$i]} dist=${DISTS[$i]}"
  done
fi

# --- helpers ---
write_pull() {
  # Return 0/1 without aborting the script.
  local pull="$1" value="$2"
  if ! printf "%s" "$value" > "$pull" 2>/dev/null; then
    [ "${DEBUG:-0}" != "0" ] && echo "[warn] write '$value' to $pull failed"
    return 1
  fi
  return 0
}

pulse_one() {
  local pull="$1" high_s="$2" line_id="$3"
  [ -e "$pull" ] || { [ "${DEBUG:-0}" != "0" ] && echo "[warn] missing $pull"; return 0; }
  write_pull "$pull" "pull-up"   || return 0
  sleep "$high_s"
  write_pull "$pull" "pull-down" || return 0
  [ "${DEBUG:-0}" != "0" ] && printf "[debug] pulsed line%s width=%.6fs\n" "$line_id" "$high_s"
  return 0
}

# --- main loop ---
while :; do
  frame_start="$(date +%s.%N)"

  for i in "${!LINES[@]}"; do
    line="${LINES[$i]}"
    dist="${DISTS[$i]}"
    pull="${PULLS[$i]}"
    # time-of-flight: t = 2*dist / c
    high_s="$(awk -v d="$dist" -v c="$C" 'BEGIN{printf("%.6f",(2.0*d)/c)}')"
    pulse_one "$pull" "$high_s" "$line"
    sleep "$GAP_S"
  done

  now="$(date +%s.%N)"
  sleep_left="$(awk -v per="$FRAME_S" -v s="$frame_start" -v n="$now" 'BEGIN{d=per-(n-s); if(d<0) d=0; printf("%.6f", d)}')"
  sleep "$sleep_left"
done
