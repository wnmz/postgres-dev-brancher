#!/bin/bash
# End-to-end test of the pg-dev-brancher git-workflow: build -> unlock ->
# load data generically -> lock -> create branches -> verify isolation ->
# delete -> verify guards. Runs against its own throwaway container/volume,
# never touches a real running pg-dev-brancher instance.
#
# Usage: ./tests/e2e.sh
set -uo pipefail

cd "$(dirname "$0")/.."

CONTAINER=pg-dev-brancher-test
VOLUME=pg_dev_brancher_test_data
IMAGE=pg-dev-brancher:test
ROOT_PORT=16999
PORT_MIN=17000
PORT_MAX=17010

pass=0
fail=0

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1
  docker volume rm "$VOLUME" >/dev/null 2>&1
}
trap cleanup EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok   - $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL - $desc"
    echo "         expected: $expected"
    echo "         actual:   $actual"
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    echo "  ok   - $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL - $desc (expected output to contain: $needle)"
    echo "         actual: $haystack"
    fail=$((fail + 1))
  fi
}

assert_exit() {
  local desc="$1" expected_code="$2"
  shift 2
  local out code
  out=$("$@" 2>&1)
  code=$?
  if [ "$code" = "$expected_code" ]; then
    echo "  ok   - $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL - $desc (expected exit $expected_code, got $code)"
    echo "         output: $out"
    fail=$((fail + 1))
  fi
}

dex() { docker exec "$CONTAINER" "$@"; }
psql_c() { PGPASSWORD=postgres psql -h localhost -p "$1" -U postgres -tqc "$2" 2>&1; }

# macOS ships neither `timeout` nor `gtimeout` by default - portable
# stand-in so the deadlock regression check works everywhere.
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"; kill -9 "$cmd_pid" 2>/dev/null ) &
  local watcher_pid=$!
  wait "$cmd_pid" 2>/dev/null
  local status=$?
  kill "$watcher_pid" 2>/dev/null
  wait "$watcher_pid" 2>/dev/null
  return $status
}

echo "== build =="
cleanup
docker build -q -t "$IMAGE" . >/dev/null

echo "== boot =="
docker run -d --privileged --name "$CONTAINER" \
  -e PGBRANCH_ROOT_PORT="$ROOT_PORT" -e PGBRANCH_PORT_MIN="$PORT_MIN" -e PGBRANCH_PORT_MAX="$PORT_MAX" \
  -p "$ROOT_PORT:$ROOT_PORT" -p "$PORT_MIN-$PORT_MAX:$PORT_MIN-$PORT_MAX" \
  -v "$VOLUME:/var/lib/pgbranch" "$IMAGE" >/dev/null
for _ in $(seq 1 30); do
  dex list >/dev/null 2>&1 && break
  sleep 0.5
done

echo "== root starts locked =="
out=$(dex list)
assert_contains "list shows root locked on boot" "$out" "root: locked"

echo "== create allowed from a locked root, even an empty one =="
out=$(dex create from-empty-root)
assert_contains "create succeeds against the empty freshly-booted root" "$out" "created branch 'from-empty-root'"
dex delete from-empty-root >/dev/null

echo "== unlock =="
out=$(dex unlock)
assert_contains "unlock reports the configured port" "$out" "port $ROOT_PORT"
assert_contains "unlock prints a connection string" "$out" "postgres://postgres:postgres@localhost:$ROOT_PORT"

echo "== create refused while root is unlocked =="
assert_exit "create fails while root is unlocked" 1 dex create too-soon

echo "== load data generically (no repo-specific tooling) =="
psql_c "$ROOT_PORT" "CREATE TABLE demo(id serial primary key, note text); INSERT INTO demo(note) VALUES ('root-row');" >/dev/null

echo "== lock =="
out=$(dex lock)
assert_contains "lock confirms" "$out" "root locked"
out=$(dex list)
assert_contains "list shows root locked after lock" "$out" "root: locked"

echo "== create two branches (regression: must not deadlock on the second) =="
out=$(run_with_timeout 15 dex create feature-a)
assert_contains "feature-a created fast" "$out" "created branch 'feature-a'"
out=$(run_with_timeout 15 dex create feature-b)
assert_contains "feature-b created without hanging on the lock" "$out" "created branch 'feature-b'"

echo "== unlock refused while branches exist =="
assert_exit "unlock refuses with live branches" 1 dex unlock

echo "== branches inherit root's data =="
a_port=$(dex list | awk '/^feature-a/{print $2}')
b_port=$(dex list | awk '/^feature-b/{print $2}')
out=$(psql_c "$a_port" "SELECT note FROM demo;")
assert_contains "feature-a inherited root-row" "$out" "root-row"

echo "== isolation: write to one branch doesn't leak to another =="
psql_c "$a_port" "INSERT INTO demo(note) VALUES ('feature-a-only');" >/dev/null
out=$(psql_c "$b_port" "SELECT count(*) FROM demo;")
assert_contains "feature-b still has exactly 1 row" "$(echo "$out" | tr -d ' ')" "1"

echo "== create is idempotent/resumable =="
out=$(dex create feature-a)
assert_contains "re-running create on a running branch just reports it" "$out" "already running"

echo "== delete =="
dex delete feature-a >/dev/null
out=$(dex list)
if grep -q "^feature-a " <<<"$out"; then
  echo "  FAIL - feature-a still listed after delete"
  fail=$((fail + 1))
else
  echo "  ok   - feature-a gone after delete"
  pass=$((pass + 1))
fi
assert_contains "feature-b untouched by feature-a's delete" "$out" "feature-b"

dex delete feature-b >/dev/null

echo "== unlock works again once all branches are gone =="
assert_exit "unlock succeeds with no branches left" 0 dex unlock
dex lock >/dev/null

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
