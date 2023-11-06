#!/bin/bash

# This script downloads a PDF via URL, saves it to a specified location, and then opens it. 

# Define the PDF filename AND path for the file
PDF_FILENAME="$4"

# URL of the PDF file you want to download
PDF_URL="$5"

# Checks if PDF already exists in specifed location
if [ -e "$PDF_FILENAME" ]; then
    echo "Found the PDF file at $PDF_FILENAME. Opening it..."
    open "$PDF_FILENAME"
else

    # Check if curl command is available
    if ! command -v curl &> /dev/null; then
        echo "Error: 'curl' command is not installed. Please install it to use this script."
        exit 1
    fi

    # Download the PDF file using curl
    curl -o "$PDF_FILENAME" "$PDF_URL"

    # Check if download was successful
    if [ $? -eq 0 ]; then
        echo "Download successful. The PDF file is saved at $PDF_FILENAME."

        # Open the downloaded PDF
        open "$PDF_FILENAME"
    else
        echo "Error: Download failed."
    fi
fi
