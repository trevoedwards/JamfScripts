#!/bin/bash

#################################################################
# Uninstall Script for Grammarly Desktop on macOS               #
# Modified for use with Jamf App Installer                      #
# Author: Trevor Edwards                                        #
# Version: 2.1 (2025-06-02)                                     #
#################################################################

#################################################################
# CHANGELOG
# v2.1 - Replaced jamfHelper dialogs with swiftDialog
#      - Added pre-check for swiftDialog with graceful fail
#      - Enhanced logging with error output and status separation
#      - Applied custom icon via web URL for swiftDialog dialogs
#################################################################

VERSION="2.1"

# Jamf Script Parameters
PARAM_LOG_DIR="$4"
PARAM_LOG_FILE="$5"
PARAM_DIALOG_ICON="$6"

# Fallbacks if parameters are not set
LOG_DIR="${PARAM_LOG_DIR:-/private/var/EnterpriseManagement/Logs}"
LOG_FILE="${PARAM_LOG_FILE:-$LOG_DIR/UninstallGrammarly_$(date +"%Y%m%d_%H%M%S").log}"
DIALOG_ICON="${PARAM_DIALOG_ICON:-https://github.com/trevoedwards/JamfScripts/blob/main/ScriptResources/UninstallGrammarly.png?raw=true}" # Set your fallback icon URL
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

log "===== Starting Grammarly Uninstall Script v$VERSION ====="

# Display start dialog with swiftDialog
"$SWIFT_DIALOG" --title "Uninstaller" \
--message "Please wait while Grammarly is being removed from your Mac. You may continue working during the process." \
--icon "$DIALOG_ICON" \
--titlefont size=20 \
--messagefont size=14 \
--button1text "OK" \
--moveable \
--mini \
--width 600 &
DIALOG_PID=$!

# Known Grammarly paths
GRAMMARLY_PATHS=(
    "/Applications/Grammarly.app"
    "/Applications/Grammarly Desktop.app"
    "$HOME/Applications/Grammarly.app"
    "$HOME/Applications/Grammarly Desktop.app"
    "$HOME/Library/Application Support/Grammarly"
    "$HOME/Library/Caches/com.grammarly.macdesktop"
    "$HOME/Library/Caches/com.grammarly.ProjectLlama"
    "$HOME/Library/Logs/Grammarly"
    "$HOME/Library/Preferences/com.grammarly.macdesktop.plist"
    "$HOME/Library/Preferences/com.grammarly.ProjectLlama.plist"
    "$HOME/Library/Saved Application State/com.grammarly.macdesktop.savedState"
    "$HOME/Library/Saved Application State/com.grammarly.ProjectLlama.savedState"
    "/Library/PrivilegedHelperTools/com.grammarly.macdesktop.updater"
)

# Unload potential Grammarly launch agents or daemons
log "Unloading Grammarly launch agents and daemons..."
launch_items=(
    "com.grammarly.macdesktop.updater"
)

for item in "${launch_items[@]}"; do
    launchctl bootout system "/Library/LaunchDaemons/$item.plist" 2>/dev/null
    launchctl bootout gui/$(id -u "$loggedInUser") "/Library/LaunchAgents/$item.plist" 2>/dev/null
    log "Attempted to unload $item"
done

# Remove Grammarly files and directories
for path in "${GRAMMARLY_PATHS[@]}"; do
    if [ -e "$path" ]; then
        rm -rf "$path"
        log "Removed $path"
    fi
done

# Remove package receipts if applicable
log "Removing package receipts..."
receipts=$(pkgutil --pkgs | grep -i grammarly)
for receipt in $receipts; do
    pkgutil --forget "$receipt" && log "Forgot pkg receipt: $receipt"
done

log "===== Grammarly Uninstall Script v$VERSION Has Completed ====="

# Kill swiftDialog to prevent hanging
if [ -n "$DIALOG_PID" ]; then
    kill "$DIALOG_PID" 2>/dev/null
    sleep 1
fi

/usr/bin/killall dialog 2>/dev/null

# Completion dialog
"$SWIFT_DIALOG" --title "Uninstaller" \
--message "Grammarly has been successfully removed from your Mac." \
--icon "$DIALOG_ICON" \
--button1text "Close" \
--moveable \
--mini \
--width 500 &

exit 0
