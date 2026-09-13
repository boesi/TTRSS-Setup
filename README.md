# TTRSS-Setup

Docker-based [Tiny Tiny RSS](https://tt-rss.org/) setup using the now-discontinued
cthulhoo images, with backup and restore scripts.

## Services

| Service | Description |
|---------|-------------|
| `app` | tt-rss FPM application |
| `web-nginx` | Nginx reverse proxy serving the frontend |
| `db` | PostgreSQL 12 database |
| `updater` | Background feed updater |
| `backups` | Periodic backup runner (dcron) |

## Setup

1. Copy `.env-dist` to `.env` and adjust the values:

   ```bash
   cp .env-dist .env
   ```

   At minimum, set `TTRSS_SELF_URL_PATH` to your public URL.

2. Start the stack:

   ```bash
   docker compose up -d
   ```

   The default admin password is printed in the `app` container logs on first
   startup. Set `ADMIN_USER_PASS` in `.env` to override.

## Backup

```bash
./ttrss-backup.sh [backup-dir]
```

Creates a timestamped backup under `./ttrss-backups/<timestamp>/` containing:

- Docker image tarballs (saved once to `./ttrss-backups/images/`)
- Config files (`.env`, `docker-compose.override.yml`)
- Live database dump (gzipped pg_dump)
- `app` and `backups` volume archives

Run with `-h` for options (`--log-level quiet|error|verbose`).

**Tip:** Pass an external directory to avoid losing backups if the project
folder is recreated:

```bash
./ttrss-backup.sh /mnt/backups/ttrss
```

## Restore

```bash
./ttrss-restore.sh <backup-dir> [component]
```

Components: `all` (default) | `images` | `config` | `db` | `app` | `backups`

Destructive components (`db`, `app`) ask for confirmation unless `-y` is
given. Run with `-h` for options.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
