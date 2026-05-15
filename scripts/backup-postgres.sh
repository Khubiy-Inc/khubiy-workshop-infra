#!/bin/bash
# backup-postgres.sh — pg_dump cron job для prod базы khubiy_workshop.
#
# Запускается на VPS из cron'а khubiy-пользователя (или root).
# Дамп пишется в /opt/khubiy-workshop/backups/, хранится 14 дней.
#
# Установка в cron:
#   sudo crontab -e
#   # Каждый день в 03:30 UTC (≈06:30 МСК)
#   30 3 * * * /opt/khubiy-workshop/scripts/backup-postgres.sh >> /var/log/khubiy-backup.log 2>&1
#
# Для offsite — раскомментируй секцию RCLONE (предварительно настрой
# rclone remote `khubiy-backup` на S3 / B2 / Selectel).
#
# Восстановление:
#   gunzip < backup-YYYYMMDD-HHMMSS.sql.gz | \
#     docker compose -f docker-compose.prod.yml exec -T postgres \
#     psql -U khubiy_admin -d khubiy_workshop

set -euo pipefail

BACKUP_DIR="/opt/khubiy-workshop/backups"
RETENTION_DAYS=14
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
DUMP_FILE="${BACKUP_DIR}/khubiy-workshop-${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

cd /opt/khubiy-workshop

echo "[$(date -u --iso-8601=seconds)] Starting backup → ${DUMP_FILE}"

# pg_dump через docker compose exec — pg_dump живёт внутри postgres-контейнера.
# --no-owner / --no-privileges чтобы restore работал в любую БД без перенакручивания ролей.
# --create — INSERT DROP+CREATE DATABASE statements в начале (опц., полезно при full-restore).
docker compose -f docker-compose.prod.yml exec -T postgres \
    pg_dump -U postgres \
        --no-owner --no-privileges \
        --format=plain \
        khubiy_workshop \
    | gzip -9 > "$DUMP_FILE"

SIZE_MB=$(du -m "$DUMP_FILE" | cut -f1)
echo "[$(date -u --iso-8601=seconds)] Dump written: ${SIZE_MB}MB"

# Удалить старые бэкапы (хранение 14 дней)
find "$BACKUP_DIR" -name 'khubiy-workshop-*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete -print \
    | sed 's|^|  pruned: |'

# === Опц.: offsite копия через rclone (раскомментируй когда настроишь remote) ===
# if command -v rclone >/dev/null; then
#     echo "[$(date -u --iso-8601=seconds)] Uploading to offsite remote..."
#     rclone copy "$DUMP_FILE" khubiy-backup:khubiy-workshop-backups/ \
#         --include "khubiy-workshop-${TIMESTAMP}.sql.gz" \
#         --transfers 2 --checkers 4
#     echo "[$(date -u --iso-8601=seconds)] Offsite OK"
# fi

echo "[$(date -u --iso-8601=seconds)] Backup complete"
