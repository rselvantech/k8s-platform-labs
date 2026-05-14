# DaemonSet Node Targeting — Controlling Where Pods Land

## Lab Overview

A DaemonSet's default behaviour is to place one pod on every node in the
cluster. In production, you almost always need finer control. A GPU driver
DaemonSet should only run on nodes with GPUs. A high-performance disk
monitoring agent should only run on nodes with SSDs. A security scanner
should run on worker nodes only — not the control-plane. Some nodes carry
taints that must be explicitly tolerated before any pod can land there.

This lab covers every mechanism Kubernetes provides for controlling which
nodes a DaemonSet targets: `nodeSelector`, `nodeAffinity` (required and
preferred), taints and tolerations (all three effects), and the interplay
between them. Each mechanism is demonstrated by labelling real nodes in
your `3node` cluster, watching `DESIRED` change live, and proving that
pods appear and disappear on cue.

**What you'll do:**
- Use `nodeSelector` to target a labelled subset of nodes
- Watch `DESIRED` count change as nodes gain and lose labels
- Use `nodeAffinity` with `requiredDuringSchedulingIgnoredDuringExecution`
- Use `nodeAffinity` with `preferredDuringSchedulingIgnoredDuringExecution`
- Understand why "IgnoredDuringExecution" matters for running DaemonSet pods
- Combine `matchExpressions` operators: `In`, `NotIn`, `Exists`, `DoesNotExist`
- Add and remove taints from nodes — `NoSchedule`, `PreferNoSchedule`, `NoExecute`
- Write tolerations that match taints precisely
- Target worker nodes only (exclude control-plane without using tolerations)
- Target a single named node using `nodeName` directly
- Layer multiple targeting mechanisms and understand their precedence

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control-plane + 2 worker nodes
- kubectl installed and configured

**Verify your cluster:**
```bash
kubectl get nodes --show-labels
```

**Knowledge Requirements:**
- **REQUIRED:** Completion of `01-basic-daemonset`
- Understanding of Kubernetes labels and selectors
- Familiarity with `kubectl get ds` column meanings

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
1. ✅ Use `nodeSelector` to restrict a DaemonSet to a subset of nodes
2. ✅ Explain the difference between `nodeSelector` and `nodeAffinity`
3. ✅ Write `requiredDuringScheduling` affinity rules with `matchExpressions`
4. ✅ Write `preferredDuringScheduling` affinity rules with `weight`
5. ✅ Explain what "IgnoredDuringExecution" means for running pods
6. ✅ Add taints to nodes and explain all three taint effects
7. ✅ Write tolerations that match taints — full and partial matching
8. ✅ Explain the difference between `NoSchedule` and `NoExecute` for existing pods
9. ✅ Target worker nodes only — two different approaches
10. ✅ Combine `nodeSelector` and tolerations and explain the AND relationship
11. ✅ Use `nodeName` for direct single-node targeting

## Directory Structure

```
02-daemonset-node-targeting/
└── src/
    ├── 01-nodeselector-daemonset.yaml          # nodeSelector — simple label match
    ├── 02-affinity-required-daemonset.yaml     # nodeAffinity required — expressions
    ├── 03-affinity-preferred-daemonset.yaml    # nodeAffinity preferred — weighted
    ├── 04-workers-only-daemonset.yaml          # Workers only — no control-plane toleration
    ├── 05-taint-toleration-daemonset.yaml      # NoSchedule taint + matching toleration
    └── 06-noexecute-toleration-daemonset.yaml  # NoExecute taint — eviction behaviour
```

---

## Targeting Mechanisms — Overview and Precedence

Kubernetes provides three targeting mechanisms for DaemonSets. They stack
as AND conditions — a node must satisfy all configured constraints to
receive a pod:

```
For a DaemonSet pod to land on a node, ALL of the following must be true:

  1. nodeSelector (if set)
       Node labels must match every key=value in nodeSelector

  2. nodeAffinity (if set)
       All required rules must be satisfied
       Preferred rules influence but do not block

  3. Taints and tolerations
       Node taints must all be tolerated by the pod spec
       (or have PreferNoSchedule effect — that only prefers, not blocks)

If any condition fails → DaemonSet controller skips this node
                      → DESIRED count does not include this node
                      → No pod created
```

**Mechanism comparison:**

| Mechanism | Syntax | Flexibility | Direction |
|-----------|--------|-------------|-----------|
| `nodeSelector` | Simple key=value map | Low — equality only | Pod → Node (pod says where it wants to go) |
| `nodeAffinity` | Expression-based | High — operators, weights | Pod → Node (pod says where it wants to go) |
| Taints + Tolerations | Taint on node, toleration on pod | Medium | Node → Pod (node says who can come) |
| `nodeName` | Direct node name | Exact | Pod → Node (bypass everything) |

**Rule of thumb:**
- Use `nodeSelector` for simple, stable labels (hardware type, zone)
- Use `nodeAffinity` when you need `NotIn`, `Exists`, `DoesNotExist`, or weighted preferences
- Use taints when the node needs to repel pods by default, with explicit opt-in via tolerations
- Never use `nodeName` in DaemonSets in production — it hardcodes a node name

---

## Part 1 — nodeSelector

### How nodeSelector Works

`nodeSelector` is the simplest targeting mechanism. You add a map of
key=value pairs to the pod spec. The DaemonSet controller only creates a
pod on nodes whose labels contain all the specified key=value pairs:

```
DaemonSet nodeSelector:
  disktype: ssd

Cluster nodes:
  3node      labels: {kubernetes.io/os: linux}              → NO pod (missing disktype=ssd)
  3node-m02  labels: {kubernetes.io/os: linux, disktype: ssd} → POD created
  3node-m03  labels: {kubernetes.io/os: linux, disktype: ssd} → POD created

DESIRED = 2
```

### Step 1.1 — Inspect Node Labels Before Starting

```bash
kubectl get nodes --show-labels
```

**Expected output (abbreviated):**
```
NAME        STATUS   LABELS
3node       Ready    beta.kubernetes.io/arch=amd64,kubernetes.io/hostname=3node,
                     node-role.kubernetes.io/control-plane=,kubernetes.io/os=linux,...
3node-m02   Ready    beta.kubernetes.io/arch=amd64,kubernetes.io/hostname=3node-m02,
                     kubernetes.io/os=linux,...
3node-m03   Ready    beta.kubernetes.io/arch=amd64,kubernetes.io/hostname=3node-m03,
                     kubernetes.io/os=linux,...
```

No `disktype` label exists yet. `DESIRED` will be `0` when we first deploy
the DaemonSet with `nodeSelector: disktype: ssd`.

---

### Step 1.2 — Deploy DaemonSet with nodeSelector

**01-nodeselector-daemonset.yaml:**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ds-nodeselector
spec:
  selector:
    matchLabels:
      app: ds-nodeselector
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: ds-nodeselector
    spec:
      nodeSelector:
        disktype: ssd        # Only nodes with this label receive a pod
      containers:
        - name: nginx
          image: nginx:1.27
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
```

```bash
kubectl apply -f 01-nodeselector-daemonset.yaml
kubectl get ds ds-nodeselector
```

**Expected output:**
```
NAME              DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR
ds-nodeselector   0         0         0       0            0           disktype=ssd
```

`DESIRED = 0` — no nodes have the `disktype=ssd` label. The `NODE SELECTOR`
column shows the selector value directly from `spec.template.spec.nodeSelector`.

---

### Step 1.3 — Label One Node — Watch DESIRED Go Up

```bash
# Terminal 1 — watch DaemonSet status
kubectl get ds ds-nodeselector -w

# Terminal 2 — label one worker
kubectl label node 3node-m02 disktype=ssd
```

**Terminal 1 — expected:**
```
NAME              DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
ds-nodeselector   0         0         0       0            0
ds-nodeselector   1         0         0       0            0   ← DESIRED increments
ds-nodeselector   1         1         0       1            0   ← pod created, starting
ds-nodeselector   1         1         1       1            1   ← pod ready
```

```bash
kubectl get pods -l app=ds-nodeselector -o wide
```

**Expected output:**
```
NAME                    READY   STATUS    NODE
ds-nodeselector-7mnbq   1/1     Running   3node-m02   ← only the labelled node
```

---

### Step 1.4 — Label Second Node — DESIRED Goes to 2

```bash
kubectl label node 3node-m03 disktype=ssd
kubectl get ds ds-nodeselector
```

**Expected output:**
```
DESIRED   CURRENT   READY
2         2         2
```

```bash
kubectl get pods -l app=ds-nodeselector -o wide
# Shows pods on 3node-m02 and 3node-m03 only
# 3node (control-plane) has no pod — no disktype=ssd label AND no toleration
```

---

### Step 1.5 — Remove a Label — DESIRED Goes Down, Pod Deleted

```bash
# Terminal 1 — watch pods
kubectl get pods -l app=ds-nodeselector -o wide -w

# Terminal 2 — remove label from 3node-m03
kubectl label node 3node-m03 disktype-    # The trailing dash removes the label
```

**Terminal 1 — expected:**
```
NAME                    READY   STATUS        NODE
ds-nodeselector-7mnbq   1/1     Running       3node-m02
ds-nodeselector-p9sz3   1/1     Running       3node-m03

ds-nodeselector-p9sz3   1/1     Terminating   3node-m03   ← label removed → pod deleted
```

```bash
kubectl get ds ds-nodeselector
# DESIRED = 1  (only 3node-m02 still has the label)
```

**Key insight:** `nodeSelector` is evaluated continuously by the DaemonSet
controller. Removing a label from a node causes the controller to delete
the pod from that node in the next reconcile cycle.

---

### Step 1.6 — Cleanup

```bash
kubectl delete -f 01-nodeselector-daemonset.yaml
kubectl label node 3node-m02 disktype-    # remove the label
```

---

## Part 2 — nodeAffinity

### nodeSelector vs nodeAffinity

`nodeSelector` only supports equality matching — a label must equal an
exact value. `nodeAffinity` supports expressions with operators, optional
weighting, and clearer semantics:

```
nodeSelector (simple):
  disktype: ssd           → node label must equal exactly "ssd"

nodeAffinity (expressive):
  key: disktype
  operator: In
  values: [ssd, nvme]     → node label can be "ssd" OR "nvme"

  key: env
  operator: NotIn
  values: [dev]           → node must NOT have env=dev

  key: gpu
  operator: Exists        → node must have the key "gpu" (any value)

  key: deprecated
  operator: DoesNotExist  → node must NOT have the key "deprecated"
```

### The Two Rule Types

```
requiredDuringSchedulingIgnoredDuringExecution
  → Pod WILL NOT be placed on a node that doesn't satisfy this rule
  → Like nodeSelector but with expression power
  → "IgnoredDuringExecution" means: if a running pod's node stops
    satisfying the rule (e.g. label removed), the pod keeps running
    It is NOT evicted. Only new scheduling decisions are affected.

preferredDuringSchedulingIgnoredDuringExecution
  → Pod PREFERS nodes that satisfy this rule, with a weight (1-100)
  → Pod can still be placed on nodes that don't satisfy it
  → Useful when you want to express preference without hard constraint
  → Multiple preferred rules are scored: node with highest total weight wins
  → Same "IgnoredDuringExecution" semantics — running pods not evicted
```

```
"IgnoredDuringExecution" — what it means for DaemonSets:

  Scenario: DaemonSet has required nodeAffinity for label env=prod
            3node-m02 has label env=prod → pod running

            Admin removes label: kubectl label node 3node-m02 env-
            → The running pod is NOT evicted (IgnoredDuringExecution)
            → But DESIRED count drops — the controller will not create
              a new pod here if this one dies
            → The running pod is now "misscheduled" from the controller's
              perspective — it will show in Misscheduled count

  Contrast with "RequiredDuringExecution" (not yet stable in Kubernetes):
            → Pod WOULD be evicted when node stops satisfying the rule
```

---

### Step 2.1 — Required nodeAffinity

**02-affinity-required-daemonset.yaml:**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ds-affinity-required
spec:
  selector:
    matchLabels:
      app: ds-affinity-required
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: ds-affinity-required
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-role
                    operator: In
                    values:
                      - worker
                      - compute          # Node must have node-role=worker OR node-role=compute
                  - key: env
                    operator: NotIn
                    values:
                      - dev              # AND node must NOT have env=dev
      containers:
        - name: nginx
          image: nginx:1.27
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
```

**Understanding `nodeSelectorTerms`:**
```
nodeSelectorTerms is a LIST — terms are OR'd together
  (node satisfies term[0] OR term[1] OR ... → pod can land)

Within each term, matchExpressions entries are AND'd
  (node must satisfy ALL expressions in a term)

This manifest has one term with two expressions:
  - node-role In [worker, compute]    AND
  - env NotIn [dev]
  → Node must match BOTH conditions
```

**Operator reference:**

| Operator | Meaning | Requires `values`? |
|----------|---------|-------------------|
| `In` | Label value is in the list | Yes |
| `NotIn` | Label value is not in the list | Yes |
| `Exists` | Label key is present (any value) | No |
| `DoesNotExist` | Label key is absent | No |
| `Gt` | Label value is greater than (numeric string) | Yes (one value) |
| `Lt` | Label value is less than (numeric string) | Yes (one value) |

```bash
kubectl apply -f 02-affinity-required-daemonset.yaml
kubectl get ds ds-affinity-required
```

**Expected: DESIRED = 0** — no nodes have `node-role=worker` yet.

```bash
# Label both worker nodes
kubectl label node 3node-m02 node-role=worker env=prod
kubectl label node 3node-m03 node-role=compute env=staging

kubectl get ds ds-affinity-required
```

**Expected: DESIRED = 2** — both workers match:
- `3node-m02`: `node-role=worker` (In [worker, compute] ✅) + `env=prod` (NotIn [dev] ✅)
- `3node-m03`: `node-role=compute` (In [worker, compute] ✅) + `env=staging` (NotIn [dev] ✅)

```bash
kubectl get pods -l app=ds-affinity-required -o wide
# Pods on 3node-m02 and 3node-m03 — not on control-plane 3node
```

**Now label 3node-m03 with env=dev — it should lose its pod:**
```bash
kubectl label node 3node-m03 env=dev --overwrite

kubectl get ds ds-affinity-required
# DESIRED drops to 1 — 3node-m03 now violates NotIn [dev]

kubectl get pods -l app=ds-affinity-required -o wide
# Pod on 3node-m03 is Terminating, then gone
```

**Cleanup:**
```bash
kubectl delete -f 02-affinity-required-daemonset.yaml
kubectl label node 3node-m02 node-role- env-
kubectl label node 3node-m03 node-role- env-
```

---

### Step 2.2 — Preferred nodeAffinity

**03-affinity-preferred-daemonset.yaml:**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ds-affinity-preferred
spec:
  selector:
    matchLabels:
      app: ds-affinity-preferred
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: ds-affinity-preferred
    spec:
      affinity:
        nodeAffinity:
          # No required rule — pod can go on ANY node
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 80                     # High preference
              preference:
                matchExpressions:
                  - key: disktype
                    operator: In
                    values: [ssd, nvme]      # Prefer SSD or NVMe nodes

            - weight: 20                     # Lower preference
              preference:
                matchExpressions:
                  - key: zone
                    operator: In
                    values: [us-east-1a]     # Also prefer us-east-1a zone
      containers:
        - name: nginx
          image: nginx:1.27
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
```

**How preferred rules score nodes:**
```
Node scoring (DaemonSet uses same logic as scheduler for preferred rules):

  3node (control-plane):  no disktype label → weight 80 not added
                          no zone label     → weight 20 not added
                          Score: 0

  3node-m02 (worker):     disktype=ssd → weight 80 added ✅
                          no zone label → weight 20 not added
                          Score: 80

  3node-m03 (worker):     disktype=ssd → weight 80 added ✅
                          zone=us-east-1a → weight 20 added ✅
                          Score: 100

Result: all three nodes STILL get a pod (preferred = not required).
        But if there were a choice between nodes, highest score wins.
        For DaemonSets this scoring mainly affects multi-node tie-breaking
        in scenarios with nodeSelectorTerms and partial matches.
```

```bash
kubectl apply -f 03-affinity-preferred-daemonset.yaml

# No nodeSelector, no required rule, control-plane toleration missing
# → DESIRED = 2 (worker nodes) — control-plane has NoSchedule taint
kubectl get ds ds-affinity-preferred
```

```bash
# Label nodes to see preferred scoring in action
kubectl label node 3node-m02 disktype=ssd
kubectl label node 3node-m03 disktype=ssd zone=us-east-1a

kubectl get pods -l app=ds-affinity-preferred -o wide
# Both worker nodes get pods (preferred rules don't exclude any nodes)
```

**Cleanup:**
```bash
kubectl delete -f 03-affinity-preferred-daemonset.yaml
kubectl label node 3node-m02 disktype-
kubectl label node 3node-m03 disktype- zone-
```

---

## Part 3 — Workers Only (No Control-Plane Toleration)

### Two Approaches to Exclude the Control-Plane

In `01-basic-daemonset` you added a toleration to include the control-plane.
Here you deliberately exclude it. There are two clean approaches:

**Approach A — Omit the toleration (simplest)**
The control-plane node has a `NoSchedule` taint by default. Without a
matching toleration, the DaemonSet controller will not schedule there.
`DESIRED` equals the number of worker nodes only.

**Approach B — Use nodeAffinity with DoesNotExist**
Explicitly require that the node does NOT have the
`node-role.kubernetes.io/control-plane` label.
This is more explicit and survives if the taint is removed from the
control-plane (e.g. in a single-node dev cluster).

**04-workers-only-daemonset.yaml:**

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ds-workers-only
spec:
  selector:
    matchLabels:
      app: ds-workers-only
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: ds-workers-only
    spec:
      # Approach A: Simply omit the control-plane toleration.
      # The control-plane node carries taint:
      #   node-role.kubernetes.io/control-plane:NoSchedule
      # Without a matching toleration, the controller skips it.
      # DESIRED = 2 (worker nodes only)
      #
      # NO tolerations block here — that is the entire point.

      # Approach B (alternative — uncomment to use):
      # affinity:
      #   nodeAffinity:
      #     requiredDuringSchedulingIgnoredDuringExecution:
      #       nodeSelectorTerms:
      #         - matchExpressions:
      #             - key: node-role.kubernetes.io/control-plane
      #               operator: DoesNotExist   # Exclude control-plane nodes explicitly
      containers:
        - name: nginx
          image: nginx:1.27
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
```

```bash
kubectl apply -f 04-workers-only-daemonset.yaml
kubectl get ds ds-workers-only
```

**Expected output:**
```
NAME              DESIRED   CURRENT   READY   NODE SELECTOR
ds-workers-only   2         2         2       <none>
```

`DESIRED = 2` — only the two worker nodes. The control-plane is excluded
by the absence of a toleration, with zero configuration overhead.

```bash
kubectl get pods -l app=ds-workers-only -o wide
# Pods only on 3node-m02 and 3node-m03
# 3node (control-plane) has no pod
```

**Cleanup:**
```bash
kubectl delete -f 04-workers-only-daemonset.yaml
```

---

## Part 4 — Taints and Tolerations

### What Taints Do

A taint is placed on a **node** — it is the node repelling pods. A
toleration is placed in the **pod spec** — it is the pod saying "I can
tolerate that taint." Without a matching toleration, the DaemonSet
controller will not schedule a pod on a tainted node.

```
Taint format:
  key=value:effect    (e.g. dedicated=gpu:NoSchedule)
  key:effect          (e.g. node-role.kubernetes.io/control-plane:NoSchedule)

Three effects:

  NoSchedule
    → New pods without a matching toleration will NOT be scheduled here
    → Existing pods on this node are NOT evicted
    → Strongest "no new pods" signal

  PreferNoSchedule
    → Scheduler and DaemonSet controller PREFER not to schedule here
    → Will schedule here if no other node is available
    → Soft version of NoSchedule

  NoExecute
    → New pods without a matching toleration will NOT be scheduled here (like NoSchedule)
    → EXISTING pods without a matching toleration ARE evicted immediately
    → Most severe — affects running pods too
    → Used for node failure (node.kubernetes.io/not-ready:NoExecute)
```

### Taint and Toleration Matching Rules

A toleration matches a taint if ALL of these are true:
```
Toleration key == Taint key     (or toleration omits key — matches all keys)
Toleration effect == Taint effect (or toleration omits effect — matches all effects)
operator: Equal  → toleration value == taint value (must specify value)
operator: Exists → taint key exists (any value or no value)
```

**Examples:**

```yaml
# Taint on node:
# dedicated=gpu:NoSchedule

# Toleration A — exact match:
tolerations:
  - key: dedicated
    operator: Equal
    value: gpu
    effect: NoSchedule    # Matches exactly

# Toleration B — key+effect match (any value):
tolerations:
  - key: dedicated
    operator: Exists
    effect: NoSchedule    # Matches if key "dedicated" exists with NoSchedule

# Toleration C — key match, any effect:
tolerations:
  - key: dedicated
    operator: Exists      # effect omitted → matches any effect for this key

# Toleration D — match everything (catch-all, use with caution):
tolerations:
  - operator: Exists      # key omitted, effect omitted → matches any taint
```

---

### Step 4.1 — NoSchedule Taint

```bash
# Apply a NoSchedule taint to 3node-m03
# Simulates: "this node is reserved for GPU workloads — keep others off"
kubectl taint node 3node-m03 dedicated=gpu:NoSchedule
```

**Verify taint was applied:**
```bash
kubectl describe node 3node-m03 | grep -A 3 "Taints:"
```

**Expected output:**
```
Taints:   dedicated=gpu:NoSchedule
```

**Deploy a DaemonSet WITHOUT a toleration for this taint:**

```bash
kubectl apply -f 04-workers-only-daemonset.yaml   # no toleration for dedicated=gpu
kubectl get ds ds-workers-only
```

**Expected output:**
```
DESIRED   CURRENT   READY
1         1         1       ← Only 3node-m02 — 3node-m03 blocked by taint
```

```bash
kubectl get pods -l app=ds-workers-only -o wide
# Pod on 3node-m02 only — 3node-m03 (tainted) has no pod
```

**Now deploy WITH a toleration:**

**05-taint-toleration-daemonset.yaml:**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ds-taint-toleration
spec:
  selector:
    matchLabels:
      app: ds-taint-toleration
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: ds-taint-toleration
    spec:
      tolerations:
        # Tolerate the gpu taint on 3node-m03
        - key: dedicated
          operator: Equal
          value: gpu
          effect: NoSchedule

        # Also tolerate the control-plane taint
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: nginx
          image: nginx:1.27
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
```

```bash
kubectl apply -f 05-taint-toleration-daemonset.yaml
kubectl get ds ds-taint-toleration
```

**Expected output:**
```
DESIRED   CURRENT   READY
3         3         3       ← All 3 nodes — both taints tolerated
```

```bash
kubectl get pods -l app=ds-taint-toleration -o wide
# Pods on all 3 nodes including tainted 3node-m03
```

**Remove the taint when done:**
```bash
kubectl taint node 3node-m03 dedicated=gpu:NoSchedule-   # trailing dash removes taint
kubectl delete -f 05-taint-toleration-daemonset.yaml
kubectl delete -f 04-workers-only-daemonset.yaml
```

---

### Step 4.2 — NoExecute Taint — Eviction of Running Pods

`NoExecute` is different from `NoSchedule` — it evicts pods that are
already running on the node if they do not have a matching toleration.

```bash
# Deploy a DaemonSet on all nodes first (with control-plane toleration, no gpu toleration)
kubectl apply -f 04-workers-only-daemonset.yaml  # DESIRED=2, pods on both workers
```

```bash
# Terminal 1 — watch pods
kubectl get pods -l app=ds-workers-only -o wide -w

# Terminal 2 — apply NoExecute taint to 3node-m02
kubectl taint node 3node-m02 maintenance=true:NoExecute
```

**Terminal 1 — expected:**
```
NAME                 READY   STATUS        NODE
ds-workers-only-xxx  1/1     Running       3node-m02
ds-workers-only-yyy  1/1     Running       3node-m03

ds-workers-only-xxx  1/1     Terminating   3node-m02   ← NoExecute evicts running pod
                                                         (no toleration for maintenance=true)
```

```bash
kubectl get ds ds-workers-only
# DESIRED = 1 — 3node-m02 is now excluded (taint + no toleration)
```

**NoExecute with tolerationSeconds — timed grace period:**

```yaml
tolerations:
  - key: maintenance
    operator: Equal
    value: "true"
    effect: NoExecute
    tolerationSeconds: 60   # Pod stays running for 60 seconds after taint is applied
                            # then is evicted if taint is not removed
                            # Useful for graceful shutdown windows
```

**Remove the NoExecute taint — pod is recreated:**
```bash
kubectl taint node 3node-m02 maintenance=true:NoExecute-

# The DaemonSet controller sees 3node-m02 is now untainted
# It creates a new pod on 3node-m02
kubectl get ds ds-workers-only
# DESIRED = 2 again

kubectl get pods -l app=ds-workers-only -o wide
# Pod back on 3node-m02
```

**Cleanup:**
```bash
kubectl delete -f 04-workers-only-daemonset.yaml
```

---

### Step 4.3 — NoExecute with tolerationSeconds

**06-noexecute-toleration-daemonset.yaml:**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ds-noexecute-grace
spec:
  selector:
    matchLabels:
      app: ds-noexecute-grace
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: ds-noexecute-grace
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule

        # Built-in Kubernetes node condition taints — always tolerate these
        # in DaemonSets that must stay running during node problems:
        - key: node.kubernetes.io/not-ready
          operator: Exists
          effect: NoExecute
          tolerationSeconds: 300    # Stay 5 minutes if node goes not-ready

        - key: node.kubernetes.io/unreachable
          operator: Exists
          effect: NoExecute
          tolerationSeconds: 300    # Stay 5 minutes if node becomes unreachable

        # Custom maintenance taint with grace period:
        - key: maintenance
          operator: Equal
          value: "true"
          effect: NoExecute
          tolerationSeconds: 120    # Stay 2 minutes after maintenance taint applied
      containers:
        - name: nginx
          image: nginx:1.27
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
```

**The built-in node condition taints:**
```
Kubernetes automatically applies taints to nodes based on their condition:

  node.kubernetes.io/not-ready:NoExecute
    → Applied when node condition Ready=False
    → Pods WITHOUT this toleration are evicted after 300s (default)

  node.kubernetes.io/unreachable:NoExecute
    → Applied when node condition Ready=Unknown (node-controller lost contact)
    → Pods WITHOUT this toleration are evicted after 300s (default)

  node.kubernetes.io/memory-pressure:NoSchedule
  node.kubernetes.io/disk-pressure:NoSchedule
  node.kubernetes.io/pid-pressure:NoSchedule
  node.kubernetes.io/unschedulable:NoSchedule   ← applied by kubectl cordon

DaemonSets for critical infrastructure (kube-proxy, CNI) tolerate all of
these — they must survive node problems to help the node recover.
```

**Understanding tolerationSeconds with DaemonSets — the recreation cycle:**

When `tolerationSeconds` expires and a DaemonSet pod is evicted, the
DaemonSet controller **immediately creates a new pod on the same node**.
The new pod also carries the same toleration — so the cycle repeats:

```
t=0:    taint applied → 120s countdown starts
t=120:  pod evicted (tolerationSeconds expired)
t=121:  DaemonSet controller creates NEW pod on same node
        → new pod also has tolerationSeconds: 120
        → new 120s countdown starts
t=241:  new pod evicted again
t=242:  another new pod created...
        → infinite cycle
```

This is confirmed by the `AGE=49s` you observed after waiting 120 seconds —
the original pod was evicted and a new one was already running.

**The correct maintenance workflow — cordon first, then taint:**

To actually remove the DaemonSet pod from a node during maintenance, the node
must be cordoned BEFORE the taint is applied. Cordoning excludes the node from
DESIRED — so when the pod is evicted, the controller does not recreate it.

```bash
# Step 1 — Deploy the DaemonSet
kubectl apply -f 06-noexecute-toleration-daemonset.yaml
kubectl get ds ds-noexecute-grace
# DESIRED=3, all pods Running

# Step 2 — Cordon the node FIRST (marks unschedulable, excludes from DESIRED)
kubectl cordon 3node-m03

kubectl get ds ds-noexecute-grace
# DESIRED=2 ← 3node-m03 now excluded
# CURRENT=3 ← existing pod still running (cordon does not evict)
# AVAILABLE=2

# Step 3 — Apply the NoExecute taint
kubectl taint node 3node-m03 maintenance=true:NoExecute

# Pod on 3node-m03 now has a 120s grace period (tolerationSeconds: 120)
# Watch the pod — it will be evicted after 120 seconds
kubectl get pods -l app=ds-noexecute-grace -o wide -w
```

**Expected output after 120 seconds:**

```
NAME                       READY   STATUS    
ds-noexecute-grace-42pj9   1/1     Running 
ds-noexecute-grace-4wrq8   1/1     Running 
ds-noexecute-grace-dvz9b   1/1     Running  
ds-noexecute-grace-4wrq8   1/1     Terminating   3node-m03   ← evicted after 120s
                                                             ← node is cordoned
                                                             → controller does NOT recreate on 3node-m03
```

```bash
kubectl get ds ds-noexecute-grace
# DESIRED=2  CURRENT=2  READY=2  ← stable, no recreation loop
```

```bash
# Step 4 — Do your maintenance work on 3node-m03...

# Step 5 — Remove taint and uncordon to restore
kubectl taint node 3node-m03 maintenance=true:NoExecute-
kubectl uncordon 3node-m03

kubectl get ds ds-noexecute-grace
# DESIRED=3 ← node back in cluster
# New pod created on 3node-m03

kubectl get pods -l app=ds-noexecute-grace -o wide
# All 3 nodes have pods again
```

**Without cordon — what you will observe (the recreation loop):**

```bash
# If you taint WITHOUT cordoning first:
kubectl taint node 3node-m03 maintenance=true:NoExecute

# After 120s: pod evicted
# After 121s: DaemonSet controller immediately creates a NEW pod on 3node-m03
#             (node not cordoned → still in DESIRED count)
# After 241s: new pod evicted again
# → infinite cycle, DESIRED always 3

# This matches what happened in testing:
# AGE=49s after waiting 120s = original evicted, new one already running
```

**When tolerationSeconds IS useful (no DaemonSet recreation problem):**

The built-in node condition taints have a different dynamic — when a node
goes `not-ready`, Kubernetes applies the taint. The kubelet on that node
cannot create new pods (it's not-ready). So `tolerationSeconds` works as
intended: pod stays for N seconds giving the node time to recover, then is
evicted to another node. No recreation loop because the node is unhealthy.

```yaml
# These work correctly with tolerationSeconds — no recreation loop:
- key: node.kubernetes.io/not-ready
  operator: Exists
  effect: NoExecute
  tolerationSeconds: 300    # Node has 5 mins to recover before pod moves

- key: node.kubernetes.io/unreachable
  operator: Exists
  effect: NoExecute
  tolerationSeconds: 300
```

```bash
# Cleanup
kubectl taint node 3node-m03 maintenance=true:NoExecute-  # if still present
kubectl uncordon 3node-m03                                  # if still cordoned
kubectl delete -f 06-noexecute-toleration-daemonset.yaml
```

---

## Part 5 — Combining Mechanisms

### nodeSelector AND Tolerations — Both Must Pass

When you combine `nodeSelector` and tolerations, **both conditions must
be satisfied**. A node that satisfies the `nodeSelector` but has an
untolerated taint still does not receive a pod:

```
Example combination:
  nodeSelector:  disktype=ssd
  tolerations:   dedicated=gpu:NoSchedule

Node evaluation:
  3node      no disktype label → nodeSelector fails → NO pod
  3node-m02  disktype=ssd ✅, no gpu taint → toleration not needed → POD
  3node-m03  disktype=ssd ✅, dedicated=gpu:NoSchedule taint ✅ tolerated → POD

DESIRED = 2 (m02 and m03 satisfy both conditions)
```

### nodeAffinity AND nodeSelector — Both Must Pass

```yaml
spec:
  nodeSelector:         # AND
    disktype: ssd
  affinity:
    nodeAffinity:       # AND (in addition to nodeSelector)
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: env
                operator: NotIn
                values: [dev]
```

Node must have `disktype=ssd` AND must not have `env=dev`. Both must pass.

### The Practical Multi-Layer Pattern

Production DaemonSets often combine all three mechanisms:

```yaml
spec:
  nodeSelector:
    kubernetes.io/os: linux          # Hardware constraint — Linux only

  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-pool
                operator: In
                values: [gpu-pool, compute-pool]   # Only specific node pools

  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule             # Allow control-plane nodes

    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule             # Allow GPU-tainted nodes

    - key: node.kubernetes.io/not-ready
      operator: Exists
      effect: NoExecute
      tolerationSeconds: 300         # Survive transient node failure
```

---

## Part 6 — nodeName Direct Binding (Know It, Don't Use It)

`spec.nodeName` binds a pod directly to a named node, bypassing the
selector and taint/toleration checks entirely. The DaemonSet controller
itself uses this mechanism — but you should not use it in DaemonSet pod
templates:

```yaml
# DO NOT USE in DaemonSet pod templates:
spec:
  nodeName: 3node-m02    # Hardcodes the node name
```

**Why it exists:** The DaemonSet controller sets this field programmatically
on each pod it creates — one pod per node, with the correct node name filled
in at creation time. You saw this in Lab 01 when you ran
`kubectl get pod <name> -o yaml | grep nodeName`.

**Why not to use it in templates:**
```
1. The template is shared — all pods would bind to the same single node
2. Node names are not portable — different clusters have different names
3. Bypasses taint/toleration checks — pod lands even on tainted nodes
4. Node removed → pod is stuck Pending forever (no other node to reschedule to)

Only valid production use of nodeName in a DaemonSet context:
  The DaemonSet controller sets it per-pod at creation time.
  You never put nodeName in spec.template.spec.
```

---

## Summary — Choosing the Right Mechanism

```
Scenario → Recommended approach

"Run on every node"
  → No nodeSelector, no affinity, add control-plane toleration

"Run on worker nodes only"
  → Omit control-plane toleration (Approach A — simplest)
  → OR: nodeAffinity DoesNotExist on control-plane label (Approach B — explicit)

"Run only on SSD nodes"
  → nodeSelector: disktype=ssd  (if simple equality is enough)
  → nodeAffinity In [ssd, nvme] (if multiple values or operators needed)

"Run on GPU nodes (which have a dedicated taint)"
  → nodeSelector: accelerator=gpu  (target labelled nodes)
  → tolerations: nvidia.com/gpu:NoSchedule  (tolerate the taint)

"Survive node failure / unreachable"
  → tolerations: node.kubernetes.io/not-ready:NoExecute (tolerationSeconds: 300)
               + node.kubernetes.io/unreachable:NoExecute (tolerationSeconds: 300)

"Run everywhere EXCEPT dev-labelled nodes"
  → nodeAffinity required: env NotIn [dev]

"Prefer SSD nodes but run anywhere"
  → nodeAffinity preferred: disktype In [ssd] weight: 80
```

---

## Common Questions

### Q: If I remove a label from a node, does the running DaemonSet pod get evicted?
**A:** It depends on the mechanism. With `nodeSelector` or required
`nodeAffinity` — the controller deletes the pod in the next reconcile cycle
(not an eviction, but a controller-driven deletion). With `NoExecute` taint
— the kubelet evicts the pod directly. The "IgnoredDuringExecution" in
affinity names means affinity rules do not evict running pods — but the
DaemonSet controller still reconciles and removes pods from nodes that
no longer match. In practice, removing a label does remove the pod.

### Q: What is the difference between `NoSchedule` and `NoExecute` for running pods?
**A:** `NoSchedule` does not affect existing running pods — they stay until
they die or are deleted normally. `NoExecute` evicts existing running pods
that do not have a matching toleration (immediately, or after
`tolerationSeconds`). When Kubernetes marks a node `not-ready`, it uses
`NoExecute` — because it needs to move pods off the unhealthy node.

### Q: Can I combine `nodeSelector` and `nodeAffinity` in the same DaemonSet?
**A:** Yes — both must be satisfied. The node must match the `nodeSelector`
AND the `nodeAffinity` rules. In practice, prefer `nodeAffinity` alone —
it is more expressive and covers everything `nodeSelector` can do. The
Kubernetes documentation recommends migrating from `nodeSelector` to
`nodeAffinity` for new workloads.

### Q: What happens to DESIRED count during a taint/label change?
**A:** The DaemonSet controller reconciles continuously. When a node
becomes ineligible (label removed, taint added without matching toleration),
`DESIRED` decrements and the pod is deleted. When a node becomes eligible
(label added, taint removed or toleration added), `DESIRED` increments
and a new pod is created. You can watch this in real time with
`kubectl get ds -w`.

### Q: Do tolerations in the DaemonSet spec override node taints?
**A:** No — they declare compatibility. A toleration does not remove the
taint. It tells the DaemonSet controller and kubelet: "this pod is willing
to run despite this taint." The taint still affects all other pods that
do not tolerate it.

---

## What You Learned

In this lab, you:
- ✅ Used `nodeSelector` to restrict a DaemonSet to labelled nodes
- ✅ Watched `DESIRED` change live as nodes gained and lost labels
- ✅ Wrote required `nodeAffinity` with `In`, `NotIn`, and `DoesNotExist` operators
- ✅ Wrote preferred `nodeAffinity` with weighted rules
- ✅ Understood "IgnoredDuringExecution" — affinity rules don't evict running pods
- ✅ Excluded the control-plane using two different approaches
- ✅ Applied `NoSchedule` taints and matching tolerations — new pods blocked
- ✅ Applied `NoExecute` taints — running pods evicted without toleration
- ✅ Used `tolerationSeconds` for timed grace periods during maintenance
- ✅ Understood the built-in node condition taints (`not-ready`, `unreachable`)
- ✅ Combined `nodeSelector` + `nodeAffinity` + tolerations as AND conditions
- ✅ Understood why `nodeName` exists and why not to use it in templates

**Key Takeaway:** Targeting is a layered AND: `nodeSelector` narrows by label,
`nodeAffinity` narrows with expressions, taints/tolerations control node-level
opt-in. All three must pass for a pod to land. Design your targeting from
the outside in — start with which nodes should receive a pod, then work
backwards to which combination of mechanisms expresses that cleanly.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get nodes --show-labels` | See all node labels |
| `kubectl label node <n> key=value` | Add label to node |
| `kubectl label node <n> key-` | Remove label from node |
| `kubectl taint node <n> key=value:Effect` | Add taint to node |
| `kubectl taint node <n> key=value:Effect-` | Remove taint from node |
| `kubectl describe node <n> \| grep -A3 Taints` | View node taints |
| `kubectl describe node <n> \| grep -A10 Labels` | View node labels |
| `kubectl get ds <n> -w` | Watch DESIRED change live |
| `kubectl get pods -o wide` | Show pod-to-node placement |
| `kubectl describe ds <n> \| grep Misscheduled` | Check for misscheduled pods |

---

## Troubleshooting

**DESIRED is lower than expected?**
```bash
kubectl describe ds <name>
# Look for: "Number of Nodes Misscheduled"
# Check each node:
kubectl describe node <node-name> | grep -E "Taints|Labels"
# Does node label match nodeSelector?
# Does node have untolerated taints?
```

**Pod on wrong node / unexpected node?**
```bash
kubectl get pods -l app=<name> -o wide
kubectl get pod <name> -o jsonpath='{.spec.nodeName}'
# Verify nodeSelector and tolerations match what you expect
kubectl describe node <node-name> | grep -A5 "Taints:"
```

**Pod not evicted after NoExecute taint?**
```bash
kubectl describe pod <name> | grep -A10 "Tolerations:"
# Pod may have a toleration for that taint — check tolerationSeconds
# If tolerationSeconds is set, pod stays for that duration first
```

**Label removed but pod still running?**
```bash
# This is expected for nodeAffinity "IgnoredDuringExecution"
# The DaemonSet controller WILL delete the pod in the next reconcile
# Check how long ago the label was removed:
kubectl describe ds <name> | grep -A5 "Events:"
# Reconcile typically completes within a few seconds
```

---

## CKA Certification Tips

✅ **nodeSelector syntax — simplest, exam-friendly:**
```yaml
spec:
  nodeSelector:
    disktype: ssd
```

✅ **Required nodeAffinity — know the full path:**
```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: disktype
              operator: In
              values: [ssd]
```

✅ **Taint a node imperatively (exam speed):**
```bash
kubectl taint node <n> key=value:NoSchedule
kubectl taint node <n> key=value:NoSchedule-   # remove
```

✅ **Toleration for control-plane — memorise this:**
```yaml
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
```

✅ **Workers only — just omit the toleration above**

✅ **NoExecute vs NoSchedule — the exam distinction:**
- `NoSchedule` → blocks new pods, existing pods stay
- `NoExecute` → blocks new pods AND evicts existing pods (without toleration)

✅ **`kubectl taint` remove syntax — trailing dash:**
```bash
kubectl taint node <n> key=value:Effect-   # the - at the end removes the taint
```