#!/bin/bash
#
# Uninstall-AllJava.sh - macOS
#
# SYNOPSIS
#   Detects and silently removes LICENSED ORACLE JAVA (proprietary Oracle/Sun JDK / JRE) from macOS for licence
#   compliance. OpenJDK and every open-source distribution are always kept - they are the intended replacements.
#   Built for Jamf Pro (policy script AND Extension Attribute in one file) and also works from an admin shell with
#   sudo. macOS port of Remove-AllJava.ps1.
#
# SCOPE (fixed: licensed Oracle only - there is no setting that widens it)
#   Removes proprietary Oracle/Sun distributions, including no-fee (NFTC) Oracle JDK builds. Never removes OpenJDK:
#   Temurin / AdoptOpenJDK, Zulu, Corretto, Microsoft, Liberica, SapMachine, Semeru, Red Hat, Dragonwell, GraalVM
#   (CE and Oracle GraalVM), Homebrew openjdk, Oracle's own GPL builds from jdk.java.net, or any other vendor.
#   This removal policy does not establish subscription liability.
#
#   Oracle's own free OpenJDK builds (jdk.java.net, IntelliJ "Oracle OpenJDK", SDKMAN "-open") report
#   IMPLEMENTOR="Oracle Corporation" exactly like the licensed JDK, so vendor alone cannot tell them apart. An
#   Oracle-vendor install is therefore targeted only when there is positive evidence:
#     * its license text is Oracle's commercial / OTN / NFTC licence, or its release file says BUILD_TYPE=commercial;
#     * its bundle identifier is com.oracle.java.* or its bundle name is "Java SE ..." (Oracle's .pkg installers);
#     * an Oracle .pkg receipt (com.oracle.jdk* / com.oracle.jre) installed it;
#     * its folder uses the legacy Sun/Oracle name jre1.x / jdk1.x / j2sdk / j2re (Java 8 and earlier);
#     * a version-manager folder names Oracle (SDKMAN "21.0.2-oracle", asdf/mise "oracle-21.0.2");
#     * it is the Oracle Java browser plug-in (JavaAppletPlugin.plugin) or a Homebrew oracle-jdk cask.
#   Positive GPL (Classpath Exception) licence evidence always wins and the build is kept. Oracle-vendor copies whose
#   distribution cannot be established are kept and flagged for manual review. Every other vendor is kept. Oracle
#   GraalVM is classified as vendor "GraalVM" (as on Windows) and is kept.
#   The same rule is checked again immediately before anything is deleted, receipt-forgotten or unregistered.
#
# DETECTION (read-only)
#   * /Library/Java/JavaVirtualMachines/*            (system JDK bundles, incl. partially removed remnants)
#   * /Library/Internet Plug-Ins[ (Disabled)]/JavaAppletPlugin.plugin   (Oracle JRE 7/8 browser plug-in)
#   * Installer receipts (pkgutil) for Java vendors; mapped to the bundle they installed. Orphans are found too.
#   * Homebrew casks (oracle-jdk, oracle-jdk@NN, java8; other vendors' JDK casks are listed and kept) in
#     /opt/homebrew and /usr/local.
#   * Per user (unless SkipUserProfiles): ~/Library/Java/JavaVirtualMachines (IntelliJ on macOS), ~/.jdks,
#     ~/.gradle/jdks, ~/.jbang/cache/jdks, ~/.sdkman/candidates/java, ~/.asdf/installs/java,
#     ~/.local/share/mise/installs/java, ~/.jabba/jdk.
#   * Loose copies with Java-like names in /opt, /opt/java, /usr/local, /usr/local/java, /Library/Java, /Applications.
#   * Optional (ScanEmbedded): runtimes bundled inside apps in /Applications and /Library/Application Support,
#     reported as "Unmanaged" (never removed automatically).
#
# REMOVAL
#   1. Stops processes running from the Java homes being removed (unless NoKill).
#   2. Deletes the JDK bundles / plug-in / folders in scope.
#   3. Forgets the matching pkg receipts (pkgutil --forget) once their files are gone.
#   4. Removes the matching Homebrew cask registration (Caskroom) so `brew upgrade` does not reinstall it.
#   5. Cleans Oracle leftovers once no licensed Oracle Java remains: Java Control Panel prefpane, Java Updater
#      LaunchAgent / Helper-Tool LaunchDaemon (booted out first), PrivilegedHelperTool, /Library/Application Support/
#      Oracle/Java, per-user Oracle Java deployment caches and com.oracle.java* preferences, and /Library/Java/Home
#      if it is a dead link to Oracle Java. Nothing that belongs to an OpenJDK distribution is touched.
#      Shell start-up files that still reference a removed Java are reported (never edited).
#   6. Scans again and reports anything that is still present.
#
# SAFETY
#   * Only licensed Oracle Java is ever removed (see SCOPE); that applies to AdditionalPath too.
#   * Runtimes bundled inside other applications are never removed automatically (use AdditionalPath).
#   * Symbolic links are never followed or deleted as Java homes; a path whose parent directories contain a symlink
#     is refused. Protected locations (/, /System, /Library, /Applications, user home roots, discovery roots, ...)
#     can never be deleted.
#   * Anything inside a directory owned by a standard user is deleted AS THAT USER (sudo -u), so a user cannot
#     redirect a root delete with a symlink swap.
#   * A receipt, cask and bundle that belong to the same Java are kept together; a folder that contains a kept Java
#     is never deleted.
#   * Detect, WhatIf and EA modes change nothing (Detect/WhatIf only write this script's log and JSON report).
#   * The script never restarts the computer.
#
# JAMF PRO
#   Policy script - parameters (all optional; leave blank for the default):
#     $4  Mode             Remove (default) | Detect | WhatIf
#     $5  (not used)       Leave blank. Formerly Vendor; the scope is now fixed to licensed Oracle Java. Any value
#                          other than blank or "Oracle" stops the script with exit code 2.
#     $6  KeepMajorVersion Oracle Java major versions to keep, e.g. 17,21 (1.8 / 8u counts as 8)
#     $7  Exclude          Extended regular expression (case-insensitive) matched against
#                          "name | version | path | vendor"; matching items are kept. Example: jdk-21|Corretto
#     $8  AdditionalPath   Extra places to look for Oracle Java (comma / semicolon separated, globs allowed). Each
#                          must be a Java home / .jdk bundle or contain them within two levels. Only the licensed
#                          Oracle Java found there is removed; Keep and Exclude apply as usual.
#     $9  Options          Comma list: SkipUserProfiles, SkipLeftoverCleanup, ScanEmbedded, NoKill, Recon
#     $10 LogDirectory     Default /Library/Logs/JavaRemoval
#   Extension Attribute - upload this same file as an EA script (Data type: String). Jamf runs EA scripts with NO
#     arguments; in that case the script performs a read-only scan and prints only
#     <result>None</result> or <result>Found (N): ...</result> (licensed Oracle Java only).
#     Smart Group example: "Oracle Java" like "Found".
#     A standalone, read-only EA is also provided: OracleJava-ExtensionAttribute.sh. It uses the same detection
#     code, is fixed to licensed Oracle Java only (never OpenJDK or other vendors), and has editable Keep / Exclude /
#     SkipUserProfiles settings to keep in step with $6/$7/$9.
#
# COMMAND LINE
#   sudo ./Uninstall-AllJava.sh --detect
#   sudo ./Uninstall-AllJava.sh --whatif
#   sudo ./Uninstall-AllJava.sh --remove [--keep-major 17,21] [--exclude 'jdk-21']
#        [--additional-path '/Users/Shared/tools/jdk-11.jdk'] [--skip-user-profiles]
#        [--skip-leftover-cleanup] [--scan-embedded] [--no-kill] [--recon] [--log-dir DIR]
#   ./Uninstall-AllJava.sh            (no arguments) = Extension Attribute output
#
# EXIT CODES
#   0  Success: no licensed Oracle Java was found, or all of it was removed (always 0 in EA mode).
#   1  Detect: licensed Oracle Java was found.  Remove: one or more items could not be removed (see the log).
#   2  Invalid parameters, another instance already running, or a logging/configuration problem.
#   5  Not running as root (Remove and WhatIf require root; Detect does not).
#
# KNOWN LIMITATIONS
#   * Homebrew formulae (brew install openjdk) are not scanned; they are OpenJDK and always kept.
#   * TCC-protected folders (~/Desktop, ~/Documents, ~/Downloads) are not scanned. Use AdditionalPath (and grant the
#     Jamf binary Full Disk Access via PPPC) for copies stored there.
#   * A deployment tool that still has Java scoped (another Jamf policy, Self Service, Munki, brew) may reinstall it.
#
# Version 1.1.0

SCRIPT_VERSION="1.1.0"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec"
export PATH
umask 022
shopt -s nullglob

#----------------------------------------------------------------------------------------------- Settings (defaults)
MODE="remove"                 # remove | detect | whatif | ea
VENDOR_ARG=""                 # Jamf $5 (retired): only blank / Oracle accepted
KEEP_ARG=""
EXCLUDE_RE=""
ADDITIONAL_ARG=""
SKIP_USER_PROFILES=0
SKIP_LEFTOVER=0
SCAN_EMBEDDED=0
NO_KILL=0
RUN_RECON=0
LOG_DIR_ARG=""
DEFAULT_LOG_DIR="/Library/Logs/JavaRemoval"
LOCK_DIR="/private/var/run/JavaRemoval.lock"
KILL_TIMEOUT=10
LOG_RETENTION_DAYS=30

#----------------------------------------------------------------------------------------------- State
LOG_FILE=""
LOG_DIR=""
JSON_FILE=""
QUIET=0
MY_UID=$(/usr/bin/id -u)
IS_ROOT=0; [[ $MY_UID -eq 0 ]] && IS_ROOT=1
CHANGE_COUNT=0
HAVE_LOCK=0
REMOVED_PATHS=()
KEEP_MAJORS=()
ADDITIONAL_PATHS=()
USER_NAMES=(); USER_UIDS=(); USER_HOMES=()
USERS_LOADED=0
PROTECTED_EXTRA=()
RC_ID=(); RC_PATH=()
VERIFYING=0

#----------------------------------------------------------------------------------------------- Patterns (ERE)
# License text: every OpenJDK build (incl. Oracle's jdk.java.net builds) ships GPLv2 + Classpath Exception; Oracle
# JDK/JRE ship Oracle's commercial terms (BCL, OTN, NFTC). GPL evidence is tested first and wins.
RX_GPL="GNU GENERAL PUBLIC LICENSE|General Public License, version 2|GPLv2|GPL,? version 2|Classpath[[:space:]\"']*exception"
RX_COMMERCIAL='Oracle Free Use Terms|No[- ]Fee Terms|Technology Network License Agreement|Oracle Binary Code License|Early Adopter Development License|Commercial Features|OTN License|java\.com/(otn)?license'
# Legacy Sun/Oracle home names (Java 8 and earlier).
RX_LEGACY_ORACLE_LEAF='^(jre|jdk|j2re|j2sdk)1\.[0-9]'
# Version-manager folder names that say Oracle JDK (SDKMAN 21.0.2-oracle, asdf / mise oracle-21.0.2).
RX_TOOL_ORACLE_LEAF='(^|[-_.])oracle([-_.]|$)'
# Folder names of Java homes for the generic (loose) locations.
RX_JAVAISH_LEAF='^((j2re|j2sdk|jre|jdk|openjdk|zulu|corretto|amazon-corretto|liberica|libericajdk|semeru|sapmachine|graalvm|temurin|adoptopenjdk|dragonwell|microsoft-jdk|ojdkbuild|kona|bisheng)([-_.]?[0-9]|[-_.](ce|ee|jdk|jre|openj9|hotspot)([^a-z]|$)|$)|javafx[-_.]?([0-9]|sdk|runtime))'
# Installer receipts that may belong to a Java distribution (confirmed by the files they installed).
RX_JAVA_RECEIPT='^(com\.oracle\.(jdk|jre|java)|net\.temurin|net\.adoptopenjdk|com\.azul|com\.amazon\.corretto|com\.microsoft\.(openjdk|jdk)|com\.bellsoft|com\.sap\.|com\.ibm\.semeru|org\.graalvm|com\.oracle\.graalvm|com\.redhat\.|com\.alibaba\.)'
RX_ORACLE_RECEIPT='^com\.oracle\.(jdk|jre)'
# Homebrew casks that install a JDK (oracle-jdk-javadoc and the formula "openjdk" are deliberately not matched).
RX_JAVA_CASK='^(oracle-jdk(@[0-9]+)?|java8|temurin(@[0-9]+)?|adoptopenjdk[0-9]*|zulu(@[0-9]+)?|corretto(@[0-9]+)?|microsoft-openjdk(@[0-9]+)?|liberica-jdk[0-9]*(-full)?(-lts)?|sapmachine(-jdk)?(@[0-9]+)?|semeru-jdk-open(@[0-9]+)?|graalvm-jdk(@[0-9]+)?|graalvm-ce-java[0-9]*|dragonwell[0-9]*)$'
RX_ORACLE_CASK='^(oracle-jdk(@[0-9]+)?|java8)$'

#=============================================================================================== Logging
log() {   # log MESSAGE [LEVEL]   LEVEL: INFO WARN ERROR ACTION OK DETAIL
    local msg="$1" level="${2:-INFO}" line
    line="$(/bin/date '+%Y-%m-%d %H:%M:%S') [$(printf '%-6s' "$level")] $msg"
    [[ $QUIET -eq 1 ]] || printf '%s\n' "$line"
    [[ -n $LOG_FILE ]] && printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null
    return 0
}

# Uses a log directory only when it is safe: not a symlink and (as root) owned by root and not writable by others.
secure_log_dir() {
    local d="$1" parent owner
    [[ -n $d && $d == /* ]] || return 1
    d="${d%/}"
    parent=$(/usr/bin/dirname "$d")
    [[ -d $parent && ! -L $parent ]] || return 1
    if [[ -L $d ]]; then return 1; fi
    if [[ ! -d $d ]]; then { /bin/mkdir -p "$d" && /bin/chmod 755 "$d"; } 2>/dev/null || return 1; fi
    [[ -L $d ]] && return 1
    if [[ $IS_ROOT -eq 1 ]]; then
        owner=$(/usr/bin/stat -f %u "$d" 2>/dev/null)
        [[ $owner == 0 ]] || return 1
        /usr/sbin/chown root:wheel "$d" 2>/dev/null
        /bin/chmod 755 "$d" 2>/dev/null || return 1
    fi
    [[ -w $d ]] || return 1
    LOG_DIR="$d"
    return 0
}

init_logging() {
    local stamp host d
    stamp=$(/bin/date '+%Y%m%d-%H%M%S')
    host=$(/bin/hostname -s 2>/dev/null); [[ -z $host ]] && host="mac"
    for d in "${LOG_DIR_ARG:-$DEFAULT_LOG_DIR}" "/private/var/log/JavaRemoval"; do
        secure_log_dir "$d" && break
    done
    if [[ -z $LOG_DIR && $IS_ROOT -eq 0 ]]; then
        secure_log_dir "${TMPDIR:-/private/tmp}/JavaRemoval"
    fi
    [[ -z $LOG_DIR ]] && return 1
    [[ -e $LOG_DIR/JavaRemoval-$host-$stamp.log || -L $LOG_DIR/JavaRemoval-$host-$stamp.log ]] && stamp="$stamp-$$"
    LOG_FILE="$LOG_DIR/JavaRemoval-$host-$stamp.log"
    JSON_FILE="$LOG_DIR/JavaRemoval-$host-$stamp.json"
    if [[ -e $LOG_FILE || -L $LOG_FILE ]]; then LOG_FILE=""; JSON_FILE=""; return 1; fi
    : > "$LOG_FILE" 2>/dev/null || { LOG_FILE=""; JSON_FILE=""; return 1; }
    /bin/chmod 644 "$LOG_FILE" 2>/dev/null
    return 0
}

purge_old_logs() {
    [[ -n $LOG_DIR ]] || return 0
    /usr/bin/find "$LOG_DIR" -maxdepth 1 -type f \( -name 'JavaRemoval-*.log' -o -name 'JavaRemoval-*.json' \) \
        -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
}

#=============================================================================================== Generic helpers
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
lower() { printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]'; }

# Case-insensitive ERE match. BASH_REMATCH is set for the caller.
imatch() {
    local rc
    shopt -s nocasematch
    [[ $1 =~ $2 ]]; rc=$?
    shopt -u nocasematch
    return $rc
}

# One trimmed, non-empty value per line; separators: comma, semicolon, newline.
split_list() {
    local tok
    # shellcheck disable=SC2020  # deliberate: both ',' and ';' become a newline
    printf '%s\n' "$@" | /usr/bin/tr ',;' '\n\n' | while IFS= read -r tok; do
        tok=$(trim "$tok")
        [[ -n $tok ]] && printf '%s\n' "$tok"
    done
}

in_list() { local v="$1" x; shift; for x in "$@"; do [[ $x == "$v" ]] && return 0; done; return 1; }

path_under() {   # path_under CHILD PARENT : CHILD equals PARENT or is inside it
    local c="${1%/}" p="${2%/}"
    [[ -n $c && -n $p ]] || return 1
    [[ $c == "$p" || $c == "$p"/* ]]
}

# Physical path (no symlinks in any parent) of an existing or non-existing leaf; empty if the parent is unreachable.
physical_path() {
    local p="${1%/}" dir base
    dir=$(/usr/bin/dirname -- "$p"); base=$(/usr/bin/basename -- "$p")
    dir=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || return 1
    [[ $dir == / ]] && dir=""
    printf '%s/%s' "$dir" "$base"
}

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

release_get() {   # release_get HOME KEY
    local f="$1/release" sz
    [[ -f $f ]] || return 0
    sz=$(/usr/bin/stat -f %z "$f" 2>/dev/null); [[ -n $sz && $sz -lt 200000 ]] || return 0
    /usr/bin/sed -n "s/^$2=//p" "$f" 2>/dev/null | /usr/bin/head -n 1 | /usr/bin/tr -d '"\r'
}

version_from_text() { [[ $1 =~ ([0-9]+([._][0-9]+)*) ]] && printf '%s' "${BASH_REMATCH[1]}"; }

get_major() {   # get_major VERSION NAME
    local v n m=""
    v=$(trim "$1"); n="$2"
    if [[ $v =~ ^1\.([0-9]{1,2})([^0-9]|$) ]]; then m="${BASH_REMATCH[1]}"
    elif [[ $v =~ ^([0-9]{1,2})([^0-9]|$) ]]; then m="${BASH_REMATCH[1]}"
    fi
    if [[ -z $m && -n $n ]]; then
        n=$(printf '%s' "$n" | /usr/bin/sed -E 's/(x86_64|x64|x86|amd64|arm64|aarch64|64-bit|32-bit)//g')
        if [[ $n =~ (^|[^0-9.])1\.([0-9]{1,2})[._] ]]; then m="${BASH_REMATCH[2]}"
        elif [[ $n =~ (^|[^0-9.])([0-9]{1,2})([^0-9]|$) ]]; then m="${BASH_REMATCH[2]}"
        fi
    fi
    [[ -n $m ]] || return 0
    m=$((10#$m))
    [[ $m -ge 1 ]] && printf '%s' "$m"
}

# Returns the first vendor recognised in the given texts (most reliable text first).
get_vendor() {
    local t
    for t in "$@"; do
        [[ -z $t ]] && continue
        if   imatch "$t" 'Temurin|Adoptium|AdoptOpenJDK|Eclipse Foundation'; then echo Adoptium; return
        elif imatch "$t" 'GraalVM'; then echo GraalVM; return
        elif imatch "$t" 'Zulu|Azul'; then echo Azul; return
        elif imatch "$t" 'Corretto|Amazon'; then echo Amazon; return
        elif imatch "$t" 'Liberica|BellSoft'; then echo BellSoft; return
        elif imatch "$t" 'Semeru|(^|[^a-z])IBM([^a-z]|$)|International Business Machines'; then echo IBM; return
        elif imatch "$t" 'SapMachine|(^|[^a-z])SAP([^a-z]|$)'; then echo SAP; return
        elif imatch "$t" 'Red ?Hat'; then echo RedHat; return
        elif imatch "$t" 'Dragonwell|Alibaba'; then echo Alibaba; return
        elif imatch "$t" 'OpenLogic|Perforce'; then echo OpenLogic; return
        elif imatch "$t" 'Kona|Tencent'; then echo Tencent; return
        elif imatch "$t" 'BiSheng|Huawei'; then echo Huawei; return
        elif imatch "$t" 'Microsoft'; then echo Microsoft; return
        elif imatch "$t" 'Oracle|Sun Microsystems|^Java([^a-z]|$)|^J2(SE|RE|SDK)|JavaFX'; then echo Oracle; return
        fi
    done
    echo Other
}

normalize_vendor() {
    case "$(lower "$1" | /usr/bin/tr -d ' _-')" in
        oracle|sun)                               echo Oracle ;;
        adoptium|temurin|adoptopenjdk|eclipse)    echo Adoptium ;;
        azul|zulu)                                echo Azul ;;
        amazon|corretto)                          echo Amazon ;;
        microsoft)                                echo Microsoft ;;
        bellsoft|liberica)                        echo BellSoft ;;
        ibm|semeru)                               echo IBM ;;
        sap|sapmachine)                           echo SAP ;;
        redhat)                                   echo RedHat ;;
        graalvm|graal)                            echo GraalVM ;;
        alibaba|dragonwell)                       echo Alibaba ;;
        openlogic)                                echo OpenLogic ;;
        tencent|kona)                             echo Tencent ;;
        huawei|bisheng)                           echo Huawei ;;
        other)                                    echo Other ;;
        all|everything|any)                       echo All ;;
        *)                                        return 1 ;;
    esac
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

#=============================================================================================== Users / protection
load_users() {
    [[ $USERS_LOADED -eq 1 ]] && return 0
    USERS_LOADED=1
    local name uid home
    while read -r name uid; do
        [[ -z $name || $name == _* ]] && continue
        [[ $uid =~ ^[0-9]+$ ]] || continue
        [[ $uid -ge 500 && $uid -lt 2147483647 ]] || continue
        home=$(/usr/bin/dscl . -read "/Users/$name" NFSHomeDirectory 2>/dev/null | /usr/bin/tr '\n' ' ' \
            | /usr/bin/sed -E 's/^NFSHomeDirectory:[[:space:]]*//; s/[[:space:]]+$//')
        [[ -n $home && $home == /* && $home != /var/empty && -d $home && ! -L $home ]] || continue
        home=$(cd -P -- "$home" 2>/dev/null && pwd -P) || continue
        [[ $home == / ]] && continue
        USER_NAMES+=("$name"); USER_UIDS+=("$uid"); USER_HOMES+=("$home")
    done < <(/usr/bin/dscl . -list /Users UniqueID 2>/dev/null)
}

is_protected() {
    local p="${1%/}" h x
    [[ -z $p || $p != /* ]] && return 0
    case "$p" in
        /|/System|/System/*|/bin|/bin/*|/sbin|/sbin/*|/private|/private/var|/private/etc|/private/tmp|/var|/etc|/tmp|\
        /dev|/dev/*|/Volumes|/Users|/Users/Shared|/Applications|/Applications/Utilities|/Library|/Library/Java|\
        /Library/Java/JavaVirtualMachines|/Library/Java/Extensions|"/Library/Internet Plug-Ins"|\
        "/Library/Internet Plug-Ins (Disabled)"|/Library/PreferencePanes|"/Library/Application Support"|\
        /Library/LaunchAgents|/Library/LaunchDaemons|/Library/PrivilegedHelperTools|/Library/Preferences|\
        /opt|/opt/java|/opt/homebrew|/opt/homebrew/Caskroom|/usr/local|/usr/local/java|/usr/local/Caskroom|\
        /cores|/Network|/Network/*|/Library/Logs)
            return 0 ;;
        /usr|/usr/*)
            [[ $p == /usr/local/* ]] || return 0 ;;
    esac
    [[ $p =~ ^/[^/]+$ ]] && return 0      # nothing directly under /
    for h in "${USER_HOMES[@]}"; do
        path_under "$h" "$p" && return 0  # a user home, or an ancestor of one
    done
    for x in "${PROTECTED_EXTRA[@]}"; do
        path_under "$x" "$p" && return 0  # a discovery root (Caskroom, ~/.sdkman/candidates/java ...) or an ancestor
    done
    return 1
}

# UID to delete a path as: the deepest non-root owner of any parent directory (a user who could swap a parent for a
# symlink); 0 when every parent is owned by root.
delete_uid() {
    local cur o
    cur=$(/usr/bin/dirname -- "${1%/}")
    while [[ -n $cur && $cur != / ]]; do
        o=$(/usr/bin/stat -f %u "$cur" 2>/dev/null)
        if [[ -n $o && $o != 0 ]]; then echo "$o"; return; fi
        cur=$(/usr/bin/dirname -- "$cur")
    done
    echo 0
}

#=============================================================================================== Java homes
is_home() {
    local d="$1"
    [[ -n $d && -d $d ]] || return 1
    [[ -f $d/bin/java || -f $d/lib/server/libjvm.dylib || -f $d/jre/lib/server/libjvm.dylib || -f $d/lib/jli/libjli.dylib ]]
}

home_of() {   # the Java home of a home directory or a .jdk-style bundle (no deeper search)
    local d="${1%/}"
    if is_home "$d/Contents/Home"; then printf '%s' "$d/Contents/Home"
    elif is_home "$d"; then printf '%s' "$d"
    fi
}

find_home() {   # home_of, or a home one level down (zip / tar.gz extracted into a wrapper folder)
    local d="${1%/}" h c
    h=$(home_of "$d"); [[ -n $h ]] && { printf '%s' "$h"; return; }
    for c in "$d"/*; do
        [[ -d $c && ! -L $c ]] || continue
        h=$(home_of "$c"); [[ -n $h ]] && { printf '%s' "$h"; return; }
    done
}

# Reads a Java home's license text: Commercial | OpenSource | Unknown. GPL evidence first.
license_kind() {
    local d="$1" rel f sz
    if [[ -n $d && -d $d ]]; then
        for rel in LICENSE LICENSE.txt COPYRIGHT legal/java.base/LICENSE legal/jdk/LICENSE; do
            f="$d/$rel"
            [[ -f $f ]] || continue
            sz=$(/usr/bin/stat -L -f %z "$f" 2>/dev/null)
            [[ -n $sz && $sz -gt 0 && $sz -le 600000 ]] || continue
            if /usr/bin/grep -Eiq -- "$RX_GPL" "$f" 2>/dev/null; then echo OpenSource; return; fi
            if /usr/bin/grep -Eiq -- "$RX_COMMERCIAL" "$f" 2>/dev/null; then echo Commercial; return; fi
        done
    fi
    echo Unknown
}

has_oracle_receipt() {
    local p="$1" k
    for ((k = 0; k < ${#RC_ID[@]}; k++)); do
        imatch "${RC_ID[$k]}" "$RX_ORACLE_RECEIPT" && [[ ${RC_PATH[$k]} == "$p" ]] && return 0
    done
    return 1
}

# Can this folder be deleted whole? Only standard JDK/JRE content (protects e.g. /opt/jdk-21 holding someone's work).
is_clean_java_dir() {
    local d="${1%/}" c n
    if [[ -d $d/Contents ]]; then
        for c in "$d"/* "$d"/.[!.]*; do
            n=$(/usr/bin/basename "$c"); in_list "$n" Contents .DS_Store || return 1
        done
        for c in "$d"/Contents/*; do
            n=$(/usr/bin/basename "$c"); in_list "$n" Home Info.plist MacOS _CodeSignature Resources CodeResources || return 1
        done
        return 0
    fi
    is_home "$d" || return 1
    for c in "$d"/*; do
        [[ -d $c ]] || continue
        n=$(/usr/bin/basename "$c")
        in_list "$n" bin lib conf include jmods legal man jre db demo sample samples src || return 1
    done
    return 0
}

#=============================================================================================== Inventory model
# Parallel arrays (bash 3.2 has no associative arrays).
reset_items() {
    ITEM_COUNT=0; LAST=-1
    I_TYPE=(); I_KIND=(); I_PATH=(); I_HOME=(); I_NAME=(); I_SOURCE=(); I_EXTRA=(); I_VENDOR=(); I_VERSION=()
    I_MAJOR=(); I_LIC=(); I_OL=(); I_EVID=(); I_INSCOPE=(); I_REASON=(); I_RESULT=()
}
reset_items

# add_item TYPE KIND PATH HOME NAME SOURCE [EXTRA]
#   TYPE: Bundle (JavaVirtualMachines) | Plugin | Folder | Receipt | Homebrew | Unmanaged
add_item() {
    local i=$ITEM_COUNT
    I_TYPE[i]="$1"; I_KIND[i]="$2"; I_PATH[i]="$3"; I_HOME[i]="$4"; I_NAME[i]="$5"; I_SOURCE[i]="$6"; I_EXTRA[i]="$7"
    I_VENDOR[i]="Other"; I_VERSION[i]=""; I_MAJOR[i]=""; I_LIC[i]="Unknown"; I_OL[i]=0; I_EVID[i]=""
    I_INSCOPE[i]=0; I_REASON[i]=""; I_RESULT[i]="Pending"
    ITEM_COUNT=$((ITEM_COUNT + 1)); LAST=$i
}

find_item() {   # find_item PATH [TYPE...] -> index
    local p="$1" i; shift
    for ((i = 0; i < ITEM_COUNT; i++)); do
        [[ ${I_PATH[$i]} == "$p" ]] || continue
        if [[ $# -gt 0 ]]; then in_list "${I_TYPE[$i]}" "$@" || continue; fi
        echo "$i"; return 0
    done
    return 1
}

under_any_item() {   # is PATH inside an item already found?
    local p="$1" i
    for ((i = 0; i < ITEM_COUNT; i++)); do
        case "${I_TYPE[$i]}" in Receipt|Homebrew) continue ;; esac
        path_under "$p" "${I_PATH[$i]}" && return 0
    done
    return 1
}

# Classifies a JDK bundle / plug-in / folder: vendor, version, major, license, Oracle-licensed + evidence.
classify_java_dir() {
    local i=$1 p h plist="" bid="" bname="" jvmvendor="" jvmver="" bver="" rdir impl implver jver btype graal leaf
    local vendor version major lic ol=0 evid=""
    p="${I_PATH[$i]}"; h="${I_HOME[$i]}"
    if [[ $h == */Contents/Home ]]; then plist="${h%/Home}/Info.plist"; else plist="$p/Contents/Info.plist"; fi
    if [[ -f $plist ]]; then
        bid=$(plist_get "$plist" CFBundleIdentifier)
        bname=$(plist_get "$plist" CFBundleName)
        jvmvendor=$(plist_get "$plist" JavaVM:JVMVendor)
        jvmver=$(plist_get "$plist" JavaVM:JVMVersion)
        bver=$(plist_get "$plist" CFBundleVersion)
    fi
    rdir="$h"
    [[ -z $rdir && -d $p/Contents/Home ]] && rdir="$p/Contents/Home"
    [[ -z $rdir ]] && rdir="$p"
    impl=$(release_get "$rdir" IMPLEMENTOR)
    implver=$(release_get "$rdir" IMPLEMENTOR_VERSION)
    jver=$(release_get "$rdir" JAVA_VERSION)
    btype=$(release_get "$rdir" BUILD_TYPE)
    graal=$(release_get "$rdir" GRAALVM_VERSION); [[ -n $graal ]] && graal="GraalVM"
    leaf=$(/usr/bin/basename "$p"); leaf="${leaf%.jdk}"; leaf="${leaf%.plugin}"

    vendor=$(get_vendor "$graal" "$bid" "$bname" "$jvmvendor" "$impl" "$implver" "$leaf")
    version="$jver"
    [[ -z $version ]] && version="$jvmver"
    [[ -z $version ]] && version="$bver"
    [[ -z $version ]] && version=$(version_from_text "$leaf")
    major=$(get_major "$version" "$leaf")
    lic=$(license_kind "$rdir")
    if [[ $lic == Unknown ]] && imatch "$btype" '^commercial$'; then lic=Commercial; fi

    if [[ $vendor == Oracle ]]; then
        if   [[ $lic == OpenSource ]]; then ol=0; evid="GPL license (OpenJDK)"
        elif [[ $lic == Commercial ]]; then ol=1; evid="Oracle commercial license text"
        elif imatch "$bid" '^com\.oracle\.java\.'; then ol=1; evid="Oracle bundle id $bid"
        elif imatch "$bname" '^Java SE'; then ol=1; evid="bundle name '$bname'"
        elif has_oracle_receipt "$p"; then ol=1; evid="installed by an Oracle pkg"
        elif imatch "$leaf" "$RX_LEGACY_ORACLE_LEAF"; then ol=1; evid="legacy Sun/Oracle folder name"
        elif [[ ${I_TYPE[$i]} == Folder ]] && in_list "${I_KIND[$i]}" SDKMAN asdf mise && imatch "$leaf" "$RX_TOOL_ORACLE_LEAF"; then
            ol=1; evid="version-manager identifier '$leaf'"
        else evid="no Oracle licence evidence"
        fi
    fi
    I_VENDOR[i]="$vendor"; I_VERSION[i]="$version"; I_MAJOR[i]="$major"; I_LIC[i]="$lic"; I_OL[i]=$ol; I_EVID[i]="$evid"
}

#=============================================================================================== Discovery
discover_receipts() {
    RC_ID=(); RC_PATH=()
    local id info vol loc f full bpath
    while IFS= read -r id; do
        imatch "$id" "$RX_JAVA_RECEIPT" || continue
        info=$(/usr/sbin/pkgutil --pkg-info "$id" 2>/dev/null)
        vol=$(printf '%s\n' "$info" | /usr/bin/sed -n 's/^volume: //p' | /usr/bin/head -n 1)
        loc=$(printf '%s\n' "$info" | /usr/bin/sed -n 's/^location: //p' | /usr/bin/head -n 1)
        bpath=""
        while IFS= read -r f; do
            full="/${vol#/}/${loc#/}/$f"
            while [[ $full == *//* ]]; do full="${full//\/\//\/}"; done
            if [[ $full =~ ^(.*/JavaVirtualMachines/[^/]+)(/|$) ]]; then bpath="${BASH_REMATCH[1]}"; break; fi
            if [[ $full =~ ^(.*/JavaAppletPlugin\.plugin)(/|$) ]]; then bpath="${BASH_REMATCH[1]}"; break; fi
        done < <(/usr/sbin/pkgutil --files "$id" 2>/dev/null | /usr/bin/head -n 60)
        [[ -n $bpath ]] || continue   # not a JDK/JRE receipt
        RC_ID+=("$id"); RC_PATH+=("$bpath")
    done < <(/usr/sbin/pkgutil --pkgs 2>/dev/null)
}

discover_system_bundles() {
    local root="/Library/Java/JavaVirtualMachines" d h kind
    [[ -d $root && ! -L $root ]] || return 0
    for d in "$root"/*; do
        if [[ -L $d ]]; then log "Ignoring symbolic link: $d" DETAIL; continue; fi
        [[ -d $d ]] || continue
        h=$(home_of "$d"); kind=Home; [[ -z $h ]] && kind=Remnant
        add_item Bundle "$kind" "$d" "$h" "$(/usr/bin/basename "$d")" "system"
        classify_java_dir "$LAST"
    done
}

discover_plugins() {
    local p h kind
    for p in "/Library/Internet Plug-Ins/JavaAppletPlugin.plugin" "/Library/Internet Plug-Ins (Disabled)/JavaAppletPlugin.plugin"; do
        [[ -d $p && ! -L $p ]] || continue
        h=$(home_of "$p"); kind=Home; [[ -z $h ]] && kind=Remnant
        add_item Plugin "$kind" "$p" "$h" "Java browser plug-in (JavaAppletPlugin)" "system"
        classify_java_dir "$LAST"
    done
}

USER_JAVA_ROOTS=(
    "Library/Java/JavaVirtualMachines|UserJVM"
    ".jdks|IntelliJ"
    ".gradle/jdks|Gradle"
    ".jbang/cache/jdks|JBang"
    ".sdkman/candidates/java|SDKMAN"
    ".asdf/installs/java|asdf"
    ".local/share/mise/installs/java|mise"
    ".jabba/jdk|jabba"
)

discover_user_dirs() {
    local u home name spec root kind d h leaf
    for ((u = 0; u < ${#USER_HOMES[@]}; u++)); do
        home="${USER_HOMES[$u]}"; name="${USER_NAMES[$u]}"
        for spec in "${USER_JAVA_ROOTS[@]}"; do
            root="$home/${spec%%|*}"; kind="${spec##*|}"
            PROTECTED_EXTRA+=("$root")
            [[ -d $root && ! -L $root ]] || continue
            for d in "$root"/*; do
                [[ -d $d && ! -L $d ]] || continue
                leaf=$(/usr/bin/basename "$d")
                in_list "$leaf" current latest system && continue
                h=$(find_home "$d")
                if [[ -z $h ]]; then
                    # Only the JavaVirtualMachines folder gets partially removed bundles ("remnants").
                    [[ $kind == UserJVM && ( $leaf == *.jdk || -f $d/Contents/Info.plist ) ]] || continue
                    add_item Folder Remnant "$d" "" "$leaf" "user:$name ($kind)"
                else
                    add_item Folder "$kind" "$d" "$h" "$leaf" "user:$name"
                fi
                classify_java_dir "$LAST"
            done
        done
    done
}

discover_loose() {
    local root d leaf h
    for root in /opt /opt/java /usr/local /usr/local/java /Library/Java /Applications; do
        [[ -d $root && ! -L $root ]] || continue
        for d in "$root"/*; do
            [[ -d $d && ! -L $d ]] || continue
            case "$d" in /Library/Java/JavaVirtualMachines|/Library/Java/Extensions|/Library/Java/Home|*.app) continue ;; esac
            leaf=$(/usr/bin/basename "$d"); leaf="${leaf%.jdk}"
            imatch "$leaf" "$RX_JAVAISH_LEAF" || continue
            h=$(find_home "$d"); [[ -n $h ]] || continue
            find_item "$d" >/dev/null && continue
            add_item Folder Loose "$d" "$h" "$(/usr/bin/basename "$d")" "loose"
            classify_java_dir "$LAST"
        done
    done
}

discover_casks() {
    local prefix croot d tok ver v
    for prefix in /opt/homebrew /usr/local; do
        croot="$prefix/Caskroom"
        [[ -d $croot && ! -L $croot ]] || continue
        PROTECTED_EXTRA+=("$croot")
        for d in "$croot"/*; do
            [[ -d $d && ! -L $d ]] || continue
            tok=$(/usr/bin/basename "$d")
            imatch "$tok" "$RX_JAVA_CASK" || continue
            ver=""
            for v in "$d"/*; do [[ -d $v ]] && { ver=$(/usr/bin/basename "$v"); break; }; done
            add_item Homebrew Cask "$d" "" "brew cask $tok" "homebrew" "$tok"
            I_VENDOR[LAST]=$(get_vendor "$tok")
            I_VERSION[LAST]="$ver"
            I_MAJOR[LAST]=$(get_major "$ver" "$tok")
            I_LIC[LAST]="Package"
            if [[ ${I_VENDOR[$LAST]} == Oracle ]] && imatch "$tok" "$RX_ORACLE_CASK"; then
                I_OL[LAST]=1; I_EVID[LAST]="Oracle JDK cask"
            fi
        done
    done
}

add_receipt_items() {
    local k id p j
    for ((k = 0; k < ${#RC_ID[@]}; k++)); do
        id="${RC_ID[$k]}"; p="${RC_PATH[$k]}"
        j=""
        [[ -e $p ]] && j=$(find_item "$p" Bundle Plugin)
        add_item Receipt Pkg "$p" "" "pkg $id" "pkgutil" "$id"
        if [[ -n $j ]]; then
            I_VENDOR[LAST]="${I_VENDOR[$j]}"; I_VERSION[LAST]="${I_VERSION[$j]}"; I_MAJOR[LAST]="${I_MAJOR[$j]}"
            I_LIC[LAST]="${I_LIC[$j]}"; I_OL[LAST]="${I_OL[$j]}"; I_EVID[LAST]="${I_EVID[$j]}"
        else
            I_KIND[LAST]="Orphan"
            I_VENDOR[LAST]=$(get_vendor "$id")
            I_MAJOR[LAST]=$(get_major "" "$id")
            if [[ ${I_VENDOR[$LAST]} == Oracle ]] && imatch "$id" "$RX_ORACLE_RECEIPT"; then
                I_OL[LAST]=1; I_EVID[LAST]="Oracle pkg receipt"
            fi
        fi
    done
}

add_or_mark_additional() {
    local c="$1" j h
    j=$(find_item "$c")
    if [[ -n $j ]]; then
        [[ ${I_TYPE[$j]} == Unmanaged ]] && I_TYPE[j]=Folder
        I_SOURCE[j]="${I_SOURCE[$j]},AdditionalPath"
        return 0
    fi
    h=$(home_of "$c")
    add_item Folder Additional "$c" "$h" "$(/usr/bin/basename "$c")" "AdditionalPath"
    classify_java_dir "$LAST"
}

glob_expand() {   # prints the matches of one glob pattern (no word splitting on spaces)
    local IFS='' m
    # shellcheck disable=SC2206
    local found=( $1 )
    for m in "${found[@]}"; do printf '%s\n' "$m"; done
}

discover_additional() {
    local pat m p c cc found matches
    for pat in "${ADDITIONAL_PATHS[@]}"; do
        matches=()
        if [[ $pat == *[\*\?\[]* ]]; then
            while IFS= read -r m; do matches+=("$m"); done < <(glob_expand "$pat")
        else
            matches=("$pat")
        fi
        [[ ${#matches[@]} -eq 0 ]] && { [[ $VERIFYING -eq 1 ]] || log "AdditionalPath '$pat' matched nothing." WARN; continue; }
        for m in "${matches[@]}"; do
            m="${m%/}"
            if [[ -L $m ]]; then log "AdditionalPath '$m' is a symbolic link; refused." WARN; continue; fi
            if [[ ! -d $m ]]; then [[ $VERIFYING -eq 1 ]] || log "AdditionalPath '$m' does not exist or is not a folder." WARN; continue; fi
            p=$(physical_path "$m")
            if [[ -z $p || $p != "$m" ]]; then log "AdditionalPath '$m' has a symbolic link in its parent path ($p); refused." WARN; continue; fi
            if is_protected "$p"; then log "AdditionalPath '$p' is a protected location; refused." WARN; continue; fi
            if [[ -n $(home_of "$p") ]]; then add_or_mark_additional "$p"; continue; fi
            found=0
            for c in "$p"/*; do
                [[ -d $c && ! -L $c ]] || continue
                if [[ -n $(home_of "$c") ]]; then add_or_mark_additional "$c"; found=1; continue; fi
                for cc in "$c"/*; do
                    [[ -d $cc && ! -L $cc ]] || continue
                    [[ -n $(home_of "$cc") ]] && { add_or_mark_additional "$cc"; found=1; }
                done
            done
            [[ $found -eq 0 ]] && log "AdditionalPath '$p' is not a Java home and contains none within two levels." WARN
        done
    done
}

discover_embedded() {
    local f home p app
    while IFS= read -r f; do
        home="${f%/bin/java}"
        p="$home"; [[ $home == */Contents/Home ]] && p="${home%/Contents/Home}"
        under_any_item "$p" && continue
        app=""; [[ $f =~ ^(.*\.app)/ ]] && app=$(/usr/bin/basename "${BASH_REMATCH[1]}")
        add_item Unmanaged Embedded "$p" "$home" "${app:-$(/usr/bin/basename "$p")}" "embedded"
        classify_java_dir "$LAST"
    done < <(/usr/bin/find /Applications "/Library/Application Support" -maxdepth 8 \
                \( -path '/Applications/Xcode*.app' -prune \) -o \( -type f -path '*/bin/java' -print \) 2>/dev/null | /usr/bin/sort)
}

discover_all() {
    reset_items
    PROTECTED_EXTRA=()
    load_users
    discover_receipts
    discover_system_bundles
    discover_plugins
    [[ $SKIP_USER_PROFILES -eq 0 ]] && discover_user_dirs
    discover_loose
    discover_casks
    add_receipt_items
    discover_additional
    [[ $SCAN_EMBEDDED -eq 1 ]] && discover_embedded
    return 0
}

#=============================================================================================== Scope
# THE rule for what this script may remove: Oracle vendor, positive Oracle-licence evidence, and no GPL licence text.
# Every scope decision and every destructive action goes through it.
is_licensed_oracle() {
    local i=$1
    [[ ${I_VENDOR[$i]} == Oracle && ${I_OL[$i]} == 1 && ${I_LIC[$i]} != OpenSource ]]
}

set_item_scope() {
    local i=$1 text
    I_INSCOPE[i]=0; I_REASON[i]=""
    if [[ ${I_TYPE[$i]} == Unmanaged ]]; then
        I_REASON[i]="bundled with an application - use AdditionalPath to remove it"; I_RESULT[i]=Kept; return
    fi
    if ! is_licensed_oracle "$i"; then
        if [[ ${I_VENDOR[$i]} != Oracle ]]; then
            I_REASON[i]="${I_VENDOR[$i]} distribution (not Oracle-licensed); open-source Java is always kept"
        elif [[ ${I_LIC[$i]} == OpenSource ]]; then
            I_REASON[i]="Oracle-built OpenJDK (GPL); open-source Java is always kept"
        else
            I_REASON[i]="Oracle distribution could not be established; preserved for manual review"
        fi
        I_RESULT[i]=Kept; return
    fi
    if [[ -n ${I_MAJOR[$i]} && ${#KEEP_MAJORS[@]} -gt 0 ]] && in_list "${I_MAJOR[$i]}" "${KEEP_MAJORS[@]}"; then
        I_REASON[i]="Java ${I_MAJOR[$i]} kept by KeepMajorVersion"; I_RESULT[i]=Kept; return
    fi
    if [[ -n $EXCLUDE_RE ]]; then
        text="${I_NAME[$i]} | ${I_VERSION[$i]} | ${I_PATH[$i]} | ${I_VENDOR[$i]}"
        if printf '%s\n' "$text" | /usr/bin/grep -Eiq -- "$EXCLUDE_RE"; then
            I_REASON[i]="matches Exclude"; I_RESULT[i]=Kept; return
        fi
    fi
    I_INSCOPE[i]=1
}

is_path_type() { in_list "$1" Bundle Plugin Folder Unmanaged; }

linkable_path() {   # Homebrew casks have no Java path; everything else links by its (trusted) path.
    [[ ${I_TYPE[$1]} == Homebrew ]] && return 0
    printf '%s' "${I_PATH[$1]}"
}

# Do two items describe the same installation (bundle + pkg receipt + brew cask)?
items_linked() {
    local a=$1 b=$2 differ=0 pa pb
    if [[ ${I_VENDOR[$a]} == Oracle && ${I_VENDOR[$b]} == Oracle && ${I_OL[$a]} != "${I_OL[$b]}" ]]; then differ=1; fi
    [[ $differ -eq 1 ]] && return 1
    if [[ ${I_TYPE[$a]} == "${I_TYPE[$b]}" ]] || { is_path_type "${I_TYPE[$a]}" && is_path_type "${I_TYPE[$b]}"; }; then
        is_path_type "${I_TYPE[$a]}" || return 1
        path_under "${I_PATH[$a]}" "${I_PATH[$b]}" || path_under "${I_PATH[$b]}" "${I_PATH[$a]}"
        return
    fi
    pa=$(linkable_path "$a"); pb=$(linkable_path "$b")
    if [[ -n $pa && -n $pb ]]; then
        path_under "$pa" "$pb" || path_under "$pb" "$pa"
        return
    fi
    [[ ${I_VENDOR[$a]} == "${I_VENDOR[$b]}" && -n ${I_MAJOR[$a]} && ${I_MAJOR[$a]} == "${I_MAJOR[$b]}" ]]
}

# Takes items out of scope when they are linked to something kept (or whose removal failed).
set_linked_protection() {
    local changed=1 pass=0 i k
    while [[ $changed -eq 1 && $pass -lt 5 ]]; do
        changed=0; pass=$((pass + 1))
        for ((i = 0; i < ITEM_COUNT; i++)); do
            [[ ${I_INSCOPE[$i]} == 1 ]] || continue
            for ((k = 0; k < ITEM_COUNT; k++)); do
                [[ $k -eq $i ]] && continue
                [[ ${I_TYPE[$k]} == Unmanaged ]] && continue
                [[ ${I_INSCOPE[$k]} == 0 || ${I_RESULT[$k]} == Failed ]] || continue
                if items_linked "$i" "$k"; then
                    I_INSCOPE[i]=0; I_RESULT[i]=Kept
                    I_REASON[i]="linked to '${I_NAME[$k]}' (${I_TYPE[$k]}), which is being kept or could not be removed"
                    changed=1; break
                fi
            done
        done
    done
}

scope_all() {
    local i
    for ((i = 0; i < ITEM_COUNT; i++)); do set_item_scope "$i"; done
    set_linked_protection
}

show_inventory() {   # show_inventory TITLE INDEX...
    local title="$1" i n=0 action major what level; shift
    log "$title: $# item(s)"
    for i in "$@"; do
        n=$((n + 1))
        action=KEEP; [[ ${I_INSCOPE[$i]} == 1 ]] && action=REMOVE
        major="${I_MAJOR[$i]:-?}"
        case "${I_TYPE[$i]}" in
            Receipt)  what="${I_NAME[$i]} -> ${I_PATH[$i]}$([[ ${I_KIND[$i]} == Orphan ]] && echo ' (orphan)')" ;;
            Homebrew) what="${I_NAME[$i]} ${I_VERSION[$i]} (${I_PATH[$i]})" ;;
            *)        what="${I_PATH[$i]} [${I_VERSION[$i]:-?}]" ;;
        esac
        log "$(printf '  %2d. %-6s %-9s %-9s %-3s %s' "$n" "$action" "${I_TYPE[$i]}" "${I_VENDOR[$i]}" "$major" "$what")"
        if [[ ${I_VENDOR[$i]} == Oracle ]]; then
            log "        Oracle  : licensed=$([[ ${I_OL[$i]} == 1 ]] && echo yes || echo no); license=${I_LIC[$i]}; ${I_EVID[$i]}" DETAIL
        fi
        [[ ${I_TYPE[$i]} == Folder || ${I_TYPE[$i]} == Unmanaged ]] && log "        Found by: ${I_SOURCE[$i]} (${I_KIND[$i]})" DETAIL
        if [[ ${I_INSCOPE[$i]} != 1 && -n ${I_REASON[$i]} ]]; then
            level=DETAIL; [[ ${I_REASON[$i]} == *"manual review"* ]] && level=WARN
            log "        Kept    : ${I_REASON[$i]}" "$level"
        fi
    done
}

#=============================================================================================== Removal actions
# remove_path PATH REASON : deletes a file / folder safely; a symlink is removed as a link only.
remove_path() {
    local p="${1%/}" reason="$2" phys uid
    if [[ ! -e $p && ! -L $p ]]; then return 0; fi
    phys=$(physical_path "$p")
    if [[ -z $phys || $phys != "$p" ]]; then
        log "Refused: '$p' has a symbolic link in its parent path ($phys)." ERROR; return 1
    fi
    if is_protected "$p"; then log "Refused: '$p' is a protected location." ERROR; return 1; fi
    uid=$(delete_uid "$p")
    if [[ $MODE == whatif ]]; then
        log "WhatIf: would remove '$p' ($reason)$([[ $uid != 0 ]] && echo " as uid $uid")" ACTION
        REMOVED_PATHS+=("$p"); return 0
    fi
    log "Removing '$p' ($reason)$([[ $uid != 0 ]] && echo " as uid $uid")" ACTION
    if [[ $uid == "$MY_UID" ]]; then
        /bin/rm -rf -- "$p" 2>/dev/null
    elif [[ $IS_ROOT -eq 1 ]] && /usr/bin/id -un "$uid" >/dev/null 2>&1; then
        /usr/bin/sudo -n -u "#$uid" /bin/rm -rf -- "$p" 2>/dev/null
    elif [[ $IS_ROOT -eq 1 ]]; then
        /bin/rm -rf -- "$p" 2>/dev/null          # owner uid has no account: nobody can race us
    else
        log "Cannot remove '$p': owned by uid $uid and not running as root." ERROR; return 1
    fi
    if [[ -e $p || -L $p ]]; then
        if [[ $uid != 0 ]]; then
            log "Could not fully remove '$p'. It is in a folder owned by uid $uid but contains files that user cannot delete (e.g. extracted with sudo); remove it manually." ERROR
        else
            log "Could not fully remove '$p'." ERROR
        fi
        return 1
    fi
    CHANGE_COUNT=$((CHANGE_COUNT + 1)); REMOVED_PATHS+=("$p")
    return 0
}

was_removed() { local p="$1"; [[ ! -e $p && ! -L $p ]] && return 0; in_list "$p" "${REMOVED_PATHS[@]}"; }

remove_empty_dir() {
    local d="$1"
    [[ -d $d && ! -L $d ]] || return 0
    local entries=("$d"/* "$d"/.[!.]*)
    [[ ${#entries[@]} -eq 1 && $(/usr/bin/basename "${entries[0]}") == .DS_Store ]] && entries=()
    [[ ${#entries[@]} -eq 0 ]] || return 0
    remove_path "$d" "empty folder"
}

stop_java_processes() {   # stop_java_processes PATH...
    [[ $NO_KILL -eq 1 ]] && { log "Process termination skipped (NoKill)."; return 0; }
    local pid comm pfx pids=() p waited=0
    while read -r pid comm; do
        [[ -n $pid && $pid != "$$" ]] || continue
        for pfx in "$@"; do
            [[ -n $pfx ]] || continue
            if [[ $comm == "$pfx"/* ]]; then pids+=("$pid"); log "Stopping process $pid: $comm" ACTION; break; fi
        done
    done < <(/bin/ps -axww -o pid= -o comm= 2>/dev/null)
    [[ ${#pids[@]} -eq 0 ]] && { log "No running Java processes from the targeted locations."; return 0; }
    [[ $MODE == whatif ]] && { log "WhatIf: would stop ${#pids[@]} process(es)." ACTION; return 0; }
    /bin/kill -TERM "${pids[@]}" 2>/dev/null
    while [[ $waited -lt $KILL_TIMEOUT ]]; do
        local alive=0
        for p in "${pids[@]}"; do /bin/kill -0 "$p" 2>/dev/null && alive=1; done
        [[ $alive -eq 0 ]] && break
        /bin/sleep 1; waited=$((waited + 1))
    done
    for p in "${pids[@]}"; do
        if /bin/kill -0 "$p" 2>/dev/null; then log "Process $p did not exit; sending SIGKILL." WARN; /bin/kill -KILL "$p" 2>/dev/null; fi
    done
    CHANGE_COUNT=$((CHANGE_COUNT + 1))
}

logged_in_uids() {
    /bin/ps -axo uid= -o comm= 2>/dev/null | /usr/bin/awk '$2 ~ /loginwindow$/ && $1 >= 500 {print $1}' | /usr/bin/sort -u
}

bootout_job() {   # bootout_job PLIST system|gui
    local plist="$1" domain="$2" uid label
    [[ -f $plist && ! -L $plist ]] || return 0
    label=$(plist_get "$plist" Label)
    if [[ $MODE == whatif ]]; then log "WhatIf: would unload launchd job ${label:-$plist}" ACTION; return 0; fi
    if [[ $domain == system ]]; then
        /bin/launchctl bootout system "$plist" >/dev/null 2>&1 && log "Unloaded launchd job ${label:-$plist} (system)" ACTION
    else
        while read -r uid; do
            [[ -n $uid ]] || continue
            /bin/launchctl bootout "gui/$uid" "$plist" >/dev/null 2>&1 && log "Unloaded launchd job ${label:-$plist} (gui/$uid)" ACTION
        done < <(logged_in_uids)
    fi
}

ORACLE_SYSTEM_LEFTOVERS=(
    "/Library/PreferencePanes/JavaControlPanel.prefPane"
    "/Library/LaunchAgents/com.oracle.java.Java-Updater.plist"
    "/Library/LaunchDaemons/com.oracle.java.Helper-Tool.plist"
    "/Library/LaunchDaemons/com.oracle.java.JavaUpdateHelper.plist"
    "/Library/PrivilegedHelperTools/com.oracle.java.JavaUpdateHelper"
    "/Library/Preferences/com.oracle.java.Helper-Tool.plist"
    "/Library/Preferences/com.oracle.java.Java-Updater.plist"
    "/Library/Application Support/Oracle/Java"
)
ORACLE_USER_LEFTOVERS=(
    "Library/Application Support/Oracle/Java"
    "Library/Preferences/com.oracle.java.JavaAppletPlugin.plist"
    "Library/Preferences/com.oracle.java.Java-Updater.plist"
    "Library/Preferences/com.oracle.java.Helper-Tool.plist"
    "Library/Preferences/com.oracle.javadeployment.plist"
    "Library/Caches/Oracle.Java"
)

list_oracle_leftovers() {   # prints existing leftover paths (system, then per user)
    local p h r
    for p in "${ORACLE_SYSTEM_LEFTOVERS[@]}"; do [[ -e $p || -L $p ]] && printf '%s\n' "$p"; done
    [[ $SKIP_USER_PROFILES -eq 1 ]] && return 0
    for h in "${USER_HOMES[@]}"; do
        for r in "${ORACLE_USER_LEFTOVERS[@]}"; do [[ -e $h/$r || -L $h/$r ]] && printf '%s\n' "$h/$r"; done
        for p in "$h"/Library/Caches/com.oracle.java.*; do printf '%s\n' "$p"; done
    done
}

dead_oracle_java_home() {   # /Library/Java/Home is a dead link into the Oracle plug-in or a removed Oracle Java
    local t r
    [[ -L /Library/Java/Home && ! -e /Library/Java/Home ]] || return 1
    t=$(/usr/bin/readlink /Library/Java/Home 2>/dev/null); [[ -n $t ]] || return 1
    [[ $t == *JavaAppletPlugin.plugin* ]] && return 0
    for r in "${REMOVED_PATHS[@]}"; do path_under "$t" "$r" && return 0; done
    return 1
}

cleanup_oracle_leftovers() {
    local p h failed=0 leftovers
    leftovers=$(list_oracle_leftovers)
    if [[ -z $leftovers ]] && ! dead_oracle_java_home; then
        log "No Oracle Java leftovers found."; return 0
    fi
    log "Cleaning Oracle Java leftovers (no licensed Oracle Java remains)."
    bootout_job "/Library/LaunchAgents/com.oracle.java.Java-Updater.plist" gui
    bootout_job "/Library/LaunchDaemons/com.oracle.java.Helper-Tool.plist" system
    bootout_job "/Library/LaunchDaemons/com.oracle.java.JavaUpdateHelper.plist" system
    while IFS= read -r p; do
        [[ -n $p ]] || continue
        if [[ -L $p ]]; then
            # The prefpane is normally a symlink into the (now removed) plug-in: remove the link itself only.
            if [[ $MODE == whatif ]]; then log "WhatIf: would remove symbolic link '$p'" ACTION
            elif /bin/rm -f -- "$p" 2>/dev/null; then log "Removed symbolic link '$p'" ACTION; CHANGE_COUNT=$((CHANGE_COUNT + 1))
            else log "Could not remove symbolic link '$p'" ERROR; failed=1
            fi
        else
            remove_path "$p" "Oracle Java leftover" || failed=1
        fi
    done <<< "$leftovers"
    remove_empty_dir "/Library/Application Support/Oracle"
    if [[ $SKIP_USER_PROFILES -eq 0 ]]; then
        for h in "${USER_HOMES[@]}"; do remove_empty_dir "$h/Library/Application Support/Oracle"; done
    fi
    # /Library/Java/Home is a legacy symlink; remove it only when it points nowhere and pointed at Oracle Java.
    if dead_oracle_java_home; then
        if [[ $MODE == whatif ]]; then log "WhatIf: would remove dead symbolic link /Library/Java/Home" ACTION
        else /bin/rm -f /Library/Java/Home && { log "Removed dead symbolic link /Library/Java/Home" ACTION; CHANGE_COUNT=$((CHANGE_COUNT + 1)); }
        fi
    fi
    return $failed
}

# Report (never edit) shell start-up files that still point at a removed Java.
report_shell_references() {
    local h f r
    [[ ${#REMOVED_PATHS[@]} -gt 0 && $SKIP_USER_PROFILES -eq 0 ]] || return 0
    local files=(/etc/zshrc /etc/zprofile /etc/zshenv /etc/profile /etc/bashrc)
    for h in "${USER_HOMES[@]}"; do
        files+=("$h/.zshrc" "$h/.zprofile" "$h/.zshenv" "$h/.bash_profile" "$h/.bashrc" "$h/.profile")
    done
    for f in "${files[@]}"; do
            [[ -f $f && ! -L $f ]] || continue
            for r in "${REMOVED_PATHS[@]}"; do
                if /usr/bin/grep -Fq -- "$r" "$f" 2>/dev/null; then
                    log "Shell start-up file '$f' still references removed Java '$r' (JAVA_HOME/PATH) - review it." WARN
                fi
            done
    done
}

#=============================================================================================== Reporting
item_json() {
    local i=$1
    printf '{"Type":"%s","Kind":"%s","Name":"%s","Vendor":"%s","Version":"%s","Major":"%s","Path":"%s","License":"%s","OracleLicensed":%s,"Evidence":"%s","Source":"%s","InScope":%s,"Result":"%s","Reason":"%s"}' \
        "$(json_escape "${I_TYPE[$i]}")" "$(json_escape "${I_KIND[$i]}")" "$(json_escape "${I_NAME[$i]}")" \
        "$(json_escape "${I_VENDOR[$i]}")" "$(json_escape "${I_VERSION[$i]}")" "$(json_escape "${I_MAJOR[$i]}")" \
        "$(json_escape "${I_PATH[$i]}")" "$(json_escape "${I_LIC[$i]}")" \
        "$([[ ${I_OL[$i]} == 1 ]] && echo true || echo false)" "$(json_escape "${I_EVID[$i]}")" \
        "$(json_escape "${I_SOURCE[$i]}")" "$([[ ${I_INSCOPE[$i]} == 1 ]] && echo true || echo false)" \
        "$(json_escape "${I_RESULT[$i]}")" "$(json_escape "${I_REASON[$i]}")"
}

items_json() {   # items_json INDEX...
    local i first=1
    printf '['
    for i in "$@"; do
        [[ $first -eq 1 ]] || printf ','
        first=0
        item_json "$i"
    done
    printf ']'
}

write_json_report() {   # write_json_report BODY
    [[ -n $JSON_FILE ]] || return 0
    if printf '%s\n' "$1" > "$JSON_FILE" 2>/dev/null; then
        /bin/chmod 644 "$JSON_FILE" 2>/dev/null
        log "JSON report: $JSON_FILE" DETAIL
    else
        log "Could not write JSON report $JSON_FILE" WARN
    fi
}

item_summary() {   # one-line description of an item for summaries / EA
    local i=$1
    printf '%s %s %s (%s)' "${I_VENDOR[$i]}" "${I_MAJOR[$i]:-?}" "${I_TYPE[$i]}" "${I_PATH[$i]:-${I_NAME[$i]}}"
}

#=============================================================================================== Argument parsing
usage() {
    /usr/bin/sed -n '2,/^# Version/p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
}

apply_options_list() {
    local o
    while IFS= read -r o; do
        case "$(lower "$o" | /usr/bin/tr -d ' _-')" in
            includeoracleopenjdk) echo "Option '$o' is no longer supported: this script removes licensed Oracle Java only." >&2; return 1 ;;
            skipuserprofiles)     SKIP_USER_PROFILES=1 ;;
            skipleftovercleanup)  SKIP_LEFTOVER=1 ;;
            scanembedded)         SCAN_EMBEDDED=1 ;;
            nokill)               NO_KILL=1 ;;
            recon)                RUN_RECON=1 ;;
            *) echo "Unknown option '$o'. Valid: SkipUserProfiles, SkipLeftoverCleanup, ScanEmbedded, NoKill, Recon" >&2; return 1 ;;
        esac
    done < <(split_list "$1")
    return 0
}

set_mode() {
    case "$(lower "$(trim "$1")")" in
        ""|remove|uninstall)      MODE=remove ;;
        detect|detectonly|audit)  MODE=detect ;;
        whatif|dryrun|dry-run)    MODE=whatif ;;
        ea|extensionattribute)    MODE=ea ;;
        *) echo "Unknown mode '$1'. Valid: Remove, Detect, WhatIf" >&2; return 1 ;;
    esac
}

parse_args() {
    if [[ $# -eq 0 ]]; then MODE=ea; return 0; fi
    if [[ $1 != -* ]]; then
        # Jamf Pro: $1 mount point, $2 computer name, $3 user name, $4..$11 policy parameters.
        set_mode "$4" || return 1
        VENDOR_ARG="$5"; KEEP_ARG="$6"; EXCLUDE_RE="$7"; ADDITIONAL_ARG="$8"
        apply_options_list "$9" || return 1
        LOG_DIR_ARG="$(trim "${10}")"
        return 0
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --detect|--detect-only)      MODE=detect ;;
            --whatif|--dry-run)          MODE=whatif ;;
            --remove)                    MODE=remove ;;
            --ea)                        MODE=ea ;;
            --vendor|--include-oracle-openjdk)
                echo "'$1' is no longer supported: this script removes licensed Oracle Java only." >&2; return 1 ;;
            --keep-major|--keep-major-version) KEEP_ARG="$2"; shift ;;
            --exclude)                   EXCLUDE_RE="$2"; shift ;;
            --additional-path)           ADDITIONAL_ARG="${ADDITIONAL_ARG:+$ADDITIONAL_ARG;}$2"; shift ;;
            --skip-user-profiles)        SKIP_USER_PROFILES=1 ;;
            --skip-leftover-cleanup)     SKIP_LEFTOVER=1 ;;
            --scan-embedded)             SCAN_EMBEDDED=1 ;;
            --no-kill)                   NO_KILL=1 ;;
            --recon)                     RUN_RECON=1 ;;
            --options)                   apply_options_list "$2" || return 1; shift ;;
            --log-dir)                   LOG_DIR_ARG="$2"; shift ;;
            -h|--help)                   usage; exit 0 ;;
            *) echo "Unknown argument '$1' (see --help)." >&2; return 1 ;;
        esac
        shift
    done
    return 0
}

# Validates and expands parameters into KEEP_MAJORS / ADDITIONAL_PATHS. Errors go to PARAM_ERROR.
PARAM_ERROR=""
resolve_parameters() {
    local v m
    PARAM_ERROR=""
    # The vendor scope is fixed. A leftover Vendor value ($5) other than Oracle is an error, not silently ignored.
    while IFS= read -r v; do
        [[ $(normalize_vendor "$v") == Oracle ]] && continue
        PARAM_ERROR="Vendor '$v' is not supported: this script removes licensed Oracle Java only and always keeps OpenJDK. Clear parameter 5."
        return 1
    done < <(split_list "$VENDOR_ARG")
    KEEP_MAJORS=()
    while IFS= read -r m; do
        m="${m#1.}"
        [[ $m =~ ^[0-9]{1,3}$ ]] || { PARAM_ERROR="Invalid KeepMajorVersion '$m' (expected numbers such as 8,17,21)."; return 1; }
        KEEP_MAJORS+=("$((10#$m))")
    done < <(split_list "$KEEP_ARG")
    EXCLUDE_RE=$(trim "$EXCLUDE_RE")
    if [[ -n $EXCLUDE_RE ]]; then
        printf 'x\n' | /usr/bin/grep -Eq -- "$EXCLUDE_RE" 2>/dev/null
        [[ $? -eq 2 ]] && { PARAM_ERROR="Exclude is not a valid extended regular expression: $EXCLUDE_RE"; return 1; }
    fi
    ADDITIONAL_PATHS=()
    while IFS= read -r m; do
        [[ $m == /* ]] || { PARAM_ERROR="AdditionalPath must be absolute: $m"; return 1; }
        ADDITIONAL_PATHS+=("$m")
    done < <(split_list "$ADDITIONAL_ARG")
    return 0
}

#=============================================================================================== Locking
acquire_lock() {
    local pid
    if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then echo $$ > "$LOCK_DIR/pid"; HAVE_LOCK=1; return 0; fi
    pid=$(/bin/cat "$LOCK_DIR/pid" 2>/dev/null)
    if [[ -n $pid ]] && /bin/kill -0 "$pid" 2>/dev/null; then return 1; fi
    /bin/rm -rf "$LOCK_DIR" 2>/dev/null                       # stale lock from a crashed run
    if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then echo $$ > "$LOCK_DIR/pid"; HAVE_LOCK=1; return 0; fi
    return 1
}
release_lock() { [[ $HAVE_LOCK -eq 1 ]] && /bin/rm -rf "$LOCK_DIR" 2>/dev/null; HAVE_LOCK=0; }

#=============================================================================================== Main
run_ea() {
    local i found=() text="" s
    QUIET=1
    resolve_parameters
    discover_all
    scope_all
    for ((i = 0; i < ITEM_COUNT; i++)); do
        [[ ${I_TYPE[$i]} == Receipt || ${I_TYPE[$i]} == Homebrew ]] && continue   # report the Java itself, not its packaging
        [[ ${I_INSCOPE[$i]} == 1 ]] && is_licensed_oracle "$i" && found+=("$i")
    done
    if [[ ${#found[@]} -gt 0 ]]; then
        for i in "${found[@]}"; do s=$(item_summary "$i"); text="${text:+$text; }$s"; done
        echo "<result>Found (${#found[@]}): $text</result>"
    else
        echo "<result>None</result>"
    fi
    return 0
}

main() {
    local i mode_label host computer initial_json all_idx=() inscope=() pathtargets=() stop_paths=() kept_paths=()
    local nested k status exit_code=0 removed=0 failed=0 still=() kept_final=() lic_kept=0

    if [[ $MODE == ea ]]; then run_ea; return 0; fi

    init_logging
    case "$MODE" in detect) mode_label="DETECT ONLY" ;; whatif) mode_label="WHATIF (simulation)" ;; *) mode_label="REMOVE" ;; esac
    host=$(/bin/hostname 2>/dev/null)
    computer=$(/usr/sbin/scutil --get ComputerName 2>/dev/null); [[ -z $computer ]] && computer="$host"
    log "Java removal script v$SCRIPT_VERSION | $computer | mode: $mode_label"
    log "Account: $(/usr/bin/id -un) (uid $MY_UID) | macOS $(/usr/bin/sw_vers -productVersion 2>/dev/null) ($(/usr/bin/uname -m)) | bash $BASH_VERSION"
    if [[ -n $LOG_FILE ]]; then log "Log file: $LOG_FILE" DETAIL; else log "Log file could not be created; console output only." WARN; fi
    if [[ $IS_ROOT -eq 1 && $MODE == remove && -z $LOG_FILE ]]; then
        log "Removal stopped: a protected log directory is required." ERROR
        return 2
    fi

    resolve_parameters || { log "$PARAM_ERROR" ERROR; return 2; }
    log "Scope: licensed (proprietary) Oracle/Sun Java only. OpenJDK and all open-source distributions, incl. Oracle's jdk.java.net builds, are always kept."
    [[ ${#KEEP_MAJORS[@]} -gt 0 ]] && log "Keep major version: ${KEEP_MAJORS[*]}"
    [[ -n $EXCLUDE_RE ]] && log "Exclude pattern   : $EXCLUDE_RE"
    if [[ ${#ADDITIONAL_PATHS[@]} -gt 0 ]]; then local ap; ap=$(printf '%s; ' "${ADDITIONAL_PATHS[@]}"); log "Additional paths  : ${ap%; }"; fi
    [[ $SKIP_USER_PROFILES -eq 1 ]] && log "User profiles     : skipped"

    if [[ $MODE != detect && $IS_ROOT -eq 0 ]]; then
        log "Root is required to remove Java (or to simulate removal). Run from Jamf or with sudo; use --detect for an inventory." ERROR
        return 5
    fi
    if [[ $IS_ROOT -eq 1 ]]; then
        if ! acquire_lock; then log "Another instance of the Java removal script is already running. Exiting." ERROR; return 2; fi
    fi
    [[ $IS_ROOT -eq 0 ]] && log "Not running as root: other users' folders may not be readable; results can be incomplete." WARN

    # ---- Discovery
    log ""
    log "=== Discovery ==="
    discover_all
    scope_all
    for ((i = 0; i < ITEM_COUNT; i++)); do all_idx+=("$i"); [[ ${I_INSCOPE[$i]} == 1 ]] && inscope+=("$i"); done
    show_inventory "Java found" "${all_idx[@]}"

    # Oracle leftovers are cleaned when no licensed Oracle Java is being kept.
    for ((i = 0; i < ITEM_COUNT; i++)); do
        [[ ${I_VENDOR[$i]} == Oracle && ${I_OL[$i]} == 1 && ${I_TYPE[$i]} != Unmanaged ]] || continue
        [[ ${I_INSCOPE[$i]} == 1 ]] || lic_kept=1
    done
    local leftovers
    leftovers=$(list_oracle_leftovers)
    if [[ -n $leftovers ]]; then
        log "Oracle Java leftovers present:"
        while IFS= read -r i; do log "        $i" DETAIL; done <<< "$leftovers"
    fi

    if [[ $MODE == detect ]]; then
        log ""
        if [[ ${#inscope[@]} -gt 0 ]]; then
            local summary="" s
            for i in "${inscope[@]}"; do s=$(item_summary "$i"); summary="${summary:+$summary; }$s"; done
            log "DETECTED: ${#inscope[@]} Java item(s) in scope: $summary" WARN
        else
            log "DETECTED: no Java in scope." OK
        fi
        write_json_report "{\"Computer\":\"$(json_escape "$computer")\",\"Time\":\"$(/bin/date '+%Y-%m-%dT%H:%M:%S')\",\"Mode\":\"$mode_label\",\"ScriptVersion\":\"$SCRIPT_VERSION\",\"Items\":$(items_json "${all_idx[@]}")}"
        [[ ${#inscope[@]} -gt 0 ]] && return 1
        return 0
    fi
    [[ $MODE == remove ]] && purge_old_logs

    # ---- Phase 1: processes
    log ""
    log "=== Phase 1: Stop Java processes ==="
    for ((i = 0; i < ITEM_COUNT; i++)); do
        is_path_type "${I_TYPE[$i]}" || continue
        if [[ ${I_INSCOPE[$i]} == 1 ]]; then pathtargets+=("$i"); else kept_paths+=("${I_PATH[$i]}"); fi
    done
    for i in "${pathtargets[@]}"; do stop_paths+=("${I_PATH[$i]}"); done
    if [[ $lic_kept -eq 0 && $SKIP_LEFTOVER -eq 0 ]]; then
        stop_paths+=("/Library/Application Support/Oracle/Java" "/Library/PrivilegedHelperTools/com.oracle.java.JavaUpdateHelper")
    fi
    if [[ ${#inscope[@]} -gt 0 ]]; then stop_java_processes "${stop_paths[@]}"; else log "Nothing in scope."; fi

    # ---- Phase 2: bundles, plug-in and folders
    log ""
    log "=== Phase 2: Remove Java bundles and folders ==="
    [[ ${#pathtargets[@]} -eq 0 ]] && log "No Java folders in scope."
    for i in "${pathtargets[@]}"; do
        if ! is_licensed_oracle "$i"; then   # defence in depth: never act on anything but licensed Oracle Java
            I_INSCOPE[i]=0; I_RESULT[i]=Kept; I_REASON[i]="not licensed Oracle Java"
            log "Refusing to touch '${I_PATH[$i]}': not licensed Oracle Java." ERROR; continue
        fi
        nested=""
        for k in "${kept_paths[@]}"; do
            [[ $k != "${I_PATH[$i]}" ]] && path_under "$k" "${I_PATH[$i]}" && nested="${nested:+$nested; }$k"
        done
        if [[ -n $nested ]]; then
            I_INSCOPE[i]=0; I_RESULT[i]=Kept; I_REASON[i]="contains kept Java: $nested"
            log "Kept '${I_PATH[$i]}': ${I_REASON[$i]}" WARN; continue
        fi
        if [[ ${I_KIND[$i]} == Loose && ,${I_SOURCE[$i]}, != *,AdditionalPath,* ]] && ! is_clean_java_dir "${I_PATH[$i]}"; then
            I_RESULT[i]=Failed; I_REASON[i]="folder contains non-Java content; review and remove manually or pass it as AdditionalPath"
            log "Not removing '${I_PATH[$i]}': ${I_REASON[$i]}" WARN; continue
        fi
        if remove_path "${I_PATH[$i]}" "${I_VENDOR[$i]} Java ${I_MAJOR[$i]:-?} ${I_TYPE[$i]}"; then
            I_RESULT[i]=Removed
        else
            I_RESULT[i]=Failed
        fi
    done

    # ---- Phase 3: installer receipts
    log ""
    log "=== Phase 3: Forget installer receipts ==="
    local any=0
    for ((i = 0; i < ITEM_COUNT; i++)); do
        [[ ${I_TYPE[$i]} == Receipt && ${I_INSCOPE[$i]} == 1 ]] || continue
        any=1
        if ! is_licensed_oracle "$i"; then   # defence in depth: never act on anything but licensed Oracle Java
            I_INSCOPE[i]=0; I_RESULT[i]=Kept; I_REASON[i]="not licensed Oracle Java"
            log "Refusing to touch '${I_EXTRA[$i]}': not licensed Oracle Java." ERROR; continue
        fi
        for k in "${pathtargets[@]}"; do
            if [[ ${I_RESULT[$k]} == Failed ]] && items_linked "$i" "$k"; then
                I_RESULT[i]=Failed; I_REASON[i]="its Java ('${I_PATH[$k]}') could not be removed"; break
            fi
        done
        [[ ${I_RESULT[$i]} == Failed ]] && { log "Keeping receipt ${I_EXTRA[$i]}: ${I_REASON[$i]}" WARN; continue; }
        if [[ -n ${I_PATH[$i]} ]] && ! was_removed "${I_PATH[$i]}"; then
            I_RESULT[i]=Failed; I_REASON[i]="files still present at ${I_PATH[$i]}"
            log "Keeping receipt ${I_EXTRA[$i]}: ${I_REASON[$i]}" WARN; continue
        fi
        if [[ $MODE == whatif ]]; then
            log "WhatIf: would run pkgutil --forget ${I_EXTRA[$i]}" ACTION; I_RESULT[i]=Removed
        elif /usr/sbin/pkgutil --forget "${I_EXTRA[$i]}" >/dev/null 2>&1; then
            log "Forgot installer receipt ${I_EXTRA[$i]}" ACTION; I_RESULT[i]=Removed; CHANGE_COUNT=$((CHANGE_COUNT + 1))
        else
            log "pkgutil --forget ${I_EXTRA[$i]} failed." ERROR; I_RESULT[i]=Failed
        fi
    done
    [[ $any -eq 0 ]] && log "No installer receipts in scope."

    # ---- Phase 4: Homebrew casks
    log ""
    log "=== Phase 4: Homebrew cask registrations ==="
    any=0
    for ((i = 0; i < ITEM_COUNT; i++)); do
        [[ ${I_TYPE[$i]} == Homebrew && ${I_INSCOPE[$i]} == 1 ]] || continue
        any=1
        if ! is_licensed_oracle "$i"; then   # defence in depth: never act on anything but licensed Oracle Java
            I_INSCOPE[i]=0; I_RESULT[i]=Kept; I_REASON[i]="not licensed Oracle Java"
            log "Refusing to touch '${I_NAME[$i]}': not licensed Oracle Java." ERROR; continue
        fi
        for k in "${pathtargets[@]}"; do
            if [[ ${I_RESULT[$k]} == Failed ]] && items_linked "$i" "$k"; then
                I_RESULT[i]=Failed; I_REASON[i]="its Java ('${I_PATH[$k]}') could not be removed"; break
            fi
        done
        [[ ${I_RESULT[$i]} == Failed ]] && { log "Keeping ${I_NAME[$i]}: ${I_REASON[$i]}" WARN; continue; }
        # The JDK itself was removed above; deleting the Caskroom entry unregisters the cask so brew will not
        # reinstall it (brew uninstall cannot run unattended: it needs sudo for the pkg).
        if remove_path "${I_PATH[$i]}" "Homebrew cask registration ${I_EXTRA[$i]}"; then I_RESULT[i]=Removed; else I_RESULT[i]=Failed; fi
    done
    [[ $any -eq 0 ]] && log "No Homebrew Java casks in scope."

    # ---- Phase 5: leftovers
    log ""
    log "=== Phase 5: Leftover cleanup ==="
    if [[ $SKIP_LEFTOVER -eq 1 ]]; then
        log "Leftover cleanup skipped (SkipLeftoverCleanup)."
    else
        local lic_failed=0
        for i in "${inscope[@]}"; do
            [[ ${I_VENDOR[$i]} == Oracle && ${I_OL[$i]} == 1 && ${I_RESULT[$i]} == Failed ]] && lic_failed=1
        done
        if [[ $lic_kept -eq 0 && $lic_failed -eq 0 ]]; then
            cleanup_oracle_leftovers || failed=$((failed + 1))
        else
            log "Oracle leftovers kept: licensed Oracle Java is still installed (kept or failed)."
        fi
        report_shell_references
    fi

    # ---- Phase 6: verification
    log ""
    log "=== Verification ==="
    local -a snap_idx=()
    for ((i = 0; i < ITEM_COUNT; i++)); do
        snap_idx+=("$i")
        [[ ${I_INSCOPE[$i]} == 1 || ${I_RESULT[$i]} == Failed ]] || continue
        case "${I_RESULT[$i]}" in
            Removed) removed=$((removed + 1)) ;;
            Failed)  failed=$((failed + 1)) ;;
        esac
    done
    initial_json=$(items_json "${snap_idx[@]}")

    if [[ $MODE == whatif ]]; then
        log "Verification skipped in WhatIf mode."
    else
        VERIFYING=1
        discover_all
        scope_all
        VERIFYING=0
        for ((i = 0; i < ITEM_COUNT; i++)); do
            if [[ ${I_INSCOPE[$i]} == 1 ]]; then still+=("$i"); else kept_final+=("$i"); fi
        done
        [[ ${#kept_final[@]} -gt 0 ]] && show_inventory "Java kept (out of scope / unmanaged)" "${kept_final[@]}"
        [[ ${#still[@]} -gt 0 ]] && show_inventory "NOT REMOVED" "${still[@]}"
    fi

    status="SUCCESS"
    if [[ $MODE == whatif ]]; then status="WHATIF - no changes made"
    elif [[ ${#still[@]} -gt 0 || $failed -gt 0 ]]; then exit_code=1; status="PARTIAL - some Java could not be removed"
    elif [[ ${#inscope[@]} -eq 0 ]]; then status="SUCCESS - no Java in scope was found"
    fi

    log ""
    log "=== Summary ==="
    log "Items handled: ${#inscope[@]} | removed: $removed | failed: $failed | still present: ${#still[@]} | kept: ${#kept_final[@]} | changes: $CHANGE_COUNT"
    if [[ $exit_code -eq 1 ]]; then log "RESULT: $status (exit code $exit_code)" ERROR; else log "RESULT: $status (exit code $exit_code)" OK; fi

    write_json_report "{\"Computer\":\"$(json_escape "$computer")\",\"Time\":\"$(/bin/date '+%Y-%m-%dT%H:%M:%S')\",\"Mode\":\"$mode_label\",\"ScriptVersion\":\"$SCRIPT_VERSION\",\"Status\":\"$(json_escape "$status")\",\"ExitCode\":$exit_code,\"Initial\":$initial_json,\"Remaining\":$(items_json "${still[@]}"),\"Kept\":$(items_json "${kept_final[@]}")}"

    if [[ $RUN_RECON -eq 1 && $MODE == remove && $CHANGE_COUNT -gt 0 ]]; then
        local jamf_bin=""
        for jamf_bin in /usr/local/bin/jamf /usr/local/jamf/bin/jamf ""; do [[ -x $jamf_bin ]] && break; done
        if [[ -n $jamf_bin ]]; then
            log "Running jamf recon to update inventory." ACTION
            "$jamf_bin" recon >/dev/null 2>&1 || log "jamf recon failed." WARN
        else
            log "Recon requested but the jamf binary was not found." WARN
        fi
    fi
    return $exit_code
}

# Lets the functions be sourced for testing without running anything.
if [[ ${BASH_SOURCE[0]} != "$0" && $JAVAREMOVAL_NO_MAIN == 1 ]]; then return 0; fi

trap 'release_lock' EXIT
trap 'log "Interrupted." ERROR; release_lock; exit 2' INT TERM HUP

parse_args "$@" || exit 2
main
rc=$?
release_lock
exit $rc
