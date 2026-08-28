# Shared helpers for omarchy-cursor-changer bin/ scripts.
# Source this; do not execute directly.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "source lib/common.sh from another script; do not run it directly" >&2
  exit 1
fi

CCX_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/cursor-changer"
CCX_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/cursor-changer"
CCX_STATE_FILE="$CCX_STATE_HOME/state.json"
CCX_LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/omarchy-cursor-changer-apply.lock"
CCX_DEFAULT_SIZE=24

# Directories to scan for cursor themes, highest priority first.
# Each entry is "path\tsource" (source is "user" or "system").
ccx_search_paths() {
  local xdg_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  local dir entry seen=""

  printf '%s\tuser\n' "$HOME/.icons"
  printf '%s\tuser\n' "$xdg_data_home/icons"

  IFS=':' read -r -a dirs <<<"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  for dir in "${dirs[@]}"; do
    [[ -n $dir ]] || continue
    entry="$dir/icons"
    # Deduplicate: XDG_DATA_DIRS commonly repeats /usr/share across entries.
    [[ $seen == *"|$entry|"* ]] && continue
    seen="$seen|$entry|"
    printf '%s\tsystem\n' "$entry"
  done
}

# Print "Name=" from an index.theme file, or empty if absent/unreadable.
ccx_theme_name_from_index() {
  local index_theme="$1"
  [[ -f $index_theme ]] || return 0
  sed -n 's/^Name=//p' "$index_theme" 2>/dev/null | head -n1
}

# Print "Inherits=" (comma-separated raw value) from an index.theme file.
# Some themes (seen in the wild, e.g. MacOSX/Moga-Dark cursor packs) quote
# the value as Inherits="hicolor"; strip surrounding quotes and whitespace
# from each entry so callers never have to special-case that.
ccx_theme_inherits_from_index() {
  local index_theme="$1" raw
  [[ -f $index_theme ]] || return 0
  raw=$(sed -n 's/^Inherits=//p' "$index_theme" 2>/dev/null | head -n1)
  [[ -n $raw ]] || return 0
  raw=${raw#\"}
  raw=${raw%\"}
  IFS=',' read -r -a parts <<<"$raw"
  local part trimmed out=()
  for part in "${parts[@]}"; do
    trimmed=$(sed -e 's/^[[:space:]"]*//' -e 's/[[:space:]"]*$//' <<<"$part")
    [[ -n $trimmed ]] && out+=("$trimmed")
  done
  (IFS=,; printf '%s\n' "${out[*]}")
}

# Role name -> ordered list of candidate cursor filenames. Themes do not
# agree on a single canonical name per role (X11/Xcursor legacy names,
# CSS-style names, and a theme author's own choices all coexist in the
# wild), so each role tries several aliases before being reported missing.
ccx_role_names() {
  echo "pointer text link wait resize-horizontal resize-vertical resize-diagonal grab grabbing"
}

ccx_role_aliases() {
  case "$1" in
    pointer) echo "left_ptr default arrow top_left_arrow" ;;
    text) echo "text xterm ibeam" ;;
    link) echo "pointer hand2 hand1 pointing_hand" ;;
    wait) echo "wait watch progress left_ptr_watch" ;;
    resize-horizontal) echo "ew-resize sb_h_double_arrow h_double_arrow col-resize" ;;
    resize-vertical) echo "ns-resize sb_v_double_arrow v_double_arrow row-resize" ;;
    resize-diagonal) echo "nwse-resize size_fdiag fd_double_arrow bd_double_arrow nesw-resize" ;;
    grab) echo "grab openhand fleur" ;;
    grabbing) echo "grabbing closedhand dnd-move" ;;
    *) echo "" ;;
  esac
}

# Resolve the ordered list of ancestor directories for inheritance, deepest
# search first: [theme_dir, parent_dir, grandparent_dir, ...]. Only
# ancestors that are themselves real cursor themes contribute anything, but
# non-cursor ancestors (icon-only themes like "hicolor") are still walked
# past (not treated as errors) since Inherits= chains commonly name them.
# Guards against cycles and unbounded chains via a visited set and a depth
# cap.
ccx_resolve_inheritance_chain() {
  local start_dir="$1"
  local -A visited=()
  local -a chain=()
  local -a queue=("$start_dir")
  local depth=0
  local dir index_theme inherits parent_name parent_dir

  while (( ${#queue[@]} > 0 && depth < 16 )); do
    dir="${queue[0]}"
    queue=("${queue[@]:1}")
    # Not `((depth++))`: under `set -e`, post-increment from 0 evaluates
    # the whole expression to 0 (falsy), which bash treats as command
    # failure and aborts this subshell before anything is printed.
    depth=$((depth + 1))

    [[ -n ${visited[$dir]:-} ]] && continue
    visited[$dir]=1
    chain+=("$dir")

    index_theme="$dir/index.theme"
    inherits=$(ccx_theme_inherits_from_index "$index_theme")
    [[ -n $inherits ]] || continue

    IFS=',' read -r -a parents <<<"$inherits"
    for parent_name in "${parents[@]}"; do
      [[ -n $parent_name ]] || continue
      parent_dir=$(ccx_find_theme_dir_by_name "$parent_name")
      [[ -n $parent_dir ]] || continue
      [[ -n ${visited[$parent_dir]:-} ]] || queue+=("$parent_dir")
    done
  done

  printf '%s\n' "${chain[@]}"
}

# Find any installed theme directory (cursor theme or plain icon theme) by
# its declared Name= or, failing that, its directory basename. Used only to
# walk Inherits= chains, so icon-only ancestors (hicolor, Humanity, ...) are
# legitimately returned even though ccx_has_cursors would reject them.
ccx_find_theme_dir_by_name() {
  local wanted="$1" path source dir name
  while IFS=$'\t' read -r path source; do
    [[ -d $path ]] || continue
    for dir in "$path"/*/; do
      [[ -d $dir ]] || continue
      dir=${dir%/}
      name=$(ccx_theme_name_from_index "$dir/index.theme")
      [[ -n $name ]] || name=${dir##*/}
      if [[ $name == "$wanted" || ${dir##*/} == "$wanted" ]]; then
        printf '%s\n' "$dir"
        return
      fi
    done
  done < <(ccx_search_paths)
}

# Resolve one role to an actual cursor file path by walking the inheritance
# chain (self first, then ancestors) and, within each directory, trying
# every alias for that role in order. Prints nothing if unresolved anywhere
# in the chain.
ccx_resolve_role() {
  local role="$1"; shift
  local -a chain=("$@")
  local dir alias candidate

  for dir in "${chain[@]}"; do
    [[ -d "$dir/cursors" ]] || continue
    for alias in $(ccx_role_aliases "$role"); do
      candidate="$dir/cursors/$alias"
      if [[ -f $candidate || -L $candidate ]]; then
        printf '%s\n' "$candidate"
        return
      fi
    done
  done
}

# A directory counts as an actual cursor theme only if cursors/ exists and
# holds at least one regular file or symlink (broken themes with an empty or
# missing cursors/ dir are not real cursor themes, even if they carry an
# icon-theme index.theme).
ccx_has_cursors() {
  local dir="$1"
  [[ -d "$dir/cursors" ]] || return 1
  find -L "$dir/cursors" -mindepth 1 -maxdepth 1 -type f -print -quit 2>/dev/null | grep -q .
}

# Resolve a theme argument (bare name or absolute directory) to a directory,
# preferring the discovery order (user before system). Prints the directory
# or nothing if not found.
ccx_resolve_theme_dir() {
  local wanted="$1"

  if [[ $wanted == /* && -d $wanted ]]; then
    ccx_has_cursors "$wanted" && printf '%s\n' "$wanted"
    return
  fi

  local path source dir name
  while IFS=$'\t' read -r path source; do
    [[ -d $path ]] || continue
    for dir in "$path"/*/; do
      [[ -d $dir ]] || continue
      dir=${dir%/}
      ccx_has_cursors "$dir" || continue
      name=$(ccx_theme_name_from_index "$dir/index.theme")
      [[ -n $name ]] || name=${dir##*/}
      if [[ $name == "$wanted" || ${dir##*/} == "$wanted" ]]; then
        printf '%s\n' "$dir"
        return
      fi
    done
  done < <(ccx_search_paths)
}

mkdir -p "$CCX_STATE_HOME" "$CCX_CACHE_HOME" 2>/dev/null || true
