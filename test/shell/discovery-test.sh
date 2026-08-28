#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

DISCOVER="$ROOT/bin/omarchy-cursor-changer-discover"

ccx_sandbox_setup

# --- user theme is discovered -------------------------------------------
make_fake_theme "$XDG_DATA_HOME/icons/UserOnly" "UserOnly"
out=$("$DISCOVER")
assert_equal "$(jq -r '[.[] | select(.name=="UserOnly")] | length' <<<"$out")" "1" \
  "user-only theme is discovered"
assert_equal "$(jq -r '.[] | select(.name=="UserOnly") | .source' <<<"$out")" "user" \
  "user theme is tagged source=user"

# --- system theme is discovered ------------------------------------------
make_fake_theme "$XDG_DATA_DIRS/icons/SystemOnly" "SystemOnly"
out=$("$DISCOVER")
assert_equal "$(jq -r '.[] | select(.name=="SystemOnly") | .source' <<<"$out")" "system" \
  "system theme is tagged source=system"

# --- duplicate theme: same name in user and system dedupes to one, user wins
make_fake_theme "$XDG_DATA_HOME/icons/Shared" "Shared"
make_fake_theme "$XDG_DATA_DIRS/icons/Shared" "Shared"
out=$("$DISCOVER")
assert_equal "$(jq -r '[.[] | select(.name=="Shared")] | length' <<<"$out")" "1" \
  "duplicate theme name collapses to a single entry"
assert_equal "$(jq -r '.[] | select(.name=="Shared") | .source' <<<"$out")" "user" \
  "duplicate theme keeps the user-installed copy"
assert_equal "$(jq -r '.[] | select(.name=="Shared") | .dir' <<<"$out")" "$XDG_DATA_HOME/icons/Shared" \
  "duplicate theme resolves to the user directory, not the system one"

# --- missing search directory does not error -----------------------------
# Scoped to a subshell so it doesn't disturb the SystemOnly/Shared fixtures
# used by later assertions.
(
  export XDG_DATA_DIRS="$ccx_sandbox_dir/does-not-exist"
  out=$("$DISCOVER") || fail "discover must not error when a search directory is missing"
  assert_equal "$(jq -r '[.[] | select(.name=="UserOnly")] | length' <<<"$out")" "1" \
    "missing system directory does not prevent discovering user themes"
) || exit 1

# --- invalid theme: cursors/ dir exists but is empty ----------------------
mkdir -p "$XDG_DATA_HOME/icons/EmptyCursors/cursors"
echo -e "[Icon Theme]\nName=EmptyCursors" >"$XDG_DATA_HOME/icons/EmptyCursors/index.theme"
out=$("$DISCOVER")
assert_equal "$(jq -r '[.[] | select(.name=="EmptyCursors")] | length' <<<"$out")" "0" \
  "a theme with an empty cursors/ dir is not treated as a real cursor theme"

# --- invalid theme: index.theme exists but no cursors/ dir at all --------
mkdir -p "$XDG_DATA_HOME/icons/IconOnly"
echo -e "[Icon Theme]\nName=IconOnly" >"$XDG_DATA_HOME/icons/IconOnly/index.theme"
out=$("$DISCOVER")
assert_equal "$(jq -r '[.[] | select(.name=="IconOnly")] | length' <<<"$out")" "0" \
  "an icon-only theme (no cursors/ dir) is excluded"

# --- theme without index.theme falls back to directory basename ----------
mkdir -p "$XDG_DATA_HOME/icons/NoMetadata/cursors"
printf 'fake' >"$XDG_DATA_HOME/icons/NoMetadata/cursors/left_ptr"
out=$("$DISCOVER")
assert_equal "$(jq -r '.[] | select(.dir | endswith("NoMetadata")) | .name' <<<"$out")" "NoMetadata" \
  "a theme without index.theme falls back to its directory name"
assert_equal "$(jq -r '.[] | select(.dir | endswith("NoMetadata")) | .hasIndexTheme' <<<"$out")" "false" \
  "hasIndexTheme is false when index.theme is absent"

# --- deterministic ordering: user before system, then alphabetical -------
out=$("$DISCOVER")
names=$(jq -r '.[].name' <<<"$out")
first_system_line=$(jq -r 'to_entries[] | select(.value.source=="system") | .key' <<<"$out" | head -n1)
last_user_line=$(jq -r 'to_entries[] | select(.value.source=="user") | .key' <<<"$out" | tail -n1)
[[ -n $first_system_line && -n $last_user_line ]] && (( last_user_line < first_system_line )) ||
  fail "all user themes sort before all system themes"
pass "all user themes sort before all system themes"

out2=$("$DISCOVER")
assert_equal "$out" "$out2" "discovery output is stable across repeated runs"

echo "All discovery tests passed."
