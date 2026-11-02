#!/bin/zsh
# Script:  UninstallMicrosoftOneDrive.zsh
# Purpose: Remove Microsoft OneDrive (standalone and Mac App Store builds) for all
#          local users. The users' OneDrive files folders are not deleted.
# Author:  Trevor Edwards
#
# Jamf Pro parameters
#   $4  Minimum UID     Only accounts with a UID at or above this value are
#                       processed. Whole number. Default: 501.
#   $5  Preserve data   true  (default) Keep OneDrive's own group containers
#                             (sync database, account settings).
#                       false Also delete OneDrive's own group containers, so a
#                             reinstall starts from a clean setup.
#                       Accepts true/false, yes/no, 1/0 (any case).
#   An invalid value stops the script (exit 2) before anything is changed.
#
# What it does, in order
#   1. Asks OneDrive to quit in each user session where it's running, and waits
#      up to 15 seconds.
#   2. Boots out OneDrive launchd jobs: daemons from the system domain, agents
#      from each logged-in user's gui/<uid> domain.
#   3. Terminates any OneDrive processes still running (SIGTERM, then SIGKILL).
#   4. Deletes the items listed below and forgets the package receipts.
#
# Removed
#   /Applications/OneDrive.app, /Applications/Microsoft OneDrive.app,
#   /Applications/OneDrive.localized/OneDrive.app
#   /Library/LaunchAgents/com.microsoft.OneDrive*.plist
#   /Library/LaunchDaemons/com.microsoft.OneDrive*.plist
#   /Library/PrivilegedHelperTools/com.microsoft.OneDriveStandaloneUpdater
#   /Library/Application Support/Microsoft/OneDriveUpdater
#   /Library/Preferences/com.microsoft.OneDrive.plist
#   /Library/Preferences/com.microsoft.OneDriveUpdater.plist
#   /Library/Logs/Microsoft/OneDrive
#   Package receipts com.microsoft.OneDrive, com.microsoft.OneDrive-mac,
#   com.microsoft.OneDriveUpdater, com.microsoft.OneDriveStandaloneUpdater
#   For each user (~ is that user's home folder):
#     ~/Applications/OneDrive.app, ~/Applications/Microsoft OneDrive.app
#     ~/Library/Preferences/com.microsoft.OneDrive*
#     ~/Library/Caches/com.microsoft.OneDrive*
#     ~/Library/Containers/com.microsoft.OneDrive*
#     ~/Library/LaunchAgents/com.microsoft.OneDrive*
#     ~/Library/Saved Application State/com.microsoft.OneDrive*
#     ~/Library/Logs/OneDrive
#   For each user, only when $5 is false:
#     ~/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite
#     ~/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite
#     ~/Library/Group Containers/UBF8T346G9.OneDriveStandaloneUpdater
#     ~/Library/Group Containers/UBF8T346G9.OfficeOneDriveSyncIntegration
#
# Not removed
#   - The users' OneDrive files folders: ~/OneDrive* and
#     ~/Library/CloudStorage/OneDrive*. Deleting those is left to someone who
#     has checked what's in them.
#   - Shared Microsoft group containers such as UBF8T346G9.Office and
#     UBF8T346G9.ms. Outlook and the other Office apps keep their data there,
#     so this script never touches them.
#   - Office apps, Microsoft AutoUpdate and keychain items.
#
# About the users' files
#   Not deleting files isn't the same as keeping them available offline.
#   - With Files On-Demand, cloud-only items are placeholders. They have no
#     local content and exist only in OneDrive online.
#   - On macOS 12.1 and later OneDrive syncs through Apple's File Provider, and
#     macOS manages ~/Library/CloudStorage/OneDrive-*. What stays in that folder
#     after the app is removed is up to macOS, not this script.
#   - Changes that hadn't finished uploading when OneDrive quit aren't uploaded.
#   Treat OneDrive online as the copy of record.
#
# Exit codes
#   0  Finished, and no OneDrive app bundle is left
#   1  Not run as root
#   2  Invalid Jamf parameter
#   3  Finished, but at least one OneDrive app bundle couldn't be removed
#
# Log: /private/var/EnterpriseManagement/Logs/onedrive_uninstall_<timestamp>.log
#
# CHANGELOG:
# 11-1-26: Prepared for public release: Jamf parameters, launchctl domain fixes,
#          graceful quit, null-glob cleanup, shared Office containers left alone.
# 11-9-25: Revised to preserve local data + robust user enumeration and launchctl handling.
# 11-7-25: Script created.

set -o errexit
set -o pipefail
set -o nounset

readonly LOG_DIR="/private/var/EnterpriseManagement/Logs"
readonly LOG_FILE="${LOG_DIR}/onedrive_uninstall_$(/bin/date +"%Y%m%d_%H%M%S").log"
readonly SCRIPT_NAME="${0:t}"
readonly QUIT_TIMEOUT=15   # seconds to wait for OneDrive to quit on its own

# Jamf passes the mount point, computer name and user name as $1-$3, so custom
# values start at $4.
readonly MIN_UID_RAW="${4:-}"
readonly PRESERVE_RAW="${5:-}"
MIN_UID=501
PRESERVE_LOCAL_DATA=true

# Matched against full command lines with pgrep -f: anything running from inside
# a OneDrive app bundle, plus the standalone updater binaries. This script's own
# command line doesn't match, and $$ is skipped as well.
readonly PROC_REGEX='/(Microsoft )?OneDrive\.app/Contents/|/OneDrive(Standalone)?Updater(Daemon)?( |$)'

# ----------- Logging -----------
log() {
  local msg="[$(/bin/date +"%Y%m%d_%H%M%S")] [$SCRIPT_NAME] $*"
  print -r -- "$msg"
  { print -r -- "$msg" >>"$LOG_FILE"; } 2>/dev/null || true
}

init_logging() {
  /bin/mkdir -p "$LOG_DIR"
  /bin/chmod 755 "$LOG_DIR" 2>/dev/null || true
}

# ----------- Preconditions -----------
require_root() {
  if [[ $EUID -ne 0 ]]; then
    log "❌ This script must be run as root."
    exit 1
  fi
}

parse_params() {
  local raw="${MIN_UID_RAW//[[:space:]]/}"
  if [[ -n "$raw" ]]; then
    if [[ "$raw" != <-> ]]; then
      log "❌ Parameter 4 (minimum UID) must be a whole number, got '${MIN_UID_RAW}'."
      exit 2
    fi
    MIN_UID=$(( raw ))
  fi

  raw="${PRESERVE_RAW//[[:space:]]/}"
  case "${(L)raw}" in
    "")           ;;  # keep the default
    true|yes|1)   PRESERVE_LOCAL_DATA=true ;;
    false|no|0)   PRESERVE_LOCAL_DATA=false ;;
    *)
      log "❌ Parameter 5 (preserve data) must be true or false, got '${PRESERVE_RAW}'."
      exit 2
      ;;
  esac
}

# ----------- Utilities -----------
# Emit NUL-delimited records of: HOME<TAB>USER<TAB>UID\0 for users with UID >= MIN_UID.
get_user_homes() {
  local user uid home
  /usr/bin/dscl . -list /Users UniqueID 2>/dev/null \
  | /usr/bin/awk -v min="$MIN_UID" 'NF==2 && $2 ~ /^[0-9]+$/ && $2+0>=min {print $1 "\t" $2}' \
  | while IFS=$'\t' read -r user uid; do
      # dscl moves the value to the next line when it contains a space, so join
      # everything after the attribute name.
      home="$(/usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null \
        | /usr/bin/awk 'NR==1 {sub(/^NFSHomeDirectory:/, "")} {sub(/^ +/, ""); printf "%s", $0}')" || home=""
      case "$home" in
        ""|"/"|/var/empty|/dev/null) continue ;;
      esac
      [[ -d "$home" ]] || continue
      printf '%s\t%s\t%s\0' "$home" "$user" "$uid"
    done
}

# Safe delete helper that logs first.
safe_rm() {
  local p
  for p in "$@"; do
    if [[ -e "$p" || -L "$p" ]]; then
      log "Deleting: $p"
      /bin/rm -rf -- "$p" 2>/dev/null || log "  ⚠️ Could not fully delete: $p"
    fi
  done
}

# Print a launchd plist's Label, or the file name without .plist if it has none.
plist_label() {
  local label
  label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$1" 2>/dev/null)" || label=""
  [[ -n "$label" ]] || label="${1:t:r}"
  print -r -- "$label"
}

any_onedrive_process() {
  /usr/bin/pgrep -x OneDrive >/dev/null 2>&1 || /usr/bin/pgrep -f -- "$PROC_REGEX" >/dev/null 2>&1
}

signal_onedrive_processes() {
  local sig="$1" pid
  for pid in ${(f)"$(/usr/bin/pgrep -x OneDrive 2>/dev/null || true)"} \
             ${(f)"$(/usr/bin/pgrep -f -- "$PROC_REGEX" 2>/dev/null || true)"}; do
    [[ -n "$pid" && "$pid" != "$$" ]] || continue
    /bin/kill "-$sig" "$pid" 2>/dev/null || true
  done
}

# ----------- Actions -----------
quit_onedrive_gracefully() {
  local home user uid asked=false waited=0
  while IFS=$'\t' read -r -d '' home user uid; do
    /usr/bin/pgrep -x -U "$uid" OneDrive >/dev/null 2>&1 || continue
    log "Asking OneDrive to quit for $user (uid $uid)…"
    # Run in the background so a stuck Apple event can't hang the policy.
    /bin/launchctl asuser "$uid" /usr/bin/sudo -u "$user" \
      /usr/bin/osascript -e 'tell application "OneDrive" to quit' </dev/null >/dev/null 2>&1 &
    asked=true
  done < <(get_user_homes)

  [[ "$asked" == true ]] || return 0

  while /usr/bin/pgrep -x OneDrive >/dev/null 2>&1 && (( waited < QUIT_TIMEOUT )); do
    /bin/sleep 1
    waited=$(( waited + 1 ))
  done

  if /usr/bin/pgrep -x OneDrive >/dev/null 2>&1; then
    log "OneDrive didn't quit within ${QUIT_TIMEOUT}s; it will be terminated."
  else
    log "OneDrive quit."
  fi
}

unload_launch_items() {
  log "Booting out OneDrive launchd jobs…"
  local plist label home user uid
  local -a daemon_labels agent_labels user_labels
  daemon_labels=(
    "com.microsoft.OneDriveStandaloneUpdaterDaemon"
    "com.microsoft.OneDriveUpdaterDaemon"
  )
  agent_labels=(
    "com.microsoft.OneDrive"
    "com.microsoft.OneDriveUpdater"
    "com.microsoft.OneDriveStandaloneUpdater"
    "com.microsoft.OneDrive.FinderSync"
  )

  for plist in /Library/LaunchDaemons/com.microsoft.OneDrive*.plist(N); do
    daemon_labels+=("$(plist_label "$plist")")
  done
  for plist in /Library/LaunchAgents/com.microsoft.OneDrive*.plist(N); do
    agent_labels+=("$(plist_label "$plist")")
  done

  # System domain daemons
  for label in "${(u)daemon_labels[@]}"; do
    if /bin/launchctl bootout "system/$label" >/dev/null 2>&1; then
      log "  Booted out system/$label"
    fi
  done

  # Per-user agents, from each logged-in user's GUI domain
  while IFS=$'\t' read -r -d '' home user uid; do
    /bin/launchctl print "gui/$uid" >/dev/null 2>&1 || continue
    user_labels=("${agent_labels[@]}")
    for plist in "$home"/Library/LaunchAgents/com.microsoft.OneDrive*.plist(N); do
      user_labels+=("$(plist_label "$plist")")
    done
    for label in "${(u)user_labels[@]}"; do
      if /bin/launchctl bootout "gui/$uid/$label" >/dev/null 2>&1; then
        log "  Booted out gui/$uid/$label ($user)"
      fi
    done
  done < <(get_user_homes)
}

stop_remaining_processes() {
  if ! any_onedrive_process; then
    log "No OneDrive processes left running."
    return 0
  fi
  log "Terminating remaining OneDrive processes…"
  signal_onedrive_processes TERM
  /bin/sleep 2
  if any_onedrive_process; then
    log "  Still running; sending SIGKILL."
    signal_onedrive_processes KILL
  fi
}

remove_apps() {
  log "Removing application bundles…"
  safe_rm \
    "/Applications/OneDrive.app" \
    "/Applications/Microsoft OneDrive.app" \
    "/Applications/OneDrive.localized/OneDrive.app" \
    "/Library/PrivilegedHelperTools/com.microsoft.OneDriveStandaloneUpdater"

  local home user uid
  while IFS=$'\t' read -r -d '' home user uid; do
    safe_rm \
      "$home/Applications/OneDrive.app" \
      "$home/Applications/Microsoft OneDrive.app"
  done < <(get_user_homes)
}

remove_support_files() {
  log "Removing support files and preferences…"

  # System-level artifacts
  safe_rm \
    /Library/LaunchAgents/com.microsoft.OneDrive*.plist(N) \
    /Library/LaunchDaemons/com.microsoft.OneDrive*.plist(N) \
    "/Library/Application Support/Microsoft/OneDriveUpdater" \
    "/Library/Preferences/com.microsoft.OneDrive.plist" \
    "/Library/Preferences/com.microsoft.OneDriveUpdater.plist" \
    "/Library/Logs/Microsoft/OneDrive"

  # Per-user artifacts. The (N) qualifier drops a pattern that matches nothing.
  local home user uid
  while IFS=$'\t' read -r -d '' home user uid; do
    log "Cleaning OneDrive settings and caches: $user (uid $uid)"
    safe_rm \
      "$home"/Library/Preferences/com.microsoft.OneDrive*(N) \
      "$home"/Library/Caches/com.microsoft.OneDrive*(N) \
      "$home"/Library/Containers/com.microsoft.OneDrive*(N) \
      "$home"/Library/LaunchAgents/com.microsoft.OneDrive*(N) \
      "$home/Library/Saved Application State"/com.microsoft.OneDrive*(N) \
      "$home/Library/Logs/OneDrive"

    if [[ "$PRESERVE_LOCAL_DATA" == "false" ]]; then
      # OneDrive's own group containers only. UBF8T346G9.Office, UBF8T346G9.ms
      # and the other shared Microsoft containers hold Outlook and Office data
      # and are never deleted. Neither are the users' OneDrive files folders.
      safe_rm \
        "$home/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite" \
        "$home/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite" \
        "$home/Library/Group Containers/UBF8T346G9.OneDriveStandaloneUpdater" \
        "$home/Library/Group Containers/UBF8T346G9.OfficeOneDriveSyncIntegration"
    fi
  done < <(get_user_homes)
}

forget_receipts() {
  log "Forgetting package receipts…"
  local receipts=(
    "com.microsoft.OneDrive"
    "com.microsoft.OneDriveUpdater"
    "com.microsoft.OneDriveStandaloneUpdater"
    "com.microsoft.OneDrive-mac"
  )
  local id
  for id in "${receipts[@]}"; do
    if /usr/sbin/pkgutil --pkg-info "$id" >/dev/null 2>&1; then
      /usr/sbin/pkgutil --forget "$id" >/dev/null 2>&1 && log "Forgot $id" || true
    fi
  done
}

# Returns non-zero if an app bundle is still present.
verify_apps_removed() {
  local leftover=0 app home user uid
  for app in "/Applications/OneDrive.app" "/Applications/Microsoft OneDrive.app" \
             "/Applications/OneDrive.localized/OneDrive.app"; do
    if [[ -e "$app" ]]; then
      log "❌ Still present: $app"
      leftover=1
    fi
  done
  while IFS=$'\t' read -r -d '' home user uid; do
    for app in "$home/Applications/OneDrive.app" "$home/Applications/Microsoft OneDrive.app"; do
      if [[ -e "$app" ]]; then
        log "❌ Still present: $app"
        leftover=1
      fi
    done
  done < <(get_user_homes)
  return $leftover
}

# ----------- Main -----------
main() {
  require_root
  init_logging
  parse_params
  log "=== Starting Microsoft OneDrive removal (minimum UID: ${MIN_UID}, preserve OneDrive data: ${PRESERVE_LOCAL_DATA}) ==="
  log "Enumerating user homes (UID >= ${MIN_UID})…"

  local listed=false home user uid
  while IFS=$'\t' read -r -d '' home user uid; do
    log "  • Will process: $home  (user: $user, uid: $uid)"
    listed=true
  done < <(get_user_homes)
  [[ "$listed" == true ]] || log "  (none found)"

  quit_onedrive_gracefully
  unload_launch_items
  stop_remaining_processes
  remove_apps
  remove_support_files
  forget_receipts

  if ! verify_apps_removed; then
    log "❌ Finished, but OneDrive app bundles remain (see above). Check that the Jamf agent can delete apps (App Management / Full Disk Access)."
    exit 3
  fi

  log "✅ OneDrive app removed. No OneDrive files folders were deleted. That doesn't make them available offline: cloud-only (Files On-Demand) items exist only in OneDrive online, and macOS decides what stays in ~/Library/CloudStorage."
  exit 0
}

main "$@"
