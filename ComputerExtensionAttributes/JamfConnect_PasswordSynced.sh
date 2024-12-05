#!/bin/sh

# Author: Trevor Edwards        
# Last modified: 02-12-2024
# Data Type: String
# Purpose: Displays the value of the PasswordCurrent attribute (boolean value that confirms whether the user's network and local passwords are in sync) for the Jamf Connect user.

#Get current signed in user
currentUser=$(ls -l /dev/console | awk '/ / { print $3 }')

#com.jamf.connect.state.plist location
jamfConnectStateLocation=/Users/$currentUser/Library/Preferences/com.jamf.connect.state.plist

PasswordCurrent=$(/usr/libexec/PlistBuddy -c "Print :PasswordCurrent" $jamfConnectStateLocation || echo "Does not exist")
echo "PasswordCurrent"
echo "<result>$PasswordCurrent</result>"
