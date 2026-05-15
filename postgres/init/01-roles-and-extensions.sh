-- Создание ролей и расширений для KhubiyInc Workshop.
-- Запускается ОДИН РАЗ при первом старте контейнера postgres (через docker-entrypoint-initdb.d).
-- Если нужно перезапустить с нуля — `docker compose down -v`.

-- ============================================================================
-- Роли
-- ============================================================================
-- khubiy_admin: владелец схемы, для миграций Alembic. BYPASSRLS — обходит RLS.
-- khubiy_app:   рантайм приложения. RLS работает; tenant_id выставляется через
--               SET LOCAL app.tenant_id перед каждым запросом.
-- khubiy_readonly: read-only для аналитики / отладки (опц.).

CREATE ROLE khubiy_admin LOGIN BYPASSRLS PASSWORD 'khubiy_admin_dev_password';
CREATE ROLE khubiy_app LOGIN PASSWORD 'khubiy_app_dev_password';
CREATE ROLE khubiy_readonly LOGIN PASSWORD 'khubiy_readonly_dev_password';

-- ============================================================================
-- БД
-- ============================================================================
-- БД создаётся через POSTGRES_DB env (см. docker-compose.dev.yml),
-- здесь только меняем владельца и выдаём права.

ALTER DATABASE khubiy_workshop_dev OWNER TO khubiy_admin;

GRANT CONNECT ON DATABASE khubiy_workshop_dev TO khubiy_app, khubiy_readonly;

-- ============================================================================
-- Расширения
-- ============================================================================
-- Подключаемся к целевой БД для CREATE EXTENSION.
\connect khubiy_workshop_dev

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
