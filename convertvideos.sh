#!/usr/bin/env bash
# convertvideos - batch convert to 1080p-max HEVC(H.265)/AAC MP4
#   Output compatible with most devices
#   Keeps all audio and sub tracks
#   Converts files with the following extensions: .avi, .mkv, .mp4
#   Converted files end with _converted.mp4
#   Converted files are skipped by the script
#   !!! Hardware encoding with AMD GPU !!!
#   !!! Won't work without AMD GPU !!!
# Usage:
#   convertvideos                        → videos in current directory (no recursion)
#   convertvideos -r                     → videos in current directory + its subfolders (1 level deep)
#   convertvideos -r 3                   → 3 levels deep
#   convertvideos -d                     → delete originals after successful conversion
#   convertvideos dir/                   → videos in that directory (no recursion)
#   convertvideos -r 2 -d dir/           → videos in that directory + 2 level deep + delete originals
#   convertvideos moviea.mkv movieb.mp4  → specific file(s)
# Behavior:
#   Default: originals are archived to a BAK/ subfolder (with .nomedia).
#   With -d: originals are deleted instead (WARNING!).
# Install:
#   ln -s "$PWD/convertvideos.sh" ~/.local/bin/convertvideos
#   chmod +x "$PWD/convertvideos.sh"

set -u

n_ok=0 n_skip=0 n_fail=0
depth=""      # empty = not recursive
delete=no
targets=()

usage() { awk '/^#!/{next} /^#/{print} {exit}' "$0"; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    -r)
      depth=1
      if [ $# -gt 1 ] && [[ "$2" =~ ^[0-9]+$ ]]; then depth="$2"; shift; fi
      ;;
    -d) delete=yes ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *)  targets+=("$1") ;;
  esac
  shift
done
[ ${#targets[@]} -eq 0 ] && targets=(.)

# validate targets up front (counters work here; collect() runs in a subshell)
for t in "${targets[@]}"; do
  [ -e "$t" ] || { echo "ERROR: '$t' not found" >&2; n_fail=$((n_fail+1)); }
done

convert_one() {
  local f="$1"
  case "$f" in *_converted.mp4) echo "SKIP: $f"; return 2 ;; esac
  local out="${f%.*}_converted.mp4"
  [ -e "$out" ] && { echo "SKIP: $f (already done)"; return 2; }

  local common=(-vaapi_device /dev/dri/renderD128 -i "$f"
    -vf "scale='min(1920,iw)':-2:flags=lanczos,format=nv12,hwupload"
    -c:v hevc_vaapi -qp 22 -c:a aac -b:a 192k -ac 2
    -movflags +faststart)

  echo "=== $f"
  # 1st try: keep all text subtitles; 2nd try: no subs (bitmap-only sources)
  ffmpeg -n -hide_banner "${common[@]}" \
    -map 0:v:0 -map 0:a? -map 0:s? -c:s mov_text "$out" \
  || ffmpeg -y -hide_banner "${common[@]}" \
    -map 0:v:0 -map 0:a? -sn "$out" \
  || { echo "FAILED: $f"; return 1; }

  # conversion succeeded → dispose of the original
  if [ "$delete" = yes ]; then
    if rm -- "$f"; then
      echo "DELETED: $f"
    else
      echo "WARNING: couldn't delete original. Converted file is fine, source left in place"
    fi
  else
    local bak_dir bak_name
    bak_dir="$(dirname "$f")/BAK"
    bak_name="$(basename "$f")"
    if ! mkdir -p "$bak_dir"; then
      echo "WARNING: couldn't create $bak_dir. Original left in place"
      return 0
    fi
    touch "$bak_dir/.nomedia"
    if [ -e "$bak_dir/$bak_name" ]; then
      echo "WARNING: $bak_dir/$bak_name already exists. Coriginal left in place"
      return 0
    fi
    if mv "$f" "$bak_dir/"; then
      echo "ARCHIVED: $f → $bak_dir/"
    else
      echo "WARNING: couldn't move original. Converted file is fine, source left in place"
    fi
  fi
  return 0
}

collect() {
  local arg="$1" f
  if [ -f "$arg" ]; then
    printf '%s\0' "$arg"
  elif [ -d "$arg" ]; then
    if [ -n "$depth" ]; then
      find "$arg" -maxdepth $((depth + 1)) -type f -not -path '*/BAK/*' \
        \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' \) -print0
    else
      for f in "$arg"/*.mkv "$arg"/*.mp4 "$arg"/*.avi; do
        [ -f "$f" ] && printf '%s\0' "$f"
      done
    fi
  fi
}

mapfile -d '' -t all_files < <(for arg in "${targets[@]}"; do collect "$arg"; done | sort -z)

if [ ${#all_files[@]} -eq 0 ]; then
  echo "Nothing to do."
  [ $n_fail -gt 0 ] && exit 1
  exit 0
fi

if [ "$delete" = yes ]; then
  echo "!!!  DELETE MODE: originals will be permanently removed after conversion."
  read -r -p "Proceed with ${#all_files[@]} file(s)? [y/N] " reply
  case "$reply" in [yY]*) ;; *) echo "Aborted."; exit 0 ;; esac
fi

for f in "${all_files[@]}"; do
  rc=0
  convert_one "$f" || rc=$?
  case $rc in
    0) n_ok=$((n_ok+1)) ;;
    2) n_skip=$((n_skip+1)) ;;
    *) n_fail=$((n_fail+1)) ;;
  esac
done

echo
echo "Finished: $n_ok converted, $n_skip skipped, $n_fail failed."

