#!/bin/sh

# Author: Trevor Edwards        
# Last modified: 02-12-2024
# Data Type: String
# Purpose: Displays the version number for the currently installed Jamf Connect menu bar app.

#Jamf Connect 2.0 Location
 jamfConnectLocation="/Applications/Jamf Connect.app"
 
 jamfConnectVersion=$(defaults read "$jamfConnectLocation"/Contents/Info.plist "CFBundleShortVersionString" || echo "Does not exist")
echo "jamfConnectVersion"
echo "<result>$jamfConnectVersion</result>"
