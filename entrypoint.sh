#!/bin/bash
# Mounts (or creates) the btrfs-formatted loopback volume, and bootstraps an
# empty, locked "root" cluster on first boot. Doesn't touch root after that -
# use `unlock` to load data into it with whatever tool you like.
set -euo pipefail

IMG_DIR=/var/lib/pgbranch
IMG="$IMG_DIR/btrfs.img"
MNT=/mnt/pgbranch
SIZE=${PGBRANCH_IMG_SIZE:-100G}
PGBIN=/usr/lib/postgresql/15/bin
ROOT="$MNT/root"
SUPERUSER=${PGBRANCH_SUPERUSER:-postgres}
SUPERUSER_PASS=${PGBRANCH_SUPERUSER_PASSWORD:-postgres}

mkdir -p "$IMG_DIR" "$MNT"

# `docker rm` doesn't detach loop devices set up inside a dead container -
# they're a host/VM-kernel-wide resource, not container-scoped. Every
# container that ever ran here (including past ones for other volumes)
# leaks one loop device forever unless we clean up. Left unchecked, the
# kernel's loop pool eventually runs out and losetup -f starts failing
# unpredictably. Safe to detach anything whose backing file is gone -
# devices still backing a real, live file (including another running
# container's) are left alone.
losetup -a 2>/dev/null | awk -F: '/\(deleted\)/{print $1}' | while read -r dev; do
  losetup -d "$dev" 2>/dev/null || true
done

if [ ! -f "$IMG" ]; then
  echo "[pgbranch] creating sparse btrfs image $IMG ($SIZE)"
  truncate -s "$SIZE" "$IMG"
  mkfs.btrfs -q "$IMG"
fi

LOOPDEV=$(losetup -j "$IMG" | cut -d: -f1)
if [ -z "$LOOPDEV" ]; then
  LOOPDEV=$(losetup -f --show "$IMG")
  echo "[pgbranch] attached $IMG to $LOOPDEV"
fi

if ! mountpoint -q "$MNT"; then
  mount "$LOOPDEV" "$MNT"
  echo "[pgbranch] mounted $LOOPDEV at $MNT"
fi

mkdir -p "$MNT/branches"

if [ ! -d "$ROOT" ]; then
  echo "[pgbranch] bootstrapping root (empty cluster, superuser '$SUPERUSER')"
  btrfs subvolume create "$ROOT" >/dev/null
  chown postgres:postgres "$ROOT"

  pwfile=$(mktemp)
  printf '%s' "$SUPERUSER_PASS" > "$pwfile"
  chown postgres:postgres "$pwfile"
  su postgres -c "$PGBIN/initdb -D $ROOT -U $SUPERUSER --pwfile=$pwfile" >/tmp/pgbranch-initdb.log 2>&1
  rm -f "$pwfile"

  echo "host all all 0.0.0.0/0 md5" >> "$ROOT/pg_hba.conf"
  btrfs property set -ts "$ROOT" ro true
  echo "[pgbranch] root ready and locked - run 'unlock' to load data into it"
fi

# `$ROOT` exists as a directory well before it's actually ready (initdb +
# locking root still take a couple seconds) - bin/_common.sh waits on this
# marker, not on the directory, so commands can't race a still-booting
# container into reading a half-initialized root.
touch "$IMG_DIR/.ready"

# Physically release host resources on shutdown instead of leaking them -
# stop every postgres process still running (root + branches) so the
# unmount below isn't yanking a live filesystem out from under them, then
# unmount and detach the loop device. Without this, `docker stop` just
# kills PID 1 and the loop device leaks (see the cleanup pass above, which
# only catches it lazily on the *next* boot).
shutdown() {
  echo "[pgbranch] shutting down - stopping postgres, unmounting, detaching $LOOPDEV"
  for pidfile in "$ROOT/postmaster.pid" "$MNT"/branches/*/postmaster.pid; do
    [ -f "$pidfile" ] || continue
    su postgres -c "$PGBIN/pg_ctl -D $(dirname "$pidfile") -m fast -w stop" >/dev/null 2>&1 || true
  done
  umount "$MNT" 2>/dev/null || true
  losetup -d "$LOOPDEV" 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

"$@" &
wait $!
