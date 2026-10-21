# Configure on each Consul Enterprise server agent in the registered datacenter.
# Replace placeholders with the Operations Hub hostname, cluster UUID, and token file.
global_registry {
  enabled              = true
  address              = "https://HUB_HOST"
  cluster_id           = "CLUSTER_UUID"
  token_file           = "/etc/consul.d/registry-token.txt"
  ca_file              = "/etc/consul.d/hub-ca.pem" # Optional when system CA trust is sufficient.
  tls_skip_verify      = false
  snapshot_interval    = 600000000000 # 10 minutes in nanoseconds.
  delta_flush_interval = 120000000000 # 2 minutes in nanoseconds.
}
