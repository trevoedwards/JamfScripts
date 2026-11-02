#!/bin/bash

# Data Type: String
# Purpose: Reports whether the enrollment completion tag written by CreateEnrollmentCompletionTag.sh
#          is present, so smart groups can tell Macs that finished enrollment from those that haven't.
#
# Possible results:
#   Enrollment Complete       The tag file exists
#   Enrollment Not Complete   The tag file is missing (enrollment not finished, or the tag
#                             policy hasn't run on this Mac yet)
# Use the "is" operator in smart group criteria rather than "like".
#
# Extension attributes can't take parameters, so the tag name and folder are fixed here and
# must match CreateEnrollmentCompletionTag.sh. If you change the tag name there (via $4),
# edit TAG_NAME below to the same value.

TAG_NAME="enrollment_complete.tag"
BASE_DIR="/private/var/EnterpriseManagement/Enrollment"
TAG_PATH="${BASE_DIR}/${TAG_NAME}"

if [[ -f "${TAG_PATH}" ]]; then
  echo "<result>Enrollment Complete</result>"
else
  echo "<result>Enrollment Not Complete</result>"
fi
