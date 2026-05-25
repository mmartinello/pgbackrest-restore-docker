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

# Host port exposed by the PostgreSQL container
POSTGRESQL_HOST_PORT=5432
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

## Running a restore

Make the script executable (first time only):

```bash
chmod +x pgbackrest-restore.sh
```

### Interactive mode

Run without arguments to be guided through every parameter step by step:

```bash
./pgbackrest-restore.sh
```

The script will ask:

1. **PostgreSQL version** — major version to use (default from `.env`)
2. **Stanza** — which stanza to restore from (read from `pgbackrest.conf`)
3. **Backup set** — select from a paginated list sorted most-recent-first; press
   ENTER to use the latest available backup
4. **PITR target time** — optional point-in-time recovery timestamp
   (`YYYY-MM-DD HH:MM:SS`); press ENTER to skip
5. **Databases to include** — space-separated list; press ENTER to restore all
6. **Databases to exclude** — space-separated list; press ENTER to exclude none
7. **Host port** — port exposed on the Docker host (default from `.env`)

### Non-interactive (CLI) mode

Pass one or more arguments to skip the corresponding interactive prompts. Any
parameter not provided on the command line uses its default value silently —
no prompt is shown.

#### Options

| Option | Short | Argument | Default (CLI mode) | Description |
|--------|-------|----------|--------------------|-------------|
| `--postgres-version` | `-V` | `VERSION` | — (required) | PostgreSQL major version |
| `--stanza` | `-s` | `STANZA` | — (required) | pgBackRest stanza name |
| `--backup-set` | `-b` | `LABEL\|latest` | — (required) | Backup label, or `latest` for the most recent |
| `--time` | `-t` | `'YYYY-MM-DD HH:MM:SS'` | no PITR | Point-in-time recovery target |
| `--databases` | `-d` | `'db1 db2 ...'` | all databases | Databases to restore (space-separated) |
| `--exclude` | `-e` | `'db1 db2 ...'` | none | Databases to exclude (space-separated) |
| `--port` | `-p` | `PORT` | value from `.env` or `5432` | PostgreSQL host port |
| `--dry-run` | | | | Print the restore command without executing it |
| `--debug` | | | | Print debug information during execution |
| `--help` | `-h` | | | Show usage and exit |

#### Examples

**Restore the latest backup of a production stanza (fully non-interactive):**

```bash
./pgbackrest-restore.sh \
  -V 17 \
  -s my_stanza_prod \
  -b latest
```

**Restore a specific backup set:**

```bash
./pgbackrest-restore.sh \
  -V 17 \
  -s my_stanza_prod \
  -b 20260510-020005F
```

**Point-in-time recovery to a specific timestamp:**

```bash
./pgbackrest-restore.sh \
  -V 17 \
  -s my_stanza_prod \
  -b latest \
  -t '2026-05-12 14:30:00'
```

**Restore only specific databases:**

```bash
./pgbackrest-restore.sh \
  -V 17 \
  -s my_stanza_prod \
  -b latest \
  -d 'myapp analytics'
```

**Restore all databases except one:**

```bash
./pgbackrest-restore.sh \
  -V 17 \
  -s my_stanza_prod \
  -b latest \
  -e 'legacy_db'
```

**Restore on a non-default port:**

```bash
./pgbackrest-restore.sh \
  -V 17 \
  -s my_stanza_prod \
  -b latest \
  -p 15432
```

**Preview the restore command without executing it:**

```bash
./pgbackrest-restore.sh \
  -V 17 \
  -s my_stanza_prod \
  -b latest \
  -t '2026-05-12 14:30:00' \
  --dry-run
```

## Restore behaviour

The script selects the appropriate pgBackRest restore strategy based on the
parameters provided:

| Scenario | pgBackRest options used |
|----------|------------------------|
| Full restore, latest backup | `--type=default --target-timeline=latest` |
| Full restore, specific backup | `--set=LABEL --type=default --target-timeline=latest` |
| PITR | `--type=time --target='...' --target-action=promote` |
| Selective restore (`--db-include` / `--db-exclude`) | `--type=immediate --target-action=promote` |

## Cleaning up

If you need to start over (e.g. the restore failed or you want to restore a
different backup), remove the Docker volumes created by this project:

```bash
docker compose down -v
```

> **Warning:** this permanently deletes all data in the Docker volumes. Only run
> this if you are sure you want to discard the current state.
