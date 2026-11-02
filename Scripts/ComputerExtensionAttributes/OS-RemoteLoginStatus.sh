#!/bin/bash

# Author: Trevor Edwards
# Last modified: 11-01-2026
# Data Type: String
# Purpose: Displays status of Remote Login (SSH).
#
# Reads the launchd disabled-services list for com.openssh.sshd rather than using
# "systemsetup -getremotelogin", which needs Full Disk Access on macOS 10.15+ and can
# report the wrong value without it.
#
# Possible results: Enabled, Disabled

# Line looks like:  "com.openssh.sshd" => disabled
sshdState=$(/bin/launchctl print-disabled system 2>/dev/null | /usr/bin/awk -F' => ' '$1 ~ /"com\.openssh\.sshd"/ { gsub(/[^a-z]/, "", $2); print $2; exit }')

# Current macOS prints enabled/disabled; older releases print false/true (true = disabled).
# If sshd isn't listed it falls back to its launchd default, which is disabled.
case "$sshdState" in
	enabled | false) result="Enabled" ;;
	*) result="Disabled" ;;
esac

echo "<result>${result}</result>"

exit 0
