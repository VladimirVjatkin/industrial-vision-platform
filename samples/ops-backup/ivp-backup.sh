#!/usr/bin/env bash
# Daily IVP backup. Nothing is restored by this script.
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
CONF=/etc/ivp-backup/backup.conf
[[ -r $CONF ]] || { echo "Missing $CONF" >&2; exit 1; }
# The config must be owned by root; it is trusted shell configuration.
[[ $(stat -c %u "$CONF") == 0 && $(stat -c %a "$CONF") =~ ^(600|640|400|440)$ ]] || {
  echo 'Unsafe backup.conf owner/mode' >&2; exit 1;
}
source "$CONF"
: "${SSD_DIR:=/var/backups/ivp}" "${HDD_MOUNT:=/srv/video}"
: "${HDD_DIR:=/srv/video/backup/ivp}" "${OUTBOX_DIR:=/var/backups/ivp-outbox}"
: "${PULL_GROUP:=sample-backup-read}"
: "${SOURCE_ROOT:=/opt/ivp}" "${TELEMETRY_DIR:=/srv/telemetry}"
: "${ENV_FILE:=/opt/ivp/.env}" "${MIN_FREE_MB:=1024}"
: "${OFFSITE_DAILY_MAX_MB:=200}"
mode=${1:-run}
[[ $mode == run || $mode == --dry-run || $mode == usb ]] || { echo 'Usage: ivp-backup.sh [--dry-run|usb MOUNTPOINT]' >&2; exit 2; }
if [[ $mode == usb ]]; then [[ $# == 2 ]] || exit 2; usb_mount=$2; fi
date_id=$(TZ=Europe/Prague date +%F)
host=$(hostname -s | tr -cd 'a-zA-Z0-9-')
archive="ivp-${host}-${date_id}.tar.zst"
week_day=$(TZ=Europe/Prague date +%u)
day_num=$(TZ=Europe/Prague date +%d)
log() { printf '%s ivp-backup: %s\n' "$(date -Is)" "$*"; }
notify() {
  local message=$1 token chat
  [[ -r $ENV_FILE ]] || return 1
  token=$(sed -n 's/^TELEGRAM_ALARM_BOT_TOKEN=//p' "$ENV_FILE" | head -n1)
  chat=$(sed -n 's/^TELEGRAM_ALARM_CHAT_ID=//p' "$ENV_FILE" | head -n1)
  [[ -n $token && -n $chat ]] || return 1
  curl -fsS --max-time 20 -o /dev/null -K - \
    --data-urlencode "chat_id=$chat" --data-urlencode "text=$message" \
    <<<"url = \"https://api.telegram.org/bot${token}/sendMessage\""
}
if [[ $mode == --dry-run ]]; then
  printf 'Plan: PostgreSQL globals + n8n + telemetry; n8n workflow export; Frigate SQLite; /opt configuration; face library; telemetry files; system settings; inventory.\n'
  printf 'Targets: %s/%s and %s/%s; age outbox: %s; weekly router export/restore test: Sunday; USB: manual.\n' "$SSD_DIR" "$archive" "$HDD_DIR" "$archive" "$OUTBOX_DIR"
  printf 'No files, network calls, locks, or containers changed.\n'
  exit 0
fi
if [[ $mode == usb ]]; then
  [[ -d $usb_mount && -d $RECOVERY_DOCS ]] || { echo 'USB mount or recovery docs missing' >&2; exit 1; }
  mountpoint -q "$usb_mount" || { echo 'USB destination is not a mountpoint' >&2; exit 1; }
  [[ -s $SSD_DIR/last-success.epoch ]] || { echo 'No complete backup marker' >&2; exit 1; }
  good_day=$(TZ=Europe/Prague date -d "@$(cat "$SSD_DIR/last-success.epoch")" +%F)
  src="$SSD_DIR/ivp-${host}-${good_day}.tar.zst"
  [[ -s $src && -s $HDD_DIR/$(basename "$src") ]] || { echo 'Latest complete pair is missing' >&2; exit 1; }
  mountpoint -q "$HDD_MOUNT" && [[ $(findmnt -n -o UUID --target "$HDD_MOUNT") == "$EXPECTED_HDD_UUID" ]] || { echo 'HDD mount mismatch' >&2; exit 1; }
  cmp -s -- "$src" "$HDD_DIR/$(basename "$src")" || { echo 'SSD/HDD pair differs' >&2; exit 1; }
  usb_dir="$usb_mount/IVP-backup-$(TZ=Europe/Prague date +%F)"
  mkdir -m 700 -p "$usb_dir"
  cp -- "$src" "$usb_dir/"
  tar --use-compress-program=zstd -xf "$src" -C "$usb_dir" ./inventory
  mkdir -p "$usb_dir/RECOVERY"
  cp -a -- "$RECOVERY_DOCS/." "$usb_dir/RECOVERY/"
  printf 'Start with RECOVERY/README.md and RECOVERY/DISK_SSD_FAILED.md. Contains unencrypted secrets and biometrics: keep offline and locked.\n' > "$usb_dir/README.txt"
  sha256sum "$usb_dir/$(basename "$src")" > "$usb_dir/SHA256SUMS"
  (cd "$usb_dir" && sha256sum -c SHA256SUMS)
  sync
  log "USB copied and verified at $usb_dir. Unmount/eject the stick safely."
  exit 0
fi

mkdir -p "$SSD_DIR" "$OUTBOX_DIR" /run/lock
getent group "$PULL_GROUP" > /dev/null || { log "Create group $PULL_GROUP for encrypted backup pulls"; exit 1; }
chgrp "$PULL_GROUP" "$OUTBOX_DIR"
chmod 750 "$OUTBOX_DIR"
exec 9>/run/lock/ivp-backup.lock
flock -n 9 || { log 'Another run is active'; exit 1; }
stage= hdd_ok=0 verify_db1= verify_db2=
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n $verify_db1 ]]; then docker exec postgres dropdb -U postgres --if-exists "$verify_db1" >/dev/null 2>&1 || true; fi
  if [[ -n $verify_db2 ]]; then docker exec postgres dropdb -U postgres --if-exists "$verify_db2" >/dev/null 2>&1 || true; fi
  if [[ -n $stage && -d $stage ]]; then rm -rf -- "$stage"; fi
  if (( rc != 0 )); then
    rm -f -- "$SSD_DIR/.${archive}.partial"
    if (( hdd_ok )); then rm -f -- "$HDD_DIR/.${archive}.partial"; fi
    rm -f -- "$OUTBOX_DIR/${archive}.age.partial"
  fi
  if (( rc != 0 )); then log "FAILED (exit $rc)"; notify "❌ Резервная копия IVP ${date_id} НЕ СДЕЛАНА. Журнал: journalctl -u ivp-backup" || true; fi
  exit "$rc"
}
trap cleanup EXIT

[[ -d $SOURCE_ROOT && -d $TELEMETRY_DIR ]] || { log 'Required source directory missing'; exit 1; }
for name in postgres mosquitto n8n frigate; do
  [[ $(docker inspect -f '{{.State.Running}}' "$name") == true ]] || { log "Container $name not running"; exit 1; }
done
[[ $(df -Pm "$SSD_DIR" | awk 'NR==2 {print $4}') -ge $MIN_FREE_MB ]] || { log 'SSD free space below minimum'; exit 1; }
if mountpoint -q "$HDD_MOUNT" && [[ -n ${EXPECTED_HDD_UUID:-} ]] && \
   [[ $(findmnt -n -o UUID --target "$HDD_MOUNT") == "$EXPECTED_HDD_UUID" ]]; then
  hdd_ok=1
  mkdir -p "$HDD_DIR"
  [[ $(df -Pm "$HDD_DIR" | awk 'NR==2 {print $4}') -ge $MIN_FREE_MB ]] || { log 'HDD free space below minimum'; hdd_ok=0; }
else
  log 'HDD mount/UUID mismatch; HDD copy will be skipped'
fi

stage=$(mktemp -d "$SSD_DIR/.ivp-stage.XXXXXXXX")
mkdir -p "$stage"/{db,files,inventory,routers}
log 'Creating PostgreSQL logical dumps'
docker exec -i postgres pg_dumpall -U postgres --globals-only > "$stage/db/globals.sql"
for db in n8n telemetry; do
  docker exec -i postgres pg_dump -U postgres -Fc "$db" > "$stage/db/$db.dump"
  docker exec -i postgres pg_restore --list < "$stage/db/$db.dump" > /dev/null
done

log 'Exporting n8n workflows'
n8n_tmp="/tmp/ivp-workflows-${date_id}-$$"
docker exec n8n mkdir -p "$n8n_tmp"
if docker exec n8n n8n export:workflow --all --separate --output="$n8n_tmp"; then
  docker cp "n8n:$n8n_tmp/." "$stage/files/"
else
  docker exec n8n rm -rf -- "$n8n_tmp" || true
  exit 1
fi
docker exec n8n rm -rf -- "$n8n_tmp"
mv "$stage/files" "$stage/n8n-workflows"
mkdir -p "$stage/files"
[[ -n $(find "$stage/n8n-workflows" -type f -name '*.json' -print -quit) ]] || { log 'n8n workflow export is empty'; exit 1; }

log 'Making consistent SQLite copies'
frigate_config="$SOURCE_ROOT/frigate/config"
for name in frigate.db backup.db; do
  [[ -f $frigate_config/$name ]] || continue
  if [[ $name == backup.db ]] && ! sqlite3 "$frigate_config/$name" 'PRAGMA integrity_check;' >/dev/null 2>&1; then
    log 'Skipping backup.db: it is not readable SQLite'
    continue
  fi
  sqlite3 "$frigate_config/$name" ".backup '$stage/db/$name'"
  [[ $(sqlite3 "$stage/db/$name" 'PRAGMA integrity_check;') == ok ]] || { log "SQLite integrity failed: $name"; exit 1; }
done
[[ -s $stage/db/frigate.db ]] || { log 'Frigate database missing'; exit 1; }

log 'Archiving configuration, telemetry, faces and host settings'
tar -C /opt -cpf "$stage/files/opt-ivp.tar" \
  --exclude='ivp/frigate/config/model_cache' \
  --exclude='ivp/frigate/config/frigate.db*' \
  --exclude='ivp/frigate/config/backup.db*' \
  ivp
tar -C /srv -cpf "$stage/files/telemetry.tar" telemetry
faces="$HDD_MOUNT/frigate/clips/faces"
if (( hdd_ok )) && [[ -d $faces ]]; then
  tar -C "$HDD_MOUNT" -cpf "$stage/files/faces.tar" frigate/clips/faces
else
  log 'Face library unavailable; complete backup cannot be certified'
  hdd_ok=0
fi
system_paths=(etc/fstab etc/netplan etc/ssh/sshd_config etc/ssh/sshd_config.d
  etc/docker/daemon.json etc/chrony etc/sysctl.d etc/systemd/system
  etc/systemd/journald.conf.d etc/sysstat etc/default/sysstat etc/smartd.conf
  etc/ivp-backup root/.ssh/known_hosts root/.ssh/ivp_router_backup.pub)
present=()
for path in "${system_paths[@]}"; do
  if [[ -e /$path ]]; then present+=("$path"); fi
done
if ((${#present[@]})); then tar -C / -cpf "$stage/files/system.tar" "${present[@]}"; fi
crontab -l -u root > "$stage/files/root-crontab.txt" 2>/dev/null || true

{ cat /etc/os-release; uname -a; } > "$stage/inventory/os.txt"
nvidia-smi > "$stage/inventory/nvidia-smi.txt" 2>&1 || true
docker version > "$stage/inventory/docker-version.txt"
docker compose version > "$stage/inventory/compose-version.txt"
docker images --digests --no-trunc > "$stage/inventory/images.txt"
docker ps --format '{{.Names}} {{.Image}} {{.Status}}' > "$stage/inventory/containers.txt"
for name in postgres mosquitto n8n frigate; do
  docker inspect -f '{{range .Mounts}}{{.Type}} {{.Name}} {{.Source}} -> {{.Destination}}{{println}}{{end}}' "$name" > "$stage/inventory/mounts-$name.txt"
  docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$name" > "$stage/inventory/compose-dir-$name.txt"
done
dpkg-query -W > "$stage/inventory/packages.txt"
apt-mark showmanual > "$stage/inventory/manual-packages.txt"
lsblk -f > "$stage/inventory/lsblk.txt"
ip -br link > "$stage/inventory/links.txt"
ip -br addr > "$stage/inventory/addresses.txt"
df -h > "$stage/inventory/filesystems.txt"
systemctl list-unit-files --state=enabled --no-pager > "$stage/inventory/enabled-units.txt"
dmidecode -t bios -t system > "$stage/inventory/bios.txt" 2>&1 || true
docker exec postgres psql -U postgres -Atc 'SHOW server_version' > "$stage/inventory/postgres-version.txt"
docker inspect -f '{{.Config.Image}}' mosquitto > "$stage/inventory/mosquitto-version.txt"
docker exec n8n n8n --version > "$stage/inventory/n8n-version.txt"
docker inspect -f '{{.Config.Image}}' frigate > "$stage/inventory/frigate-version.txt"
smart_status=not-scheduled
if [[ $week_day == 7 ]]; then
  if command -v smartctl >/dev/null; then
    smart_status=ok
    while read -r device _; do
      [[ -n $device ]] || continue
      if ! smartctl -H "$device" > "$stage/inventory/smart-$(basename "$device").txt" 2>&1; then smart_status=warning; fi
    done < <(smartctl --scan 2>/dev/null)
  else smart_status=unavailable; fi
fi

router_status=not-scheduled
if [[ $week_day == 7 ]]; then
  router_status=ok
  for device in router-a router-b; do
    # RouterOS 7 hides secrets by default; RouterOS 6 needs hide-sensitive
    # RouterOS 6 may export Wi-Fi keys without hide-sensitive.
    if [[ $device == router-a ]]; then target=${ROUTER_A_HOST:-}; export_cmd=${ROUTER_A_EXPORT_CMD:-/export terse}
    else target=${ROUTER_B_HOST:-}; export_cmd=${ROUTER_B_EXPORT_CMD:-/export terse hide-sensitive}; fi
    if [[ -z $target || ! -r ${ROUTER_KEY:-/dev/null} ]]; then router_status=failed; continue; fi
    opts=(-i "$ROUTER_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
    if ! ssh "${opts[@]}" "${ROUTER_USER}@${target}" "$export_cmd" > "$stage/routers/${device}.rsc" || \
       grep -qiE 'private-key=|pre-shared-key=|passphrase=|password=' "$stage/routers/${device}.rsc" || \
       ! ssh "${opts[@]}" "${ROUTER_USER}@${target}" '/system resource print' > "$stage/routers/${device}-resource.txt" || \
       ! ssh "${opts[@]}" "${ROUTER_USER}@${target}" '/system routerboard print' > "$stage/routers/${device}-board.txt"; then
      router_status=failed
      rm -f -- "$stage/routers/${device}.rsc" "$stage/routers/${device}-resource.txt" "$stage/routers/${device}-board.txt"
      log "Router export failed: $device"
    fi
  done
fi

# Weekly restore test. A failed test is reported but must not cancel the
# backup itself, so every step is chained with && instead of relying on set -e.
restore_check() {
  verify_db1="ivp_verify_n8n_$$"
  verify_db2="ivp_verify_telemetry_$$"
  docker exec postgres createdb -U postgres -O n8n_app "$verify_db1" &&
  docker exec -i postgres pg_restore -U postgres --no-owner --role=n8n_app -d "$verify_db1" < "$stage/db/n8n.dump" &&
  docker exec postgres psql -U postgres -d "$verify_db1" -v ON_ERROR_STOP=1 -Atc 'SELECT count(*) FROM public.workflow_entity' > "$stage/inventory/n8n-workflow-count.txt" &&
  docker exec postgres createdb -U postgres -O telemetry_app "$verify_db2" &&
  docker exec -i postgres pg_restore -U postgres --no-owner --role=telemetry_app -d "$verify_db2" < "$stage/db/telemetry.dump" &&
  docker exec postgres psql -U postgres -d "$verify_db2" -v ON_ERROR_STOP=1 -Atc \
    "SELECT count(*) FROM telemetry.measurements; SELECT telemetry.daily_summary((current_timestamp AT TIME ZONE 'Europe/Prague')::date - 1);" \
    > "$stage/inventory/telemetry-restore-check.txt"
}
restore_status=not-scheduled
if [[ $week_day == 7 ]]; then
  if restore_check; then restore_status=ok; else restore_status=failed; log 'Weekly restore test failed'; fi
  docker exec postgres dropdb -U postgres --if-exists "$verify_db1" >/dev/null 2>&1 || true; verify_db1=
  docker exec postgres dropdb -U postgres --if-exists "$verify_db2" >/dev/null 2>&1 || true; verify_db2=
fi

cat > "$stage/MANIFEST" <<EOF
IVP logical backup
date=$date_id
host=$host
postgres=n8n,telemetry,globals
frigate_sqlite=online-backup
faces=$([[ -f $stage/files/faces.tar ]] && echo included || echo unavailable)
routers=$router_status
restore_test=$restore_status
smart=$smart_status
excluded=ordinary-recordings,previews,review,thumbs,event-snapshots,model_cache
EOF
(cd "$stage" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
out="$SSD_DIR/$archive"
rm -f -- "$SSD_DIR/.${archive}.partial"
tar -C "$stage" -cf - . | zstd -T0 -q -o "$SSD_DIR/.${archive}.partial"
mv -- "$SSD_DIR/.${archive}.partial" "$out"
chmod 600 "$out"
zstd -tq "$out"
log "SSD archive ready: $archive"
if (( hdd_ok )); then
  [[ $(df -Pm "$HDD_DIR" | awk 'NR==2 {print $4}') -gt $(( $(stat -c %s "$out") / 1048576 + MIN_FREE_MB )) ]] || { log 'HDD cannot hold archive'; hdd_ok=0; }
fi
if (( hdd_ok )); then
  rm -f -- "$HDD_DIR/.${archive}.partial"
  cp -- "$out" "$HDD_DIR/.${archive}.partial"
  cmp -s -- "$out" "$HDD_DIR/.${archive}.partial" || { log 'HDD copy differs'; exit 1; }
  mv -- "$HDD_DIR/.${archive}.partial" "$HDD_DIR/$archive"
  chmod 600 "$HDD_DIR/$archive"
  log 'HDD copy verified'
else
  log 'HDD backup unavailable; daily backup incomplete'
  exit 1
fi

# Encrypted copy for off-site storage and an approved client. Sending is done by ivp-backup-offsite.sh
# (called here and retried hourly by its own timer until it succeeds); a copy
# of the day that was already sent is not re-created on a manual re-run.
offsite_status=not-configured
if [[ -s ${AGE_RECIPIENTS:-/dev/null} ]]; then
  encrypted="$OUTBOX_DIR/${archive}.age"
  if [[ -e $OUTBOX_DIR/.sent/${archive}.age ]]; then
    log "Encrypted copy of $date_id already sent; not re-created"
  else
    rm -f -- "${encrypted}.partial"
    age -R "$AGE_RECIPIENTS" -o "${encrypted}.partial" "$out"
    mv -- "${encrypted}.partial" "$encrypted"
    chgrp "$PULL_GROUP" "$encrypted"
    chmod 640 "$encrypted"
  fi
  offsite_status=queued
  if [[ -n ${OFFSITE_HOST:-} ]]; then
    /usr/local/sbin/ivp-backup-offsite.sh || true
    if [[ -e $OUTBOX_DIR/.sent/${archive}.age ]]; then offsite_status=sent; else offsite_status=pending; fi
  fi
fi

# Both local targets succeeded; the marker has only timestamp, no secrets.
printf '%s\n' "$(date +%s)" > "$SSD_DIR/.last-success.partial"
mv -- "$SSD_DIR/.last-success.partial" "$SSD_DIR/last-success.epoch"
prune() {
  local dir=$1 file d sunday=0 daily=0
  local -a paths=()
  local -A keep=()
  mapfile -t paths < <(find "$dir" -maxdepth 1 -type f -name "ivp-${host}-????-??-??.tar.zst" | sort -r)
  for file in "${paths[@]}"; do
    d=${file##*/}; d=${d#ivp-${host}-}; d=${d%.tar.zst}
    if (( daily < 14 )); then keep["$file"]=1; ((daily+=1)); fi
    if [[ $(date -d "$d" +%u) == 7 ]] && (( sunday < 8 )); then keep["$file"]=1; ((sunday+=1)); fi
  done
  for file in "${paths[@]}"; do [[ ${keep[$file]:-0} == 1 ]] || rm -f -- "$file"; done
}
prune "$SSD_DIR"; prune "$HDD_DIR"
# encrypted outbox: keep the 14 newest files
find "$OUTBOX_DIR" -maxdepth 1 -type f -name "ivp-${host}-????-??-??.tar.zst.age" | sort -r | tail -n +15 | xargs -r rm -f --
log "SUCCESS SSD/HDD; offsite=$offsite_status; routers=$router_status; restore=$restore_status"
# Only real problems are pushed immediately; "not-configured"/"queued"/"deferred-size"
# are expected states and appear in the Sunday summary.
if [[ $offsite_status == failed || $router_status == failed || $restore_status == failed || $smart_status == warning ]]; then
  notify "⚠️ Резервная копия IVP ${date_id}: локальные копии OK, но есть проблема — удалённая копия=${offsite_status}, роутеры=${router_status}, тест восстановления=${restore_status}, SMART=${smart_status}. Журнал: journalctl -u ivp-backup" || true
fi
if [[ $week_day == 7 ]]; then
  notify "🗄 Резервные копии IVP за неделю: SSD+HDD OK, размер $(du -h "$out" | awk '{print $1}'), удалённая копия=${offsite_status}, роутеры=${router_status}, тест восстановления=${restore_status}, SMART=${smart_status}" || true
fi
