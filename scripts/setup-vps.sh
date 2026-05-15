#!/usr/bin/env bash
# =============================================================================
# setup-vps.sh — one-time подготовка свежего VPS (Ubuntu 22.04 / 24.04 LTS).
#
# Запускается прямо на VPS через ssh root@<IP> < setup-vps.sh
# либо:
#   scp scripts/setup-vps.sh root@<IP>:/tmp/
#   ssh root@<IP> bash /tmp/setup-vps.sh
#
# Делает:
#   1. Обновляет систему
#   2. Ставит docker + docker-compose
#   3. Ставит ufw (firewall) — открывает только 22/80/443
#   4. Создаёт app-user `khubiy` для деплоя (если нужен не-root SSH)
#   5. Клонирует khubiy-workshop-infra в /opt/khubiy-workshop
#   6. Генерирует RSA-ключи JWT
#   7. Готовит .env (просит заполнить вручную)
#
# Запуск:
#   bash setup-vps.sh
#
# Идемпотентно: можно запускать повторно — повторно не сломает.
# =============================================================================

set -euo pipefail

INFRA_REPO="https://github.com/Khubiy-Inc/khubiy-workshop-infra.git"
APP_ROOT="/opt/khubiy-workshop"
APP_USER="khubiy"

log() { printf "\033[1;34m[setup-vps]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[setup-vps]\033[0m %s\n" "$*" >&2; exit 1; }

# --- 1. Sanity ---------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  err "Запустите от root: sudo bash $0"
fi

log "Stage 1: apt update"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y \
  ca-certificates curl gnupg lsb-release \
  ufw fail2ban htop unzip jq git openssh-server

# --- 2. Docker --------------------------------------------------------------

log "Stage 2: docker"
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

# --- 3. Firewall ------------------------------------------------------------

log "Stage 3: ufw firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP (Traefik)'
ufw allow 443/tcp comment 'HTTPS (Traefik)'
ufw --force enable

# --- 4. App user ------------------------------------------------------------

log "Stage 4: app user '$APP_USER'"
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G docker "$APP_USER"
  log "Created user $APP_USER (member of docker group)"
fi

# Копируем root authorized_keys в app-user (чтобы можно было заходить тем же ключом)
if [[ -f /root/.ssh/authorized_keys ]]; then
  mkdir -p /home/$APP_USER/.ssh
  cp /root/.ssh/authorized_keys /home/$APP_USER/.ssh/authorized_keys
  chown -R $APP_USER:$APP_USER /home/$APP_USER/.ssh
  chmod 700 /home/$APP_USER/.ssh
  chmod 600 /home/$APP_USER/.ssh/authorized_keys
fi

# --- 5. Clone infra --------------------------------------------------------

log "Stage 5: clone infra repo"
mkdir -p "$APP_ROOT"
chown $APP_USER:$APP_USER "$APP_ROOT"

if [[ ! -d "$APP_ROOT/.git" ]]; then
  sudo -u $APP_USER git clone "$INFRA_REPO" "$APP_ROOT"
else
  sudo -u $APP_USER git -C "$APP_ROOT" pull --ff-only
fi

# --- 6. JWT keys ------------------------------------------------------------

log "Stage 6: JWT RSA keys"
SECRETS_DIR="$APP_ROOT/secrets"
mkdir -p "$SECRETS_DIR"

if [[ ! -f "$SECRETS_DIR/jwt_private.pem" ]]; then
  openssl genrsa -out "$SECRETS_DIR/jwt_private.pem" 4096
  openssl rsa -in "$SECRETS_DIR/jwt_private.pem" -pubout -out "$SECRETS_DIR/jwt_public.pem"
  log "Generated new JWT keypair in $SECRETS_DIR"
else
  log "JWT keys already present — keeping them"
fi
chown -R $APP_USER:$APP_USER "$SECRETS_DIR"
chmod 600 "$SECRETS_DIR/jwt_private.pem"
chmod 644 "$SECRETS_DIR/jwt_public.pem"

# --- 7. .env template -------------------------------------------------------

log "Stage 7: .env"
if [[ ! -f "$APP_ROOT/.env" ]]; then
  sudo -u $APP_USER cp "$APP_ROOT/.env.prod.example" "$APP_ROOT/.env"
  log "Created $APP_ROOT/.env from template. Заполните секреты вручную перед запуском!"
fi
chmod 600 "$APP_ROOT/.env"

# --- 8. Traefik users (basic auth для dashboard) -----------------------------

log "Stage 8: traefik dashboard users"
TRAEFIK_USERS="$APP_ROOT/traefik/users"
if [[ ! -f "$TRAEFIK_USERS" ]]; then
  apt-get install -y apache2-utils
  # Дефолтный admin/admin — переделать после первого входа!
  htpasswd -cbB "$TRAEFIK_USERS" admin admin
  log "Created traefik dashboard credentials (admin/admin) — измените!"
fi

# --- 9. GHCR docker login (опционально) ------------------------------------

log "Stage 9: GHCR readme"
cat <<'EOF'

==============================================================================
SETUP COMPLETE. Что дальше:

1. Заполните секреты в .env:
     nano $APP_ROOT/.env

   Минимум:
   - KW_DB_*_PASSWORD (3 пароля)
   - KW_S3_ACCESS_KEY / KW_S3_SECRET_KEY
   - KW_WEBPUSH_VAPID_* (через `npx web-push generate-vapid-keys` локально)
   - TRAEFIK_ACME_EMAIL

2. Залогиньтесь в GHCR (нужен Personal Access Token с read:packages):
     echo <GHCR_TOKEN> | docker login ghcr.io -u <github-username> --password-stdin

3. Настройте DNS на Selectel:
     A   khubiyinc.ru          → 45.144.177.119
     A   app.khubiyinc.ru      → 45.144.177.119
     A   traefik.khubiyinc.ru  → 45.144.177.119
     A   minio.khubiyinc.ru    → 45.144.177.119  (опц.)
     A   www.khubiyinc.ru      → 45.144.177.119  (опц.)

4. Подождите распространения DNS (5-30 мин) и запустите стек:
     cd $APP_ROOT
     docker compose -f docker-compose.prod.yml pull
     docker compose -f docker-compose.prod.yml up -d

5. Дождитесь Let's Encrypt cert (1-2 мин), потом откройте:
     https://app.khubiyinc.ru
     https://traefik.khubiyinc.ru  (admin/admin)

6. Создайте demo-тенанта внутри контейнера api:
     docker compose -f docker-compose.prod.yml exec api \\
       python scripts/bootstrap_demo.py --slug demo-ex \\
       --owner-email owner@example.com --owner-password demo1234

==============================================================================
EOF
