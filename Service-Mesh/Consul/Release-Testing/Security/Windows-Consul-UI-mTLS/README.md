# Certificate-Based Access to the Consul UI on Windows

This lab project demonstrates Consul HTTPS with mutual TLS (mTLS), using a private CA, a server certificate, and a Windows client certificate. It is structured as reusable examples rather than a copy-paste-only procedure.

## Project files

- [consul-server.hcl.example](config/consul-server.hcl.example) — single-server lab configuration.
- [server-cert.ext.example](certs/server-cert.ext.example) and [client-cert.ext.example](certs/client-cert.ext.example) — X.509 certificate extensions.
- [generate-certs.sh](scripts/generate-certs.sh) — creates a local CA, server/client keypairs and certificates, and a password-protected PFX.

## Quick start

1. Review the lab-only configuration and replace all placeholders. The sample enables incoming certificate verification for Consul RPC; in a multi-agent datacenter, stage trusted certificates on every agent before enabling it.
2. On a secure machine, run the generator with the actual private IP, UI DNS name, and datacenter name:

   ```sh
   ./scripts/generate-certs.sh 10.0.0.10 consul.example.internal dc1 ./generated
   ```

   The script prompts for the PFX export password. Keep the generated CA private key offline or tightly restricted.
3. Install the generated server files on the Consul server and merge the example configuration into the agent configuration. Restrict port 8501 to trusted clients.
4. Transfer only generated/consul-agent-ca.pem and generated/consul-ui-user.pfx to Windows through a secure channel. Import the CA into Local Computer > Trusted Root Certification Authorities and the PFX into Current User > Personal.
5. Visit https://consul.example.internal:8501/ui/ and select the client certificate if prompted. The URL hostname must match a DNS SAN on the server certificate.
6. Validate the endpoint with curl:

   ```sh
   curl --cacert generated/consul-agent-ca.pem \
     --cert generated/consul-ui-user.pem \
     --key generated/consul-ui-user-key.pem \
     https://consul.example.internal:8501/v1/status/leader
   ```

## Security and scope

This is a learning lab, not a production PKI design. Do not commit generated keys, certificates, PFX files, passwords, or production configuration. A client certificate establishes TLS identity; it does not grant Consul ACL permissions. If ACLs are enabled, authenticate with an authorized token or the configured UI login method.

The generated server SANs include Consul's default RPC server name server.<datacenter>.consul plus the supplied UI DNS name and IP. The sample uses a one-server bootstrap setting. Adapt it for a real cluster and follow the [Consul TLS rollout guidance](https://developer.hashicorp.com/consul/docs/secure/encryption/tls/mtls).

## Troubleshooting

- **Name/certificate error:** Use a hostname or IP present in the server certificate SAN and trust the CA certificate on Windows.
- **TLS client-certificate error:** Confirm the PFX is imported for the current Windows user and chains to the configured CA.
- **HTTP 403:** TLS may have succeeded; check Consul ACL authorization separately.
- **Agents lose connectivity:** Verify all required agent certificates and trust configuration before enforcing incoming verification.

## References

- [Consul TLS with OpenSSL](https://developer.hashicorp.com/consul/docs/secure/encryption/tls/enable/new/openssl)
- [Consul mutual TLS encryption](https://developer.hashicorp.com/consul/docs/secure/encryption/tls/mtls)
- [Consul security model](https://developer.hashicorp.com/consul/docs/secure/security-model/core)
