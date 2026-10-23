# Migrate Consul Connect CA from Vault to Consul CA

A VM-focused runbook and reusable examples for moving an initialized Consul Connect datacenter from Vault-backed CA to Consul's built-in CA provider.

## Contents

- [Migration runbook](docs/migration-runbook.md) — prerequisites, change sequence, validation, and rollback considerations.
- [Consul CA configuration](config/consul-ca.json.example) — example provider configuration.
- [Vault cross-sign policy](config/vault-cross-sign-policy.hcl.example) — narrowly scoped temporary permission example.
- [CA state capture script](scripts/capture-ca-state.sh) — saves public root metadata and the active public root certificate before/after the change.

## Usage

1. Review the runbook and confirm the exact Consul and Vault versions and permissions in your environment.
2. Take a Consul snapshot using your normal recovery procedure and confirm the datacenter is healthy.
3. Record the current roots: `CONSUL_HTTP_ADDR=https://consul.example:8501 CONSUL_HTTP_TOKEN=<token> ./scripts/capture-ca-state.sh before`
4. Follow the runbook to grant the temporary Vault cross-sign permission, apply the provider change, and verify workload health.
5. Capture the roots again with a different prefix, compare the active root ID and rotation state, then revoke the temporary Vault permission.

## Safety

This repository contains examples only. Do not commit Consul ACL tokens, Vault tokens, private keys, generated certificates, snapshots, or production configuration. Keep Vault available until the provider transition, trust distribution, and workload certificate renewal are confirmed. The sample uses cross-signing; do not force rotation without cross-signing unless you have explicitly planned for the mesh impact.

The CA configuration change is a live datacenter operation. Validate commands and provider options against the exact Consul version before applying them.
