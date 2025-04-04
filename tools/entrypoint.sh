#!/bin/sh

RCLONE_PORT="${RCLONE_PORT:-5572}"
RCLONE_USERNAME="${RCLONE_USERNAME:-rclone}"
RCLONE_PASSWORD="${RCLONE_PASSWORD:-rclone}"

[ -f /config/mounts.json ] || (mkdir -p /config && echo '{}' > /config/mounts.json)

# Run rclone as a daemon
(
  sh -c "rclone rcd --rc-web-gui --rc-web-gui-update --rc-web-gui-force-update --rc-web-gui-no-open-browser --rc-addr :$RCLONE_PORT --rc-user $RCLONE_USERNAME --rc-pass $RCLONE_PASSWORD" &
  PID_RCLONE=$!

  # Wait a few seconds to ensure rclone is ready
  sleep 5

  # Run the Python script once
  RCLONE_PORT=$RCLONE_PORT RCLONE_USERNAME=$RCLONE_USERNAME RCLONE_PASSWORD=$RCLONE_PASSWORD python /tools/rclone_initializer.py
  PYTHON_EXIT_CODE=$?

  # If the Python script fails, terminate rclone
  if [ $PYTHON_EXIT_CODE -ne 0 ]; then
    echo "Python script failed with exit code $PYTHON_EXIT_CODE. Terminating rclone..."
    kill $PID_RCLONE 2>/dev/null
    exit $PYTHON_EXIT_CODE
  fi

  # Wait for rclone to finish (if needed)
  wait $PID_RCLONE
) 2>&1