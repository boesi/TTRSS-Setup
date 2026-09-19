#!/usr/bin/env bash
#
# Full backup of the ttrss-docker stack: current images, config files,
# a live database dump, and the app/backups volumes.
#
# Run this from the directory that contains docker-compose.yml and .env.

set -euo pipefail

VERSION="0.9"

usage() {
  cat <<EOF
ttrss-backup.sh ${VERSION}

Full backup of the ttrss-docker stack: current images, config files,
a live database dump, and the app/backups volumes.

Usage:
  $0 [options] [backup-dir]

Arguments:
  [backup-dir]  Backup root directory. Backups are written to
                <backup-dir>/<timestamp>/, with image tarballs kept once
                under <backup-dir>/images/.
                Defaults to ./ttrss-backups (relative paths are resolved
                against the current directory).

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
EOF
}

LOG_LEVEL="error"
POSITIONAL=()

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

if [ $# -gt 1 ]; then
  echo "Error: too many positional arguments (expected at most one: backup root dir)." >&2
  usage
  exit 1
fi

log_info() {
  [ "${LOG_LEVEL}" = "quiet" ] && return 0
  echo "$@"
}

# --- Configuration ---------------------------------------------------------

PROJECT_DIR="$(pwd)"
BACKUP_ROOT="${1:-${PROJECT_DIR}/ttrss-backups}"
# Resolve relative paths against the current directory now: Docker's -v bind
# mounts require absolute host paths and don't resolve relative paths.
# -m (--canonicalize-missing) keeps paths that don't exist yet valid, since
# mkdir happens later.
if [[ "${BACKUP_ROOT}" != /* ]]; then
  BACKUP_ROOT="$(realpath -m "${BACKUP_ROOT}")"
fi
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
OVERRIDE_FILE="${PROJECT_DIR}/docker-compose.override.yml"
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

# --- Image helpers ------------------------------------------------------
#
# The images are not hardcoded: they're read from the live compose
# configuration, so this script works with the current (supahgreg) and any
# previous (cthulhoo) setup unchanged.

# Image ref used by a compose service (e.g. "supahgreg/tt-rss:latest").
compose_image() {
  local service="$1"
  docker compose "${COMPOSE_ARGS[@]}" config \
    | awk -v svc="${service}" '
        /^  [a-zA-Z0-9_-]+:$/ { cur=$1; sub(/:$/, "", cur) }
        cur==svc && /^    image:/ { print $2; exit }
      '
}

# Filesystem-safe tarball basename for an image ref:
#   <repo>_<version>  if a real version tag exists (anything but "latest")
#   <repo>_<date>     else, using the image's publish date as fallback
image_tar_basename() {
  local ref="$1"
  local repo="${ref}"
  local first tag version tags t_pick t_repo t_tag pick=""

  # Strip a leading registry prefix (docker.io, ghcr.io, ...) so only the
  # repo path participates in the name.
  first="${repo%%/*}"
  if [ "${first}" != "${repo}" ] && { [ "${first}" = "localhost" ] || [[ "${first}" == *.* || "${first}" == *:* ]]; }; then
    repo="${repo#*/}"
  fi

  # Split off the tag; a ref without a ":tag" implies "latest".
  tag="${repo##*:}"
  if [ "${tag}" = "${repo}" ]; then
    tag=""
  else
    repo="${repo%:*}"
  fi

  version=""
  if [ -n "${tag}" ] && [ "${tag}" != "latest" ]; then
    version="${tag}"
  else
    # Look for a real version tag on the same locally pulled image.
    tags="$(docker image inspect "${ref}" --format '{{.RepoTags}}' 2>/dev/null || true)"
    tags="$(printf '%s' "${tags}" | tr -d '[]' | tr ' ' '\n')"
    while IFS= read -r t_pick; do
      [ -z "${t_pick}" ] && continue
      t_repo="${t_pick%%:*}"
      [ "${t_repo}" != "${repo}" ] && continue
      t_tag="${t_pick##*:}"
      [ "${t_tag}" = "latest" ] && continue
      pick="${pick}${t_tag}"$'\n'
    done <<< "${tags}"
    version="$(printf '%s\n' "${pick}" | sed '/^$/d' | sort -V | tail -n1 || true)"
  fi

  if [ -z "${version}" ]; then
    # Fallback: publish date of the image (YYYY-MM-DD).
    version="$(docker image inspect "${ref}" --format '{{.Created}}' 2>/dev/null | cut -c1-10 || true)"
  fi
  if [ -z "${version}" ]; then
    echo "Error: could not determine a name for image '${ref}'." >&2
    exit 1
  fi

  echo "${repo//\//_}_${version}"
}

# --- Setup -------------------------------------------------------------

if [ $# -eq 0 ]; then
  echo "Warning: using default backup root '${BACKUP_ROOT}'." >&2
  echo "         Backups stored inside the project directory can be lost when" >&2
  echo "         the directory is recreated or removed during a migration." >&2
  echo "         Consider passing an external directory, e.g.:" >&2
  echo "           $0 /mnt/backups/ttrss" >&2
fi

mkdir -p "${BACKUP_DIR}"
mkdir -p "${IMAGE_BACKUP_DIR}"
log_info "==> Backing up into ${BACKUP_DIR}"

# --- 1. Save the current images (once) -------------------------------------
#
# All three service images (app, web-nginx, db) are saved so a restore can
# run fully offline. updater/backups reuse the app image. Existing tarballs
# of the same image are skipped; old tarballs are not removed here.

log_info "==> Resolving current images from the compose configuration"
APP_IMAGE="$(compose_image app)"
WEB_IMAGE="$(compose_image web-nginx)"
DB_IMAGE="$(compose_image db)"
if [ -z "${APP_IMAGE}" ] || [ -z "${WEB_IMAGE}" ] || [ -z "${DB_IMAGE}" ]; then
  echo "Error: could not resolve the app/web-nginx/db image from the compose configuration." >&2
  exit 1
fi

for img in "${APP_IMAGE}" "${WEB_IMAGE}" "${DB_IMAGE}"; do
  base="$(image_tar_basename "${img}")"
  tar="${IMAGE_BACKUP_DIR}/${base}.tar"
  if [ ! -f "${tar}" ]; then
    log_info "==> Saving ${img} as ${base}.tar"
    docker save "${img}" -o "${tar}"
  else
    log_info "==> Image tar ${base}.tar already exists, skipping"
  fi
done

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
log_info "==> Images stored in ${IMAGE_BACKUP_DIR} (kept across runs)"
