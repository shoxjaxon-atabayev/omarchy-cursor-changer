#!/bin/bash

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "source test/shell/base-test.sh from a shell test; do not run it directly" >&2
  exit 1
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export ROOT

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

require_command() {
  local command="$1"
  command -v "$command" >/dev/null || fail "required command is available: $command"
}

assert_equal() {
  local actual="$1" expected="$2" description="$3"
  [[ $actual == "$expected" ]] || fail "$description" "$(printf 'expected: %s\nactual:   %s' "$expected" "$actual")"
  pass "$description"
}

assert_json_equal() {
  local actual_json="$1" expected_json="$2" description="$3"
  local a e
  a=$(jq -cS . <<<"$actual_json" 2>/dev/null) || fail "$description" "not valid JSON: $actual_json"
  e=$(jq -cS . <<<"$expected_json")
  [[ $a == "$e" ]] || fail "$description" "$(printf 'expected: %s\nactual:   %s' "$e" "$a")"
  pass "$description"
}

# Build a minimal fake cursor theme under $1 with Name=$2, optional
# Inherits=$3, and cursor files named by the remaining args (default: left_ptr).
make_fake_theme() {
  local dir="$1" name="$2" inherits="${3:-}"
  shift 3 2>/dev/null || shift $#
  local cursor_names=("$@")
  (( ${#cursor_names[@]} == 0 )) && cursor_names=(left_ptr)

  mkdir -p "$dir/cursors"
  {
    echo "[Icon Theme]"
    echo "Name=$name"
    [[ -n $inherits ]] && echo "Inherits=$inherits"
  } >"$dir/index.theme"

  local cname
  for cname in "${cursor_names[@]}"; do
    # A real Xcursor file is not required for discovery/parsing tests; only
    # the preview renderer cares about file contents.
    printf 'fake-xcursor-data' >"$dir/cursors/$cname"
  done
}

# Run a command with a sandboxed HOME/XDG environment so tests never touch
# the real system's icon directories or state/cache.
ccx_sandbox_dir=""

ccx_sandbox_setup() {
  ccx_sandbox_dir=$(mktemp -d)
  mkdir -p "$ccx_sandbox_dir/home/.icons" \
    "$ccx_sandbox_dir/home/.local/share/icons" \
    "$ccx_sandbox_dir/data/icons" \
    "$ccx_sandbox_dir/home/.local/state" \
    "$ccx_sandbox_dir/home/.cache"

  export HOME="$ccx_sandbox_dir/home"
  export XDG_DATA_HOME="$ccx_sandbox_dir/home/.local/share"
  export XDG_DATA_DIRS="$ccx_sandbox_dir/data"
  export XDG_STATE_HOME="$ccx_sandbox_dir/home/.local/state"
  export XDG_CACHE_HOME="$ccx_sandbox_dir/home/.cache"
  export XDG_RUNTIME_DIR="$ccx_sandbox_dir/runtime"
  mkdir -p "$XDG_RUNTIME_DIR"
}

ccx_sandbox_teardown() {
  [[ -n $ccx_sandbox_dir && -d $ccx_sandbox_dir ]] && rm -rf "$ccx_sandbox_dir"
}

trap ccx_sandbox_teardown EXIT
