#!/usr/bin/env bash
#
# Install / update Grafana Alloy agent on a SkyEye-monitored machine.
#
# Usage (single-product host):
#   export PRODUCT=ppclub
#   export SERVER_ID=ppclub-prod
#   export JOURNAL_MATCHES='_SYSTEMD_UNIT=ppclub-backend.service _SYSTEMD_UNIT=caddy.service'
#   export LOKI_PUSH_URL=https://loki-push.wanbrain.com/loki/api/v1/push
#   # Optional metrics:
#   export PROM_PUSH_URL=https://prom-push.wanbrain.com/api/v1/write
#   export APP_METRICS_TARGET=localhost:8090
#   # (script will prompt for CF Access Client ID / Secret if unset)
#   sudo -E bash agents/alloy/setup.sh
#
# Usage (shared host running multiple products, e.g. Prod02):
#   # If switching from single-product vars in the same shell, clear them first:
#   unset APP_METRICS_TARGET APP_METRICS_BEARER_TOKEN
#   export PRODUCT=services
#   export SERVER_ID=PROD02
#   export LOKI_PUSH_URL=https://loki-push.wanbrain.com/loki/api/v1/push
#   export PROM_PUSH_URL=https://prom-push.wanbrain.com/api/v1/write
#   export JOURNAL_PRODUCT_MAP='ppclub-backend.service|caddy.service=ppclub;enyoung-menu.service=enyoung;zenincome-api.service|zenincome-web.service=zenincome'
#   export APP_METRICS_PRODUCT_MAP='localhost:8090|localhost:8091@linkcourt-scheduler|localhost:8092=ppclub;127.0.0.1:2112=zenincome'
#   read -rsp 'ppclub metrics bearer token: ' APP_METRICS_BEARER_TOKEN_PPCLUB; echo
#   export APP_METRICS_BEARER_TOKEN_PPCLUB
#   sudo -E bash agents/alloy/setup.sh
#   unset APP_METRICS_BEARER_TOKEN_PPCLUB
#
# Dry-run render (no root, no host changes; writes mode-0600 new file in an
# existing directory; refuses existing paths and /etc/alloy):
#   bash agents/alloy/setup.sh --render-only /tmp/config.alloy
#
# Required:
#   PRODUCT                     host-level product label, e.g. ppclub or services (shared host)
#   SERVER_ID                   unique per host, e.g. ppclub-prod / PROD02
#   JOURNAL_MATCHES             journalctl filter(s), space-separated OR (required unless JOURNAL_PRODUCT_MAP is set)
#   LOKI_PUSH_URL               e.g. https://loki-push.wanbrain.com/loki/api/v1/push
#   CF_ACCESS_CLIENT_ID         (prompt if unset, except with --render-only)
#   CF_ACCESS_CLIENT_SECRET     (prompt if unset, hidden input, except with --render-only)
#
# Optional:
#   PROM_PUSH_URL               central Prometheus remote_write URL (enables node_exporter)
#   JOURNAL_PRODUCT_MAP         shared-host journald map: 'unit1|unit2=product1;unit3=product2'
#   APP_METRICS_TARGET          single-product app /metrics host:port (requires PROM_PUSH_URL)
#   APP_METRICS_BEARER_TOKEN    bearer token for APP_METRICS_TARGET (single-product only)
#   APP_METRICS_PRODUCT_MAP     shared-host app /metrics map (requires PROM_PUSH_URL;
#                               mutually exclusive with APP_METRICS_TARGET):
#                               'addr[@service]|addr2[@service2]=product1;addr3=product2'
#                               Each target carries product="<product>" so host-level
#                               external_labels only apply to host metrics; default service
#                               is "<product>-backend", job_name is "<product>-backend".
#   APP_METRICS_BEARER_TOKEN_<PRODUCT>
#                               per-product bearer token for APP_METRICS_PRODUCT_MAP, where
#                               <PRODUCT> is uppercased with '-' replaced by '_'
#                               (e.g. APP_METRICS_BEARER_TOKEN_PPCLUB)
#
# Supports: Ubuntu / Debian (apt); other distros need manual install.
#
# The live config is only replaced after the new one passed `alloy validate`,
# and is restored if Alloy then fails to start. See "How setup.sh handles
# failure" in README.md for the exit codes and what stays on disk.
#
# Alloy must be a version listed in alloy-versions.env; a host without Alloy
# gets the pinned apt version, held. Only one SkyEye Alloy install, Trading
# add/retire or uninstall runs at a time on a host (see "Alloy versions" and
# "One run at a time" in README.md).

set -euo pipefail

RENDER_ONLY_PATH=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --render-only)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: --render-only requires an output file path" >&2
        exit 2
      fi
      RENDER_ONLY_PATH=$2
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Usage: bash agents/alloy/setup.sh [--render-only PATH]" >&2
      exit 2
      ;;
  esac
done
if [ -n "$RENDER_ONLY_PATH" ]; then
  case "$RENDER_ONLY_PATH" in
    */)
      echo "ERROR: --render-only path must be a new file, not a directory: $RENDER_ONLY_PATH" >&2
      exit 2
      ;;
  esac
  case "$RENDER_ONLY_PATH" in
    /*) ;;
    *) RENDER_ONLY_PATH="$PWD/$RENDER_ONLY_PATH" ;;
  esac
  if [ -e "$RENDER_ONLY_PATH" ] || [ -L "$RENDER_ONLY_PATH" ]; then
    echo "ERROR: --render-only only writes a new file; destination already exists: $RENDER_ONLY_PATH" >&2
    exit 2
  fi
  render_parent="$(dirname "$RENDER_ONLY_PATH")"
  if [ ! -d "$render_parent" ]; then
    echo "ERROR: --render-only parent directory does not exist: $render_parent" >&2
    exit 2
  fi
fi

cd "$(dirname "$0")"

ALLOY_CONFIG=/etc/alloy/config.alloy
# Shared with trading/setup-linux.sh, retire-linux.sh and uninstall.sh. /run is
# writable only by root, so no other user can create or hold this file.
LOCK_FILE=/run/skyeye-alloy.lock

# These live next to the config so every rename stays on one filesystem. None
# may end in .alloy: with CONFIG_FILE=/etc/alloy, Alloy loads every *.alloy in
# the directory, dotfiles included.
ALLOY_PREVIOUS="$ALLOY_CONFIG.previous"   # config replaced by the last good run
ALLOY_ROLLBACK="$ALLOY_CONFIG.rollback"   # exists only while this run is in flight

# ───────────────────────────── 1. Validate env ─────────────────────────────

require_env() {
  local name=$1
  if [ -z "${!name:-}" ]; then
    echo "ERROR: \$${name} is required. See usage at top of script." >&2
    exit 2
  fi
}

trim_ws() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

to_env_suffix() {
  local s=$1 i ch out=""
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    case "$ch" in
      a) ch=A ;; b) ch=B ;; c) ch=C ;; d) ch=D ;; e) ch=E ;; f) ch=F ;;
      g) ch=G ;; h) ch=H ;; i) ch=I ;; j) ch=J ;; k) ch=K ;; l) ch=L ;;
      m) ch=M ;; n) ch=N ;; o) ch=O ;; p) ch=P ;; q) ch=Q ;; r) ch=R ;;
      s) ch=S ;; t) ch=T ;; u) ch=U ;; v) ch=V ;; w) ch=W ;; x) ch=X ;;
      y) ch=Y ;; z) ch=Z ;; -) ch=_ ;;
    esac
    out+="$ch"
  done
  printf '%s' "$out"
}

to_lower() {
  local s=$1 i ch out=""
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    case "$ch" in
      A) ch=a ;; B) ch=b ;; C) ch=c ;; D) ch=d ;; E) ch=e ;; F) ch=f ;;
      G) ch=g ;; H) ch=h ;; I) ch=i ;; J) ch=j ;; K) ch=k ;; L) ch=l ;;
      M) ch=m ;; N) ch=n ;; O) ch=o ;; P) ch=p ;; Q) ch=q ;; R) ch=r ;;
      S) ch=s ;; T) ch=t ;; U) ch=u ;; V) ch=v ;; W) ch=w ;; X) ch=x ;;
      Y) ch=y ;; Z) ch=z ;;
    esac
    out+="$ch"
  done
  printf '%s' "$out"
}

validate_bearer_token() {
  local var_name=$1 val=$2
  case "$val" in
    *[[:cntrl:]]*|*\"*|*\\*)
      echo "ERROR: $var_name must not contain double quotes, backslashes, or control characters" >&2
      exit 2
      ;;
  esac
}

validate_host_port() {
  local addr=$1 host="" port=""
  local ipv6_re='^\[([0-9A-Fa-f:.]+)\]:([1-9][0-9]*)$'
  local hostport_re='^([^:]+):([1-9][0-9]*)$'
  local ipv4_chars_re='^[0-9.]+$'
  local digits_re='^[0-9]+$'
  local hostname_re='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'
  case "$addr" in
    *[[:space:]]*|*\"*|*\\*|*[[:cntrl:]]*|*/*|*\?*|*\#*)
      return 1
      ;;
  esac
  if [[ "$addr" == \[* ]]; then
    [[ "$addr" =~ $ipv6_re ]] || return 1
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    [[ "$host" == *:* ]] || return 1
  else
    [[ "$addr" =~ $hostport_re ]] || return 1
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    if [[ "$host" =~ $ipv4_chars_re ]]; then
      local IFS='.'
      local octets=() o
      read -ra octets <<< "$host"
      [ "${#octets[@]}" -eq 4 ] || return 1
      [[ "$host" != *. ]] || return 1
      for o in "${octets[@]}"; do
        [[ "$o" =~ $digits_re ]] || return 1
        if [ "${#o}" -gt 1 ] && [[ "$o" == 0* ]]; then
          return 1
        fi
        [ "$o" -le 255 ] || return 1
      done
    else
      [[ "$host" =~ $hostname_re ]] || return 1
    fi
  fi
  [ "${#port}" -le 5 ] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

check_render_only_target_safe() {
  local render_path=$1 cfg_path=$2 prev_path=$3 roll_path=$4 lock_path=$5
  if ! command -v perl >/dev/null 2>&1; then
    echo "ERROR: perl not found (Debian/Ubuntu package: perl-base)" >&2
    exit 2
  fi
  perl -e '
    use strict;
    use warnings;

    sub resolve_path {
      my ($p) = @_;
      my @parts = split(m{/+}, $p);
      my $cur = "/";
      my $depth = 0;
      while (@parts) {
        my $seg = shift @parts;
        next if $seg eq "" || $seg eq ".";
        if ($seg eq "..") {
          $cur =~ s{/[^/]+$}{};
          $cur = "/" if $cur eq "";
          next;
        }
        my $next = ($cur eq "/") ? "/$seg" : "$cur/$seg";
        if (-l $next) {
          die "too many symlinks\n" if ++$depth > 40;
          my $target = readlink($next);
          die "readlink failed\n" unless defined $target;
          $cur = "/" if $target =~ m{^/};
          unshift @parts, split(m{/+}, $target);
        } else {
          $cur = $next;
        }
      }
      return $cur;
    }

    sub parent_of {
      my ($p) = @_;
      $p =~ s{/+$}{} unless $p eq "/";
      return "/" if $p eq "/" || $p !~ m{/};
      $p =~ s{/[^/]+$}{};
      return $p eq "" ? "/" : $p;
    }

    sub in_dir {
      my ($path, $dir) = @_;
      return 1 if $path eq $dir;
      my $prefix = ($dir eq "/") ? "/" : "$dir/";
      return index($path, $prefix) == 0;
    }

    my ($render, $cfg, $prev, $roll, $lock) = @ARGV;
    my $r_target = resolve_path($render);
    my $r_parent = resolve_path(parent_of($render));
    my $cfg_dir  = resolve_path(parent_of($cfg));
    my @managed  = map { resolve_path($_) } ($cfg, $prev, $roll, $lock);

    exit 1 if in_dir($r_target, $cfg_dir) || in_dir($r_parent, $cfg_dir);
    for my $mf (@managed) {
      exit 1 if $r_target eq $mf;
    }
    exit 0;
  ' "$render_path" "$cfg_path" "$prev_path" "$roll_path" "$lock_path"
}

if [ -n "$RENDER_ONLY_PATH" ]; then
  if ! check_render_only_target_safe "$RENDER_ONLY_PATH" "$ALLOY_CONFIG" "$ALLOY_PREVIOUS" "$ALLOY_ROLLBACK" "$LOCK_FILE"; then
    echo "ERROR: --render-only refuses to write inside managed Alloy config directory ($(dirname "$ALLOY_CONFIG")) or managed paths" >&2
    exit 2
  fi
fi

require_env PRODUCT
require_env SERVER_ID
if [ -z "${JOURNAL_PRODUCT_MAP:-}" ]; then
  require_env JOURNAL_MATCHES
fi
require_env LOKI_PUSH_URL

if [ -n "${APP_METRICS_TARGET:-}" ] && [ -n "${APP_METRICS_PRODUCT_MAP:-}" ]; then
  echo "ERROR: APP_METRICS_TARGET and APP_METRICS_PRODUCT_MAP cannot both be set" >&2
  exit 2
fi

if [ -n "${APP_METRICS_TARGET:-}" ] && [ -z "${PROM_PUSH_URL:-}" ]; then
  echo "ERROR: APP_METRICS_TARGET requires PROM_PUSH_URL to be set too" >&2
  exit 2
fi

if [ -n "${APP_METRICS_PRODUCT_MAP:-}" ] && [ -z "${PROM_PUSH_URL:-}" ]; then
  echo "ERROR: APP_METRICS_PRODUCT_MAP requires PROM_PUSH_URL to be set too" >&2
  exit 2
fi

if [ -n "${APP_METRICS_PRODUCT_MAP:-}" ] && [ -n "${APP_METRICS_BEARER_TOKEN:-}" ]; then
  echo "ERROR: APP_METRICS_BEARER_TOKEN cannot be used with APP_METRICS_PRODUCT_MAP; set per-product APP_METRICS_BEARER_TOKEN_<PRODUCT> instead" >&2
  exit 2
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "ERROR: envsubst not found (Debian/Ubuntu package: gettext-base)" >&2
  exit 2
fi

TEMPLATES=(config-logs.alloy.tmpl)
if [ -n "${PROM_PUSH_URL:-}" ]; then
  TEMPLATES+=(config-metrics.alloy.tmpl)
fi
if [ -n "${APP_METRICS_TARGET:-}" ]; then
  TEMPLATES+=(config-app.alloy.tmpl)
fi
for template in "${TEMPLATES[@]}"; do
  if [ ! -r "$template" ]; then
    echo "ERROR: template $template is missing or unreadable" >&2
    exit 2
  fi
done

if [ -z "$RENDER_ONLY_PATH" ]; then
  if [ ! -r install-common.sh ]; then
    echo "ERROR: install-common.sh is missing; copy the whole agents/alloy directory" >&2
    exit 2
  fi
  # shellcheck source=agents/alloy/install-common.sh
  . ./install-common.sh
  if ! skyeye_load_alloy_versions; then
    echo "ERROR: $SKYEYE_INSTALL_ERROR" >&2
    exit 2
  fi
fi

if [ -z "$RENDER_ONLY_PATH" ]; then
  if [ -z "${CF_ACCESS_CLIENT_ID:-}" ]; then
    read -rp "CF Access Client ID (xxx.access): " CF_ACCESS_CLIENT_ID
  fi
  if [ -z "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
    read -rsp "CF Access Client Secret (hidden): " CF_ACCESS_CLIENT_SECRET
    echo
  fi
fi
require_env CF_ACCESS_CLIENT_ID
require_env CF_ACCESS_CLIENT_SECRET

APP_METRICS_AUTHORIZATION=""
if [ -n "${APP_METRICS_BEARER_TOKEN:-}" ]; then
  validate_bearer_token APP_METRICS_BEARER_TOKEN "$APP_METRICS_BEARER_TOKEN"
  # shellcheck disable=SC2089
  APP_METRICS_AUTHORIZATION="  authorization {
    type        = \"Bearer\"
    credentials = \"${APP_METRICS_BEARER_TOKEN}\"
  }"
fi

APP_MAP_PRODUCTS=()
APP_MAP_COMP_IDS=()
APP_MAP_ENV_SUFFIXES=()
APP_MAP_TARGET_LINES=()
APP_MAP_SEEN_ADDRS=()
APP_MAP_SEEN_ADDR_PRODUCTS=()
APP_METRICS_MAP_CONFIG=""
if [ -n "${APP_METRICS_PRODUCT_MAP:-}" ]; then
  case "$APP_METRICS_PRODUCT_MAP" in
    *$'\n'*)
      echo "ERROR: APP_METRICS_PRODUCT_MAP must be a single line" >&2
      exit 2
      ;;
  esac
  rest="$APP_METRICS_PRODUCT_MAP"
  while :; do
    if [[ "$rest" == *";"* ]]; then
      entry="${rest%%;*}"
      rest="${rest#*;}"
      has_more=1
    else
      entry="$rest"
      has_more=0
    fi
    entry="$(trim_ws "$entry")"
    if [ -z "$entry" ]; then
      echo "ERROR: APP_METRICS_PRODUCT_MAP contains an empty entry" >&2
      exit 2
    fi
    if [[ "$entry" != *=* ]]; then
      echo "ERROR: APP_METRICS_PRODUCT_MAP entry '$entry' must have the form 'targets=product'" >&2
      exit 2
    fi
    targets_spec="$(trim_ws "${entry%%=*}")"
    product_val="$(trim_ws "${entry#*=}")"
    if [[ "$product_val" == *=* ]]; then
      echo "ERROR: APP_METRICS_PRODUCT_MAP entry '$entry' must contain only one '='" >&2
      exit 2
    fi
    if [ -z "$targets_spec" ]; then
      echo "ERROR: APP_METRICS_PRODUCT_MAP entry '$entry' has no target before '='" >&2
      exit 2
    fi
    if [[ ! "$product_val" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
      echo "ERROR: APP_METRICS_PRODUCT_MAP has invalid product '$product_val'" >&2
      exit 2
    fi
    comp_id="app_${product_val//-/_}"
    env_suffix="$(to_env_suffix "$product_val")"
    found_idx=-1
    for ((idx = 0; idx < ${#APP_MAP_PRODUCTS[@]}; idx++)); do
      if [ "${APP_MAP_PRODUCTS[$idx]}" = "$product_val" ]; then
        found_idx=$idx
        break
      fi
      if [ "${APP_MAP_COMP_IDS[$idx]}" = "$comp_id" ] || [ "${APP_MAP_ENV_SUFFIXES[$idx]}" = "$env_suffix" ]; then
        echo "ERROR: APP_METRICS_PRODUCT_MAP products '${APP_MAP_PRODUCTS[$idx]}' and '$product_val' collide in Alloy identifier or bearer token variable name" >&2
        exit 2
      fi
    done
    if [ "$found_idx" -lt 0 ]; then
      found_idx=${#APP_MAP_PRODUCTS[@]}
      APP_MAP_PRODUCTS+=("$product_val")
      APP_MAP_COMP_IDS+=("$comp_id")
      APP_MAP_ENV_SUFFIXES+=("$env_suffix")
      APP_MAP_TARGET_LINES+=("")
    fi

    t_rest="$targets_spec"
    while :; do
      if [[ "$t_rest" == *"|"* ]]; then
        item="${t_rest%%|*}"
        t_rest="${t_rest#*|}"
        t_more=1
      else
        item="$t_rest"
        t_more=0
      fi
      item="$(trim_ws "$item")"
      if [ -z "$item" ]; then
        echo "ERROR: APP_METRICS_PRODUCT_MAP has an empty target for product '$product_val'" >&2
        exit 2
      fi
      if [[ "$item" == *@* ]]; then
        addr="$(trim_ws "${item%%@*}")"
        service_val="$(trim_ws "${item#*@}")"
        if [[ "$service_val" == *@* ]]; then
          echo "ERROR: APP_METRICS_PRODUCT_MAP target '$item' must contain at most one '@'" >&2
          exit 2
        fi
        if [[ ! "$service_val" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
          echo "ERROR: APP_METRICS_PRODUCT_MAP target '$item' has invalid service '$service_val'" >&2
          exit 2
        fi
      else
        addr="$item"
        service_val="${product_val}-backend"
      fi
      if [ -z "$addr" ]; then
        echo "ERROR: APP_METRICS_PRODUCT_MAP target '$item' has an empty address" >&2
        exit 2
      fi
      if ! validate_host_port "$addr"; then
        echo "ERROR: APP_METRICS_PRODUCT_MAP has invalid host:port address '$addr' (use host:port without URL scheme, path, or query)" >&2
        exit 2
      fi
      addr_key="$(to_lower "$addr")"
      for ((seen_idx = 0; seen_idx < ${#APP_MAP_SEEN_ADDRS[@]}; seen_idx++)); do
        if [ "${APP_MAP_SEEN_ADDRS[$seen_idx]}" = "$addr_key" ] && [ "${APP_MAP_SEEN_ADDR_PRODUCTS[$seen_idx]}" != "$product_val" ]; then
          echo "ERROR: APP_METRICS_PRODUCT_MAP assigns address '$addr' to multiple products ('${APP_MAP_SEEN_ADDR_PRODUCTS[$seen_idx]}' and '$product_val')" >&2
          exit 2
        fi
      done
      APP_MAP_SEEN_ADDRS+=("$addr_key")
      APP_MAP_SEEN_ADDR_PRODUCTS+=("$product_val")
      APP_MAP_TARGET_LINES[found_idx]+="    { __address__ = \"${addr}\", service = \"${service_val}\", product = \"${product_val}\" },"$'\n'
      [ "$t_more" -eq 1 ] || break
    done
    [ "$has_more" -eq 1 ] || break
  done

  APP_METRICS_MAP_CONFIG="// Generated by agents/alloy/setup.sh (Phase 2C multi-product app scrape section)
// Appended when APP_METRICS_PRODUCT_MAP is set.
//
// Pipeline: backend /metrics → scrape (per product) → remote_write (shared with node)
// Each target sets its own product label so remote_write external_labels only
// apply to host-level series (e.g. product=\"services\").

////////////////////////////////////////////////////////////////////////////////
// 9. Scrape: application /metrics endpoints (one scrape block per product)
////////////////////////////////////////////////////////////////////////////////"

  for ((idx = 0; idx < ${#APP_MAP_PRODUCTS[@]}; idx++)); do
    product_val="${APP_MAP_PRODUCTS[$idx]}"
    comp_id="${APP_MAP_COMP_IDS[$idx]}"
    env_suffix="${APP_MAP_ENV_SUFFIXES[$idx]}"
    token_var="APP_METRICS_BEARER_TOKEN_${env_suffix}"
    token_val="${!token_var:-}"
    auth_block=""
    if [ -n "$token_val" ]; then
      validate_bearer_token "$token_var" "$token_val"
      auth_block="  authorization {
    type        = \"Bearer\"
    credentials = \"${token_val}\"
  }
"
    fi
    APP_METRICS_MAP_CONFIG+="

prometheus.scrape \"${comp_id}\" {
  targets = [
${APP_MAP_TARGET_LINES[$idx]}  ]
  forward_to      = [prometheus.remote_write.central.receiver]
  scrape_interval = \"15s\"
  scrape_timeout  = \"10s\"
  job_name        = \"${product_val}-backend\"
  metrics_path    = \"/metrics\"
${auth_block}  // If the app is slow on startup or reloads, avoid immediately flagging down
  honor_labels    = false
}"
  done
  APP_METRICS_MAP_CONFIG+=$'\n'
fi

# Only listed variables get substituted — unlisted $vars (including Alloy
# regex capture refs like $1) stay intact.
# shellcheck disable=SC2016
ENVSUBST_VARS='$PRODUCT $SERVER_ID $JOURNAL_MATCHES $LOKI_PUSH_URL $CF_ACCESS_CLIENT_ID $CF_ACCESS_CLIENT_SECRET $PROM_PUSH_URL $APP_METRICS_TARGET $APP_METRICS_AUTHORIZATION $JOURNAL_SOURCES'

render_alloy_config() {
  local target_file=$1

  # Build JOURNAL_SOURCES — one loki.source.journal block per product.
  #   JOURNAL_PRODUCT_MAP unset → single source covering all JOURNAL_MATCHES,
  #                                tagged product=$PRODUCT.
  #   JOURNAL_PRODUCT_MAP set   → parse 'units_spec=product;units_spec=product'
  #                                and emit one source per product. Each source's
  #                                matches filter is built from units_spec (the
  #                                part before the `=`), which supports | as a
  #                                unit separator (e.g. "a.service|b.service").
  #                                Backslash-escapes in units_spec are stripped
  #                                (so \.service is treated as .service).
  #
  # Example for a shared host:
  #   export JOURNAL_PRODUCT_MAP='ppclub-backend.service|caddy.service=ppclub;enyoung-menu.service=enyoung'
  JOURNAL_SOURCES=""
  if [ -n "${JOURNAL_PRODUCT_MAP:-}" ]; then
    echo "==> JOURNAL_PRODUCT_MAP set — multi-tenant: one journal source per product"
    IFS=';' read -ra PAIRS <<< "$JOURNAL_PRODUCT_MAP"
    for pair in "${PAIRS[@]}"; do
      pair="${pair# }"
      units_spec="${pair%=*}"        # e.g. "a.service|b.service"
      product_val="${pair##*=}"      # e.g. "ppclub"

      # Strip any backslash escapes left over from regex-style syntax
      units_spec_clean="${units_spec//\\/}"

      # Split on | and build the journalctl matches string:
      #   "_SYSTEMD_UNIT=a.service _SYSTEMD_UNIT=b.service"
      IFS='|' read -ra UNITS <<< "$units_spec_clean"
      matches_str=""
      for u in "${UNITS[@]}"; do
        matches_str+=" _SYSTEMD_UNIT=${u}"
      done
      matches_str="${matches_str# }"

      JOURNAL_SOURCES+="
loki.source.journal \"${product_val}\" {
  matches    = \"${matches_str}\"
  max_age    = \"5m\"
  forward_to = [loki.process.scrub_pii.receiver]
  labels     = {
    product   = \"${product_val}\",
    server_id = \"${SERVER_ID}\",
    job       = \"journald\",
  }
}
"
    done
  else
    # Single-tenant: one source covering JOURNAL_MATCHES, tagged $PRODUCT
    # shellcheck disable=SC2089
    JOURNAL_SOURCES="
loki.source.journal \"system\" {
  matches    = \"${JOURNAL_MATCHES}\"
  max_age    = \"5m\"
  forward_to = [loki.process.scrub_pii.receiver]
  labels     = {
    product   = \"${PRODUCT}\",
    server_id = \"${SERVER_ID}\",
    job       = \"journald\",
  }
}
"
  fi

  JOURNAL_MATCHES="${JOURNAL_MATCHES:-}"
  # shellcheck disable=SC2090
  export PRODUCT SERVER_ID JOURNAL_MATCHES LOKI_PUSH_URL \
         CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET \
         PROM_PUSH_URL APP_METRICS_TARGET APP_METRICS_AUTHORIZATION JOURNAL_SOURCES

  # Always: logs section (Phase 2A)
  envsubst "$ENVSUBST_VARS" < config-logs.alloy.tmpl > "$target_file"

  # Phase 2B: append node metrics section when PROM_PUSH_URL is set
  if [ -n "${PROM_PUSH_URL:-}" ]; then
    echo "==> PROM_PUSH_URL set — appending node metrics section"
    envsubst "$ENVSUBST_VARS" < config-metrics.alloy.tmpl >> "$target_file"
  else
    echo "==> PROM_PUSH_URL unset — log-only mode (Phase 2A)"
  fi

  # Phase 2C: append app /metrics scrape when APP_METRICS_TARGET or APP_METRICS_PRODUCT_MAP is set
  if [ -n "${APP_METRICS_TARGET:-}" ]; then
    echo "==> APP_METRICS_TARGET set ($APP_METRICS_TARGET) — appending app scrape section"
    envsubst "$ENVSUBST_VARS" < config-app.alloy.tmpl >> "$target_file"
  elif [ -n "${APP_METRICS_PRODUCT_MAP:-}" ]; then
    echo "==> APP_METRICS_PRODUCT_MAP set (${#APP_MAP_PRODUCTS[@]} products) — appending multi-product app scrape section"
    printf '%s' "$APP_METRICS_MAP_CONFIG" >> "$target_file"
  fi
}

if [ -n "$RENDER_ONLY_PATH" ]; then
  render_tmp="$(mktemp "$RENDER_ONLY_PATH.tmp.XXXXXX")"
  trap 'rm -f "$render_tmp"' EXIT
  render_alloy_config "$render_tmp"
  if [ ! -s "$render_tmp" ]; then
    echo "ERROR: rendered config is empty." >&2
    exit 1
  fi
  if ! perl -e 'link($ARGV[0], $ARGV[1]) or exit 1' "$render_tmp" "$RENDER_ONLY_PATH"; then
    echo "ERROR: --render-only could not create $RENDER_ONLY_PATH (destination already exists or link failed)" >&2
    exit 1
  fi
  rm -f "$render_tmp"
  trap - EXIT
  echo "==> Rendered config written to $RENDER_ONLY_PATH"
  exit 0
fi

# ───────────────────────────── 2. Root check ───────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root (use sudo -E so env vars carry over)." >&2
  exit 1
fi

# ───────────────────────────── 3. Lock + target state ──────────────────────

# Held until this script exits. Taken before anything below reads the host.
if ! skyeye_take_host_lock "$LOCK_FILE"; then
  echo "ERROR: $SKYEYE_INSTALL_ERROR." >&2
  exit 1
fi

# mv replaces a symlink instead of writing through it, and moves into a directory.
if [ -L "$ALLOY_CONFIG" ] || { [ -e "$ALLOY_CONFIG" ] && [ ! -f "$ALLOY_CONFIG" ]; }; then
  echo "ERROR: $ALLOY_CONFIG must be a regular file; refusing to replace it." >&2
  exit 1
fi
if [ -e "$ALLOY_ROLLBACK" ]; then
  echo "ERROR: $ALLOY_ROLLBACK exists, so an earlier run did not finish." >&2
  echo "       It holds the config from before that run. Compare it with" >&2
  echo "       $ALLOY_CONFIG, then move it over the config or delete it, and re-run." >&2
  exit 1
fi

# ───────────────────────────── 4. Install Alloy ────────────────────────────

if ! command -v alloy >/dev/null 2>&1; then
  echo "==> Installing Grafana Alloy $SKYEYE_ALLOY_APT_VERSION via apt"
  apt-get install -y ca-certificates curl gnupg wget lsb-release >/dev/null
  mkdir -p /etc/apt/keyrings/
  wget -q -O - https://apt.grafana.com/gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg --yes
  chmod 644 /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt-get update -qq
  apt-get install -y "alloy=$SKYEYE_ALLOY_APT_VERSION"
  # Keeps apt upgrades, unattended ones included, on the tested version.
  apt-mark hold alloy
fi

# An Alloy that was already installed is checked here, never upgraded or held.
if ! skyeye_alloy_version_gate linux; then
  echo "ERROR: $SKYEYE_INSTALL_ERROR." >&2
  echo "       $ALLOY_CONFIG was not changed." >&2
  exit 1
fi
echo "==> Alloy $SKYEYE_ALLOY_VERSION"

# `alloy fmt` only parses, so it passes configs that cannot run. `validate`
# shipped in v1.9.0; older versions exit non-zero with "unknown command". Every
# tested version has it, so only SKYEYE_ALLOY_UNTESTED_VERSION can reach this.
if ! alloy validate --help >/dev/null 2>&1; then
  echo "ERROR: this Alloy has no validate command: $(alloy --version | head -1)" >&2
  echo "       Upgrade to Alloy v1.9.0 or newer, then re-run. $ALLOY_CONFIG was not changed." >&2
  exit 1
fi

# ───────────────────────────── 5. Render config ────────────────────────────

STAGED_CONFIG=""
HAD_PREVIOUS=0
ALLOY_WAS_ACTIVE=0
CONFIG_SWAPPED=0   # 1 from the swap until the new config has proven healthy

# Alloy runs under Restart=always, so a single is-active sample can land on a
# crash loop's up phase. Require one unbroken main process across the window.
alloy_stays_up() {
  local first="" current _
  for _ in 1 2 3 4 5; do
    sleep 1
    systemctl is-active --quiet alloy || return 1
    current="$(systemctl show -p MainPID alloy)" || return 1
    if [ -z "$first" ]; then
      first=$current
    fi
    [ "$current" = "$first" ] || return 1
  done
}

# Puts the host back the way this run found it. Runs from the EXIT trap, where
# set -e is off, so each step reports its own failure. Do not add a bare
# `return`: in a trap handler it yields the status from before the trap ran.
rollback() {
  if [ "$HAD_PREVIOUS" -eq 0 ]; then
    echo "==> No previous config: removing $ALLOY_CONFIG and stopping alloy" >&2
    rm -f "$ALLOY_CONFIG" && systemctl stop alloy
  else
    echo "==> Restoring the previous $ALLOY_CONFIG" >&2
    mv -f "$ALLOY_ROLLBACK" "$ALLOY_CONFIG" || return 1
    if [ "$ALLOY_WAS_ACTIVE" -eq 1 ]; then
      systemctl restart alloy && alloy_stays_up
    else
      systemctl stop alloy
    fi
  fi
}

on_exit() {
  local status=$?
  trap - EXIT
  trap '' HUP INT TERM
  if [ "$CONFIG_SWAPPED" -eq 1 ]; then
    if rollback; then
      echo "ERROR: install failed; the host is back to its state before this run." >&2
    else
      status=3
      echo "CRITICAL: rollback did not finish. Check $ALLOY_CONFIG and 'systemctl status alloy' by hand." >&2
      echo "          If $ALLOY_ROLLBACK still exists, it holds the previous config." >&2
    fi
  fi
  rm -f "$STAGED_CONFIG"
  exit "$status"
}
trap on_exit EXIT

echo "==> Rendering staged config"
mkdir -p "$(dirname "$ALLOY_CONFIG")"

# mktemp creates the file 0600 whatever the umask, so credentials are private
# from the first byte. The rename below needs it on the config's filesystem.
STAGED_CONFIG="$(mktemp "$ALLOY_CONFIG.staged.XXXXXX")"

render_alloy_config "$STAGED_CONFIG"

# `alloy validate` accepts an empty file, which would run with no pipeline.
if [ ! -s "$STAGED_CONFIG" ]; then
  echo "ERROR: rendered config is empty; $ALLOY_CONFIG was not changed." >&2
  exit 1
fi

# ───────────────────────────── 6. Validate ─────────────────────────────────

echo "==> Validating staged config"
if ! alloy validate "$STAGED_CONFIG"; then
  echo "ERROR: alloy validate rejected the rendered config; $ALLOY_CONFIG was not changed." >&2
  exit 1
fi

# Set on the staged file so the config is never live with the wrong owner. The
# alloy user cannot read a root:root 640 file, so a chown failure is fatal.
chown root:alloy "$STAGED_CONFIG"
chmod 640 "$STAGED_CONFIG"

# ───────────────────────────── 7. journald access ───────────────────────────

# Alloy user needs read access to /var/log/journal/
if getent group systemd-journal >/dev/null; then
  usermod -a -G systemd-journal alloy || true
fi
# Ensure persistent journal is enabled (otherwise /run/log/journal is volatile)
if [ ! -d /var/log/journal ]; then
  mkdir -p /var/log/journal
  systemd-tmpfiles --create --prefix /var/log/journal
  systemctl restart systemd-journald
fi

# ───────────────────────────── 8. Swap + restart ────────────────────────────

# The hard link keeps the old inode, so a rollback restores content, mode and
# owner exactly. Signals are ignored for these few commands so that
# CONFIG_SWAPPED always matches what is on disk when the EXIT trap reads it.
swap_in_staged_config() {
  trap '' HUP INT TERM
  if [ -f "$ALLOY_CONFIG" ]; then
    ln "$ALLOY_CONFIG" "$ALLOY_ROLLBACK"
    HAD_PREVIOUS=1
  fi
  if ! mv -f "$STAGED_CONFIG" "$ALLOY_CONFIG"; then
    rm -f "$ALLOY_ROLLBACK"
    echo "ERROR: could not move the staged config into place; $ALLOY_CONFIG was not changed." >&2
    exit 1
  fi
  CONFIG_SWAPPED=1
  # An explicit trap, unlike bash's default, lets a running `systemctl restart`
  # finish first, so the rollback's own restart cannot overlap it.
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

activation_failed() {
  echo "ERROR: $1. Last 30 lines of journal:" >&2
  journalctl -u alloy -n 30 --no-pager >&2 || true
  exit 1
}

if systemctl is-active --quiet alloy; then
  ALLOY_WAS_ACTIVE=1
fi

swap_in_staged_config

echo "==> Restarting alloy.service"
systemctl restart alloy || activation_failed "systemctl restart alloy failed"
alloy_stays_up || activation_failed "alloy did not stay up on the new config"

# The new config is proven; a failure from here on must not undo it.
CONFIG_SWAPPED=0
if [ "$HAD_PREVIOUS" -eq 1 ]; then
  if mv -f "$ALLOY_ROLLBACK" "$ALLOY_PREVIOUS"; then
    echo "==> Previous config kept at $ALLOY_PREVIOUS"
  else
    echo "WARNING: could not rename $ALLOY_ROLLBACK to $ALLOY_PREVIOUS; delete or rename it before the next run." >&2
  fi
fi

# Enabled only now, so a failed attempt never changes boot behaviour.
echo "==> Enabling alloy.service"
if ! systemctl enable alloy >/dev/null 2>&1; then
  echo "WARNING: systemctl enable alloy failed; alloy is running but may not start at boot." >&2
fi

# ───────────────────────────── 9. Post-install hints ───────────────────────

if [ -n "${JOURNAL_PRODUCT_MAP:-}" ]; then
  LOKI_VERIFY_QUERY="{server_id=\"$SERVER_ID\"}"
else
  LOKI_VERIFY_QUERY="{product=\"$PRODUCT\"}"
fi

cat <<EOF

==> Alloy is running.

Verify locally:
  systemctl status alloy
  journalctl -u alloy -f

Verify end-to-end in central Grafana (https://grafana.wanbrain.com):
  1. Open Explore → Datasource: Loki
  2. Query: $LOKI_VERIFY_QUERY
  3. Should see log lines within ~30 seconds.

If logs are not arriving, on this host:
  journalctl -u alloy --since=2m | grep -iE 'error|fail|denied|refused'

EOF
