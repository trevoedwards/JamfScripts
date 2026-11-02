#!/bin/bash

# Extension Attribute to determine the number of failed login attempts during a specified duration.
# dat type: string

searchDuration="24h"  # [--last <num>[m|h|d] ]

failedLoginAttempts=$( /usr/bin/log show --last "${searchDuration}" --style syslog --predicate 'eventMessage contains "Failed to authenticate user"' | /usr/bin/wc -l | /usr/bin/tr -d ' ' )

echo "<result>$failedLoginAttempts</result>"

exit 0
