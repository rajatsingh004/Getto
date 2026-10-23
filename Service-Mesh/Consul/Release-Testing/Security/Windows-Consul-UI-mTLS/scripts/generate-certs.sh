#!/usr/bin/env sh
# Generate a lab CA, Consul server cert, UI client cert, and Windows PFX.
# Usage: ./generate-certs.sh SERVER_IP UI_DNS_NAME DATACENTER [OUTPUT_DIR]
set -eu
umask 077

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 SERVER_IP UI_DNS_NAME DATACENTER [OUTPUT_DIR]" >&2
  exit 2
fi

server_ip=$1
ui_dns=$2
datacenter=$3
out_dir=${4:-./generated}

if [ -e "$out_dir" ] && [ -n "$(find "$out_dir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  echo "Output directory is not empty: $out_dir" >&2
  exit 1
fi

mkdir -p "$out_dir"
chmod 700 "$out_dir"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../certs" && pwd)
server_ext="$out_dir/server-cert.ext"
client_ext="$out_dir/client-cert.ext"

sed \
  -e "s|<SERVER_PRIVATE_IP>|$server_ip|g" \
  -e "s|<DATACENTER>|$datacenter|g" \
  -e "s|<CONSUL_UI_HOSTNAME>|$ui_dns|g" \
  "$script_dir/server-cert.ext.example" > "$server_ext"
cp "$script_dir/client-cert.ext.example" "$client_ext"

openssl genrsa -out "$out_dir/consul-agent-ca-key.pem" 4096
openssl req -x509 -new -nodes \
  -key "$out_dir/consul-agent-ca-key.pem" \
  -sha256 -days 3650 \
  -out "$out_dir/consul-agent-ca.pem" \
  -subj "/CN=Consul Lab CA"

openssl genrsa -out "$out_dir/consul-server-key.pem" 2048
openssl req -new \
  -key "$out_dir/consul-server-key.pem" \
  -out "$out_dir/consul-server.csr" \
  -subj "/CN=consul-server-1"
openssl x509 -req \
  -in "$out_dir/consul-server.csr" \
  -CA "$out_dir/consul-agent-ca.pem" \
  -CAkey "$out_dir/consul-agent-ca-key.pem" \
  -CAcreateserial \
  -out "$out_dir/consul-server.pem" \
  -days 825 -sha256 \
  -extfile "$server_ext"

openssl genrsa -out "$out_dir/consul-ui-user-key.pem" 2048
openssl req -new \
  -key "$out_dir/consul-ui-user-key.pem" \
  -out "$out_dir/consul-ui-user.csr" \
  -subj "/CN=consul-ui-user"
openssl x509 -req \
  -in "$out_dir/consul-ui-user.csr" \
  -CA "$out_dir/consul-agent-ca.pem" \
  -CAkey "$out_dir/consul-agent-ca-key.pem" \
  -CAcreateserial \
  -out "$out_dir/consul-ui-user.pem" \
  -days 825 -sha256 \
  -extfile "$client_ext"

openssl pkcs12 -export \
  -out "$out_dir/consul-ui-user.pfx" \
  -inkey "$out_dir/consul-ui-user-key.pem" \
  -in "$out_dir/consul-ui-user.pem" \
  -certfile "$out_dir/consul-agent-ca.pem" \
  -name "Consul UI User"

chmod 600 "$out_dir"/*-key.pem "$out_dir/consul-agent-ca-key.pem" "$out_dir/consul-ui-user.pfx"
chmod 644 "$out_dir/consul-agent-ca.pem" "$out_dir/consul-server.pem" "$out_dir/consul-ui-user.pem"

echo "Generated lab certificates in $out_dir"
echo "Protect $out_dir/consul-agent-ca-key.pem; do not transfer it to Windows."
echo "Transfer only the CA certificate and password-protected client PFX securely."
