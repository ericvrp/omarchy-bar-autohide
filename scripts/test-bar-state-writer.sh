#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
writer="$repo_dir/scripts/bar-state-writer.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

runtime="$test_root/runtime"
toggles="$test_root/toggles"
mkdir -p "$runtime" "$toggles" "$test_root/bin"
current_owner="$runtime/current"
journal="$runtime/journal"
lock="$runtime/lock"
bar_off="$toggles/bar-off"
operation="$runtime/ericvrp.bar-autohide.operation"
acknowledgement="$runtime/ericvrp.bar-autohide.ack"
old_owner=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
new_owner=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

cat > "$test_root/bin/omarchy-shell" <<'MOCK'
#!/usr/bin/env bash
# Model a delayed host visibility callback. It acknowledges the operation
# that triggered the probe only after the test releases the callback gate.
[[ "${FAIL_BAR_SYNC:-0}" != 1 ]] || exit 1
operation="$(cat "$TEST_OPERATION")"
token="${operation%:*}"
if [[ "${PAUSE_BAR_SYNC:-0}" == 1 && ! -e "$SYNC_RELEASE" ]]; then
  : > "$SYNC_STARTED"
  while [[ ! -e "$SYNC_RELEASE" ]]; do sleep 0.01; done
fi
printf '%s\n' "$token" > "$TEST_ACK"
exit 0
MOCK
chmod +x "$test_root/bin/omarchy-shell"
real_touch="$(command -v touch)"
cat > "$test_root/bin/touch" <<'MOCK'
#!/usr/bin/env bash
if [[ "${PAUSE_BAR_TOUCH:-0}" == 1 && "${2:-}" == "$TEST_BAR_OFF" ]]; then
  : > "$TOUCH_STARTED"
  while [[ ! -e "$TOUCH_RELEASE" ]]; do sleep 0.01; done
fi
[[ "${FAIL_BAR_TOUCH:-0}" != 1 ]] || exit 1
exec "$REAL_TOUCH" "$@"
MOCK
chmod +x "$test_root/bin/touch"
real_rm="$(command -v rm)"
cat > "$test_root/bin/rm" <<'MOCK'
#!/usr/bin/env bash
for path in "$@"; do
  if [[ "${PAUSE_BAR_RESTORE:-0}" == 1 && "$path" == "$TEST_BAR_OFF" ]]; then
    : > "$RESTORE_STARTED"
    while [[ ! -e "$RESTORE_RELEASE" ]]; do sleep 0.01; done
  fi
done
exec "$REAL_RM" "$@"
MOCK
chmod +x "$test_root/bin/rm"
export PATH="$test_root/bin:$PATH"
export REAL_TOUCH="$real_touch" REAL_RM="$real_rm" TEST_BAR_OFF="$bar_off"
export TEST_OPERATION="$operation"
export TEST_ACK="$acknowledgement" SYNC_STARTED="$test_root/sync.started"
export SYNC_RELEASE="$test_root/sync.release" TOUCH_STARTED="$test_root/touch.started"
export TOUCH_RELEASE="$test_root/touch.release"
export RESTORE_STARTED="$test_root/restore.started" RESTORE_RELEASE="$test_root/restore.release"

run_writer() {
  bash "$writer" "$runtime" "$current_owner" "$journal" "$lock" "$bar_off" \
    "$operation" "$acknowledgement"
}

publish() {
  local owner="$1" revision="$2" state="$3" observed="${4:-visible}"
  printf '%s:%s:%s\n' "$revision" "$state" "$observed" \
    > "$runtime/ericvrp.bar-autohide.$owner.intent"
}

assert_state() {
  local expected="$1"
  local actual=visible
  [[ -e "$bar_off" ]] && actual=hidden
  [[ "$actual" == "$expected" ]] || {
    printf 'expected bar state %s, got %s\n' "$expected" "$actual" >&2
    exit 1
  }
}

# A hidden callback is delayed after a newer visible request has been
# published. The writer must keep the hidden operation marker until that
# callback acknowledges it, then reconcile the latest visible request.
publish "$old_owner" 1 hidden
printf '%s\n' "$old_owner" > "$current_owner"
PAUSE_BAR_SYNC=1 run_writer &
writer_pid=$!
for _ in {1..200}; do [[ -e "$SYNC_STARTED" ]] && break; sleep 0.01; done
[[ -e "$SYNC_STARTED" ]]
[[ "$(<"$operation")" == "$old_owner:1:"*":hidden:waiting" ]]
publish "$old_owner" 2 visible hidden
: > "$SYNC_RELEASE"
wait "$writer_pid"
unset PAUSE_BAR_SYNC
assert_state visible
[[ "$(<"$journal")" == "visible:$old_owner:2" ]]
latest_operation="$(<"$operation")"
[[ "$latest_operation" == "$old_owner:2:"*":visible:waiting" ]]
[[ "$(<"$acknowledgement")" == "${latest_operation%:*}" ]]

# A delayed hide worker must read the newest intent after acquiring the lock.
publish "$old_owner" 3 hidden
exec 9>"$lock"
flock -x 9
run_writer &
writer_pid=$!
publish "$old_owner" 4 closed
flock -u 9
exec 9>&-
wait "$writer_pid"
assert_state visible
[[ ! -e "$journal" ]]

# A stale destructor only closes its own slot; the replacement remains the
# current owner and its hidden intent wins.
publish "$old_owner" 5 hidden
run_writer
assert_state hidden
publish "$new_owner" 1 hidden hidden
printf '%s\n' "$new_owner" > "$current_owner"
publish "$old_owner" 6 closed
run_writer
assert_state hidden
[[ "$(<"$journal")" == "visible:$new_owner:1" ]]

# Pause predecessor cleanup before it restores visible. A replacement owner
# publishes hidden while the old cleanup is paused; after the restore callback,
# the replacement's latest intent must still win.
rm -f "$RESTORE_STARTED" "$RESTORE_RELEASE"
publish "$new_owner" 2 closed hidden
PAUSE_BAR_RESTORE=1 run_writer &
writer_pid=$!
for _ in {1..200}; do [[ -e "$RESTORE_STARTED" ]] && break; sleep 0.01; done
[[ -e "$RESTORE_STARTED" ]]
[[ "$(<"$operation")" == "$new_owner:2:"*":visible:closing" ]]
publish "$old_owner" 1 hidden visible
printf '%s\n' "$old_owner" > "$current_owner"
: > "$RESTORE_RELEASE"
wait "$writer_pid"
unset PAUSE_BAR_RESTORE
assert_state hidden
[[ "$(<"$journal")" == "visible:$old_owner:1" ]]

# Final unload restores the original baseline captured by the first owner.
publish "$old_owner" 2 closed hidden
run_writer
assert_state visible
[[ ! -e "$journal" ]]

# A failed flag write or sync must leave the original baseline journaled so a
# later writer can recover without treating the plugin's hidden flag as its start.
crash_owner=cccccccccccccccccccccccccccccccc
publish "$crash_owner" 1 hidden
printf '%s\n' "$crash_owner" > "$current_owner"
if FAIL_BAR_TOUCH=1 run_writer; then
  echo 'expected injected touch failure' >&2
  exit 1
fi
assert_state visible
[[ "$(<"$journal")" == 'visible::' ]]
run_writer
assert_state hidden
[[ "$(<"$journal")" == "visible:$crash_owner:1" ]]
publish "$crash_owner" 2 visible hidden
if FAIL_BAR_SYNC=1 run_writer; then
  echo 'expected injected sync failure' >&2
  exit 1
fi
assert_state visible
[[ "$(<"$journal")" == "visible:$crash_owner:1" ]]
run_writer
[[ "$(<"$journal")" == "visible:$crash_owner:2" ]]
publish "$crash_owner" 3 closed hidden
run_writer
assert_state visible
[[ ! -e "$journal" ]]

# A pre-existing hidden bar state is captured and restored on unload.
touch "$bar_off"
printf '%s\n' "$old_owner" > "$current_owner"
publish "$old_owner" 3 hidden hidden
run_writer
[[ "$(<"$journal")" == "hidden:$old_owner:3" ]]
publish "$old_owner" 4 closed hidden
run_writer
assert_state hidden
[[ ! -e "$journal" ]]

printf 'bar state writer ordering checks passed\n'
