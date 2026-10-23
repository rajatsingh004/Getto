# Example Nomad client config. Use private addresses and restrict network access.
data_dir  = "/opt/nomad"
bind_addr = "<CLIENT_PRIVATE_IP>"

client {
  enabled = true
  servers = ["<SERVER_PRIVATE_IP>:4647"]
}

telemetry {
  prometheus_metrics         = true
  publish_allocation_metrics = true
  publish_node_metrics       = true
}
