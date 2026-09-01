#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'SkyEye trading log access: %s\n' "$*" >&2
  exit 1
}

for required_name in TQ_REPO_ROOT TQ_RAW_LOG_GLOB TQ_ALLOY_USER; do
  [[ -n "${!required_name:-}" ]] || die "$required_name is required"
done

for absolute_path in "$TQ_REPO_ROOT" "$TQ_RAW_LOG_GLOB"; do
  [[ "$absolute_path" == /* ]] || die "configured paths must be absolute"
  [[ "$absolute_path" != *[[:space:]\"\']* ]] || die "configured paths contain unsafe characters"
done

[[ "$TQ_ALLOY_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || \
  die "TQ_ALLOY_USER is invalid"
command -v find >/dev/null 2>&1 || die "find is required"
command -v getfacl >/dev/null 2>&1 || die "getfacl is required"
command -v grep >/dev/null 2>&1 || die "grep is required"
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

find "$raw_log_dir" -maxdepth 1 -type f -name "$raw_log_pattern" -print0 2>/dev/null |
  while IFS= read -r -d '' raw_log; do
    if ! acl="$(getfacl -cp -- "$raw_log" 2>/dev/null)"; then
      die "unable to inspect a configured raw log ACL"
    fi
    if printf '%s\n' "$acl" | grep -Eq "^user:${TQ_ALLOY_USER}:r" &&
      printf '%s\n' "$acl" | grep -Eq '^mask::r'
    then
      continue
    fi
    if ! setfacl -m "u:${TQ_ALLOY_USER}:r--" -- "$raw_log" >/dev/null 2>&1; then
      die "unable to grant Alloy read access to a configured raw log"
    fi
  done
