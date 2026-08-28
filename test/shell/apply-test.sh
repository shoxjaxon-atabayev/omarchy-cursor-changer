#!/bin/bash

# Exercises omarchy-cursor-changer-apply against fake hyprctl/gsettings
# (test doubles under fakes/), so this suite never touches the real
# Hyprland session or the real dconf database, even though this machine
# happens to have both running live.

set -uo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

APPLY="$ROOT/bin/omarchy-cursor-changer-apply"
FAKES_DIR="$ROOT/test/shell/fakes"

ccx_sandbox_setup

export CCX_TEST_LOG="$ccx_sandbox_dir/fake-log"
mkdir -p "$CCX_TEST_LOG"
export PATH="$FAKES_DIR:$PATH"
unset CCX_TEST_HYPRCTL_FAIL CCX_TEST_GSETTINGS_SET_FAIL CCX_TEST_GSETTINGS_VERIFY_MISMATCH

STATE_FILE="$XDG_STATE_HOME/omarchy/cursor-changer/state.json"

make_fake_theme "$XDG_DATA_HOME/icons/ThemeA" "ThemeA"
make_fake_theme "$XDG_DATA_HOME/icons/ThemeB" "ThemeB"

reset_fake_log() {
  rm -rf "$CCX_TEST_LOG"
  mkdir -p "$CCX_TEST_LOG"
}

# --- valid theme: apply succeeds end-to-end -------------------------------
reset_fake_log
out=$("$APPLY" ThemeA) || fail "apply of a valid theme should succeed"
assert_equal "$(jq -r '.applied' <<<"$out")" "true" "valid theme apply reports applied=true"
assert_equal "$(cat "$CCX_TEST_LOG/hyprctl.cursor")" "ThemeA 24" \
  "hyprctl setcursor was called with the resolved theme name and default size"
assert_equal "$(grep '^cursor-theme=' "$CCX_TEST_LOG/gsettings.store" | tail -1)" "cursor-theme=ThemeA" \
  "gsettings cursor-theme was set to the applied theme"
assert_equal "$(jq -r '.theme' "$STATE_FILE")" "ThemeA" "state file records the applied theme"
hook_dst="$HOME/.config/omarchy/hooks/post-boot.d/omarchy-cursor-changer-reapply.hook"
[[ -x $hook_dst ]] && pass "post-boot reapply hook is installed and executable" ||
  fail "post-boot reapply hook is installed and executable"

# --- same theme applied again is idempotent -------------------------------
reset_fake_log
out2=$("$APPLY" ThemeA) || fail "re-applying the same theme should succeed"
assert_equal "$(jq -r '.theme' <<<"$out2")" "ThemeA" "re-applying the same theme still reports it as applied"
assert_equal "$(cat "$CCX_TEST_LOG/hyprctl.cursor")" "ThemeA 24" "repeated apply keeps the same hyprctl cursor state"
count=$(grep -c '^cursor-theme=' "$CCX_TEST_LOG/gsettings.store")
assert_equal "$(jq -r '.theme' "$STATE_FILE")" "ThemeA" "state file is unchanged in content after a repeated apply"

# --- switching themes updates both hyprctl and gsettings ------------------
reset_fake_log
"$APPLY" ThemeB >/dev/null || fail "switching to a different valid theme should succeed"
assert_equal "$(cat "$CCX_TEST_LOG/hyprctl.cursor")" "ThemeB 24" "switching themes updates hyprctl's live cursor"
assert_equal "$(grep '^cursor-theme=' "$CCX_TEST_LOG/gsettings.store" | tail -1)" "cursor-theme=ThemeB" \
  "switching themes updates gsettings"
assert_equal "$(jq -r '.theme' "$STATE_FILE")" "ThemeB" "state file reflects the newly switched theme"

# --- invalid/unknown theme is rejected without touching anything ---------
reset_fake_log
if "$APPLY" DoesNotExist >/tmp/ccx-apply-invalid-err 2>&1; then
  fail "applying an unknown theme should fail"
else
  pass "applying an unknown theme fails cleanly"
fi
[[ ! -s "$CCX_TEST_LOG/hyprctl.calls" ]] && pass "an invalid theme never reaches hyprctl" ||
  fail "an invalid theme never reaches hyprctl"
assert_equal "$(jq -r '.theme' "$STATE_FILE")" "ThemeB" "an invalid theme attempt leaves prior state untouched"
rm -f /tmp/ccx-apply-invalid-err

# --- hyprctl failure: no partial state, no gsettings write, no persistence
reset_fake_log
export CCX_TEST_HYPRCTL_FAIL=1
if "$APPLY" ThemeA >/tmp/ccx-apply-hyprctl-err 2>&1; then
  fail "a hyprctl failure should make apply fail"
else
  pass "a hyprctl failure makes apply fail"
fi
unset CCX_TEST_HYPRCTL_FAIL
# Reading old state (a `get`) happens before hyprctl is even attempted, by
# design — only a `set` would mean the toolkit setting was actually changed.
if ! grep -q '^set ' "$CCX_TEST_LOG/gsettings.calls" 2>/dev/null; then
  pass "a hyprctl failure prevents any gsettings write"
else
  fail "a hyprctl failure prevents any gsettings write"
fi
assert_equal "$(jq -r '.theme' "$STATE_FILE")" "ThemeB" "a hyprctl failure leaves the previous state file untouched"
rm -f /tmp/ccx-apply-hyprctl-err

# --- gsettings failure: rolls back hyprctl to the old theme ---------------
reset_fake_log
export CCX_TEST_GSETTINGS_SET_FAIL=1
if "$APPLY" ThemeA >/tmp/ccx-apply-gsettings-err 2>&1; then
  fail "a gsettings failure should make apply fail"
else
  pass "a gsettings failure makes apply fail"
fi
unset CCX_TEST_GSETTINGS_SET_FAIL
assert_equal "$(cat "$CCX_TEST_LOG/hyprctl.cursor")" "ThemeB 24" \
  "a gsettings failure rolls hyprctl back to the previous theme"
assert_equal "$(jq -r '.theme' "$STATE_FILE")" "ThemeB" "a gsettings failure leaves the previous state file untouched"
rm -f /tmp/ccx-apply-gsettings-err

# --- verification failure: both commands "succeed" but re-read mismatches
reset_fake_log
export CCX_TEST_GSETTINGS_VERIFY_MISMATCH="SomethingElse"
if "$APPLY" ThemeA >/tmp/ccx-apply-verify-err 2>&1; then
  fail "a verification mismatch should make apply fail"
else
  pass "a verification mismatch makes apply fail"
fi
unset CCX_TEST_GSETTINGS_VERIFY_MISMATCH
assert_equal "$(cat "$CCX_TEST_LOG/hyprctl.cursor")" "ThemeB 24" \
  "a verification failure rolls hyprctl back to the previous theme"
assert_equal "$(jq -r '.theme' "$STATE_FILE")" "ThemeB" "a verification failure leaves the previous state file untouched"
rm -f /tmp/ccx-apply-verify-err

# --- repeated apply after failures still works (system not left broken) --
reset_fake_log
"$APPLY" ThemeA >/dev/null || fail "apply should still work normally after prior simulated failures"
assert_equal "$(jq -r '.theme' "$STATE_FILE")" "ThemeA" "apply succeeds again once the simulated failures stop"

echo "All apply tests passed."
