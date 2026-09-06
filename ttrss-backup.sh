#!/usr/bin/env bash
#
# Full backup of the ttrss-docker stack before migrating away from the
# discontinued cthulhoo images.
#
# Run this from the directory that contains docker-compose.yml and .env.

set -euo pipefail

VERSION="0.6"

usage() {
  cat <<EOF
ttrss-backup.sh ${VERSION}

Full backup of the ttrss-docker stack: old cthulhoo images, config files,
a live database dump, and the app/backups volumes.

Usage:
  $0 [options]

Options:
  -l, --log-level LVL Verbosity: quiet | error | verbose (default: error)
  -v, --version        Show version number and exit
  -h, --help           Show this help message and exit

Log levels:
  quiet    Only the final summary lines, no step-by-step progress
  error    Step-by-step progress lines, default tool verbosity (default)
  verbose  Step-by-step progress, plus pg_dump --verbose and tar -v
           (lists every file/table as it's archived/dumped)

Run this from the directory that contains docker-compose.yml and .env.
Output is written to ./ttrss-backups/<timestamp>/, with image tarballs
kept once under ./ttrss-backups/images/.
EOF
}

LOG_LEVEL="error"

while [ $# -gt 0 ]; do
  case "$1" in
    -l|--log-level)
      LOG_LEVEL="${2:-}"
      case "${LOG_LEVEL}" in
        quiet|error|verbose) ;;
        *)
          echo "Invalid --log-level '${LOG_LEVEL}': must be quiet, error, or verbose" >&2
          exit 1
          ;;
      esac
      shift 2
      continue
      ;;
    -v|--version)
      echo "ttrss-backup.sh ${VERSION}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

log_info() {
  [ "${LOG_LEVEL}" = "quiet" ] && return 0
  echo "$@"
}

# --- Configuration ---------------------------------------------------------

PROJECT_DIR="$(pwd)"
BACKUP_ROOT="${PROJECT_DIR}/ttrss-backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
OVERRIDE_FILE="${PROJECT_DIR}/docker-compose.override.yml"

OLD_APP_IMAGE="cthulhoo/ttrss-fpm-pgsql-static:latest"
OLD_WEB_IMAGE="cthulhoo/ttrss-web-nginx:latest"
IMAGE_BACKUP_DIR="${BACKUP_ROOT}/images"

# The Compose project name (and with it every default container/volume
# name) depends on the current directory's name. Resolve it live instead
# of hardcoding it, so renaming the project directory can't silently break
# container/volume lookups.
if [ ! -f "${COMPOSE_FILE}" ]; then
  echo "Error: ${COMPOSE_FILE} not found. Run this from the project directory." >&2
  exit 1
fi

# Passing -f explicitly (instead of relying on Compose's default file
# discovery) means docker-compose.override.yml is no longer picked up
# automatically, so add it back in by hand when present.
COMPOSE_ARGS=(-f "${COMPOSE_FILE}")
[ -f "${OVERRIDE_FILE}" ] && COMPOSE_ARGS+=(-f "${OVERRIDE_FILE}")

PROJECT_NAME="$(docker compose "${COMPOSE_ARGS[@]}" config 2>/dev/null | awk '/^name:/{print $2; exit}')"
if [ -z "${PROJECT_NAME}" ]; then
  echo "Error: could not determine the Compose project name from ${COMPOSE_FILE}." >&2
  exit 1
fi

# Look up a volume's real name via Docker's own Compose labels rather than
# guessing "<project>_<short>" ourselves.
get_volume_name() {
  local short="$1"
  local found
  found="$(docker volume ls \
    --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
    --filter "label=com.docker.compose.volume=${short}" \
    --format '{{.Name}}' | head -n1)"
  if [ -n "${found}" ]; then
    echo "${found}"
  else
    echo "${PROJECT_NAME}_${short}"
  fi
}

APP_VOLUME="$(get_volume_name app)"
BACKUPS_VOLUME="$(get_volume_name backups)"

# --- Setup -------------------------------------------------------------

mkdir -p "${BACKUP_DIR}"
mkdir -p "${IMAGE_BACKUP_DIR}"
log_info "==> Backing up into ${BACKUP_DIR}"

# --- 1. Save the old images (once — they can no longer be pulled) ---------

if [ ! -f "${IMAGE_BACKUP_DIR}/ttrss-fpm-pgsql-static.tar" ]; then
  log_info "==> Saving ${OLD_APP_IMAGE}"
  docker save "${OLD_APP_IMAGE}" -o "${IMAGE_BACKUP_DIR}/ttrss-fpm-pgsql-static.tar"
else
  log_info "==> Image tar for ttrss-fpm-pgsql-static already exists, skipping"
fi

if [ ! -f "${IMAGE_BACKUP_DIR}/ttrss-web-nginx.tar" ]; then
  log_info "==> Saving ${OLD_WEB_IMAGE}"
  docker save "${OLD_WEB_IMAGE}" -o "${IMAGE_BACKUP_DIR}/ttrss-web-nginx.tar"
else
  log_info "==> Image tar for ttrss-web-nginx already exists, skipping"
fi

# --- 2. Config files ---------------------------------------------------
#
# .env and docker-compose.override.yml are intentionally gitignored
# (secrets and local-only overrides), so they're backed up here.
# docker-compose.yml and config.d are tracked in git and are not backed
# up by this script.

log_info "==> Backing up config files"
cp "${PROJECT_DIR}/.env" "${BACKUP_DIR}/.env.bak"
if [ -f "${PROJECT_DIR}/docker-compose.override.yml" ]; then
  cp "${PROJECT_DIR}/docker-compose.override.yml" "${BACKUP_DIR}/docker-compose.override.yml.bak"
fi

# --- 3. Database logical dump (safe to run while ttrss is up) --------------

log_info "==> Dumping database from the db service"
# shellcheck disable=SC1091
source "${PROJECT_DIR}/.env"

pg_dump_opts=(-U "${TTRSS_DB_USER}" "${TTRSS_DB_NAME}")
[ "${LOG_LEVEL}" = "verbose" ] && pg_dump_opts=(--verbose "${pg_dump_opts[@]}")

docker compose "${COMPOSE_ARGS[@]}" exec -T -e PGPASSWORD="${TTRSS_DB_PASS}" db \
  pg_dump "${pg_dump_opts[@]}" \
  | gzip -9 > "${BACKUP_DIR}/db-dump.sql.gz"

# --- 4. app volume (safe to copy live) ----------------------------------

log_info "==> Archiving app volume (${APP_VOLUME})"
tar_flags="czf"
[ "${LOG_LEVEL}" = "verbose" ] && tar_flags="cvzf"
docker run --rm \
  -v "${APP_VOLUME}:/data:ro" \
  -v "${BACKUP_DIR}:/backup" \
  alpine tar "${tar_flags}" /backup/app-volume.tar.gz -C /data .

# --- 5. backups volume (existing periodic backups, if any) -----------------

log_info "==> Archiving backups volume (${BACKUPS_VOLUME})"
docker run --rm \
  -v "${BACKUPS_VOLUME}:/data:ro" \
  -v "${BACKUP_DIR}:/backup" \
  alpine tar "${tar_flags}" /backup/backups-volume.tar.gz -C /data .

# --- 6. Raw db volume (optional, requires stopping db for consistency) -----
#
# Uncomment if you want a raw filesystem-level copy in addition to the
# pg_dump above. This briefly stops the database container.
#
# db_volume="$(get_volume_name db)"
# log_info "==> Stopping db service for a consistent raw volume copy"
# docker compose "${COMPOSE_ARGS[@]}" stop db
# docker run --rm \
#   -v "${db_volume}:/data:ro" \
#   -v "${BACKUP_DIR}:/backup" \
#   alpine tar "${tar_flags}" /backup/db-volume-raw.tar.gz -C /data .
# docker compose "${COMPOSE_ARGS[@]}" start db

log_info "==> Done. Backup stored in ${BACKUP_DIR}"
log_info "==> Old images stored in ${IMAGE_BACKUP_DIR} (kept across runs)"
