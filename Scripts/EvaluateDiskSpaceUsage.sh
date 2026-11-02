#!/bin/bash
# Evaluate Disk Space Usage (read-only)
#
# Purpose: Show where space is going on the Data volume. Starting at
#          /System/Volumes/Data, the script measures one directory level at a
#          time and follows the largest subdirectory down, logging each step.
#          It also summarises free space, purgeable space and APFS local
#          snapshots. du can't see those, but they often explain a large
#          "System Data" figure in Storage settings.
#
#          Nothing is deleted or changed. The only files written are the log
#          and a scratch directory in /tmp that is removed on exit.
#
# Output: a short summary on stdout (the Jamf policy log) and a detailed log
#         file. Only directory paths are logged, never file names.
#
# Jamf Pro parameters:
#   $4  Log directory, absolute path.
#       Default: /private/var/EnterpriseManagement/Logs
#   $5  Maximum drill-down depth, 1-64. Default: 12
#   $6  Minimum size in MB worth drilling into, 0 or more. The drill-down stops
#       when the largest subdirectory is smaller than this. 0 = never stop
#       early. Default: 1024
#   $7  Time limit in seconds for the whole drill-down, 10-86400. Each du step
#       gets whatever time remains and is stopped when it runs out. Steps that
#       finished are still reported. Default: 600
#
# Requirements:
#   - Run as root, which Jamf does. Otherwise other users' folders can't be
#     measured.
#   - Full Disk Access. Even root can't read folders protected by macOS privacy
#     controls (TCC), such as Mail, Messages, Safari and some app containers.
#     du then under-counts them and the drill-down can follow the wrong folder.
#     Grant Full Disk Access (SystemPolicyAllFiles) to the jamf binary,
#     /usr/local/jamf/bin/jamf, with a PPPC configuration profile. The summary
#     says how many locations du could not read.
#
# Exit codes:
#   0  Finished, including when the time limit stopped the drill-down early
#      (the summary says so)
#   1  The start directory is missing, du could not measure it, or a
#      temporary file could not be created
#   2  Invalid parameter

set -u

START="/System/Volumes/Data"
AUX_TIMEOUT=30 # seconds allowed for each of tmutil and osascript

# --- Helpers ------------------------------------------------------------------

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

# Detailed line: log file only (stdout if there is no log file).
log() {
  local line
  line="$(/bin/date '+%Y-%m-%d %H:%M:%S') | $*"
  if [ -n "$LOG_FILE" ]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  else
    printf '%s\n' "$line"
  fi
}

# Summary line: stdout and the log file.
say() {
  printf '%s\n' "$*"
  if [ -n "$LOG_FILE" ]; then
    printf '%s | %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
  fi
}

die_param() {
  printf 'ERROR: %s\n' "$*"
  exit 2
}

is_number() {
  case "$1" in
    "" | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# uint_in_range VALUE MIN MAX: prints VALUE without leading zeros, or returns 1.
uint_in_range() {
  local v
  if ! is_number "$1" || [ "${#1}" -gt 9 ]; then
    return 1
  fi
  v=$((10#$1))
  if [ "$v" -lt "$2" ] || [ "$v" -gt "$3" ]; then
    return 1
  fi
  printf '%s\n' "$v"
}

human_kb() {
  /usr/bin/awk -v kb="${1:-0}" 'BEGIN {
    v = kb + 0
    if (v < 1024) { printf("%dKiB", v); exit }
    v /= 1024; if (v < 1024) { printf("%.1fMiB", v); exit }
    v /= 1024; if (v < 1024) { printf("%.1fGiB", v); exit }
    v /= 1024; printf("%.1fTiB", v)
  }'
}

# run_bounded SECONDS OUT_FILE ERR_FILE COMMAND [ARGS...]
# Runs COMMAND in the background and stops it after SECONDS.
# Returns its exit status, or 124 if it had to be stopped.
run_bounded() {
  local limit="$1" out="$2" err="$3" begun rc
  shift 3
  "$@" >"$out" 2>"$err" &
  BG_PID=$!
  begun=$SECONDS
  while kill -0 "$BG_PID" 2>/dev/null; do
    if [ $((SECONDS - begun)) -ge "$limit" ]; then
      kill -TERM "$BG_PID" 2>/dev/null
      wait "$BG_PID" 2>/dev/null
      BG_PID=""
      return 124
    fi
    /bin/sleep 1
  done
  wait "$BG_PID"
  rc=$?
  BG_PID=""
  return "$rc"
}

# Reads du output ($DU_OUT) for directory $1 and prints, tab-separated:
#   total_kb  subdir_count  subdirs_kb  largest_kb  largest_path
# total_kb and largest_kb are -1 and largest_path is "-" when missing.
parse_level() {
  /usr/bin/awk -v cur="$1" '
    BEGIN { total = -1; n = 0; sum = 0; max = -1; best = "-" }
    {
      i = index($0, "\t")
      if (i == 0) next
      kb = substr($0, 1, i - 1) + 0
      p = substr($0, i + 1)
      if (p == cur) { total = kb; next }
      n++
      sum += kb
      if (kb > max) { max = kb; best = p }
    }
    END { printf("%.0f\t%d\t%.0f\t%.0f\t%s\n", total, n, sum, max, best) }
  ' "$DU_OUT"
}

# --- Parameters ---------------------------------------------------------------

LOG_DIR="$(trim "${4:-}")"
LOG_DIR="${LOG_DIR:-/private/var/EnterpriseManagement/Logs}"
RAW_DEPTH="$(trim "${5:-}")"
RAW_MIN_MB="$(trim "${6:-}")"
RAW_LIMIT="$(trim "${7:-}")"

case "$LOG_DIR" in
  /*) ;;
  *) die_param "Parameter 4 (log directory) must be an absolute path, got '$LOG_DIR'." ;;
esac

if ! MAX_DEPTH="$(uint_in_range "${RAW_DEPTH:-12}" 1 64)"; then
  die_param "Parameter 5 (maximum depth) must be a whole number from 1 to 64, got '$RAW_DEPTH'."
fi
if ! MIN_MB="$(uint_in_range "${RAW_MIN_MB:-1024}" 0 999999999)"; then
  die_param "Parameter 6 (minimum size in MB) must be a whole number, 0 or more, got '$RAW_MIN_MB'."
fi
if ! TIME_LIMIT="$(uint_in_range "${RAW_LIMIT:-600}" 10 86400)"; then
  die_param "Parameter 7 (time limit in seconds) must be a whole number from 10 to 86400, got '$RAW_LIMIT'."
fi
MIN_KB=$((MIN_MB * 1024))

# --- Log file and scratch space -----------------------------------------------

LOG_FILE=""
if [ ! -d "$LOG_DIR" ]; then
  if /bin/mkdir -p "$LOG_DIR" 2>/dev/null; then
    /bin/chmod 0755 "$LOG_DIR" 2>/dev/null
  fi
fi
CANDIDATE="${LOG_DIR%/}/EvaluateDiskSpaceUsage_$(/bin/date '+%Y-%m-%d_%H-%M-%S').log"
if (: >>"$CANDIDATE") 2>/dev/null; then
  LOG_FILE="$CANDIDATE"
else
  say "WARNING: Can't write to $LOG_DIR. The detailed log goes to stdout instead."
fi

BG_PID=""
TMP_DIR=""
# shellcheck disable=SC2329 # called by the EXIT trap below
cleanup() {
  if [ -n "$BG_PID" ]; then
    kill -TERM "$BG_PID" 2>/dev/null
  fi
  if [ -n "$TMP_DIR" ]; then
    /bin/rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

if ! TMP_DIR="$(/usr/bin/mktemp -d /tmp/EvaluateDiskSpaceUsage.XXXXXX)"; then
  TMP_DIR=""
  say "ERROR: Could not create a temporary directory."
  exit 1
fi
DU_OUT="$TMP_DIR/du.out"
DU_ERR="$TMP_DIR/du.err"
AUX_OUT="$TMP_DIR/aux.out"
AUX_ERR="$TMP_DIR/aux.err"

log "=== START | EvaluateDiskSpaceUsage | start=$START max_depth=$MAX_DEPTH min_mb=$MIN_MB time_limit=${TIME_LIMIT}s ==="
log "macOS: $(/usr/bin/sw_vers -productVersion 2>/dev/null) ($(/usr/bin/sw_vers -buildVersion 2>/dev/null))"

say "=== Disk space summary (read-only) ==="

if [ "$EUID" -ne 0 ]; then
  say "WARNING: Not running as root. Other users' folders can't be measured."
fi

if [ ! -d "$START" ]; then
  say "ERROR: Start directory not found: $START"
  exit 1
fi

# --- Free space, purgeable space and local snapshots --------------------------

DF_TOTAL="" DF_USED="" DF_AVAIL="" DF_CAP=""
read -r DF_TOTAL DF_USED DF_AVAIL DF_CAP <<< "$(/bin/df -P -k "$START" 2>/dev/null | /usr/bin/awk 'NR == 2 { print $2, $3, $4, $5 }')"
if is_number "$DF_TOTAL" && is_number "$DF_USED" && is_number "$DF_AVAIL"; then
  say "Data volume: $(human_kb "$DF_AVAIL") free of $(human_kb "$DF_TOTAL"); this volume uses $(human_kb "$DF_USED") (${DF_CAP})"
else
  DF_AVAIL=""
  say "Data volume: free space unavailable (df failed)"
fi

# Space available for important resources = free + purgeable, as Finder and
# Storage settings count it. Subtracting df's free space estimates purgeable.
JXA_IMPORTANT_KB='ObjC.import("Foundation");
var ref = Ref();
$.NSURL.fileURLWithPath("/").getResourceValueForKeyError(ref, "NSURLVolumeAvailableCapacityForImportantUsageKey", null);
Math.floor(ObjC.unwrap(ref[0]) / 1024);'
IMPORTANT_KB=""
if run_bounded "$AUX_TIMEOUT" "$AUX_OUT" "$AUX_ERR" /usr/bin/osascript -l JavaScript -e "$JXA_IMPORTANT_KB"; then
  IMPORTANT_KB="$(trim "$(/usr/bin/head -n 1 "$AUX_OUT")")"
fi
if is_number "$IMPORTANT_KB" && [ -n "$DF_AVAIL" ]; then
  PURGEABLE_KB=$((IMPORTANT_KB - DF_AVAIL))
  if [ "$PURGEABLE_KB" -lt 0 ]; then
    PURGEABLE_KB=0
  fi
  say "Purgeable (approx.): $(human_kb "$PURGEABLE_KB"); free + purgeable: $(human_kb "$IMPORTANT_KB")"
else
  say "Purgeable: unavailable (couldn't query macOS for it)"
fi

if run_bounded "$AUX_TIMEOUT" "$AUX_OUT" "$AUX_ERR" /usr/bin/tmutil listlocalsnapshots /; then
  # Keep only snapshot names: one word per line, not the "Snapshots for ...:" header.
  SNAPSHOTS="$(/usr/bin/awk 'NF == 1 && $1 !~ /:$/ { print $1 }' "$AUX_OUT")"
  SNAP_COUNT="$(printf '%s\n' "$SNAPSHOTS" | /usr/bin/grep -c .)"
  say "APFS local snapshots on /: ${SNAP_COUNT:-0}"
  if [ "${SNAP_COUNT:-0}" -gt 0 ]; then
    shown=0
    while IFS= read -r snap; do
      if [ -z "$snap" ]; then
        continue
      fi
      shown=$((shown + 1))
      if [ "$shown" -le 5 ]; then
        say "  $snap"
      else
        log "  $snap"
      fi
    done <<< "$SNAPSHOTS"
    if [ "$SNAP_COUNT" -gt 5 ]; then
      say "  ...and $((SNAP_COUNT - 5)) more (see log)"
    fi
  fi
else
  say "APFS local snapshots on /: unavailable (tmutil failed or timed out)"
fi

# --- Drill-down ---------------------------------------------------------------

current="$START"
depth=0
start_kb=""
final_kb=""
files_kb=""
max_errors=0
max_perm=0
stop_reason=""
CHAIN=()
drill_begun=$SECONDS

while :; do
  if [ "$depth" -ge "$MAX_DEPTH" ]; then
    stop_reason="reached the maximum depth ($MAX_DEPTH)"
    break
  fi
  remaining=$((TIME_LIMIT - (SECONDS - drill_begun)))
  if [ "$remaining" -le 0 ]; then
    stop_reason="time limit (${TIME_LIMIT}s) reached; the result is incomplete"
    break
  fi

  log "Measuring $current (${remaining}s left)"
  run_bounded "$remaining" "$DU_OUT" "$DU_ERR" /usr/bin/du -k -x -d 1 "$current"
  rc=$?

  # Count du's errors without logging the paths they name.
  errors="$(/usr/bin/grep -c . "$DU_ERR")"
  perm="$(/usr/bin/grep -c -e 'Operation not permitted' -e 'Permission denied' "$DU_ERR")"
  errors="${errors:-0}"
  perm="${perm:-0}"
  if [ "$errors" -gt 0 ]; then
    log "WARN | du reported $errors error(s) under $current, $perm of them permission errors. Sizes here are under-counted."
  fi
  if [ "$errors" -gt "$max_errors" ]; then
    max_errors=$errors
  fi
  if [ "$perm" -gt "$max_perm" ]; then
    max_perm=$perm
  fi

  if [ "$rc" -eq 124 ]; then
    stop_reason="time limit (${TIME_LIMIT}s) reached while measuring $current; the result is incomplete"
    break
  fi

  IFS=$'\t' read -r total_kb subdir_count subdirs_kb best_kb best_path <<< "$(parse_level "$current")"
  if ! is_number "${total_kb:-}"; then
    if [ "$depth" -eq 0 ]; then
      say "ERROR: du could not measure $START (exit $rc)."
      exit 1
    fi
    stop_reason="du could not measure $current"
    break
  fi

  if [ "$depth" -eq 0 ]; then
    start_kb=$total_kb
    final_kb=$total_kb
  fi
  files_kb=$((total_kb - subdirs_kb))
  if [ "$files_kb" -lt 0 ]; then
    files_kb=0
  fi

  if [ "$subdir_count" -eq 0 ]; then
    stop_reason="$current has no subdirectories"
    break
  fi
  if [ "$best_kb" -lt "$MIN_KB" ]; then
    stop_reason="largest subdirectory of $current is $(human_kb "$best_kb"), below ${MIN_MB}MB"
    break
  fi
  if [ ! -d "$best_path" ]; then
    stop_reason="could not open the largest subdirectory of $current"
    break
  fi

  depth=$((depth + 1))
  pct=0
  if [ "$total_kb" -gt 0 ]; then
    pct=$((best_kb * 100 / total_kb))
  fi
  log "STEP $depth | $(human_kb "$best_kb") | $best_path (${pct}% of parent, ${subdir_count} subdir(s) at this level)"
  CHAIN+=("  $depth. $(human_kb "$best_kb")  $best_path (${pct}% of parent)")
  current="$best_path"
  final_kb=$best_kb
  files_kb="" # not known until $current itself is measured
done

# --- Summary ------------------------------------------------------------------

if [ -n "$start_kb" ]; then
  say "Drill-down from $START ($(human_kb "$start_kb") counted by du):"
else
  say "Drill-down from $START:"
fi
if [ "${#CHAIN[@]}" -gt 0 ]; then
  for line in "${CHAIN[@]}"; do
    say "$line"
  done
else
  say "  (no subdirectory was followed)"
fi
say "Stopped: $stop_reason"
if [ -n "$final_kb" ]; then
  if [ -n "$files_kb" ]; then
    say "Largest directory found: $(human_kb "$final_kb")  $current ($(human_kb "$files_kb") in files directly inside it)"
  else
    say "Largest directory found: $(human_kb "$final_kb")  $current"
  fi
fi
if [ "$max_perm" -gt 0 ]; then
  say "WARNING: du could not read $max_perm location(s) (permission errors). Sizes are under-counted and the drill-down may have followed the wrong folder. Grant Full Disk Access to the jamf binary with a PPPC profile."
elif [ "$max_errors" -gt 0 ]; then
  say "Note: du reported $max_errors other error(s), for example files removed during the scan."
fi
say "Finished in ${SECONDS}s."
if [ -n "$LOG_FILE" ]; then
  say "Log: $LOG_FILE"
fi
log "=== END | EvaluateDiskSpaceUsage ==="

exit 0
