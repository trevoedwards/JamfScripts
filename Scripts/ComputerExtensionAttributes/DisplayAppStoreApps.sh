#!/bin/sh

# Data Type: String

result=`mdfind "kMDItemAppStoreHasReceipt=1"`

echo "<result>$result</result>"
