#!/usr/bin/env bash
#
# The Windows installer cannot run on this machine, and the first place it would
# otherwise be parsed is an elevated prompt on the host. So this suite parses the
# scripts with PowerShell 7, rejects what Windows PowerShell 5.1 would not read,
# and runs every STOP and rollback path of the installer against a fake host
# (tests/fixtures/windows/installer.Tests.ps1).
#
# Not covered here, because only Windows has them: PowerShell 5.1 itself and the
# real service, registry, ACL and Event Log calls. Their first run is
# `install.ps1 -Mode Check` on the host, which changes nothing.
#
# It must never pass by skipping.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_DIR="$REPO_ROOT/agents/alloy/windows"
LOGIC_TESTS="$REPO_ROOT/tests/fixtures/windows/installer.Tests.ps1"
FAILED=0

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

record() {
  printf 'FAIL: %s\n' "$*"
  FAILED=1
}

command -v pwsh >/dev/null 2>&1 || die "pwsh is required (brew install powershell); this suite must not pass by skipping"
[[ -f "$LOGIC_TESTS" ]] || die "missing $LOGIC_TESTS"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-windows-installer.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

run_pwsh() {
  pwsh -NoLogo -NoProfile -NonInteractive "$@"
}

scripts=("$AGENT_DIR/install.ps1" "$AGENT_DIR/uninstall.ps1" "$AGENT_DIR/SkyEyeAlloy.ps1")
for script in "${scripts[@]}" "$LOGIC_TESTS"; do
  [[ -f "$script" ]] || die "missing $script"
  # Windows PowerShell 5.1 reads a script without a BOM in the ANSI code page,
  # Big5 on the first host, so one non-ASCII byte changes what it parses.
  if LC_ALL=C grep -n '[^[:print:][:space:]]' "$script" >"$WORK/non-ascii.txt"; then
    record "${script#"$REPO_ROOT/"} has non-ASCII bytes: $(head -n 3 "$WORK/non-ascii.txt" | tr '\n' ' ')"
  fi
  if LC_ALL=C grep -q $'\r' "$script"; then
    record "${script#"$REPO_ROOT/"} has CR line endings"
  fi
done

# The render entry point: the one part of install.ps1 itself that runs here.
if ! run_pwsh -File "$AGENT_DIR/install.ps1" -Product verify -ServerId verify-host \
  -RenderOnly "$WORK/render.alloy" >"$WORK/render.log" 2>&1; then
  record "install.ps1 -RenderOnly failed: $(tail -n 3 "$WORK/render.log" | tr '\n' ' ')"
elif ! grep -q 'server_id = "verify-host"' "$WORK/render.alloy"; then
  record "install.ps1 -RenderOnly did not write the render"
fi
run_pwsh -File "$AGENT_DIR/install.ps1" -Product 'Bad Product' -ServerId verify-host \
  -RenderOnly "$WORK/bad.alloy" >"$WORK/bad.log" 2>&1
rc=$?
[[ "$rc" -eq 2 ]] || record "install.ps1 -RenderOnly with a bad -Product exited $rc, want 2"
[[ ! -e "$WORK/bad.alloy" ]] || record "install.ps1 -RenderOnly wrote a file for a bad -Product"

mkdir -p "$WORK/hosts"
if ! run_pwsh -File "$LOGIC_TESTS" -AgentDir "$AGENT_DIR" -WorkDir "$WORK/hosts" >"$WORK/logic.log" 2>&1; then
  cat "$WORK/logic.log"
  FAILED=1
fi
logic_summary="$(grep -E '^PASS: Windows installer logic: [0-9]+ checks$' "$WORK/logic.log" || true)"
if [[ -z "$logic_summary" && "$FAILED" -eq 0 ]]; then
  cat "$WORK/logic.log"
  record "the logic tests did not report a result"
fi

[[ "$FAILED" -eq 0 ]] || die "Windows installer checks failed"
printf 'PASS: Windows installer: parse, PowerShell 5.1 compatibility, render entry point; %s\n' "${logic_summary#PASS: }"
