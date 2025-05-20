#!/bin/bash

#################################################################
#           Unified Adobe Creative Cloud Apps Updater           #
#               Update Script for macOS 15.x                    #
#                                                               #
# - RemoteUpdateManager (RUM) for enterprise-managed Adobe apps #
# - AdobeUpdateServiceMgr (AUService) for user-installed apps   #
# - Compatible with Jamf Pro deployments                        # 
#                                                               #
#                   Author: Trevor Edwards                      #
#                  Version: 1.1 (2025-05-20)                    #
#################################################################

VERSION="2.0"
LOG_DIR="/private/var/log"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/AdobeUpdate_${TIMESTAMP}.log"
RUM_PATH="/usr/local/bin/adobe/RemoteUpdateManager"
CLOUD_APPS_PATH="/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app"
LOG_RETENTION_DAYS=60
LOGGED_IN_USER=$(stat -f "%Su" /dev/console)
USER_UID=$(id -u "$LOGGED_IN_USER")
EXIT_CODE=0

# ===================== Logging Setup =====================
echo "🔧 Adobe Update Script v$VERSION starting..." | tee -a "$LOG_FILE"
echo "Logging to: $LOG_FILE" | tee -a "$LOG_FILE"
# Ensure log directory exists - uncomment this if you're using a custom log directory
#if [ ! -d "$LOG_DIR" ]; then
#    echo "Creating log directory: $LOG_DIR" | tee -a "$LOG_FILE"
#    mkdir -p "$LOG_DIR"
#else
#    echo "Log directory exists: $LOG_DIR" | tee -a "$LOG_FILE"
#fi

echo "======== Script Start: $(date) ========" | tee -a "$LOG_FILE"

# Clean up old logs
echo "🧹 Cleaning logs older than $LOG_RETENTION_DAYS days..." | tee -a "$LOG_FILE"
find "$LOG_DIR" -type f -name "*.log" -mtime +$LOG_RETENTION_DAYS -exec rm {} \; 2>> "$LOG_FILE"

# ===================== Pre-Update App Versions =====================
echo -e "\n== 📋 Installed Adobe Apps (Pre-Update) ==" | tee -a "$LOG_FILE"
find /Applications -maxdepth 1 -name "Adobe*" | while read APP; do
    VER=$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
    if [[ -n "$VER" ]]; then
        echo "$(basename "$APP") - v$VER" | tee -a "$LOG_FILE"
    fi
done
echo "----------------------------------------" | tee -a "$LOG_FILE"

#####################################
# Step 1: Run RemoteUpdateManager   #
#####################################

if [ -x "$RUM_PATH" ]; then
    echo "Running RemoteUpdateManager for enterprise apps..." | tee -a "$LOG_FILE"
    RUM_OUTPUT=$("$RUM_PATH" 2>&1)
    echo "$RUM_OUTPUT" | tee -a "$LOG_FILE"

    echo "Parsing RUM output..." | tee -a "$LOG_FILE"
    UPDATED_LINES=$(echo "$RUM_OUTPUT" | grep -E "Updating|Update completed")

    if [ -n "$UPDATED_LINES" ]; then
        echo "✅ RUM applied updates:" | tee -a "$LOG_FILE"
        echo "$UPDATED_LINES" | tee -a "$LOG_FILE"
    else
        echo "ℹ️ RUM found no applicable updates." | tee -a "$LOG_FILE"
    fi
else
    echo "❌ RemoteUpdateManager not found at $RUM_PATH" | tee -a "$LOG_FILE" >&2
fi

#####################################################
# Step 2: Trigger AdobeUpdateServiceMgr (AUService) #
#####################################################

if [[ "$LOGGED_IN_USER" != "root" && -n "$LOGGED_IN_USER" ]]; then
    # Check if AUService is loaded for the user
    PLIST_PATH="/Users/$LOGGED_IN_USER/Library/LaunchAgents/com.adobe.AdobeUpdateServiceMgr.plist"

    if [[ -f "$PLIST_PATH" ]]; then
        echo "🔄 Restarting AdobeUpdateServiceMgr for user: $LOGGED_IN_USER" | tee -a "$LOG_FILE"
        su -l "$LOGGED_IN_USER" -c "/bin/launchctl kickstart -k gui/$USER_UID/com.adobe.AdobeUpdateServiceMgr" 2>&1 | tee -a "$LOG_FILE"
        echo "📡 AUService successfully triggered." | tee -a "$LOG_FILE"
    else
        echo "⚠️ AdobeUpdateServiceMgr agent not found for $LOGGED_IN_USER. Has Creative Cloud been launched?" | tee -a "$LOG_FILE"
    fi
else
    echo "⚠️ No GUI user session found — cannot trigger AUService." | tee -a "$LOG_FILE"
fi

echo "✅ Adobe update tasks completed." | tee -a "$LOG_FILE"
echo "======== Script Complete: $(date) ========" | tee -a "$LOG_FILE"
exit $EXIT_CODE
