#!/usr/bin/env bash
# Called by ivp-backup.sh right after a backup and hourly by
# ivp-backup-offsite.timer, so a copy missed during an internet outage is sent
# as soon as the link is back. Each file is sent once; state is kept as empty
# marker files in $OUTBOX_DIR/.sent/.
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
CONF=/etc/ivp-backup/backup.conf
[[ -r $CONF ]] || { echo "Missing $CONF" >&2; exit 1; }
source "$CONF"
: "${OUTBOX_DIR:=/var/backups/ivp-outbox}" "${OFFSITE_DAILY_MAX_MB:=200}"
: "${ENV_FILE:=/opt/ivp/.env}" "${OFFSITE_ALERT_HOURS:=24}"

log() { printf '%s ivp-backup-offsite: %s\n' "$(date -Is)" "$*"; }
notify() {
  local token chat
  token=$(sed -n 's/^TELEGRAM_ALARM_BOT_TOKEN=//p' "$ENV_FILE" | head -n1)
  chat=$(sed -n 's/^TELEGRAM_ALARM_CHAT_ID=//p' "$ENV_FILE" | head -n1)
  [[ -n $token && -n $chat ]] || return 1
  curl -fsS --max-time 20 -o /dev/null -K - \
    --data-urlencode "chat_id=$chat" --data-urlencode "text=$1" \
    <<<"url = \"https://api.telegram.org/bot${token}/sendMessage\""
}

if [[ -z ${OFFSITE_HOST:-} || -z ${OFFSITE_USER:-} || -z ${OFFSITE_PATH:-} || ! -r ${OFFSITE_KEY:-/dev/null} ]]; then
  log 'off-site target not configured'; exit 0
fi
mkdir -p /run/lock
exec 8>/run/lock/ivp-backup-offsite.lock
flock -n 8 || { log 'another send is running'; exit 0; }

sent_dir=$OUTBOX_DIR/.sent
mkdir -p "$sent_dir"
waiting=

while IFS= read -r file; do
  name=${file##*/}
  [[ -e $sent_dir/$name ]] && continue
  day=${name%.tar.zst.age}; day=${day##*-}
  size_mb=$(( ($(stat -c %s "$file") + 1048575) / 1048576 ))
  # large archives are sent only on the first day of a month
  if (( size_mb > OFFSITE_DAILY_MAX_MB )) && [[ $day != 01 ]]; then continue; fi
  if scp -q -i "$OFFSITE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=20 \
       "$file" "${OFFSITE_USER}@${OFFSITE_HOST}:${OFFSITE_PATH%/}/"; then
    touch "$sent_dir/$name"
    log "sent $name"
  else
    log "send failed: $name (will retry next hour)"
    waiting=$file
    break   # link is down — the remaining files wait as well
  fi
done < <(find "$OUTBOX_DIR" -maxdepth 1 -type f -name 'ivp-*-????-??-??.tar.zst.age' | sort)

# forget markers of files already pruned from the outbox
for marker in "$sent_dir"/*; do
  [[ -e $marker ]] || continue
  [[ -e $OUTBOX_DIR/${marker##*/} ]] || rm -f -- "$marker"
done

# A short network outage is normal and
# silent; alert only when a copy has been waiting longer than OFFSITE_ALERT_HOURS.
if [[ -n $waiting ]]; then
  age_h=$(( ($(date +%s) - $(stat -c %Y "$waiting")) / 3600 ))
  if (( age_h >= OFFSITE_ALERT_HOURS )); then
    notify "⚠️ Резервная копия IVP не уходит на удалённый приёмник уже ${age_h} ч (${waiting##*/}). Журнал: journalctl -u ivp-backup-offsite" || true
  fi
  exit 1
fi
