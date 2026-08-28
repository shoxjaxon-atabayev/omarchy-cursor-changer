#!/bin/bash

# Exercises the plugin's persisted state contract (omarchy-cursor-changer-state)
# and the post-boot reapply hook in isolation from apply.

set -uo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

STATE_CMD="$ROOT/bin/omarchy-cursor-changer-state"
HOOK="$ROOT/bin/omarchy-cursor-changer-reapply.hook"
FAKES_DIR="$ROOT/test/shell/fakes"

ccx_sandbox_setup

export CCX_TEST_LOG="$ccx_sandbox_dir/fake-log"
mkdir -p "$CCX_TEST_LOG"
export PATH="$FAKES_DIR:$PATH"

STATE_DIR="$XDG_STATE_HOME/omarchy/cursor-changer"
STATE_FILE="$STATE_DIR/state.json"
mkdir -p "$STATE_DIR"

# --- missing state: reported cleanly, not an error ------------------------
rm -f "$STATE_FILE"
out=$("$STATE_CMD") || fail "reading state must not fail when no state file exists"
assert_equal "$(jq -r '.hasState' <<<"$out")" "false" "missing state file reports hasState=false"
assert_equal "$(jq -r '.theme' <<<"$out")" "null" "missing state file reports theme=null"

# --- state creation + reading ---------------------------------------------
jq -n '{theme: "Adwaita", dir: "/usr/share/icons/Adwaita", size: 24, appliedAt: "2026-01-01T00:00:00Z"}' \
  >"$STATE_FILE"
out=$("$STATE_CMD")
assert_equal "$(jq -r '.hasState' <<<"$out")" "true" "a written state file reports hasState=true"
assert_equal "$(jq -r '.theme' <<<"$out")" "Adwaita" "state reading returns the persisted theme"
assert_equal "$(jq -r '.dir' <<<"$out")" "/usr/share/icons/Adwaita" "state reading returns the persisted dir"
assert_equal "$(jq -r '.size' <<<"$out")" "24" "state reading returns the persisted size"

# --- corrupted state: reported cleanly, not a crash -----------------------
printf '{not valid json' >"$STATE_FILE"
out=$("$STATE_CMD") || fail "reading a corrupted state file must not crash"
assert_equal "$(jq -r '.hasState' <<<"$out")" "false" "a corrupted state file reports hasState=false rather than crashing"

# --- post-boot hook: missing state file is a silent no-op ----------------
rm -f "$STATE_FILE"
rm -f "$CCX_TEST_LOG/hyprctl.calls"
bash "$HOOK"
assert_equal "$?" "0" "the post-boot hook exits 0 when no state file exists"
[[ ! -f "$CCX_TEST_LOG/hyprctl.calls" ]] && pass "the post-boot hook never calls hyprctl with no state file" ||
  fail "the post-boot hook never calls hyprctl with no state file"

# --- post-boot hook: corrupted state file is a silent no-op ---------------
printf 'not json at all' >"$STATE_FILE"
rm -f "$CCX_TEST_LOG/hyprctl.calls"
bash "$HOOK"
assert_equal "$?" "0" "the post-boot hook exits 0 when the state file is corrupted"
[[ ! -f "$CCX_TEST_LOG/hyprctl.calls" ]] && pass "the post-boot hook never calls hyprctl with a corrupted state file" ||
  fail "the post-boot hook never calls hyprctl with a corrupted state file"

# --- post-boot hook: valid state reapplies via hyprctl --------------------
jq -n '{theme: "Yaru", dir: "/usr/share/icons/Yaru", size: 32, appliedAt: "2026-01-01T00:00:00Z"}' \
  >"$STATE_FILE"
rm -f "$CCX_TEST_LOG/hyprctl.calls"
bash "$HOOK"
assert_equal "$?" "0" "the post-boot hook exits 0 on successful reapply"
assert_equal "$(cat "$CCX_TEST_LOG/hyprctl.cursor")" "Yaru 32" \
  "the post-boot hook reapplies the persisted theme and size via hyprctl setcursor"

# --- post-boot hook: hyprctl failing still exits 0 (never breaks the boot
# hook chain, per omarchy's hook contract) --------------------------------
export CCX_TEST_HYPRCTL_FAIL=1
bash "$HOOK"
assert_equal "$?" "0" "the post-boot hook exits 0 even if hyprctl itself fails"
unset CCX_TEST_HYPRCTL_FAIL

echo "All persistence/post-boot tests passed."
