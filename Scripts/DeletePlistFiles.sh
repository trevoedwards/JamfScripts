#!/bin/bash

# Define the directory where plist files are located
# Using parameter $4 of the Jamf Script Parameters to define the folder later in a Policy:
directory="$4"

# Check if the directory exists
if [ -d "$directory" ]; then
    # Delete all plist files in the directory
    find "$directory" -type f -name "*.plist" -delete
    echo "Plist files deleted successfully."
else
    echo "Directory '$directory' does not exist."
fi
