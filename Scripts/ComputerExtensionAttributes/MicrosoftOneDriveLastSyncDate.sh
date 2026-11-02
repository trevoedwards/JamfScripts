#!/bin/bash

# Data Type: Date (YYYY-MM-DD hh:mm:ss)
# Purpose: Reports when OneDrive last recorded sync activity for the logged-in user's
#          work or school (Business) account, in the Mac's local time.
#
# OneDrive keeps per-account sync state in settings/Business1, Business2, ... folders and
# rewrites its sync database files there as it syncs. This EA reports the newest
# modification time of those files across both editions of the app:
#   Standalone:      ~/Library/Application Support/OneDrive/settings
#   Mac App Store:   ~/Library/Containers/com.microsoft.OneDrive-mac/Data/Library/Application Support/OneDrive/settings
# Personal accounts (settings/Personal) are not checked.
#
# Possible results:
#   YYYY-MM-DD hh:mm:ss   Last sync activity
#   No User Logged In     Nobody is logged in at the console
#   Not Installed         OneDrive.app is not in /Applications or ~/Applications
#   Not Configured        No Business account sync data found for the logged-in user
# The status strings are not dates, so they won't match date-based smart group criteria.

consoleUser=$(/bin/echo "show State:/Users/ConsoleUser" | /usr/sbin/scutil | /usr/bin/awk '$1 == "Name" && $2 == ":" { print $3; exit }')

case "$consoleUser" in
	"" | loginwindow | _mbsetupuser | root)
		echo "<result>No User Logged In</result>"
		exit 0
		;;
esac

# Home folder from the directory service (dscl wraps values that contain spaces onto a second line)
userHome=$(/usr/bin/dscl . -read "/Users/${consoleUser}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '
	NR == 1 { sub(/^NFSHomeDirectory: */, ""); if ($0 != "") { print; exit } next }
	{ sub(/^ +/, ""); print; exit }')
[ -d "$userHome" ] || userHome="/Users/${consoleUser}"

if [ ! -d "/Applications/OneDrive.app" ] && [ ! -d "${userHome}/Applications/OneDrive.app" ]; then
	echo "<result>Not Installed</result>"
	exit 0
fi

newest=0
for settingsDir in \
	"${userHome}/Library/Application Support/OneDrive/settings" \
	"${userHome}/Library/Containers/com.microsoft.OneDrive-mac/Data/Library/Application Support/OneDrive/settings"; do
	for syncFile in "$settingsDir"/Business*/*.dat "$settingsDir"/Business*/SyncEngineDatabase.db "$settingsDir"/Business*/SyncEngineDatabase.db-wal; do
		[ -f "$syncFile" ] || continue
		mtime=$(/usr/bin/stat -f %m "$syncFile" 2>/dev/null)
		case "$mtime" in
			"" | *[!0-9]*) continue ;;
		esac
		if [ "$mtime" -gt "$newest" ]; then
			newest=$mtime
		fi
	done
done

if [ "$newest" -gt 0 ]; then
	echo "<result>$(/bin/date -r "$newest" '+%Y-%m-%d %H:%M:%S')</result>"
else
	echo "<result>Not Configured</result>"
fi

exit 0
