#!/bin/bash

################################################################################
# Script:  UninstallGlobalProtect.sh
# Purpose: Uninstall the Palo Alto Networks GlobalProtect VPN app from macOS.
# Author:  Trevor Edwards
#
# Jamf Pro parameters
#   $4  Remove user data  true (default) or false. When true, each user's
#                         GlobalProtect preferences, caches, logs and
#                         Application Support data are deleted.
#                         Accepts true/false, yes/no, 1/0 (any case).
#   $5  Minimum UID       Per-user data is deleted only for accounts with a UID
#                         at or above this value. Whole number. Default: 501.
#                         (Launch agents are booted out of every logged-in
#                         session, whatever the UID.)
#   An invalid value stops the script (exit 2) before anything is changed.
#
# What it does, in order
#   1. Exits 0 if neither /Applications/GlobalProtect.app nor a GlobalProtect
#      package receipt is found.
#   2. Disconnects the VPN with the app's command-line tool, if it has one.
#   3. Runs Palo Alto's uninstaller when it's present
#      (GlobalProtect 6.0.4 and later, and 6.1 and later):
#        /Applications/GlobalProtect.app/Contents/Resources/uninstall_gp.sh
#   4. Cleans up whatever is left, whether or not step 3 ran:
#      - Boots out the launchd jobs: daemons from the system domain, agents
#        from gui/<uid>/<label> for each logged-in user. PanGPS is a KeepAlive
#        job, so this happens before any process is killed.
#      - Stops GlobalProtect processes still running (SIGTERM, then SIGKILL).
#      - Deletes the launchd plists, the app bundles, GlobalProtect's system
#        settings and logs, and the package receipts.
#      - Deletes per-user GlobalProtect data when $4 is true.
#   5. Checks that nothing is left and logs the system extension's state.
#
# Removed
#   /Library/LaunchDaemons/com.paloaltonetworks.gp.*.plist
#   /Library/LaunchAgents/com.paloaltonetworks.gp.*.plist
#   /Library/LaunchAgents/com.paloaltonetworks.GlobalProtect.*.plist
#   /Applications/GlobalProtect.app, /Applications/Uninstall GlobalProtect.app,
#   /Applications/GlobalProtect Portal.app
#   /Library/Preferences/com.paloaltonetworks.GlobalProtect*
#   /Library/Application Support/PaloAltoNetworks/GlobalProtect
#   /Library/Logs/PaloAltoNetworks/GlobalProtect
#   /private/var/log/pan_gp_*.log
#   Package receipts whose ID contains "paloaltonetworks.globalprotect"
#   For each user, when $4 is true (~ is that user's home folder):
#     ~/Library/Preferences/com.paloaltonetworks.GlobalProtect*
#     ~/Library/Application Support/PaloAltoNetworks/GlobalProtect
#     ~/Library/Caches/com.paloaltonetworks.GlobalProtect*
#     ~/Library/Logs/PaloAltoNetworks/GlobalProtect
#   A parent PaloAltoNetworks folder is removed only if it ends up empty, so
#   other Palo Alto Networks products are left alone (Cortex XDR, for example,
#   lives in /Library/Application Support/PaloAltoNetworks/Traps).
#
# System extension
#   GlobalProtect can use a system extension,
#   com.paloaltonetworks.GlobalProtect.client.extension (team ID PXPZ95SK77).
#   This script doesn't remove it directly. Palo Alto's uninstaller asks macOS
#   to remove it, and macOS may need approval first:
#   - Before macOS 12, the user is prompted for administrator credentials.
#   - On macOS 12.2.1 and later, an MDM System Extensions payload that lists
#     the extension as removable lets uninstall_gp.sh remove it without a
#     prompt.
#   At the end the script logs the extension's entry from
#   `systemextensionsctl list`. If it's still listed, it may be waiting for
#   approval or a restart.
#   Legacy kernel extensions aren't handled. Their names couldn't be verified,
#   and third-party kernel extensions don't load on Apple silicon Macs unless
#   the startup security policy is lowered.
#
# Exit codes
#   0  GlobalProtect removed, or it wasn't installed
#   1  Not run as root
#   2  Invalid Jamf parameter
#   3  Finished, but the app, a launchd plist, a loaded launchd job or a
#      running process is left
#
# Log: /private/var/EnterpriseManagement/Logs/GlobalProtect_Uninstall_<timestamp>.log
################################################################################

readonly EXIT_OK=0
readonly EXIT_NOT_ROOT=1
readonly EXIT_BAD_PARAM=2
readonly EXIT_LEFTOVERS=3

LOG_DIR="/private/var/EnterpriseManagement/Logs"
TIMESTAMP="$(/bin/date '+%Y%m%d-%H%M%S')"
LOG_FILE="${LOG_DIR}/GlobalProtect_Uninstall_${TIMESTAMP}.log"
LOG_TAG="GlobalProtect-Uninstall"

GP_APP="/Applications/GlobalProtect.app"
GP_CLI="$GP_APP/Contents/Resources/globalprotect"
GP_UNINSTALLER="$GP_APP/Contents/Resources/uninstall_gp.sh"
GP_SYSEXT_ID="com.paloaltonetworks.GlobalProtect.client.extension"

# Process names are all 16 characters or fewer, so pgrep/pkill -x match them
# exactly on macOS and can't match this script's own command line.
GP_PROCESSES=( "GlobalProtect" "PanGPS" "PanGPA" "PanGPAUI" "PanGPAPlugin" "PanGpHip" "PanGpHipMp" )

# Jamf passes the mount point, computer name and user name as $1-$3, so custom
# values start at $4.
REMOVE_USER_DATA_RAW="${4:-}"
MIN_UID_RAW="${5:-}"

# Unmatched globs expand to nothing instead of the literal pattern.
shopt -s nullglob

log() {
  echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') [${LOG_TAG}] $*"
}

###############################################################################
# Helpers
###############################################################################
strip_spaces() {
  echo "$1" | /usr/bin/tr -d '[:space:]'
}

to_lower() {
  echo "$1" | /usr/bin/tr '[:upper:]' '[:lower:]'
}

# Print "uid<TAB>user" for each local account with a UID >= $1.
list_accounts() {
  /usr/bin/dscl . -list /Users UniqueID 2>/dev/null \
    | /usr/bin/awk -v min="$1" 'NF==2 && $2 ~ /^[0-9]+$/ && $2+0>=min {print $2 "\t" $1}'
}

# Print "uid<TAB>user" for each account that has a GUI login session right now
# (including fast user switching), whatever the minimum UID parameter says.
list_gui_sessions() {
  local uid user
  while IFS=$'\t' read -r uid user; do
    if /bin/launchctl print "gui/$uid" &>/dev/null; then
      printf '%s\t%s\n' "$uid" "$user"
    fi
  done < <(list_accounts 1)
}

# Print "uid<TAB>user<TAB>home" for each local account with UID >= MIN_UID whose
# home folder exists. The home folder is last, so spaces in it survive `read`.
list_users() {
  local user uid home
  list_accounts "$MIN_UID" \
    | while IFS=$'\t' read -r uid user; do
        # dscl moves the value to the next line when it contains a space, so
        # join everything after the attribute name.
        home="$(/usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null \
          | /usr/bin/awk 'NR==1 {sub(/^NFSHomeDirectory:/, "")} {sub(/^ +/, ""); printf "%s", $0}')"
        case "$home" in
          ""|"/"|/var/empty|/dev/null) continue ;;
        esac
        [[ -d "$home" ]] || continue
        printf '%s\t%s\t%s\n' "$uid" "$user" "$home"
      done
}

# Succeeds if $1 equals any of the remaining arguments.
contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# Print a launchd plist's Label, or the file name without .plist if it has none.
plist_label() {
  local label
  label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$1" 2>/dev/null)"
  [[ -n "$label" ]] || label="$(/usr/bin/basename "$1" .plist)"
  echo "$label"
}

remove_path() {
  local target="$1"
  [[ -e "$target" || -L "$target" ]] || return 0
  log "Deleting: $target"
  /bin/rm -rf -- "$target" || log "WARNING: Could not delete $target"
}

remove_dir_if_empty() {
  if [[ -d "$1" ]] && /bin/rmdir "$1" 2>/dev/null; then
    log "Removed empty folder: $1"
  fi
}

any_gp_process_running() {
  local proc
  for proc in "${GP_PROCESSES[@]}"; do
    /usr/bin/pgrep -x "$proc" &>/dev/null && return 0
  done
  return 1
}

signal_gp_processes() {
  local sig="$1" proc
  for proc in "${GP_PROCESSES[@]}"; do
    if /usr/bin/pgrep -x "$proc" &>/dev/null; then
      log "Sending SIG${sig} to: $proc"
      /usr/bin/pkill "-${sig}" -x "$proc" 2>/dev/null
    fi
  done
}

gp_launchd_plists() {
  local plist
  for plist in /Library/LaunchDaemons/com.paloaltonetworks.gp.*.plist \
               /Library/LaunchAgents/com.paloaltonetworks.gp.*.plist \
               /Library/LaunchAgents/com.paloaltonetworks.GlobalProtect.*.plist; do
    echo "$plist"
  done
}

###############################################################################
# 1. Require root (Jamf normally runs as root)
###############################################################################
if [[ "$EUID" -ne 0 ]]; then
  log "ERROR: This script must be run as root. Exiting."
  exit "$EXIT_NOT_ROOT"
fi

###############################################################################
# 2. Logging setup
###############################################################################
if [[ ! -d "$LOG_DIR" ]]; then
  /bin/mkdir -p "$LOG_DIR"
  /bin/chmod 755 "$LOG_DIR"
fi

# Send all stdout/stderr to the log file AND the Jamf policy log
exec > >(/usr/bin/tee -a "$LOG_FILE") 2>&1

log "Starting GlobalProtect uninstall"
log "Log file: $LOG_FILE"

###############################################################################
# 3. Read and validate Jamf parameters
###############################################################################
REMOVE_USER_DATA=true
case "$(to_lower "$(strip_spaces "$REMOVE_USER_DATA_RAW")")" in
  "")         ;;  # keep the default
  true|yes|1) REMOVE_USER_DATA=true ;;
  false|no|0) REMOVE_USER_DATA=false ;;
  *)
    log "ERROR: Parameter 4 (remove user data) must be true or false, got '${REMOVE_USER_DATA_RAW}'."
    exit "$EXIT_BAD_PARAM"
    ;;
esac

MIN_UID=501
MIN_UID_CLEAN="$(strip_spaces "$MIN_UID_RAW")"
if [[ -n "$MIN_UID_CLEAN" ]]; then
  case "$MIN_UID_CLEAN" in
    *[!0-9]*)
      log "ERROR: Parameter 5 (minimum UID) must be a whole number, got '${MIN_UID_RAW}'."
      exit "$EXIT_BAD_PARAM"
      ;;
  esac
  MIN_UID=$(( 10#$MIN_UID_CLEAN ))
fi

log "Remove user data: $REMOVE_USER_DATA | Minimum UID: $MIN_UID"

###############################################################################
# 4. Detect GlobalProtect
###############################################################################
if [[ ! -d "$GP_APP" ]]; then
  if ! /usr/sbin/pkgutil --pkgs 2>/dev/null | /usr/bin/grep -qi "paloaltonetworks.globalprotect"; then
    log "GlobalProtect not detected. Exiting."
    exit "$EXIT_OK"
  fi
fi

log "GlobalProtect detected. Proceeding."

# Record launchd labels now: the vendor uninstaller may delete the plists while
# leaving the jobs loaded. The two agent labels are the ones in Palo Alto's
# documentation for stopping PanGPS and PanGPA.
DAEMON_LABELS=()
AGENT_LABELS=( "com.paloaltonetworks.gp.pangps" "com.paloaltonetworks.gp.pangpa" )
for PLIST in /Library/LaunchDaemons/com.paloaltonetworks.gp.*.plist; do
  LABEL="$(plist_label "$PLIST")"
  contains "$LABEL" "${DAEMON_LABELS[@]}" || DAEMON_LABELS+=( "$LABEL" )
done
for PLIST in /Library/LaunchAgents/com.paloaltonetworks.gp.*.plist \
             /Library/LaunchAgents/com.paloaltonetworks.GlobalProtect.*.plist; do
  LABEL="$(plist_label "$PLIST")"
  contains "$LABEL" "${AGENT_LABELS[@]}" || AGENT_LABELS+=( "$LABEL" )
done

###############################################################################
# 5. Disconnect the VPN
###############################################################################
if [[ -x "$GP_CLI" ]]; then
  log "Disconnecting VPN (if connected)"
  "$GP_CLI" disconnect </dev/null &>/dev/null
  "$GP_CLI" disable </dev/null &>/dev/null
fi

###############################################################################
# 6. Run Palo Alto's uninstaller (GlobalProtect 6.0.4+ / 6.1+)
###############################################################################
if [[ -f "$GP_UNINSTALLER" ]]; then
  log "Running Palo Alto uninstaller: $GP_UNINSTALLER"
  if [[ -x "$GP_UNINSTALLER" ]]; then
    "$GP_UNINSTALLER" </dev/null
    VENDOR_RC=$?
  else
    /bin/bash "$GP_UNINSTALLER" </dev/null
    VENDOR_RC=$?
  fi
  log "Uninstaller exited with status $VENDOR_RC. Continuing with cleanup of anything left."
else
  log "Palo Alto uninstaller not found (it ships with GlobalProtect 6.0.4+/6.1+). Using manual cleanup only."
fi

###############################################################################
# 7. Boot out launchd jobs (before killing processes: PanGPS is KeepAlive)
###############################################################################
log "Booting out GlobalProtect launchd jobs..."

for LABEL in "${DAEMON_LABELS[@]}"; do
  if /bin/launchctl bootout "system/$LABEL" &>/dev/null; then
    log "Booted out system/$LABEL"
  fi
done

while IFS=$'\t' read -r USER_UID USER_NAME; do
  for LABEL in "${AGENT_LABELS[@]}"; do
    if /bin/launchctl bootout "gui/$USER_UID/$LABEL" &>/dev/null; then
      log "Booted out gui/$USER_UID/$LABEL ($USER_NAME)"
    fi
  done
done < <(list_gui_sessions)

###############################################################################
# 8. Stop remaining processes
###############################################################################
if any_gp_process_running; then
  log "Stopping remaining GlobalProtect processes..."
  signal_gp_processes TERM
  /bin/sleep 3
  if any_gp_process_running; then
    signal_gp_processes KILL
    /bin/sleep 1
  fi
else
  log "No GlobalProtect processes running."
fi

###############################################################################
# 9. Remove launchd plists
###############################################################################
log "Removing launchd plists..."
while IFS= read -r PLIST; do
  remove_path "$PLIST"
done < <(gp_launchd_plists)

###############################################################################
# 10. Remove application bundles
###############################################################################
log "Removing application bundles..."

APP_PATHS=(
  "/Applications/GlobalProtect.app"
  "/Applications/Uninstall GlobalProtect.app"
  "/Applications/GlobalProtect Portal.app"
)

for APP in "${APP_PATHS[@]}"; do
  remove_path "$APP"
done

###############################################################################
# 11. Remove system-level support files
###############################################################################
log "Removing system-level support files..."

for FOUND in /Library/Preferences/com.paloaltonetworks.GlobalProtect* \
             "/Library/Application Support/PaloAltoNetworks/GlobalProtect" \
             "/Library/Logs/PaloAltoNetworks/GlobalProtect" \
             /private/var/log/pan_gp_*.log; do
  remove_path "$FOUND"
done
remove_dir_if_empty "/Library/Application Support/PaloAltoNetworks"
remove_dir_if_empty "/Library/Logs/PaloAltoNetworks"

###############################################################################
# 12. Forget pkgutil receipts
###############################################################################
log "Forgetting GlobalProtect pkg receipts..."

while IFS= read -r PKG; do
  [[ -n "$PKG" ]] || continue
  log "Forgetting package: $PKG"
  /usr/sbin/pkgutil --forget "$PKG" &>/dev/null || log "WARNING: Could not forget $PKG"
done < <(/usr/sbin/pkgutil --pkgs 2>/dev/null | /usr/bin/grep -i "paloaltonetworks.globalprotect")

###############################################################################
# 13. Remove per-user data
###############################################################################
if [[ "$REMOVE_USER_DATA" == true ]]; then
  log "Cleaning per-user GlobalProtect data..."
  while IFS=$'\t' read -r USER_UID USER_NAME USER_HOME; do
    for FOUND in "$USER_HOME"/Library/Preferences/com.paloaltonetworks.GlobalProtect* \
                 "$USER_HOME/Library/Application Support/PaloAltoNetworks/GlobalProtect" \
                 "$USER_HOME"/Library/Caches/com.paloaltonetworks.GlobalProtect* \
                 "$USER_HOME/Library/Logs/PaloAltoNetworks/GlobalProtect"; do
      remove_path "$FOUND"
    done
    remove_dir_if_empty "$USER_HOME/Library/Application Support/PaloAltoNetworks"
    remove_dir_if_empty "$USER_HOME/Library/Logs/PaloAltoNetworks"
  done < <(list_users)
else
  log "Parameter 4 is false: keeping per-user GlobalProtect data."
fi

###############################################################################
# 14. Verify, and report the system extension
###############################################################################
log "Verifying removal..."
LEFTOVERS=0

if [[ -e "$GP_APP" ]]; then
  log "ERROR: Still present: $GP_APP"
  LEFTOVERS=1
fi

while IFS= read -r PLIST; do
  log "ERROR: Still present: $PLIST"
  LEFTOVERS=1
done < <(gp_launchd_plists)

for LABEL in "${DAEMON_LABELS[@]}"; do
  if /bin/launchctl print "system/$LABEL" &>/dev/null; then
    log "ERROR: Still loaded: system/$LABEL"
    LEFTOVERS=1
  fi
done

while IFS=$'\t' read -r USER_UID USER_NAME; do
  for LABEL in "${AGENT_LABELS[@]}"; do
    if /bin/launchctl print "gui/$USER_UID/$LABEL" &>/dev/null; then
      log "ERROR: Still loaded: gui/$USER_UID/$LABEL ($USER_NAME)"
      LEFTOVERS=1
    fi
  done
done < <(list_gui_sessions)

for PROC in "${GP_PROCESSES[@]}"; do
  if /usr/bin/pgrep -x "$PROC" &>/dev/null; then
    log "ERROR: Still running: $PROC"
    LEFTOVERS=1
  fi
done

# Report only: this script doesn't remove system extensions (see header).
if [[ -x /usr/bin/systemextensionsctl ]]; then
  SYSEXT_ENTRIES="$(/usr/bin/systemextensionsctl list 2>/dev/null | /usr/bin/grep -F "$GP_SYSEXT_ID")"
  if [[ -n "$SYSEXT_ENTRIES" ]]; then
    log "GlobalProtect system extension is still listed:"
    while IFS= read -r LINE; do
      log "  $LINE"
    done <<< "$SYSEXT_ENTRIES"
    log "macOS removes it once the removal is approved (user prompt, or an MDM profile that marks it removable on macOS 12+). Some states clear only after a restart."
  else
    log "GlobalProtect system extension is not listed."
  fi
fi

###############################################################################
# 15. Completion
###############################################################################
if [[ "$LEFTOVERS" -ne 0 ]]; then
  log "GlobalProtect uninstall finished with leftovers (see errors above)."
  exit "$EXIT_LEFTOVERS"
fi

log "GlobalProtect uninstall completed successfully"
exit "$EXIT_OK"
