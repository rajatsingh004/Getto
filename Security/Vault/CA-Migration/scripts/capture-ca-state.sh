#!/usr/bin/env sh
# Save public CA roots and active root certificate for before/after comparison.
# Usage: CONSUL_HTTP_ADDR=https://consul.example:8501 CONSUL_HTTP_TOKEN=... ./capture-ca-state.sh before
set -eu
umask 077

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 OUTPUT_PREFIX" >&2
  exit 2
fi

: "${CONSUL_HTTP_ADDR:?Set CONSUL_HTTP_ADDR, for example https://127.0.0.1:8501}"
prefix=$1
roots_file="${prefix}-roots.json"
summary_file="${prefix}-summary.json"
active_cert_file="${prefix}-active-root.pem"

if [ -n "${CONSUL_HTTP_TOKEN:-}" ]; then
  curl --fail --silent --show-error \
    --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" \
    "${CONSUL_HTTP_ADDR%/}/v1/connect/ca/roots" > "$roots_file"
else
  curl --fail --silent --show-error \
    "${CONSUL_HTTP_ADDR%/}/v1/connect/ca/roots" > "$roots_file"
fi

jq -e '.Roots and (.Roots | length > 0)' "$roots_file" >/dev/null
jq '{ActiveRootID, Roots: [.Roots[] | {ID, Active}]}' "$roots_file" > "$summary_file"
jq -r '[.Roots[] | select(.Active == true) | .RootCert] | if length == 1 then .[0] else error("expected exactly one active root") end' \
  "$roots_file" > "$active_cert_file"
openssl x509 -in "$active_cert_file" -noout -subject -issuer -serial -dates -fingerprint -sha256

echo "Saved:"
echo "  $roots_file"
echo "  $summary_file"
echo "  $active_cert_file"
echo "These files contain public CA material and metadata; protect them according to your change-record policy."
