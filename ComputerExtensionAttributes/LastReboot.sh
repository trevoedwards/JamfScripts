#!/bin/bash

# Shows when the device was last booted
# Data Type: String

echo -n "<result>$(date -jf '%s' "$(sysctl kern.boottime | awk -F'= |,' '{print $2}')" '+%Y-%m-%d %T')</result>"

