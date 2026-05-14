# DaemonSet Logging Agent — Fluent Bit in Production Pattern

## Lab Overview

This lab applies everything from `01-basic-daemonset` and
`02-daemonset-node-targeting` to a real infrastructure workload: a Fluent Bit
log collection agent deployed as a DaemonSet.

DaemonSet mechanics are not re-taught here — refer to the earlier labs when
you need a refresher on update strategies, node targeting, or the reconcile
loop. This lab focuses on what makes a real-world DaemonSet different from the
nginx demos: it has application configuration externalised in a ConfigMap, it
needs RBAC permissions to call the Kubernetes API, it mounts the node's log
filesystem read-only, and it exposes a health endpoint that the readiness probe
checks.

Fluent Bit is the industry-standard choice for node-level log collection. It
runs on every node (DaemonSet), reads container log files from the node
filesystem, enriches each record with Kubernetes metadata (pod name, namespace,
labels), and forwards to a centralised backend. At 1 MB memory footprint it is
purpose-built for the DaemonSet role — one instance per node, always running,
minimal resource overhead.

> **Scope boundary:** In this lab Fluent Bit collects and parses logs then
> prints enriched records to its own stdout — visible via `kubectl logs`.
> No backend is configured here. The complete end-to-end pipeline —
> **Fluent Bit → Loki → Grafana** with multi-cluster dashboards — is built
> in **`06-observability/01-logs-loki-grafana`**. Read
> **`06-observability/00-observability-concepts`** for the full Fluent Bit
> architecture, Fluentd vs Fluent Bit comparison, and observability stack
> design before starting those labs.

**What you'll do:**
- Understand the Fluent Bit pipeline: Input → Parser → Filter → Output
- Understand why Fluent Bit is chosen over Fluentd for the node-agent role
- Externalise pipeline configuration in a ConfigMap — understand every field
- Create a ServiceAccount and RBAC for the Kubernetes metadata filter
- Deploy the DaemonSet targeting worker nodes only (applying Lab 02 skills)
- Verify one pod per worker node using `kubectl get pods -o wide`
- Read enriched JSON log records with Kubernetes metadata from `kubectl logs`
- Use the Fluent Bit HTTP health endpoint as a readiness probe target
- Understand what changes in the ConfigMap to connect to a real Loki backend
- Perform a rolling update to the DaemonSet (applying Lab 01 skills)

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control-plane + 2 worker nodes
- kubectl installed and configured

**Required prior labs:**
- **REQUIRED:** `01-basic-daemonset` — DaemonSet mechanics, update strategies
- **REQUIRED:** `02-daemonset-node-targeting` — nodeSelector, tolerations
- **RECOMMENDED:** `06-observability/00-observability-concepts` — Fluent Bit
  architecture, Fluentd vs Fluent Bit, Loki, multi-cluster design

**Verify your cluster:**
```bash
kubectl get nodes
# NAME        STATUS   ROLES           AGE
# 3node       Ready    control-plane
# 3node-m02   Ready    <none>
# 3node-m03   Ready    <none>
```

**Apply the control-plane taint (minikube does not set this by default):**
```bash
# Production clusters (EKS, kubeadm) taint the control-plane automatically.
# minikube does not — apply it manually so these demos match production behaviour.
kubectl taint node 3node node-role.kubernetes.io/control-plane:NoSchedule
# Verify:
kubectl describe node 3node | grep Taints
# Expected: Taints: node-role.kubernetes.io/control-plane:NoSchedule
```

> This taint is assumed to exist throughout all three DaemonSet labs.
> Without it, DESIRED=3 even without a toleration — which masks the
> behaviour the labs demonstrate.

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain the Fluent Bit pipeline stages and what each one does
2. ✅ Explain why Fluent Bit is used at the node level instead of Fluentd
3. ✅ Explain why pipeline config lives in a ConfigMap, not the container image
4. ✅ Explain why the DaemonSet needs a ServiceAccount with RBAC
5. ✅ Deploy the logging agent DaemonSet on worker nodes only
6. ✅ Read enriched log records — identify every metadata field added by the filter
7. ✅ Use the Fluent Bit HTTP health endpoint to verify pipeline status
8. ✅ Identify exactly which line in the ConfigMap changes to connect to Loki
9. ✅ Perform a rolling update to the logging agent
10. ✅ Clean up all resources in the correct order

## Directory Structure

```
03-daemonset-logging-agent/
└── src/
    ├── fluent-bit-rbac.yaml          # ServiceAccount + ClusterRole + ClusterRoleBinding
    ├── fluent-bit-configmap.yaml     # Fluent Bit pipeline configuration
    └── fluent-bit-daemonset.yaml     # DaemonSet — workers only, stdout output
```

---

## Understanding Fluent Bit

### Why kubectl logs Is Not Enough in Production

Every container writes to stdout/stderr. The container runtime (containerd
in minikube) captures these and writes them to files on the node:

```
Node filesystem — /var/log/containers/
  nginx-abc123_default_nginx-sha256def.log
  kube-proxy-xyz_kube-system_kube-proxy-sha256abc.log
  ... one log file per running container, on every node
```

`kubectl logs` reads these files on demand. In production this breaks down:

```
Problem 1 — No history after pod deletion
  Pod crashes → replaced by new pod → old logs gone forever
  Rolling update → old pod terminated → its logs gone

Problem 2 — No cross-pod search
  Error hits 1 in 10 requests across 30 pods
  You would manually kubectl logs each of 30 pods

Problem 3 — No retention
  Node disk fills → container runtime rotates log files
  Old data overwritten, never stored elsewhere

Problem 4 — No correlation
  Cannot ask: "all errors across the entire cluster, 14:30–14:35 yesterday"

Solution:
  A process on every node reads log files continuously, enriches them
  with context, and ships them to a central store.
  → That process is Fluent Bit running as a DaemonSet.
```

### Fluentd vs Fluent Bit — The Node-Agent Decision

Both tools come from the same CNCF project and share the same pipeline model.
They serve different roles:

| | Fluentd | Fluent Bit |
|---|---------|-----------|
| **Language** | Ruby + C extensions | Pure C |
| **Memory** | ~40 MB | ~1 MB |
| **CPU overhead** | Higher — Ruby GIL | Minimal |
| **Plugin count** | 1,000+ | ~100 |
| **Kubernetes filter** | Separate plugin | Built-in |
| **Config format** | Ruby DSL | INI sections |
| **Best role** | Central aggregator | Node-level collector |
| **DaemonSet fit** | ❌ Too heavy per node | ✅ Designed for this |

**The production pattern:**
```
Every node (DaemonSet):
  Fluent Bit  — 1 MB, reads node logs, enriches, forwards
      │
      ▼ (optional for complex routing / fan-out)
Central aggregator (Deployment, 1-3 replicas):
  Fluentd  — complex transformation, multiple backends
      │
      ▼
Backend:
  Loki / Elasticsearch / CloudWatch / Splunk
```

In this lab and in `06-observability/01-logs-loki-grafana`, Fluent Bit talks
directly to Loki — no Fluentd aggregator needed for a single backend.

### The Fluent Bit Pipeline — Four Stages

Every log record flows through these stages in order:

```
┌────────────────────────────────────────────────────────────────────┐
│                      Fluent Bit Pipeline                            │
│                                                                     │
│  ┌─────────┐    ┌─────────┐    ┌──────────┐    ┌───────────────┐  │
│  │  INPUT  │───▶│ PARSER  │───▶│  FILTER  │───▶│    OUTPUT     │  │
│  └─────────┘    └─────────┘    └──────────┘    └───────────────┘  │
│                                                                     │
│  INPUT   tail                                                       │
│    reads /var/log/containers/*.log from the node filesystem        │
│    tags each record: kube.<namespace>.<pod>.<container>            │
│    tracks read position per file — survives pod restarts           │
│                                                                     │
│  PARSER  cri                                                        │
│    containerd writes logs in CRI format:                           │
│    2024-01-15T09:41:07Z stdout F actual log message here           │
│    → extracts: time, stream (stdout/stderr), log (the message)     │
│                                                                     │
│  FILTER  kubernetes                                                 │
│    calls Kubernetes API to enrich each record:                     │
│    + pod_name, namespace_name, container_name                      │
│    + node_name, pod labels, pod annotations                        │
│    requires: ServiceAccount + RBAC (get/list/watch on pods)        │
│                                                                     │
│  OUTPUT  stdout (this lab)                                          │
│    prints enriched JSON records to Fluent Bit's own stdout         │
│    readable with: kubectl logs <pod>                               │
│                                                                     │
│  OUTPUT  loki (06-observability/01-logs-loki-grafana)              │
│    one line change in ConfigMap — ships records to Loki backend    │
└────────────────────────────────────────────────────────────────────┘
```

**A fully processed log record — what the pipeline produces:**
```json
{
  "date": 1705312867.123,
  "stream": "stdout",
  "log": "10.244.1.1 - GET /api/users HTTP/1.1 200 45ms",
  "kubernetes": {
    "pod_name":        "nginx-deploy-abc123-def456",
    "namespace_name":  "default",
    "container_name":  "nginx",
    "node_name":       "3node-m02",
    "labels":          { "app": "nginx" },
    "annotations":     {}
  }
}
```

Every log line from every container on the node, enriched with full
Kubernetes context. In Loki you query:
`{namespace="default", app="nginx"} |= "error"` — all errors across all
pods and nodes, any time range.

---

## Why Each Design Decision Was Made

Before reading the YAML, understand why it is structured this way:

```
Decision: ConfigMap for pipeline config (not baked into image)
Reason:   Change the output destination (stdout → Loki) without
          rebuilding or changing the image. Update the ConfigMap,
          roll the DaemonSet. Config and code are separate.

Decision: ServiceAccount + RBAC
Reason:   The kubernetes filter calls the Kubernetes API to look up
          pod and namespace metadata. Without RBAC permission, these
          calls return 403 Forbidden — the filter runs but produces
          no Kubernetes metadata in the output records.

Decision: hostPath volumes (read-only)
Reason:   The log files are on the NODE's filesystem, not inside a
          container or PVC. Fluent Bit must mount the node's /var/log
          directly to read them. read-only because the agent never
          writes to the node — it only reads.

Decision: Workers only (no control-plane toleration)
Reason:   Application workloads run on worker nodes. The control-plane
          runs system components whose logs are already captured by
          kube-system DaemonSets. Keeping the logging agent on workers
          focuses it on application log collection.
          (Applying 02-daemonset-node-targeting — Approach A)

Decision: Readiness probe on HTTP health endpoint
Reason:   Fluent Bit exposes /api/v1/health at port 2020. Probing this
          confirms not just that the container is alive (Running) but
          that the Fluent Bit service is initialised and processing.
          Without this probe, pods show Ready before the pipeline is
          actually running. (See 04-pod-deep-dive/03-health-probes)

Decision: stdout output in this lab
Reason:   Makes the pipeline observable without requiring a backend.
          kubectl logs shows every processed record — you can verify
          parsing and enrichment work correctly before connecting a
          real backend. One line in the ConfigMap changes it to Loki.
```

---

## Lab Step-by-Step Guide

### Step 1: Understand the RBAC Manifest

**fluent-bit-rbac.yaml:**
```yaml
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

**Why `ClusterRole` and not `Role`:**
The Fluent Bit kubernetes filter looks up pods across all namespaces —
not just the namespace where the DaemonSet runs. A `Role` is
namespace-scoped. A `ClusterRole` grants permission cluster-wide.
The filter needs to resolve pod metadata for any container whose logs
it collects — those containers can be in any namespace.

**Resources and why each is needed:**

| Resource | Why needed |
|----------|-----------|
| `pods` | Look up pod name, labels, annotations, owner references |
| `namespaces` | Look up namespace labels and annotations |
| `nodes` | Look up node-level metadata |
| `nodes/proxy` | Required in some Kubernetes versions for kubelet API access |

---

### Step 2: Understand the ConfigMap — Every Field

**fluent-bit-configmap.yaml:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: default
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush         1
        Log_Level     info
        Daemon        off
        Parsers_File  /fluent-bit/etc/parsers.conf
        HTTP_Server   On
        HTTP_Listen   0.0.0.0
        HTTP_Port     2020

    [INPUT]
        Name              tail
        Tag               kube.*
        Path              /var/log/containers/*.log
        Parser            cri
        DB                /var/log/flb_kube.db
        Mem_Buf_Limit     5MB
        Skip_Long_Lines   On
        Refresh_Interval  10

    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Merge_Log           On
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On

    [OUTPUT]
        Name   stdout
        Match  *
        Format json
```

**`[SERVICE]` fields:**

| Field | Value | Meaning |
|-------|-------|---------|
| `Flush` | `1` | Flush buffered records to output every 1 second |
| `Log_Level` | `info` | Fluent Bit's own log verbosity (`debug` for troubleshooting) |
| `Daemon` | `off` | Run in foreground — required for containers |
| `Parsers_File` | path | Built-in parsers file inside the container image |
| `HTTP_Server` | `On` | Expose health + metrics endpoint — required by readiness probe |
| `HTTP_Listen` | `0.0.0.0` | Listen on all interfaces inside the container |
| `HTTP_Port` | `2020` | Port for `/api/v1/health` and `/api/v1/metrics` |

**`[INPUT] tail` fields:**

| Field | Value | Meaning |
|-------|-------|---------|
| `Name` | `tail` | Tail plugin — watches files for new lines |
| `Tag` | `kube.*` | Tag prefix for all records. `*` expands to the file path which encodes pod name and namespace — the kubernetes filter uses this |
| `Path` | `/var/log/containers/*.log` | All container log files on this node |
| `Parser` | `cri` | Parse CRI log format (containerd). Extracts: `time`, `stream`, `log` |
| `DB` | `/var/log/flb_kube.db` | SQLite file tracking read offset per log file. Survives pod restarts — no duplicate or missed records |
| `Mem_Buf_Limit` | `5MB` | Maximum memory for buffering before backpressure |
| `Skip_Long_Lines` | `On` | Truncate and skip lines over the buffer limit instead of crashing |
| `Refresh_Interval` | `10` | Seconds between scanning for new log files |

**`[FILTER] kubernetes` fields:**

| Field | Value | Meaning |
|-------|-------|---------|
| `Name` | `kubernetes` | Built-in Kubernetes metadata enrichment filter |
| `Match` | `kube.*` | Apply only to records tagged by the INPUT above |
| `Kube_URL` | cluster service URL | Kubernetes API endpoint — uses in-cluster DNS |
| `Kube_CA_File` | mounted by default | CA certificate for TLS verification |
| `Kube_Token_File` | mounted by default | ServiceAccount bearer token for authentication |
| `Merge_Log` | `On` | If the `log` field is JSON, parse it and merge into the record — structured logging support |
| `K8S-Logging.Parser` | `On` | Respect the `fluentbit.io/parser: <name>` pod annotation |
| `K8S-Logging.Exclude` | `On` | Respect the `fluentbit.io/exclude: "true"` pod annotation — skip noisy pods |

**`[OUTPUT] stdout` — and what changes for Loki:**

```
[OUTPUT]           ← This lab (demo output)
    Name   stdout
    Match  *
    Format json

[OUTPUT]           ← 06-observability/01-logs-loki-grafana (real backend)
    Name   loki
    Match  *
    Host   loki.monitoring.svc.cluster.local
    Port   3100
    Labels job=fluent-bit, cluster=3node, node=$node_name
```

**That is the only change between this lab and the full observability pipeline.**
The rest of the ConfigMap, the DaemonSet spec, the RBAC — all identical.
The pipeline is already correct. Only the output destination changes.

---

### Step 3: Understand the DaemonSet Manifest

**fluent-bit-daemonset.yaml:**

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: default
  labels:
    app: fluent-bit
spec:
  selector:
    matchLabels:
      app: fluent-bit
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: fluent-bit
    spec:
      serviceAccountName: fluent-bit
      # Workers only — no control-plane toleration
      # Control-plane has NoSchedule taint → DESIRED = 2
      # See 02-daemonset-node-targeting for full explanation
      containers:
        - name: fluent-bit
          image: fluent/fluent-bit:3.3
          ports:
            - name: http
              containerPort: 2020
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /api/v1/health
              port: 2020
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /api/v1/health
              port: 2020
            initialDelaySeconds: 30
            periodSeconds: 30
            failureThreshold: 3
          resources:
            requests:
              cpu: "50m"
              memory: "50Mi"
            limits:
              cpu: "100m"
              memory: "100Mi"
          volumeMounts:
            - name: config
              mountPath: /fluent-bit/etc/fluent-bit.conf
              subPath: fluent-bit.conf
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: varlibdockercontainers
              mountPath: /var/lib/docker/containers
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: fluent-bit-config
        - name: varlog
          hostPath:
            path: /var/log
        - name: varlibdockercontainers
          hostPath:
            path: /var/lib/docker/containers
```

**Field-by-field decisions:**

`serviceAccountName: fluent-bit`
Links this pod to the ServiceAccount created in Step 1. Kubernetes
auto-mounts the token and CA certificate at
`/var/run/secrets/kubernetes.io/serviceaccount/` — exactly where
the ConfigMap's `Kube_CA_File` and `Kube_Token_File` point.

`readinessProbe` on `/api/v1/health:2020`
Fluent Bit's HTTP server must be ready — confirming both that the container
is alive AND that the Fluent Bit service is initialised and the pipeline
is running. Without this probe, `READY` shows `1/1` before Fluent Bit
has actually started processing. `initialDelaySeconds: 10` gives Fluent Bit
time to start and read its config before the first probe fires.

`livenessProbe` on `/api/v1/health:2020`
Restarts the container if Fluent Bit becomes unhealthy. `initialDelaySeconds: 30`
gives more buffer than the readiness probe — liveness should not fire during
normal startup delays.

`volumeMounts` — three mounts:

| Mount | Source | Access | Why |
|-------|--------|--------|-----|
| `config` | ConfigMap `fluent-bit-config` | read | Pipeline configuration |
| `varlog` | Node `/var/log` | read-only | Container log files |
| `varlibdockercontainers` | Node `/var/lib/docker/containers` | read-only | Container metadata |

`subPath: fluent-bit.conf`
Mounts only the `fluent-bit.conf` key from the ConfigMap as a single
file at `/fluent-bit/etc/fluent-bit.conf`. Without `subPath`, the entire
ConfigMap would replace the `/fluent-bit/etc/` directory — removing other
files the image expects to find there (like the built-in parsers file).

`hostPath` volumes
The log files live on the **node's** filesystem — not in a PVC, not in
the container. `hostPath` mounts the node's directory directly. This is
normal and expected for a DaemonSet logging agent. `readOnly: true` means
Fluent Bit can read but never write to the node filesystem.

`resources`
50m CPU / 50Mi memory request. 100m / 100Mi limit. DaemonSet pods run on
every node — these values are multiplied by node count. On a 3-node cluster
that is 150m CPU and 150Mi memory reserved cluster-wide just for log
collection. Size appropriately for your log volume. See Lab 01 for why
DaemonSet resource limits have cluster-wide blast radius.

---

### Step 4: Apply RBAC

```bash
cd 03-daemonset-logging-agent/src
kubectl apply -f fluent-bit-rbac.yaml
```

**Expected output:**
```
serviceaccount/fluent-bit created
clusterrole.rbac.authorization.k8s.io/fluent-bit created
clusterrolebinding.rbac.authorization.k8s.io/fluent-bit created
```

**Verify:**
```bash
kubectl get serviceaccount fluent-bit
kubectl get clusterrole fluent-bit
kubectl get clusterrolebinding fluent-bit
```

---

### Step 5: Apply ConfigMap

```bash
kubectl apply -f fluent-bit-configmap.yaml
```

**Expected output:**
```
configmap/fluent-bit-config created
```

**Verify the config was stored:**
```bash
kubectl describe configmap fluent-bit-config
# Shows the full fluent-bit.conf content stored in etcd
```

---

### Step 6: Deploy the DaemonSet

```bash
kubectl apply -f fluent-bit-daemonset.yaml
```

**Expected output:**
```
daemonset.apps/fluent-bit created
```

---

### Step 7: Verify Status — Workers Only

```bash
kubectl get ds fluent-bit
```

**Expected output:**
```
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
fluent-bit   2         2         2       2            2           <none>          30s
```

`DESIRED = 2` — worker nodes only. The control-plane node has
`node-role.kubernetes.io/control-plane:NoSchedule` taint. Without a
matching toleration in the pod spec, the DaemonSet controller skips it.
This is **Approach A** from `02-daemonset-node-targeting` — no extra
configuration needed, the taint does the work.

> **If DESIRED = 3:** The control-plane taint has been removed
> (e.g. single-node dev cluster setup). Add a `nodeAffinity` with
> `DoesNotExist` on `node-role.kubernetes.io/control-plane` to
> explicitly exclude it (Approach B from Lab 02).

```bash
kubectl get pods -l app=fluent-bit -o wide
```

**Expected output:**
```
NAME               READY   STATUS    NODE
fluent-bit-7mnbq   1/1     Running   3node-m02   ← worker 1
fluent-bit-p9sz3   1/1     Running   3node-m03   ← worker 2
```

One pod per worker node. Control-plane has no pod.

---

### Step 8: Read Processed Log Records

The stdout output means every enriched record is visible via `kubectl logs`:

```bash
# Stream live records from worker 1
kubectl logs -f fluent-bit-7mnbq
```

**Expected output — one JSON object per processed log line:**
```json
{
  "date": 1705312867.123,
  "stream": "stdout",
  "log": "I0115 09:41:07.123456 1 server.go:625] GET /api/v1/pods...",
  "kubernetes": {
    "pod_name":        "kube-apiserver-3node",
    "namespace_name":  "kube-system",
    "container_name":  "kube-apiserver",
    "node_name":       "3node-m02",
    "labels":          { "component": "kube-apiserver", "tier": "control-plane" }
  }
}
```

Press `Ctrl+C` to stop streaming.

**Read the last 20 records without streaming:**
```bash
kubectl logs fluent-bit-7mnbq --tail=20
```

**Filter records from a specific namespace:**
```bash
kubectl logs fluent-bit-7mnbq \
  | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        r = json.loads(line)
        ns = r.get('kubernetes', {}).get('namespace_name', '')
        if ns == 'kube-system':
            pod = r['kubernetes']['pod_name']
            log = r.get('log', '')[:80]
            print(f'{pod}: {log}')
    except Exception:
        pass
" | head -20
```

**What the metadata tells you:**
- `pod_name` — exact pod that generated this log line
- `namespace_name` — namespace of that pod
- `container_name` — specific container (pods can have multiple)
- `node_name` — which node this Fluent Bit pod collected it from
- `labels` — pod labels at the time of collection — enables filtering by `app`, `version`, etc.

In Loki, these fields become queryable labels. In this lab they are visible
in the JSON output so you can verify the enrichment works before connecting
a backend.

---

### Step 9: Verify the HTTP Health Endpoint

Fluent Bit exposes a health and metrics API at port 2020:

```bash
# Port-forward to one pod's health endpoint
kubectl port-forward pod/fluent-bit-7mnbq 2020:2020 &
```

```bash
# Health check — what the readiness probe calls
curl http://localhost:2020/api/v1/health
```

**Expected output:**
```json
{"healthy":true}
```

```bash
# Pipeline metrics — Prometheus format
curl http://localhost:2020/api/v1/metrics
```

**Expected output (excerpt):**
```
# HELP fluentbit_input_records_total Number of input records
# TYPE fluentbit_input_records_total counter
fluentbit_input_records_total{name="tail.0"} 1247

# HELP fluentbit_filter_records_total Number of filter records
# TYPE fluentbit_filter_records_total counter
fluentbit_filter_records_total{name="kubernetes.0"} 1247

# HELP fluentbit_output_records_total Number of output records
# TYPE fluentbit_output_records_total counter
fluentbit_output_records_total{name="stdout.0"} 1247
```

These metrics show records flowing through each stage of the pipeline.
Input, filter, and output counts all match — no records dropped.

```bash
# Stop the port-forward
kill %1
```

---

### Step 10: Examine What the Readiness Probe Does

Look at the probe in the pod's condition chain:

```bash
kubectl get pod fluent-bit-7mnbq \
  -o jsonpath='{.status.containerStatuses[0]}' \
  | python3 -m json.tool
```

**Expected output:**
```json
{
    "name": "fluent-bit",
    "ready": true,
    "restartCount": 0,
    "started": true,
    "state": {
        "running": {
            "startedAt": "2024-01-15T09:41:07Z"
        }
    }
}
```

`ready: true` — the HTTP probe to `/api/v1/health:2020` returned `{"healthy":true}`.
`restartCount: 0` — liveness probe has not triggered a restart.

```bash
kubectl describe pod fluent-bit-7mnbq | grep -A 6 "Readiness:\|Liveness:"
```

**Expected output:**
```
Liveness:   http-get http://:2020/api/v1/health delay=30s timeout=1s period=30s
Readiness:  http-get http://:2020/api/v1/health delay=10s timeout=1s period=10s
```

---

### Step 11: Perform a Rolling Update

Update the image from `3.3` to `3.3.1`. The DaemonSet controller replaces
pods one node at a time — `maxUnavailable: 1` — exactly as demonstrated
in `01-basic-daemonset`.

```bash
# Terminal 1 — watch pods
kubectl get pods -l app=fluent-bit -o wide -w

# Terminal 2 — update image
kubectl set image daemonset/fluent-bit fluent-bit=fluent/fluent-bit:3.3.1

kubectl rollout status daemonset/fluent-bit
```

**Expected rollout output:**
```
Waiting for daemon set "fluent-bit" rollout to finish: 1 out of 2 new pods have been updated...
Waiting for daemon set "fluent-bit" rollout to finish: 1 of 2 updated pods are available...
daemon set "fluent-bit" successfully rolled out
```

**Verify all pods on new image:**
```bash
kubectl get pods -l app=fluent-bit \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

**Expected output:**
```
fluent-bit-abc12   fluent/fluent-bit:3.3.1
fluent-bit-def34   fluent/fluent-bit:3.3.1
```

**Rollback if needed:**
```bash
kubectl rollout undo daemonset/fluent-bit
kubectl rollout status daemonset/fluent-bit
```

---

### Step 12: Connecting to Loki — What Changes

When you reach `06-observability/01-logs-loki-grafana`, the only change
to this lab's setup is the `[OUTPUT]` block in the ConfigMap:

```bash
# Current (this lab):
[OUTPUT]
    Name   stdout
    Match  *
    Format json

# 06-observability/01-logs-loki-grafana:
[OUTPUT]
    Name   loki
    Match  *
    Host   loki.monitoring.svc.cluster.local
    Port   3100
    Labels job=fluent-bit, cluster=3node, node=$node_name
```

The `cluster=3node` label in the Loki output is the multi-cluster key.
Every log record shipped to Loki is tagged with the cluster name. In
Grafana, a dashboard variable `{cluster="$cluster"}` lets you switch
between `3node`, `5node`, or any other minikube profile feeding the
same Loki instance. This design is covered in detail in
`06-observability/00-observability-concepts` — Part 5: Multi-Cluster Design.

To apply the change:
```bash
# Edit the ConfigMap — change the OUTPUT block
kubectl edit configmap fluent-bit-config

# Restart the DaemonSet to pick up the new config
# (ConfigMap changes are not automatically reloaded by Fluent Bit)
kubectl rollout restart daemonset/fluent-bit
kubectl rollout status daemonset/fluent-bit
```

---

### Step 13: Cleanup — Correct Order

Resources must be deleted in order — the DaemonSet before the RBAC,
because the running pods use the ServiceAccount:

```bash
# 1 — Delete the DaemonSet (and its pods)
kubectl delete -f fluent-bit-daemonset.yaml

# 2 — Delete the ConfigMap
kubectl delete -f fluent-bit-configmap.yaml

# 3 — Delete the RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
kubectl delete -f fluent-bit-rbac.yaml
```

**Verify complete removal:**
```bash
kubectl get ds fluent-bit
kubectl get pods -l app=fluent-bit
kubectl get configmap fluent-bit-config
kubectl get serviceaccount fluent-bit
kubectl get clusterrole fluent-bit
kubectl get clusterrolebinding fluent-bit
# All should return: not found
```

---

## Experiments to Try

1. **Exclude Fluent Bit's own logs from collection:**
   Add the annotation to the DaemonSet pod template to stop Fluent Bit
   collecting its own logs (avoids recursive log collection):
   ```yaml
   template:
     metadata:
       labels:
         app: fluent-bit
       annotations:
         fluentbit.io/exclude: "true"   # Kubernetes filter respects this
   ```
   Apply and verify: Fluent Bit's own log lines no longer appear in
   `kubectl logs fluent-bit-7mnbq` output.

2. **Test Merge_Log with a JSON-logging pod:**
   Deploy a pod that logs JSON:
   ```bash
   kubectl run json-logger --image=busybox \
     --restart=Never \
     -- sh -c 'while true; do
       echo "{\"level\":\"info\",\"msg\":\"heartbeat\",\"ts\":$(date +%s)}";
       sleep 2; done'
   ```
   Watch the Fluent Bit output — with `Merge_Log On`, the JSON fields
   (`level`, `msg`, `ts`) appear at the top level of the record alongside
   the Kubernetes metadata, not nested inside `log`.

3. **Observe the SQLite offset database:**
   ```bash
   # Exec into a Fluent Bit pod and look at the DB file
   kubectl exec fluent-bit-7mnbq -- ls -lh /var/log/flb_kube.db
   # The DB tracks exactly how far through each log file Fluent Bit has read
   # Delete the pod — when it restarts, it picks up from where it left off
   kubectl delete pod fluent-bit-7mnbq
   kubectl get pods -l app=fluent-bit -o wide -w
   # New pod created on same node — no duplicate records
   ```

4. **Verify the cluster-wide resource usage:**
   ```bash
   kubectl top pods -l app=fluent-bit
   # Shows actual CPU and memory per pod
   # Compare to resource requests (50m CPU, 50Mi memory)
   # Multiply by node count for total cluster cost of log collection
   ```

---

## Common Questions

### Q: Why is the ConfigMap mounted with `subPath` instead of a directory mount?
**A:** The Fluent Bit image includes a built-in parsers file at
`/fluent-bit/etc/parsers.conf`. Without `subPath`, mounting the ConfigMap
at `/fluent-bit/etc/` would replace the entire directory — removing the
parsers file and breaking the pipeline. `subPath` mounts only the
`fluent-bit.conf` key as a single file, leaving everything else in that
directory intact.

### Q: What happens if the Kubernetes API is unreachable and the filter can't enrich records?
**A:** Fluent Bit continues processing — the `kubernetes` filter degrades
gracefully. Records are still collected and forwarded to the output, but
without the Kubernetes metadata (no `pod_name`, `namespace_name`, etc.).
The filter logs warnings about failed API calls. The pipeline does not
stop or crash.

### Q: Why do we not tolerate the control-plane node here?
**A:** Application workloads run on worker nodes — that is where the logs
we care about are generated. The control-plane runs system components
whose logs are already handled by `kube-system` DaemonSets. Keeping
the logging agent on workers keeps it focused on application log
collection and avoids unnecessary load on the control-plane node.

### Q: What is `K8S-Logging.Exclude On` used for?
**A:** It enables a per-pod opt-out mechanism. Any pod with the annotation
`fluentbit.io/exclude: "true"` will have its logs skipped by Fluent Bit.
Useful for extremely high-volume or sensitive pods that should not be
collected into the central log store.

### Q: ConfigMap was updated but Fluent Bit did not pick up the change. Why?
**A:** Fluent Bit reads its config file at startup — it does not watch for
ConfigMap changes. Updating the ConfigMap alone is not enough. You must
restart the DaemonSet: `kubectl rollout restart daemonset/fluent-bit`.
The rolling update replaces each pod with a new one that reads the
updated ConfigMap on startup.

### Q: Does deleting a Fluent Bit pod cause log data loss?
**A:** No — because of the SQLite DB (`/var/log/flb_kube.db`). The DB
tracks the read offset for every log file. When the pod is recreated on
the same node, it reads the DB and resumes from where it left off. Lines
already processed are not re-read. Note: the DB file is written to the
node's `/var/log` via the hostPath mount, so it persists across pod
restarts as long as it stays on the same node.

---

## What You Learned

In this lab, you:
- ✅ Explained the four Fluent Bit pipeline stages and each stage's role
- ✅ Explained the Fluentd vs Fluent Bit decision — footprint, role, and fit
- ✅ Deployed a three-resource pattern: RBAC → ConfigMap → DaemonSet
- ✅ Explained every field in the ConfigMap pipeline configuration
- ✅ Applied workers-only targeting from Lab 02 (no control-plane toleration)
- ✅ Applied `subPath` ConfigMap mounting to preserve image-provided files
- ✅ Verified one pod per worker node with `kubectl get pods -o wide`
- ✅ Read enriched JSON records and identified every Kubernetes metadata field
- ✅ Used the HTTP health endpoint and Prometheus metrics from Fluent Bit
- ✅ Verified readiness and liveness probe configuration on the running pod
- ✅ Performed a rolling update with `kubectl set image` and `rollout status`
- ✅ Identified exactly which ConfigMap line changes to connect to Loki
- ✅ Understood why `kubectl rollout restart` is needed after ConfigMap changes
- ✅ Cleaned up resources in the correct dependency order

**Key Takeaway:** A production DaemonSet is more than a pod spec — it is
a composition of RBAC, ConfigMap, and DaemonSet working together. The
DaemonSet mechanics (one pod per node, rolling updates, node targeting)
are the same as Labs 01 and 02. What changes is the application layer:
external config, API permissions, node filesystem access, and health
probes that reflect real service readiness. The stdout output here is a
deliberate stepping stone — one ConfigMap line away from the full Loki
pipeline in `06-observability/01-logs-loki-grafana`.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get ds fluent-bit` | DaemonSet status — DESIRED should be 2 (workers only) |
| `kubectl get pods -l app=fluent-bit -o wide` | Pods with node placement |
| `kubectl logs -f fluent-bit-<suffix>` | Stream enriched JSON log records |
| `kubectl logs fluent-bit-<suffix> --tail=20` | Last 20 records |
| `kubectl port-forward pod/fluent-bit-<n> 2020:2020` | Access health endpoint |
| `curl http://localhost:2020/api/v1/health` | Health check |
| `curl http://localhost:2020/api/v1/metrics` | Pipeline metrics (Prometheus format) |
| `kubectl set image ds/fluent-bit fluent-bit=fluent/fluent-bit:3.3.1` | Update image |
| `kubectl rollout status ds/fluent-bit` | Watch rolling update |
| `kubectl rollout undo ds/fluent-bit` | Rollback |
| `kubectl rollout restart ds/fluent-bit` | Restart all pods (e.g. after ConfigMap change) |
| `kubectl edit configmap fluent-bit-config` | Edit pipeline config in-place |
| `kubectl describe configmap fluent-bit-config` | View stored config |

---

## Troubleshooting

**DESIRED = 3 (control-plane getting a pod)?**
```bash
kubectl describe node 3node | grep Taints
# If Taints: <none> — control-plane taint was removed
# Fix: add nodeAffinity DoesNotExist (Approach B from Lab 02)
# or: kubectl taint node 3node node-role.kubernetes.io/control-plane:NoSchedule
```

**`kubectl logs` shows no JSON records — only Fluent Bit startup lines?**
```bash
kubectl logs fluent-bit-7mnbq | grep -i error
# Common causes:
# [error] ConfigMap not mounted — check volume + subPath
# [error] RBAC 403 — check ServiceAccount and ClusterRoleBinding
# [error] /var/log/containers not accessible — check hostPath
kubectl describe pod fluent-bit-7mnbq | grep -A5 "Events:"
```

**Records appear but have no `kubernetes` field?**
```bash
# The kubernetes filter ran but could not reach the API
kubectl logs fluent-bit-7mnbq | grep -i "kube\|403\|forbidden"
# Check: kubectl get clusterrolebinding fluent-bit -o yaml
# Verify: subject namespace matches where the ServiceAccount was created
```

**ConfigMap change not picked up after `kubectl apply`?**
```bash
# Fluent Bit does not hot-reload config — restart is required
kubectl rollout restart daemonset/fluent-bit
kubectl rollout status daemonset/fluent-bit
```

**Rolling update stuck at 1/2?**
```bash
kubectl describe pod <new-pod-name>
# Check Events — readiness probe may be failing on new image
# Verify: curl http://localhost:2020/api/v1/health (via port-forward)
# Recovery: kubectl rollout undo daemonset/fluent-bit
```

---

## CKA Certification Tips

✅ **Three-resource pattern — apply in order:**
```bash
kubectl apply -f rbac.yaml
kubectl apply -f configmap.yaml
kubectl apply -f daemonset.yaml
```

✅ **Update image imperatively (faster than editing YAML):**
```bash
kubectl set image daemonset/<n> <container>=<image>:<tag>
```

✅ **Restart DaemonSet after ConfigMap change:**
```bash
kubectl rollout restart daemonset/<n>
```

✅ **subPath — when to use it:**
Mount a single file from a ConfigMap without replacing the entire
directory. Required when the container image has other files in the
same directory that must be preserved.

✅ **hostPath volumes — DaemonSet pattern:**
```yaml
volumes:
  - name: varlog
    hostPath:
      path: /var/log
```
Normal and expected for node-local DaemonSets. Always `readOnly: true`
for collectors — they read, never write.

✅ **ServiceAccount auto-mount location:**
```
/var/run/secrets/kubernetes.io/serviceaccount/token
/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```
Automatically mounted when `serviceAccountName` is set. Used by
in-cluster API clients (Fluent Bit kubernetes filter, etc.).