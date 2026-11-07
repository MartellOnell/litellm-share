#!/usr/bin/env bash
# Дамп БД LiteLLM (ключи, пользователи, логи расходов).
#
#   ./scripts/backup-db.sh [outdir]
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

OUT="${1:-./backups}"
mkdir -p "$OUT"
FILE="$OUT/litellm-$(date +%Y%m%d-%H%M%S).sql.gz"

docker compose exec -T postgres \
  pg_dump -U "${POSTGRES_USER:-litellm}" "${POSTGRES_DB:-litellm}" \
  | gzip > "$FILE"

echo "$FILE"
