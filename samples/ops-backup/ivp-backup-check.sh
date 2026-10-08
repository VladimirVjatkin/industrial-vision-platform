#!/usr/bin/env bash
# Independent from the backup process and its failure trap.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
source /etc/ivp-backup/backup.conf
marker=${SSD_DIR:-/var/backups/ivp}/last-success.epoch
if [[ -s $marker ]] && [[ $(cat "$marker") =~ ^[0-9]+$ ]]; then
  age=$(( ($(date +%s) - $(cat "$marker")) / 3600 ))
else
  age=999999
fi
if (( age < 20 )); then
  echo "IVP backup age: ${age}h; current"
  exit 0
fi
if (( age >= 48 )); then level=CRITICAL
elif (( age >= 26 )); then level=HIGH
else level=WARNING
fi
echo "IVP backup ${level}: last complete copy ${age}h ago"
token=$(sed -n 's/^TELEGRAM_ALARM_BOT_TOKEN=//p' "${ENV_FILE:-/opt/ivp/.env}" | head -n1)
chat=$(sed -n 's/^TELEGRAM_ALARM_CHAT_ID=//p' "${ENV_FILE:-/opt/ivp/.env}" | head -n1)
[[ -n $token && -n $chat ]] || exit 1
curl -fsS --max-time 20 -o /dev/null -K - \
  --data-urlencode "chat_id=$chat" \
  --data-urlencode "text=⚠️ Резервная копия IVP (${level}): последняя полная копия ${age} ч назад" \
  <<<"url = \"https://api.telegram.org/bot${token}/sendMessage\""
exit 1
