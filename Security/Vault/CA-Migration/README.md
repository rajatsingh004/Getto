# Migrate Consul Connect CA Provider from Vault to Consul CA on VMs

**How-to guide**

This procedure migrates an existing Consul service-mesh datacenter from the Vault CA provider to Consul's built-in CA provider. It updates the live CA configuration, rotates the root with cross-signing, and checks that the new provider and certificates are active.

## Before you begin

Plan this as a CA rotation. Confirm the exact Consul version and CLI syntax, take a Consul snapshot using your normal recovery procedure, and schedule an operational window. Ensure the cluster is healthy, the Consul HTTP API is reachable, and `curl`, `jq`, `openssl`, and the Consul CLI are available. Use a Consul ACL token authorized to read CA state and update the CA configuration.

The live CA provider for an initialized datacenter is managed through the CA configuration API or `consul connect ca set-config`. Editing `connect.ca_provider` in server HCL and running `consul reload` does not perform this migration. Keep Vault available until the provider switch and validations are complete.

### Vault permission needed for a cross-signed rotation

Changing away from Vault triggers a root change that requires Vault to perform a privileged root cross-sign operation. Before switching providers, temporarily grant the Vault token or auth method used by the active Vault CA provider the additional permission below, using the current `RootPKIPath`:

```hcl
path "<root_pki_path>/root/sign-self-issued" {
  capabilities = ["sudo", "update"]
}
```

Keep the normal policy required by the active Vault provider as well. If Consul is configured with a Vault token, follow HashiCorp's recommended sequence: stage a temporary token with the extra permission, update the Vault provider to use it, then switch the provider. Revoke the temporary privilege after the cross-sign operation succeeds. If this permission cannot be granted, stop and plan the transition with your Vault/Consul administrators; forcing rotation without cross-signing can cause temporary mesh connection failures.

## 1. Confirm the current provider

```sh
consul connect ca get-config
```

Confirm the provider is `vault`. Record the configured Vault `RootPKIPath` for the temporary policy. Consul filters sensitive settings such as Vault tokens when it displays the configuration; do not expect the token to be returned.

For API calls, set the local Consul API address and an ACL token in your shell. Do not put a real token in this file or paste it into logs or tickets.

```sh
export CONSUL_HTTP_ADDR="http://127.0.0.1:8500"
export CONSUL_HTTP_TOKEN="<CONSUL_ACL_TOKEN>"
```

The CA configuration read/update endpoints require Consul ACL `operator:write` in current API documentation. Use HTTPS and a trusted CA when the API is not local.

## 2. Save the current trusted roots

Capture the roots before the change. The roots endpoint returns public certificates and does not include CA private keys.

```sh
curl --fail --silent --show-error \
  --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" \
  "${CONSUL_HTTP_ADDR}/v1/connect/ca/roots" \
  | jq . > connect-ca-roots-before.json

jq '{ActiveRootID, Roots: [.Roots[] | {ID, Active}]}' \
  connect-ca-roots-before.json
```

Keep the snapshot for comparison. Record the existing `ActiveRootID` and root IDs.

## 3. Prepare the Consul CA provider configuration

Create `consul-ca.json`:

```json
{
  "Provider": "consul",
  "Config": {
    "IntermediateCertTTL": "8760h",
    "LeafCertTTL": "72h"
  },
  "ForceWithoutCrossSigning": false
}
```

The built-in provider generates a root automatically when no custom `RootCert` and `PrivateKey` are provided. This example retains the existing intermediate and leaf TTLs. `ForceWithoutCrossSigning` remains `false` so Consul attempts the normal cross-signed rotation. Check provider options against the documentation for the Consul version you run; do not add undocumented fields such as `RootCertTTL` without confirming that version supports them.

## 4. Apply the provider change

Apply the change to the live datacenter using the Consul CLI:

```sh
consul connect ca set-config -config-file consul-ca.json
```

Or use the HTTP API:

```sh
curl --fail --silent --show-error \
  --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" \
  --header "Content-Type: application/json" \
  --request PUT \
  --data @consul-ca.json \
  "${CONSUL_HTTP_ADDR}/v1/connect/ca/configuration"
```

The API may return an empty body on success. `curl --fail` exits nonzero for HTTP errors; check the command's exit code immediately. A successful API response means the request was accepted, not that all workload certificates have already renewed.

Do not use `curl -k` for production validation. It disables TLS certificate verification. If your API endpoint uses TLS, point curl at the appropriate trusted CA instead.

## 5. Watch Consul logs for rotation

On VM installations using systemd:

```sh
journalctl -u consul -f
```

Confirm the logs show the CA provider change/root rotation and contain no Vault, cross-signing, or CA errors. If the operation fails, stop and investigate before removing Vault access or configuration.

## 6. Verify the active provider

```sh
consul connect ca get-config
```

Expected provider:

```text
Provider: consul
```

The API equivalent is:

```sh
curl --fail --silent --show-error \
  --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" \
  "${CONSUL_HTTP_ADDR}/v1/connect/ca/configuration" | jq .
```

## 7. Verify root rotation and overlap

```sh
curl --fail --silent --show-error \
  --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" \
  "${CONSUL_HTTP_ADDR}/v1/connect/ca/roots" \
  | tee connect-ca-roots-after.json \
  | jq '{ActiveRootID, Roots: [.Roots[] | {ID, Active}]}'
```

Compare with `connect-ca-roots-before.json`. Confirm that the active root ID changed and a new root is active. With cross-signing, the old root may remain in the trust set during the overlap period; it should no longer be active. Do not remove old trust just because the new root is active—allow Consul's root-rotation process to distribute trust and renew certificates.

## 8. Inspect the new root certificate

Extract the active public root certificate and inspect it:

```sh
curl --fail --silent --show-error \
  --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" \
  "${CONSUL_HTTP_ADDR}/v1/connect/ca/roots" \
  | jq -r '.Roots[] | select(.Active == true) | .RootCert' \
  > consul-active-root.pem

openssl x509 -in consul-active-root.pem -noout \
  -subject -issuer -serial -dates -fingerprint -sha256
```

Certificate subject/issuer text is useful for inspection but does not by itself prove which provider created the root. Confirm the provider using `consul connect ca get-config`, and compare the root ID and fingerprint with the pre-migration record.

## 9. Check active-root intermediates

```sh
curl --fail --silent --show-error \
  --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" \
  "${CONSUL_HTTP_ADDR}/v1/connect/ca/roots" \
  | jq '.Roots[] | select(.Active == true) | {ID, IntermediateCerts}'
```

Confirm the active root entry and intermediate certificate state are consistent with the Consul version and rotation stage. The API can return `null` when no intermediate certificate is present, so interpret this output using the provider's documented rotation behavior.

## 10. Verify a service leaf certificate

Choose a service that is registered and has a local Connect leaf certificate. The agent endpoint is local to the agent being queried; run this on the relevant VM or set the address to that agent.

```sh
curl --fail --silent --show-error \
  --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" \
  "${CONSUL_HTTP_ADDR}/v1/agent/connect/ca/leaf/dashboard" \
  | jq -r '.CertPEM' > dashboard-leaf.pem

openssl x509 -in dashboard-leaf.pem -noout \
  -subject -issuer -serial -dates -fingerprint -sha256
```

Confirm the leaf is valid, its issuer/chain corresponds to the new Consul CA trust, and its serial or fingerprint differs from the saved pre-migration leaf if you recorded one. The leaf endpoint is cached and may initially return a certificate issued before the migration. Check the HTTP `Age` header, wait for renewal/refresh, and query again before treating an old cached leaf as a failed rotation. Do not print or store `.PrivateKeyPEM` from this endpoint.

## 11. Clean up and close the change

- Confirm services remain healthy and mesh connections are established across the fleet.
- Remove the temporary elevated Vault permission/token after the cross-signing operation is complete.
- After validating the live configuration, clean up obsolete Vault CA settings in configuration management in a controlled change. Do not rely on HCL edits plus `consul reload` to change the live provider.
- Keep the before/after root snapshots and change record according to your security retention policy.
- Keep Vault available until you are satisfied that rotation and workload certificate renewal have completed.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Provider still reports `vault` | Confirm the CLI/API update succeeded, inspect Consul server logs, and verify you queried the intended datacenter. HCL reload alone does not update an initialized CA provider. |
| CA configuration update fails during rotation | Check the Vault token/auth method and temporary `root/sign-self-issued` permission, plus Vault reachability and current provider permissions. |
| Old root remains in the roots list | This may be expected during cross-signing and trust overlap. Check `ActiveRootID`, `Active`, server logs, and rollout state before cleanup. |
| Service connections fail after the change | Check whether the rotation was forced without cross-signing, and whether agents/proxies have received updated trust and leaf certificates. |
| Leaf still appears Vault-issued | The agent leaf endpoint may be serving a cached certificate. Inspect response `Age`, wait for refresh, then re-query; confirm its chain against the active root. |
| TLS verification fails against Consul API | Use the trusted server CA with curl; avoid `-k` except for isolated diagnostics. |

## References

- [Consul CA HTTP API](https://developer.hashicorp.com/consul/api-docs/connect/ca)
- [Use Vault as a service mesh certificate authority](https://developer.hashicorp.com/consul/docs/secure-mesh/certificate/vault)
- [Use Consul's built-in certificate authority](https://developer.hashicorp.com/consul/docs/secure-mesh/certificate/built-in)
- [Vault as Consul service mesh certification authority tutorial](https://developer.hashicorp.com/consul/tutorials/operate-consul/vault-pki-consul-connect-ca)
