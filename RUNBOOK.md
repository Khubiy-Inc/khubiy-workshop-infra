# KhubiyInc Workshop — Production Runbook

Документ для оперативной работы с prod-инфраструктурой. Что делать при
типовых ситуациях: деплой, откат, бэкап, восстановление, мониторинг.

VPS: `root@45.144.177.119` (ru-vps; куплен)
Домены: `khubiyinc.ru`, `app.khubiyinc.ru` (web+api через Caddy),
`minio.khubiyinc.ru` (S3 console).
Демо-логин: tenant `demo-ex` / `owner@khubiyinc.ru` / `CLnl7AjJyS2hLNXP`

---

## Архитектура (одно предложение)

VPS + docker-compose: Caddy (TLS + reverse-proxy) → web (nginx SPA) +
api (FastAPI/uv) + postgres-16 + redis-7 + minio. CI: push в main →
GitHub Actions → GHCR → SSH в VPS → docker compose pull + migrations +
restart. Stack описан в `docker-compose.prod.yml`.

---

## Где живут данные

- **Postgres**: docker volume `khubiy-workshop-postgres-data`
- **MinIO** (S3 файлы — фото товаров, etc.): docker volume `khubiy-workshop-minio-data`
- **Caddy data** (Let's Encrypt cert'ы): docker volume `caddy-data`
- **Бэкапы**: `/opt/khubiy-workshop/backups/` (см. ниже)
- **Логи Caddy/API**: `docker compose logs <service>` (нет persistent volume — для аудита используется `audit_events` таблица в БД)

---

## Деплой (автоматический)

`git push origin main` в репо `khubiy-workshop-api` или `khubiy-workshop-web`
→ GitHub Actions:
1. Build & push образ в `ghcr.io/khubiy-inc/khubiy-workshop-{api,web}:latest`
2. SSH в VPS → `git pull` (для compose-файла) → `docker compose pull` → миграции (только api) → `docker compose up -d --force-recreate --no-deps <service>` → smoke test

CI зелёный → деплой завершён. Pipeline зелёный end-to-end проверен.

---

## Откат на предыдущий образ

GitHub Actions при push'е создаёт несколько тегов:
- `latest`
- `main`
- `sha-XXXXXXX` (короткий SHA коммита)
- `v1.2.3` (если push tag'а)

Чтобы откатиться — pull старый SHA-tag и принудительно recreate:

```bash
ssh root@45.144.177.119
cd /opt/khubiy-workshop

# Найти предыдущий стабильный SHA-tag
docker images | grep khubiy-workshop-api | head -5

# Указать тег в docker-compose.prod.yml ИЛИ через override
# Простейший способ — pull нужного tag'а и tag его как latest локально:
docker pull ghcr.io/khubiy-inc/khubiy-workshop-api:sha-<old-sha>
docker tag ghcr.io/khubiy-inc/khubiy-workshop-api:sha-<old-sha> \
    ghcr.io/khubiy-inc/khubiy-workshop-api:latest

# Recreate
docker compose -f docker-compose.prod.yml up -d --force-recreate --no-deps api

# Проверка
docker compose -f docker-compose.prod.yml ps
curl -sI https://app.khubiyinc.ru/api/v1/auth/me  # expect 401 / 405
```

**ВНИМАНИЕ** — если за это время прошли миграции, откат образа НЕ откатывает
схему БД. Для отката схемы:

```bash
docker compose -f docker-compose.prod.yml exec api alembic downgrade -1
```

Лучше избегать downgrade в проде — пилотные клиенты могут потерять данные.
Вместо этого — forward-fix новой миграцией.

---

## Бэкапы Postgres

### Создать ad-hoc дамп (вручную)

```bash
ssh root@45.144.177.119
cd /opt/khubiy-workshop
./scripts/backup-postgres.sh
ls -la backups/
```

### Настроить ежедневный cron

```bash
sudo crontab -e
# Добавить:
30 3 * * * /opt/khubiy-workshop/scripts/backup-postgres.sh >> /var/log/khubiy-backup.log 2>&1
```

Каждый день в 03:30 UTC создаётся `backups/khubiy-workshop-YYYYMMDD-HHMMSS.sql.gz`.
Старше 14 дней — автоматически удаляются.

### Offsite копия (опц.)

Скрипт `backup-postgres.sh` подхватывает env vars из `/opt/khubiy-workshop/.env_backup`:

```bash
# /opt/khubiy-workshop/.env_backup
KW_BACKUP_RCLONE_REMOTE=selectel-s3
KW_BACKUP_RCLONE_PATH=khubiy-prod-backups
```

Настройка rclone (один раз):

```bash
apt install rclone
rclone config  # interactive, добавить remote 'selectel-s3' (S3 API)
# Тестируем:
rclone copy backups/khubiy-workshop-XXXXXX.sql.gz selectel-s3:khubiy-prod-backups/
```

Рекомендуемые S3-провайдеры (RU-юрисдикция): Selectel Cloud Storage, Yandex
Cloud Object Storage, VK Cloud. Альтернатива: Backblaze B2 — самый дешёвый.

Если offsite upload падает — скрипт **не падает**, просто пишет WARN в лог.
Локальная копия в `/opt/khubiy-workshop/backups/` всегда создаётся первой.

### Проверка восстановимости

`scripts/verify-backup.sh` берёт последний дамп, восстанавливает в throwaway-БД
`khubiy_verify_<ts>`, проверяет counts, удаляет. Рекомендуется в cron раз в неделю:

```bash
# crontab -e (root)
0 4 * * 0 /opt/khubiy-workshop/scripts/verify-backup.sh >> /var/log/khubiy-backup-verify.log 2>&1
```

Ручной запуск:

```bash
ssh root@45.144.177.119 'cd /opt/khubiy-workshop && ./scripts/verify-backup.sh'
```

Exit code 0 — backup восстановим. Не-нулевой — что-то сломано, проверь логи.

### Восстановление из дампа (полное)

```bash
ssh root@45.144.177.119
cd /opt/khubiy-workshop

# 1. Остановить api чтобы не было активных запросов в БД
docker compose -f docker-compose.prod.yml stop api

# 2. Сначала восстанавливаем в новую БД (отдельная — чтобы можно было
#    откатиться если что-то пойдёт не так).
docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U postgres -c "CREATE DATABASE khubiy_workshop_new;"
zcat backups/khubiy-workshop-YYYYMMDD-HHMMSS.sql.gz | \
    docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U postgres -d khubiy_workshop_new --quiet

# 3. Sanity check
docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U postgres -d khubiy_workshop_new \
    -c "SELECT COUNT(*) FROM platform.tenants;"

# 4. Переименовываем: старая БД → backup, новая → prod
docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U postgres -c "ALTER DATABASE khubiy_workshop RENAME TO khubiy_workshop_pre_restore;"
docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U postgres -c "ALTER DATABASE khubiy_workshop_new RENAME TO khubiy_workshop;"

# 5. Поднимаем api
docker compose -f docker-compose.prod.yml up -d --no-deps api

# 6. Через несколько дней (если всё ок) — дропаем pre_restore
docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U postgres -c "DROP DATABASE khubiy_workshop_pre_restore;"
```

---

## Мониторинг

### Healthcheck

API имеет `GET /health` (без auth, не пропущен через Caddy наружу).
Извне используется `GET /api/v1/auth/me` — возвращает 401 без JWT (= живой
сервис) или 200 с JWT.

### UptimeRobot (рекомендуется)

1. Бесплатный аккаунт на https://uptimerobot.com (RU/EN, без VPN)
2. Создать монитор:
   - Тип: HTTP(s)
   - URL: `https://app.khubiyinc.ru/api/v1/auth/me`
   - Interval: 5 минут
   - "Expected status code": `401`
3. Алерт-канал: email `mrbroman.schanel@gmail.com` (или Telegram bot)

### Sentry (когда поднимем)

В `.env.prod` оставлен `KW_SENTRY_DSN=` пустым. Когда заведём аккаунт:
1. https://sentry.io → создать project `khubiy-workshop-api`
2. Скопировать DSN, прописать в `.env`:
   ```
   KW_SENTRY_DSN=https://....ingest.sentry.io/...
   KW_SENTRY_TRACES_SAMPLE_RATE=0.05
   ```
3. `docker compose up -d --force-recreate api`

---

## Распространённые проблемы

### Контейнер не пересоздаётся после `pull`

Если CI прошёл, но api показывает старое поведение — `docker compose ps`
покажет `Up X hours` вместо «только что recreate». Принудительно:

```bash
docker compose -f docker-compose.prod.yml up -d --force-recreate --no-deps api
```

(В CI workflow это уже включено через `--force-recreate`. Грабли — если
ручной деплой без флага.)

### 403 на mutation endpoints

Если owner делает что-то и получает 403 — JWT, возможно, без `roles: ["owner"]`.
Проверить:

```bash
JWT=$(curl -sX POST https://app.khubiyinc.ru/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"tenant_slug":"...","email":"...","password":"..."}' | jq -r .access_token)
echo "$JWT" | cut -d. -f2 | base64 -d 2>/dev/null | jq .roles
```

Если `[]` — выдать роль в БД (или через `/settings/roles` если уже есть owner):

```bash
docker compose exec postgres psql -U khubiy_admin -d khubiy_workshop -c \
  "INSERT INTO auth.user_roles (id, tenant_id, user_id, role, granted_by)
   SELECT gen_random_uuid(), 'TENANT_ID', 'USER_ID', 'owner', 'USER_ID'
   WHERE NOT EXISTS (
     SELECT 1 FROM auth.user_roles
     WHERE tenant_id='TENANT_ID' AND user_id='USER_ID' AND role='owner'
   );"
```

Затем user должен logout/login (JWT обновится).

### Caddy не выпускает Let's Encrypt сертификат

Если HTTPS не работает:
```bash
docker compose -f docker-compose.prod.yml logs caddy --tail 100
```

Частые причины:
- DNS A-record указывает не на VPS → проверить `dig khubiyinc.ru +short`
- Порт 80 закрыт фаерволом → `ufw status` (должен быть allow 80/tcp, 443/tcp)
- Rate-limit Let's Encrypt (5 cert'ов в неделю на домен) → ждать

### Миграция упала, api в crash-loop

```bash
docker compose -f docker-compose.prod.yml logs api --tail 50
# Если "Target database is not up to date" — миграция не прошла
docker compose -f docker-compose.prod.yml run --rm api-migrate
# Если миграция конфликтует:
docker compose -f docker-compose.prod.yml exec postgres psql -U khubiy_admin -d khubiy_workshop -c "SELECT * FROM alembic_version;"
# Иногда нужно downgrade + rerun:
docker compose -f docker-compose.prod.yml exec api alembic downgrade -1
docker compose -f docker-compose.prod.yml run --rm api-migrate
```

---

## Контакты эскалации

- **Разработка / архитектура**: владелец проекта (этот разработчик)
- **VPS-провайдер**: support@<provider> (тикет через личный кабинет)
- **DNS Selectel**: support@selectel.ru
- **Let's Encrypt / Caddy**: community.caddyserver.com

---

## Чек-лист подготовки нового владельца тенанта

1. `docker compose exec api python scripts/bootstrap_demo.py --slug NEW_SLUG --owner-email X --owner-password Y --reset`
2. Отправить логин-данные новому владельцу
3. Помочь ему создать первых работников (`/employees` → «Создать» → выпустить QR)
4. Помочь настроить tech-карты + бригады → задачи в auto-assign

Или (когда заведём email-провайдер): `POST /api/v1/platform/tenants/{id}/invite-owner`
→ owner получит письмо с accept-invite ссылкой → сам ставит пароль.
