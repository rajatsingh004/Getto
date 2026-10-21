# Consul API Gateway on Kubernetes: Feature Validation

Functional, bypass, and observability validation for advanced Consul API Gateway routing on Kubernetes.

## Status

**Support readiness: APPROVED**  
**Testing completed:** October 2026  
**Reported release:** Consul Enterprise 2.1.0+ent (and Consul 2.1.0-rc1)  
**Test platform:** Kind, Kubernetes v1.35.0

> **Version note:** The supplied test-environment values use Consul `2.1.0-rc2`, `consul-k8s-control-plane:2.1.0-rc1`, and `consul-dataplane:2.1.0-rc1`. The summary also reports testing on Consul and Consul Enterprise `2.1.0-rc1`. Confirm the precise versions associated with each result before publishing this repository as a release-specific certification.

## What was validated

| Capability | Result | Summary |
| --- | --- | --- |
| Inverted HTTP header matching | PASS | `RouteHeaderMatchInvertFilter` routes matching values to the fallback; an absent header does not match the inverted rule. |
| gRPC and HTTP/2 listener protocols | PASS | Listener annotations select protocol; gRPC listeners load `grpc_stats` and `grpc_http1_bridge` in Envoy. |
| Upstream limits and passive health checks | PASS | Route-level circuit-breaker and outlier-detection settings are visible in Envoy; route settings override Gateway defaults. |
| Zero-touch TLS and automatic DNS | PASS | Gateway terminates TLS with a Connect CA leaf certificate; routed services use `<service>.api-gateway.consul`. |

See [test findings](docs/findings.md) and [test environment and operations](docs/test-environment.md).

## Repository layout

```text
.
├── README.md
├── docs/
│   ├── findings.md
│   └── test-environment.md
└── examples/
    ├── 10-gateway.yaml
    └── 20-routes.yaml
```

The YAML examples are the supplied test fixtures. They are illustrative and may need adjustment for the exact Consul chart and CRD version being used. In particular, inspect the installed `RouteUpstreamLimitsFilter` CRD before reusing its fields.

## Prerequisites

- Kubernetes 1.28 or later (tested with Kind and Kubernetes v1.35.0).
- Helm 3 and the Consul Helm chart installed.
- `connectInject.enabled=true` and API Gateway/Gateway API CRDs installed.
- A Consul `GatewayClass` and `Gateway` using the `consul` class.
- `ServiceIntentions` permitting the gateway to reach each backend. A missing or not-yet-propagated intention can cause HTTP 403 responses.
- For DNS tests, CoreDNS forwarding `.consul` queries to Consul DNS.
- For Enterprise tests, a valid license secret. Keep license contents out of source control, tickets, and logs.

## Feature behavior

### Inverted header match

An `HTTPRoute` `ExtensionRef` of kind `RouteHeaderMatchInvertFilter` inverts a header match. In the tested scenario, `x-canary: true` takes the fallback path; `x-canary: false` and `x-canary: foo` take the matched-service path. An absent header does not match the inverted rule, following Envoy semantics.

### Listener protocol

The listener annotation selects `http`, `http2`, `grpc`, or `tcp` and the control plane writes the selected protocol to the `api-gateway` config entry. For `grpc`, Envoy loads `grpc_stats` and `grpc_http1_bridge` filters.

### Upstream limits and passive health checks

`RouteUpstreamLimitsFilter` configures limits and outlier detection per route. Gateway `default-*` annotations provide defaults, with route values taking precedence. Envoy exposes the effective settings as `circuit_breakers` and `outlier_detection`.

### TLS and DNS

Set `consul.hashicorp.com/tls-enabled: "true"` on the Gateway to terminate TLS with a leaf certificate from the Consul Connect CA. The tested certificate SANs include `*.api-gateway.consul` and `*.api-gateway.dc1.consul`. Routed backends resolve as `<service>.api-gateway.consul`; the name is based on the service, not the Gateway.

## Quick verification commands

```sh
# Inspect the Consul API Gateway config entry
consul config read -kind api-gateway -name <gateway-name>

# Check the Consul service catalog and DNS
consul catalog services
dig @<consul-dns-ip> -p 8600 <service>.api-gateway.consul

# Fetch public Connect CA roots for TLS verification
curl -s http://127.0.0.1:8500/v1/connect/ca/roots

# Inspect Envoy configuration from a client or diagnostic shell
kubectl exec <gateway-pod> -c consul-dataplane -- wget -qO- 127.0.0.1:19000/config_dump
```

See [test environment and operations](docs/test-environment.md) for troubleshooting, checklists, and additional commands.

## Original test material

The source test folder was `/Users/rajat.singh/Documents/consul-testing/bob-igw/` and the supplied report reference was `bob-igw-report/test-report.md`. The report folder was not present when this project was organized. The original folder contains detailed evidence captures; they have not been copied into this starter project. Add reviewed, sanitized evidence under an `evidence/` directory before publishing. Do not commit private keys, license data, or unreviewed environment-specific secrets.

## Findings

- **O-1:** Invalid `default-*` values are logged at INFO, while an orphaned listener protocol annotation is logged at DEBUG. PRs #5596/#5594 reportedly describe WARN-level logging.
- **O-2:** Documentation should state that an inverted header match does not match an absent header.
- **O-3:** No deprecation warning appeared on the IngressGateway CRD or config entry.
- **O-4:** `tls-gw` remained `Programmed=False/Pending` for more than 20 minutes although its pod was Ready and traffic worked. Cause is unknown; reproduce on a clean cluster before filing a bug.

Related release context: Confluence page “Consul Releases 2.1.0”; release candidates listed as 2.1.0-rc2 and 2.1.0-rc2+ent.
