#!/usr/bin/env bash
set -euo pipefail

# Manage accounts (executors) in an already-installed Linux Trading monitoring
# instance (/etc/skyeye-trading/instances/<strategy>.env) by atomically
# updating only the TQ_EXECUTOR_MAP line.
#
# Scope: Linux Trading lanes installed via agents/alloy/trading/setup-linux.sh
# only. macOS (Mac mini) and Windows lanes are out of scope.
#
# Because skyeye-trading-probe@.service uses EnvironmentFile= and re-reads the
# env on every 15-second probe invocation (and Alloy templates do not reference
# TQ_EXECUTOR_MAP), account changes never reload or restart Alloy and never
# modify Alloy fragments, ACLs, systemd units, or shared probe.sh.
#
# Invoked directly, through setup-linux.sh account, or via scripts/trading-account.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMON_LIB="$SCRIPT_DIR/linux-common.sh"
INSTALL_COMMON="$SCRIPT_DIR/../install-common.sh"

SUBCOMMAND=""
SERVER_ID=""
STRATEGY=""
EXECUTOR=""
EXCHANGE=""
DRY_RUN=0

WAIT_SECONDS="${SKYEYE_ACCOUNT_WAIT_SECONDS:-0}"
VERIFY_TIMEOUT="${SKYEYE_ACCOUNT_VERIFY_TIMEOUT:-45}"
POLL_INTERVAL="${SKYEYE_ACCOUNT_POLL_INTERVAL:-2}"
MAX_PROM_BYTES="${SKYEYE_ACCOUNT_MAX_PROM_BYTES:-4194304}"

# Transaction state shared with signal/exit traps.
WORK_DIR=""
STAGED_ENV_TEMP=""
BACKUP_DIR=""
BACKUP_ENV=""
INSTALL_ENV=""
INSTALL_ENV_ROOT=""
INSTANCE_TIMER=""
INSTANCE_SERVICE=""
PRIOR_TIMER_ENABLED=0
PRIOR_TIMER_ACTIVE=0
ORIG_ENV_OWNER=""
TX_STARTED=0
TX_COMMITTED=0
ROLLBACK_DONE=0
ROLLBACK_FAILED=0
ROLLBACK_REASON=""
SLEEP_PID=""
PROM_ERR_TMP=""
SYSTEMCTL_ERR_TMP=""

usage() {
  printf '%s\n' \
    'Usage: setup-linux.sh account add    [--server ID] --strategy NAME --executor NAME [--exchange NAME] [--dry-run]' \
    '       setup-linux.sh account remove [--server ID] --strategy NAME --executor NAME [--exchange NAME] [--dry-run]' \
    '       setup-linux.sh account list   [--server ID] --strategy NAME' \
    '' \
    'Manage executors in an installed Linux Trading lane (TQ_EXECUTOR_MAP only).' \
    'Scope: Linux Trading lanes installed via setup-linux.sh only; macOS (Mac mini)' \
    'and Windows lanes are out of scope.' \
    '' \
    'Subcommands:' \
    '  add     Atomically add one executor to TQ_EXECUTOR_MAP under /run/skyeye-alloy.lock.' \
    '          If --exchange is omitted and all current executors share one exchange,' \
    '          that exchange is inferred; multi-exchange lanes require --exchange.' \
    '  remove  Atomically remove one executor from TQ_EXECUTOR_MAP (refuses removing' \
    '          the last one). If --exchange is given, verifies it matches.' \
    '  list    Read-only: display TQ_EXECUTOR_MAP and executors currently emitting' \
    '          series in the strategy .prom file.' \
    '' \
    'Options:' \
    '  --server ID       Verify TQ_SERVER_ID in the installed env matches ID.' \
    '  --strategy NAME   Installed strategy slug (/etc/skyeye-trading/instances/NAME.env).' \
    '  --executor NAME   Executor name (add/remove only).' \
    '  --exchange NAME   Exchange label (optional on add/remove; required on add when' \
    '                    multiple exchanges exist in TQ_EXECUTOR_MAP).' \
    '  --dry-run         Validate and print the planned change without modifying the host.' \
    '  -h, --help        Show this help.' \
    '' \
    'Verification & timer state:' \
    '  - Never touches Alloy, Alloy fragments, ACLs, systemd units, or shared probe.sh.' \
    '  - Preserves probe timer enabled/active state.' \
    '  - Active timer: waits for the next timer-triggered .prom snapshot (timestamp' \
    '    advancing after the write) and verifies executor labels in that snapshot.' \
    '  - Inactive timer (disabled or stopped): verifies env content and preserved' \
    '    timer state only; live probe .prom output is not verified.' \
    '  - Any verification failure or interruption (HUP/INT/TERM) atomically restores' \
    '    the backed-up env.' \
    '' \
    'Ordering with tnauqquant (SkyEye never touches tnauqquant@* units/configs/envs):' \
    '  Add:    1) Run SkyEye account add first; 2) Add the account in tnauqquant and restart.' \
    '  Remove: 1) Remove the account in tnauqquant and restart first; 2) Run SkyEye account remove.' \
    '' \
    'Guards:' \
    '  - Mutating commands (add/remove) are refused during UTC 18:10-19:30' \
    '    (checked both at preflight and again inside the lock before writing).' \
    '  - Serialized with setup-linux.sh / retire-linux.sh via /run/skyeye-alloy.lock.' \
    '  - New strategies, strategy retirement, and shared probe.sh updates still require' \
    '    the full workflow in agents/alloy/trading/README.md.'
}

die() {
  printf 'SkyEye trading account: %s\n' "$*" >&2
  exit 1
}

[[ -f "$COMMON_LIB" ]] || die "missing shared helper library: $COMMON_LIB"
# shellcheck source=agents/alloy/trading/linux-common.sh
source "$COMMON_LIB"
[[ -f "$INSTALL_COMMON" ]] || die "missing shared helper library: $INSTALL_COMMON"
# shellcheck source=agents/alloy/install-common.sh
source "$INSTALL_COMMON"

# Prints a host-side retry command preserving every flag (including --dry-run)
# ONLY when invoked from a persistent host checkout (setup-linux.sh beside us).
# When invoked from a wrapper-uploaded temp dir, the wrapper owns retry hints.
format_host_retry_cmd() {
  [[ -x "$SCRIPT_DIR/setup-linux.sh" ]] || return 0
  local cmd="sudo $SCRIPT_DIR/setup-linux.sh account $SUBCOMMAND"
  if [[ -n "$SERVER_ID" ]]; then
    cmd="$cmd --server $SERVER_ID"
  fi
  cmd="$cmd --strategy $STRATEGY"
  if [[ -n "$EXECUTOR" ]]; then
    cmd="$cmd --executor $EXECUTOR"
  fi
  if [[ -n "$EXCHANGE" ]]; then
    cmd="$cmd --exchange $EXCHANGE"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    cmd="$cmd --dry-run"
  fi
  printf '%s' "$cmd"
}

print_host_retry_hint() {
  local label="$1" retry_cmd
  retry_cmd="$(format_host_retry_cmd)"
  if [[ -n "$retry_cmd" ]]; then
    printf '%s: %s\n' "$label" "$retry_cmd" >&2
  fi
}

check_utc_window() {
  local now_hm hh mm total_min
  now_hm="$(date -u '+%H:%M')"
  [[ "$now_hm" =~ ^([0-9]{2}):([0-9]{2})$ ]] || \
    die "cannot determine current UTC time from 'date -u +%H:%M': $now_hm"
  hh="${BASH_REMATCH[1]}"
  mm="${BASH_REMATCH[2]}"
  total_min=$((10#$hh * 60 + 10#$mm))
  # Refuse UTC 18:10 (1090) through 19:30 (1170) inclusive.
  if [[ "$total_min" -ge 1090 && "$total_min" -le 1170 ]]; then
    if [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR" && -f "$BACKUP_DIR/account.meta" ]]; then
      printf 'status=refused_utc_window\n' >>"$BACKUP_DIR/account.meta"
    fi
    printf 'SkyEye trading account: refusing to modify trading accounts during the UTC 18:10-19:30 maintenance/restart window (current UTC: %s). Retry after 19:30 UTC.\n' \
      "$now_hm" >&2
    print_host_retry_hint "Retry after 19:30 UTC"
    exit 1
  fi
}

# Atomically opens a .prom file without following symlinks (O_NOFOLLOW | O_NONBLOCK),
# verifies fstat(fd) is a regular file, enforces a strict byte read cap
# (MAX_PROM_BYTES, default 4 MiB), and reads its complete contents from that
# single descriptor into PROM_SNAPSHOT. Shared by list and post-write verification.
# Return codes:
#   0  = regular file read into PROM_SNAPSHOT
#   10 = ENOENT (file does not exist)
#   11 = ELOOP (symlink refused)
#   12 = other open/read error
#   13 = non-regular file (FIFO, directory, etc. refused)
#   14 = file size or bytes read exceeds MAX_PROM_BYTES
PROM_SNAPSHOT=""
PROM_READ_ERROR=""
read_prom_snapshot() {
  local prom_path="$1"
  local parent_dir="${prom_path%/*}"
  PROM_SNAPSHOT=""
  PROM_READ_ERROR=""
  if [[ -L "$parent_dir" ]]; then
    PROM_READ_ERROR="refusing symlink textfile directory: $parent_dir"
    return 11
  fi
  local rc=0
  PROM_ERR_TMP="$(mktemp "${TMPDIR:-/tmp}/skyeye-prom-err.XXXXXX")"
  PROM_SNAPSHOT="$(perl -MFcntl=O_RDONLY,O_NOFOLLOW,O_NONBLOCK -e '
    use strict;
    use warnings;
    my ($path, $max_bytes) = @ARGV;
    my $fh;
    if (!sysopen($fh, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)) {
      if ($!{ENOENT}) { exit 10; }
      if ($!{ELOOP})  { print STDERR "refusing symlink prom file: $path\n"; exit 11; }
      print STDERR "cannot open prom file $path: $!\n";
      exit 12;
    }
    if (! -f $fh) {
      close($fh);
      print STDERR "refusing non-regular prom file: $path\n";
      exit 13;
    }
    my $fsize = -s $fh;
    if (defined($fsize) && $fsize > $max_bytes) {
      close($fh);
      print STDERR "prom file exceeds maximum allowed size ($max_bytes bytes): $path\n";
      exit 14;
    }
    my $data = "";
    my $total = 0;
    while (1) {
      my $buf = "";
      my $n = sysread($fh, $buf, 65536);
      if (!defined($n)) {
        print STDERR "cannot read prom file $path: $!\n";
        close($fh);
        exit 12;
      }
      last if $n == 0;
      $total += $n;
      if ($total > $max_bytes) {
        close($fh);
        print STDERR "prom file exceeds maximum allowed size ($max_bytes bytes): $path\n";
        exit 14;
      }
      $data .= $buf;
    }
    close($fh);
    print $data;
  ' "$prom_path" "$MAX_PROM_BYTES" 2>"$PROM_ERR_TMP")" || rc=$?
  if [[ -s "$PROM_ERR_TMP" ]]; then
    PROM_READ_ERROR="$(cat "$PROM_ERR_TMP")"
  fi
  rm -f -- "$PROM_ERR_TMP"
  PROM_ERR_TMP=""
  return "$rc"
}

snapshot_probe_timestamp() {
  local snapshot="$1"
  local strategy="$2"
  [[ -n "$snapshot" ]] || return 0
  LC_ALL=C awk -v want="strategy=\"$strategy\"" '
    index($0, "tnauqquant_probe_timestamp_seconds{") == 1 && index($0, want) > 0 {
      val = $NF
      if (val ~ /^[0-9]+([.][0-9]+)?$/) {
        sub(/[.].*$/, "", val)
        print val
        exit
      }
    }
  ' <<<"$snapshot"
}

# Lists executors present in a .prom snapshot as: <executor>\t<exchange>\t<metrics>
snapshot_list_executors() {
  local snapshot="$1"
  [[ -n "$snapshot" ]] || return 0
  LC_ALL=C awk '
    /^#/ || /^[[:space:]]*$/ { next }
    /^tnauqquant_[A-Za-z0-9_]+\{/ {
      metric = $1
      brace = index(metric, "{")
      if (brace <= 1) next
      mname = substr(metric, 1, brace - 1)
      rest = substr($0, brace + 1)
      close_b = index(rest, "}")
      if (close_b <= 1) next
      labels = substr(rest, 1, close_b - 1)

      ex = ""
      exch = ""
      n = split(labels, parts, ",")
      for (i = 1; i <= n; i++) {
        p = parts[i]
        if (index(p, "executor=\"") == 1 && substr(p, length(p), 1) == "\"") {
          ex = substr(p, 11, length(p) - 11)
        } else if (index(p, "exchange=\"") == 1 && substr(p, length(p), 1) == "\"") {
          exch = substr(p, 11, length(p) - 11)
        }
      }
      if (ex == "") next

      tag = mname
      if (mname == "tnauqquant_current_executor_equity_usdt") tag = "equity"
      else if (mname == "tnauqquant_current_executor_real_pnl_usdt") tag = "real_pnl"
      else if (mname == "tnauqquant_current_executor_cycles_completed") tag = "cycles"
      else if (mname == "tnauqquant_current_run_executor_volume_usd") tag = "volume"

      if (!(ex in seen_ex)) {
        seen_ex[ex] = 1
        order[++cnt] = ex
        ex_exchange[ex] = exch
      }
      key = ex SUBSEP tag
      if (!(key in seen_tag)) {
        seen_tag[key] = 1
        if (ex_tags[ex] == "") ex_tags[ex] = tag
        else ex_tags[ex] = ex_tags[ex] "," tag
      }
    }
    END {
      for (i = 1; i <= cnt; i++) {
        ex = order[i]
        printf "%s\t%s\t%s\n", ex, ex_exchange[ex], ex_tags[ex]
      }
    }
  ' <<<"$snapshot"
}

# Prints any executor=<name> series in a .prom snapshot that violates allowed_map.
# When allowed_map has no shared exchange (single-account or distinct exchanges),
# probe.sh must not emit any executor="..." series at all.
snapshot_unexpected_executors() {
  local snapshot="$1"
  local allowed_map="$2"
  [[ -n "$snapshot" ]] || return 0
  LC_ALL=C awk -v mapping="$allowed_map" '
    BEGIN {
      has_shared = 0
      n = split(mapping, entries, ",")
      for (i = 1; i <= n; i++) {
        eq = index(entries[i], "=")
        if (eq <= 1) continue
        ex = substr(entries[i], 1, eq - 1)
        exch = substr(entries[i], eq + 1)
        allow[ex] = exch
        if (++exch_count[exch] >= 2) has_shared = 1
      }
    }
    /^#/ || /^[[:space:]]*$/ { next }
    /^tnauqquant_[A-Za-z0-9_]+\{/ {
      brace = index($0, "{")
      rest = substr($0, brace + 1)
      close_b = index(rest, "}")
      if (close_b <= 1) next
      labels = substr(rest, 1, close_b - 1)
      ex = ""
      exch = ""
      n = split(labels, parts, ",")
      for (i = 1; i <= n; i++) {
        p = parts[i]
        if (index(p, "executor=\"") == 1 && substr(p, length(p), 1) == "\"") {
          ex = substr(p, 11, length(p) - 11)
        } else if (index(p, "exchange=\"") == 1 && substr(p, length(p), 1) == "\"") {
          exch = substr(p, 11, length(p) - 11)
        }
      }
      if (ex == "") next
      if (!has_shared || !(ex in allow) || (exch != "" && allow[ex] != exch)) {
        item = ex "=" exch
        if (!(item in bad)) {
          bad[item] = 1
          print item
        }
      }
    }
  ' <<<"$snapshot"
}

# Validates that key instance variables appear exactly once as unambiguous
# column-1 VAR=... assignments without executing the env file. Detects leading
# whitespace (which systemd EnvironmentFile= accepts), 'export VAR=', spaces
# before '=', duplicate lines, and backslash line-continuation ambiguity.
validate_env_assignments() {
  local env_file="$1"
  perl -e '
    use strict;
    use warnings;
    my ($path) = @ARGV;
    my @watched = qw(
      TQ_EXECUTOR_MAP
      TQ_STRATEGY
      TQ_SERVER_ID
      TQ_TEXTFILE_DIR
      TQ_TEXTFILE_NAME
    );
    my %watched_set = map { $_ => 1 } @watched;
    my %lines_for = map { $_ => [] } @watched;

    open(my $in, "<:raw", $path) or die "SkyEye trading account: cannot open $path: $!\n";
    local $/;
    my $raw = <$in>;
    close($in);
    defined($raw) or $raw = "";

    my @lines = split(/(?<=\n)/, $raw, -1);
    pop @lines if @lines && $lines[-1] eq "";

    my $prev_continued = 0;
    for my $idx (0..$#lines) {
      my $lineno = $idx + 1;
      my $line = $lines[$idx];
      $line =~ s/\r?\n\z//;

      my $ends_with_cont = 0;
      if ($line !~ /^[ \t]*[#;]/ && $line =~ /(\\+)\z/) {
        $ends_with_cont = (length($1) % 2 == 1) ? 1 : 0;
      }

      if ($prev_continued) {
        if ($line =~ /^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=/ && $watched_set{$1}) {
          die "SkyEye trading account: ambiguous backslash line continuation into $1 at line $lineno in $path; expected exactly one literal $1= line\n";
        }
        $prev_continued = $ends_with_cont;
        next;
      }

      if ($line =~ /^[ \t]*$/ || $line =~ /^[ \t]*[#;]/) {
        next;
      }

      if ($line =~ /^([ \t]*)(export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)([ \t]*)=/) {
        my ($lead_ws, $exp_kw, $var, $pre_eq_ws) = ($1, $2, $3, $4);
        if ($watched_set{$var}) {
          push @{ $lines_for{$var} }, $lineno;
          if ($lead_ws ne "") {
            die "SkyEye trading account: ambiguous $var assignment with leading whitespace at line $lineno in $path (EnvironmentFile= accepts indented assignments); expected exactly one literal $var= line\n";
          }
          if (defined($exp_kw) && $exp_kw ne "") {
            die "SkyEye trading account: ambiguous '\''export'\'' $var assignment at line $lineno in $path; expected exactly one literal $var= line\n";
          }
          if ($pre_eq_ws ne "") {
            die "SkyEye trading account: ambiguous whitespace before '\''='\'' in $var assignment at line $lineno in $path; expected exactly one literal $var= line\n";
          }
          if ($ends_with_cont) {
            die "SkyEye trading account: unsupported trailing backslash continuation in $var at line $lineno in $path; expected exactly one literal $var= line\n";
          }
        }
      }

      $prev_continued = $ends_with_cont;
    }

    for my $var (@watched) {
      my $n = scalar(@{ $lines_for{$var} });
      if ($n != 1) {
        my $where = $n > 0 ? " (lines " . join(",", @{ $lines_for{$var} }) . ")" : "";
        die "SkyEye trading account: expected exactly one literal $var= line in $path, found $n$where\n";
      }
    }
  ' "$env_file"
}

# Replaces ONLY the single TQ_EXECUTOR_MAP= line in raw byte mode, preserving
# every other byte and original line endings (including missing final newline).
rewrite_executor_map_exact() {
  local src="$1" dst="$2" new_val="$3"
  perl -e '
    use strict;
    use warnings;
    my ($src, $dst, $new_val) = @ARGV;
    open(my $in, "<:raw", $src) or die "cannot open $src: $!\n";
    local $/;
    my $raw = <$in>;
    close($in);
    defined($raw) or $raw = "";

    my @lines = split(/(?<=\n)/, $raw, -1);
    pop @lines if @lines && $lines[-1] eq "";

    my @matches = grep { $lines[$_] =~ /^TQ_EXECUTOR_MAP=/ } 0..$#lines;
    die "expected exactly 1 TQ_EXECUTOR_MAP= line, found " . scalar(@matches) . "\n"
      unless @matches == 1;

    my $idx = $matches[0];
    my $ending = ($lines[$idx] =~ /(\r?\n)\z/) ? $1 : "";
    $lines[$idx] = "TQ_EXECUTOR_MAP=" . $new_val . $ending;

    open(my $out, ">:raw", $dst) or die "cannot open $dst: $!\n";
    print $out join("", @lines) or die "cannot write $dst: $!\n";
    close($out) or die "cannot close $dst: $!\n";
  ' "$src" "$dst" "$new_val"
}

# Byte-for-byte check that new_file equals old_file everywhere except the single
# TQ_EXECUTOR_MAP= line, whose original line ending is also preserved.
verify_single_line_env_diff_exact() {
  local old_file="$1" new_file="$2" expected_val="$3"
  perl -e '
    use strict;
    use warnings;
    my ($old_p, $new_p, $want_val) = @ARGV;
    sub slurp {
      open(my $fh, "<:raw", $_[0]) or die "open $_[0]: $!\n";
      local $/;
      my $d = <$fh>;
      close($fh);
      return defined($d) ? $d : "";
    }
    sub split_lines {
      my @l = split(/(?<=\n)/, $_[0], -1);
      pop @l if @l && $l[-1] eq "";
      return @l;
    }
    my @old = split_lines(slurp($old_p));
    my @new = split_lines(slurp($new_p));
    if (scalar(@old) != scalar(@new)) {
      print STDERR "line count changed: old=" . scalar(@old) . " new=" . scalar(@new) . "\n";
      exit 1;
    }
    my $diffs = 0;
    for my $i (0..$#old) {
      if ($old[$i] ne $new[$i]) {
        $diffs++;
        my $ending = ($old[$i] =~ /(\r?\n)\z/) ? $1 : "";
        my $expected = "TQ_EXECUTOR_MAP=" . $want_val . $ending;
        if ($old[$i] !~ /^TQ_EXECUTOR_MAP=/ || $new[$i] ne $expected) {
          print STDERR "unexpected byte diff at line " . ($i + 1) . "\n";
          exit 1;
        }
      }
    }
    if ($diffs != 1) {
      print STDERR "expected exactly 1 changed line, found $diffs\n";
      exit 1;
    }
  ' "$old_file" "$new_file" "$expected_val"
}

file_owner_uid_gid() {
  perl -e '
    use strict;
    use warnings;
    my @s = lstat($ARGV[0]) or exit 1;
    print "$s[4]:$s[5]\n";
  ' "$1"
}

# Atomically writes src_file into target_env using a temp file in target_env's
# directory, preserving owner/group (when root / non-test) and mode 0600.
# When enforce_utc=1 (forward apply), re-checks the UTC 18:10-19:30 guard after
# staging and immediately before mv -f, then marks TX_STARTED=1. Rollback calls
# with enforce_utc=0 so restoring a backup is never blocked by the UTC window.
atomic_replace_env() {
  local src_file="$1" target_env="$2" owner_uid_gid="$3" enforce_utc="${4:-0}"
  local target_dir target_base tmp_path old_umask
  target_dir="$(dirname "$target_env")"
  target_base="$(basename "$target_env")"

  old_umask="$(umask)"
  umask 077
  tmp_path="$(mktemp "$target_dir/.$target_base.tmp.XXXXXX")" || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  STAGED_ENV_TEMP="$tmp_path"

  cp -- "$src_file" "$tmp_path" || return 1
  chmod 600 "$tmp_path" || return 1
  if [[ -z "$TEST_SYSTEM_ROOT" && -n "$owner_uid_gid" ]]; then
    chown "$owner_uid_gid" "$tmp_path" || return 1
  fi
  cmp -s "$src_file" "$tmp_path" || return 1
  if [[ "$enforce_utc" -eq 1 ]]; then
    check_utc_window
    TX_STARTED=1
  fi
  mv -f -- "$tmp_path" "$target_env" || return 1
  STAGED_ENV_TEMP=""
  cmp -s "$src_file" "$target_env" || return 1
  [[ "$(file_mode "$target_env")" == "600" ]] || return 1
  return 0
}

timer_label() {
  case "${1}${2}" in
    11) printf 'enabled/active' ;;
    10) printf 'enabled/inactive' ;;
    01) printf 'disabled/active' ;;
    *)  printf 'disabled/inactive' ;;
  esac
}

# Strict systemd timer query: distinguishes bus/query failures and missing
# units (LoadState=not-found) from genuine disabled/inactive states.
TIMER_QUERY_ENABLED=""
TIMER_QUERY_ACTIVE=""
TIMER_QUERY_ERROR=""
query_timer_state() {
  local unit="$1"
  TIMER_QUERY_ENABLED=""
  TIMER_QUERY_ACTIVE=""
  TIMER_QUERY_ERROR=""

  local out="" err_file="" rc=0 err_msg=""
  err_file="$(mktemp "${TMPDIR:-/tmp}/skyeye-systemctl-err.XXXXXX")"
  SYSTEMCTL_ERR_TMP="$err_file"
  out="$("$SYSTEMCTL_BIN" show --no-pager -p LoadState -p UnitFileState -p ActiveState -- "$unit" 2>"$err_file")" || rc=$?
  if [[ -s "$err_file" ]]; then
    err_msg="$(tr '\n' ' ' <"$err_file" | sed 's/[[:space:]]*$//')"
  fi
  rm -f -- "$err_file"
  SYSTEMCTL_ERR_TMP=""

  if [[ "$rc" -ne 0 ]]; then
    TIMER_QUERY_ERROR="systemctl show failed for $unit (rc=$rc${err_msg:+: $err_msg})"
    return 1
  fi

  local load_state="" unit_file_state="" active_state="" line
  while IFS= read -r line; do
    case "$line" in
      LoadState=*) load_state="${line#LoadState=}" ;;
      UnitFileState=*) unit_file_state="${line#UnitFileState=}" ;;
      ActiveState=*) active_state="${line#ActiveState=}" ;;
    esac
  done <<<"$out"

  if [[ "$load_state" == "not-found" ]]; then
    TIMER_QUERY_ERROR="systemd unit does not exist (LoadState=not-found): $unit"
    return 1
  fi
  if [[ "$load_state" != "loaded" ]]; then
    TIMER_QUERY_ERROR="systemd unit $unit is not loaded (LoadState=${load_state:-missing}${err_msg:+; $err_msg})"
    return 1
  fi

  case "$unit_file_state" in
    enabled|enabled-runtime)
      TIMER_QUERY_ENABLED=1
      ;;
    disabled|static|indirect|masked|masked-runtime|linked|linked-runtime|generated)
      TIMER_QUERY_ENABLED=0
      ;;
    *)
      TIMER_QUERY_ERROR="cannot determine enabled state of $unit (UnitFileState=${unit_file_state:-missing})"
      return 1
      ;;
  esac

  case "$active_state" in
    active|reloading|activating)
      TIMER_QUERY_ACTIVE=1
      ;;
    inactive|failed|deactivating)
      TIMER_QUERY_ACTIVE=0
      ;;
    *)
      TIMER_QUERY_ERROR="cannot determine active state of $unit (ActiveState=${active_state:-missing})"
      return 1
      ;;
  esac
  return 0
}

# Strict systemd probe service query: returns LoadState verification plus
# ActiveState, Result, InvocationID, and ExecMainStartTimestampMonotonic.
SVC_ACTIVE_STATE=""
SVC_RESULT=""
SVC_INVOCATION_ID=""
SVC_EXEC_START_MONO=""
SVC_QUERY_ERROR=""
query_probe_service_state() {
  local unit="$1"
  SVC_ACTIVE_STATE=""
  SVC_RESULT=""
  SVC_INVOCATION_ID=""
  SVC_EXEC_START_MONO=""
  SVC_QUERY_ERROR=""

  local out="" err_file="" rc=0 err_msg=""
  err_file="$(mktemp "${TMPDIR:-/tmp}/skyeye-systemctl-err.XXXXXX")"
  SYSTEMCTL_ERR_TMP="$err_file"
  out="$("$SYSTEMCTL_BIN" show --no-pager \
    -p LoadState -p ActiveState -p Result -p InvocationID -p ExecMainStartTimestampMonotonic \
    -- "$unit" 2>"$err_file")" || rc=$?
  if [[ -s "$err_file" ]]; then
    err_msg="$(tr '\n' ' ' <"$err_file" | sed 's/[[:space:]]*$//')"
  fi
  rm -f -- "$err_file"
  SYSTEMCTL_ERR_TMP=""

  if [[ "$rc" -ne 0 ]]; then
    SVC_QUERY_ERROR="systemctl show failed for $unit (rc=$rc${err_msg:+: $err_msg})"
    return 1
  fi

  local load_state="" line
  while IFS= read -r line; do
    case "$line" in
      LoadState=*) load_state="${line#LoadState=}" ;;
      ActiveState=*) SVC_ACTIVE_STATE="${line#ActiveState=}" ;;
      Result=*) SVC_RESULT="${line#Result=}" ;;
      InvocationID=*) SVC_INVOCATION_ID="${line#InvocationID=}" ;;
      ExecMainStartTimestampMonotonic=*) SVC_EXEC_START_MONO="${line#ExecMainStartTimestampMonotonic=}" ;;
    esac
  done <<<"$out"

  if [[ "$load_state" == "not-found" ]]; then
    SVC_QUERY_ERROR="systemd unit does not exist (LoadState=not-found): $unit"
    return 1
  fi
  if [[ "$load_state" != "loaded" ]]; then
    SVC_QUERY_ERROR="systemd unit $unit is not loaded (LoadState=${load_state:-missing}${err_msg:+; $err_msg})"
    return 1
  fi
  if [[ -z "$SVC_ACTIVE_STATE" ]]; then
    SVC_QUERY_ERROR="cannot determine ActiveState of $unit"
    return 1
  fi
  if [[ -z "$SVC_EXEC_START_MONO" ]]; then
    SVC_EXEC_START_MONO=0
  fi
  [[ "$SVC_EXEC_START_MONO" =~ ^[0-9]+$ ]] || {
    SVC_QUERY_ERROR="unexpected ExecMainStartTimestampMonotonic for $unit: $SVC_EXEC_START_MONO"
    return 1
  }
  return 0
}

# Returns:
#   0 = timer queried cleanly and matches prior enabled/active state
#   1 = timer queried cleanly and drifted from prior state
#   2 = timer could not be queried (systemd error or missing unit)
TIMER_CHECK_ERROR=""
timer_matches_prior() {
  TIMER_CHECK_ERROR=""
  if ! query_timer_state "$INSTANCE_TIMER"; then
    TIMER_CHECK_ERROR="$TIMER_QUERY_ERROR"
    return 2
  fi
  if [[ "$TIMER_QUERY_ENABLED" -eq "$PRIOR_TIMER_ENABLED" && "$TIMER_QUERY_ACTIVE" -eq "$PRIOR_TIMER_ACTIVE" ]]; then
    return 0
  fi
  TIMER_CHECK_ERROR="$INSTANCE_TIMER changed from $(timer_label "$PRIOR_TIMER_ENABLED" "$PRIOR_TIMER_ACTIVE") to $(timer_label "$TIMER_QUERY_ENABLED" "$TIMER_QUERY_ACTIVE")"
  return 1
}

interruptible_sleep() {
  sleep "$1" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=""
}

kill_pending_sleep() {
  if [[ -n "${SLEEP_PID:-}" ]]; then
    kill "$SLEEP_PID" 2>/dev/null || true
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""
  fi
}

# Idempotent transactional rollback shared by verification failures, set -e
# aborts, and HUP/INT/TERM signals. Returns 0 when completely restored, 1 when
# rollback is incomplete (causing exit code 3).
perform_rollback() {
  local reason="$1"
  if [[ "$ROLLBACK_DONE" -eq 1 ]]; then
    return "$ROLLBACK_FAILED"
  fi
  ROLLBACK_DONE=1

  set +e
  kill_pending_sleep
  printf 'SkyEye trading account: %s; restoring backup from %s\n' "$reason" "$BACKUP_ENV" >&2

  # Clean any half-staged forward temp file before staging the backup restore.
  if [[ -n "${STAGED_ENV_TEMP:-}" && -e "$STAGED_ENV_TEMP" ]]; then
    rm -f -- "$STAGED_ENV_TEMP"
    STAGED_ENV_TEMP=""
  fi

  local env_restored=0 timer_preserved=0 timer_status_label="0" timer_check_detail=""
  if [[ -f "$BACKUP_ENV" ]]; then
    if cmp -s "$BACKUP_ENV" "$INSTALL_ENV" && [[ "$(file_mode "$INSTALL_ENV")" == "600" ]]; then
      env_restored=1
    elif atomic_replace_env "$BACKUP_ENV" "$INSTALL_ENV" "$ORIG_ENV_OWNER" 0 2>/dev/null; then
      if cmp -s "$BACKUP_ENV" "$INSTALL_ENV" && [[ "$(file_mode "$INSTALL_ENV")" == "600" ]]; then
        env_restored=1
      fi
    else
      # Remove any half-staged temp file left by a failed atomic_replace_env.
      if [[ -n "${STAGED_ENV_TEMP:-}" && -e "$STAGED_ENV_TEMP" ]]; then
        rm -f -- "$STAGED_ENV_TEMP"
        STAGED_ENV_TEMP=""
      fi
    fi
  fi

  local tm_rc=0
  timer_matches_prior || tm_rc=$?
  if [[ "$tm_rc" -eq 0 ]]; then
    timer_preserved=1
    timer_status_label="1"
  elif [[ "$tm_rc" -eq 2 ]]; then
    timer_preserved=0
    timer_status_label="unknown"
    timer_check_detail="Timer state check UNKNOWN: could not query $INSTANCE_TIMER ($TIMER_CHECK_ERROR)."
  else
    timer_preserved=0
    timer_status_label="0"
    timer_check_detail="Timer state check FAILED: $TIMER_CHECK_ERROR."
  fi

  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    {
      printf 'rollback_reason=%s\n' "$reason"
      printf 'rollback_env_restored=%s\n' "$env_restored"
      printf 'rollback_timer_preserved=%s\n' "$timer_status_label"
    } >>"$BACKUP_DIR/account.meta"
  fi

  if [[ "$env_restored" -eq 1 && "$timer_preserved" -eq 1 ]]; then
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
      printf 'status=rolled_back\n' >>"$BACKUP_DIR/account.meta"
    fi
    printf 'SkyEye trading account: verified original env restored to %s (matches %s) and timer state preserved (%s).\n' \
      "$INSTALL_ENV" "$BACKUP_ENV" "$(timer_label "$PRIOR_TIMER_ENABLED" "$PRIOR_TIMER_ACTIVE")" >&2
    printf 'Backup record: %s\n' "$BACKUP_DIR" >&2
    ROLLBACK_FAILED=0
    return 0
  fi

  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    printf 'status=rollback_incomplete\n' >>"$BACKUP_DIR/account.meta"
  fi

  printf 'CRITICAL: rollback_incomplete (env_restored=%s timer_preserved=%s)\n' \
    "$env_restored" "$timer_status_label" >&2
  if [[ "$env_restored" -ne 1 ]]; then
    printf '%s\n' \
      "Env restore FAILED: $INSTALL_ENV could not be restored to match $BACKUP_ENV." \
      "Manual env recovery and verification:" \
      "  sudo install -m 600 $BACKUP_ENV $INSTALL_ENV" \
      "  sudo cmp -s $BACKUP_ENV $INSTALL_ENV && echo ENV-RESTORED-OK" >&2
  else
    printf 'Env restore OK: %s verified byte-identical to %s (mode 600).\n' \
      "$INSTALL_ENV" "$BACKUP_ENV" >&2
  fi
  if [[ "$timer_preserved" -ne 1 ]]; then
    printf '%s\n' \
      "$timer_check_detail" \
      "Inspect timer state with:" \
      "  sudo systemctl show -p LoadState -p UnitFileState -p ActiveState $INSTANCE_TIMER" >&2
  fi
  printf 'Backup record: %s\n' "$BACKUP_DIR" >&2
  ROLLBACK_FAILED=1
  return 1
}

# Invoked via signal traps below.
# shellcheck disable=SC2329
on_signal() {
  local sig="$1" sig_code="$2"
  trap '' HUP INT TERM
  kill_pending_sleep
  if [[ -z "$ROLLBACK_REASON" ]]; then
    ROLLBACK_REASON="interrupted by SIG$sig"
  fi
  exit "$sig_code"
}

# Invoked via EXIT trap below.
# shellcheck disable=SC2329
on_exit() {
  local status=$?
  # Clear only EXIT so subsequent HUP/INT/TERM signals stay ignored while
  # rollback, verification, metadata recording, and temp cleanup complete.
  trap - EXIT
  trap '' HUP INT TERM
  kill_pending_sleep
  if [[ "$TX_STARTED" -eq 1 && "$TX_COMMITTED" -eq 0 ]]; then
    local reason="${ROLLBACK_REASON:-unexpected exit (rc=$status)}"
    if ! perform_rollback "$reason"; then
      status=3
    elif [[ "$status" -eq 0 ]]; then
      status=1
    fi
  fi
  if [[ -n "${PROM_ERR_TMP:-}" && -e "$PROM_ERR_TMP" ]]; then
    rm -f -- "$PROM_ERR_TMP"
  fi
  if [[ -n "${SYSTEMCTL_ERR_TMP:-}" && -e "$SYSTEMCTL_ERR_TMP" ]]; then
    rm -f -- "$SYSTEMCTL_ERR_TMP"
  fi
  if [[ -n "${STAGED_ENV_TEMP:-}" && -e "$STAGED_ENV_TEMP" ]]; then
    rm -f -- "$STAGED_ENV_TEMP"
  fi
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
  exit "$status"
}

# ---- CLI parsing ----

case "${1:-}" in
  add|remove|list)
    SUBCOMMAND="$1"
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  "")
    usage >&2
    exit 2
    ;;
  *)
    die "unknown subcommand: $1 (expected add, remove, or list)"
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)
      [[ $# -ge 2 ]] || die "--server requires a value"
      SERVER_ID="$2"
      shift 2
      ;;
    --strategy)
      [[ $# -ge 2 ]] || die "--strategy requires a value"
      STRATEGY="$2"
      shift 2
      ;;
    --executor)
      [[ $# -ge 2 ]] || die "--executor requires a value"
      EXECUTOR="$2"
      shift 2
      ;;
    --exchange)
      [[ $# -ge 2 ]] || die "--exchange requires a value"
      EXCHANGE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$STRATEGY" ]] || die "--strategy is required"
valid_label_value "$STRATEGY" || die "invalid strategy name: $STRATEGY"
if [[ -n "$SERVER_ID" ]]; then
  valid_label_value "$SERVER_ID" || die "invalid server_id: $SERVER_ID"
fi

[[ "$MAX_PROM_BYTES" =~ ^[0-9]+$ && "$MAX_PROM_BYTES" -ge 1 ]] || \
  die "SKYEYE_ACCOUNT_MAX_PROM_BYTES must be a positive integer, got: $MAX_PROM_BYTES"

if [[ "$SUBCOMMAND" == "list" ]]; then
  [[ -z "$EXECUTOR" ]] || die "list does not take --executor"
  [[ -z "$EXCHANGE" ]] || die "list does not take --exchange"
  [[ "$DRY_RUN" -eq 0 ]] || die "list does not take --dry-run"
else
  [[ -n "$EXECUTOR" ]] || die "--executor is required for $SUBCOMMAND"
  valid_label_value "$EXECUTOR" || die "invalid executor name: $EXECUTOR"
  if [[ -n "$EXCHANGE" ]]; then
    valid_label_value "$EXCHANGE" || die "invalid exchange name: $EXCHANGE"
  fi
  [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "SKYEYE_ACCOUNT_WAIT_SECONDS must be a non-negative integer, got: $WAIT_SECONDS"
  [[ "$VERIFY_TIMEOUT" =~ ^[0-9]+$ ]] || die "SKYEYE_ACCOUNT_VERIFY_TIMEOUT must be a non-negative integer, got: $VERIFY_TIMEOUT"
  [[ "$POLL_INTERVAL" =~ ^[0-9]+$ && "$POLL_INTERVAL" -ge 1 ]] || \
    die "SKYEYE_ACCOUNT_POLL_INTERVAL must be a positive integer, got: $POLL_INTERVAL"
fi

# Helper: safely read & validate installed env (must be called INSIDE host lock for mutations).
load_installed_instance() {
  INSTALL_ENV_DIR="$(system_path /etc/skyeye-trading)"
  INSTALL_ENV_ROOT="$INSTALL_ENV_DIR/instances"
  INSTALL_ENV="$INSTALL_ENV_ROOT/$STRATEGY.env"

  [[ ! -L "$INSTALL_ENV" ]] || die "installed env must not be a symlink: $INSTALL_ENV"
  [[ -f "$INSTALL_ENV" ]] || \
    die "installed strategy instance not found: $INSTALL_ENV (to onboard a new strategy, follow 'Add or remove a Trading target' in agents/alloy/trading/README.md)"

  local env_mode
  env_mode="$(file_mode "$INSTALL_ENV")"
  [[ "$env_mode" == "600" ]] || die "installed env must have mode 600, found $env_mode: $INSTALL_ENV"

  validate_env_assignments "$INSTALL_ENV" || exit 1

  ENV_STRATEGY="$(installed_env_value TQ_STRATEGY "$INSTALL_ENV")" || \
    die "TQ_STRATEGY in $INSTALL_ENV cannot be read safely"
  [[ "$ENV_STRATEGY" == "$STRATEGY" ]] || \
    die "installed env TQ_STRATEGY ($ENV_STRATEGY) does not match --strategy ($STRATEGY)"

  ENV_SERVER_ID="$(installed_env_value TQ_SERVER_ID "$INSTALL_ENV")" || \
    die "TQ_SERVER_ID in $INSTALL_ENV cannot be read safely"
  [[ -n "$ENV_SERVER_ID" ]] || die "TQ_SERVER_ID is missing in $INSTALL_ENV"
  if [[ -n "$SERVER_ID" && "$ENV_SERVER_ID" != "$SERVER_ID" ]]; then
    die "server_id mismatch: --server is '$SERVER_ID' but $INSTALL_ENV has TQ_SERVER_ID='$ENV_SERVER_ID'"
  fi

  ENV_EXECUTOR_MAP="$(installed_env_value TQ_EXECUTOR_MAP "$INSTALL_ENV")" || \
    die "TQ_EXECUTOR_MAP in $INSTALL_ENV cannot be read safely"
  valid_executor_map "$ENV_EXECUTOR_MAP" || \
    die "existing TQ_EXECUTOR_MAP in $INSTALL_ENV is invalid: $ENV_EXECUTOR_MAP"

  ENV_TEXTFILE_DIR="$(installed_env_value TQ_TEXTFILE_DIR "$INSTALL_ENV")" || \
    die "TQ_TEXTFILE_DIR in $INSTALL_ENV cannot be read safely"
  ENV_TEXTFILE_NAME="$(installed_env_value TQ_TEXTFILE_NAME "$INSTALL_ENV")" || \
    die "TQ_TEXTFILE_NAME in $INSTALL_ENV cannot be read safely"
  [[ "$ENV_TEXTFILE_DIR" == /* && "$ENV_TEXTFILE_DIR" != *[[:space:]\"\']* ]] || \
    die "unsafe TQ_TEXTFILE_DIR in $INSTALL_ENV: $ENV_TEXTFILE_DIR"
  [[ "$ENV_TEXTFILE_NAME" == "tnauqquant-$STRATEGY.prom" ]] || \
    die "TQ_TEXTFILE_NAME in $INSTALL_ENV must be tnauqquant-$STRATEGY.prom, found: $ENV_TEXTFILE_NAME"
  if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
    init_system_root "$ENV_TEXTFILE_DIR"
  fi
  PROM_PATH="$ENV_TEXTFILE_DIR/$ENV_TEXTFILE_NAME"

  EXISTING_EXECUTORS=()
  EXISTING_EXCHANGES=()
  UNIQUE_EXCHANGES=()
  local old_ifs="$IFS" entry ex_name exch_name seen_u u
  IFS=',' read -r -a raw_entries <<<"$ENV_EXECUTOR_MAP"
  IFS="$old_ifs"
  for entry in "${raw_entries[@]}"; do
    ex_name="${entry%%=*}"
    exch_name="${entry#*=}"
    EXISTING_EXECUTORS+=("$ex_name")
    EXISTING_EXCHANGES+=("$exch_name")
    seen_u=0
    for u in ${UNIQUE_EXCHANGES[@]+"${UNIQUE_EXCHANGES[@]}"}; do
      if [[ "$u" == "$exch_name" ]]; then
        seen_u=1
        break
      fi
    done
    if [[ "$seen_u" -eq 0 ]]; then
      UNIQUE_EXCHANGES+=("$exch_name")
    fi
  done
}

# ---- Read-only list subcommand ----

if [[ "$SUBCOMMAND" == "list" ]]; then
  for command_name in awk grep mktemp perl; do
    command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
  done
  init_system_root
  load_installed_instance

  prom_rc=0
  read_prom_snapshot "$PROM_PATH" || prom_rc=$?
  case "$prom_rc" in
    0|10) ;;
    *) die "${PROM_READ_ERROR:-cannot read prom file safely: $PROM_PATH}" ;;
  esac

  printf 'server_id: %s\n' "$ENV_SERVER_ID"
  printf 'strategy: %s\n' "$ENV_STRATEGY"
  printf 'env_file: %s\n' "$INSTALL_ENV"
  if [[ "$prom_rc" -eq 0 ]]; then
    prom_ts="$(snapshot_probe_timestamp "$PROM_SNAPSHOT" "$STRATEGY")"
    printf 'prom_file: %s\n' "$PROM_PATH"
    printf 'probe_timestamp_seconds: %s\n' "${prom_ts:-none}"
  else
    printf 'prom_file: %s (missing)\n' "$PROM_PATH"
    printf 'probe_timestamp_seconds: none\n'
  fi
  printf 'configured_executors (TQ_EXECUTOR_MAP=%s):\n' "$ENV_EXECUTOR_MAP"
  for i in "${!EXISTING_EXECUTORS[@]}"; do
    printf '  %s\t%s\n' "${EXISTING_EXECUTORS[$i]}" "${EXISTING_EXCHANGES[$i]}"
  done
  printf 'prom_series_executors:\n'
  if [[ "$prom_rc" -eq 10 ]]; then
    printf '  (prom file missing)\n'
  else
    prom_execs="$(snapshot_list_executors "$PROM_SNAPSHOT")"
    if [[ -n "$prom_execs" ]]; then
      while IFS=$'\t' read -r p_ex p_exch p_tags; do
        printf '  %s\t%s\t(%s)\n' "$p_ex" "$p_exch" "$p_tags"
      done <<<"$prom_execs"
    else
      printf '  (none)\n'
    fi
  fi
  exit 0
fi

# ---- Mutating subcommands (add / remove) ----

# Early fail-fast UTC window check (checked again inside the lock before writing).
check_utc_window

for command_name in awk cmp cp date grep install mktemp mv perl systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done
init_system_root
resolve_systemctl

# Acquire the SAME host lock used by setup.sh, setup-linux.sh, retire-linux.sh,
# and uninstall.sh BEFORE reading any instance file, and hold it until exit
# (after commit or rollback finishes).
HOST_LOCK="$(system_path /run/skyeye-alloy.lock)"
mkdir -p "$(dirname "$HOST_LOCK")"
if ! skyeye_take_host_lock "$HOST_LOCK"; then
  printf 'SkyEye trading account: %s\n' "$SKYEYE_INSTALL_ERROR" >&2
  print_host_retry_hint "Retry after it finishes"
  exit 1
fi

# Read and validate instance strictly inside the lock.
load_installed_instance

BACKUP_ROOT="$INSTALL_ENV_DIR/account-backup"
INSTANCE_SERVICE="skyeye-trading-probe@$STRATEGY.service"
INSTANCE_TIMER="skyeye-trading-probe@$STRATEGY.timer"

# Compute the new TQ_EXECUTOR_MAP.
NEW_EXECUTOR_MAP=""
TARGET_EXCHANGE=""
INFERRED_EXCHANGE=0
if [[ "$SUBCOMMAND" == "add" ]]; then
  for existing_ex in "${EXISTING_EXECUTORS[@]}"; do
    if [[ "$existing_ex" == "$EXECUTOR" ]]; then
      die "executor '$EXECUTOR' already exists in TQ_EXECUTOR_MAP ($ENV_EXECUTOR_MAP)"
    fi
  done
  if [[ -n "$EXCHANGE" ]]; then
    TARGET_EXCHANGE="$EXCHANGE"
  else
    if [[ "${#UNIQUE_EXCHANGES[@]}" -eq 1 ]]; then
      TARGET_EXCHANGE="${UNIQUE_EXCHANGES[0]}"
      INFERRED_EXCHANGE=1
    else
      die "multiple exchanges present in TQ_EXECUTOR_MAP (${UNIQUE_EXCHANGES[*]}); specify --exchange <name>"
    fi
  fi
  NEW_EXECUTOR_MAP="$ENV_EXECUTOR_MAP,$EXECUTOR=$TARGET_EXCHANGE"
else
  found_index=-1
  found_exchange=""
  for i in "${!EXISTING_EXECUTORS[@]}"; do
    if [[ "${EXISTING_EXECUTORS[$i]}" == "$EXECUTOR" ]]; then
      found_index="$i"
      found_exchange="${EXISTING_EXCHANGES[$i]}"
      break
    fi
  done
  if [[ "$found_index" -lt 0 ]]; then
    die "executor '$EXECUTOR' is not present in TQ_EXECUTOR_MAP ($ENV_EXECUTOR_MAP)"
  fi
  if [[ -n "$EXCHANGE" && "$found_exchange" != "$EXCHANGE" ]]; then
    die "executor '$EXECUTOR' is mapped to exchange '$found_exchange', not '$EXCHANGE'"
  fi
  if [[ "${#EXISTING_EXECUTORS[@]}" -le 1 ]]; then
    die "cannot remove the last executor '$EXECUTOR' from $STRATEGY (TQ_EXECUTOR_MAP must keep at least one executor; to retire the entire strategy use setup-linux.sh retire --strategy $STRATEGY)"
  fi
  TARGET_EXCHANGE="$found_exchange"
  for i in "${!EXISTING_EXECUTORS[@]}"; do
    [[ "$i" -eq "$found_index" ]] && continue
    pair="${EXISTING_EXECUTORS[$i]}=${EXISTING_EXCHANGES[$i]}"
    if [[ -z "$NEW_EXECUTOR_MAP" ]]; then
      NEW_EXECUTOR_MAP="$pair"
    else
      NEW_EXECUTOR_MAP="$NEW_EXECUTOR_MAP,$pair"
    fi
  done
fi

valid_executor_map "$NEW_EXECUTOR_MAP" || \
  die "computed TQ_EXECUTOR_MAP is invalid: $NEW_EXECUTOR_MAP"

if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
  WORK_DIR="$(mktemp -d "$TEST_SYSTEM_ROOT/skyeye-trading-account.XXXXXX")"
else
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-trading-account.XXXXXX")"
fi
chmod 700 "$WORK_DIR"

trap 'on_signal HUP 129' HUP
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap on_exit EXIT

CANDIDATE_ENV="$WORK_DIR/$STRATEGY.env.new"
(
  umask 077
  rewrite_executor_map_exact "$INSTALL_ENV" "$CANDIDATE_ENV" "$NEW_EXECUTOR_MAP"
)
chmod 600 "$CANDIDATE_ENV"

if ! verify_single_line_env_diff_exact "$INSTALL_ENV" "$CANDIDATE_ENV" "$NEW_EXECUTOR_MAP"; then
  die "refusing to apply: staged env changed bytes outside the single TQ_EXECUTOR_MAP line"
fi
validate_env_assignments "$CANDIDATE_ENV" || \
  die "staged env failed assignment validation"
candidate_readback="$(installed_env_value TQ_EXECUTOR_MAP "$CANDIDATE_ENV")" || \
  die "staged env TQ_EXECUTOR_MAP cannot be read back safely"
[[ "$candidate_readback" == "$NEW_EXECUTOR_MAP" ]] || \
  die "staged env TQ_EXECUTOR_MAP readback mismatch"

if ! query_timer_state "$INSTANCE_TIMER"; then
  die "cannot verify probe timer state before writing: $TIMER_QUERY_ERROR"
fi
PRIOR_TIMER_ENABLED="$TIMER_QUERY_ENABLED"
PRIOR_TIMER_ACTIVE="$TIMER_QUERY_ACTIVE"

if ! query_probe_service_state "$INSTANCE_SERVICE"; then
  die "cannot verify probe service state before writing: $SVC_QUERY_ERROR"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'Dry run (%s) for %s/%s:\n' "$SUBCOMMAND" "$ENV_SERVER_ID" "$STRATEGY"
  if [[ "$INFERRED_EXCHANGE" -eq 1 ]]; then
    printf '  inferred_exchange: %s\n' "$TARGET_EXCHANGE"
  fi
  printf '  old TQ_EXECUTOR_MAP: %s\n' "$ENV_EXECUTOR_MAP"
  printf '  new TQ_EXECUTOR_MAP: %s\n' "$NEW_EXECUTOR_MAP"
  printf '  timer_state (preserved): %s\n' "$(timer_label "$PRIOR_TIMER_ENABLED" "$PRIOR_TIMER_ACTIVE")"
  if [[ "$PRIOR_TIMER_ACTIVE" -eq 0 ]]; then
    printf '  note: probe timer is inactive; applying verifies env content and timer state only (no live .prom check)\n'
  fi
  printf 'Dry run: validation passed (no changes made)\n'
  exit 0
fi

# Re-check UTC 18:10-19:30 window INSIDE the lock before creating backups,
# and again inside atomic_replace_env after temp staging immediately before mv.
check_utc_window

# Capture original owner/group before replacing.
ORIG_ENV_OWNER="$(file_owner_uid_gid "$INSTALL_ENV")" || \
  die "cannot inspect ownership of $INSTALL_ENV"

# Create persistent backup before beginning the transaction.
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$timestamp-$STRATEGY-$$"
BACKUP_ENV="$BACKUP_DIR/$STRATEGY.env.before"
install -d -m 700 "$INSTALL_ENV_DIR" "$BACKUP_ROOT" "$BACKUP_DIR"
install -m 600 "$INSTALL_ENV" "$BACKUP_ENV"
cmp -s "$INSTALL_ENV" "$BACKUP_ENV" || die "backup verification failed for $BACKUP_ENV"
{
  printf 'action=%s\n' "$SUBCOMMAND"
  printf 'server_id=%s\n' "$ENV_SERVER_ID"
  printf 'strategy=%s\n' "$STRATEGY"
  printf 'executor=%s\n' "$EXECUTOR"
  printf 'exchange=%s\n' "$TARGET_EXCHANGE"
  printf 'old_executor_map=%s\n' "$ENV_EXECUTOR_MAP"
  printf 'new_executor_map=%s\n' "$NEW_EXECUTOR_MAP"
  printf 'prior_timer_enabled=%s\n' "$PRIOR_TIMER_ENABLED"
  printf 'prior_timer_active=%s\n' "$PRIOR_TIMER_ACTIVE"
  printf 'created_at_utc=%s\n' "$timestamp"
} >"$BACKUP_DIR/account.meta"

printf 'Backup record: %s\n' "$BACKUP_DIR"
if [[ "$INFERRED_EXCHANGE" -eq 1 ]]; then
  printf 'Inferred exchange from existing TQ_EXECUTOR_MAP: %s\n' "$TARGET_EXCHANGE"
fi

# Stage replacement env, re-check UTC window immediately before mv -f, mark
# TX_STARTED=1 right before rename, and atomically replace INSTALL_ENV.
if ! atomic_replace_env "$CANDIDATE_ENV" "$INSTALL_ENV" "$ORIG_ENV_OWNER" 1; then
  if [[ "$TX_STARTED" -eq 1 ]]; then
    ROLLBACK_REASON="atomic replacement of $INSTALL_ENV failed"
    exit 1
  fi
  printf 'status=aborted_before_write\n' >>"$BACKUP_DIR/account.meta"
  die "failed to stage replacement env before rename (original $INSTALL_ENV untouched)"
fi

# Verify according to prior timer state.
FINAL_PROM_TS=""
FINAL_PROM_EXECS=""
if [[ "$PRIOR_TIMER_ACTIVE" -eq 1 ]]; then
  # Record post-write service invocation baseline and .prom baseline so any
  # in-flight probe started before or during the env write is excluded and
  # only a new timer-triggered probe execution started after the write can
  # satisfy verification.
  POST_WRITE_EPOCH="$(date +%s)"
  if ! query_probe_service_state "$INSTANCE_SERVICE"; then
    ROLLBACK_REASON="cannot inspect probe service baseline after write: $SVC_QUERY_ERROR"
    exit 1
  fi
  EXCLUDED_INVOCATION_ID="$SVC_INVOCATION_ID"
  BASELINE_EXEC_MONO="$SVC_EXEC_START_MONO"

  BASELINE_PROM_EXISTS=0
  BASELINE_PROM_TS=""
  base_rc=0
  read_prom_snapshot "$PROM_PATH" || base_rc=$?
  case "$base_rc" in
    0)
      BASELINE_PROM_EXISTS=1
      BASELINE_PROM_TS="$(snapshot_probe_timestamp "$PROM_SNAPSHOT" "$STRATEGY")"
      ;;
    10)
      BASELINE_PROM_EXISTS=0
      ;;
    *)
      ROLLBACK_REASON="${PROM_READ_ERROR:-cannot read prom file safely: $PROM_PATH}"
      exit 1
      ;;
  esac

  verify_start="$SECONDS"
  verify_deadline=$((verify_start + VERIFY_TIMEOUT))
  if [[ "$WAIT_SECONDS" -gt 0 ]]; then
    interruptible_sleep "$WAIT_SECONDS"
  fi
  printf 'Waiting for next timer-triggered probe update to %s (timeout %ss)...\n' \
    "$PROM_PATH" "$VERIFY_TIMEOUT"

  verified=0
  last_fail_reason="probe timer did not publish an updated .prom snapshot within ${VERIFY_TIMEOUT}s"
  while true; do
    tm_rc=0
    timer_matches_prior || tm_rc=$?
    if [[ "$tm_rc" -eq 2 ]]; then
      ROLLBACK_REASON="cannot verify probe timer state during post-write verification: $TIMER_CHECK_ERROR"
      exit 1
    elif [[ "$tm_rc" -ne 0 ]]; then
      ROLLBACK_REASON="probe timer state changed during post-write verification ($TIMER_CHECK_ERROR)"
      exit 1
    fi

    if ! query_probe_service_state "$INSTANCE_SERVICE"; then
      ROLLBACK_REASON="cannot inspect probe service during post-write verification: $SVC_QUERY_ERROR"
      exit 1
    fi
    if [[ "$SVC_ACTIVE_STATE" == "failed" ]]; then
      ROLLBACK_REASON="probe service $INSTANCE_SERVICE entered failed state (Result=${SVC_RESULT:-unknown})"
      exit 1
    fi

    if [[ -z "$SVC_INVOCATION_ID" || "$SVC_INVOCATION_ID" == "$EXCLUDED_INVOCATION_ID" ]]; then
      # Still on the pre-write / in-flight probe invocation (or never run yet).
      # Advance baselines if that excluded invocation finishes and publishes a
      # snapshot so its stale-env output can never satisfy verification.
      if [[ "$SVC_EXEC_START_MONO" -gt "$BASELINE_EXEC_MONO" ]]; then
        BASELINE_EXEC_MONO="$SVC_EXEC_START_MONO"
      fi
      excl_rc=0
      read_prom_snapshot "$PROM_PATH" || excl_rc=$?
      case "$excl_rc" in
        11|12|13|14)
          ROLLBACK_REASON="${PROM_READ_ERROR:-unsafe prom file: $PROM_PATH}"
          exit 1
          ;;
        0)
          excl_ts="$(snapshot_probe_timestamp "$PROM_SNAPSHOT" "$STRATEGY")"
          if [[ -n "$excl_ts" ]]; then
            if [[ "$BASELINE_PROM_EXISTS" -eq 0 || -z "$BASELINE_PROM_TS" || "$excl_ts" -gt "$BASELINE_PROM_TS" ]]; then
              BASELINE_PROM_EXISTS=1
              BASELINE_PROM_TS="$excl_ts"
            fi
          fi
          ;;
      esac
      if [[ -n "$EXCLUDED_INVOCATION_ID" && "$SVC_INVOCATION_ID" == "$EXCLUDED_INVOCATION_ID" ]]; then
        last_fail_reason="waiting for a new timer-triggered probe run after env write (InvocationID $EXCLUDED_INVOCATION_ID started before or during write; timer may not have triggered)"
      else
        last_fail_reason="probe service $INSTANCE_SERVICE has not run after env write; timer may not have triggered"
      fi
    elif [[ "$SVC_ACTIVE_STATE" != "inactive" ]]; then
      last_fail_reason="post-write probe run ($SVC_INVOCATION_ID) is still running (ActiveState=$SVC_ACTIVE_STATE)"
    elif [[ -n "$SVC_RESULT" && "$SVC_RESULT" != "success" ]]; then
      ROLLBACK_REASON="post-write probe service $INSTANCE_SERVICE finished with Result=$SVC_RESULT"
      exit 1
    elif [[ "$SVC_EXEC_START_MONO" -le "$BASELINE_EXEC_MONO" ]]; then
      last_fail_reason="probe ExecMainStartTimestampMonotonic ($SVC_EXEC_START_MONO) did not advance past baseline ($BASELINE_EXEC_MONO); timer may not have triggered"
    else
      snap_rc=0
      read_prom_snapshot "$PROM_PATH" || snap_rc=$?
      case "$snap_rc" in
        11|12|13|14)
          ROLLBACK_REASON="${PROM_READ_ERROR:-unsafe prom file: $PROM_PATH}"
          exit 1
          ;;
        10)
          last_fail_reason="probe output missing: $PROM_PATH"
          ;;
        0)
          if [[ -z "$PROM_SNAPSHOT" ]]; then
            last_fail_reason="probe output is empty: $PROM_PATH"
          else
            cur_ts="$(snapshot_probe_timestamp "$PROM_SNAPSHOT" "$STRATEGY")"
            if [[ -z "$cur_ts" ]]; then
              last_fail_reason="tnauqquant_probe_timestamp_seconds missing in $PROM_PATH"
            elif [[ "$BASELINE_PROM_EXISTS" -eq 1 && -n "$BASELINE_PROM_TS" && "$cur_ts" -le "$BASELINE_PROM_TS" ]]; then
              last_fail_reason="tnauqquant_probe_timestamp_seconds ($cur_ts) did not advance past baseline ($BASELINE_PROM_TS); timer may not have triggered"
            elif [[ "$cur_ts" -le "$POST_WRITE_EPOCH" ]]; then
              last_fail_reason="tnauqquant_probe_timestamp_seconds ($cur_ts) did not advance past env write second ($POST_WRITE_EPOCH); timer may not have triggered"
            else
              unexpected="$(snapshot_unexpected_executors "$PROM_SNAPSHOT" "$NEW_EXECUTOR_MAP")"
              if [[ -n "$unexpected" ]]; then
                last_fail_reason="unexpected executor series in $PROM_PATH: $(printf '%s' "$unexpected" | tr '\n' ' ')"
              else
                FINAL_PROM_TS="$cur_ts"
                FINAL_PROM_EXECS="$(snapshot_list_executors "$PROM_SNAPSHOT")"
                verified=1
                break
              fi
            fi
          fi
          ;;
      esac
    fi

    if [[ "$SECONDS" -ge "$verify_deadline" ]]; then
      break
    fi
    interruptible_sleep "$POLL_INTERVAL"
  done

  if [[ "$verified" -ne 1 ]]; then
    ROLLBACK_REASON="$last_fail_reason"
    exit 1
  fi
else
  # Inactive timer: verify env content/mode and preserved timer state only.
  if ! cmp -s "$CANDIDATE_ENV" "$INSTALL_ENV" || [[ "$(file_mode "$INSTALL_ENV")" != "600" ]]; then
    ROLLBACK_REASON="installed env verification failed after atomic write"
    exit 1
  fi
  tm_rc=0
  timer_matches_prior || tm_rc=$?
  if [[ "$tm_rc" -eq 2 ]]; then
    ROLLBACK_REASON="cannot verify probe timer state after write: $TIMER_CHECK_ERROR"
    exit 1
  elif [[ "$tm_rc" -ne 0 ]]; then
    ROLLBACK_REASON="probe timer state changed from inactive $(timer_label "$PRIOR_TIMER_ENABLED" "$PRIOR_TIMER_ACTIVE") ($TIMER_CHECK_ERROR)"
    exit 1
  fi
fi

printf 'status=committed\n' >>"$BACKUP_DIR/account.meta"
TX_COMMITTED=1

printf '\nAccount %s committed for %s/%s:\n' "$SUBCOMMAND" "$ENV_SERVER_ID" "$STRATEGY"
printf '  old TQ_EXECUTOR_MAP: %s\n' "$ENV_EXECUTOR_MAP"
printf '  new TQ_EXECUTOR_MAP: %s\n' "$NEW_EXECUTOR_MAP"
printf '  timer_state: %s (preserved)\n' "$(timer_label "$PRIOR_TIMER_ENABLED" "$PRIOR_TIMER_ACTIVE")"
if [[ "$PRIOR_TIMER_ACTIVE" -eq 1 ]]; then
  printf '  prom_verified: %s (probe_timestamp_seconds=%s)\n' "$PROM_PATH" "$FINAL_PROM_TS"
  if [[ -n "$FINAL_PROM_EXECS" ]]; then
    printf '  prom_series_executors:\n'
    while IFS=$'\t' read -r p_ex p_exch p_tags; do
      printf '    %s\t%s\t(%s)\n' "$p_ex" "$p_exch" "$p_tags"
    done <<<"$FINAL_PROM_EXECS"
  else
    printf '  prom_series_executors: (none)\n'
  fi
else
  printf '  prom_check: not verified because probe timer remains %s (env content and timer state verified)\n' \
    "$(timer_label "$PRIOR_TIMER_ENABLED" "$PRIOR_TIMER_ACTIVE")"
fi
printf '  backup_record: %s\n' "$BACKUP_DIR"
if [[ "$SUBCOMMAND" == "add" ]]; then
  printf 'Next: add %s to tnauqquant config/env and restart the tnauqquant lane (SkyEye never controls tnauqquant@*).\n' "$EXECUTOR"
else
  printf 'Note: ensure %s was already removed from tnauqquant config/env and the tnauqquant lane restarted.\n' "$EXECUTOR"
fi
