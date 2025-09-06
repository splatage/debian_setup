#!/bin/bash
# setup-fan-service.sh
# Installs /usr/local/sbin/fan_control.sh and a systemd service.
# Reads CPU temps from sysfs coretemp only; writes fans via IPMI.
# Scope: simple baseline control, no smoothing, no SDR, no sensors CLI.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_PATH="/usr/local/sbin/fan_control.sh"
SERVICE_PATH="/etc/systemd/system/fan-control.service"
DEFAULTS_PATH="/etc/default/fan-control"

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

install_deps() {
  local pkgs=(ipmitool)  # sysfs read needs no packages; we only need ipmitool to write fans
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}"
  elif command -v zypper >/dev/null 2>&1; then
    zypper install -y "${pkgs[@]}"
  else
    echo "NOTE: Could not detect a supported package manager. Ensure installed: ${pkgs[*]}" >&2
  fi
}

write_script() {
  install -m 0755 /dev/stdin "${SCRIPT_PATH}" <<'FANEOF'
#!/bin/bash
# /usr/local/sbin/fan_control.sh
# Minimal, sysfs-only CPU-temp → fan control for IBM (IMM) or Dell/Unisys.
# - Temp source: /sys/class/hwmon/* coretemp (Package id N). No 'sensors', no SDR.
# - Control: baseline + gains + deadband; clamp to [MIN_PCT, MAX_PCT].
# - IBM: write configured banks only; no detection; trailing byte fixed to 0x01.
# - Dell: manual mode then set global %.

set -euo pipefail
IFS=$'\n\t'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---------- single-instance lock ----------
LOCKFILE="/var/run/fan_control.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "[$(date +'%F %T')] already running (lock $LOCKFILE). Exiting. PID=$$"
  exit 0
fi

# ---------- config (env-overridable) ----------
INTERVAL=${INTERVAL:-15}          # seconds between loops
BASELINE_C=${BASELINE_C:-50}      # target quiet temp (°C)
UP_GAIN=${UP_GAIN:-2}             # % per +1°C above baseline
DOWN_GAIN=${DOWN_GAIN:-1}         # % per -1°C below baseline
DEADBAND_C=${DEADBAND_C:-1}       # °C around baseline to hold MIN_PCT
MIN_PCT=${MIN_PCT:-5}            # floor %
MAX_PCT=${MAX_PCT:-50}            # ceiling % (IBM: stay <= ~0x50 to avoid mixing)

VENDOR=${VENDOR:-ibm}             # 'ibm' or 'dell'
IBM_BANKS=${IBM_BANKS:-0x01}      # space-separated list; no autodetect; e.g. "0x01" or "0x01 0x02"
IBM_CODEMAP=${IBM_CODEMAP:-linear} # 'table' or 'linear' (table is calmer on IBM)

DO_WRITE=${DO_WRITE:-1}           # 1=apply via ipmitool, 0=dry-run log only

# ---------- helpers ----------
now() { date +'%Y-%m-%d %H:%M:%S'; }
clamp_pct() { local p=$1; (( p<0 )) && p=0; (( p>100 )) && p=100; echo "$p"; }
log() { echo "[$(now)] $*"; }
run() {
  # echo the ipmitool command; execute only if DO_WRITE=1
  echo "+ $*"
  if [[ "$DO_WRITE" = "1" ]]; then
    "$@"
  fi
}

# ---------- sysfs temperature (coretemp only) ----------
# Returns hottest package temperature across all sockets (int °C), or empty on failure.
read_hottest_package_temp() {
  local best=-1
  shopt -s nullglob
  for H in /sys/class/hwmon/*; do
    [[ -r "$H/name" ]] || continue
    local name; name=$(<"$H/name")
    [[ "$name" =~ [Cc]oretemp ]] || continue

    local found_pkg=0
    for L in "$H"/temp*_label; do
      [[ -r "$L" ]] || continue
      local lab; lab=$(<"$L")
      if [[ "$lab" =~ [Pp]ackage[[:space:]]*id[[:space:]]*[0-9]+ ]]; then
        local base=${L%_label}
        local inp="${base}_input"
        [[ -r "$inp" ]] || continue
        local milli; milli=$(tr -dc '0-9' < "$inp")
        [[ -n "$milli" ]] || continue
        local deg=$(( milli / 1000 ))
        (( deg > 0 && deg <= 120 )) || continue
        (( deg > best )) && best=$deg
        found_pkg=1
      fi
    done

    # fallback: if no Package labels, accept any coretemp inputs (cores)
    if (( found_pkg == 0 )); then
      for inp in "$H"/temp*_input; do
        [[ -r "$inp" ]] || continue
        local milli; milli=$(tr -dc '0-9' < "$inp")
        [[ -n "$milli" ]] || continue
        local deg=$(( milli / 1000 ))
        (( deg > 0 && deg <= 120 )) || continue
        (( deg > best )) && best=$deg
      done
    fi
  done
  if (( best >= 0 )); then
    echo "$best"
    return 0
  else
    return 1
  fi
}

# ---------- control law ----------
compute_target_percent() {
  local t=$1
  local err=$(( t - BASELINE_C ))

  # deadband: hold MIN_PCT near baseline
  if (( DEADBAND_C > 0 )); then
    local abserr=$(( err<0 ? -err : err ))
    if (( abserr <= DEADBAND_C )); then
      echo "$MIN_PCT"; return
    fi
  fi

  local pct
  if (( err >= 0 )); then
    pct=$(( MIN_PCT + UP_GAIN * err ))
  else
    err=$(( -err ))
    pct=$(( MIN_PCT - DOWN_GAIN * err ))
  fi

  (( pct < MIN_PCT )) && pct=$MIN_PCT
  (( pct > MAX_PCT )) && pct=$MAX_PCT
  echo "$pct"
}

# ---------- IBM mapping & writers ----------
ibm_hex_for_pct() {
  local p; p=$(clamp_pct "$1")
  if [[ "$IBM_CODEMAP" == "linear" ]]; then
    # 0..100% → 0x12..0xFF
    local min_dec=$((16#12)) max_dec=$((16#FF))
    local span=$(( max_dec - min_dec ))
    local code=$(( min_dec + (p * span + 50) / 100 ))
    (( code < min_dec )) && code=$min_dec
    (( code > max_dec )) && code=$max_dec
    printf "0x%02X" "$code"
  else
    # classic step table (quieter on IBM)
    if   (( p <= 0 ));  then echo 0x12
    elif (( p <= 25 )); then echo 0x30
    elif (( p <= 30 )); then echo 0x35
    elif (( p <= 35 )); then echo 0x3A
    elif (( p <= 40 )); then echo 0x40
    elif (( p <= 50 )); then echo 0x50
    elif (( p <= 60 )); then echo 0x60
    elif (( p <= 70 )); then echo 0x70
    elif (( p <= 80 )); then echo 0x80
    elif (( p <= 90 )); then echo 0x90
    elif (( p <= 95 )); then echo 0xA0
    else                   echo 0xFF
    fi
  fi
}

set_ibm_bank_pct() {
  local bank="$1" pct="$2"
  local hx; hx="$(ibm_hex_for_pct "$pct")"
  run ipmitool raw 0x3a 0x07 "$bank" "$hx" 0x01
}

# ---------- Dell writer ----------
pct_to_hex() { local p; p=$(clamp_pct "$1"); printf "0x%02x" "$p"; }
set_dell_global_pct() {
  local pct="$1" hx; hx="$(pct_to_hex "$pct")"
  run ipmitool raw 0x30 0x30 0x01 0x00          # manual mode
  run ipmitool raw 0x30 0x30 0x02 0xff "$hx"    # set %
}

# ---------- main loop ----------
log "start vendor=${VENDOR} baseline=${BASELINE_C}C deadband=${DEADBAND_C}C range=${MIN_PCT}..${MAX_PCT}% map=${IBM_CODEMAP} write=${DO_WRITE}"

while true; do
  # 1) read hottest package temp
  HOT="$(read_hottest_package_temp || true)"
  if [[ -z "${HOT:-}" ]]; then
    log "no CPU temp via sysfs coretemp; try 'modprobe coretemp'"
    sleep "$INTERVAL"
    continue
  fi

  # 2) compute percent
  WANT="$(compute_target_percent "$HOT")"

  # 3) write
  if [[ "$VENDOR" == "ibm" ]]; then
    for B in $IBM_BANKS; do set_ibm_bank_pct "$B" "$WANT"; done
    log "IBM: HOT=${HOT}°C -> ${WANT}% banks=[$IBM_BANKS] map=${IBM_CODEMAP}"
  else
    set_dell_global_pct "$WANT"
    log "DELL: HOT=${HOT}°C -> ${WANT}%"
  fi

  # 4) sleep
  sleep "$INTERVAL"
done
FANEOF
}

write_defaults() {
  cat > "${DEFAULTS_PATH}" <<'DFEOF'
# /etc/default/fan-control
# Override environment variables for /usr/local/sbin/fan_control.sh

# Core behavior
INTERVAL=15
BASELINE_C=50
DEADBAND_C=1
UP_GAIN=2
DOWN_GAIN=1
MIN_PCT=5
MAX_PCT=50

# Platform select ibm | dell (no auto-detect; set explicitly)
VENDOR=ibm

# IBM-only settings
# set only valid banks for your chassis (e.g. x3500: 0x01)
IBM_BANKS="0x01"
# table | linear  (table is calmer on IBM)
IBM_CODEMAP=linear

# Safety / testing
DO_WRITE=1
# 1=apply via ipmitool, 0=dry-run logs only
DFEOF
  chmod 0644 "${DEFAULTS_PATH}"
}

write_service() {
  cat > "${SERVICE_PATH}" <<SVC
[Unit]
Description=Simple CPU-temp fan control (sysfs coretemp → IPMI)
After=multi-user.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${SCRIPT_PATH}
EnvironmentFile=-${DEFAULTS_PATH}
Restart=always
RestartSec=3
User=root
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
SVC
}

enable_service() {
  systemctl daemon-reload
  systemctl enable --now fan-control.service
}

summary() {
  echo
  echo "Installed:"
  echo "  Script : ${SCRIPT_PATH}"
  echo "  Service: ${SERVICE_PATH}"
  echo "  Env    : ${DEFAULTS_PATH}"
  echo
  echo "Tune and test:"
  echo "  sudo editor ${DEFAULTS_PATH}    # set VENDOR, IBM_BANKS, etc."
  echo "  sudo systemctl restart fan-control.service"
  echo "  journalctl -u fan-control.service -f"
  echo
  echo "Quick sanity (IBM x3500):"
  echo "  VENDOR=ibm IBM_BANKS=0x01 MIN_PCT=12 MAX_PCT=50 INTERVAL=10"
  echo
}

main() {
  need_root
  install_deps
  write_script
  write_defaults
  write_service
  enable_service
  summary
}

main "$@"
