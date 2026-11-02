#!/bin/bash
###############################################################################
# InstallXcodeCommandLineTools.sh
#
# Installs the Xcode Command Line Tools (CLT) silently through softwareupdate
# when they are missing, and updates a standalone CLT install when Software
# Update offers a newer Command Line Tools package. No GUI, no user prompts.
#
# Behaviour:
#   - Full Xcode is the active developer directory (xcode-select -p is set to
#     something other than /Library/Developer/CommandLineTools): nothing to
#     do. Xcode ships its own command line tools and updates with Xcode.
#   - CLT missing (xcode-select -p returns no existing directory, or the
#     com.apple.pkg.CLTools_Executables receipt is missing): install the
#     newest Command Line Tools label softwareupdate offers. Skipped in
#     "update" mode.
#   - CLT installed: check softwareupdate once for a newer Command Line Tools
#     label and install it if offered. No label is the normal result for an
#     up-to-date Mac, so there is no polling. Skipped in "install" mode.
#   - After installing, the result is verified with "xcode-select -p" and
#     "pkgutil --pkg-info=com.apple.pkg.CLTools_Executables".
#
#   Only labels starting with "Command Line Tools" are considered, so Xcode
#   and macOS updates are never selected. Non-beta labels are preferred, and
#   the highest Xcode version wins.
#
#   To make softwareupdate offer CLT on a Mac that doesn't have it, the script
#   creates the placeholder file
#     /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
#   (used by Apple's on-demand CLT installer) and removes it on exit. This
#   technique is widely documented in the Mac admin community, notably by
#   Rich Trouton (Der Flounder); credit to him and the others who shared it.
#
# Jamf Pro parameters:
#   $4  Mode (default: auto)
#         auto    - install CLT if missing, otherwise update it when a newer
#                   Command Line Tools package is offered
#         install - install CLT if missing; never update an existing install
#         update  - update an existing standalone CLT install; never install
#   $5  Install label wait in seconds (default: 120, range 0-1800)
#         How long to keep retrying softwareupdate for a Command Line Tools
#         label when installing. 0 checks once. Update checks always run once.
#
# Requirements:
#   macOS 10.14 or later. Runs as root (Jamf policy scripts do). Needs access
#   to Apple's software update servers (or a content caching server).
#
# Jamf Pro suggestion:
#   One policy, mode "auto", Recurring Check-in, Ongoing or once a week.
#   Or separate policies: "install" at enrollment, "update" weekly.
#
# Logging:
#   /private/var/EnterpriseManagement/Logs/XcodeCommandLineTools.log and
#   stderr (Jamf records both in the policy log). softwareupdate's own output
#   goes to the log file only.
#
# Exit codes:
#   0  Installed or updated; already installed or current; full Xcode active;
#      or nothing to do for the selected mode
#   1  Not running as root, or invalid parameter
#   2  softwareupdate offered no Command Line Tools label to install
#   3  softwareupdate failed to install the label
#   4  Post-install verification failed
###############################################################################

set -o pipefail

readonly CLT_PATH="/Library/Developer/CommandLineTools"
readonly CLT_PKG_ID="com.apple.pkg.CLTools_Executables"
readonly PLACEHOLDER="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
readonly LOG_DIR="/private/var/EnterpriseManagement/Logs"
readonly LOG="${LOG_DIR}/XcodeCommandLineTools.log"
readonly DEFAULT_LABEL_WAIT=120
readonly MAX_LABEL_WAIT=1800
readonly POLL_INTERVAL=15

MODE=""
LABEL_WAIT=""

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

# Writes to the log file and stderr, never stdout. Several functions return a
# value on stdout through command substitution; log lines must not end up in
# those values.
log() {
    local line
    line="$(/bin/date '+%Y-%m-%d %H:%M:%S')  $*"
    /usr/bin/printf '%s\n' "${line}" 2>/dev/null >> "${LOG}"
    /usr/bin/printf '%s\n' "${line}" >&2
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    /usr/bin/printf '%s' "${value}"
}

parse_parameters() {
    local raw_mode raw_wait

    raw_mode="$(trim "${4:-}")"
    MODE="$(/usr/bin/printf '%s' "${raw_mode}" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    if [[ -z "${MODE}" ]]; then
        MODE="auto"
    fi
    case "${MODE}" in
        auto|install|update) ;;
        *)
            log "ERROR: Invalid mode (\$4): \"${raw_mode}\". Use auto, install or update."
            exit 1
            ;;
    esac

    raw_wait="$(trim "${5:-}")"
    if [[ -z "${raw_wait}" ]]; then
        raw_wait="${DEFAULT_LABEL_WAIT}"
    fi
    if [[ ! "${raw_wait}" =~ ^[0-9]{1,4}$ ]] || (( 10#${raw_wait} > MAX_LABEL_WAIT )); then
        log "ERROR: Invalid install label wait (\$5): \"${raw_wait}\". Use 0-${MAX_LABEL_WAIT} seconds."
        exit 1
    fi
    LABEL_WAIT=$(( 10#${raw_wait} ))
}

# Prints the active developer directory without a trailing slash, or nothing
# if none is set or it no longer exists. "xcode-select -p" is safe to call
# without CLT; it doesn't trigger the install prompt.
active_developer_dir() {
    local dir
    dir="$(/usr/bin/xcode-select -p 2>/dev/null)" || return 0
    dir="${dir%/}"
    if [[ -n "${dir}" && -d "${dir}" ]]; then
        /bin/echo "${dir}"
    fi
    return 0
}

# Prints the full CLTools_Executables package version (e.g.
# 16.2.0.0.1.1733547573). Fails if the receipt is missing.
installed_clt_version() {
    local version
    version="$(/usr/sbin/pkgutil --pkg-info="${CLT_PKG_ID}" 2>/dev/null \
        | /usr/bin/awk '/^version:/ {print $2; exit}')"
    [[ -n "${version}" ]] || return 1
    /bin/echo "${version}"
}

# Succeeds if dotted version $1 is newer than $2. Only as many components as
# $1 has are compared, so "16.2" is not newer than "16.2.0.0.1.1733547573".
# Pure bash, so it doesn't rely on "sort -V".
version_gt() {
    local a="$1" b="$2" a_part b_part
    while [[ -n "${a}" ]]; do
        a_part="${a%%.*}"
        b_part="${b%%.*}"
        if [[ "${a}" == *.* ]]; then a="${a#*.}"; else a=""; fi
        if [[ "${b}" == *.* ]]; then b="${b#*.}"; else b=""; fi
        [[ "${a_part}" =~ ^[0-9]+$ ]] || a_part=0
        [[ "${b_part}" =~ ^[0-9]+$ ]] || b_part=0
        if (( 10#${a_part} > 10#${b_part} )); then return 0; fi
        if (( 10#${a_part} < 10#${b_part} )); then return 1; fi
    done
    return 1
}

# Prints the Xcode version a CLT label refers to, e.g. "16.2" for
# "Command Line Tools for Xcode-16.2". Prints nothing if there is none.
version_from_label() {
    local re_xcode='for Xcode[- ]([0-9]+(\.[0-9]+)*)'
    local re_tail='-([0-9]+(\.[0-9]+)*)$'
    if [[ "$1" =~ ${re_xcode} || "$1" =~ ${re_tail} ]]; then
        /bin/echo "${BASH_REMATCH[1]}"
    fi
}

# Prints one Command Line Tools label per line from "softwareupdate -l"
# output. Two formats exist:
#   macOS 10.15+: "* Label: Command Line Tools for Xcode-16.2"
#   macOS 10.14:  "   * Command Line Tools (macOS Mojave version 10.14) for Xcode-10.3"
collect_clt_labels() {
    local line label
    local re_modern='^[[:space:]]*\*[[:space:]]*Label:[[:space:]]*(Command Line Tools.*)$'
    local re_legacy='^[[:space:]]*\*[[:space:]]*(Command Line Tools.*)$'

    while IFS= read -r line; do
        if [[ "${line}" =~ ${re_modern} || "${line}" =~ ${re_legacy} ]]; then
            label="${BASH_REMATCH[1]}"
            label="${label%"${label##*[![:space:]]}"}"
            if [[ -n "${label}" ]]; then
                /bin/echo "${label}"
            fi
        fi
    done <<< "$1"
    return 0
}

# Picks the label to install from $1 (CLT labels, one per line):
#   1. If some labels name the running macOS ("... version 10.14) ...", the
#      10.14-style format), only those are considered. Modern labels carry
#      only the Xcode version, which is never compared with the macOS version.
#   2. Non-beta labels are preferred.
#   3. The highest Xcode version wins.
select_clt_label() {
    local labels="$1" os_minor="$2" subset label version best="" best_version=""

    subset="$(/bin/echo "${labels}" | /usr/bin/grep -F "version ${os_minor})")"
    if [[ -n "${subset}" ]]; then
        labels="${subset}"
    fi

    subset="$(/bin/echo "${labels}" | /usr/bin/grep -Fiv "beta")"
    if [[ -n "${subset}" ]]; then
        labels="${subset}"
    fi

    while IFS= read -r label; do
        [[ -n "${label}" ]] || continue
        version="$(version_from_label "${label}")"
        if [[ -z "${best}" ]] || { [[ -n "${version}" ]] && version_gt "${version}" "${best_version:-0}"; }; then
            best="${label}"
            best_version="${version}"
        fi
    done <<< "${labels}"

    [[ -n "${best}" ]] || return 1
    /bin/echo "${best}"
}

# Runs "softwareupdate -l" once and prints the selected CLT label.
# Fails if no Command Line Tools label is offered.
find_clt_label() {
    local os_minor="$1" listing labels label

    listing="$(/usr/sbin/softwareupdate -l 2>/dev/null)"
    labels="$(collect_clt_labels "${listing}")"
    [[ -n "${labels}" ]] || return 1

    while IFS= read -r label; do
        log "Offered: ${label}"
    done <<< "${labels}"

    select_clt_label "${labels}" "${os_minor}"
}

# Install mode only: retries find_clt_label for up to $2 seconds, because the
# label can take a moment to appear after the placeholder is created.
wait_for_clt_label() {
    local os_minor="$1" wait="$2" start="${SECONDS}" attempt=1

    while true; do
        if find_clt_label "${os_minor}"; then
            return 0
        fi
        if (( SECONDS - start + POLL_INTERVAL > wait )); then
            return 1
        fi
        log "No Command Line Tools label yet (attempt ${attempt}, $(( SECONDS - start ))s elapsed); retrying in ${POLL_INTERVAL}s."
        /bin/sleep "${POLL_INTERVAL}"
        attempt=$(( attempt + 1 ))
    done
}

install_label() {
    local label="$1"

    log "Running: softwareupdate -i \"${label}\" --verbose (output in ${LOG})"
    if ! /usr/sbin/softwareupdate -i "${label}" --verbose >> "${LOG}" 2>&1; then
        log "ERROR: softwareupdate failed to install \"${label}\"."
        return 1
    fi
    return 0
}

# Verifies CLT with "xcode-select -p" and pkgutil, and prints the installed
# package version. If xcode-select has no valid path but CLT is on disk (for
# example it still points at a deleted Xcode.app), it is pointed at CLT first.
verify_clt() {
    local dev_dir version

    dev_dir="$(active_developer_dir)"
    if [[ -z "${dev_dir}" && -d "${CLT_PATH}" ]]; then
        log "xcode-select has no valid developer directory; switching it to ${CLT_PATH}."
        /usr/bin/xcode-select --switch "${CLT_PATH}" >> "${LOG}" 2>&1
        dev_dir="$(active_developer_dir)"
    fi
    if [[ -z "${dev_dir}" ]]; then
        log "ERROR: Verification failed: xcode-select -p returns no valid developer directory."
        return 1
    fi
    if ! version="$(installed_clt_version)"; then
        log "ERROR: Verification failed: pkgutil has no receipt for ${CLT_PKG_ID}."
        return 1
    fi
    log "Verified: xcode-select -p is ${dev_dir}; ${CLT_PKG_ID} version ${version}."
    /bin/echo "${version}"
}

# Invoked through "trap ... EXIT" in install_clt.
# shellcheck disable=SC2329
cleanup_placeholder() {
    /bin/rm -f "${PLACEHOLDER}"
}

install_clt() {
    local os_minor="$1" label version

    /usr/bin/touch "${PLACEHOLDER}"
    trap cleanup_placeholder EXIT

    log "Looking for a Command Line Tools label (retrying for up to ${LABEL_WAIT}s)..."
    if ! label="$(wait_for_clt_label "${os_minor}" "${LABEL_WAIT}")"; then
        log "ERROR: softwareupdate offered no Command Line Tools label."
        log "  Check access to Apple's software update servers (or your caching server)."
        exit 2
    fi
    log "Selected label: \"${label}\""

    install_label "${label}" || exit 3
    version="$(verify_clt)" || exit 4
    log "Command Line Tools ${version} installed."
}

update_clt() {
    local os_minor="$1" installed="$2" label available version

    # softwareupdate lists CLT updates for an installed CLT without the
    # placeholder, and no label just means CLT is current: check once.
    log "Checking softwareupdate once for a newer Command Line Tools package..."
    if ! label="$(find_clt_label "${os_minor}")"; then
        log "No Command Line Tools update offered; ${installed} is current."
        return 0
    fi

    available="$(version_from_label "${label}")"
    if [[ -z "${available}" ]]; then
        log "WARNING: No version found in \"${label}\"; installing it because softwareupdate offers it."
    elif ! version_gt "${available}" "${installed}"; then
        log "Offered \"${label}\" is not newer than ${installed}; nothing to do."
        return 0
    fi
    log "Updating Command Line Tools ${installed} with \"${label}\"."

    install_label "${label}" || exit 3
    version="$(verify_clt)" || exit 4
    if [[ -n "${available}" ]] && version_gt "${available}" "${version}"; then
        log "ERROR: Verification failed: ${CLT_PKG_ID} is still ${version}, expected ${available}."
        exit 4
    fi
    log "Command Line Tools updated to ${version}."
}

main() {
    local product_version os_major os_minor dev_dir installed

    require_root
    init_logging
    parse_parameters "$@"

    product_version="$(/usr/bin/sw_vers -productVersion)"
    IFS=. read -r os_major os_minor _ <<< "${product_version}"
    os_minor="${os_major}.${os_minor:-0}"
    log "===== Xcode Command Line Tools (mode: ${MODE}) on macOS ${product_version} ====="

    dev_dir="$(active_developer_dir)"
    if [[ -n "${dev_dir}" && "${dev_dir}" != "${CLT_PATH}" ]]; then
        log "Active developer directory is ${dev_dir} (full Xcode)."
        log "Xcode provides its own command line tools and updates with Xcode; nothing to do."
        exit 0
    fi

    if [[ "${dev_dir}" == "${CLT_PATH}" ]] && installed="$(installed_clt_version)"; then
        log "Command Line Tools ${installed} installed at ${CLT_PATH}."
        if [[ "${MODE}" == "install" ]]; then
            log "Mode is install; not checking for updates."
            exit 0
        fi
        update_clt "${os_minor}" "${installed}"
    else
        if [[ "${dev_dir}" == "${CLT_PATH}" ]]; then
            log "${CLT_PATH} exists but ${CLT_PKG_ID} has no receipt; treating CLT as not installed."
        else
            log "Command Line Tools not installed (xcode-select -p returns no valid directory)."
        fi
        if [[ "${MODE}" == "update" ]]; then
            log "Mode is update; not installing."
            exit 0
        fi
        install_clt "${os_minor}"
    fi

    log "===== Finished ====="
    exit 0
}

main "$@"
