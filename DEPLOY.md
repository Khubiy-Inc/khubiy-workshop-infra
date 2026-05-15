# Deploy на VPS — quickstart

Этот документ — пошаговый сценарий первого деплоя KhubiyInc Workshop на свежий VPS Ubuntu 22.04+.

VPS: `root@45.144.177.119` · Домен: `khubiyinc.ru` · DNS: Selectel · Registry: GHCR.

После завершения — каждый push в `main` в репо `khubiy-workshop-api` или `khubiy-workshop-web` автоматически выкатит новый билд в прод (build → push GHCR → SSH в VPS → `docker compose pull` + restart + smoke).

---

## 1. DNS-записи (Selectel)

В Selectel DNS panel для зоны `khubiyinc.ru` создать A-записи:

| Имя | Тип | Значение | TTL |
|---|---|---|---|
| `@` (apex `khubiyinc.ru`) | A | `45.144.177.119` | 300 |
| `app` | A | `45.144.177.119` | 300 |
| `traefik` | A | `45.144.177.119` | 300 |
| `minio` | A | `45.144.177.119` | 300 (опц.) |
| `www` | A | `45.144.177.119` | 300 (опц.) |

Подождать 5-30 мин распространения. Проверить:
```bash
dig +short app.khubiyinc.ru
# должно вернуть 45.144.177.119
```

---

## 2. Сгенерировать SSH-ключ для CI

На локальной машине:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/khubiy_deploy -C "github-actions@khubiyinc" -N ""
```

Получится два файла:
- `~/.ssh/khubiy_deploy` (private — пойдёт в GitHub Secrets)
- `~/.ssh/khubiy_deploy.pub` (public — добавится на VPS)

Скопировать public key на VPS:
```bash
ssh-copy-id -i ~/.ssh/khubiy_deploy.pub root@45.144.177.119
# или вручную: cat khubiy_deploy.pub | ssh root@45.144.177.119 'cat >> ~/.ssh/authorized_keys'
```

Проверить, что login проходит:
```bash
ssh -i ~/.ssh/khubiy_deploy root@45.144.177.119 echo OK
```

---

## 3. One-time setup VPS

Скопировать и запустить setup-скрипт:
```bash
scp -i ~/.ssh/khubiy_deploy scripts/setup-vps.sh root@45.144.177.119:/tmp/
ssh -i ~/.ssh/khubiy_deploy root@45.144.177.119 bash /tmp/setup-vps.sh
```

Скрипт идемпотентен — можно запускать повторно. Делает:
1. Обновление системы + установку docker + ufw
2. Создаёт user `khubiy` (для будущей миграции с root)
3. Клонирует `khubiy-workshop-infra` в `/opt/khubiy-workshop`
4. Генерирует JWT RSA-keypair в `secrets/`
5. Открывает 22/80/443 в firewall
6. Создаёт `.env` из шаблона (пустые секреты — заполняем дальше)
7. Создаёт `traefik/users` с дефолтным admin/admin (поменять!)

---

## 4. Заполнить секреты в `.env` на VPS

```bash
ssh -i ~/.ssh/khubiy_deploy root@45.144.177.119
nano /opt/khubiy-workshop/.env
```

Минимум что нужно задать:
- `KW_DB_SUPER_PASSWORD`, `KW_DB_ADMIN_PASSWORD`, `KW_DB_APP_PASSWORD` — три сильных пароля (`openssl rand -base64 32`)
- `KW_S3_ACCESS_KEY` (`openssl rand -hex 16`) и `KW_S3_SECRET_KEY` (`openssl rand -hex 32`)
- `TRAEFIK_ACME_EMAIL` (для Let's Encrypt) — например `admin@khubiyinc.ru`
- `KW_WEBPUSH_VAPID_PUBLIC_KEY` + `KW_WEBPUSH_VAPID_PRIVATE_KEY` — сгенерировать локально:
  ```bash
  npx web-push generate-vapid-keys
  ```
- `KW_WEBPUSH_VAPID_EMAIL` — `mailto:admin@khubiyinc.ru`

Опционально:
- `KW_SMTP_*` — настроить когда подключим email-провайдер
- `KW_SENTRY_DSN` — если есть Sentry

Также поменять traefik dashboard password:
```bash
htpasswd -B /opt/khubiy-workshop/traefik/users admin
# введите новый пароль дважды
```

---

## 5. GHCR login на VPS

GitHub Container Registry требует Personal Access Token (PAT) с правом `read:packages`. Создать на https://github.com/settings/tokens:
- Note: `khubiy-vps-pull`
- Scopes: `read:packages`
- Сохранить токен `ghp_xxx...`

На VPS:
```bash
echo ghp_xxx... | docker login ghcr.io -u <ваш-github-username> --password-stdin
```

---

## 6. Первый запуск

```bash
ssh -i ~/.ssh/khubiy_deploy root@45.144.177.119
cd /opt/khubiy-workshop
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d
```

Дождаться:
1. Postgres healthy (10-20 с)
2. MinIO healthy + minio-init создаст bucket
3. Traefik запрашивает Let's Encrypt cert (1-3 мин на каждый домен)
4. api-migrate накатит миграции
5. api + web start

Проверка:
```bash
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs -f traefik
```

Должно открыться:
- `https://app.khubiyinc.ru` — Web SPA (login page)
- `https://app.khubiyinc.ru/api/v1/health` — JSON `{"status":"ok"}`
- `https://traefik.khubiyinc.ru` — Traefik dashboard (admin/admin → переделать!)
- `https://minio.khubiyinc.ru` — MinIO console (опционально)

---

## 7. Bootstrap demo-тенанта (одноразово)

```bash
ssh -i ~/.ssh/khubiy_deploy root@45.144.177.119
cd /opt/khubiy-workshop
docker compose -f docker-compose.prod.yml exec api \
  python scripts/bootstrap_demo.py \
    --slug demo-ex \
    --owner-email owner@example.com \
    --owner-password "$(openssl rand -base64 16)"
```

(Запомните сгенерированный пароль — он будет в выводе.)

Открыть `https://app.khubiyinc.ru/login`, ввести:
- Tenant: `demo-ex`
- Email: `owner@example.com`
- Password: тот что сгенерировали

---

## 8. GitHub Secrets для CI/CD

В обоих репо (`khubiy-workshop-api`, `khubiy-workshop-web`):

**Settings → Secrets and variables → Actions → New repository secret**

| Secret | Значение |
|---|---|
| `VPS_HOST` | `45.144.177.119` |
| `VPS_USER` | `root` (после миграции на app-user → `khubiy`) |
| `VPS_SSH_PRIVATE_KEY` | Содержимое `~/.ssh/khubiy_deploy` (private key, целиком включая `-----BEGIN` / `-----END`) |

**Settings → Environments → New environment**
- Имя: `production`
- (Опц.) Required reviewers — кто аппрувит каждый deploy

После этого:
- Любой push в `main` в `khubiy-workshop-api` → build образа → push в `ghcr.io` → SSH в VPS → `docker compose pull api` + миграции + restart → smoke test
- То же для `khubiy-workshop-web`

---

## 9. Локальная разработка после переключения на VPS

`docker-compose.dev.yml` не трогаем — продолжаем работать локально как раньше. Push в main → автодеплой на VPS — для пилота.

---

## 10. Rollback при проблемах

Откатить api на предыдущий образ:
```bash
ssh root@45.144.177.119
cd /opt/khubiy-workshop
# Посмотреть доступные теги:
docker images ghcr.io/khubiy-inc/khubiy-workshop-api
# Указать конкретный sha-тег в .env:
sed -i 's/API_IMAGE_TAG=.*/API_IMAGE_TAG=sha-abc1234/' .env
docker compose -f docker-compose.prod.yml up -d --no-deps api
```

Если миграция испортила БД — восстановить из бэкапа (см. `runbooks/` для процедуры pg_dump/restore).

---

## 11. Бэкапы (next step)

После запуска сразу настроить cron на VPS:
```bash
# /etc/cron.daily/khubiy-backup
docker compose -f /opt/khubiy-workshop/docker-compose.prod.yml exec -T postgres \
  pg_dump -U postgres khubiy_workshop | gzip > /backups/khubiy-$(date +%F).sql.gz
# rotate 14 дней:
find /backups -name 'khubiy-*.sql.gz' -mtime +14 -delete
```

Лучше — добавить отдельный backup-сервис в compose с rclone в Selectel S3.
