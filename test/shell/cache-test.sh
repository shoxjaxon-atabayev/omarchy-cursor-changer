#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command python3

if [[ ! -f /usr/share/icons/Adwaita/cursors/left_ptr ]]; then
  echo "Adwaita cursor theme not found on this machine; skipping cache-test.sh." >&2
  exit 0
fi

PREVIEW="$ROOT/bin/omarchy-cursor-changer-preview"

ccx_sandbox_setup

mkdir -p "$ccx_sandbox_dir/theme/cursors"
cp /usr/share/icons/Adwaita/cursors/left_ptr "$ccx_sandbox_dir/theme/cursors/left_ptr"
printf '[Icon Theme]\nName=CacheTest\n' >"$ccx_sandbox_dir/theme/index.theme"

# --- first call renders and caches ---------------------------------------
cache_dir="$XDG_CACHE_HOME/omarchy/cursor-changer/previews"
[[ -d $cache_dir ]] && [[ -z $(ls -A "$cache_dir" 2>/dev/null) || ! -d $cache_dir ]]
first=$("$PREVIEW" "$ccx_sandbox_dir/theme")
[[ -f $first ]] && pass "first call renders and returns an existing PNG path" ||
  fail "first call renders and returns an existing PNG path"
before_count=$(find "$cache_dir" -type f -name '*.png' | wc -l)
assert_equal "$before_count" "1" "exactly one cache entry exists after the first call"

# --- repeated calls reuse the cache, do not re-render --------------------
before_mtime=$(stat -c '%Y' "$first")
sleep 1.1
second=$("$PREVIEW" "$ccx_sandbox_dir/theme")
assert_equal "$second" "$first" "a second call for the same theme returns the same cache path"
after_mtime=$(stat -c '%Y' "$first")
assert_equal "$after_mtime" "$before_mtime" "a cache hit does not rewrite the cached file"
after_count=$(find "$cache_dir" -type f -name '*.png' | wc -l)
assert_equal "$after_count" "1" "a cache hit does not create a second cache entry"

# --- distinct themes never collide on the same cache key ----------------
mkdir -p "$ccx_sandbox_dir/theme2/cursors"
cp /usr/share/icons/Adwaita/cursors/text "$ccx_sandbox_dir/theme2/cursors/left_ptr"
printf '[Icon Theme]\nName=CacheTestOther\n' >"$ccx_sandbox_dir/theme2/index.theme"
third=$("$PREVIEW" "$ccx_sandbox_dir/theme2")
[[ $third != "$first" ]] && pass "a different theme gets a different cache entry (no collision)" ||
  fail "a different theme gets a different cache entry (no collision)"

# --- invalidation: changing the source cursor file busts the cache -------
sleep 1.1
touch "$ccx_sandbox_dir/theme/cursors/left_ptr"
fourth=$("$PREVIEW" "$ccx_sandbox_dir/theme")
[[ $fourth != "$first" ]] && pass "touching a source cursor file invalidates the cache (new key)" ||
  fail "touching a source cursor file invalidates the cache (new key)"
[[ -f $fourth ]] && pass "the invalidated cache entry is regenerated" ||
  fail "the invalidated cache entry is regenerated"

# --- unresolvable theme is a clean error, not a crash --------------------
if "$PREVIEW" "/does/not/exist-theme" 2>/tmp/ccx-preview-err; then
  fail "a nonexistent theme should fail cleanly"
else
  pass "a nonexistent theme fails cleanly rather than crashing"
fi
rm -f /tmp/ccx-preview-err

echo "All preview cache tests passed."
