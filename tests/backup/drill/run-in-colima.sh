#!/bin/bash
# Runs the restore drill, or the test suite, inside the Colima VM: the Docker volume
# path only exists there, and it is Linux with GNU tools, like monitoring-prod.
#
#   DRILL_LOG_DIR=<dir> DRILL_JQ_DEBS=<dir> bash tests/backup/drill/run-in-colima.sh drill
#   DRILL_JQ_DEBS=<dir> bash tests/backup/drill/run-in-colima.sh tests
#
# The repository and DRILL_LOG_DIR have to be under the home directory, which Colima
# mounts at the same path. The VM has no jq and monitoring-prod does. DRILL_JQ_DEBS
# holds the jq, libjq1 and libonig5 packages of the VM's release: they are unpacked
# into a temporary directory, not installed, and removed afterwards.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TOOLS=/var/tmp/skyeye-restore-drill-tools
MODE="${1:?usage: run-in-colima.sh drill|tests}"

RULES_LOCAL=""
RULES_FILE="$REPO_ROOT/prometheus/rules/backup.yml"
if [ ! -f "$RULES_FILE" ]; then
  # Until PR-1 reaches this branch. The VM reads it through the home mount.
  RULES_LOCAL="$(mktemp "$HOME/.skyeye-drill-rules.XXXXXX")"
  git -C "$REPO_ROOT" show feat/backup-docs-rules:prometheus/rules/backup.yml >"$RULES_LOCAL"
  chmod 0644 "$RULES_LOCAL"
  RULES_FILE="$RULES_LOCAL"
fi
remove_rules_copy() {
  [ -z "$RULES_LOCAL" ] || rm -f "${RULES_LOCAL:?}"
}
trap remove_rules_copy EXIT

in_vm() {
  colima ssh -- "$@"
}

path_in_vm="/usr/sbin:/usr/bin:/sbin:/bin"
if ! in_vm sh -c 'command -v jq' >/dev/null 2>&1; then
  : "${DRILL_JQ_DEBS:?the VM has no jq: set DRILL_JQ_DEBS}"
  in_vm sh -c "rm -rf '$TOOLS' && mkdir -p '$TOOLS/root' '$TOOLS/bin' && for deb in '$DRILL_JQ_DEBS'/*.deb; do dpkg -x \"\$deb\" '$TOOLS/root'; done"
  in_vm sh -c "printf '#!/bin/sh\nLD_LIBRARY_PATH=$TOOLS/root/usr/lib/aarch64-linux-gnu exec $TOOLS/root/usr/bin/jq \"\$@\"\n' >'$TOOLS/bin/jq' && chmod 0755 '$TOOLS/bin/jq' && chmod -R a+rX '$TOOLS'"
  path_in_vm="$TOOLS/bin:$path_in_vm"
fi
remove_tools() {
  remove_rules_copy
  in_vm rm -rf "$TOOLS" || true
}
trap remove_tools EXIT

in_vm sh -c "PATH=$path_in_vm jq --version"

case "$MODE" in
  tests)
    in_vm env PATH="$path_in_vm" BACKUP_RULES_FILE="$RULES_FILE" /bin/bash "$REPO_ROOT/tests/backup/run-tests.sh"
    ;;
  drill)
    : "${DRILL_LOG_DIR:?DRILL_LOG_DIR is required}"
    mkdir -p "$DRILL_LOG_DIR"
    in_vm sudo env PATH="$path_in_vm" DRILL_LOG_DIR="$DRILL_LOG_DIR" DRILL_RULES_FILE="$RULES_FILE" \
      ${DRILL_LOOKBACK_WAIT:+DRILL_LOOKBACK_WAIT="$DRILL_LOOKBACK_WAIT"} \
      /bin/bash "$REPO_ROOT/tests/backup/drill/run-drill.sh"
    ;;
  *)
    echo "usage: run-in-colima.sh drill|tests" >&2
    exit 2
    ;;
esac
