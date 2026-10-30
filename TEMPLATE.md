# HydraDB v0.3 Graph Database on Object Storage — Railway template spec

## Listing

- **Name:** HydraDB v0.3 Graph Database on Object Storage (round-6 listing; major.minor of the pinned 0.3.0)
- **Description (74 chars):** Cypher graph database that keeps its data in S3-compatible object storage.
- **Category:** Storage
- **Tags:** hydradb, graph-database, cypher, opencypher, bolt, neo4j-drivers, object-storage, s3
- **Template repo:** `baranberkay96/hydradb-railway` (this folder), both services from `/services/hydradb`

The listing description was "Graph database that keeps its data in S3-compatible object storage." (67 chars). "Cypher" was added because the brief asks for the main query language in the description when it fits, and 74 characters fit under the 75-character limit. Everything the description promises is delivered: the graph's durable state (records, WALs, manifests, writer leases, traversal indexes) lives in a Railway Bucket, which is S3-compatible; queries use HydraDB's OpenCypher subset.

## Base market templates

None. `_market/` is empty and no HydraDB template exists on the Railway marketplace (checked by the brief). The design follows upstream's own production deployment, the Helm chart in `charts/hydradb/` at v0.3.0, translated to Railway's primitives (see "Improvements over upstream defaults").

## What HydraDB speaks

| Interface | Port | Details |
|---|---|---|
| **OpenCypher subset** (query language) | n/a | Typed, directed relationships, bounded variable-length paths, `MATCH`/`OPTIONAL MATCH`/`WHERE`/`RETURN` with aggregates, `CREATE`, `MERGE` by id, `SET`/`REMOVE`/`DELETE`, `UNWIND` batches, `UNION`, plus native path procedures `algo.SPpaths`, `algo.SSpaths`, `algo.MSpaths` and `algo.degree`. Not full Cypher: no `RETURN *`, no undirected or untyped patterns, no unanchored scans, writes need an edge pattern, `id` is an upsert key, auto-commit only (no `BEGIN`/`COMMIT`). Upstream lists the rules in `cypher-compat.md` and `USING-HYDRADB.md`. |
| **Bolt 5.1–5.4** (`BOLT_SUPPORTED_VERSIONS` in `src/client/bolt.rs`) | 7687 | Official Neo4j drivers (Python, JavaScript, Java, Go, .NET) work unmodified. Token in the password field, any user name, session database `default`. `bolt://` direct or `neo4j://` routing. |
| **HTTP query API** | 8443 | `POST /v1/graphs/{graph_id}/query` (JSON or streaming NDJSON with `Accept: application/x-ndjson`), `POST /v1/graphs/{graph_id}/queries/{query_id}/cancel`, `GET /healthz`. Bearer token; `cell_id` is mandatory in every body. 1 MiB body limit. |
| Admin | 9090 (node), 9091 (indexer) | `GET /livez`, `GET /readyz`, `GET /metrics` (Prometheus, no auth by upstream design), `/v1/cypher-engine` (PUT needs the token). Private network only. |

Not supported: Gremlin, SPARQL, GraphQL. GQL (ISO/IEC 39075) is being added to upstream's experimental engine (`gql/` docs on `main`, after v0.3.0); `GRAPH_CYPHER_ENGINE=experimental` switches to that engine, but the template keeps upstream's default `legacy` and does not advertise GQL.

## Pinned versions

| Service | Image | Tag / digest | Released |
|---|---|---|---|
| HydraDB, HydraDB Indexer (`services/hydradb`) | `ghcr.io/hydra-db/hydradb` (official, built by upstream's `container.yml` on the `v0.3.0` tag) | `0.3.0@sha256:515ee78600b5d543f9146e62e775c76a8d5d0309773c165b918ed770649a91f3` (OCI index, linux/amd64 + linux/arm64; label `org.opencontainers.image.revision=0283b42fdf3d5c6e22dc9720445d131a16949104`, `version=v0.3.0`, `licenses=AGPL-3.0`; image created 2026-10-25) | v0.3.0: tag 2026-10-25 (CHANGELOG date 2026-10-22) |

Checked 2026-10-30 through the GHCR registry API. Tags present: `0.1.0`, `0.1.1`, `0.2.0`, `0.3.0`, `0.3`, `0`, `latest`, `sha-*`. `main` is 6 commits ahead of v0.3.0, all documentation (`gql/*.md`). The image is Ubuntu 24.04 with `graph-node`, `graph-indexer` and `falkor-dump-import`, built with `server-runtime,indexer-runtime,experimental-cypher-engine,otlp`, running as uid 10001.

## Architecture

```
 Apps on Railway ── Bolt (neo4j drivers, token) ─────> HydraDB:7687  ┐
 Apps on Railway ── HTTP JSON/NDJSON (bearer token) ─> HydraDB:8443  │ graph-node, 1 replica
 Internet ── HTTPS ──> Railway edge ──> HydraDB:8443 (token)         │ volume /var/cache/slatedb
 Prometheus on Railway ──> HydraDB:9090/metrics, Indexer:9091/metrics│ (disposable SlateDB disk cache)
                                                                      ┘
 HydraDB ──── wake (bearer) ────> HydraDB Indexer:9091/v1/changes:process
 HydraDB ─┐                                     (graph-indexer: builds CSC traversal indexes)
          ├── S3 over HTTPS (conditional PUTs) ──> Railway Bucket "Bucket"
 Indexer ─┘   records, WALs, manifests, heartbeats, writer leases, index generations
```

Two services and one Bucket, the same split as upstream's Helm chart (`node-statefulset.yaml` + `indexer-deployment.yaml`). There is no database server to back up besides the Bucket: query nodes and indexers hold only state they can rebuild.

## Design decisions

### Object store: Railway Bucket (not SeaweedFS)

HydraDB stores everything through SlateDB, which loads its store from the environment (`slatedb::admin::load_object_store_from_env` in the `hydra-db/slatedb` fork at `c1003496`, `CLOUD_PROVIDER=aws` → `object_store::aws::AmazonS3Builder::from_env()`, object_store **0.14.1**, crate checksum matched against `Cargo.lock`). The Bucket qualifies on both points the brief asked about:

- **Custom endpoint:** `AWS_ENDPOINT` is read from the environment. Railway documents the endpoint as `https://t3.storageapi.dev`.
- **Virtual-hosted style:** `AWS_VIRTUAL_HOSTED_STYLE_REQUEST=true` is supported, but object_store then uses the endpoint *as is* and expects the bucket name inside it (`builder.rs`: `(Some(endpoint), _, true) => endpoint.clone()`). Railway's `${{Bucket.ENDPOINT}}` has no bucket in it and a reference cannot be spliced after the `https://`, so the start script builds `https://{BUCKET}.t3.storageapi.dev` from `HYDRADB_S3_ENDPOINT` and `AWS_BUCKET_NAME`. `HYDRADB_S3_ADDRESSING=path` covers buckets created before Railway's switch to virtual-hosted URLs.
- **Conditional writes:** WAL fencing, writer leases and index publication use `PutMode::Create` (`If-None-Match: *`) and `PutMode::Update` (`If-Match: {etag}`); object_store 0.14 enables ETag conditional puts by default. Railway's bucket docs do not list conditional writes. The endpoint appears to be Tigris-backed storage (not stated in Railway's docs), and Tigris documents both headers on PUT. HydraDB 0.3.0 checks this itself at boot: `probe_create_only_puts` races 32 create-only PUTs, expects exactly one winner and verifies that a HEAD returns the `slatedbputid` user metadata. A failed probe is retried with backoff from 5 s up to 5 minutes. Until the probe passes the node serves reads only and `/readyz` is not 200, so **the deploy healthcheck fails loudly if the Bucket is not safe for writes** instead of silently losing acknowledged writes.
- Region `${{Bucket.REGION}}` (`auto` in Railway's docs) is passed as `AWS_REGION` for SigV4 signing.
- Empty `AWS_*` variables are removed before start: `from_env()` reads every `AWS_*` name it knows, so an empty `AWS_ENDPOINT` would become an empty endpoint.

If the probe fails on Railway, the fallback is SeaweedFS's S3 gateway (Rule 3; never MinIO), but only after checking that its gateway honours `If-None-Match: *` and returns user metadata on HEAD. That is not verified here.

### Two services: node and indexer

- **HydraDB** (`graph-node`): Bolt, HTTP, admin; owns the writer for `cell-0`; serves reads from a pinned SlateDB snapshot plus the WAL tail.
- **HydraDB Indexer** (`graph-indexer`): builds immutable CSC traversal-index generations and publishes them through atomic object-store pointers. Readers stay correct without it, but large traversals fall back to WAL-tail and snapshot adjacency, so production quality needs it (upstream's chart enables it by default).
- Both are built from the same folder; `HYDRADB_ROLE` picks the binary, so no start-command override is needed.
- The node wakes the indexer after writes (`GRAPH_INDEXER_NOTIFY_URL`, bearer token; failures are logged at debug and polling recovers). Because of that wake, the indexer's dirty-scope poll runs every 1000 ms instead of upstream's 250 ms. Each poll is an S3 request from the service, which Railway bills as egress.

### Cache volume

- Upstream keeps a disposable SlateDB disk cache at `/var/cache/slatedb` (chart: `emptyDir` 20 GiB by default, `persistentVolume` 40 GiB as an option). The template mounts a Railway volume there.
- Why a volume: the cache survives redeploys (warm reads after a deploy), it is not limited by the container's ephemeral disk, and **a service with a volume is stopped before its replacement starts**. Without that, a redeploy would briefly run two processes with the same `GRAPH_NODE_ID`; the shutting-down one deletes its heartbeat object, which is the same key the new one writes.
- `GRAPH_DATA_CACHE_BYTES=auto` = 75% of the volume (`df`), 64 MiB to 8 GiB (8 GiB is upstream's default). About 3.75 GiB on Hobby's 5 GB volume, 384 MiB on a 0.5 GB Free/Trial volume.
- The cache is keyed by object path, and a new SlateDB database reuses WAL object names. The start script therefore records the store identity (provider, endpoint, bucket, `GRAPH_DATA_PATH`) next to the cache and empties it when that changes, or when `HYDRADB_CACHE_RESET=true`. Emptying the Bucket's objects in place is not detectable; the README tells users to set `HYDRADB_CACHE_RESET=true` once in that case.
- Ownership: the image runs as uid 10001, and Railway mounts volumes as root. The image is started as root (`USER root`), the script `chown`s the volume when needed, then `exec setpriv --reuid=10001 --regid=10001 --clear-groups --no-new-privs`.

### Authentication

- One bearer token, `HYDRADB_AUTH_TOKEN = secret(48)` (letters and digits). HydraDB reads it from a file (`GRAPH_AUTH_TOKEN_FILE`, at least 32 characters, not `change-me`). The script writes it to `/run/hydradb/auth-token` (0400, uid 10001) and unsets `HYDRADB_AUTH_TOKEN` and `NEO4J_PASSWORD` before exec. The token is never logged.
- It is required on every HTTP query/cancel request and as the Bolt password. It grants read, write, cancel and admin on the graph (`StaticQueryTransportScopeAuthorizer` in `graph-node.rs`). HydraDB 0.3 has no per-user accounts or read-only tokens.
- The indexer gets the same token by reference; it accepts change notifications only with it.
- Unauthenticated by upstream design: `/healthz` on 8443 (returns `{"status":"ok"}`) and the admin ports' `/livez`, `/readyz`, `/metrics` (upstream `SECURITY.md`). The admin ports are never given a public domain.

### Exposure and TLS

- **Private by default for Bolt and admin.** No TCP proxy is created.
- **Public domain → 8443 only**, the token-protected HTTP query API. Railway's edge terminates HTTPS. This is the safest external path because Railway handles TLS, and it lets a user test the database with `curl` right after deploy (the image has no curl or shell clients).
- HydraDB's TLS is all-or-nothing: with `GRAPH_ALLOW_PLAINTEXT=false` both Bolt and HTTP require TLS, and Railway's edge cannot proxy to an HTTPS upstream. The default `HYDRADB_TLS=off` therefore sets `GRAPH_ALLOW_PLAINTEXT=true`. Upstream's `SECURITY.md` says plaintext is meant for development; here the plaintext hops are Railway's encrypted private network and the edge-to-container hop, while internet clients reach the node only via HTTPS.
- **Optional TCP proxy for external Bolt** (port 7687), documented in the README. With `HYDRADB_TLS=off` it is plaintext, and the token crosses the internet in clear. `HYDRADB_TLS=self-signed` generates a P-256 certificate (825 days, SANs: localhost, private, TCP-proxy and public domains; kept on the volume, renewed when the names change or 30 days before expiry). Clients then use `bolt+ssc://`. In that mode the public domain stops working, because 8443 then serves TLS, and private HTTP clients must use `https://` without verification.
- External Bolt clients must use a direct `bolt://` or `bolt+ssc://` URI, not `neo4j://`: the routing table advertises the private address (`GRAPH_ADVERTISED_BOLT_ADDR`).

### Listeners and networking (Rules 8.2, 8.13, 8.14)

- `GRAPH_BOLT_ADDR`, `GRAPH_HTTP_ADDR`, `GRAPH_ADMIN_ADDR` and `GRAPH_INDEXER_ADMIN_ADDR` default to `[::]:port` in the start script (upstream: `0.0.0.0`). These are Rust tokio/std listeners, which are dual-stack on Linux, so IPv6-first clients and Railway's IPv4 healthcheck both connect.
- The advertised Bolt address is a plain string (no DNS lookup at boot), so the node's own private name not resolving yet is harmless. An empty private domain falls back to `localhost:7687`, with a warning.

### Healthchecks (Rules 3, 8.1)

- Node: `PORT=9090`, `healthcheckPath=/readyz`, timeout 300 s. `/readyz` is 200 only when the node is started, its placement view is fresh and the create-only probe has passed. The public domain targets 8443 independently of `PORT`.
- Indexer: `PORT=9091`, `/readyz` (ready once its admin server is up; it turns unready after 3 failed cycles in a row).

### Memory and CPU from the cgroup (Rule 8.15)

- Memory budget: the tightest of cgroup v2 `memory.max`/`memory.high` and v1 `memory.limit_in_bytes`, if below `MemTotal`. Otherwise 2 GiB is assumed and logged. `HYDRADB_MEMORY_LIMIT_MB` overrides it.
- `GRAPH_SLATE_DB_CACHE_BYTES=auto` = 5/16 of the budget, 64 MiB to 2 GiB (exactly upstream's 640 MiB at 2 GiB; 320 MiB on a 1 GB Trial service). This is the biggest RAM consumer, and upstream's fixed 640 MiB alone would crowd a 1 GB container.
- `GRAPH_MAX_GRAPHBLAS_BYTES=auto` (node) = 1/16, 32–512 MiB (upstream's 128 MiB at 2 GiB).
- Cores: cgroup v2 `cpu.max` or v1 CFS quota rounded up, else `nproc`, capped at 8 (`HYDRADB_CPU_LIMIT` overrides it). Then:
  - `GRAPHBLAS_NTHREADS` (otherwise GraphBLAS uses one OpenMP thread per host core, per `graphblas.rs`) and `OMP_NUM_THREADS` = cores;
  - `TOKIO_WORKER_THREADS` = max(2, cores) (verified in tokio 1.52.4 `loom/std/mod.rs`);
  - `MALLOC_ARENA_MAX` = max(2, cores) unless set (glibc otherwise allows 8 arenas per host core).
- All explicit numbers are passed through unchanged; invalid values stop the start with exit code 78 and a message naming the variable.

### Other start-up settings

- `RUST_MIN_STACK=33554432`: upstream's README and `AGENTS.md` say the node serves `/readyz` and then aborts on the first query without it. The image and upstream's Helm chart do not set it, so the Dockerfile does.
- Logs: HydraDB logs JSON by default (`GRAPH_LOG_FORMAT`), which Railway's log view parses. The script's own lines start with `[railway]`.
- Shutdown: both binaries handle SIGTERM (drain listeners, withdraw the heartbeat, release leases). The script `exec`s, so the binary receives the signal from Railway's init. `RAILWAY_DEPLOYMENT_DRAINING_SECONDS=60` matches the chart's `terminationGracePeriodSeconds` (Railway's default is 0).
- Writer lease: leases are held per process (`PROCESS_HOLDER_ID`). After an unclean stop the next node can write once the old lease expires, at most `GRAPH_WRITER_LEASE_MS` (30 s, upstream default). Reads work meanwhile.

## Services

<!-- BEGIN SERVICES -->

### HydraDB

Query node: HydraDB 0.3.0 `graph-node`.

- Source: repo `baranberkay96/hydradb-railway`, root directory `/services/hydradb` (Dockerfile build, `FROM ghcr.io/hydra-db/hydradb:0.3.0@sha256:515ee786…`)
- Start command: image default (`railway-entrypoint.sh` → `graph-node`)
- Pre-deploy command: none
- Healthcheck: `/readyz` on `PORT` 9090 (timeout 300 s)
- Public domain: yes, target port `8443` (HTTPS query API, token required)
- TCP proxy: none (optional, port 7687; see README)
- Volume: `/var/cache/slatedb` (disposable SlateDB disk cache)
- Restart policy: ALWAYS; replicas: 1; cron: none

| Variable | Value | Description |
|---|---|---|
| `HYDRADB_ROLE` | `node` | Program this service runs: node = graph-node (Bolt 7687, HTTP query API 8443, admin 9090). |
| `PORT` | `9090` | Admin port. Railway's healthcheck GETs /readyz here; ready once the Bucket passes the write probe. |
| `HYDRADB_AUTH_TOKEN` | `${{secret(48, "abc…XYZ0123456789")}}` | Bearer token for the HTTP API and the Bolt password (any user name). 32+ chars of A-Z a-z 0-9 . _ ~ -. |
| `CLOUD_PROVIDER` | `aws` | Object store type read by SlateDB. aws = any S3-compatible store, here the Railway Bucket. |
| `AWS_BUCKET_NAME` | `${{Bucket.BUCKET}}` | Bucket that holds the graph (records, WALs, leases, indexes). The source of truth for all data. |
| `AWS_ACCESS_KEY_ID` | `${{Bucket.ACCESS_KEY_ID}}` | Bucket access key. |
| `AWS_SECRET_ACCESS_KEY` | `${{Bucket.SECRET_ACCESS_KEY}}` | Bucket secret key. |
| `AWS_REGION` | `${{Bucket.REGION}}` | Bucket region used to sign S3 requests. |
| `HYDRADB_S3_ENDPOINT` | `${{Bucket.ENDPOINT}}` | S3 endpoint without the bucket name. The start script derives AWS_ENDPOINT from it. |
| `HYDRADB_S3_ADDRESSING` | `virtual` | virtual = https://{bucket}.{endpoint host} (new Railway Buckets); path for older buckets (see Credentials tab). |
| `GRAPH_NAMESPACE` | `default` | Namespace of the graph. With 'default' the X-Graph-Namespace HTTP header is optional. |
| `GRAPH_ID` | `default` | Graph id, used in the HTTP path /v1/graphs/{id}/query. |
| `GRAPH_DATABASE` | `default` | Bolt database name: pass it as the session database in Neo4j drivers. |
| `GRAPH_CELL_ID` | `cell-0` | Partition (cell) this node owns. Every HTTP query must send it as cell_id. |
| `GRAPH_CELLS` | `${{GRAPH_CELL_ID}}` | All cells of the graph, comma-separated. Must contain GRAPH_CELL_ID. |
| `GRAPH_DATA_PATH` | `hydradb` | Prefix inside the Bucket for all HydraDB objects. Do not change after the first write. |
| `GRAPH_NODE_ID` | `hydradb-0` | Stable node id used for heartbeats, writer leases and Bolt routing tables. |
| `GRAPH_ADVERTISED_BOLT_ADDR` | `${{RAILWAY_PRIVATE_DOMAIN}}:7687` | Bolt address this node puts in routing tables (neo4j:// URIs). Private network by default. |
| `GRAPH_INDEXER_NOTIFY_URL` | `http://${{HydraDB Indexer.RAILWAY_PRIVATE_DOMAIN}}:9091/v1/changes:process` | Wakes the indexer after writes (sent with the bearer token). Empty = the indexer only polls. |
| `HYDRADB_TLS` | `off` | off = plaintext behind Railway's HTTPS edge. self-signed = TLS on Bolt and HTTP (breaks the public domain). |
| `GRAPH_DATA_CACHE_BYTES` | `auto` | SlateDB disk cache on the volume. auto = 75% of the volume, 64 MiB to 8 GiB; or a number of bytes. |
| `GRAPH_SLATE_DB_CACHE_BYTES` | `auto` | SlateDB RAM cache. auto = 5/16 of the memory budget, 64 MiB to 2 GiB; or bytes (0 disables it). |
| `GRAPH_MAX_GRAPHBLAS_BYTES` | `auto` | Memory for compiled GraphBLAS matrices. auto = 1/16 of the memory budget, 32 to 512 MiB; or bytes. |
| `HYDRADB_MEMORY_LIMIT_MB` | `auto` | Memory budget for the auto sizes. auto = the container limit (2 GiB if none is visible); or MiB. |
| `HYDRADB_CPU_LIMIT` | `auto` | Cores for thread pools. auto = the container CPU quota (else nproc), capped at 8; or a number. |
| `GRAPHBLAS_NTHREADS` | `auto` | SuiteSparse GraphBLAS threads. auto = HYDRADB_CPU_LIMIT's core count. |
| `TOKIO_WORKER_THREADS` | `auto` | Async runtime worker threads. auto = the core count, at least 2. |
| `HYDRADB_CACHE_RESET` | `false` | true empties the disk cache at every start. Use once after emptying or replacing the Bucket's data. |
| `GRAPH_CYPHER_ENGINE` | `legacy` | legacy = the documented OpenCypher subset. experimental = upstream's newer engine (not for production). |
| `RUST_LOG` | `info` | Log filter (JSON logs). e.g. info,hydradb=debug for more detail. |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `60` | Seconds between SIGTERM and SIGKILL, so the node drains queries and hands back its writer lease. |
| `HYDRADB_HOST` | `${{RAILWAY_PRIVATE_DOMAIN}}` | Private host name for clients that take host and port separately. |
| `HYDRADB_URL` | `http://${{RAILWAY_PRIVATE_DOMAIN}}:8443` | HTTP query API base URL on the private network. Reference it as ${{HydraDB.HYDRADB_URL}}. |
| `HYDRADB_QUERY_URL` | `${{HYDRADB_URL}}/v1/graphs/${{GRAPH_ID}}/query` | POST endpoint for queries (JSON body with cell_id and query; bearer token). |
| `HYDRADB_BOLT_URL` | `bolt://${{RAILWAY_PRIVATE_DOMAIN}}:7687` | Bolt URL for Neo4j drivers on the private network. |
| `HYDRADB_PUBLIC_URL` | `https://${{RAILWAY_PUBLIC_DOMAIN}}` | HTTPS query API on the public domain (token required). Egress-billed; prefer the private URL. |
| `HYDRADB_METRICS_URL` | `http://${{RAILWAY_PRIVATE_DOMAIN}}:9090/metrics` | Prometheus scrape URL on the private network (no auth, never public). |
| `NEO4J_URI` | `${{HYDRADB_BOLT_URL}}` | Same as HYDRADB_BOLT_URL, under the name Neo4j-driver apps usually read. |
| `NEO4J_USERNAME` | `neo4j` | Bolt user name. HydraDB ignores it; any value works. |
| `NEO4J_PASSWORD` | `${{HYDRADB_AUTH_TOKEN}}` | Bolt password = the bearer token. |
| `NEO4J_DATABASE` | `${{GRAPH_DATABASE}}` | Bolt session database. |

Set by the start script, not template variables: `GRAPH_AUTH_TOKEN_FILE`, `GRAPH_ALLOW_PLAINTEXT` (from `HYDRADB_TLS`), `GRAPH_TLS_CERTIFICATE`/`GRAPH_TLS_PRIVATE_KEY` (self-signed mode), `AWS_ENDPOINT`, `AWS_VIRTUAL_HOSTED_STYLE_REQUEST`, `GRAPH_DATA_CACHE_DIR=/var/cache/slatedb/data`, `GRAPH_BOLT_ADDR=[::]:7687`, `GRAPH_HTTP_ADDR=[::]:8443`, `GRAPH_ADMIN_ADDR=[::]:9090`, `OMP_NUM_THREADS`, `MALLOC_ARENA_MAX`, `RUST_MIN_STACK` (also in the Dockerfile). Each can still be set explicitly; explicit values win (except the TLS pair, which follows `HYDRADB_TLS`). All other `GRAPH_*` runtime limits keep upstream's defaults (30 s query runtime, 1,000,000 scanned edges, 256 concurrent queries, 4096 Bolt connections) and can be added as variables.

### HydraDB Indexer

Index builder: HydraDB 0.3.0 `graph-indexer`.

- Source: same repo and root directory as HydraDB (`HYDRADB_ROLE=indexer`)
- Start command: image default (`railway-entrypoint.sh` → `graph-indexer`)
- Healthcheck: `/readyz` on `PORT` 9091 (timeout 300 s)
- Public domain: no; TCP proxy: none; volume: none (its SlateDB readers are read-only and use RAM only)
- Restart policy: ALWAYS; replicas: 1; cron: none

| Variable | Value | Description |
|---|---|---|
| `HYDRADB_ROLE` | `indexer` | Program this service runs: indexer = graph-indexer (builds traversal indexes; admin 9091). |
| `PORT` | `9091` | Indexer admin port. Railway's healthcheck GETs /readyz here. |
| `HYDRADB_AUTH_TOKEN` | `${{HydraDB.HYDRADB_AUTH_TOKEN}}` | The node's token. The indexer accepts change notifications only with it. |
| `CLOUD_PROVIDER` | `${{HydraDB.CLOUD_PROVIDER}}` | Same object store as the node. |
| `AWS_BUCKET_NAME` | `${{HydraDB.AWS_BUCKET_NAME}}` | Same bucket as the node. |
| `AWS_ACCESS_KEY_ID` | `${{HydraDB.AWS_ACCESS_KEY_ID}}` | Same bucket access key as the node. |
| `AWS_SECRET_ACCESS_KEY` | `${{HydraDB.AWS_SECRET_ACCESS_KEY}}` | Same bucket secret key as the node. |
| `AWS_REGION` | `${{HydraDB.AWS_REGION}}` | Same region as the node. |
| `HYDRADB_S3_ENDPOINT` | `${{HydraDB.HYDRADB_S3_ENDPOINT}}` | Same S3 endpoint as the node. |
| `HYDRADB_S3_ADDRESSING` | `${{HydraDB.HYDRADB_S3_ADDRESSING}}` | Same addressing style as the node. |
| `GRAPH_NAMESPACE` | `${{HydraDB.GRAPH_NAMESPACE}}` | Same namespace as the node. |
| `GRAPH_ID` | `${{HydraDB.GRAPH_ID}}` | Same graph id as the node. |
| `GRAPH_CELLS` | `${{HydraDB.GRAPH_CELLS}}` | Same cells as the node. |
| `GRAPH_DATA_PATH` | `${{HydraDB.GRAPH_DATA_PATH}}` | Same data prefix as the node. |
| `GRAPH_INDEXER_BUILD_MODE` | `full` | full rebuilds each index generation (upstream default); incremental reuses the previous one. |
| `GRAPH_INDEXER_INTERVAL_MS` | `5000` | Full sweep interval over all graph scopes (upstream default). |
| `GRAPH_INDEXER_DIRTY_POLL_INTERVAL_MS` | `1000` | Poll for changed graphs (50-60000). 1000 instead of upstream's 250: the node already wakes the indexer. |
| `GRAPH_INDEXER_RETAIN_PREVIOUS` | `1` | Older index generations kept in the Bucket for readers still using them. |
| `GRAPH_SLATE_DB_CACHE_BYTES` | `auto` | SlateDB RAM cache. auto = 5/16 of the memory budget, 64 MiB to 2 GiB; or bytes. |
| `HYDRADB_MEMORY_LIMIT_MB` | `auto` | Memory budget for the auto sizes. auto = the container limit (2 GiB if none is visible); or MiB. |
| `HYDRADB_CPU_LIMIT` | `auto` | Cores for thread pools. auto = the container CPU quota (else nproc), capped at 8; or a number. |
| `GRAPHBLAS_NTHREADS` | `auto` | SuiteSparse GraphBLAS threads. auto = HYDRADB_CPU_LIMIT's core count. |
| `TOKIO_WORKER_THREADS` | `auto` | Async runtime worker threads. auto = the core count, at least 2. |
| `RUST_LOG` | `info` | Log filter (JSON logs). |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `60` | Seconds between SIGTERM and SIGKILL, so an index build can stop cleanly. |

Set by the start script: `GRAPH_AUTH_TOKEN_FILE`, `GRAPH_INDEXER_ADMIN_ADDR=[::]:9091`, `AWS_ENDPOINT`, `AWS_VIRTUAL_HOSTED_STYLE_REQUEST`, `OMP_NUM_THREADS`, `MALLOC_ARENA_MAX`, `RUST_MIN_STACK`.

### Bucket

Railway Storage Bucket named `Bucket` (private, S3-compatible). Exposes `BUCKET`, `ENDPOINT`, `REGION`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`. Layout under `GRAPH_DATA_PATH` (`hydradb/`): SlateDB manifests, WAL and SST objects per scope and cell, heartbeats, writer leases, index generations and publication pointers, plus short-lived `_create_only_probe/` objects (deleted after each probe). Railway Buckets have no versioning, lifecycle rules or automatic backups.

<!-- END SERVICES -->

### Files

| File | Purpose |
|---|---|
| `services/hydradb/Dockerfile` | `FROM ghcr.io/hydra-db/hydradb:0.3.0@sha256:…`; `USER root` for the volume fix-up; adds the start script; build-time checks (`sh -n`, both binaries, `setpriv`, `openssl`, uid 10001); `ENV RUST_MIN_STACK`; no `VOLUME` (Rule 8.17) |
| `services/hydradb/railway-entrypoint.sh` | POSIX sh: role, token file, Bucket endpoint, cache volume and identity marker, TLS mode, listeners, cgroup sizing, privilege drop, `exec` |

## Improvements over upstream defaults

There is no market template to improve on, so this compares with what upstream's Dockerfile and Helm chart give you on a generic container platform:

1. **Works with Railway Buckets out of the box:** virtual-hosted endpoint built for object_store, region and credentials wired by reference, empty `AWS_*` values removed.
2. **Token generated and written to the file HydraDB needs** (Railway has no secret files); shared with the indexer by reference; scrubbed from the process environment.
3. **`RUST_MIN_STACK` set**, which upstream's image and chart omit although upstream's docs say the node aborts on the first query without it.
4. **Caches and thread pools sized to the container**, not the host: SlateDB RAM cache, GraphBLAS matrix memory, disk cache (from the volume size), GraphBLAS/OpenMP threads, tokio workers, glibc arenas. Upstream's fixed 640 MiB + 128 MiB + 8 GiB defaults assume a 4–16 GiB pod with a 20 GiB cache disk.
5. **Volume ownership fixed at start** for the non-root image, then privileges dropped with `no_new_privs`.
6. **Cache safety:** identity marker, so a cache from another bucket or data path is never served.
7. **Dual-stack listeners** (`[::]`) for Railway's private network (upstream binds `0.0.0.0`).
8. **Readiness healthcheck** that also proves the Bucket supports the conditional writes HydraDB's fencing needs.
9. **Ready-made connection variables:** `HYDRADB_URL`, `HYDRADB_QUERY_URL`, `HYDRADB_BOLT_URL`, `HYDRADB_HOST`, `HYDRADB_PUBLIC_URL`, `HYDRADB_METRICS_URL`, plus `NEO4J_URI`/`NEO4J_USERNAME`/`NEO4J_PASSWORD`/`NEO4J_DATABASE` for driver-based apps.
10. **Optional self-signed TLS** for Bolt through a TCP proxy, generated and renewed on the volume.
11. **Less idle polling egress:** the indexer's dirty poll is 1 s instead of 250 ms, because the node's wake URL is wired.
12. **Fail-fast validation** of every input the script touches, with exit code 78 and a message that names the variable.

## Resource estimate

Not measured: no container was run in this round. The estimates come from the image contents and upstream's chart (requests 2 vCPU / 4 GiB per component, sized for large graphs).

| Service | Idle RAM | Typical RAM | Idle vCPU | Typical vCPU | Storage |
|---|---|---|---|---|---|
| HydraDB | 0.15–0.3 GB | 0.5–1.2 GB (RAM cache fills with the working set, up to the auto cap) | 0.02–0.05 | 0.2–0.5 | volume: cache usage, up to 75% of the volume |
| HydraDB Indexer | 0.1–0.2 GB | 0.3–1 GB during builds (graph-size dependent) | 0.01–0.03 | 0.1–0.5 in bursts | none |
| Bucket | | | | | the graph itself, $0.015/GB-month (Railway docs) |

Prices: RAM $10/GB-month, vCPU $20/vCPU-month, volume $0.15/GB-month, egress $0.05/GB. S3 API calls and bucket egress are free. Data the services **upload** to the Bucket (WAL, compaction output, index generations, heartbeats, polling requests) counts as service egress.

- **Idle:** 0.4 GB × $10 + 0.05 vCPU × $20 + 0.2 GB volume × $0.15 + ~10 GB polling egress × $0.05 ≈ **$5.50/month**.
- **Typical (small app graph, steady reads, light writes):** 1.2 GB × $10 + 0.4 vCPU × $20 + 2 GB volume × $0.15 + 5 GB bucket × $0.015 + ~30 GB egress × $0.05 ≈ **$22/month**.
- **Busy (millions of edges, write-heavy, index rebuilds):** 4 GB × $10 + 2 vCPU × $20 + 5 GB × $0.15 + 50 GB × $0.015 + ~200 GB egress × $0.05 ≈ **$92/month**. Write amplification (WAL + compaction + index generations) makes egress noticeable here.

**Minimum plan:** Trial/Free can boot it for evaluation (1 GB / 0.5 GB RAM per service, 0.5 GB volume → 384 MiB disk cache), if Buckets are available on the account. **Hobby** for real use (5 GB volume → ~3.75 GiB disk cache; the graph itself lives in the Bucket, so the volume does not cap graph size). **Pro** for large caches or multi-node setups.

## Verification checklist

1. Both services build (Dockerfile checks pass) and both deploy healthy: HydraDB `/readyz` on 9090, Indexer `/readyz` on 9091, within 300 s.
2. HydraDB logs, in order: `[railway] object store: bucket …, virtual-hosted requests to https://{bucket}.t3.storageapi.dev, region …`, `cache: SlateDB disk cache … MiB … (75% of the … MiB volume)`, `tls: off …`, `memory: budget … MiB (container memory limit | assumed)`, `cpu: N core(s) (…)`, `starting graph-node as uid 10001`; then HydraDB's JSON lines `starting graph node`, `object store passed the create-only probe: writers allowed`, `graph node listeners started`. **Record** the memory and CPU sources and values (they decide the defaults; see Open questions).
3. If instead `object store failed the create-only probe` appears, stop: the Bucket does not honour `If-None-Match: *` or user metadata (see Open questions).
4. From your machine: `curl https://{public-domain}/healthz` → `{"status":"ok"}`. A query without the token → 401 `unauthenticated`. With the token, the README's write → read → delete round trip returns `{"type":"vertex_id","value":2}`.
5. Nothing public reaches the admin ports: `https://{public-domain}/metrics` and `/readyz` return 404 from the query API's router (only 8443 has a domain).
6. From another service in the project: a Neo4j driver with `${{HydraDB.NEO4J_URI}}`, user `neo4j`, password `${{HydraDB.NEO4J_PASSWORD}}`, database `default`: `MERGE (a {id: 1})-[:FOLLOWS]->(b {id: 2})`, then `MATCH (a {id: 1})-[:FOLLOWS]->(b) RETURN b.id AS id` → 2. Try a `neo4j://` URI too (routing table → `hydradb.railway.internal:7687`).
7. `curl ${{HydraDB.HYDRADB_METRICS_URL}}` from another service → Prometheus text; the Indexer's `http://hydradb-indexer.railway.internal:9091/metrics` too.
8. After some writes, Indexer logs show index generations being built and published, and HydraDB logs show index discovery. A traversal over a few thousand edges uses the compiled index (planner fields in the logs).
9. Persistence: redeploy HydraDB → data still there (it lives in the Bucket); logs show no cache wipe. Redeploy the Indexer → no errors.
10. Unclean stop: restart HydraDB from the dashboard during writes → reads work at once; writes resume within ≤ 30 s.
11. Bucket browser: objects under `hydradb/`; no `_create_only_probe/` objects left behind.
12. Optional: TCP proxy on 7687 + `HYDRADB_TLS=self-signed` → `bolt+ssc://{proxy-domain}:{proxy-port}` connects; the public domain then returns 502 (expected).

## Open questions

- **Not deploy-tested; no container run.** Verified statically: `sh -n`/`dash -n`/`bash -n` on the start script, a 135-check test harness under dash and bash with stubbed binaries, `id`, `chown`, `setpriv`, `df` and fake cgroup v1/v2 trees (sizing, overrides, invalid input, cache identity, TLS generation with OpenSSL 3.6, non-root mode), a simulation of Railway's reference resolution for both services fed into the script, JSON parsing and `_tools/to_serialized.py`, GHCR registry checks (tags, index, config, base and package layer file lists for `setpriv`, `openssl`, `dash`, GNU `find`), and reading upstream source at v0.3.0 plus object_store 0.14.1, the SlateDB fork and tokio 1.52.4. No `docker build` (Rule 8.10 not run per the brief); low risk (one `FROM`, one `COPY`, one check `RUN`).
- **Railway Bucket and conditional writes.** Not documented by Railway. HydraDB's own probe decides at boot (failure = node not ready, deploy fails the healthcheck). Tigris documents `If-Match`/`If-None-Match` on PUT, and Railway's endpoint appears to be Tigris-backed (unconfirmed). Whether Railway's bucket layer honours them, and returns `x-amz-meta-*` on HEAD, is the first thing the deploy test answers.
- **Virtual-hosted addressing** (`https://{bucket}.t3.storageapi.dev`) is taken from Railway's docs, not tested against a real bucket. `HYDRADB_S3_ADDRESSING=path` is the switch if requests fail with DNS or signature errors.
- **Cgroup visibility on Railway** is unknown (see the RabbitMQ and pgvector templates). If Railway exposes the plan ceiling as `memory.max`, the caps (2 GiB RAM cache, 512 MiB GraphBLAS) bound memory. If it exposes nothing, 2 GiB is assumed. Record both on the first deploy.
- **`[::]` listeners and Railway's IPv4 healthcheck:** Rust listeners are dual-stack under Linux defaults; not observed on Railway.
- **`setpriv --no-new-privs` under Railway's runtime** and `chown` on the volume: standard util-linux behaviour, not run.
- **Real RAM/CPU/egress** are estimates. Polling egress in particular (node heartbeats, lease renewals, manifest polls, indexer polls) should be read from the Railway metrics after a day idle.
- **External Bolt is plaintext unless `HYDRADB_TLS=self-signed`**, and self-signed mode disables the public HTTPS domain (HydraDB's TLS covers both listeners). A TLS-terminating sidecar would allow both; not added.
- **Single node only.** Multi-node needs one Railway service per node, each with its own `GRAPH_NODE_ID`, and all node addresses in `GRAPH_BOLT_NODE_ADDRESSES`. Not templated or tested.
- **AGPL-3.0:** see NOTICE.md. Running the unmodified image is fine; modified builds served to users trigger section 13.
- **Repo name** `baranberkay96/hydradb-railway` comes from the brief. The deploy-button slug `hydradb-v03-graph-database-on-object-sto` is predicted from earlier publishes (40-character truncation); confirm it at publish time.
