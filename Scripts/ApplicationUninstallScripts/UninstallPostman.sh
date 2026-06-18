#!/bin/bash
# Universal Postman Uninstaller - macOS 26 (Tahoe)
# Removes Postman.app and (optionally) common support files for all local users
# Logs to /private/var/EnterpriseManagement/Logs/Postman-Uninstall.log
#
# Parameter:
#   REMOVE_USER_DATA (default: true)
#   Accepts: true/false, yes/no, 1/0 (case-insensitive)
#
# Jamf example:
#   Parameter 4 = false   (keeps user data)

set -u

LOG_DIR="/private/var/EnterpriseManagement/Logs"
LOG_FILE="${LOG_DIR}/Postman-Uninstall.log"

# If running in Jamf, $4 is commonly used as the first custom param.
# You can pass REMOVE_USER_DATA as an env var too, e.g. REMOVE_USER_DATA=false ./script.sh
REMOVE_USER_DATA_RAW="${REMOVE_USER_DATA:-${4:-false}}"

ts() { /bin/date "+%Y-%m-%d %H:%M:%S"; }

log() {
  echo "[$(ts)] $*" | /usr/bin/tee -a "$LOG_FILE" >/dev/null
}

ensure_log_path() {
  if [[ ! -d "$LOG_DIR" ]]; then
    /bin/mkdir -p "$LOG_DIR" 2>/dev/null
    /usr/sbin/chown root:wheel "$LOG_DIR" 2>/dev/null || true
    /bin/chmod 755 "$LOG_DIR" 2>/dev/null || true
  fi

  /usr/bin/touch "$LOG_FILE" 2>/dev/null || true
  /usr/sbin/chown root:wheel "$LOG_FILE" 2>/dev/null || true
  /bin/chmod 644 "$LOG_FILE" 2>/dev/null || true
}

normalize_bool() {
  # echoes "true" or "false"
  local v
  v="$(echo "${1:-}" | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/xargs)"
  case "$v" in
    true|t|yes|y|1)  echo "true" ;;
    false|f|no|n|0)  echo "false" ;;
    "")              echo "true" ;;  # default
    *)               echo "true" ;;  # fail-safe default to true
  esac
}

as_root_required() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "ERROR: This script must be run as root to fully remove Postman for all users."
    log "Exiting with code 1."
    exit 1
  fi
}

rm_path() {
  local p="$1"
  if [[ -e "$p" || -L "$p" ]]; then
    log "Removing: $p"
    /bin/rm -rf "$p" 2>>"$LOG_FILE" || log "WARN: Failed to remove $p"
  else
    log "Not found: $p"
  fi
}

kill_postman() {
  log "Stopping Postman processes (if running)..."

  /usr/bin/osascript <<'APPLESCRIPT' >/dev/null 2>&1
tell application "Postman"
  try
    quit
  end try
end tell
APPLESCRIPT

  /bin/sleep 2

  local patterns=(
    "Postman"
    "Postman Helper"
    "Postman Helper (Renderer)"
    "Postman Helper (GPU)"
    "Postman Helper (Plugin)"
  )

  for pat in "${patterns[@]}"; do
    if /usr/bin/pgrep -f "$pat" >/dev/null 2>&1; then
      log "Killing processes matching: $pat"
      /usr/bin/pkill -f "$pat" 2>>"$LOG_FILE" || true
    fi
  done

  /bin/sleep 1

  if /usr/bin/pgrep -fi "postman" >/dev/null 2>&1; then
    log "Force-killing any remaining processes containing 'postman'..."
    /usr/bin/pkill -9 -fi "postman" 2>>"$LOG_FILE" || true
  fi
}

get_local_homes() {
  for d in /Users/*; do
    [[ -d "$d" ]] || continue
    local base
    base="$(/usr/bin/basename "$d")"
    [[ "$base" == "Shared" ]] && continue
    [[ "$base" == .* ]] && continue
    echo "$d"
  done
}

# ---------- main ----------
ensure_log_path
as_root_required

REMOVE_USER_DATA="$(normalize_bool "$REMOVE_USER_DATA_RAW")"

log "======================================"
log "Postman Universal Uninstaller - START"
log "macOS: $(/usr/bin/sw_vers -productName) $(/usr/bin/sw_vers -productVersion) ($( /usr/bin/sw_vers -buildVersion))"
log "Script user: $(/usr/bin/id -un) (uid: ${EUID})"
log "REMOVE_USER_DATA: ${REMOVE_USER_DATA} (raw: '${REMOVE_USER_DATA_RAW}')"
log "======================================"

kill_postman

log "Removing Postman application bundles..."

APP_PATHS=(
  "/Applications/Postman.app"
  "/Applications/Postman Canary.app"
  "/Applications/Postman Agent.app"
  "/Applications/Postman Agent Beta.app"
)

for ap in "${APP_PATHS[@]}"; do
  rm_path "$ap"
done

# Per-user Applications (some users drag into ~/Applications)
for home in $(get_local_homes); do
  rm_path "${home}/Applications/Postman.app"
  rm_path "${home}/Applications/Postman Canary.app"
  rm_path "${home}/Applications/Postman Agent.app"
  rm_path "${home}/Applications/Postman Agent Beta.app"
done

if [[ "$REMOVE_USER_DATA" == "true" ]]; then
  log "REMOVE_USER_DATA=true -> Removing Postman support files for all local users..."

  for home in $(get_local_homes); do
    user="$(/usr/bin/basename "$home")"
    log "---- User: $user ($home) ----"

    rm_path "${home}/Library/Application Support/Postman"
    rm_path "${home}/Library/Application Support/Postman Agent"
    rm_path "${home}/Library/Application Support/PostmanAgent"
    rm_path "${home}/Library/Caches/Postman"
    rm_path "${home}/Library/Caches/com.postmanlabs.mac"
    rm_path "${home}/Library/Preferences/com.postmanlabs.mac.plist"
    rm_path "${home}/Library/Preferences/com.postmanlabs.mac.Canary.plist"
    rm_path "${home}/Library/Preferences/com.postmanlabs.postman.plist"
    rm_path "${home}/Library/Logs/Postman"
    rm_path "${home}/Library/Saved Application State/com.postmanlabs.mac.savedState"
    rm_path "${home}/Library/Saved Application State/com.postmanlabs.mac.Canary.savedState"

    rm_path "${home}/Library/Application Support/com.postmanlabs.mac"
    rm_path "${home}/Library/Caches/com.postmanlabs.postman"
  done
else
  log "REMOVE_USER_DATA=false -> Skipping removal of per-user Postman support files."
fi

log "Removing global/Postman-related receipts (best-effort)..."
for pkg in $(/usr/sbin/pkgutil --pkgs 2>/dev/null | /usr/bin/grep -i "postman" || true); do
  log "Forgetting receipt: $pkg"
  /usr/sbin/pkgutil --forget "$pkg" >>"$LOG_FILE" 2>&1 || log "WARN: Failed to forget $pkg"
done

log "Removing LaunchAgents/Daemons (best-effort)..."
rm_path "/Library/LaunchAgents/com.postman*.plist"
rm_path "/Library/LaunchDaemons/com.postman*.plist"

log "Final verification..."
if [[ -d "/Applications/Postman.app" ]]; then
  log "WARN: /Applications/Postman.app still exists."
else
  log "OK: /Applications/Postman.app not present."
fi

log "Postman Universal Uninstaller - COMPLETE"
log "========================================"
exit 0