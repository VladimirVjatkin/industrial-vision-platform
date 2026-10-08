#!/usr/bin/env bash
# smartd -M exec hook. SMARTD_* values are data, never shell code.
set -euo pipefail
[[ $EUID -eq 0 ]] || exit 1
ENV_FILE=/opt/ivp/.env
token=$(sed -n 's/^TELEGRAM_ALARM_BOT_TOKEN=//p' "$ENV_FILE" | head -n1)
chat=$(sed -n 's/^TELEGRAM_ALARM_CHAT_ID=//p' "$ENV_FILE" | head -n1)
[[ -n $token && -n $chat ]] || exit 1
device=${SMARTD_DEVICE:-unknown}
reason=${SMARTD_FAILTYPE:-SMART warning}
message="💽 SMART IVP: диск ${device}: ${reason} — проверить диск, обновить резервную копию"
# The token remains out of argv and the journal.
curl -fsS --max-time 20 -o /dev/null -K - \
  --data-urlencode "chat_id=$chat" --data-urlencode "text=$message" \
  <<<"url = \"https://api.telegram.org/bot${token}/sendMessage\""
