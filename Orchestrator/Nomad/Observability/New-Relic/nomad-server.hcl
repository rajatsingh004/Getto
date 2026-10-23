# Example Nomad server config. Use private addresses and restrict network access.
data_dir  = "/opt/nomad/data"
bind_addr = "<SERVER_PRIVATE_IP>"

advertise {
  http = "<SERVER_PRIVATE_IP>"
  rpc  = "<SERVER_PRIVATE_IP>"
  serf = "<SERVER_PRIVATE_IP>"
}

server {
  enabled          = true
  bootstrap_expect = 3

  # Nomad Enterprise only. Install the license on every Nomad server.
  license_path = "/opt/license.hclic"
}

ui {
  enabled = true
}

telemetry {
  prometheus_metrics         = true
  publish_allocation_metrics = true
  publish_node_metrics       = true
}
