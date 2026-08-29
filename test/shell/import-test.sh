#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command tar

IMPORT="$ROOT/bin/omarchy-cursor-changer-import"
DISCOVER="$ROOT/bin/omarchy-cursor-changer-discover"

ccx_sandbox_setup
work="$ccx_sandbox_dir/work"
mkdir -p "$work"
cd "$work"

# --- plain directory import ------------------------------------------------
mkdir -p PlainDir/cursors
printf 'fake' >PlainDir/cursors/left_ptr
out=$("$IMPORT" PlainDir)
assert_equal "$(jq -r '.imported' <<<"$out")" "true" "importing a plain theme directory succeeds"
[[ -d "$XDG_DATA_HOME/icons/PlainDir/cursors" ]] && pass "the imported directory lands under \$XDG_DATA_HOME/icons" ||
  fail "the imported directory lands under \$XDG_DATA_HOME/icons"

# --- tar.gz with a wrapper folder (the common "downloaded pack" shape) ---
mkdir -p WrapperSrc/MyPack/cursors
echo -e "[Icon Theme]\nName=MyPack" >WrapperSrc/MyPack/index.theme
printf 'fake' >WrapperSrc/MyPack/cursors/left_ptr
tar -czf mypack.tar.gz -C WrapperSrc MyPack
out=$("$IMPORT" mypack.tar.gz)
assert_equal "$(jq -r '.imported' <<<"$out")" "true" "importing a .tar.gz with a wrapper folder succeeds"
assert_equal "$(jq -r '.name' <<<"$out")" "MyPack" "the imported name comes from the theme's own index.theme, not the archive filename"
[[ -d "$XDG_DATA_HOME/icons/MyPack/cursors" ]] && pass "the wrapper folder is unwrapped; only the theme dir is installed" ||
  fail "the wrapper folder is unwrapped; only the theme dir is installed"

# --- tar.xz, no wrapper (cursors/ at archive root) -------------------------
mkdir -p FlatSrc/cursors
printf 'fake' >FlatSrc/cursors/left_ptr
tar -cJf flat.tar.xz -C FlatSrc .
out=$("$IMPORT" flat.tar.xz)
assert_equal "$(jq -r '.imported' <<<"$out")" "true" "importing a .tar.xz with cursors/ at the archive root succeeds"

# --- double-nested wrapper (a real-world shape: Pack/Pack/cursors/, with a
# README/screenshot sitting alongside at the outer level) ------------------
mkdir -p DoubleWrap/DoubleWrap/DoubleWrap/cursors
echo -e "[Icon Theme]\nName=DoubleWrap" >DoubleWrap/DoubleWrap/DoubleWrap/index.theme
printf 'fake' >DoubleWrap/DoubleWrap/DoubleWrap/cursors/left_ptr
echo "not a cursor" >DoubleWrap/ReadMe.txt
tar -czf doublewrap.tar.gz DoubleWrap
out=$("$IMPORT" doublewrap.tar.gz)
assert_equal "$(jq -r '.imported' <<<"$out")" "true" "importing a theme nested two levels deep succeeds"
assert_equal "$(jq -r '.name' <<<"$out")" "DoubleWrap" "a doubly-nested theme still resolves its declared name"

# --- zip, if available ------------------------------------------------------
if command -v zip >/dev/null; then
  mkdir -p ZipSrc/cursors
  printf 'fake' >ZipSrc/cursors/left_ptr
  echo -e "[Icon Theme]\nName=ZipTheme" >ZipSrc/index.theme
  (cd ZipSrc && zip -qr ../ziptheme.zip .)
  out=$("$IMPORT" ziptheme.zip)
  assert_equal "$(jq -r '.imported' <<<"$out")" "true" "importing a .zip succeeds"
else
  pass "zip import test skipped (zip command not available to build a fixture)"
fi

# --- duplicate name is refused, not silently overwritten -------------------
if "$IMPORT" PlainDir 2>/tmp/ccx-import-dup-err; then
  fail "importing a theme whose name already exists should be refused"
else
  pass "importing a theme whose name already exists is refused"
fi
grep -qi "already exists" /tmp/ccx-import-dup-err && pass "the duplicate-name error is clear" ||
  fail "the duplicate-name error is clear"
rm -f /tmp/ccx-import-dup-err

# --- invalid archive: no cursors/ anywhere inside --------------------------
mkdir -p NotACursorPack
echo "just some text" >NotACursorPack/readme.txt
tar -czf notacursor.tar.gz NotACursorPack
if "$IMPORT" notacursor.tar.gz 2>/tmp/ccx-import-invalid-err; then
  fail "importing an archive with no cursor theme inside should be refused"
else
  pass "importing an archive with no cursor theme inside is refused"
fi
rm -f /tmp/ccx-import-invalid-err

# --- unrecognized file type --------------------------------------------------
echo "not an archive" >plain.txt
if "$IMPORT" plain.txt 2>/dev/null; then
  fail "importing an unrecognized file type should be refused"
else
  pass "importing an unrecognized file type is refused"
fi

# --- nonexistent source path -------------------------------------------------
if "$IMPORT" /does/not/exist.tar.gz 2>/dev/null; then
  fail "importing a nonexistent path should be refused"
else
  pass "importing a nonexistent path is refused"
fi

# --- imported themes are then discoverable ----------------------------------
out=$(XDG_DATA_DIRS="$ccx_sandbox_dir/data" "$DISCOVER")
names=$(jq -r '.[].name' <<<"$out")
for expected in PlainDir MyPack; do
  [[ $names == *"$expected"* ]] && pass "imported theme '$expected' is discoverable afterward" ||
    fail "imported theme '$expected' is discoverable afterward" "got: $names"
done

echo "All import tests passed."
