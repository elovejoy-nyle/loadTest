#!/usr/bin/env bash
set -euo pipefail

# cpu_burn.sh - Max out CPU to observe power/thermal behavior on Linux (Pi/CM modules friendly)
#
# Usage:
#   ./cpu_burn.sh                 # run until Ctrl+C
#   ./cpu_burn.sh -t 600          # run 10 minutes
#   ./cpu_burn.sh -w 4            # force 4 workers
#   ./cpu_burn.sh -l burn.csv     # custom log file
#
# Notes:
# - Will try to set CPU governor to "performance" (needs sudo + supported cpufreq driver).
# - Prefers stress-ng if available; otherwise uses Python busy loops.
# - Logs: timestamp,temp_C,freq_khz,load1,throttle_hex (throttle on Pi if vcgencmd present)

DURATION=0          # seconds; 0 = until interrupted
WORKERS=0           # 0 = nproc
LOGFILE="cpu_burn_$(date +%Y%m%d_%H%M%S).csv"
SET_GOVERNOR=1

usage() {
  sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'
}

while getopts ":t:w:l:gh" opt; do
  case "$opt" in
    t) DURATION="$OPTARG" ;;
    w) WORKERS="$OPTARG" ;;
    l) LOGFILE="$OPTARG" ;;
    g) SET_GOVERNOR=0 ;;          # don't change governor
    h) usage; exit 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage; exit 2 ;;
    :)  echo "Option -$OPTARG requires an argument." >&2; usage; exit 2 ;;
  esac
done

if [[ "$WORKERS" -le 0 ]]; then
  WORKERS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc || echo 1)"
fi

cleanup() {
  echo ""
  echo "Stopping load..."
  if [[ -n "${LOAD_PID:-}" ]] && kill -0 "$LOAD_PID" 2>/dev/null; then
    kill "$LOAD_PID" 2>/dev/null || true
    wait "$LOAD_PID" 2>/dev/null || true
  fi
  if [[ -n "${PY_PIDS:-}" ]]; then
    # shellcheck disable=SC2086
    kill $PY_PIDS 2>/dev/null || true
    # shellcheck disable=SC2086
    wait $PY_PIDS 2>/dev/null || true
  fi
}
trap cleanup INT TERM EXIT

set_governor_performance() {
  # Try both per-policy and per-cpu paths
  local changed=0

  if command -v cpupower >/dev/null 2>&1; then
    if cpupower frequency-set -g performance >/dev/null 2>&1; then
      changed=1
    fi
  fi

  for gov in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor \
             /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -w "$gov" ]] || continue
    echo performance > "$gov" 2>/dev/null || true
    changed=1
  done

  if [[ "$changed" -eq 1 ]]; then
    echo "CPU governor: attempted to set 'performance'"
  else
    echo "CPU governor: not changed (no permission/driver). Run with sudo if you want this."
  fi
}

read_temp_c() {
  # Prefer vcgencmd on Raspberry Pi, fallback to thermal_zone0
  if command -v vcgencmd >/dev/null 2>&1; then
    # temp=54.0'C
    vcgencmd measure_temp 2>/dev/null | awk -F'[=\\x27]' '{print $2}' || true
    return
  fi
  if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
    awk '{printf "%.1f\n", $1/1000.0}' /sys/class/thermal/thermal_zone0/temp
    return
  fi
  echo ""
}

read_freq_khz() {
  # policy0 is usually representative; fallback to cpu0
  if [[ -r /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq ]]; then
    cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null || true
    return
  fi
  if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]]; then
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || true
    return
  fi
  echo ""
}

read_throttle_hex() {
  # Pi-specific throttling flags (undervoltage, throttled, etc.)
  if command -v vcgencmd >/dev/null 2>&1; then
    # throttled=0x50000
    vcgencmd get_throttled 2>/dev/null | awk -F'=' '{print $2}' || true
    return
  fi
  echo ""
}

start_load() {
  if command -v stress-ng >/dev/null 2>&1; then
    echo "Load generator: stress-ng (workers=$WORKERS)"
    if [[ "$DURATION" -gt 0 ]]; then
      # --timeout ends stress-ng itself; we still log for DURATION below
      stress-ng --cpu "$WORKERS" --cpu-method matrixprod --verify --timeout "${DURATION}s" >/dev/null 2>&1 &
      LOAD_PID=$!
    else
      stress-ng --cpu "$WORKERS" --cpu-method matrixprod --verify >/dev/null 2>&1 &
      LOAD_PID=$!
    fi
    return
  fi

  echo "Load generator: python busy-loop per core (workers=$WORKERS)"
  PY_PIDS=""
  for _ in $(seq 1 "$WORKERS"); do
    python3 - <<'PY' >/dev/null 2>&1 &
import time
x = 0
# Tight integer loop; keeps a core busy.
while True:
    x = (x + 1) & 0xFFFFFFFF
    # prevent being optimized away in some runtimes
    if x == 0:
        time.sleep(0)
PY
    PY_PIDS="$PY_PIDS $!"
  done
}

log_loop() {
  echo "Writing log: $LOGFILE"
  echo "timestamp,temp_C,freq_khz,load1,throttle_hex" > "$LOGFILE"

  local start_ts now_ts elapsed
  start_ts="$(date +%s)"

  while true; do
    now_ts="$(date +%s)"
    elapsed=$(( now_ts - start_ts ))

    if [[ "$DURATION" -gt 0 && "$elapsed" -ge "$DURATION" ]]; then
      break
    fi

    local ts temp freq load1 thr
    ts="$(date -Is)"
    temp="$(read_temp_c)"
    freq="$(read_freq_khz)"
    load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || true)"
    thr="$(read_throttle_hex)"

    echo "${ts},${temp},${freq},${load1},${thr}" >> "$LOGFILE"
    sleep 1
  done
}

main() {
  echo "Cores/workers: $WORKERS"
  echo "Duration: $([[ "$DURATION" -gt 0 ]] && echo "${DURATION}s" || echo "until Ctrl+C")"

  if [[ "$SET_GOVERNOR" -eq 1 ]]; then
    set_governor_performance
  fi

  start_load
  log_loop
}

main

