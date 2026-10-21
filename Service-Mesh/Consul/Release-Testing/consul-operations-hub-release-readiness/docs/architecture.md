# Architecture and behavior

## Components and data flow

```text
Consul Enterprise server leader
  └── global_registry ── HTTPS push ──► Operations Hub gateway
                                          ├── POST /api/v1/registry/ingest ──► Neo4j
                                          └── GET /api/v1/* ──► Read API / web UI
```

The Consul API Gateway terminates TLS and enforces UI/API OIDC authentication using Envoy `ext_authz` and `oauth2-proxy`. Keycloak is bundled as the default OIDC provider; an external OIDC/SAML identity provider can be used instead.

| Component | Role |
| --- | --- |
| Ingest API | Accepts snapshot and delta pushes from Consul server leaders; authenticates with a per-cluster bearer token. |
| Neo4j graph store | Stores catalog entities such as services, nodes, gateways, and health checks as a multi-datacenter graph. |
| Read API / Graph Service | Serves inventory, topology, security-posture, and freshness queries to the UI. |
| Consul API Gateway | Terminates TLS and enforces UI/API OIDC via Envoy `ext_authz` and `oauth2-proxy`. |
| Keycloak | Bundled default OIDC provider; can be replaced with an external OIDC/SAML IdP. |

## Snapshot and delta pushes

| Push type | Trigger | Purpose |
| --- | --- | --- |
| Snapshot | Periodic; default 10 minutes | Sends full state. Mark-and-sweep removes entries no longer present. |
| Delta | Catalog changes, flushed periodically; default 2 minutes | Sends incremental changes. Last-Write-Wins is guarded by Consul `modifyIndex`. |

Intervals are represented as nanosecond integers in `global_registry` configuration. Example defaults are `600000000000` for 10 minutes and `120000000000` for 2 minutes.

## Freshness model and lifecycle

Every entity carries freshness metadata:

| State | Meaning |
| --- | --- |
| `current` | Data arrived within the staleness threshold (default 90 seconds). |
| `stale` | No push arrived within the threshold. |
| `unknown` | The field was absent from the push; the Hub returns unknown and does not infer a value. |
| `unavailable` | The datacenter has never successfully pushed. |

Datacenter lifecycle states are `empty → pending → connected → stale → disconnected`.

## UI sections

| Section | Content |
| --- | --- |
| Dashboard | Fleet health, service and gateway counts, stale-data warnings. |
| Datacenters | Registered datacenters, health, version, and last sync. |
| Services | Cross-datacenter service inventory, health, mesh status, partition, and namespace. |
| Gateways | Gateway inventory, type, health, and connections. |
| Topology | Global and per-datacenter service connectivity graph. |
| Security | Mesh health, mTLS, ACL posture, and certificate details. |

## Authentication and authorization

- UI and read API authentication is OIDC-enforced at the gateway. Browser users authenticate with a session cookie; programmatic users use a bearer token.
- `POST /api/v1/registry/ingest` uses the cluster-specific bearer token minted during datacenter registration. OIDC is bypassed for ingest by design.
- RBAC is descoped for the Phase 0 MVP: every authenticated operator has full access.

## Architecture decisions

- Self-hosted within the customer environment; no data leaves for a HashiCorp-hosted control plane.
- One binary and one customer-provisioned datastore for operational simplicity.
- Read-only Phase 0: the Hub ingests and serves state and does not write back to Consul.
- The Hub manages the per-cluster cryptographic bearer tokens used for catalog ingestion.

## Consul `global_registry` configuration

The server leader sends catalog data to the Hub over HTTPS. See [`../examples/global-registry.hcl`](../examples/global-registry.hcl) for the complete template.

| Setting | Purpose |
| --- | --- |
| `enabled` | Enables registry publishing. |
| `address` | Operations Hub ingest host over HTTPS. |
| `cluster_id` | UUID created when the datacenter is registered. |
| `token_file` | Path to the datacenter's bearer token. |
| `ca_file` | Optional private CA bundle when the system trust store does not include the gateway CA. |
| `tls_skip_verify` | Must remain `false` in production. |
| `snapshot_interval` | Full-state push interval in nanoseconds. |
| `delta_flush_interval` | Delta flush interval in nanoseconds. |

## Token precedence

Consul uses the first non-empty token source in this order:

1. `CONSUL_GLOBAL_REGISTRY_TOKEN` environment variable
2. `token` configuration field
3. `CONSUL_GLOBAL_REGISTRY_TOKEN_FILE` environment variable
4. `token_file` configuration field

An environment variable can therefore override the token file configured in HCL. Check the effective environment when diagnosing authentication errors.
