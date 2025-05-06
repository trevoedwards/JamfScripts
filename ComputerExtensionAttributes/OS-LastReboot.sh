#!/bin/bash

# Last modified: 05-5-2025
# Data Type: String
# Purpose: Shows when the device was last booted

echo -n "<result>$(date -jf '%s' "$(sysctl kern.boottime | awk -F'= |,' '{print $2}')" '+%Y-%m-%d %T')</result>"
