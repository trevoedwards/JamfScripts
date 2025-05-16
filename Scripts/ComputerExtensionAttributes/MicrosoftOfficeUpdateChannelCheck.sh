#!/bin/sh

# Author: Trevor Edwards        
# Last modified: 02-12-2025
# Data Type: String

## Extension Attribute to report which update channel is being used by Microsoft AutoUpdate

## Function to read a preference value from a specified domain and key
## Arguments: $1 = domain (e.g., com.microsoft.autoupdate2), $2 = key (e.g., ChannelName)
function getPrefValue { # $1: domain, $2: key
     osascript -l JavaScript << EndOfScript
     ObjC.import('Foundation');
     ObjC.unwrap($.NSUserDefaults.alloc.initWithSuiteName('$1').objectForKey('$2'))
EndOfScript
}

## Function to determine if a preference key is being managed (via profile/MCX)
## Arguments: $1 = domain, $2 = key
function getPrefIsManaged { # $1: domain, $2: key
     osascript -l JavaScript << EndOfScript
     ObjC.import('Foundation')
     $.CFPreferencesAppValueIsForced(ObjC.wrap('$2'), ObjC.wrap('$1'))
EndOfScript
}

## Main logic starts here

# Check if Microsoft AutoUpdate is installed
if [ -d /Library/Application\ Support/Microsoft/MAU2.0/Microsoft\ AutoUpdate.app ]; then
    ChannelName=$(getPrefValue "com.microsoft.autoupdate2" "ChannelName")
    if [ "$ChannelName" = "External" ] || [ "$ChannelName" = "Preview" ]; then
    	echo "<result>Current Channel Preview</result>"
    elif [ "$ChannelName" = "InsiderFast" ] || [ "$ChannelName" = "Beta" ]; then
    	echo "<result>Beta Channel</result>"
    elif [ "$ChannelName" = "CurrentThrottle" ]; then
    	echo "<result>Monthly</result>"
    elif [ "$ChannelName" = "Internal" ]; then
    	echo "<result>Microsoft</result>"
    elif [ "$ChannelName" = "Dogfood" ]; then
    	echo "<result>Dogfood</result>"
    elif [ "$ChannelName" = "Custom" ]; then
    	ManifestServer=$(getPrefValue "com.microsoft.autoupdate2" "ManifestServer")
    	echo "<result>Custom - $ManifestServer</result>"
    else
    	echo "<result>Current Channel</result>"
    fi
else
    echo "<result>Not installed</result>"
fi

exit 0
