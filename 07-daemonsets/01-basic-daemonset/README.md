# Basic DaemonSet — Mechanics, Manifest, and Update Strategies

## Lab Overview

This lab is a deep dive into the DaemonSet workload type — its controller
behaviour, every field in the manifest, and both update strategies in practice.
No application complexity here: the workload is a plain nginx container so all
attention stays on the DaemonSet object itself.

A DaemonSet guarantees exactly one pod on every matching node in your cluster.
Unlike a Deployment — which places a fixed replica count wherever the scheduler
decides — a DaemonSet is topology-driven: its pod count is determined by your
cluster's node count, not by a number you choose. Every node that joins gets a
pod; every node that leaves has its pod cleaned up automatically.

**What you'll do:**
- Understand the DaemonSet controller and how it differs from a Deployment controller
- Walk through every field in the DaemonSet manifest with full explanation
- Deploy a DaemonSet and read every column of its status output
- Prove the one-pod-per-node guarantee using `kubectl get pods -o wide`
- Inspect `spec.nodeName` to see the scheduler bypass in action
- Observe cordon, drain, and delete behaviour on DaemonSet pods
- Perform a full `RollingUpdate` — watch node-by-node replacement with annotated output
- Understand `OnDelete` — when and why to choose manual update control
- Manage rollout history and perform a rollback
- Clean up all resources correctly

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control-plane + 2 worker nodes
- kubectl installed and configured
- Text editor

**Verify your cluster before starting:**
```bash
kubectl get nodes
```

**Expected output:**
```
NAME        STATUS   ROLES           AGE   VERSION
3node       Ready    control-plane   1h    v1.32.0
3node-m02   Ready    <none>          1h    v1.32.0
3node-m03   Ready    <none>          1h    v1.32.0
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

**Knowledge Requirements:**
- **REQUIRED:** Completion of `02-deployments/01-basic-deployment`
- Understanding of pod labels and selectors
- Familiarity with `kubectl describe`, `kubectl get -o wide`, `kubectl get -o yaml`

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain how the DaemonSet controller differs from the Deployment controller
2. ✅ Explain every field in a DaemonSet manifest and its valid values
3. ✅ Read and interpret all six columns of `kubectl get ds` output
4. ✅ Verify the one-pod-per-node guarantee with `kubectl get pods -o wide`
5. ✅ Prove that the DaemonSet controller sets `spec.nodeName` directly
6. ✅ Explain what happens to DaemonSet pods during cordon, drain, and node delete
7. ✅ Perform a `RollingUpdate` and trace it node-by-node with annotated watch output
8. ✅ Explain `OnDelete` strategy — how it works and when to use it
9. ✅ Manage rollout history, annotate revisions, and perform a rollback
10. ✅ Clean up DaemonSet resources and verify complete removal

## Directory Structure

```
01-basic-daemonset/
└── src/
    ├── nginx-daemonset.yaml      # DaemonSet — nginx:1.27, all nodes
    └── nginx-daemonset-v2.yaml   # Same spec — nginx:1.28, triggers RollingUpdate
```

---

## Understanding DaemonSets

### The DaemonSet Controller vs the Deployment Controller

Both controllers run inside `kube-controller-manager`. They use the same
watch-reconcile pattern but make fundamentally different decisions:

```
Deployment Controller
─────────────────────
Input:  desired replica count (e.g. replicas: 3)
Logic:  count existing pods → create or delete until count matches
Result: N pods, placed anywhere the scheduler chooses

                replicas: 3
                     │
                     ▼
              ┌─────────────┐
              │  ReplicaSet │  ← Deployment creates and manages this
              └──────┬──────┘
         ┌───────────┼───────────┐
         ▼           ▼           ▼
       Pod-1       Pod-2       Pod-3
    (any node)  (any node)  (any node)   ← scheduler decides placement


DaemonSet Controller
─────────────────────
Input:  the cluster's node list (filtered by nodeSelector, nodeAffinity, and tolerations)
Logic:  for each matching node → ensure exactly one pod exists there
Result: one pod per matching node — no ReplicaSet, no replica count

        node list: [3node, 3node-m02, 3node-m03]
             │
             ▼
    ┌──────────────────┐
    │ DaemonSet Controller │  ← no ReplicaSet created
    └──────────────────┘
         │           │           │
         ▼           ▼           ▼
       Pod-1       Pod-2       Pod-3
    (3node)    (3node-m02)  (3node-m03)  ← controller sets nodeName directly
```

**Key consequences of this difference:**

| Behaviour | Deployment | DaemonSet |
|-----------|-----------|-----------|
| Pod count source | `spec.replicas` field | Number of matching nodes |
| Pod placement | Scheduler (best-fit) | Controller (sets `nodeName` directly) |
| New node joins cluster | No new pods | Pod created automatically |
| Node removed from cluster | Pod rescheduled elsewhere | Pod garbage-collected |
| `kubectl scale` works | Yes | No — rejected by API server |
| ReplicaSet created | Yes | No |
| Rollout history stored | In ReplicaSet | In ControllerRevision objects |

### The Reconcile Loop — Step by Step

The DaemonSet controller runs a continuous reconcile loop:

```
Every reconcile cycle:

Step 1 — Build the desired set
    List all nodes in the cluster
    Filter: keep only nodes matching spec.nodeSelector (if set)
    Filter: keep only nodes satisfying spec.affinity.nodeAffinity (if set)
    Filter: keep only nodes whose taints are all tolerated by the pod spec
    → Result: desired_nodes = [3node, 3node-m02, 3node-m03]

  Step 2 — Build the actual set
    List all pods owned by this DaemonSet
    Group by the node each pod is scheduled on
    → Result: actual_pods = {3node: pod-a, 3node-m02: pod-b}
              (3node-m03 is missing a pod)

  Step 3 — Reconcile
    For each node in desired_nodes:
      Pod exists and is healthy? → do nothing
      Pod missing?               → CREATE pod, set spec.nodeName = node

    For each pod in actual_pods:
      Node still in desired_nodes? → do nothing
      Node removed or unmatched?   → DELETE pod

  Step 4 — Repeat
    Triggered by: node add/remove, pod add/remove, spec change
```

**Why set `spec.nodeName` directly instead of letting the scheduler decide?**

The scheduler places pods based on resource availability and affinity rules.
A node under resource pressure might be skipped. A DaemonSet cannot accept
"might" — it must guarantee placement. By setting `spec.nodeName`, the
controller binds the pod directly to its target node. The kubelet on that
node sees the pod in its watch and starts it, regardless of what the
scheduler would have decided.

The DaemonSet controller still respects taints and tolerations — it checks
these itself before creating a pod, emulating what the scheduler would check.

### What Happens in kube-system Right Now

The pattern you are about to build already exists in your cluster:

```bash
kubectl get daemonsets -n kube-system
```

**Expected output:**
```
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR
kube-proxy   3         3         3       3            3           kubernetes.io/os=linux
```

```bash
kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide
```

**Expected output:**
```
NAME               READY   STATUS    NODE
kube-proxy-r4x2p   1/1     Running   3node        ← control-plane
kube-proxy-m7nbq   1/1     Running   3node-m02    ← worker 1
kube-proxy-s9tz3   1/1     Running   3node-m03    ← worker 2
```

`kube-proxy` is a DaemonSet that manages iptables/ipvs rules for Service
routing. It must run on every node — without it, Services do not work on
that node. This is the canonical DaemonSet use case: node-local infrastructure
that cannot be optional on any node.

---

## DaemonSet Manifest — Every Field Explained

### The Complete Manifest

**nginx-daemonset.yaml:**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nginx-ds
  namespace: default
  labels:
    app: nginx-ds
spec:

  # ── Selector ────────────────────────────────────────────────────────
  selector:
    matchLabels:
      app: nginx-ds

  # ── Update Strategy ─────────────────────────────────────────────────
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1

  # ── Pod Template ────────────────────────────────────────────────────
  template:
    metadata:
      labels:
        app: nginx-ds        # MUST match spec.selector.matchLabels
    spec:

      # ── Tolerations ───────────────────────────────────────────────
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule

      # ── Containers ────────────────────────────────────────────────
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
              protocol: TCP
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"

  # ── Optional: Pod Lifecycle ─────────────────────────────────────────
  # minReadySeconds: 0       # Seconds a pod must be ready before counted AVAILABLE
                           # Applicable to: Deployment, StatefulSet, DaemonSet
                           # NOT applicable to: Job, CronJob (completion-based, not readiness-based)

  # revisionHistoryLimit: 10 # How many ControllerRevisions to keep (default: 10)
```

### Field-by-Field Reference

**`apiVersion: apps/v1`**
DaemonSets live in the `apps` API group, same as Deployments and StatefulSets.
`v1` is the stable version — always use this, not the older `extensions/v1beta1`.

**`kind: DaemonSet`**
Tells the API server which controller to hand this object to.
Do not add `spec.replicas` — the API server will reject the object with
a validation error: *"replicas: Invalid value: 3: may not be specified"*.

**`metadata.name`**
The DaemonSet name. Pod names are derived from this: `nginx-ds-<random-suffix>`.
Unlike StatefulSet pods (`web-0`, `web-1`), DaemonSet pods get random suffixes —
they have no ordinal identity.

**`metadata.labels`**
Labels on the DaemonSet object itself — used by `kubectl get ds -l app=nginx-ds`
to filter DaemonSets. These are **not** the pod labels. Keep them consistent
with pod labels by convention, but they serve a different purpose.

---

**`spec.selector`**

```yaml
selector:
  matchLabels:
    app: nginx-ds
```

The selector defines how the DaemonSet controller identifies which pods it
owns. The controller will only manage pods whose labels match this selector.

**Rules — identical to Deployments:**
- Must match `spec.template.metadata.labels` exactly
- Immutable after creation — you cannot change the selector without deleting the DaemonSet
- Mismatch between selector and template labels → API server validation error at creation time

**`matchLabels` vs `matchExpressions`:**
```yaml
# Simple equality (most common):
selector:
  matchLabels:
    app: nginx-ds

```yaml
# Expression-based (advanced):
selector:
  matchExpressions:
    - key: app
      operator: In
      values: [nginx-ds, nginx-agent]  # OR
    - key: environment
      operator: Exists                 # Both expressions must match — AND, not OR
```

**AND vs OR in selectors:**
So `[nginx-ds, nginx-agent]` means `app=nginx-ds OR app=nginx-agent`, but ALSO `environment` must exist (AND). Both expressions together = AND.
```

---

**`spec.updateStrategy`**

```yaml
updateStrategy:
  type: RollingUpdate        # or: OnDelete
  rollingUpdate:
    maxUnavailable: 1        # only used when type: RollingUpdate
```

Controls how pods are replaced when the pod template changes.

`type: RollingUpdate` — default. When the template changes (e.g. image version),
pods are replaced node by node. At most `maxUnavailable` nodes will be without
a running pod at any point during the update.

`type: OnDelete` — no automatic replacement. A pod is only replaced with
the new template when you manually delete it. Used for security-sensitive
DaemonSets where each node must be validated individually before proceeding.

**`maxUnavailable`** — accepts an integer (number of nodes) or a percentage:
```yaml
maxUnavailable: 1      # at most 1 node without a pod during update
maxUnavailable: 33%    # at most 33% of nodes without a pod
maxUnavailable: 0      # not valid for DaemonSet — at least 1 must be unavailable
                       # (there is no maxSurge for DaemonSet unlike Deployment)
```

> **Why no `maxSurge` for DaemonSet?**
> A Deployment can temporarily run more pods than desired during a rolling
> update (that is what `maxSurge` controls). A DaemonSet cannot — there
> is exactly one pod slot per node. You cannot run two pods on the same
> node for the same DaemonSet. Therefore, an update always requires
> terminating the old pod before starting the new one on each node.

---

**DaemonSet `updateStrategy` vs Deployment `strategy` — key differences:**

| Aspect | Deployment `strategy` | DaemonSet `updateStrategy` |
|--------|----------------------|---------------------------|
| Field name | `spec.strategy` | `spec.updateStrategy` |
| `maxSurge` | ✅ Supported — can temporarily run extra pods | ❌ Not supported — one pod slot per node |
| `maxUnavailable` | Accepts integer or % | Accepts integer or % |
| Default | `RollingUpdate, maxSurge:25%, maxUnavailable:25%` | `RollingUpdate, maxUnavailable:1` |
| `Recreate` | ✅ Supported | ❌ Not supported |
| `OnDelete` | ❌ Not supported | ✅ Supported |

`maxSurge` does not apply to DaemonSets because there is exactly one pod
slot per node — you cannot temporarily run two DaemonSet pods on the same node.
An update always terminates the old pod before starting the new one on each node.

---

**`spec.template`**

The pod template — identical structure to a Deployment's pod template.
This is what the DaemonSet controller uses to create each pod.

```yaml
template:
  metadata:
    labels:
      app: nginx-ds    # MUST match spec.selector.matchLabels
  spec:
    ...
```

The `template.metadata.labels` must satisfy the `spec.selector`. Any pod
the controller creates using this template will automatically match the
selector — this is how the controller recognises its own pods.

**Fields NOT valid in DaemonSet pod template:**
- `spec.template.spec.restartPolicy` — DaemonSet always uses `Always`
  (it must keep the pod running). Setting any other value is rejected.

---

**`spec.template.spec.tolerations`**

```yaml
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
```

The control-plane node in a kubeadm/minikube cluster has a taint:
`node-role.kubernetes.io/control-plane:NoSchedule`. Without a matching
toleration, the DaemonSet controller will not create a pod there.

**Effect:**
```
Without toleration:  DESIRED = 2  (workers only)
With toleration:     DESIRED = 3  (control-plane + workers)
```

Toleration fields:
- `key` — the taint key to match. Omit for a catch-all toleration.
- `operator` — `Exists` (key present, any value) or `Equal` (key + value match)
- `effect` — `NoSchedule`, `PreferNoSchedule`, or `NoExecute`. Omit to tolerate all effects.
- `value` — required when `operator: Equal`
- `tolerationSeconds` — only for `NoExecute`; how long the pod can stay after the taint is applied

Node targeting via tolerations and `nodeSelector` / `nodeAffinity` is covered
in full in **`02-daemonset-node-targeting`**.

---

**`spec.template.spec.containers[].resources`**

```yaml
resources:
  requests:
    cpu: "50m"
    memory: "64Mi"
  limits:
    cpu: "100m"
    memory: "128Mi"
```

DaemonSet pods run on **every** matching node — they consume resources on
every node simultaneously. Without `resources.requests`, the DaemonSet
will crowd out application pods on nodes that are already under pressure.
Without `resources.limits`, a bug in the DaemonSet pod (e.g. a memory leak
in a log collector) can starve all other pods on that node.

**Always set both `requests` and `limits` on DaemonSet containers.**
This is not optional advice — it is a production requirement. DaemonSets
have a cluster-wide blast radius that Deployments do not.

---

**What happens when a node lacks resources for the DaemonSet pod:**

Scenario: Node has 100m CPU allocatable, DaemonSet requests 50m,
but application pods have consumed 80m.

`Result 1 — DaemonSet pod stays Pending:`
The pod is created (spec.nodeName is set directly) but kubelet cannot
admit it — insufficient resources. Pod stays Pending indefinitely.
DESIRED=3, CURRENT=3, READY=2 — the Pending pod counts in CURRENT.

`Result 2 — Priority and Preemption:`
If the DaemonSet pod has a higher PriorityClass than running pods,
the kubelet can evict lower-priority pods to make room.
DaemonSet system pods (kube-proxy, CNI) use high-priority PriorityClasses.
Your custom DaemonSets use the default PriorityClass (priority 0) unless
you explicitly assign one.Assign a priority class to a DaemonSet pod:
```
spec:
  priorityClassName: system-node-critical  

# system-node-critical              -> highest — for critical infrastructure
# system-cluster-critical           ->  second highest
# a custom PriorityClass you create
```

`Result 3 — Eviction under memory pressure:`
If memory runs low, kubelet evicts pods in QoS order:
BestEffort (no requests/limits) → evicted first
Burstable   (requests < limits)  → evicted second
Guaranteed  (requests == limits) → evicted last
DaemonSet pods with limits == requests are Guaranteed QoS — evicted last.
Another reason to always set both requests and limits on DaemonSet containers.

**Production guidance:**
- Assign `system-node-critical` PriorityClass to DaemonSets that are essential for node operation (CNI, kube-proxy, log collectors)
- Set `requests == limits` for Guaranteed QoS — protects DaemonSet pods from eviction
- Size requests conservatively — DaemonSet overhead multiplies by node count

---

**`spec.minReadySeconds`** (optional, default: 0)

```yaml
minReadySeconds: 10
```

A pod is counted as `AVAILABLE` only after it has been `Ready` for at least
this many seconds without any containers restarting. Setting this to a
non-zero value during rolling updates means the controller waits for the
pod to prove stability before moving to the next node.

---

**`spec.revisionHistoryLimit`** (optional, default: 10)

```yaml
revisionHistoryLimit: 5
```

How many `ControllerRevision` objects to retain. Each revision stores a
snapshot of the pod template — used for `kubectl rollout undo`. Unlike
Deployments (which store history in ReplicaSets), DaemonSets store history
in `ControllerRevision` objects. Reducing this saves etcd space on large
clusters.

```bash
# See the ControllerRevision objects directly
kubectl get controllerrevisions -l app=nginx-ds
```

---

## Lab Step-by-Step Guide

### Step 1: Look at kube-proxy First

```bash
kubectl get ds -n kube-system
kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide
```

Note the one-pod-per-node pattern. You will reproduce this in the next step.

---

### Step 2: Apply the DaemonSet

```bash
cd 01-basic-daemonset/src
kubectl apply -f nginx-daemonset.yaml
```

**Expected output:**
```
daemonset.apps/nginx-ds created
```

---

### Step 3: Read the Status Output — Every Column

```bash
kubectl get ds nginx-ds
```

**Expected output:**
```
NAME       DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
nginx-ds   3         3         3       3            3           <none>          15s
```

**Column definitions:**

| Column | What it counts | When it can be less than DESIRED |
|--------|---------------|----------------------------------|
| `DESIRED` | Nodes matching `nodeSelector` + tolerations | Always the reference count |
| `CURRENT` | Pods that exist (any phase) | Pod creation is pending (rare) |
| `READY` | Pods that passed their readiness probe | Pod is starting, crashing, or probe failing |
| `UP-TO-DATE` | Pods running the current pod template version | During a rolling update — old pods not yet replaced |
| `AVAILABLE` | Ready pods that have been ready for `minReadySeconds` | During update if `minReadySeconds > 0` |
| `NODE SELECTOR` | The value of `spec.template.spec.nodeSelector` | — |

**Reading a mid-update status:**
```
NAME       DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
nginx-ds   3         3         2       2            2

Reading:  3 nodes should have a pod
          3 pods exist (old + new)
          2 pods are ready (new pods ready, old pod terminating)
          2 pods are on the new template (UP-TO-DATE)
          2 pods are available
          → 1 node is mid-update: old pod terminated, new pod starting
```

---

### Step 4: Verify One Pod Per Node

```bash
kubectl get pods -l app=nginx-ds -o wide
```

**Expected output:**
```
NAME             READY   STATUS    NODE        IP            NODE
nginx-ds-4xk2p   1/1     Running   3node       10.244.0.5    ← control-plane
nginx-ds-7mnbq   1/1     Running   3node-m02   10.244.1.8    ← worker 1
nginx-ds-p9sz3   1/1     Running   3node-m03   10.244.2.3    ← worker 2
```

**What to verify:**
- Exactly **one row per node** in the `NODE` column
- All pods in `Running` status
- Each pod has a **different IP** — they are on different node subnets
- Pod names have **random suffixes** (no ordinals like `web-0`, `web-1`)

Compare to a Deployment with `replicas: 3` — that could show 3 pods all
on `3node-m02` if the scheduler decided so. A DaemonSet cannot do that.

---

### Step 5: Verify No ReplicaSet Exists

A Deployment creates a ReplicaSet to manage its pods. A DaemonSet manages
pods directly — no intermediate object:

```bash
kubectl get all -l app=nginx-ds
```

**Expected output:**
```
NAME                 READY   STATUS    RESTARTS   AGE
pod/nginx-ds-4xk2p   1/1     Running   0          2m
pod/nginx-ds-7mnbq   1/1     Running   0          2m
pod/nginx-ds-p9sz3   1/1     Running   0          2m

NAME                      DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
daemonset.apps/nginx-ds   3         3         3       3            3
```

No `replicaset.apps/...` row. The DaemonSet → Pods hierarchy is flat.

```bash
# Confirm directly
kubectl get replicasets -l app=nginx-ds
# Returns: No resources found in default namespace.
```

---

### Step 6: Prove the Scheduler Bypass — Inspect nodeName

```bash
# Pick any pod name from Step 4
kubectl get pod nginx-ds-4xk2p -o yaml | grep "nodeName:"
```

**Expected output:**
```yaml
  nodeName: 3node
```

```bash
# Compare to a Deployment pod — nodeName is also set, but by the scheduler
# The DaemonSet controller sets it directly without going through scheduling
kubectl get pod nginx-ds-4xk2p \
  -o jsonpath='{.spec.nodeName}{"\n"}'
```

Now verify the controller set it — look at the pod's `schedulerName`:

```bash
kubectl get pod nginx-ds-4xk2p \
  -o jsonpath='{.spec.schedulerName}{"\n"}'
```

**Expected output:**
```
default-scheduler
```

The `schedulerName` field is populated, but the scheduler was bypassed.
The DaemonSet controller pre-set `nodeName` before the scheduler had a
chance to act. When `nodeName` is already set, the scheduler skips the
pod entirely — it treats it as already scheduled.

---

### Step 7: Examine the ControllerRevision

DaemonSet rollout history is stored in `ControllerRevision` objects —
not in ReplicaSets as Deployments use:

**What is a ControllerRevision?**

A `ControllerRevision` is an immutable snapshot of a controller's pod template
at a specific point in time. DaemonSets (and StatefulSets) use ControllerRevisions
to store rollout history — Deployments use ReplicaSets for the same purpose.
```
ControllerRevision stores:
  → Complete pod template spec (image, env, volumes, resources, etc.)
  → The revision number
  → The CHANGE-CAUSE annotation value (if set at creation time)
  → A hash of the pod template (used as part of the object name)

kubectl rollout history  → reads from ControllerRevision objects
kubectl rollout undo     → restores a previous pod template from a ControllerRevision

ControllerRevisions are owned by their DaemonSet — deleted automatically
when the DaemonSet is deleted or when revisionHistoryLimit is exceeded.
```

```bash
kubectl get controllerrevisions -l app=nginx-ds
```

**Expected output:**
```
NAME              CONTROLLER                REVISION   AGE
nginx-ds-5d9f8c   daemonset.apps/nginx-ds   1          5m
```

Each `ControllerRevision` stores a complete snapshot of the pod template
for that revision. `kubectl rollout undo` uses these to restore a previous
pod template.

```bash
kubectl describe controllerrevision nginx-ds-5d9f8c
```

You will see the full pod template stored inside the revision — including
the image version, resource requests, tolerations, and all other spec fields.

---

### Step 8: Describe the DaemonSet — Full Status

```bash
kubectl describe daemonset nginx-ds
```

**Key sections and what to read:**

```
Name:           nginx-ds
Selector:       app=nginx-ds
Node-Selector:  <none>               ← no nodeSelector = all nodes
Tolerations:    node-role.kubernetes.io/control-plane:NoSchedule op=Exists

Desired Number of Nodes Scheduled:              3
Current Number of Nodes Scheduled:              3
Number of Nodes Scheduled with Up-to-date Pods: 3
Number of Nodes Scheduled with Available Pods:  3
Number of Nodes Misscheduled:                   0
Pods Status:    3 Running / 0 Waiting / 0 Succeeded / 0 Failed

Update Strategy:
  Type: RollingUpdate
  Rolling Update:
    Max Unavailable: 1

Events:
  Type    Reason            Message
  ----    ------            -------
  Normal  SuccessfulCreate  Created pod: nginx-ds-4xk2p
  Normal  SuccessfulCreate  Created pod: nginx-ds-7mnbq
  Normal  SuccessfulCreate  Created pod: nginx-ds-p9sz3
```

**`Number of Nodes Misscheduled: 0`** — if this is non-zero, a DaemonSet
pod exists on a node that no longer matches the selector or tolerations.
This is the "orphaned pod" state — the controller will clean it up shortly.

---

### Step 9: Cordon a Node — Existing Pod Is Unaffected

`kubectl cordon` marks a node `SchedulingDisabled` — the scheduler will
not place new pods there. Existing pods continue running.

```bash
# Terminal 1 — watch pods continuously
kubectl get pods -l app=nginx-ds -o wide -w

# Terminal 2 — cordon worker node
kubectl cordon 3node-m03
```

**Terminal 1 — expected: nothing changes**
```
NAME             READY   STATUS    NODE
nginx-ds-4xk2p   1/1     Running   3node
nginx-ds-7mnbq   1/1     Running   3node-m02
nginx-ds-p9sz3   1/1     Running   3node-m03   ← still running on cordoned node
```

**Check the DaemonSet status:**
```bash
kubectl get ds nginx-ds
```

```
DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
3         3         3       3            3
```

`DESIRED` is still `3` — the DaemonSet controller counts the cordoned node
in DESIRED because the pod already exists there and is healthy. Cordoning
only blocks **new** pod scheduling. The controller does not evict existing pods.

**Uncordon before continuing:**
```bash
kubectl uncordon 3node-m03
```

---

### Step 10: Delete a DaemonSet Pod — It Is Recreated Immediately

```bash
# Terminal 1 — watch
kubectl get pods -l app=nginx-ds -o wide -w

# Terminal 2 — delete a pod
kubectl delete pod nginx-ds-p9sz3
```

**Terminal 1 — expected sequence:**
```
NAME             READY   STATUS        NODE
nginx-ds-p9sz3   1/1     Running       3node-m03
nginx-ds-p9sz3   1/1     Terminating   3node-m03    ← deleted
nginx-ds-abc12   0/1     Pending       3node-m03    ← controller creates replacement
nginx-ds-abc12   0/1     ContainerCreating  3node-m03
nginx-ds-abc12   1/1     Running       3node-m03    ← new pod running
```

**Critical observation:** the new pod is created on the **same node** —
`3node-m03`. The DaemonSet controller detected a missing pod on that node
and created a replacement bound to the same node. You cannot reduce
DaemonSet pod count by deleting pods — the controller always reconciles
back to one pod per node.

```bash
kubectl get ds nginx-ds
# DESIRED 3, CURRENT 3, READY 3 — no change in desired count
```

---

### Step 11: Drain a Node — DaemonSet Pods Are Skipped

`kubectl drain` evicts application pods from a node for maintenance.
DaemonSet pods are intentionally not evicted — they are node infrastructure.

```bash
# This will FAIL if DaemonSet pods exist on the node:
kubectl drain 3node-m03
# Error: cannot delete DaemonSet-managed Pods (use --ignore-daemonsets)

# Correct usage:
kubectl drain 3node-m03 --ignore-daemonsets
```

**Expected output:**
```
node/3node-m03 cordoned
evicting pod nginx-ds-abc12   ← Wait — DaemonSet pods should be ignored
```

> **Note:** With only DaemonSet pods on the node, the drain completes
> immediately because there is nothing to evict. In a real cluster,
> application Deployment pods would be evicted; DaemonSet pods stay.

Check the DaemonSet pod:
```bash
kubectl get pods -l app=nginx-ds -o wide
# nginx-ds pod on 3node-m03 still shows Running
# Node is cordoned (SchedulingDisabled) but pod is untouched
```

**Uncordon after drain:**
```bash
kubectl uncordon 3node-m03
```

---

### Step 12: Annotate Revisions — Add Change-Cause

Before performing create or  update, annotate the current revision with a
`change-cause` so rollout history is readable.

The `kubernetes.io/change-cause` annotation is captured by the controller
when a **new ControllerRevision is created** — i.e., at the moment you run
`kubectl apply`. Annotating the DaemonSet object after a revision has already
been created does NOT retroactively update that revision's CHANGE-CAUSE.


**The correct workflow — annotate BEFORE or at the same time as apply:**
```bash
# Method 1: set the annotation in the YAML metadata before applying
metadata:
  annotations:
    kubernetes.io/change-cause: "Update nginx:1.27 → nginx:1.28" --overwrite"

# Method 2: annotate then apply (both commands in sequence)
kubectl annotate daemonset nginx-ds \
  kubernetes.io/change-cause="Update nginx:1.27 → nginx:1.28" --overwrite"
kubectl apply -f nginx-daemonset-v2.yaml
```

## Change Cause Annotation Strategies

| Scenario | Recommended Approach | Reason |
| :--- | :--- | :--- |
| **First Revision (Creation)** | **Method 1 (In-YAML)** | Since the object does not yet exist in the cluster, the annotation must be defined directly in the YAML metadata. This ensures the `change-cause` is captured the moment the resource is created. |
| **Second Revision & Beyond** | **Both Methods** | Both approaches are technically functional, but **Method 1** is the preferred "GitOps" standard for tracking history in version control, whereas **Method 2** is an imperative shortcut for manual testing. |



**Why revision 1 always shows `<none>` by deafult:**


Check history:
```bash
kubectl rollout history daemonset/nginx-ds
```

**Expected output:**
```
**Expected output:**
REVISION  CHANGE-CAUSE
1         <none>          ← revision 1: no annotation was set at creation time
```

> **Revision 1 will always show `<none>`** unless you set the annotation in
> the YAML metadata before the very first `kubectl apply`.

---

### Step 13: Perform a RollingUpdate — Full Annotated Walk-Through

The update YAML (`nginx-daemonset-v2.yaml`) changes only the image:
`nginx:1.27` → `nginx:1.28`. All other fields are identical.

**nginx-daemonset-v2.yaml:**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nginx-ds
  namespace: default
  labels:
    app: nginx-ds
spec:
  selector:
    matchLabels:
      app: nginx-ds
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: nginx-ds
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: nginx
          image: nginx:1.28       # ← Only change from nginx-daemonset.yaml
          ports:
            - containerPort: 80
              protocol: TCP
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
```

**Open Terminal 1 — watch the rollout:**
```bash
kubectl get pods -l app=nginx-ds -o wide -w
```

**Open Terminal 2 — watch DaemonSet status:**
```bash
watch kubectl get ds nginx-ds
```

**Terminal 3 — apply the update:**
```bash
kubectl annotate daemonset nginx-ds \
  kubernetes.io/change-cause="Update nginx:1.27 → nginx:1.28" --overwrite

kubectl apply -f nginx-daemonset-v2.yaml
```

**Terminal 1 — expected pod-level sequence:**
```
NAME             READY   STATUS    IMAGE     NODE
nginx-ds-4xk2p   1/1     Running   1.27      3node        ← revision 1
nginx-ds-7mnbq   1/1     Running   1.27      3node-m02    ← revision 1
nginx-ds-abc12   1/1     Running   1.27      3node-m03    ← revision 1

─── Controller picks one node to update first (typically last in list) ───

nginx-ds-abc12   1/1     Terminating   1.27   3node-m03   ← old pod: terminated
                                                            maxUnavailable: 1 consumed
nginx-ds-def34   0/1     Pending       1.28   3node-m03   ← new pod: binding to node
nginx-ds-def34   0/1     ContainerCreating  1.28  3node-m03
nginx-ds-def34   1/1     Running       1.28   3node-m03   ✅ node 3 done
                                                            maxUnavailable: 1 released
                                                            → controller moves to next node

nginx-ds-7mnbq   1/1     Terminating   1.27   3node-m02   ← node 2: old pod terminated
nginx-ds-ghi56   0/1     ContainerCreating  1.28  3node-m02
nginx-ds-ghi56   1/1     Running       1.28   3node-m02   ✅ node 2 done

nginx-ds-4xk2p   1/1     Terminating   1.27   3node       ← node 1 (control-plane)
nginx-ds-jkl78   0/1     ContainerCreating  1.28  3node
nginx-ds-jkl78   1/1     Running       1.28   3node        ✅ node 1 done
```

**Terminal 2 — expected DaemonSet status sequence:**
```
── Before update ──
DESIRED  CURRENT  READY  UP-TO-DATE  AVAILABLE
3        3        3      3           3

── During update (1 node updating) ──
3        3        2      2           2
         ↑                ↑
    3 pods exist    2 pods are on new template
    (old terminating,   1 pod is still old (not yet updated)
     new starting)

── After node 3 done, node 2 starting ──
3        3        2      2           2   (briefly, while node 2 terminates)
3        3        3      3           3   (node 2 new pod ready)

── After all nodes done ──
3        3        3      3           3
                          ↑
                     all 3 pods now on new template
```

**maxUnavailable: 1 in action:**
At any point during the rollout, at most **1 node** is without a running
pod. The other 2 nodes keep running `nginx:1.27` until their turn comes.
This is the guarantee `maxUnavailable: 1` provides.

**Verify rollout completed:**
```bash
kubectl rollout status daemonset/nginx-ds
```

**Expected output:**
```
daemon set "nginx-ds" successfully rolled out
```

**Verify all pods are on the new image:**
```bash
kubectl get pods -l app=nginx-ds \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

**Expected output:**
```
nginx-ds-def34   nginx:1.28
nginx-ds-ghi56   nginx:1.28
nginx-ds-jkl78   nginx:1.28
```

**Check rollout history:**
```bash
kubectl rollout history daemonset/nginx-ds
```

**Expected output:**
```
REVISION   CHANGE-CAUSE
1          <none>
2          Update nginx:1.27 → nginx:1.28
```

---

### Step 14: Rollback with kubectl rollout undo

```bash
# Rollback to the previous revision (revision 1)
kubectl rollout undo daemonset/nginx-ds
```

**Expected output:**
```
daemonset.apps/nginx-ds rolled back
```

**Watch the rollback:**
```bash
kubectl get pods -l app=nginx-ds -o wide -w
```

The rollback uses the same `RollingUpdate` mechanism — pods are replaced
one node at a time, `maxUnavailable: 1`, until all pods run `nginx:1.27`
again.

```bash
kubectl rollout status daemonset/nginx-ds
# daemon set "nginx-ds" successfully rolled out

kubectl rollout history daemonset/nginx-ds
# REVISION 1 (now active again), REVISION 2, REVISION 3
# Note: rollback creates a NEW revision (3) — it does not delete revision 2
```

**Expected output:**
```
REVISION  CHANGE-CAUSE
2         Update nginx:1.27 → nginx:1.28
3         <none>
```

**Rollback to a specific revision:**
```bash
kubectl rollout undo daemonset/nginx-ds --to-revision=2
# Rolls forward to revision 2 (nginx:1.28)
kubectl rollout history daemonset/nginx-ds
```

**Expected output:**
```
REVISION  CHANGE-CAUSE
3         <none>
4         Update nginx:1.27 → nginx:1.28
```

---

### Step 15: OnDelete — Theory and Short Example

**How OnDelete works:**

With `type: OnDelete`, the controller does not replace pods when the
template changes. A pod is only replaced with the new template when you
manually delete it. This gives you node-by-node control: update one node,
validate it, then decide whether to proceed.

**When to use OnDelete:**

| Scenario | Why OnDelete? |
|----------|--------------|
| CNI plugin (Calico, Cilium) | A broken network plugin takes the node offline. Manual validation after each node is essential. |
| Security agent (Falco, etc.) | A bad security agent config could expose the node. Validate before rollout continues. |
| Low-level node daemon | Any daemon that can affect node stability — you want to observe each node before proceeding. |
| Compliance-gated rollouts | Policy requires human approval before each node is updated. |

**Short demo:**

```bash
# 1 — Switch the update strategy to OnDelete
kubectl patch daemonset nginx-ds \
  --type=merge \
  -p '{"spec":{"updateStrategy":{"type":"OnDelete"}}}'

# 2 — Apply a template change (nginx:1.29)
kubectl set image daemonset/nginx-ds nginx=nginx:1.29

# 3 — Observe: NO pods are replaced automatically
kubectl get pods -l app=nginx-ds \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# All pods still show nginx:1.28 — OnDelete does not trigger automatic replacement

kubectl get ds nginx-ds
# UP-TO-DATE shows 0 — no pods are on the new template yet

# 4 — Manually update one node by deleting its pod
kubectl delete pod nginx-ds-def34     # replace with actual pod on 3node-m03

# DaemonSet controller immediately creates a new pod on 3node-m03
# The new pod uses nginx:1.29

# 5 — Verify that pod, then decide to proceed
kubectl get pods -l app=nginx-ds \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# 3node-m03: nginx:1.29  (updated)
# 3node-m02: nginx:1.28  (still old — you control when this updates)
# 3node:     nginx:1.28  (still old)

# 6 — Proceed to next nodes when ready
kubectl delete pod nginx-ds-ghi56     # 3node-m02
kubectl delete pod nginx-ds-jkl78     # 3node (control-plane)
```

**Restore to RollingUpdate before cleanup:**
```bash
kubectl patch daemonset nginx-ds \
  --type=merge \
  -p '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"maxUnavailable":1}}}}'
```

---

### Step 16: Cleanup

```bash
kubectl delete -f nginx-daemonset.yaml
# or: kubectl delete daemonset nginx-ds
```

**Expected output:**
```
daemonset.apps "nginx-ds" deleted
```

**Verify complete removal:**
```bash
kubectl get ds
kubectl get pods -l app=nginx-ds
kubectl get controllerrevisions -l app=nginx-ds
```

All three commands should return empty. When a DaemonSet is deleted:
- ✅ The DaemonSet object is removed
- ✅ All managed pods are terminated on all nodes (no ReplicaSet to clean up)
- ✅ All ControllerRevision objects are garbage-collected

---

## Experiments to Try

1. **What happens when you try to scale a DaemonSet:**
   ```bash
   kubectl scale daemonset nginx-ds --replicas=5
   # Error from server (NotFound): the server could not find the requested resource
   # DaemonSets cannot be scaled — the count follows node count
   ```

2. **What happens when you try to add `replicas` to the spec:**
   ```bash
   kubectl patch daemonset nginx-ds \
     --type=merge \
     -p '{"spec":{"replicas":5}}'
   # The patch silently ignores unknown fields in a merge patch
   # But creating a DaemonSet with replicas in the YAML is rejected:
   # error: error validating "bad-ds.yaml": [spec.replicas: Invalid value]
   ```

3. **Watch DESIRED change when you label/unlabel a node:**
   ```bash
   # First: add a nodeSelector to the DaemonSet
   kubectl patch daemonset nginx-ds \
     --type=merge \
     -p '{"spec":{"template":{"spec":{"nodeSelector":{"disk":"ssd"}}}}}'
   # DESIRED drops to 0 — no nodes have disk=ssd label

   kubectl get ds nginx-ds
   # DESIRED 0, CURRENT 0 — no pods

   # Label one node
   kubectl label node 3node-m02 disk=ssd
   kubectl get ds nginx-ds
   # DESIRED 1, CURRENT 1 — pod created on 3node-m02 only

   # Add second node
   kubectl label node 3node-m03 disk=ssd
   kubectl get ds nginx-ds
   # DESIRED 2 — pod created on 3node-m03

   # Remove the nodeSelector patch to restore all-nodes behaviour
   kubectl patch daemonset nginx-ds \
     --type=merge \
     -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}'
   # DESIRED 3 — pods restored on all nodes
   # Don't forget to remove the labels:
   kubectl label node 3node-m02 disk-
   kubectl label node 3node-m03 disk-
   ```

4. **Inspect the ControllerRevision objects:**
   ```bash
   kubectl get controllerrevisions -l app=nginx-ds
   kubectl describe controllerrevision <name>
   # See the full pod template stored per revision
   ```

---

## Common Questions

### Q: Why can't I scale a DaemonSet with `kubectl scale`?
**A:** `kubectl scale` sets `spec.replicas`. DaemonSets do not have a
`spec.replicas` field — their pod count is derived from the node list.
The API server rejects the command because DaemonSet does not implement
the `scale` subresource. To reduce the "scale" of a DaemonSet, use a
`nodeSelector` to target fewer nodes.


### Q: What is the difference between `DESIRED` and `AVAILABLE`?
**A:** `DESIRED` counts nodes that should have a pod. `AVAILABLE` counts
pods that are both `Ready` and have been ready for `minReadySeconds`.
During a rolling update, `AVAILABLE` can be less than `DESIRED` because
the new pod on a node needs to pass its readiness probe (and stay ready
for `minReadySeconds` if configured) before it is counted as `AVAILABLE`.

### Q: Why does rollback create a new revision instead of going back to the old one?
**A:** Rolling back is just another template update — the DaemonSet's
template changes from v2 back to v1. Kubernetes records this as a new
revision (revision 3 with the v1 template). This ensures the audit trail
is complete: you can see that a rollback happened, when, and from what.
The old revision 1 still exists for further reference.

### Q: Can a DaemonSet pod run on a node that has `NoExecute` taint?
**A:** Only if the pod spec includes a toleration for `NoExecute`. Without
it, existing pods on a `NoExecute`-tainted node will be evicted (unlike
`NoSchedule` which only prevents new scheduling). DaemonSets for critical
infrastructure (kube-proxy, CNI) include `NoExecute` tolerations so their
pods are never evicted.

### Q: Where does DaemonSet rollout history live if there are no ReplicaSets?
**A:** In `ControllerRevision` objects. Each revision stores a serialised
snapshot of the pod template. `kubectl rollout history` reads these.
`kubectl rollout undo` restores a previous template from a ControllerRevision.
They are garbage-collected when the DaemonSet is deleted or when
`revisionHistoryLimit` is exceeded.

---

## What You Learned

In this lab, you:
- ✅ Explained the DaemonSet controller — topology-driven vs replica-driven
- ✅ Traced the reconcile loop: desired nodes → actual pods → create/delete
- ✅ Explained every field in the DaemonSet manifest with valid values
- ✅ Read and interpreted all six columns of `kubectl get ds`
- ✅ Verified one-pod-per-node with `kubectl get pods -o wide`
- ✅ Confirmed no ReplicaSet is created — `kubectl get all -l app=nginx-ds`
- ✅ Proved `spec.nodeName` is set directly by the controller
- ✅ Inspected ControllerRevision objects — the DaemonSet rollout history store
- ✅ Observed cordon — existing pod unaffected, new scheduling blocked
- ✅ Observed pod delete — controller immediately recreates on the same node
- ✅ Observed drain `--ignore-daemonsets` — DaemonSet pods are skipped
- ✅ Performed a full `RollingUpdate` with annotated node-by-node trace
- ✅ Read `UP-TO-DATE` and `AVAILABLE` columns during an active update
- ✅ Rolled back with `kubectl rollout undo` and understood revision numbering
- ✅ Understood `OnDelete` — manual node-by-node update with delete-to-trigger

**Key Takeaway:** A DaemonSet is not a Deployment with `replicas: <node-count>`.
It is a fundamentally different controller with different guarantees: topology-
driven placement, direct `nodeName` binding, ControllerRevision-based history,
and no `maxSurge`. The one-pod-per-node guarantee is enforced by the
reconcile loop, not by a number you choose. Every node that joins gets a pod;
every node that leaves loses its pod. The update strategies — `RollingUpdate`
for automation, `OnDelete` for manual control — give you the right tool for
each operational scenario.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get ds` | List DaemonSets in current namespace |
| `kubectl get ds -A` | List DaemonSets across all namespaces |
| `kubectl get pods -l app=nginx-ds -o wide` | Pods with node placement |
| `kubectl get all -l app=nginx-ds` | Confirm no ReplicaSet exists |
| `kubectl describe ds nginx-ds` | Full status incl. Misscheduled count |
| `kubectl get controllerrevisions -l app=nginx-ds` | Rollout history objects |
| `kubectl rollout status ds/nginx-ds` | Watch active rollout |
| `kubectl rollout history ds/nginx-ds` | List revisions with change-cause |
| `kubectl rollout undo ds/nginx-ds` | Rollback to previous revision |
| `kubectl rollout undo ds/nginx-ds --to-revision=1` | Rollback to specific revision |
| `kubectl cordon <node>` | Block new scheduling, existing pods stay |
| `kubectl uncordon <node>` | Re-enable scheduling |
| `kubectl drain <node> --ignore-daemonsets` | Evict non-DaemonSet pods |
| `kubectl delete ds nginx-ds` | Delete DaemonSet and all its pods |

---

## Troubleshooting

**`DESIRED` is less than total node count?**
```bash
kubectl describe ds nginx-ds
# Check: "Number of Nodes Misscheduled"
# Check: Tolerations — missing control-plane toleration?
# Check: nodeSelector — does it match all nodes?
kubectl get nodes --show-labels
```

**Pod stuck in `Pending` on a specific node?**
```bash
kubectl describe pod <pod-name>
# Events section — look for:
#   "didn't tolerate" → node has a taint your pod spec doesn't tolerate
#   "Insufficient cpu/memory" → node doesn't have enough resources
#   → Lower resource requests or add toleration
```

**`kubectl rollout undo` rolls back but UP-TO-DATE stays 0?**
```bash
kubectl get ds nginx-ds
# If updateStrategy is OnDelete, rollback does NOT auto-replace pods
# Check: kubectl get ds nginx-ds -o yaml | grep -A3 updateStrategy
# Fix: delete pods manually, or switch to RollingUpdate
```

**`kubectl scale daemonset nginx-ds --replicas=5` returns error?**
```
This is correct — DaemonSets cannot be scaled.
To target fewer nodes: add a nodeSelector.
To target more nodes: add/label nodes.
```

---

## CKA Certification Tips

✅ **Generate DaemonSet YAML from Deployment (no `kubectl create daemonset`):**
```bash
kubectl create deployment nginx-ds --image=nginx:1.27 \
  --dry-run=client -o yaml > ds.yaml
# Edit the file:
#   kind: Deployment  →  kind: DaemonSet
#   Remove: spec.replicas
#   Remove: spec.strategy
#   Add:    spec.updateStrategy: {type: RollingUpdate, rollingUpdate: {maxUnavailable: 1}}
```

✅ **Three fields that MUST NOT appear in a DaemonSet spec:**
```
spec.replicas          → validation error
spec.strategy          → that is Deployment syntax
spec.template.spec.restartPolicy: Never/OnFailure → only Always is valid
```

✅ **Read UP-TO-DATE during a rollout — it tells you progress:**
```
UP-TO-DATE = pods on new template
DESIRED - UP-TO-DATE = pods still on old template
```

✅ **Rollout commands are identical to Deployment:**
```bash
kubectl rollout status ds/<name>
kubectl rollout history ds/<name>
kubectl rollout undo ds/<name>
kubectl rollout undo ds/<name> --to-revision=<n>
```

✅ **Drain requires `--ignore-daemonsets` — exam will test this:**
```bash
kubectl drain <node> --ignore-daemonsets
# Without the flag: error if DaemonSet pods exist on the node
```

✅ **Short name:** `kubectl get ds` not `kubectl get daemonsets`