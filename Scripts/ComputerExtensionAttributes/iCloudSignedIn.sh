#!/bin/bash

# Data Type: String
# Purpose: Displays whether the logged-in user is signed in to iCloud with an Apple Account.
#
# Reads the Accounts array from the user's ~/Library/Preferences/MobileMeAccounts.plist,
# running "defaults" as that user so it sees the live value from cfprefsd. The Apple ID
# itself is personal data and is never reported.
#
# Possible results:
#   Signed In           An iCloud account is configured for the logged-in user
#   Not Signed In       No iCloud account found for the logged-in user
#   No User Logged In   Nobody is logged in at the console

consoleUser=$(/bin/echo "show State:/Users/ConsoleUser" | /usr/sbin/scutil | /usr/bin/awk '$1 == "Name" && $2 == ":" { print $3; exit }')

case "$consoleUser" in
	"" | loginwindow | _mbsetupuser | root)
		echo "<result>No User Logged In</result>"
		exit 0
		;;
esac

consoleUID=$(/usr/bin/id -u "$consoleUser" 2>/dev/null)
accounts=""

if [ -n "$consoleUID" ]; then
	accounts=$(/bin/launchctl asuser "$consoleUID" /usr/bin/sudo -u "$consoleUser" /usr/bin/defaults read MobileMeAccounts Accounts 2>/dev/null)
fi

# Signed in when at least one account entry has a non-empty AccountID
if printf '%s\n' "$accounts" | /usr/bin/grep -Eq '^[[:space:]]*AccountID = "?[^";[:space:]]'; then
	echo "<result>Signed In</result>"
else
	echo "<result>Not Signed In</result>"
fi

exit 0
