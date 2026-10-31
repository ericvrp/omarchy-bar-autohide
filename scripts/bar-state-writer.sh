set -euo pipefail

runtime_dir="$1"
current_owner_file="$2"
journal_file="$3"
lock_file="$4"
bar_off_file="$5"
operation_file="$6"
acknowledgement_file="$7"

exec 9>"$lock_file"
flock -x 9

sync_bar() {
  if command -v omarchy-shell >/dev/null 2>&1; then
    omarchy-shell -q omarchy.bar syncHidden
  fi
}

write_flag() {
  if [[ "$1" == hidden ]]; then
    mkdir -p -- "$(dirname -- "$bar_off_file")"
    touch -- "$bar_off_file"
  else
    rm -f -- "$bar_off_file"
  fi
}

wait_for_acknowledgement() {
  local token="$1"
  for attempt in {1..500}; do
    [[ "$(cat -- "$acknowledgement_file" 2>/dev/null || true)" == "$token" ]] && return 0
    # An unloaded service cannot acknowledge a probe. Let its final request
    # restore the baseline instead of blocking cleanup behind its own callback.
    local live_owner live_request
    live_owner="$(cat -- "$current_owner_file" 2>/dev/null || true)"
    live_request="$(cat -- "$runtime_dir/ericvrp.bar-autohide.$live_owner.intent" 2>/dev/null || true)"
    [[ "$live_owner" != "$owner" || "$live_request" != *:closed:* ]] || return 0
    (( attempt % 10 != 0 )) || sync_bar
    sleep 0.01
  done
  echo "bar-autohide: timed out waiting for the bar visibility probe" >&2
  return 1
}

wait_for_previous_operation() {
  local operation token prior_owner prior_revision prior_pid prior_state phase
  operation="$(cat -- "$operation_file" 2>/dev/null || true)"
  IFS=: read -r prior_owner prior_revision prior_pid prior_state phase <<< "$operation"
  [[ "$phase" == preparing || "$phase" == closing-preparing \
    || "$phase" == waiting || "$phase" == closing \
    || "$phase" == noop || "$phase" == closing-noop ]] || return 0
  [[ "$prior_owner" =~ ^[[:xdigit:]]{32}$ && "$prior_revision" =~ ^[0-9]+$ \
    && "$prior_pid" =~ ^[0-9]+$ \
    && ("$prior_state" == hidden || "$prior_state" == visible) ]] || {
      echo "bar-autohide: malformed operation record" >&2
      return 1
    }
  token="${operation%:*}"
  if [[ "$phase" == noop || "$phase" == closing-noop ]]; then
    printf '%s\n' "$token" > "${acknowledgement_file}.tmp.$$"
    mv -f -- "${acknowledgement_file}.tmp.$$" "$acknowledgement_file"
    return 0
  fi
  [[ "$(cat -- "$acknowledgement_file" 2>/dev/null || true)" == "$token" ]] && return 0
  # A failed write, or a manual toggle while the previous owner was disabled,
  # can leave the flag different from an unacknowledged operation. Replay it
  # before advancing: otherwise no matching visibility signal can ever arrive.
  write_flag "$prior_state"
  phase=waiting
  printf '%s:%s\n' "$token" "$phase" > "${operation_file}.tmp.$$"
  mv -f -- "${operation_file}.tmp.$$" "$operation_file"
  sync_bar
  wait_for_acknowledgement "$token"
}

while :; do
  owner="$(cat -- "$current_owner_file" 2>/dev/null || true)"
  [[ "$owner" =~ ^[[:xdigit:]]{32}$ ]] || exit 0
  intent_file="$runtime_dir/ericvrp.bar-autohide.$owner.intent"
  request="$(cat -- "$intent_file" 2>/dev/null || true)"
  IFS=: read -r revision state _observed_state <<< "$request"
  [[ "$revision" =~ ^[0-9]+$ ]] || exit 0

  case "$state" in
    hidden|visible)
      if [[ ! -f "$journal_file" ]]; then
        baseline=visible
        [[ ! -e "$bar_off_file" ]] || baseline=hidden
        journal_tmp="${journal_file}.tmp.$$"
        printf '%s::\n' "$baseline" > "$journal_tmp"
        mv -f -- "$journal_tmp" "$journal_file"
      fi
      IFS=: read -r baseline applied_owner applied_revision < "$journal_file"
      [[ "$baseline" == hidden || "$baseline" == visible ]] || exit 1
      [[ -z "$applied_owner" || "$applied_owner" =~ ^[[:xdigit:]]{32}$ ]] || exit 1
      [[ -z "$applied_revision" || "$applied_revision" =~ ^[0-9]+$ ]] || exit 1

      if [[ "$applied_owner" != "$owner" || "$applied_revision" != "$revision" ]]; then
        wait_for_previous_operation
        token="$owner:$revision:$$:$state"
        phase=preparing
        if [[ "$state" == hidden && -e "$bar_off_file" ]] \
            || [[ "$state" == visible && ! -e "$bar_off_file" ]]; then
          phase=noop
        fi
        operation_tmp="${operation_file}.tmp.$$"
        printf '%s:%s\n' "$token" "$phase" > "$operation_tmp"
        mv -f -- "$operation_tmp" "$operation_file"
        if [[ "$phase" == noop ]]; then
          printf '%s\n' "$token" > "${acknowledgement_file}.tmp.$$"
          mv -f -- "${acknowledgement_file}.tmp.$$" "$acknowledgement_file"
        else
          write_flag "$state"
          printf '%s:waiting\n' "$token" > "${operation_file}.tmp.$$"
          mv -f -- "${operation_file}.tmp.$$" "$operation_file"
          sync_bar
          wait_for_acknowledgement "$token"
        fi
        journal_tmp="${journal_file}.tmp.$$"
        printf '%s:%s:%s\n' "$baseline" "$owner" "$revision" > "$journal_tmp"
        mv -f -- "$journal_tmp" "$journal_file"
      fi
      ;;
    closed)
      if [[ -f "$journal_file" ]]; then
        wait_for_previous_operation
        IFS=: read -r baseline _ _ < "$journal_file"
        [[ "$baseline" == hidden || "$baseline" == visible ]] || exit 1
        token="$owner:$revision:$$:$baseline"
        phase=closing-preparing
        if [[ "$baseline" == hidden && -e "$bar_off_file" ]] \
            || [[ "$baseline" == visible && ! -e "$bar_off_file" ]]; then
          phase=closing-noop
        fi
        operation_tmp="${operation_file}.tmp.$$"
        printf '%s:%s\n' "$token" "$phase" > "$operation_tmp"
        mv -f -- "$operation_tmp" "$operation_file"
        if [[ "$phase" == closing-noop ]]; then
          printf '%s\n' "$token" > "${acknowledgement_file}.tmp.$$"
          mv -f -- "${acknowledgement_file}.tmp.$$" "$acknowledgement_file"
        else
          write_flag "$baseline"
          printf '%s:closing\n' "$token" > "${operation_file}.tmp.$$"
          mv -f -- "${operation_file}.tmp.$$" "$operation_file"
          sync_bar
        fi
        rm -f -- "$journal_file"
      fi
      ;;
    *)
      exit 0
      ;;
  esac

  latest_owner="$(cat -- "$current_owner_file" 2>/dev/null || true)"
  latest_request="$(cat -- "$intent_file" 2>/dev/null || true)"
  [[ "$latest_owner" != "$owner" || "$latest_request" != "$request" ]] || exit 0
done
