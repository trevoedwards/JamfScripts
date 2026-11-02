#!/bin/bash
###############################################################################
# CiscoSecureClientDisableAutoUpdate.sh
#
# Stops Cisco Secure Client (or legacy AnyConnect) from running its built-in
# updater, vpndownloader, by setting in AnyConnectLocalPolicy.xml:
#   - BypassDownloader = true
#   - AllowSoftwareUpdatesFromAnyServer = false (only if an UpdatePolicy entry
#     for it already exists; it is never added)
# Optionally ($6) it also sets AutoUpdate = false in the local VPN profile
# XML files that already contain an <AutoUpdate> element.
#
# Typical reason: vpndownloader runs from /private/tmp during client updates,
# which can trigger prompts or blocks from endpoint privilege-management or
# security tools. Use this when the client is deployed and updated by Jamf.
#
# READ BEFORE DEPLOYING - BypassDownloader=true is not harmless:
#   - Per Cisco's Secure Client admin guide, the client then no longer checks
#     the headend (ASA / Secure Firewall) for dynamic content: translations,
#     customizations, optional modules, core software updates, and VPN client
#     profile updates. Profiles pushed by the headend stop reaching the Mac,
#     so local profiles drift from the headend over time.
#   - Cisco also documents that with BypassDownloader=true, if the VPN client
#     profile on the headend differs from the one on the client, the client
#     aborts the connection attempt. Any profile change made on the headend
#     must then be deployed to Macs another way (for example a Jamf package)
#     or VPN connections fail. Cisco recommends BypassDownloader=true only if
#     you don't rely on the headend to manage client profiles.
#   - That is why editing VPN profiles ($6) is off by default: changing the
#     local copy of a headend-managed profile creates exactly that mismatch.
#     Only enable it for profiles you deploy locally that the headend doesn't
#     push. The element is changed only where it already exists; it is never
#     inserted, because the profile schema fixes the element order.
#
# Applying the change:
#   Cisco documents that local policy changes need a VPN service restart
#   (AnyConnect 4.x guide) or a reboot (Secure Client 5.x guide). Only when
#   AnyConnectLocalPolicy.xml was actually changed, the script terminates any
#   running vpndownloader and restarts the VPN agent daemon with
#   "launchctl kickstart -k" (unless $5 is false). Restarting the agent DROPS
#   ANY ACTIVE VPN SESSION on that Mac. If nothing changed, nothing is
#   restarted. Changing a profile alone doesn't restart anything.
#
# Safety:
#   - Every file is checked with xmllint before and after editing; a file is
#     only replaced if the result is well-formed XML.
#   - Every file is backed up to <file>.bak.<YYYYmmddHHMMSS> before it's
#     changed. The file keeps its owner and permissions.
#   - Uses /usr/bin/perl and /usr/bin/xmllint, which ship with macOS. It does
#     not use python3: on current macOS /usr/bin/python3 is a Command Line
#     Tools stub that fails or prompts to install CLT if CLT is missing.
#
# Jamf Pro parameters (true/false, yes/no or 1/0, case-insensitive):
#   $4  Dry run (default: false). Logs what would change (with a diff) and
#       what would be restarted, without writing, backing up or restarting.
#   $5  Restart the VPN agent when the local policy changed (default: true).
#       false = apply at the next reboot and leave VPN sessions up.
#   $6  Also set AutoUpdate=false in local VPN profiles (default: false).
#       See the warning above before enabling.
#
# Requirements:
#   macOS with Cisco Secure Client 5.x (/opt/cisco/secureclient) or AnyConnect
#   4.x (/opt/cisco/anyconnect). Runs as root (Jamf policy scripts do).
#
# Jamf Pro suggestion:
#   Recurring Check-in, Ongoing or weekly (an upgrade can reset the local
#   policy), scoped to a smart group of Macs with Cisco Secure Client.
#
# Logging:
#   /private/var/EnterpriseManagement/Logs/CiscoSecureClientDisableAutoUpdate.log
#   and stdout (Jamf policy log). A dry run still writes this log.
#
# Exit codes:
#   0  Success, already configured, dry run, or Cisco client not installed
#   1  Not running as root, or invalid parameter
#   2  One or more AnyConnectLocalPolicy.xml files could not be updated
#      (VPN profile problems are logged as warnings only)
###############################################################################

set -o pipefail

readonly LOG_DIR="/private/var/EnterpriseManagement/Logs"
readonly LOG="${LOG_DIR}/CiscoSecureClientDisableAutoUpdate.log"
readonly POLICY_PATHS=(
    "/opt/cisco/secureclient/AnyConnectLocalPolicy.xml"
    "/opt/cisco/anyconnect/AnyConnectLocalPolicy.xml"
)
readonly VPN_PROFILE_DIRS=(
    "/opt/cisco/secureclient/vpn/profile"
    "/opt/cisco/anyconnect/profile"
)
# launchd labels of the VPN agent daemon (Secure Client 5.x, AnyConnect 4.x).
readonly VPN_AGENT_LABELS=(
    "system/com.cisco.secureclient.vpnagentd"
    "system/com.cisco.anyconnect.vpnagentd"
)

DRY_RUN="false"
RESTART_AGENT="true"
EDIT_PROFILES="false"
POLICY_CHANGED="false"
LAST_RESULT=""

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        /bin/echo "ERROR: This script must run as root." >&2
        exit 1
    fi
}

init_logging() {
    /bin/mkdir -p "${LOG_DIR}"
    /bin/chmod 755 "${LOG_DIR}"
    /usr/bin/touch "${LOG}"
    /bin/chmod 644 "${LOG}"
}

log() {
    local line
    line="$(/bin/date '+%Y-%m-%d %H:%M:%S')  $*"
    /usr/bin/printf '%s\n' "${line}" 2>/dev/null >> "${LOG}"
    /usr/bin/printf '%s\n' "${line}"
}

# Prints "true" or "false" for $1, or the default $2 if $1 is empty.
# Fails on anything else.
parse_bool() {
    local value
    value="$(/usr/bin/printf '%s' "$1" | /usr/bin/tr -d '[:space:]' | /usr/bin/tr '[:upper:]' '[:lower:]')"
    case "${value}" in
        "")          /bin/echo "$2" ;;
        true|yes|1)  /bin/echo "true" ;;
        false|no|0)  /bin/echo "false" ;;
        *)           return 1 ;;
    esac
}

parse_parameters() {
    if ! DRY_RUN="$(parse_bool "${4:-}" false)"; then
        log "ERROR: Invalid dry run value (\$4): \"${4}\". Use true or false."
        exit 1
    fi
    if ! RESTART_AGENT="$(parse_bool "${5:-}" true)"; then
        log "ERROR: Invalid restart value (\$5): \"${5}\". Use true or false."
        exit 1
    fi
    if ! EDIT_PROFILES="$(parse_bool "${6:-}" false)"; then
        log "ERROR: Invalid edit profiles value (\$6): \"${6}\". Use true or false."
        exit 1
    fi
}

# Prints the edited XML of file $2 to stdout. $1 is "policy" or "profile".
# Exit status: 0 = edited content printed (it may equal the original),
# 2 = the change can't be applied safely, 3 = profile has no <AutoUpdate>.
# The file is read and written as bytes; only the targeted elements change.
edit_xml() {
    /usr/bin/perl - "$1" "$2" <<'PERL'
use strict;
use warnings;

my ($kind, $file) = @ARGV;
open(my $in, '<', $file) or die "Cannot read $file: $!\n";
binmode($in);
my $xml = do { local $/; <$in> };
close($in);
my $nl = ($xml =~ /\r\n/) ? "\r\n" : "\n";

if ($kind eq 'policy') {
    # BypassDownloader = true. Replace the element whatever its value (also
    # empty or self-closing). If it's missing, insert it as the first child of
    # the root element, where Cisco's default file has it. A self-closing root
    # element has no place to insert, so that is refused (exit 2).
    if ($xml =~ /<BypassDownloader\b/) {
        my $count = ($xml =~ s{<BypassDownloader\s*/>|<BypassDownloader\s*>[^<]*</BypassDownloader\s*>}
                              {<BypassDownloader>true</BypassDownloader>}g);
        exit 2 unless $count;
    } else {
        $xml =~ s{(<AnyConnectLocalPolicy(?:\s[^>]*)?(?<!/)>)}
                 {$1$nl<BypassDownloader>true</BypassDownloader>}
            or exit 2;
    }
    # AllowSoftwareUpdatesFromAnyServer = false, only where it already exists.
    $xml =~ s{<AllowSoftwareUpdatesFromAnyServer\s*/>|<AllowSoftwareUpdatesFromAnyServer\s*>[^<]*</AllowSoftwareUpdatesFromAnyServer\s*>}
             {<AllowSoftwareUpdatesFromAnyServer>false</AllowSoftwareUpdatesFromAnyServer>}g;
} elsif ($kind eq 'profile') {
    # AutoUpdate = false, keeping attributes such as UserControllable.
    # Never inserted: the profile schema fixes the element order.
    exit 3 unless $xml =~ /<AutoUpdate\b/;
    my $count = ($xml =~ s{(<AutoUpdate\b[^>]*?)\s*/>}{$1>false</AutoUpdate>}g);
    $count += ($xml =~ s{(<AutoUpdate\b[^>]*>)[^<]*(</AutoUpdate\s*>)}{${1}false$2}g);
    exit 2 unless $count;
} else {
    die "Unknown kind: $kind\n";
}

binmode(STDOUT);
print $xml;
exit 0;
PERL
}

# Applies edit_xml to one file. Sets LAST_RESULT to updated, would-update,
# unchanged or skipped. Returns 1 (file left untouched) on any error.
process_file() {
    local kind="$1" file="$2" tmp rc backup line
    LAST_RESULT="error"

    if [[ ! -x /usr/bin/perl || ! -x /usr/bin/xmllint ]]; then
        log "ERROR: /usr/bin/perl and /usr/bin/xmllint are required; ${file} left untouched."
        return 1
    fi
    if ! /usr/bin/xmllint --noout --nonet "${file}" >/dev/null 2>&1; then
        log "ERROR: ${file} is not well-formed XML; left untouched."
        return 1
    fi

    if ! tmp="$(/usr/bin/mktemp /tmp/CiscoDisableAutoUpdate.XXXXXX)"; then
        log "ERROR: Could not create a temporary file; ${file} left untouched."
        return 1
    fi

    edit_xml "${kind}" "${file}" > "${tmp}"
    rc=$?
    if [[ "${rc}" -eq 3 ]]; then
        /bin/rm -f "${tmp}"
        LAST_RESULT="skipped"
        return 0
    elif [[ "${rc}" -ne 0 ]]; then
        /bin/rm -f "${tmp}"
        log "ERROR: No supported element or insertion point in ${file}; left untouched."
        return 1
    fi

    if /usr/bin/cmp -s "${file}" "${tmp}"; then
        /bin/rm -f "${tmp}"
        LAST_RESULT="unchanged"
        return 0
    fi

    if ! /usr/bin/xmllint --noout --nonet "${tmp}" >/dev/null 2>&1; then
        /bin/rm -f "${tmp}"
        log "ERROR: Editing ${file} would produce malformed XML; left untouched."
        return 1
    fi

    log "Changes for ${file}:"
    while IFS= read -r line; do
        log "    ${line}"
    done < <(/usr/bin/diff "${file}" "${tmp}")

    if [[ "${DRY_RUN}" == "true" ]]; then
        /bin/rm -f "${tmp}"
        LAST_RESULT="would-update"
        return 0
    fi

    backup="${file}.bak.$(/bin/date '+%Y%m%d%H%M%S')"
    if ! /bin/cp -p "${file}" "${backup}"; then
        /bin/rm -f "${tmp}"
        log "ERROR: Could not back up ${file}; left untouched."
        return 1
    fi
    log "Backup created: ${backup}"

    # Overwrite in place so the file keeps its owner, group and mode.
    if ! /bin/cat "${tmp}" > "${file}"; then
        log "ERROR: Could not write ${file}; restoring the backup."
        /bin/cp -p "${backup}" "${file}"
        /bin/rm -f "${tmp}"
        return 1
    fi
    /bin/rm -f "${tmp}"
    LAST_RESULT="updated"
    return 0
}

apply_local_policies() {
    local policy_file found="false" status=0

    for policy_file in "${POLICY_PATHS[@]}"; do
        [[ -f "${policy_file}" ]] || continue
        found="true"
        log "Local policy: ${policy_file}"

        if ! process_file policy "${policy_file}"; then
            status=2
            continue
        fi
        case "${LAST_RESULT}" in
            updated)
                log "Updated: BypassDownloader=true (AllowSoftwareUpdatesFromAnyServer=false where present)."
                POLICY_CHANGED="true"
                ;;
            would-update)
                log "DRY RUN: would update ${policy_file}."
                POLICY_CHANGED="true"
                ;;
            unchanged)
                log "Already configured; no change."
                ;;
        esac
    done

    if [[ "${found}" == "false" ]]; then
        log "No AnyConnectLocalPolicy.xml found; Cisco Secure Client / AnyConnect not installed."
    fi
    return "${status}"
}

apply_vpn_profiles() {
    local profile_dir profile_file

    for profile_dir in "${VPN_PROFILE_DIRS[@]}"; do
        [[ -d "${profile_dir}" ]] || continue

        while IFS= read -r -d '' profile_file; do
            log "VPN profile: ${profile_file}"
            if ! process_file profile "${profile_file}"; then
                log "WARNING: ${profile_file} left unchanged."
                continue
            fi
            case "${LAST_RESULT}" in
                updated)      log "Set AutoUpdate=false." ;;
                would-update) log "DRY RUN: would set AutoUpdate=false." ;;
                unchanged)    log "AutoUpdate already false; no change." ;;
                skipped)      log "No <AutoUpdate> element; left unchanged." ;;
            esac
        done < <(/usr/bin/find "${profile_dir}" -maxdepth 1 -type f \( -name '*.xml' -o -name '*.XML' \) -print0 2>/dev/null)
    done
}

stop_vpndownloader() {
    if ! /usr/bin/pgrep -f vpndownloader >/dev/null 2>&1; then
        log "No running vpndownloader process."
        return 0
    fi
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "DRY RUN: would terminate running vpndownloader process(es)."
        return 0
    fi
    log "Terminating running vpndownloader process(es)."
    /usr/bin/pkill -f vpndownloader 2>/dev/null || true
}

# Restarts the first loaded VPN agent daemon. This drops active VPN sessions.
restart_vpn_agent() {
    local label

    for label in "${VPN_AGENT_LABELS[@]}"; do
        /bin/launchctl print "${label}" >/dev/null 2>&1 || continue
        if [[ "${DRY_RUN}" == "true" ]]; then
            log "DRY RUN: would restart ${label} (drops any active VPN session)."
            return 0
        fi
        log "Restarting ${label} to apply the local policy (drops any active VPN session)."
        if /bin/launchctl kickstart -k "${label}" >/dev/null 2>&1; then
            return 0
        fi
        log "WARNING: launchctl kickstart -k ${label} failed."
    done

    log "VPN agent not restarted; the local policy applies after the next reboot."
}

main() {
    local exit_code=0

    require_root
    init_logging
    parse_parameters "$@"

    log "===== Cisco Secure Client auto-update disable (dry run: ${DRY_RUN}, restart agent: ${RESTART_AGENT}, edit profiles: ${EDIT_PROFILES}) ====="

    apply_local_policies || exit_code=$?

    if [[ "${EDIT_PROFILES}" == "true" ]]; then
        apply_vpn_profiles
    else
        log "VPN profiles not modified (\$6 is false)."
    fi

    if [[ "${POLICY_CHANGED}" == "true" ]]; then
        stop_vpndownloader
        if [[ "${RESTART_AGENT}" == "true" ]]; then
            restart_vpn_agent
        else
            log "VPN agent restart disabled (\$5 is false); the local policy applies after the next reboot."
        fi
    fi

    if [[ "${exit_code}" -eq 0 ]]; then
        log "===== Completed ====="
    else
        log "===== Finished with errors ====="
    fi
    exit "${exit_code}"
}

main "$@"
