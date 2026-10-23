# Set Up Certificate-Based Access to the Consul UI on Windows

This guide configures HTTPS mutual TLS (mTLS) for the Consul UI and verifies access from a Windows browser using a client certificate. The examples use a small, single-server lab; adapt the topology and certificate names for your environment.

> **Security:** Protect the CA private key and Consul server private key. Never copy the CA private key to Windows. Transfer only the CA certificate and the client PFX through a secure channel. Bind the Consul API to a private interface and restrict port 8501 with firewall rules.

## What this configures

- HTTPS access to Consul on port 8501.
- A server certificate trusted by a private CA, with names matching both the Consul RPC identity and the URL used by the browser.
- Client-certificate verification for HTTPS UI access.
- A Windows browser importing the CA certificate and a client PFX.

A client certificate proves identity at the TLS layer. It does not replace Consul ACL authorization. If ACLs are enabled, use an authorized ACL token or the configured UI login flow as well.

## Prerequisites

- A Consul server and administrative access to its host.
- OpenSSL, curl, and jq on the Consul host.
- Windows administrator access to install the CA certificate in the Local Computer trust store.
- A private DNS name or stable IP address for the Consul UI.
- A maintenance plan if enabling incoming TLS verification for other Consul agents in a multi-agent datacenter.

Replace all placeholders such as <SERVER_PRIVATE_IP>, <CONSUL_UI_HOSTNAME>, and <DATACENTER> before running commands.

## 1. Create a private CA and certificates

Run on a secure host. Keep the CA private key offline or tightly restricted. The examples create files under /opt/consul/tls.

```sh
sudo install -d -m 700 /opt/consul/tls
cd /opt/consul/tls
sudo openssl genrsa -out consul-agent-ca-key.pem 4096
sudo chmod 600 consul-agent-ca-key.pem
sudo openssl req -x509 -new -nodes \
  -key consul-agent-ca-key.pem \
  -sha256 -days 3650 \
  -out consul-agent-ca.pem \
  -subj "/CN=Consul Lab CA"
sudo chmod 644 consul-agent-ca.pem
```

Create the Consul server key and CSR:

```sh
sudo openssl genrsa -out consul-server-key.pem 2048
sudo chmod 600 consul-server-key.pem
sudo openssl req -new \
  -key consul-server-key.pem \
  -out consul-server.csr \
  -subj "/CN=consul-server-1"
```

Create an extensions file. Consul's default server identity is server.<datacenter>.<domain> (commonly server.dc1.consul). Include it when verify_server_hostname is enabled. Include every DNS name or IP address users and agents actually use to reach this server.

```sh
cat > consul-server.ext <<'EOF'
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=IP:<SERVER_PRIVATE_IP>,DNS:consul-server-1,DNS:server.<DATACENTER>.consul,DNS:<CONSUL_UI_HOSTNAME>
EOF
```

Issue the server certificate:

```sh
sudo openssl x509 -req \
  -in consul-server.csr \
  -CA consul-agent-ca.pem \
  -CAkey consul-agent-ca-key.pem \
  -CAcreateserial \
  -out consul-server.pem \
  -days 825 -sha256 \
  -extfile consul-server.ext
sudo chmod 644 consul-server.pem
```

Create a client certificate for the Windows user:

```sh
sudo openssl genrsa -out consul-ui-user-key.pem 2048
sudo chmod 600 consul-ui-user-key.pem
sudo openssl req -new \
  -key consul-ui-user-key.pem \
  -out consul-ui-user.csr \
  -subj "/CN=consul-ui-user"
cat > consul-client.ext <<'EOF'
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
EOF
sudo openssl x509 -req \
  -in consul-ui-user.csr \
  -CA consul-agent-ca.pem \
  -CAkey consul-agent-ca-key.pem \
  -CAcreateserial \
  -out consul-ui-user.pem \
  -days 825 -sha256 \
  -extfile consul-client.ext
```

Export a password-protected PFX for Windows:

```sh
sudo openssl pkcs12 -export \
  -out consul-ui-user.pfx \
  -inkey consul-ui-user-key.pem \
  -in consul-ui-user.pem \
  -certfile consul-agent-ca.pem \
  -name "Consul UI User"
sudo chmod 600 consul-ui-user.pfx
```

Use a strong export password and deliver it separately from the PFX.

## 2. Configure the Consul server

Install the server certificate, key, and CA certificate in a root-readable directory on the Consul server. Update the Consul server configuration (for example, /etc/consul.d/consul.hcl):

```hcl
datacenter = "<DATACENTER>"
data_dir   = "/opt/consul"
bind_addr  = "<SERVER_PRIVATE_IP>"
client_addr = "<SERVER_PRIVATE_IP>"

server = true
bootstrap_expect = 1

ui_config {
  enabled = true
}

ports {
  http  = -1
  https = 8501
}

tls {
  defaults {
    ca_file                = "/opt/consul/tls/consul-agent-ca.pem"
    cert_file              = "/opt/consul/tls/consul-server.pem"
    key_file               = "/opt/consul/tls/consul-server-key.pem"
    verify_incoming        = true
    verify_outgoing        = true
    verify_server_hostname = true
  }

  https {
    verify_incoming = true
  }
}
```

This is a single-server lab configuration. In a multi-agent datacenter, tls.defaults.verify_incoming = true requires Consul clients and servers making incoming RPC connections to present trusted certificates. Configure and roll out certificates for all agents before enforcing it, or follow the Consul TLS migration guidance to avoid disrupting cluster communication. Keep the HTTP listener disabled and restrict HTTPS access to trusted networks.

Set ownership and restart Consul:

```sh
sudo chown -R consul:consul /opt/consul/tls
sudo chmod 600 /opt/consul/tls/consul-server-key.pem
sudo systemctl restart consul
sudo systemctl status consul --no-pager
```

## 3. Transfer certificate files to Windows

Securely transfer these public/client files to the Windows user:

- consul-agent-ca.pem — CA certificate (public).
- consul-ui-user.pfx — client certificate and private key, password-protected.

Do **not** transfer consul-agent-ca-key.pem or the Consul server private key.

## 4. Import certificates on Windows

1. Open certlm.msc (Certificates — Local Computer).
2. Import consul-agent-ca.pem into **Trusted Root Certification Authorities > Certificates**.
3. Open certmgr.msc (Certificates — Current User).
4. Import consul-ui-user.pfx into **Personal > Certificates**, entering the export password.
5. Close and reopen the browser so it reloads the certificate stores.

Use the DNS hostname in the browser URL if that hostname is in the server certificate SAN. If connecting by IP, that exact IP must appear as an IP SAN.

## 5. Verify HTTPS and client certificate access

From a machine with the files available, test the TLS endpoint without disabling certificate verification:

```sh
curl --cacert consul-agent-ca.pem \
  --cert consul-ui-user.pem \
  --key consul-ui-user-key.pem \
  https://<CONSUL_UI_HOSTNAME>:8501/v1/status/leader
```

A leader address confirms the HTTPS request reached Consul. It does not confirm ACL authorization for all UI features.

You can also inspect the handshake:

```sh
openssl s_client \
  -connect <CONSUL_UI_HOSTNAME>:8501 \
  -servername <CONSUL_UI_HOSTNAME> \
  -CAfile consul-agent-ca.pem \
  -cert consul-ui-user.pem \
  -key consul-ui-user-key.pem
```

Then browse to:

```text
https://<CONSUL_UI_HOSTNAME>:8501/ui/
```

When prompted, select the Consul UI User client certificate. If ACLs are enabled, authenticate in the UI using the appropriate Consul ACL token or configured login method.

## Troubleshooting

| Symptom | Likely cause | Check |
| --- | --- | --- |
| Browser reports a name or certificate error | URL host is absent from the server certificate SAN, or the CA is not trusted | Use a matching DNS name/IP SAN; confirm the CA is in Local Computer Trusted Root |
| TLS handshake fails with client-certificate alert | Client PFX is missing, expired, or not signed by the trusted CA | Reimport the PFX and check the client cert chain and validity |
| Browser does not prompt for a certificate | Certificate is not in the current user's Personal store, or the connection is reusing a prior TLS session | Confirm the PFX import, close all browser processes, and retry |
| curl returns HTTP 403 | TLS succeeded, but ACL policy/token does not authorize the request | Check ACL configuration and use a valid token where required |
| Consul fails to start or agents lose connectivity | Incoming verification was enabled before all agents had certificates | Review Consul logs and complete the TLS rollout on all agents before enforcing verification |
| Connection is refused | HTTPS listener is disabled, Consul is not listening on the address, or network filtering blocks port 8501 | Check ports.https, service status, listening sockets, and firewall rules |

## References

- [Consul TLS with OpenSSL](https://developer.hashicorp.com/consul/docs/secure/encryption/tls/enable/new/openssl)
- [Consul mutual TLS encryption](https://developer.hashicorp.com/consul/docs/secure/encryption/tls/mtls)
- [Consul security model](https://developer.hashicorp.com/consul/docs/secure/security-model/core)
