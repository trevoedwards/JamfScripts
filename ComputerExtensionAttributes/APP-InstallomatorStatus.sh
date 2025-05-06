#!/bin/sh

# Author: Trevor Edwards        
# Last modified: 05-5-2025
# Data Type: String
# Purpose: Checks if Installomator is installed at default location for AppAutoPatch 3.x 
# Installomator's default location is: /usr/local/Installomator/Installomator.sh
# Find more AppAutoPatch related EA's here: https://github.com/App-Auto-Patch/App-Auto-Patch/tree/main/AAP-JamfProEAs

# Path to expected Installomator script
installomatorPath="/Library/Management/AppAutoPatch/Installomator/Installomator.sh"

if [[ -x "$installomatorPath" ]]; then
    echo "<result>Installed</result>"
else
    echo "<result>Not Installed</result>"
fi
