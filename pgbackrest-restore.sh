#!/bin/bash

# 23/10/2024 Mattia Martinello
# This script restore a backup from our pgBackRest repository

# Variables
LOG_LEVEL="info"
CONFIG_FILE_DIR="/etc/pgbackrest"
CONFIG_FILE_NAME="pgbackrest.conf"
DOCKER_COMPOSE_PATH="docker compose"
PGBACKREST_DOCKER_CONTAINER="postgresql"
POSTGRESQL_DATA_DIR=/var/lib/postgresql/data

# CLI override flags
CLI_POSTGRES_VERSION=false
CLI_STANZA=false
CLI_BACKUP_SET=false
CLI_TIME=false
CLI_DATABASES=false
CLI_PORT=false
CLI_DRY_RUN=false
CLI_DEBUG=false
CLI_MODE=false

# Check if the jq command exists
jq_cmd_path=$(which jq 2>/dev/null)
if [ -z "$jq_cmd_path" ]; then
    echo "Error: command 'jq' not installed, please install it and try again!"
    exit 1
fi

usage() {
    echo "Usage: $0 COMMAND [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  restore    Restore a pgBackRest backup"
    echo "  list       List available backups"
    echo "  show       Show active restore instances"
    echo "  start      Start a restore instance"
    echo "  stop       Stop an active restore instance"
    echo "  restart    Restart a restore instance"
    echo "  logs       Show logs of a restore instance"
    echo "  ps         Show services of a restore instance"
    echo "  clean      Delete a restore instance and its volumes"
    echo "  help       Show this help"
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help or command-specific help"
    echo ""
    echo "Run '$0 COMMAND --help' for more information on a command."
}

usage_list() {
    echo "Usage: $0 list [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -s, --stanza STANZA    pgBackRest stanza name"
    echo "  -h, --help             Show this help"
    echo ""
    echo "If no options are provided, the stanza is asked interactively."
}

usage_restore() {
    echo "Usage: $0 restore [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -V, --postgres-version VERSION        PostgreSQL version"
    echo "  -s, --stanza STANZA                   pgBackRest stanza name"
    echo "  -b, --backup-set LABEL|latest         Backup label, or 'latest' for most recent"
    echo "  -t, --time 'YYYY-MM-DD HH:MM:SS'      Point-in-time recovery target"
    echo "  -d, --databases 'db1 db2 ...'         Databases to restore (default: all)"
    echo "  -p, --port PORT                       PostgreSQL host port"
    echo "  --dry-run                             Print the restore command without executing it"
    echo "  --debug                               Print debug information"
    echo "  -h, --help                            Show this help"
    echo ""
    echo "If no options are provided, all parameters are asked interactively."
}

usage_show() {
    echo "Usage: $0 show"
    echo ""
    echo "Shows all active restore instances started from this project's docker-compose.yml."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help"
}

usage_start() {
    echo "Usage: $0 start INSTANCE"
    echo ""
    echo "Starts the given restore instance (runs 'docker compose up -d --force-recreate')."
    echo "The instance must have been previously created by the restore command."
    echo "Existing Docker volumes are reused, so the restored data is preserved."
    echo ""
    echo "Arguments:"
    echo "  INSTANCE    Name of the instance to start (e.g. pgbackrest_restore_5432)"
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help"
    echo ""
    echo "Use '$0 show' to list active instances."
}

usage_restart() {
    echo "Usage: $0 restart INSTANCE"
    echo ""
    echo "Restarts the given restore instance (runs 'docker compose down' then"
    echo "'docker compose up -d --force-recreate'). Works whether the instance"
    echo "is currently running or stopped. Docker volumes are preserved."
    echo ""
    echo "Arguments:"
    echo "  INSTANCE    Name of the instance to restart (e.g. pgbackrest_restore_5432)"
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help"
    echo ""
    echo "Use '$0 show' to list active instances."
}

usage_logs() {
    echo "Usage: $0 logs INSTANCE [OPTIONS]"
    echo ""
    echo "Shows logs for the given restore instance."
    echo ""
    echo "Arguments:"
    echo "  INSTANCE      Name of the instance (e.g. pgbackrest_restore_5432)"
    echo ""
    echo "Options:"
    echo "  -f, --follow  Follow log output"
    echo "  -h, --help    Show this help"
    echo ""
    echo "Use '$0 show' to list active instances."
}

usage_ps() {
    echo "Usage: $0 ps INSTANCE"
    echo ""
    echo "Shows the services and their status for the given restore instance."
    echo ""
    echo "Arguments:"
    echo "  INSTANCE    Name of the instance (e.g. pgbackrest_restore_5432)"
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help"
    echo ""
    echo "Use '$0 show' to list active instances."
}

usage_clean() {
    echo "Usage: $0 clean INSTANCE"
    echo ""
    echo "Stops and permanently deletes the given restore instance, including all"
    echo "Docker volumes (PostgreSQL data, pgBackRest state, logs). This operation"
    echo "is irreversible. A confirmation prompt is shown before proceeding."
    echo ""
    echo "Arguments:"
    echo "  INSTANCE    Name of the instance to delete (e.g. pgbackrest_restore_5432)"
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help"
    echo ""
    echo "Use '$0 show' to list active instances."
}

usage_stop() {
    echo "Usage: $0 stop INSTANCE"
    echo ""
    echo "Stops the given restore instance (runs 'docker compose down' for that project)."
    echo "Docker volumes are preserved; only containers are stopped and removed."
    echo ""
    echo "Arguments:"
    echo "  INSTANCE    Name of the instance to stop (e.g. pgbackrest_restore_5432)"
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help"
    echo ""
    echo "Use '$0 show' to list active instances."
}

# Select the PostgreSQL version to use
select_postgres_version() {
    if $CLI_POSTGRES_VERSION; then
        export POSTGRES_VERSION
        echo "PostgreSQL version: $POSTGRES_VERSION"
        return 0
    fi

    local supported_versions=(14 15 16 17)
    local default_version=""

    if [ -f ".env" ]; then
        default_version=$(grep -E '^POSTGRES_VERSION=' .env | cut -d= -f2)
    fi
    [ -z "$default_version" ] && default_version="17"

    echo "Supported PostgreSQL versions: ${supported_versions[*]}"
    read -p "Which PostgreSQL version do you want to use? (ENTER for default: $default_version): " version_input

    if [ -z "$version_input" ]; then
        POSTGRES_VERSION="$default_version"
    else
        POSTGRES_VERSION="$version_input"
    fi

    export POSTGRES_VERSION
    echo "PostgreSQL version: $POSTGRES_VERSION"
}

# Returns 0 if the port is free, 1 if already in use
is_port_free() {
    ! nc -z -w1 127.0.0.1 "$1" 2>/dev/null
}

# Select the PostgreSQL host port
select_postgresql_port() {
    local default_port=""
    local port_range_start=""
    local port_range_end=""

    if [ -f ".env" ]; then
        default_port=$(grep -E '^POSTGRESQL_HOST_PORT=' .env | cut -d= -f2)
        local range
        range=$(grep -E '^POSTGRESQL_HOST_PORT_RANGE=' .env | cut -d= -f2)
        if [ -z "$range" ]; then
            echo "WARNING: POSTGRESQL_HOST_PORT_RANGE is not set in .env — only the default port will be tried; if it is busy the script will exit with an error."
        elif [[ "$range" =~ ^[0-9]+-[0-9]+$ ]]; then
            port_range_start="${range%-*}"
            port_range_end="${range#*-}"
            if [ "$port_range_start" -lt 1 ] || [ "$port_range_end" -gt 65535 ] || [ "$port_range_start" -ge "$port_range_end" ]; then
                echo "WARNING: POSTGRESQL_HOST_PORT_RANGE '$range' is invalid (ports must be 1-65535 and start must be less than end) — only the default port will be tried; if it is busy the script will exit with an error."
                port_range_start=""
                port_range_end=""
            fi
        else
            echo "WARNING: POSTGRESQL_HOST_PORT_RANGE '$range' is not a valid range (expected format: START-END) — only the default port will be tried; if it is busy the script will exit with an error."
        fi
    fi
    [ -z "$default_port" ] && default_port="5432"

    # CLI mode with explicit --port: check availability, error if busy
    if $CLI_PORT; then
        if ! is_port_free "$POSTGRESQL_HOST_PORT"; then
            echo "Error: port $POSTGRESQL_HOST_PORT is already in use."
            exit 1
        fi
        export POSTGRESQL_HOST_PORT
        echo "PostgreSQL host port: $POSTGRESQL_HOST_PORT"
        return 0
    fi

    # CLI mode without explicit port: use default as-is, no range search
    if $CLI_MODE; then
        POSTGRESQL_HOST_PORT="$default_port"
        export POSTGRESQL_HOST_PORT
        echo "PostgreSQL host port: $POSTGRESQL_HOST_PORT"
        return 0
    fi

    # Interactive mode
    while true; do
        read -p "Which port should PostgreSQL listen on? (ENTER for auto, default $default_port): " port_input

        if [ -z "$port_input" ]; then
            # Try default port first
            if is_port_free "$default_port"; then
                POSTGRESQL_HOST_PORT="$default_port"
            elif [ -n "$port_range_start" ] && [ -n "$port_range_end" ]; then
                echo "Port $default_port is already in use, searching in range $port_range_start-$port_range_end ..."
                POSTGRESQL_HOST_PORT=""
                for ((p = port_range_start; p <= port_range_end; p++)); do
                    if is_port_free "$p"; then
                        POSTGRESQL_HOST_PORT="$p"
                        break
                    fi
                done
                if [ -z "$POSTGRESQL_HOST_PORT" ]; then
                    echo "Error: no free port found in range $port_range_start-$port_range_end."
                    exit 1
                fi
            else
                echo "Error: port $default_port is already in use and no valid POSTGRESQL_HOST_PORT_RANGE is available."
                exit 1
            fi
            break
        elif [[ "$port_input" =~ ^[0-9]+$ ]] && [ "$port_input" -ge 1 ] && [ "$port_input" -le 65535 ]; then
            if ! is_port_free "$port_input"; then
                echo "Error: port $port_input is already in use."
                exit 1
            fi
            POSTGRESQL_HOST_PORT="$port_input"
            break
        else
            echo "Invalid port '$port_input'. Please enter a number between 1 and 65535."
        fi
    done

    export POSTGRESQL_HOST_PORT
    echo "PostgreSQL host port: $POSTGRESQL_HOST_PORT"
}

# Select databases to be restored
select_databases() {
    if $CLI_DATABASES || $CLI_MODE; then
        return 0
    fi

    msg="Which database/s do you want to restore"
    msg+=" (space separated values, press ENTER for all databases)?"
    read -p "$msg " databases_string
}

# Select which time point to be restored
select_time() {
    if $CLI_TIME; then
        return 0
    fi
    if $CLI_MODE; then
        time_string=""
        return 0
    fi

    msg="Which time do you want to restore (YYYY-MM-DD HH:MM:SS, press ENTER"
    msg+=" to select a backup and restore at the latest abailable WAL)?"
    read -p "$msg " time_string

    if [ -n "$time_string" ]; then
        check_date "$time_string"
        case $? in
            1)
                echo "Wrong PITR date '$time_string', exiting now!"
                exit 1
                ;;
            2)
                echo "Wrong PITR date format '$time_string', exiting now!"
                exit 1
                ;;
        esac
    fi
}

# Check if a given date is correct and has the correct format
# Valid format: YYYY-MM-DD HH:MM:SS
# Return values:
# - 0: valid format and valid date
# - 1: valid format but wrong date
# - 2: wrong format
check_date() {
    date_string=$1

    $CLI_DEBUG && echo "Checking date string: $date_string"

    # Check if the given string has the valid format
    if [[ "$date_string" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then

      # Check if the given string is a valid date (GNU date on Linux, BSD date on macOS)
      if date -d "$date_string" >/dev/null 2>&1 || date -j -f "%Y-%m-%d %H:%M:%S" "$date_string" >/dev/null 2>&1; then
        return 0
      else
        return 1
      fi
    else
      return 2
    fi
}

# Select a stanza fron the pgBackRest configuration file
select_stanza() {
    local config_file=$1

    if $CLI_STANZA; then
        echo "Stanza: $stanza"
        return 0
    fi

    if [[ ! -f $config_file ]]; then
        echo "Error: the file '$config_file' does not exist."
        return 1
    fi

    # Extract stanzas (excluding 'global') and save them in an array
    local stanzas=($(grep -oE '^\[[^]]+\]' "$config_file" | tr -d '[]' | grep -v '^global$'))

    if [[ ${#stanzas[@]} -eq 0 ]]; then
        echo "No available stanzas to select."
        return 1
    fi

    # Print the stanzas with identifying numbers
    echo "Available stanzas:"
    for i in "${!stanzas[@]}"; do
        echo "$((i + 1)). ${stanzas[$i]}"
    done

    # Prompt the user to select a stanza
    while true; do
        read -p "Select a stanza (enter the number): " choice
        if [[ $choice =~ ^[0-9]+$ ]] && (( choice > 0 && choice <= ${#stanzas[@]} )); then
            stanza=${stanzas[$((choice - 1))]}
            echo "You selected the stanza: $stanza"
            return 0
        else
            echo "Invalid choice. Please try again."
        fi
    done
}

# Select the backup set from the available backups
choose_backup() {
    local backups_json=$1
    local page_size=20  # items per page (10 rows x 2 columns)

    if $CLI_BACKUP_SET; then
        if [ -z "$backup_set" ]; then
            echo "Last backup selected."
        else
            echo "Backup set: $backup_set"
        fi
        return 0
    fi

    # Build arrays of labels and types (most recent first)
    local labels=()
    local types=()
    while read -r label type; do
        labels+=("$label")
        types+=("$type")
    done < <(echo "$backups_json" | $jq_cmd_path -r '.[] | .backup | reverse | .[] | "\(.label) \(.type | ascii_upcase)"')

    local total=${#labels[@]}
    if [ "$total" -eq 0 ]; then
        echo "No backups available."
        backup_set=""
        return 0
    fi

    # Compute display widths dynamically
    local num_width=${#total}
    local label_width=0
    local type_width=0
    local i
    for i in "${!labels[@]}"; do
        [ ${#labels[$i]} -gt $label_width ] && label_width=${#labels[$i]}
        local tw="(${types[$i]})"
        [ ${#tw} -gt $type_width ] && type_width=${#tw}
    done

    local total_pages=$(( (total + page_size - 1) / page_size ))
    local current_page=0

    while true; do
        local start=$((current_page * page_size))
        local end=$((start + page_size - 1))
        [ $end -ge $total ] && end=$((total - 1))

        echo "Available backups (from most recent to oldest):"
        echo

        # Display entries in two columns, top-to-bottom order
        local count=$((end - start + 1))
        local rows=$(( (count + 1) / 2 ))
        local r=0
        while [ $r -lt $rows ]; do
            local left_idx=$((start + r))
            local right_idx=$((start + rows + r))
            local left_num=$((left_idx + 1))

            if [ $right_idx -le $end ]; then
                local right_num=$((right_idx + 1))
                printf "  %*d. %-*s %-*s  |  %*d. %-*s %s\n" \
                    $num_width $left_num \
                    $label_width "${labels[$left_idx]}" \
                    $type_width "(${types[$left_idx]})" \
                    $num_width $right_num \
                    $label_width "${labels[$right_idx]}" \
                    "(${types[$right_idx]})"
            else
                printf "  %*d. %-*s %s\n" \
                    $num_width $left_num \
                    $label_width "${labels[$left_idx]}" \
                    "(${types[$left_idx]})"
            fi
            r=$((r + 1))
        done

        echo
        echo "  Page $((current_page + 1)) of $total_pages — entries $((start + 1))-$((end + 1)) of $total"
        echo

        local prompt="  Enter backup number"
        [ $total_pages -gt 1 ] && prompt+=", [n]ext, [p]rev"
        prompt+=", or ENTER for latest: "
        echo -n "$prompt"
        read -r choice

        case "$choice" in
            "")
                echo "Last backup selected."
                backup_set=""
                return 0
                ;;
            n|N)
                if [ $((current_page + 1)) -lt $total_pages ]; then
                    current_page=$((current_page + 1))
                else
                    echo "  Already on the last page."
                fi
                ;;
            p|P)
                if [ $current_page -gt 0 ]; then
                    current_page=$((current_page - 1))
                else
                    echo "  Already on the first page."
                fi
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $total ]; then
                    backup_set="${labels[$((choice - 1))]}"
                    return 0
                else
                    echo "  Invalid choice. Please try again."
                fi
                ;;
        esac
        echo
    done
}

# Display all backups without interactive selection
list_backups() {
    local backups_json=$1
    local page_size=20  # items per page (10 rows x 2 columns)

    # Build arrays of labels and types (most recent first)
    local labels=()
    local types=()
    while read -r label type; do
        labels+=("$label")
        types+=("$type")
    done < <(echo "$backups_json" | $jq_cmd_path -r '.[] | .backup | reverse | .[] | "\(.label) \(.type | ascii_upcase)"')

    local total=${#labels[@]}
    if [ "$total" -eq 0 ]; then
        echo "No backups available."
        return 0
    fi

    # Compute display widths dynamically
    local num_width=${#total}
    local label_width=0
    local type_width=0
    local i
    for i in "${!labels[@]}"; do
        [ ${#labels[$i]} -gt $label_width ] && label_width=${#labels[$i]}
        local tw="(${types[$i]})"
        [ ${#tw} -gt $type_width ] && type_width=${#tw}
    done

    local total_pages=$(( (total + page_size - 1) / page_size ))
    local current_page=0

    while [ $current_page -lt $total_pages ]; do
        local start=$((current_page * page_size))
        local end=$((start + page_size - 1))
        [ $end -ge $total ] && end=$((total - 1))

        echo "Available backups (from most recent to oldest):"
        echo

        # Display entries in two columns, top-to-bottom order
        local count=$((end - start + 1))
        local rows=$(( (count + 1) / 2 ))
        local r=0
        while [ $r -lt $rows ]; do
            local left_idx=$((start + r))
            local right_idx=$((start + rows + r))
            local left_num=$((left_idx + 1))

            if [ $right_idx -le $end ]; then
                local right_num=$((right_idx + 1))
                printf "  %*d. %-*s %-*s  |  %*d. %-*s %s\n" \
                    $num_width $left_num \
                    $label_width "${labels[$left_idx]}" \
                    $type_width "(${types[$left_idx]})" \
                    $num_width $right_num \
                    $label_width "${labels[$right_idx]}" \
                    "(${types[$right_idx]})"
            else
                printf "  %*d. %-*s %s\n" \
                    $num_width $left_num \
                    $label_width "${labels[$left_idx]}" \
                    "(${types[$left_idx]})"
            fi
            r=$((r + 1))
        done

        echo
        echo "  Page $((current_page + 1)) of $total_pages — entries $((start + 1))-$((end + 1)) of $total"
        echo

        current_page=$((current_page + 1))
    done
}

# Show active restore instances started from this project's docker-compose.yml
show_instances() {
    local config_file
    config_file="$(pwd)/docker-compose.yml"

    local instances_json
    instances_json=$(docker compose ls --format json 2>/dev/null | \
        $jq_cmd_path --arg cf "$config_file" \
        '[.[] | select(.ConfigFiles | split(",") | map(ltrimstr(" ") | rtrimstr(" ")) | any(. == $cf))]')

    local total
    total=$(echo "$instances_json" | $jq_cmd_path 'length')

    if [ "$total" -eq 0 ]; then
        echo "No active restore instances found."
        return 0
    fi

    echo "Active restore instances:"
    echo
    printf "  %-40s  %-20s  %s\n" "NAME" "STATUS" "PORT"
    printf "  %-40s  %-20s  %s\n" "----" "------" "----"

    while IFS= read -r entry; do
        local name status port
        name=$(echo "$entry" | $jq_cmd_path -r '.Name')
        status=$(echo "$entry" | $jq_cmd_path -r '.Status')
        if [[ "$name" =~ ^pgbackrest_restore_([0-9]+)$ ]]; then
            port="${BASH_REMATCH[1]}"
        else
            port="-"
        fi
        printf "  %-40s  %-20s  %s\n" "$name" "$status" "$port"
    done < <(echo "$instances_json" | $jq_cmd_path -c '.[]')

    echo
}

# Parse command-line arguments

# No arguments: command is required
if [[ $# -eq 0 ]]; then
    echo "Error: a command is required."
    echo ""
    usage
    exit 1
fi

# Dispatch on the first argument
case "$1" in
    -h|--help)
        shift
        case "$1" in
            restore)
                usage_restore; exit 0 ;;
            list)
                usage_list; exit 0 ;;
            show)
                usage_show; exit 0 ;;
            start)
                usage_start; exit 0 ;;
            stop)
                usage_stop; exit 0 ;;
            restart)
                usage_restart; exit 0 ;;
            logs)
                usage_logs; exit 0 ;;
            ps)
                usage_ps; exit 0 ;;
            clean)
                usage_clean; exit 0 ;;
            "")
                usage; exit 0 ;;
            *)
                echo "Error: unknown command '$1'"
                echo ""
                usage; exit 1 ;;
        esac
        ;;
    help)
        usage; exit 0 ;;
    show)
        COMMAND="show"
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -h|--help)
                    usage_show; exit 0 ;;
                *)
                    echo "Error: unknown option '$1'"
                    echo ""
                    usage_show; exit 1 ;;
            esac
        done
        ;;
    start)
        COMMAND="start"
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -h|--help)
                    usage_start; exit 0 ;;
                -*)
                    echo "Error: unknown option '$1'"
                    echo ""
                    usage_start; exit 1 ;;
                *)
                    if [ -n "$START_INSTANCE" ]; then
                        echo "Error: too many arguments."
                        echo ""
                        usage_start; exit 1
                    fi
                    START_INSTANCE="$1"; shift ;;
            esac
        done
        if [ -z "$START_INSTANCE" ]; then
            echo "Error: instance name is required."
            echo ""
            usage_start; exit 1
        fi
        if [[ ! "$START_INSTANCE" =~ ^pgbackrest_restore_[0-9]+$ ]]; then
            echo "Error: '$START_INSTANCE' is not a valid instance name."
            echo "Expected format: pgbackrest_restore_<port>"
            exit 1
        fi
        ;;
    stop)
        COMMAND="stop"
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -h|--help)
                    usage_stop; exit 0 ;;
                -*)
                    echo "Error: unknown option '$1'"
                    echo ""
                    usage_stop; exit 1 ;;
                *)
                    if [ -n "$STOP_INSTANCE" ]; then
                        echo "Error: too many arguments."
                        echo ""
                        usage_stop; exit 1
                    fi
                    STOP_INSTANCE="$1"; shift ;;
            esac
        done
        if [ -z "$STOP_INSTANCE" ]; then
            echo "Error: instance name is required."
            echo ""
            usage_stop; exit 1
        fi
        ;;
    restart)
        COMMAND="restart"
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -h|--help)
                    usage_restart; exit 0 ;;
                -*)
                    echo "Error: unknown option '$1'"
                    echo ""
                    usage_restart; exit 1 ;;
                *)
                    if [ -n "$RESTART_INSTANCE" ]; then
                        echo "Error: too many arguments."
                        echo ""
                        usage_restart; exit 1
                    fi
                    RESTART_INSTANCE="$1"; shift ;;
            esac
        done
        if [ -z "$RESTART_INSTANCE" ]; then
            echo "Error: instance name is required."
            echo ""
            usage_restart; exit 1
        fi
        if [[ ! "$RESTART_INSTANCE" =~ ^pgbackrest_restore_[0-9]+$ ]]; then
            echo "Error: '$RESTART_INSTANCE' is not a valid instance name."
            echo "Expected format: pgbackrest_restore_<port>"
            exit 1
        fi
        ;;
    logs)
        COMMAND="logs"
        LOGS_FOLLOW=false
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -h|--help)
                    usage_logs; exit 0 ;;
                -f|--follow)
                    LOGS_FOLLOW=true; shift ;;
                -*)
                    echo "Error: unknown option '$1'"
                    echo ""
                    usage_logs; exit 1 ;;
                *)
                    if [ -n "$LOGS_INSTANCE" ]; then
                        echo "Error: too many arguments."
                        echo ""
                        usage_logs; exit 1
                    fi
                    LOGS_INSTANCE="$1"; shift ;;
            esac
        done
        if [ -z "$LOGS_INSTANCE" ]; then
            echo "Error: instance name is required."
            echo ""
            usage_logs; exit 1
        fi
        if [[ ! "$LOGS_INSTANCE" =~ ^pgbackrest_restore_[0-9]+$ ]]; then
            echo "Error: '$LOGS_INSTANCE' is not a valid instance name."
            echo "Expected format: pgbackrest_restore_<port>"
            exit 1
        fi
        ;;
    ps)
        COMMAND="ps"
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -h|--help)
                    usage_ps; exit 0 ;;
                -*)
                    echo "Error: unknown option '$1'"
                    echo ""
                    usage_ps; exit 1 ;;
                *)
                    if [ -n "$PS_INSTANCE" ]; then
                        echo "Error: too many arguments."
                        echo ""
                        usage_ps; exit 1
                    fi
                    PS_INSTANCE="$1"; shift ;;
            esac
        done
        if [ -z "$PS_INSTANCE" ]; then
            echo "Error: instance name is required."
            echo ""
            usage_ps; exit 1
        fi
        if [[ ! "$PS_INSTANCE" =~ ^pgbackrest_restore_[0-9]+$ ]]; then
            echo "Error: '$PS_INSTANCE' is not a valid instance name."
            echo "Expected format: pgbackrest_restore_<port>"
            exit 1
        fi
        ;;
    clean)
        COMMAND="clean"
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -h|--help)
                    usage_clean; exit 0 ;;
                -*)
                    echo "Error: unknown option '$1'"
                    echo ""
                    usage_clean; exit 1 ;;
                *)
                    if [ -n "$CLEAN_INSTANCE" ]; then
                        echo "Error: too many arguments."
                        echo ""
                        usage_clean; exit 1
                    fi
                    CLEAN_INSTANCE="$1"; shift ;;
            esac
        done
        if [ -z "$CLEAN_INSTANCE" ]; then
            echo "Error: instance name is required."
            echo ""
            usage_clean; exit 1
        fi
        if [[ ! "$CLEAN_INSTANCE" =~ ^pgbackrest_restore_[0-9]+$ ]]; then
            echo "Error: '$CLEAN_INSTANCE' is not a valid instance name."
            echo "Expected format: pgbackrest_restore_<port>"
            exit 1
        fi
        ;;
    list)
        COMMAND="list"
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -s|--stanza)
                    stanza="$2"; CLI_STANZA=true; shift 2 ;;
                -h|--help)
                    usage_list; exit 0 ;;
                *)
                    echo "Error: unknown option '$1'"
                    echo ""
                    usage_list; exit 1 ;;
            esac
        done
        ;;
    restore)
        COMMAND="restore"
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -V|--postgres-version)
                    POSTGRES_VERSION="$2"; CLI_POSTGRES_VERSION=true; CLI_MODE=true; shift 2 ;;
                -s|--stanza)
                    stanza="$2"; CLI_STANZA=true; CLI_MODE=true; shift 2 ;;
                -b|--backup-set)
                    [ "$2" = "latest" ] && backup_set="" || backup_set="$2"
                    CLI_BACKUP_SET=true; CLI_MODE=true; shift 2 ;;
                -t|--time)
                    time_string="$2"; CLI_TIME=true; CLI_MODE=true; shift 2 ;;
                -d|--databases)
                    databases_string="$2"; CLI_DATABASES=true; CLI_MODE=true; shift 2 ;;
                -p|--port)
                    if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ]; then
                        POSTGRESQL_HOST_PORT="$2"; CLI_PORT=true; CLI_MODE=true
                    else
                        echo "Error: invalid port '$2'. Must be between 1 and 65535."
                        exit 1
                    fi
                    shift 2 ;;
                --dry-run)
                    CLI_DRY_RUN=true; shift ;;
                --debug)
                    CLI_DEBUG=true; shift ;;
                -h|--help)
                    usage_restore; exit 0 ;;
                *)
                    echo "Error: unknown option '$1'"
                    echo ""
                    usage_restore; exit 1 ;;
            esac
        done
        ;;
    -*)
        echo "Error: options are not allowed without a command."
        echo ""
        usage; exit 1
        ;;
    *)
        echo "Error: unknown command '$1'"
        echo ""
        usage; exit 1
        ;;
esac

# Print title
if [[ "$COMMAND" == "list" ]]; then
    echo "pgBackRest Backup List"
    echo

    select_stanza "$CONFIG_FILE_NAME"
    echo

    backup_list_cmd="$DOCKER_COMPOSE_PATH run --rm $PGBACKREST_DOCKER_CONTAINER pgbackrest --stanza=$stanza info --output=json 2>/dev/null"
    backups_json=$(eval "$backup_list_cmd")
    list_backups "$backups_json"
    exit 0
fi

if [[ "$COMMAND" == "show" ]]; then
    echo "pgBackRest Restore Instances"
    echo
    show_instances
    exit 0
fi

if [[ "$COMMAND" == "start" ]]; then
    echo "pgBackRest Start Instance"
    echo

    START_PORT="${START_INSTANCE#pgbackrest_restore_}"

    if ! docker volume inspect "${START_INSTANCE}_data" > /dev/null 2>&1; then
        echo "Error: no data volume found for instance '$START_INSTANCE'."
        echo "Run '$0 restore' first to create this instance."
        exit 1
    fi

    echo "Starting instance '$START_INSTANCE' ..."
    POSTGRESQL_HOST_PORT="$START_PORT" $DOCKER_COMPOSE_PATH -p "$START_INSTANCE" up -d --force-recreate
    exit_status=$?

    echo
    echo "========================================================================"
    if [ $exit_status -eq 0 ]; then
        echo "PostgreSQL is up and running!"
        echo "Connection port: $START_PORT"
    else
        echo "Error: failed to start instance '$START_INSTANCE' (exit code $exit_status)."
    fi
    exit $exit_status
fi

if [[ "$COMMAND" == "stop" ]]; then
    echo "pgBackRest Stop Instance"
    echo

    config_file="$(pwd)/docker-compose.yml"
    instance_check=$(docker compose ls --format json 2>/dev/null | \
        $jq_cmd_path --arg cf "$config_file" --arg name "$STOP_INSTANCE" \
        '[.[] | select(.Name == $name and (.ConfigFiles | split(",") | map(ltrimstr(" ") | rtrimstr(" ")) | any(. == $cf)))] | length')

    if [ "$instance_check" -eq 0 ]; then
        echo "Error: instance '$STOP_INSTANCE' not found among active instances of this project."
        echo "Use '$0 show' to list active instances."
        exit 1
    fi

    echo "Stopping instance '$STOP_INSTANCE' ..."
    $DOCKER_COMPOSE_PATH -p "$STOP_INSTANCE" down
    exit_status=$?

    echo
    if [ $exit_status -eq 0 ]; then
        echo "Instance '$STOP_INSTANCE' stopped successfully."
        echo "Note: Docker volumes have been preserved. Run 'docker compose down -v' to remove them."
    else
        echo "Error: failed to stop instance '$STOP_INSTANCE' (exit code $exit_status)."
    fi
    exit $exit_status
fi

if [[ "$COMMAND" == "restart" ]]; then
    echo "pgBackRest Restart Instance"
    echo

    RESTART_PORT="${RESTART_INSTANCE#pgbackrest_restore_}"

    if ! docker volume inspect "${RESTART_INSTANCE}_data" > /dev/null 2>&1; then
        echo "Error: no data volume found for instance '$RESTART_INSTANCE'."
        echo "Run '$0 restore' first to create this instance."
        exit 1
    fi

    echo "Stopping instance '$RESTART_INSTANCE' ..."
    $DOCKER_COMPOSE_PATH -p "$RESTART_INSTANCE" down
    exit_status=$?

    if [ $exit_status -ne 0 ]; then
        echo "Error: failed to stop instance '$RESTART_INSTANCE' (exit code $exit_status)."
        exit $exit_status
    fi

    echo
    echo "Starting instance '$RESTART_INSTANCE' ..."
    POSTGRESQL_HOST_PORT="$RESTART_PORT" $DOCKER_COMPOSE_PATH -p "$RESTART_INSTANCE" up -d --force-recreate
    exit_status=$?

    echo
    echo "========================================================================"
    if [ $exit_status -eq 0 ]; then
        echo "PostgreSQL is up and running!"
        echo "Connection port: $RESTART_PORT"
    else
        echo "Error: failed to start instance '$RESTART_INSTANCE' (exit code $exit_status)."
    fi
    exit $exit_status
fi

if [[ "$COMMAND" == "clean" ]]; then
    echo "pgBackRest Clean Instance"
    echo

    if ! docker volume inspect "${CLEAN_INSTANCE}_data" > /dev/null 2>&1; then
        echo "Error: no data volume found for instance '$CLEAN_INSTANCE'."
        echo "Run '$0 restore' first to create this instance."
        exit 1
    fi

    echo "WARNING: this will permanently delete instance '$CLEAN_INSTANCE'"
    echo "and all its Docker volumes, including the PostgreSQL data."
    echo "This operation cannot be undone."
    echo
    read -p "Type the instance name to confirm: " confirm
    if [ "$confirm" != "$CLEAN_INSTANCE" ]; then
        echo "Aborted."
        exit 1
    fi

    echo
    echo "Deleting instance '$CLEAN_INSTANCE' ..."
    $DOCKER_COMPOSE_PATH -p "$CLEAN_INSTANCE" down -v
    exit_status=$?

    echo
    if [ $exit_status -eq 0 ]; then
        echo "Instance '$CLEAN_INSTANCE' deleted successfully."
    else
        echo "Error: failed to delete instance '$CLEAN_INSTANCE' (exit code $exit_status)."
    fi
    exit $exit_status
fi

if [[ "$COMMAND" == "ps" ]]; then
    if ! docker volume inspect "${PS_INSTANCE}_data" > /dev/null 2>&1; then
        echo "Error: no data volume found for instance '$PS_INSTANCE'."
        echo "Run '$0 restore' first to create this instance."
        exit 1
    fi

    $DOCKER_COMPOSE_PATH -p "$PS_INSTANCE" ps
    exit $?
fi

if [[ "$COMMAND" == "logs" ]]; then
    if ! docker volume inspect "${LOGS_INSTANCE}_data" > /dev/null 2>&1; then
        echo "Error: no data volume found for instance '$LOGS_INSTANCE'."
        echo "Run '$0 restore' first to create this instance."
        exit 1
    fi

    if $LOGS_FOLLOW; then
        $DOCKER_COMPOSE_PATH -p "$LOGS_INSTANCE" logs --follow
    else
        $DOCKER_COMPOSE_PATH -p "$LOGS_INSTANCE" logs
    fi
    exit $?
fi

echo "pgBackRest Backup Restore"

##############################################################################
# Main script

# Select the PostgreSQL host port (must be first to build the project name)
select_postgresql_port
echo

COMPOSE_PROJECT="pgbackrest_restore_${POSTGRESQL_HOST_PORT}"

# Select the PostgreSQL version
select_postgres_version
echo

# Select the stanza
select_stanza "$CONFIG_FILE_NAME"
echo

# Select the time
select_time
echo

# Select the backup set to restore (skipped if a PITR time is set)
if [ -z "$time_string" ]; then
    backup_list_cmd="$DOCKER_COMPOSE_PATH -p \"$COMPOSE_PROJECT\" run --rm $PGBACKREST_DOCKER_CONTAINER pgbackrest --stanza=$stanza info --output=json 2>/dev/null"
    backups_json=$(eval "$backup_list_cmd")
    choose_backup "$backups_json"
    echo
fi

# Select databases to include
select_databases
echo

# Print debug
if $CLI_DEBUG; then
    echo "Debug information:"
    echo "* Stanza: $stanza"
    echo "* Databases: $databases_string"
    echo "* Backup set: $backup_set"
    echo "* Time: $time_string"
    echo
fi

# Basic pgBackRest restore command
restore_cmd="$DOCKER_COMPOSE_PATH -p \"$COMPOSE_PROJECT\" run --rm $PGBACKREST_DOCKER_CONTAINER"
restore_cmd+=" pgbackrest restore"
restore_cmd+=" --log-level-console=$LOG_LEVEL"
restore_cmd+=" --stanza=$stanza"
restore_cmd+=" --archive-mode=off"

# Restore a specific backup set
if [ -n "$backup_set" ]; then
    restore_cmd+=" --set=$backup_set"
fi

# Restore a single or a list of databases
if [ -n "$databases_string" ]; then
    databases=($databases_string)

    for database in "${databases[@]}"; do
        restore_cmd+=" --db-include=$database"
    done
else
    echo "No database selected, restoring all databases ..."
fi

# Point In Time Recovery
if [ -n "$time_string" ]; then
    check_date "$time_string"
    check_date_result=$?

    case "$check_date_result" in
        0)
            restore_cmd+=" --type=time"
            restore_cmd+=" --target=\"$time_string\""
            restore_cmd+=" --target-action=promote"
            ;;
        1)
            echo "Wrong PITR date '$time_string', exiting now!"
            exit 1
            ;;
        2)
            echo "Wrong PITR date format '$time_string', exiting now!"
            exit 1
            ;;
    esac
elif [ -n "$databases_string" ]; then
    # Selective restore: stop at consistent point to avoid WAL replay errors
    # on excluded/non-included databases
    echo "Selective restore requested, stopping at consistent point ..."
    restore_cmd+=" --type=immediate"
    restore_cmd+=" --target-action=promote"
else
    echo "No PITR requested, restoring last full state ..."
    restore_cmd+=" --type=default"
    restore_cmd+=" --target-timeline=latest"
fi

if $CLI_DRY_RUN || $CLI_DEBUG; then
    echo
    echo "Restore command:"
    echo "$restore_cmd"
fi

if $CLI_DRY_RUN; then
    exit 0
fi

# Ensure that PostgreSQL datadir is empty
if [ -f ".env" ]; then
    pgdata_env=$(grep -E '^PGDATA=' .env | cut -d= -f2)
    [ -n "$pgdata_env" ] && POSTGRESQL_DATA_DIR="$pgdata_env"
fi
echo
echo "Checking if PostgreSQL datadir contains data ..."
$DOCKER_COMPOSE_PATH -p "$COMPOSE_PROJECT" run --rm -T "$PGBACKREST_DOCKER_CONTAINER" sh -c "[ -z \"\$(ls -A $POSTGRESQL_DATA_DIR)\" ]" 2>/dev/null

# Exit if stanza does not exist
if [ $? -ne 0 ]; then
    echo
    echo "The PostgreSQL data dir is not empty!"
    echo
    echo "Maybe you've already have used this Docker Compose project"
    echo "in the past?"
    echo
    echo "Hint: the Docker volume 'data' already exists, maybe you should"
    echo "purge this project running 'docker compose down -v'?"
    echo
    echo "WARNING: do this only if you know what you're doing!"
    echo
    echo "Exiting now!"
    exit 1
fi

# Start restore
echo
echo "Starting restore ..."

eval "$restore_cmd"
exit_status=$?

echo
echo "========================================================================"
echo

if [[ "$exit_status" -ne 0 ]]; then
  echo "ERROR DURING RESTORE."
  echo "The restore command exited with the status code $exit_status"
  echo "Please check the above output to find out where which error(s) occurred"
  echo "Fix them and try again."
else
  # Start PostgreSQL Docker container
  echo "Starting PostgreSQL Docker container ..."

  cmd="$DOCKER_COMPOSE_PATH -p $COMPOSE_PROJECT up -d --force-recreate"
  $cmd
  exit_status=$?

  echo
  echo "========================================================================"
  echo "PostgresSQL is up and running with the restored data!"
  echo "Connection port: $POSTGRESQL_HOST_PORT"
fi
