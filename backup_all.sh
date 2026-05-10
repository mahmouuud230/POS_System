#!/usr/bin/env bash
# =============================================================================
# backup_all.sh
#
# Creates a timestamped backup of every tenant database + its filestore.
# Designed to be run by the odoo-backup.timer systemd unit.
#
# Each backup is a .tar.gz containing:
#   <shop>_YYYYMMDD-HHMMSS/
#     └── dump.sql          (pg_dump of the tenant database)
#     └── filestore/        (copy of /var/lib/odoo/filestore/<shop>/)
#
# Retention: keeps the last KEEP_DAYS worth of backups (default: 14)
# Storage:   local at BACKUP_DIR (mount an NFS or S3 bucket here optionally)
# =============================================================================

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/odoo-saas}"
BACKUP_DIR="${BACKUP_DIR:-/opt/odoo-saas/backups}"
KEEP_DAYS="${KEEP_DAYS:-14}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
PG_USER="${POSTGRES_USER:-odoo}"
PG_PASS="${POSTGRES_PASSWORD:-}"

# Load .env if it exists
[[ -f "${COMPOSE_DIR}/.env" ]] && source "${COMPOSE_DIR}/.env"
PG_USER="${POSTGRES_USER:-odoo}"
PG_PASS="${POSTGRES_PASSWORD:-}"

mkdir -p "${BACKUP_DIR}"

echo "[$(date)] Starting Odoo backup run..."

# ── Get list of tenant databases ──────────────────────────────────────────────
# Exclude PostgreSQL system databases
DATABASES=$(docker compose -f "${COMPOSE_DIR}/docker-compose.yml" exec -T postgres \
    psql -U "${PG_USER}" -At -c \
    "SELECT datname FROM pg_database WHERE datistemplate=false AND datname NOT IN ('postgres','template0','template1');" \
    2>/dev/null)

if [[ -z "$DATABASES" ]]; then
    echo "[$(date)] No tenant databases found. Exiting."
    exit 0
fi

for DB in $DATABASES; do
    echo "[$(date)] Backing up: ${DB}"
    DEST="${BACKUP_DIR}/${DB}_${TIMESTAMP}"
    mkdir -p "${DEST}"

    # 1. Database dump
    docker compose -f "${COMPOSE_DIR}/docker-compose.yml" exec -T postgres \
        pg_dump -U "${PG_USER}" --format=custom "${DB}" \
        > "${DEST}/dump.pgdump"

    # 2. Filestore (files stored under /var/lib/odoo/filestore/<DB>/ in container)
    docker compose -f "${COMPOSE_DIR}/docker-compose.yml" exec -T odoo \
        tar -czf - -C /var/lib/odoo/filestore "${DB}" 2>/dev/null \
        > "${DEST}/filestore.tar.gz" || {
            echo "   ⚠ Filestore not found for ${DB} — skipping"
        }

    # 3. Compress everything into a single archive
    tar -czf "${BACKUP_DIR}/${DB}_${TIMESTAMP}.tar.gz" -C "${BACKUP_DIR}" "${DB}_${TIMESTAMP}"
    rm -rf "${DEST}"

    echo "   ✓ ${BACKUP_DIR}/${DB}_${TIMESTAMP}.tar.gz"
done

# ── Prune old backups ─────────────────────────────────────────────────────────
echo "[$(date)] Pruning backups older than ${KEEP_DAYS} days..."
find "${BACKUP_DIR}" -name "*.tar.gz" -mtime "+${KEEP_DAYS}" -delete
echo "[$(date)] Backup run complete."
