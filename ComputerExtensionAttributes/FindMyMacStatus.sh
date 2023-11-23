#!/bin/bash

# Displays whether Find My Mac and, by extension, Activation Lock are enabled/disabled on the computer. 
# Data Type: String

fmmToken=$(/usr/sbin/nvram -x -p | /usr/bin/grep fmm-mobileme-token-FMM)

if [ -z "$fmmToken" ];
then echo "<result>Disabled</result>"
else echo "<result>Enabled</result>"
fi
