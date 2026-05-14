# Metrics Pipeline — node-exporter → Prometheus → Grafana

## Lab Overview

This lab adds the metrics pipeline to the observability stack built in Lab 01.
You deploy Prometheus as the metrics storage backend, add a node-exporter
DaemonSet to collect node-level OS metrics from every node, and extend the
same Grafana instance from Lab 01 with a Prometheus datasource and a Node
Metrics dashboard.

When this lab is complete you will see real CPU usage, memory consumption,
disk I/O, and network throughput per minikube node — live — in Grafana. You
will also run a combined view showing logs and metrics side by side for the
same time window, demonstrating the observability correlation pattern.

**Read first:**
`06-observability/00-observability-concepts` — Part 2 covers Prometheus
architecture, the pull model, and PromQL. Part 4 covers Grafana data sources.
Part 5 covers the multi-cluster design with `external_labels`.

**Prerequisite lab:**
`06-observability/01-logs-loki-grafana` — Grafana must be running in the
`monitoring` namespace. This lab adds a second datasource and dashboard to
the same Grafana deployment.

**What you'll do:**
- Understand node-exporter: what it collects and why it needs host-level access
- Understand Prometheus's pull model, TSDB, and Kubernetes service discovery
- Understand every field in the Prometheus scrape configuration
- Deploy node-exporter as a DaemonSet on all nodes (applying DaemonSet skills)
- Deploy Prometheus with Kubernetes service discovery scrape config
- Add the `cluster=3node` external label to all Prometheus metrics
- Add Prometheus datasource to Grafana (auto-provisioned via ConfigMap)
- Use the Node Metrics dashboard: CPU %, memory %, disk %, network I/O
- Write PromQL queries to understand what the dashboard panels do
- Correlate a log spike with a CPU metric spike in the same time window
- Understand the AWS production architecture: EBS PVC, EKS IRSA, AMP vs self-hosted

## Prerequisites

**Required Software:**
- Minikube `3node` profile running with metrics-server enabled
- Lab 01 complete — Grafana running in `monitoring` namespace
- kubectl configured for `3node`

**Enable metrics-server (required for `kubectl top`):**
```bash
minikube addons enable metrics-server --profile 3node
# Wait ~60 seconds, then verify:
kubectl top nodes
```

**Verify Lab 01 is running:**
```bash
kubectl get pods -n monitoring
# NAME               READY   STATUS    AGE
# grafana-xxxxx      1/1     Running   ...
# loki-xxxxx         1/1     Running   ...
```

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain what node-exporter collects and why it needs `hostPID`, `hostNetwork`, and `/host` mounts
2. ✅ Explain Prometheus's pull model — targets, scrape intervals, TSDB
3. ✅ Explain `kubernetes_sd_configs` — how Prometheus discovers node-exporter pods automatically
4. ✅ Explain `external_labels` and why `cluster=3node` is the multi-cluster key
5. ✅ Explain relabeling — how target labels become metric labels in Prometheus
6. ✅ Deploy node-exporter DaemonSet with proper host-level access
7. ✅ Deploy Prometheus with Kubernetes service discovery
8. ✅ Verify Prometheus is scraping node-exporter targets
9. ✅ Add Prometheus datasource to Grafana via ConfigMap (no manual UI steps)
10. ✅ Interpret the Node Metrics custom dashboard panels and their PromQL queries
11. ✅ Import the community Node Exporter Full dashboard (ID 1860) via Grafana UI
12. ✅ Write PromQL queries for CPU, memory, disk, and network metrics
12. ✅ Correlate logs and metrics in a combined Grafana view

## Versions

| Component | Version | Image |
|-----------|---------|-------|
| Prometheus | 3.10.0 | `prom/prometheus:v3.10.0` |
| node-exporter | 1.10.2 | `quay.io/prometheus/node-exporter:v1.10.2` |
| Grafana OSS | 12.4.2 | `grafana/grafana:12.4.2` (already running from Lab 01) |

## Directory Structure

```
02-metrics-prometheus-grafana/
└── src/
    ├── 01-prometheus-rbac.yaml           # ServiceAccount + ClusterRole for k8s service discovery
    ├── 02-prometheus-configmap.yaml      # prometheus.yml — scrape config + external_labels
    ├── 03-prometheus-pvc.yaml            # PVC for Prometheus TSDB storage
    ├── 04-prometheus-deployment.yaml     # Prometheus Deployment + ClusterIP Service
    ├── 05-node-exporter-daemonset.yaml   # node-exporter DaemonSet — all nodes
    ├── 06-grafana-prometheus-ds.yaml     # ConfigMap: add Prometheus datasource to Grafana
    └── 07-grafana-node-dashboard-cm.yaml # ConfigMap: Node Metrics dashboard JSON
```

---

## Understanding the Components

### node-exporter — What It Collects and How

node-exporter is a Prometheus exporter that runs on each node and exposes
OS-level metrics from the Linux kernel's proc and sys filesystems:

```
/proc/stat           → CPU time by mode (user, system, idle, iowait, ...)
/proc/meminfo        → memory totals, free, available, buffers, cached
/proc/diskstats      → disk reads, writes, I/O time per device
/proc/net/dev        → network bytes/packets sent/received per interface
/proc/sys/fs/file-nr → file descriptor usage
/proc/loadavg        → 1, 5, 15 minute load averages
/sys/class/hwmon     → hardware sensor readings (temperature, fan speed)
```

**Why it needs special access in Kubernetes:**

node-exporter runs in a container but must read the HOST's proc and sys
filesystems — not the container's isolated view of them. Three flags
are required:

```yaml
hostPID: true
# The container sees the host's PID namespace.
# Without this, /proc inside the container only shows container processes.
# node-exporter needs ALL host PIDs to report per-process metrics.

hostNetwork: true
# The container uses the host's network namespace.
# Without this, network interface metrics show only veth interfaces
# (container networking), not the node's real eth0, flannel0, etc.
# Also means node-exporter listens on the node's IP at port 9100,
# making it directly addressable by Prometheus without a Service.

volumes:
  - name: host-root
    hostPath:
      path: /
# Mount the entire host root filesystem at /host inside the container.
# node-exporter uses --path.rootfs=/host to read /host/proc, /host/sys
# instead of the container's isolated /proc, /sys.
```

**Key metrics exposed:**

```
CPU:
  node_cpu_seconds_total{cpu, mode}
  One counter per CPU core per mode (user, system, idle, iowait, irq, softirq, steal, guest)

Memory:
  node_memory_MemTotal_bytes
  node_memory_MemAvailable_bytes     ← most useful — includes reclaimable buffers/cache
  node_memory_MemFree_bytes
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
  node_load1    (1-minute load average)
  node_load5    (5-minute load average)
  node_load15   (15-minute load average)

System:
  node_boot_time_seconds      (system uptime reference point)
  node_uname_info{...}        (kernel version, architecture, hostname)
```

### Prometheus — Pull Model and Kubernetes Service Discovery

**The pull model:**
```
Prometheus configuration defines "targets" — HTTP endpoints to scrape.
Every scrape_interval (15s by default), Prometheus:

  1. Reads the target list (static or discovered dynamically)
  2. Sends GET /metrics to each target
  3. Parses the Prometheus text format response
  4. Stores the samples in TSDB with a timestamp
  5. Repeats

Target response format (Prometheus text exposition format):
  # HELP node_load1 1m load average.
  # TYPE node_load1 gauge
  node_load1{instance="3node-m02:9100",job="node-exporter"} 0.45

                                    ↑                           ↑
                              labels (metadata)             value
```

**Kubernetes service discovery (`kubernetes_sd_configs`):**

Instead of listing node-exporter IP addresses manually, Prometheus queries
the Kubernetes API to find all pods with a specific label. When a new
node-exporter pod appears (new DaemonSet pod on a new node), Prometheus
discovers it automatically:

```yaml
scrape_configs:
  - job_name: node-exporter
    kubernetes_sd_configs:
      - role: pod               # Discover pods (not nodes, services, endpoints)
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app]
        regex: node-exporter    # Only scrape pods with label app=node-exporter
        action: keep
```

**Relabeling — how it works:**

When Prometheus discovers a target, it creates a set of meta-labels
from the Kubernetes API response (`__meta_kubernetes_*`). Relabeling
transforms these into the final label set attached to metrics:

```
Meta-labels from Kubernetes API (available during scrape):
  __meta_kubernetes_pod_name           = node-exporter-7mnbq
  __meta_kubernetes_pod_node_name      = 3node-m02
  __meta_kubernetes_pod_ip             = 10.244.1.8
  __meta_kubernetes_namespace          = default

Relabeling actions:
  - source_labels: [__meta_kubernetes_pod_node_name]
    target_label: node
  → Adds label: node="3node-m02" to all metrics from this target

  - source_labels: [__meta_kubernetes_pod_ip]
    replacement: ${1}:9100
    target_label: __address__
  → Sets the scrape address to pod_ip:9100
    (node-exporter uses hostNetwork, so pod IP = node IP)
```

**`external_labels` — the multi-cluster key:**

```yaml
global:
  external_labels:
    cluster: 3node    # Added to EVERY metric scraped by this Prometheus
```

This label propagates to all metrics stored in TSDB. In Grafana, the
`$cluster` dashboard variable filters by this label — selecting `3node`
shows only metrics from this Prometheus instance. A second Prometheus on
`5node` would use `cluster: 5node`, and both feed the same Grafana.

### PromQL — Key Queries

The dashboard panels use these PromQL expressions. Understanding them
lets you write your own:

```
CPU Usage % per node:
  100 - (avg by (node) (
    rate(node_cpu_seconds_total{cluster="$cluster", mode="idle"}[5m])
  ) * 100)

  Explanation:
  rate(node_cpu_seconds_total{mode="idle"}[5m])
    → idle CPU fraction per core, 5-minute rate
  avg by (node)(...)
    → average across all cores on each node
  100 - (...) * 100
    → convert idle fraction to usage percentage

Memory Usage % per node:
  (node_memory_MemTotal_bytes{cluster="$cluster"}
   - node_memory_MemAvailable_bytes{cluster="$cluster"})
  / node_memory_MemTotal_bytes{cluster="$cluster"} * 100

  Explanation:
  MemAvailable includes reclaimable buffers and cache (better than MemFree)
  (Total - Available) / Total = fraction in use

Disk Usage % per node (root filesystem):
  (node_filesystem_size_bytes{cluster="$cluster", mountpoint="/"}
   - node_filesystem_avail_bytes{cluster="$cluster", mountpoint="/"})
  / node_filesystem_size_bytes{cluster="$cluster", mountpoint="/"} * 100

Network receive rate (bytes/sec) per node:
  rate(node_network_receive_bytes_total{
    cluster="$cluster",
    device!~"lo|veth.*|docker.*|flannel.*|cni.*"
  }[5m])

  Explanation:
  Rate converts cumulative counter to per-second rate
  device filter excludes loopback and virtual interfaces — shows real NICs only
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  default namespace                                           │
│                                                             │
│  node-exporter DaemonSet  (all 3 nodes)                    │
│    hostPID: true                                            │
│    hostNetwork: true                                        │
│    /host mounted from /  (read-only)                       │
│    Exposes: :9100/metrics on each node                     │
└────────────────────────┬────────────────────────────────────┘
                         │ HTTP GET /metrics every 15s
                         │ (Prometheus discovers via kubernetes_sd)
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  monitoring namespace                                        │
│                                                             │
│  Prometheus 3.10.0 (Deployment)                            │
│    ClusterIP Service: prometheus:9090                      │
│    PVC: prometheus-storage (10Gi)                          │
│    Config: kubernetes_sd_configs — discovers node-exporter │
│    external_labels: cluster=3node                          │
│                                                             │
│  Grafana 12.4.2 (from Lab 01 — same Deployment)           │
│    New datasource: Prometheus (auto-provisioned)           │
│    New dashboard: Node Metrics (auto-provisioned)          │
│    NodePort: 30300 (unchanged)                             │
└─────────────────────────────────────────────────────────────┘
                         │
                         ▼
              Browser → http://<minikube-ip>:30300
              Logs dashboard (Lab 01) + Node Metrics dashboard (this lab)
```

---

## Lab Step-by-Step Guide

### Step 1: Understand the Prometheus Configuration

**02-prometheus-configmap.yaml:**

```yaml
global:
  scrape_interval: 15s        # Scrape every target every 15 seconds
  evaluation_interval: 15s    # Evaluate alerting rules every 15 seconds
  scrape_timeout: 10s         # Abort a scrape if no response in 10s

  external_labels:
    cluster: 3node            # Added to EVERY metric — the multi-cluster key
                              # Change this per minikube profile

scrape_configs:
  # ── Prometheus self-monitoring ──────────────────────────────────────
  - job_name: prometheus
    static_configs:
      - targets: [localhost:9090]   # Prometheus scrapes its own /metrics

  # ── node-exporter via Kubernetes service discovery ─────────────────
  - job_name: node-exporter
    kubernetes_sd_configs:
      - role: pod             # Watch the Kubernetes API for pod changes
        namespaces:
          names: [default]    # Only look in the default namespace
    relabel_configs:
      # Only scrape pods with label app=node-exporter
      - source_labels: [__meta_kubernetes_pod_label_app]
        regex: node-exporter
        action: keep

      # Set the scrape address to the pod IP + port 9100
      # node-exporter uses hostNetwork so pod IP == node IP
      - source_labels: [__meta_kubernetes_pod_ip]
        replacement: '${1}:9100'
        target_label: __address__

      # Preserve the node name as a metric label
      - source_labels: [__meta_kubernetes_pod_node_name]
        target_label: node

      # Preserve the namespace as a metric label
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
```

**Why `role: pod` and not `role: node`?**
`role: node` would discover the Kubernetes Node objects directly. It works
but gives you less flexibility — you cannot filter by pod labels. `role: pod`
discovers pods, letting you filter by `app=node-exporter` and extract the
pod's node name through relabeling. The end result is the same but the
approach is more maintainable.

---

### Step 2: Understand the node-exporter DaemonSet

**05-node-exporter-daemonset.yaml:**
```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-exporter
  namespace: default
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: default
  labels:
    app: node-exporter
    version: "1.10.2"
spec:
  selector:
    matchLabels:
      app: node-exporter
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: node-exporter
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9100"
    spec:
      serviceAccountName: node-exporter
      # hostPID: required to see the host PID namespace.
      # Without it /proc shows only container processes — CPU and process metrics wrong.
      hostPID: true
      # hostNetwork: required for real NIC metrics.
      # Without it only virtual interfaces (veth, docker0) visible.
      # Side effect: pod IP = node IP, port 9100 bound directly on node.
      hostNetwork: true
      # Tolerate ALL taints — monitor every node including control-plane.
      tolerations:
        - operator: Exists
      containers:
        - name: node-exporter
          image: quay.io/prometheus/node-exporter:v1.10.2
          args:
            - --path.procfs=/host/proc    # Read host /proc, not container's
            - --path.sysfs=/host/sys      # Read host /sys, not container's
            - --path.rootfs=/host         # Root of host filesystem
            # Exclude virtual/container filesystems from disk metrics.
            # Without this filter, Docker image layers inflate disk stats.
            # $$ escapes the literal $ in YAML multiline strings.
            - --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)
            # Exclude loopback and virtual network interfaces.
            - --collector.netdev.device-exclude=^(lo|veth.*|docker.*|flannel.*|cni.*)$$
          ports:
            - name: metrics
              containerPort: 9100
              hostPort: 9100    # Binds to node port directly (hostNetwork mode)
          readinessProbe:
            httpGet:
              path: /
              port: 9100
            initialDelaySeconds: 5
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65534    # nobody
            capabilities:
              drop: [ALL]
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
          volumeMounts:
            - name: proc
              mountPath: /host/proc
              readOnly: true
            - name: sys
              mountPath: /host/sys
              readOnly: true
            # HostToContainer: new mounts on host become visible inside container.
            # Required for disk stats on dynamically mounted volumes.
            - name: host-root
              mountPath: /host
              readOnly: true
              mountPropagation: HostToContainer
      volumes:
        - name: proc
          hostPath:
            path: /proc
        - name: sys
          hostPath:
            path: /sys
        - name: host-root
          hostPath:
            path: /
```

**Three critical flags explained:**

| Flag | Why required | Without it |
|------|-------------|-----------|
| `hostPID: true` | See ALL host PIDs through `/proc` | Only container processes visible — CPU time wrong |
| `hostNetwork: true` | Use host network namespace | Only virtual interfaces (veth, docker0) — no real NIC metrics |
| `/host` hostPath mount | Read actual node proc/sys | Container's isolated view — reports container stats, not node stats |

---

### Step 3: Apply RBAC for Prometheus

Prometheus needs to call the Kubernetes API to discover node-exporter pods
via `kubernetes_sd_configs`. These permissions grant that access.

**01-prometheus-rbac.yaml:**
```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus
rules:
  - apiGroups: [""]
    resources:
      - nodes
      - nodes/proxy       # Required for Kubernetes cadvisor metrics scraping
      - nodes/metrics     # Required for kubelet /metrics/resource endpoint
      - services
      - endpoints
      - pods
    verbs:
      - get
      - list
      - watch
  - apiGroups: ["extensions", "networking.k8s.io"]
    resources:
      - ingresses
    verbs:
      - get
      - list
      - watch
  - nonResourceURLs:
      - /metrics           # Scrape /metrics directly on nodes
      - /metrics/cadvisor  # Container-level resource metrics
    verbs:
      - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: monitoring
```

```bash
cd 02-metrics-prometheus-grafana/src
kubectl apply -f 01-prometheus-rbac.yaml
```

**Expected output:**
```
serviceaccount/prometheus created
clusterrole.rbac.authorization.k8s.io/prometheus created
clusterrolebinding.rbac.authorization.k8s.io/prometheus created
```

---

### Step 4: Deploy Prometheus

**03-prometheus-pvc.yaml:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prometheus-storage
  namespace: monitoring
  labels:
    app: prometheus
spec:
  # minikube: "standard" StorageClass — hostPath-backed dynamic provisioning
  # AWS EKS production: storageClassName: gp3 (requires aws-ebs-csi-driver)
  storageClassName: standard
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
      # Prometheus TSDB sizing rule of thumb:
      # bytes_per_sample(~2) × samples_per_second × retention_seconds × 2
      # For 3 nodes, node-exporter only: 10Gi covers months of data
```

**04-prometheus-deployment.yaml:**
```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: monitoring
  labels:
    app: prometheus
    version: "3.10.0"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      serviceAccountName: prometheus
      securityContext:
        fsGroup: 65534       # nobody GID — Prometheus default
        runAsUser: 65534
        runAsGroup: 65534
        runAsNonRoot: true
      containers:
        - name: prometheus
          image: prom/prometheus:v3.10.0
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            - --storage.tsdb.path=/prometheus          # TSDB on PVC
            - --storage.tsdb.retention.time=15d        # Keep 15 days
            - --storage.tsdb.retention.size=8GB        # Cap at 8GB (2GB headroom on 10Gi PVC)
            - --web.enable-lifecycle                   # POST /-/reload to reload config
          ports:
            - name: http
              containerPort: 9090
          readinessProbe:
            httpGet:
              path: /-/ready
              port: 9090
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /-/healthy
              port: 9090
            initialDelaySeconds: 60
            periodSeconds: 30
            failureThreshold: 5
          resources:
            requests:
              cpu: "200m"
              memory: "512Mi"
            limits:
              cpu: "1000m"
              memory: "1Gi"
          volumeMounts:
            - name: config
              mountPath: /etc/prometheus/prometheus.yml
              subPath: prometheus.yml
            - name: storage
              mountPath: /prometheus
      volumes:
        - name: config
          configMap:
            name: prometheus-config
        - name: storage
          persistentVolumeClaim:
            claimName: prometheus-storage
---
# ClusterIP Service — Grafana queries Prometheus via in-cluster DNS:
#   http://prometheus.monitoring.svc.cluster.local:9090
# Add nodePort: 30090 and type: NodePort for direct browser access during debugging
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: monitoring
  labels:
    app: prometheus
spec:
  type: ClusterIP
  selector:
    app: prometheus
  ports:
    - name: http
      port: 9090
      targetPort: 9090
```

```bash
kubectl apply -f 02-prometheus-configmap.yaml
kubectl apply -f 03-prometheus-pvc.yaml
kubectl apply -f 04-prometheus-deployment.yaml
```

**Expected output:**
```
configmap/prometheus-config created
persistentvolumeclaim/prometheus-storage created
deployment.apps/prometheus created
service/prometheus created
```

**Watch Prometheus start:**
```bash
kubectl get pods -n monitoring -w
# prometheus-xxxxxxxxx-xxxxx goes 0/1 → 1/1
```

**Verify Prometheus is running:**
```bash
kubectl port-forward -n monitoring svc/prometheus 9090:9090 &

# Check targets — Prometheus UI
open http://localhost:9090/targets
# Or check via API:
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep '"health"'
```

**Expected targets:**
```
"health": "up"   ← prometheus self-monitoring
"health": "up"   ← node-exporter on 3node
"health": "up"   ← node-exporter on 3node-m02
"health": "up"   ← node-exporter on 3node-m03
```

All 4 targets should be `up`. If node-exporter targets are `unknown` or
`down`, wait 30 seconds for the first scrape cycle to complete.

**Verify a sample metric:**
```bash
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode 'query=node_load1{cluster="3node"}' \
  | python3 -m json.tool
```

**Expected output:**
```json
{
    "status": "success",
    "data": {
        "resultType": "vector",
        "result": [
            {
                "metric": {
                    "__name__": "node_load1",
                    "cluster": "3node",      ← external_label applied
                    "instance": "...",
                    "job": "node-exporter",
                    "node": "3node"
                },
                "value": [1705312867.123, "0.45"]
            }
        ]
    }
}
```

The `cluster: 3node` label is present on every metric — added by `external_labels`.

```bash
kill %1  # stop port-forward
```

---

### Step 5: Deploy node-exporter DaemonSet

```bash
kubectl apply -f 05-node-exporter-daemonset.yaml
```

**Expected output:**
```
daemonset.apps/node-exporter created
```

```bash
kubectl get ds node-exporter
# NAME            DESIRED   CURRENT   READY
# node-exporter   3         3         3     ← all 3 nodes (control-plane + workers)
```

```bash
kubectl get pods -l app=node-exporter -o wide
# NAME                  READY   STATUS    NODE
# node-exporter-4xk2p   1/1     Running   3node       ← control-plane
# node-exporter-7mnbq   1/1     Running   3node-m02   ← worker 1
# node-exporter-p9sz3   1/1     Running   3node-m03   ← worker 2
```

**Verify node-exporter exposes metrics:**
```bash
# Port-forward to the pod on worker 1 (or any pod)
kubectl port-forward pod/node-exporter-7mnbq 9100:9100 &

curl http://localhost:9100/metrics | grep "^node_load1"
```

**Expected output:**
```
node_load1 0.51
```

```bash
curl http://localhost:9100/metrics | grep "^node_cpu_seconds_total" | head -5
```

**Expected output (one line per CPU mode):**
```
node_cpu_seconds_total{cpu="0",mode="idle"} 12345.67
node_cpu_seconds_total{cpu="0",mode="iowait"} 23.45
node_cpu_seconds_total{cpu="0",mode="system"} 234.56
node_cpu_seconds_total{cpu="0",mode="user"} 456.78
```

```bash
kill %1
```

---

### Step 6: Add Prometheus Datasource to Grafana

This ConfigMap replaces the one from Lab 01, adding Prometheus alongside Loki.
Grafana auto-provisions datasources from `/etc/grafana/provisioning/datasources/`
at startup — updating this ConfigMap and restarting Grafana is all that is needed.

**06-grafana-prometheus-ds.yaml:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: monitoring
  labels:
    app: grafana
data:
  # Replaces the Lab 01 version — adds Prometheus alongside Loki.
  # After applying: kubectl rollout restart deployment/grafana -n monitoring
  datasources.yaml: |
    apiVersion: 1
    datasources:
      # ── Loki (from Lab 01 — unchanged) ─────────────────────────────
      - name: Loki
        type: loki
        uid: loki-datasource
        access: proxy
        url: http://loki.monitoring.svc.cluster.local:3100
        isDefault: true
        version: 1
        editable: false
        jsonData:
          maxLines: 1000

      # ── Prometheus (added in this lab) ──────────────────────────────
      - name: Prometheus
        type: prometheus
        uid: prometheus-datasource   # Stable UID referenced by dashboard JSON
        access: proxy
        # proxy: Grafana backend calls Prometheus — browser never contacts it
        url: http://prometheus.monitoring.svc.cluster.local:9090
        isDefault: false             # Loki remains default for Explore
        version: 1
        editable: false
        jsonData:
          timeInterval: 15s          # Matches Prometheus scrape_interval
          queryTimeout: 60s
          httpMethod: POST           # POST supports longer queries than GET
```

```bash
kubectl apply -f 06-grafana-prometheus-ds.yaml
```

**Expected output:**
```
configmap/grafana-datasources configured   ← updates the existing ConfigMap
```

**Restart Grafana to pick up the new datasource:**
```bash
kubectl rollout restart deployment/grafana -n monitoring
kubectl rollout status deployment/grafana -n monitoring
```

**Verify in Grafana:**

Open Grafana in your browser (same URL from Lab 01).

Navigate to: **Connections → Data sources**

You should now see **two datasources**:
- `Loki` (from Lab 01) — default datasource
- `Prometheus` — pointing to `http://prometheus.monitoring.svc.cluster.local:9090`

Click `Prometheus` → **Save & test** → `Data source is working`

---

### Step 7: Add the Focused Node Metrics Dashboard

**07-grafana-node-dashboard-cm.yaml** — stripped structure (full JSON in `src/`):
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-node-metrics
  namespace: monitoring
data:
  node-metrics.json: |
    {
      "title": "Node Metrics",
      "uid": "node-metrics-v1",
      "templating": {
        "list": [
          # $cluster  — label_values(node_uname_info, cluster)
          # $node     — label_values(node_uname_info{cluster="$cluster"}, node)
        ]
      },
      "panels": [
        # Panel 1 — CPU Usage % by Node
        #   expr: 100 - (avg by (node)(rate(node_cpu_seconds_total{..., mode="idle"}[5m])) * 100)
        #   type: timeseries   unit: percent

        # Panel 2 — Memory Usage % by Node
        #   expr: (MemTotal - MemAvailable) / MemTotal * 100
        #   type: timeseries   unit: percent

        # Panel 3 — Disk Usage % Root Filesystem
        #   expr: (size - avail) / size * 100   mountpoint="/"
        #   type: gauge   thresholds: green/70%yellow/90%red

        # Panel 4 — Network Receive Rate bytes/sec
        #   expr: rate(node_network_receive_bytes_total{device!~"lo|veth.*|..."}[5m])
        #   type: timeseries   unit: Bps

        # Panel 5 — Load Average (1m / 5m / 15m)
        #   expr: node_load1, node_load5, node_load15
        #   type: timeseries
      ]
    }
```

Full JSON with all PromQL queries is in `src/07-grafana-node-dashboard-cm.yaml`.
Every query is explained in Step 8 below.

```bash
kubectl apply -f 07-grafana-node-dashboard-cm.yaml
```

**Patch the Grafana Deployment's initContainer** to copy this new dashboard JSON
into the shared dashboard directory alongside the Kubernetes Logs dashboard:

```bash
kubectl patch deployment grafana -n monitoring --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/initContainers/0/command/2",
    "value": "mkdir -p /var/lib/grafana/dashboards && cp /tmp/dashboards/kubernetes-logs.json /var/lib/grafana/dashboards/ && cp /tmp/node-dashboard/node-metrics.json /var/lib/grafana/dashboards/ && echo Dashboard files copied"
  }
]'
```

Alternatively, edit the Deployment directly:
```bash
kubectl edit deployment grafana -n monitoring
# In the initContainer command, add:
#   cp /tmp/node-dashboard/node-metrics.json /var/lib/grafana/dashboards/
# Add a new volumeMount:
#   - name: node-dashboard-source
#     mountPath: /tmp/node-dashboard
# Add a new volume:
#   - name: node-dashboard-source
#     configMap:
#       name: grafana-dashboard-node-metrics
#       items:
#         - key: node-metrics.json
#           path: node-metrics.json
```

Restart Grafana to pick up all changes:
```bash
kubectl rollout restart deployment/grafana -n monitoring
kubectl rollout status deployment/grafana -n monitoring
```

Navigate to **Dashboards → Kubernetes** folder. You should see:
- `Kubernetes Logs` (from Lab 01)
- `Node Metrics` (this lab — 5 focused panels)

Open **Node Metrics**.

---

### Step 7b: Import the Node Exporter Full Community Dashboard (ID 1860)

The community dashboard **Node Exporter Full** (ID 1860) is the production
standard — built by the Prometheus community, maintained at
[github.com/rfmoz/grafana-dashboards](https://github.com/rfmoz/grafana-dashboards),
and used by thousands of teams worldwide. It contains ~30 panels covering every
node-exporter metric in depth.

**Importing via Grafana UI (standard production workflow):**

1. In Grafana, navigate to **Dashboards → New → Import**

2. In the **"Import via grafana.com"** field, type: `1860`

3. Click **Load** — Grafana fetches the dashboard JSON from grafana.com

4. On the next screen:
   - **Name**: `Node Exporter Full` (or keep as-is)
   - **Folder**: `Kubernetes`
   - **Prometheus**: select `Prometheus` from the datasource dropdown
   - Click **Import**

5. The dashboard opens immediately with all panels populated.

**What the Node Exporter Full dashboard contains:**

```
Row: Quick CPU / Mem / Disk
  ├── CPU Busy (gauge — % not idle)
  ├── Sys Load (gauge — load avg / CPU count ratio)
  ├── RAM Used (gauge)
  ├── SWAP Used (gauge)
  └── Root FS Used (gauge)

Row: Basic CPU / Mem / Net / Disk
  ├── CPU Basic (time series — user/system/iowait/steal)
  ├── Memory Basic (time series — used/buffers/cached/free)
  ├── Network Traffic Basic (time series — receive/transmit bytes/sec)
  └── Disk Space Used Basic (gauge per filesystem)

Row: CPU
  ├── CPU Usage (stacked — user/nice/system/iowait/irq/softirq/steal/idle)
  ├── CPU Usage Per Core
  └── CPU Frequency

Row: Memory
  ├── Memory Usage (detailed — used/buffers/cached/free/slab)
  ├── Memory Pages In / Out
  └── Swap Activity

Row: Disk
  ├── I/O Utilization
  ├── I/O Weighted Time
  ├── Disk R/W Bytes
  └── Disk Read/Write Latency

Row: Network
  ├── Network Traffic (bytes/sec per interface)
  ├── Network Packet Errors
  └── Network Packet Drops
```

**Key difference from the custom dashboard:** The community dashboard uses
`instance` label (IP:port) as the node identifier — not the `node` label
from our relabeling rules. You may need to adjust the `instance` variable
to match your node-exporter pod IPs or add a `node` variable pointing to
the `node` label created by the relabeling config in `02-prometheus-configmap.yaml`.

**When to use each:**

| Dashboard | Use for |
|-----------|---------|
| Node Metrics (custom, this lab) | Learning — each panel maps to a concept taught in this lab |
| Node Exporter Full (ID 1860) | Production — comprehensive coverage, community maintained |

---

### Step 8: Explore the Node Metrics Dashboard

**Dashboard variables at the top:**
- `cluster` — select `3node`
- `node` — select a specific node or `.*` for all

**Panel 1 — CPU Usage % per Node (time series)**
```promql
100 - (avg by (node) (
  rate(node_cpu_seconds_total{cluster="$cluster", mode="idle"}[5m])
) * 100)
```
This computes: what percentage of CPU time is NOT idle?
The `avg by (node)` averages across all CPU cores on each node.
Expected range: 5–40% on an idle minikube cluster.

**Panel 2 — Memory Usage % per Node (gauge + time series)**
```promql
(node_memory_MemTotal_bytes{cluster="$cluster"}
 - node_memory_MemAvailable_bytes{cluster="$cluster"})
/ node_memory_MemTotal_bytes{cluster="$cluster"} * 100
```
Uses `MemAvailable` (not `MemFree`) — MemAvailable includes reclaimable
buffers and page cache, which Linux counts as "used" but can reclaim
instantly. MemAvailable is the correct metric for "how much memory is
actually available for new processes."

**Panel 3 — Disk Usage % (root filesystem)**
```promql
(node_filesystem_size_bytes{cluster="$cluster", mountpoint="/"}
 - node_filesystem_avail_bytes{cluster="$cluster", mountpoint="/"})
/ node_filesystem_size_bytes{cluster="$cluster", mountpoint="/"} * 100
```
Filters to the root filesystem only (`mountpoint="/"`) to avoid showing
Docker overlay filesystems which would inflate the metric.

**Panel 4 — Network Receive Rate (bytes/sec)**
```promql
rate(node_network_receive_bytes_total{
  cluster="$cluster",
  device!~"lo|veth.*|docker.*|flannel.*|cni.*"
}[5m])
```
The `device` regex excludes loopback (`lo`), virtual Ethernet pairs
(`veth.*`), Docker bridge (`docker.*`), and CNI overlay interfaces.
Only the real node NIC (usually `eth0` in minikube) is shown.

---

### Step 9: Write PromQL in Prometheus UI (and Grafana Explore)

**Using Prometheus built-in expression browser:**
```bash
kubectl port-forward -n monitoring svc/prometheus 9090:9090 &
```

Open `http://localhost:9090/graph` in your browser.

**Try these queries:**

```promql
# Current node load average
node_load1{cluster="3node"}

# Current memory available per node in GB
node_memory_MemAvailable_bytes{cluster="3node"} / 1024 / 1024 / 1024

# Rate of disk reads per node (bytes/sec over last 5 minutes)
rate(node_disk_read_bytes_total{cluster="3node"}[5m])

# How long has each node been running? (seconds since boot)
time() - node_boot_time_seconds{cluster="3node"}

# Top 3 CPU-using nodes
topk(3, 100 - avg by (node) (
  rate(node_cpu_seconds_total{cluster="3node", mode="idle"}[5m])
) * 100)
```

Switch the view to **Graph** tab to see each metric as a time series.

**In Grafana Explore:**

Switch the datasource from Loki to Prometheus (top dropdown in Explore).

Try the same queries — Grafana renders them with its time series visualisation.
Notice the time range picker and the ability to zoom into specific windows.

```bash
kill %1
```

---

### Step 10: Correlate Logs and Metrics

This is the observability payoff — using both Loki and Prometheus in the
same Grafana time window to correlate a metric anomaly with its cause in logs.

**Scenario:** You notice a CPU spike on `3node-m02`. Find out what caused it.

**Step A — See the CPU spike in Node Metrics dashboard:**

Open **Node Metrics** dashboard. Set `node=3node-m02`.

Note the time window when CPU usage is elevated.

**Step B — Pivot to logs for the same time window:**

Click the time range on the CPU graph → **Explore from here** (Grafana 12.x feature).

This opens Explore with the same time range pre-selected. Switch datasource
to Loki and run:
```logql
{cluster="3node", namespace="kube-system"} |= "error"
```

Or open a **split view** in Explore:
- Left panel: Prometheus — CPU query
- Right panel: Loki — error logs

Both panels share the same time range. Move the cursor on one panel — the
other highlights the same timestamp. This is the correlation workflow.

**Step C — Verify with kubectl top:**
```bash
kubectl top nodes
# Shows current CPU and memory usage per node
# Should match the Prometheus metrics for the current time
```

---

### Step 11: Production Architecture Note — AWS

This lab uses minikube's `standard` StorageClass and self-hosted components.
In production on AWS EKS, the architecture changes:

```
Storage:
  standard StorageClass (minikube hostPath)
  → gp3 StorageClass (AWS EBS CSI Driver)
  PVC requests gp3 → EBS volume auto-provisioned, attached to the node
  kubectl apply required: aws-ebs-csi-driver addon on EKS

Prometheus:
  Self-hosted Prometheus (Deployment + PVC)
  → Amazon Managed Prometheus (AMP)
  Prometheus remote_write to AMP endpoint
  AMP handles storage, retention, HA
  Auth: EKS IRSA (IAM Roles for Service Accounts)
    - ServiceAccount annotated with IAM role ARN
    - IAM role grants aps:RemoteWrite permission
    - No credentials in pod spec

node-exporter:
  Same DaemonSet — no change needed on EKS

Grafana:
  Self-hosted (Deployment + EBS PVC)
  → Amazon Managed Grafana (AMG) or self-hosted
  AMG: managed authentication (AWS SSO), native AMP datasource
  Self-hosted: add Prometheus datasource pointing to AMP endpoint
    URL: https://aps-workspaces.<region>.amazonaws.com/workspaces/<workspace-id>
    Auth: AWS SigV4 (enabled in Grafana datasource config)

Loki:
  filesystem storage (minikube PVC)
  → S3 object storage
  loki-config storage section:
    object_store: s3
    s3:
      endpoint: s3.us-east-1.amazonaws.com
      bucketnames: my-loki-bucket
      region: us-east-1
  Auth: EKS IRSA — IAM role with s3:PutObject, s3:GetObject on the bucket
```

---

### Step 12: Cleanup

```bash
# Remove Node Metrics dashboard
kubectl delete -f 07-grafana-node-dashboard-cm.yaml

# Remove node-exporter
kubectl delete -f 05-node-exporter-daemonset.yaml

# Remove Prometheus
kubectl delete -f 04-prometheus-deployment.yaml
kubectl delete -f 03-prometheus-pvc.yaml
kubectl delete -f 02-prometheus-configmap.yaml
kubectl delete -f 01-prometheus-rbac.yaml

# Restore Grafana to Lab 01 state (remove Prometheus datasource)
# Either revert 06-grafana-prometheus-ds.yaml or delete and re-apply Lab 01's datasource CM

# To remove everything including Lab 01:
kubectl delete namespace monitoring
```

---

## Common Questions

### Q: Why does node-exporter need `hostPID: true`?
**A:** Without `hostPID`, the container sees only its own PID namespace —
the proc filesystem inside the container shows only the node-exporter
process itself. With `hostPID: true`, the container sees all host PIDs
through `/proc`, giving node-exporter access to system-wide CPU time,
process counts, and per-process resource usage.

### Q: Why does Prometheus use `kubernetes_sd_configs` instead of `static_configs`?
**A:** `static_configs` requires you to list every target IP address
manually. In Kubernetes, pod IPs change every restart. A new node
joining the cluster creates a new node-exporter pod with a new IP.
`kubernetes_sd_configs` queries the Kubernetes API continuously —
new targets are discovered automatically, removed targets are dropped.
Zero manual configuration for new nodes.

### Q: Why does `external_labels` matter if I only have one cluster?
**A:** Even with one cluster, `external_labels: cluster: 3node` is good
practice. It labels every metric with its source, making dashboards
explicit. When you add a second cluster later, you do not need to
change anything in Grafana — the label is already there to filter by.

### Q: What is the difference between MemFree and MemAvailable?
**A:** `MemFree` is physically free memory — genuinely unused. Linux
aggressively uses free memory for disk caching (`Cached`) and I/O
buffers (`Buffers`). These are "used" but can be reclaimed instantly
when a process needs memory. `MemAvailable` is an estimate of how
much memory is available to new processes — it includes `MemFree`
plus reclaimable cache. `MemAvailable` is almost always the right
metric for "how much memory does this system have available."

### Q: How often does Prometheus scrape node-exporter?
**A:** Every `scrape_interval: 15s` by default. This means metric data
points are 15 seconds apart. PromQL `rate()` functions need a time window
at least 2× the scrape interval — `rate(...[30s])` is the minimum,
`rate(...[5m])` is more reliable and smooths out noise.

---

## What You Learned

In this lab, you:
- ✅ Explained why node-exporter needs `hostPID`, `hostNetwork`, and `/host` volume mount
- ✅ Explained Prometheus pull model — GET /metrics on schedule, TSDB storage
- ✅ Explained `kubernetes_sd_configs` — auto-discovery of node-exporter pods
- ✅ Explained relabeling — converting Kubernetes API meta-labels to metric labels
- ✅ Explained `external_labels` — the multi-cluster key on all metrics
- ✅ Deployed node-exporter DaemonSet on all 3 nodes (applying DaemonSet lab skills)
- ✅ Deployed Prometheus with Kubernetes service discovery
- ✅ Verified Prometheus targets are all `up`
- ✅ Added Prometheus datasource to Grafana via ConfigMap update
- ✅ Explored the Node Metrics dashboard — 5 focused panels matching this lab's PromQL concepts
- ✅ Imported the community Node Exporter Full dashboard (ID 1860) via the Grafana import UI
- ✅ Understood the difference between custom (learning) and community (production) dashboards
- ✅ Understood the PromQL query behind each dashboard panel
- ✅ Correlated a metric observation with log evidence in Grafana Explore
- ✅ Understood the AWS production architecture: EBS CSI, AMP, IRSA, SigV4

**Key Takeaway:** Prometheus pulls metrics from node-exporter on a 15-second
cycle. The `cluster` external label is the thread that connects minikube
profiles to a shared Grafana. With both Loki and Prometheus as datasources,
Grafana becomes a single pane of glass: spot an anomaly in metrics, pivot
to logs for the same time window, find the root cause. This is the complete
observability pattern — metrics for detection, logs for diagnosis.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get ds node-exporter` | node-exporter DaemonSet status (DESIRED=3) |
| `kubectl get pods -l app=node-exporter -o wide` | Pods with node placement |
| `kubectl get pods -n monitoring` | All monitoring stack pods |
| `kubectl port-forward -n monitoring svc/prometheus 9090:9090` | Access Prometheus UI |
| `kubectl port-forward pod/node-exporter-<n> 9100:9100` | Access node-exporter metrics directly |
| `curl http://localhost:9090/api/v1/targets` | List Prometheus targets and health |
| `curl http://localhost:9100/metrics` | Raw node-exporter metric output |
| `kubectl top nodes` | Current CPU/memory usage (requires metrics-server) |
| `kubectl rollout restart deployment/grafana -n monitoring` | Restart Grafana after CM change |
| `minikube service grafana -n monitoring --url` | Grafana browser URL |

---

## Troubleshooting

**node-exporter targets showing `down` in Prometheus?**
```bash
# Check node-exporter pods are running
kubectl get pods -l app=node-exporter -o wide
# Verify port 9100 is accessible
kubectl exec <prometheus-pod> -n monitoring -- \
  wget -qO- http://<node-exporter-pod-ip>:9100/metrics | head -5
# Check RBAC — Prometheus needs to discover pods
kubectl auth can-i list pods --as=system:serviceaccount:monitoring:prometheus
```

**Grafana Prometheus datasource test fails?**
```bash
# Verify Prometheus service in monitoring namespace
kubectl get svc -n monitoring prometheus
# Verify Prometheus pod is running and responding
kubectl port-forward -n monitoring svc/prometheus 9090:9090 &
curl http://localhost:9090/-/ready
# Should return: Prometheus Server is Ready.
```

**CPU usage shows 0% or no data?**
```bash
# Check that node-exporter is collecting the metric
curl http://localhost:9100/metrics | grep node_cpu_seconds_total
# Verify the cluster label matches your PromQL filter
kubectl port-forward -n monitoring svc/prometheus 9090:9090 &
curl "http://localhost:9090/api/v1/query?query=node_cpu_seconds_total" | \
  python3 -m json.tool | grep cluster
# Should show: "cluster": "3node"
```

**Dashboard shows "No data" for all panels?**
```bash
# Verify external_labels is set correctly in prometheus.yml
kubectl describe configmap prometheus-config -n monitoring | grep cluster
# Should show: cluster: 3node
# Verify the dashboard $cluster variable has the right value
# In Grafana: open the dashboard → top variable = cluster → should show "3node"
```