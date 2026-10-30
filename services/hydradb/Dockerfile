# HydraDB 0.3.0 for Railway: the official image plus a small start-up wrapper.
# One image serves both services; HYDRADB_ROLE=node runs graph-node and
# HYDRADB_ROLE=indexer runs graph-indexer (see railway-entrypoint.sh).
#
# Pinned by tag and by the multi-arch index digest published for v0.3.0
# (commit 0283b42f, built 2026-10-25 by upstream's container workflow).
FROM ghcr.io/hydra-db/hydradb:0.3.0@sha256:515ee78600b5d543f9146e62e775c76a8d5d0309773c165b918ed770649a91f3

# The image runs as uid 10001 (`graph`), but Railway mounts volumes owned by root.
# The wrapper starts as root, fixes ownership and writes the token file, then
# drops to uid 10001 with setpriv before HydraDB starts.
USER root

COPY --chmod=0755 railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh

# Fail the build early if the image layout this template relies on ever changes.
RUN sh -n /usr/local/bin/railway-entrypoint.sh \
    && test -x /usr/local/bin/graph-node \
    && test -x /usr/local/bin/graph-indexer \
    && command -v setpriv \
    && command -v openssl \
    && [ "$(id -u graph)" = 10001 ] \
    && install -d -m 0700 -o 10001 -g 10001 /run/hydradb

# Upstream: graph-node's OpenCypher futures overflow Rust's default thread stack.
ENV RUST_MIN_STACK=33554432

# 7687 Bolt and 8443 HTTP query API (node), 9090 node admin (/readyz, /metrics),
# 9091 indexer admin. Persistence is declared in template.json, not here.
EXPOSE 7687 8443 9090 9091

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
