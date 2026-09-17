# pg-dev-brancher

Instant, disk-cheap postgres database branches for local testing. Generic -
works with any postgres database, any schema, any roles.

One protected `root` database lives in a btrfs-formatted volume. Every
branch is a `btrfs subvolume snapshot` of root - creation is a metadata
operation (~100-300ms), and disk usage only grows by what you actually
change (copy-on-write diff, not a full copy).

**Usage flow:** `unlock` → load root data (e.g. a prod backup) → `lock` root → `create` branches

## root: locked vs unlocked

`root` is always in exactly one of two states:

- **locked** (the default, and the state right after first boot) - mounted
  read-only, nothing can write to it, not even the tool itself. This is the
  only state `create` will clone a branch from, so every branch you make is
  guaranteed to come from a stable, finished snapshot.
- **unlocked** - root's own postgres is running on `PGBRANCH_ROOT_PORT`,
  writable, reachable from the host like any local postgres. This is where
  *you* load data in, with whatever tool you want - the container doesn't
  know or care how.

`unlock` refuses while any branch exists - delete them first. There's no
guard the other way: `lock` always succeeds, stopping root's postgres and
flipping it back to read-only, even mid-write, so don't `lock` while a
restore is still running.

```bash
docker compose up -d --build

# load data into root with whatever tool you like - psql, pg_restore,
# pg_dump | psql, a custom seed script, anything that can reach a postgres
# server on a port
docker exec pg-dev-brancher unlock
#   -> prints a connection string for port 6999 (PGBRANCH_ROOT_PORT, from .env)
pg_restore ... # or psql, or pg_dump | psql, etc - your call entirely

docker exec pg-dev-brancher lock
```

## Everyday use

```bash
# create a branch (clone of root), prints the port to connect on
docker exec pg-dev-brancher create my-feature

# connect like any local postgres
psql -h localhost -p <port> -U postgres

# list root's state + all branches - name, port, running/stopped, disk used (MB)
docker exec pg-dev-brancher list

# done with it - stop + free the disk
docker exec pg-dev-brancher delete my-feature

# "reset to root" - just delete + create again
docker exec pg-dev-brancher delete my-feature && docker exec pg-dev-brancher create my-feature
```

Root and branches persist across `docker compose restart` / host reboot
(they live on the `pgbranch_data` named volume). `create` on an
already-existing but stopped branch just resumes it instead of erroring.

## FAQ

**Why is `PGBRANCH_IMG_SIZE` 100G? Will that run out?** It's a sparse file -
the number is a nominal ceiling, not a reservation. Nothing is actually
allocated on disk until you write to it, so setting it to 100G costs
nothing up front. The real limit is always your host's actual free disk
space, not this number. Raise it (`PGBRANCH_IMG_SIZE=500G` etc.) if you
genuinely expect to need more than 100G of *real* data across root + all
branches; there's no downside to leaving it high.

**Why does `create` refuse while root is unlocked?** A branch is a snapshot
of root at that instant. If root is mid-write (you're still loading a
backup into it), the snapshot could catch inconsistent data. Lock root
once you're done loading, then create branches from the stable result.

**Does deleting a branch affect root or other branches?** No - each branch
is an independent btrfs subvolume and an independent postgres process.
Deleting one only stops that process and frees that subvolume's disk.

## Requirements

- A privileged container (loop device + btrfs mount) - already set in
  `docker-compose.yml`.
- Port range `PGBRANCH_PORT_MIN`-`PGBRANCH_PORT_MAX` (default `7000-7050`)
  plus `PGBRANCH_ROOT_PORT` (default `6999`), all published 1:1 to the host.
