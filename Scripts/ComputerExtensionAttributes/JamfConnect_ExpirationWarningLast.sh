#!/bin/bash
#
# Data Type: String
# Input Type: Script
# Purpose: Displays the date for when the last password expiration warning was displayed for the Jamf Connect user
#
# Copyright (c) 2022 JAMF Software, LLC

# Get current signed in user
currentUser=$(ls -l /dev/console | awk '/ / { print $3 }')

# com.jamf.connect.state.plist location
jamfConnectStateLocation=/Users/$currentUser/Library/Preferences/com.jamf.connect.state.plist

ExpirationWarningLast=$(/usr/libexec/PlistBuddy -c "Print :ExpirationWarningLast" $jamfConnectStateLocation || echo "Does not exist")
echo "ExpirationWarningLast"
echo "<result>$ExpirationWarningLast</result>"
