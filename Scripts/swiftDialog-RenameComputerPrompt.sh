#!/bin/bash

dialogApp="/usr/local/bin/dialog"

# Get serial number using system_profiler
serial_number=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')

title="Computer Name Prompter"
message="Please set the name of this device. \n\n Department Code + Serial Number + L/W (Laptop or Workstation). \n\n Your computer's serial number is: $serial_number"


hwType=$(/usr/sbin/system_profiler SPHardwareDataType | grep "Model Identifier" | grep "Book")  
if [ "$hwType" != "" ]; then
  icon="SF=laptopcomputer"
  else
  icon="SF=desktopcomputer"
fi #credit to https://github.com/acodega

dialogCMD="$dialogApp -p --title \"$title\" \
--icon \"$icon\" \
--message \"$message\" \
--messagefont "name=Arial,size=15" \
--small \
--button1text "Set" \
--button2 \
--ontop \
--moveable \
--textfield \"Computer Name\""

computerName=$(eval "$dialogCMD" | awk -F " : " '{print $NF}')

if [[ $computerName == "" ]]; then
  echo "Aborting"
  exit 1
fi

scutil --set HostName "$computerName"
scutil --set LocalHostName "$computerName"
scutil --set ComputerName "$computerName"

#Run Jamf binary command to update inventory record with new computer name
/usr/local/bin/jamf recon -setComputerName "$computerName"

#Echo new computer name for logging
echo "Computer Name is now $computerName"

exit 0
