#!/bin/bash

################################################################################
# Script Name: UninstallCitrixWorkspace_swiftDialog.sh
# Version: 1.4.1
# Last Modified: 2025-05-15
# Author: Trevor Edwards
#
# Changelog:
# v1.4.1 - Converted LOG_DIR, LOG_FILE, and DIALOG_ICON to Jamf script parameters.
# v1.4.0 - Switched to swiftDialog --mini HUD for progress, added auto-close for final dialog, custom icon.
# v1.3.1 - Fixed issue with persistent swiftDialog progress window not closing.
# v1.3 - Integrated swiftDialog for user-facing progress and completion messages.
# v1.2 - Added more comprehensive application removal and orphaned file cleanup.
# v1.1 - Added log directory check and creation.
# v1.0 - Initial version for removing Citrix Workspace and logging actions.
################################################################################

VERSION="1.4.1"

# Jamf Script Parameters
PARAM_LOG_DIR="$4"
PARAM_LOG_FILE="$5"
PARAM_DIALOG_ICON="$6"

# Fallbacks if parameters are not set
LOG_DIR="${PARAM_LOG_DIR:-/private/var/EnterpriseManagement/Logs}"
LOG_FILE="${PARAM_LOG_FILE:-$LOG_DIR/UninstallCitrixWorkspace_$(date +"%Y%m%d_%H%M%S").log}"
DIALOG_ICON="${PARAM_DIALOG_ICON:-https://github.com/trevoedwards/JamfScripts/blob/main/ScriptResources/UninstallCitrixWorkspace.png?raw=true}" # Set your fallback icon URL
SWIFT_DIALOG="/usr/local/bin/dialog"
loggedInUser=$(stat -f%Su /dev/console)

# Ensure log directory exists
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"
fi

log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG_FILE"
}

# Check if swiftDialog is installed
if [ ! -x "$SWIFT_DIALOG" ]; then
    log "swiftDialog not found at $SWIFT_DIALOG. Exiting script."
    exit 1
fi

# Capture swiftDialog PID via pgrep (in case $! fails)
DIALOG_PID=$(pgrep -f "dialog.*Uninstaller")

log "===== Starting Citrix Workspace Uninstall Script v$VERSION ====="

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
DIALOG_PID=$!

# List of known Citrix Workspace paths
CITRIX_PATHS=(
    "/Applications/Citrix Workspace.app"
    "/Applications/Citrix Receiver.app"
    "$HOME/Applications/Citrix Workspace.app"
    "$HOME/Applications/Citrix Receiver.app"
    "/Library/Application Support/Citrix"
    "$HOME/Library/Application Support/Citrix"
    "/Library/Preferences/com.citrix.receiver.nomas.plist"
    "$HOME/Library/Preferences/com.citrix.receiver.nomas.plist"
    "$HOME/Library/Caches/com.citrix.receiver.nomas"
    "$HOME/Library/Logs/Citrix Receiver"
    "$HOME/Library/Logs/Citrix Workspace"
    "/Library/LaunchAgents/com.citrix.AuthManager_Mac.plist"
    "/Library/LaunchAgents/com.citrix.ServiceRecords.plist"
    "/Library/LaunchDaemons/com.citrix.ctxusbd.plist"
    "/Library/PrivilegedHelperTools/com.citrix.ctxusbd"
)

# Unload launch agents and daemons
log "Unloading Citrix launch agents and daemons..."
launch_items=(
    "com.citrix.AuthManager_Mac"
    "com.citrix.ServiceRecords"
    "com.citrix.ctxusbd"
)

for item in "${launch_items[@]}"; do
    launchctl bootout system "/Library/LaunchDaemons/$item.plist" 2>/dev/null
    launchctl bootout gui/$(id -u "$loggedInUser") "/Library/LaunchAgents/$item.plist" 2>/dev/null
    log "Attempted to unload $item"
done

# Remove known app and support paths
for path in "${CITRIX_PATHS[@]}"; do
    if [ -e "$path" ]; then
        rm -rf "$path"
        log "Removed $path"
    fi
done

# Remove package receipts
log "Removing package receipts..."
receipts=$(pkgutil --pkgs | grep -i citrix)
for receipt in $receipts; do
    pkgutil --forget "$receipt" && log "Forgot pkg receipt: $receipt"
done

log "===== Citrix Workspace Uninstall Script v$VERSION Has Completed ====="

# Kill swiftDialog to prevent hanging
if [ -n "$DIALOG_PID" ]; then
    kill "$DIALOG_PID" 2>/dev/null
    sleep 1
fi

# Final safeguard: kill all lingering swiftDialog processes
/usr/bin/killall dialog 2>/dev/null

# Completion dialog
"$SWIFT_DIALOG" --title "Uninstaller" \
--message "Citrix Workspace has been successfully removed from your Mac." \
--icon "$DIALOG_ICON" \
--button1text "Close" \
--moveable \
--mini \
--width 500 &

exit 0
