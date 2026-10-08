#!/usr/bin/env bash
# Recovery helper. Operates on an already decrypted .tar.zst file.
set -Eeuo pipefail
umask 077
usage() {
  echo 'Usage: ivp-restore.sh list|verify ARCHIVE | extract ARCHIVE EMPTY_DIR | restore-db ARCHIVE n8n|telemetry | restore-files ARCHIVE EMPTY_DIR' >&2
  exit 2
}
[[ $# -ge 2 ]] || usage
action=$1 archive=$2
[[ -f $archive ]] || { echo 'Archive not found' >&2; exit 1; }
confirm() {
  local expected=$1 answer
  read -r -p "Type $expected to proceed: " answer
  [[ $answer == "$expected" ]] || { echo 'Cancelled' >&2; exit 1; }
}
empty_dir() {
  local target=$1
  [[ ! -e $target ]] || { echo 'Destination already exists; use a new empty path' >&2; exit 1; }
  mkdir -m 700 -p "$target"
}
unpack() {
  local target=$1
  tar --use-compress-program=zstd -xf "$archive" -C "$target"
  (cd "$target" && sha256sum -c SHA256SUMS)
}
case "$action" in
  list)
    [[ $# == 2 ]] || usage
    tar --use-compress-program=zstd -tf "$archive"
    ;;
  verify)
    [[ $# == 2 ]] || usage
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    unpack "$tmp"
    for db in n8n telemetry; do
      if command -v pg_restore >/dev/null; then
        pg_restore --list "$tmp/db/$db.dump" > /dev/null
      elif command -v docker >/dev/null && [[ $(docker inspect -f '{{.State.Running}}' postgres 2>/dev/null) == true ]]; then
        docker exec -i postgres pg_restore --list < "$tmp/db/$db.dump" > /dev/null
      else
        echo 'Install postgresql-client or start the postgres container to inspect dump TOCs' >&2
        exit 1
      fi
    done
    for db in frigate.db backup.db; do
      [[ -f $tmp/db/$db ]] || continue
      [[ $(sqlite3 "$tmp/db/$db" 'PRAGMA integrity_check;') == ok ]] || exit 1
    done
    echo 'Checksums, PostgreSQL TOCs and SQLite integrity: OK'
    ;;
  extract)
    [[ $# == 3 ]] || usage
    confirm EXTRACT
    empty_dir "$3"
    unpack "$3"
    echo "Extracted and verified: $3"
    ;;
  restore-db)
    [[ $# == 3 && ( $3 == n8n || $3 == telemetry ) ]] || usage
    [[ $EUID == 0 ]] || { echo 'Run as root' >&2; exit 1; }
    db=$3
    exists=$(docker exec postgres psql -U postgres -Atc "SELECT 1 FROM pg_database WHERE datname='$db'")
    [[ $exists == 1 ]] || { echo "Create the empty $db database first, with correct owner" >&2; exit 1; }
    relations=$(docker exec postgres psql -U postgres -d "$db" -Atc \
      "SELECT count(*) FROM pg_class WHERE relnamespace IN (SELECT oid FROM pg_namespace WHERE nspname NOT IN ('pg_catalog','information_schema')) AND relkind IN ('r','p','v','m','S')")
    [[ $relations == 0 ]] || { echo 'Database is not empty; refusing overwrite' >&2; exit 1; }
    confirm "RESTORE-$db"
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    unpack "$tmp"
    owner=n8n_app; [[ $db == telemetry ]] && owner=telemetry_app
    docker exec -i postgres pg_restore -U postgres --no-owner --role="$owner" -d "$db" < "$tmp/db/$db.dump"
    if [[ $db == telemetry ]]; then
      docker exec postgres psql -U postgres -v ON_ERROR_STOP=1 \
        -c 'ALTER ROLE telemetry_app IN DATABASE telemetry SET search_path = telemetry, public;'
    fi
    echo "Restored $db; run the acceptance checks before starting applications."
    ;;
  restore-files)
    [[ $# == 3 ]] || usage
    confirm STAGE-FILES
    empty_dir "$3"
    unpack "$3"
    echo "Files staged in $3. Review files/*.tar and recovery docs, then copy selected files manually. No live /opt files changed."
    ;;
  *) usage ;;
esac
