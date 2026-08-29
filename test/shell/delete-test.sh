#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

DELETE="$ROOT/bin/omarchy-cursor-changer-delete"
DISCOVER="$ROOT/bin/omarchy-cursor-changer-discover"

ccx_sandbox_setup

STATE_DIR="$XDG_STATE_HOME/omarchy/cursor-changer"
mkdir -p "$STATE_DIR"

# --- deleting a real user theme succeeds ----------------------------------
make_fake_theme "$XDG_DATA_HOME/icons/UserTheme" "UserTheme"
out=$("$DELETE" UserTheme)
assert_equal "$(jq -r '.deleted' <<<"$out")" "true" "deleting a user theme succeeds"
[[ ! -d "$XDG_DATA_HOME/icons/UserTheme" ]] && pass "the theme directory is actually removed" ||
  fail "the theme directory is actually removed"

# --- a deleted theme is no longer discoverable ----------------------------
make_fake_theme "$XDG_DATA_HOME/icons/ToRemove" "ToRemove"
"$DELETE" ToRemove >/dev/null
names=$(XDG_DATA_DIRS="$ccx_sandbox_dir/does-not-exist" "$DISCOVER" | jq -r '.[].name')
[[ $names != *"ToRemove"* ]] && pass "a deleted theme is no longer discovered" ||
  fail "a deleted theme is no longer discovered"

# --- system themes are refused, never deleted -----------------------------
if [[ -d /usr/share/icons/Adwaita ]]; then
  if "$DELETE" /usr/share/icons/Adwaita 2>/tmp/ccx-delete-system-err; then
    fail "deleting a system theme should be refused"
  else
    pass "deleting a system theme is refused"
  fi
  [[ -d /usr/share/icons/Adwaita ]] && pass "the real system theme is untouched" ||
    fail "the real system theme is untouched"
  rm -f /tmp/ccx-delete-system-err
else
  pass "system theme refusal test skipped (Adwaita not installed on this machine)"
fi

# --- the currently active theme is refused, not deleted -------------------
make_fake_theme "$XDG_DATA_HOME/icons/ActiveTheme" "ActiveTheme"
jq -n --arg dir "$XDG_DATA_HOME/icons/ActiveTheme" \
  '{theme: "ActiveTheme", dir: $dir, size: 24, appliedAt: "2026-01-01T00:00:00Z"}' \
  >"$STATE_DIR/state.json"
if "$DELETE" ActiveTheme 2>/tmp/ccx-delete-active-err; then
  fail "deleting the currently active theme should be refused"
else
  pass "deleting the currently active theme is refused"
fi
grep -qi "active" /tmp/ccx-delete-active-err && pass "the active-theme refusal error is clear" ||
  fail "the active-theme refusal error is clear"
[[ -d "$XDG_DATA_HOME/icons/ActiveTheme" ]] && pass "the active theme's directory is left in place" ||
  fail "the active theme's directory is left in place"
rm -f /tmp/ccx-delete-active-err
rm -f "$STATE_DIR/state.json"

# --- a non-active user theme can still be deleted while another is active
make_fake_theme "$XDG_DATA_HOME/icons/OtherTheme" "OtherTheme"
jq -n --arg dir "$XDG_DATA_HOME/icons/ActiveTheme" \
  '{theme: "ActiveTheme", dir: $dir, size: 24, appliedAt: "2026-01-01T00:00:00Z"}' \
  >"$STATE_DIR/state.json"
out=$("$DELETE" OtherTheme)
assert_equal "$(jq -r '.deleted' <<<"$out")" "true" "a non-active user theme can be deleted while a different theme is active"

# --- nonexistent theme is refused cleanly ---------------------------------
if "$DELETE" DoesNotExist 2>/dev/null; then
  fail "deleting a nonexistent theme should be refused"
else
  pass "deleting a nonexistent theme is refused"
fi

echo "All delete tests passed."
