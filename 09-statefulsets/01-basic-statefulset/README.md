# Basic StatefulSet — Stable Identity, Ordered Lifecycle, Headless Service

## Lab Overview

This lab introduces StatefulSets — the Kubernetes workload designed for
applications that need persistent identity. Unlike a Deployment (where pods
are interchangeable and replaceable), a StatefulSet gives each pod a stable,
predictable name that survives restarts, a stable network hostname, and a
guaranteed ordered startup and shutdown sequence.

StatefulSets are the right workload for databases, message queues, distributed
caches, and any application where the identity of each instance matters —
where "which pod am I?" affects the application's behaviour.

In this lab the workload is a plain nginx container so all attention stays on
the StatefulSet object itself: its controller, its naming convention, its
headless service, and its ordered lifecycle. Persistent storage is added in
Lab 02. Scaling and update strategies are covered in Lab 03.

**What you'll do:**
- Understand the StatefulSet controller and how it differs from Deployment and DaemonSet
- Walk through every field in the StatefulSet manifest
- Deploy a StatefulSet and observe stable pod names (`web-0`, `web-1`, `web-2`)
- Understand the Headless Service — why StatefulSets need it and what DNS it creates
- Verify per-pod stable DNS records from inside the cluster
- Observe ordered startup: pods created strictly in order 0 → 1 → 2
- Observe ordered shutdown: pods terminated strictly in reverse order 2 → 1 → 0
- Delete a StatefulSet pod and verify it is recreated with the same name on the same node
- Inspect ControllerRevision objects — StatefulSet rollout history
- Clean up resources correctly

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control-plane + 2 worker nodes
- kubectl installed and configured

**Verify your cluster:**
```bash
kubectl get nodes
# NAME        STATUS   ROLES           AGE
# 3node       Ready    control-plane
# 3node-m02   Ready    <none>
# 3node-m03   Ready    <none>
```

**Knowledge Requirements:**
- **REQUIRED:** Completion of `02-deployments/01-basic-deployment`
- **RECOMMENDED:** Completion of `03-daemonsets/01-basic-daemonset`
- Understanding of Kubernetes Services and DNS

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain how the StatefulSet controller differs from Deployment and DaemonSet controllers
2. ✅ Explain every field in the StatefulSet manifest and its valid values
3. ✅ Explain why a StatefulSet requires a Headless Service
4. ✅ Explain the DNS records a Headless Service creates per pod
5. ✅ Verify stable pod names survive pod deletion and restart
6. ✅ Observe ordered startup (0 → 1 → 2) and ordered shutdown (2 → 1 → 0)
7. ✅ Explain `podManagementPolicy: Parallel` and when to use it
8. ✅ Inspect ControllerRevision objects for StatefulSet rollout history
9. ✅ Read all columns of `kubectl get statefulset` output
10. ✅ Clean up StatefulSet resources in the correct order

## Directory Structure

```
01-basic-statefulset/
└── src/
    ├── nginx-headless-service.yaml   # Headless Service — required for StatefulSet DNS
    └── nginx-statefulset.yaml        # StatefulSet — nginx:1.27, 3 replicas
```

---

## Understanding StatefulSets

### The Three Workload Controllers Side by Side

```
Deployment Controller
  Input:   desired replica count (replicas: 3)
  Places:  pods anywhere the scheduler chooses
  Names:   random suffix   nginx-7d8f9-abc12, nginx-7d8f9-def34
  If pod dies: recreated with a NEW random name, possibly on a different node
  Use for: stateless apps — web servers, APIs, workers

DaemonSet Controller
  Input:   cluster node list
  Places:  exactly one pod per matching node
  Names:   random suffix   nginx-ds-4xk2p, nginx-ds-7mnbq
  If pod dies: recreated with a NEW random name on the SAME node
  Use for: node-local infrastructure — log collectors, monitoring agents

StatefulSet Controller
  Input:   desired replica count (replicas: 3)
  Places:  pods in order, one at a time
  Names:   ordinal suffix  web-0, web-1, web-2  ← STABLE, PREDICTABLE
  If pod dies: recreated with the SAME name on any available node
  Use for: stateful apps — databases, message queues, distributed caches
```

### What "Stable Identity" Means

A StatefulSet pod's identity has three components that persist across restarts:

```
Identity component    How it is expressed
──────────────────────────────────────────────────────────────────
1. Stable name        web-0, web-1, web-2
                      Pod name never changes — regardless of which node it runs on

2. Stable DNS         web-0.nginx.default.svc.cluster.local
                      Headless Service creates one DNS A record per pod
                      DNS resolves to the pod's current IP even after restart

3. Stable storage     (Lab 02) — each pod gets its own PVC, bound by ordinal
                      web-0 always gets pvc-web-0, web-1 gets pvc-web-1
                      PVC survives pod deletion — data persists

In a Deployment:
  If pod nginx-7d8f9-abc12 dies → new pod nginx-7d8f9-xyz99
  Different name, different DNS (ClusterIP service round-robins, no per-pod DNS)
  No guaranteed storage binding

In a StatefulSet:
  If pod web-1 dies → new pod web-1 (same name)
  Same DNS record (web-1.nginx.default.svc.cluster.local)
  Same PVC (pvc-web-1) — data intact
```

### The StatefulSet Controller — Reconcile Loop

```
StatefulSet Controller (inside kube-controller-manager)
    │
    ├── WATCH: StatefulSet spec changes
    ├── WATCH: pod list owned by this StatefulSet
    │
    └── RECONCILE:
            Current state: [web-0 Running, web-1 Running]
            Desired state: replicas: 3

            Step 1: web-0 exists and is Ready? YES → proceed
            Step 2: web-1 exists and is Ready? YES → proceed
            Step 3: web-2 exists? NO → CREATE web-2 (in order, after web-1 is Ready)

            On scale-down (replicas: 2):
            Step 1: delete highest ordinal first → delete web-2
            Step 2: only after web-2 is fully terminated → delete web-1
            (web-0 stays — target is replicas: 2)
```

**The "Ready Gate":** The StatefulSet controller waits for pod N to be
`Running` and `Ready` before creating pod N+1. This is what makes ordered
startup meaningful — each pod proves it is healthy before the next one starts.

### Why a StatefulSet Needs a Headless Service

A regular ClusterIP Service load-balances traffic across all matching pods.
If you query `nginx.default.svc.cluster.local`, DNS returns the Service's
virtual IP and iptables routes to any pod — you cannot target a specific pod.

StatefulSets need the opposite: a DNS record that resolves to each individual
pod. This requires a **Headless Service** — a Service with `clusterIP: None`.

```
Regular ClusterIP Service:
  nginx.default.svc.cluster.local → 10.96.100.100 (virtual IP)
  iptables routes 10.96.100.100 to any of: web-0, web-1, web-2
  You cannot address web-1 specifically

Headless Service (clusterIP: None):
  nginx.default.svc.cluster.local → [10.244.0.5, 10.244.1.8, 10.244.2.3]
                                      (all pod IPs returned directly)
  web-0.nginx.default.svc.cluster.local → 10.244.0.5 (web-0's IP only)
  web-1.nginx.default.svc.cluster.local → 10.244.1.8 (web-1's IP only)
  web-2.nginx.default.svc.cluster.local → 10.244.2.3 (web-2's IP only)

  When web-1 restarts with a new IP (10.244.1.99):
  web-1.nginx.default.svc.cluster.local → 10.244.1.99 (DNS auto-updates)
  The application still uses the same hostname to reach web-1
```

**Why this matters for databases:**
In a MySQL replica set, the primary is always `mysql-0`. Replicas always
connect to `mysql-0.mysql.default.svc.cluster.local` to replicate. If the
primary pod restarts on a different node, its hostname stays `mysql-0` and
its DNS record updates — replicas reconnect automatically without any
configuration change.

### DNS Record Structure

For a StatefulSet named `web` with a Headless Service named `nginx` in
namespace `default`:

```
Per-pod A records (one per pod):
  web-0.nginx.default.svc.cluster.local → <web-0 pod IP>
  web-1.nginx.default.svc.cluster.local → <web-1 pod IP>
  web-2.nginx.default.svc.cluster.local → <web-2 pod IP>

  Format: <pod-name>.<service-name>.<namespace>.svc.cluster.local

Service A record (returns all pod IPs — no load balancing):
  nginx.default.svc.cluster.local → [<web-0 IP>, <web-1 IP>, <web-2 IP>]

Short forms (from within the same namespace):
  web-0.nginx          → resolves to web-0's IP
  web-0.nginx.default  → resolves to web-0's IP
```

### StatefulSet vs Deployment — When to Use Each

| Scenario | Use |
|----------|-----|
| Web server, API, background worker | Deployment — pods are interchangeable |
| Redis, Memcached single-instance cache | Deployment — no per-pod identity needed |
| MySQL, PostgreSQL primary | StatefulSet — `mysql-0` is always the primary |
| MySQL replicas | StatefulSet — replicas identify themselves to primary by stable hostname |
| Kafka, RabbitMQ broker cluster | StatefulSet — each broker has a stable ID |
| Zookeeper quorum | StatefulSet — quorum membership uses stable hostnames |
| Elasticsearch data nodes | StatefulSet — each node stores its own shard data |
| Prometheus (single instance) | Deployment — no per-pod identity needed |

**The deciding question:** Does the application need to know which instance
it is, or does it need other instances to reach it by a stable address?
If yes → StatefulSet. If no → Deployment.

---

## StatefulSet Manifest — Every Field Explained

### nginx-headless-service.yaml

**nginx-headless-service.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx             # This name becomes part of every pod's DNS hostname:
                          # <pod-name>.nginx.<namespace>.svc.cluster.local
  namespace: default
  labels:
    app: nginx
spec:
  clusterIP: None         # ← This is what makes it Headless.
                          #   None = no virtual IP assigned.
                          #   DNS returns pod IPs directly.
                          #   Required for StatefulSet per-pod DNS records.

  selector:
    app: nginx            # Selects pods with this label (the StatefulSet pods)

  ports:
    - name: http
      port: 80
      targetPort: 80

  # publishNotReadyAddresses: false (default)
  # When false: only Ready pods appear in DNS.
  # When true:  all pods appear in DNS even before they pass readiness probe.
  # Set to true for applications that need to discover peers before they are
  # fully ready (e.g. Elasticsearch cluster formation, Zookeeper quorum setup).
  publishNotReadyAddresses: false
```

**Key field — `clusterIP: None`:**

| Value | Behaviour |
|-------|-----------|
| omitted or `""` | Kubernetes assigns a ClusterIP (load-balanced virtual IP) |
| `None` | Headless — no ClusterIP assigned, DNS returns pod IPs directly |
| specific IP | Kubernetes uses that IP as the ClusterIP |

The Headless Service **must be created before the StatefulSet**. The StatefulSet
references the service by name in `spec.serviceName`. If the service does not
exist at StatefulSet creation time, pods will still be created but their DNS
records will not be set up correctly.

---

### nginx-statefulset.yaml

**nginx-statefulset.yaml:**
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web               # StatefulSet name. Pod names derive from this:
                          # web-0, web-1, web-2
  namespace: default
  labels:
    app: nginx
spec:

  # ── Service binding ───────────────────────────────────────────────────
  serviceName: nginx      # REQUIRED. Must match the Headless Service name.
                          # The controller uses this to construct per-pod DNS:
                          # web-0.nginx.default.svc.cluster.local

  # ── Replica count ─────────────────────────────────────────────────────
  replicas: 3             # Pods created in order: web-0 → web-1 → web-2
                          # Each waits for previous to be Running + Ready
                          # before the next is created.

  # ── Selector ─────────────────────────────────────────────────────────
  selector:
    matchLabels:
      app: nginx          # Must match template.metadata.labels exactly.
                          # Immutable after creation.

  # ── Pod Management Policy ─────────────────────────────────────────────
  podManagementPolicy: OrderedReady
  # OrderedReady (default):
  #   Start: web-0 must be Ready before web-1 starts, web-1 before web-2
  #   Stop:  web-2 terminated before web-1, web-1 before web-0
  #   Use for: databases, distributed systems with leader election
  #
  # Parallel:
  #   Start: all pods created simultaneously — no ordering enforced
  #   Stop:  all pods terminated simultaneously
  #   Use for: stateless-like stateful apps where startup order doesn't matter
  #   Example: a distributed cache where any node can join at any time

  # ── Update Strategy ──────────────────────────────────────────────────
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0
      # partition: N means only pods with ordinal >= N are updated.
      # partition: 0 = update all pods (default behaviour).
      # partition: 2 = only web-2 is updated; web-0 and web-1 keep old version.
      # Used for canary updates on StatefulSets — see Lab 03.
  # type: OnDelete = pods only updated when manually deleted (like DaemonSet)

  # ── Revision History ─────────────────────────────────────────────────
  revisionHistoryLimit: 10
  # Number of ControllerRevision objects to keep for rollback.
  # Same mechanism as DaemonSet (not ReplicaSets like Deployment).

  # ── Pod Template ─────────────────────────────────────────────────────
  template:
    metadata:
      labels:
        app: nginx        # Must match spec.selector.matchLabels
    spec:
      # terminationGracePeriodSeconds: 10 (default: 30)
      # For databases: set high enough for in-flight transactions to complete.
      # For this lab: 10s is fine for nginx.
      terminationGracePeriodSeconds: 10

      containers:
        - name: nginx
          image: nginx:1.27

          ports:
            - name: http
              containerPort: 80

          # readinessProbe: critical for StatefulSet ordered startup.
          # The controller uses readiness to gate the next pod's creation.
          # Without a probe, Kubernetes considers the pod Ready immediately
          # after the container starts — which may be before nginx is serving.
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3

          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"

  # ── Volume Claim Templates ────────────────────────────────────────────
  # Not used in this lab — added in Lab 02 (StatefulSet with Persistent Storage).
  # volumeClaimTemplates:
  #   - metadata:
  #       name: data
  #     spec:
  #       accessModes: [ReadWriteOnce]
  #       storageClassName: standard
  #       resources:
  #         requests:
  #           storage: 1Gi
```

**Key field summary:**

| Field | Valid Values | Meaning |
|-------|-------------|---------|
| `serviceName` | any Service name | Headless Service that provides pod DNS |
| `replicas` | integer ≥ 0 | Number of pods (created/deleted in ordinal order) |
| `podManagementPolicy` | `OrderedReady` \| `Parallel` | Controls startup/shutdown ordering |
| `updateStrategy.type` | `RollingUpdate` \| `OnDelete` | How pods are updated on template change |
| `updateStrategy.rollingUpdate.partition` | integer 0–N | Only update pods with ordinal ≥ partition |
| `revisionHistoryLimit` | integer | ControllerRevision objects kept for rollback |

---

## Lab Step-by-Step Guide

### Step 1: Verify kube-dns Is Running

StatefulSet per-pod DNS requires kube-dns (or CoreDNS) to be healthy:

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

**Expected output:**
```
NAME                       READY   STATUS    AGE
coredns-xxxxxxxxx-xxxxx    1/1     Running   1h
```

CoreDNS pods are `Running` and `Ready`.

---

### Step 2: Deploy the Headless Service First

```bash
cd 01-basic-statefulset/src
kubectl apply -f nginx-headless-service.yaml
```

**Expected output:**
```
service/nginx created
```

**Verify it is headless:**
```bash
kubectl get service nginx
```

**Expected output:**
```
NAME    TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
nginx   ClusterIP   None         <none>        80/TCP    5s
```

`CLUSTER-IP: None` — this is the headless service. No virtual IP assigned.

```bash
kubectl describe service nginx
```

Key lines:
```
Type:      ClusterIP
IP Family: IPv4
IP:        None          ← confirms headless
Selector:  app=nginx
Endpoints: <none>        ← no pods yet
```

---

### Step 3: Deploy the StatefulSet

```bash
kubectl apply -f nginx-statefulset.yaml
```

**Expected output:**
```
statefulset.apps/web created
```

---

### Step 4: Observe Ordered Startup

Open Terminal 1 and watch pods appear:

```bash
kubectl get pods -w
```

**Terminal 1 — expected sequence:**
```
NAME    READY   STATUS              RESTARTS   AGE
web-0   0/1     Pending             0          0s    ← web-0 created first
web-0   0/1     ContainerCreating   0          1s
web-0   0/1     Running             0          3s    ← Running but not yet Ready
web-0   1/1     Running             0          8s    ← web-0 is Ready ✅
                                                       controller now creates web-1
web-1   0/1     Pending             0          8s
web-1   0/1     ContainerCreating   0          9s
web-1   1/1     Running             0          14s   ← web-1 is Ready ✅
                                                       controller now creates web-2
web-2   0/1     Pending             0          14s
web-2   0/1     ContainerCreating   0          15s
web-2   1/1     Running             0          20s   ← web-2 is Ready ✅
```

**What to observe:**
- Pods appear one at a time — never two in parallel
- Each pod waits until the previous one passes its readiness probe
- Pod names are `web-0`, `web-1`, `web-2` — not random suffixes
- Ordinals are sequential from 0

---

### Step 5: Read the StatefulSet Status Columns

```bash
kubectl get statefulset web
```

**Expected output:**
```
NAME   READY   AGE
web    3/3     45s
```

**Column meanings:**

| Column | Meaning |
|--------|---------|
| `NAME` | StatefulSet name |
| `READY` | `ready_pods/desired_pods` — 3/3 means all 3 pods are Running and Ready |
| `AGE` | Time since StatefulSet was created |

StatefulSet status is simpler than Deployment — there is no `UP-TO-DATE` or
`AVAILABLE` column. Use `kubectl describe` for full detail.

```bash
kubectl describe statefulset web
```

**Key sections:**
```
Name:               web
Namespace:          default
Replicas:           3 desired | 3 total
Update Strategy:    RollingUpdate
  Partition:        0
Pod Management Policy: OrderedReady
Selector:           app=nginx
Service Name:       nginx

Pods Status:        3 Running / 0 Waiting / 0 Succeeded / 0 Failed

Pod Template:
  Labels: app=nginx
  Containers:
   nginx: nginx:1.27

Events:
  Normal  SuccessfulCreate  pod/web-0 created
  Normal  SuccessfulCreate  pod/web-1 created
  Normal  SuccessfulCreate  pod/web-2 created
```

---

### Step 6: Verify Stable Pod Names

```bash
kubectl get pods -l app=nginx -o wide
```

**Expected output:**
```
NAME    READY   STATUS    NODE        IP
web-0   1/1     Running   3node       10.244.0.5
web-1   1/1     Running   3node-m02   10.244.1.8
web-2   1/1     Running   3node-m03   10.244.2.3
```

Three observations:
1. Names are `web-0`, `web-1`, `web-2` — ordinal, predictable
2. Pods are on different nodes — the scheduler placed them normally
3. Each has a unique IP — they are distinct network endpoints

**Verify no ReplicaSet exists** (StatefulSet manages pods directly like DaemonSet):
```bash
kubectl get replicasets -l app=nginx
# No resources found in default namespace.
```

---

### Step 7: Verify Per-Pod DNS Records

DNS records are created automatically by CoreDNS + the Headless Service.
Verify them from inside the cluster using a temporary pod:

```bash
kubectl run dns-test --image=registry.k8s.io/e2e-test-images/agnhost:2.43 --restart=Never -it --rm \
  --command -- sh -c "
    echo '=== Service DNS (returns all pod IPs) ==='
    nslookup nginx.default.svc.cluster.local

    echo '=== Per-pod DNS records ==='
    nslookup web-0.nginx.default.svc.cluster.local
    nslookup web-1.nginx.default.svc.cluster.local
    nslookup web-2.nginx.default.svc.cluster.local
  "
```

**Expected output:**
```
=== Service DNS (returns all pod IPs) ===
Server:         10.96.0.10
Address:        10.96.0.10#53

Name:   nginx.default.svc.cluster.local
Address: 10.244.0.5
Name:   nginx.default.svc.cluster.local
Address: 10.244.1.9
Name:   nginx.default.svc.cluster.local
Address: 10.244.2.9

=== Per-pod DNS records ===
Server:         10.96.0.10
Address:        10.96.0.10#53

Name:   web-0.nginx.default.svc.cluster.local
Address: 10.244.2.9

Server:         10.96.0.10
Address:        10.96.0.10#53

Name:   web-1.nginx.default.svc.cluster.local
Address: 10.244.1.9

Server:         10.96.0.10
Address:        10.96.0.10#53

Name:   web-2.nginx.default.svc.cluster.local
Address: 10.244.0.5

pod "dns-test" deleted from default namespace
```

**What this proves:**
- The headless service DNS returns all three pod IPs simultaneously
- Each pod has its own A record resolving to only that pod's IP
- These records are what applications use to address specific instances

**Short form DNS** (from inside the same namespace):
```bash
kubectl run dns-test --image=registry.k8s.io/e2e-test-images/agnhost:2.43 --restart=Never -it --rm \
--command -- nslookup web-0.nginx
```

`web-0.nginx` resolves — the search domain (`.default.svc.cluster.local`)
is automatically appended by kube-dns inside the cluster.

---

### Step 8: Verify Stable Identity After Pod Deletion

Delete `web-1` and watch what happens:

```bash
# Terminal 1 — watch
kubectl get pods -w

# Terminal 2 — delete web-1
kubectl delete pod web-1
```

**Terminal 1 — expected sequence:**
```
NAME    READY   STATUS        NODE        IP
web-0   1/1     Running       3node       10.244.0.5
web-1   1/1     Running       3node-m02   10.244.1.8
web-2   1/1     Running       3node-m03   10.244.2.3

web-1   1/1     Terminating   3node-m02   10.244.1.8   ← deleted
web-1   0/1     Pending       <none>      <none>        ← recreated immediately
web-1   0/1     ContainerCreating   3node-m02            ← same node (scheduler chose it)
web-1   1/1     Running       3node-m02   10.244.1.9   ← Running — note new IP
```

**Critical observations:**
- The new pod is named `web-1` — the same name
- It may land on the same node or a different one (scheduler decides)
- The IP changed (`10.244.1.8` → `10.244.1.9`) — IPs are not stable
- But the DNS record `web-1.nginx.default.svc.cluster.local` updates automatically

**Verify DNS updated after pod restart:**
```bash
kubectl run dns-test --image=registry.k8s.io/e2e-test-images/agnhost:2.43 \
--restart=Never -it --rm \
--command -- nslookup web-1.nginx.default.svc.cluster.local
```

**Expected output:**
```
Name:      web-1.nginx.default.svc.cluster.local
Address 1: 10.244.1.9    ← new IP — DNS auto-updated
```

The IP changed but the hostname is permanent. Applications using
`web-1.nginx.default.svc.cluster.local` reconnect automatically after
the pod restarts — no configuration change required.

---

### Step 9: Observe Pod Identity from Inside the Pod

Each pod can discover its own identity from its hostname:

```bash
# web-0 knows it is web-0
kubectl exec web-0 -- hostname
# web-0

kubectl exec web-1 -- hostname
# web-1

kubectl exec web-2 -- hostname
# web-2
```

**The full hostname:**
```bash
kubectl exec web-0 -- hostname -f
# web-0.nginx.default.svc.cluster.local
```

This is how a database like MySQL uses StatefulSets: the pod reads its own
hostname to determine its role. `web-0` → primary. `web-1`, `web-2` → replicas.
No external configuration file needed — the ordinal is the identity.

---

### Step 10: Observe Ordered Shutdown (Scale Down)

```bash
# Terminal 1 — watch
kubectl get pods -l app=nginx -w

# Terminal 2 — scale down from 3 to 1
kubectl scale statefulset web --replicas=1
```

**Terminal 1 — expected sequence:**
```
NAME    READY   STATUS        NODE
web-0   1/1     Running       3node
web-1   1/1     Running       3node-m02
web-2   1/1     Running       3node-m03

web-2   1/1     Terminating   3node-m03   ← highest ordinal deleted first
web-2   0/0     Terminating   3node-m03
                                           ← web-2 fully terminated
web-1   1/1     Terminating   3node-m02   ← next highest ordinal
web-1   0/0     Terminating   3node-m02
                                           ← web-1 fully terminated
                                           ← web-0 stays (target: replicas=1)
web-0   1/1     Running       3node
```

**Why reverse order matters:** In a database cluster, replicas must shut
down before the primary. The replica with ordinal 2 shuts down first, then
ordinal 1, and the primary (ordinal 0) shuts down last — ensuring no data
is lost and no replica tries to connect to an already-gone primary.

```bash
# Scale back up to 3
kubectl scale statefulset web --replicas=3
```

Watch Terminal 1 — pods reappear in order: `web-1` first, then `web-2`.
`web-0` was already running so it is not recreated.

---

### Step 11: Inspect ControllerRevision — Rollout History

StatefulSets (like DaemonSets) store rollout history in `ControllerRevision`
objects, not in ReplicaSets:

```bash
kubectl get controllerrevisions -l app=nginx
```

**Expected output:**
```
NAME             CONTROLLER              REVISION   AGE
web-xxxxxxxxxx   statefulset.apps/web    1          10m
```

Each revision stores a snapshot of the pod template. Used by `kubectl rollout undo`.

```bash
# Check rollout status
kubectl rollout status statefulset/web
# partitioned roll out complete: 3 new pods have been updated...

# Check rollout history
kubectl rollout history statefulset/web
# REVISION  CHANGE-CAUSE
# 1         <none>
```

---

### Step 12: Verify Endpoints in the Headless Service

```bash
kubectl get endpoints nginx
```

**Expected output (3 replicas):**
```
NAME    ENDPOINTS                                       AGE
nginx   10.244.0.5:80,10.244.1.9:80,10.244.2.3:80     15m
```

Three endpoints — one per pod. With a regular ClusterIP service this would
be hidden behind a virtual IP. With the Headless Service, the raw pod IPs
are exposed directly. Applications that need to connect to specific pods
(like database drivers with built-in cluster awareness) use these endpoints.

---

### Step 13: Cleanup

StatefulSets do NOT automatically delete PersistentVolumeClaims when deleted.
In this lab there are no PVCs (added in Lab 02), so cleanup is straightforward.

```bash
# Delete in reverse creation order: StatefulSet first, then Service
kubectl delete statefulset web
kubectl delete service nginx
```

**Watch pods terminate in order:**
```bash
kubectl get pods -l app=nginx -w
# web-2 terminates first, then web-1, then web-0
```

**Verify complete removal:**
```bash
kubectl get statefulset
kubectl get service nginx
kubectl get pods -l app=nginx
# All empty
```

> **Lab 02 note:** After creating a StatefulSet with `volumeClaimTemplates`,
> deleting the StatefulSet does NOT delete the PVCs. They must be deleted
> separately: `kubectl delete pvc -l app=nginx`

---

## Experiments to Try

1. **Test `podManagementPolicy: Parallel`:**
   ```bash
   # Edit the StatefulSet to use Parallel
   kubectl patch statefulset web \
     --type=merge \
     -p '{"spec":{"podManagementPolicy":"Parallel"}}'
   # Note: podManagementPolicy is immutable after creation
   # You need to delete and recreate the StatefulSet

   # Delete and recreate with Parallel policy, then scale:
   kubectl scale statefulset web --replicas=0
   # Watch: all pods terminate simultaneously (not one-by-one)
   kubectl scale statefulset web --replicas=3
   # Watch: all pods start simultaneously
   ```

2. **Verify pod identity is self-discoverable:**
   ```bash
   # Each pod extracts its own ordinal from its hostname
   for pod in web-0 web-1 web-2; do
     echo -n "$pod sees itself as: "
     kubectl exec $pod -- hostname
   done
   ```

3. **DNS short-form lookup:**
   ```bash
   kubectl run debug --image=busybox:1.36 --restart=Never -it --rm \
     -- sh -c "
       for i in 0 1 2; do
         echo -n \"web-\$i.nginx resolves to: \"
         nslookup web-\$i.nginx 2>/dev/null | grep Address | tail -1
       done
     "
   ```

4. **Observe `publishNotReadyAddresses` behaviour:**
   ```bash
   # Patch the service to publish unready pod addresses
   kubectl patch service nginx \
     --type=merge \
     -p '{"spec":{"publishNotReadyAddresses":true}}'

   # Delete a pod and immediately check DNS — the pod's address
   # will appear in DNS even before it passes readiness probe
   kubectl delete pod web-1
   kubectl run dns-test --image=busybox:1.36 --restart=Never -it --rm \
     -- nslookup nginx.default.svc.cluster.local
   # web-1's new IP appears immediately, before the pod is Ready
   ```

---

## Common Questions

### Q: Why can't I use `kubectl scale` on a StatefulSet like a Deployment?
**A:** You can — `kubectl scale statefulset web --replicas=5` works fine.
The difference is the behaviour: scaling up creates new pods in ordinal order
(web-3 before web-4), and scaling down deletes in reverse ordinal order (web-4
before web-3). The `kubectl scale` command works but the controller enforces ordering.

### Q: What happens if I delete the Headless Service while the StatefulSet is running?
**A:** The pods keep running but their DNS records stop resolving — CoreDNS
can only create DNS records for pods whose Service still exists. Applications
using `web-0.nginx.default.svc.cluster.local` will get `NXDOMAIN` errors.
Recreating the service restores DNS. Always create the service before the
StatefulSet and delete the StatefulSet before the service.

### Q: Do StatefulSet pods always land on the same node after restart?
**A:** No — the scheduler places the replacement pod wherever resources are
available, just like any other pod. The pod NAME is stable, the NODE is not
(unless you add node affinity or the pod has a PVC that is node-local).
This is a common misconception: stable identity ≠ stable node placement.

### Q: What is the difference between `serviceName` and the StatefulSet name?
**A:** `serviceName` is the name of the Headless Service that provides DNS.
The StatefulSet name is what appears in pod names (`web-0`, `web-1`).
They can be different:
```yaml
metadata:
  name: mysql-cluster   # Pod names: mysql-cluster-0, mysql-cluster-1
spec:
  serviceName: mysql    # DNS: mysql-cluster-0.mysql.default.svc.cluster.local
```

### Q: Why does `kubectl get statefulset` show fewer columns than `kubectl get deployment`?
**A:** StatefulSets do not use ReplicaSets so there is no `UP-TO-DATE` or
`AVAILABLE` concept in the same way. The `READY` column (`N/M`) is the
primary health indicator. Use `kubectl describe statefulset` for full detail
including current partition, update progress, and events.

### Q: Can a StatefulSet pod be in a different namespace than its Headless Service?
**A:** No — the pod, the StatefulSet, and the Headless Service must all be
in the same namespace. The DNS record `web-0.nginx.default.svc.cluster.local`
encodes the namespace. Cross-namespace StatefulSet DNS is not supported.

---

## What You Learned

In this lab, you:
- ✅ Explained the StatefulSet controller: ordered creation, stable naming, stable DNS
- ✅ Explained how StatefulSet differs from Deployment (random names, any node) and DaemonSet (one per node)
- ✅ Explained every field in the StatefulSet and Headless Service manifests
- ✅ Created a Headless Service before the StatefulSet — and understood why order matters
- ✅ Observed ordered startup: web-0 → web-1 → web-2, each waiting for the previous to be Ready
- ✅ Verified stable pod names: `web-0`, `web-1`, `web-2` — predictable and permanent
- ✅ Verified per-pod DNS records: `web-0.nginx.default.svc.cluster.local` resolves to web-0's IP
- ✅ Verified DNS auto-updates after pod restart — new IP, same hostname
- ✅ Read pod's own identity from `hostname` inside the container
- ✅ Observed ordered shutdown: web-2 → web-1 (reverse ordinal, web-0 preserved)
- ✅ Inspected ControllerRevision objects — StatefulSet rollout history (not ReplicaSets)
- ✅ Verified Headless Service endpoints expose raw pod IPs directly

**Key Takeaway:** A StatefulSet gives each pod three stable guarantees: name,
DNS hostname, and (in Lab 02) storage. These guarantees are what make
distributed stateful systems possible on Kubernetes. The ordered lifecycle —
start in order, stop in reverse order — ensures that databases, message queues,
and quorum-based systems can safely initialise and shut down without data loss
or split-brain scenarios.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get sts` | List StatefulSets (short name) |
| `kubectl get sts web` | StatefulSet status — READY N/M |
| `kubectl get pods -l app=nginx -o wide` | Pods with ordinal names and node placement |
| `kubectl describe sts web` | Full StatefulSet detail — policy, strategy, events |
| `kubectl scale sts web --replicas=N` | Scale up or down (ordered) |
| `kubectl rollout status sts/web` | Watch rolling update progress |
| `kubectl rollout history sts/web` | Show revision history |
| `kubectl rollout undo sts/web` | Rollback to previous revision |
| `kubectl exec web-0 -- hostname` | Pod reads its own stable identity |
| `kubectl exec web-0 -- hostname -f` | Full DNS hostname of the pod |
| `kubectl get controllerrevisions -l app=nginx` | StatefulSet revision objects |
| `kubectl get endpoints nginx` | Raw pod IPs exposed by Headless Service |

---

## Troubleshooting

**StatefulSet stuck — pod N not starting after pod N-1?**
```bash
kubectl get pods -l app=nginx
# If web-0 is not Ready, web-1 will never be created
kubectl describe pod web-0
# Look in Events: readiness probe failing? Image pull error? Resource limit?
```

**DNS not resolving `web-0.nginx.default.svc.cluster.local`?**
```bash
# Verify Headless Service exists
kubectl get service nginx
# CLUSTER-IP should be None

# Verify pod has correct labels
kubectl get pod web-0 --show-labels
# Should show: app=nginx

# Verify service selector matches
kubectl describe service nginx | grep Selector
# Should show: app=nginx
```

**Pod restarts but gets a different name?**
```bash
# This cannot happen for StatefulSet pods — by design.
# If you see a different name, verify it is owned by the StatefulSet:
kubectl get pod web-1 -o yaml | grep -A5 ownerReferences
# Should show: kind: StatefulSet, name: web
```

**`kubectl scale` not working?**
```bash
# StatefulSet supports kubectl scale
kubectl scale sts web --replicas=2
# If it hangs, check if a pod is stuck in Terminating state
kubectl get pods -l app=nginx
# Stuck pod: kubectl delete pod web-2 --force --grace-period=0 (last resort)
```

---

## CKA Certification Tips

✅ **Generate StatefulSet YAML fast — use `--dry-run`:**
```bash
# No direct imperative create for StatefulSet — use Deployment as base:
kubectl create deployment web --image=nginx:1.27 --replicas=3 \
  --dry-run=client -o yaml > sts.yaml
# Edit:
#   kind: Deployment → StatefulSet
#   Remove: spec.strategy
#   Add:    spec.serviceName: nginx
#   Add:    spec.podManagementPolicy: OrderedReady
#   Add:    spec.updateStrategy: ...
```

✅ **Always create the Headless Service before the StatefulSet:**
```bash
kubectl apply -f headless-service.yaml
kubectl apply -f statefulset.yaml
```

✅ **Short names:**
```bash
kubectl get sts        # StatefulSet
kubectl get sts/web    # specific StatefulSet
```

✅ **Key StatefulSet fields the exam tests:**
```yaml
spec:
  serviceName: nginx          # REQUIRED — must match Headless Service name
  podManagementPolicy: OrderedReady  # or Parallel
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0
```

✅ **Headless Service — mandatory field:**
```yaml
spec:
  clusterIP: None    # This single field makes it headless
```

✅ **Rollout commands work the same as Deployment and DaemonSet:**
```bash
kubectl rollout status sts/web
kubectl rollout history sts/web
kubectl rollout undo sts/web
```

✅ **StatefulSet does NOT create a ReplicaSet:**
```bash
kubectl get replicasets -l app=nginx
# No resources found — StatefulSet manages pods directly
```