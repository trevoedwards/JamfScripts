#!/bin/bash

#################################################################
#           Adobe Creative Cloud Apps Enterprise                #
#               Update Script for macOS 15.x                    #
#                                                               #
#                   Author: Trevor Edwards                      #
#                  Version: 1.1 (2025-05-20)                    #
#################################################################

VERSION="1.1"
LOG_DIR="/private/var/log"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/AdobeRemoteUpdateManager_${TIMESTAMP}.log"
RUM_PATH="/usr/local/bin/adobe/RemoteUpdateManager"
CLOUD_APPS_PATH="/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app"
LOG_RETENTION_DAYS=60
EXIT_CODE=0

echo "Adobe RUM Script (v$VERSION) starting..." | tee -a "$LOG_FILE"
echo "Log file will be saved to: $LOG_FILE" | tee -a "$LOG_FILE"

# Ensure log directory exists - uncomment this if you're using a custom log directory
#if [ ! -d "$LOG_DIR" ]; then
#    echo "Creating log directory: $LOG_DIR" | tee -a "$LOG_FILE"
#    mkdir -p "$LOG_DIR"
#else
#    echo "Log directory exists: $LOG_DIR" | tee -a "$LOG_FILE"
#fi

echo "========== Adobe RUM Script (v$VERSION) Started: $(date) ==========" | tee -a "$LOG_FILE"

# Step 1: Clean up old logs
echo "Cleaning old logs >$LOG_RETENTION_DAYS days..." | tee -a "$LOG_FILE"
find "$LOG_DIR" -type f -name "*.log" -mtime +$LOG_RETENTION_DAYS -exec rm {} \; 2>> "$LOG_FILE"

# Step 2: Check if Creative Cloud is installed
if [ -d "$CLOUD_APPS_PATH" ]; then
    CC_VERSION=$(defaults read "$CLOUD_APPS_PATH/Contents/Info.plist" CFBundleVersion 2>/dev/null)
    echo "✔️ Creative Cloud installed, version: $CC_VERSION" | tee -a "$LOG_FILE"
else
    echo "⚠️ Creative Cloud is not installed." | tee -a "$LOG_FILE"
    # Still proceed with RUM, as some components may still be updatable
fi

# Step 3: Kill Creative Cloud processes
echo "Checking for Creative Cloud processes..." | tee -a "$LOG_FILE"
if pkill -f "Creative Cloud"; then
    echo "✔️ Creative Cloud processes killed." | tee -a "$LOG_FILE"
else
    echo "No Creative Cloud processes running." | tee -a "$LOG_FILE"
fi

# Step 4: Run RUM
if [ -x "$RUM_PATH" ]; then
    echo "Running Adobe RemoteUpdateManager..." | tee -a "$LOG_FILE"

    RUM_OUTPUT=$("$RUM_PATH" 2>&1)
    echo "$RUM_OUTPUT" | tee -a "$LOG_FILE"

    echo "Parsing RUM output for updated apps..." | tee -a "$LOG_FILE"
    UPDATED_LINES=$(echo "$RUM_OUTPUT" | grep -E "Updating|Update completed")

    if [ -n "$UPDATED_LINES" ]; then
        echo "✅ Updates were applied:" | tee -a "$LOG_FILE"
        echo "$UPDATED_LINES" | tee -a "$LOG_FILE"
        EXIT_CODE=0
    else
        echo "ℹ️ No updates were available." | tee -a "$LOG_FILE"
        EXIT_CODE=0
    fi
else
    echo "❌ ERROR: RUM not found at $RUM_PATH" | tee -a "$LOG_FILE" >&2
    EXIT_CODE=1
fi

echo "✅ Adobe RUM Script complete. Log saved to: $LOG_FILE" | tee -a "$LOG_FILE"
echo "========== Adobe RUM Script (v$VERSION) Finished: $(date) ==========" | tee -a "$LOG_FILE"

exit $EXIT_CODE
