#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'SkyEye trading log access: %s\n' "$*" >&2
  exit 1
}

# Every path below is absolute. A neutral working directory keeps find from
# failing when it is started from one this user cannot open, such as /root
# under `runuser` from a root shell.
cd / || die "unable to change to the root directory"

for required_name in TQ_REPO_ROOT TQ_RAW_LOG_GLOB TQ_ALLOY_USER; do
  [[ -n "${!required_name:-}" ]] || die "$required_name is required"
done

for absolute_path in "$TQ_REPO_ROOT" "$TQ_RAW_LOG_GLOB"; do
  [[ "$absolute_path" == /* ]] || die "configured paths must be absolute"
  [[ "$absolute_path" != *[[:space:]\"\']* ]] || die "configured paths contain unsafe characters"
done

[[ "$TQ_ALLOY_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || \
  die "TQ_ALLOY_USER is invalid"
command -v awk >/dev/null 2>&1 || die "awk is required"
command -v find >/dev/null 2>&1 || die "find is required"
command -v getfacl >/dev/null 2>&1 || die "getfacl is required"
command -v setfacl >/dev/null 2>&1 || die "setfacl is required"

repo_root="${TQ_REPO_ROOT%/}"
raw_log_dir="${TQ_RAW_LOG_GLOB%/*}"
raw_log_pattern="${TQ_RAW_LOG_GLOB##*/}"
[[ -n "$repo_root" ]] || die "TQ_REPO_ROOT cannot be the filesystem root"
[[ -n "$raw_log_pattern" && "$raw_log_pattern" != */* ]] || \
  die "TQ_RAW_LOG_GLOB must end in one filename pattern"
[[ -d "$repo_root" ]] || die "configured repository root is missing"
[[ -d "$raw_log_dir" ]] || die "configured raw-log directory is missing"
repo_root="$(cd "$repo_root" && pwd -P)"
raw_log_dir="$(cd "$raw_log_dir" && pwd -P)"
case "$raw_log_dir" in
  "$repo_root"/*) ;;
  *) die "TQ_RAW_LOG_GLOB must stay below TQ_REPO_ROOT" ;;
esac

# find's own errors stay on stderr; its status is checked after the pipeline so a
# failed listing is reported instead of ending the script without a message.
set +e
find "$raw_log_dir" -maxdepth 1 -type f -name "$raw_log_pattern" -print0 | {
  set -euo pipefail
  raw_logs=()
  while IFS= read -r -d '' raw_log; do
    raw_logs+=("$raw_log")
  done

  if [[ "${#raw_logs[@]}" -eq 0 ]]; then
    exit 0
  fi

  acl_total_bytes=0
  for (( acl_index = 0; acl_index < ${#raw_logs[@]}; acl_index++ )); do
    acl_total_bytes=$((acl_total_bytes + ${#raw_logs[$acl_index]} + 16))
  done
  acl_arg_budget=131072
  if [[ "$acl_total_bytes" -gt "$acl_arg_budget" ]]; then
    platform_arg_max="$(getconf ARG_MAX 2>/dev/null || printf '262144')"
    if [[ "$platform_arg_max" =~ ^[0-9]+$ && "$platform_arg_max" -gt 131072 ]]; then
      acl_arg_budget=$((platform_arg_max / 2))
      [[ "$acl_arg_budget" -le 1048576 ]] || acl_arg_budget=1048576
    fi
  fi

  run_batched_getfacl() {
    local start=0 end batch_bytes entry_bytes
    while [[ "$start" -lt "${#raw_logs[@]}" ]]; do
      batch_bytes=0
      end="$start"
      while [[ "$end" -lt "${#raw_logs[@]}" ]]; do
        entry_bytes=$(( ${#raw_logs[$end]} + 16 ))
        if [[ "$end" -gt "$start" && $((batch_bytes + entry_bytes)) -gt "$acl_arg_budget" ]]; then
          break
        fi
        batch_bytes=$((batch_bytes + entry_bytes))
        end=$((end + 1))
      done
      [[ "$start" -eq 0 ]] || printf '\n'
      getfacl -cp -- "${raw_logs[@]:$start:$((end - start))}" 2>/dev/null || return 1
      start="$end"
    done
  }

  if ! missing_indices="$(run_batched_getfacl | LC_ALL=C awk -v alloy_user="$TQ_ALLOY_USER" -v expected="${#raw_logs[@]}" '
    BEGIN {
      RS = ""
      FS = "\n"
      user_prefix = "user:" alloy_user ":r"
      mask_prefix = "mask::r"
    }
    {
      has_user = 0
      has_mask = 0
      for (i = 1; i <= NF; i++) {
        if (index($i, user_prefix) == 1) has_user = 1
        if (index($i, mask_prefix) == 1) has_mask = 1
      }
      if (!has_user || !has_mask) print NR - 1
    }
    END {
      if (NR != expected) exit 2
    }
  ')"; then
    die "unable to inspect a configured raw log ACL"
  fi

  missing_files=()
  if [[ -n "$missing_indices" ]]; then
    while IFS= read -r missing_index; do
      [[ -n "$missing_index" ]] || continue
      missing_files+=("${raw_logs[$missing_index]}")
    done <<<"$missing_indices"
  fi

  set_start=0
  while [[ "$set_start" -lt "${#missing_files[@]}" ]]; do
    set_batch_bytes=0
    set_end="$set_start"
    while [[ "$set_end" -lt "${#missing_files[@]}" ]]; do
      set_entry_bytes=$(( ${#missing_files[$set_end]} + 16 ))
      if [[ "$set_end" -gt "$set_start" && $((set_batch_bytes + set_entry_bytes)) -gt "$acl_arg_budget" ]]; then
        break
      fi
      set_batch_bytes=$((set_batch_bytes + set_entry_bytes))
      set_end=$((set_end + 1))
    done
    if ! setfacl -m "u:${TQ_ALLOY_USER}:r--" -- "${missing_files[@]:$set_start:$((set_end - set_start))}" >/dev/null 2>&1; then
      die "unable to grant Alloy read access to a configured raw log"
    fi
    set_start="$set_end"
  done
}
pipeline_status=("${PIPESTATUS[@]}")
set -e
# The loop has already printed its reason; a find stopped by its exit is not
# a separate failure.
[[ "${pipeline_status[1]}" -eq 0 ]] || exit "${pipeline_status[1]}"
[[ "${pipeline_status[0]}" -eq 0 ]] || \
  die "listing configured raw logs with find failed (rc=${pipeline_status[0]}) in $raw_log_dir"
