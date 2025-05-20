#!/bin/sh

#######################################################################################
# A script to collect the version of Adobe Remote Update Manager currently installed. #
# If Adobe Remote Update Manager is not installed, "Not Installed" will return back   #
#######################################################################################

RESULT="Not Installed"

if [ -f "/usr/local/bin/RemoteUpdateManager" ] ; then
    RESULT=$( /usr/local/bin/RemoteUpdateManager --help 2>&1 | /usr/bin/awk ' NR==1{ print $5 } ' )
fi

echo "<result>$RESULT</result>"
