#!/bin/bash

#################################################################
# Uninstall Script for Grammarly Desktop on macOS               #
# Modified for use with Jamf App Installer                      #
# Author: Trevor Edwards                                        #
# Version: 2.0 (2025-05-15)                                     #
#################################################################

#################################################################
# CHANGELOG
# v2.0 - Replaced jamfHelper dialogs with swiftDialog
#      - Added pre-check for swiftDialog with graceful fail
#      - Enhanced logging with error output and status separation
#      - Applied custom icon via web URL for swiftDialog dialogs
#################################################################

# Jamf Parameters
# $4 = Custom log file path (e.g., /private/var/Company/Logs/UninstallGrammarly.log)
# $5 = Custom icon URL for swiftDialog (e.g., https://example.com/logo.png)

VERSION="2.0"
SWIFT_DIALOG="/usr/local/bin/dialog"
LOGFILE="${4:-/private/var/EnterpriseManagement/Logs/UninstallGrammarly.log}"
DIALOG_ICON="${5:-https://github.com/trevoedwards/JamfScripts/blob/main/ScriptResources/UninstallGrammarly.png?raw=true}"  # Set your fallback icon URL

# Ensure log directory exists
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

log "===== Starting Grammarly Uninstall Script v$VERSION ====="

# Check if swiftDialog is installed
if [ ! -x "$SWIFT_DIALOG" ]; then
    log "swiftDialog not found at $SWIFT_DIALOG. Exiting script."
    exit 1
fi

# Display start dialog with swiftDialog
"$SWIFT_DIALOG" --title "Uninstaller" \
--message "Please wait while Grammarly Desktop is being removed from your Mac. You may continue working during the process." \
--icon "$DIALOG_ICON" \
--titlefont size=20 \
--messagefont size=14 \
--button1text "OK" \
--moveable \
--mini \
--width 600 &

# Kill any Grammarly processes
pkill -i -f "Grammarly Desktop" && log "Terminated Grammarly Desktop processes." || log "No Grammarly Desktop processes found."
pkill -i -f "Grammarly" && log "Terminated any legacy Grammarly processes." || log "No legacy Grammarly processes found."

# Remove app from /Applications
for app in "/Applications/Grammarly.app" "/Applications/Grammarly Desktop.app"; do
    if [ -d "$app" ]; then
        rm -rf "$app" && log "Removed $app" || log "Failed to remove $app"
    fi
done

# Remove per-user Applications installs
for userPath in /Users/*; do
    if [ -d "$userPath/Applications/Grammarly.app" ]; then
        rm -rf "$userPath/Applications/Grammarly.app" && log "Removed $userPath/Applications/Grammarly.app"
    fi
    if [ -d "$userPath/Applications/Grammarly Desktop.app" ]; then
        rm -rf "$userPath/Applications/Grammarly Desktop.app" && log "Removed $userPath/Applications/Grammarly Desktop.app"
    fi
done

# Remove per-user Grammarly artifacts
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

    # Remove Grammarly user data
    rm -rf "$userPath/Library/Application Support/Grammarly"
    rm -rf "$userPath/Library/Caches/com.grammarly."*
    rm -f "$userPath/Library/Preferences/com.grammarly."*.plist
    rm -rf "$userPath/Library/Saved Application State/com.grammarly."*
    rm -rf "$userPath/Library/Containers/com.grammarly."*
    rm -rf "$userPath/Library/Application Scripts/com.grammarly."*
    rm -rf "$userPath/Library/Group Containers/"*grammarly*
    rm -f "$userPath/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup/Word/Grammarly.dotm"
done

# Remove system-wide Grammarly components
rm -f /Library/LaunchAgents/com.grammarly.* 2>/dev/null && log "Removed system LaunchAgents."
rm -f /Library/LaunchDaemons/com.grammarly.* 2>/dev/null && log "Removed system LaunchDaemons."
rm -f "/Library/Application Support/Microsoft/Office365/User Content.localized/Startup/Word/Grammarly.dotm" && log "Removed system Grammarly Word plug-in."
rm -rf "/Library/Application Support/Grammarly" && log "Removed /Library/Application Support/Grammarly"

# Completion dialog
"$SWIFT_DIALOG" --title "Uninstaller" \
--message "Grammarly Desktop has been successfully removed from your Mac." \
--icon "$DIALOG_ICON" \
--button1text "Close" \
--moveable \
--mini \
--width 500 &

log "===== Grammarly Uninstall Script v$VERSION Has Completed ====="

exit 0