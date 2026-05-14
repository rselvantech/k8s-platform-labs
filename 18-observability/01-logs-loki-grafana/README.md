# Logs Pipeline — Fluent Bit → Loki → Grafana

## Lab Overview

This lab builds the complete end-to-end log collection pipeline for your
`3node` minikube cluster. You deploy Loki as the log storage backend, Grafana
as the visualisation layer, and update the Fluent Bit DaemonSet from Lab 03
to forward logs to Loki instead of printing to stdout.

When this lab is complete you will open Grafana in your browser, write LogQL
queries against real Kubernetes logs, and explore a pre-provisioned dashboard
that filters logs by cluster, namespace, and pod — with dashboard variables
that work across multiple minikube profiles.

**Read first:**
`06-observability/00-observability-concepts` covers the full Loki architecture,
LogQL query language, label indexing design, and multi-cluster patterns. This
lab assumes that reading has been done.

**Prerequisite lab:**
`03-daemonsets/03-daemonset-logging-agent` — Fluent Bit DaemonSet must be
deployed and running. This lab modifies its ConfigMap OUTPUT block only.

**What you'll do:**
- Understand Loki's internal components and monolithic deployment mode
- Understand every field in the Loki configuration file
- Deploy Loki in monolithic mode with filesystem storage and a PVC
- Deploy Grafana with auto-provisioned Loki datasource and Kubernetes Logs dashboard
- Update Fluent Bit ConfigMap to ship logs to Loki (one block change)
- Verify the full pipeline: Fluent Bit → Loki ingest → Grafana query
- Write LogQL queries in Grafana Explore — stream selectors, pipeline operators
- Use dashboard variables to filter by cluster, namespace, and pod
- Understand how to add a second minikube profile to the same Grafana

## Prerequisites

**Required Software:**
- Minikube `3node` profile running — 1 control-plane + 2 workers
- kubectl configured for `3node`
- Fluent Bit DaemonSet from `03-daemonset-logging-agent` deployed and healthy
- Browser (Grafana UI)

**Verify before starting:**
```bash
kubectl get ds fluent-bit
# NAME         DESIRED   CURRENT   READY
# fluent-bit   2         2         2

kubectl get nodes
# 3node, 3node-m02, 3node-m03 all Ready
```

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain Loki's internal components: Distributor, Ingester, Querier, Compactor
2. ✅ Explain monolithic vs simple-scalable vs microservices Loki deployment modes
3. ✅ Explain every key field in the Loki configuration file
4. ✅ Deploy Loki and Grafana from plain Kubernetes manifests (no Helm)
5. ✅ Understand Grafana datasource and dashboard auto-provisioning via ConfigMap
6. ✅ Change one Fluent Bit ConfigMap block to ship logs to Loki
7. ✅ Verify the ingest pipeline using Loki's `/ready` and `/metrics` endpoints
8. ✅ Write LogQL stream selectors and log pipeline queries in Grafana Explore
9. ✅ Use dashboard variables (cluster, namespace, pod) to filter log panels
10. ✅ Explain how the `cluster` label enables multi-cluster log viewing in one Grafana
11. ✅ Create a LogQL-based alert rule — query, condition, evaluation interval, labels
12. ✅ Understand alert states: Normal → Pending → Firing, and how silences work

## Versions

| Component | Version | Image |
|-----------|---------|-------|
| Loki | 3.7.1 | `grafana/loki:3.7.1` |
| Grafana OSS | 12.4.2 | `grafana/grafana:12.4.2` |
| Fluent Bit | 3.3 | `fluent/fluent-bit:3.3` (from Lab 03) |

## Directory Structure

```
01-logs-loki-grafana/
└── src/
    ├── 01-monitoring-namespace.yaml       # monitoring namespace
    ├── 02-loki-pvc.yaml                   # PVC for Loki log storage
    ├── 03-loki-configmap.yaml             # Loki configuration (loki.yaml)
    ├── 04-loki-deployment.yaml            # Loki Deployment + ClusterIP Service
    ├── 05-grafana-datasources-cm.yaml     # Grafana datasource auto-provisioning
    ├── 06-grafana-dashboard-cm.yaml       # Kubernetes Logs dashboard JSON
    ├── 07-grafana-deployment.yaml         # Grafana Deployment + NodePort Service
    ├── 08-fluent-bit-configmap-loki.yaml  # Updated Fluent Bit ConfigMap — loki OUTPUT
    └── 09-fluent-bit-rbac.yaml            # Fluent Bit RBAC (if not already applied)
```

---

## Understanding Loki

### Loki Internal Components

Loki is built around a set of internal components that can run as a single
binary (monolithic mode) or as separate processes (scaled modes). Understanding
them clarifies what happens to a log record after Fluent Bit sends it:

```
┌─────────────────────────────────────────────────────────────────────┐
│                       Loki Components                                │
│                                                                      │
│  Fluent Bit                                                         │
│  POST /loki/api/v1/push                                             │
│       │                                                             │
│       ▼                                                             │
│  ┌─────────────┐                                                    │
│  │ Distributor │  Validates incoming log streams                    │
│  │             │  Checks label limits, stream limits               │
│  │             │  Hashes the stream → routes to correct Ingester   │
│  └──────┬──────┘                                                    │
│         │                                                           │
│         ▼                                                           │
│  ┌─────────────┐                                                    │
│  │  Ingester   │  Holds recent logs in memory (WAL)                │
│  │             │  Builds compressed chunks over time               │
│  │             │  Flushes chunks to storage on schedule or size    │
│  └──────┬──────┘                                                    │
│         │  compressed chunks                                        │
│         ▼                                                           │
│  ┌─────────────┐                                                    │
│  │   Storage   │  Chunk store (filesystem in this lab / S3 in prod)│
│  │             │  Index (TSDB — label index only, not content)     │
│  └──────┬──────┘                                                    │
│         │                                                           │
│         ▼                                                           │
│  ┌─────────────┐                                                    │
│  │   Querier   │  Executes LogQL queries                           │
│  │             │  Fetches chunks from storage                      │
│  │             │  Decompresses and scans for matching lines        │
│  └──────┬──────┘                                                    │
│         │                                                           │
│         ▼                                                           │
│  ┌─────────────┐                                                    │
│  │  Compactor  │  Merges small index files into larger ones        │
│  │             │  Applies retention policies                       │
│  │             │  Runs periodically in background                  │
│  └─────────────┘                                                    │
│                                                                      │
│  Query Frontend (in scaled modes):                                  │
│  Receives Grafana queries → splits into time-range sub-queries     │
│  → parallelises across Queriers → merges results                   │
│  Not used in monolithic mode — Querier handles everything directly  │
└─────────────────────────────────────────────────────────────────────┘
```

### Loki Deployment Modes

```
┌──────────────────────────────────────────────────────────────────┐
│  Monolithic (this lab)                                            │
│  All components in one binary / one container                    │
│  Single pod, no horizontal scaling                               │
│  Storage: filesystem (this lab) or object store                  │
│  Suitable: dev, small clusters, < ~50GB logs/day                 │
│  Config: target: all                                             │
├──────────────────────────────────────────────────────────────────┤
│  Simple Scalable                                                  │
│  Two groups: read-path pods + write-path pods                    │
│  Scales read and write independently                             │
│  Suitable: production, moderate log volumes, ~50-500GB logs/day  │
│  Config: target: read | write | backend                          │
├──────────────────────────────────────────────────────────────────┤
│  Microservices                                                    │
│  Each component runs as its own Deployment                       │
│  Fine-grained scaling and resource allocation                    │
│  Suitable: large scale, > ~500GB logs/day                        │
│  Typically deployed via Helm chart                               │
└──────────────────────────────────────────────────────────────────┘
```

### Why Label-Only Indexing

Loki stores two things for each log entry: the stream labels (indexed) and
the log line content (compressed, not indexed). This is the design choice
that makes Loki cheap:

```
ELK (Elasticsearch) approach:
  Log line: "GET /api/users 200 45ms user_id=42"
  Indexed:  GET, /api/users, 200, 45ms, user_id, 42 — every token
  Cost:     large inverted index, expensive storage, slow ingestion at scale
  Benefit:  fast full-text search on any word

Loki approach:
  Log line: "GET /api/users 200 45ms user_id=42" (not indexed — stored as-is)
  Indexed:  {cluster="3node", namespace="default", app="nginx"} — labels only
  Cost:     tiny index, cheap storage, fast ingestion
  Benefit:  fast label filtering, then grep through compressed chunks for content
  Tradeoff: slower arbitrary full-text search (must scan chunk bytes)

The Kubernetes use case fits Loki perfectly:
  You always start by filtering with labels:
    "show me logs from namespace=production, app=api-server"
  Then search the content:
    |= "error" or | json | status >= 500
  You rarely need to search across all logs regardless of source.
```

### LogQL — Query Language

LogQL uses two parts: a stream selector (required) and a log pipeline (optional):

```
─── Stream selector (must include at least one = matcher) ───────────
{cluster="3node"}                         all logs from this cluster
{namespace="production"}                  all production namespace logs
{namespace="production", app="nginx"}     further narrowed
{namespace=~"prod.*"}                     regex match on namespace
{app!="kube-proxy"}                       exclude kube-proxy

─── Log pipeline (chained after |) ──────────────────────────────────
|= "error"              keep lines containing "error" (case-sensitive)
|= "Error"              keep lines containing "Error"
|~ "err|ERROR|Err"      regex — keep lines matching any
!= "health"             drop lines containing "health"
!~ "GET|POST"           regex — drop lines matching any

─── Parsing (structured logs) ───────────────────────────────────────
| json                  parse JSON log line → extract fields
| logfmt                parse logfmt (key=value format)
| pattern               `<ip> - <user> [<ts>] "<method> <path>"`

─── Label filter (after parsing) ────────────────────────────────────
| level = "error"       keep records where parsed field level=error
| status >= 500         keep records where parsed field status>=500
| duration > 1000ms     keep records where duration>1000ms

─── Format (change display) ─────────────────────────────────────────
| line_format "{{.pod_name}}: {{.log}}"   reshape log line display

─── Metric queries (convert log stream to metrics) ──────────────────
rate({namespace="production"} |= "error" [5m])
  → errors per second, 5-minute rate
count_over_time({namespace="production"}[1h])
  → log line count per hour
bytes_over_time({app="nginx"}[10m])
  → bytes ingested per 10 minutes
```

### Multi-Cluster Design — The cluster Label

Every log record that Fluent Bit sends to Loki carries a `cluster` label.
This label is the key to viewing logs from multiple minikube profiles in
one Grafana dashboard:

```
Fluent Bit on 3node cluster:
  [OUTPUT]
      Name   loki
      Labels job=fluent-bit, cluster=3node, ...
      → All streams tagged: {cluster="3node", ...}

Fluent Bit on 5node cluster (future):
  [OUTPUT]
      Name   loki
      Labels job=fluent-bit, cluster=5node, ...
      → All streams tagged: {cluster="5node", ...}

Both send to the same Loki endpoint in the monitoring namespace.

Grafana dashboard variable:
  Name: cluster
  Type: query
  Query: label_values(cluster)   → pulls all unique cluster values from Loki
  → Dropdown shows: [3node, 5node]

Dashboard panel query:
  {cluster="$cluster", namespace="$namespace"}
  → Filters by whatever the user selected in the dropdown
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  default namespace                                           │
│                                                             │
│  Fluent Bit DaemonSet (from Lab 03)                        │
│    worker node 1  →  reads /var/log/containers/*.log       │
│    worker node 2  →  reads /var/log/containers/*.log       │
│                                                             │
│    [OUTPUT] loki                                            │
│      Host: loki.monitoring.svc.cluster.local               │
│      Port: 3100                                            │
│      Labels: job=fluent-bit, cluster=3node                 │
└────────────────────────┬────────────────────────────────────┘
                         │ HTTP POST /loki/api/v1/push
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  monitoring namespace                                        │
│                                                             │
│  Loki 3.7.1 (Deployment)                                   │
│    ClusterIP Service: loki:3100                            │
│    PVC: loki-storage (5Gi, minikube standard StorageClass) │
│    Mode: monolithic (target: all)                          │
│    Storage: filesystem (/loki on the PVC)                  │
│                                                             │
│  Grafana 12.4.2 (Deployment)                               │
│    NodePort Service: grafana:30300                         │
│    Datasource: Loki (auto-provisioned via ConfigMap)       │
│    Dashboard: Kubernetes Logs (auto-provisioned via CM)    │
└─────────────────────────────────────────────────────────────┘
                         │
                         ▼
              Browser → http://<minikube-ip>:30300
              admin / admin
```

---

## Lab Step-by-Step Guide

### Step 1: Understand the Loki Configuration

**03-loki-configmap.yaml:**

```yaml
# Full loki.yaml explained:
auth_enabled: false
# In multi-tenant production, set to true and pass X-Scope-OrgID header.
# false = single-tenant mode (all logs in one tenant) — correct for this lab.

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
# 3100: Fluent Bit sends logs here, Grafana queries here
# 9096: internal component communication (not exposed)

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks   # compressed log chunks stored here
      rules_directory:  /loki/rules    # alert rules stored here
  replication_factor: 1
  # replication_factor: 1 = no replication (single instance)
  # Production: 3 for HA (requires multiple Ingester pods)
  ring:
    kvstore:
      store: inmemory
      # inmemory: component coordination via in-process ring (monolithic mode)
      # Production: consul or etcd for distributed coordination

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100
# Cache query results in memory — avoids re-scanning chunks for repeat queries

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb          # TSDB: the index backend (replaced boltdb in Loki 3.x)
      object_store: filesystem
      schema: v13          # v13: current schema — do not use older versions
      index:
        prefix: index_
        period: 24h        # New index file every 24 hours

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h   # Reject logs older than 7 days
  allow_structured_metadata: true    # Allow Fluent Bit structured_metadata field

ruler:
  alertmanager_url: http://localhost/
# Placeholder — not used in this lab (no Alertmanager deployed)

analytics:
  reporting_enabled: false
# Disable usage reporting to Grafana Labs
```

**Key schema_config fields:**

| Field | Value | Meaning |
|-------|-------|---------|
| `from` | `2024-01-01` | This config applies to logs from this date onwards |
| `store` | `tsdb` | Index backend — TSDB replaces deprecated BoltDB in Loki 3.x |
| `schema` | `v13` | Current label schema — always use latest |
| `period` | `24h` | New index file created daily — easier compaction and retention |

---

### Step 2: Understand Grafana Auto-Provisioning

Grafana supports provisioning datasources and dashboards from files on disk
at startup — no manual UI clicking required. The provisioning files are
mounted from ConfigMaps.

**How provisioning works:**
```
Grafana container starts
  │
  └── reads /etc/grafana/provisioning/datasources/*.yaml
        → creates or updates datasource entries in Grafana's database
      reads /etc/grafana/provisioning/dashboards/*.yaml
        → reads dashboard JSON files from the specified path
        → imports them as dashboards
```

**05-grafana-datasources-cm.yaml:**
```yaml
# Grafana reads this file on startup and creates the Loki datasource
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    access: proxy         # Grafana backend proxies queries to Loki
                          # (browser never talks to Loki directly)
    url: http://loki.monitoring.svc.cluster.local:3100
    isDefault: true
    jsonData:
      maxLines: 1000      # Maximum log lines returned per query
```

**Why `access: proxy`:** Grafana's backend process makes API calls to Loki.
The browser only talks to Grafana. This means Loki's service does not need
to be exposed outside the cluster — `ClusterIP` is sufficient.

---

### Step 3: Understand the Dashboard JSON Structure

**06-grafana-dashboard-cm.yaml:**
The dashboard has three panels:

```
Panel 1 — Log Volume (time series)
  Type:  time series graph
  Query: sum by (namespace) (count_over_time({cluster="$cluster"}[$__interval]))
  Shows: log ingestion rate per namespace over time
  Variable: $cluster → selected by dashboard dropdown

Panel 2 — Log Stream (logs panel)
  Type:  Grafana Logs panel
  Query: {cluster="$cluster", namespace="$namespace", pod=~"$pod"}
  Shows: actual log lines, coloured by level
  Variables: $cluster, $namespace, $pod → all filterable by dropdown

Panel 3 — Error Rate (time series)
  Type:  time series graph
  Query: sum by (pod) (rate({cluster="$cluster", namespace="$namespace"}
           |= "error" [5m]))
  Shows: error log rate per pod over 5-minute windows
  Useful for spotting which pod generates most errors
```

**Dashboard variables:**
```
$cluster   → label_values(cluster)        dropdown of all cluster labels in Loki
$namespace → label_values({cluster="$cluster"}, namespace)  namespaces in that cluster
$pod       → label_values({cluster="$cluster", namespace="$namespace"}, pod)  pods in that ns
```

Each variable queries Loki for the distinct values of that label, filtered
by the upstream variable. Selecting `cluster=3node` narrows `$namespace` to
only namespaces that exist in `3node`. Selecting a namespace narrows `$pod`.

---

### Step 4: Deploy the monitoring namespace

**01-monitoring-namespace.yaml:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    name: monitoring
    purpose: observability
```

```bash
cd 01-logs-loki-grafana/src
kubectl apply -f 01-monitoring-namespace.yaml
```

**Expected output:**
```
namespace/monitoring created
```

```bash
kubectl get namespace monitoring
# NAME         STATUS   AGE
# monitoring   Active   5s
```

---

### Step 5: Deploy Loki Storage (PVC)

**02-loki-pvc.yaml:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: loki-storage
  namespace: monitoring
  labels:
    app: loki
spec:
  # minikube default StorageClass: "standard" — dynamic hostPath provisioning.
  # AWS EKS production: use storageClassName: gp3 with EBS CSI driver.
  storageClassName: standard
  accessModes:
    - ReadWriteOnce    # Single Loki pod reads/writes — correct for monolithic mode
  resources:
    requests:
      storage: 5Gi
      # Sizing: daily_log_volume_GB × retention_days × 0.3 (compression ratio)
```

```bash
kubectl apply -f 02-loki-pvc.yaml
```

**Expected output:**
```
persistentvolumeclaim/loki-storage created
```

```bash
kubectl get pvc -n monitoring
```

**Expected output:**
```
NAME           STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
loki-storage   Pending   ...                                standard       5s
```

`Pending` is expected — the PVC uses minikube's `standard` StorageClass which
provisions dynamically. The PV is created when a pod mounts the PVC.

---

### Step 6: Deploy Loki

**04-loki-deployment.yaml:**
```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki
  namespace: monitoring
  labels:
    app: loki
    version: "3.7.1"
spec:
  replicas: 1                  # Monolithic mode: single replica
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
    spec:
      securityContext:
        fsGroup: 10001          # Volume ownership for /loki mount
        runAsUser: 10001
        runAsGroup: 10001
        runAsNonRoot: true
      containers:
        - name: loki
          image: grafana/loki:3.7.1
          args:
            - -config.file=/etc/loki/loki.yaml
            - -target=all       # monolithic: run all components in this pod
          ports:
            - name: http
              containerPort: 3100    # Fluent Bit pushes here; Grafana queries here
            - name: grpc
              containerPort: 9096    # Internal component communication
          readinessProbe:
            httpGet:
              path: /ready
              port: 3100
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /ready
              port: 3100
            initialDelaySeconds: 60
            periodSeconds: 30
            failureThreshold: 5
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          volumeMounts:
            - name: config
              mountPath: /etc/loki/loki.yaml
              subPath: loki.yaml      # Mount only the config key
            - name: storage
              mountPath: /loki        # PVC mounted here — chunks and index live here
      volumes:
        - name: config
          configMap:
            name: loki-config
        - name: storage
          persistentVolumeClaim:
            claimName: loki-storage
---
# ClusterIP Service — Fluent Bit and Grafana reach Loki via in-cluster DNS:
#   loki.monitoring.svc.cluster.local:3100
# No NodePort needed — Grafana proxies all queries (access: proxy)
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: monitoring
  labels:
    app: loki
spec:
  type: ClusterIP
  selector:
    app: loki
  ports:
    - name: http
      port: 3100
      targetPort: 3100
    - name: grpc
      port: 9096
      targetPort: 9096
```

```bash
kubectl apply -f 03-loki-configmap.yaml
kubectl apply -f 04-loki-deployment.yaml
```

**Expected output:**
```
configmap/loki-config created
deployment.apps/loki created
service/loki created
```

**Watch Loki start:**
```bash
kubectl get pods -n monitoring -w
```

**Expected output:**
```
NAME                   READY   STATUS              RESTARTS   AGE
loki-xxxxxxxxx-xxxxx   0/1     ContainerCreating   0          5s
loki-xxxxxxxxx-xxxxx   0/1     Running             0          15s   ← starting
loki-xxxxxxxxx-xxxxx   1/1     Running             0          25s   ← ready
```

**Verify Loki is healthy:**
```bash
# Port-forward to the Loki HTTP API
kubectl port-forward -n monitoring svc/loki 3100:3100 &

curl http://localhost:3100/ready
# ready

curl http://localhost:3100/metrics | grep loki_build_info
# loki_build_info{branch="HEAD",goversion="go1.23",revision="...",version="3.7.1"} 1

# Stop port-forward
kill %1
```

---

### Step 7: Deploy Grafana

**07-grafana-deployment.yaml:**
```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: monitoring
  labels:
    app: grafana
    version: "12.4.2"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      securityContext:
        fsGroup: 472        # Grafana's default GID
        runAsUser: 472
        runAsGroup: 472
        runAsNonRoot: true
      initContainers:
        # Copy dashboard JSON to the directory Grafana reads at startup.
        # emptyDir volume shared between initContainer and main container.
        - name: copy-dashboards
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              mkdir -p /var/lib/grafana/dashboards
              cp /tmp/dashboards/kubernetes-logs.json /var/lib/grafana/dashboards/
              echo "Dashboards copied"
          volumeMounts:
            - name: dashboard-source
              mountPath: /tmp/dashboards
            - name: dashboard-target
              mountPath: /var/lib/grafana/dashboards
          securityContext:
            runAsUser: 0
      containers:
        - name: grafana
          image: grafana/grafana:12.4.2
          env:
            - name: GF_SECURITY_ADMIN_USER
              value: admin
            - name: GF_SECURITY_ADMIN_PASSWORD
              value: admin
              # Production: use a Secret instead of plain-text env var
            - name: GF_AUTH_ANONYMOUS_ENABLED
              value: "false"
            - name: GF_LOG_LEVEL
              value: warn
          ports:
            - name: http
              containerPort: 3000
          readinessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 30
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          volumeMounts:
            - name: datasources
              mountPath: /etc/grafana/provisioning/datasources
            - name: dashboard-provisioner
              mountPath: /etc/grafana/provisioning/dashboards
            - name: dashboard-target
              mountPath: /var/lib/grafana/dashboards
      volumes:
        - name: datasources
          configMap:
            name: grafana-datasources
            items:
              - key: datasources.yaml
                path: datasources.yaml
        - name: dashboard-provisioner
          configMap:
            name: grafana-dashboard-kubernetes-logs
            items:
              - key: dashboards.yaml
                path: dashboards.yaml
        - name: dashboard-source
          configMap:
            name: grafana-dashboard-kubernetes-logs
            items:
              - key: kubernetes-logs.json
                path: kubernetes-logs.json
        - name: dashboard-target
          emptyDir: {}
---
# NodePort Service — browser access at http://<minikube-ip>:30300
# Production: use LoadBalancer or Ingress instead of NodePort
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: monitoring
  labels:
    app: grafana
spec:
  type: NodePort
  selector:
    app: grafana
  ports:
    - name: http
      port: 3000
      targetPort: 3000
      nodePort: 30300
```

```bash
kubectl apply -f 05-grafana-datasources-cm.yaml
kubectl apply -f 06-grafana-dashboard-cm.yaml
kubectl apply -f 07-grafana-deployment.yaml
```

**Expected output:**
```
configmap/grafana-datasources created
configmap/grafana-dashboard-kubernetes-logs created
deployment.apps/grafana created
service/grafana created
```

**Watch Grafana start:**
```bash
kubectl get pods -n monitoring -w
```

**Expected: both loki and grafana pods showing `1/1 Running`**

**Get the Grafana URL:**
```bash
minikube service grafana -n monitoring --url --profile 3node
```

**Expected output:**
```
http://192.168.49.2:30300
```

Open this URL in your browser. Login: `admin` / `admin`. Grafana prompts
you to change the password — skip for now (click "Skip").

**Verify the Loki datasource was auto-provisioned:**

Navigate to: **Connections → Data sources** (left sidebar)

You should see `Loki` listed as the default datasource, pointing to
`http://loki.monitoring.svc.cluster.local:3100`.

Click `Loki` → scroll down → click **Save & test**.

**Expected:** `Data source connected and labels found.`

**Verify the dashboard was auto-provisioned:**

Navigate to: **Dashboards** (left sidebar)

You should see **Kubernetes Logs** in the list.

---

### Step 8: Apply Fluent Bit RBAC (if not already from Lab 03)

If you have not completed `03-daemonsets/03-daemonset-logging-agent`, apply
the RBAC now. If the DaemonSet from that lab is already running, skip this step.

```bash
# Check first — if these exist, skip:
kubectl get serviceaccount fluent-bit 2>/dev/null && echo "RBAC already applied"
```

**09-fluent-bit-rbac.yaml:**
```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluent-bit
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluent-bit
rules:
  - apiGroups: [""]
    resources:
      - pods
      - namespaces
      - nodes
      - nodes/proxy
    verbs:
      - get
      - list
      - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fluent-bit
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluent-bit
subjects:
  - kind: ServiceAccount
    name: fluent-bit
    namespace: default
```

```bash
# Only apply if not already present:
kubectl apply -f 09-fluent-bit-rbac.yaml
```

---

### Step 9: Update Fluent Bit ConfigMap — Connect to Loki

This is the single change that connects the logging pipeline. The Fluent Bit
ConfigMap's `[OUTPUT]` block changes from `stdout` to `loki`:

**08-fluent-bit-configmap-loki.yaml:**

```
Before (Lab 03 — stdout):          After (this lab — Loki):
──────────────────────────         ────────────────────────────────────────
[OUTPUT]                           [OUTPUT]
    Name   stdout                      Name   loki
    Match  *                           Match  *
    Format json                        Host   loki.monitoring.svc.cluster.local
                                       Port   3100
                                       Labels job=fluent-bit, cluster=3node
                                       Structured_Metadata pod=$kubernetes['pod_name']
                                       Auto_Kubernetes_Labels on
```

**New OUTPUT field explanation:**

| Field | Value | Meaning |
|-------|-------|---------|
| `Name` | `loki` | Built-in Loki output plugin (official, not deprecated grafana-loki) |
| `Host` | `loki.monitoring.svc.cluster.local` | Loki service DNS — in-cluster resolution |
| `Port` | `3100` | Loki HTTP ingest port |
| `Labels` | `job=fluent-bit, cluster=3node` | Fixed labels on all streams. `cluster=3node` is the multi-cluster key |
| `Structured_Metadata` | `pod=$kubernetes['pod_name']` | Adds pod name as structured metadata (Loki 3.x feature) — high-cardinality values here instead of labels |
| `Auto_Kubernetes_Labels` | `on` | Automatically adds all Kubernetes labels (namespace, pod, container) as Loki stream labels |

**Apply the update:**
```bash
kubectl apply -f 08-fluent-bit-configmap-loki.yaml
```

**Expected output:**
```
configmap/fluent-bit-config configured
```

**Restart the DaemonSet to pick up the new config:**
```bash
kubectl rollout restart daemonset/fluent-bit
kubectl rollout status daemonset/fluent-bit
```

**Expected output:**
```
Waiting for daemon set "fluent-bit" rollout to finish: 1 out of 2 new pods have been updated...
daemon set "fluent-bit" successfully rolled out
```

**Verify Fluent Bit is now sending to Loki (not stdout):**
```bash
kubectl logs -l app=fluent-bit --tail=10
```

After the restart, `kubectl logs` will show Fluent Bit's own startup messages
only — no more JSON log records. Those records are now going to Loki.

---

### Step 10: Verify Logs Are Reaching Loki

**Check Loki ingest metrics:**
```bash
kubectl port-forward -n monitoring svc/loki 3100:3100 &

# Query Loki for received stream count
curl -s "http://localhost:3100/loki/api/v1/labels" | python3 -m json.tool
```

**Expected output:**
```json
{
    "status": "200",
    "data": [
        "app",
        "cluster",
        "container",
        "filename",
        "job",
        "namespace",
        "node_name",
        "pod"
    ]
}
```

The presence of `cluster`, `namespace`, `pod`, `app` labels confirms Fluent
Bit is successfully shipping records with Kubernetes metadata to Loki.

```bash
# Query the most recent log entry
curl -s "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={cluster="3node"}' \
  --data-urlencode "start=$(date -d '5 minutes ago' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode "limit=1" \
  | python3 -m json.tool | head -30
```

**Expected output (abbreviated):**
```json
{
    "status": "success",
    "data": {
        "resultType": "streams",
        "result": [
            {
                "stream": {
                    "app": "kube-proxy",
                    "cluster": "3node",
                    "namespace": "kube-system",
                    "pod": "kube-proxy-xxxxx"
                },
                "values": [
                    ["1705312867123456789", "I0115 09:41:07 Syncing..."]
                ]
            }
        ]
    }
}
```

The stream labels (`cluster`, `namespace`, `pod`, `app`) are exactly what
appears in the Grafana dashboard query selectors.

```bash
kill %1  # stop port-forward
```

---

### Step 11: Explore Logs in Grafana — Explore Mode

Navigate to **Explore** in the left sidebar (compass icon).

Ensure the datasource dropdown at the top shows **Loki**.

**Query 1 — All logs from the cluster:**
```logql
{cluster="3node"}
```
Click **Run query** (or press Shift+Enter).

You will see a log volume graph at the top and raw log lines below.
Lines are colour-coded by log level if Loki detected level labels.

**Query 2 — Filter by namespace:**
```logql
{cluster="3node", namespace="kube-system"}
```
Only kube-system logs. Notice the query runs faster — fewer streams to scan.

**Query 3 — Filter by content — find errors:**
```logql
{cluster="3node"} |= "error"
```
All log lines from any pod containing "error" (case-sensitive).

**Query 4 — Regex content filter:**
```logql
{cluster="3node", namespace="default"} |~ "error|Error|ERROR"
```
Case-insensitive error lines from the default namespace.

**Query 5 — Parse structured JSON logs:**
```logql
{cluster="3node", namespace="default"}
| json
| level = "error"
```
If any pods in `default` emit JSON logs, this extracts the `level` field
and filters to errors only. Try this against the Fluent Bit pods themselves.

**Query 6 — Error rate metric query:**
```logql
sum by (namespace) (
  rate({cluster="3node"} |= "error" [5m])
)
```
This converts logs to a time series — errors per second per namespace over
a 5-minute window. Switch the visualization to **Time series** to see the graph.

---

### Step 12: Use the Kubernetes Logs Dashboard

Navigate to **Dashboards → Kubernetes Logs**.

**Dashboard variables at the top:**
- `cluster` — select `3node` from the dropdown
- `namespace` — select any namespace (e.g. `kube-system`)
- `pod` — select a specific pod or leave as `.*` (all)

**Panel 1 — Log Volume:**
Bar chart showing log ingestion rate per namespace. Taller bars = more active
namespaces. Useful for spotting unusual log volume spikes.

**Panel 2 — Log Stream:**
The actual log lines. Filter using the variables above. Use the search bar
at the top of this panel for additional content filtering. Click any log
line to expand it and see all parsed fields.

**Panel 3 — Error Rate:**
Time series showing error log rate per pod. A spike here means a pod is
suddenly generating many error lines — a useful first signal before drilling
into logs.

**Try this workflow:**
1. Set `namespace=kube-system`, `pod=.*` — see all system logs
2. Notice which pod has the highest error rate in Panel 3
3. Set `pod=<that pod name>` in the variable
4. Panel 2 now shows only that pod's logs — find the specific error

---

### Step 13: Verify the Multi-Cluster Label Design

The `cluster=3node` label is in every stream. Verify it appears in Grafana:

In Explore, run:
```logql
{cluster="3node"}
```

Click any log line to expand it. In the labels section you should see:
```
cluster:   3node
namespace: kube-system
pod:       kube-proxy-xxxxx
app:       kube-proxy
```

**How to add a second minikube profile:**

On the second profile (`5node`), deploy the same Fluent Bit DaemonSet but
with `cluster=5node` in the Loki output labels:
```
Labels job=fluent-bit, cluster=5node
```

Point it to the same Loki endpoint (requires network connectivity between
minikube profiles, or use minikube tunnel / NodePort). After deploying:

In Grafana → Explore:
```logql
{cluster=~"3node|5node"}
```

Both clusters' logs appear in the same Explore view. In the dashboard,
the `$cluster` dropdown adds `5node` as an option — select it to switch
the entire dashboard to the second cluster's logs.

---

### Step 14: Create an Alert Rule — Log Error Rate

Grafana Alerting allows you to define rules that fire when a LogQL metric
query exceeds a threshold. This step creates one alert rule that fires when
the error log rate across the cluster exceeds a defined threshold for 5 minutes.

**Grafana Alerting concepts:**

```
Alert Rule
  └── Query       — a LogQL or PromQL expression evaluated periodically
  └── Condition   — threshold that triggers the alert (e.g. > 0.1 errors/sec)
  └── Evaluation  — how often the query runs and how long condition must hold
  └── Labels      — key=value pairs used to route the alert
  └── Annotations — human-readable context added to the alert notification

Alert States:
  Normal    → condition not met
  Pending   → condition met but not yet for the full "for" duration
  Firing    → condition met for the full "for" duration — alert is active
  NoData    → query returned no data (treated as alert by default)
  Error     → query execution failed

Contact Point:
  Where the alert notification goes (email, Slack, PagerDuty, webhook)
  Not configured in this lab — the alert fires but is only visible in Grafana UI

Notification Policy:
  Routes firing alerts to contact points based on label matchers
  Default policy: send all alerts to the default contact point
```

**Navigate to Grafana Alerting:**

In the Grafana left sidebar → **Alerting** → **Alert rules** → **New alert rule**

**Configure the alert rule:**

**Section 1 — Query and alert condition:**

Set the datasource to **Loki**.

Enter this LogQL expression in the query box:
```logql
sum(rate({cluster="3node"} |~ "(?i)error" [5m]))
```

This computes: total error log lines per second across all pods in the
`3node` cluster, evaluated over a 5-minute window.

Under **Expressions**, set the threshold condition:
- Expression type: **Threshold**
- IS ABOVE: `0.05`  ← fires when error rate exceeds 0.05 lines/second
  (adjust to a value that makes sense for your cluster's current log volume)

**Section 2 — Alert evaluation behaviour:**

- **Folder**: `Kubernetes` (same folder as the dashboards)
- **Evaluation group**: `log-alerts` (create new group)
- **Evaluate every**: `1m`  ← query runs every 1 minute
- **for**: `5m`  ← condition must hold for 5 minutes before Firing
  (prevents noise from transient spikes)

**Section 3 — Labels and annotations:**

Add labels to identify this alert:
- `severity` = `warning`
- `cluster` = `3node`
- `team` = `platform`

Add annotations for human context:
- `summary` = `Elevated error log rate in cluster 3node`
- `description` = `Error log rate is {{ $values.B.Value | humanizePercentage }} above threshold. Check the Kubernetes Logs dashboard for details.`

Click **Save rule and exit**.

**Verify the alert rule was created:**

Navigate to **Alerting → Alert rules**. You should see `log-error-rate-high`
in the `Kubernetes/log-alerts` group.

**Watch the alert state:**

```bash
# The alert state cycles through Normal → Pending → Firing
# based on your cluster's actual error log volume.
# If the threshold is too high, the alert stays Normal.
# Lower the threshold to 0.001 to see it fire on any error log:

# In Grafana: edit the alert rule, change threshold to 0.001, save
# Refresh the Alert rules page every 60 seconds — watch state change to Pending, then Firing
```

**Understanding the firing state:**

When the alert fires, Grafana displays it as **Firing** (red) in the Alert
rules list. Without a contact point configured, no notification is sent
externally — the alert is visible only in the Grafana UI. In production:

```
Contact Points (Grafana → Alerting → Contact points):
  Slack webhook   → posts to #alerts channel
  PagerDuty key   → creates an incident
  Email SMTP      → sends to ops@example.com
  OpsGenie        → creates an OpsGenie alert
  Webhook         → HTTP POST to any endpoint

Notification Policy (Grafana → Alerting → Notification policies):
  Default policy: route all alerts to default contact point
  Custom matchers: severity=critical → PagerDuty
                   severity=warning  → Slack only
```

**Create a silence (suppress the alert during maintenance):**

Navigate to **Alerting → Silences → Add silence**:
- Start: now
- Duration: 1h
- Matchers: `cluster=3node` + `severity=warning`
- Comment: `Lab cleanup — suppressing alerts`

A silence suppresses matching alerts for the specified duration without
deleting the rule. Useful during planned maintenance windows.

---

### Step 15: Cleanup

```bash
# Remove Fluent Bit components (update configmap back if you want lab 03 behaviour)
kubectl delete -f 08-fluent-bit-configmap-loki.yaml
# Apply the original stdout configmap from lab 03 to restore
# kubectl apply -f ../../../03-daemonsets/03-daemonset-logging-agent/src/fluent-bit-configmap.yaml
# kubectl rollout restart daemonset/fluent-bit

# Remove monitoring stack
kubectl delete -f 07-grafana-deployment.yaml
kubectl delete -f 06-grafana-dashboard-cm.yaml
kubectl delete -f 05-grafana-datasources-cm.yaml
kubectl delete -f 04-loki-deployment.yaml
kubectl delete -f 03-loki-configmap.yaml
kubectl delete -f 02-loki-pvc.yaml
kubectl delete -f 01-monitoring-namespace.yaml
```

> **Note:** Deleting the namespace removes all resources inside it including
> the PVC. The PV data is lost when the PVC is deleted in minikube.

---

## Common Questions

### Q: Why does Loki use `auth_enabled: false`?
**A:** In multi-tenant production, each tenant's logs are isolated by
a tenant ID passed in the `X-Scope-OrgID` HTTP header. `auth_enabled: false`
puts Loki in single-tenant mode — all logs go to one tenant called `fake`.
For a single-cluster lab this is correct. In production with multiple teams,
set `auth_enabled: true` and configure tenant routing in Fluent Bit.

### Q: Why use `structured_metadata` for pod name instead of a label?
**A:** Labels in Loki are indexed — they should have low cardinality. Pod
names are high-cardinality (change every deployment, hundreds of pods).
Putting pod names in labels would bloat the index. `structured_metadata`
attaches values to individual log entries without indexing them. You can
still filter by them, but the index stays small.

### Q: What happens to logs collected before Loki was running?
**A:** Fluent Bit tracks its read position in `/var/log/flb_kube.db`. When
it reconnects to Loki after a restart, it resumes from where it left off
and ships the buffered logs. Logs from before Fluent Bit was deployed are
not collected — only from the moment Fluent Bit first reads the log file.

### Q: How do I set a retention policy to delete old logs?
**A:** In the Loki config:
```yaml
limits_config:
  retention_period: 168h   # Keep logs for 7 days (requires compactor)
compactor:
  retention_enabled: true
  delete_request_cancel_period: 24h
```
The Compactor runs the retention job periodically. For this lab, no
retention is configured — logs accumulate until the PVC fills or you
delete the namespace.

### Q: Why is the Grafana datasource `access: proxy` and not `access: direct`?
**A:** `access: direct` means the browser would make requests directly to
Loki's URL. In Kubernetes, Loki's ClusterIP service is not reachable from
outside the cluster. `access: proxy` means Grafana's backend process (which
runs inside the cluster) makes the requests — the browser only talks to
Grafana's NodePort service.

---

## What You Learned

In this lab, you:
- ✅ Understood Loki's five internal components and what each does
- ✅ Understood monolithic vs simple-scalable vs microservices deployment modes
- ✅ Explained every key field in the Loki configuration file
- ✅ Deployed Loki with filesystem storage backed by a PVC
- ✅ Deployed Grafana with auto-provisioned datasource and dashboard via ConfigMaps
- ✅ Changed one Fluent Bit ConfigMap block to ship logs to Loki
- ✅ Verified the ingest pipeline using Loki's REST API
- ✅ Wrote LogQL stream selectors, content filters, and metric queries in Explore
- ✅ Used the Kubernetes Logs dashboard with cluster/namespace/pod variables
- ✅ Understood why the `cluster` label enables multi-cluster viewing
- ✅ Understood why pod names use structured_metadata instead of stream labels
- ✅ Created a LogQL-based Grafana alert rule — error rate threshold, evaluation interval, labels
- ✅ Understood alert states (Normal → Pending → Firing), contact points, notification policies, and silences

**Key Takeaway:** The Fluent Bit → Loki → Grafana pipeline has exactly three
configuration touchpoints: the Fluent Bit OUTPUT block (send to Loki), the
Loki config file (schema and storage), and Grafana's provisioning ConfigMaps
(datasource + dashboard). Understanding each piece makes the entire pipeline
debuggable from first principles.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get pods -n monitoring` | Check Loki and Grafana pod status |
| `kubectl logs -n monitoring <loki-pod>` | Loki startup and ingest logs |
| `kubectl logs -n monitoring <grafana-pod>` | Grafana startup and provisioning logs |
| `kubectl port-forward -n monitoring svc/loki 3100:3100` | Access Loki API locally |
| `curl http://localhost:3100/ready` | Loki health check |
| `curl http://localhost:3100/loki/api/v1/labels` | List all label names in Loki |
| `minikube service grafana -n monitoring --url` | Get Grafana browser URL |
| `kubectl rollout restart daemonset/fluent-bit` | Restart Fluent Bit after ConfigMap change |
| `kubectl rollout status daemonset/fluent-bit` | Watch restart progress |

---

## Troubleshooting

**Loki pod stuck in Pending?**
```bash
kubectl describe pod -n monitoring <loki-pod>
# Events: Look for PVC binding failure
kubectl get pvc -n monitoring
# If Pending: minikube storage provisioner may not be running
minikube addons enable default-storageclass --profile 3node
minikube addons enable storage-provisioner --profile 3node
```

**Grafana datasource test fails: "connection refused"?**
```bash
# Verify Loki pod is Running and Ready
kubectl get pods -n monitoring -l app=loki
# Verify Loki service exists in monitoring namespace
kubectl get svc -n monitoring loki
# Verify DNS resolution — exec into Grafana pod
kubectl exec -n monitoring deployment/grafana -- \
  curl -s http://loki.monitoring.svc.cluster.local:3100/ready
```

**Loki shows labels but no log lines in Grafana Explore?**
```bash
# Check Fluent Bit is restarted with loki OUTPUT
kubectl get pods -l app=fluent-bit
# Verify Fluent Bit can reach Loki
kubectl exec <fluent-bit-pod> -- \
  curl -s http://loki.monitoring.svc.cluster.local:3100/ready
# Check Fluent Bit logs for Loki output errors
kubectl logs <fluent-bit-pod> | grep -i "loki\|error\|warn"
```

**Dashboard shows "No data"?**
```bash
# Verify the cluster variable matches your label
# In Grafana Explore, run: {cluster="3node"}
# If no results, the cluster label might not match — check Fluent Bit config
kubectl describe configmap fluent-bit-config | grep cluster
# Should show: cluster=3node in the Labels field
```