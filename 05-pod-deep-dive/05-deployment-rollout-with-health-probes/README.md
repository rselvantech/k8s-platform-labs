# Lab 04 — Deployment Rollout Strategies and Probe Interworking

## Lab Overview

This lab demonstrates how Kubernetes health probes integrate directly with
Deployment rollout strategies — making probes not just a health mechanism
but the **gating signal** that controls whether a rollout proceeds, pauses,
or fails.

You will observe every key concept with real output:

**What you'll do:**
- Observe how readiness probe controls RollingUpdate pace — one pod at a time
- Simulate a bad deployment — observe rollout pause, old pods stay alive
- Observe `progressDeadlineSeconds` trigger and rollback
- Understand `minReadySeconds` as a stability buffer after readiness passes
- Compare `maxSurge` and `maxUnavailable` combinations with real pod counts
- Deploy with Recreate strategy and observe the downtime window
- Observe `kubectl rollout` commands: status, pause, resume, undo, history

## Prerequisites

- **REQUIRED:** Lab 01 — Pod Lifecycle
- **REQUIRED:** Lab 03 — Health Probes
- Understanding of readiness probe → ready flag → Service endpoints chain

## Directory Structure
```
05-deployment-rollout-with-health-probes/
└── src/
    ├── 01-rolling-good.yaml          # RollingUpdate — healthy image, probe-gated
    ├── 02-rolling-bad.yaml           # RollingUpdate — bad image, probe never passes
    ├── 03-rolling-minsurge.yaml      # RollingUpdate — minReadySeconds demonstration
    ├── 04-recreate.yaml              # Recreate strategy — observe downtime window
    └── 05-pdb.yaml                   # PodDisruptionBudget — production safety net
```

## Understanding the Core Concept

### Probes as Rollout Signals — Not Just Health Checks

In the context of a Deployment rollout, the readiness probe serves a second
critical function beyond traffic routing:
```
Pod readiness probe passes
        │
        ▼
container ready = true
        │
        ▼
pod stays Ready for minReadySeconds (if set)
        │
        ▼
Deployment controller counts pod as "Available"
        │
        ▼
Controller is permitted to terminate one old pod
        │
        ▼
Next new pod created → probe fires → cycle repeats
```

Without a readiness probe, Kubernetes marks pods Ready immediately when the
container process starts — before the app is actually healthy. The Deployment
controller then terminates old pods immediately, routing traffic to a pod
that cannot yet handle requests.

**Probe failure during rollout:**
```
New pod readiness probe FAILS
        │
        ▼
pod stays 0/1 — NOT counted as Available
        │
        ▼
Deployment controller PAUSES — no old pods killed
        │
        ▼
Old pods continue serving all traffic (zero downtime so far)
        │
        ▼
After progressDeadlineSeconds → ProgressDeadlineExceeded
        │
        ▼
kubectl rollout undo → old ReplicaSet scaled back up
```

---

## Lab Step-by-Step Guide

---

### Step 1: Verify Your Cluster
```bash
kubectl get nodes
```

---

### Part 1: RollingUpdate — Probe-Gated Rollout (Happy Path)

---

### Step 2: Understand the YAML

#### What This Demo Shows

A 3-replica Deployment rolling from `nginx:1.26` to `nginx:1.27`. The
readiness probe gates each step — the controller will not terminate an old
pod until the new pod's probe passes. We observe the step-by-step pod
progression showing exactly how probes control rollout pace.

**01-rolling-good.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
  annotations:
    kubernetes.io/change-cause: "v1 — initial deploy nginx:1.26"
spec:
  replicas: 3
  revisionHistoryLimit: 5         # Keep 5 old ReplicaSets for rollback
  progressDeadlineSeconds: 60     # Fail rollout if no progress in 60s
  minReadySeconds: 5              # Pod must stay Ready 5s before counting as Available

  selector:
    matchLabels:
      app: webapp

  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1                 # Allow 1 extra pod (max 4 total during rollout)
      maxUnavailable: 0           # Never go below 3 pods — zero downtime

  template:
    metadata:
      labels:
        app: webapp
    spec:
      containers:
        - name: app
          image: nginx:1.26
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 3
            periodSeconds: 3
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
```

**Key fields explained:**
```
revisionHistoryLimit: 5
  → Keeps 5 old ReplicaSets on disk
  → Enables: kubectl rollout undo (jump back up to 5 versions)
  → Default is 10 — set lower to save etcd storage in production

progressDeadlineSeconds: 60
  → If rollout makes no progress for 60 seconds → marked as Failed
  → "Progress" = any pod becoming Available or any old pod terminating
  → Default is 600 (10 minutes) — set lower for faster failure detection

minReadySeconds: 5
  → After readiness probe passes, pod must STAY Ready for 5 more seconds
  → THEN the Deployment controller counts it as Available
  → THEN it is allowed to terminate one old pod
  → Catches "flaky ready" pods that pass briefly then degrade
  → Default is 0 — probe passing immediately = Available immediately

maxSurge: 1 + maxUnavailable: 0
  → Conservative zero-downtime strategy
  → Always 3 running, at most 4 total
  → One new pod created, must prove ready, then one old pod terminated
  → Slowest strategy — safest for production
```

---

### Step 3: Deploy Initial Version and Create Service

**Terminal 1 — watch pods:**
```bash
kubectl get pods -w
```

**Terminal 2 — deploy:**
```bash
cd 05-deployment-rollout-with-health-probes/src
kubectl apply -f 01-rolling-good.yaml
kubectl expose deployment webapp --port=80 --name=webapp-svc
```

**Terminal 1 — Expected output:**
```
NAME                     READY   STATUS    RESTARTS   AGE
webapp-xxxxx-aaa         0/1     Running   0          2s   ← probe not yet passed
webapp-xxxxx-bbb         0/1     Running   0          2s
webapp-xxxxx-ccc         0/1     Running   0          2s

webapp-xxxxx-aaa         1/1     Running   0          6s   ← probe passed + 5s minReady
webapp-xxxxx-bbb         1/1     Running   0          7s
webapp-xxxxx-ccc         1/1     Running   0          8s
```

**Verify the Deployment is Available:**
```bash
kubectl get deployment webapp
```

**Expected output:**
```
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
webapp   3/3     3            3           15s
         ↑       ↑            ↑
         │       │            └── 3 pods passed probe AND minReadySeconds
         │       └── 3 pods on current revision
         └── 3 of 3 desired pods running
```

**Verify rollout history (revision 1):**
```bash
kubectl rollout history deployment/webapp
```

**Expected output:**
```
REVISION  CHANGE-CAUSE
1         v1 — initial deploy nginx:1.26
```

---

### Step 4: Trigger Rolling Update to nginx:1.27

**Terminal 2 — update the image:**
```bash
kubectl set image deployment/webapp app=nginx:1.27
kubectl annotate deployment/webapp \
  kubernetes.io/change-cause="v2 — upgrade to nginx:1.27" \
  --overwrite
```

**Terminal 1 — Expected watch output (complete rollout sequence):**
```
NAME                     READY   STATUS              RESTARTS   AGE

# Initial state — 3 old pods (v1)
webapp-v1-aaa            1/1     Running             0          2m
webapp-v1-bbb            1/1     Running             0          2m
webapp-v1-ccc            1/1     Running             0          2m

# Step 1: maxSurge:1 allows 4 total — one new pod created
webapp-v2-xxx            0/1     ContainerCreating   0          0s
webapp-v2-xxx            0/1     Running             0          2s   ← probe firing
                                                                        initialDelaySeconds:3

# Probe passes on new pod → minReadySeconds:5 starts
webapp-v2-xxx            1/1     Running             0          9s   ← Ready + 5s minReady elapsed
                                                                        NOW Available
                                                                        → controller terminates 1 old

# Step 2: One old pod terminates, next new pod created
webapp-v1-aaa            1/1     Terminating         0          2m
webapp-v2-yyy            0/1     ContainerCreating   0          0s

webapp-v1-aaa            0/1     Terminating         0          2m
webapp-v1-aaa            (removed)

webapp-v2-yyy            1/1     Running             0          9s   ← probe + minReady → Available
webapp-v1-bbb            1/1     Terminating         0          2m   ← next old pod terminated
webapp-v2-zzz            0/1     ContainerCreating   0          0s   ← next new pod

# Step 3: Final swap
webapp-v2-zzz            1/1     Running             0          9s   ← Available
webapp-v1-ccc            1/1     Terminating         0          2m   ← last old pod gone

# Final state — 3 new pods (v2)
webapp-v2-xxx            1/1     Running             0          45s
webapp-v2-yyy            1/1     Running             0          35s
webapp-v2-zzz            1/1     Running             0          25s
```

> **What the watch output proves:**
> The controller NEVER terminated an old pod until the new pod's readiness
> probe passed AND `minReadySeconds: 5` elapsed. At no point were fewer
> than 3 pods serving traffic (`maxUnavailable: 0`). At most 4 pods ran
> simultaneously (`maxSurge: 1`).

**Terminal 2 — monitor rollout status in real time:**
```bash
kubectl rollout status deployment/webapp
```

**Expected output:**
```
Waiting for deployment "webapp" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "webapp" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "webapp" rollout to finish: 1 old replicas are pending termination...
deployment "webapp" successfully rolled out
```

**Verify rollout history (revision 2):**
```bash
kubectl rollout history deployment/webapp
```

**Expected output:**
```
REVISION  CHANGE-CAUSE
1         v1 — initial deploy nginx:1.26
2         v2 — upgrade to nginx:1.27
```

**Verify all pods on new image:**
```bash
kubectl get pods -o wide
kubectl describe deployment webapp | grep Image
```

---

### Part 2: RollingUpdate — Bad Image (Rollout Pause and Rollback)

---

### Step 5: Simulate a Bad Deployment

#### What This Demo Shows

A deployment update with a non-existent image tag. The new pods can never
start (`ImagePullBackOff`). The readiness probe never passes. The controller
pauses — old pods keep serving traffic. After `progressDeadlineSeconds: 60`
the Deployment is marked as failed. We then observe the conditions and
perform a rollback.

**Terminal 1 — watch pods:**
```bash
kubectl get pods -w
```

**Terminal 3 — watch deployment conditions:**
```bash
kubectl get deployment webapp -w
```

**Terminal 2 — trigger bad update:**
```bash
kubectl set image deployment/webapp app=nginx:THIS-IMAGE-DOES-NOT-EXIST
kubectl annotate deployment/webapp \
  kubernetes.io/change-cause="v3 — bad image (intentional failure)" \
  --overwrite
```

**Terminal 1 — Expected output:**
```
NAME                     READY   STATUS              RESTARTS   AGE
webapp-v2-xxx            1/1     Running             0          5m   ← still serving
webapp-v2-yyy            1/1     Running             0          5m   ← still serving
webapp-v2-zzz            1/1     Running             0          5m   ← still serving

webapp-v3-new            0/1     Pending             0          0s
webapp-v3-new            0/1     ContainerCreating   0          1s
webapp-v3-new            0/1     ErrImagePull        0          5s
webapp-v3-new            0/1     ImagePullBackOff    0          15s
                                 ↑
                             Image does not exist → can never start
                             Readiness probe NEVER fires
                             Controller PAUSES — no old pods terminated
                             Old pods keep serving ALL traffic ✅
```

**Terminal 3 — watch deployment READY column stay at 3/3:**
```
NAME     READY   UP-TO-DATE   AVAILABLE
webapp   3/3     1            3          ← UP-TO-DATE=1 (stuck new pod)
                                           AVAILABLE=3 (old pods still serving)
```

> `AVAILABLE=3` throughout — zero downtime even with a completely broken
> new version. This is the core guarantee of `maxUnavailable: 0` combined
> with probe-gated rollout.

**After 60s (`progressDeadlineSeconds`) — check deployment conditions:**
```bash
kubectl describe deployment webapp | grep -A 15 "Conditions:"
```

**Expected output:**
```
Conditions:
  Type             Status   Reason
  ----             ------   ------
  Progressing      False    ProgressDeadlineExceeded
  Available        True     MinimumReplicasAvailable
```

> `Progressing=False ProgressDeadlineExceeded` — rollout declared failed.
> `Available=True` — old pods are still serving. Users unaffected.

**Check rollout status:**
```bash
kubectl rollout status deployment/webapp
```

**Expected output:**
```
error: deployment "webapp" exceeded its progress deadline
```

**Rollback to previous good version:**
```bash
kubectl rollout undo deployment/webapp
```

**Terminal 1 — Expected output after undo:**
```
webapp-v3-new            0/1     Terminating         0          75s   ← bad pod gone
webapp-v2-restored       0/1     ContainerCreating   0          0s    ← v2 pod restored
webapp-v2-restored       1/1     Running             0          8s    ← probe passed
```

**Verify rollback completed:**
```bash
kubectl rollout status deployment/webapp
# deployment "webapp" successfully rolled out

kubectl rollout history deployment/webapp
```

**Expected output:**
```
REVISION  CHANGE-CAUSE
1         v1 — initial deploy nginx:1.26
2         v2 — upgrade to nginx:1.27
3         v3 — bad image (intentional failure)
4         v2 — upgrade to nginx:1.27        ← undo creates revision 4 = copy of rev 2
```

> `kubectl rollout undo` does NOT delete history. It creates a new revision
> that is a copy of the previous good ReplicaSet. Revision 4 = same spec
> as Revision 2. Revision 3 stays in history (for audit purposes).

**Rollback to a specific revision:**
```bash
# Jump to revision 1 specifically
kubectl rollout undo deployment/webapp --to-revision=1

kubectl describe deployment webapp | grep Image
# Image: nginx:1.26   ← back to v1
```

---

### Part 3: `minReadySeconds` — Stability Buffer

---

### Step 6: Understand and Observe minReadySeconds

#### What This Demo Shows

`minReadySeconds` is not a health probe — it is a **stability window**
defined at the Deployment level. After a pod's readiness probe passes,
the pod must remain Ready for `minReadySeconds` before the Deployment
controller counts it as Available and proceeds to terminate the next
old pod.
```
Without minReadySeconds (default 0):
  Probe passes at t=5s → pod immediately Available → old pod killed at t=5s
  Risk: if pod crashes at t=6s, traffic was briefly lost

With minReadySeconds: 15:
  Probe passes at t=5s → wait 15 more seconds → Available at t=20s
  If pod crashes between t=5s and t=20s → NOT counted as Available
  → old pod NOT killed → rollout pauses → protection ✅
```

**03-rolling-minsurge.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-stable
  annotations:
    kubernetes.io/change-cause: "v1 — with minReadySeconds:15"
spec:
  replicas: 3
  revisionHistoryLimit: 3
  progressDeadlineSeconds: 120
  minReadySeconds: 15             # Pod must stay Ready 15s before Available

  selector:
    matchLabels:
      app: webapp-stable

  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0

  template:
    metadata:
      labels:
        app: webapp-stable
    spec:
      containers:
        - name: app
          image: nginx:1.26
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 3
            periodSeconds: 3
            failureThreshold: 3
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
```
```bash
kubectl apply -f 03-rolling-minsurge.yaml
kubectl set image deployment/webapp-stable app=nginx:1.27
```

**Terminal 1 — watch — observe the timing gap between `1/1` and old pod termination:**
```
NAME                       READY   STATUS    RESTARTS   AGE
webapp-stable-v2-xxx       0/1     Running   0          3s   ← probe firing
webapp-stable-v2-xxx       1/1     Running   0          6s   ← probe PASSED
                                                               (minReadySeconds:15 starts now)
                                                               old pod NOT killed yet

(15 seconds pass — pod stays Ready during stability window)

webapp-stable-v1-aaa       1/1     Terminating  0        2m  ← NOW old pod killed
                                                               (15s elapsed → Available)
webapp-stable-v2-yyy       0/1     Running      0        0s  ← next new pod
```

> The gap between `1/1 Running` for the new pod and `Terminating` for the
> old pod is exactly `minReadySeconds: 15`. Without this you would see the
> Terminating event almost immediately after the new pod reaches `1/1`.

**Cleanup:**
```bash
kubectl delete -f 03-rolling-minsurge.yaml
```

---

### Part 4: Recreate Strategy — Observe the Downtime Window

---

### Step 7: Understand and Observe Recreate

#### What This Demo Shows

Recreate terminates ALL old pods before creating ANY new pods. There is
always a downtime window. Probes are irrelevant during the termination
phase — they only help minimise the downtime window on new pod startup.

**When to use Recreate:**
- Application cannot have two versions running simultaneously
  (single-instance databases, apps with file locks, schema migrations)
- Downtime is acceptable and a clean cutover is required

**04-recreate.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-recreate
  annotations:
    kubernetes.io/change-cause: "v1 — initial deploy (Recreate strategy)"
spec:
  replicas: 3
  revisionHistoryLimit: 3
  progressDeadlineSeconds: 120

  selector:
    matchLabels:
      app: webapp-recreate

  strategy:
    type: Recreate           # No rollingUpdate block — not applicable here

  template:
    metadata:
      labels:
        app: webapp-recreate
    spec:
      containers:
        - name: app
          image: nginx:1.26
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 3
            periodSeconds: 3
            failureThreshold: 3
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
```

**Terminal 1 — watch pods:**
```bash
kubectl get pods -w
```

**Terminal 2 — deploy then update:**
```bash
kubectl apply -f 04-recreate.yaml
# Wait for 3/3 Running, then:
kubectl set image deployment/webapp-recreate app=nginx:1.27
kubectl annotate deployment/webapp-recreate \
  kubernetes.io/change-cause="v2 — upgrade (Recreate)" --overwrite
```

**Terminal 1 — Expected watch output:**
```
# Initial state — v1 running
webapp-recreate-v1-aaa   1/1   Running       0   30s
webapp-recreate-v1-bbb   1/1   Running       0   30s
webapp-recreate-v1-ccc   1/1   Running       0   30s

# Phase 1: ALL old pods SIGTERM simultaneously
webapp-recreate-v1-aaa   1/1   Terminating   0   30s   ← ALL three at once
webapp-recreate-v1-bbb   1/1   Terminating   0   30s   ← no staged termination
webapp-recreate-v1-ccc   1/1   Terminating   0   30s   ← DOWNTIME BEGINS

webapp-recreate-v1-aaa   0/1   Terminating   0   32s
webapp-recreate-v1-bbb   0/1   Terminating   0   32s
webapp-recreate-v1-ccc   0/1   Terminating   0   32s
                                                          ← FULL DOWNTIME
                                                             zero pods running
                                                             Service endpoints empty

# Phase 2: ALL new pods created simultaneously
webapp-recreate-v2-xxx   0/1   ContainerCreating  0  0s
webapp-recreate-v2-yyy   0/1   ContainerCreating  0  0s
webapp-recreate-v2-zzz   0/1   ContainerCreating  0  0s

webapp-recreate-v2-xxx   0/1   Running  0  2s   ← probe firing (initialDelay:3)
webapp-recreate-v2-yyy   0/1   Running  0  2s
webapp-recreate-v2-zzz   0/1   Running  0  2s

webapp-recreate-v2-xxx   1/1   Running  0  6s   ← probe passed — DOWNTIME ENDS ✅
webapp-recreate-v2-yyy   1/1   Running  0  7s
webapp-recreate-v2-zzz   1/1   Running  0  7s
```

> **Downtime window = time between last old pod gone and first new pod `1/1`**
> In this demo: ~4–6 seconds (termination + container start + probe delay)
> In production with heavy apps: can be 60–300 seconds
>
> The readiness probe helps here by making new pods ready and in the Service
> endpoints as fast as possible — but it cannot eliminate the downtime window.

**Cleanup:**
```bash
kubectl delete -f 04-recreate.yaml
```

---

### Part 5: PodDisruptionBudget — Production Safety Net

---

### Step 8: Understand PodDisruptionBudget

#### What This Demo Shows

A PodDisruptionBudget (PDB) is not a probe — it is a separate resource
that protects against **voluntary disruptions**: node drains, cluster
upgrades, manual pod deletions. It works alongside probes and rollout
strategies as a complementary safety layer.
```
Voluntary disruptions (PDB protects against):
  - kubectl drain <node>    (node maintenance)
  - kubectl delete pod ...  (manual deletion)
  - Cluster upgrade         (node rotation)
  - Eviction by autoscaler

Involuntary disruptions (PDB does NOT protect):
  - Node hardware failure
  - Out-of-memory kill
  - Liveness probe failure restart
```

**05-pdb.yaml:**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: webapp-pdb
spec:
  minAvailable: 2           # At least 2 pods must be Available at all times
  selector:
    matchLabels:
      app: webapp           # Applies to webapp Deployment pods
```
```bash
kubectl apply -f 05-pdb.yaml
```

**Verify the PDB:**
```bash
kubectl get pdb webapp-pdb
```

**Expected output:**
```
NAME         MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
webapp-pdb   2               N/A               1                     10s
             ↑                                 ↑
             At least 2 must be available      Only 1 pod can be
             at any time                       disrupted at a time
```

**Observe PDB blocking a node drain:**
```bash
kubectl drain 3node-m03 --ignore-daemonsets --delete-emptydir-data
```

**Expected output (if only 1 pod on that node and PDB would be violated):**
```
evicting pod default/webapp-xxxxx
error when evicting pods/"webapp-xxxxx" -n "default" (will retry after 5s):
Cannot evict pod as it would violate the pod's disruption budget.
```

> The eviction is blocked — PDB enforces `minAvailable: 2`. Only once
> the evicted pod is replaced and ready on another node does the drain
> proceed.

**PDB configuration options:**
```yaml
# Option A — absolute minimum available
spec:
  minAvailable: 2         # At least 2 pods must always be Available

# Option B — percentage minimum available
spec:
  minAvailable: "66%"     # At least 66% of pods must be Available

# Option C — maximum unavailable
spec:
  maxUnavailable: 1       # At most 1 pod may be unavailable at any time

# Option D — maximum unavailable percentage
spec:
  maxUnavailable: "33%"   # At most 33% may be unavailable
```

> **PDB and RollingUpdate:** PDB does not interfere with RollingUpdate
> because the controller terminates pods in a controlled, ordered way
> that respects `maxUnavailable`. However during a node drain that
> coincides with a rollout, the PDB provides an extra safety layer.

**Cleanup:**
```bash
kubectl delete -f 05-pdb.yaml
kubectl delete -f 01-rolling-good.yaml
```

---

## Key Rollout Commands Reference
```bash
# Watch rollout progress — blocks until complete or failed
kubectl rollout status deployment/<name>

# View revision history
kubectl rollout history deployment/<name>

# View specific revision details
kubectl rollout history deployment/<name> --revision=2

# Pause a rollout mid-way (canary validation opportunity)
kubectl rollout pause deployment/<name>

# Resume a paused rollout
kubectl rollout resume deployment/<name>

# Rollback to previous revision
kubectl rollout undo deployment/<name>

# Rollback to specific revision
kubectl rollout undo deployment/<name> --to-revision=1

# Restart all pods (new rollout with same image)
kubectl rollout restart deployment/<name>
```

---

## Complete Concept Map — Probes × Rollout
```
┌────────────────────────────────────────────────────────────────────────────┐
│                     DEPLOYMENT FIELDS AND THEIR ROLES                      │
├─────────────────────────┬──────────────────────────────────────────────────┤
│  Field                  │  Role in Rollout                                 │
├─────────────────────────┼──────────────────────────────────────────────────┤
│  readinessProbe         │  PRIMARY GATE — pod must pass before controller  │
│                         │  counts it as Available. Failing = rollout pause │
├─────────────────────────┼──────────────────────────────────────────────────┤
│  livenessProbe          │  Restarts broken containers — independent of     │
│                         │  rollout pace. Does NOT gate rollout progress    │
├─────────────────────────┼──────────────────────────────────────────────────┤
│  startupProbe           │  Blocks readiness on slow-starting pods         │
│                         │  Pod stays 0/1 longer → rollout appears slower  │
├─────────────────────────┼──────────────────────────────────────────────────┤
│  minReadySeconds        │  Extra stability window AFTER readiness passes  │
│                         │  Pod must stay Ready N seconds → then Available │
├─────────────────────────┼──────────────────────────────────────────────────┤
│  maxSurge               │  Max extra pods during rollout (speed vs cost)  │
│                         │  Higher = faster rollout, more resources used   │
├─────────────────────────┼──────────────────────────────────────────────────┤
│  maxUnavailable         │  Max pods that can be unavailable               │
│                         │  0 = never reduce capacity (zero downtime)      │
├─────────────────────────┼──────────────────────────────────────────────────┤
│  progressDeadlineSeconds│  Timeout — rollout declared failed if no        │
│                         │  progress in N seconds → enables auto-detect    │
├─────────────────────────┼──────────────────────────────────────────────────┤
│  revisionHistoryLimit   │  Old ReplicaSets kept for rollback              │
├─────────────────────────┼──────────────────────────────────────────────────┤
│  PodDisruptionBudget    │  Separate resource — protects against voluntary │
│  (separate resource)    │  disruptions (drain, eviction, autoscaler)      │
└─────────────────────────┴──────────────────────────────────────────────────┘
```

---

## Production Patterns

### Pattern 1 — Zero Downtime (Critical Services)
```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
minReadySeconds: 30
progressDeadlineSeconds: 300
```

### Pattern 2 — Fast Rollout (Batch / Background Workers)
```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 50%
    maxUnavailable: 25%
minReadySeconds: 0
progressDeadlineSeconds: 120
```

### Pattern 3 — Clean Cutover (Single-Instance / Schema Migration)
```yaml
strategy:
  type: Recreate
# No rollingUpdate block
progressDeadlineSeconds: 300
```

### Pattern 4 — Canary Validation Window
```bash
# Deploy new version
kubectl set image deployment/webapp app=nginx:1.28

# Immediately pause — 1 new pod running, 2 old pods running
kubectl rollout pause deployment/webapp

# Validate the 1 new pod manually (metrics, logs, smoke test)
kubectl logs -l app=webapp --prefix | grep "new-pod-name"

# If healthy — resume full rollout
kubectl rollout resume deployment/webapp

# If not healthy — rollback immediately
kubectl rollout undo deployment/webapp
```

---

## What You Learned

- ✅ Readiness probe is the **gating signal** for RollingUpdate — not just
     a traffic health check. Probe failing = rollout pauses = old pods safe
- ✅ `minReadySeconds` adds a stability buffer after probe passes — protects
     against "flaky ready" pods that degrade shortly after startup
- ✅ `maxSurge: 1 maxUnavailable: 0` = zero-downtime conservative strategy
- ✅ Bad image → `ImagePullBackOff` → probe never fires → rollout pauses →
     `progressDeadlineSeconds` triggers → rollback with `kubectl rollout undo`
- ✅ `kubectl rollout undo` creates a new revision — does not delete history
- ✅ Recreate always has downtime — probes minimise its length but cannot
     eliminate it — use only when two versions cannot coexist
- ✅ PodDisruptionBudget is a separate safety layer protecting against
     voluntary disruptions — complements probes and rollout strategy
- ✅ Canary pattern: `kubectl rollout pause` after 1 pod rolls out,
     validate, then `resume` or `undo`

**Key Takeaway:** A readiness probe without a Deployment is just a traffic
gate. A Deployment without a readiness probe is dangerous — it terminates
old pods before new ones are proven healthy. Together they form the complete
zero-downtime deployment mechanism. `minReadySeconds` and `progressDeadlineSeconds`
are the production-grade additions that catch subtle failures the probe
alone cannot detect.