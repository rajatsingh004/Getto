# Migration Runbook: Vault CA to Consul CA on VMs

This procedure changes the live Connect CA provider for an initialized Consul datacenter. Plan it as a CA rotation and use the exact syntax supported by your Consul release.

## Before the change

- Confirm Consul and Vault versions, current provider, datacenter health, and the active Vault `RootPKIPath`.
- Take a Consul snapshot using your established recovery process.
- Confirm Consul API access and an ACL token authorized to read and update CA configuration. Current API documentation requires `operator:write` for CA configuration reads/writes.
- Keep Vault available until the new provider, trust overlap, and workload certificate renewal are verified.
- Do not put Consul/Vault tokens or private key material in this repository, shell history, tickets, or logs.

Set the API endpoint and token in the current shell. Use HTTPS and a trusted CA for remote API access:

```sh
export CONSUL_HTTP_ADDR="https://<CONSUL_API_HOST>:8501"
export CONSUL_HTTP_TOKEN="<CONSUL_ACL_TOKEN>"
```

Confirm that Vault is the provider:

```sh
consul connect ca get-config
```

Save public root state before the change:

```sh
CONSUL_HTTP_ADDR="$CONSUL_HTTP_ADDR" \
CONSUL_HTTP_TOKEN="$CONSUL_HTTP_TOKEN" \
  ./scripts/capture-ca-state.sh before
```

The roots endpoint returns public certificates, not CA private keys. Record the active root ID from `before-summary.json`.

## Prepare Vault for cross-signing

Changing away from Vault triggers a root change. The Vault CA integration may need permission to perform a privileged cross-sign. Use the current provider's `RootPKIPath` to adapt [vault-cross-sign-policy.hcl.example](../config/vault-cross-sign-policy.hcl.example):

```hcl
path "<ROOT_PKI_PATH>/root/sign-self-issued" {
  capabilities = ["sudo", "update"]
}
```

Keep the normal policy required by the active Vault provider. If Consul uses a Vault token, follow the supported sequence for your Consul version: stage a temporary token with the added permission, update the provider to use it, then switch providers. Revoke the temporary privilege after the cross-sign operation succeeds.

If the required permission cannot be granted, stop and plan the transition with the Consul and Vault administrators. Do not force rotation without cross-signing unless you have explicitly planned for the resulting mesh impact.

## Apply the Consul CA configuration

Review [consul-ca.json.example](../config/consul-ca.json.example) and confirm the TTLs and provider options against your Consul version. The example omits custom root certificate/private key fields so the built-in provider generates its own root. It keeps `ForceWithoutCrossSigning` false.

Apply through the Consul CLI:

```sh
consul connect ca set-config -config-file config/consul-ca.json.example
```

Or use the HTTP API:

```sh
curl --fail --silent --show-error \
  --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" \
  --header "Content-Type: application/json" \
  --request PUT \
  --data @config/consul-ca.json.example \
  "${CONSUL_HTTP_ADDR%/}/v1/connect/ca/configuration"
```

The API may return an empty body on success. A successful request means it was accepted; it does not prove all workload certificates have renewed.

Do not attempt to change the live CA provider by editing server HCL and running `consul reload`. The initialized datacenter's provider is managed through the CA configuration API or `consul connect ca set-config`.

## Monitor and verify

Watch the Consul server logs:

```sh
journalctl -u consul -f
```

Look for the provider/root rotation activity and investigate Vault, cross-signing, or CA errors before proceeding.

Verify the configured provider:

```sh
consul connect ca get-config
```

Expected provider: `consul`.

Capture and compare roots:

```sh
CONSUL_HTTP_ADDR="$CONSUL_HTTP_ADDR" \
CONSUL_HTTP_TOKEN="$CONSUL_HTTP_TOKEN" \
  ./scripts/capture-ca-state.sh after

diff -u before-summary.json after-summary.json
```

Confirm the active root ID changed and a new root is active. During cross-signing, the old root may remain in the trust set temporarily but should no longer be active. Do not remove old trust just because the active root changed; allow Consul's rotation process to distribute trust and renew certificates.

The capture script also writes an active root PEM and prints certificate subject, issuer, serial, dates, and fingerprint. Subject/issuer text alone does not prove which provider created the root; use `consul connect ca get-config` and compare root IDs/fingerprints.

Check active-root intermediate state:

```sh
jq '.Roots[] | select(.Active == true) | {ID, IntermediateCerts}' after-roots.json
```

The API can return `null` when an intermediate is not present. Interpret it for the Consul version and rotation stage.

## Verify a workload leaf certificate

Choose a registered service with a local Connect leaf certificate. The agent endpoint is local to the agent queried; run this on the relevant VM or address that agent:

```sh
curl --fail --silent --show-error \
  --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" \
  "${CONSUL_HTTP_ADDR%/}/v1/agent/connect/ca/leaf/<SERVICE_NAME>" \
  | jq -r '.CertPEM' > service-leaf.pem

openssl x509 -in service-leaf.pem -noout \
  -subject -issuer -serial -dates -fingerprint -sha256
```

Confirm the leaf is valid and its chain corresponds to the new Consul CA trust. The endpoint can return a cached certificate issued before migration. Check the response `Age` header, allow time for refresh, and query again before treating an old leaf as a failed rotation. Never print or store `.PrivateKeyPEM` from the endpoint.

## Close the change

- Confirm services remain healthy and mesh connections are established across the fleet.
- Revoke the temporary elevated Vault permission/token after cross-signing is complete.
- Keep Vault available until rotation and workload certificate renewal are confirmed.
- Clean obsolete Vault CA settings from configuration management in a separate controlled change.
- Retain before/after roots and the change record according to your security policy.

## Troubleshooting

| Symptom | Checks |
| --- | --- |
| Provider still reports `vault` | Confirm the API/CLI update succeeded, inspect Consul logs, and verify you queried the intended datacenter. HCL reload alone does not change the live provider. |
| Update fails during rotation | Check Vault reachability, provider permissions, and temporary `root/sign-self-issued` permission. |
| Old root remains listed | This can be expected during trust overlap. Check `ActiveRootID`, each root's `Active` flag, logs, and rollout state before cleanup. |
| Mesh connections fail | Check whether rotation was forced without cross-signing and whether agents/proxies received updated trust and leaves. |
| Leaf still appears old | The agent endpoint may return a cached leaf. Inspect `Age`, wait for refresh, and query again. |
| Consul API TLS verification fails | Use the appropriate trusted server CA with curl. Avoid `-k` for production validation. |

## References

- [Consul CA HTTP API](https://developer.hashicorp.com/consul/api-docs/connect/ca)
- [Use Vault as a service mesh certificate authority](https://developer.hashicorp.com/consul/docs/secure-mesh/certificate/vault)
- [Use Consul's built-in certificate authority](https://developer.hashicorp.com/consul/docs/secure-mesh/certificate/built-in)
- [Vault as Consul service mesh certification authority tutorial](https://developer.hashicorp.com/consul/tutorials/operate-consul/vault-pki-consul-connect-ca)
