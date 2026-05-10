#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/.env" ]] && { set -a; source "${SCRIPT_DIR}/.env"; set +a; }

BACKUP_DIR="${SCRIPT_DIR}/backups"
KEEP_DAYS="${KEEP_DAYS:-14}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
PG_USER="${POSTGRES_USER:-odoo}"

mkdir -p "${BACKUP_DIR}"
echo "[$(date)] Starting backup run..."

DATABASES=$(docker compose -f "${SCRIPT_DIR}/docker-compose.yml" exec -T postgres \
    psql -U "${PG_USER}" -At -c \
    "SELECT datname FROM pg_database WHERE datistemplate=false AND datname NOT IN ('postgres','template0','template1');" \
    2>/dev/null || true)

[[ -z "$DATABASES" ]] && { echo "[$(date)] No tenant databases found."; exit 0; }

for DB in $DATABASES; do
    echo "[$(date)] Backing up: ${DB}"
    DEST="${BACKUP_DIR}/${DB}_${TIMESTAMP}"
    mkdir -p "${DEST}"

    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" exec -T postgres \
        pg_dump -U "${PG_USER}" --format=custom "${DB}" > "${DEST}/dump.pgdump"

    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" exec -T odoo \
        tar -czf - -C /var/lib/odoo/filestore "${DB}" 2>/dev/null \
        > "${DEST}/filestore.tar.gz" || echo "   No filestore for ${DB}, skipping"

    tar -czf "${BACKUP_DIR}/${DB}_${TIMESTAMP}.tar.gz" -C "${BACKUP_DIR}" "${DB}_${TIMESTAMP}"
    rm -rf "${DEST}"
    echo "   Saved: ${BACKUP_DIR}/${DB}_${TIMESTAMP}.tar.gz"
done

find "${BACKUP_DIR}" -name "*.tar.gz" -mtime "+${KEEP_DAYS}" -delete
echo "[$(date)] Backup complete. Kept last ${KEEP_DAYS} days."
