> Сначала читать `../CLAUDE.md` (`../AGENTS.md`) — продуктовые правила воркспейса Khubiy Workshop, затем этот файл.
> `CLAUDE.md` и `AGENTS.md` в этом репо — зеркала друг друга, держим идентичными. `AGENTS.md` читают Codex / Cursor / Aider.

# khubiy-workshop-infra — локальные инструкции

## Что это

Инфраструктура KhubiyInc Workshop: docker-compose (dev/prod), Traefik 3 (reverse proxy, TLS, blue-green), ansible (деплой на Selectel VPS), скрипты бэкапа/restore/миграций, runbooks, reusable GitHub Actions workflows. Деплой и хранилище — Selectel (ADR DEC-002), polyrepo-разбиение — ADR DEC-006.

## Состав

- `docker-compose.dev.yml` — локальное окружение (Postgres 16, Redis 7, MinIO как S3-замена, arq).
- `docker-compose.prod.yml` — production (Traefik + FastAPI ×2 + PgBouncer + Postgres + Redis + arq).
- `traefik/` — конфиги Traefik (dynamic configs, middlewares); `Caddyfile`.
- `ansible/` — плейбуки деплоя; `postgres/` — init/настройка БД; `scripts/` — бэкап/restore/миграции; `runbooks/` — инструкции на инциденты.
- Документация: `DEPLOY.md`, `RUNBOOK.md`, `ONBOARDING.md`, `PILOT.md`.

## Окружения

- **dev** — локально через `docker-compose.dev.yml` (MinIO вместо S3).
- **staging** — Selectel VPS, `staging.workshop.khubiyinc.ru`, автодеплой с `main`.
- **production** — Selectel VPS, `app.khubiyinc.ru`, деплой по тегам `v*` с blue-green.

## Правила и gotchas

- Backend-образ собирается из `khubiy-workshop-api`. Reusable workflows вызываются из api/web: `uses: Khubiy-Inc/khubiy-workshop-infra/.github/workflows/deploy.yml@main`.
- Секреты — только через env / CI secrets, не коммитим.
- Postgres-роли и RLS-инициализация (`khubiy_app`, `khubiy_admin`, `khubiy_readonly`) задаются здесь и в `khubiy-workshop-api` миграциях — менять согласованно; см. правило про bypass RLS в `../CLAUDE.md`.
- Прод-изменения (compose, Traefik, ansible) — аккуратно. Любой деплой, рестарт сервисов и операции с продовой БД — только по явному запросу пользователя.
- Детали инфры — в vault `07 - Infra/*` (Selectel Setup, Backups, CI-CD, Monitoring, Domains and DNS, Runbooks).

## Коммиты

Формат — см. `../CLAUDE.md`. Scope в этом репо: `infra`. Коммитим и пушим только по явному запросу.
