#!/bin/bash

# Data Type: String
# Purpose: Displays the value of LastCertificateExpiration (the latest expiration date of the
#          certificates pulled from the authentication domain) for the Jamf Connect user.
#
# Possible results:
#   <value as printed by PlistBuddy>   The certificate expiration date
#   Does not exist                     No Jamf Connect state plist or no LastCertificateExpiration key
#   No User Logged In                  Nobody is logged in at the console

# Get current signed in user
currentUser=$(/bin/echo "show State:/Users/ConsoleUser" | /usr/sbin/scutil | /usr/bin/awk '$1 == "Name" && $2 == ":" { print $3; exit }')

case "$currentUser" in
	"" | loginwindow | _mbsetupuser | root)
		echo "<result>No User Logged In</result>"
		exit 0
		;;
esac

# com.jamf.connect.state.plist location
jamfConnectStateLocation="/Users/${currentUser}/Library/Preferences/com.jamf.connect.state.plist"

# Only trust PlistBuddy's output when it succeeds; it prints some errors on stdout
if [ -f "$jamfConnectStateLocation" ] &&
	LastCertificateExpiration=$(/usr/libexec/PlistBuddy -c "Print :LastCertificateExpiration" "$jamfConnectStateLocation" 2>/dev/null) &&
	[ -n "$LastCertificateExpiration" ]; then
	:
else
	LastCertificateExpiration="Does not exist"
fi

echo "<result>${LastCertificateExpiration}</result>"

exit 0
