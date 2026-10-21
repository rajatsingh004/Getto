# Test environment and operations

## Environment

- Kind cluster `bob-igw`: one control-plane node and one worker.
- Kubernetes v1.35.0.
- Consul CE installed with Helm chart 2.1.0-rc1, using `values-ce.yaml` per the supplied notes.
- CoreDNS patched to forward `.consul` queries to Consul DNS.
- `curl` and Fortio test clients ran in a client namespace.
- Images were loaded with `docker save | ctr -n k8s.io images import -`. `kind load` and `--all-platforms` failed on multi-architecture manifests.

The supplied `values-ce.yaml` from the original folder instead specifies Consul `2.1.0-rc2`, control plane `2.1.0-rc1`, and dataplane `2.1.0-rc1`. Record the exact image/chart versions for each run when publishing detailed evidence.

## Prerequisites

- Kubernetes 1.28 or later.
- Helm 3 and Consul Helm chart.
- `connectInject.enabled=true` and API Gateway CRDs installed (through `apigateway.enabled` or Gateway API CRDs from the chart).
- Consul-managed GatewayClass and Gateway.
- ServiceIntentions allowing gateway access to every backend; allow time for intentions to propagate.
- CoreDNS `.consul` forward for DNS tests.
- Valid Enterprise license secret for Enterprise tests. Never include license contents in repository files.

## Configuration checks

```sh
# Confirm the config entry contains listener protocol and TLS settings
consul config read -kind api-gateway -name <gateway-name>

# A no-op Gateway re-apply should leave ModifyIndex unchanged

# Check Envoy listeners, filters, circuit breakers, and outlier detection
kubectl -n <namespace> exec <gateway-pod> -c consul-dataplane -- \
  wget -qO- 127.0.0.1:19000/config_dump

# Check Envoy clusters
kubectl exec <gateway-pod> -c consul-dataplane -- wget -qO- 127.0.0.1:19000/clusters

# Check Connect CA root availability (public certificate only)
curl -s http://127.0.0.1:8500/v1/connect/ca/roots

# Resolve service DNS through Consul DNS
dig @<consul-dns-ip> -p 8600 <service>.api-gateway.consul

# Verify gateway TLS with Connect CA root and expected SNI
openssl s_client -connect <gateway-ip>:443 \
  -servername <service>.api-gateway.consul -CAfile connect-ca.pem
```

Expected observations include `grpc_stats` and `grpc_http1_bridge` for gRPC listeners, and `circuit_breakers` and `outlier_detection` values matching effective route/default settings. Verify that route-level limits override Gateway `default-*` annotations.

## Troubleshooting

| Symptom | Likely cause | Action |
| --- | --- | --- |
| HTTP 403 from gateway | No ServiceIntention, or intention has not propagated | Create/verify the intention, wait, then retest. A 403 that clears shortly afterward is propagation delay. |
| HTTP 503, no healthy upstream | Backend ejected by outlier detection, or backend lacks a sidecar | Inspect Envoy `outlier_detection` and the backend pod. |
| TLS verification error | Verification uses the Helm TLS CA instead of Connect CA | Obtain public Connect CA roots from `/v1/connect/ca/roots` and verify with the Connect CA root. |
| DNS name does not resolve | Missing CoreDNS `.consul` forward or wrong name | Query `<service>.api-gateway.consul`, not the Gateway name; check client reachability to Consul DNS. |
| Annotation has no effect | Invalid value or listener name does not exist | Check annotation spelling/value and matching listener. Invalid `default-*` values are logged at INFO; orphaned protocol annotations at DEBUG. |
| Gateway is `Programmed=False` / Pending | Pods may still be scheduling or status may not have updated | Check pod readiness and control-plane logs. Finding O-4 requires clean-cluster reproduction. |
| Listener port-forward fails | Envoy listens on the pod IP | Test from an in-cluster client pod. Use the Gateway Service or pod IP with the right SNI/Host header. |

## Useful commands

```sh
kubectl logs -n consul deploy/consul-connect-injector
kubectl logs -n consul <gateway-pod> -c consul-dataplane
kubectl get gateway,httproute -A -o yaml
kubectl describe gateway <gateway-name>
kubectl get events -n <namespace>
```

To inspect the Envoy config dump:

```sh
kubectl -n consul exec <gateway-pod> -c consul-dataplane -- \
  wget -qO- 127.0.0.1:19000/config_dump
```

Raise injector log verbosity to DEBUG to see orphaned listener protocol annotations.

## CRD field compatibility

The example field names for `RouteUpstreamLimitsFilter` must be checked against the CRD installed with the target chart before reuse:

```sh
kubectl get crd routeupstreamlimitsfilters.consul.hashicorp.com -o yaml
```

## Original evidence location

The original fixtures and evidence are in `/Users/rajat.singh/Documents/consul-testing/bob-igw/`. The report path provided was `bob-igw-report/test-report.md`; that directory was not present at the time this project was prepared. Review and sanitize evidence before adding it to GitHub. In particular, do not add license contents or private keys.
