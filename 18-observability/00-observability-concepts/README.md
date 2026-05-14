# Observability Concepts — Read This Before the Observability Labs

## Overview

This document is a **theory-only read-first guide** — there are no `kubectl` commands here. It establishes the conceptual foundation for the two hands-on labs that follow:

- **`01-logs-loki-grafana`** — Fluent Bit → Loki → Grafana (logs pipeline)
- **`02-metrics-prometheus-grafana`** — node-exporter → Prometheus → Grafana (metrics pipeline)

Reading this first means you will understand *why* every configuration decision in those labs was made, not just *what* to type.

---

## The Three Pillars of Observability

Observability is your ability to understand what is happening inside a system by examining its outputs. The three outputs that matter are:

```
┌─────────────────────────────────────────────────────────────────────┐
│                  The Three Pillars                                   │
│                                                                      │
│  LOGS          Human-readable timestamped event records             │
│                "What happened and when?"                            │
│                Examples: HTTP request, error stack trace, DB query  │
│                Tool in this repo: Fluent Bit → Loki → Grafana       │
│                                                                      │
│  METRICS       Numeric measurements over time                       │
│                "How much / how many / how fast?"                    │
│                Examples: CPU%, memory bytes, request rate, latency  │
│                Tool in this repo: node-exporter → Prometheus → Grafana│
│                                                                      │
│  TRACES        The lifecycle of a single request across services    │
│                "Which service caused the latency?"                  │
│                Examples: distributed request path, span durations   │
│                Tool: OpenTelemetry + Tempo (not covered here)       │
└─────────────────────────────────────────────────────────────────────┘
```

**The three pillars together:**
```
Alert fires → "high error rate on /checkout" (metric)
    │
    ▼ Drill into logs for that time window
"NullPointerException in PaymentService" (log)
    │
    ▼ Follow the trace for that request
"PaymentService called InventoryService which timed out" (trace)
```

Without all three, you are debugging with one hand tied behind your back. In production you start with metrics (anomaly detection), pivot to logs (root cause), and use traces to understand service-to-service propagation.

---

## Part 1 — Logs: Fluentd and Fluent Bit

### Why `kubectl logs` Is Not Enough in Production

`kubectl logs` reads the current log file for a running pod — on demand, one pod at a time. It has critical limitations in production:

```
Limitation 1: No history after pod deletion
  Pod crashes → replaced by new pod → old logs gone forever
  DaemonSet rolling update → old pod terminated → its logs gone

Limitation 2: No search across pods
  Bug hits 1 in 10 requests across 50 pods
  You would need to kubectl logs each of 50 pods manually

Limitation 3: No retention policy
  Node disk fills up → container runtime rotates log files
  Old log data is overwritten, never stored

Limitation 4: No correlation
  You cannot correlate logs from different pods or namespaces
  No way to ask: "show me all errors across my entire cluster
  from 14:30 to 14:35 yesterday"

What you need instead:
  A process on every node that reads log files continuously,
  enriches them with context, and ships them to a central store
  where they can be searched, retained, and correlated.
  → That process is Fluent Bit running as a DaemonSet.
```

### Fluentd Architecture — Internal Components

Fluentd is the original project. Understanding its architecture is foundational because Fluent Bit shares the same pipeline model.

```
┌──────────────────────────────────────────────────────────────────┐
│                    Fluentd Architecture                           │
│                                                                   │
│  ┌──────────┐                                                    │
│  │  Source  │  Where logs come from                             │
│  │  Plugins │  → tail (files), systemd (journald),             │
│  │          │    forward (from other Fluentd/Fluent Bit),       │
│  │          │    http (HTTP POST), syslog                       │
│  └────┬─────┘                                                    │
│       │  raw event: { tag, time, record }                       │
│       ▼                                                          │
│  ┌──────────┐                                                    │
│  │  Parser  │  Converts raw text → structured key-value record  │
│  │          │  → json, regexp, nginx, apache2, csv, ltsv        │
│  └────┬─────┘                                                    │
│       │  structured record: { time: ..., log: ..., host: ... }  │
│       ▼                                                          │
│  ┌──────────┐                                                    │
│  │  Filter  │  Transform, enrich, or drop records               │
│  │          │  → record_transformer (add/modify fields)         │
│  │          │  → grep (include/exclude by field value)          │
│  │          │  → kubernetes_metadata (add pod/namespace info)   │
│  └────┬─────┘                                                    │
│       │  enriched record ready for routing                       │
│       ▼                                                          │
│  ┌──────────┐                                                    │
│  │  Buffer  │  Absorbs bursts and retries on backend failure    │
│  │          │  → memory: fast, lost on crash                    │
│  │          │  → file: durable, survives crash/restart          │
│  │          │  Controls: chunk_limit_size, total_limit_size,    │
│  │          │             flush_interval, retry_max_times       │
│  └────┬─────┘                                                    │
│       │  chunks of records — flushed on interval or size        │
│       ▼                                                          │
│  ┌──────────┐                                                    │
│  │  Router  │  Routes records to output(s) by tag matching      │
│  │          │  → tag: "kube.production.*" → output: Elasticsearch│
│  │          │  → tag: "kube.debug.*"      → output: stdout      │
│  │          │  → tag: "system.*"          → output: S3          │
│  └────┬─────┘                                                    │
│       ▼                                                          │
│  ┌──────────┐                                                    │
│  │  Output  │  Where records go                                 │
│  │  Plugins │  → elasticsearch, loki, s3, kafka, stdout,       │
│  │          │    cloudwatch_logs, bigquery, datadog, splunk     │
│  └──────────┘                                                    │
└──────────────────────────────────────────────────────────────────┘
```

**The Tag system — how routing works:**

Every record in Fluentd/Fluent Bit carries a tag. Tags are dot-separated strings that encode the record's origin. The router matches tags to outputs:

```
Input reads: /var/log/containers/nginx-abc_production_nginx-sha.log
             ↓
Tag assigned: kube.production.nginx-abc.nginx

Router rules:
  Match kube.production.**  → Output: Elasticsearch (prod cluster)
  Match kube.staging.**     → Output: Loki (cheaper storage)
  Match system.**           → Output: S3 (cold archive)
  Match **                  → Output: stdout (catch-all for debugging)
```

Tags are how you implement multi-destination routing, environment separation, and log tiering — all from a single Fluentd process.

### Fluent Bit Architecture — How It Differs

Fluent Bit uses the same conceptual pipeline but is implemented entirely in C with a much smaller footprint:

```
┌──────────────────────────────────────────────────────────────────┐
│                   Fluent Bit Pipeline                             │
│                                                                   │
│  ┌─────────┐    ┌─────────┐    ┌──────────┐    ┌────────────┐  │
│  │  INPUT  │───▶│ PARSER  │───▶│  FILTER  │───▶│   OUTPUT   │  │
│  └─────────┘    └─────────┘    └──────────┘    └────────────┘  │
│                                                                   │
│  Differences from Fluentd:                                       │
│  • No separate Router stage — routing is done via Match pattern  │
│    in each Filter and Output section                             │
│  • Buffer is built into the OUTPUT section, not a separate stage │
│  • Configuration is INI-style sections, not Ruby DSL             │
│  • Memory buffer only by default (file buffer available)         │
│  • Plugin ecosystem is smaller but covers all production cases   │
│                                                                   │
│  Shared with Fluentd:                                            │
│  • Same tag system (kube.*, system.*, etc.)                      │
│  • Same pipeline concepts (source → parse → filter → output)    │
│  • Compatible forward protocol (Fluent Bit can feed Fluentd)     │
└──────────────────────────────────────────────────────────────────┘
```

### Fluentd vs Fluent Bit — Complete Comparison

| Dimension | Fluentd | Fluent Bit |
|-----------|---------|-----------|
| **Language** | Ruby + C extensions | Pure C |
| **Binary size** | ~40 MB | ~450 KB |
| **Memory at rest** | ~40 MB | ~1 MB |
| **CPU overhead** | Moderate — Ruby GIL limits parallelism | Minimal — C, no GIL |
| **Plugin count** | 1,000+ | ~100 |
| **Config format** | Ruby DSL (powerful but complex) | INI sections (simple, readable) |
| **Kubernetes filter** | Requires `fluent-plugin-kubernetes_metadata_filter` | Built-in `kubernetes` filter |
| **Multi-output** | Yes — native tag routing | Yes — Match patterns per Output |
| **Protocol support** | Very broad — 1,000 plugins | Focused — all production protocols |
| **Buffer durability** | File-backed buffer — survives restart | Memory default; file buffer available |
| **Best deployment** | Central aggregator (Deployment, 1-3 replicas) | Node collector (DaemonSet, 1 per node) |
| **Typical role** | Aggregation, complex transformation, fan-out | Collection, light enrichment, forwarding |
| **Community** | Mature, large | Fast-growing, Kubernetes-native focus |

### The Modern Production Log Collection Pattern

```
Every node — DaemonSet:
┌─────────────────────────────────────────────────────┐
│  Fluent Bit  (1 MB memory, 50m CPU)                │
│  INPUT:  tail /var/log/containers/*.log             │
│  FILTER: kubernetes (enriches with pod metadata)   │
│  OUTPUT: loki (HTTP POST to Loki service)           │
│          — OR —                                     │
│          forward (to Fluentd aggregator)            │
└─────────────────────────────────────────────────────┘
          │
          │ (optional aggregation layer for complex routing)
          ▼
Central aggregator — Deployment (1-3 replicas):
┌─────────────────────────────────────────────────────┐
│  Fluentd                                            │
│  INPUT:  forward (receives from Fluent Bit)        │
│  FILTER: record_transformer (add env, region tags) │
│  OUTPUT: elasticsearch (prod logs)                 │
│          loki          (debug/staging logs)        │
│          s3            (archive, 90-day retention) │
└─────────────────────────────────────────────────────┘
```

**When you need the Fluentd aggregator layer:**
- Fan-out to 3+ different backends
- Complex routing by namespace, environment, or label
- Heavy log transformation (schema normalisation)
- Buffering against backend unavailability at scale

**When Fluent Bit → backend directly is sufficient:**
- Single backend (Loki, CloudWatch, Elasticsearch)
- Simple label-based routing
- Small to medium clusters (up to ~500 nodes)
- All observability labs in this repo

### The Kubernetes Filter — What It Does

The Kubernetes filter is what makes Fluent Bit production-ready. Without it, you have raw log lines with no context. With it, every record carries:

```
Raw log line (what containerd writes to disk):
2024-01-15T09:41:07.123Z stdout F GET /api/users 200 45ms

After tail INPUT + cri PARSER:
{
  "time":   "2024-01-15T09:41:07.123Z",
  "stream": "stdout",
  "log":    "GET /api/users 200 45ms"
}

After kubernetes FILTER:
{
  "time":   "2024-01-15T09:41:07.123Z",
  "stream": "stdout",
  "log":    "GET /api/users 200 45ms",
  "kubernetes": {
    "pod_name":        "api-server-7d8f9b-xk2p",
    "namespace_name":  "production",
    "container_name":  "api",
    "node_name":       "3node-m02",
    "pod_id":          "a1b2c3d4-...",
    "labels": {
      "app":     "api-server",
      "version": "v2.1.0",
      "env":     "production"
    },
    "annotations": {
      "fluentbit.io/exclude": "false"
    }
  }
}
```

Now in Loki you can ask: `{namespace="production", app="api-server"} |= "500"` — find all 500 errors in the production API, across all pods and nodes, for any time window.

---

## Part 2 — Metrics: Prometheus and node-exporter

### What Are Metrics?

Metrics are numeric measurements collected at regular intervals and stored as time series. Each time series is identified by a metric name and a set of labels:

```
Metric name:  node_cpu_seconds_total
Labels:       {cpu="0", mode="idle", instance="3node-m02:9100", job="node-exporter"}
Value:        12345.67
Timestamp:    2024-01-15T09:41:07Z

This reads as:
"CPU core 0 on node 3node-m02 has been idle for 12345.67 seconds total"
```

Labels are what make metrics multidimensional. The same metric name with different label combinations represents different data points — one per CPU core, per node, per container, per HTTP status code.

### Prometheus Architecture

Prometheus operates on a **pull model** — it reaches out to targets and scrapes their `/metrics` endpoint on a schedule:

```
┌──────────────────────────────────────────────────────────────────┐
│                   Prometheus Architecture                         │
│                                                                   │
│  ┌────────────────────────────────┐                              │
│  │    Targets (metrics sources)   │                              │
│  │  node-exporter DaemonSet pods  │  ← HTTP GET /metrics        │
│  │  application pods with /metrics│    every scrape_interval     │
│  │  kube-state-metrics            │                              │
│  └────────────────┬───────────────┘                              │
│                   │ raw metrics text (Prometheus exposition fmt) │
│                   ▼                                              │
│  ┌────────────────────────────────┐                              │
│  │  Retrieval / Scraper           │                              │
│  │  Reads scrape configs          │                              │
│  │  Executes HTTP GETs            │                              │
│  │  Applies relabeling rules      │                              │
│  └────────────────┬───────────────┘                              │
│                   │ parsed samples                               │
│                   ▼                                              │
│  ┌────────────────────────────────┐                              │
│  │  TSDB (Time Series Database)   │                              │
│  │  Stores samples on local disk  │                              │
│  │  Compresses into blocks        │                              │
│  │  Default retention: 15 days    │                              │
│  └────────────────┬───────────────┘                              │
│                   │                                              │
│          ┌────────┴────────┐                                     │
│          ▼                 ▼                                     │
│  ┌──────────────┐  ┌──────────────┐                             │
│  │  HTTP API    │  │  Alertmanager│                             │
│  │  /query      │  │  (separate)  │                             │
│  │  /query_range│  │  routes      │                             │
│  │  Grafana     │  │  alerts to   │                             │
│  │  uses this   │  │  Slack, email│                             │
│  └──────────────┘  └──────────────┘                             │
└──────────────────────────────────────────────────────────────────┘
```

**Pull vs Push — why Prometheus pulls:**
```
Pull (Prometheus):
  Prometheus controls the schedule — uniform scrape intervals
  If a target disappears, Prometheus knows immediately (scrape fails)
  No need to configure each target with a Prometheus address
  Targets just expose /metrics and Prometheus finds them via service discovery

Push (StatsD, InfluxDB push mode):
  Targets decide when to send metrics
  If Prometheus is down, metrics are lost
  Each target must know the Prometheus address
```

### Prometheus node-exporter — What It Exposes

`node-exporter` is a DaemonSet that runs on every node and exposes the node's OS-level metrics at `http://<node-ip>:9100/metrics`:

```
Node metrics exposed by node-exporter:

CPU:
  node_cpu_seconds_total{cpu, mode}
  → Total seconds each CPU core has spent in each mode
    (user, system, idle, iowait, irq, softirq, steal)

Memory:
  node_memory_MemTotal_bytes
  node_memory_MemFree_bytes
  node_memory_MemAvailable_bytes
  node_memory_Buffers_bytes
  node_memory_Cached_bytes

Disk I/O:
  node_disk_read_bytes_total{device}
  node_disk_written_bytes_total{device}
  node_disk_io_time_seconds_total{device}

Filesystem:
  node_filesystem_size_bytes{device, fstype, mountpoint}
  node_filesystem_avail_bytes{device, fstype, mountpoint}

Network:
  node_network_receive_bytes_total{device}
  node_network_transmit_bytes_total{device}
  node_network_receive_errors_total{device}

Load:
  node_load1     (1-minute load average)
  node_load5     (5-minute load average)
  node_load15    (15-minute load average)

System:
  node_uname_info{domainname, machine, nodename, release, sysname, version}
  node_boot_time_seconds
  node_time_seconds
```

These are the raw building blocks. In Grafana you combine them into useful panels:

```
PromQL to calculate CPU usage %:
  100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

PromQL to calculate memory usage %:
  (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)
  / node_memory_MemTotal_bytes * 100

PromQL to calculate disk usage %:
  (node_filesystem_size_bytes - node_filesystem_avail_bytes)
  / node_filesystem_size_bytes * 100
```

---

## Part 3 — Loki: Logs Storage and Query

### What Is Loki?

Loki is a log aggregation system built by Grafana Labs. Its design is deliberately minimal compared to Elasticsearch:

```
Elasticsearch (ELK stack):           Loki:
────────────────────────────         ────────────────────────────
Indexes the full text of             Indexes only the labels
every log line                       (metadata), not the log content

"GET /api 200" → tokenised,          "GET /api 200" → stored as-is,
every word indexed in                compressed chunks, addressed
inverted index                       by label set

Fast full-text search                Fast label-based filtering,
("find all lines containing X")      then grep through compressed chunks
                                     for content matching

High storage cost                    Low storage cost
(index is large)                     (index is tiny — labels only)

Complex to operate                   Simple to operate
(index sharding, merging)            (object storage or filesystem)
```

**The key insight:** In Kubernetes, you almost always filter by metadata first — namespace, pod name, app label, node name — and then look at the content. Loki optimises for exactly this pattern.

### Loki Core Concepts

```
Label Set (Stream Selector):
  {cluster="3node", namespace="production", app="nginx"}
  → This is a Loki Stream — a unique combination of labels
  → Each stream is stored as an ordered sequence of log entries
  → All queries MUST include at least one label equality matcher

Log Entry:
  timestamp: 2024-01-15T09:41:07.123456789Z
  line:       GET /api/users 200 45ms

LogQL — Loki Query Language:

  Stream selector (required):
    {namespace="production"}                     → all logs in production
    {namespace="production", app="api-server"}   → narrow by app
    {namespace=~"prod.*"}                        → regex match

  Log pipeline (optional, chained after |):
    |= "error"                   → keep lines containing "error"
    != "healthcheck"             → drop lines containing "healthcheck"
    | json                       → parse JSON log line into fields
    | pattern `<ip> - <user>`    → extract fields using pattern
    | logfmt                     → parse logfmt formatted lines

  Complete example:
    {namespace="production", app="api-server"}
      |= "error"
      | json
      | status >= 500

  Metric query (convert logs to metrics):
    rate({namespace="production"} |= "error" [5m])
    → requests per second matching "error" over 5-minute window
```

### Loki Deployment Modes

```
Monolithic (used in this repo):
  Single binary running all Loki components
  Stores data on local filesystem (or object storage)
  Best for: development, small clusters, this minikube demo
  Resource: ~256MB RAM, ~0.1 CPU cores

Simple Scalable:
  Read and Write paths split into separate components
  Recommended for: production, moderate log volumes
  Scales write path independently of read path

Microservices:
  Every internal component (ingester, querier, distributor, etc.)
  runs as a separate Kubernetes Deployment
  Required for: very large log volumes, fine-grained scaling
  Complex to operate — use Helm chart for this mode
```

For these labs, Monolithic mode is used — one `Deployment` with one replica, storing logs to a local `PersistentVolume`. This keeps the manifest simple and readable.

---

## Part 4 — Grafana: Unified Visualisation

### What Is Grafana?

Grafana is the visualisation layer. It does not store data — it connects to data sources (Loki, Prometheus, Elasticsearch, etc.) and renders dashboards from queries against those sources.

```
┌──────────────────────────────────────────────────────────┐
│                    Grafana                                │
│                                                          │
│  Data Sources:                                           │
│    → Loki (your logs)        → LogQL queries            │
│    → Prometheus (your metrics) → PromQL queries         │
│    → Tempo (traces, optional)  → TraceQL queries        │
│    → (any other source via plugin)                       │
│                                                          │
│  Dashboard Panels:                                       │
│    → Time series graph  → metrics over time             │
│    → Logs panel         → log lines, filterable         │
│    → Stat panel         → single number (CPU%, pod count)│
│    → Table              → tabular data                  │
│    → Histogram          → distribution                  │
│                                                          │
│  Variables:                                              │
│    → Dashboard-level dropdowns: cluster, namespace, pod │
│    → Queries update automatically when variable changes  │
│                                                          │
│  Explore:                                               │
│    → Ad-hoc query UI — write LogQL or PromQL directly   │
│    → Side-by-side log + metric correlation              │
└──────────────────────────────────────────────────────────┘
```

### Correlating Logs and Metrics — The Key Power

The real value of having both Loki and Prometheus in the same Grafana instance:

```
Scenario: Alert fires — "API error rate > 1% for 5 minutes"

Step 1: Open the API dashboard → metrics panel
  PromQL: rate(http_requests_total{status=~"5..",app="api"}[5m])
  → Spike visible at 14:32

Step 2: Click the spike → Grafana "Explore" with same time range
  Switch to Loki data source
  LogQL: {namespace="production", app="api"} |= "error"
  → See the actual error messages at 14:32

Step 3: Read the stack trace
  "ConnectionRefusedException: database pool exhausted"
  → Root cause found in 2 minutes instead of 20
```

This is why both pipelines share one Grafana instance and both use the `cluster` label — so you can switch between log and metric views for the same cluster at the same time range.

---

## Part 5 — Multi-Cluster Design

### The Problem: Multiple Minikube Profiles

You may run multiple minikube profiles: `3node` for workloads, `5node` for scale testing, `observability` for a dedicated monitoring cluster. Without multi-cluster design, you would need a separate Grafana per cluster — defeating the purpose of centralised observability.

### The Solution: The `cluster` Label

The `cluster` label is added to every log record and every metric at collection time. It flows through the entire pipeline and becomes a Grafana dashboard variable:

```
Logs — Fluent Bit ConfigMap (per cluster):
  [OUTPUT]
      Name   loki
      Match  *
      Host   loki.monitoring.svc.cluster.local
      Port   3100
      Labels job=fluent-bit, cluster=3node      ← cluster name here

Metrics — Prometheus scrape config (per cluster):
  global:
    external_labels:
      cluster: 3node                             ← cluster label on all metrics

Grafana — data sources:
  Loki:       url: http://loki.monitoring:3100   (one shared Loki)
  Prometheus: url: http://prometheus.monitoring:9090  (one shared Prometheus)

Grafana — dashboard variable:
  Name: cluster
  Type: query
  DataSource: Loki
  Query: label_values(cluster)
  → Grafana shows a dropdown: [3node, 5node]

Dashboard panel query (logs):
  {cluster="$cluster", namespace="$namespace"}

Dashboard panel query (metrics):
  rate(node_cpu_seconds_total{cluster="$cluster"}[5m])
```

**How the same Loki and Prometheus receive data from multiple clusters:**

```
Cluster: 3node                     Cluster: 5node
  Fluent Bit DaemonSet               Fluent Bit DaemonSet
  Labels: cluster=3node              Labels: cluster=5node
       │                                   │
       └──────────────┬────────────────────┘
                      │ HTTP POST /loki/api/v1/push
                      ▼
              Loki (monitoring namespace)
              Streams:
                {cluster="3node", namespace="default", ...}
                {cluster="5node", namespace="default", ...}
```

Loki stores both streams. Grafana queries filter by `{cluster="$cluster"}`. The dashboard variable controls which cluster you see. You get a single pane of glass for all your minikube clusters.

### What This Requires Per Cluster

For each additional minikube profile you want to add to the dashboard:

1. Deploy the Fluent Bit DaemonSet (from `01-logs-loki-grafana`) with `cluster=<profile-name>` in the output labels
2. Deploy the node-exporter DaemonSet (from `02-metrics-prometheus-grafana`) with `cluster=<profile-name>` in external_labels
3. Ensure the cluster has network access to the Loki and Prometheus services

The Loki, Prometheus, and Grafana Deployments run once — in the `monitoring` namespace of one cluster (your "management" cluster, or `3node` in these labs). All other clusters only run the collection agents (Fluent Bit, node-exporter).

---

## Part 6 — Stack Overview and Lab Map

### The Full Stack Deployed in These Labs

```
Versions (latest stable, April 2026):
  Fluent Bit:           3.3
  Loki:                 3.4   (monolithic mode)
  Prometheus:           3.1
  Prometheus node-exporter: 1.9
  Grafana:              11.5
```

```
Kubernetes Resources Deployed:

monitoring namespace:
  ├── Loki Deployment (1 replica, monolithic)
  │     PersistentVolumeClaim (local storage, 5Gi)
  │     Service (ClusterIP :3100)
  │
  ├── Prometheus Deployment (1 replica)
  │     ConfigMap (scrape config — points to node-exporter DaemonSet)
  │     PersistentVolumeClaim (local storage, 5Gi)
  │     Service (ClusterIP :9090)
  │
  └── Grafana Deployment (1 replica)
        ConfigMap (datasources.yaml — auto-provisions Loki + Prometheus)
        ConfigMap (dashboards/*.json — auto-provisions dashboards)
        Service (NodePort :30300 — browser access)

default namespace (DaemonSets — run on every node):
  ├── Fluent Bit DaemonSet
  │     ConfigMap (pipeline config — tail → kubernetes filter → loki output)
  │     ServiceAccount + ClusterRoleBinding (kubernetes filter RBAC)
  │
  └── node-exporter DaemonSet
        Service (ClusterIP :9100 — Prometheus scrapes this)
```

### Lab Sequence

```
You are here → 00-observability-concepts  (this document — theory only)
                      │
                      ▼
               01-logs-loki-grafana
                 Deploy: Loki, Grafana, Fluent Bit DaemonSet
                 Result: Browser → Grafana → query logs by cluster/namespace/pod
                      │
                      ▼
               02-metrics-prometheus-grafana
                 Deploy: Prometheus, node-exporter DaemonSet
                 Update: Grafana with Prometheus data source + Node dashboard
                 Result: Browser → Grafana → CPU/memory/disk panels per node
                         Combined dashboard: logs + metrics side-by-side
```

---

## Quick Reference — Key Terms

| Term | What It Is |
|------|-----------|
| **Fluent Bit** | Lightweight log collector — runs as DaemonSet, 1 pod per node |
| **Fluentd** | Heavy log aggregator — runs as Deployment, 1-3 replicas, complex routing |
| **Loki** | Log storage — indexes labels only (not content), queried with LogQL |
| **LogQL** | Loki's query language — stream selector + log pipeline |
| **Label (Loki)** | Key=value metadata attached to a log stream — the only indexed field |
| **Stream (Loki)** | Unique combination of labels — one ordered sequence of log entries |
| **Prometheus** | Metrics storage — pull model, TSDB, queried with PromQL |
| **PromQL** | Prometheus query language — time series math and aggregation |
| **node-exporter** | DaemonSet that exposes OS-level node metrics at `:9100/metrics` |
| **Scrape interval** | How often Prometheus polls a target's `/metrics` endpoint |
| **Grafana** | Visualisation layer — connects to Loki + Prometheus, renders dashboards |
| **Data source** | A backend that Grafana queries — one entry per Loki/Prometheus instance |
| **cluster label** | Added by Fluent Bit and Prometheus to all records — enables multi-cluster filtering in Grafana |
| **LGTM stack** | Loki + Grafana + Tempo + Mimir — the Grafana Labs observability suite |

---

## What To Read Next

You now have the conceptual foundation. Proceed to:

1. **`01-logs-loki-grafana`** — build the complete logs pipeline end-to-end
2. **`02-metrics-prometheus-grafana`** — add metrics and the combined dashboard

Both labs assume you have read and understood this document. Every configuration decision in those labs maps back to concepts covered here.