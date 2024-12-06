#!/bin/bash

# Author: Trevor Edwards
# Purpose: This script clears any files out of the Waiting Room & Downloads folder(s) located in /Library/Application Support/JAMF
# Logs actions and errors to /var/log/jamf_cache_cleanup.log

# Directories to empty
directories=(
    "/Library/Application Support/JAMF/Downloads"
    "/Library/Application Support/JAMF/Waiting Room"
)

# Log file path
log_file="/var/log/jamf_cache_cleanup.log"

# Function to log messages
log_message() {
    local message="$1"
    echo "$(date "+%Y-%m-%d %H:%M:%S") - $message" | tee -a "$log_file"
}

# Function to empty directory
empty_directory() {
    local dir="$1"
    if [ -d "$dir" ]; then
        log_message "Emptying directory: $dir"
        rm -rf "$dir"/* 2>>"$log_file"
        if [ $? -eq 0 ]; then
            log_message "Successfully emptied: $dir"
        else
            log_message "Error: Failed to empty: $dir"
        fi
    else
        log_message "Directory does not exist: $dir"
    fi
}

# Main script execution
log_message "Starting cleanup of Jamf cache directories..."
for dir in "${directories[@]}"; do
    empty_directory "$dir"
done
log_message "Script execution completed."

