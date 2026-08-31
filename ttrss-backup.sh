#!/usr/bin/env bash
#
# Full backup of the ttrss-docker stack before migrating away from the
# discontinued cthulhoo images.
#
# Run this from the directory that contains docker-compose.yml and .env.

set -euo pipefail

VERSION="0.2"

usage() {
  cat <<EOF
ttrss-backup.sh ${VERSION}

Full backup of the ttrss-docker stack: old cthulhoo images, config files,
a live database dump, and the app/backups volumes.

Usage:
  $0 [options]

Options:
  -v, --version   Show version number and exit
  -h, --help      Show this help message and exit

Run this from the directory that contains docker-compose.yml and .env.
Output is written to ./ttrss-backups/<timestamp>/, with image tarballs
kept once under ./ttrss-backups/images/.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
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

# --- Configuration ---------------------------------------------------------

PROJECT_DIR="$(pwd)"
BACKUP_ROOT="${PROJECT_DIR}/ttrss-backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"

DB_CONTAINER="ttrss-docker-db-1"
APP_CONTAINER="ttrss-docker-app-1"

DB_VOLUME="ttrss-docker_db"
APP_VOLUME="ttrss-docker_app"
BACKUPS_VOLUME="ttrss-docker_backups"

OLD_APP_IMAGE="cthulhoo/ttrss-fpm-pgsql-static:latest"
OLD_WEB_IMAGE="cthulhoo/ttrss-web-nginx:latest"
IMAGE_BACKUP_DIR="${BACKUP_ROOT}/images"

# --- Setup -------------------------------------------------------------

mkdir -p "${BACKUP_DIR}"
mkdir -p "${IMAGE_BACKUP_DIR}"
echo "==> Backing up into ${BACKUP_DIR}"

# --- 1. Save the old images (once — they can no longer be pulled) ---------

if [ ! -f "${IMAGE_BACKUP_DIR}/ttrss-fpm-pgsql-static.tar" ]; then
  echo "==> Saving ${OLD_APP_IMAGE}"
  docker save "${OLD_APP_IMAGE}" -o "${IMAGE_BACKUP_DIR}/ttrss-fpm-pgsql-static.tar"
else
  echo "==> Image tar for ttrss-fpm-pgsql-static already exists, skipping"
fi

if [ ! -f "${IMAGE_BACKUP_DIR}/ttrss-web-nginx.tar" ]; then
  echo "==> Saving ${OLD_WEB_IMAGE}"
  docker save "${OLD_WEB_IMAGE}" -o "${IMAGE_BACKUP_DIR}/ttrss-web-nginx.tar"
else
  echo "==> Image tar for ttrss-web-nginx already exists, skipping"
fi

# --- 2. Config files ---------------------------------------------------

echo "==> Backing up config files"
cp "${PROJECT_DIR}/docker-compose.yml" "${BACKUP_DIR}/docker-compose.yml.bak"
cp "${PROJECT_DIR}/.env" "${BACKUP_DIR}/.env.bak"
if [ -d "${PROJECT_DIR}/config.d" ]; then
  cp -r "${PROJECT_DIR}/config.d" "${BACKUP_DIR}/config.d.bak"
fi

# --- 3. Database logical dump (safe to run while ttrss is up) --------------

echo "==> Dumping database from ${DB_CONTAINER}"
# shellcheck disable=SC1091
source "${PROJECT_DIR}/.env"
docker exec -e PGPASSWORD="${TTRSS_DB_PASS}" "${DB_CONTAINER}" \
  pg_dump -U "${TTRSS_DB_USER}" "${TTRSS_DB_NAME}" \
  | gzip -9 > "${BACKUP_DIR}/db-dump.sql.gz"

# --- 4. app volume (safe to copy live) ----------------------------------

echo "==> Archiving app volume (${APP_VOLUME})"
docker run --rm \
  -v "${APP_VOLUME}:/data:ro" \
  -v "${BACKUP_DIR}:/backup" \
  alpine tar czf /backup/app-volume.tar.gz -C /data .

# --- 5. backups volume (existing periodic backups, if any) -----------------

echo "==> Archiving backups volume (${BACKUPS_VOLUME})"
docker run --rm \
  -v "${BACKUPS_VOLUME}:/data:ro" \
  -v "${BACKUP_DIR}:/backup" \
  alpine tar czf /backup/backups-volume.tar.gz -C /data .

# --- 6. Raw db volume (optional, requires stopping db for consistency) -----
#
# Uncomment if you want a raw filesystem-level copy in addition to the
# pg_dump above. This briefly stops the database container.
#
# echo "==> Stopping ${DB_CONTAINER} for a consistent raw volume copy"
# docker stop "${DB_CONTAINER}"
# docker run --rm \
#   -v "${DB_VOLUME}:/data:ro" \
#   -v "${BACKUP_DIR}:/backup" \
#   alpine tar czf /backup/db-volume-raw.tar.gz -C /data .
# docker start "${DB_CONTAINER}"

echo "==> Done. Backup stored in ${BACKUP_DIR}"
echo "==> Old images stored in ${IMAGE_BACKUP_DIR} (kept across runs)"
