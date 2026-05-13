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
CLI_EXCLUDE_DATABASES=false
CLI_PORT=false
CLI_DRY_RUN=false

# Check if the jq command exists
jq_cmd_path=$(which jq 2>/dev/null)
if [ -z "$jq_cmd_path" ]; then
    echo "Error: command 'jq' not installed, please install it and try again!"
    exit 1
fi

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -V, --postgres-version VERSION        PostgreSQL version"
    echo "  -s, --stanza STANZA                   pgBackRest stanza name"
    echo "  -b, --backup-set LABEL|latest         Backup label, or 'latest' for most recent"
    echo "  -t, --time 'YYYY-MM-DD HH:MM:SS'      Point-in-time recovery target"
    echo "  -d, --databases 'db1 db2 ...'         Databases to restore (default: all)"
    echo "  -e, --exclude 'db1 db2 ...'           Databases to exclude"
    echo "  -p, --port PORT                       PostgreSQL host port"
    echo "  --dry-run                             Print the restore command without executing it"
    echo "  -h, --help                            Show this help"
    echo ""
    echo "If no options are provided, all parameters are asked interactively."
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

# Select the PostgreSQL host port
select_postgresql_port() {
    if $CLI_PORT; then
        export POSTGRESQL_HOST_PORT
        echo "PostgreSQL host port: $POSTGRESQL_HOST_PORT"
        return 0
    fi

    local default_port=""

    if [ -f ".env" ]; then
        default_port=$(grep -E '^POSTGRESQL_HOST_PORT=' .env | cut -d= -f2)
    fi
    [ -z "$default_port" ] && default_port="5432"

    while true; do
        read -p "Which port should PostgreSQL listen on? (ENTER for default: $default_port): " port_input

        if [ -z "$port_input" ]; then
            POSTGRESQL_HOST_PORT="$default_port"
            break
        elif [[ "$port_input" =~ ^[0-9]+$ ]] && [ "$port_input" -ge 1 ] && [ "$port_input" -le 65535 ]; then
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
    if $CLI_DATABASES; then
        return 0
    fi

    msg="Which database/s do you want to restore"
    msg+=" (space separated values, press ENTER for all databases)?"
    read -p "$msg " databases_string
}

# Select databases to be excluded
select_excluded_databases() {
    if $CLI_EXCLUDE_DATABASES; then
        return 0
    fi

    msg="Which database/s do you want to EXCLUDE from restore"
    msg+=" (space separated values, press ENTER for no database excluded)?"
    read -p "$msg " databases_excluded_string
}

# Select which time point to be restored
select_time() {
    if $CLI_TIME; then
        return 0
    fi

    msg="Which time do you want to restore"
    msg+=" (YYYY-MM-DD HH:MM:SS, press ENTER for last full backup)?"
    read -p "$msg " time_string
}

# Check if a given date is correct and has the correct format
# Valid format: YYYY-MM-DD HH:MM:SS
# Return values:
# - 0: valid format and valid date
# - 1: valid format but wrong date
# - 2: wrong format
check_date() {
    date_string=$1

    echo "Checking date string: $date_string"

    # Check if the given string has the valid format
    if [[ "$date_string" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then

      # Check if the given string is a valid date
      if date -d "$date_stringut" >/dev/null 2>&1; then
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

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -V|--postgres-version)
            POSTGRES_VERSION="$2"; CLI_POSTGRES_VERSION=true; shift 2 ;;
        -s|--stanza)
            stanza="$2"; CLI_STANZA=true; shift 2 ;;
        -b|--backup-set)
            [ "$2" = "latest" ] && backup_set="" || backup_set="$2"
            CLI_BACKUP_SET=true; shift 2 ;;
        -t|--time)
            time_string="$2"; CLI_TIME=true; shift 2 ;;
        -d|--databases)
            databases_string="$2"; CLI_DATABASES=true; shift 2 ;;
        -e|--exclude)
            databases_excluded_string="$2"; CLI_EXCLUDE_DATABASES=true; shift 2 ;;
        -p|--port)
            if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ]; then
                POSTGRESQL_HOST_PORT="$2"; CLI_PORT=true
            else
                echo "Error: invalid port '$2'. Must be between 1 and 65535."
                exit 1
            fi
            shift 2 ;;
        --dry-run)
            CLI_DRY_RUN=true; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Error: unknown option '$1'"
            usage; exit 1 ;;
    esac
done

# Print title
echo "pgBackRest Backup Restore"

##############################################################################
# Main script

# Select the PostgreSQL version
select_postgres_version
echo

# Select the stanza
select_stanza "$CONFIG_FILE_NAME"
echo

# Select the backup set to restore
backup_list_cmd="$DOCKER_COMPOSE_PATH run --rm $PGBACKREST_DOCKER_CONTAINER pgbackrest --stanza=$stanza info --output=json 2>/dev/null"
backups_json=$(eval "$backup_list_cmd")
choose_backup "$backups_json"
echo

# Select the time
select_time
echo

# Select databases to include
select_databases
echo

# Select databases to exclude
select_excluded_databases
echo

# Select the PostgreSQL host port
select_postgresql_port
echo

# Print debug
#echo "Stanza: $stanza"
#echo "Databases: $databases_string"
#echo "Backup set: $backup_set"
#echo "Time: $time_string"

# Basic pgBackRest restore command
restore_cmd="$DOCKER_COMPOSE_PATH run --rm $PGBACKREST_DOCKER_CONTAINER"
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

# Exclude databases
if [ -n "$databases_excluded_string" ]; then
    databases=($databases_excluded_string)

    for database in "${databases[@]}"; do
        restore_cmd+=" --db-exclude=$database"
    done
else
    echo "No database to be excluded ..."
fi

# Point In Time Recovery
if [ -n "$time_string" ]; then
    check_date "$time_string"
    check_date_result=$?

    echo "Check date result: $check_date_result"
    case "$check_date_result" in
        0)
            restore_cmd+=" --target=\"$time_string\" --type=time"
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
else
    echo "No PITR requested, restoring last full state ..."

    restore_cmd+=" --type=default"
    restore_cmd+=" --target-timeline=current"
fi

echo
echo "Restore command:"
echo "$restore_cmd"

if $CLI_DRY_RUN; then
    exit 0
fi

# Ensure that PostgreSQL datadir is empty
echo
echo "Checking if PostgreSQL datadir contains data ..."
$DOCKER_COMPOSE_PATH run --rm -T "$PGBACKREST_DOCKER_CONTAINER" sh -c "[ -z \"\$(ls -A $POSTGRESQL_DATA_DIR)\" ]" 2>/dev/null

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

$restore_cmd
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

  cmd="$DOCKER_COMPOSE_PATH up -d"
  $cmd
  exit_status=$?

  source .env

  echo
  echo "========================================================================"
  echo "PostgresSQL is up and running with the restored data!"
  echo "Connection port: $POSTGRESQL_HOST_PORT"
fi
