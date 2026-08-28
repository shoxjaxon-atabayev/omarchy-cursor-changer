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
ccx_theme_inherits_from_index() {
  local index_theme="$1"
  [[ -f $index_theme ]] || return 0
  sed -n 's/^Inherits=//p' "$index_theme" 2>/dev/null | head -n1
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
