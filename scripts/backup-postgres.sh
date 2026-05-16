#!/bin/bash
# backup-postgres.sh — pg_dump cron job для prod базы khubiy_workshop.
#
# Запускается на VPS из cron'а khubiy-пользователя (или root).
# Дамп пишется в /opt/khubiy-workshop/backups/, хранится 14 дней.
#
# Установка в cron (текущее значение на проде, см. RUNBOOK):
#   sudo crontab -e
#   # Каждый день в 03:30 UTC (≈06:30 МСК) — низкая нагрузка
#   30 3 * * * /opt/khubiy-workshop/scripts/backup-postgres.sh >> /var/log/khubiy-backup.log 2>&1
#
# Offsite (опц.) — через rclone. Настройка:
#   rclone config  # → создать remote, например `selectel-s3`, для bucket
#   # Затем в /opt/khubiy-workshop/.env_backup:
#   KW_BACKUP_RCLONE_REMOTE=selectel-s3
#   KW_BACKUP_RCLONE_PATH=khubiy-prod-backups
#   # Скрипт автоматически подхватит env vars и зальёт дамп.
#
# Восстановление (см. RUNBOOK.md раздел «Recovery»):
#   docker compose -f docker-compose.prod.yml exec -T postgres \
#       psql -U postgres -c 'CREATE DATABASE khubiy_workshop_restore;'
#   zcat /opt/khubiy-workshop/backups/khubiy-workshop-YYYYMMDD-HHMMSS.sql.gz | \
#       docker compose -f docker-compose.prod.yml exec -T postgres \
#       psql -U postgres -d khubiy_workshop_restore --quiet
#   # Проверить counts, потом drop prod DB и rename restore → khubiy_workshop.

set -euo pipefail

BACKUP_DIR="/opt/khubiy-workshop/backups"
RETENTION_DAYS=14
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
DUMP_FILE="${BACKUP_DIR}/khubiy-workshop-${TIMESTAMP}.sql.gz"
STATUS_FILE="${BACKUP_DIR}/.last_status"

# Загрузка опц. env'ов для offsite. Файл может отсутствовать — это норма.
if [ -f /opt/khubiy-workshop/.env_backup ]; then
    set -a
    # shellcheck disable=SC1091
    source /opt/khubiy-workshop/.env_backup
    set +a
fi

mkdir -p "$BACKUP_DIR"
cd /opt/khubiy-workshop

log() {
    echo "[$(date -u --iso-8601=seconds)] $*"
}

fail() {
    log "ERROR: $*"
    echo "FAILED at $(date -u --iso-8601=seconds): $*" > "$STATUS_FILE"
    exit 1
}

log "Starting backup → ${DUMP_FILE}"

# pg_dump через docker compose exec — pg_dump живёт внутри postgres-контейнера.
# --no-owner / --no-privileges чтобы restore работал в любую БД без перенакрутки ролей.
# Plain text + gzip — компактно и читаемо. PostgreSQL --create нам не нужен:
# мы восстанавливаем в существующую (новую) БД через psql -d <name>.
docker compose -f docker-compose.prod.yml exec -T postgres \
    pg_dump -U postgres \
        --no-owner --no-privileges \
        --format=plain \
        khubiy_workshop \
    | gzip -9 > "$DUMP_FILE" || fail "pg_dump pipeline returned non-zero"

if [ ! -s "$DUMP_FILE" ]; then
    fail "Dump file is empty: ${DUMP_FILE}"
fi

SIZE_MB=$(du -m "$DUMP_FILE" | cut -f1)
log "Dump written: ${SIZE_MB}MB"

# Sanity check — заголовок должен начинаться с PostgreSQL header после gunzip.
HEADER_OK=$(zcat "$DUMP_FILE" | head -3 | grep -c "PostgreSQL database dump" || true)
if [ "${HEADER_OK}" -lt 1 ]; then
    fail "Dump header missing 'PostgreSQL database dump' — файл повреждён"
fi

# Удалить старые бэкапы.
log "Pruning backups older than ${RETENTION_DAYS} days"
find "$BACKUP_DIR" -name 'khubiy-workshop-*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete -print \
    | sed 's|^|  pruned: |'

# === Offsite копия через rclone (опц.) ===
if [ -n "${KW_BACKUP_RCLONE_REMOTE:-}" ] && [ -n "${KW_BACKUP_RCLONE_PATH:-}" ]; then
    if command -v rclone >/dev/null; then
        log "Uploading to offsite ${KW_BACKUP_RCLONE_REMOTE}:${KW_BACKUP_RCLONE_PATH}/"
        if rclone copy "$DUMP_FILE" \
            "${KW_BACKUP_RCLONE_REMOTE}:${KW_BACKUP_RCLONE_PATH}/" \
            --transfers 2 --checkers 4 --quiet; then
            log "Offsite upload OK"
        else
            # Не падаем — local backup уже есть. Лог + status, owner увидит.
            log "WARN: offsite upload failed (rclone exit non-zero). Local copy still exists."
        fi
    else
        log "WARN: rclone not installed but KW_BACKUP_RCLONE_REMOTE set; install rclone"
    fi
fi

# Финальный статус — для health check / monitoring.
echo "OK at $(date -u --iso-8601=seconds) size=${SIZE_MB}MB file=${DUMP_FILE}" > "$STATUS_FILE"

# Heartbeat в БД — admin UI читает через GET /api/v1/internal/system-health,
# показывает «Бэкап: 2 часа назад ✓» / WARN / DEAD. Если БД недоступна,
# log + продолжаем (само-блокирующее поведение нежелательно для backup).
log "Writing heartbeat to platform.system_heartbeats"
HEARTBEAT_PAYLOAD=$(printf '{"size_mb":%s,"file":"%s"}' "$SIZE_MB" "$(basename "$DUMP_FILE")")
if docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U postgres -d khubiy_workshop -v ON_ERROR_STOP=1 -q -c "
        INSERT INTO platform.system_heartbeats (key, last_at, payload)
        VALUES ('backup', NOW(), '${HEARTBEAT_PAYLOAD}'::jsonb)
        ON CONFLICT (key) DO UPDATE
        SET last_at = EXCLUDED.last_at, payload = EXCLUDED.payload;
    " >/dev/null 2>&1; then
    log "Heartbeat written"
else
    log "WARN: heartbeat write failed (БД недоступна или таблица не создана). Local dump всё равно ок."
fi

log "Backup complete"
