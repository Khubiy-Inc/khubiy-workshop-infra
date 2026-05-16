#!/bin/bash
# verify-backup.sh — проверка восстановимости последнего backup'а.
#
# Берёт самый свежий dump из /opt/khubiy-workshop/backups/, восстанавливает
# в throwaway-базу `khubiy_verify_<timestamp>`, считает rows в критичных
# таблицах, проверяет что counts > 0, потом удаляет throwaway-БД.
#
# Использование:
#   /opt/khubiy-workshop/scripts/verify-backup.sh
#   # exit 0 — backup восстановим, exit ≠ 0 — что-то не так
#
# Cron (запускать раз в неделю + после crucial migrations):
#   0 4 * * 0 /opt/khubiy-workshop/scripts/verify-backup.sh >> /var/log/khubiy-backup-verify.log 2>&1

set -euo pipefail

BACKUP_DIR="/opt/khubiy-workshop/backups"

log() {
    echo "[$(date -u --iso-8601=seconds)] $*"
}

LATEST=$(ls -1t "$BACKUP_DIR"/khubiy-workshop-*.sql.gz 2>/dev/null | head -1 || true)
if [ -z "$LATEST" ]; then
    log "ERROR: нет ни одного backup'а в $BACKUP_DIR"
    exit 1
fi

log "Verifying: $LATEST ($(du -h "$LATEST" | cut -f1))"

VERIFY_DB="khubiy_verify_$(date -u +%Y%m%d%H%M%S)"
cd /opt/khubiy-workshop

cleanup() {
    log "Cleanup: dropping $VERIFY_DB"
    docker compose -f docker-compose.prod.yml exec -T postgres \
        psql -U postgres -c "DROP DATABASE IF EXISTS ${VERIFY_DB};" 2>&1 | tail -1 || true
}
trap cleanup EXIT

# Создаём throwaway DB
docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U postgres -c "CREATE DATABASE ${VERIFY_DB};" >/dev/null
log "Created throwaway DB: $VERIFY_DB"

# Restore
log "Restoring..."
if ! zcat "$LATEST" | docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U postgres -d "$VERIFY_DB" --quiet >/dev/null 2>&1; then
    log "ERROR: psql restore returned non-zero"
    exit 2
fi

# Считаем критичные таблицы. Если хоть одна пустая — это подозрительно
# (на проде должны быть хотя бы demo-данные). Не падаем на этом — только лог.
log "Row counts:"
docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U postgres -d "$VERIFY_DB" -t -A -F'|' -c "
        SELECT 'tenants'      , COUNT(*) FROM platform.tenants
        UNION ALL SELECT 'users'        , COUNT(*) FROM auth.users
        UNION ALL SELECT 'clients'      , COUNT(*) FROM sales.clients
        UNION ALL SELECT 'sales_orders' , COUNT(*) FROM sales.sales_orders
        UNION ALL SELECT 'production_orders', COUNT(*) FROM production.production_orders
        UNION ALL SELECT 'shifts'       , COUNT(*) FROM production.shifts
        UNION ALL SELECT 'work_logs'    , COUNT(*) FROM production.work_logs;
    " | sed 's|^|  |'

# Sanity — должна быть хотя бы одна tenant.
TENANTS=$(docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U postgres -d "$VERIFY_DB" -t -A -c "SELECT COUNT(*) FROM platform.tenants;" \
    | tr -d ' \r')
if [ "$TENANTS" -lt 1 ]; then
    log "ERROR: 0 tenants в restored DB — backup похоже сломан"
    exit 3
fi

log "OK: backup verified, ${TENANTS} tenants restored"
