#!/bin/bash

# Store folder path as a variable
# Using parameter $4 of the Jamf Script Parameters to define the folder later in a Policy:
folder_path="$4"

# Check if the folder exists
if [ ! -d "$folder_path" ]; then
    echo "Folder $folder_path does not exist."
    exit 1
fi

# Delete the folder
rm -rf "$folder_path"

# Check if deletion was successful
if [ $? -eq 0 ]; then
    echo "Folder $folder_path deleted successfully."
else
    echo "Failed to delete folder $folder_path."
fi
