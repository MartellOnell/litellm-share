#!/usr/bin/env bash
# Создание виртуального ключа без лимитов.
#
#   ./scripts/create-key.sh dev-1
#
# Требуется .env рядом с docker-compose.yml (LITELLM_MASTER_KEY, LITELLM_PORT).
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

ALIAS="${1:?usage: $0 <key-alias>}"
BASE="http://127.0.0.1:${LITELLM_PORT:-4000}"

curl -sS -X POST "$BASE/key/generate" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"key_alias\":\"${ALIAS}\"}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("key") or d)'
