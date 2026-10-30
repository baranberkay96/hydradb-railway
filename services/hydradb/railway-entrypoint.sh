#!/bin/sh
# HydraDB 0.3 on Railway: start-up wrapper shared by both services built from this folder.
#
#   HYDRADB_ROLE=node     -> graph-node     Bolt :7687, HTTP query API :8443, admin :9090
#   HYDRADB_ROLE=indexer  -> graph-indexer  admin :9091
#
# Before it execs the binary (so SIGTERM reaches HydraDB directly) it:
#   1. checks the shared bearer token and writes it to the file HydraDB reads
#      (GRAPH_AUTH_TOKEN_FILE, mode 0400, owned by uid 10001);
#   2. turns the Railway Bucket's ENDPOINT + BUCKET into object_store's AWS_ENDPOINT
#      (virtual-hosted: https://{bucket}.{endpoint host}) and drops empty AWS_*
#      variables, which object_store would otherwise read as real values;
#   3. node: chooses plaintext (TLS at Railway's edge) or a self-signed certificate,
#      prepares the cache volume and sizes the SlateDB disk cache from it;
#   4. sizes RAM caches and thread pools from the container's cgroup limits, because
#      HydraDB, GraphBLAS/OpenMP, tokio and glibc otherwise size from the host;
#   5. drops root and runs the binary as uid 10001 (the image's `graph` user).
#
# POSIX sh (the image's /bin/sh is dash). No secret is ever printed.
set -eu

readonly BIN_DIR="${HYDRADB_BIN_DIR:-/usr/local/bin}"
readonly CGROUP_ROOT="${HYDRADB_CGROUP_ROOT:-/sys/fs/cgroup}"
readonly MEMINFO="${HYDRADB_MEMINFO:-/proc/meminfo}"
readonly RUN_UID=10001
readonly RUN_GID=10001
readonly MIB=1048576
readonly GIB=1073741824
readonly DEFAULT_STACK=33554432

log() { printf '[railway] %s\n' "$*"; }
die() {
  printf '[railway] error: %s\n' "$*" >&2
  exit 78
}

# Non-negative decimal integer without leading zeros, at most 18 digits (so shell
# arithmetic cannot overflow and cgroup v1's ~2^63 "unlimited" value is rejected).
is_uint() {
  case "$1" in
    '' | *[!0-9]* | 0?*) return 1 ;;
  esac
  [ "${#1}" -le 18 ]
}
is_auto() {
  case "${1:-auto}" in
    auto | AUTO | Auto) return 0 ;;
  esac
  return 1
}
min() { if [ "$1" -lt "$2" ]; then echo "$1"; else echo "$2"; fi; }
max() { if [ "$1" -gt "$2" ]; then echo "$1"; else echo "$2"; fi; }
clamp() { max "$(min "$1" "$3")" "$2"; }
mib() { echo $(($1 / MIB)); }
am_root() { [ "$(id -u)" -eq 0 ]; }
give_to_runtime_user() {
  if am_root; then chown "$RUN_UID:$RUN_GID" "$@"; fi
}

# ---------------------------------------------------------------- role

role="${HYDRADB_ROLE:-node}"
case "$role" in
  node) bin="$BIN_DIR/graph-node" ;;
  indexer) bin="$BIN_DIR/graph-indexer" ;;
  *) die "HYDRADB_ROLE must be node or indexer, got '$role'" ;;
esac
[ -x "$bin" ] || die "$bin is missing from the image"

if am_root; then
  secrets_dir="${HYDRADB_SECRETS_DIR:-/run/hydradb}"
else
  secrets_dir="${HYDRADB_SECRETS_DIR:-/tmp/graph/secrets}"
fi

# ---------------------------------------------------------------- token

setup_token() {
  token="${HYDRADB_AUTH_TOKEN:-}"
  [ -n "$token" ] || die "HYDRADB_AUTH_TOKEN is empty (the indexer must reference the HydraDB service's token)"
  [ "${#token}" -ge 32 ] || die "HYDRADB_AUTH_TOKEN must have at least 32 characters; HydraDB rejects shorter tokens"
  case "$token" in
    *[!A-Za-z0-9._~-]*)
      die "HYDRADB_AUTH_TOKEN may contain only A-Z a-z 0-9 . _ ~ - (it is sent as a Bolt password and an HTTP bearer token)"
      ;;
  esac
  old_umask="$(umask)"
  umask 077
  mkdir -p "$secrets_dir"
  rm -f "$secrets_dir/auth-token"
  printf '%s\n' "$token" >"$secrets_dir/auth-token"
  umask "$old_umask"
  give_to_runtime_user "$secrets_dir" "$secrets_dir/auth-token"
  chmod 0700 "$secrets_dir"
  chmod 0400 "$secrets_dir/auth-token"
  GRAPH_AUTH_TOKEN_FILE="$secrets_dir/auth-token"
  export GRAPH_AUTH_TOKEN_FILE
  unset token
}

# ---------------------------------------------------------------- object store

bucket=""
setup_object_store() {
  # Railway passes empty strings for template variables left blank, and object_store's
  # AmazonS3Builder::from_env() reads every AWS_* name it knows, empty or not.
  for name in $(env | sed -n 's/^\(AWS_[A-Za-z0-9_]*\)=$/\1/p'); do
    unset "$name"
  done

  CLOUD_PROVIDER="${CLOUD_PROVIDER:-aws}"
  export CLOUD_PROVIDER
  if [ "$CLOUD_PROVIDER" != aws ]; then
    log "object store: CLOUD_PROVIDER=$CLOUD_PROVIDER (not an S3 bucket; for development only)"
    return 0
  fi

  bucket="${AWS_BUCKET_NAME:-${AWS_BUCKET:-}}"
  [ -n "$bucket" ] || die "no bucket name: AWS_BUCKET_NAME should reference \${{Bucket.BUCKET}}"
  if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    die "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must reference the Bucket's credentials"
  fi

  if [ -n "${AWS_ENDPOINT:-}" ] || [ -n "${AWS_ENDPOINT_URL:-}" ]; then
    log "object store: bucket $bucket at ${AWS_ENDPOINT:-${AWS_ENDPOINT_URL:-}} (AWS_ENDPOINT set explicitly)"
    return 0
  fi
  endpoint="${HYDRADB_S3_ENDPOINT:-}"
  if [ -z "$endpoint" ]; then
    log "object store: bucket $bucket on Amazon S3 (HYDRADB_S3_ENDPOINT is empty)"
    return 0
  fi

  endpoint="${endpoint%/}"
  case "$endpoint" in
    https://*)
      scheme=https
      host="${endpoint#https://}"
      ;;
    http://*)
      scheme=http
      host="${endpoint#http://}"
      AWS_ALLOW_HTTP=true
      export AWS_ALLOW_HTTP
      ;;
    *) die "HYDRADB_S3_ENDPOINT must start with https:// (got '$endpoint')" ;;
  esac
  [ -n "$host" ] || die "HYDRADB_S3_ENDPOINT has no host"

  style="${HYDRADB_S3_ADDRESSING:-virtual}"
  case "$style" in
    virtual)
      case "$bucket" in
        *[!a-z0-9.-]*) die "bucket name '$bucket' cannot be used in a virtual-hosted URL; set HYDRADB_S3_ADDRESSING=path" ;;
      esac
      # object_store expects the bucket inside the endpoint for virtual-hosted requests.
      case "$host" in
        "$bucket".*) ;;
        *) host="$bucket.$host" ;;
      esac
      AWS_VIRTUAL_HOSTED_STYLE_REQUEST=true
      ;;
    path) AWS_VIRTUAL_HOSTED_STYLE_REQUEST=false ;;
    *) die "HYDRADB_S3_ADDRESSING must be virtual or path, got '$style'" ;;
  esac
  AWS_ENDPOINT="$scheme://$host"
  AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-auto}}"
  export AWS_ENDPOINT AWS_VIRTUAL_HOSTED_STYLE_REQUEST AWS_REGION
  log "object store: bucket $bucket, $style-hosted requests to $AWS_ENDPOINT, region $AWS_REGION"
}

# ---------------------------------------------------------------- node: cache volume and TLS

cache_root="${HYDRADB_CACHE_ROOT:-/var/cache/slatedb}"

setup_cache() {
  data_dir="${GRAPH_DATA_CACHE_DIR:-$cache_root/data}"
  data_dir="${data_dir%/}"
  case "$data_dir" in
    /?*) ;;
    *) die "GRAPH_DATA_CACHE_DIR must be an absolute path below /, got '${GRAPH_DATA_CACHE_DIR:-}'" ;;
  esac
  GRAPH_DATA_CACHE_DIR="$data_dir"
  export GRAPH_DATA_CACHE_DIR
  mkdir -p "$cache_root" "$data_dir"

  # Railway mounts volumes owned by root; HydraDB runs as uid 10001.
  if am_root && [ -n "$(find "$cache_root" "$data_dir" \( ! -user "$RUN_UID" -o ! -group "$RUN_GID" \) -print -quit 2>/dev/null)" ]; then
    chown -R "$RUN_UID:$RUN_GID" "$cache_root" "$data_dir"
    log "cache: gave $cache_root to uid $RUN_UID"
  fi

  # The cache is keyed by object path. SlateDB reuses WAL object names in a new
  # database, so a cache filled from another bucket or data path must not survive.
  reset="${HYDRADB_CACHE_RESET:-false}"
  case "$reset" in
    true | false) ;;
    *) die "HYDRADB_CACHE_RESET must be true or false, got '$reset'" ;;
  esac
  identity="v1 provider=$CLOUD_PROVIDER endpoint=${AWS_ENDPOINT:-${LOCAL_PATH:-default}} bucket=$bucket path=${GRAPH_DATA_PATH:-graph/data}"
  marker="$data_dir.railway-identity"
  reason=""
  if [ "$reset" = true ]; then
    reason="HYDRADB_CACHE_RESET=true"
  elif [ -f "$marker" ]; then
    if [ "$(cat "$marker")" != "$identity" ]; then reason="the object store or GRAPH_DATA_PATH changed"; fi
  elif [ -n "$(ls -A "$data_dir" 2>/dev/null)" ]; then
    reason="the cache has no identity marker"
  fi
  if [ -n "$reason" ]; then
    find "$data_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    log "cache: emptied $data_dir ($reason)"
  fi
  printf '%s\n' "$identity" >"$marker"
  give_to_runtime_user "$marker"

  if is_auto "${GRAPH_DATA_CACHE_BYTES:-}"; then
    kb="$(df -Pk "$data_dir" 2>/dev/null | awk 'NR == 2 { print $2 }')" || kb=""
    if is_uint "$kb" && [ "$kb" -gt 0 ]; then
      size=$((kb / 4 * 3 * 1024))
      source="75% of the $((kb / 1024)) MiB volume"
    else
      size=$((8 * GIB))
      source="volume size unknown"
    fi
    GRAPH_DATA_CACHE_BYTES="$(clamp "$size" $((64 * MIB)) $((8 * GIB)))"
  else
    is_uint "$GRAPH_DATA_CACHE_BYTES" && [ "$GRAPH_DATA_CACHE_BYTES" -gt 0 ] ||
      die "GRAPH_DATA_CACHE_BYTES must be auto or a number of bytes"
    source="GRAPH_DATA_CACHE_BYTES"
  fi
  export GRAPH_DATA_CACHE_BYTES
  log "cache: SlateDB disk cache $(mib "$GRAPH_DATA_CACHE_BYTES") MiB in $data_dir ($source)"
}

setup_tls() {
  mode="${HYDRADB_TLS:-off}"
  case "$mode" in
    off)
      GRAPH_ALLOW_PLAINTEXT=true
      export GRAPH_ALLOW_PLAINTEXT
      unset GRAPH_TLS_CERTIFICATE GRAPH_TLS_PRIVATE_KEY
      log "tls: off; Bolt and HTTP are plaintext inside the private network, the public domain is HTTPS at Railway's edge"
      ;;
    self-signed)
      command -v openssl >/dev/null 2>&1 || die "openssl is missing from the image"
      tls_dir="$cache_root/tls"
      cert="$tls_dir/cert.pem"
      key="$tls_dir/key.pem"
      names="DNS:localhost"
      for domain in "${RAILWAY_PRIVATE_DOMAIN:-}" "${RAILWAY_TCP_PROXY_DOMAIN:-}" "${RAILWAY_PUBLIC_DOMAIN:-}"; do
        if [ -n "$domain" ]; then names="$names,DNS:$domain"; fi
      done
      mkdir -p "$tls_dir"
      renew=""
      if [ ! -s "$cert" ] || [ ! -s "$key" ]; then
        renew="new"
      elif [ "$(cat "$tls_dir/names" 2>/dev/null || true)" != "$names" ]; then
        renew="host names changed"
      elif ! openssl x509 -checkend 2592000 -noout -in "$cert" >/dev/null 2>&1; then
        renew="expires within 30 days"
      fi
      if [ -n "$renew" ]; then
        rm -f "$cert" "$key"
        old_umask="$(umask)"
        umask 077
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 825 \
          -subj "/CN=${RAILWAY_PRIVATE_DOMAIN:-hydradb}" -addext "subjectAltName=$names" \
          -keyout "$key" -out "$cert" >/dev/null 2>&1 || die "openssl could not create the TLS certificate"
        umask "$old_umask"
        printf '%s\n' "$names" >"$tls_dir/names"
        log "tls: created a self-signed certificate ($renew)"
      fi
      chmod 0700 "$tls_dir"
      chmod 0600 "$key"
      give_to_runtime_user "$tls_dir" "$cert" "$key" "$tls_dir/names"
      GRAPH_ALLOW_PLAINTEXT=false
      GRAPH_TLS_CERTIFICATE="$cert"
      GRAPH_TLS_PRIVATE_KEY="$key"
      export GRAPH_ALLOW_PLAINTEXT GRAPH_TLS_CERTIFICATE GRAPH_TLS_PRIVATE_KEY
      log "tls: self-signed for $names; clients use bolt+ssc:// and https:// without verification; the public domain cannot reach this listener"
      ;;
    *) die "HYDRADB_TLS must be off or self-signed, got '$mode'" ;;
  esac
}

setup_node_network() {
  GRAPH_BOLT_ADDR="${GRAPH_BOLT_ADDR:-[::]:7687}"
  GRAPH_HTTP_ADDR="${GRAPH_HTTP_ADDR:-[::]:8443}"
  GRAPH_ADMIN_ADDR="${GRAPH_ADMIN_ADDR:-[::]:9090}"
  export GRAPH_BOLT_ADDR GRAPH_HTTP_ADDR GRAPH_ADMIN_ADDR
  # ${{RAILWAY_PRIVATE_DOMAIN}} is empty when private networking is off.
  case "${GRAPH_ADVERTISED_BOLT_ADDR:-}" in
    '' | :*)
      GRAPH_ADVERTISED_BOLT_ADDR="localhost:${GRAPH_BOLT_ADDR##*:}"
      export GRAPH_ADVERTISED_BOLT_ADDR
      log "warning: no private domain; Bolt routing tables advertise $GRAPH_ADVERTISED_BOLT_ADDR"
      ;;
  esac
  case "${GRAPH_INDEXER_NOTIFY_URL:-}" in
    http://:* | https://:*)
      unset GRAPH_INDEXER_NOTIFY_URL
      log "warning: the indexer has no private domain; it will find changes by polling"
      ;;
  esac
  check_port "$GRAPH_ADMIN_ADDR" "the admin server (/readyz)"
}

check_port() {
  if [ -n "${PORT:-}" ] && [ "$PORT" != "${1##*:}" ]; then
    log "warning: PORT=$PORT but $2 listens on ${1##*:}; Railway's healthcheck probes PORT"
  fi
}

# ---------------------------------------------------------------- memory and CPU (Rule: size from cgroups)

memory_limit() {
  best=""
  for file in "$CGROUP_ROOT/memory.max" "$CGROUP_ROOT/memory.high" "$CGROUP_ROOT/memory/memory.limit_in_bytes"; do
    if [ -r "$file" ]; then
      value="$(cat "$file" 2>/dev/null || true)"
      if is_uint "$value" && [ "$value" -gt 0 ]; then
        if [ -z "$best" ] || [ "$value" -lt "$best" ]; then best="$value"; fi
      fi
    fi
  done
  printf '%s' "$best"
}

cpu_quota() {
  quota=""
  period=""
  if [ -r "$CGROUP_ROOT/cpu.max" ]; then
    read -r quota period <"$CGROUP_ROOT/cpu.max" || true
  elif [ -r "$CGROUP_ROOT/cpu/cpu.cfs_quota_us" ] && [ -r "$CGROUP_ROOT/cpu/cpu.cfs_period_us" ]; then
    quota="$(cat "$CGROUP_ROOT/cpu/cpu.cfs_quota_us" 2>/dev/null || true)"
    period="$(cat "$CGROUP_ROOT/cpu/cpu.cfs_period_us" 2>/dev/null || true)"
  fi
  if is_uint "$quota" && is_uint "$period" && [ "$quota" -gt 0 ] && [ "$period" -gt 0 ]; then
    printf '%s' $(((quota + period - 1) / period))
  fi
}

# resolve_bytes VAR COMPUTED: "auto"/empty -> COMPUTED, a number is kept, anything else fails.
resolve_bytes() {
  eval "current=\${$1:-}"
  if is_auto "$current"; then
    eval "$1=\$2"
  elif ! is_uint "$current"; then
    die "$1 must be auto or a number of bytes, got '$current'"
  fi
  export "${1?}"
}

# resolve_count VAR COMPUTED: like resolve_bytes for positive counts.
resolve_count() {
  eval "current=\${$1:-}"
  if is_auto "$current"; then
    eval "$1=\$2"
  elif ! is_uint "$current" || [ "$current" -eq 0 ]; then
    die "$1 must be auto or a positive number, got '$current'"
  fi
  export "${1?}"
}

setup_memory() {
  host=""
  total_kb="$(awk '/^MemTotal:/ { print $2 }' "$MEMINFO" 2>/dev/null || true)"
  if is_uint "$total_kb"; then host=$((total_kb * 1024)); fi
  if is_auto "${HYDRADB_MEMORY_LIMIT_MB:-}"; then
    limit="$(memory_limit)"
    if [ -n "$limit" ] && { [ -z "$host" ] || [ "$limit" -lt "$host" ]; }; then
      budget="$limit"
      source="container memory limit"
    else
      budget=$((2 * GIB))
      if [ -n "$host" ]; then budget="$(min "$budget" "$host")"; fi
      source="no container limit visible, assumed"
    fi
  else
    if ! is_uint "$HYDRADB_MEMORY_LIMIT_MB" || [ "$HYDRADB_MEMORY_LIMIT_MB" -lt 256 ]; then
      die "HYDRADB_MEMORY_LIMIT_MB must be auto or a number of MiB (256 or more)"
    fi
    budget=$((HYDRADB_MEMORY_LIMIT_MB * MIB))
    source="HYDRADB_MEMORY_LIMIT_MB"
  fi
  # 5/16 of the budget is upstream's 640 MiB default at a 2 GiB budget.
  resolve_bytes GRAPH_SLATE_DB_CACHE_BYTES "$(clamp $((budget / 16 * 5)) $((64 * MIB)) $((2 * GIB)))"
  summary="SlateDB RAM cache $(mib "$GRAPH_SLATE_DB_CACHE_BYTES") MiB"
  if [ "$role" = node ]; then
    # 1/16 of the budget is upstream's 128 MiB default at a 2 GiB budget.
    resolve_bytes GRAPH_MAX_GRAPHBLAS_BYTES "$(clamp $((budget / 16)) $((32 * MIB)) $((512 * MIB)))"
    summary="$summary, GraphBLAS matrices $(mib "$GRAPH_MAX_GRAPHBLAS_BYTES") MiB"
  fi
  log "memory: budget $(mib "$budget") MiB ($source); $summary"
}

setup_cpu() {
  if is_auto "${HYDRADB_CPU_LIMIT:-}"; then
    cores="$(cpu_quota)"
    if [ -n "$cores" ]; then
      source="container CPU quota"
    else
      cores="$(nproc 2>/dev/null || echo 1)"
      source="no CPU quota visible, nproc"
    fi
    is_uint "$cores" || cores=1
    cores="$(clamp "$cores" 1 8)"
  else
    if ! is_uint "$HYDRADB_CPU_LIMIT" || [ "$HYDRADB_CPU_LIMIT" -lt 1 ] || [ "$HYDRADB_CPU_LIMIT" -gt 64 ]; then
      die "HYDRADB_CPU_LIMIT must be auto or a number from 1 to 64"
    fi
    cores="$HYDRADB_CPU_LIMIT"
    source="HYDRADB_CPU_LIMIT"
  fi
  resolve_count GRAPHBLAS_NTHREADS "$cores"
  resolve_count TOKIO_WORKER_THREADS "$(max "$cores" 2)"
  OMP_NUM_THREADS="${OMP_NUM_THREADS:-$GRAPHBLAS_NTHREADS}"
  MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-$(max "$cores" 2)}"
  export OMP_NUM_THREADS MALLOC_ARENA_MAX
  log "cpu: $cores core(s) ($source); tokio $TOKIO_WORKER_THREADS workers, GraphBLAS $GRAPHBLAS_NTHREADS threads, glibc $MALLOC_ARENA_MAX arenas"
}

# ---------------------------------------------------------------- main

setup_token
setup_object_store
if [ "$role" = node ]; then
  setup_cache
  setup_tls
  setup_node_network
else
  GRAPH_INDEXER_ADMIN_ADDR="${GRAPH_INDEXER_ADMIN_ADDR:-[::]:9091}"
  export GRAPH_INDEXER_ADMIN_ADDR
  check_port "$GRAPH_INDEXER_ADMIN_ADDR" "the indexer admin server (/readyz)"
fi
setup_memory
setup_cpu

# graph-node's OpenCypher futures overflow Rust's default 2 MiB thread stack (upstream README).
if ! is_uint "${RUST_MIN_STACK:-}"; then RUST_MIN_STACK="$DEFAULT_STACK"; fi
export RUST_MIN_STACK

# The token now lives in GRAPH_AUTH_TOKEN_FILE; keep copies out of HydraDB's environment.
unset HYDRADB_AUTH_TOKEN NEO4J_PASSWORD

if [ -d /tmp/graph ]; then
  cd /tmp/graph
  HOME=/tmp/graph
  export HOME
fi

if am_root; then
  log "starting $(basename "$bin") as uid $RUN_UID"
  exec setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --clear-groups --no-new-privs -- "$bin" "$@"
fi
log "starting $(basename "$bin") as uid $(id -u)"
exec "$bin" "$@"
