# Consul service mesh 2.1.0-rc2 with Kubernetes operators: CloudNativePG test

## 1. Summary

**Question:** Can Consul service mesh 2.1.0 run operator-managed workloads (CNPG, RabbitMQ Cluster Operator, Keycloak Operator) with namespace-level injection, similar to `istio-injection: enabled`?

**Answer for CloudNativePG (the only operator tested): yes, with per-operator configuration.** CNPG ran healthy inside the mesh, and mTLS and intentions were enforced. It did not work with the namespace label alone. Four issues needed workarounds, described in section 4.

| Area | Result |
|---|---|
| Namespace-level injection of operator-created pods | Works (label only, no pod annotations) |
| CNPG cluster healthy in the mesh | Works, after workarounds |
| Registration in Consul catalog and health | Works |
| Service-to-service mTLS and intentions (allow/deny) | Works |
| "Label the namespace and it just works" | **No**: each operator needs its own annotations and exclusions |
| ServiceAccount name must match Consul service name (ACLs on) | **Still applies** in 2.1.0-rc2 |
| RabbitMQ Cluster Operator, Keycloak Operator | **Not tested** |

Consul K8s 2.1.0 is currently at **release candidate 2** (`2.1.0-rc2`). The latest GA release at the time of testing was 2.0.4.

## 2. Test environment

| Component | Version / setting |
|---|---|
| Kubernetes | kind cluster `consul-operator-test`, single control-plane node |
| Consul | Helm chart `hashicorp/consul` 2.1.0-rc2 (app 2.1.0-rc2), 1 server |
| Consul security | TLS enabled, ACLs enabled (`manageSystemACLs: true`) |
| Mesh mode | Transparent proxy on by default |
| Injection | `connectInject.default: true`, restricted by `namespaceSelector` (label `consul-inject=true`) |
| Operator | CloudNativePG 1.30.1 (Helm chart `cnpg/cloudnative-pg` 0.29.1), installed in the unmeshed namespace `cnpg-system` |
| Database | PostgreSQL 18, 1 instance, in namespace `db` |

### Consul Helm values

```yaml
global:
  name: consul
  datacenter: dc1
  tls:
    enabled: true
  acls:
    manageSystemACLs: true
server:
  replicas: 1
  bootstrapExpect: 1
connectInject:
  enabled: true
  default: true
  namespaceSelector: |
    matchLabels:
      consul-inject: "true"
  transparentProxy:
    defaultEnabled: true
```

### Setup steps

```bash
kind create cluster --name consul-operator-test

helm repo add hashicorp https://helm.releases.hashicorp.com
helm install consul hashicorp/consul --version 2.1.0-rc2 --devel \
  -n consul --create-namespace -f consul-values.yaml --wait

helm repo add cnpg https://cloudnative-pg.github.io/charts
helm install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace --wait

kubectl create namespace db
kubectl label namespace db consul-inject=true
```

Note: the Consul control plane with ACLs and TLS needs about 2 GB of free memory for the Docker host. On a memory-constrained host the install timed out and the API connection dropped until other workloads were removed.

## 3. Baseline: what the namespace label alone does

After labelling `db` and applying a plain CNPG `Cluster` with no Consul annotations:

- The Consul injector mutated the operator-created pods automatically (adding the `consul-connect-inject-init` init container and the `consul-dataplane` sidecar).
- The CNPG cluster **did not become healthy**. See section 4.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg
  namespace: db
spec:
  instances: 1
  storage:
    size: 1Gi
```

## 4. Issues found and workarounds

| # | Symptom | Cause | Workaround |
|---|---|---|---|
| 1 | The CNPG `initdb` job pod hung in `Init`, and the cluster was reported "unrecoverable" | The injector also mutates the operator's bootstrap job pod. No Kubernetes Service selects that pod, and Consul only registers pods that a Service selects, so the init container times out | Exclude CNPG job pods from injection. In the test I added a `cnpg.io/jobRole DoesNotExist` expression to the injector webhook's `objectSelector`. This is a manual change to a Helm-managed object, so a Helm upgrade would revert it. Annotating only the job pods was not tested. |
| 2 | Pod creation denied: `multi-port Consul service registration is disabled; set "consul.hashicorp.com/connect-service-port" to exactly one application port` | The PostgreSQL pod exposes several ports, and multi-port registration is disabled by default from 2.0.4 (GH-5625) | `consul.hashicorp.com/connect-service-port: "5432"` |
| 3 | Sidecar init failed: `service account name pg doesn't match Consul service name pg-r` | CNPG uses one ServiceAccount (`pg`) but creates three Services (`pg-r`, `pg-rw`, `pg-ro`). With ACLs on, the ServiceAccount name must equal the Consul service name | `consul.hashicorp.com/connect-service: "pg"` |
| 4 | The operator logged `x509: certificate signed by unknown authority` calling port 8000 on the instance, and the startup probe failed | The operator is outside the mesh and calls the CNPG instance manager (port 8000) over its own TLS. The Consul proxy intercepted that traffic and rewrote the probes | `consul.hashicorp.com/transparent-proxy-exclude-inbound-ports: "8000"` and `consul.hashicorp.com/transparent-proxy-overwrite-probes: "false"`. Both were applied together, so it is not known whether each is needed individually. |

Workarounds 2 to 4 were applied through the CNPG `Cluster` resource:

```yaml
spec:
  inheritedMetadata:
    annotations:
      consul.hashicorp.com/connect-service-port: "5432"
      consul.hashicorp.com/connect-service: "pg"
      consul.hashicorp.com/transparent-proxy-exclude-inbound-ports: "8000"
      consul.hashicorp.com/transparent-proxy-overwrite-probes: "false"
```

## 5. Final results

### CNPG state
After the workarounds, the cluster reached `Cluster in healthy state`, with `pg-1` at 2/2 containers ready.

### Consul registration
The catalog contained `pg` and `pg-sidecar-proxy`. The `pg` service health was `passing`.

### Mesh connectivity (mTLS and intentions)

A meshed client pod (its own ServiceAccount `client`, a Kubernetes Service selecting it, and the annotation `consul.hashicorp.com/connect-service-upstreams: "pg:15432"`) connected to Postgres through its Consul upstream:

| Test | Result |
|---|---|
| Meshed client to `127.0.0.1:15432` (upstream `pg`), intention `client` to `pg` = **allow** | Connected and queried successfully |
| Same, intention changed to **deny** | Connection refused by the proxy |
| Same, intention changed back to **allow** | Connected again |
| Non-mesh pod connecting directly to the Postgres pod IP on 5432 | Rejected |

Intention used:

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceIntentions
metadata:
  name: pg
  namespace: db
spec:
  destination:
    name: pg
  sources:
  - name: client
    action: allow
```

### Observations about client access
- A client pod must be selected by a Kubernetes Service, or it is never registered in Consul and its init container waits until it times out.
- A client pod needs its own ServiceAccount (not `default`), because the default ACL binding rule `serviceaccount.name!=default` blocks the `default` account from logging in.
- Connecting to the CNPG ClusterIP Service (`pg-rw.db.svc:5432`) failed even from a meshed client. Connecting through an explicit Consul upstream worked. Consul's virtual DNS name was not tested.

## 6. Answer to the ServiceAccount question

The earlier question was whether newer Consul removes the requirement for a ServiceAccount per service. In 2.1.0-rc2 it does not:

- With ACLs enabled, the ACL binding rule maps `${serviceaccount.name}` to the Consul service name.
- This was hit directly with CNPG (issue 3 above). It was resolved by setting the Consul service name to match the operator's single ServiceAccount.
- The 2.1.0-rc1 and rc2 changelogs contain no change to this rule. The new options `global.acls.authMethod.create` and `global.acls.authMethod.name` only control how the auth method is created.

For operators that run all their pods under one ServiceAccount, use `consul.hashicorp.com/connect-service` to align the names. This is only possible where the operator lets you set pod annotations.

## 7. Limits of this test

- **Operators tested:** CloudNativePG only. RabbitMQ Cluster Operator and Keycloak Operator were **not** tested, and each will need its own investigation (ports, ServiceAccounts, job or init pods, operator-to-pod traffic).
- **Scope:** one PostgreSQL instance. Replicas, failover, backup/restore, and operator upgrades were not tested.
- **Release status:** 2.1.0 is at rc2, not GA. Behaviour may change before release.
- **Environment:** single-node kind cluster with a single Consul server, not a production topology.
- **Workaround 1** modifies a Helm-managed webhook and needs a durable alternative before production use.

## 8. Recommendations

1. Treat Consul and operators as supported **per operator, with a validated configuration profile**, not as a blanket "label the namespace" capability.
2. Run the same test for RabbitMQ and Keycloak before committing to a migration.
3. Plan one Consul service name per operator-managed service, and use `consul.hashicorp.com/connect-service` where the ServiceAccount cannot be changed.
4. Decide how to exclude operator job and init pods from injection in a way that survives Helm upgrades.
5. If namespace-level injection without ServiceAccount constraints is a hard requirement, raise it as a feature request on `hashicorp/consul-k8s`.
