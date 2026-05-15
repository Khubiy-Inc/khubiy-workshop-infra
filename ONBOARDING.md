# KhubiyInc Workshop — Developer Onboarding

Гид «как новый разработчик начинает работу с проектом». Опирается на
CLAUDE.md (полный контекст для AI/нового сотрудника).

## Что это за проект

Multi-tenant SaaS для управления швейными цехами. См.
[Pilot Guide](./PILOT.md) для бизнес-обзора.

## Стек

| Слой | Технология |
|---|---|
| Backend | Python 3.12 + FastAPI + SQLAlchemy 2 + Alembic + uv |
| База данных | Postgres 16 + RLS (multi-tenant изоляция через `app.tenant_id`) |
| Очередь / кэш | Redis 7 |
| Хранилище файлов | MinIO (S3-совместимое) |
| Frontend (web) | Vite 5 + React 18 + TS strict + Tailwind 3 + TanStack Query 5 |
| Mobile | Expo 54 + React Native 0.81 + expo-router 6 |
| Infra | Docker Compose + Caddy 2 (TLS) |
| CI/CD | GitHub Actions → GHCR → SSH в VPS |
| Hosting | Single VPS (RU) + единый Postgres + MinIO bucket |

## Где живёт код

```
~/Developer/
├── khubiy-workshop-api/          ← Backend (Python/FastAPI)
├── khubiy-workshop-web/          ← Web (React/Vite)
├── khubiy-workshop-mobile/       ← Mobile (Expo/RN)
├── khubiy-workshop-infra/        ← docker-compose + scripts + docs (этот репо)
├── khubiy-workshop-knowledge/    ← Obsidian vault — архитектура и ADR
└── clothes_workshop/             ← Прототип-снапшот (исторически)
```

## Локальный запуск с нуля

```bash
# 1. Клонировать все репо
cd ~/Developer
gh repo clone Khubiy-Inc/khubiy-workshop-api
gh repo clone Khubiy-Inc/khubiy-workshop-web
gh repo clone Khubiy-Inc/khubiy-workshop-mobile
gh repo clone Khubiy-Inc/khubiy-workshop-infra

# 2. Поднять инфраструктуру (postgres + redis + minio + mailpit)
cd khubiy-workshop-infra
docker compose -f docker-compose.dev.yml up -d

# 3. Backend
cd ../khubiy-workshop-api
uv sync
uv run alembic upgrade head
# Создать демо-тенант (полностью заполненный, с employees/shifts/orders/payments/etc.)
PYTHONPATH=. uv run python scripts/bootstrap_demo.py \
    --slug demo-ex \
    --owner-email owner@example.com \
    --owner-password demo1234 \
    --reset
# Запустить backend
uv run uvicorn backend.app.main:app --reload --port 8000

# 4. Web (в отдельном терминале)
cd ../khubiy-workshop-web
pnpm install
pnpm dev   # → http://localhost:5173

# 5. (опц.) Mobile через Expo Go
cd ../khubiy-workshop-mobile
pnpm install
pnpm start  # QR-код → отсканируй через Expo Go на телефоне
# Backend URL для физ. устройства: укажи IP машины в .env.local
#   EXPO_PUBLIC_API_BASE_URL=http://192.168.X.X:8000
```

После п.3 — открывай http://localhost:5173, логинься:
- Tenant slug: `demo-ex`
- Email: `owner@example.com`
- Password: `demo1234`

## Структура backend кода

```
backend/app/
├── api/v1/
│   ├── auth/              ← /auth/login, /auth/refresh, /auth/me, /auth/pin-login, /auth/qr-login, /auth/qr-decode
│   ├── internal/          ← /api/v1/internal/* — все бизнес endpoints (RBAC-gated)
│   ├── platform/          ← /api/v1/platform/* — управление тенантами (admin only)
│   └── public/            ← /api/v1/public/* — внешние API (X-API-Key, scope-gated)
├── auth/                  ← модели User, UserRole, Credential; JWT; RBAC gates
├── catalog/               ← Section, Operation, Material, Product, TechCard, Brigade
├── sales/                 ← Client, SalesOrder, Payment, SalesChannel, PriceList
├── production/            ← ProductionOrder, Routing, RoutingOp, Shift, ShiftTask, WorkLog
├── inventory/             ← Warehouse, StockBalance, StockMove, Reservation
├── quality/               ← DefectCause, DefectEvent
├── hr/                    ← Employee
├── platform/              ← Tenant lifecycle
├── payroll/               ← PayrollPeriod, PayrollItem
├── shipments/             ← Shipment, ShipmentItem
├── returns/               ← Return, ReturnItem
├── subcontracting/        ← Subcontractor, OutsourcedTask
├── api_management/        ← ApiKey, WebhookEndpoint, WebhookDelivery
├── notifications/         ← WebPush, ExpoPush subscriptions + sender
├── files/                 ← FileObject + presigned S3 upload
├── audit/                 ← AuditEvent (immutable journal всех state transitions)
├── reports/               ← агрегаты для дашборда
└── core/                  ← config, database, errors, logging
```

## Архитектурные паттерны (фиксированные)

1. **Multi-tenant через RLS**: каждая business-таблица имеет `tenant_id` + RLS policy. Middleware ставит `SET LOCAL app.tenant_id = <jwt.tid>` на сессию.

2. **State machines**: переходы статусов — отдельный сервисный метод `transition()` + матрица `ALLOWED`. Зеркалится на фронте в `*-api.ts`.

3. **Snapshot pattern**: при создании PO `RoutingOp` копирует `norm_minutes_snapshot` + `base_rate_rub_snapshot` из текущей tech-card. Изменения tech-card в будущем не ломают старые routings.

4. **Каскадные эффекты в одной транзакции**: создание `WorkLog` в одном `async with session.begin()` обновляет `routing_op.qty_done` + `shift.fact_qty`.

5. **RBAC**: все mutation endpoints в `/internal/` имеют gate (`OwnerOnly` / `OwnerOrManager` / `OwnerOrAccountant` / `OwnerManagerOrAccountant`). Backend authoritative, web — UX-only hide через `RoleGuard`.

6. **CSS-переменные + Tailwind**: `tokenColor('ink') => 'var(--ink)'`, тема переключается мгновенно через класс `html.dark`.

7. **Auth invariant**: 401 от backend → `window.dispatchEvent(new CustomEvent('auth:unauthorized'))` → AuthProvider слушает → logout + redirect.

## Полезные команды

### Backend

```bash
cd ~/Developer/khubiy-workshop-api
uv run pytest -q                                    # все тесты
uv run pytest tests/test_X.py::test_Y -q            # один тест
uv run ruff check . && uv run ruff format --check . # линт + формат (CI запускает с точкой!)
uv run mypy backend                                  # типы (strict)
uv run alembic revision --autogenerate -m "msg"      # новая миграция
uv run alembic upgrade head                          # применить
uv run alembic current                               # текущая версия
```

### Web

```bash
cd ~/Developer/khubiy-workshop-web
pnpm dev                  # Vite dev сервер
pnpm build                # tsc + vite build
pnpm lint                 # ESLint flat config (zero-warnings)
pnpm format:check         # Prettier --check
pnpm e2e                  # Playwright тесты (нужен запущенный backend)
```

### Mobile

```bash
cd ~/Developer/khubiy-workshop-mobile
pnpm start                # Expo dev server
pnpm typecheck            # tsc --noEmit
pnpm lint                 # ESLint
# Build APK через EAS:
eas build --platform android --profile preview
```

### Infra

```bash
cd ~/Developer/khubiy-workshop-infra
# Dev (locally):
docker compose -f docker-compose.dev.yml up -d
docker compose -f docker-compose.dev.yml ps
docker compose -f docker-compose.dev.yml down -v   # ВНИМАНИЕ: -v снесёт volume!

# Prod (на VPS):
ssh root@45.144.177.119
cd /opt/khubiy-workshop
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs <service> --tail 50
```

## Git workflow

Conventional Commits v1.0.0-beta.3 (см. CLAUDE.md):
- Формат: `<type>[scope]: <description>`
- Типы: `feat`, `fix`, `chore`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `improvement`
- Scope-ы: `web`, `api`, `infra`, `vault`, `scripts`, `mobile`
- Description: нижний регистр, без точки, ≤72 символов
- Breaking change: `!` после type или `BREAKING CHANGE: ...` в footer

Push в `main` → GitHub Actions автоматически деплоит на VPS.

## Тестирование подходов

- **Backend**: pytest + pytest-asyncio. Каждый тест создаёт свой тенант через
  `tenant_token` fixture (`roles=["owner"]` чтобы покрывать все RBAC-gate'ы).
  Teardown — DELETE FROM platform.tenants WHERE id = ... (cascade'ы убирают всё).
- **Web**: Playwright E2E (auth + navigation smoke). Запускаются с running backend.
- **Mobile**: Manual через Expo Go или EAS Build preview APK.

## Известные грабли (не наступай)

См. CLAUDE.md → «Известные грабли». Самые частые:

- `mypy: Function "list" not valid as a type` когда у класса есть метод `list`
  → менять параметр на `Sequence[X]`.
- `_recalc_totals()` возвращает 0 сразу после `session.add(item)` → нужен
  `await session.flush()` между add и SELECT-aggregate.
- StrEnum value vs name: SQLAlchemy шлёт name атрибута (`"in_"`), а в БД enum
  value (`"in"`). Фикс: `Enum(MyEnum, values_callable=lambda x: [e.value for e in x])`.
- pnpm CI: `pnpm install --frozen-lockfile --ignore-scripts` — иначе на Linux
  получаем `ERR_PNPM_IGNORED_BUILDS` exit 1 на esbuild postinstall.
- `EmailStr` отвергает `.local` → для демо использовать `@example.com`.

## Knowledge base (Obsidian vault)

Архитектурные решения и ADR живут в `~/Developer/khubiy-workshop-knowledge/`.
Подключён через Obsidian Local REST API (плагин на `http://localhost:3001`).

В новой сессии всегда читать в этом порядке:
1. `00 - Index/Resume Here.md` — что делать прямо сейчас + опции
2. `00 - Index/Current Status.md` — где мы по фазам
3. `09 - Daily Notes/YYYY-MM-DD.md` — текущие заметки

## Деплой и операции

См. [RUNBOOK.md](./RUNBOOK.md) — деплой, откат, бэкап, восстановление,
мониторинг, типовые проблемы.

## Помощь

- Code review / архитектура — в Obsidian vault'е (ADR'ы)
- Прод-проблемы — RUNBOOK.md
- Бизнес-вопросы — PILOT.md
- Не нашёл ответа — спроси автора (`mrbroman.schanel@gmail.com`)
