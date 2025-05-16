#!/bin/zsh

# Data Type: String

# Get the currently logged in user
currentUser="$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )"

# Check for a logged in user and proceed with last user if needed
if [[ $currentUser == "" ]]; then
	# Set currentUser variable to the last logged in user
	currentUser=$( defaults read /Library/Preferences/com.apple.loginwindow lastUserName )
fi

# Get the current user's UID
currentUserID="$( id -u "$currentUser" )"

# Nudge plist name
nudgePlist="com.github.macadmins.Nudge.plist"

# Get the current OS version
osVersion="$( /usr/bin/sw_vers -productVersion )"

# Get the required minimum OS version from the plist
minOS="$( launchctl asuser "$currentUserID" sudo -u "$currentUser" defaults read $nudgePlist requiredMinimumOSVersion 2>/dev/null )"

# Report info from nudge plist
if [[ $minOS ]]; then
	
	# Check if OS version meets the requirement using zsh is-at-least function
	autoload is-at-least
	if is-at-least "$minOS" "$osVersion"; then
		result="macOS meets minimum required version"
	# If not up-to-date, get the number of deferrals from the plist
	else
		result="$( launchctl asuser "$currentUserID" sudo -u "$currentUser" defaults read $nudgePlist userDeferrals )"
	fi
else
	result="No minimum required macOS version found"
fi

echo "<result>${result}</result>"
