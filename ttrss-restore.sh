#!/usr/bin/env bash
#
# Restore the ttrss-docker stack from a backup created by ttrss-backup.sh.
#
# Usage:
#   ./ttrss-restore.sh <backup-dir> [component]
#
# <backup-dir>  path to a timestamped folder under ttrss-backups/
#               (e.g. ./ttrss-backups/20260825-143000)
# [component]   optional: all | images | config | db | app | backups
#               defaults to "all"
#
# Run this from the directory that contains docker-compose.yml and .env.

set -euo pipefail

VERSION="0.2"

usage() {
  cat <<EOF
ttrss-restore.sh ${VERSION}

Restore the ttrss-docker stack from a backup created by ttrss-backup.sh.

Usage:
  $0 [options] <backup-dir> [component]

Arguments:
  <backup-dir>  Path to a timestamped folder under ttrss-backups/
                (e.g. ./ttrss-backups/20260825-143000)
  [component]   all | images | config | db | app | backups
                Defaults to "all"

Options:
  -y, --yes       Assume "yes" to all confirmation prompts (non-interactive)
  -v, --version   Show version number and exit
  -h, --help      Show this help message and exit

Run this from the directory that contains docker-compose.yml and .env.
The "db" and "app" components are destructive and ask for confirmation,
unless -y/--yes is given.
EOF
}

ASSUME_YES=false

# --- Parse options and positional args --------------------------------

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)
      ASSUME_YES=true
      shift
      continue
      ;;
    -v|--version)
      echo "ttrss-restore.sh ${VERSION}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      continue
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

# --- Configuration ---------------------------------------------------------

PROJECT_DIR="$(pwd)"
BACKUP_DIR="${1:-}"
COMPONENT="${2:-all}"
IMAGE_BACKUP_DIR="${PROJECT_DIR}/ttrss-backups/images"

DB_CONTAINER="ttrss-docker-db-1"

DB_VOLUME="ttrss-docker_db"
APP_VOLUME="ttrss-docker_app"
BACKUPS_VOLUME="ttrss-docker_backups"

if [ -z "${BACKUP_DIR}" ]; then
  usage
  echo
  echo "Available backups:"
  ls -1 "${PROJECT_DIR}/ttrss-backups" 2>/dev/null | grep -v '^images$' || echo "  (none found)"
  exit 1
fi

if [ ! -d "${BACKUP_DIR}" ]; then
  echo "Error: backup dir '${BACKUP_DIR}' not found."
  exit 1
fi

# Docker's -v bind mounts require an absolute host path, and don't resolve
# relative paths against the shell's cwd the way plain file commands do —
# a relative path here gets misread as a named volume instead.
BACKUP_DIR="$(realpath "${BACKUP_DIR}")"

confirm() {
  local prompt="$1"
  local reply
  if [ "${ASSUME_YES}" = true ]; then
    echo "${prompt} Auto-confirmed (-y/--yes)."
    return 0
  fi
  read -r -p "${prompt} Type YES to continue: " reply
  if [ "${reply,,}" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi
}

echo "==> Restoring from ${BACKUP_DIR} (component: ${COMPONENT})"

# --- images: docker load the old image tarballs ----------------------------

restore_images() {
  echo "==> Loading images from ${IMAGE_BACKUP_DIR}"
  if [ -f "${IMAGE_BACKUP_DIR}/ttrss-fpm-pgsql-static.tar" ]; then
    docker load -i "${IMAGE_BACKUP_DIR}/ttrss-fpm-pgsql-static.tar"
  else
    echo "  (no ttrss-fpm-pgsql-static.tar found, skipping)"
  fi
  if [ -f "${IMAGE_BACKUP_DIR}/ttrss-web-nginx.tar" ]; then
    docker load -i "${IMAGE_BACKUP_DIR}/ttrss-web-nginx.tar"
  else
    echo "  (no ttrss-web-nginx.tar found, skipping)"
  fi
}

# --- config: docker-compose.yml, .env, config.d ----------------------------

restore_config() {
  echo "==> Restoring config files (current files saved with .pre-restore suffix)"
  [ -f "${PROJECT_DIR}/docker-compose.yml" ] && cp "${PROJECT_DIR}/docker-compose.yml" "${PROJECT_DIR}/docker-compose.yml.pre-restore"
  [ -f "${PROJECT_DIR}/.env" ] && cp "${PROJECT_DIR}/.env" "${PROJECT_DIR}/.env.pre-restore"
  [ -d "${PROJECT_DIR}/config.d" ] && cp -r "${PROJECT_DIR}/config.d" "${PROJECT_DIR}/config.d.pre-restore"

  cp "${BACKUP_DIR}/docker-compose.yml.bak" "${PROJECT_DIR}/docker-compose.yml"
  cp "${BACKUP_DIR}/.env.bak" "${PROJECT_DIR}/.env"
  if [ -d "${BACKUP_DIR}/config.d.bak" ]; then
    rm -rf "${PROJECT_DIR}/config.d"
    cp -r "${BACKUP_DIR}/config.d.bak" "${PROJECT_DIR}/config.d"
  fi
}

# --- db: recreate volume, fresh init, restore pg_dump -----------------------

restore_db() {
  confirm "This will STOP the stack and REPLACE the current database with ${BACKUP_DIR}/db-dump.sql.gz."

  echo "==> Stopping stack"
  docker compose -f "${PROJECT_DIR}/docker-compose.yml" down

  echo "==> Removing db volume (${DB_VOLUME})"
  docker volume rm "${DB_VOLUME}" || true

  echo "==> Starting fresh db container to reinitialize the volume"
  docker compose -f "${PROJECT_DIR}/docker-compose.yml" up -d db

  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"

  echo "==> Waiting for Postgres to be ready"
  until docker exec "${DB_CONTAINER}" pg_isready -U "${TTRSS_DB_USER}" >/dev/null 2>&1; do
    sleep 1
  done

  echo "==> Restoring dump into ${DB_CONTAINER}"
  gunzip -c "${BACKUP_DIR}/db-dump.sql.gz" | \
    docker exec -i -e PGPASSWORD="${TTRSS_DB_PASS}" "${DB_CONTAINER}" \
    psql -U "${TTRSS_DB_USER}" "${TTRSS_DB_NAME}"

  echo "==> Restarting full stack"
  docker compose -f "${PROJECT_DIR}/docker-compose.yml" up -d
}

# --- app volume: recreate and extract tarball -------------------------------

restore_app() {
  confirm "This will STOP the stack and REPLACE the app volume (${APP_VOLUME})."

  docker compose -f "${PROJECT_DIR}/docker-compose.yml" down

  echo "==> Recreating app volume"
  docker volume rm "${APP_VOLUME}" || true
  docker volume create "${APP_VOLUME}"

  echo "==> Extracting app-volume.tar.gz"
  docker run --rm \
    -v "${APP_VOLUME}:/data" \
    -v "${BACKUP_DIR}:/backup:ro" \
    alpine tar xzf /backup/app-volume.tar.gz -C /data

  echo "==> Restarting stack"
  docker compose -f "${PROJECT_DIR}/docker-compose.yml" up -d
}

# --- backups volume: recreate and extract tarball ---------------------------

restore_backups_volume() {
  confirm "This will REPLACE the backups volume (${BACKUPS_VOLUME})."

  echo "==> Recreating backups volume"
  docker volume rm "${BACKUPS_VOLUME}" || true
  docker volume create "${BACKUPS_VOLUME}"

  echo "==> Extracting backups-volume.tar.gz"
  docker run --rm \
    -v "${BACKUPS_VOLUME}:/data" \
    -v "${BACKUP_DIR}:/backup:ro" \
    alpine tar xzf /backup/backups-volume.tar.gz -C /data
}

# --- dispatch ----------------------------------------------------------

case "${COMPONENT}" in
  all)
    restore_images
    restore_config
    restore_app
    restore_db
    restore_backups_volume
    ;;
  images) restore_images ;;
  config) restore_config ;;
  db) restore_db ;;
  app) restore_app ;;
  backups) restore_backups_volume ;;
  *)
    echo "Unknown component '${COMPONENT}'. Use: all|images|config|db|app|backups"
    exit 1
    ;;
esac

echo "==> Restore complete."
