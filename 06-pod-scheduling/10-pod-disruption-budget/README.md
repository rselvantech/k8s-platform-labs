# PodDisruptionBudget

## Lab Overview

When you drain a node for maintenance or a rolling update is in progress,
Kubernetes needs to know how many pods it can take down at once. Without
any policy, it could take all replicas offline simultaneously — causing a
full outage. A PodDisruptionBudget (PDB) prevents this by defining the
minimum availability your application requires during voluntary disruptions.

```
Voluntary disruptions — PDB applies:
  → kubectl drain (node maintenance, OS patching)
  → Cluster autoscaler node scale-down
  → Direct eviction via Eviction API

Involuntary disruptions — PDB does NOT apply:
  → Node hardware failure
  → Node-pressure eviction (kubelet — Demo 09)
  → OOM kill
  → Kernel panic
```

**What this lab covers:**
- PDB fields — minAvailable, maxUnavailable, selector, unhealthyPodEvictionPolicy
- PDB status — reading Allowed disruptions, Current, Desired, Total
- Default values and what happens when fields are omitted
- minAvailable vs maxUnavailable — when to use each
- PDB with scaling — how each field behaves as replicas change
- Rolling update — PDB counts disruptions but does not control rollout
- Common pitfall — single replica with minAvailable: 1
- unhealthyPodEvictionPolicy — what it means and when to use each
- Node maintenance workflow — cordon, drain, uncordon with PDB active

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl installed and configured

**Knowledge Requirements:**
- **REQUIRED:** Completion of [09-node-pressure-eviction](../09-node-pressure-eviction/)
- Understanding of Deployments and rolling updates
- Understanding of QoS classes

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Create a PDB with minAvailable — absolute and percentage
2. ✅ Create a PDB with maxUnavailable — absolute and percentage
3. ✅ Read PDB status — Allowed disruptions, Current, Desired, Total
4. ✅ Explain why maxUnavailable is preferred over minAvailable for scaling deployments
5. ✅ Explain how PDB interacts with rolling updates — counts but does not control
6. ✅ Demonstrate the single-replica pitfall and fix it
7. ✅ Explain what unhealthy means in PDB context and when to use each policy
8. ✅ Perform a full cordon, drain, uncordon workflow with PDB active

## Directory Structure

```
10-pod-disruption-budget/
├── README.md                        # This file
└── src/
    ├── web-deployment.yaml          # 5-replica deployment for PDB demos
    ├── pdb-minavailable.yaml        # PDB with minAvailable: 3
    ├── pdb-minavailable-pct.yaml    # PDB with minAvailable: 60%
    ├── pdb-maxunavailable.yaml      # PDB with maxUnavailable: 1
    └── pdb-alwaysallow.yaml         # PDB with unhealthyPodEvictionPolicy: AlwaysAllow
```

---

## Understanding PodDisruptionBudget

### What PDB Protects

A PDB specifies the minimum availability an application must maintain
during voluntary disruptions. The Eviction API checks the PDB before
evicting any pod — if eviction would violate the budget, it returns
429 Too Many Requests and the operation waits.

```
Without PDB (5 replicas):
  kubectl drain → all 5 pods evicted simultaneously → full outage

With PDB (minAvailable: 3, replicas: 5):
  kubectl drain → evicts pods one at a time
  always keeps at least 3 pods running
  allowed disruptions = 5 - 3 = 2 at any one time
```

> **PDB only applies to Eviction API — not to direct deletion:**
> Scaling down a Deployment (`kubectl scale --replicas=2`) uses direct
> pod deletion — it bypasses the Eviction API and PDB entirely.
> PDB does not prevent scale-down operations. PDB only protects against
> voluntary disruptions that go through the Eviction API:
> kubectl drain, direct eviction API calls, and cluster autoscaler.

### PDB Fields

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
spec:
  minAvailable: 3                              # OR maxUnavailable — not both
  selector:                                    # required
    matchLabels:
      app: web
  unhealthyPodEvictionPolicy: IfHealthyBudget  # default
```

| Field | Required | Default | Purpose |
|---|---|---|---|
| `minAvailable` | One of these two | none | Minimum pods that must remain available |
| `maxUnavailable` | One of these two | none | Maximum pods that can be unavailable |
| `selector` | ✅ | none | Which pods this PDB protects |
| `unhealthyPodEvictionPolicy` | ❌ | `IfHealthyBudget` | How unhealthy pods are treated |

> One of `minAvailable` or `maxUnavailable` must be set — they are
> mutually exclusive. Neither has a default value.

**SMU — memory aid for PDB fields:**
```
S → selector                  required — which pods this PDB protects
M → minAvailable/maxUnavailable required — one of these (not both)
U → unhealthyPodEvictionPolicy optional — default is IfHealthyBudget

"Selector Must be Updated"
```

### PDB Status — How to Read It

```bash
kubectl describe pdb web-pdb
```

```
Status:
  Allowed disruptions:  2    ← how many pods can be disrupted RIGHT NOW
  Current:              5    ← currently healthy pods (Ready condition = True)
  Desired:              3    ← minimum required (from minAvailable)
  Total:                5    ← total pods matched by selector
```

```
Allowed disruptions = Current - Desired = 5 - 3 = 2
```

> If Allowed disruptions = 0 → no evictions permitted
> kubectl drain blocks until a pod recovers and budget is restored

### minAvailable vs maxUnavailable

```
minAvailable: 3  (replicas: 5)
  Allowed disruptions = 5 - 3 = 2
  If replicas scales to 10: Allowed disruptions = 10 - 3 = 7
  If replicas scales to 3:  Allowed disruptions = 3 - 3 = 0 ← blocks all
  Value is ABSOLUTE — does not scale with replicas

maxUnavailable: 1  (replicas: 5)
  Allowed disruptions = 1 always
  If replicas scales to 10: Allowed disruptions = 1 still
  If replicas scales to 3:  Allowed disruptions = 1 still
  Value is RELATIVE — remains valid regardless of replica count

→ maxUnavailable recommended — automatically responds to replica changes
→ minAvailable use case: guarantee a fixed minimum count regardless of scale
```

> The use of maxUnavailable is recommended as it automatically responds
> to changes in the number of replicas of the corresponding controller.
> — Kubernetes official documentation

### Common Pitfall — Single Replica with minAvailable: 1

```
replicas: 1
PDB: minAvailable: 1

Allowed disruptions = Current(1) - Desired(1) = 0
→ NO evictions ever allowed
→ kubectl drain hangs indefinitely
```

If you set `maxUnavailable` to 0% or 0, or you set `minAvailable` to
100% or the number of replicas, you are requiring zero voluntary evictions.
When you set zero voluntary evictions for a workload, you cannot
successfully drain a Node running one of those Pods.

```
Fix: use maxUnavailable: 1
  → Allowed disruptions = 1
  → drain can proceed
  → single pod can be down during maintenance
```

### PDB and Rolling Updates — Counts but Does NOT Control

Rolling updates are controlled by the Deployment's own `maxUnavailable`
and `maxSurge` fields — PDB does NOT block or control rolling updates.

```
Deployment rolling update fields:
  maxUnavailable  → how many pods can be unavailable during rollout
  maxSurge        → how many extra pods can be created during rollout

PDB role during rolling updates:
  → counts pods that are unavailable during rollout against the budget
  → does NOT stop or control the rollout pace
  → only limits Eviction-API-initiated disruptions separately
```

**Practical implication:**

```
Scenario:
  Deployment: replicas=5, maxUnavailable=2
  PDB: minAvailable=3, Allowed disruptions=2

  Rolling update terminates 2 pods → budget = 5 - 3 = 2 allows this
  During rollout, if someone tries to drain a node:
    → drain counts against remaining budget
    → may be blocked if budget exhausted by rollout

  PDB provides an additional guard — if rolling update is already
  consuming budget, concurrent node drains are limited further
```

### unhealthyPodEvictionPolicy — What Does Unhealthy Mean

**Healthy pod definition (from official documentation):**

A pod is considered healthy when it has `status.conditions` with
`type="Ready"` and `status="True"`. In plain terms:

```
Healthy pod   → Running AND passing readiness probe → Ready=True
Unhealthy pod → Running BUT failing readiness probe → Ready=False
               (pod is Running but not serving traffic)
               Examples: CrashLoopBackOff, readiness probe failing,
                         app starting up, misconfiguration
```

**Why this matters for drain:**

During a node drain, all pods on the node must be evicted. If some pods
are unhealthy (Running but not Ready), the PDB faces a dilemma:

```
IfHealthyBudget (default)
  → unhealthy running pods can only be evicted if the application still
    has at least minAvailable healthy pods elsewhere
  → if too many pods are unhealthy → currentHealthy < desiredHealthy
    → drain waits for unhealthy pods to recover (become Ready)
  → recovery = pod passes readiness probe → Ready=True

  Risk: if pods are stuck unhealthy (CrashLoopBackOff, bad config)
        they will never recover → drain hangs indefinitely

AlwaysAllow
  → unhealthy running pods can always be evicted regardless of budget
  → drain always completes even if pods never become healthy
  → recommended by official documentation for most workloads

  Risk: unhealthy pods evicted without waiting for recovery
        application may have reduced capacity during drain
```

> It is recommended to set AlwaysAllow Unhealthy Pod Eviction Policy
> to your PodDisruptionBudgets to support eviction of misbehaving
> applications during a node drain. The default behavior is to wait
> for the application pods to become healthy before the drain can proceed.
> — Kubernetes official documentation

```
When to use IfHealthyBudget:
  → critical stateful workloads (databases, Zookeeper, Kafka)
  → where losing an unhealthy pod could cause data loss
  → where you prefer drain to wait rather than risk disruption

When to use AlwaysAllow:
  → stateless web services, API servers
  → any workload where you prefer drain to complete over waiting
  → recommended as the default for most production workloads
```

---

## Lab Step-by-Step Guide

---

### Step 1: Deploy Web Application

```bash
cd 10-pod-disruption-budget/src

kubectl get nodes
```

**Expected output:**
```
NAME        STATUS   ROLES           AGE   VERSION
3node       Ready    control-plane   ...   v1.34.0
3node-m02   Ready    <none>          ...   v1.34.0
3node-m03   Ready    <none>          ...   v1.34.0
```

**web-deployment.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-deploy
spec:
  replicas: 5
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      terminationGracePeriodSeconds: 10
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"
```

```bash
kubectl apply -f web-deployment.yaml
kubectl rollout status deployment/web-deploy
kubectl get pods -o wide
```

**Expected output:**
```
deployment.apps/web-deploy successfully rolled out

NAME                          READY   STATUS    NODE
web-deploy-xxxxxxxxx-aaaaa    1/1     Running   3node-m02
web-deploy-xxxxxxxxx-bbbbb    1/1     Running   3node-m02
web-deploy-xxxxxxxxx-ccccc    1/1     Running   3node-m02
web-deploy-xxxxxxxxx-ddddd    1/1     Running   3node-m03
web-deploy-xxxxxxxxx-eeeee    1/1     Running   3node-m03
```

Verify all pods are healthy (Ready=True):

```bash
kubectl get pods -l app=web \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
```

**Expected output:**
```
web-deploy-xxxxxxxxx-aaaaa    True
web-deploy-xxxxxxxxx-bbbbb    True
web-deploy-xxxxxxxxx-ccccc    True
web-deploy-xxxxxxxxx-ddddd    True
web-deploy-xxxxxxxxx-eeeee    True
```

All pods healthy — Ready=True confirms readiness probe passing. ✅

---

### Step 2: PDB with minAvailable — Absolute Value

**pdb-minavailable.yaml:**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb-min
spec:
  minAvailable: 3
  selector:
    matchLabels:
      app: web
```

```bash
kubectl apply -f pdb-minavailable.yaml
kubectl describe pdb web-pdb-min
```

**Expected output:**
```
Name:           web-pdb-min
Namespace:      default
Min available:  3
Selector:       app=web
Status:
  Allowed disruptions:  2
  Current:              5
  Desired:              3
  Total:                5
```

```
Allowed disruptions = Current(5) - Desired(3) = 2
→ 2 pods can be disrupted simultaneously
```

**Test — scale to exactly minAvailable (replicas = minAvailable):**

```bash
kubectl scale deployment web-deploy --replicas=3
kubectl get pods -o wide
kubectl describe pdb web-pdb-min
```

**Expected output:**
```
Status:
  Allowed disruptions:  0
  Current:              3
  Desired:              3
  Total:                3
```

```
Allowed disruptions = Current(3) - Desired(3) = 0
→ No disruptions allowed — drain would block here
→ minAvailable is FIXED — does not adjust with replicas
```

**Test — scale BELOW minAvailable (replicas < minAvailable):**

```bash
kubectl scale deployment web-deploy --replicas=2
kubectl describe pdb web-pdb-min
```

**Expected output:**
```
Status:
  Allowed disruptions:  0
  Current:              2
  Desired:              3
  Total:                2
```

```
#As shown in above ouptut
Current(2) < Desired(3) → budget already violated
Allowed disruptions = 0
→ PDB is in deficit — all evictions will be blocked
→ This means the application is already below its minimum availability
```

**Note:** scale down below `minAvailable` didnt failed with 429

> **Why scaling down does NOT trigger 429:**
> `kubectl scale` uses direct pod deletion — it bypasses the Eviction
> API entirely. PDB is not consulted and cannot prevent scale-down
> operations. This is confirmed by official documentation:
> "deleting deployments or pods bypasses Pod Disruption Budgets."
>
> PDB only protects against operations that go through the Eviction API:
> kubectl drain, direct eviction API calls, and cluster autoscaler.
> Direct deletion (kubectl scale, kubectl delete pod, rolling updates)
> bypasses PDB completely.

>```
>kubectl scale → deletes pods directly → bypasses PDB → no 429
>kubectl drain → uses Eviction API → PDB consulted → 429 possible
>kubectl delete pod → direct deletion → bypasses PDB → no 429
>```

Scale back:
```bash
kubectl scale deployment web-deploy --replicas=5
kubectl describe pdb web-pdb-min
# Verify Allowed disruptions returns to 2
kubectl delete -f pdb-minavailable.yaml
```

---

### Step 3: PDB with minAvailable — Percentage

**pdb-minavailable-pct.yaml:**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb-min-pct
spec:
  minAvailable: "60%"
  selector:
    matchLabels:
      app: web
```

```bash
kubectl apply -f pdb-minavailable-pct.yaml
kubectl describe pdb web-pdb-min-pct
```

**Expected output:**
```
Status:
  Allowed disruptions:  2
  Current:              5
  Desired:              3
  Total:                5
```

```
minAvailable: 60% of 5 = 3 pods (Kubernetes rounds up)
Allowed disruptions = 5 - 3 = 2
```

Scale to 10 and observe percentage recalculation:

```bash
kubectl scale deployment web-deploy --replicas=10
kubectl describe pdb web-pdb-min-pct
```

**Expected output:**
```
Status:
  Allowed disruptions:  4
  Current:              10
  Desired:              6
  Total:                10
```

```
minAvailable: 60% of 10 = 6 pods
Allowed disruptions = 10 - 6 = 4
→ minAvailable percentage scales with replicas
→ but the ABSOLUTE value changes — compare with maxUnavailable in Step 4
```

Scale back:
```bash
kubectl scale deployment web-deploy --replicas=5
kubectl delete -f pdb-minavailable-pct.yaml
```

---

### Step 4: PDB with maxUnavailable — Stays Constant

**pdb-maxunavailable.yaml:**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb-max
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: web
  unhealthyPodEvictionPolicy: AlwaysAllow
```

```bash
kubectl apply -f pdb-maxunavailable.yaml
kubectl describe pdb web-pdb-max
```

**Expected output:**
```
Name:               web-pdb-max
Namespace:          default
Max unavailable:    1
Selector:           app=web
Status:
  Allowed disruptions:  1
  Current:              5
  Desired:              4
  Total:                5
```

Scale to 10 and observe maxUnavailable stays constant:

```bash
kubectl scale deployment web-deploy --replicas=10
kubectl describe pdb web-pdb-max
```

**Expected output:**
```
Status:
  Allowed disruptions:  1   ← still 1 regardless of replica count
  Current:              10
  Desired:              9
  Total:                10
```

Scale down to 2:

```bash
kubectl scale deployment web-deploy --replicas=2
kubectl describe pdb web-pdb-max
```

**Expected output:**
```
Status:
  Allowed disruptions:  1   ← still 1
  Current:              2
  Desired:              1
  Total:                2
```

```
maxUnavailable: 1 → always exactly 1 disruption allowed
regardless of replica count — this is why it is recommended

Compare with minAvailable:
  minAvailable: 3 with replicas=2 → Allowed disruptions = 0 (blocks all)
  maxUnavailable: 1 with replicas=2 → Allowed disruptions = 1 (always works)
```

Scale back:
```bash
# IMPORTANT: delete pdb-maxunavailable before Step 6
# Having two PDBs matching the same pod causes Eviction API error
kubectl delete -f pdb-maxunavailable.yaml
kubectl scale deployment web-deploy --replicas=5
```

---

### Step 5: PDB During Rolling Update

This step demonstrates that PDB counts pods unavailable during a
rolling update but does NOT control the rollout. The rollout is
controlled by the Deployment's `maxUnavailable` and `maxSurge` fields.

```bash
# PDB maxUnavailable: 1 is still active
kubectl describe pdb web-pdb-max

# Trigger rolling update — change image
kubectl set image deployment/web-deploy app=nginx

# Watch progress in real time
kubectl get pods -o wide -w &
WATCH_PID=$!
kubectl rollout status deployment/web-deploy
```

**Expected output during rolling update:**
```
NAME                          READY   STATUS              NODE
web-deploy-old-xxxxxxxxx-a    1/1     Running             3node-m02
web-deploy-old-xxxxxxxxx-b    1/1     Running             3node-m02
web-deploy-old-xxxxxxxxx-c    1/1     Terminating         3node-m02  ← 1 terminating
web-deploy-new-xxxxxxxxx-d    0/1     ContainerCreating   3node-m03  ← new starting
...
deployment.apps/web-deploy successfully rolled out
```

```bash
kill $WATCH_PID 2>/dev/null
```

**Observation:**
```
Rolling update replaces pods one at a time
→ controlled by Deployment's maxUnavailable (default: 25%)
→ PDB maxUnavailable: 1 is counting unavailable pods during rollout
→ PDB does NOT stop or control the rollout itself
→ If someone tried to drain a node DURING this rollout:
   the drain would be limited by remaining budget
```

**Check PDB budget during active rollout (run quickly after triggering rollout):**

```bash
kubectl describe pdb web-pdb-max | grep "Allowed disruptions"
```

During rollout, Allowed disruptions may temporarily drop to 0 —
any concurrent drain would be blocked until the rollout progresses.

```bash
# Rollback to busybox
kubectl rollout undo deployment/web-deploy
kubectl rollout status deployment/web-deploy
kubectl delete -f pdb-maxunavailable.yaml
```

---

### Step 6: Single Replica Pitfall — minAvailable: 1 Blocks All Drains

```bash
# Verify no PDBs active
kubectl get pdb

# Scale to 1 replica
kubectl scale deployment web-deploy --replicas=1
kubectl get pods -o wide

cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb-single
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: web
EOF

kubectl describe pdb web-pdb-single
```

**Expected output:**
```
Name:           web-pdb-single
Min available:  1
Selector:       app=web
Status:
  Allowed disruptions:  0     ← zero disruptions allowed ✅
  Current:              1
  Desired:              1
  Total:                1
```

```
Allowed disruptions = Current(1) - Desired(1) = 0
→ Any eviction would drop below minAvailable(1)
→ kubectl drain will hang indefinitely
```

**Verify drain hangs:**

```bash
kubectl cordon 3node-m02
kubectl drain 3node-m02 --ignore-daemonsets --delete-emptydir-data &
DRAIN_PID=$!

sleep 15
kubectl get pods -o wide
# Pod still on 3node-m02 — drain is blocked
```

**Expected output:**
```
NAME                          READY   STATUS    NODE
web-deploy-xxxxxxxxx-aaaaa    1/1     Running   3node-m02   ← not moved
```

**Verify node is cordoned:**
```bash
kubectl describe node 3node-m02 | grep -E "Taints:|Unschedulable:"
```

**Expected output:**
```
Taints:         node.kubernetes.io/unschedulable:NoSchedule
Unschedulable:  true
```

**Cancel drain and fix — use maxUnavailable: 1 instead:**

```bash
kill $DRAIN_PID
kubectl uncordon 3node-m02
kubectl delete pdb web-pdb-single

cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb-fixed
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: web
EOF

kubectl describe pdb web-pdb-fixed
```

**Expected output:**
```
Name:             web-pdb-fixed
Max unavailable:  1
Selector:         app=web
Status:
  Allowed disruptions:  1    ← drain can now proceed ✅
  Current:              1
  Desired:              0    ← maxUnavailable=1, so Desired=Total(1)-1=0 ✅
  Total:                1
```

Allowed disruptions = 1 → drain can now proceed ✅

Note: Desired=0 when maxUnavailable=1 and replicas=1
→ maxUnavailable=1 means 1 pod can always be unavailable
→ Desired = Total - maxUnavailable = 1 - 1 = 0
→ Even with 1 replica, drain is always allowed


```bash
kubectl delete pdb web-pdb-fixed
kubectl delete -f web-deployment.yaml
```

---

### Step 7: unhealthyPodEvictionPolicy — AlwaysAllow

Deploy pods that fail readiness — simulating misbehaving pods stuck
in an unhealthy state during a node drain:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unhealthy-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: unhealthy-test
  template:
    metadata:
      labels:
        app: unhealthy-test
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"
          readinessProbe:
            exec:
              command: ["cat", "/tmp/ready"]
            initialDelaySeconds: 2
            periodSeconds: 5
EOF

kubectl get pods -l app=unhealthy-test -o wide
```

**Expected output:**
```
NAME                                READY   STATUS    NODE
unhealthy-deploy-xxxxxxxxx-aaaaa    0/1     Running   3node-m02   ← not ready
unhealthy-deploy-xxxxxxxxx-bbbbb    0/1     Running   3node-m02   ← not ready
unhealthy-deploy-xxxxxxxxx-ccccc    0/1     Running   3node-m03   ← not ready
```

All pods Running but 0/1 READY — readiness probe fails because
`/tmp/ready` does not exist. These pods are **unhealthy** (Running but
Ready=False). They will never recover without manual intervention.

**pdb-alwaysallow.yaml:**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: unhealthy-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: unhealthy-test
  unhealthyPodEvictionPolicy: AlwaysAllow
```

```bash
kubectl apply -f pdb-alwaysallow.yaml
kubectl describe pdb unhealthy-pdb
```

**Expected output:**
```
Status:
  Allowed disruptions:  0   ← 0 because no pods are healthy (Ready=True)
  Current:              0   ← 0 pods with Ready=True
  Desired:              1
  Total:                3
```

```
Current = 0 (no healthy pods) < Desired = 1 (minAvailable)
Normally: Allowed disruptions = 0 → drain hangs
With AlwaysAllow: unhealthy pods can always be evicted → drain proceeds
```

**Drain with AlwaysAllow — unhealthy pods evicted regardless:**

```bash
kubectl cordon 3node-m02
kubectl drain 3node-m02 \
  --ignore-daemonsets \
  --delete-emptydir-data
```

**Expected output:**
```
evicting pod default/unhealthy-deploy-xxxxxxxxx-aaaaa
evicting pod default/unhealthy-deploy-xxxxxxxxx-bbbbb
pod/unhealthy-deploy-xxxxxxxxx-aaaaa evicted
pod/unhealthy-deploy-xxxxxxxxx-bbbbb evicted
node/3node-m02 drained
```

Drain completed despite 0 healthy pods — `AlwaysAllow` evicted unhealthy
pods regardless of budget. With `IfHealthyBudget` (default), this drain
would hang indefinitely waiting for pods to become Ready.

```bash
kubectl uncordon 3node-m02
kubectl delete deployment unhealthy-deploy
kubectl delete -f pdb-alwaysallow.yaml
```

---

### Step 8: Cordon, Drain, Uncordon — Full Maintenance Workflow

Demonstrates a complete production node maintenance workflow with PDB
protecting application availability throughout.

```bash
# Apply PDB maxUnavailable: 1 with AlwaysAllow
kubectl apply -f web-deployment.yaml
kubectl apply -f pdb-maxunavailable.yaml
kubectl describe pdb web-pdb-max

kubectl get pods -o wide
```

**Expected output:**
```
NAME                          READY   STATUS    NODE
web-deploy-xxxxxxxxx-25klh    1/1     Running   3node-m02
web-deploy-xxxxxxxxx-glwlm    1/1     Running   3node-m03
web-deploy-xxxxxxxxx-rzthc    1/1     Running   3node-m02
web-deploy-xxxxxxxxx-vqxqs    1/1     Running   3node-m03
web-deploy-xxxxxxxxx-vs9bd    1/1     Running   3node-m02
```

**Step 8a — Cordon 3node-m02:**

```bash
kubectl cordon 3node-m02
kubectl get nodes
```

**Expected output:**
```
NAME        STATUS                     ROLES
3node       Ready                      control-plane
3node-m02   Ready,SchedulingDisabled   <none>    ← cordoned
3node-m03   Ready                      <none>
```

**Verify cordon details on the node:**
```
kubectl describe node 3node-m02 | grep -E "Taints:|Unschedulable:"
```

**Expected output:**
```
Taints:         node.kubernetes.io/unschedulable:NoSchedule
Unschedulable:  true
```

**Verify cordon event on the node:**
```
kubectl describe node 3node-m02 | grep -A3 Events
```

**Expected output:**
```
Events:
  Type    Reason               Age   From     Message
  Normal  NodeNotSchedulable   ...   kubelet  Node 3node-m02 status is now: NodeNotSchedulable
```

```bash
kubectl get pods -o wide
# All pods still running — cordon only stops NEW scheduling
```

**Expected output:**
```
NAME                          READY   STATUS    NODE
web-deploy-xxxxxxxxx-25klh    1/1     Running   3node-m02   ← still running
web-deploy-xxxxxxxxx-glwlm    1/1     Running   3node-m03
web-deploy-xxxxxxxxx-rzthc    1/1     Running   3node-m02   ← still running
web-deploy-xxxxxxxxx-vqxqs    1/1     Running   3node-m03
web-deploy-xxxxxxxxx-vs9bd    1/1     Running   3node-m02   ← still running
```


>Cordon only sets Unschedulable: true and adds the
>node.kubernetes.io/unschedulable:NoSchedule taint.
>Existing pods keep running — cordon only stops NEW scheduling.

**Step 8b — Drain 3node-m02:**

```bash
kubectl drain 3node-m02 \
  --ignore-daemonsets \
  --delete-emptydir-data
```

**Expected output — drain with PDB active (maxUnavailable: 1):**
```
node/3node-m02 already cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/kindnet-gr5gr, kube-system/kube-proxy-t4sp5
evicting pod default/web-deploy-xxxxxxxxx-vs9bd
evicting pod default/web-deploy-xxxxxxxxx-25klh
evicting pod default/web-deploy-xxxxxxxxx-rzthc
error when evicting pods/"web-deploy-xxxxxxxxx-25klh" -n "default" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
error when evicting pods/"web-deploy-xxxxxxxxx-vs9bd" -n "default" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
evicting pod default/web-deploy-xxxxxxxxx-25klh
evicting pod default/web-deploy-xxxxxxxxx-vs9bd
pod/web-deploy-xxxxxxxxx-rzthc evicted
pod/web-deploy-xxxxxxxxx-25klh evicted
pod/web-deploy-xxxxxxxxx-vs9bd evicted
node/3node-m02 drained
```

**Observations from verified drain output:**
```
1. DaemonSet warning — always appears:
   "Warning: ignoring DaemonSet-managed Pods: kube-system/kindnet-gr5gr,
   kube-system/kube-proxy-t4sp5"
   → DaemonSet pods skipped — this is expected and normal
   → --ignore-daemonsets flag causes this warning

2. drain tries to evict ALL pods simultaneously — not one at a time:
   "evicting pod ...vs9bd"
   "evicting pod ...25klh"
   "evicting pod ...rzthc"
   → drain sends eviction requests to all pods on the node at once

3. PDB blocks 2 of 3 evictions immediately (429):
   "error when evicting pods/...25klh (will retry after 5s):
   Cannot evict pod as it would violate the pod's disruption budget."
   → maxUnavailable: 1 only allows 1 eviction at a time
   → 2 pods get 429, 1 succeeds

4. drain auto-retries every 5s — no manual intervention needed:
   "evicting pod default/...25klh"  ← retry
   "evicting pod default/...vs9bd"  ← retry
   → drain keeps retrying blocked pods until budget is restored

5. All 3 pods evicted successfully and drain completes:
   pod/...rzthc evicted
   pod/...25klh evicted
   pod/...vs9bd evicted
   node/3node-m02 drained ✅
```

```bash
kubectl get pods -o wide
```

**Expected output:**
```
NAME                          READY   STATUS    NODE
web-deploy-xxxxxxxxx-2bmpz    1/1     Running   3node-m03   ← replacement
web-deploy-xxxxxxxxx-cjvfj    1/1     Running   3node-m03   ← replacement
web-deploy-xxxxxxxxx-glwlm    1/1     Running   3node-m03   ← was here already
web-deploy-xxxxxxxxx-lfxf7    1/1     Running   3node-m03   ← replacement
web-deploy-xxxxxxxxx-vqxqs    1/1     Running   3node-m03   ← was here already
```


The 3 pods from 3node-m02 were evicted and recreated by the
Deployment controller on 3node-m03. The 2 original 3node-m03
pods were unaffected.

**Step 8c — [Perform maintenance — OS patch, hardware replacement, etc.]**

```bash
# In production: patch OS, replace hardware, upgrade kubelet etc.
# In this demo: simulate maintenance with a sleep
sleep 5
echo "Maintenance complete"
```

**Step 8d — Uncordon 3node-m02:**

```bash
kubectl uncordon 3node-m02
kubectl get nodes
```

**Expected output:**
```
NAME        STATUS   ROLES
3node       Ready    control-plane
3node-m02   Ready    <none>    ← schedulable again
3node-m03   Ready    <none>
```

**Verify cordon event on the node:**
```
kubectl describe node 3node-m02 | grep -A3 Events
```

**Expected output:**
```
Events:
  Type    Reason            Age   From     Message
  Normal  NodeSchedulable   ...   kubelet  Node 3node-m02 status is now: NodeSchedulable
```

**Verify: existing pods do NOT automatically move back:**

```bash
kubectl get pods -o wide
```

**Expected output:**
```
NAME                          READY   STATUS    NODE
web-deploy-xxxxxxxxx-2bmpz    1/1     Running   3node-m03   ← stays
web-deploy-xxxxxxxxx-cjvfj    1/1     Running   3node-m03   ← stays
web-deploy-xxxxxxxxx-glwlm    1/1     Running   3node-m03   ← stays
web-deploy-xxxxxxxxx-lfxf7    1/1     Running   3node-m03   ← stays
web-deploy-xxxxxxxxx-vqxqs    1/1     Running   3node-m03   ← stays
```

> Existing pods stay on their current node after uncordon.
> Only NEW pods will schedule on `3node-m02`.
> Kubernetes does not rebalance running pods automatically.

**Force rebalance — rollout restart:**

```bash
kubectl rollout restart deployment/web-deploy
kubectl rollout status deployment/web-deploy
kubectl get pods -o wide
```

**Expected output after restart:**
```
Waiting for deployment "web-deploy" rollout to finish: 2 out of 5 new replicas have been updated...
Waiting for deployment "web-deploy" rollout to finish: 3 out of 5 new replicas have been updated...
Waiting for deployment "web-deploy" rollout to finish: 4 out of 5 new replicas have been updated...
Waiting for deployment "web-deploy" rollout to finish: 2 old replicas are pending termination...
Waiting for deployment "web-deploy" rollout to finish: 1 old replicas are pending termination...
deployment "web-deploy" successfully rolled out
```


```
kubectl get pods -o wide
```

**Expected output:**
```
NAME                          READY   STATUS    NODE
web-deploy-xxxxxxxxx-77mvt    1/1     Running   3node-m02   ← rebalanced
web-deploy-xxxxxxxxx-g4wcd    1/1     Running   3node-m03
web-deploy-xxxxxxxxx-htprs    1/1     Running   3node-m03
web-deploy-xxxxxxxxx-l72sh    1/1     Running   3node-m02   ← rebalanced
web-deploy-xxxxxxxxx-qvnhp    1/1     Running   3node-m02   ← rebalanced
```
Pods redistributed across both worker nodes after rollout restart. ✅

**Cleanup:**
```bash
kubectl delete -f pdb-maxunavailable.yaml
```

---

### Step 9: Final Cleanup

```bash
kubectl delete -f web-deployment.yaml
kubectl delete pdb --all

# Verify clean
kubectl get pdb
kubectl get pods
kubectl get nodes
```

---

## Common Questions

### Q: Does PDB work with StatefulSets?

**A:** Yes. PDB works with any replicated workload — Deployments,
StatefulSets, ReplicaSets. For a StatefulSet with 3 replicas and
`minAvailable: 2`, kubectl drain only evicts a pod if at least 2
replicas are healthy. Multiple parallel drains still respect the budget.

### Q: Does PDB stop rolling updates?

**A:** No. Pods unavailable during a rolling upgrade count against the
disruption budget, but Deployments and StatefulSets are not limited by
PDBs when doing rolling upgrades. The rollout is controlled by the
Deployment's own `maxUnavailable` and `maxSurge`. PDB only limits
Eviction-API-initiated disruptions.

### Q: What happens if PDB selector matches no pods?

**A:** An empty selector matches every pod in the namespace (policy/v1).
An unset selector selects no pods. Always set an explicit selector to
avoid unintended matches.

### Q: Does cluster autoscaler respect PDB?

**A:** Yes. If evicting pods from a node would violate a PDB, the
autoscaler will not scale down that node.

### Q: What is the difference between minAvailable: "50%" and maxUnavailable: "50%"?

**A:** They are complementary. With 10 replicas:
- `minAvailable: "50%"` → at least 5 must be available → 5 can be disrupted
- `maxUnavailable: "50%"` → at most 5 can be unavailable → 5 can be disrupted

Same result in this case, but behaviour differs as replicas scale.

---

## What You Learned

In this lab, you:
- ✅ Created PDBs with `minAvailable` absolute and percentage values
- ✅ Observed minAvailable blocking all disruptions when replicas = minAvailable
- ✅ Observed minAvailable going into deficit when replicas < minAvailable
- ✅ Created PDBs with `maxUnavailable` and confirmed it stays constant as replicas change
- ✅ Understood PDB during rolling updates — counts but does not control rollout
- ✅ Demonstrated single-replica pitfall and fixed it with maxUnavailable: 1
- ✅ Understood what unhealthy means (Ready=False) and when each policy applies
- ✅ Performed full cordon → drain → uncordon workflow with PDB active
- ✅ Verified existing pods do not rebalance after uncordon — used rollout restart

**Key Takeaway:** PDB is your application's availability guarantee during
voluntary disruptions. Use `maxUnavailable` for deployments that scale.
Set `unhealthyPodEvictionPolicy: AlwaysAllow` for stateless workloads —
official documentation recommends it as the better choice for most
workloads. After uncordon, existing pods do not rebalance automatically —
use `kubectl rollout restart` to redistribute.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get pdb` | List all PodDisruptionBudgets (short name) |
| `kubectl describe pdb <n>` | Show PDB status — Allowed disruptions, Current, Desired |
| `kubectl create pdb <n> --selector=app=<n> --min-available=2` | Create PDB imperatively (minAvailable) |
| `kubectl create pdb <n> --selector=app=<n> --max-unavailable=1` | Create PDB imperatively (maxUnavailable) |
| `kubectl cordon <node>` | Mark node unschedulable — existing pods unaffected |
| `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` | Safely drain node respecting PDB |
| `kubectl uncordon <node>` | Mark node schedulable again |
| `kubectl rollout restart deployment/<n>` | Force pod rebalancing after uncordon |
| `kubectl rollout status deployment/<n>` | Monitor rolling update or restart progress |
| `kubectl explain pdb.spec` | Browse PDB field docs |

---

## CKA Certification Tips

✅ **Short name:**
```bash
kubectl get pdb
kubectl describe pdb <n>
```

✅ **PDB API version — policy/v1:**
```yaml
apiVersion: policy/v1   # ← correct. v1beta1 removed in v1.25
kind: PodDisruptionBudget
```

✅ **minAvailable vs maxUnavailable — mutually exclusive, no default:**
```yaml
spec:
  minAvailable: 2     # OR
  maxUnavailable: 1   # NOT both — validation error
  # Neither has a default — one must be set
```

✅ **SMU — memory aid: "Selector Must be Updated"**
```
S → selector                  required
M → minAvailable/maxUnavailable required (one of)
U → unhealthyPodEvictionPolicy optional — default: IfHealthyBudget
```

✅ **Healthy pod definition:**
```
healthy = status.conditions type=Ready, status=True
unhealthy = Running but Ready=False (failing readiness probe)
```

✅ **Reading PDB status:**
```
Allowed disruptions = Current - Desired
If 0 → no evictions allowed → drain hangs
```

✅ **Single replica pitfall:**
```
replicas: 1 + minAvailable: 1 → Allowed disruptions = 0 → drain hangs
Fix: use maxUnavailable: 1
```

✅ **PDB does NOT control rolling updates — only counts disruptions**

✅ **After uncordon — existing pods do NOT rebalance automatically:**
```bash
kubectl rollout restart deployment/<n>   # to force rebalancing
```

✅ **Imperative creation:**
```bash
kubectl create pdb web-pdb --selector=app=web --min-available=2
kubectl create pdb web-pdb --selector=app=web --max-unavailable=1
```

---

## Troubleshooting

**kubectl drain hangs:**
```bash
kubectl describe pdb <n>
# Check Allowed disruptions — if 0, no evictions permitted
# Check Current — if 0 and policy=IfHealthyBudget → stuck on unhealthy pods
kubectl get pods -l <selector> -o wide
# Look for pods Running but not Ready (0/1)
# Fix: set unhealthyPodEvictionPolicy: AlwaysAllow
# Or: kubectl drain --disable-eviction (bypasses PDB — use with caution)
```

**PDB Allowed disruptions shows 0 unexpectedly:**
```bash
kubectl describe pdb <n>
# Check Current vs Desired — if equal or Current < Desired, allowed = 0
kubectl get pods -l <selector>
# Look for pods in non-Running or not-Ready (0/1) state
```

**Pods not rebalancing after uncordon:**
```bash
# This is expected — existing pods stay on their node
# Use rollout restart to redistribute
kubectl rollout restart deployment/<n>
kubectl rollout status deployment/<n>
kubectl get pods -o wide
```

**PDB not protecting pods during drain:**
```bash
# Verify selector matches pod labels exactly
kubectl get pods -l <pdb-selector> -o wide
# Verify PDB is in same namespace as pods
kubectl get pdb -n <namespace>
```