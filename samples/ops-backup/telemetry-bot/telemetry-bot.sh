#!/usr/bin/env bash
# telemetry-bot.sh — Telegram bot commands (/status) by long polling.
#
# Runs as systemd service telemetry-bot.service. Commands, allow-list and
# request log live in the database (telemetry.bot_process, bot_users,
# bot_requests); this script only moves JSON between Telegram and PostgreSQL.
#
# Token is read from /opt/ivp/.env: TELEGRAM_ALARM_BOT_TOKEN.
# The bot must not have a webhook (getUpdates and webhooks exclude each other).

set -uo pipefail

ENV_FILE=/opt/ivp/.env
PSQL=(docker exec -i postgres psql -U telemetry_app -d telemetry -At -v ON_ERROR_STOP=1)

log() { echo "telemetry-bot: $*"; }

TOKEN="$(grep -E '^TELEGRAM_ALARM_BOT_TOKEN=' "$ENV_FILE" | head -n1 | cut -d= -f2-)"
[[ -n "$TOKEN" ]] || { log "TELEGRAM_ALARM_BOT_TOKEN not set in $ENV_FILE"; exit 1; }

# tg <method> [curl args...] — URL goes through stdin (-K -), so the token
# does not appear in the process list
tg() {
    local method="$1"; shift
    curl -sS --max-time 70 "$@" -K - <<<"url = \"https://api.telegram.org/bot${TOKEN}/${method}\""
}

log "started"
while true; do
    if ! offset="$("${PSQL[@]}" -c "SELECT telemetry.bot_offset()" 2>&1)"; then
        log "db: ${offset:0:200}"; sleep 30; continue
    fi

    if ! resp="$(tg getUpdates -G --data-urlencode "timeout=50" --data-urlencode "offset=${offset}" \
                    --data-urlencode 'allowed_updates=["message"]')"; then
        log "getUpdates: network error"; sleep 10; continue
    fi
    if [[ "$resp" != *'"ok":true'* ]]; then
        log "getUpdates: ${resp:0:200}"; sleep 30; continue
    fi
    [[ "$resp" == *'"update_id"'* ]] || continue

    if ! replies="$(printf '%s\n' "SELECT json_build_object('chat_id', to_chat, 'text', reply) FROM telemetry.bot_process(:'j'::jsonb);" \
                    | "${PSQL[@]}" -v j="$resp" 2>&1)"; then
        log "db: ${replies:0:200}"; sleep 10; continue
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        out="$(tg sendMessage -H 'Content-Type: application/json' --data-binary "$line")"
        [[ "$out" == *'"ok":true'* ]] || log "sendMessage: ${out:0:200}"
    done <<<"$replies"
done
