# Pod Topology Spread Constraints & Pod Scheduling Readiness

## Lab Overview

Pod affinity and anti-affinity allow some control of pod placement in
different topologies. However, these features only resolve part of pod
distribution use cases — either place unlimited pods in a single topology,
or disallow two pods from co-locating in the same topology. In between
these two extremes, there is a common need to distribute pods evenly
across topologies to achieve better cluster utilisation and high
availability. 

**Pod Topology Spread Constraints** address this gap. You can use topology
spread constraints to control how pods are spread across your cluster
among failure domains such as regions, zones, nodes, and other
user-defined topology domains — to achieve either high availability
or cost-saving. 

**Pod Scheduling Readiness** (`schedulingGates`) solves a separate
problem — preventing a pod from entering the scheduler queue until an
external condition is met. This is covered in the final step of this lab.

---

## Cluster Setup

This demo uses a dedicated **6-node minikube cluster** (`6node` profile)
with 2 worker nodes per availability zone. This is required to demonstrate
the real difference between zone-level and node-level topology spread —
something a 3-node cluster (1 node per zone) cannot show.

```
6node       → control plane (tainted — no workload pods)
6node-m02   → worker — zone-a
6node-m03   → worker — zone-a
6node-m04   → worker — zone-b
6node-m05   → worker — zone-b
6node-m06   → worker — zone-c
6node-m07   → worker — zone-c
```

### Create the Cluster

```bash
#stop existing cluster
minikube stop -p 3node

#create new clsuter
minikube start --nodes=7 -p 6node --kubernetes-version=v1.34.0
```

Wait for all nodes to be Ready:

```bash
kubectl get nodes
```

**Expected output:**
```
NAME        STATUS   ROLES           AGE   VERSION
6node       Ready    control-plane   2m    v1.34.0
6node-m02   Ready    <none>          2m    v1.34.0
6node-m03   Ready    <none>          2m    v1.34.0
6node-m04   Ready    <none>          2m    v1.34.0
6node-m05   Ready    <none>          2m    v1.34.0
6node-m06   Ready    <none>          2m    v1.34.0
6node-m07   Ready    <none>          2m    v1.34.0
```

Taint the control plane so workload pods do not land on it:

> **Note:** Minikube does not apply the control plane taint by default —
> unlike kubeadm clusters where it is applied automatically. We add it
> manually here to simulate a production-like cluster where workloads
> do not run on the control plane.
```bash
kubectl taint nodes 6node node-role.kubernetes.io/control-plane:NoSchedule
```

Verify:

```bash
kubectl describe node 6node | grep Taints
```

**Expected output:**
```
Taints: node-role.kubernetes.io/control-plane:NoSchedule
```

Add zone labels — 2 workers per zone:

```bash
kubectl label nodes 6node-m02 topology.kubernetes.io/zone=zone-a
kubectl label nodes 6node-m03 topology.kubernetes.io/zone=zone-a
kubectl label nodes 6node-m04 topology.kubernetes.io/zone=zone-b
kubectl label nodes 6node-m05 topology.kubernetes.io/zone=zone-b
kubectl label nodes 6node-m06 topology.kubernetes.io/zone=zone-c
kubectl label nodes 6node-m07 topology.kubernetes.io/zone=zone-c
```

Verify:

```bash
kubectl get nodes --show-labels | grep zone
```

**Expected output:**
```
6node-m02   ...   topology.kubernetes.io/zone=zone-a,...
6node-m03   ...   topology.kubernetes.io/zone=zone-a,...
6node-m04   ...   topology.kubernetes.io/zone=zone-b,...
6node-m05   ...   topology.kubernetes.io/zone=zone-b,...
6node-m06   ...   topology.kubernetes.io/zone=zone-c,...
6node-m07   ...   topology.kubernetes.io/zone=zone-c,...
```
---

## Prerequisites

**Required Software:**
- Minikube installed (cluster setup covered above)
- kubectl installed and configured
- Text editor (VS Code recommended with Kubernetes extension)

**Knowledge Requirements:**
- **REQUIRED:** Completion of [04-pod-affinity](../04-pod-affinity/)
- Understanding of `topologyKey` and topology domains
- Understanding of Pod Anti-Affinity and its binary limitation

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain `maxSkew` and how skew is calculated across topology domains
2. ✅ Write `topologySpreadConstraints` with all required fields (TMWLN)
3. ✅ Explain why `nodeTaintsPolicy: Honor` is required on clusters with a tainted control plane
4. ✅ Explain the difference between `DoNotSchedule` and `ScheduleAnyway` and when each applies
5. ✅ Demonstrate the real difference between zone-level and hostname-level spread using a 6-node cluster
6. ✅ Apply multiple topology constraints simultaneously (AND logic)
7. ✅ Combine Topology Spread with Node Affinity to restrict eligible nodes
8. ✅ Explain when `DoNotSchedule` causes Pending in production vs in a clean cluster
9. ✅ Gate a pod from scheduling using `schedulingGates` and release it
10. ✅ Compare Topology Spread with Pod Anti-Affinity and choose the right mechanism

## Directory Structure

```
05-pod-topology-spread/
├── README.md                         # This file
└── src/
    ├── spread-hostname.yaml          # Hostname spread, maxSkew: 1, nodeTaintsPolicy: Honor
    ├── spread-hostname-ignore.yaml   # Same without nodeTaintsPolicy — shows default Ignore behaviour
    ├── spread-donotschedule.yaml     # whenUnsatisfiable: DoNotSchedule
    ├── spread-scheduleanyway.yaml    # whenUnsatisfiable: ScheduleAnyway
    ├── spread-zone.yaml              # Zone-based spread — 2 nodes per zone
    ├── spread-multi-constraint.yaml  # Zone + hostname constraints simultaneously
    ├── spread-with-affinity.yaml     # Topology Spread + Node Affinity combined
    └── scheduling-gate.yaml          # schedulingGates — hold pod from scheduler queue
```

---

## Understanding Topology Spread Constraints

### maxSkew — The Core Concept

`maxSkew` is the maximum allowed difference in pod count between the most
loaded and least loaded topology domain.
```
Cluster: 6 worker nodes — 2 per zone (zone-a, zone-b, zone-c)
         1 control plane (tainted — excluded from skew with nodeTaintsPolicy: Honor)
Deployment: 6 replicas, topologyKey: zone, maxSkew: 1

Zone pod counts after scheduling:
  zone-a: 2   zone-b: 2   zone-c: 2   → skew = 0  ✅
  zone-a: 3   zone-b: 2   zone-c: 1   → skew = 2  ❌ (3-1=2 > maxSkew 1)
  zone-a: 2   zone-b: 2   zone-c: 1   → skew = 1  ✅ (2-1=1 = maxSkew 1)
```

> `maxSkew` must be greater than zero — `maxSkew: 0` is rejected at the
> API level. The tightest constraint is `maxSkew: 1`. Perfect balance
> (skew=0) is an outcome when replicas divide evenly, not an enforceable
> setting.

### Key Fields
```yaml
topologySpreadConstraints:
  - maxSkew: 1                               # max allowed pod count difference
    topologyKey: kubernetes.io/hostname      # topology boundary
    whenUnsatisfiable: DoNotSchedule         # hard or soft constraint
    nodeTaintsPolicy: Honor                  # how tainted nodes are counted
    labelSelector:                           # which pods to count
      matchLabels:
        app: my-app
```

| Field | Required | Purpose |
|---|---|---|
| `maxSkew` | ✅ | Maximum allowed pod count difference — must be ≥ 1 |
| `topologyKey` | ✅ | Label key defining topology domains |
| `whenUnsatisfiable` | ✅ | `DoNotSchedule` (hard) or `ScheduleAnyway` (soft) |
| `labelSelector` | ✅ | Which pods to count when calculating skew |
| `nodeTaintsPolicy` | ❌ | `Honor` or `Ignore` — default is `Ignore` |

### Topology Spread Syntax — Memory Aid
```yaml
topologySpreadConstraints:
  - topologyKey: kubernetes.io/hostname    # T
    maxSkew: 1                             # M
    whenUnsatisfiable: DoNotSchedule       # W
    labelSelector:                         # L
      matchLabels:
        app: my-app
    nodeTaintsPolicy: Honor                # N
```

**TMWLN** — "Topology Must Work Like Networks"
```
T → topologyKey       WHAT boundary defines a domain?
M → maxSkew           HOW MUCH imbalance is allowed? (must be ≥ 1)
W → whenUnsatisfiable WHAT happens when constraint is violated?
                        DoNotSchedule → Pending (hard)
                        ScheduleAnyway → schedule anyway (soft)
L → labelSelector     WHICH pods are counted in skew calculation?
N → nodeTaintsPolicy  HOW are tainted nodes treated?
                        Honor  → excluded if pod cannot tolerate taint
                        Ignore → counted regardless (default)
```

> T, M, W, L are **required** — missing any causes a validation error.
> N is **optional** — but always set `Honor` on clusters with a tainted
> control plane to avoid unexpected Pending.

### nodeTaintsPolicy — Critical on Real Clusters
```
nodeTaintsPolicy: Ignore  (default when field is not set)
  → ALL nodes including tainted ones counted in skew calculation
  → Tainted control plane has 0 pods → global minimum = 0
  → Any worker going from 1 to 2 pods → skew = 2-0 = 2
  → With maxSkew: 1 this causes unexpected Pending

nodeTaintsPolicy: Honor
  → Tainted nodes the pod cannot tolerate are EXCLUDED
  → Control plane excluded → only 6 worker domains counted
  → Correct skew calculation → expected behaviour
```

> Always set `nodeTaintsPolicy: Honor` on clusters with a tainted
> control plane. Without it, topology spread behaves unexpectedly —
> pods go Pending earlier than `maxSkew` would suggest.
> Verified on this cluster: without `Honor`, max schedulable replicas
> on hostname spread = 6 (one per worker). With `Honor`, 7th pod
> schedules correctly (skew=1 across 6 worker domains).

### DoNotSchedule vs ScheduleAnyway
```
DoNotSchedule  → Hard constraint
               → Pod goes Pending if placing it would violate maxSkew
               → Use when correct distribution matters more than availability

ScheduleAnyway → Soft constraint
               → Pod schedules even if it violates maxSkew
               → Scheduler still tries to minimise skew
               → Use when availability matters more than perfect distribution
```

### Zone Spread vs Hostname Spread — Why This Cluster Shows the Difference
```
topologyKey: kubernetes.io/hostname
  → each node is its own domain (7 domains including control plane)
  → with nodeTaintsPolicy: Honor → 6 worker domains
  → 6 pods across 6 worker nodes = 1 per node
  → scheduler has no freedom within a zone

topologyKey: topology.kubernetes.io/zone
  → zone-a, zone-b, zone-c are the 3 domains
  → 6 pods across 3 zones = 2 per zone
  → within each zone the scheduler places freely across 2 nodes
  → result: same zone balance, different node distribution possible
```

This distinction is only visible with multiple nodes per zone — which is
why this demo uses a 6-node cluster instead of the standard 3-node cluster.

### Topology Spread vs Pod Anti-Affinity

| | Pod Anti-Affinity | Topology Spread |
|---|---|---|
| Control | Binary — same or different | Numeric — max N difference |
| Surplus replicas | Pending if no slot | Spreads as evenly as possible |
| Multiple replicas per domain | Hard to express | Native — that is the point |
| Production HA use case | Simple one-per-node | Even zone distribution |

---

## Lab Step-by-Step Guide

---

### Step 1: Verify Cluster State

```bash
cd 05-pod-topology-spread/src

kubectl get nodes
```

**Expected output:**
```
NAME        STATUS   ROLES           AGE   VERSION
6node       Ready    control-plane   10m   v1.34.0
6node-m02   Ready    <none>          10m   v1.34.0
6node-m03   Ready    <none>          10m   v1.34.0
6node-m04   Ready    <none>          10m   v1.34.0
6node-m05   Ready    <none>          10m   v1.34.0
6node-m06   Ready    <none>          10m   v1.34.0
6node-m07   Ready    <none>          10m   v1.34.0
```

Verify control plane taint and zone labels before proceeding:

```bash
kubectl describe node 6node | grep Taints
kubectl get nodes --show-labels | grep zone
```

> If either is missing go back to Cluster Setup and apply them first.

---

### Step 2: Basic Hostname Spread — maxSkew: 1

**spread-hostname.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-hostname-deploy
spec:
  replicas: 6
  selector:
    matchLabels:
      app: spread-hostname
  template:
    metadata:
      labels:
        app: spread-hostname
    spec:
      terminationGracePeriodSeconds: 0
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          nodeTaintsPolicy: Honor
          labelSelector:
            matchLabels:
              app: spread-hostname
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

**Key YAML Fields:**
- `topologySpreadConstraints` — under `spec.template.spec`, same level
  as `affinity` and `containers`
- `topologyKey: kubernetes.io/hostname` — each node is its own domain
- `maxSkew: 1` — most loaded node can have at most 1 more pod than
  the least loaded node
- `nodeTaintsPolicy: Honor` — tainted nodes that the pod cannot
  tolerate are excluded from skew calculation. Without this, the tainted
  control plane is counted as a domain with 0 pods, pulling the global
  minimum to 0 and causing unexpected Pending behaviour
- `labelSelector` — counts only pods with `app: spread-hostname`.
  Other pods on the same nodes are not counted

```bash
kubectl apply -f spread-hostname.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                     READY   STATUS    NODE
spread-hostname-deploy-xxxxxxxxx-aaaaa   1/1     Running   6node-m02
spread-hostname-deploy-xxxxxxxxx-bbbbb   1/1     Running   6node-m03
spread-hostname-deploy-xxxxxxxxx-ccccc   1/1     Running   6node-m04
spread-hostname-deploy-xxxxxxxxx-ddddd   1/1     Running   6node-m05
spread-hostname-deploy-xxxxxxxxx-eeeee   1/1     Running   6node-m06
spread-hostname-deploy-xxxxxxxxx-fffff   1/1     Running   6node-m07
```

6 pods, 1 per worker node, skew = 0. Control plane (`6node`) receives
no pods — taint blocks it and `nodeTaintsPolicy: Honor` excludes it
from skew calculation.

**Scale to 7 and observe:**

```bash
kubectl scale deployment spread-hostname-deploy --replicas=7
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                     READY   STATUS    NODE
spread-hostname-deploy-xxxxxxxxx-aaaaa   1/1     Running   6node-m02
spread-hostname-deploy-xxxxxxxxx-bbbbb   1/1     Running   6node-m03
spread-hostname-deploy-xxxxxxxxx-ccccc   1/1     Running   6node-m04
spread-hostname-deploy-xxxxxxxxx-ddddd   1/1     Running   6node-m05
spread-hostname-deploy-xxxxxxxxx-eeeee   1/1     Running   6node-m06
spread-hostname-deploy-xxxxxxxxx-fffff   1/1     Running   6node-m07
spread-hostname-deploy-xxxxxxxxx-ggggg   1/1     Running   6node-m02
```

7th pod schedules on one of the worker nodes. With `nodeTaintsPolicy:
Honor`, the 6 worker domains each have 1 pod. Adding the 7th creates
2 vs 1 = skew of 1 which is within `maxSkew: 1`. ✅

> **Why `nodeTaintsPolicy: Honor` matters:**
> Without this field, the default is `Ignore` — the tainted control
> plane is counted as a domain with 0 pods. Global minimum becomes 0.
> Any worker going from 1 to 2 pods creates skew of 2 which exceeds
> `maxSkew: 1` — the 7th pod goes Pending even though 6 worker nodes
> have capacity. Always set `nodeTaintsPolicy: Honor` on clusters with
> a tainted control plane.

**Scale to 12 — observe 2 pods per node:**

```bash
kubectl scale deployment spread-hostname-deploy --replicas=12
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                     READY   STATUS    NODE
spread-hostname-deploy-xxxxxxxxx-aaaaa   1/1     Running   6node-m02
spread-hostname-deploy-xxxxxxxxx-bbbbb   1/1     Running   6node-m02
spread-hostname-deploy-xxxxxxxxx-ccccc   1/1     Running   6node-m03
spread-hostname-deploy-xxxxxxxxx-ddddd   1/1     Running   6node-m03
spread-hostname-deploy-xxxxxxxxx-eeeee   1/1     Running   6node-m04
spread-hostname-deploy-xxxxxxxxx-fffff   1/1     Running   6node-m04
spread-hostname-deploy-xxxxxxxxx-ggggg   1/1     Running   6node-m05
spread-hostname-deploy-xxxxxxxxx-hhhhh   1/1     Running   6node-m05
spread-hostname-deploy-xxxxxxxxx-iiiii   1/1     Running   6node-m06
spread-hostname-deploy-xxxxxxxxx-jjjjj   1/1     Running   6node-m06
spread-hostname-deploy-xxxxxxxxx-kkkkk   1/1     Running   6node-m07
spread-hostname-deploy-xxxxxxxxx-lllll   1/1     Running   6node-m07
```

12 pods, 2 per node, skew = 0. ✅

**Scale to 13 — observe skew of 1:**

```bash
kubectl scale deployment spread-hostname-deploy --replicas=13
kubectl get pods -o wide
# One node gets 3 pods, others get 2 — skew = 1 which is within maxSkew: 1 ✅
```

**Scale back:**
```bash
kubectl scale deployment spread-hostname-deploy --replicas=6
```

**Cleanup:**
```bash
kubectl delete -f spread-hostname.yaml
```

---

### Step 2b: nodeTaintsPolicy — Default Ignore Behaviour

This step shows what happens when `nodeTaintsPolicy` is not set — the
default is `Ignore`, meaning **all nodes including tainted ones are
counted** in the skew calculation.

The manifest is identical to `spread-hostname.yaml` from Step 2 but
with `nodeTaintsPolicy: Honor` removed:

**spread-hostname-ignore.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-ignore-deploy
spec:
  replicas: 6
  selector:
    matchLabels:
      app: spread-ignore
  template:
    metadata:
      labels:
        app: spread-ignore
    spec:
      terminationGracePeriodSeconds: 0
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          # nodeTaintsPolicy not set → default is Ignore
          labelSelector:
            matchLabels:
              app: spread-ignore
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f spread-hostname-ignore.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                    READY   STATUS    NODE
spread-ignore-deploy-xxxxxxxxx-aaaaa    1/1     Running   6node-m02
spread-ignore-deploy-xxxxxxxxx-bbbbb    1/1     Running   6node-m03
spread-ignore-deploy-xxxxxxxxx-ccccc    1/1     Running   6node-m04
spread-ignore-deploy-xxxxxxxxx-ddddd    1/1     Running   6node-m05
spread-ignore-deploy-xxxxxxxxx-eeeee    1/1     Running   6node-m06
spread-ignore-deploy-xxxxxxxxx-fffff    1/1     Running   6node-m07
```

6 pods Running — 1 per worker node. So far identical to Step 2. Now
scale to 7 and observe:

```bash
kubectl scale deployment spread-ignore-deploy --replicas=7
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                    READY   STATUS    NODE
spread-ignore-deploy-xxxxxxxxx-aaaaa    1/1     Running   6node-m02
spread-ignore-deploy-xxxxxxxxx-bbbbb    1/1     Running   6node-m03
spread-ignore-deploy-xxxxxxxxx-ccccc    1/1     Running   6node-m04
spread-ignore-deploy-xxxxxxxxx-ddddd    1/1     Running   6node-m05
spread-ignore-deploy-xxxxxxxxx-eeeee    1/1     Running   6node-m06
spread-ignore-deploy-xxxxxxxxx-fffff    1/1     Running   6node-m07
spread-ignore-deploy-xxxxxxxxx-ggggg    0/1     Pending   <none>
```

7th pod goes Pending — even though 6 worker nodes each have capacity.

**Why?**

```
nodeTaintsPolicy: Ignore (default)
  → ALL 7 nodes counted as topology domains including tainted 6node
  → 6node is an eligible domain with 0 pods
  → global minimum across all domains = 0 (6node has no pods)
  → each worker domain has 1 pod
  → placing 7th pod on any worker → that domain goes to 2 pods
  → skew = max(domain) - min(domain) = 2 - 0 = 2
  → maxSkew: 1 violated → DoNotSchedule blocks the 7th pod
  → result: Pending — not because workers are imbalanced
                       but because an untolerated domain pulls
                       the global minimum to 0
```

```bash
kubectl describe pod <pending-pod-name> | grep -A5 Events
```

**Expected output:**
```
Events:
  Warning  FailedScheduling  ...  0/7 nodes are available:
  1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
  6 node(s) didn't match pod topology spread constraints.
```

> **Key distinction:** This Pending is caused by the taint policy
> counting the control plane as a domain with 0 pods — NOT because
> `DoNotSchedule` genuinely detected an imbalance between worker nodes.
> All 6 workers have exactly 1 pod each (perfectly balanced). The
> constraint appears violated only because of the tainted node being
> counted.
>
> This is why `nodeTaintsPolicy: Honor` is important — it gives
> accurate skew calculation by excluding nodes the pod cannot
> schedule on.

| | nodeTaintsPolicy: Honor | nodeTaintsPolicy: Ignore (default) |
|---|---|---|
| Domains counted | 6 workers only | 6 workers + control plane (7 total) |
| Global minimum at 6 replicas | 1 | 0 (control plane has 0 pods) |
| 7th pod | Running ✅ | Pending ❌ |
| Reason | skew = 1 ≤ maxSkew:1 | skew = 2 > maxSkew:1 |

**Cleanup:**
```bash
kubectl delete -f spread-hostname-ignore.yaml
```

---

### Step 3: DoNotSchedule — Understanding When It Actually Blocks

Now that we understand `nodeTaintsPolicy`, this step explores
`whenUnsatisfiable: DoNotSchedule` in isolation — with `Honor` set
correctly so taint policy does not interfere with the results.

---

#### Part 1 — Single Eligible Node

Taint all worker nodes except `6node-m02`:

```bash
kubectl taint nodes 6node-m03 test=true:NoSchedule
kubectl taint nodes 6node-m04 test=true:NoSchedule
kubectl taint nodes 6node-m05 test=true:NoSchedule
kubectl taint nodes 6node-m06 test=true:NoSchedule
kubectl taint nodes 6node-m07 test=true:NoSchedule
```

Verify only `6node-m02` is eligible:

```bash
kubectl describe nodes | grep -E "Name:|Taints:"
```

**Expected output:**
```
Name:               6node
Taints:             node-role.kubernetes.io/control-plane:NoSchedule
Name:               6node-m02
Taints:             <none>
Name:               6node-m03
Taints:             test=true:NoSchedule
...
```

**spread-donotschedule.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-dns-deploy
spec:
  replicas: 4
  selector:
    matchLabels:
      app: spread-dns
  template:
    metadata:
      labels:
        app: spread-dns
    spec:
      terminationGracePeriodSeconds: 0
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          nodeTaintsPolicy: Honor
          labelSelector:
            matchLabels:
              app: spread-dns
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f spread-donotschedule.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                  READY   STATUS    NODE
spread-dns-deploy-xxxxxxxxx-aaaaa     1/1     Running   6node-m02
spread-dns-deploy-xxxxxxxxx-bbbbb     1/1     Running   6node-m02
spread-dns-deploy-xxxxxxxxx-ccccc     1/1     Running   6node-m02
spread-dns-deploy-xxxxxxxxx-ddddd     1/1     Running   6node-m02
```

All 4 pods Running — no Pending. With `nodeTaintsPolicy: Honor`, only
`6node-m02` is counted as a domain. With 1 domain there is nothing to
compare against — **skew is always 0 regardless of pod count**.
`DoNotSchedule` has no violation to enforce.

**Cleanup:**
```bash
kubectl delete -f spread-donotschedule.yaml
```

---

#### Part 2 — Two Eligible Nodes

Remove the taint from `6node-m03`:

```bash
kubectl taint nodes 6node-m03 test=true:NoSchedule-
```

```bash
kubectl apply -f spread-donotschedule.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                  READY   STATUS    NODE
spread-dns-deploy-xxxxxxxxx-aaaaa     1/1     Running   6node-m02
spread-dns-deploy-xxxxxxxxx-bbbbb     1/1     Running   6node-m03
spread-dns-deploy-xxxxxxxxx-ccccc     1/1     Running   6node-m02
spread-dns-deploy-xxxxxxxxx-ddddd     1/1     Running   6node-m03
```

4 pods Running — 2 per node, **skew = 0**. Scale up and observe:

```bash
kubectl scale deployment spread-dns-deploy --replicas=9
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                  READY   STATUS    NODE
spread-dns-deploy-xxxxxxxxx-aaaaa     1/1     Running   6node-m02
spread-dns-deploy-xxxxxxxxx-bbbbb     1/1     Running   6node-m02
spread-dns-deploy-xxxxxxxxx-ccccc     1/1     Running   6node-m02
spread-dns-deploy-xxxxxxxxx-ddddd     1/1     Running   6node-m02
spread-dns-deploy-xxxxxxxxx-eeeee     1/1     Running   6node-m02
spread-dns-deploy-xxxxxxxxx-fffff     1/1     Running   6node-m03
spread-dns-deploy-xxxxxxxxx-ggggg     1/1     Running   6node-m03
spread-dns-deploy-xxxxxxxxx-hhhhh     1/1     Running   6node-m03
spread-dns-deploy-xxxxxxxxx-iiiii     1/1     Running   6node-m03
```

9 pods Running — no Pending. Distribution: 5-4, **skew = 1**. ✅

With 2 domains and `maxSkew: 1` the scheduler alternates between nodes
and never goes Pending regardless of replica count:

```
replicas 2 → 1-1  skew=0 ✅
replicas 3 → 2-1  skew=1 ✅
replicas 4 → 2-2  skew=0 ✅
replicas 5 → 3-2  skew=1 ✅
...always satisfiable
```

**Cleanup:**
```bash
kubectl delete -f spread-donotschedule.yaml
```

---

#### Part 3 — ScheduleAnyway: Direct Comparison

Re-taint `6node-m03` to restore 1 eligible node — same constrained
state as Part 1:

```bash
kubectl taint nodes 6node-m03 test=true:NoSchedule
```

**spread-scheduleanyway.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-sa-deploy
spec:
  replicas: 4
  selector:
    matchLabels:
      app: spread-sa
  template:
    metadata:
      labels:
        app: spread-sa
    spec:
      terminationGracePeriodSeconds: 0
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          nodeTaintsPolicy: Honor
          labelSelector:
            matchLabels:
              app: spread-sa
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f spread-scheduleanyway.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                  READY   STATUS    NODE
spread-sa-deploy-xxxxxxxxx-aaaaa      1/1     Running   6node-m02
spread-sa-deploy-xxxxxxxxx-bbbbb      1/1     Running   6node-m02
spread-sa-deploy-xxxxxxxxx-ccccc      1/1     Running   6node-m02
spread-sa-deploy-xxxxxxxxx-ddddd      1/1     Running   6node-m02
```

All 4 pods Running on `6node-m02`. With only 1 eligible domain,
`ScheduleAnyway` and `DoNotSchedule` behave identically — both stack
all pods on the single available node since skew is always 0 with
1 domain.

The difference between `DoNotSchedule` and `ScheduleAnyway` only
becomes meaningful when there are **multiple eligible domains and a
genuine skew violation** — which requires pre-existing imbalance.

**Direct comparison summary:**

| Scenario | DoNotSchedule | ScheduleAnyway |
|---|---|---|
| 1 eligible domain | All pods stack — no Pending | All pods stack — no Pending |
| 2 eligible domains (clean) | Alternates, never Pending | Alternates, never Pending |
| Pre-existing imbalance | **Pending** — refuses to worsen skew | **Schedules** — best effort only |
| nodeTaintsPolicy: Ignore | **Pending** — control plane counted | Schedules — ignores skew violation |

**Cleanup:**
```bash
kubectl delete -f spread-scheduleanyway.yaml
```

---

#### Part 4 — Real-World Scenarios Where DoNotSchedule Causes Pending

In a clean, stable cluster with `nodeTaintsPolicy: Honor`, `DoNotSchedule`
rarely causes Pending. It becomes relevant when **pre-existing imbalance**
makes placing a new pod violate `maxSkew`. Real-world triggers:

> **Note:** The following scenarios are based on reasoning about how
> topology spread constraints interact with cluster events. They have
> not been verified by live testing in this session. Use them as a
> conceptual guide only.

**Node failure:**
```
3 nodes, 6 pods (2 per node)
node-b fails → its 2 pods rescheduled onto node-a and node-c
node-a=3, node-b=0(gone), node-c=3
Node-b recovers, rejoins as new domain with 0 pods
New pod → node-a or node-c would create 4-0 skew=4 → Pending
New pod → node-b (0 pods) satisfies constraint → schedules there
```

**New node added to cluster:**
```
Cluster running 6 pods on 2 nodes (3 per node)
3rd node added → domain with 0 pods
New pod → existing node would create 4 vs 0 → skew=4 → Pending
New pod → new node (0 pods) → skew=3-0=3 > maxSkew:1 → still Pending
Solution: descheduler rebalances, or use ScheduleAnyway
```

**Rolling update:**
```
Old pods and new pods coexist during rolling update
labelSelector counts both generations
One node temporarily has higher count → new pods may go Pending
until old pods terminate and skew normalises
```

> **Note:** The most reliable way to observe `DoNotSchedule` Pending
> in a demo environment is using `nodeTaintsPolicy: Ignore` (default)
> — as demonstrated in Step 2b. The tainted control plane creates a
> permanent 0-pod domain that causes skew violations on any
> well-balanced worker cluster.
>
> In production, always use `nodeTaintsPolicy: Honor` and understand
> that Pending from `DoNotSchedule` indicates genuine imbalance that
> needs investigation — not a configuration error.

Remove all test taints before proceeding to Step 4:

```bash
kubectl taint nodes 6node-m03 test=true:NoSchedule-
kubectl taint nodes 6node-m04 test=true:NoSchedule-
kubectl taint nodes 6node-m05 test=true:NoSchedule-
kubectl taint nodes 6node-m06 test=true:NoSchedule-
kubectl taint nodes 6node-m07 test=true:NoSchedule-

# Verify all workers are clean
kubectl describe nodes | grep -E "Name:|Taints:"
```

**Expected output:**
```
Name:               6node
Taints:             node-role.kubernetes.io/control-plane:NoSchedule
Name:               6node-m02
Taints:             <none>
Name:               6node-m03
Taints:             <none>
Name:               6node-m04
Taints:             <none>
Name:               6node-m05
Taints:             <none>
Name:               6node-m06
Taints:             <none>
Name:               6node-m07
Taints:             <none>
```

---

### Step 4: Zone-Based Spread — The Real Power of This Cluster

This step shows why zone spread on a cluster with multiple nodes per
zone behaves differently from hostname spread — only visible with this
6-node setup.

**spread-zone.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-zone-deploy
spec:
  replicas: 6
  selector:
    matchLabels:
      app: spread-zone
  template:
    metadata:
      labels:
        app: spread-zone
    spec:
      terminationGracePeriodSeconds: 0
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          nodeTaintsPolicy: Honor
          labelSelector:
            matchLabels:
              app: spread-zone
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f spread-zone.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                  READY   STATUS    NODE
spread-zone-deploy-xxxxxxxxx-aaaaa    1/1     Running   6node-m02
spread-zone-deploy-xxxxxxxxx-bbbbb    1/1     Running   6node-m03
spread-zone-deploy-xxxxxxxxx-ccccc    1/1     Running   6node-m04
spread-zone-deploy-xxxxxxxxx-ddddd    1/1     Running   6node-m05
spread-zone-deploy-xxxxxxxxx-eeeee    1/1     Running   6node-m06
spread-zone-deploy-xxxxxxxxx-fffff    1/1     Running   6node-m07
```

```
zone-a: 2 pods (6node-m02, 6node-m03)
zone-b: 2 pods (6node-m04, 6node-m05)
zone-c: 2 pods (6node-m06, 6node-m07)
Zone skew = 0 ✅
```

The constraint is at **zone level** — 2 pods per zone. Within each zone
the scheduler placed freely across the 2 available nodes. Compare with
hostname spread (Step 2) where each node got exactly 1 pod regardless
of zone.

**Scale to 7 — observe zone-level skew:**

```bash
kubectl scale deployment spread-zone-deploy --replicas=7
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                  READY   STATUS    NODE
spread-zone-deploy-xxxxxxxxx-aaaaa    1/1     Running   6node-m02
spread-zone-deploy-xxxxxxxxx-bbbbb    1/1     Running   6node-m03
spread-zone-deploy-xxxxxxxxx-ccccc    1/1     Running   6node-m04
spread-zone-deploy-xxxxxxxxx-ddddd    1/1     Running   6node-m05
spread-zone-deploy-xxxxxxxxx-eeeee    1/1     Running   6node-m06
spread-zone-deploy-xxxxxxxxx-fffff    1/1     Running   6node-m07
spread-zone-deploy-xxxxxxxxx-ggggg    1/1     Running   6node-m02
```

```
zone-a: 3 pods (6node-m02 has 2, 6node-m03 has 1)
zone-b: 2 pods
zone-c: 2 pods
Zone skew = 3-2 = 1 ✅ within maxSkew: 1
```

7th pod lands in zone-a — the scheduler chose which node within zone-a
freely. Zone constraint is satisfied (skew=1). Node distribution within
the zone is the scheduler's decision.

**Scale to 12 — 4 pods per zone:**

```bash
kubectl scale deployment spread-zone-deploy --replicas=12
kubectl get pods -o wide
```

**Expected output:**
```
zone-a: 6node-m02(2), 6node-m03(2) = 4 pods
zone-b: 6node-m04(2), 6node-m05(2) = 4 pods
zone-c: 6node-m06(2), 6node-m07(2) = 4 pods
Zone skew = 0 ✅
```

**Scale to 13 — one zone gets 5:**

```bash
kubectl scale deployment spread-zone-deploy --replicas=13
kubectl get pods -o wide
```

**Expected output:**
```
zone-a: 5 pods (6node-m02 gets 3)
zone-b: 4 pods
zone-c: 4 pods
Zone skew = 5-4 = 1 ✅ schedules successfully
```

**Cleanup:**
```bash
kubectl delete -f spread-zone.yaml
```

---

### Step 5: Multiple Topology Constraints

Multiple constraints use AND logic — all must be satisfied simultaneously.

Real scenario: spread across zones for HA, then spread across nodes
within each zone for within-zone balance.

**spread-multi-constraint.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-multi-deploy
spec:
  replicas: 6
  selector:
    matchLabels:
      app: spread-multi
  template:
    metadata:
      labels:
        app: spread-multi
    spec:
      terminationGracePeriodSeconds: 0
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          nodeTaintsPolicy: Honor
          labelSelector:
            matchLabels:
              app: spread-multi
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          nodeTaintsPolicy: Honor
          labelSelector:
            matchLabels:
              app: spread-multi
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f spread-multi-constraint.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                    READY   STATUS    NODE
spread-multi-deploy-xxxxxxxxx-aaaaa     1/1     Running   6node-m02
spread-multi-deploy-xxxxxxxxx-bbbbb     1/1     Running   6node-m03
spread-multi-deploy-xxxxxxxxx-ccccc     1/1     Running   6node-m04
spread-multi-deploy-xxxxxxxxx-ddddd     1/1     Running   6node-m05
spread-multi-deploy-xxxxxxxxx-eeeee     1/1     Running   6node-m06
spread-multi-deploy-xxxxxxxxx-fffff     1/1     Running   6node-m07
```

```
Zone constraint:  zone-a=2, zone-b=2, zone-c=2  → skew=0 ✅
Node constraint:  each node=1                    → skew=0 ✅
Both satisfied simultaneously.
```

**Cleanup:**
```bash
kubectl delete -f spread-multi-constraint.yaml
```

---

### Step 6: Topology Spread + Node Affinity Combined

Node Affinity restricts which nodes are eligible. Topology Spread
distributes evenly among those eligible nodes only.

Real scenario: spread pods evenly across storage nodes — general
purpose nodes should not receive any pods.

```bash
kubectl label nodes 6node-m02 node-role=storage
kubectl label nodes 6node-m03 node-role=storage
kubectl label nodes 6node-m04 node-role=storage
kubectl label nodes 6node-m05 node-role=storage
# 6node-m06 and 6node-m07 NOT labeled — pods must not go there
```

**spread-with-affinity.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-affinity-deploy
spec:
  replicas: 4
  selector:
    matchLabels:
      app: spread-affinity
  template:
    metadata:
      labels:
        app: spread-affinity
    spec:
      terminationGracePeriodSeconds: 0
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-role
                    operator: In
                    values:
                      - storage
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          nodeTaintsPolicy: Honor
          labelSelector:
            matchLabels:
              app: spread-affinity
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f spread-with-affinity.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                      READY   STATUS    NODE
spread-affinity-deploy-xxxxxxxxx-aaaaa    1/1     Running   6node-m02
spread-affinity-deploy-xxxxxxxxx-bbbbb    1/1     Running   6node-m03
spread-affinity-deploy-xxxxxxxxx-ccccc    1/1     Running   6node-m04
spread-affinity-deploy-xxxxxxxxx-ddddd    1/1     Running   6node-m05
```

All 4 pods on storage nodes only — none on `6node-m06`, `6node-m07`,
or control plane. Evenly spread 1 per node across 4 eligible nodes.

**Cleanup:**
```bash
kubectl delete -f spread-with-affinity.yaml
kubectl label nodes 6node-m02 node-role-
kubectl label nodes 6node-m03 node-role-
kubectl label nodes 6node-m04 node-role-
kubectl label nodes 6node-m05 node-role-
```

---

### Step 7: Pod Scheduling Readiness — schedulingGates

By default a pod enters the scheduler queue immediately on creation.
`schedulingGates` hold a pod in `SchedulingGated` state — invisible to
the scheduler — until all gates are explicitly removed.

**When is this useful:**

```
A pod needs an external resource before it can run:
  → cloud disk not yet provisioned
  → network interface not yet attached
  → licence slot not yet allocated

Without gates: pod enters queue → goes Pending → scheduler retries
With gates:    pod waits silently in SchedulingGated → released when ready
```

**scheduling-gate.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gated-pod
spec:
  terminationGracePeriodSeconds: 0
  schedulingGates:
    - name: example.com/disk-provisioned
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
```

> Gate names are arbitrary strings — use domain-prefixed format
> (`example.com/gate-name`) by convention to avoid conflicts.
> A pod can have multiple gates — ALL must be removed before scheduling.

```bash
kubectl apply -f scheduling-gate.yaml
kubectl get pod gated-pod -o wide
```

**Expected output:**
```
NAME         READY   STATUS            NODE
gated-pod    0/1     SchedulingGated   <none>
```

The pod is created but the scheduler has not been asked to place it.
This is distinct from `Pending`:

```
Pending          → scheduler is trying but cannot find a node
SchedulingGated  → scheduler has not been asked yet — gate blocks entry
```

Inspect the gate:

```bash
kubectl get pod gated-pod -o yaml | grep -A3 schedulingGates
```

**Expected output:**
```yaml
  schedulingGates:
  - name: example.com/disk-provisioned
```

Remove the gate — simulate external resource ready:

```bash
kubectl patch pod gated-pod \
  --type='json' \
  -p='[{"op": "remove", "path": "/spec/schedulingGates"}]'

kubectl get pod gated-pod -o wide
```

**Expected output:**
```
NAME         READY   STATUS    NODE
gated-pod    1/1     Running   6node-m02
```

Gate removed → pod enters scheduler queue → scheduled and running.

**Cleanup:**
```bash
kubectl delete pod gated-pod --grace-period=0 --force
```

---

### Step 8: Final Cleanup

```bash
# Remove all remaining deployments and pods
kubectl delete deployment --all
kubectl delete pod --all

# Remove zone labels
kubectl label nodes 6node-m02 topology.kubernetes.io/zone-
kubectl label nodes 6node-m03 topology.kubernetes.io/zone-
kubectl label nodes 6node-m04 topology.kubernetes.io/zone-
kubectl label nodes 6node-m05 topology.kubernetes.io/zone-
kubectl label nodes 6node-m06 topology.kubernetes.io/zone-
kubectl label nodes 6node-m07 topology.kubernetes.io/zone-

# Remove control plane taint
kubectl taint nodes 6node node-role.kubernetes.io/control-plane:NoSchedule-

# Verify clean state
kubectl get all
kubectl get nodes --show-labels

# Delete (or) Stop the cluster
minikube delete -p 6node
(or)
minikube stop -p 6node

# Switch back to 3node profile
kubectl config use-context 3node
minikube start -p 3node
```

---

## Experiments to Try

1. **schedulingGates with multiple gates:**
   ```yaml
   schedulingGates:
     - name: example.com/disk-ready
     - name: example.com/network-ready
   ```
   ```bash
   # Remove one gate — pod stays SchedulingGated (all must be removed)
   kubectl patch pod gated-pod --type='json' \
     -p='[{"op": "remove", "path": "/spec/schedulingGates/0"}]'
   kubectl get pod gated-pod   # still SchedulingGated
   kubectl patch pod gated-pod --type='json' \
     -p='[{"op": "remove", "path": "/spec/schedulingGates"}]'
   kubectl get pod gated-pod   # now Running
   ```

2. **maxSkew: 2 — relaxed constraint:**
   ```bash
   # Edit spread-zone.yaml, change maxSkew to 2
   # Deploy and scale to 9 pods
   # zone-a=4, zone-b=3, zone-c=2 → skew=2 ✅ schedules
   # zone-a=4, zone-b=3, zone-c=1 → skew=3 ❌ Pending
   ```

---

## Common Questions

### Q: How does Topology Spread interact with existing pods not in the deployment?

**A:** The `labelSelector` counts only pods that match the selector. Pods
without the matching label are invisible to the skew calculation. You can
have many other pods on a node without affecting the spread of your deployment.

### Q: What is the difference between `podAntiAffinity` and `topologySpreadConstraints`?

**A:** Pod Anti-Affinity gives binary control — same or different domain.
It enforces strict one-per-domain with `required`, or no numeric guarantee
with `preferred`. Topology Spread gives numeric control — you define the
maximum allowed imbalance. It handles surplus replicas gracefully without
going Pending, which Anti-Affinity with `required` cannot do.

### Q: Is `ScheduleAnyway` the same as not having a constraint at all?

**A:** No. With `ScheduleAnyway` the scheduler still tries to minimise
skew — it scores nodes based on how well they satisfy the spread goal.
The difference from no constraint is that spreading is still actively
preferred even when the constraint cannot be strictly enforced.

---

## Scheduling Mechanisms — Comparison & Decision Guide

Kubernetes provides several scheduling mechanisms. Understanding what
each one does and when to use it prevents misapplication and makes
your intent clear in the manifest.

#### What Each Mechanism Controls
```
Node Affinity          → relationship between a POD and a NODE
                         "schedule me on nodes that have label X"
                         Attracts pod to nodes — cannot spread pods

Pod Affinity           → relationship between a POD and other PODS (attract)
                         "schedule me where certain pods ARE running"
                         Co-location — cannot spread pods

Pod Anti-Affinity      → relationship between a POD and other PODS (repel)
                         "schedule me where certain pods ARE NOT running"
                         Spreading — binary same/different domain only

Topology Spread        → relationship between a POD and DOMAIN COUNTS
                         "distribute me so no domain has more than N extra pods"
                         Even numeric distribution — not binary

Taints & Tolerations   → relationship between a NODE and all PODS
                         Node-driven — node decides who is allowed
                         Exclusion and isolation

schedulingGates        → relationship between a POD and TIME
                         "do not even consider me for scheduling yet"
                         External condition gating
```

#### The Spreading Mechanisms — TSC vs Pod Anti-Affinity

Only two mechanisms are specifically designed for spreading:

| | Pod Anti-Affinity | Topology Spread |
|---|---|---|
| Control type | Binary — same or different domain | Numeric — max N difference |
| Self-limiting | Yes — 4th pod Pending with 3 nodes | No — surplus replicas handled |
| Surplus replicas | Pending (required) or stack (preferred) | Spreads as evenly as possible |
| Multiple levels | One topologyKey per rule | Multiple constraints simultaneously |
| When violated | Pending or ignored | DoNotSchedule or ScheduleAnyway |
| Production HA | Simple one-per-node | Even zone + node distribution |
| Best for | Small replica count, strict isolation | Large deployments, zone HA |

**When to choose Pod Anti-Affinity:**
- Replica count is small and known (e.g. exactly 3 replicas, 3 nodes)
- Strict one-per-domain is a hard requirement
- Simplicity matters — binary rule is easier to reason about

**When to choose Topology Spread:**
- Replica count varies or grows over time
- Zone-level HA is required (multiple nodes per zone)
- You need both zone and node-level spread simultaneously
- You cannot afford Pending when replicas exceed node count

#### Full Decision Guide

| Requirement | Use |
|---|---|
| Run pods on nodes with specific hardware (GPU, SSD, high-memory) | Node Affinity |
| Prevent pods from running on specific nodes | Node Affinity `NotIn` / `DoesNotExist` |
| Dedicate nodes to specific teams or workloads | Taints + Tolerations + Node Affinity |
| Co-locate pod with another pod (cache near app, sidecar pattern) | Pod Affinity |
| Strict one pod per node — small known replica count | Pod Anti-Affinity `required` |
| Best-effort spread — never go Pending | Pod Anti-Affinity `preferred` |
| Even distribution across nodes — any replica count | TSC `topologyKey: hostname` |
| Even distribution across availability zones | TSC `topologyKey: zone` |
| Even distribution across zones AND nodes simultaneously | TSC multi-constraint |
| Gate pod from scheduling until external resource is ready | schedulingGates |

#### Common Combinations in Production
```
Web tier (stateless, HA):
  TSC zone + hostname → even distribution, never Pending

Cache tier (latency-sensitive):
  Pod Affinity → co-locate with app pod on same node
  Pod Anti-Affinity → spread cache pods across nodes

ML/GPU tier (dedicated nodes):
  Node Affinity → GPU nodes only
  Taints + Tolerations → block non-ML pods from GPU nodes

Any pod needing external resource:
  schedulingGates → wait for EBS volume, ENI, licence slot
```

> Pod Affinity and Topology Spread are **not alternatives** —
> they serve opposite purposes. Pod Affinity brings pods together.
> Topology Spread distributes them evenly. Both can be active on
> the same deployment simultaneously.
>
> Pod Anti-Affinity and Topology Spread **do overlap** for spreading
> — but TSC is the modern preferred approach for zone-level HA
> because it handles surplus replicas and multiple topology levels
> in ways Anti-Affinity cannot.

## What You Learned

In this lab, you:
- ✅ Understood `maxSkew` as the maximum allowed pod count difference between topology domains
- ✅ Learned that `maxSkew` must be ≥ 1 — `maxSkew: 0` is rejected at the API level
- ✅ Understood `nodeTaintsPolicy` default is `Ignore` — tainted control plane is counted as a domain with 0 pods, pulling global minimum to 0 and causing unexpected Pending
- ✅ Set `nodeTaintsPolicy: Honor` to exclude tainted nodes from skew calculation
- ✅ Compared `DoNotSchedule` (hard) vs `ScheduleAnyway` (soft) — and understood that with correct `Honor` policy, `DoNotSchedule` rarely causes Pending in a clean cluster
- ✅ Saw zone-level spread with 2 nodes per zone — scheduler enforces zone balance, places freely within each zone
- ✅ Applied zone + hostname multi-constraint simultaneously
- ✅ Combined Topology Spread with Node Affinity to restrict eligible domains
- ✅ Gated a pod using `schedulingGates` and observed `SchedulingGated` state distinct from `Pending`
- ✅ Compared all scheduling mechanisms and understood when to use each

**Key Takeaway:** Topology Spread Constraints give numeric control over pod distribution that neither Anti-Affinity nor Node Affinity can express. Always set `nodeTaintsPolicy: Honor` on clusters with a tainted control plane. Zone spread with multiple nodes per zone is the standard production HA pattern. `schedulingGates` is the correct mechanism when a pod needs an external resource before it can run — not Pending

---

## Quick Commands Reference

Commands unique to this demo — commands common to all demos (get nodes, describe pod, get events) are not repeated here.

| Command | Description |
|---|---|
| `minikube start --nodes=7 -p 6node --kubernetes-version=v1.34.0` | Create 7-node cluster for this demo |
| `minikube delete -p 6node` | Delete 6node cluster |
| `kubectl config use-context 3node` | Switch kubectl context back to 3node cluster |
| `kubectl describe nodes \| grep -E "Name:\|Taints:"` | View all node names and taints together |
| `kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints` | View nodes and taints in table format |
| `kubectl cordon <node>` | Mark node unschedulable — existing pods unaffected |
| `kubectl uncordon <node>` | Mark node schedulable again |
| `kubectl get pod <n> -o yaml \| grep -A3 schedulingGates` | Inspect active scheduling gates on a pod |
| `kubectl patch pod <n> --type='json' -p='[{"op":"remove","path":"/spec/schedulingGates"}]'` | Remove all scheduling gates — pod enters scheduler queue |
| `kubectl explain pod.spec.topologySpreadConstraints` | Browse TSC field docs |
| `kubectl explain pod.spec.topologySpreadConstraints.nodeTaintsPolicy` | Check nodeTaintsPolicy values and default |
| `kubectl explain pod.spec.schedulingGates` | Browse schedulingGates field docs |

---

## CKA Certification Tips

Tips unique to this demo only.

✅ **TMWLN — all four required fields, one optional:**
```yaml
topologySpreadConstraints:
  - topologyKey: kubernetes.io/hostname  # T — required
    maxSkew: 1                           # M — required, must be ≥ 1
    whenUnsatisfiable: DoNotSchedule     # W — required
    labelSelector:                       # L — required
      matchLabels:
        app: my-app
    nodeTaintsPolicy: Honor              # N — optional, always set on tainted clusters
```

✅ **`topologySpreadConstraints` sits at pod spec level — same as `affinity`:**
```yaml
spec:
  template:
    spec:
      affinity: ...
      topologySpreadConstraints:   # ← same level as affinity ✅
        - topologyKey: ...
      containers:
      - name: ...
```

✅ **`nodeTaintsPolicy` default is `Ignore` — verified by `kubectl explain`:**
```bash
kubectl explain pod.spec.topologySpreadConstraints.nodeTaintsPolicy
# "If this value is nil, the behavior is equivalent to the Ignore policy"
# Ignore → tainted control plane counted as domain with 0 pods → unexpected Pending
# Honor → tainted nodes excluded → correct skew calculation
```

✅ **`SchedulingGated` is not `Pending`:**
```
Pending         → scheduler tried, no eligible node found
SchedulingGated → scheduler has not been asked yet — gate blocks queue entry
```

✅ **`schedulingGates` patch to release a pod:**
```bash
kubectl patch pod <pod-name> \
  --type='json' \
  -p='[{"op": "remove", "path": "/spec/schedulingGates"}]'
```

✅ **Multiple constraints = AND logic:**
```yaml
topologySpreadConstraints:
  - topologyKey: topology.kubernetes.io/zone    # both must be
  - topologyKey: kubernetes.io/hostname          # satisfied
```

---

### Troubleshooting

**Pods Pending with "didn't match pod topology spread constraints":**
```bash
kubectl describe pod <pod-name> | grep -A8 Events
# Check nodeTaintsPolicy — if not set (Ignore), tainted control plane
# is counted as domain with 0 pods pulling global minimum to 0
kubectl describe nodes | grep -E "Name:|Taints:"
# Verify zone labels are present on all worker nodes
kubectl get nodes --show-labels | grep zone
```

**Pod stuck in SchedulingGated:**
```bash
# Inspect active gates
kubectl get pod <n> -o yaml | grep -A3 schedulingGates
# Remove all gates
kubectl patch pod <n> --type='json' \
  -p='[{"op": "remove", "path": "/spec/schedulingGates"}]'
```

**Spread uneven after scaling — pods stacking on one node:**
```bash
# Check if pre-existing pods with matching label are skewing the count
kubectl get pods -l app=<label> -o wide
# Check nodeTaintsPolicy — Ignore pulls minimum to 0
kubectl explain pod.spec.topologySpreadConstraints.nodeTaintsPolicy
```