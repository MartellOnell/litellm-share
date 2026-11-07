# LiteLLM Share

Селф-хостед шлюз на [LiteLLM Proxy](https://docs.litellm.ai/), который раздаёт одну
модель (или несколько) нескольким пользователям по виртуальным ключам.

Что внутри:

- **LiteLLM Proxy** — OpenAI-совместимый API (`/v1/chat/completions`) + веб-админка.
- **PostgreSQL** — хранение ключей, пользователей и логов расходов.
- **Виртуальные ключи** (`dev-1`, `dev-2`, …) — у каждого пользователя свой ключ,
  без лимитов по бюджету, легко отозвать один и не трогать остальные.
- **Ретраи** — до 5 попыток на запрос (1 + 4 ретрая), чтобы пользователь не получал
  ошибку из-за единичного сбоя провайдера.
- Всё поднимается одной командой `docker compose up -d`.

```
клиент ──sk-dev-1──▶ LiteLLM :4000 ──▶ провайдер (OpenAI-compatible)
                          │
                          └──▶ PostgreSQL (ключи, логи)
```

---

## 1. Требования

- Linux-сервер (проверено на Ubuntu 26.04), 2 vCPU / 4 ГБ RAM / 10 ГБ диска.
- Docker Engine + Compose v2.
- Открытый порт `4000` (или reverse proxy с TLS, см. §8).

Установка Docker (Ubuntu):

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
```

---

## 2. Быстрый старт

```bash
git clone https://github.com/<you>/litellm-share.git
cd litellm-share

cp .env.example .env
cp config.example.yaml config.yaml

# сгенерировать секреты и вписать в .env
echo "LITELLM_MASTER_KEY=sk-$(openssl rand -hex 32)"
echo "LITELLM_SALT_KEY=sk-$(openssl rand -hex 32)"
echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)"

# отредактировать .env (ключи, пароль админа, провайдер)
nano .env

docker compose up -d
docker compose logs -f litellm
```

Готово, когда в логах появится `Uvicorn running on http://0.0.0.0:4000`
и `GET /health/liveliness` отвечает `"I'm alive!"`:

```bash
curl http://127.0.0.1:4000/health/liveliness
```

> Первый запуск занимает 1–2 минуты: LiteLLM применяет миграции схемы в Postgres.

---

## 3. Настройка модели

`config.yaml` — единственное место, где описан провайдер. Пример (z.ai, OpenRouter,
vLLM, Ollama, любой OpenAI-совместимый шлюз):

```yaml
model_list:
  - model_name: my-model
    litellm_params:
      model: openai/YOUR_MODEL_ID
      api_base: os.environ/OPENAI_COMPATIBLE_API_BASE
      api_key: os.environ/OPENAI_COMPATIBLE_API_KEY
```

- `model_name` — имя, которое видят клиенты (`model: "my-model"` в запросе).
  Можно сделать несколько алиасов на одну и ту же модель.
- `model` — `openai/<ID модели у провайдера>` для любого OpenAI-совместимого API.
- `api_base` / `api_key` берутся из `.env` через `os.environ/…` — секреты не попадают
  в конфиг и в Git.
- Нужна вторая модель или фолбэк — просто добавьте ещё один элемент в `model_list`.

После правки: `docker compose restart litellm`.

Проверка, что модели видны:

```bash
curl -s http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | python3 -m json.tool
```

---

## 4. Вход в админку

Откройте `http://<server>:4000/ui` (или просто `http://<server>:4000`).

Логин и пароль — из `.env`:

```env
UI_USERNAME=admin
UI_PASSWORD=<ваш пароль>
```

Почта **не обязательна**: `UI_USERNAME` — произвольная строка, поле «email» в форме
можно заполнить тем же значением. Если браузер предлагает вход по e-mail — это лишь
подсказка UI, а не требование.

> Мастер-ключ (`LITELLM_MASTER_KEY`) — это пароль администратора API, а не логин в UI.
> Не раздавайте его пользователям: для них есть виртуальные ключи.

---

## 5. Виртуальные ключи для пользователей

Через скрипт:

```bash
./scripts/create-key.sh dev-1
./scripts/create-key.sh dev-2
```

Или напрямую через API:

```bash
curl -s -X POST http://127.0.0.1:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key_alias":"dev-1"}' | python3 -m json.tool
```

В ответе будет `"key": "sk-…"` — это и есть ключ пользователя.

Ключ **без лимитов**: не заданы `max_budget`, `budget_duration`, `rpm`, `tpm`,
`models` — значит доступны все модели и срок не истекает. Ограничения при
необходимости добавляются в тот же запрос:

```json
{
  "key_alias": "dev-1",
  "max_budget": 5,
  "budget_duration": "30d",
  "rpm_limit": 60,
  "models": ["my-model"]
}
```

Список и отзыв ключей:

```bash
# список
curl -s http://127.0.0.1:4000/key/list \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | python3 -m json.tool

# отозвать
curl -s -X POST http://127.0.0.1:4000/key/delete \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key": "sk-..."}'
```

То же самое доступно в UI: **Virtual Keys → Create New Key**.

---

## 6. Ретраи и таймауты

В `config.yaml`:

```yaml
litellm_settings:
  num_retries: 4        # 1 попытка + 4 ретрая = до 5 обращений к провайдеру
  request_timeout: 600  # 10 минут на один запрос (coding-сессии длинные)
  drop_params: true

router_settings:
  routing_strategy: simple-shuffle
  num_retries: 4
  retry_after: 2        # пауза между попытками, сек
  allowed_fails: 4      # столько ошибок до временного отключения модели
  cooldown_time: 30     # на сколько секунд отключать, сек
```

Важно: `num_retries: 4` — это **4 повтора после первой неудачи**, то есть до
5 запросов к провайдеру. Если нужно ровно 4 обращения — поставьте `num_retries: 3`.
Ретраи не спасают от ошибок биллинга/авторизации провайдера — только от сетевых
сбоев, 429 и 5xx.

Для разных моделей можно добавить фолбэк:

```yaml
router_settings:
  fallbacks:
    - my-model: ["my-model-backup"]
```

---

## 7. Ресурсы и лимиты

В `docker-compose.yml` заданы лимиты, чтобы контейнеры не съели всю память
и ОС не «задохнулась»:

| Сервис   | RAM   | CPU  |
|----------|-------|------|
| litellm  | 2 GB  | 1.5  |
| postgres | 512MB | 0.5  |

Меняются в `.env`: `LITELLM_MEM_LIMIT`, `LITELLM_CPUS`, `PG_MEM_LIMIT`, `PG_CPUS`.
Ориентир: на 4 ГБ RAM оставляйте системе минимум 1–1.2 ГБ.
`LITELLM_WORKERS=2` — по числу vCPU (не больше).

---

## 8. Безопасность и TLS

По умолчанию порт `4000` слушается на всех интерфейсах и **без TLS**. Для публичного
сервера обязательно:

1. Домен + reverse proxy с сертификатом (Caddy — самый простой вариант):

   ```caddyfile
   llm.example.com {
       reverse_proxy 127.0.0.1:4000
   }
   ```

   Затем в `.env`: `LITELLM_BIND=127.0.0.1` и `docker compose up -d`.

2. Firewall: открыть только `22`, `80`, `443`; `4000` и `5432` наружу не публиковать.

   ```bash
   ufw allow 22,80,443/tcp
   ufw enable
   ```

3. Пароль root — только по SSH-ключу, парольный вход отключить.

4. Сменить все секреты, если они когда-либо попадали в чат/репозиторий.

---

## 9. Подключение клиентов

Любой OpenAI-совместимый клиент:

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://llm.example.com/v1",
    api_key="sk-<виртуальный ключ>",
)

resp = client.chat.completions.create(
    model="my-model",
    messages=[{"role": "user", "content": "привет"}],
)
print(resp.choices[0].message.content)
```

```bash
curl https://llm.example.com/v1/chat/completions \
  -H "Authorization: Bearer sk-<виртуальный ключ>" \
  -H "Content-Type: application/json" \
  -d '{"model":"my-model","messages":[{"role":"user","content":"привет"}]}'
```

Claude Code / Anthropic-совместимые клиенты могут использовать `/v1/messages`
(прокси транслирует формат) — укажите base URL `https://llm.example.com`
и виртуальный ключ.

---

## 10. Обслуживание

```bash
# обновить образ
docker compose pull && docker compose up -d

# логи
docker compose logs -f --tail=200 litellm

# бэкап БД (ключи, пользователи, расходы)
./scripts/backup-db.sh

# освободить диск от старых образов
docker image prune -f
```

Восстановление:

```bash
gunzip -c backups/litellm-YYYYmmdd-HHMMSS.sql.gz \
  | docker compose exec -T postgres psql -U litellm -d litellm
```

---

## 11. Частые проблемы

| Симптом | Причина / решение |
|---|---|
| `Insufficient balance or no resource package` | У провайдера не активирован тариф/нет баланса. Ключ и конфиг тут ни при чём. |
| `401` на `/v1/...` | Неверный виртуальный ключ или он отозван. |
| UI просит e-mail | Используйте `UI_USERNAME` из `.env`; почта не обязательна. |
| Контейнер `litellm` перезапускается | `docker compose logs litellm` — чаще всего битый `config.yaml` или не задан `LITELLM_SALT_KEY`. |
| `database ... does not exist` | Проверьте `POSTGRES_DB`/`POSTGRES_USER` и что postgres healthy. |
| Долгие ответы обрываются | Увеличьте `request_timeout` в `config.yaml`. |

---

## Структура

```
.
├── docker-compose.yml     # litellm + postgres, лимиты ресурсов
├── config.example.yaml    # шаблон конфига с моделью-плейсхолдером
├── .env.example           # все переменные с комментариями
├── scripts/
│   ├── create-key.sh      # создать виртуальный ключ
│   └── backup-db.sh       # дамп БД
└── README.md
```

`config.yaml` и `.env` в Git не попадают (см. `.gitignore`) — там секреты.
