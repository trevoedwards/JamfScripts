#!/bin/bash
# Purpose: Demote the current console user from local admin to standard user,
#          unless that account is excluded.
# Author: Trevor Edwards
#
# Scope: only the user logged in at the console when the script runs is changed.
# Every other admin account on the Mac is left alone. To demote all admin
# accounts instead, see DemoteAdminUsersUnlessSpecified.sh.
#
# Jamf Pro parameters:
#   $4  Extra accounts to exclude, comma-separated, e.g. "itadmin,helpdesk"
#       (default: none)
#   $5  Jamf management account short name (default: none). Always excluded.
#   $6  Dry run: true or false (default: false). When true, every check runs and
#       the same exit codes apply, but the admin group is never changed.
#
# root is always excluded. Account names are matched case-insensitively.
#
# Safety:
#   - Nothing happens when no one is logged in (the console is owned by
#     loginwindow, root or _mbsetupuser).
#   - The console user is not demoted if no other admin account would remain.
#     Only enabled local accounts that are direct members of the admin group
#     count. root, system (_) accounts, accounts without a local record and
#     admin rights granted through nested groups do not.
#   - Membership is checked again after the change. A user who still has admin
#     rights (for example through a nested group) is reported as a failure.
#
# Exit codes:
#   0  Demoted, or nothing to do (no console user, excluded, not an admin, dry run)
#   1  Not running as root (required unless dry run is on)
#   2  Invalid parameter
#   3  Refused: no other admin account would remain
#   4  Could not check membership, or the demotion failed or did not take effect

set -u

log() {
  printf '[%s] %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*"
}

to_lower() {
  printf '%s\n' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]'
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

# Short names: letters, digits, underscore, dot and hyphen, not starting with a hyphen.
is_valid_name() {
  case "$1" in
    "" | -* | *[![:alnum:]_.-]*) return 1 ;;
  esac
  return 0
}

is_excluded() {
  local name_lc e
  name_lc="$(to_lower "$1")"
  for e in "${EXCLUDES[@]}"; do
    if [ "$name_lc" = "$e" ]; then
      return 0
    fi
  done
  return 1
}

# Prints "yes", "no" or "unknown". Only a reply that starts with the word "yes"
# counts. Matching "yes" anywhere in the reply would also match the
# "no <user> is NOT a member of admin" reply for a user whose name contains "yes".
admin_status() {
  local reply
  reply="$(/usr/sbin/dseditgroup -o checkmember -m "$1" admin 2>&1)"
  case "$reply" in
    "yes "*) echo "yes" ;;
    "no "*) echo "no" ;;
    *) echo "unknown" ;;
  esac
}

# Sets OTHER_ADMINS and OTHER_ADMIN_COUNT to the enabled local accounts, other
# than root and $1, that are direct members of the admin group.
# Returns 1 if the admin group can't be read.
find_other_admins() {
  local skip_lc members m m_lc
  skip_lc="$(to_lower "$1")"
  OTHER_ADMINS=""
  OTHER_ADMIN_COUNT=0
  members="$(/usr/bin/dscl . -read /Groups/admin GroupMembership 2>/dev/null)" || return 1
  members="${members#GroupMembership:}"
  set -f
  for m in $members; do
    m_lc="$(to_lower "$m")"
    if [ "$m_lc" = "root" ] || [ "$m_lc" = "$skip_lc" ]; then
      continue
    fi
    case "$m" in
      _*) continue ;;
    esac
    if ! /usr/bin/dscl . -read "/Users/$m" UniqueID >/dev/null 2>&1; then
      continue
    fi
    if /usr/bin/dscl . -read "/Users/$m" AuthenticationAuthority 2>/dev/null | /usr/bin/grep -q 'DisabledUser'; then
      continue
    fi
    OTHER_ADMINS="${OTHER_ADMINS:+$OTHER_ADMINS }$m"
    OTHER_ADMIN_COUNT=$((OTHER_ADMIN_COUNT + 1))
  done
  set +f
  return 0
}

# --- Parameters ---------------------------------------------------------------

EXCLUDE_RAW="${4:-}"
MGMT_ACCOUNT="$(trim "${5:-}")"
DRY_RUN_RAW="$(trim "${6:-}")"

EXCLUDES=("root")

if [ -n "$MGMT_ACCOUNT" ]; then
  if ! is_valid_name "$MGMT_ACCOUNT"; then
    log "ERROR: Parameter 5 (Jamf management account) is not a valid account name: '$MGMT_ACCOUNT'."
    exit 2
  fi
  EXCLUDES+=("$(to_lower "$MGMT_ACCOUNT")")
fi

if [ -n "$EXCLUDE_RAW" ]; then
  IFS=',' read -r -a EXCLUDE_LIST <<< "$EXCLUDE_RAW"
  for entry in ${EXCLUDE_LIST[@]+"${EXCLUDE_LIST[@]}"}; do
    entry="$(trim "$entry")"
    if [ -z "$entry" ]; then
      continue
    fi
    if ! is_valid_name "$entry"; then
      log "ERROR: Parameter 4 (excluded accounts) contains an invalid account name: '$entry'."
      exit 2
    fi
    EXCLUDES+=("$(to_lower "$entry")")
  done
fi

case "$(to_lower "$DRY_RUN_RAW")" in
  "" | false | no | 0) DRY_RUN=false ;;
  true | yes | 1) DRY_RUN=true ;;
  *)
    log "ERROR: Parameter 6 (dry run) must be true or false, got '$DRY_RUN_RAW'."
    exit 2
    ;;
esac

if [ "$DRY_RUN" = false ] && [ "$EUID" -ne 0 ]; then
  log "ERROR: This script must run as root."
  exit 1
fi

if [ "$DRY_RUN" = true ]; then
  log "DRY RUN: checks only, the admin group will not be changed."
fi
log "Excluded accounts: ${EXCLUDES[*]}"

# --- Console user -------------------------------------------------------------

CONSOLE_USER="$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" 2>/dev/null | /usr/bin/awk -F': ' '/Name :/ { print $2; exit }')"

case "$CONSOLE_USER" in
  "" | loginwindow | root | _mbsetupuser)
    log "No user is logged in at the console (owner: '${CONSOLE_USER:-none}'). Nothing to do."
    exit 0
    ;;
esac

log "Console user: '$CONSOLE_USER'"

if is_excluded "$CONSOLE_USER"; then
  log "'$CONSOLE_USER' is excluded. No changes made."
  exit 0
fi

if ! /usr/bin/id "$CONSOLE_USER" >/dev/null 2>&1; then
  log "ERROR: Console user '$CONSOLE_USER' could not be resolved to an account. No changes made."
  exit 4
fi

# --- Admin membership ---------------------------------------------------------

STATUS="$(admin_status "$CONSOLE_USER")"
case "$STATUS" in
  no)
    log "'$CONSOLE_USER' is not an admin. No changes needed."
    exit 0
    ;;
  unknown)
    log "ERROR: Could not determine whether '$CONSOLE_USER' is an admin. No changes made."
    exit 4
    ;;
esac

log "'$CONSOLE_USER' is an admin."

if ! find_other_admins "$CONSOLE_USER"; then
  log "ERROR: Could not read the admin group. No changes made."
  exit 4
fi

if [ "$OTHER_ADMIN_COUNT" -eq 0 ]; then
  log "REFUSED: no other enabled local admin account would remain after demoting '$CONSOLE_USER'. No changes made."
  exit 3
fi

log "Admin accounts that would remain: $OTHER_ADMINS"

# --- Demote -------------------------------------------------------------------

if [ "$DRY_RUN" = true ]; then
  log "DRY RUN: would remove '$CONSOLE_USER' from the admin group. No changes made."
  exit 0
fi

log "Removing '$CONSOLE_USER' from the admin group..."
if ! /usr/sbin/dseditgroup -o edit -d "$CONSOLE_USER" -t user admin; then
  log "ERROR: dseditgroup failed to remove '$CONSOLE_USER' from the admin group."
  exit 4
fi

STATUS="$(admin_status "$CONSOLE_USER")"
if [ "$STATUS" != "no" ]; then
  # Membership lookups can be cached for a moment; check once more before failing.
  /bin/sleep 2
  STATUS="$(admin_status "$CONSOLE_USER")"
fi

if [ "$STATUS" != "no" ]; then
  log "ERROR: '$CONSOLE_USER' still has admin rights after removal (check result: $STATUS). They may get admin through a nested group."
  exit 4
fi

log "SUCCESS: '$CONSOLE_USER' is now a standard user."
exit 0
