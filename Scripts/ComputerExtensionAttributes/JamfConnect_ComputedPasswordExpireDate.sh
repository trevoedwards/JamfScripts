#!/bin/bash
#
# Data Type: String
# Input Type: Script
# Purpose: Displays the value of the ComputedPasswordExpireDate attribute for the Jamf Connect user.
# Copyright (c) 2022 JAMF Software, LLC
#
# Get current signed in user
currentUser=$(ls -l /dev/console | awk '/ / { print $3 }')

# com.jamf.connect.state.plist location
jamfConnectStateLocation=/Users/$currentUser/Library/Preferences/com.jamf.connect.state.plist

ComputedPasswordExpireDate=$(/usr/libexec/PlistBuddy -c "Print :ComputedPasswordExpireDate" $jamfConnectStateLocation || echo "Does not exist")
echo "ComputedPasswordExpireDate"
echo "<result>$ComputedPasswordExpireDate</result>"
