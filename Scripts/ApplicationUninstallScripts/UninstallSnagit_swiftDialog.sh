#!/bin/bash

#################################################################
# Uninstall Script for Snagit on macOS                          #
# For use with any version of Snagit                            #
# Version: 1.3 (2025-07-24)                                     #
#################################################################

# Jamf Parameters
# $4 = Custom log file path (e.g., /private/var/Company/Logs/UninstallSnagit.log)
# $5 = Custom icon URL for swiftDialog (optional)

VERSION="1.3"
SWIFT_DIALOG="/usr/local/bin/dialog"
LOGFILE="${4:-/private/var/EnterpriseManagement/Logs/UninstallSnagit_$(date +"%Y%m%d_%H%M%S").log}"
DIALOG_ICON="${5:-https://github.com/trevoedwards/JamfScripts/blob/main/ScriptResources/UninstallSnagit.png?raw=true}" 

# Ensure log directory exists
LOGDIR="$(dirname "$LOGFILE")"
if [ ! -d "$LOGDIR" ]; then
    mkdir -p "$LOGDIR"
fi
touch "$LOGFILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

log "===== Starting Snagit Uninstall Script v$VERSION ====="

# Display initial message
"$SWIFT_DIALOG" --title "Uninstaller" \
--message "Please wait while Snagit is being removed from your Mac. You may continue working during the process." \
--icon "$DIALOG_ICON" \
--titlefont size=20 \
--messagefont size=14 \
--button1text "OK" \
--moveable \
--mini \
--width 600 &

# Kill any running Snagit processes
pkill -i -f "Snagit" && log "Terminated Snagit processes." || log "No Snagit processes found."

# Remove all Snagit apps from /Applications using wildcard
find /Applications -maxdepth 1 -type d -iname "Snagit*.app" | while read -r app; do
    rm -rf "$app" && log "Removed $app" || log "Failed to remove $app"
done

# Remove per-user Snagit apps
for userPath in /Users/*; do
    if [ -d "$userPath/Applications" ]; then
        find "$userPath/Applications" -maxdepth 1 -type d -iname "Snagit*.app" | while read -r app; do
            rm -rf "$app" && log "Removed $app from $userPath"
        done
    fi
done

# Remove user-specific data
for userPath in /Users/*; do
    if [ ! -d "$userPath" ] || [[ "$userPath" == "/Users/Shared" ]]; then continue; fi

    user=$(basename "$userPath")
    log "Cleaning Snagit data for user: $user"

    # Unload LaunchAgents
    if ls "$userPath/Library/LaunchAgents/com.techsmith.snagit"* 1> /dev/null 2>&1; then
        for agent in "$userPath/Library/LaunchAgents/com.techsmith.snagit"*; do
            launchctl bootout gui/$(id -u "$user") "$agent" 2>/dev/null
            rm -f "$agent"
            log "Unloaded and removed $agent"
        done
    fi

    # Remove Snagit-related user files
    rm -rf "$userPath/Library/Application Support/TechSmith"
    rm -rf "$userPath/Library/Preferences/com.techsmith.snagit"* 2>/dev/null
    rm -rf "$userPath/Library/Caches/com.techsmith.snagit"* 2>/dev/null
    rm -rf "$userPath/Library/Saved Application State/com.techsmith.snagit"* 2>/dev/null
    rm -rf "$userPath/Library/Containers/com.techsmith.snagit"* 2>/dev/null
    rm -rf "$userPath/Documents/Snagit" 2>/dev/null
done

# Remove system-wide files
rm -rf "/Library/Application Support/TechSmith"
rm -f /Library/LaunchAgents/com.techsmith.snagit* 2>/dev/null
rm -f /Library/LaunchDaemons/com.techsmith.snagit* 2>/dev/null

# Remove license key
if [ -d "/Users/Shared/TechSmith/Snagit" ]; then
    rm -rf "/Users/Shared/TechSmith/Snagit" && log "Removed license key directory: /Users/Shared/TechSmith/Snagit"
else
    log "License key directory not found at /Users/Shared/TechSmith/Snagit"
fi

# Remove package receipts
log "Starting package receipt cleanup for Snagit..."
receipts=$(pkgutil --pkgs | grep -i "techsmith\|snagit")

if [ -z "$receipts" ]; then
    log "No Snagit-related package receipts found."
else
    for receipt in $receipts; do
        sudo pkgutil --forget "$receipt"
        if [ $? -eq 0 ]; then
            log "Forgot package receipt: $receipt"
        else
            log "Failed to forget: $receipt"
        fi
    done
fi

# Validate that all Snagit applications are removed
log "Validating removal of Snagit applications..."

remaining_apps=$(find /Applications /Users/*/Applications -maxdepth 1 -type d -iname "Snagit*.app" 2>/dev/null)

if [ -n "$remaining_apps" ]; then
    log "ERROR: Snagit still appears to be installed:"
    log "$remaining_apps"
    "$SWIFT_DIALOG" --title "Uninstall Failed" \
    --message "Snagit could not be fully removed. Some files or applications are still present:\n\n$remaining_apps" \
    --icon "$DIALOG_ICON" \
    --button1text "Close" \
    --moveable \
    --mini \
    --width 600
else
    "$SWIFT_DIALOG" --title "Uninstaller" \
    --message "Snagit has been successfully removed from your Mac." \
    --icon "$DIALOG_ICON" \
    --button1text "Close" \
    --moveable \
    --mini \
    --width 500
    log "All Snagit applications and files removed successfully."
fi

log "===== Snagit Uninstall Script v$VERSION Has Completed ====="
exit 0
