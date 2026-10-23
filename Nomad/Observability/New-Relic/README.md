# Observability for HashiCorp Nomad with New Relic and Prometheus

This guide configures Nomad agents to expose Prometheus-format telemetry, Prometheus to scrape the Nomad server and clients, and Prometheus remote write to forward metrics to New Relic.

## Data flow

```text
Nomad server and client agents
  └── GET /v1/metrics?format=prometheus
          ▲
          │ Prometheus scrape
          │
      Prometheus ── remote_write over HTTPS ──► New Relic
```

## Prerequisites

- Docker, if you plan to run Nomad workloads with the Docker driver. Prometheus itself can also run as a native service.
- Nomad installed and running. See [Install Nomad](https://developer.hashicorp.com/nomad/install).
- Prometheus installed on a host that can reach each Nomad agent's HTTP API on TCP 4646. Download a supported release from [Prometheus downloads](https://prometheus.io/download/).
- A New Relic **Ingest - License** key and the correct remote-write endpoint for your New Relic region.
- For Nomad Enterprise, a valid license file installed on every Nomad server. Never commit the license file.

## 1. Configure Nomad servers

Use a distinct private address for each server. Do not expose Nomad's HTTP, RPC, or Serf ports to the public internet; restrict them to the required cluster and monitoring networks. These examples are templates. For a production cluster, use a quorum of three or five servers; `bootstrap_expect = 1` is suitable only for a single-server lab.

See [`nomad-server.hcl`](nomad-server.hcl). For Nomad Enterprise, provide `server.license_path` with the path to the license on the server:

```hcl
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
  # Enterprise only; ensure the file exists on every server:
  license_path     = "/opt/license.hclic"
}

ui {
  enabled = true
}

telemetry {
  prometheus_metrics         = true
  publish_allocation_metrics = true
  publish_node_metrics       = true
}
```

For Nomad Community Edition, remove the `license_path` line. Install/start Nomad with your service manager, for example:

```sh
sudo systemctl enable nomad
sudo systemctl start nomad
```

Verify Prometheus-format metrics locally:

```sh
curl --fail --silent --show-error \
  "http://127.0.0.1:4646/v1/metrics?format=prometheus" | head
```

## 2. Configure Nomad clients

See [`nomad-client.hcl`](nomad-client.hcl). Set `bind_addr` to the client's private interface and list the server RPC address on port 4647:

```hcl
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
```

Start the client service:

```sh
sudo systemctl enable nomad
sudo systemctl start nomad
```

Test the metrics endpoint on each client as well. Allocation and node metrics can increase metric volume and label cardinality; enable only the families you need, and review metadata labels before sending them externally.

## 3. Configure Prometheus remote write in New Relic

In New Relic, open the Prometheus Remote Write integration setup, create or select a data source, and copy the appropriate endpoint and an **Ingest - License** key. New Relic's US endpoint is used in the sample file. For EU or JP accounts, use the region-specific endpoint from the New Relic documentation.

Place the license key in a protected file on the Prometheus host, for example `/etc/prometheus/secrets/newrelic-license-key`, readable only by the Prometheus service account. Do not put the key in Git, a URL, or a shell history.

## 4. Configure Prometheus

Edit [`prometheus.yml`](prometheus.yml) and replace the private IP placeholders and `prometheus_server` label. The config scrapes both the server and client endpoints every 15 seconds and sends metrics to New Relic over HTTPS using a credentials file.

Install Prometheus as a service in production so it restarts after reboot. To run it in the foreground for a quick check:

```sh
prometheus --config.file=/etc/prometheus/prometheus.yml
```

If the Prometheus and license files are elsewhere, update the paths. Avoid exposing the Prometheus UI publicly; bind it to localhost or protect it behind an authenticated internal proxy/firewall.

## 5. Verify data flow

### Verify Prometheus targets

Open the Prometheus UI from an authorized network at `http://<PROMETHEUS_HOST>:9090`, then check **Status → Target health**. Every configured Nomad target should be `UP`.

You can also query the targets endpoint:

```sh
curl --fail --silent --show-error \
  http://127.0.0.1:9090/api/v1/targets | jq .
```

If a target is down, check that the target's HTTP API is reachable from the Prometheus host, the Nomad agent binds to the intended private address, and the metrics path includes `format=prometheus`.

### Verify New Relic

Check Prometheus logs for remote-write errors, then use New Relic Metrics Explorer or the Prometheus remote-write dashboard. Ingestion can take several minutes after scraping begins. Confirm that the `prometheus_server` label matches the data source name you configured.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Prometheus target is `DOWN` | Network/firewall access to TCP 4646, Nomad `bind_addr`, target IP/port, and Nomad service health. |
| Response is JSON instead of Prometheus text | Request `/v1/metrics?format=prometheus`; enable `telemetry.prometheus_metrics = true`. |
| Nomad returns connection refused | Confirm the agent is running and its HTTP listener is reachable at the target address. |
| New Relic remote write returns 401/403 | Use an Ingest - License key, check the credentials file and Prometheus service permissions, and verify the regional URL. |
| Remote write has no visible metrics yet | Check Prometheus logs and target health, then allow several minutes for ingestion and query the configured `prometheus_server` name. |
| Missing client allocation/node metrics | Enable the corresponding `publish_allocation_metrics` and/or `publish_node_metrics` settings on clients. |

## References

- [Nomad telemetry configuration](https://developer.hashicorp.com/nomad/docs/configuration/telemetry)
- [Nomad metrics HTTP API](https://developer.hashicorp.com/nomad/api-docs/metrics)
- [Monitor Nomad](https://developer.hashicorp.com/nomad/docs/monitor)
- [Set up Prometheus remote write in New Relic](https://docs.newrelic.com/docs/infrastructure/prometheus-integrations/install-configure-remote-write/set-your-prometheus-remote-write-integration/)
- [Prometheus configuration reference](https://prometheus.io/docs/prometheus/latest/configuration/configuration/)
