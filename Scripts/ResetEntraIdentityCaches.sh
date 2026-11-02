#!/bin/bash
###############################################################################
# ResetEntraIdentityCaches.sh
#
# Clears Microsoft Entra ID identity caches (Company Portal, Microsoft
# Enterprise SSO plug-in, MSAL/ADAL, OneAuth, Office identity caches and
# legacy Workplace Join keychain items) for the logged-in console user.
#
# PURPOSE
#   One-off remediation for a Mac that is stuck on stale or corrupted local
#   Microsoft identity state. Typical symptoms: the device shows as compliant
#   in Microsoft Entra ID (for example through Jamf Pro device compliance) but
#   Conditional Access still treats it as unregistered or noncompliant, or
#   Microsoft 365 apps keep looping on sign-in.
#
#   In order, the script:
#     1. Exits without changes if the Mac is registered with Platform SSO
#        (see $8).
#     2. Asks Word, Excel, PowerPoint, Outlook, OneNote, Teams, Edge and
#        OneDrive to quit, so the user can save their work, waits, and only
#        force-quits them if $5 allows it. Company Portal and its SSO
#        extension hold no user documents and are always stopped. The user's
#        AppSSOAgent is restarted.
#     3. Deletes the user's Company Portal / SSO extension containers and
#        caches, MSAL/ADAL/OneAuth caches and Office identity caches, then
#        restarts cfprefsd so deleted preferences are not written back.
#     4. Deletes Microsoft / Workplace Join items from the user's file-based
#        keychains (the login keychain and any other *.keychain-db).
#     5. Optionally resets the associated-domains cache ($7).
#     6. Refreshes Company Portal's browser native-messaging manifest for
#        Chrome, Edge and Arc: only for browsers the user has, and only when
#        Company Portal provides a manifest to copy.
#
# USERS MUST SIGN IN AGAIN
#   Afterwards the user restarts the Mac, opens Company Portal, signs in with
#   their work account and completes device registration again. Word, Excel,
#   PowerPoint, Outlook, OneNote, Teams, OneDrive and Edge will also ask them
#   to sign in again.
#
# WHAT THIS SCRIPT DOES NOT CLEAR
#   - The data-protection keychain. The Enterprise SSO plug-in keeps its
#     Primary Refresh Token (PRT) and Workplace Join keys there (newer Company
#     Portal versions can keep the device key in the Secure Enclave). The
#     `security` command can only reach file-based keychains, so those items
#     survive, and the "PRT" lines in the log are not conclusive. To reset
#     them, the user removes the account / device registration in Company
#     Portal and registers again.
#   - Platform SSO registration (the script exits instead; see $8).
#   - Jamf Pro enrollment, MDM profiles or managed preferences.
#   - The Apple Kerberos SSO extension profile, if you use one. The user may
#     have to re-authenticate to it once after AppSSOAgent restarts.
#   - The Company Portal app itself, or the Entra device object in the cloud.
#   - Browser cookies and sessions, and caches of any other local user.
#
# SUPPORTED macOS
#   Written for macOS 13 Ventura and later. The Platform SSO check relies on
#   `app-sso platform`, which only exists from macOS 13 onwards; on older
#   releases that check is skipped. It has not been verified against every
#   macOS release or Company Portal version, so run it on a pilot Mac with $4
#   (dry run) first.
#
# REQUIREMENTS
#   - Runs as root (the Jamf Pro default). A user must be logged in at the
#     console. At the login window or in Setup Assistant it exits without
#     changes.
#   - Full Disk Access for the process that runs the script: deploy a PPPC
#     (Privacy Preferences Policy Control) configuration profile granting
#     SystemPolicyAllFiles to the Jamf binary (/usr/local/jamf/bin/jamf).
#     Without it, deleting items under ~/Library/Containers and
#     ~/Library/Group Containers fails with "Operation not permitted". Each
#     failure is logged and the script exits 6.
#   - Graceful quitting sends each running app a "quit" Apple Event as the
#     user. If macOS blocks or prompts for that event, the app stays open and
#     the timeout / force-quit rules below apply.
#
# JAMF PRO PARAMETERS
#   Booleans accept true/false, yes/no or 1/0 (case-insensitive). An empty
#   parameter uses the default. Any other value exits 3 without changes.
#   $4  Dry run (default: false). Log what would be quit, removed or changed,
#       and change nothing.
#   $5  Force-quit apps (default: false). Kill any app that is still open
#       when the timeout runs out. UNSAVED WORK IN THAT APP IS LOST. When
#       false, the script exits 5 without clearing anything if an app is
#       still open.
#   $6  Quit timeout in seconds (default: 60, allowed: 0-600). How long to
#       wait for apps to quit after asking them.
#   $7  Reset associated domains (default: false). Runs `swcutil reset` and
#       restarts swcd. This resets associated-domain data for every app, not
#       just Microsoft's, and runs as root rather than for one user. Only use
#       it if the SSO extension still fails to load for its domains.
#   $8  Allow Platform SSO (default: false). Run even if the Mac is (or might
#       be) registered with Platform SSO. That can break the registration.
#
# LOG
#   /private/var/EnterpriseManagement/Logs/ResetEntraIdentityCaches.log
#
# JAMF PRO RECOMMENDATIONS
#   Trigger:    Self Service (preferred) or custom event
#   Frequency:  Once per computer / as needed
#   Scope:      Affected computers only
#   Follow-up:  Tell the user to restart and sign in to Company Portal again
#
# EXIT CODES
#   0  Completed (or dry run completed); the user still has to sign in again
#   1  Not running as root
#   2  No console user, or the user's home folder / UID could not be resolved
#   3  Invalid Jamf parameter
#   4  Platform SSO registration detected, or its state is unknown; no changes
#   5  Apps did not quit in time and force-quit is off; no caches changed
#   6  Completed, but one or more items could not be removed
###############################################################################

set -o pipefail

readonly LOG_DIR="/private/var/EnterpriseManagement/Logs"
readonly LOG="${LOG_DIR}/ResetEntraIdentityCaches.log"
readonly COMPANY_PORTAL_APP="/Applications/Company Portal.app"
readonly COMPANY_PORTAL_BUNDLE_ID="com.microsoft.CompanyPortalMac"

# Company Portal and every process inside its bundle, including the Enterprise
# SSO extension. They hold the caches being removed and keep no user
# documents, so they are always stopped.
readonly COMPANY_PORTAL_PROCESS_REGEX='/Company Portal\.app/Contents/'

# Public application (client) ID of Microsoft's first-party "Microsoft
# Authentication Broker" app. It is the same in every tenant; it is not a
# tenant ID. Used to look for a PRT item named after it in the login keychain.
readonly MS_AUTH_BROKER_APP_ID="29d9ed98-a469-4536-ade2-f981bc1d605e"
readonly PRT_SERVICE="primaryrefreshtoken-${MS_AUTH_BROKER_APP_ID}"

# Microsoft apps that share the Office / OneAuth identity caches and can hold
# unsaved work. They are asked to quit, and only killed if $5 allows it.
# Format: "Display name;pgrep -f regex for the main executable;bundle ID(s)"
readonly MS_USER_APPS=(
    'Microsoft Word;/Microsoft Word\.app/Contents/MacOS/;com.microsoft.Word'
    'Microsoft Excel;/Microsoft Excel\.app/Contents/MacOS/;com.microsoft.Excel'
    'Microsoft PowerPoint;/Microsoft PowerPoint\.app/Contents/MacOS/;com.microsoft.Powerpoint'
    'Microsoft Outlook;/Microsoft Outlook\.app/Contents/MacOS/;com.microsoft.Outlook'
    'Microsoft OneNote;/Microsoft OneNote\.app/Contents/MacOS/;com.microsoft.onenote.mac'
    'Microsoft Teams;/Microsoft Teams( classic| \(work or school\))?\.app/Contents/MacOS/;com.microsoft.teams2 com.microsoft.teams'
    'Microsoft Edge;/Microsoft Edge\.app/Contents/MacOS/;com.microsoft.edgemac'
    'OneDrive;/OneDrive\.app/Contents/MacOS/;com.microsoft.OneDrive com.microsoft.OneDrive-mac'
)

# User-scoped paths that commonly hold SSO / MSAL / Company Portal state
readonly USER_CACHE_GLOBS=(
    "Library/Containers/com.microsoft.CompanyPortalMac"
    "Library/Containers/com.microsoft.CompanyPortalMac.ssoextension"
    "Library/Group Containers/UBF8T346G9.com.microsoft.identity"
    "Library/Group Containers/UBF8T346G9.com.microsoft.oneauth"
    "Library/Group Containers/UBF8T346G9.Office/Library/Caches"
    "Library/Group Containers/UBF8T346G9.Office/Microsoft Office Identities Cache 2"
    "Library/Group Containers/UBF8T346G9.Office/Microsoft Office Identities Settings 2"
    "Library/Group Containers/UBF8T346G9.Office/Microsoft Office Identities Cache 3"
    "Library/Group Containers/UBF8T346G9.Office/Microsoft Office Identities Settings 3"
    "Library/Group Containers/UBF8T346G9.Office/ComRPC32"
    "Library/Application Support/com.microsoft.CompanyPortalMac"
    "Library/Application Support/com.microsoft.CompanyPortal"
    "Library/Caches/com.microsoft.CompanyPortalMac"
    "Library/Caches/com.microsoft.CompanyPortalMac.ssoextension"
    "Library/Caches/com.microsoft.SSOExtension"
    "Library/Caches/com.microsoft.oneauth"
    "Library/Caches/Microsoft/OneAuth"
    "Library/Caches/Microsoft/MSAL"
    "Library/Caches/com.microsoft.identity"
    "Library/HTTPStorages/com.microsoft.CompanyPortalMac"
    "Library/HTTPStorages/com.microsoft.CompanyPortalMac.ssoextension"
    "Library/Preferences/com.microsoft.CompanyPortalMac.plist"
    "Library/Preferences/com.microsoft.CompanyPortal.plist"
    "Library/Preferences/com.microsoft.adalcache.plist"
    "Library/Preferences/com.microsoft.identity.plist"
    "Library/Preferences/com.microsoft.oneauth.plist"
)

# Preference / identity keys commonly left in the login keychain
readonly KEYCHAIN_GENERIC_ACCOUNTS=(
    "com.microsoft.workplacejoin.thumbprint"
    "com.microsoft.workplacejoin.registeredUserPrincipalName"
    "com.microsoft.workplacejoin.registrationKey"
    "com.microsoft.workplacejoin.discoveryHint"
    "com.microsoft.workplacejoin.deviceID"
    "com.microsoft.adalcache"
    "com.microsoft.identity.universalstorage"
    "com.microsoft.CompanyPortal"
    "com.microsoft.CompanyPortal.HockeySDK"
)

readonly KEYCHAIN_GENERIC_SERVICES=(
    "enterpriseregistration.windows.net"
    "https://device.login.microsoftonline.com"
    "https://device.login.microsoftonline.com/"
    "https://enterpriseregistration.windows.net"
    "https://enterpriseregistration.windows.net/"
    "Microsoft Office Identities Cache 2"
    "Microsoft Office Identities Settings 2"
    "Microsoft Office Identities Cache 3"
    "Microsoft Office Identities Settings 3"
    "Microsoft Session Transport Key"
)

# Chromium browsers that load Company Portal's "browsercore" native-messaging
# host for Entra SSO. Format: "Browser name;user data directory under ~"
readonly NATIVE_MESSAGING_BROWSERS=(
    'Google Chrome;Library/Application Support/Google/Chrome'
    'Microsoft Edge;Library/Application Support/Microsoft Edge'
    'Arc;Library/Application Support/Arc/User Data'
)
readonly BROWSERCORE_MANIFEST="com.microsoft.browsercore.json"

# Set from Jamf parameters in read_parameters
DRY_RUN="false"
FORCE_QUIT="false"
QUIT_TIMEOUT=60
RESET_ASSOCIATED_DOMAINS="false"
ALLOW_PLATFORM_SSO="false"

# Number of items that could not be removed or changed
FAILURES=0

init_logging() {
    /bin/mkdir -p "${LOG_DIR}"
    /bin/chmod 755 "${LOG_DIR}"
    /usr/bin/touch "${LOG}"
    /bin/chmod 644 "${LOG}"
}

log() {
    /bin/echo "$(/bin/date '+%Y-%m-%d %H:%M:%S')  $*" | /usr/bin/tee -a "${LOG}"
}

fail() {
    FAILURES=$((FAILURES + 1))
    log "FAILED: $*"
}

is_true() {
    [[ "$1" == "true" ]]
}

require_root() {
    if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
        /bin/echo "ERROR: This script must run as root." >&2
        exit 1
    fi
}

# Echo "true" or "false" for a boolean parameter ($2 is the default when $1
# is empty). Returns 1 if the value is not a recognised boolean.
parse_bool() {
    local value
    value="$(printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -d '[:space:]')"
    case "${value}" in
        "")           /bin/echo "$2" ;;
        true|yes|1)   /bin/echo "true" ;;
        false|no|0)   /bin/echo "false" ;;
        *)            return 1 ;;
    esac
}

invalid_parameter() {
    log "ERROR: Invalid value for parameter $1: '$2'. $3 No changes were made."
    exit 3
}

read_parameters() {
    local timeout

    # $1-$3 are set by Jamf Pro (mount point, computer name, username).
    DRY_RUN="$(parse_bool "${4:-}" false)" \
        || invalid_parameter 4 "${4:-}" "Use true or false."
    FORCE_QUIT="$(parse_bool "${5:-}" false)" \
        || invalid_parameter 5 "${5:-}" "Use true or false."
    RESET_ASSOCIATED_DOMAINS="$(parse_bool "${7:-}" false)" \
        || invalid_parameter 7 "${7:-}" "Use true or false."
    ALLOW_PLATFORM_SSO="$(parse_bool "${8:-}" false)" \
        || invalid_parameter 8 "${8:-}" "Use true or false."

    timeout="$(printf '%s' "${6:-}" | /usr/bin/tr -d '[:space:]')"
    case "${timeout}" in
        "")
            QUIT_TIMEOUT=60
            ;;
        *[!0-9]*)
            invalid_parameter 6 "${6:-}" "Use a whole number of seconds from 0 to 600."
            ;;
        *)
            # Drop leading zeros (bash would read "08" as octal), keep "0".
            timeout="${timeout#"${timeout%%[!0]*}"}"
            timeout="${timeout:-0}"
            if [[ "${#timeout}" -gt 3 ]] || [[ "${timeout}" -gt 600 ]]; then
                invalid_parameter 6 "${6:-}" "Use a whole number of seconds from 0 to 600."
            fi
            QUIT_TIMEOUT="${timeout}"
            ;;
    esac
}

os_version_major() {
    /usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{print $1}'
}

console_user() {
    local user
    user="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)"
    case "${user}" in
        ""|root|loginwindow|_mbsetupuser)
            /bin/echo ""
            return 1
            ;;
    esac
    /bin/echo "${user}"
}

console_user_home() {
    local user="$1"
    # dscl puts values containing spaces on the following line, so strip the
    # attribute name and join the lines rather than splitting on whitespace.
    /usr/bin/dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null \
        | /usr/bin/sed -e 's/^NFSHomeDirectory://' -e 's/^ *//' \
        | /usr/bin/tr -d '\n'
}

console_user_id() {
    local user="$1"
    /usr/bin/id -u "${user}" 2>/dev/null
}

run_as_user() {
    local user="$1"
    local uid="$2"
    shift 2

    if /usr/bin/command -v /bin/launchctl >/dev/null 2>&1; then
        /bin/launchctl asuser "${uid}" /usr/bin/sudo -u "${user}" "$@"
        return $?
    fi

    /usr/bin/sudo -u "${user}" "$@"
}

check_full_disk_access() {
    # Only a process with Full Disk Access can read the system TCC database.
    if /usr/bin/head -c 1 "/Library/Application Support/com.apple.TCC/TCC.db" >/dev/null 2>&1; then
        log "Full Disk Access: granted."
    else
        log "WARNING: Full Disk Access does not appear to be granted to the process running this script."
        log "WARNING: Removing app containers will probably fail. Grant SystemPolicyAllFiles to the Jamf binary with a PPPC profile."
    fi
}

# Classify `app-sso platform -s` output: echoes registered, not-registered or
# unknown.
platform_sso_state() {
    local output="$1"
    local device

    if /usr/bin/grep -Eq '"registrationCompleted"[[:space:]]*:[[:space:]]*(true|1)' <<< "${output}"; then
        /bin/echo "registered"
        return 0
    fi

    if ! /usr/bin/grep -q '^Device Configuration:' <<< "${output}"; then
        /bin/echo "unknown"
        return 0
    fi

    # Text of the "Device Configuration:" section (including anything on the
    # heading line itself), up to the next "... Configuration:" heading.
    device="$(/usr/bin/awk '
        /^Device Configuration:/ { inside = 1; sub(/^Device Configuration:/, ""); print; next }
        /^[A-Za-z][A-Za-z ]*Configuration:/ { inside = 0 }
        inside { print }
    ' <<< "${output}" | /usr/bin/tr -d '[:space:]')"

    case "${device}" in
        ""|null|"(null)") /bin/echo "not-registered" ;;
        *)                /bin/echo "registered" ;;
    esac
}

guard_platform_sso() {
    local user="$1"
    local uid="$2"
    local major="$3"
    local output state="unknown"

    if [[ "${major}" -lt 13 ]]; then
        log "Platform SSO check skipped: not available before macOS 13."
        return 0
    fi

    if [[ -x /usr/bin/app-sso ]]; then
        output="$(run_as_user "${user}" "${uid}" /usr/bin/app-sso platform -s 2>&1)"
        state="$(platform_sso_state "${output}")"
    else
        log "WARNING: /usr/bin/app-sso not found."
    fi

    case "${state}" in
        not-registered)
            log "Platform SSO: this Mac is not registered."
            return 0
            ;;
        registered)
            log "Platform SSO registration detected (app-sso platform -s)."
            ;;
        *)
            log "WARNING: Could not determine the Platform SSO state from 'app-sso platform -s'."
            ;;
    esac

    if is_true "${ALLOW_PLATFORM_SSO}"; then
        log "WARNING: Continuing because parameter 8 (allow Platform SSO) is true."
        log "WARNING: The user may have to repair their Platform SSO registration afterwards."
        return 0
    fi

    log "ERROR: This script is not meant for Platform SSO Macs. No changes were made."
    log "ERROR: Set parameter 8 to true to run it anyway."
    exit 4
}

# Echo a comma-separated list of MS_USER_APPS still running for this user.
running_user_apps() {
    local uid="$1"
    local entry name regex list=""

    for entry in "${MS_USER_APPS[@]}"; do
        IFS=';' read -r name regex _ <<< "${entry}"
        if /usr/bin/pgrep -u "${uid}" -f "${regex}" >/dev/null 2>&1; then
            list="${list:+${list}, }${name}"
        fi
    done
    /bin/echo "${list}"
}

# Send a "quit" Apple Event as the user, without waiting for a reply. The app
# can still ask the user to save open documents. The bundle ID is passed as an
# argument so nothing is resolved (or launched) unless the app is running.
ask_app_to_quit() {
    local user="$1"
    local uid="$2"
    local bundle_id="$3"

    run_as_user "${user}" "${uid}" /usr/bin/osascript \
        -e 'on run argv' \
        -e 'set bundleID to item 1 of argv' \
        -e 'try' \
        -e 'if application id bundleID is running then' \
        -e 'ignoring application responses' \
        -e 'tell application id bundleID to quit' \
        -e 'end ignoring' \
        -e 'end if' \
        -e 'end try' \
        -e 'end run' \
        "${bundle_id}" >/dev/null 2>&1 || true
}

quit_user_apps() {
    local user="$1"
    local uid="$2"
    local entry name regex bundle_ids bundle_id running waited=0

    running="$(running_user_apps "${uid}")"
    if [[ -z "${running}" ]]; then
        log "No Microsoft Office / Teams / Edge / OneDrive apps running for ${user}."
        return 0
    fi

    if is_true "${DRY_RUN}"; then
        log "DRY RUN: would ask these apps to quit: ${running}"
        if is_true "${FORCE_QUIT}"; then
            log "DRY RUN: any still open after ${QUIT_TIMEOUT}s would be force-quit."
        else
            log "DRY RUN: if any were still open after ${QUIT_TIMEOUT}s, the script would exit 5 without changes."
        fi
        return 0
    fi

    log "Asking these apps to quit (the user can save open work): ${running}"
    for entry in "${MS_USER_APPS[@]}"; do
        IFS=';' read -r name regex bundle_ids <<< "${entry}"
        /usr/bin/pgrep -u "${uid}" -f "${regex}" >/dev/null 2>&1 || continue
        for bundle_id in ${bundle_ids}; do
            ask_app_to_quit "${user}" "${uid}" "${bundle_id}"
        done
    done

    while [[ "${waited}" -lt "${QUIT_TIMEOUT}" ]]; do
        running="$(running_user_apps "${uid}")"
        [[ -z "${running}" ]] && break
        /bin/sleep 2
        waited=$((waited + 2))
    done

    running="$(running_user_apps "${uid}")"
    if [[ -z "${running}" ]]; then
        log "All Microsoft apps quit."
        return 0
    fi

    if ! is_true "${FORCE_QUIT}"; then
        log "ERROR: Still open after ${QUIT_TIMEOUT}s: ${running}"
        log "ERROR: No caches were changed. Have the user save their work and quit these apps, then run again,"
        log "ERROR: or set parameter 5 to true to force-quit them."
        exit 5
    fi

    log "WARNING: Still open after ${QUIT_TIMEOUT}s; force-quitting (unsaved work in these apps is lost): ${running}"
    for entry in "${MS_USER_APPS[@]}"; do
        IFS=';' read -r name regex _ <<< "${entry}"
        /usr/bin/pkill -9 -u "${uid}" -f "${regex}" >/dev/null 2>&1 || true
    done
    /bin/sleep 2

    running="$(running_user_apps "${uid}")"
    if [[ -n "${running}" ]]; then
        log "ERROR: Could not stop: ${running}. No caches were changed."
        exit 5
    fi
    log "Force-quit complete."
}

stop_company_portal() {
    local user="$1"
    local uid="$2"
    local waited=0

    if ! /usr/bin/pgrep -u "${uid}" -f "${COMPANY_PORTAL_PROCESS_REGEX}" >/dev/null 2>&1; then
        return 0
    fi

    if is_true "${DRY_RUN}"; then
        log "DRY RUN: would stop Company Portal and its SSO extension for ${user}."
        return 0
    fi

    log "Stopping Company Portal and its SSO extension for ${user}."
    ask_app_to_quit "${user}" "${uid}" "${COMPANY_PORTAL_BUNDLE_ID}"
    while [[ "${waited}" -lt 10 ]] \
        && /usr/bin/pgrep -u "${uid}" -f "${COMPANY_PORTAL_PROCESS_REGEX}" >/dev/null 2>&1; do
        /bin/sleep 1
        waited=$((waited + 1))
    done

    /usr/bin/pkill -u "${uid}" -f "${COMPANY_PORTAL_PROCESS_REGEX}" >/dev/null 2>&1 || true
    /bin/sleep 1
    /usr/bin/pkill -9 -u "${uid}" -f "${COMPANY_PORTAL_PROCESS_REGEX}" >/dev/null 2>&1 || true
}

quit_microsoft_apps() {
    local user="$1"
    local uid="$2"

    log "Quitting Microsoft identity-related apps for ${user}."
    quit_user_apps "${user}" "${uid}"
    stop_company_portal "${user}" "${uid}"

    # Restart Apple's SSO host so the Microsoft Enterprise SSO plug-in reloads
    # with a clean cache. launchd relaunches both on demand. This can briefly
    # interrupt Kerberos SSO; the Kerberos SSO extension profile is untouched.
    if is_true "${DRY_RUN}"; then
        log "DRY RUN: would restart AppSSOAgent for ${user} and AppSSODaemon."
        return 0
    fi
    log "Restarting AppSSOAgent for ${user} and AppSSODaemon (SSO extension host)."
    /usr/bin/pkill -u "${uid}" -x AppSSOAgent >/dev/null 2>&1 || true
    /usr/bin/pkill -x AppSSODaemon >/dev/null 2>&1 || true

    /bin/sleep 2
}

reset_associated_domains_cache() {
    if ! is_true "${RESET_ASSOCIATED_DOMAINS}"; then
        log "Associated-domains reset (swcutil) skipped; set parameter 7 to true to enable it."
        return 0
    fi

    if is_true "${DRY_RUN}"; then
        log "DRY RUN: would run 'swcutil reset' and restart swcd and AppSSOAgent."
        return 0
    fi

    log "Resetting the associated-domains cache (swcd / swcutil) for all apps."

    /usr/bin/pkill -x swcd >/dev/null 2>&1 || true

    if [[ -x /usr/bin/swcutil ]]; then
        if /usr/bin/swcutil reset >/dev/null 2>&1; then
            log "swcutil reset completed."
        else
            fail "swcutil reset returned a non-zero status."
        fi
    else
        fail "swcutil not found; associated-domains reset not done."
    fi

    /usr/bin/pkill -x AppSSOAgent >/dev/null 2>&1 || true
}

capture_identity_status() {
    local user="$1"
    local uid="$2"
    local label="$3"
    local output="" line

    log "Identity status snapshot (${label}):"

    if [[ -x /usr/bin/app-sso ]]; then
        # List configured SSO extensions (Microsoft Enterprise SSO, Kerberos).
        output="$(run_as_user "${user}" "${uid}" /usr/bin/app-sso -l 2>&1 || true)"
        if [[ -n "${output}" ]]; then
            log "Configured SSO extensions (app-sso -l):"
            while IFS= read -r line; do
                log "  ${line}"
            done <<< "${output}"
        else
            log "app-sso -l returned no output."
        fi
    else
        log "app-sso not available; skipping SSO extension list."
    fi

    if run_as_user "${user}" "${uid}" /usr/bin/security find-generic-password -s "${PRT_SERVICE}" >/dev/null 2>&1; then
        log "PRT item found in the user's file-based keychains (${label})."
    else
        log "No PRT item in the user's file-based keychains (${label}). Not conclusive: the SSO plug-in's PRT lives in the data-protection keychain, which scripts cannot read."
    fi
}

# Remove a file or directory and report what really happened.
# Returns 0 if removed (or would be, in a dry run), 1 if it does not exist,
# 2 if it could not be removed (counted in FAILURES).
remove_path_if_exists() {
    local path="$1"
    local err rc

    if [[ ! -e "${path}" && ! -L "${path}" ]]; then
        return 1
    fi

    if is_true "${DRY_RUN}"; then
        log "DRY RUN: would remove ${path}"
        return 0
    fi

    err="$(/bin/rm -rf "${path}" 2>&1)"
    rc=$?
    if [[ "${rc}" -ne 0 || -e "${path}" || -L "${path}" ]]; then
        fail "could not remove ${path}: ${err:-rm exited ${rc}} (Full Disk Access missing?)"
        return 2
    fi

    log "Removed: ${path}"
    return 0
}

# Restart cfprefsd for an account so preference files deleted on disk are not
# written back from its in-memory cache.
flush_preferences_cache() {
    local account="$1"

    if is_true "${DRY_RUN}"; then
        log "DRY RUN: would restart cfprefsd for ${account}."
        return 0
    fi
    /usr/bin/killall -u "${account}" cfprefsd >/dev/null 2>&1 || true
    log "Restarted cfprefsd for ${account}."
}

clear_user_file_caches() {
    local user="$1"
    local home="$2"
    local rel path
    local removed=0
    local handled=$'\n'

    log "Clearing user-scoped Microsoft / Entra cache paths for ${user}."

    for rel in "${USER_CACHE_GLOBS[@]}"; do
        path="${home}/${rel}"
        if remove_path_if_exists "${path}"; then
            removed=$((removed + 1))
            handled="${handled}${path}"$'\n'
        fi
    done

    # Other MSAL / ADAL / OneAuth leftovers under known Microsoft roots only.
    # Outlook data and User Content (templates, fonts) are never searched, and
    # names must be Microsoft-specific so user files are not matched.
    local search_roots=()
    local root
    for root in \
        "${home}/Library/Application Support/Microsoft" \
        "${home}/Library/Caches/Microsoft" \
        "${home}/Library/Group Containers/UBF8T346G9.Office"
    do
        [[ -d "${root}" ]] && search_roots+=("${root}")
    done

    if [[ "${#search_roots[@]}" -gt 0 ]]; then
        while IFS= read -r path; do
            [[ -z "${path}" ]] && continue
            # Already reported above (matters in a dry run, where nothing is gone)
            case "${handled}" in
                *$'\n'"${path}"$'\n'*) continue ;;
            esac
            if remove_path_if_exists "${path}"; then
                removed=$((removed + 1))
            fi
        done < <(/usr/bin/find \
            "${search_roots[@]}" \
            -maxdepth 5 \
            \( -path '*/UBF8T346G9.Office/Outlook' -o -path '*/UBF8T346G9.Office/User Content' \) -prune -o \
            \( \
                -iname 'com.microsoft.msal*' -o -iname 'msal' -o -iname 'msal.*' -o -iname 'msal_*' -o \
                -iname 'com.microsoft.oneauth*' -o -iname 'oneauth' -o -iname 'oneauth.*' -o -iname 'oneauth_*' -o \
                -iname 'com.microsoft.adal*' -o -iname 'adalcache*' -o \
                -iname 'com.microsoft.workplacejoin*' -o \
                -iname '*CompanyPortal*' -o \
                -iname '*SSOExtension*' -o \
                -iname 'Microsoft Office Identities*' \
            \) -print -prune 2>/dev/null)
    fi

    if [[ "${removed}" -gt 0 ]]; then
        flush_preferences_cache "${user}"
    fi

    if is_true "${DRY_RUN}"; then
        log "User file-cache items that would be removed: ${removed}"
    else
        log "User file-cache items removed: ${removed}"
    fi
}

# Delete every matching generic-password item from one keychain (or the
# default search list). Logs real outcomes; an item that is still there
# afterwards counts as a failure.
delete_keychain_generic_password() {
    local user="$1"
    local uid="$2"
    local account="$3"
    local service="$4"
    local keychain="$5"
    local args=()
    local label="default keychain search list"
    local deleted=0

    if [[ -n "${account}" ]]; then
        args+=(-a "${account}")
    fi
    if [[ -n "${service}" ]]; then
        args+=(-s "${service}")
    fi
    if [[ -n "${keychain}" ]]; then
        args+=("${keychain}")
        label="${keychain}"
    fi

    if is_true "${DRY_RUN}"; then
        if run_as_user "${user}" "${uid}" /usr/bin/security find-generic-password "${args[@]}" >/dev/null 2>&1; then
            log "DRY RUN: would delete keychain item account='${account}' service='${service}' from ${label}"
        fi
        return 0
    fi

    # delete-generic-password removes one match per call; repeat for duplicates.
    while [[ "${deleted}" -lt 20 ]] \
        && run_as_user "${user}" "${uid}" /usr/bin/security delete-generic-password "${args[@]}" >/dev/null 2>&1; do
        deleted=$((deleted + 1))
    done

    if [[ "${deleted}" -gt 0 ]]; then
        log "Deleted ${deleted} keychain item(s) account='${account}' service='${service}' from ${label}"
    fi
    if run_as_user "${user}" "${uid}" /usr/bin/security find-generic-password "${args[@]}" >/dev/null 2>&1; then
        fail "keychain item account='${account}' service='${service}' is still in ${label}"
    fi
}

clear_microsoft_keychain_items() {
    local user="$1"
    local uid="$2"
    local home="$3"
    local account service keychain hash label
    local keychains=()

    log "Clearing Microsoft / Workplace Join items from ${user}'s file-based keychains."
    log "NOTE: The data-protection keychain (where the SSO plug-in keeps its PRT) cannot be reached from here."
    log "NOTE: Keychain prompts may appear for some items; deletes are best-effort."

    # Default search list, then the login keychain and any other file-based
    # keychains (*.keychain-db). The data-protection keychain (keychain-2.db)
    # is skipped because the security command cannot open it.
    keychains+=("")
    while IFS= read -r keychain; do
        [[ -z "${keychain}" ]] && continue
        keychains+=("${keychain}")
    done < <(
        {
            [[ -f "${home}/Library/Keychains/login.keychain-db" ]] \
                && /bin/echo "${home}/Library/Keychains/login.keychain-db"
            /usr/bin/find "${home}/Library/Keychains" -maxdepth 2 \
                -name '*.keychain-db' -type f 2>/dev/null
        } | /usr/bin/awk 'NF && !seen[$0]++'
    )

    for keychain in "${keychains[@]}"; do
        label="${keychain:-default keychain search list}"

        for account in "${KEYCHAIN_GENERIC_ACCOUNTS[@]}"; do
            delete_keychain_generic_password "${user}" "${uid}" "${account}" "" "${keychain}"
        done

        for service in "${KEYCHAIN_GENERIC_SERVICES[@]}"; do
            delete_keychain_generic_password "${user}" "${uid}" "" "${service}" "${keychain}"
        done

        # Primary Refresh Token (PRT) items that ended up in a file-based
        # keychain. Take the full service name from the "svce" attribute.
        while IFS= read -r service; do
            [[ -z "${service}" ]] && continue
            delete_keychain_generic_password "${user}" "${uid}" "" "${service}" "${keychain}"
        done < <(
            run_as_user "${user}" "${uid}" /usr/bin/security dump-keychain ${keychain:+"${keychain}"} 2>/dev/null \
                | /usr/bin/sed -n 's/^.*"svce"<blob>="\(primaryrefreshtoken-[^"]*\)".*$/\1/p' \
                | /usr/bin/sort -u
        )

        delete_keychain_generic_password "${user}" "${uid}" "" "${PRT_SERVICE}" "${keychain}"

        # Workplace Join / Entra device certs (subject or issuer contains MS-Organization-Access)
        while IFS= read -r hash; do
            [[ -z "${hash}" ]] && continue
            if is_true "${DRY_RUN}"; then
                log "DRY RUN: would delete certificate SHA-1 ${hash} from ${label}"
            elif run_as_user "${user}" "${uid}" /usr/bin/security delete-certificate -Z "${hash}" ${keychain:+"${keychain}"} >/dev/null 2>&1; then
                log "Deleted certificate SHA-1 ${hash} from ${label}"
            else
                fail "could not delete certificate SHA-1 ${hash} from ${label}"
            fi
        done < <(
            run_as_user "${user}" "${uid}" /usr/bin/security find-certificate -a -Z ${keychain:+"${keychain}"} 2>/dev/null \
                | /usr/bin/awk '
                    /SHA-1 hash:/ { hash=$3; next }
                    {
                        line=tolower($0)
                        if (hash != "" && index(line, "ms-organization-access") > 0) {
                            print hash
                            hash=""
                        }
                    }
                ' | /usr/bin/sort -u
        )
    done

    # Identity preference entries for enterprise registration endpoints
    for service in \
        "https://enterpriseregistration.windows.net" \
        "https://enterpriseregistration.windows.net/" \
        "https://device.login.microsoftonline.com" \
        "https://device.login.microsoftonline.com/"
    do
        if is_true "${DRY_RUN}"; then
            run_as_user "${user}" "${uid}" /usr/bin/security get-identity-preference -s "${service}" >/dev/null 2>&1 \
                && log "DRY RUN: would delete identity preference: ${service}"
        else
            run_as_user "${user}" "${uid}" /usr/bin/security delete-identity-preference -s "${service}" >/dev/null 2>&1 \
                && log "Deleted identity preference: ${service}"
        fi
    done
    return 0
}

clear_system_microsoft_prefs() {
    local path
    local removed=0

    log "Clearing machine-scoped Microsoft identity preference leftovers (if present)."

    for path in \
        "/Library/Preferences/com.microsoft.CompanyPortalMac.plist" \
        "/Library/Preferences/com.microsoft.CompanyPortal.plist" \
        "/Library/Managed Preferences/com.microsoft.CompanyPortalMac.plist"
    do
        # Do not remove Managed Preferences payloads delivered by MDM
        if [[ "${path}" == "/Library/Managed Preferences/"* ]]; then
            log "Skipping MDM-managed preference (left intact): ${path}"
            continue
        fi
        if remove_path_if_exists "${path}"; then
            removed=$((removed + 1))
        fi
    done

    if [[ "${removed}" -gt 0 ]]; then
        flush_preferences_cache root
    fi
}

# Replace Company Portal's browser native-messaging manifest with the copy
# shipped in the app. Nothing is deleted: if Company Portal has no manifest to
# copy, existing manifests are left alone. Only browsers that already have a
# user data directory are touched, and files are written as the user so the
# NativeMessagingHosts directory and manifest are owned by them.
refresh_browser_native_messaging_hosts() {
    local user="$1"
    local uid="$2"
    local home="$3"
    local src="${COMPANY_PORTAL_APP}/Contents/Resources/${BROWSERCORE_MANIFEST}"
    local entry name data_dir host_dir dest

    if [[ ! -f "${src}" ]]; then
        log "Company Portal ${BROWSERCORE_MANIFEST} not found; browser native-messaging manifests left untouched."
        log "If Chrome/Edge device claims fail after re-registration, reinstall Company Portal."
        return 0
    fi

    for entry in "${NATIVE_MESSAGING_BROWSERS[@]}"; do
        IFS=';' read -r name data_dir <<< "${entry}"
        data_dir="${home}/${data_dir}"
        host_dir="${data_dir}/NativeMessagingHosts"
        dest="${host_dir}/${BROWSERCORE_MANIFEST}"

        if [[ ! -d "${data_dir}" ]]; then
            log "${name}: no browser data for ${user}; native-messaging manifest not added."
            continue
        fi

        if [[ -L "${host_dir}" || -L "${dest}" ]]; then
            log "WARNING: ${name}: ${host_dir} or its manifest is a symbolic link; leaving it alone."
            continue
        fi

        if is_true "${DRY_RUN}"; then
            log "DRY RUN: would write ${dest} (copy of ${src}) as ${user}"
            continue
        fi

        # Hand back a directory or manifest that an earlier run (or another
        # tool) created as root, so the user can write to it.
        if [[ -d "${host_dir}" && "$(/usr/bin/stat -f%u "${host_dir}")" != "${uid}" ]]; then
            /usr/sbin/chown -h "${uid}" "${host_dir}" \
                && log "${name}: changed owner of ${host_dir} to ${user}"
        fi
        if [[ -f "${dest}" && "$(/usr/bin/stat -f%u "${dest}")" != "${uid}" ]]; then
            /usr/sbin/chown -h "${uid}" "${dest}" \
                && log "${name}: changed owner of ${dest} to ${user}"
        fi

        if run_as_user "${user}" "${uid}" /bin/mkdir -p "${host_dir}" \
            && run_as_user "${user}" "${uid}" /bin/cp -f "${src}" "${dest}" \
            && run_as_user "${user}" "${uid}" /bin/chmod 644 "${dest}"; then
            log "Refreshed ${name} native-messaging host: ${dest}"
        else
            fail "could not write ${name} native-messaging host: ${dest}"
        fi
    done
}

print_next_steps() {
    local user="$1"

    log "--------------------------------------------------------------------"
    log "Cleanup finished for user: ${user}"
    log "REQUIRED next steps on the Mac:"
    log "  1. Restart the Mac."
    log "  2. Open Company Portal and sign in with the Entra work account."
    log "  3. If an account or device registration is still shown, use"
    log "     Company Portal > Settings > Remove account from this device, then"
    log "     sign in again. This also resets the PRT and device keys in the"
    log "     data-protection keychain, which this script cannot remove."
    log "  4. Sign in to Office, Teams, OneDrive and Edge again when asked."
    log "  5. If the Apple Kerberos SSO extension is also in use, complete any"
    log "     Kerberos prompt (its profile was not touched)."
    log "  6. Retest a Conditional Access-protected resource"
    log "     (e.g. https://portal.office.com)."
    log "  7. Optional diagnostics: Company Portal > Help > Send diagnostic"
    log "     report; SSO extension logs are under"
    log "     ~/Library/Containers/com.microsoft.CompanyPortalMac.ssoextension/"
    log "--------------------------------------------------------------------"
    log "Jamf Pro device compliance note:"
    log "  Entra 'Compliant' on the device object can disagree with the device"
    log "  claim presented by the Microsoft Enterprise SSO plug-in. After"
    log "  re-registration, wait a few minutes for partner compliance sync,"
    log "  then retest. Leave the Entra device record in place unless it is"
    log "  clearly a duplicate/orphan after re-registration fails."
}

main() {
    local user home uid major

    require_root
    init_logging
    read_parameters "$@"

    major="$(os_version_major)"
    log "===== Reset Entra identity caches starting ====="
    log "macOS $(/usr/bin/sw_vers -productVersion) (major ${major}), host $(/bin/hostname)"
    log "Options: dry run=${DRY_RUN}, force quit=${FORCE_QUIT}, quit timeout=${QUIT_TIMEOUT}s, reset associated domains=${RESET_ASSOCIATED_DOMAINS}, allow Platform SSO=${ALLOW_PLATFORM_SSO}"
    if is_true "${DRY_RUN}"; then
        log "DRY RUN: nothing will be quit, deleted or changed."
    fi

    if [[ "${major}" -lt 13 ]]; then
        log "WARNING: Script targets macOS 13+; continuing anyway."
    fi

    user="$(console_user || true)"
    if [[ -z "${user}" ]]; then
        log "ERROR: No user logged in at the console. Log in as the affected user and run again. No changes were made."
        exit 2
    fi

    home="$(console_user_home "${user}")"
    uid="$(console_user_id "${user}")"

    if [[ -z "${home}" || ! -d "${home}" || -z "${uid}" ]]; then
        log "ERROR: Could not resolve home/UID for console user '${user}'. No changes were made."
        exit 2
    fi

    log "Console user: ${user} (uid ${uid})"
    log "Home directory: ${home}"

    if [[ -d "${COMPANY_PORTAL_APP}" ]]; then
        log "Company Portal present: ${COMPANY_PORTAL_APP}"
    else
        log "WARNING: Company Portal not installed at ${COMPANY_PORTAL_APP}."
        log "SSO extension / compliance device claims require Company Portal."
    fi

    check_full_disk_access
    guard_platform_sso "${user}" "${uid}" "${major}"

    capture_identity_status "${user}" "${uid}" "before"
    quit_microsoft_apps "${user}" "${uid}"
    clear_user_file_caches "${user}" "${home}"
    clear_microsoft_keychain_items "${user}" "${uid}" "${home}"
    clear_system_microsoft_prefs
    reset_associated_domains_cache
    refresh_browser_native_messaging_hosts "${user}" "${uid}" "${home}"

    if is_true "${DRY_RUN}"; then
        log "===== Dry run completed; nothing was changed ====="
        exit 0
    fi

    capture_identity_status "${user}" "${uid}" "after"
    print_next_steps "${user}"

    if [[ "${FAILURES}" -gt 0 ]]; then
        log "===== Completed with ${FAILURES} failure(s); see FAILED lines above ====="
        exit 6
    fi

    log "===== Reset Entra identity caches completed ====="
    exit 0
}

main "$@"
