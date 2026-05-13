# khubiy-workshop-infra

Инфраструктура KhubiyInc Workshop: docker-compose, Traefik, бэкапы, мониторинг, CI/CD workflows, runbooks.

## Содержание

```
docker-compose.dev.yml        # локальное окружение для разработки
docker-compose.prod.yml       # production (Traefik + FastAPI ×2 + PgBouncer + Postgres + Redis + arq)
traefik/                      # конфиги Traefik (dynamic configs, middlewares)
ansible/                      # плейбуки для деплоя на Selectel VPS (опц.)
scripts/                      # вспомогательные скрипты (бэкап, restore, миграции)
runbooks/                     # runbooks-as-code: инструкции на инциденты
.github/workflows/            # reusable GitHub Actions workflows (deploy, lint, test)
```

## Сервисы

| Сервис | Назначение |
|---|---|
| **Postgres 16** | Основная БД с RLS |
| **PgBouncer** | Пулинг соединений |
| **Redis 7** | Кэш, sessions, arq queue |
| **MinIO** (dev only) | S3-совместимое хранилище для разработки |
| **arq worker** | Background tasks |
| **FastAPI** ×2 | Backend (из репо `khubiy-workshop-api`) |
| **Traefik 3** | Reverse proxy, TLS, blue-green |

## Окружения

- **dev** — локально через `docker-compose.dev.yml`, использует MinIO как S3-замену
- **staging** — Selectel VPS, поддомен `staging.workshop.khubiyinc.ru`, автодеплой с `main`
- **production** — Selectel VPS, `app.khubiyinc.ru`, деплой через теги `v*` с blue-green

## Использование reusable workflows

В репо `khubiy-workshop-api` или `khubiy-workshop-web`:

```yaml
jobs:
  deploy:
    uses: Khubiy-Inc/khubiy-workshop-infra/.github/workflows/deploy.yml@main
    with:
      environment: staging
    secrets: inherit
```

## Связанные репозитории

- [khubiy-workshop-api](https://github.com/Khubiy-Inc/khubiy-workshop-api)
- [khubiy-workshop-web](https://github.com/Khubiy-Inc/khubiy-workshop-web)
- [khubiy-workshop-knowledge](https://github.com/Khubiy-Inc/khubiy-workshop-knowledge)

## Документация

В [knowledge vault](https://github.com/Khubiy-Inc/khubiy-workshop-knowledge):
- ADR DEC-002 — Selectel as VPS and Storage
- ADR DEC-006 — Polyrepo split
- `07 - Infra/Selectel Setup`, `Backups`, `CI-CD`, `Monitoring`, `Domains and DNS`
- `07 - Infra/Runbooks/*`
