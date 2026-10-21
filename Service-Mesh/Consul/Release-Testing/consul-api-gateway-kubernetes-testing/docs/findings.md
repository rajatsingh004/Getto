# Test findings

## Summary

All reported functional, bypass, and observability test cases passed on Kind Kubernetes v1.35.0. Support readiness was marked **APPROVED**. Testing was completed in October 2026.

| Feature | Result |
| --- | --- |
| Header match invert | PASS |
| gRPC and HTTP/2 listener protocol | PASS |
| Upstream limits and passive health checks | PASS |
| Zero-touch TLS and auto-DNS | PASS |

## Background and customer scenario

The work addresses gaps for customers moving from an `IngressGateway` config entry to API Gateway on Kubernetes:

- Route traffic away from a backend when a header does not match, such as sending `x-canary: true` traffic to a fallback.
- Expose gRPC and HTTP/2 services through gateway listeners.
- Protect backends from overload with connection limits and passive health checks (outlier detection).
- Obtain listener TLS and names such as `<service>.api-gateway.consul` without manually managing certificates.

The gaps under test included load-balancing algorithms, sticky sessions, failover, inverted and suffix header matching, automatic subdomains/DNS/TLS, and listener timeouts. The specific reported passing results are listed above; do not treat the broader background list as separate test cases unless supported by evidence.

## Detailed behavior

### Header match invert

An `HTTPRoute` `ExtensionRef` of kind `RouteHeaderMatchInvertFilter` inverts a header match. In the tested scenario:

- `x-canary: true` goes to the fallback.
- `x-canary: false` and `x-canary: foo` go to the matched service.
- When the header is absent, the request goes to the fallback because an inverted match does not match an absent header under Envoy semantics.

### Listener protocol

The `api-gateway.consul.hashicorp.com/listener-<name>-protocol` annotation selects `http`, `http2`, `grpc`, or `tcp`. The control plane writes that protocol into the `api-gateway` config entry. For `grpc`, Envoy loads `grpc_stats` and `grpc_http1_bridge` filters.

### Upstream limits and passive health checks

`RouteUpstreamLimitsFilter` sets per-route limits and outlier detection. Gateway `default-*` annotations supply defaults; route-level configuration overrides Gateway defaults. Envoy shows the resulting settings under `circuit_breakers` and `outlier_detection`.

### TLS and automatic DNS

The annotation `consul.hashicorp.com/tls-enabled: "true"` enables listener TLS termination with a leaf certificate issued by the Consul Connect CA. Tested SANs were `*.api-gateway.consul` and `*.api-gateway.dc1.consul`. Routed backend names use `<service>.api-gateway.consul`, not the Gateway name.

## Observations

- **O-1 — Annotation log level:** Invalid `default-*` annotation values are ignored and logged at INFO, not WARN. An orphaned `listener-<name>-protocol` annotation (with no matching listener) is logged at DEBUG. PRs #5596/#5594 reportedly describe WARN.
- **O-2 — Inverted match docs:** Documentation should clarify that an inverted header match does not match when the header is absent.
- **O-3 — IngressGateway deprecation:** No deprecation warning appeared on the IngressGateway CRD or config entry.
- **O-4 — Gateway status:** `tls-gw` stayed `Programmed=False/Pending` for more than 20 minutes despite a Ready pod and working traffic. Cause is unknown. Reproduce on a clean cluster before filing a bug.

## Scope note

No separate event tracing was tested. Use Kubernetes Gateway status conditions and namespace events for status investigation.
