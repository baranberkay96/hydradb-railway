# NOTICE

This Railway template is a community package. It is not affiliated with or endorsed by the HydraDB project or its maintainers (github.com/hydra-db).

## What this template runs

| Component | Source | License |
|---|---|---|
| HydraDB `graph-node`, `graph-indexer`, `falkor-dump-import` | Official image `ghcr.io/hydra-db/hydradb:0.3.0@sha256:515ee78600b5d543f9146e62e775c76a8d5d0309773c165b918ed770649a91f3`, built by upstream's `.github/workflows/container.yml` from https://github.com/hydra-db/hydradb at tag `v0.3.0` (commit `0283b42fdf3d5c6e22dc9720445d131a16949104`; image labels `org.opencontainers.image.licenses=AGPL-3.0`, `org.opencontainers.image.version=v0.3.0`) | GNU Affero General Public License v3.0 (`LICENSE` in the repository) |
| SlateDB (fork `hydra-db/slatedb` at `c1003496403d7c9d6613175d529381eb32e17d46`), object_store 0.14.1, tokio and the other Rust crates compiled into the binaries | Pinned by upstream's `Cargo.lock` | Their own licenses (mostly Apache-2.0 and/or MIT); see each crate |
| Ubuntu 24.04 base, SuiteSparse GraphBLAS (`libgraphblas7`), `libcypher-parser8`, OpenSSL, util-linux (`setpriv`) | Ubuntu packages installed by upstream's Dockerfile | Their own licenses (GraphBLAS: Apache-2.0; libcypher-parser: Apache-2.0; OpenSSL: Apache-2.0; util-linux: GPL-2.0-or-later and others); see `/usr/share/doc/*/copyright` in the image |

The upstream image is used as published. The template's Dockerfile adds one file, `railway-entrypoint.sh`, and changes the start user to root so that this script can fix volume ownership. The script then drops to the image's own uid 10001 before running HydraDB. No HydraDB file is changed, patched or rebuilt.

## Files in this package

| File | Origin |
|---|---|
| `services/hydradb/Dockerfile` | Written for this template |
| `services/hydradb/railway-entrypoint.sh` | Written for this template from HydraDB's documented environment variables and source (listed below). The cgroup-sizing approach follows this project's own earlier templates (RabbitMQ, pgvector), not third-party code |
| `template.json`, `TEMPLATE.md`, `README.md`, `NOTICE.md` | Written for this template. The README's example queries follow the shapes documented in upstream's `README.md` and `USING-HYDRADB.md`; no upstream prose is copied |

No file was copied from `_upstream/` or from any other template. There is no Railway marketplace template for HydraDB to compare with (`_market/` is empty).

## AGPL-3.0 notes

These are practical notes, not legal advice. Consult your own counsel for your situation.

- HydraDB is licensed under the AGPL-3.0. Running the unmodified official image and letting users or applications reach it over a network does not change HydraDB's license. Upstream publishes the complete corresponding source at https://github.com/hydra-db/hydradb/tree/v0.3.0.
- If you **modify** HydraDB, for example by building your own image from patched source, and let users interact with that modified version over a network, AGPL-3.0 section 13 requires you to offer those users the corresponding source of your modified version.
- Configuration is not a modification of the program: environment variables, the start-up wrapper, cache sizes and TLS mode. Neither is connecting to HydraDB from your own application through Bolt or HTTP.
- Whether an application that only talks to HydraDB over the network becomes subject to the AGPL is a legal question this note does not answer. The common reading is that it does not, but get advice if this matters to your business.
- Graph data you store in HydraDB is yours and is not covered by the program's license.
- This package (Dockerfile, script, documentation) adds no license obligations of its own beyond those of the software it runs.

## Upstream material checked (HydraDB v0.3.0, 2026-10-30)

The local copy in `_upstream/hydra-db__hydradb` is `main`, 6 commits after v0.3.0; those commits only add `gql/*.md` documentation. The files this template relies on were compared byte for byte with `ref=v0.3.0` through `gh api repos/hydra-db/hydradb/contents/{path}`. Read for configuration facts only:

- `Dockerfile` (stages, features `server-runtime,indexer-runtime,experimental-cypher-engine,otlp`, runtime user 10001, `/var/cache/slatedb`, ports 7687/8443/9090/9443, `ENTRYPOINT graph-node`), `.dockerignore`, `.github/workflows/container.yml` (tag scheme `{{version}}`, `{{major}}.{{minor}}`, multi-arch), `.github/SECURITY.md` (unauthenticated admin probes, plaintext meant for development)
- `README.md`, `USING-HYDRADB.md`, `cypher-compat.md`, `architecture.md`, `AGENTS.md` (`RUST_MIN_STACK=33554432`, ports, health endpoints, Bolt authentication, dialect limits), `CHANGELOG.md` (0.3.0 create-only PUT conformance)
- `charts/hydradb/values.yaml`, `templates/configmap.yaml`, `node-statefulset.yaml`, `indexer-deployment.yaml`, `_helpers.tpl`, `Chart.yaml` (`appVersion 0.3.0`; every runtime variable, probes, cache volume, indexer wake URL `/v1/changes:process`, resources)
- `src/bin/graph_node/config.rs` (every `GRAPH_*` variable, defaults and validation: plaintext/TLS rule, token file of at least 32 characters, cells, lease and heartbeat bounds, cache handle minimum), `src/bin/graph-node.rs` (start-up order, create-only probe and writer gate, listeners, indexer notifier, SIGTERM handling), `src/bin/graph_node/admin.rs` and `readiness.rs` (routes, readiness), `src/bin/graph_node/tls.rs`, `src/bin/graph-indexer.rs` (indexer variables, bounds, admin routes, wake token), `src/client/http.rs` (routes, body limit, default namespace), `src/client/bolt.rs` (Bolt 5.1 to 5.4), `src/core/create_only.rs`, `src/core/namespace.rs`, `src/engine.rs` (`object_store_from_env`), `src/engine/writer_lease.rs` (per-process holder), `src/sparse_kernel/graphblas.rs` (`GRAPHBLAS_NTHREADS`), `crates/telemetry/src/config.rs` (JSON logs, OTLP variables), `crates/placement/src/heartbeat.rs` (node id rules)
- `Cargo.toml` and `Cargo.lock` (SlateDB fork revision, object_store 0.14.1, tokio 1.52.4)

Dependencies read at their pinned versions (source only, nothing executed):

- `hydra-db/slatedb` `slatedb/src/admin.rs` at `c1003496` (`load_object_store_from_env`, `CLOUD_PROVIDER`, `.env` loading, `AmazonS3Builder::from_env`)
- object_store 0.14.1 crate from crates.io (SHA-256 matches `Cargo.lock`): `aws/builder.rs` (`AWS_*` keys, virtual-hosted endpoint handling, default region), `aws/precondition.rs` (conditional put defaults to ETag), `local.rs`
- tokio 1.52.4 crate from crates.io (SHA-256 matches `Cargo.lock`): `loom/std/mod.rs` (`TOKIO_WORKER_THREADS`)

Image facts were read through the GHCR registry API without Docker: the tag list, the OCI index (amd64 + arm64), the amd64 image config (user, ports, entrypoint, labels, history), and the file lists of the base and runtime-package layers (`setpriv`, `openssl`, `dash`, `find`, `libgomp`, `libgraphblas`).

Railway facts: https://docs.railway.com/storage-buckets (endpoint, virtual-hosted addressing, variables, unsupported features, pricing), https://docs.railway.com/reference/pricing/plans (resource prices and per-plan limits), checked 2026-10-30. Tigris conditional-request documentation (https://www.tigrisdata.com/docs/objects/conditionals) was read as background; Railway does not document which storage provider backs its buckets.

## Logo

The marketplace icon is HydraDB's own favicon from the project's benchmark site repository (`hydra-db/benchmark`, `docs/favicon.svg` at commit `f4598348cb9fe448cda62ab1408381fa1e9863c0`, served via jsDelivr). It is used only to identify the software.

## Trademarks

HydraDB is a name of its respective owner. Neo4j and Cypher are trademarks of Neo4j, Inc.; openCypher is an open project. Tigris belongs to Tigris Data, Inc. Railway belongs to its respective owner. All names are used only to describe compatibility and what the template runs.
