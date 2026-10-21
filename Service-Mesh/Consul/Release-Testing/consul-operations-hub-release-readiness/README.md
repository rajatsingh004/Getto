# Consul Operations Hub — Release Readiness

Release-readiness documentation for Consul Operations Hub, the customer-facing product built on the Consul Global Management Plane (CMP). This project organizes the supplied release notes, architecture, deployment examples, and operational checks for the Consul Enterprise 2.1.x release family.

## Release information

- **Product:** Consul Operations Hub (component/API shorthand: CMP)
- **Release candidate described:** Consul Enterprise 2.1.0-rc2
- **Release version also listed:** Consul Enterprise 2.1.0+ent and Consul 2.1.0-rc1
- **Release readiness outcome:** Not specified in the supplied material

> **Version discrepancy:** The overview describes Operations Hub shipping in Consul Enterprise 2.1.0-rc2, while the Release Version & Date field lists Consul Enterprise 2.1.0+ent and Consul 2.1.0-rc1. Confirm the intended build/release association before publishing this as a final release certification. No release date or final support-readiness decision was supplied.

## Product summary

Operations Hub is a self-hosted, read-only inventory dashboard for Consul estates. Consul Enterprise server leaders send catalog data—services, nodes, gateways, and health checks—over HTTPS using the new `global_registry` configuration block. The Hub stores the data in Neo4j and presents it through a REST API and web UI.

The Hub runs inside the customer environment. The design calls for no external runtime dependency beyond the customer-provisioned datastore, no HashiCorp-hosted control plane, and no write-back to managed Consul datacenters. The Hub mints per-cluster bearer tokens used by Consul to push catalog data.

## Project layout

```text
.
├── README.md
├── docs/
│   ├── architecture.md
│   └── operations.md
└── examples/
    ├── global-registry.hcl
    └── operations-hub-values.yaml
```

## Scenarios covered

1. **Fleet health:** Review health, stale-data warnings, and last synchronization across many datacenters from one dashboard.
2. **Mesh topology:** Explore evidence-based service connectivity from catalog data without inferring unconfirmed links.
3. **Security posture:** Compare mesh health, mTLS status, ACL enablement, certificate authority providers, and token counts.
4. **Datacenter onboarding:** Register a datacenter, generate its cluster UUID and one-time bearer token, configure `global_registry`, and wait for its data to appear.

## Prerequisites at a glance

- Kubernetes 1.27+, `kubectl`, and Helm 3.x.
- Consul Enterprise 2.1.x server agents with a valid license; `global_registry` is Enterprise-only.
- Consul service mesh injection (`connectInject.enabled=true`) and Consul API Gateway controller (`apiGateway.enabled=true`).
- Neo4j 5.x reachable from Operations Hub over Bolt (`bolt://`, port 7687), either external or through a chart subchart.
- DNS and a TLS certificate for the Operations Hub gateway hostname. A private CA can be supplied to Consul agents with `ca_file`.
- OIDC provider for UI access: bundled Keycloak by default, or an external OIDC/SAML provider.
- Gateway proxy request timeout of 300 seconds for full snapshots.

## Read next

- [Architecture, data flow, and behavior](docs/architecture.md)
- [Deployment, configuration, and operational checks](docs/operations.md)
- [Consul server `global_registry` example](examples/global-registry.hcl)
- [Helm values example](examples/operations-hub-values.yaml)

## Scope and evidence

This repository captures the supplied design and operational guidance. The source material does not include a test matrix, observed test outcomes, a final support-readiness decision, or a release date. Treat configuration snippets as templates and verify chart values and Consul configuration against the exact release artifacts before use.

