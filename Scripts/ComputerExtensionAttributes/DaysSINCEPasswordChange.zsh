#!/bin/zsh

# Data Type: Integer

currentUser=$(stat -f %Su /dev/console)

passwordLastSetEpoch=$(dscl . read /Users/$currentUser accountPolicyData | awk '/passwordLastSetTime/{getline; print $0}' | cut -c 8- | rev | cut -c 8- | rev | awk -F'.' '{print $1}')

daysSinceSet=$((($(date +"%s") - $passwordLastSetEpoch) / 86400))

echo "<result>$daysSinceSet</result>"
