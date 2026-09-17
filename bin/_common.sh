#!/bin/bash
# Shared by create/list/delete/lock/unlock. Not directly executable.
set -euo pipefail

MNT=/mnt/pgbranch
BRANCHES="$MNT/branches"
ROOT="$MNT/root"
STATE=/var/lib/pgbranch/state
LOCK=/var/lib/pgbranch/pgbranch.lock
PGBIN=/usr/lib/postgresql/15/bin
PORT_MIN=${PGBRANCH_PORT_MIN:-7000}
PORT_MAX=${PGBRANCH_PORT_MAX:-7050}
ROOT_PORT=${PGBRANCH_ROOT_PORT:-6999}
SUPERUSER=${PGBRANCH_SUPERUSER:-postgres}

# entrypoint.sh does mount setup + root bootstrap (initdb, locking root)
# synchronously, but `docker compose up -d` / `docker run -d` return as
# soon as the container starts - not once entrypoint finishes. `$ROOT`
# exists as a directory well before initdb+lock are actually done, so wait
# on entrypoint's own readiness marker, not just the mount or the
# directory, or commands can race a still-booting container into reading
# half-initialized state.
for _ in $(seq 1 60); do
  [ -f /var/lib/pgbranch/.ready ] && break
  sleep 0.5
done
if [ ! -f /var/lib/pgbranch/.ready ]; then
  echo "container still booting (root not ready yet) - check: docker logs <container>" >&2
  exit 1
fi

mkdir -p "$STATE"
chown postgres:postgres "$STATE"
touch "$LOCK"

is_running() {
  local dir="$1"
  [ -f "$dir/postmaster.pid" ] || return 1
  kill -0 "$(head -1 "$dir/postmaster.pid")" 2>/dev/null
}

valid_name() {
  [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]] && [ "$1" != "root" ] && [ "$1" != "branches" ]
}

free_port() {
  local used
  used=$( (ls "$STATE"/*.port 2>/dev/null | xargs -r cat) || true)
  local p
  for p in $(seq "$PORT_MIN" "$PORT_MAX"); do
    if ! grep -qx "$p" <<<"$used"; then
      echo "$p"
      return 0
    fi
  done
  echo "no free port in range $PORT_MIN-$PORT_MAX" >&2
  return 1
}

human_mb() {
  awk -v b="$1" 'BEGIN { printf "%.1f", b/1024/1024 }'
}

is_root_locked() {
  [ "$(btrfs property get -ts "$ROOT" ro 2>/dev/null)" = "ro=true" ]
}

require_root() {
  if [ ! -d "$ROOT" ]; then
    echo "root not initialized - container startup didn't finish, check: docker logs <container>" >&2
    exit 1
  fi
}
