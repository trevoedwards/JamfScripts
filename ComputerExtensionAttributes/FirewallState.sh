#!/bin/bash

# Author: Trevor Edwards       
# Last modified: 12-02-2024
# Data Type: String
# Description: Displays status of Firewall 

# Check if Firewall is enabled
result=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate)
if [ "$result" == "Firewall is enabled. (State = 1)" ]; then
	echo "<result>On</result>"
else
	echo "<result>Off</result>"
fi
