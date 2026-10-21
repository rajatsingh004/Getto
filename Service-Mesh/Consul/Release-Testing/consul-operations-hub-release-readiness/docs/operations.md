# Deployment and operations

## Prerequisites

| Requirement | Minimum / setting | Notes |
| --- | --- | --- |
| Kubernetes | 1.27+ | `kubectl` access and Helm 3.x. |
| Consul Enterprise | 2.1.x | Server agents need a valid Enterprise license. `global_registry` is Enterprise-only. |
| Consul service mesh | Required | Enable `connectInject.enabled=true`. |
| Consul API Gateway controller | Required | Enable `apiGateway.enabled=true`. |
| Neo4j | 5.x | External or bundled subchart; Bolt endpoint must be reachable from Hub pods. |
| DNS and TLS | Required | Gateway hostname and certificate; private CA supported using Consul `ca_file`. |
| OIDC provider | Required for UI | Bundled Keycloak or external OIDC/SAML provider. |

The gateway must permit 300-second ingestion requests for full snapshots. Configure the existing Consul proxy defaults with `local_request_timeout_ms = 300000`, or enable `proxyDefaults.enabled=true` in Helm values to let the chart create the config entry.

## Deploy with Helm

The following flow uses placeholders. Do not commit passwords, OIDC client secrets, cookie secrets, private keys, or real bearer tokens.

### 1. Create secrets

```sh
kubectl create secret generic operations-hub-neo4j \
  --namespace "$HUB_NAMESPACE" \
  --from-file=neo4j-password=/PATH/TO/neo4j-password

# Cookie secret must contain exactly 16, 24, or 32 ASCII characters.
kubectl create secret generic operations-hub-oidc \
  --namespace "$HUB_NAMESPACE" \
  --from-file=client-secret=/PATH/TO/oidc-client-secret \
  --from-file=cookie-secret=/PATH/TO/cookie-secret

kubectl create secret tls operations-hub-tls \
  --namespace "$HUB_NAMESPACE" \
  --cert=/PATH/TO/tls.crt \
  --key=/PATH/TO/tls.key
```

### 2. Prepare Helm values

See [`../examples/operations-hub-values.yaml`](../examples/operations-hub-values.yaml). Replace every placeholder and confirm the values against the chart version you intend to deploy. In production, store Keycloak's admin password in a Kubernetes Secret rather than a plaintext Helm values file.

### 3. Install the chart

```sh
helm install operations-hub /PATH/TO/consul-ops-hub \
  --namespace "$HUB_NAMESPACE" \
  --values operations-hub-values.yaml \
  --wait --timeout 10m
```

### 4. Verify deployment

```sh
kubectl rollout status deployment/operations-hub-consul-ops-hub \
  --namespace "$HUB_NAMESPACE" --timeout=10m
kubectl get gateway operations-hub-consul-ops-hub-gateway \
  --namespace "$HUB_NAMESPACE"
kubectl describe httproute operations-hub-consul-ops-hub-route \
  --namespace "$HUB_NAMESPACE"
```

### 5. Register a datacenter

1. Sign in to `https://HUB_HOST`.
2. Open **Datacenters → Add datacenter** and enter the datacenter name and environment.
3. On the Configure step, generate the token.
4. Save the token and cluster ID immediately; the token is displayed only once.

### 6. Configure Consul Enterprise servers

Add [`../examples/global-registry.hcl`](../examples/global-registry.hcl) to each server agent's configuration, using that datacenter's cluster UUID and token file. Store the token in `/etc/consul.d/registry-token.txt` with restrictive permissions and ownership readable by the Consul process. For a private gateway CA, set `ca_file` to the CA certificate path.

Reload configuration on every server:

```sh
consul reload
```

The leader begins publishing. Data should appear within one snapshot interval (10 minutes by default); reduce `snapshot_interval` during initial testing if needed.

## Troubleshooting

| Symptom | Likely cause | Action |
| --- | --- | --- |
| `401 Unauthorized` on ingest | Token missing, incorrect, or revoked | Match token to `cluster_id`; confirm Consul can read `token_file`; check whether `CONSUL_GLOBAL_REGISTRY_TOKEN` overrides it. |
| Token and cluster ID mismatch | Token belongs to a different registered datacenter | Use the UUID generated for this datacenter; do not reuse another datacenter's ID. |
| `snapshot_interval: cannot parse` | Interval supplied as a string such as `"10m"` | Use nanosecond integers, e.g. `600000000000` for 10 minutes. |
| `x509: certificate signed by unknown authority` | Private gateway CA is not in the system trust store | Set `ca_file` to the Hub gateway CA certificate. |
| `502 Bad Gateway` | Neo4j unavailable to the Hub | Check Bolt URI, credentials, network policy, and service-mesh connectivity. |
| `BackendNotFound` on HTTPRoute | Hub service was not ready when the Gateway reconciled | Wait for readiness and check whether the route self-heals; inspect or restart the Gateway controller if needed. |
| API call redirects with `302` to sign-in | OIDC session absent or expired | Re-authenticate or provide a valid bearer ID token. |
| Datacenter stays `pending` | No snapshot received after registration | Check leader logs for `global_registry` errors and outbound connectivity to gateway port 443. |
| Datacenter becomes `stale` | No push within default 90-second threshold | Check leader health, loaded config, `global_registry.enabled=true`, and connectivity. |

## Logs and diagnostics

### Operations Hub

```sh
POD=$(kubectl get pod -n "$HUB_NAMESPACE" \
  -l app.kubernetes.io/name=consul-ops-hub \
  -o jsonpath='{.items[0].metadata.name}')
kubectl logs "$POD" -n "$HUB_NAMESPACE" --tail=200 -f
```

Look for successful Neo4j connection and received snapshot/delta messages. Token mismatch indicates ingest authentication failure; connection-refused messages indicate Neo4j connectivity problems.

### Consul leader

```sh
grep -i 'global.registry\|global_registry' /var/log/consul/consul.log
# In Kubernetes:
kubectl logs -n consul consul-server-0 | grep -i 'global.registry\|global_registry'
```

Look for registry sync start, snapshot/delta sent, 401 push failures, and TLS errors.

### oauth2-proxy

```sh
PROXY_POD=$(kubectl get pod -n "$HUB_NAMESPACE" \
  -l app.kubernetes.io/component=oauth2-proxy \
  -o jsonpath='{.items[0].metadata.name}')
kubectl logs "$PROXY_POD" -n "$HUB_NAMESPACE" --tail=100
```

## Health and event tracing

The `/health` endpoint exposes per-datacenter freshness and lag for monitoring integrations:

```sh
kubectl port-forward svc/operations-hub-consul-ops-hub 8443:443 \
  -n "$HUB_NAMESPACE" &
curl --cacert /PATH/TO/hub-ca.pem https://localhost:8443/health | jq .
```

Example response shape:

```json
{
  "status": "ok",
  "database": "connected",
  "datacenters": [
    {
      "cluster_id": "<UUID>",
      "freshness_status": "current",
      "last_seen": "<timestamp>"
    }
  ]
}
```

Inspect Gateway API events and conditions:

```sh
kubectl describe gateway operations-hub-consul-ops-hub-gateway -n "$HUB_NAMESPACE"
kubectl describe httproute operations-hub-consul-ops-hub-route -n "$HUB_NAMESPACE"
```

## Operational checklists

### Datacenter is not syncing

- [ ] `global_registry.enabled = true` is in the server config.
- [ ] `consul reload` exited successfully with no parse errors.
- [ ] Leader logs show registry sync starting.
- [ ] `cluster_id` matches the registered datacenter UUID.
- [ ] Token file path is correct and readable by the Consul process.
- [ ] No `CONSUL_GLOBAL_REGISTRY_TOKEN` environment variable overrides the configured source.
- [ ] Consul leader can reach the Hub gateway on port 443.
- [ ] If the gateway uses a private CA, `ca_file` points to that CA certificate.
- [ ] `tls_skip_verify` remains `false`.

### Operations Hub pod is not starting

- [ ] Neo4j is reachable at the configured `bolt://` endpoint from the Hub namespace.
- [ ] Required Neo4j, OIDC, and TLS Kubernetes Secrets exist.
- [ ] The image is pullable and there is no `ImagePullBackOff`.
- [ ] Sidecar injection is enabled in the Hub namespace.
- [ ] Consul API Gateway controller is running.

Use a Neo4j driver or `cypher-shell` to test Bolt connectivity. A `curl` probe to a `bolt://` URI is not a valid Bolt protocol check.

### Authentication or sign-in is failing

- [ ] OIDC issuer URL is reachable from the cluster.
- [ ] OIDC client redirect URI includes `https://HUB_HOST/oauth2/callback`.
- [ ] `auth.publicUrl` matches the public host exactly.
- [ ] Cookie secret is exactly 16, 24, or 32 ASCII characters.
- [ ] `cookieSecure=true` for HTTPS; only use `false` for plain-HTTP development.
- [ ] User email domain is included in `allowedEmailDomains`.
- [ ] oauth2-proxy logs show the specific rejection reason.

## Configuration and dependency verification

```sh
# Confirm reload succeeds and token file is present with restricted permissions.
consul reload
stat /etc/consul.d/registry-token.txt

# Review installed chart values.
helm get values operations-hub -n "$HUB_NAMESPACE"

# Check core dependencies and controller resources.
kubectl get gateway -n "$HUB_NAMESPACE"
kubectl get pods -n "$HUB_NAMESPACE"
consul license get
```

Expected dependencies: Neo4j reachable, Gateway has an address and ready status, oauth2-proxy and bundled Keycloak (if enabled) are running, Consul connect-inject webhook is present, and the Consul Enterprise license is valid.

## Network and TLS checks

From the Consul leader, check gateway health and outbound reachability:

```sh
curl --cacert /etc/consul.d/hub-ca.pem https://HUB_HOST/health
nc -zv HUB_HOST 443
```

Allow outbound TCP 443 from Consul leaders to the Hub gateway, inbound TCP 443 to the gateway from leader addresses, and Neo4j TCP 7687 from the Hub pod network.

Inspect the gateway certificate and hostname:

```sh
openssl s_client -connect HUB_HOST:443 -servername HUB_HOST </dev/null 2>&1 \
  | openssl x509 -noout -subject -issuer -dates
```

The certificate SAN must include `HUB_HOST`.
