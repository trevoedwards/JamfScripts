#!/bin/bash

appToUninstall="$1"

########Functions###########
initializeUninstaller(){
    # Force Quit the app
    pgrep $1 | xargs kill -15
    
    # Remove the App
    /bin/rm -Rf "/Applications/$1.app"
}

if [[ -d "/Applications/$appToUninstall.app" ]]; then
    
    initializeUninstaller "$appToUninstall" # pass the app name to the function
    exit 0
    
else
    
    echo "Application is not installed on system."
    exit 1
    
fi
