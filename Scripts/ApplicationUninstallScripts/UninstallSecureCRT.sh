#!/bin/bash

################################################################################
# Script to uninstall SecureCRT from macOS
# Removes application bundle, user-specific and system-wide configuration files
# Intended for use in managed environments (e.g., Jamf Pro)
################################################################################

APP_NAME="SecureCRT.app"
APP_PATH="/Applications/${APP_NAME}"

echo "Uninstalling SecureCRT..."

# Quit the app if running
if pgrep -x "SecureCRT" >/dev/null; then
    echo "SecureCRT is running, attempting to quit..."
    osascript -e 'quit app "SecureCRT"'
    sleep 3
fi

# Remove application bundle
if [ -d "$APP_PATH" ]; then
    echo "Removing ${APP_PATH}..."
    rm -rf "$APP_PATH"
else
    echo "SecureCRT not found in /Applications."
fi

# Remove system-wide support files
echo "Removing system support files..."
rm -rf /Library/Application\ Support/VanDyke/SecureCRT
rm -rf /Library/Preferences/com.vandyke.SecureCRT.plist

# Remove user-specific data
for USER_HOME in /Users/*; do
    if [ -d "$USER_HOME" ]; then
        echo "Cleaning up for user: $USER_HOME"

        rm -rf "$USER_HOME/Library/Application Support/VanDyke/SecureCRT"
        rm -f "$USER_HOME/Library/Preferences/com.vandyke.SecureCRT.plist"
        rm -f "$USER_HOME/Library/Saved Application State/com.vandyke.SecureCRT.savedState"

        # Optional: remove SecureCRT settings and logs
        rm -rf "$USER_HOME/.vandyke"
    fi
done

echo "SecureCRT has been uninstalled."

exit 0
