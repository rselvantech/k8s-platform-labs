# Multi-Container Pods — Init, Sidecar, Ambassador & Adapter Patterns

## Lab Overview

This lab teaches you how to build production-grade multi-container pods — the
foundation of microservice observability, dependency management, and service
mesh architecture in Kubernetes.

A pod can hold multiple containers that share the same network namespace and
selectively share storage volumes. This enables powerful design patterns:
**init containers** that enforce prerequisites before your app starts, and
**sidecar**, **ambassador**, and **adapter** patterns that decouple supporting
concerns from your application logic.

You will start with the fundamentals (shared network, shared storage), progress
through init container patterns, and culminate with the native sidecar feature
introduced in Kubernetes v1.33 (stable in v1.34) — which solves long-standing
ordering and lifecycle problems with traditional sidecars.

**What you'll do:**
- Prove that containers in a pod share a network namespace (communicate via localhost)
- Prove that volumes are selectively mounted per container (readOnly vs ReadWrite)
- Use init containers to gate application startup on service availability
- Chain multiple init containers in sequence
- Compare the old sidecar pattern (regular container) with native sidecars (v1.34)
- Demonstrate all three old sidecar problems using a Job
- Observe native sidecar (v1.34) solving all three problems with real output

## Prerequisites

**Required Software:**
- Minikube multi-node cluster (`3node` profile) — 1 control plane + 2 workers
- kubectl installed and configured
- Text editor (VS Code recommended)

**Knowledge Requirements:**
- **REQUIRED:** Completion of Lab 01 (Pod Lifecycle, Termination, Restart Policies)
- Understanding of pods, containers, restartPolicy
- Basic YAML syntax

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain why containers in a pod communicate via `localhost`
2. ✅ Mount a shared volume with different access modes per container
3. ✅ Write init containers that gate main container startup
4. ✅ Chain multiple init containers and observe `Init:0/2 → Init:1/2 → Running`
5. ✅ Explain the difference between init containers and sidecar/ambassador/adapter patterns
6. ✅ Configure a native sidecar container using `restartPolicy: Always` in `initContainers`
7. ✅ Explain all three problems native sidecars solve — with log timestamp
      and READY column evidence from real cluster output

## Directory Structure

```
02-multi-container-pods/
└── src/
    ├── 01-shared-network.yaml          # Prove shared network namespace
    ├── 02-shared-storage.yaml          # Prove selective volume mounting
    ├── 03-init-single.yaml             # Single init container (service DNS gate)
    ├── 03-postgres-svc.yaml            # Service created to unblock init container
    ├── 04-init-multiple.yaml           # Two init containers in sequence
    ├── 04-api-svc.yaml                 # Service for second init container
    ├── 05-job-old-sidecar.yaml         # Old sidecar pattern — Job never completes (3 problems)
    └── 06-job-native-sidecar.yaml      # Native sidecar — Job completes, all 3 problems solved
```

## Understanding Multi-Container Pod Fundamentals

### Shared Network Namespace

When a pod is created, Kubernetes creates a single **network namespace** for
the entire pod. All containers in the pod share it — same IP address, same
routing tables, same port space.

```
┌──────────────────────────────────────────────────────────────────┐
│                            POD                                   │
│             One IP address · Shared port space                   │
│                                                                  │
│  ┌───────────────────┐          ┌──────────────────────────┐     │
│  │  Container 1      │          │  Container 2             │     │
│  │  nginx (port 80)  │◄─────────│  curl localhost:80  ✅   │     │
│  └───────────────────┘          └──────────────────────────┘     │
│                                                                  │
│  ✅ Container 2 reaches Container 1 via localhost — no Service   │
│  ❌ Container 2 CANNOT also bind port 80 (already taken)         │
└──────────────────────────────────────────────────────────────────┘
```

> **Network namespace is a Linux kernel concept**, not a Kubernetes invention.
> It isolates all networking for a group of processes. The hidden `pause`
> container that Kubernetes creates for every pod is what actually holds and
> owns this network namespace — all other containers in the pod attach to it.

### Selective Volume Mounting

Volumes are declared at the **pod level** but **individually mounted** per
container. Each container opts in with `volumeMounts`, and can have a different
access mode (ReadWrite vs ReadOnly):

```
Volume (pod level, emptyDir)
    │
    ├── nginx container      → ReadWrite  (writes logs)
    ├── log-collector        → ReadOnly   (reads logs, ships elsewhere)
    └── another-container    → not mounted (cannot see volume at all)
```

### Main vs Helper Containers

In any multi-container pod, one container is the **main container** — the one
running your application logic. All others are **helper containers** whose job
is to support the main container without being part of the application itself.

```
Main container  →  nginx, your API, your microservice
Helper containers →  log collector (Fluent Bit), proxy (Envoy),
                     metric exporter (Prometheus), cert manager
```

**Key property:** If a helper container fails, the main application continues
running. Only the helper's function (logging, metrics) is interrupted until
Kubelet restarts it.

### The Four Patterns and Where They Live in YAML

```
┌──────────────────────────────────────────────────────────────────────┐
│  Pattern       │  YAML block              │  Lifecycle              │
├────────────────┼──────────────────────────┼─────────────────────────┤
│  Init          │  spec.initContainers[]   │  Run once, then vanish  │
│  Sidecar       │  spec.containers[]       │  Full pod lifetime      │
│  Ambassador    │  spec.containers[]       │  Full pod lifetime      │
│  Adapter       │  spec.containers[]       │  Full pod lifetime      │
└──────────────────────────────────────────────────────────────────────┘
```

> **Critical point:** You NEVER write `sidecarContainers:`,
> `ambassadorContainers:`, or `adapterContainers:` in your YAML.
> Sidecar, Ambassador, and Adapter are **logical design patterns** — their
> containers all live inside `spec.containers[]`. ONLY init containers have
> their own dedicated block: `spec.initContainers[]`.

---

## Lab Step-by-Step Guide

---

### Step 1: Verify Your Cluster

```bash
kubectl get nodes
```

**Expected output:**
```
NAME        STATUS   ROLES           AGE   VERSION
3node       Ready    control-plane   1h    v1.34.0
3node-m02   Ready    <none>          1h    v1.34.0
3node-m03   Ready    <none>          1h    v1.34.0
```

---

### Part 1: Shared Network Namespace

---

### Step 2: Understand the YAML

**01-shared-network.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: shared-network-demo
spec:
  restartPolicy: Never
  containers:
    - name: nginx                 # Main container — serves HTTP on port 80
      image: nginx:1.27
      ports:
        - containerPort: 80

    - name: network-probe         # Helper container — proves shared network
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "--- Proving shared network namespace ---"
          echo ""
          echo "1. My hostname:"
          hostname
          echo ""
          echo "2. My IP address (same as nginx's IP):"
          hostname -i
          echo ""
          echo "3. Reaching nginx via localhost (no Service needed):"
          wget -qO- http://localhost:80 | head -5
          echo ""
          echo "4. Port 80 is already taken — cannot bind it:"
          nc -l -p 80 2>&1 || echo "Port 80 is in use (expected!)"
          sleep 3600
```

**Key YAML Fields Explained:**

- Two containers in `spec.containers[]` — both share the pod's network namespace
- `network-probe` uses `localhost:80` to reach nginx — no ClusterIP, no DNS,
  no Service needed. They share the same IP and port space.
- `nc -l -p 80` attempts to bind port 80 — it will fail because nginx already
  owns that port. This is the port conflict demonstration.
- `hostname -i` will print the **same IP** for both containers — they share one IP.

---

### Step 3: Deploy and Observe Shared Networking

```bash
cd 02-multi-container-pods/src

kubectl apply -f 01-shared-network.yaml
kubectl get pods -w
```

**Expected output:**
```bash
NAME                   READY   STATUS    RESTARTS   AGE
shared-network-demo    2/2     Running   0          10s
                       ↑ ↑
                       │ └── total containers in spec.containers[]
                       └──── containers where ready = true
                             (no readiness probe defined → defaults to true immediately)
```
Both containers defined in spec.containers[] are counted.
Init containers are NEVER counted here — even if defined.
2/2 = all containers ready → pod Ready condition = True → eligible for Service traffic


**Check the logs of the `network-probe` container:**

```bash
kubectl logs shared-network-demo -c network-probe
```

**Expected output:**
```
--- Proving shared network namespace ---

1. My hostname:
shared-network-demo

2. My IP address (same as nginx's IP):
10.244.2.30

3. Reaching nginx via localhost (no Service needed):
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>

4. Port 80 is already taken — cannot bind it:
Port 80 is in use (expected!)
```

**Check hostname and IP  of the `nginx` container:**

```bash
kubectl exec pods/shared-network-demo -c nginx -- hostname
kubectl exec pods/shared-network-demo -c nginx -- hostname -i
```

**Expected output:**
```
shared-network-demo
10.244.2.30
```

**What this proves:**
- Both containers have the **same hostname** (the pod name)
- Both containers have the **same IP address**
- `network-probe` reached nginx at `localhost:80` — no Service, no DNS
- Port 80 cannot be bound twice — the network namespace is shared

**Cleanup:**
```bash
kubectl delete -f 01-shared-network.yaml
```

---

### Part 2: Shared Storage

---

### Step 4: Understand the YAML

**02-shared-storage.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: shared-storage-demo
spec:
  restartPolicy: Never
  containers:
    - name: nginx                  # Main container — writes access and error logs
      image: nginx:1.27
      volumeMounts:
        - name: nginx-logs
          mountPath: /var/log/nginx  # nginx writes access.log + error.log here
                                     # default readOnly: false — full read/write

    - name: log-reader             # Helper container — demonstrates ReadOnly mount
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "Waiting for nginx to initialise log files..."
          sleep 3
          echo "--- Contents of shared log volume ---"
          ls -la /logs/
          echo ""
          echo "--- Attempting to write to ReadOnly volume ---"
          echo "test" >> /logs/access.log 2>&1 \
            || echo "Write BLOCKED (ReadOnly — expected!)"
          sleep 3600
      volumeMounts:
        - name: nginx-logs
          mountPath: /logs           # Different mountPath, same underlying volume
          readOnly: true             # Helper can read — cannot write

  volumes:
    - name: nginx-logs              # Declared at pod level — shared by both containers
      emptyDir: {}                  # Ephemeral — exists for pod lifetime only
```

**Key YAML Fields Explained:**

- `volumes` is at `spec` level — pod-level declaration. Both containers
  reference the same `nginx-logs` volume by name.
- `nginx` mounts to `/var/log/nginx` with default `readOnly: false` — nginx
  writes `access.log` (one line per HTTP request) and `error.log` (startup
  and worker process messages) here.
- `log-reader` mounts the **same** volume to `/logs` with `readOnly: true`.
  Different `mountPath` values do not create different volumes — they are
  two mount points into the same underlying directory on the node.
- `emptyDir: {}` — starts empty, lives for the pod's lifetime, deleted
  when the pod is removed. Not persisted after pod deletion.

> **Why `readOnly: true` matters in production:** A log collector sidecar
> should never be able to modify or delete log files — only read and ship
> them. `readOnly: true` enforces this at the kernel level. It cannot be
> overridden by the process running inside the container.

---

### Step 5: Deploy and Observe Shared Storage

**Terminal 1 — watch pod status:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply:**
```bash
kubectl apply -f 02-shared-storage.yaml
```

**Terminal 1 — Expected output:**
```
NAME                   READY   STATUS    RESTARTS   AGE
shared-storage-demo    2/2     Running   0          5s
```

**Terminal 2 — generate nginx traffic (creates an access log entry):**
```bash
POD_IP=$(kubectl get pod shared-storage-demo -o jsonpath='{.status.podIP}')
kubectl run curl-test --image=curlimages/curl:8.11.0 --rm -it --restart=Never \
  -- curl -s http://$POD_IP/
```

**Expected output:**
```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
</html>
pod "curl-test" deleted from default namespace
```

---

#### Verification 1 — Volume contents from BOTH container mountPaths
```bash
# From nginx container — its ReadWrite mountPath
kubectl exec shared-storage-demo -c nginx -- ls -la /var/log/nginx
```

**Expected output:**
```
total 16
drwxrwxrwx 2 root root 4096 Mar 20 12:25 .
drwxr-xr-x 1 root root 4096 Jun 10  2025 ..
-rw-r--r-- 1 root root   92 Mar 20 12:29 access.log
-rw-r--r-- 1 root root 1324 Mar 20 12:25 error.log
```
```bash
# From log-reader container — its ReadOnly mountPath
kubectl exec shared-storage-demo -c log-reader -- ls -la /logs
```

**Expected output:**
```
total 16
drwxrwxrwx    2 root     root          4096 Mar 20 12:25 .
drwxr-xr-x    1 root     root          4096 Mar 20 12:25 ..
-rw-r--r--    1 root     root            92 Mar 20 12:29 access.log
-rw-r--r--    1 root     root          1324 Mar 20 12:25 error.log
```

**What this proves:** Identical size (`92` bytes), identical timestamp
(`12:29`), identical permissions from both containers. Two different
mountPaths (`/var/log/nginx` and `/logs`), one underlying volume — the
same inode, the same data.

---

#### Verification 2 — nginx wrote access.log (ReadWrite mount in action)
```bash
kubectl exec shared-storage-demo -c nginx -- cat /var/log/nginx/access.log
```

**Expected output:**
```
10.244.1.32 - - [20/Mar/2026:12:29:19 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/8.11.0" "-"
```

nginx wrote one line for the curl request — via its `ReadWrite` mount at
`/var/log/nginx`.

---

#### Verification 3 — log-reader can READ the same file (ReadOnly mount in action)
```bash
kubectl exec shared-storage-demo -c log-reader -- cat /logs/access.log
```

**Expected output:**
```
10.244.1.32 - - [20/Mar/2026:12:29:19 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/8.11.0" "-"
```

The `log-reader` container reads the **same file** via its `ReadOnly` mount at
`/logs`. Different path, same data — shared storage confirmed.

---

#### Verification 4 — log-reader CANNOT write (ReadOnly enforced at kernel level)
```bash
kubectl exec shared-storage-demo -c log-reader -- sh -c "echo test >> /logs/access.log"
```

**Expected output:**
```
sh: can't create /logs/access.log: Read-only file system
```

The kernel refuses the write. `readOnly: true` is enforced at the filesystem
mount level — not a permission setting, not advisory. No process inside this
container can write to this mountPath regardless of the user it runs as.

---

#### Verification 5 — log-reader container logs (startup check + write block)
```bash
kubectl logs shared-storage-demo -c log-reader
```

**Expected output:**
```
Waiting for nginx to initialise log files...
--- Contents of shared log volume ---
total 12
drwxrwxrwx    2 root     root          4096 Mar 20 12:25 .
drwxr-xr-x    1 root     root          4096 Mar 20 12:25 ..
-rw-r--r--    1 root     root             0 Mar 20 12:25 access.log    ← 0 bytes at startup
-rw-r--r--    1 root     root          1324 Mar 20 12:25 error.log

--- Attempting to write to ReadOnly volume ---
Write BLOCKED (ReadOnly — expected!)
```

> **Why is `access.log` 0 bytes here but 92 bytes in Verification 1?**
> The `log-reader` script ran its `sleep 3` check at container startup —
> **before** the curl request was made. nginx creates `access.log` as an
> empty file on startup and only writes to it when an HTTP request arrives.
> The curl request came after this check had already run.
> The `kubectl exec` verifications (1–4) always reflect current state.
> This is expected behaviour — not a discrepancy.

---

**What all five verifications prove together:**
```
nginx    → /var/log/nginx  (ReadWrite) → writes access.log + error.log ✅
log-reader → /logs         (ReadOnly)  → reads the same files           ✅
log-reader → /logs         (ReadOnly)  → cannot write — kernel enforced ✅
Both containers             → same underlying emptyDir volume           ✅
Two different mountPaths    → same directory on the node                ✅
```

**Cleanup:**
```bash
kubectl delete -f 02-shared-storage.yaml
```

---

### Part 3: Init Containers


### Step 6: Understand Init Container Behaviour

```
┌─────────────────────────────────────────────────────────────────────┐
│                   INIT CONTAINER EXECUTION ORDER                    │
│                                                                     │
│  Pod Created                                                        │
│      │                                                              │
│      ▼                                                              │
│  ┌─────────────┐  exit 0  ┌─────────────┐  exit 0                   │
│  │  Init #1    │─────────►│  Init #2    │──────────┐                │
│  └─────────────┘          └─────────────┘          ▼                │
│       │ non-zero               │ non-zero    ┌────────────┐         │
│       ▼                        ▼             │  MAIN APP  │         │
│  Pod restarts             Pod restarts       │  Starts ✅ │         │
│                                              └────────────┘         │
└─────────────────────────────────────────────────────────────────────┘
```

**Key init container facts (verified from official docs):**
- Run **sequentially** — #1 must exit 0 before #2 starts
- Main container **never starts** if any init container fails
- **NOT counted** in the READY column (`0/1` not `0/2` when 1 init + 1 main)
- **Vanish** after completion — consume zero CPU/memory
- Defined in `spec.initContainers[]` — separate from `spec.containers[]`

---

### Step 7: Single Init Container — Wait for PostgreSQL Service

**Scenario:** A web application must not start until its PostgreSQL database service is
reachable. Without this gate, the app starts, immediately tries to connect
to a database that does not exist yet, and crashes — entering
`CrashLoopBackOff`.

The init container solves this by polling the PostgreSQL Service DNS name
in a loop. Only when DNS resolves (confirming the Service exists in the
cluster) does the init container exit 0 — unblocking the main container.

We create the Service **separately and deliberately late** — after the pod
is already deployed and waiting. This makes the blocking and unblocking
behaviour visible in real time.

**03-init-single.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: webapp-with-init
spec:
  initContainers:
    - name: wait-for-postgres        # Init container — waits for DB Service
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "Checking if PostgreSQL service is available..."
          until nslookup postgres-svc.default.svc.cluster.local; do
            echo "Waiting for postgres-svc DNS resolution... retrying in 3s"
            sleep 3
          done
          echo "PostgreSQL service found! Starting main application."

  containers:
    - name: webapp                   # Main container — starts ONLY after init passes
      image: nginx:1.27
      ports:
        - containerPort: 80
```

**Key YAML Fields Explained:**

- `spec.initContainers[]` — separate block, NOT inside `spec.containers[]`
- `nslookup postgres-svc.default.svc.cluster.local` — queries the cluster DNS
  (CoreDNS) for the service. Fails until a Service named `postgres-svc` exists
  in the `default` namespace.
- The `until` loop retries every 3 seconds until DNS resolves. This is the
  standard pattern for service dependency waiting.
- The format `<svc>.<namespace>.svc.cluster.local` is the full Kubernetes
  internal DNS name for a service.

**03-postgres-svc.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-svc                 # The name the init container looks for
spec:
  selector:
    app: postgres                    # No actual postgres pod needed for DNS demo
  ports:
    - port: 5432
      targetPort: 5432
```

---

### Step 8: Deploy and Observe Init Container Blocking

**Terminal 1 — watch pod status:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply the pod only (NOT the service yet):**
```bash
kubectl apply -f 03-init-single.yaml
```

**Terminal 3 — follow init container logs live:**
```bash
kubectl logs -f webapp-with-init -c wait-for-postgres
```

**Terminal 1 — Expected output:**
```
NAME               READY   STATUS     RESTARTS   AGE
webapp-with-init   0/1     Init:0/1   0          5s
webapp-with-init   0/1     Init:0/1   0          15s
webapp-with-init   0/1     Init:0/1   0          25s
                   ↑       ↑
                   │       └── STATUS: Init:0/1
                   │           Format: Init:<completed>/<total>
                   │           Meaning: 0 of 1 init containers completed
                   │           The init container IS running — just not done yet
                   │           STATUS only transitions away from Init:x/y when
                   │           ALL init containers have exited 0
                   │
                   └── READY: 0/1
                       Only the 1 main container is counted here
                       Init container is completely invisible to READY
                       Main container has not started yet → 0 of 1 ready
```

> **STATUS vs READY for init containers — key distinction:**
>
> | Column | What it counts | During init phase |
> |--------|---------------|-------------------|
> | `READY` | `spec.containers[]` only | Shows `0/1` — main not started yet |
> | `STATUS` | Overall pod state | Shows `Init:0/1` — init running |
>
> The `STATUS` column is the one that tells you init containers are
> involved and how many have completed. `READY` tells you nothing about
> init containers — it only reflects `spec.containers[]`. Both columns
> together give the full picture:
> - `STATUS = Init:0/1` → init container running, main container blocked
> - `READY = 0/1` → main container not ready (has not started at all)
> - Neither column restarts — `RESTARTS = 0` — nothing has crashed

**Terminal 3 — Expected output (looping until service exists):**
```
Waiting for postgres-svc DNS resolution... retrying in 3s
Server:         10.96.0.10
Address:        10.96.0.10:53

** server can't find postgres-svc.default.svc.cluster.local: NXDOMAIN

** server can't find postgres-svc.default.svc.cluster.local: NXDOMAIN
```

Now in **Terminal 2** — create the Service to unblock the init container:

```bash
kubectl apply -f 03-postgres-svc.yaml
```

**Terminal 1 — immediately after service is created:**
```
NAME               READY   STATUS         RESTARTS   AGE
webapp-with-init   0/1     Pending           0          0s
webapp-with-init   0/1     Pending           0          0s
webapp-with-init   0/1     Init:0/1          0          0s
webapp-with-init   0/1     Init:0/1          0          0s
webapp-with-init   0/1     PodInitializing   0          3m10s  ← init done, main starting
webapp-with-init   1/1     Running           0          3m11s  ← main app running!
```

**Terminal 3 — final log lines when init succeeds:**
```
Waiting for postgres-svc DNS resolution... retrying in 3s
Server:         10.96.0.10
Address:        10.96.0.10:53


Name:   postgres-svc.default.svc.cluster.local
Address: 10.98.157.76

PostgreSQL service found! Starting main application.
```

> **How does Kubernetes DNS work here?**
> All cluster DNS queries go to CoreDNS at `10.96.0.10` (the `kube-dns`
> ClusterIP service). CoreDNS resolves `postgres-svc.default.svc.cluster.local`
> to the Service's ClusterIP. The init container's `nslookup` gets that IP
> and exits 0 — unblocking the main container.

**Cleanup:**
```bash
kubectl delete -f 03-init-single.yaml
kubectl delete -f 03-postgres-svc.yaml
```

---

### Part 4: Multiple Init Containers in Sequence

---

### Step 9: Chain Two Init Containers

#### What This Demo Shows

This demo chains two init containers that must both succeed **in sequence**
before the main container starts.

- **Init #1** (`check-external-api`) — verifies outbound HTTP connectivity
  by checking `http://info.cern.ch`. This simulates a real prerequisite:
  the application needs to reach an external payment gateway or third-party
  API before starting.

- **Init #2** (`check-internal-svc`) — waits for an internal Kubernetes
  Service DNS name to resolve. This simulates waiting for a dependent
  microservice to be registered in the cluster.

We deploy the pod first, then create the internal Service manually — making
the sequential blocking and unblocking behaviour visible in real time.
If Init #1 fails, Init #2 never runs. If Init #2 fails, the main container
never starts. Both must succeed in order.

**04-init-multiple.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: microservice-with-inits
spec:
  initContainers:
    - name: check-external-api          # Init #1: verify outbound HTTP connectivity
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "Init 1: Checking outbound HTTP connectivity..."
          until wget -q --spider http://info.cern.ch; do
            echo "Not reachable. Retrying in 5s..."
            sleep 5
          done
          echo "Init 1: External HTTP reachable. Proceeding to Init 2."

    - name: check-internal-svc          # Init #2: runs ONLY after Init #1 exits 0
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "Init 2: Waiting for api-svc to be created..."
          until nslookup api-svc.default.svc.cluster.local; do
            echo "api-svc not found. Retrying in 3s..."
            sleep 3
          done
          echo "Init 2: api-svc found. Starting main application."

  containers:
    - name: microservice                # Starts ONLY after BOTH inits exit 0
      image: nginx:1.27
      ports:
        - containerPort: 80
```

**04-api-svc.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-svc
spec:
  selector:
    app: api
  ports:
    - port: 80
      targetPort: 80
```

>```
>#  wget -q --spider http://info.cern.ch
>#        │   │
>#        │   └── Check reachability only — no download
>#        └────── No output — clean terminal ( quiet mode )
>```

---

### Step 10: Deploy and Observe Sequential Init Progression

**Terminal 1 — watch pod status:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply the pod only:**
```bash
kubectl apply -f 04-init-multiple.yaml
```

**Terminal 3 — follow init container #1 logs live:**
```bash
kubectl logs -f microservice-with-inits -c check-external-api
```

**Terminal 1 — Expected output:**
```
NAME                       READY   STATUS     RESTARTS   AGE
microservice-with-inits    0/1     Init:0/2   0          5s   ← Init #1 running
microservice-with-inits    0/1     Init:1/2   0          15s  ← Init #1 done, Init #2 running
                                   ↑
                           Still stuck at 1/2 until the service is created

NAME                      READY   STATUS    RESTARTS   AGE
microservice-with-inits   0/1     Pending    0          0s
microservice-with-inits   0/1     Pending    0          0s
microservice-with-inits   0/1     Init:0/2   0          0s   ← Init #1 running
microservice-with-inits   0/1     Init:1/2   0          2s   ← Init #1 done, Init #2 running
microservice-with-inits   0/1     Init:1/2   0          3s
                                   ↑
                           Still stuck at 1/2 until the service is created
```

**Terminal 3 — Expected output from Init #1:**
```
Init 1: Checking external API...
Init 1: External API reachable. Proceeding to Init 2.
```

When STATUS shows `Init:1/2`, switch Terminal 3 to follow Init #2:

```bash
kubectl logs -f microservice-with-inits -c check-internal-svc
```

**Terminal 3 — Expected output from Init #2 (looping):**
```
Server:         10.96.0.10
Address:        10.96.0.10:53

** server can't find api-svc.default.svc.cluster.local: NXDOMAIN

** server can't find api-svc.default.svc.cluster.local: NXDOMAIN
api-svc not found. Retrying in 3s...
```

Now in **Terminal 2** — create the Service to unblock Init #2:

```bash
kubectl apply -f 04-api-svc.yaml
```

**Terminal 1 — immediately after:**
```
microservice-with-inits    0/1     PodInitializing   0   30s   ← both inits done
microservice-with-inits    1/1     Running           0   31s   ← main app started!

NAME                      READY   STATUS        RESTARTS      AGE
microservice-with-inits   0/1     Pending           0          0s
microservice-with-inits   0/1     Pending           0          0s
microservice-with-inits   0/1     Init:0/2          0          0s
microservice-with-inits   0/1     Init:1/2          0          2s
microservice-with-inits   0/1     Init:1/2          0          3s
microservice-with-inits   0/1     PodInitializing   0          4m53s ← both inits done
microservice-with-inits   1/1     Running           0          4m54s ← main app started!
```

**Terminal 3 — final lines from Init #2:**
```
Name:   api-svc.default.svc.cluster.local
Address: 10.108.74.110


Init 2: api-svc found. Starting main application.
```

**Inspect the `Initialized` condition — confirms all inits completed:**
```bash
kubectl get pod microservice-with-inits -o yaml | grep -A 30 "conditions:"
```

**Expected output (while pod is Running):**
```yaml
  conditions:
  - lastProbeTime: null
    lastTransitionTime: "2026-03-20T13:28:14Z"
    observedGeneration: 1
    status: "True"
    type: PodReadyToStartContainers

  - lastProbeTime: null
    lastTransitionTime: "2026-03-20T13:33:05Z"
    observedGeneration: 1
    status: "True"
    type: Initialized             ← True only after ALL init containers exit 0

  - lastProbeTime: null
    lastTransitionTime: "2026-03-20T13:33:06Z"
    observedGeneration: 1
    status: "True"
    type: Ready

  - lastProbeTime: null
    lastTransitionTime: "2026-03-20T13:33:06Z"
    observedGeneration: 1
    status: "True"
    type: ContainersReady

  - lastProbeTime: null
    lastTransitionTime: "2026-03-20T13:28:12Z"
    observedGeneration: 1
    status: "True"
    type: PodScheduled
```

**Cleanup:**
```bash
kubectl delete -f 04-init-multiple.yaml
kubectl delete -f 04-api-svc.yaml
```

---

### Step 10: Deploy and Observe Sequential Init Progression

**Terminal 1 — watch pod status:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply the pod only:**
```bash
kubectl apply -f 04-init-multiple.yaml
```

**Terminal 3 — follow Init #1 logs live:**
```bash
kubectl logs -f microservice-with-inits -c check-external-api
```

**Terminal 1 — Expected output:**
```
NAME                      READY   STATUS     RESTARTS   AGE
microservice-with-inits   0/1     Pending    0          0s
microservice-with-inits   0/1     Pending    0          0s
microservice-with-inits   0/1     Init:0/2   0          0s   ← Init #1 running
microservice-with-inits   0/1     Init:1/2   0          2s   ← Init #1 done, Init #2 running
microservice-with-inits   0/1     Init:1/2   0          3s   ← stuck here until Service created
```

> **Reading `Init:0/2` and `Init:1/2`:**
> Format is `Init:<completed>/<total>`. `Init:0/2` means 0 of 2 init
> containers have exited 0 — Init #1 is currently running. `Init:1/2`
> means Init #1 exited 0 and Init #2 is now running. STATUS stays at
> `Init:1/2` until the Service is created and Init #2 unblocks.
> READY stays `0/1` throughout — main container has not started at all.

**Terminal 3 — Expected output from Init #1:**
```
Init 1: Checking outbound HTTP connectivity...
Init 1: External HTTP reachable. Proceeding to Init 2.
```

> Init #1 passes quickly — `http://info.cern.ch` is reachable. As soon
> as it exits 0, STATUS flips from `Init:0/2` to `Init:1/2` and Init #2
> starts immediately.

When STATUS shows `Init:1/2`, switch Terminal 3 to Init #2:
```bash
kubectl logs -f microservice-with-inits -c check-internal-svc
```

**Terminal 3 — Expected output from Init #2 (looping until Service exists):**
```
Init 2: Waiting for api-svc to be created...
Server:         10.96.0.10
Address:        10.96.0.10:53

** server can't find api-svc.default.svc.cluster.local: NXDOMAIN
** server can't find api-svc.default.svc.cluster.local: NXDOMAIN
api-svc not found. Retrying in 3s...
```

> `NXDOMAIN` means the DNS name does not exist — CoreDNS has no record
> for `api-svc` because the Service has not been created yet. Init #2
> retries every 3 seconds. The main container is completely blocked.

Now in **Terminal 2** — create the Service to unblock Init #2:
```bash
kubectl apply -f 04-api-svc.yaml
```

**Terminal 1 — immediately after Service is created:**
```
microservice-with-inits   0/1     PodInitializing   0     4m53s ← both inits done
microservice-with-inits   1/1     Running           0     4m54s ← main app started!
```

> `PodInitializing` is a brief transitional status between all inits
> completing and the main container becoming ready. `Running 1/1`
> confirms the main container started and its ready flag is true
> (no readiness probe defined → defaults to true immediately).

**Terminal 3 — final lines from Init #2 after Service is created:**
```
Name:    api-svc.default.svc.cluster.local
Address: 10.108.74.110

Init 2: api-svc found. Starting main application.
```

> CoreDNS resolved `api-svc.default.svc.cluster.local` to `10.108.74.110`
> — the ClusterIP assigned to the Service. Init #2 exits 0. Main
> container starts immediately after.

---

**Validation — Inspect All 5 Pod Conditions**
```bash
kubectl get pod microservice-with-inits -o yaml | grep -A 30 "conditions:"
```

**Expected output:**
```yaml
conditions:
- lastProbeTime: null
  lastTransitionTime: "2026-03-20T13:28:12Z"
  observedGeneration: 1
  status: "True"
  type: PodScheduled                  ← set first — node assigned

- lastProbeTime: null
  lastTransitionTime: "2026-03-20T13:28:14Z"
  observedGeneration: 1
  status: "True"
  type: PodReadyToStartContainers     ← sandbox + CNI ready (2s after scheduled)

- lastProbeTime: null
  lastTransitionTime: "2026-03-20T13:33:05Z"
  observedGeneration: 1
  status: "True"
  type: Initialized                   ← ~5 min after scheduled
                                        set True only after ALL inits exit 0

- lastProbeTime: null
  lastTransitionTime: "2026-03-20T13:33:06Z"
  observedGeneration: 1
  status: "True"
  type: ContainersReady               ← 1s after Initialized

- lastProbeTime: null
  lastTransitionTime: "2026-03-20T13:33:06Z"
  observedGeneration: 1
  status: "True"
  type: Ready                         ← same second as ContainersReady
```

> **What the timestamps tell us:**
>
> ```
> 13:28:12  PodScheduled                ← pod assigned to node
> 13:28:14  PodReadyToStartContainers   ← 2s later, sandbox ready
>
>           (init containers run for ~5 minutes — waiting for Service)
>
> 13:33:05  Initialized                 ← all inits done (Init #2 unblocked)
> 13:33:06  ContainersReady             ← 1s later, main container ready
> 13:33:06  Ready                       ← same second, pod joins Service endpoints
> ```
>
> `PodReadyToStartContainers` flipped at `13:28:14` — the sandbox was
> ready immediately. `Initialized` only flipped at `13:33:05` — nearly
> 5 minutes later, held back entirely by Init #2 waiting for the Service.
> This is exactly the init container guarantee in action: the main
> container start was delayed by 5 minutes because of a missing dependency,
> without any restarts or errors.

**Cleanup:**
```bash
kubectl delete -f 04-init-multiple.yaml
kubectl delete -f 04-api-svc.yaml
```

---

### Part 5: Old Sidecar Pattern vs Native Sidecar (v1.34)


### Step 11: The Problem with the Old Sidecar Pattern

Before Kubernetes v1.28, sidecars were regular containers in `spec.containers[]`.
This caused three known production problems:

```
Problem 1 — Startup order not guaranteed
  Main container starts at the same time as sidecar.
  If sidecar isn't ready yet, first log lines from main are lost.

Problem 2 — Jobs never complete
  Job's main container exits → Job should be Complete.
  BUT the sidecar container is still running → Job never terminates.
  The sidecar holds the pod alive indefinitely.

Problem 3 — Shutdown order not guaranteed
  During pod termination, sidecar may stop BEFORE main container.
  Last log lines during shutdown are lost — exactly when you need them most.
```

---

### Step 12: Demo — Old Sidecar Pattern (All Three Problems)

#### What This Demo Shows

We deploy a Kubernetes `Job` with an old-style sidecar — both in
`spec.containers[]`. The main container logs its lifecycle (started,
running, finished) and exits after 10 seconds. The sidecar logs its
own lifecycle continuously. We observe all three problems through the
log timestamps and the Job's COMPLETIONS counter.

A `Job` is used instead of a plain Pod because Problem 2 only produces
a clear, unambiguous observable outcome with a Job — `0/1 COMPLETIONS`
staying stuck forever makes the impact immediately visible without
needing explanation.

#### YAML

**05-job-old-sidecar.yaml:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: job-old-sidecar
spec:
  template:
    spec:
      restartPolicy: Never

      containers:
        - name: main-job             # Main container — completes in 10 seconds
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              echo "[main]    ▶ STARTED  at $(date +%T)"
              echo "[main]    ● RUNNING  - processing work..."
              sleep 10
              echo "[main]    ■ FINISHED at $(date +%T) — exiting 0"
              exit 0

        - name: sidecar              # Old-style sidecar — in spec.containers[]
          image: busybox:1.36        # No lifecycle guarantee — runs indefinitely
          command:
            - sh
            - -c
            - |
              echo "[sidecar] ▶ STARTED  at $(date +%T)"
              while true; do
                echo "[sidecar] ● RUNNING  at $(date +%T)"
                sleep 3
              done
              echo "[sidecar] ■ STOPPED  at $(date +%T)"
```

**Key YAML Fields Explained:**

- `restartPolicy: Never` — required for Job pods. The Job controller
  manages retries — not Kubelet.
- Both containers in `spec.containers[]` — they start simultaneously
  with no ordering guarantee between them.
- `main-job` echoes `▶ STARTED`, `● RUNNING`, `■ FINISHED` with
  timestamps — startup and shutdown order visible in logs.
- `sidecar` echoes `▶ STARTED` then loops `● RUNNING` every 3 seconds.
  The `■ STOPPED` line will never be reached in the old pattern — the
  sidecar has no way to know the main container has finished.
- `$(date +%T)` prints `HH:MM:SS` — short and directly comparable
  between log lines from different containers.

---

#### Deploy and Observe

**Terminal 1 — watch pod status (appends every change, nothing cleared):**
```bash
kubectl get pods -w
```

**Terminal 2 — apply:**
```bash
kubectl apply -f 05-job-old-sidecar.yaml
```

**Terminal 3 — follow all container logs with container prefix:**
```bash
# Get the pod name from Terminal 1, then:
kubectl logs -f job-old-sidecar-xxxxx --all-containers --prefix
```

> `--all-containers` streams from all containers simultaneously.
> `--prefix` prepends `[pod/container-name]` to each line so you
> can tell which container produced which output.
> Note: logs from each container may appear in batches rather than
> strictly interleaved by timestamp — this is normal buffer flush
> behaviour. Use the timestamps in the log lines to determine actual
> ordering.

---

**Terminal 1 — Expected output:**
```
NAME                    READY   STATUS              RESTARTS   AGE
job-old-sidecar-xxxxx   0/2     Pending             0          0s
job-old-sidecar-xxxxx   0/2     Pending             0          0s      
job-old-sidecar-xxxxx   0/2     ContainerCreating   0          0s
job-old-sidecar-xxxxx   2/2     Running             0          3s      ← both containers started
                        ↑                                                  simultaneously — Problem 1
                    2/2 — both main-job AND sidecar counted in READY
                           started at the same time — no ordering guarantee

job-old-sidecar-xxxxx   1/2     NotReady            0          12s     ← main-job exited (exit 0)
                        ↑   ↑                                              sidecar still running
                        │   └── NotReady — main-job ready=false (exited)   pod cannot complete
                        │        sidecar ready=true (still running)
                        │        pod is NOT Completed — Problem 2 begins
                        └── 1/2 — only sidecar is ready now

job-old-sidecar-xxxxx   1/2     NotReady            0          2m47s   ← same state — periodic watch event
                                                                           pod stuck here since 12s
                                                                           ~2m35s have passed since
                                                                           main-job finished
                                                                           sidecar still running — Problem 2

(kubectl delete issued at this point)

job-old-sidecar-xxxxx   1/2     Terminating         0          2m47s   ← kubectl delete issued
                                                                           SIGTERM sent to ALL containers
                                                                           simultaneously — Problem 3
                                                                           no shutdown ordering guarantee

job-old-sidecar-xxxxx   1/2     Terminating         0          2m47s   
```

> **Reading the full output — what each phase tells us:**
>
> ```
> 0s  → 3s    ContainerCreating → Running 2/2
>             Both containers started at the same time
>             Problem 1: no startup ordering guarantee
>
> 3s  → 12s   Running 2/2
>             Both running — main-job processing work
>
> 12s         Running 2/2 → NotReady 1/2
>             main-job finished (exit 0) and exited
>             sidecar unaware — keeps running
>             Problem 2 begins: Job stuck at 0/1 COMPLETIONS
>
> 12s → 2m47s NotReady 1/2 (no change)
>             ~2m35s of the sidecar running uselessly
>             Job controller waiting — will wait forever
>             Downstream pipeline blocked
>
> 2m47s       Terminating
>             kubectl delete issued
>             SIGTERM sent simultaneously to both containers
>             Problem 3: no shutdown ordering guarantee
>             sidecar may die before main's final messages
> ```

> **Problem 2 visible in Terminal 1:** Pod stays at `1/2 NotReady`
> indefinitely. main-job finished 10 seconds ago — sidecar is still
> running, holding the pod open. The Job will never complete.

**Terminal 2 — check Job status after pod shows `1/2 NotReady`:**
```bash
kubectl get job job-old-sidecar
```

**Expected output:**
```
NAME              STATUS    COMPLETIONS   DURATION   AGE
job-old-sidecar   Running   0/1           90s        90s
                  ↑         ↑
                  │         └── 0 of 1 completions — never finishes
                  └── STATUS = Running — Job controller still waiting
                      In a real pipeline, downstream jobs wait forever
```

> **Problem 2 confirmed:** `COMPLETIONS = 0/1` indefinitely.
> `STATUS = Running` — the Job controller has no idea work is done
> because the sidecar is still alive. A CronJob would think the
> previous run never finished and refuse to start the next one.

---

**Terminal 3 — Expected log output:**
```
[pod/job-old-sidecar-xxxxx/main-job] [main]    ▶ STARTED  at 15:00:04
[pod/job-old-sidecar-xxxxx/main-job] [main]    ● RUNNING  - processing work...
[pod/job-old-sidecar-xxxxx/main-job] [main]    ■ FINISHED at 15:00:14 — exiting 0
                                                           ↑
                                               main-job done at 15:00:14
                                               10 seconds of work completed

[pod/job-old-sidecar-xxxxx/sidecar]  [sidecar] ▶ STARTED  at 15:00:04
                                                           ↑
                                               Problem 1: same second as main
                                               no startup ordering guarantee
                                               if sidecar needed 3s to warm up
                                               first 3 lines of [main] would be lost

[pod/job-old-sidecar-xxxxx/sidecar]  [sidecar] ● RUNNING  at 15:00:04
[pod/job-old-sidecar-xxxxx/sidecar]  [sidecar] ● RUNNING  at 15:00:07
[pod/job-old-sidecar-xxxxx/sidecar]  [sidecar] ● RUNNING  at 15:00:10
[pod/job-old-sidecar-xxxxx/sidecar]  [sidecar] ● RUNNING  at 15:00:13
[pod/job-old-sidecar-xxxxx/sidecar]  [sidecar] ● RUNNING  at 15:00:16
                                                           ↑
                                               Problem 2: 15:00:16 > 15:00:14
                                               sidecar running AFTER main finished
                                               has no way to detect main has exited

[pod/job-old-sidecar-xxxxx/sidecar]  [sidecar] ● RUNNING  at 15:00:19
[pod/job-old-sidecar-xxxxx/sidecar]  [sidecar] ● RUNNING  at 15:00:22
[pod/job-old-sidecar-xxxxx/sidecar]  [sidecar] ● RUNNING  at 15:00:25
                                               (continues indefinitely...)
```

> **Why main-job lines appear first, then sidecar lines?**
> `--all-containers --prefix` buffers output per container and may
> flush in batches rather than strictly interleaving by timestamp.
> This is normal. The timestamps inside the log lines are the source
> of truth for ordering — not the position in the terminal output.
> Both `▶ STARTED` timestamps show `15:00:04` — same second —
> confirming Problem 1 regardless of display order.

**Three problems confirmed through this output:**
```
Problem 1 — [main] ▶ STARTED at 15:00:04
            [sidecar] ▶ STARTED at 15:00:04
            Same second — no ordering guarantee ❌

Problem 2 — [main] ■ FINISHED at 15:00:14
            [sidecar] ● RUNNING at 15:00:16, 15:00:19, 15:00:22...
            Sidecar unaware main exited — Job stuck at 0/1 ❌

Problem 3 — Delete the Job to observe:
            Both containers get SIGTERM simultaneously
            Sidecar may exit before main's final shutdown messages
            Final log lines may be lost ❌
```

**Cleanup — delete the stuck Job:**
```bash
kubectl delete -f 05-job-old-sidecar.yaml
```

---

### Step 13: Demo — Native Sidecar (Kubernetes v1.34 — All Three Problems Solved)

#### What This Demo Shows

We run the **exact same Job** — identical main-job logic, identical
sidecar logic — with one change: the sidecar moves from `spec.containers[]`
to `spec.initContainers[]` with `restartPolicy: Always` added. This single
field change gives Kubernetes full lifecycle control over the sidecar.

We also add a `trap` signal handler to the sidecar so it can print
`■ STOPPED` when it receives SIGTERM during pod termination — making
Problem 3 (shutdown order) visible in the logs.

We observe all three problems resolved through log timestamps and the
Job's COMPLETIONS counter.




#### YAML

**06-job-native-sidecar.yaml:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: job-native-sidecar
spec:
  template:
    spec:
      restartPolicy: Never

      initContainers:
        - name: sidecar              # Native sidecar — moved to initContainers[]
          image: busybox:1.36
          restartPolicy: Always      # ← This single field makes it a native sidecar
                                     #   Starts BEFORE main container
                                     #   Terminates AFTER main container exits
                                     #   Restarts independently if it crashes
          command:
            - sh
            - -c
            - |
              trap 'echo "[sidecar] ■ STOPPED  at $(date +%T)"; exit 0' TERM
              echo "[sidecar] ▶ STARTED  at $(date +%T)"
              while true; do
                echo "[sidecar] ● RUNNING  at $(date +%T)"
                sleep 3
              done

      containers:
        - name: main-job             # Identical to Step 12 — no changes at all
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              echo "[main]    ▶ STARTED  at $(date +%T)"
              echo "[main]    ● RUNNING  - processing work..."
              sleep 10
              echo "[main]    ■ FINISHED at $(date +%T) — exiting 0"
              exit 0
```

**What changed from Step 12 — three lines:**
```
Step 12 (old pattern):            Step 13 (native sidecar):
──────────────────────────────    ──────────────────────────────
spec:                             spec:
  containers:                       initContainers:
    - name: sidecar          →        - name: sidecar
      image: busybox:1.36               image: busybox:1.36
      command:                          restartPolicy: Always     ← added
        - sh                            command:
        - -c                              - sh
        - |                               - -c
          echo "▶ STARTED..."               - |
          while true; do                      trap '...STOPPED...' TERM  ← added
            echo "● RUNNING..."               echo "▶ STARTED..."
            sleep 3                           while true; do
          done                                  echo "● RUNNING..."
          echo "■ STOPPED..."                   sleep 3
                                              done

    - name: main-job                containers:
      command: [...]                  - name: main-job
                                        command: [...]            ← identical
```

The `main-job` command is **identical** to Step 12.
The sidecar command adds only a `trap` handler — the loop logic is identical.
The key structural change is the YAML block (`containers[]` → `initContainers[]`)
and `restartPolicy: Always`.

---

#### Deploy and Observe

**Terminal 1 — watch pod status:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply:**
```bash
kubectl apply -f 06-job-native-sidecar.yaml
```

**Terminal 3 — follow all container logs:**
```bash
# Get the pod name from Terminal 1, then:
kubectl logs -f job-native-sidecar-xxxxx --all-containers --prefix
```

---

**Terminal 1 — Expected output:**
```
NAME                       READY   STATUS              RESTARTS   AGE
job-native-sidecar-xxxxx   0/2     Pending             0          0s
job-native-sidecar-xxxxx   0/2     Pending             0          0s    
job-native-sidecar-xxxxx   0/2     Init:0/1            0          0s    ← sidecar starting
                                   ↑                                       main NOT started yet
                               Problem 1 being solved:
                               sidecar gets a guaranteed head start
                               contrast Step 12: jumped straight to 2/2 Running

job-native-sidecar-xxxxx   1/2     PodInitializing     0          1s
                           ↑
                       1/2 — sidecar Running and ready (counted in READY)
                              main-job still initialising (not yet ready)
                              native sidecar IS counted in READY column

job-native-sidecar-xxxxx   2/2     Running             0          2s    ← main-job started
                           ↑
                       2/2 — both containers Running
                              sidecar was already Running at 1/2
                              before main started — Problem 1 solved

(after ~12 seconds — main-job exits 0)

job-native-sidecar-xxxxx   1/2     Completed           0          12s   ← main-job exited (exit 0)
                           ↑                                               sidecar still running
                       1/2 — main-job ready=false (exited)                 pod NOT yet Completed
                              sidecar ready=true (still running)           Problem 3 being solved

job-native-sidecar-xxxxx   0/2     Completed           0          13s   ← sidecar terminated ✅
                                   ↑
                               Both containers done — pod fully Completed
                               Sidecar ran for ~1s after main exited
                               trap handler caught SIGTERM → clean exit
                               Problem 3 solved

job-native-sidecar-xxxxx   0/2     Completed           0          15s   
job-native-sidecar-xxxxx   0/2     Completed           0          16s   
job-native-sidecar-xxxxx   0/2     Completed           0          100s  
job-native-sidecar-xxxxx   0/2     Completed           0          100s  
```

> **READY column progression tells the full story:**
> ```
> Step 12 (old):     0/2 → 2/2         (both start simultaneously)
> Step 13 (native):  0/2 → 1/2 → 2/2  (sidecar starts first → Problem 1 solved)
> ```
> The extra `1/2` step in Step 13 is visible proof that sidecar
> started and was Running before main container started.


> **Native sidecar container is counted in the READY column — verified from real output:**
>
> The earlier theory in this lab stated native sidecars show `1/1` in
> the READY column because `initContainers[]` entries are not counted.
> This is **correct for regular init containers** but **not for native
> sidecars**.
>
> Native sidecars (`initContainers[]` + `restartPolicy: Always`) are
> a distinct container type. The Kubernetes native sidecar KEP (KEP-753)
> explicitly extended the READY column to include native sidecar status
> alongside regular containers. This is why both steps show `2/2` —
> one for the main container, one for the native sidecar.
>
> ```
> Regular init container   → NOT counted in READY (shows Init:0/1)
>                             vanishes after completion
>                             your init container demos confirm this
>
> Native sidecar           → IS counted in READY (shows 1/2 then 2/2)
>                             runs for pod lifetime
>                             this demo confirms this
> ```
>
> The `Init:0/1` STATUS in Terminal 1 is still shown during the
> startup phase — this is because the native sidecar has not yet
> reached Running state. Once it is Running (transitions to
> `1/2 PodInitializing`), it is counted. The READY column reflects
> the native sidecar's readiness from that point forward — for the
> entire pod lifetime.


**Terminal 2 — check Job status AFTER pod shows `0/2 Completed`:**
```bash
kubectl get job job-native-sidecar
```

**Expected output:**
```
NAME                 STATUS     COMPLETIONS   DURATION   AGE
job-native-sidecar   Complete   1/1           16s        52s   ← Complete ✅
```

> **Important — when to run this check:**
> Run ONLY after Terminal 1 shows `0/2 Completed`. If you run it when
> `1/2 Completed` is showing, the sidecar is still alive and the Job
> will still show `Running 0/1`. The Job controller marks completion
> only after ALL containers (including native sidecar) have terminated.

---

**Terminal 3 — Expected log output:**
```
[pod/job-native-sidecar-xxxxx/sidecar]  [sidecar] ▶ STARTED  at 15:37:22
                                                              ↑
                                                Problem 1 solved:
                                                sidecar starts first
                                                (same second as main but
                                                 Init:0/1 in Terminal 1
                                                 confirms sidecar had
                                                 head start — sub-second
                                                 precision not shown by
                                                 date +%T)

[pod/job-native-sidecar-xxxxx/sidecar]  [sidecar] ● RUNNING  at 15:37:22
[pod/job-native-sidecar-xxxxx/sidecar]  [sidecar] ● RUNNING  at 15:37:25
[pod/job-native-sidecar-xxxxx/sidecar]  [sidecar] ● RUNNING  at 15:37:28
[pod/job-native-sidecar-xxxxx/sidecar]  [sidecar] ● RUNNING  at 15:37:31
[pod/job-native-sidecar-xxxxx/sidecar]  [sidecar] ■ STOPPED  at 15:37:33
                                                              ↑
                                                trap handler caught SIGTERM
                                                15:37:33 > 15:37:32 (main finished)
                                                sidecar outlived main ✅
                                                Problem 3 solved

[pod/job-native-sidecar-xxxxx/main-job] [main]    ▶ STARTED  at 15:37:22
[pod/job-native-sidecar-xxxxx/main-job] [main]    ● RUNNING  - processing work...
[pod/job-native-sidecar-xxxxx/main-job] [main]    ■ FINISHED at 15:37:32 — exiting 0
                                                              ↑
                                                main exits at 15:37:32
                                                sidecar ■ STOPPED at 15:37:33
                                                1 second after main — Problem 3 solved
```

> **Why main lines appear after sidecar lines in the output:**
> `--all-containers --prefix` buffers output per container and may
> flush in batches — not strictly interleaved by timestamp. The
> timestamps inside the log lines are the source of truth for ordering.
> Use Terminal 1's READY progression (`0/2 → 1/2 → 2/2`) as definitive
> proof of startup order — not log line position.

> **Why both `▶ STARTED` timestamps show `15:37:22`:**
> `$(date +%T)` has 1-second resolution. The sidecar did start before
> main — Terminal 1 shows `Init:0/1` (sidecar starting alone) before
> `PodInitializing` (main starting). Both events happened within the
> same second. Use `$(date +%T%3N)` for millisecond precision if you
> need sub-second proof in future demos.

**Three problems confirmed solved:**
```
Problem 1 SOLVED — startup order guaranteed:
  Terminal 1:  0/2 → Init:0/1 → 1/2 PodInitializing → 2/2 Running
               Sidecar was Running (1/2) before main started ✅
  Logs:        [sidecar] ▶ STARTED at 15:37:22
               [main]    ▶ STARTED at 15:37:22
               (same second — but Terminal 1 proves sidecar first)

Problem 2 SOLVED — Job completes:
  Terminal 1:  0/2 Completed at 13s
  Terminal 2:  Complete 1/1 DURATION=16s ✅
               (compare Step 12: Running 0/1 indefinitely)

Problem 3 SOLVED — sidecar outlives main:
  [main]    ■ FINISHED at 15:37:32
  [sidecar] ■ STOPPED  at 15:37:33  ← 1 second AFTER main ✅
  (compare Step 12: ■ STOPPED never printed)
```

> **How and who terminates the native sidecar after main exits:**
>
> **Kubelet** handles this — not the Job controller, not the API server.
>
> Kubelet has a built-in rule for native sidecars:
> *"Once all `spec.containers[]` have exited, send SIGTERM to all native
> sidecars in reverse order of their appearance in `spec.initContainers[]`."*
>
> This rule only applies to native sidecars (`initContainers[]` +
> `restartPolicy: Always`). For old-style sidecars (`spec.containers[]`),
> kubelet has no such rule — they are peer containers with no special
> termination logic. When main exits, they keep running indefinitely.
>
> ```
> Old sidecar (spec.containers[]):
>   main exits → kubelet does nothing special → sidecar runs forever
>   Job controller: containers still running → 0/1 stuck ❌
>
> Native sidecar (initContainers[] + restartPolicy: Always):
>   main exits → kubelet sends SIGTERM to sidecar → sidecar exits
>   Job controller: all containers done → 1/1 Complete ✅
> ```
>
> **Why the sidecar terminated in 1 second here (not 30 seconds):**
> The `trap 'echo ...; exit 0' TERM` handler catches SIGTERM immediately
> and exits cleanly. Without the trap, the shell ignores SIGTERM while
> inside `sleep 3` — kubelet must wait the full `terminationGracePeriodSeconds`
> (default 30s) before sending SIGKILL. The `trap` handler is what makes
> the `■ STOPPED` log line possible — without it, SIGKILL arrives before
> any cleanup code can run.

#### Verify Job Completed Successfully
```bash
kubectl describe job job-native-sidecar
```

**Expected output (key fields):**
```
Pods Statuses:  0 Active (0 Ready) / 1 Succeeded / 0 Failed
Start Time:     Fri, 20 Mar 2026 11:37:21 -0400
Completed At:   Fri, 20 Mar 2026 11:37:37 -0400
Duration:       16s

Events:
  Type    Reason            Age   From            Message
  ----    ------            ----  ----            -------
  Normal  SuccessfulCreate  86s   job-controller  Created pod: job-native-sidecar-xxxxx
  Normal  Completed         70s   job-controller  Job completed   ← ✅
```

**Cleanup:**
```bash
kubectl delete -f 06-job-native-sidecar.yaml
```

---

### Step 14: Side-by-Side Comparison — Old vs Native Sidecar
```
                      Step 12 (old)              Step 13 (native)
                      ──────────────────────────  ─────────────────────────
YAML block            spec.containers[]           spec.initContainers[]
restartPolicy field   absent                      restartPolicy: Always

Problem 1
Startup order         Simultaneous — no guarantee Sidecar starts FIRST ✅
READY progression     0/2 → 2/2 (jump)            0/2 → 1/2 → 2/2 (staged)
Log evidence          [main] and [sidecar]        Terminal 1: Init:0/1 before
                      ▶ STARTED same second ❌    main started ✅

Problem 2
Job completion        0/1 stuck forever ❌        1/1 Complete ✅
After main exits      Sidecar keeps running ❌    Sidecar terminates auto ✅
Terminal 1 evidence   1/2 NotReady indefinitely   0/2 Completed in ~1s ✅

Problem 3
Shutdown order        Race — sidecar may die       Sidecar outlives main ✅
                      before main ❌
Log evidence          ■ STOPPED never printed ❌   ■ STOPPED 1s after main ✅
Mechanism             No trap handler              trap catches SIGTERM → clean exit

READY column          2/2 (both containers)        2/2 (both containers)
                                                   native sidecar IS counted ✅
STATUS during init    0/2 → 2/2 immediately        0/2 → Init:0/1 → 1/2 → 2/2
Kubernetes version    All versions                 v1.33+ stable
```

> **Production note — Per-pod sidecar vs DaemonSet log agent:**
> The per-pod sidecar pattern gives you per-pod routing, filtering,
> and log enrichment flexibility. However at scale it adds resource
> overhead — every pod carries its own helper container. For new
> systems with high pod counts, a **DaemonSet log agent** (one agent
> pod per node) is preferred — collects from all pods on the node
> with no per-pod cost. Per-pod sidecars remain the right choice
> when each pod needs independent logic or for batch workloads.


---

### Part 6: Ambassador and Adapter Patterns — Theory

These patterns are implemented the same way as old-style sidecars (in
`spec.containers[]`) and follow identical YAML structure. The difference is
their **purpose**, not their syntax.

### Ambassador Pattern

A container that acts as a **proxy between the main app and external systems**.
The main app always connects to `localhost` — the ambassador handles
authentication, TLS termination, connection pooling, and retries to the
outside world.

```
┌─────────────────────────────────────────────────────┐
│                    POD                              │
│                                                     │
│  Main App ──► localhost:5000 ──► Ambassador ──► External DB
│  (your code)   (simple call)    (handles TLS,      (complex)
│                                  auth, retry)       │
└─────────────────────────────────────────────────────┘
```

**Real-world example:** Envoy proxy sidecar — handles TLS termination, circuit
breaking, and retry logic so your application only needs to make simple HTTP
calls to localhost.

### Adapter Pattern

A container that **transforms or normalizes data** between the main app and
external consumers. The app emits data in its own format; the adapter converts
it to what the consumer expects.

```
┌─────────────────────────────────────────────────────┐
│                    POD                              │
│                                                     │
│  Main App ──► custom metrics ──► Adapter ──► Prometheus
│  (your code)   (app format)    (converts to        (expects
│                                 OpenMetrics)        OpenMetrics)
└─────────────────────────────────────────────────────┘
```

**Real-world example:** The Kubernetes custom metrics adapter (used with HPA)
converts Prometheus metrics into the Kubernetes custom metrics API format.

---

## Experiments to Try


1. **Prove init containers consume zero resources after completion:**
   ```bash
   kubectl apply -f 03-init-single.yaml
   kubectl apply -f 03-postgres-svc.yaml
   
   # Check resource usage — init containers are not listed
   kubectl top pod webapp-with-init --containers
   # Only shows: webapp (the main container)
   # Init container is gone — no CPU, no memory
   ```

2. **Try to exec into a completed init container:**
   ```bash
   kubectl exec -it webapp-with-init -c wait-for-postgres -- sh
   # Error: container not found
   # Init containers vanish after completion — there is nothing to exec into
   ```

---

## Common Questions

### Q: Why are sidecar/ambassador/adapter in `containers[]` but init containers have their own block?

**A:** Because they have fundamentally different lifecycles. Init containers
run once and exit before the main container starts. All other helper patterns
(sidecar, ambassador, adapter) run alongside the main container for the pod's
lifetime. Kubernetes expresses this distinction through the YAML structure —
`initContainers[]` for run-once patterns, `containers[]` for run-alongside
patterns.

### Q: If a native sidecar is in `initContainers[]`, does it block the main container from starting?

**A:** No — not in the same way a regular init container does. A regular init
container must **exit successfully** before the next container starts. A native
sidecar (with `restartPolicy: Always`) only needs to be in `Running` state
(and pass its startup probe if configured) before the next container starts.
It never exits during normal operation.


### Q: Can I have both init containers AND native sidecars?

**A:** Yes. They both go in `initContainers[]`. Regular init containers (no
`restartPolicy`) run first in sequence. Native sidecars (`restartPolicy: Always`)
start after all regular init containers have succeeded and run alongside the
main containers.

### Q: What happens if a native sidecar crashes?

**A:** The restartPolicy: Always on the native sidecar ensures kubelet
restarts it independently — following its own restart policy, not the pod's. 
The main container continues running uninterrupted. The sidecar's function 
is temporarily interrupted until it restarts.

---

## What You Learned

In this lab, you:
- ✅ Proved that containers in a pod communicate via `localhost` (shared network namespace)
- ✅ Mounted the same volume with different access modes (`ReadWrite` vs `ReadOnly`)
- ✅ Used a single init container to gate main container startup on service DNS availability
- ✅ Chained two init containers in sequence — `Init:0/2 → Init:1/2 → Running`
- ✅ Explained why init containers are NOT counted in the READY column
- ✅ Deployed the old-style sidecar pattern (regular container in `containers[]`)
- ✅ Demonstrated all three old sidecar problems using a Job —
     startup race (Problem 1), Job never completes (Problem 2),
     shutdown race (Problem 3) — with real log timestamps and
     READY column evidence
- ✅ Deployed native sidecar (v1.34) and observed all three
     problems solved — verified through Terminal 1 READY
     progression (0/2 → 1/2 → 2/2), Job COMPLETIONS (1/1),
     and log timestamps ([sidecar] ■ STOPPED after [main] ■ FINISHED)
- ✅ Explained all three problems native sidecars solve (startup order, job completion, shutdown order)
- ✅ Understood ambassador (external proxy) and adapter (data transformation) as patterns, not new YAML blocks


**Key Takeaway:** Multi-container pods enable decoupling of concerns through
well-defined patterns. Init containers enforce prerequisites. Native sidecars
(v1.34) provide the strongest lifecycle guarantees for helper containers —
starting before the main app and terminating after it. The difference between
sidecar, ambassador, and adapter is their purpose, not their syntax — they all
live in `spec.containers[]`.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get pods -w` | Watch init progression (`Init:0/2 → Init:1/2 → Running`) |
| `kubectl logs <pod> -c <container>` | Logs from a specific container |
| `kubectl logs <pod> -c <init-container>` | Logs from a specific init container |
| `kubectl exec -it <pod> -c <container> -- /bin/sh` | Exec into specific container |
| `kubectl get pod <n> -o jsonpath='{.spec.initContainers[*].name}'` | List init container names |
| `kubectl get pod <n> -o jsonpath='{.spec.containers[*].name}'` | List main container names |
| `kubectl describe pod <n>` | Shows Init Containers and Containers sections separately |

---

## Troubleshooting

**Init container stuck in `Init:0/1`?**
```bash
kubectl logs <pod> -c <init-container-name>
# Read the output — is it waiting for a Service? A URL?
kubectl describe pod <pod>
# Check Events section for any image pull errors
```

**Pod shows `Init:Error`?**
```bash
kubectl logs <pod> -c <init-container-name> --previous
# Check what caused the non-zero exit
```

**Native sidecar not starting?**
```bash
kubectl describe pod <pod>
# Check if restartPolicy: Always is correctly inside initContainers entry
# Common mistake: putting restartPolicy at pod level, not inside initContainers entry
```

---

## CKA Certification Tips

✅ **`initContainers[]` is a separate block** under `spec` — same level as `containers[]`:
```yaml
spec:
  initContainers:       # ← separate block
    - name: init-1
      image: busybox:1.36
      command: ["sh", "-c", "echo done"]
  containers:           # ← separate block
    - name: main-app
      image: nginx:1.27
```

✅ READY column — what is counted and what is not:

Regular init containers  → NOT counted (invisible to READY column)
```bash
  0/1  Init:0/1  → init running, main not started
  1/1  Running   → main ready (init completed and vanished)
```
Native sidecars          → ARE counted (KEP-753 extended READY column)
(restartPolicy: Always)
```bash
  0/2  Init:0/1  → sidecar starting (not yet Running)
  1/2  PodInitializing → sidecar Running, main starting
  2/2  Running   → both sidecar and main ready
  1/2  Completed → main exited, sidecar still running
  0/2  Completed → both terminated — Job complete
```

✅ **Init container status in STATUS column:**
```bash
Init:0/2    → 0 of 2 init containers done
Init:1/2    → 1 of 2 done, 2nd running
PodInitializing → all inits done, main container starting
```

✅ **Generate multi-container pod YAML fast:**
```bash
kubectl run my-pod --image=nginx:1.27 --dry-run=client -o yaml > pod.yaml
# Then manually add initContainers block above containers
```

✅ Native sidecar — one field (add trap handler for clean shutdown):
```yaml
initContainers:
  - name: my-sidecar
    image: busybox:1.36
    restartPolicy: Always          # ← this one field makes it a native sidecar
    command:
      - sh
      - -c
      - |
        trap 'echo "sidecar stopping"; exit 0' TERM
        while true; do sleep 5; done
```

✅ **Exec into specific container in multi-container pod — always use `-c`:**
```bash
kubectl exec -it <pod> -c <container-name> -- /bin/sh
# Without -c, kubectl picks the first container — may not be what you want
```
