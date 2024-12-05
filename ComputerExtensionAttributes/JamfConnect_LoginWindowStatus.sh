#!/bin/sh

# Author: Trevor Edwards        
# Last modified: 02-12-2024
# Data Type: String
# Purpose: Checks for and displays status of Jamf Connect Login Window. 

if /usr/bin/security authorizationdb read "system.login.console" | /usr/bin/grep -q "JamfConnectLogin:LoginUI"; then
	result="Enabled"
else
	result="Disabled"
fi
echo "<result>$result</result>"
