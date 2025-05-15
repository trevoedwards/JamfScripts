#!/bin/bash

#################################################################
# Enterprise Uninstall Script for Grammarly Desktop on macOS    #
# Modified for Jamf App Installer Catalog scenario              #
# Author: Trevor Edwards                                        #
# Version: 1.9 (2025-05-15)                                     #
#################################################################

VERSION="1.9"
LOGFILE="/private/var/EnterpriseManagement/Logs/UninstallGrammarly.log"

# Check for EnterpriseManagement directory
if [ ! -d "/private/var/EnterpriseManagement/Logs" ]; then
    mkdir -p "/private/var/EnterpriseManagement/Logs"
fi
touch "$LOGFILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

JAMF_HELPER="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"

# Display start dialog
if [ -x "$JAMF_HELPER" ]; then
    "$JAMF_HELPER" -windowType utility -windowPosition center -title "Company IT" -heading "Uninstalling Grammarly Desktop" -description "Please wait while Grammarly Desktop and its components are being removed from your Mac. You may continue working." -button1 "Close" -defaultButton 1 -cancelButton 1 -button1 "Close" -defaultButton 1 -cancelButton 1 -icon /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertStopIcon.icns -alignHeading center -alignDescription left -timeout 20 -width 800 -height 300 &
fi

log "===== Starting Grammarly Uninstall Script v$VERSION ====="

# 1. Kill any Grammarly processes
pkill -i -f "Grammarly Desktop" && log "Terminated Grammarly Desktop processes." || log "No Grammarly Desktop processes found."
pkill -i -f "Grammarly" && log "Terminated any legacy Grammarly processes." || log "No legacy Grammarly processes found."

# 2. Remove app from /Applications
for app in "/Applications/Grammarly.app" "/Applications/Grammarly Desktop.app"; do
    if [ -d "$app" ]; then
        rm -rf "$app"
        log "Removed $app"
    fi
done

# 3. Remove per-user Applications installs
for userPath in /Users/*; do
    if [ -d "$userPath/Applications/Grammarly.app" ]; then
        rm -rf "$userPath/Applications/Grammarly.app"
        log "Removed $userPath/Applications/Grammarly.app"
    fi
    if [ -d "$userPath/Applications/Grammarly Desktop.app" ]; then
        rm -rf "$userPath/Applications/Grammarly Desktop.app"
        log "Removed $userPath/Applications/Grammarly Desktop.app"
    fi
done

# 4. Remove per-user Grammarly artifacts
for userPath in /Users/*; do
    if [ ! -d "$userPath" ] || [[ "$userPath" == "/Users/Shared" ]]; then
        continue
    fi

    user=$(basename "$userPath")
    log "Cleaning Grammarly data for user: $user"

    # Unload user LaunchAgents
    if ls "$userPath/Library/LaunchAgents/com.grammarly."* 1> /dev/null 2>&1; then
        for agent in "$userPath/Library/LaunchAgents/com.grammarly."*; do
            launchctl bootout gui/$(id -u "$user") "$agent" 2>/dev/null
            rm -f "$agent"
            log "Unloaded and removed $agent"
        done
    fi

    # Remove known Grammarly data locations
    rm -rf "$userPath/Library/Application Support/Grammarly"
    rm -rf "$userPath/Library/Caches/com.grammarly.*"
    rm -f "$userPath/Library/Preferences/com.grammarly.*.plist"
    rm -rf "$userPath/Library/Saved Application State/com.grammarly.*"
    rm -rf "$userPath/Library/Containers/com.grammarly.*"
    rm -rf "$userPath/Library/Application Scripts/com.grammarly.*"
    rm -rf "$userPath/Library/Group Containers/*grammarly*"

    # Remove Grammarly Word plugin if exists
    rm -f "$userPath/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup/Word/Grammarly.dotm"
done

# 5. Remove system-wide Grammarly components
rm -f /Library/LaunchAgents/com.grammarly.* 2>/dev/null && log "Removed system LaunchAgents."
rm -f /Library/LaunchDaemons/com.grammarly.* 2>/dev/null && log "Removed system LaunchDaemons."
rm -f "/Library/Application Support/Microsoft/Office365/User Content.localized/Startup/Word/Grammarly.dotm" && log "Removed system Grammarly Word plug-in."
rm -rf "/Library/Application Support/Grammarly"

log "===== Grammarly Uninstall Script v$VERSION Has Completed ====="

# Display completion dialog
if [ -x "$JAMF_HELPER" ]; then
    "$JAMF_HELPER" -windowType utility -windowPosition center -title "Company IT" -heading "Grammarly Desktop Uninstalled" -description "Grammarly Desktop has been successfully removed from your Mac." -button1 "Close" -defaultButton 1 -cancelButton 1 -button1 "Close" -defaultButton 1 -cancelButton 1 -icon /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertStopIcon.icns -alignHeading center -alignDescription left -timeout 20 -width 800 -height 300 &
fi

exit 0
