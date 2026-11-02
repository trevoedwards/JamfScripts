#!/bin/bash

# Author: Trevor Edwards
# Purpose: Creates a tag file marking that this Mac has completed your enrollment workflow.
#          Default tag: /private/var/EnterpriseManagement/Enrollment/enrollment_complete.tag
#
# Use case: Run this as the last policy in your enrollment workflow. The companion extension
# attribute (ComputerExtensionAttributes/EnrollmentCompletionTagPresent.sh) reports whether
# the tag exists, so you can build smart groups such as:
#   - Enrollment Complete:     EA is "Enrollment Complete". Scope everyday policies and
#                              Self Service items here so they don't run mid-enrollment.
#   - Enrollment Not Complete: EA is "Enrollment Not Complete". Scope enrollment/retry
#                              policies here, or use it to find Macs stuck in enrollment.
# Tick "Update Inventory" in the policy (or run "jamf recon") so the EA sees the tag straight away.
#
# Parameters:
#   $4  Tag file name (optional). Default: enrollment_complete.tag
#       The EA can't take parameters and has the default name built in. If you set $4,
#       you must also edit TAG_NAME in EnrollmentCompletionTagPresent.sh to match.

set -u

DEFAULT_TAG_NAME="enrollment_complete.tag"
TAG_NAME="${4:-$DEFAULT_TAG_NAME}"

BASE_DIR="/private/var/EnterpriseManagement/Enrollment"
TAG_PATH="${BASE_DIR}/${TAG_NAME}"

log() { /bin/echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# The tag name must be a plain file name so the tag always lands in BASE_DIR
case "${TAG_NAME}" in
  */* | . | ..)
    log "ERROR: Tag name '${TAG_NAME}' must be a plain file name (no '/')"
    exit 1
    ;;
esac

if [[ "${TAG_NAME}" != "${DEFAULT_TAG_NAME}" ]]; then
  log "NOTE: Using custom tag name '${TAG_NAME}'. EnrollmentCompletionTagPresent.sh must use the same name."
fi

# Ensure directory exists with sane permissions
if [[ ! -d "${BASE_DIR}" ]]; then
  log "Creating directory: ${BASE_DIR}"
  /bin/mkdir -p "${BASE_DIR}" || { log "ERROR: Failed to create ${BASE_DIR}"; exit 1; }
  /usr/sbin/chown root:wheel "${BASE_DIR}" || { log "ERROR: Failed to chown ${BASE_DIR}"; exit 1; }
  /bin/chmod 755 "${BASE_DIR}" || { log "ERROR: Failed to chmod ${BASE_DIR}"; exit 1; }
fi

# Write tag content (overwrites if already present)
log "Writing tag file: ${TAG_PATH}"
/usr/bin/tee "${TAG_PATH}" >/dev/null <<EOF || { log "ERROR: Failed to write ${TAG_PATH}"; exit 1; }
enrollment_complete=true
timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
serial_number=$(/usr/sbin/system_profiler SPHardwareDataType 2>/dev/null | /usr/bin/awk -F': ' '/Serial Number/{print $2; exit}')
jamf_binary_version=$(/usr/local/bin/jamf -version 2>/dev/null | /usr/bin/head -n 1)
EOF

/usr/sbin/chown root:wheel "${TAG_PATH}" || { log "ERROR: Failed to chown ${TAG_PATH}"; exit 1; }
/bin/chmod 644 "${TAG_PATH}" || { log "ERROR: Failed to chmod ${TAG_PATH}"; exit 1; }

log "Enrollment completion tag created successfully."
exit 0
