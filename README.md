# pgbackrest-restore-docker

A Docker Compose environment for restoring PostgreSQL backups from a
[pgBackRest](https://pgbackrest.org/) repository hosted on S3-compatible storage.

The project spins up a temporary PostgreSQL container with pgBackRest pre-installed,
connects it to your existing S3 backup repository, runs the restore, and then starts
PostgreSQL with the recovered data.

> **Tested with pgBackRest 2.58.0.** Older versions may work but are not guaranteed
> to be compatible.

## Requirements

### Host machine

| Requirement | Notes |
|-------------|-------|
| Docker Engine | 20.10 or later |
| Docker Compose | v2 (the `docker compose` plugin, not `docker-compose`) |
| `bash` | 3.2 or later (macOS system bash is supported) |
| `jq` | 1.6 or later — used to parse pgBackRest JSON output |
| `nc` | netcat — used to check port availability |

Install `jq` on macOS:
```bash
brew install jq
```

Install `jq` on Debian/Ubuntu:
```bash
apt-get install jq
```

### S3 repository

The project expects a pgBackRest backup repository stored on S3-compatible object
storage. The following must be in place before running a restore:

- A working pgBackRest stanza with at least one completed full backup
- S3 credentials with read access to the repository bucket
- The repository encryption passphrase (if backups are encrypted)

### PostgreSQL version

The Docker image used (`mmartinello/postgresql-pgbackrest`) supports PostgreSQL
major versions **14, 15, 16, and 17**. The version must match the major version
of the source cluster that produced the backups.

## Setup

### 1. Configure environment variables

Copy `.env.sample` to `.env` and fill in the values:

```bash
cp .env.sample .env
```

```ini
# pgBackRest stanza name
PGBACKREST_STANZA=my_stanza

# PostgreSQL major version (must match the backup source)
POSTGRES_VERSION=17

# PostgreSQL superuser credentials (created on first start)
POSTGRES_USER=postgres
POSTGRES_PASSWORD=secret

# Host port exposed by the PostgreSQL container.
# If this port is busy the script automatically tries the first free port
# in POSTGRESQL_HOST_PORT_RANGE.
POSTGRESQL_HOST_PORT=5432
POSTGRESQL_HOST_PORT_RANGE=5433-5450
```

### 2. Configure pgBackRest

Copy `pgbackrest.conf.sample` to `pgbackrest.conf` and fill in your repository
details:

```bash
cp pgbackrest.conf.sample pgbackrest.conf
```

```ini
[global]
repo1-type=s3
repo1-path=/repo
repo1-s3-endpoint=s3.amazonaws.com
repo1-s3-bucket=my-backup-bucket
repo1-s3-uri-style=host
repo1-s3-key=AKIAIOSFODNN7EXAMPLE
repo1-s3-key-secret=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
repo1-s3-region=eu-west-1
repo1-s3-verify-tls=y

repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=my-encryption-passphrase

[my_stanza]
pg1-path=/var/lib/postgresql/data
```

Each section name other than `[global]` is a stanza. You can define multiple stanzas
in the same file (e.g. one per environment) and the restore script will let you choose
which one to use.

## Commands

Make the script executable (first time only):

```bash
chmod +x pgbackrest-restore.sh
```

Run `./pgbackrest-restore.sh help` or `./pgbackrest-restore.sh --help` for a list of
available commands.

### list — list available backups

```bash
./pgbackrest-restore.sh list
```

Displays all available backups for a stanza, sorted most-recent-first, in a paginated
two-column layout. Exits after printing — no restore is performed.

Pass `--stanza` to skip the interactive prompt:

```bash
./pgbackrest-restore.sh list --stanza my_stanza
```

### show — show active restore instances

```bash
./pgbackrest-restore.sh show
```

Lists all active restore instances started from the `docker-compose.yml` in the current
directory. For each instance the project name, Docker Compose status, and the PostgreSQL
host port are shown. Useful when multiple restores are running in parallel (one per port)
and you need a quick overview.

Example output:

```
pgBackRest Restore Instances

  PROJECT                                   STATUS                PORT
  -------                                   ------                ----
  pgbackrest_restore_5432                   running(1)            5432
  pgbackrest_restore_15432                  running(1)            15432
```

### stop — stop an active restore instance

```bash
./pgbackrest-restore.sh stop INSTANCE
```

Stops the specified restore instance by running `docker compose down` for that project.
Only instances started from the `docker-compose.yml` in the current directory can be
stopped with this command. **Docker volumes are preserved** — only containers are stopped
and removed. To also delete the volumes, run `docker compose down -v` manually afterwards.

`INSTANCE` is the project name as shown by `./pgbackrest-restore.sh show`
(e.g. `pgbackrest_restore_5432`).

```bash
./pgbackrest-restore.sh stop pgbackrest_restore_5432
```

### restore — restore a backup

```bash
./pgbackrest-restore.sh restore
```

Run without options to be guided through every parameter step by step.

The script will ask:

1. **Host port** — port exposed on the Docker host; the script checks availability
   automatically and falls back to `POSTGRESQL_HOST_PORT_RANGE` if the default is busy
2. **PostgreSQL version** — major version to use (default from `.env`)
3. **Stanza** — which stanza to restore from (read from `pgbackrest.conf`)
4. **PITR target time** — optional point-in-time recovery timestamp
   (`YYYY-MM-DD HH:MM:SS`); press ENTER to skip and select a backup set instead
5. **Backup set** — select from a paginated list sorted most-recent-first; press
   ENTER to use the latest available backup (skipped if a PITR time was provided)
6. **Databases to include** — space-separated list; press ENTER to restore all

#### Non-interactive (CLI) mode

Pass one or more options to skip the corresponding interactive prompts. Any
parameter not provided on the command line uses its default value silently —
no prompt is shown.

| Option | Short | Argument | Description |
|--------|-------|----------|-------------|
| `--postgres-version` | `-V` | `VERSION` | PostgreSQL major version |
| `--stanza` | `-s` | `STANZA` | pgBackRest stanza name |
| `--backup-set` | `-b` | `LABEL\|latest` | Backup label, or `latest` for the most recent |
| `--time` | `-t` | `'YYYY-MM-DD HH:MM:SS'` | Point-in-time recovery target |
| `--databases` | `-d` | `'db1 db2 ...'` | Databases to restore (space-separated) |
| `--port` | `-p` | `PORT` | PostgreSQL host port (error if already in use) |
| `--dry-run` | | | Print the restore command without executing it |
| `--debug` | | | Print debug information during execution |
| `--help` | `-h` | | Show usage and exit |

#### Examples

**Restore the latest backup of a stanza (fully non-interactive):**

```bash
./pgbackrest-restore.sh restore \
  -V 17 \
  -s my_stanza \
  -b latest
```

**Restore a specific backup set:**

```bash
./pgbackrest-restore.sh restore \
  -V 17 \
  -s my_stanza \
  -b 20260510-020005F
```

**Point-in-time recovery to a specific timestamp:**

```bash
./pgbackrest-restore.sh restore \
  -V 17 \
  -s my_stanza \
  -t '2026-05-12 14:30:00'
```

**Restore only specific databases:**

```bash
./pgbackrest-restore.sh restore \
  -V 17 \
  -s my_stanza \
  -b latest \
  -d 'myapp analytics'
```

**Restore on a specific port:**

```bash
./pgbackrest-restore.sh restore \
  -V 17 \
  -s my_stanza \
  -b latest \
  -p 15432
```

**Preview the restore command without executing it:**

```bash
./pgbackrest-restore.sh restore \
  -V 17 \
  -s my_stanza \
  -b latest \
  -t '2026-05-12 14:30:00' \
  --dry-run
```

## Port selection

When no `--port` is given, the script selects the host port automatically:

1. Checks if `POSTGRESQL_HOST_PORT` (from `.env`) is free
2. If free, uses it
3. If busy, scans `POSTGRESQL_HOST_PORT_RANGE` in order and picks the first free port
4. If the entire range is busy, exits with an error

If `--port` is given explicitly and that port is already in use, the script exits
with an error immediately.

In non-interactive CLI mode (any data option supplied), the default port is used
as-is without availability checks.

## Restore behaviour

The script selects the appropriate pgBackRest restore strategy based on the
parameters provided:

| Scenario | pgBackRest options used |
|----------|------------------------|
| Full restore, latest backup | `--type=default --target-timeline=latest` |
| Full restore, specific backup | `--set=LABEL --type=default --target-timeline=latest` |
| PITR | `--type=time --target='...' --target-action=promote` |
| Selective restore (`--databases`) | `--type=immediate --target-action=promote` |

## Cleaning up

If you need to start over (e.g. the restore failed or you want to restore a
different backup), remove the Docker volumes created by this project:

```bash
docker compose down -v
```

> **Warning:** this permanently deletes all data in the Docker volumes. Only run
> this if you are sure you want to discard the current state.
