#!/bin/bash
# Создание ролей и расширений для KhubiyInc Workshop.
# Запускается ОДИН РАЗ при первом старте контейнера postgres
# (через docker-entrypoint-initdb.d). Если нужно перезапустить с нуля —
# `docker compose down -v` (удалит volume → init выполнится заново).
#
# Параметры читаются из env, чтобы один и тот же файл работал и для dev
# (compose.dev.yml), и для prod (compose.prod.yml без хардкода паролей):
#   - POSTGRES_DB              — имя БД (создаётся entrypoint'ом до запуска нас)
#   - KW_DB_ADMIN_PASSWORD     — пароль для роли khubiy_admin (миграции, BYPASSRLS)
#   - KW_DB_APP_PASSWORD       — пароль для роли khubiy_app (runtime, под RLS)
#   - KW_DB_READONLY_PASSWORD  — пароль для роли khubiy_readonly (опц., analytics)
#
# Если переменная не задана — fallback на dev-пароль (только для local).

set -euo pipefail

DB_NAME="${POSTGRES_DB:-khubiy_workshop}"
ADMIN_PASSWORD="${KW_DB_ADMIN_PASSWORD:-khubiy_admin_dev_password}"
APP_PASSWORD="${KW_DB_APP_PASSWORD:-khubiy_app_dev_password}"
READONLY_PASSWORD="${KW_DB_READONLY_PASSWORD:-khubiy_readonly_dev_password}"

# psql от имени суперюзера postgres, без сети, через сокет.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB_NAME" <<EOSQL
-- ============================================================================
-- Роли
-- ============================================================================
-- khubiy_admin: владелец схемы, для миграций Alembic. BYPASSRLS — обходит RLS.
-- khubiy_app:   рантайм приложения. RLS работает; tenant_id выставляется через
--               SET LOCAL app.tenant_id перед каждым запросом.
-- khubiy_readonly: read-only для аналитики / отладки (опц.).

CREATE ROLE khubiy_admin LOGIN BYPASSRLS PASSWORD '${ADMIN_PASSWORD}';
CREATE ROLE khubiy_app LOGIN PASSWORD '${APP_PASSWORD}';
CREATE ROLE khubiy_readonly LOGIN PASSWORD '${READONLY_PASSWORD}';

-- ============================================================================
-- БД
-- ============================================================================
-- БД уже создана entrypoint'ом из POSTGRES_DB → меняем владельца и права.

ALTER DATABASE ${DB_NAME} OWNER TO khubiy_admin;

GRANT CONNECT ON DATABASE ${DB_NAME} TO khubiy_app, khubiy_readonly;
EOSQL

# Подключаемся к целевой БД для CREATE EXTENSION и прав на схему.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB_NAME" <<'EOSQL'
-- ============================================================================
-- Расширения
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";   -- uuid_generate_v4()
CREATE EXTENSION IF NOT EXISTS pgcrypto;       -- gen_random_uuid(), crypt()
CREATE EXTENSION IF NOT EXISTS pg_trgm;        -- триграммный поиск (LIKE/ILIKE индексы)
CREATE EXTENSION IF NOT EXISTS unaccent;       -- транслитерация для поиска по русским/тюркским
CREATE EXTENSION IF NOT EXISTS btree_gin;      -- GIN-индексы по составным ключам

-- Права на схему public для приложения.
GRANT USAGE ON SCHEMA public TO khubiy_app, khubiy_readonly;

-- Будущие таблицы (создаются миграциями) — права через default privileges,
-- чтобы khubiy_app автоматически видел новые таблицы после миграций.
ALTER DEFAULT PRIVILEGES FOR ROLE khubiy_admin IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO khubiy_app;

ALTER DEFAULT PRIVILEGES FOR ROLE khubiy_admin IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO khubiy_app;

ALTER DEFAULT PRIVILEGES FOR ROLE khubiy_admin IN SCHEMA public
    GRANT SELECT ON TABLES TO khubiy_readonly;
EOSQL

echo "[init] roles + extensions ready for DB=${DB_NAME}"
