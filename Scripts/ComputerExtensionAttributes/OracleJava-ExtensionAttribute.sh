#!/bin/bash
# shellcheck disable=SC2034  # SCRIPT_VERSION and some inventory fields are kept for parity with Uninstall-AllJava.sh
#
# OracleJava-ExtensionAttribute.sh - Jamf Pro Extension Attribute (macOS)
#
# Reports licensed Oracle/Sun Java (JDK / JRE) installed on the Mac - and nothing else. OpenJDK and the open-source
# distributions (Temurin, Zulu, Corretto, Microsoft, Liberica, SapMachine, Semeru, Homebrew openjdk, GraalVM CE,
# Oracle's own GPL builds from jdk.java.net, ...) are never reported, whatever the settings below. Read-only: it never
# changes anything, writes no files, and always exits 0. It is the standalone detection companion to Uninstall-AllJava.sh. The detection and
# classification functions below are copied verbatim from Uninstall-AllJava.sh v1.1.0, so both scripts classify
# Java identically. If you change the classification in one, regenerate or update the other.
#
# JAMF PRO SETUP
#   Settings > Computer Management > Extension Attributes > New
#     Data Type: String      Input Type: Script      Script: this file
#   Smart Group:  <EA name>  like  Found        -> scope the Uninstall-AllJava.sh policy to it
#   Optional:     <EA name>  like  Review       -> only if REPORT_REVIEW=1 below
#
# RESULT VALUES
#   None                    no licensed Oracle Java found (open-source Java may still be installed)
#   Found (N): <items>      licensed Oracle Java, i.e. what Uninstall-AllJava.sh (default vendor scope) would remove
#                           e.g. Found (2): Oracle 8 Plugin (/Library/Internet Plug-Ins/JavaAppletPlugin.plugin);
#                                Oracle 21 Bundle (/Library/Java/JavaVirtualMachines/jdk-21.jdk)
#   Review (N): <items>     only when REPORT_REVIEW=1: nothing Found, but N builds that say "Oracle Corporation" and have
#                           no licence evidence either way. These may well be OpenJDK, so they are off by default.
#   Error: <message>        invalid configuration below
#   Only Java installs are reported; pkg receipts and Homebrew casks are packaging and are not listed.
#
# WHAT IS REPORTED
#   Proprietary Oracle/Sun Java, incl. no-fee (NFTC) Oracle JDK builds and the Java browser plug-in. An install is
#   reported only when its vendor is Oracle AND there is positive Oracle-licence evidence (Oracle licence text,
#   BUILD_TYPE=commercial, Oracle bundle id / "Java SE" bundle name, an Oracle pkg receipt, a legacy jdk1.x / jre1.x
#   folder, or an SDKMAN/asdf/mise "oracle" identifier). GPL licence text always wins: such a build is never reported.
#   Oracle GraalVM (vendor "GraalVM") and runtimes bundled inside apps are not reported.
#
# CONFIGURATION
#   Jamf runs Extension Attributes without parameters, so settings are edited below. The vendor scope is fixed to
#   licensed Oracle Java and cannot be widened. If the removal policy uses parameter 6 (Keep major versions),
#   7 (Exclude) or the SkipUserProfiles option, set the same values here; otherwise the EA reports Oracle Java that
#   the policy deliberately keeps and those Macs stay in the Smart Group.

#----------------------------------------------------------------------------------------------- Configuration
KEEP_MAJOR_VERSIONS=""        # Policy $6: e.g. "17,21" - Oracle Java of these major versions is not reported
EXCLUDE_REGEX=""              # Policy $7: extended regex, case-insensitive, matched against "name | version | path | vendor"
SKIP_USER_PROFILES=0          # Policy $9 SkipUserProfiles: 1 = do not look in users' home folders
REPORT_REVIEW=0               # 1 = report "Review (N)" when nothing is Found but unconfirmed "Oracle Corporation" builds
                              #     exist. Off by default: these are often OpenJDK builds with their licence files missing.
MAX_ITEMS=10                  # list at most this many items in the result (the count is always complete)

#----------------------------------------------------------------------------------------------- Runtime
SCRIPT_VERSION="1.1.0"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec"
export PATH
shopt -s nullglob

VENDOR_ARG=""; KEEP_ARG=""; EXCLUDE_RE=""; ADDITIONAL_ARG=""
KEEP_MAJORS=(); ADDITIONAL_PATHS=()
USER_NAMES=(); USER_UIDS=(); USER_HOMES=()
USERS_LOADED=0
PROTECTED_EXTRA=()
RC_ID=(); RC_PATH=()

log() { :; }   # the shared discovery code logs; an Extension Attribute must print only its <result>

#============================================================================================== Patterns (ERE) - from Uninstall-AllJava.sh
RX_GPL="GNU GENERAL PUBLIC LICENSE|General Public License, version 2|GPLv2|GPL,? version 2|Classpath[[:space:]\"']*exception"
RX_COMMERCIAL='Oracle Free Use Terms|No[- ]Fee Terms|Technology Network License Agreement|Oracle Binary Code License|Early Adopter Development License|Commercial Features|OTN License|java\.com/(otn)?license'
RX_LEGACY_ORACLE_LEAF='^(jre|jdk|j2re|j2sdk)1\.[0-9]'
RX_TOOL_ORACLE_LEAF='(^|[-_.])oracle([-_.]|$)'
RX_JAVAISH_LEAF='^((j2re|j2sdk|jre|jdk|openjdk|zulu|corretto|amazon-corretto|liberica|libericajdk|semeru|sapmachine|graalvm|temurin|adoptopenjdk|dragonwell|microsoft-jdk|ojdkbuild|kona|bisheng)([-_.]?[0-9]|[-_.](ce|ee|jdk|jre|openj9|hotspot)([^a-z]|$)|$)|javafx[-_.]?([0-9]|sdk|runtime))'
RX_JAVA_RECEIPT='^(com\.oracle\.(jdk|jre|java)|net\.temurin|net\.adoptopenjdk|com\.azul|com\.amazon\.corretto|com\.microsoft\.(openjdk|jdk)|com\.bellsoft|com\.sap\.|com\.ibm\.semeru|org\.graalvm|com\.oracle\.graalvm|com\.redhat\.|com\.alibaba\.)'
RX_ORACLE_RECEIPT='^com\.oracle\.(jdk|jre)'
RX_JAVA_CASK='^(oracle-jdk(@[0-9]+)?|java8|temurin(@[0-9]+)?|adoptopenjdk[0-9]*|zulu(@[0-9]+)?|corretto(@[0-9]+)?|microsoft-openjdk(@[0-9]+)?|liberica-jdk[0-9]*(-full)?(-lts)?|sapmachine(-jdk)?(@[0-9]+)?|semeru-jdk-open(@[0-9]+)?|graalvm-jdk(@[0-9]+)?|graalvm-ce-java[0-9]*|dragonwell[0-9]*)$'
RX_ORACLE_CASK='^(oracle-jdk(@[0-9]+)?|java8)$'

#============================================================================================== Generic helpers - from Uninstall-AllJava.sh
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

lower() { printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]'; }

imatch() {
    local rc
    shopt -s nocasematch
    [[ $1 =~ $2 ]]; rc=$?
    shopt -u nocasematch
    return $rc
}

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


#============================================================================================== Users - from Uninstall-AllJava.sh
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


#============================================================================================== Java homes - from Uninstall-AllJava.sh
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


#============================================================================================== Inventory model - from Uninstall-AllJava.sh
reset_items() {
    ITEM_COUNT=0; LAST=-1
    I_TYPE=(); I_KIND=(); I_PATH=(); I_HOME=(); I_NAME=(); I_SOURCE=(); I_EXTRA=(); I_VENDOR=(); I_VERSION=()
    I_MAJOR=(); I_LIC=(); I_OL=(); I_EVID=(); I_INSCOPE=(); I_REASON=(); I_RESULT=()
}

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


#============================================================================================== Discovery - from Uninstall-AllJava.sh
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


#============================================================================================== Scope - from Uninstall-AllJava.sh
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

item_summary() {   # one-line description of an item for summaries / EA
    local i=$1
    printf '%s %s %s (%s)' "${I_VENDOR[$i]}" "${I_MAJOR[$i]:-?}" "${I_TYPE[$i]}" "${I_PATH[$i]:-${I_NAME[$i]}}"
}


#============================================================================================== Extension Attribute
ea_main() {
    local i found=() review=() text="" s n=0 more=0 label list
    VENDOR_ARG=""; KEEP_ARG="$KEEP_MAJOR_VERSIONS"; EXCLUDE_RE="$EXCLUDE_REGEX"; ADDITIONAL_ARG=""
    if ! resolve_parameters; then echo "<result>Error: $PARAM_ERROR</result>"; return 0; fi

    # Same discovery as Uninstall-AllJava.sh (without AdditionalPath and embedded runtimes). Receipts and casks are
    # discovered too, because they are Oracle evidence for bundles and take part in keep-linking.
    reset_items
    load_users
    discover_receipts
    discover_system_bundles
    discover_plugins
    [[ $SKIP_USER_PROFILES -eq 1 ]] || discover_user_dirs
    discover_loose
    discover_casks
    add_receipt_items
    scope_all

    for ((i = 0; i < ITEM_COUNT; i++)); do
        [[ ${I_TYPE[$i]} == Receipt || ${I_TYPE[$i]} == Homebrew ]] && continue
        if [[ ${I_INSCOPE[$i]} == 1 ]] && is_licensed_oracle "$i"; then found+=("$i")
        elif [[ ${I_VENDOR[$i]} == Oracle && ${I_REASON[$i]} == *"manual review"* ]]; then review+=("$i")
        fi
    done

    if [[ ${#found[@]} -gt 0 ]]; then label="Found"; list=("${found[@]}")
    elif [[ $REPORT_REVIEW -eq 1 && ${#review[@]} -gt 0 ]]; then label="Review"; list=("${review[@]}")
    else echo "<result>None</result>"; return 0
    fi
    for i in "${list[@]}"; do
        n=$((n + 1))
        if [[ $n -gt $MAX_ITEMS ]]; then more=$((more + 1)); continue; fi
        s=$(item_summary "$i"); text="${text:+$text; }$s"
    done
    [[ $more -gt 0 ]] && text="$text; (+$more more)"
    echo "<result>$label (${#list[@]}): $text</result>"
    return 0
}

# Lets the functions be sourced for testing without running anything.
if [[ ${BASH_SOURCE[0]} != "$0" && $JAVAREMOVAL_NO_MAIN == 1 ]]; then return 0; fi

ea_main
exit 0
