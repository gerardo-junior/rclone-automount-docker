#!/bin/sh

# Install dependencies if not already installed
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v fusermount3 >/dev/null 2>&1; then
  echo "Installing required dependencies: curl, jq, fuse3..."
  apk update && apk add --no-cache curl jq fuse3
fi

# Set permissions for /config directory
echo "Setting permissions for /config directory..."
mkdir -p /config && chmod -R g+rwX /config

RCLONE_PORT="${RCLONE_PORT:-5572}"
RCLONE_USERNAME="${RCLONE_USERNAME:-rclone}"
RCLONE_PASSWORD="${RCLONE_PASSWORD:-rclone}"
RETRY_INTERVAL="${RETRY_INTERVAL:-2}"
RCLONE_CONFIG="${RCLONE_CONFIG:-"/config/rclone.conf"}"
MOUNTS_FILE="${MOUNTS_FILE:-"/config/mounts.json"}"
RCLONE_URL="http://127.0.0.1:${RCLONE_PORT}"

# Logging function
log() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp=$(date '+%Y/%m/%d %H:%M:%S')

  # Only show DEBUG logs if DEBUG variable is set to 1
  if [ "$level" = "DEBUG" ] && [ "${DEBUG:-0}" -ne 1 ]; then
    return
  fi

  echo "$timestamp $level: $message" >&2
}

# Function to unmount all mount points
unmount_all() {
  log "NOTICE" "Unmounting all mount points before starting..."
  if [ -f "$MOUNTS_FILE" ]; then
    jq -c '.[]' "$MOUNTS_FILE" | while IFS= read -r payload; do
      local mount_point
      mount_point=$(echo "$payload" | jq -r '.mountPoint')
      log "NOTICE" "Attempting to unmount $mount_point..."
      fusermount3 -u "$mount_point" 2>/dev/null || log "DEBUG" "Unmount failed or not mounted: $mount_point. Continuing..."
    done
  else
    log "NOTICE" "No mounts file found. Skipping unmount."
  fi
}

# Trap signals for graceful shutdown
trap 'unmount_all; kill $PID_RCLONE; exit 0' SIGTERM SIGINT

# Ensure mounts.json exists
ensure_mounts_file() {
  if [ ! -f "$MOUNTS_FILE" ]; then
    log "NOTICE" "Creating $MOUNTS_FILE with an empty array."
    mkdir -p /config
    echo '[]' > "$MOUNTS_FILE"
  fi
}

# Function to check if rclone is ready
is_rclone_ready() {
  curl -s -o /dev/null -w "%{http_code}" -u "$RCLONE_USERNAME:$RCLONE_PASSWORD" \
    -X OPTIONS "$RCLONE_URL/rc/noopauth" | grep -q "200"
}

# Function to read mount payloads
read_mount_payloads() {
  log "DEBUG" "Ensuring $MOUNTS_FILE exists."
  ensure_mounts_file

  # Check if the file is empty or invalid
  if [ ! -s "$MOUNTS_FILE" ]; then
    log "NOTICE" "$MOUNTS_FILE is empty."
    return 0
  fi

  log "DEBUG" "Checking if $MOUNTS_FILE contains valid entries."
  if ! jq -e '. | length > 0' "$MOUNTS_FILE" >/dev/null 2>&1; then
    log "NOTICE" "No valid mount entries found in $MOUNTS_FILE."
    return 0
  fi

  log "DEBUG" "Parsing JSON entries from $MOUNTS_FILE."
  jq -c '.[]' "$MOUNTS_FILE" 2>/dev/null || {
    log "ERROR" "Failed to parse JSON from $MOUNTS_FILE."
    return 1
  }
}

# Function to mount payloads
mount_payloads() {
  local all_mount_success=0  # Start with success (0 means success in shell)
  local payloads
  log "DEBUG" "Reading mount payloads."
  payloads=$(read_mount_payloads) || return 1

  # Validate if there are any payloads before proceeding
  if [ -z "$payloads" ]; then
    log "NOTICE" "No payloads to mount. Skipping mount process."
    return 0
  fi

  log "DEBUG" "Processing payloads: $payloads"
  # Loop through each payload
  echo "$payloads" | while IFS= read -r payload; do
    log "DEBUG" "Processing payload: $payload"
    local fs mount_point mount_opt vfs_opt
    fs=$(echo "$payload" | jq -r '.fs')
    mount_point=$(echo "$payload" | jq -r '.mountPoint')
    mount_opt=$(echo "$payload" | jq -c '.mountOpt // {}')
    vfs_opt=$(echo "$payload" | jq -c '.vfsOpt // {}')

    log "DEBUG" "Extracted fs: $fs, mount_point: $mount_point, mount_opt: $mount_opt, vfs_opt: $vfs_opt"

    # Validate required fields
    if [ -z "$fs" ] || [ -z "$mount_point" ]; then
      log "ERROR" "Invalid payload: $payload"
      all_mount_success=1  # Mark as failure
      continue
    fi

    # Ensure the mount point exists
    log "DEBUG" "Checking if mount point $mount_point exists."
    if [ ! -d "$mount_point" ]; then
      log "NOTICE" "Creating mount point: $mount_point"
      mkdir -p "$mount_point" 2>&1 || {
        log "ERROR" "Failed to create directory $mount_point"
        all_mount_success=1  # Mark as failure
        continue
      }
      chmod 777 "$mount_point" 2>&1 || {
        log "ERROR" "Failed to set permissions on $mount_point"
        all_mount_success=1  # Mark as failure
        continue
      }
    else
      log "DEBUG" "Mount point $mount_point already exists."
    fi

    log "NOTICE" "Mounting $fs to $mount_point..."
    response=$(curl -s -o /dev/null -w "%{http_code}" -u "$RCLONE_USERNAME:$RCLONE_PASSWORD" \
      -X POST "$RCLONE_URL/mount/mount" -H "Content-Type: application/json" \
      -d "{\"fs\":\"$fs\",\"mountPoint\":\"$mount_point\",\"mountOpt\":$mount_opt,\"vfsOpt\":$vfs_opt}")

    if [ "$response" -eq 200 ]; then
      log "NOTICE" "Mount successful."
    else
      log "ERROR" "Failed to mount $fs: HTTP status $response."
      all_mount_success=1  # Mark as failure
    fi
  done

  return $all_mount_success
}

# Initialize rclone
initialize() {
  log "NOTICE" "Waiting for rclone service to be available..."
  while ! is_rclone_ready; do
    log "NOTICE" "Rclone not ready, waiting $RETRY_INTERVAL seconds..."
    sleep "$RETRY_INTERVAL"
  done
  log "NOTICE" "Rclone is ready."

  if ! mount_payloads; then
    log "ERROR" "Failed to mount payloads."
    return 1
  fi

  log "NOTICE" "Rclone initialization complete."
  return 0
}

# Run rclone as a daemon
(
  sh -c "rclone rcd --rc-web-gui --rc-no-auth --rc-web-gui-update --rc-web-gui-force-update --rc-web-gui-no-open-browser --rc-addr :$RCLONE_PORT --rc-user $RCLONE_USERNAME --rc-pass $RCLONE_PASSWORD" &
  PID_RCLONE=$!

  # Wait a few seconds to ensure rclone is ready
  sleep $RETRY_INTERVAL

  # Unmount all before starting
  unmount_all

  # Run the initialization logic
  if ! initialize; then
    log "ERROR" "Initialization failed. Terminating rclone..."
    kill $PID_RCLONE 2>/dev/null
    exit 1
  fi

  # Wait for rclone to finish (if needed)
  wait $PID_RCLONE
) 2>&1