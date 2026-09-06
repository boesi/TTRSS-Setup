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

VERSION="0.6"

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
  -y, --yes           Assume "yes" to all confirmation prompts (non-interactive)
  -l, --log-level LVL Database restore verbosity: quiet | error | verbose
                      (default: error)
  -v, --version       Show version number and exit
  -h, --help          Show this help message and exit

Log levels for the "db" component (maps to psql's ECHO setting):
  quiet    Only errors and server NOTICEs, no per-statement progress output
  error    Like quiet, but also prints the exact SQL statement that failed
           (default)
  verbose  Prints every SQL statement as it is executed, plus progress output

The restore always stops immediately on the first database error
(psql's ON_ERROR_STOP), regardless of log level.

Run this from the directory that contains docker-compose.yml and .env.
The "db" and "app" components are destructive and ask for confirmation,
unless -y/--yes is given.
EOF
}

ASSUME_YES=false
LOG_LEVEL="error"

# --- Parse options and positional args --------------------------------

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)
      ASSUME_YES=true
      shift
      continue
      ;;
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
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
OVERRIDE_FILE="${PROJECT_DIR}/docker-compose.override.yml"

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

# The Compose project name (and with it every default container/volume
# name) depends on the current directory's name, not on the "ttrss-docker"
# name from when this stack was first set up. Resolve it live instead of
# hardcoding it, so renaming the project directory can't silently break
# container/volume lookups.
#
# Passing -f explicitly (instead of relying on Compose's default file
# discovery) means docker-compose.override.yml is no longer picked up
# automatically, so COMPOSE_ARGS adds it back in by hand when present.
# This is rebuilt on every call (not cached like PROJECT_NAME) since the
# "config" component can restore docker-compose.override.yml partway
# through a run, e.g. during the "all" restore.
PROJECT_NAME=""
COMPOSE_ARGS=()
resolve_project_name() {
  if [ ! -f "${COMPOSE_FILE}" ]; then
    echo "Error: ${COMPOSE_FILE} not found — restore the 'config' component first." >&2
    exit 1
  fi
  COMPOSE_ARGS=(-f "${COMPOSE_FILE}")
  [ -f "${OVERRIDE_FILE}" ] && COMPOSE_ARGS+=(-f "${OVERRIDE_FILE}")

  [ -n "${PROJECT_NAME}" ] && return 0
  PROJECT_NAME="$(docker compose "${COMPOSE_ARGS[@]}" config 2>/dev/null | awk '/^name:/{print $2; exit}')"
  if [ -z "${PROJECT_NAME}" ]; then
    echo "Error: could not determine the Compose project name from ${COMPOSE_FILE}." >&2
    exit 1
  fi
}

# Look up a volume's real name via Docker's own Compose labels rather than
# guessing "<project>_<short>" ourselves — falls back to that convention
# only if the volume doesn't exist yet (e.g. a brand-new host).
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

# --- config: .env, docker-compose.override.yml ------------------------------
#
# .env and docker-compose.override.yml are intentionally gitignored
# (secrets and local-only overrides), so they're restored here.
# docker-compose.yml and config.d are tracked in git and are not restored
# by this script.

restore_config() {
  echo "==> Restoring config files (current files saved with .pre-restore suffix)"
  [ -f "${PROJECT_DIR}/.env" ] && cp "${PROJECT_DIR}/.env" "${PROJECT_DIR}/.env.pre-restore"
  [ -f "${PROJECT_DIR}/docker-compose.override.yml" ] && cp "${PROJECT_DIR}/docker-compose.override.yml" "${PROJECT_DIR}/docker-compose.override.yml.pre-restore"

  cp "${BACKUP_DIR}/.env.bak" "${PROJECT_DIR}/.env"
  if [ -f "${BACKUP_DIR}/docker-compose.override.yml.bak" ]; then
    cp "${BACKUP_DIR}/docker-compose.override.yml.bak" "${PROJECT_DIR}/docker-compose.override.yml"
  fi
}

# --- db: recreate volume, fresh init, restore pg_dump -----------------------

restore_db() {
  confirm "This will STOP the stack and REPLACE the current database with ${BACKUP_DIR}/db-dump.sql.gz."

  resolve_project_name
  local db_volume
  db_volume="$(get_volume_name db)"

  echo "==> Stopping stack"
  docker compose "${COMPOSE_ARGS[@]}" down

  echo "==> Removing db volume (${db_volume})"
  docker volume rm "${db_volume}" || true

  echo "==> Starting fresh db container to reinitialize the volume"
  docker compose "${COMPOSE_ARGS[@]}" up -d db

  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"

  echo "==> Waiting for Postgres to be ready"
  local waited=0
  until docker compose "${COMPOSE_ARGS[@]}" exec -T db pg_isready -U "${TTRSS_DB_USER}" >/dev/null 2>&1; do
    sleep 1
    waited=$((waited + 1))
    if [ "${waited}" -ge 60 ]; then
      echo "Error: db service did not become ready within 60s." >&2
      echo "Check 'docker compose ${COMPOSE_ARGS[*]} logs db' for details." >&2
      exit 1
    fi
  done

  echo "==> Restoring dump into the db service (log level: ${LOG_LEVEL})"
  local psql_opts=(-v ON_ERROR_STOP=1)
  case "${LOG_LEVEL}" in
    quiet)   psql_opts+=(-q) ;;
    error)   psql_opts+=(-q --set ECHO=errors) ;;
    verbose) psql_opts+=(--set ECHO=all) ;;
  esac

  gunzip -c "${BACKUP_DIR}/db-dump.sql.gz" | \
    docker compose "${COMPOSE_ARGS[@]}" exec -T -e PGPASSWORD="${TTRSS_DB_PASS}" db \
    psql "${psql_opts[@]}" -U "${TTRSS_DB_USER}" "${TTRSS_DB_NAME}"

  echo "==> Restarting full stack"
  docker compose "${COMPOSE_ARGS[@]}" up -d
}

# --- app volume: recreate and extract tarball -------------------------------

restore_app() {
  resolve_project_name
  local app_volume
  app_volume="$(get_volume_name app)"

  confirm "This will STOP the stack and REPLACE the app volume (${app_volume})."

  docker compose "${COMPOSE_ARGS[@]}" down

  echo "==> Recreating app volume"
  docker volume rm "${app_volume}" || true
  docker volume create "${app_volume}"

  echo "==> Extracting app-volume.tar.gz"
  docker run --rm \
    -v "${app_volume}:/data" \
    -v "${BACKUP_DIR}:/backup:ro" \
    alpine tar xzf /backup/app-volume.tar.gz -C /data

  echo "==> Restarting stack"
  docker compose "${COMPOSE_ARGS[@]}" up -d
}

# --- backups volume: recreate and extract tarball ---------------------------

restore_backups_volume() {
  resolve_project_name
  local backups_volume
  backups_volume="$(get_volume_name backups)"

  confirm "This will STOP the backups container and REPLACE the backups volume (${backups_volume})."

  echo "==> Stopping backups container"
  docker compose "${COMPOSE_ARGS[@]}" stop backups

  echo "==> Recreating backups volume"
  docker volume rm "${backups_volume}" || true
  docker volume create "${backups_volume}"

  echo "==> Extracting backups-volume.tar.gz"
  docker run --rm \
    -v "${backups_volume}:/data" \
    -v "${BACKUP_DIR}:/backup:ro" \
    alpine tar xzf /backup/backups-volume.tar.gz -C /data

  echo "==> Restarting backups container"
  docker compose "${COMPOSE_ARGS[@]}" start backups
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
