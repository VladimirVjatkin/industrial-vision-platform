#!/usr/bin/env bash
#
#   telemetry-files.sh daily   [YYYY-MM-DD]   default: yesterday (Europe/Prague)
#   telemetry-files.sh monthly [YYYY-MM]      default: previous month
#
# daily   -> /srv/telemetry/Temperature_Base/YYYY/MM/YYYY-MM-DD_data.csv
#                                               YYYY-MM-DD_analysis.txt
# monthly -> /srv/telemetry/archives/Temperature_Base_YYYY-MM.zip
#            (month folder + pg_dump of database "telemetry"), sent to Telegram.
#
# Secrets are read from /opt/ivp/.env:
#   TELEGRAM_ALARM_BOT_TOKEN, TELEGRAM_ALARM_CHAT_ID

set -euo pipefail

BASE=/srv/telemetry/Temperature_Base
ARCH=/srv/telemetry/archives
ENV_FILE=/opt/ivp/.env
PSQL=(docker exec -i postgres psql -U telemetry_app -d telemetry -At -v ON_ERROR_STOP=1)

log() { echo "telemetry-files: $*"; }

env_value() {
    grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2-
}

daily() {
    local day="${1:-$(TZ=Europe/Prague date -d yesterday +%F)}"
    [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { log "bad date: $day"; exit 2; }
    local dir="$BASE/${day:0:4}/${day:5:2}"
    mkdir -p "$dir"

    "${PSQL[@]}" -c "SELECT telemetry.daily_csv('$day')"     > "$dir/.${day}_data.csv.tmp"
    "${PSQL[@]}" -c "SELECT telemetry.daily_summary('$day')" > "$dir/.${day}_analysis.txt.tmp"
    mv -f "$dir/.${day}_data.csv.tmp"     "$dir/${day}_data.csv"
    mv -f "$dir/.${day}_analysis.txt.tmp" "$dir/${day}_analysis.txt"
    log "daily $day written to $dir"
}

send_telegram() {
    local file="$1" caption="$2" token chat attempt resp
    token="$(env_value TELEGRAM_ALARM_BOT_TOKEN)"
    chat="$(env_value TELEGRAM_ALARM_CHAT_ID)"
    [[ -n "$token" && -n "$chat" ]] || { log "Telegram token/chat not set in $ENV_FILE"; return 1; }
    for attempt in 1 2 3; do
        resp="$(curl -sS --max-time 120 \
                 -F chat_id="$chat" -F caption="$caption" -F document=@"$file" \
                 "https://api.telegram.org/bot${token}/sendDocument" || true)"
        if [[ "$resp" == *'"ok":true'* ]]; then
            log "sent $(basename "$file") to Telegram"
            return 0
        fi
        log "Telegram send attempt $attempt failed"
        sleep 60
    done
    return 1
}

monthly() {
    local month="${1:-$(TZ=Europe/Prague date -d "$(TZ=Europe/Prague date +%Y-%m-01) -1 day" +%Y-%m)}"
    [[ "$month" =~ ^[0-9]{4}-[0-9]{2}$ ]] || { log "bad month: $month"; exit 2; }
    local y="${month:0:4}" m="${month:5:2}"
    local work zip
    work="$(mktemp -d)"
    WORK_DIR="$work"
    trap 'rm -rf "$WORK_DIR"' EXIT
    mkdir -p "$ARCH"

    # month files (may be missing if nothing was recorded)
    if [[ -d "$BASE/$y/$m" ]]; then
        mkdir -p "$work/Temperature_Base/$y"
        cp -a "$BASE/$y/$m" "$work/Temperature_Base/$y/"
    fi
    # full database copy (custom format, compressed)
    docker exec postgres pg_dump -U telemetry_app -d telemetry -Fc > "$work/telemetry_db_$(date +%F).dump"

    zip="$ARCH/Temperature_Base_${month}.zip"
    (cd "$work" && zip -qr "$zip" .)
    log "archive $zip ($(du -h "$zip" | cut -f1))"

    if (( $(stat -c %s "$zip") > 49000000 )); then
        log "archive larger than Telegram limit (50 MB) — kept locally only"
        return 1
    fi
    send_telegram "$zip" "🗄 Архив температур за ${m}.${y} + копия базы"
}

case "${1:-}" in
    daily)   daily "${2:-}" ;;
    monthly) monthly "${2:-}" ;;
    *) echo "usage: $0 daily [YYYY-MM-DD] | monthly [YYYY-MM]" >&2; exit 2 ;;
esac
