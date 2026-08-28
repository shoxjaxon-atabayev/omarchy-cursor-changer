#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3
require_command jq

RENDERER="$ROOT/bin/lib/xcursor_preview.py"

if [[ ! -f /usr/share/icons/Adwaita/cursors/left_ptr ]]; then
  echo "Adwaita cursor theme not found on this machine; skipping preview-test.sh (needs a real XCursor theme)." >&2
  exit 0
fi

png_dims() {
  python3 - "$1" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as f:
    data = f.read()
w, h = struct.unpack(">II", data[16:24])
print(f"{w} {h}")
PY
}

is_valid_png() {
  [[ -f $1 ]] && [[ $(head -c8 "$1" | od -An -tx1 | tr -d ' \n') == "89504e470d0a1a0a" ]]
}

# --- valid XCursor: a real cursor file renders a non-trivial image -------
out="$(mktemp -u).png"
python3 "$RENDERER" '{"pointer":"/usr/share/icons/Adwaita/cursors/left_ptr"}' "$out"
is_valid_png "$out" && pass "a valid XCursor file renders a valid PNG" ||
  fail "a valid XCursor file renders a valid PNG"
dims=$(png_dims "$out")
assert_equal "$dims" "40 40" "a single-role preview is exactly one cell (40x40)"
rm -f "$out"

# --- multiple roles composite into a wider strip, left to right ----------
out="$(mktemp -u).png"
python3 "$RENDERER" \
  '{"pointer":"/usr/share/icons/Adwaita/cursors/left_ptr","text":"/usr/share/icons/Adwaita/cursors/text","wait":"/usr/share/icons/Adwaita/cursors/wait"}' \
  "$out"
dims=$(png_dims "$out")
assert_equal "$dims" "132 40" "three roles composite into a 3-cell strip (3*40 + 2*6 gap)"
rm -f "$out"

# --- multiple nominal sizes: closest-to-target size is used, and a theme
# shipping only a larger size is downsampled rather than left oversized ---
out="$(mktemp -u).png"
python3 "$RENDERER" '{"pointer":"/usr/share/icons/Adwaita/cursors/left_ptr"}' "$out" --target-size 9999
dims=$(png_dims "$out")
assert_equal "$dims" "40 40" "an oversized nominal size is box-downsampled to fit the cell"
rm -f "$out"

# --- animated cursor: frame 0 is used, output is still one static image --
if [[ -f /home/shokh/.local/share/icons/MacOSX/cursors/wait ]]; then
  out="$(mktemp -u).png"
  python3 "$RENDERER" '{"wait":"/home/shokh/.local/share/icons/MacOSX/cursors/wait"}' "$out"
  is_valid_png "$out" && pass "an animated (multi-frame) cursor still renders a single static PNG" ||
    fail "an animated (multi-frame) cursor still renders a single static PNG"
  rm -f "$out"
else
  pass "animated cursor test skipped (MacOSX cursor theme not present on this machine)"
fi

# --- missing role file: skipped, does not abort the whole render ---------
out="$(mktemp -u).png"
python3 "$RENDERER" \
  '{"pointer":"/does/not/exist","text":"/usr/share/icons/Adwaita/cursors/text"}' \
  "$out"
is_valid_png "$out" && pass "a missing role file is skipped without aborting the render" ||
  fail "a missing role file is skipped without aborting the render"
dims=$(png_dims "$out")
assert_equal "$dims" "86 40" "a missing role's cell stays reserved (transparent) rather than collapsing the grid"
rm -f "$out"

# --- fallback / corrupt file: garbage bytes are skipped, not crashed on --
mkdir -p /tmp/ccx-corrupt-test/cursors
printf 'not an xcursor file' >/tmp/ccx-corrupt-test/cursors/left_ptr
out="$(mktemp -u).png"
python3 "$RENDERER" \
  '{"pointer":"/tmp/ccx-corrupt-test/cursors/left_ptr","text":"/usr/share/icons/Adwaita/cursors/text"}' \
  "$out"
is_valid_png "$out" && pass "a corrupt (non-Xcursor) file is skipped without crashing the renderer" ||
  fail "a corrupt (non-Xcursor) file is skipped without crashing the renderer"
rm -rf /tmp/ccx-corrupt-test "$out"

# --- empty role set is a clean error, not a crash -------------------------
out="$(mktemp -u).png"
if python3 "$RENDERER" '{}' "$out" 2>/tmp/ccx-empty-err; then
  fail "an empty role set should exit non-zero rather than silently produce nothing"
else
  pass "an empty role set exits with a clean error"
fi
rm -f "$out" /tmp/ccx-empty-err

echo "All preview rendering tests passed."
