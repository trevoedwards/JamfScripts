#!/bin/sh

#######################################################################################
# Extension Attribute: Adobe Remote Update Manager Version                            #
# Reports the installed version of RUM, or "Not Installed" if not present            #
#######################################################################################

RUM_PATH="/usr/local/bin/adobe/RemoteUpdateManager"
RESULT="Not Installed"

if [ -x "$RUM_PATH" ]; then
    RESULT=$("$RUM_PATH" --help 2>&1 | awk 'NR==1 { print $NF }')
fi

echo "<result>$RESULT</result>"
