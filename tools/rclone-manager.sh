#!/bin/sh

RCLONE_PORT="${RCLONE_PORT:-5572}"
RCLONE_USERNAME="${RCLONE_USERNAME:-rclone}"
RCLONE_PASSWORD="${RCLONE_PASSWORD:-rclone}"
RCLONE_OPTS="${RCLONE_OPTS:-"--check-first --update --tpslimit 5"}"
RCLONE_CONFIG="${RCLONE_CONFIG:-"/config/rclone.conf"}"
RCLONE_URL="http://127.0.0.1:${RCLONE_PORT}"
RETRY_INTERVAL="${RETRY_INTERVAL:-2}"
MOUNTS_FILE="${MOUNTS_FILE:-"/config/mounts.json"}"
TASKS_FILE="${TASKS_FILE:-"/config/tasks.json"}"
CACHE_DIR="${CACHE_DIR:-"/cache"}"
TASK_RUNNING_FILE="${TASK_RUNNING_FILE:-"${CACHE_DIR}/tasks_running"}"

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

# Function to make a curl request with common configurations
make_curl_request() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    shift 3  # Remove os três primeiros argumentos

    if [ -n "$data" ]; then
        # Se o terceiro parâmetro não estiver vazio, inclua -d e -H
        curl -s --connect-timeout 0 --max-time 0 -u "$RCLONE_USERNAME:$RCLONE_PASSWORD" \
        -X "$method" "$RCLONE_URL/$endpoint" \
        -H "Content-Type: application/json" \
        -d "$data" "$@"
    else
        # Caso contrário, não inclua -d e -H
        curl -s --connect-timeout 0 --max-time 0 -u "$RCLONE_USERNAME:$RCLONE_PASSWORD" \
        -X "$method" "$RCLONE_URL/$endpoint" \
        "$@"
    fi
}

# Function to unmount all mount points
unmount_all() {
  if [ -f "$MOUNTS_FILE" ]; then
    if jq -e '.[]' "$MOUNTS_FILE" >/dev/null 2>&1; then
      log "NOTICE" "Unmounting all mount points before starting..."
      jq -c '.[]' "$MOUNTS_FILE" | while IFS= read -r payload; do
        local mount_point
        mount_point=$(echo "$payload" | jq -r '.mountPoint')
        log "DEBUG" "Attempting to unmount $mount_point..."
        fusermount3 -u "$mount_point" 2>/dev/null || log "DEBUG" "Unmount failed or not mounted: $mount_point. Continuing..."
      done
    else
      log "NOTICE" "No valid entries found in mounts file. Skipping unmount."
    fi
  else
    log "NOTICE" "No mounts file found. Skipping unmount."
  fi
}

# Function for graceful shutdown
graceful_shutdown() {
    local exit_code="${1:-0}"  # Default exit code is 0

    log "NOTICE" "Performing graceful shutdown..."

    # Unmount all mount points
    unmount_all

    # Kill Rclone daemon if running
    if [ -n "$PID_RCLONE" ] && kill -0 "$PID_RCLONE" 2>/dev/null; then
        log "NOTICE" "Stopping Rclone daemon..."
        kill "$PID_RCLONE" 2>/dev/null
    fi

    # Kill Cron daemon if running
    if [ -n "$PID_CROND" ] && kill -0 "$PID_CROND" 2>/dev/null; then
        log "NOTICE" "Stopping Cron daemon..."
        kill "$PID_CROND" 2>/dev/null
    fi

    log "NOTICE" "Shutdown complete. Exiting with code $exit_code."
    exit "$exit_code"
}

# Trap signals for graceful shutdown
trap 'graceful_shutdown' SIGTERM SIGINT

ensure_file_exists() {
    local file_path="$1"

    log "DEBUG" "Ensuring $file_path exists."

    if [ -z "$file_path" ]; then
        log "ERROR" "No file path provided to ensure_file_exists."
        graceful_shutdown 1
    fi

    if [ ! -f "$file_path" ]; then
        log "NOTICE" "Creating $file_path with an empty array."
        mkdir -p "$(dirname "$file_path")"
        echo '[]' > "$file_path"
    elif ! jq empty "$file_path" >/dev/null 2>&1; then # Verify if the file contains valid JSON
        log "ERROR" "The file $file_path contains invalid JSON. Exiting..."
        graceful_shutdown 1
    fi
}

# Function to check if rclone is ready
is_rclone_ready() {
    local response_code
    response_code=$(make_curl_request "OPTIONS" "rc/noopauth" "" -w "%{http_code}" -o /dev/null)

    if [ "$response_code" -eq 200 ]; then
        return 0  # Rclone está pronto
    else
        return 1  # Rclone não está pronto
    fi
}

# Function to execute a task and log its output
execute_task() {
    local payload="$1"

    # Extract variables from the payload
    local command srcFs dstFs opts
    command=$(echo "$payload" | jq -r '.command')
    srcFs=$(echo "$payload" | jq -r '.opts.srcFs')
    dstFs=$(echo "$payload" | jq -r '.opts.dstFs')
    opts=$(echo "$payload" | jq -c '.opts')

    # Validate required fields
    if [ -z "$command" ] || [ -z "$srcFs" ] || [ -z "$dstFs" ]; then
        log "ERROR" "Invalid payload: $payload"
        return 1
    fi

    # Generate a task identifier (MD5 hash)
    local task_id
    task_id="$command $srcFs -> $dstFs"

    local tasks_running;
    tasks_running=$(tac $TASK_RUNNING_FILE | awk '{
            key = $0;                  # salva linha completa
            sub(/ [0-9]+$/, "", key);  # remove número final só pra comparação
            if (!seen[key]++) {
                linhas[key] = $0       # salva a linha original (com número) da última ocorrência
            }
        }
        END {
            for (k in linhas) print linhas[k]
        }' | tac | grep "$task_id");

    # Check if the task is already running
    local matched_line
    matched_line=$(echo "$tasks_running" | grep -F "$task_id")

    if [ -n "$matched_line" ]; then
        local job_id
        job_id=$(echo "$matched_line" | awk '{print $NF}')

        # Check the status of the existing job
        local job_info
        job_info=$(make_curl_request "POST" "job/status?jobid=$job_id" "")

        # Verifica se houve erro (ex: job não encontrado)
        if [ -z "$job_info" ]; then
            log "DEBUG" "Job ID $job_id not found or failed to fetch status. Proceeding to re-execute task."
        else
            local job_finished
            job_finished=$(echo "$job_info" | jq -r '.finished')

            if [ "$job_finished" = "false" ]; then
                log "NOTICE" "Task $command $srcFs $dstFs is already running (Job ID: $job_id). Skipping execution."
                return 0
            fi
        fi
    fi

    # Add _async=true to the options
    opts=$(echo "$opts" | jq '. + {"_async": true}')

    # Execute the task
    log "DEBUG" "Starting task: $command $srcFs $dstFs"
    local response
    response=$(make_curl_request "POST" "sync/$command" "$opts")
    # Extract the job ID from the response
    local job_id
    job_id=$(echo "$response" | jq -r '.jobid // empty')

    if [ -n "$job_id" ]; then
        # Append the new task to the cache file
        echo "$task_id $job_id" >> "$TASK_RUNNING_FILE"
        log "NOTICE" "Task started successfully: $command $srcFs $dstFs (Job ID: $job_id)"
    else
        log "ERROR" "Failed to start task: $command $srcFs $dstFs. Response: $response"
        return 1
    fi

    return 0
}

# Function to read mount payloads
read_mount_payloads() {
    ensure_file_exists "$MOUNTS_FILE"

    # Check if the file is empty or invalid
    if [ ! -s "$MOUNTS_FILE" ]; then
        log "DEBUG" "$MOUNTS_FILE is empty."
        return 0
    fi

    log "DEBUG" "Checking if $MOUNTS_FILE contains valid entries."
    if ! jq -e '. | length > 0' "$MOUNTS_FILE" >/dev/null 2>&1; then
        log "DEBUG" "No valid mount entries found in $MOUNTS_FILE."
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

    # unmounting before mounting
    unmount_all

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

        log "DEBUG" "Mounting $fs to $mount_point..."
        response=$(make_curl_request "POST" "mount/mount" "{\"fs\":\"$fs\",\"mountPoint\":\"$mount_point\",\"mountOpt\":$mount_opt,\"vfsOpt\":$vfs_opt}" -w "%{http_code}" -o /dev/null)

        if [ "$response" -eq 200 ]; then
            log "NOTICE" "Mount successful $fs to $mount_point."
        else
            log "ERROR" "Failed to mount $fs: HTTP status $response."
            all_mount_success=1  # Mark as failure
        fi
    done

    return $all_mount_success
}

# Function to process tasks.json and generate crontab entries
setup_cron_tasks() {
    log "DEBUG" "Setting cron tasks ..."

    local cron_dir="/var/spool/cron/crontabs"
    local cron_file="$cron_dir/root"

    # Determine the absolute path of the current script
    SCRIPT_PATH="$(realpath "$0")"

    ensure_file_exists "$TASKS_FILE"
    truncate -s 0 $TASK_RUNNING_FILE

    # Ensure the cron directory exists
    mkdir -p "$cron_dir"
    chmod 600 "$cron_dir"

    # Clear any existing crontab entries by overwriting the file
    log "NOTICE" "Clearing existing crontab entries..."
    : > "$cron_file"  # Truncate the file to ensure it's empty

    # Check if tasks.json contains a non-empty array
    if [ ! -f "$TASKS_FILE" ] || jq -e '. | length == 0' "$TASKS_FILE" >/dev/null 2>&1; then
        log "NOTICE" "$TASKS_FILE is empty or does not contain valid tasks. Skipping task setup."
        return 0
    fi

    # Parse tasks.json and generate cron jobs
    log "DEBUG" "Processing tasks.json to generate cron jobs."
    jq -c '.[]' "$TASKS_FILE" | while IFS= read -r payload; do
        local cron command srcFs dstFs

        cron=$(echo "$payload" | jq -r '.cron')
        command=$(echo "$payload" | jq -r '.command')
        srcFs=$(echo "$payload" | jq -r '.opts.srcFs')
        dstFs=$(echo "$payload" | jq -r '.opts.dstFs')

        # Validate required fields
        if [ -z "$cron" ] || [ -z "$command" ] || [ -z "$srcFs" ] || [ -z "$dstFs" ]; then
            log "ERROR" "Invalid task entry: $payload. Skipping..."
            continue
        fi

        # Add the cron job to the crontab file
        echo "$cron $SCRIPT_PATH execute_task '$payload'" >> "$cron_file"

        # Log the scheduled task
        log "NOTICE" "Scheduled task: $command $srcFs $dstFs every $cron"
    done

    # Set proper permissions for the crontab file
    chmod 600 "$cron_file"
    log "DEBUG" "Cron jobs have been set up successfully."
}

# initialize_configs rclone
initialize_configs() {
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

    if ! setup_cron_tasks; then
        log "ERROR" "Failed to set up cron to run tasks."
        return 1
    fi

    log "NOTICE" "Rclone initialization complete."
    return 0
}

# Function to check if a package is installed
is_package_installed() {
    local package="$1"
    apk info --installed "$package" >/dev/null 2>&1
}

healthcheck() {
    log "DEBUG" "Running healthcheck..."

    # Check if mounts.json exists
    if [ ! -f "$MOUNTS_FILE" ]; then
        log "ERROR" "$MOUNTS_FILE not found."
        exit 1
    fi

    # Check if mounts.json is empty
    if jq -e '. | length == 0' "$MOUNTS_FILE" >/dev/null 2>&1; then
        log "DEBUG" "$MOUNTS_FILE is empty. No mounts to validate. Considering healthy."
        exit 0
    fi

    # Get active mounts from Rclone API
    local response
    response=$(make_curl_request "POST" "mount/listmounts" "")
    if [ -z "$response" ]; then
        log "ERROR" "Failed to fetch active mounts from Rclone API."
        exit 1
    fi

    # Debug output
    log "DEBUG" "API Response: $response"

    # Validate each mount point
    local all_mounts_valid=0
    while IFS= read -r configured_mount; do
        local fs mount_point
        fs=$(echo "$configured_mount" | jq -r '.fs')
        mount_point=$(echo "$configured_mount" | jq -r '.mountPoint')

        # Normalize paths (remove trailing slashes)
        mount_point=$(echo "$mount_point" | sed 's:/*$::')

        log "DEBUG" "Checking mount: fs=$fs, mount_point=$mount_point"

        # Check if this mount exists in the active mounts
        if ! echo "$response" | jq -e --arg fs "$fs" --arg mp "$mount_point" \
            '.mountPoints[] | select(.Fs == $fs and (.MountPoint == $mp or .MountPoint == ($mp + "/")))' >/dev/null; then
            log "ERROR" "Mount $fs at $mount_point is not active."
            all_mounts_valid=1
        else
            log "DEBUG" "Mount $fs at $mount_point is active."
        fi
    done < <(jq -c '.[]' "$MOUNTS_FILE")

    if [ "$all_mounts_valid" -eq 0 ]; then
        log "DEBUG" "All mounts are active."
        exit 0
    else
        log "ERROR" "Some mounts are not active."
        exit 1
    fi
}

init() {
    # Main script execution
    (
        # Define the list of dependencies
        DEPENDENCIES="curl jq fuse3 dcron"

        # Install dependencies if not already installed
        missing_dependencies=0
        for dependency in $DEPENDENCIES; do
            if ! is_package_installed "$dependency"; then
                log "DEBUG" "Dependency $dependency is missing."
                missing_dependencies=1
            fi
        done

        if [ $missing_dependencies -eq 1 ]; then
            log "NOTICE" "Installing required dependencies: $DEPENDENCIES..."
            if apk update >/dev/null 2>&1 && apk add --no-cache $DEPENDENCIES >/dev/null 2>&1; then
                log "DEBUG" "Dependencies installed successfully."
            else
                log "ERROR" "Failed to install dependencies."
                graceful_shutdown 1
            fi
        else
            log "NOTICE" "All dependencies are already installed."
        fi

        # Add "-vv" to RCLONE_OPTS if DEBUG is set to 1
        if [ "${DEBUG:-0}" -eq 1 ]; then
            RCLONE_OPTS="$RCLONE_OPTS -vv"
        fi

        # Ensure correct permissions for rclone.conf
        if [ -f "$RCLONE_CONFIG" ]; then
            log "NOTICE" "Setting correct permissions for $RCLONE_CONFIG..."
            chmod 600 "$RCLONE_CONFIG" || {
                log "ERROR" "Failed to set permissions for $RCLONE_CONFIG. Exiting..."
                graceful_shutdown 1
            }
        else
            log "ERROR" "Rclone configuration file $RCLONE_CONFIG not found. Exiting..."
            graceful_shutdown 1
        fi

        # Start rclone daemon
        log "NOTICE" "Starting rclone daemon..."
        sh -c "rclone rcd --rc-web-gui --rc-web-gui-update --rc-web-gui-force-update --rc-web-gui-no-open-browser --rc-addr :$RCLONE_PORT --rc-user $RCLONE_USERNAME --rc-pass $RCLONE_PASSWORD --cache-dir $CACHE_DIR $RCLONE_OPTS" 2>&1 | \
        sed -E "s/$RCLONE_PASSWORD/XXXX/g" &

        # Wait a few seconds to ensure rclone is ready
        sleep $RETRY_INTERVAL

        # Run the initialization logic
        if ! initialize_configs; then
            log "ERROR" "Initialization failed. Terminating rclone..."
            graceful_shutdown 1
        fi

        # Start cron daemon
        log "NOTICE" "Starting cron daemon..."
        crond -f -L /proc/1/fd/1 >/dev/null 2>&1 &

        sleep $RETRY_INTERVAL

        # Monitor both processes
        log "NOTICE" "Monitoring rclone and cron daemons..."
        while true; do
            # Check if rclone daemon is still running
            if ! pgrep -f "rclone rcd --rc-web-gui" >/dev/null; then
                log "ERROR" "Rclone daemon has stopped. Exiting..."
                graceful_shutdown 1
            fi

            # Check if cron daemon is still running
            if ! pgrep -f "crond -f" >/dev/null; then
                log "ERROR" "Cron daemon has stopped. Exiting..."
                graceful_shutdown 1
            fi

            # Sleep for a short interval before checking again
            sleep 5
        done
    ) 2>&1
}

# Handle direct execution of tasks
case "$1" in
    execute_task)
        shift
        execute_task "$@" >> /proc/1/fd/1 2>> /proc/1/fd/2
        ;;
    healthcheck)
        healthcheck >> /proc/1/fd/1 2>> /proc/1/fd/2
        ;;
    *)
        init "$@"
        ;;
esac
