#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

RESOLVE="$ROOT/bin/omarchy-cursor-changer-resolve"

ccx_sandbox_setup

# --- valid index.theme: Name= and Inherits= are parsed --------------------
make_fake_theme "$XDG_DATA_HOME/icons/Child" "Child" "Parent" left_ptr
make_fake_theme "$XDG_DATA_HOME/icons/Parent" "Parent" "" left_ptr text
out=$("$RESOLVE" "$XDG_DATA_HOME/icons/Child")
assert_equal "$(jq -r '.name' <<<"$out")" "Child" "valid index.theme: Name= is parsed"
assert_equal "$(jq -r '.inherits | join(",")' <<<"$out")" "Parent" "valid index.theme: Inherits= is parsed"

# --- missing index.theme: falls back to directory name, no inheritance ---
mkdir -p "$XDG_DATA_HOME/icons/Bare/cursors"
printf 'fake' >"$XDG_DATA_HOME/icons/Bare/cursors/left_ptr"
out=$("$RESOLVE" "$XDG_DATA_HOME/icons/Bare")
assert_equal "$(jq -r '.name' <<<"$out")" "Bare" "missing index.theme falls back to directory name"
assert_equal "$(jq -r '.inherits | length' <<<"$out")" "0" "missing index.theme has no inheritance"

# --- inheritance: a role missing in the child resolves from the parent --
# Child only ships left_ptr; Parent ships left_ptr + grab (openhand alias).
make_fake_theme "$XDG_DATA_HOME/icons/ChildNoGrab" "ChildNoGrab" "GrabParent" left_ptr
make_fake_theme "$XDG_DATA_HOME/icons/GrabParent" "GrabParent" "" left_ptr openhand
out=$("$RESOLVE" "$XDG_DATA_HOME/icons/ChildNoGrab")
assert_equal "$(jq -r '.roles.grab' <<<"$out")" "$XDG_DATA_HOME/icons/GrabParent/cursors/openhand" \
  "a role missing from the child resolves from an inherited parent"
assert_equal "$(jq -r '.missingRoles | index("grab")' <<<"$out")" "null" \
  "a role resolved via inheritance is not reported missing"

# --- circular inheritance: A -> B -> A does not hang and does not crash --
make_fake_theme "$XDG_DATA_HOME/icons/CircA" "CircA" "CircB" left_ptr
make_fake_theme "$XDG_DATA_HOME/icons/CircB" "CircB" "CircA" left_ptr
out=$(timeout 5 "$RESOLVE" "$XDG_DATA_HOME/icons/CircA") ||
  fail "circular Inherits= must not hang or crash"
assert_equal "$(jq -r '.searchChain | length' <<<"$out")" "2" \
  "circular inheritance visits each theme exactly once"
assert_equal "$(jq -r '.name' <<<"$out")" "CircA" "circular inheritance still resolves the requested theme's own name"

# --- missing cursor: a role no alias can resolve falls back to pointer --
# This theme ships only left_ptr, so every other role is unresolvable.
mkdir -p "$XDG_DATA_HOME/icons/PointerOnly/cursors"
printf 'fake' >"$XDG_DATA_HOME/icons/PointerOnly/cursors/left_ptr"
echo -e "[Icon Theme]\nName=PointerOnly" >"$XDG_DATA_HOME/icons/PointerOnly/index.theme"
out=$("$RESOLVE" "$XDG_DATA_HOME/icons/PointerOnly")
assert_equal "$(jq -r '.missingRoles | any(. == "wait")' <<<"$out")" "true" \
  "an unresolvable role is reported in missingRoles"
assert_equal "$(jq -r '.roles.wait' <<<"$out")" "$XDG_DATA_HOME/icons/PointerOnly/cursors/left_ptr" \
  "an unresolvable role falls back to the theme's own pointer cursor rather than a blank slot"

# --- aliases: a theme using alternate filenames still resolves each role -
make_fake_theme "$XDG_DATA_HOME/icons/AliasTheme" "AliasTheme" "" \
  default xterm hand2 watch sb_h_double_arrow sb_v_double_arrow fd_double_arrow openhand dnd-move
out=$("$RESOLVE" "$XDG_DATA_HOME/icons/AliasTheme")
assert_equal "$(jq -r '.roles.pointer | endswith("/default")' <<<"$out")" "true" "alias: pointer resolves via 'default'"
assert_equal "$(jq -r '.roles.text | endswith("/xterm")' <<<"$out")" "true" "alias: text resolves via 'xterm'"
assert_equal "$(jq -r '.roles.link | endswith("/hand2")' <<<"$out")" "true" "alias: link resolves via 'hand2'"
assert_equal "$(jq -r '.roles.wait | endswith("/watch")' <<<"$out")" "true" "alias: wait resolves via 'watch'"
assert_equal "$(jq -r '.roles["resize-horizontal"] | endswith("/sb_h_double_arrow")' <<<"$out")" "true" \
  "alias: resize-horizontal resolves via 'sb_h_double_arrow'"
assert_equal "$(jq -r '.roles["resize-vertical"] | endswith("/sb_v_double_arrow")' <<<"$out")" "true" \
  "alias: resize-vertical resolves via 'sb_v_double_arrow'"
assert_equal "$(jq -r '.roles["resize-diagonal"] | endswith("/fd_double_arrow")' <<<"$out")" "true" \
  "alias: resize-diagonal resolves via 'fd_double_arrow'"
assert_equal "$(jq -r '.roles.grab | endswith("/openhand")' <<<"$out")" "true" "alias: grab resolves via 'openhand'"
assert_equal "$(jq -r '.roles.grabbing | endswith("/dnd-move")' <<<"$out")" "true" "alias: grabbing resolves via 'dnd-move'"
assert_equal "$(jq -r '.missingRoles | length' <<<"$out")" "0" "a theme with full alias coverage reports no missing roles"

echo "All parsing/inheritance tests passed."
