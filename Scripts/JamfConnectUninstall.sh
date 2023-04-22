#!/bin/zsh

#	This will uninstall Jamf Connect and reset the login window
# Created by Kyle Ericson
# https://github.com/kylejericson
#	Version 5.0

echo "Created by Kyle Ericson"
echo "email kyle@ericsontech.com"

# Get the logged in user's name
FAKE_USER=$(/bin/echo "show State:/Users/ConsoleUser" | /usr/sbin/scutil | /usr/bin/awk '/Name :/&&!/loginwindow/{print $3}')
CURRENT_USER=$(id -un $FAKE_USER)
echo "Current User is: $CURRENT_USER"

# Reset login window to default macOS
/usr/local/bin/authchanger -reset
rm /usr/local/bin/authchanger
rm /usr/local/lib/pam/pam_saml.so.2
rm -r /Library/Security/SecurityAgentPlugins/JamfConnectLogin.bundle

# Remove Jamf Connect LaunchAgents
rm -rf /Library/LaunchAgents/com.jamf.connect.plist
rm -rf /Library/LaunchAgents/com.jamf.connect.unlock.login.plist
killall 'Jamf Connect'
rm -rf "/Applications/Jamf Connect.app"

# Remove network info from user account
dscl . delete /Users/$CURRENT_USER dsAttrTypeStandard:NetworkUser
dscl . delete /Users/$CURRENT_USER dsAttrTypeStandard:OIDCProvider
dscl . delete /Users/$CURRENT_USER dsAttrTypeStandard:OktaUser
dscl . delete /Users/$CURRENT_USER dsAttrTypeStandard:AzureUser

echo "Done removing Jamf Connect"

echo "Running Inventory Update..."

jamf recon

echo "Inventory Update Complete"
exit 0
