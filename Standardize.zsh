#!/bin/zsh

#
#  ____  _                  _               _ _         
# / ___|| |_ __ _ _ __   __| | __ _ _ __ __| (_)_______ 
# \___ \| __/ _` | '_ \ / _` |/ _` | '__/ _` | |_  / _ \
#  ___) | || (_| | | | | (_| | (_| | | | (_| | |/ /  __/
# |____/ \__\__,_|_| |_|\__,_|\__,_|_|  \__,_|_/___\___| 
#

# Name: Standardize for macOS    
# Author: Trevor Edwards        
# Last modified: 3-3-2023                      
          

# THE LAST PORTION OF THIS SCRIPT IS DEPENDANT ON DOCKUTIL BEING INSTALLED
# GET IT HERE: https://github.com/kcrawford/dockutil/releases

# Quick script to standardize some user settings of macOS for a corporate environment.
# Feel free to modify as necessary.

sleep 5

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

###############################################
#### GATHER INFORMATION & COMPLETE PRE-WORK ###
###############################################

# Close any open System Settings panes
osascript -e 'tell application "System Settings" to quit'
echo "Closing System Settings..."

# Get the currently logged in user
currentUser=$( echo "show State:/Users/ConsoleUser" | scutil | awk '/Name :/ { print $3 }' )
echo "Getting Currently Logged-In User..."

# Get UID logged in user
uid=$(id -u "${currentUser}")
echo "Getting UID of Logged-In User..."

# Current User home folder - do it this way in case the folder isn't in /Users
userHome=$(dscl . -read /users/${currentUser} NFSHomeDirectory | cut -d " " -f 2)
echo "Getting Current User's Home Folder Location..."

# Path to plist
plist="${userHome}/Library/Preferences/com.apple.dock.plist"
echo "Getting Path to Plist..."

############################
#### FINDER PREFERENCES ####
############################

# Use list view in all Finder windows by default. Other view modes: 'icnv', 'clmv', 'Flwv'.
defaults write com.apple.finder FXPreferredViewStyle -string 'Nlsv'
echo "Defaulting Finder Windows to List View..."

# Keep folders at the top of the list when sorting by name
defaults write com.apple.finder _FXSortFoldersFirst -bool true
echo "Keep Folders at Top of List when Sorting by Name..."

# Save dialogs default to local instead of iCloud
defaults write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false
echo "Setting Default Save Location to Local..."

# Avoid creating .DS_Store files on network & USB volumes
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true
echo "Disabling Creation of .DS_Store Files on Network & USB Volumes..."

# Save screen captures in `Pictures/Screenshots` instead of `Desktop`
mkdir "$userHome/Pictures/Screenshots"
defaults write com.apple.screencapture location -string "$userHome/Pictures/Screenshots"
echo "Changing Default Screenshot Location to /Pictures/Screenshots..."

# Save screenshots in PNG format (other options: BMP, GIF, JPG, PDF, TIFF)
defaults write com.apple.screencapture type -string "PNG"
echo "Setting Default Screenshot Type to PNG..."

# Restart SystemUIServer, so changes to screen capture settings will take effect
killall SystemUIServer
echo "Restarting SystemUIServer..."

################################################
#### PRIVACY & SECURITY RELATED PREFERENCES ####
################################################

# Unlock system preferences panes for standard user editing
security authorizationdb write system.preferences allow
security authorizationdb write system.services.systemconfiguration.network allow
security authorizationdb write system.preferences.timemachine allow
security authorizationdb write system.preferences.network allow
security authorizationdb write system.preferences.energysaver allow
security authorizationdb write system.preferences.printing allow
security authorizationdb write system.preferences.datetime allow
echo "Success! Unlocked System Settings Panes for Standard Users..."

# Enable Gatekeeper: App Store and Identified Developers
sudo spctl --master-enable
sudo spctl --enable
echo "Enabling Gatekeeper..."

# Disable sending diagnostic data to Apple
defaults write "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" AutoSubmit -bool false
defaults write "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" SeedAutoSubmit -bool false
defaults write "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" AutoSubmitVersion -integer 4
echo "Disabling Sending of Diagnostic Data to Apple..."
    
# Disable sending diagnostic data to Third-Party Developers
defaults write "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" ThirdPartyDataSubmit -bool false
defaults write "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" ThirdPartyDataSubmitVersion -integer 4
echo "Disabling Sending of Diagnostic Data to Developers..."

# Add users to CUPS permissions group so everyone can pause/resume printing services
dseditgroup -o edit -a everyone -t group _lpadmin
echo "Adding All Local Users to lpadmin Group..."

# Disable Resume system-wide
defaults write com.apple.systempreferences NSQuitAlwaysKeepsWindows -bool false
echo "Disabling System-Wide Resume..."

##########################
#### DOCK PREFERENCES ####
##########################

# Checking for Dock
until [[ $(pgrep Dock) ]]; do
    wait
done
echo "Confirming Dock is running..."

# Disable animations when opening an application from the Dock
defaults write com.apple.dock launchanim -bool false
echo "Disabling Application Animations on Dock..."

# Path to plist
plist="${userHome}/Library/Preferences/com.apple.dock.plist"

# Convenience function to run a command as the current user
# usage: runAsUser command arguments...
runAsUser() {  
	if [[ "${currentUser}" != "loginwindow" ]]; then
		launchctl asuser "$uid" sudo -u "${currentUser}" "$@"
	else
		echo "no user logged in"
		exit 1
	fi
}
echo "Performing Check to Run a Command as Current User..."

# Check if dockutil is installed
if [[ -x "/usr/local/bin/dockutil" ]]; then
    dockutil="/usr/local/bin/dockutil"
else
    echo "dockutil not installed in /usr/local/bin, exiting out of final configuration..."
    exit 1
fi

# Version dockutil
dockutilVersion=$(${dockutil} --version)
echo "Dockutil Version = ${dockutilVersion}"

# Create a clean Dock
runAsUser "${dockutil}" --remove all --no-restart ${plist}
echo "Clearing Out Default Dock..."

# Disable show recently opened on Dock
runAsUser defaults write com.apple.dock show-recents -bool FALSE
echo "Hiding Recent Items from Dock..."

# Full path to Applications to add to the Dock
echo "Adding Applications to Dock..."
apps=(
"/Applications/Self Service.app"
"/System/Applications/Launchpad.app"
"/Applications/Google Chrome.app"
"/Applications/Safari.app"
"/Applications/Microsoft Outlook.app"
"/Applications/OneDrive.app"
"/System/Applications/System Settings.app"
)

# Loop through Apps and check if App is installed, If Installed at App to the Dock.
for app in "${apps[@]}"; 
do
	if [[ -e ${app} ]]; then
		runAsUser "${dockutil}" --add "$app" --no-restart ${plist};
	else
		echo "${app} not installed"
    fi
done

# Restart the Dock
killall -KILL Dock
echo "Dock Configuration Successful!"

sleep 2

echo "Actions Completed, Exiting Script..."

exit 0
