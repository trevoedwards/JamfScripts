#!/bin/bash

computerName="$4"

scutil --set HostName "$computerName"
scutil --set LocalHostName "$computerName"
scutil --set ComputerName "$computerName"

# Run Jamf binary command to update inventory record with new computer name
/usr/local/bin/jamf recon -setComputerName "$computerName"

# Echo new computer name for logging
echo "Computer Name is now set to: $computerName"
