#!/usr/bin/env bash
#
# Runs scripts/bootstrap-monitoring-ec2.sh on a PATH of shims (id, uname,
# sudo, curl, unzip, docker) and checks its AWS CLI install: the download URL
# names the pinned version and architecture, curl fails on an HTTP error, and
# aws/install runs only when the download matches the pinned sha256 for that
# architecture. Nothing is downloaded or installed: the "zip" is a local
# fixture, and a run that should install uses a copy of the script whose pin
# is rewritten to the fixture's hash.
#
# VERBOSE=1 also prints every check that passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP="$REPO_ROOT/scripts/bootstrap-monitoring-ec2.sh"
VERBOSE="${VERBOSE:-0}"
CHECKS=0
FAILURES=0

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

check() {
  local description="$1"
  shift
  CHECKS=$((CHECKS + 1))
  if "$@"; then
    if [[ "$VERBOSE" == "1" ]]; then
      printf 'ok: %s\n' "$description"
    fi
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL: %s\n' "$description"
  fi
}

for tool in cat chmod cp cut find grep ln mkdir mktemp rm sed sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required; this suite must not pass by skipping"
done
[[ -x /bin/bash ]] || die "/bin/bash is required"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-bootstrap-awscli.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pin_of() { sed -n "s/^$1=//p" "$BOOTSTRAP"; }
PIN_VERSION="$(pin_of AWSCLI_VERSION)"
PIN_X86_64="$(pin_of AWSCLI_SHA256_X86_64)"
PIN_AARCH64="$(pin_of AWSCLI_SHA256_AARCH64)"

# ─────────────────────────────── The pins ───────────────────────────────────

matches() { [[ "$1" =~ $2 ]]; }
differ() { [[ "$1" != "$2" ]]; }
script_lacks() { ! grep -qE "$1" "$BOOTSTRAP"; }

check "AWSCLI_VERSION is a release version ($PIN_VERSION)" matches "$PIN_VERSION" '^2[.][0-9]+[.][0-9]+$'
check 'the x86_64 pin is a sha256' matches "$PIN_X86_64" '^[0-9a-f]{64}$'
check 'the aarch64 pin is a sha256' matches "$PIN_AARCH64" '^[0-9a-f]{64}$'
check 'the two architectures have different pins' differ "$PIN_X86_64" "$PIN_AARCH64"
check 'no unversioned AWS CLI download is left' script_lacks 'awscli-exe-linux-[a-z0-9_]+[.]zip'
check 'curl is never run with -s alone (no silent HTTP errors)' script_lacks 'curl -sL'

# ─────────────────────────────── Sandbox ────────────────────────────────────

FIXTURE="$WORK/fixture.zip"
printf 'not an AWS CLI zip\n' >"$FIXTURE"
FIXTURE_SHA="$(sha256sum "$FIXTURE" | cut -d' ' -f1)"

# make_box NAME: a fresh sandbox with shims and only the real tools the script
# needs, so a command without a shim (a real sudo, curl or aws) cannot run.
make_box() {
  local box="$WORK/$1" tool real
  mkdir -p "$box/bin" "$box/tmp" "$box/log"
  : >"$box/log/calls.log"
  for tool in cat chmod cp cut mkdir rm sha256sum; do
    real="$(command -v "$tool")"
    ln -s "$real" "$box/bin/$tool"
  done
  ln -s /bin/bash "$box/bin/bash"

  # The script runs `mktemp -d` with no template, which BSD mktemp places in
  # the per-user temp directory whatever TMPDIR says. Keep it in the sandbox
  # and log it, so the clean-up checks see the directory the script used.
  real="$(command -v mktemp)"
  cat >"$box/bin/mktemp" <<SHIM
#!/bin/bash
[[ "\$*" == "-d" ]] || { printf 'mktemp shim: unexpected %s\n' "\$*" >&2; exit 97; }
dir="\$("$real" -d "\$BOX/tmp/tmp.XXXXXX")" || exit 1
printf 'mktemp-dir %s\n' "\$dir" >>"\$BOX/log/calls.log"
printf '%s\n' "\$dir"
SHIM

  cat >"$box/bin/id" <<'SHIM'
#!/bin/bash
[[ "${1:-}" == "-u" ]] && { printf '1000\n'; exit 0; }
printf 'id shim: unexpected %s\n' "$*" >&2
exit 97
SHIM
  cat >"$box/bin/uname" <<'SHIM'
#!/bin/bash
[[ "${1:-}" == "-m" ]] && { printf '%s\n' "$FAKE_ARCH"; exit 0; }
printf 'uname shim: unexpected %s\n' "$*" >&2
exit 97
SHIM
  cat >"$box/bin/docker" <<'SHIM'
#!/bin/bash
printf 'docker %s\n' "$*" >>"$BOX/log/calls.log"
case "$*" in
  --version) printf 'Docker version 0.0.0-shim\n' ;;
  'compose version') printf 'Docker Compose version v0.0.0-shim\n' ;;
  *) exit 97 ;;
esac
SHIM
  cat >"$box/bin/sudo" <<'SHIM'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$BOX/log/calls.log"
case "$1" in
  apt-get) exit 0 ;;
  */aws/install) exec "$@" ;;
esac
printf 'sudo shim: unexpected %s\n' "$*" >&2
exit 97
SHIM
  cat >"$box/bin/curl" <<'SHIM'
#!/bin/bash
out="" url="" fail=0 arg
printf 'curl %s\n' "$*" >>"$BOX/log/calls.log"
while [[ $# -gt 0 ]]; do
  arg="$1"
  shift
  case "$arg" in
    -o) out="$1"; shift ;;
    --proto) printf 'curl-proto %s\n' "$1" >>"$BOX/log/calls.log"; shift ;;
    --fail) fail=1 ;;
    --*) ;;
    -*) [[ "$arg" == *f* ]] && fail=1 ;;
    *) url="$arg" ;;
  esac
done
printf 'curl-url %s\ncurl-fail-flag %s\n' "$url" "$fail" >>"$BOX/log/calls.log"
[[ "$url" == https://awscli.amazonaws.com/* && -n "$out" ]] || exit 97
[[ "${FAKE_CURL_STATUS:-0}" == "0" ]] || exit "$FAKE_CURL_STATUS"
cp "$FIXTURE" "$out"
SHIM
  cat >"$box/bin/unzip" <<'SHIM'
#!/bin/bash
printf 'unzip %s\n' "$*" >>"$BOX/log/calls.log"
dest=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) dest="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$dest" ]] || exit 97
mkdir -p "$dest/aws"
cat >"$dest/aws/install" <<'INSTALL'
#!/bin/bash
printf 'aws-install-ran\n' >>"$BOX/log/calls.log"
cat >"$BOX/bin/aws" <<'AWS'
#!/bin/bash
printf 'aws-cli/0.0.0-shim\n'
AWS
chmod 755 "$BOX/bin/aws"
INSTALL
chmod 755 "$dest/aws/install"
SHIM
  chmod 755 "$box/bin/id" "$box/bin/uname" "$box/bin/docker" "$box/bin/sudo" \
    "$box/bin/curl" "$box/bin/unzip" "$box/bin/mktemp"
}

# run_bootstrap NAME ARCH SCRIPT [VAR=VALUE...]: run SCRIPT in sandbox NAME.
run_bootstrap() {
  local name="$1" arch="$2" script="$3" box="$WORK/$1"
  shift 3
  (
    unset BASH_ENV ENV CDPATH
    export PATH="$box/bin" HOME="$box" USER=tester TMPDIR="$box/tmp" \
      BOX="$box" FIXTURE="$FIXTURE" FAKE_ARCH="$arch"
    # shellcheck disable=SC2163  # the arguments are VAR=VALUE pairs
    [[ $# -eq 0 ]] || export "$@"
    exec /bin/bash "$script"
  ) >"$box/log/out.log" 2>&1
  printf '%s\n' "$?" >"$box/log/rc"
}

# pinned_copy NAME ARCH_VAR: a copy of the script whose ARCH_VAR pin is the
# fixture's hash, so only that architecture's download matches.
pinned_copy() {
  local copy="$WORK/$1.sh"
  sed "s/^$2=.*/$2=$FIXTURE_SHA/" "$BOOTSTRAP" >"$copy"
  grep -qx "$2=$FIXTURE_SHA" "$copy" || die "cannot rewrite $2 in a copy of the script"
  printf '%s\n' "$copy"
}

rc_is() { [[ "$(cat "$WORK/$1/log/rc")" == "$2" ]]; }
rc_not() { [[ "$(cat "$WORK/$1/log/rc")" != "$2" ]]; }
logged() { grep -qxF -- "$2" "$WORK/$1/log/calls.log"; }
not_logged_re() { ! grep -qE -- "$2" "$WORK/$1/log/calls.log"; }
output_has() { grep -qF -- "$2" "$WORK/$1/log/out.log"; }
# The script made its download directory in the sandbox and removed it.
tmp_empty() {
  grep -qE "^mktemp-dir $WORK/$1/tmp/tmp[.]" "$WORK/$1/log/calls.log" &&
    [[ -z "$(find "$WORK/$1/tmp" -mindepth 1 -print)" ]]
}

url_for() { printf 'curl-url https://awscli.amazonaws.com/awscli-exe-linux-%s-%s.zip\n' "$1" "$PIN_VERSION"; }

# ─────────────────────────────── Pinned script, fixture download ────────────

for arch in x86_64 aarch64; do
  name="mismatch-$arch"
  make_box "$name"
  run_bootstrap "$name" "$arch" "$BOOTSTRAP"
  check "$arch: a download that does not match the pin fails the script" rc_is "$name" 1
  check "$arch: the download URL names version $PIN_VERSION" logged "$name" "$(url_for "$arch")"
  check "$arch: curl fails on an HTTP error" logged "$name" 'curl-fail-flag 1'
  check "$arch: curl is limited to https" logged "$name" 'curl-proto =https'
  check "$arch: the mismatch is reported" output_has "$name" 'does not match the pinned sha256; nothing was installed'
  check "$arch: the downloaded hash is shown" output_has "$name" "got:      $FIXTURE_SHA"
  if [[ "$arch" == x86_64 ]]; then pin="$PIN_X86_64"; else pin="$PIN_AARCH64"; fi
  check "$arch: its own pinned hash is shown" output_has "$name" "expected: $pin"
  check "$arch: nothing is unpacked after a mismatch" not_logged_re "$name" '^unzip '
  check "$arch: aws/install never runs after a mismatch" not_logged_re "$name" 'aws/install|aws-install-ran'
  check "$arch: the download is removed after a mismatch" tmp_empty "$name"
done

# ─────────────────────────────── Matching download ──────────────────────────

name=match-x86_64
make_box "$name"
run_bootstrap "$name" x86_64 "$(pinned_copy "$name" AWSCLI_SHA256_X86_64)"
check 'x86_64: a matching download installs' rc_is "$name" 0
check 'x86_64: unzip reads the downloaded file' grep -qE '^unzip -q .*/awscliv2[.]zip -d ' "$WORK/$name/log/calls.log"
check 'x86_64: aws/install runs through sudo' grep -qE '^sudo .*/aws/install$' "$WORK/$name/log/calls.log"
check 'x86_64: aws/install ran' logged "$name" 'aws-install-ran'
check 'x86_64: the installed CLI answers' output_has "$name" 'aws-cli/0.0.0-shim'
check 'x86_64: the download is removed after install' tmp_empty "$name"

name=match-aarch64
make_box "$name"
run_bootstrap "$name" aarch64 "$(pinned_copy "$name" AWSCLI_SHA256_AARCH64)"
check 'aarch64: a matching download installs' rc_is "$name" 0
check 'aarch64: aws/install ran' logged "$name" 'aws-install-ran'
check 'aarch64: the download is removed after install' tmp_empty "$name"

# The pin is chosen per architecture: the x86_64 pin never accepts an aarch64
# download.
name=wrong-arch-pin
make_box "$name"
run_bootstrap "$name" aarch64 "$(pinned_copy "$name" AWSCLI_SHA256_X86_64)"
check 'aarch64 is checked against its own pin' rc_is "$name" 1
check 'aarch64 with only the x86_64 pin matching does not install' not_logged_re "$name" 'aws-install-ran'

# ─────────────────────────────── Failures and skips ─────────────────────────

name=curl-fails
make_box "$name"
run_bootstrap "$name" x86_64 "$(pinned_copy "$name" AWSCLI_SHA256_X86_64)" FAKE_CURL_STATUS=22
check 'a failed download fails the script' rc_not "$name" 0
check 'nothing is unpacked after a failed download' not_logged_re "$name" '^unzip '
check 'aws/install never runs after a failed download' not_logged_re "$name" 'aws-install-ran'
check 'a failed download leaves no temp directory' tmp_empty "$name"

name=already-installed
make_box "$name"
printf '#!/bin/bash\nprintf "aws-cli/2.0.0-existing\\n"\n' >"$WORK/$name/bin/aws"
chmod 755 "$WORK/$name/bin/aws"
run_bootstrap "$name" x86_64 "$BOOTSTRAP"
check 'an installed AWS CLI is left alone' rc_is "$name" 0
check 'an installed AWS CLI is not downloaded again' not_logged_re "$name" '^curl '
check 'an installed AWS CLI is reported' output_has "$name" 'AWS CLI already installed: aws-cli/2.0.0-existing'

name=unsupported-arch
make_box "$name"
run_bootstrap "$name" riscv64 "$BOOTSTRAP"
check 'an unsupported architecture stops the script' rc_is "$name" 1
check 'an unsupported architecture runs nothing' not_logged_re "$name" '^(sudo|curl|unzip) '

if [[ "$FAILURES" -gt 0 ]]; then
  for box in "$WORK"/*/; do
    [[ -f "$box/log/out.log" ]] || continue
    printf -- '--- %s\n' "$(basename "$box")"
    cat "$box/log/out.log"
  done
  printf 'FAIL: bootstrap AWS CLI install: %s of %s checks failed\n' "$FAILURES" "$CHECKS"
  exit 1
fi
printf 'PASS: bootstrap AWS CLI install: %s checks\n' "$CHECKS"
