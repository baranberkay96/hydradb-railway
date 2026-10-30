# Deploy and Host HydraDB with Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/hydradb-v03-graph-database-on-object-sto?referralCode=20H68q)

HydraDB is an open-source graph database, written in Rust, that keeps its data in S3-compatible object storage. You query it with OpenCypher through Neo4j drivers over Bolt, or through a JSON HTTP API. This community template runs HydraDB 0.3 with its query node and index builder, and uses a Railway Bucket as the store.

## About Hosting HydraDB

HydraDB treats object storage as the source of truth: graph records, write-ahead logs, writer leases and traversal indexes all live in a bucket, and the query node and indexer keep only rebuildable caches. This template connects a Railway Bucket with the addressing HydraDB's S3 client expects, generates the shared token, and sizes RAM, disk cache and threads from the service's limits. The node reports healthy only after HydraDB has checked that the bucket is safe for writes.

## Common Use Cases

- Knowledge graphs and GraphRAG backends that apps query with OpenCypher from Python, JavaScript, Java or Go Neo4j drivers.
- Follower, dependency and network graphs: bounded multi-hop traversals and shortest paths with `algo.SPpaths`.
- Fraud, identity and entity-resolution graphs that need paths between many sources and targets in one request (`algo.MSpaths`).
- Graphs whose storage should grow independently of compute, with durable data in a bucket instead of on a database disk.
- Neo4j-style graph features for a Railway app without running a JVM database server.

## Dependencies for HydraDB Hosting

- HydraDB `0.3.0` from the official image `ghcr.io/hydra-db/hydradb:0.3.0` (`graph-node` and `graph-indexer`)
- A Railway Bucket (S3-compatible) as the durable store for the whole graph
- A Railway volume at `/var/cache/slatedb` for HydraDB's disposable disk cache

### Deployment Dependencies

- HydraDB source, releases and license: https://github.com/hydra-db/hydradb
- Using HydraDB (connecting, dialect, response format): https://github.com/hydra-db/hydradb/blob/v0.3.0/USING-HYDRADB.md
- Supported OpenCypher subset: https://github.com/hydra-db/hydradb/blob/v0.3.0/cypher-compat.md
- Architecture: https://github.com/hydra-db/hydradb/blob/v0.3.0/architecture.md
- Neo4j drivers: https://neo4j.com/docs/create-applications/
- Railway Storage Buckets: https://docs.railway.com/storage-buckets

### Implementation Details

| Service | Role | Public | Storage |
|---|---|---|---|
| HydraDB | `graph-node`: Bolt on 7687 and the HTTP query API on 8443 (private network), admin and Prometheus metrics on 9090 (private) | HTTPS domain → 8443, bearer token required. Optional TCP proxy for Bolt | Volume `/var/cache/slatedb` (cache only) |
| HydraDB Indexer | `graph-indexer`: builds and publishes traversal indexes; admin and metrics on 9091 (private) | No | None |
| Bucket | Railway Bucket holding all graph data under the `hydradb/` prefix | No | Bucket |

**First query**

1. Deploy the template. No input is required: the token is generated, and the Bucket is created and connected.
2. Wait until both services are healthy. HydraDB turns healthy only after its startup check of the Bucket's conditional writes has passed.
3. Copy `HYDRADB_AUTH_TOKEN` and the public domain from the HydraDB service, then write, read and clean up a test edge:

```bash
TOKEN='{your-token}'
URL='https://{your-domain}/v1/graphs/default/query'
q() { curl -sS "$URL" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "{\"cell_id\":\"cell-0\",\"query\":\"$1\"}"; echo; }

q 'MERGE (a {id: 1})-[:FOLLOWS]->(b {id: 2})'
q 'MATCH (a {id: 1})-[:FOLLOWS]->(b) RETURN b.id AS id'
q 'MATCH (a {id: 1}) DETACH DELETE a'
q 'MATCH (a {id: 2}) DETACH DELETE a'
```

The second call returns one row: `{"type":"vertex_id","value":2}`. A request without the token gets `401 unauthenticated`. There is no web UI. `GET /healthz` answers without a token.

**Connecting services in the same project**

Reference these variables from your app service:

- Bolt (Neo4j drivers): `NEO4J_URI` = `${{HydraDB.NEO4J_URI}}` (`bolt://hydradb.railway.internal:7687`), `NEO4J_USERNAME` = `${{HydraDB.NEO4J_USERNAME}}`, `NEO4J_PASSWORD` = `${{HydraDB.NEO4J_PASSWORD}}`, `NEO4J_DATABASE` = `${{HydraDB.NEO4J_DATABASE}}`
- HTTP: `HYDRADB_URL` = `${{HydraDB.HYDRADB_URL}}` or `${{HydraDB.HYDRADB_QUERY_URL}}`, with `HYDRADB_AUTH_TOKEN` = `${{HydraDB.HYDRADB_AUTH_TOKEN}}`
- Host only: `${{HydraDB.HYDRADB_HOST}}`

`neo4j://` routing URIs also work on the private network. The token in the password field grants full read and write access, so treat it like a database password.

**HydraDB is not full Neo4j**

The Bolt protocol and drivers are compatible, but the query language is a deliberate OpenCypher subset. Before writing code, read upstream's `USING-HYDRADB.md`. The points that surprise people most:

- Every HTTP request needs `cell_id` (`cell-0` here). A wrong one returns HTTP 500.
- Each relationship pattern needs one type and a direction. Unbounded `*` paths, `RETURN *` and unanchored `MATCH (a)` are rejected.
- A single write must create an edge. Edgeless nodes are created with `UNWIND $rows AS row MERGE (n {id: row.id}) SET n:Label, ...`.
- `id` is the node's identity (an upsert key). Repeated plain `CREATE` duplicates edges; `MERGE` and `UNWIND` batches do not.
- Every statement commits on its own (no `BEGIN`/`COMMIT`). Batches are capped at 1024 rows, pages at 4096.
- Tools that depend on APOC or Neo4j system procedures (for example schema introspection in some LLM frameworks) will not work.

**Connecting from outside Railway**

- **HTTPS (recommended):** use `${{HydraDB.HYDRADB_PUBLIC_URL}}/v1/graphs/default/query` with the bearer token. Railway terminates TLS.
- **Bolt through a TCP proxy (optional):** add a TCP proxy on port `7687` and connect with `bolt://{proxy-domain}:{proxy-port}` (not `neo4j://`). Without TLS the token and data cross the internet in clear text. `HYDRADB_TLS=self-signed` encrypts it (`bolt+ssc://`), but then HTTP requires TLS too and the public HTTPS domain stops working.

**Settings worth knowing**

| Variable | Default | Meaning |
|---|---|---|
| `GRAPH_SLATE_DB_CACHE_BYTES` | `auto` | RAM cache for graph data: 5/16 of the service's memory limit, between 64 MiB and 2 GiB (640 MiB at 2 GiB, upstream's default). |
| `GRAPH_DATA_CACHE_BYTES` | `auto` | Disk cache on the volume: 75% of the volume, between 64 MiB and 8 GiB. |
| `GRAPH_MAX_GRAPHBLAS_BYTES` | `auto` | Memory for compiled GraphBLAS traversal matrices: 1/16 of the memory limit, 32 to 512 MiB. |
| `HYDRADB_MEMORY_LIMIT_MB`, `HYDRADB_CPU_LIMIT` | `auto` | What the auto sizes are based on. If Railway exposes no limit, 2 GiB is assumed; thread pools are capped at 8 cores. |
| `HYDRADB_S3_ADDRESSING` | `virtual` | Railway Buckets use `https://{bucket}.{endpoint}`. Set `path` for older buckets, as their Credentials tab says. |
| `GRAPH_INDEXER_BUILD_MODE` | `full` | On the Indexer. `incremental` reuses the previous index generation for large, slowly changing graphs. |

**Monitoring**

Scrape `${{HydraDB.HYDRADB_METRICS_URL}}` and the Indexer's `:9091/metrics` from a Prometheus service in the same project (private, no authentication). `OTEL_EXPORTER_OTLP_ENDPOINT` enables OTLP export.

**Rotating the token**

Set a new `HYDRADB_AUTH_TOKEN` on HydraDB: at least 32 characters, using only letters, digits and `. _ ~ -`. The Indexer references it. Then redeploy HydraDB, the Indexer and every service that references the token.

**Persistence, redeploys and backups**

- All data lives in the Bucket. The volume holds only a cache, and HydraDB refills it on demand.
- A redeploy stops the node briefly (one deployment mounts the volume at a time). After a crash, reads work immediately and writes resume within 30 seconds.
- If you empty the Bucket but keep it, set `HYDRADB_CACHE_RESET=true` for one deploy, then back to `false`.
- Railway Buckets have no versioning or automatic backups. Back up by copying the `hydradb/` prefix with an S3 tool such as rclone, ideally with HydraDB stopped.

**Scaling**

One query node with one indexer. Scale vertically: raise memory and CPU, and the caches and thread pools follow on the next deploy. The graph's size is limited by the Bucket, not the volume.

**Pinning and upgrades**

The version is pinned by tag and digest in `services/hydradb/Dockerfile`. HydraDB is pre-1.0, so back up the `hydradb/` prefix before changing both, then redeploy both services.

**Resources**

Expect about 0.4 GB of RAM in total at idle (roughly $5.50 per month including the volume and polling egress) and about 1.2 GB for a small app graph (roughly $22 per month). Writes to the Bucket count as service egress. Trial is enough for an evaluation. Use Hobby for real projects.

**License**

HydraDB is licensed under the AGPL-3.0. This template runs the unmodified official image. If you modify HydraDB and offer the modified version to users over a network, the AGPL requires you to share your changes. This is a community template, not affiliated with the HydraDB project.

### Why Deploy HydraDB on Railway?

Railway gives HydraDB what its design expects: an S3-compatible bucket next to the compute, private networking between your apps and the database, and usage-based billing that keeps idle graphs cheap. You get an authenticated, Neo4j-driver-compatible graph database with ready-made connection variables, without running Kubernetes.
