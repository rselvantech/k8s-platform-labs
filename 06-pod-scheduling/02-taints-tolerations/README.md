# Taints & Tolerations - Controlling Pod Scheduling in Kubernetes

## Lab Overview

This lab teaches you how to control **which pods run on which nodes** using Kubernetes Taints and Tolerations. This is one of the most powerful pod scheduling mechanisms in Kubernetes, used in production environments to dedicate nodes for specific workloads, isolate critical applications, and manage node maintenance.

Building on your understanding of basic pod scheduling, this lab introduces you to the full taint/toleration system. You'll start with simple single-taint scenarios, progress to multiple taints with AND logic.

**What you'll do:**
- Apply and remove taints on nodes with different effects
- Write pod and deployment manifests with tolerations
- Test all three taint effects: `NoSchedule`, `PreferNoSchedule`, `NoExecute`
- Use both `Equal` and `Exists` operators in tolerations
- Apply multiple taints to a node and match them with multiple tolerations
- Observe `tolerationSeconds` in action with a live eviction demo
- Understand why Taints+Tolerations alone don't guarantee placement

## Prerequisites

**Required Software:**
- Kubernetes cluster with at least 2 worker nodes (minikube multi-node, kind, or cloud provider)
- kubectl installed and configured
- Text editor (VS Code recommended with Kubernetes extension)

**Knowledge Requirements:**
- Understanding of Pods and Deployments
- Familiarity with `kubectl apply`, `kubectl describe`, `kubectl get`
- Basic YAML syntax

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Apply and remove taints on nodes using `kubectl taint`
2. ✅ Write tolerations in Pod and Deployment manifests
3. ✅ Explain the difference between `NoSchedule`, `PreferNoSchedule`, and `NoExecute`
4. ✅ Use `Equal` and `Exists` toleration operators correctly
5. ✅ Apply multiple taints to a node and tolerate all of them
6. ✅ Demonstrate `tolerationSeconds` with a live eviction timer
7. ✅ Explain why tolerations don't guarantee pod placement

## Directory Structure

```
02-taints-tolerations/
├── README.md                         # This file
└── src/
    ├── toleration-equal.yaml         # Deployment with Equal operator toleration
    ├── toleration-exists.yaml        # Pod with Exists operator toleration
    ├── toleration-multi.yaml         # Deployment with multiple tolerations
    ├── toleration-seconds-demo.yaml  # Deployment demonstrating tolerationSeconds
```

---

## Understanding Taints & Tolerations

### Core Concept

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│   TAINT  (on Node)    ←→    TOLERATION  (on Pod)           │
│                                                             │
│   "NO ENTRY" sign           "Key card" that grants access  │
│   Repels pods               Allows pod to enter            │
│                                                             │
│   kubectl taint node        tolerations: in pod spec YAML  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

> ⚠️ **Critical Rule:** A toleration PERMITS a pod to be scheduled on a tainted node. It does NOT guarantee it. For guaranteed placement, combine with Node Affinity (covered in the next demo).

### Taint Syntax

```
key=value:Effect
  │    │      └─ NoSchedule | PreferNoSchedule | NoExecute
  │    └──────── The value (optional)
  └───────────── The key
```

```bash
# Examples
kubectl taint node worker1 storage=ssd:NoSchedule
kubectl taint node worker2 env=production:NoExecute
kubectl taint node worker3 dedicated:NoSchedule          # key-only, no value
```

### The Three Taint Effects

```
┌──────────────────────┬────────────────────────┬───────────────────────┬─────────────────────────────┐
│       Effect         │  New Pods (no tolera.) │ Existing Pods (no t.) │ Pods WITH toleration        │
├──────────────────────┼────────────────────────┼───────────────────────┼─────────────────────────────┤
│ NoSchedule           │ ❌ Not scheduled       │ ✅ Keep running      │ ✅ Scheduled                │
│ PreferNoSchedule     │ ⚠️  Avoid (soft rule)  │ ✅ Keep running      │ ✅ Scheduled (preferred)    │
│ NoExecute            │ ❌ Not scheduled       │ ❌ Evicted           │ ✅ Scheduled & kept         │
└──────────────────────┴────────────────────────┴───────────────────────┴─────────────────────────────┘
```

### Toleration Fields — KOVE

Remember the fields inside a toleration using the acronym **KOVE**:

```
K → key      The taint key to match
O → operator Equal (match key + value) | Exists (match key only)
V → value    The taint value — OMIT this when operator is Exists
E → effect   Must EXACTLY match the taint effect on the node
```

---

## Lab Step-by-Step Guide

---

### Step 1: Inspect Your Cluster

Before applying any taints, check the current state of nodes:

```bash
cd 02-taints-tolerations/src

kubectl get nodes
```

**Expected output:**
```
NAME        STATUS   ROLES           AGE   VERSION
3node       Ready    control-plane   10m   v1.34.0
3node-m02   Ready    <none>          10m   v1.34.0
3node-m03   Ready    <none>          10m   v1.34.0
```

Check existing taints on all nodes:

```bash
kubectl describe nodes | grep -A1 Taints
```

**Expected output:**
```
Taints:   <none>
--
Taints:   <none>
--
Taints:   <none>
```

> **Note (Minikube users):** The control plane node (`3node`) has `Taints: <none>`. This is Minikube's default behaviour. In a kubeadm cluster, the control plane would have `node-role.kubernetes.io/control-plane:NoSchedule` automatically applied. Keep this in mind — in this lab your pods may land on the control plane node since there is no taint blocking them.

---

### Step 2: Apply Your First Taint

Apply a `NoSchedule` taint to `worker1` (your first worker node):

```bash
kubectl taint node 3node-m02 storage=ssd:NoSchedule
```

**Expected output:**
```
node/3node-m02 tainted
```

Verify the taint is applied:

```bash
kubectl describe node 3node-m02 | grep -i taint
```

**Expected output:**
```
Taints:   storage=ssd:NoSchedule
```

Now deploy a simple deployment  **without** any toleration:

```bash
kubectl create deployment nginx-deploy --image nginx --replicas 3
kubectl get pods -o wide
```

**Expected output:**
```
NAME                            READY   STATUS    RESTARTS   AGE   IP           NODE        NOMINATED NODE   READINESS GATES
nginx-deploy-6f47956ff4-2n4mv   1/1     Running   0          68s   10.244.2.5   3node-m03   <none>           <none>
nginx-deploy-6f47956ff4-g5krj   1/1     Running   0          68s   10.244.0.8   3node       <none>           <none>
nginx-deploy-6f47956ff4-lsdmn   1/1     Running   0          68s   10.244.2.6   3node-m03   <none>           <none>
```

**What happened:**
- `3node-m02` has a `NoSchedule` taint — the pods has no toleration for it
- The scheduler skipped `3node-m02` and placed the pods on `3node-m03` & (`3node`)
- Since its  a minikube cluster, control plane (`3node`) also used to schedule normal pods

**Clean up before moving on:**

```bash
kubectl delete deploy nginx-deploy
```

---

### Step 3: Deploy with Equal Operator Toleration

Apply the taint to the second worker too:

```bash
kubectl taint node 3node-m03 storage=hdd:NoSchedule
```

Both worker nodes are now tainted. Let's examine the deployment manifest:

**toleration-equal.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ssd-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ssd-app
  template:
    metadata:
      labels:
        app: ssd-app
    spec:
      tolerations:
        - key: "storage"          # Must match taint key
          operator: "Equal"       # key + value must both match
          value: "ssd"            # Must match taint value
          effect: "NoSchedule"    # Must match taint effect exactly
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

**Key YAML Fields Explained:**

- `tolerations:` — list under `spec` (pod spec), NOT at the Deployment spec level
- `key: "storage"` — matches the taint key `storage`
- `operator: "Equal"` — both key AND value must match exactly
- `value: "ssd"` — matches the taint value `ssd`
- `effect: "NoSchedule"` — must match the taint effect exactly

```bash
kubectl apply -f toleration-equal.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                       READY   STATUS    RESTARTS   AGE   IP             NODE        NOMINATED NODE   READINESS GATES
ssd-app-75d9dbb67f-6h5f5   1/1     Running   0          9s    10.244.1.168   3node-m02   <none>           <none>
ssd-app-75d9dbb67f-bt792   1/1     Running   0          9s    10.244.1.167   3node-m02   <none>           <none>
ssd-app-75d9dbb67f-rmgnm   1/1     Running   0          9s    10.244.0.9     3node       <none>           <none>
```

**What happened:**
- The toleration matches `storage=ssd:NoSchedule` on `3node-m02`
- The toleration does NOT match `storage=hdd:NoSchedule` on `3node-m03`
- `3node` does not have any taints
- The scheduler skipped `3node-m03` and placed the all the pods land in `3node-m02` (the node where the toleration matches) and `3node`(the node where there is no taint)

**Clean up before moving on:**

```bash
kubectl delete -f toleration-equal.yaml
```

---

### Step 4: Deploy with Exists Operator Toleration

The `Exists` operator matches **any value** for a given key. This is useful when you want a pod to run on any node that has a `storage` taint, regardless of whether it is `ssd` or `hdd`.

**toleration-exists.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: storage-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: storage-app
  template:
    metadata:
      labels:
        app: storage-app
    spec:
      tolerations:
        - key: "storage"
          operator: "Exists"    # Matches storage=ssd AND storage=hdd
          effect: "NoSchedule"
          # ⚠️ No 'value:' field — required when using Exists operator
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

**Key Configuration Points:**

- `operator: "Exists"` — only the key needs to match, value is irrelevant
- **No `value:` field** — you must omit it when using `Exists`; including it causes a validation error
- Here pods can land on **either** `3node-m02` (ssd) **or** `3node-m03` (hdd) 

```bash
kubectl apply -f toleration-exists.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                             READY   STATUS    RESTARTS   AGE   IP             NODE        NOMINATED NODE   READINESS GATES
storage-deploy-b5867774d-5scpl   1/1     Running   0          14s   10.244.1.169   3node-m02   <none>           <none>
storage-deploy-b5867774d-8xtlq   1/1     Running   0          14s   10.244.2.7     3node-m03   <none>           <none>
storage-deploy-b5867774d-jpfv9   1/1     Running   0          14s   10.244.0.10    3node       <none>           <none>
```

**Clean up before moving on:**

```bash
kubectl delete -f toleration-exists.yaml
```

---

### Step 5: Operator Comparison

| Operator | Requires `value:` field? | Matches | Use When |
|---|---|---|---|
| `Equal` | ✅ Yes | key **AND** value must match exactly | Targeting a specific taint value (`ssd` vs `hdd`) |
| `Exists` | ❌ No — omit it | key match only, any value | Tolerate all variants of a key |

> ❌ **Common Mistake:** Using `operator: Exists` with a `value:` field causes a **validation error**. Always omit `value:` when using `Exists`.

---

### Step 6: Multiple Taints — AND Logic

A node can have multiple taints. A pod must satisfy **ALL** taints on the node to be scheduled there.

Add a second taint to `3node-m02`:

```bash
kubectl taint node 3node-m02 env=production:NoSchedule
```

Now `3node-m02` has two taints:
```
Taints:  storage=ssd:NoSchedule
         env=production:NoSchedule
```

A pod with only one toleration will be rejected. It needs BOTH:

**toleration-multi.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prod-storage-deploy
spec:
  replicas: 5
  selector:
    matchLabels:
      app: prod-storage-app
  template:
    metadata:
      labels:
        app: prod-storage-app
    spec:
      tolerations:
        - key: "storage"         # Toleration 1: any storage type
          operator: "Exists"
          effect: "NoSchedule"
        - key: "env"             # Toleration 2: must be production
          operator: "Equal"
          value: "production"
          effect: "NoSchedule"
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f toleration-multi.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                  READY   STATUS    RESTARTS   AGE   IP             NODE        NOMINATED NODE   READINESS GATES
prod-storage-deploy-76b956486-5wtrh   1/1     Running   0          9s    10.244.0.12    3node       <none>           <none>
prod-storage-deploy-76b956486-7w2qh   1/1     Running   0          9s    10.244.1.173   3node-m02   <none>           <none>
prod-storage-deploy-76b956486-kgrlm   1/1     Running   0          9s    10.244.1.172   3node-m02   <none>           <none>
prod-storage-deploy-76b956486-slz4g   1/1     Running   0          9s    10.244.2.11    3node-m03   <none>           <none>
prod-storage-deploy-76b956486-wlvw5   1/1     Running   0          9s    10.244.2.10    3node-m03   <none>           <none>
```

Pods spread across all three nodes because:
- `3node`     → no taints at all → any pod can schedule here, tolerations irrelevant
- `3node-m02` → two taints: Toleration 1 satisfies `storage=ssd:NoSchedule` ✅
                             Toleration 2 satisfies `env=production:NoSchedule` ✅
- `3node-m03` → one taint: Toleration 1 satisfies `storage=hdd:NoSchedule` ✅
                            No `env` taint exists here → Toleration 2 unused, not needed ✅

All three nodes pass. Tolerations don't attract — they only unblock.
To force all pods onto 3node-m02 exclusively, add Node Affinity.

> ⚠️ **Note:** A pod is blocked from a node only when the node has a taint the pod cannot satisfy. Extra tolerations on the pod that find no matching taint on a node are simply ignored — they never restrict placement.

**Clean up before moving on:**

```bash
kubectl delete -f toleration-multi.yaml
```

---

### Step 7: Removing Taints

> ⚠️ **Syntax rule:** To remove a taint, append a **trailing hyphen (`-`)** to the exact same command used to apply it.

```bash
# Remove storage=ssd taint from 3node-m02
kubectl taint node 3node-m02 storage=ssd:NoSchedule-

# Remove env=production taint from 3node-m02
kubectl taint node 3node-m02 env=production:NoSchedule-

# Remove storage=hdd taint from 3node-m03
kubectl taint node 3node-m03 storage=hdd:NoSchedule-

# Verify all removed
kubectl describe nodes | grep -A2 Taints
```

**Expected output:**
```
Taints:   <none>
--
Taints:   <none>
--
Taints:   <none>
```

---

### Step 8: NoExecute Effect — Live Eviction Demo

`NoExecute` is the strictest effect. It evicts **existing running pods** that do not have a matching toleration. Let's see this live.

First, clean up and deploy fresh pods **without** any tolerations:

```bash
kubectl create deployment plain-app --image=busybox --replicas=2 \
  -- sh -c "sleep 3600"

kubectl get pods -o wide
```

**Expected output:**
```
NAME                         READY   STATUS    RESTARTS   AGE   IP             NODE        NOMINATED NODE   READINESS GATES
plain-app-6f55df75cb-mwzpx   1/1     Running   0          8s    10.244.1.174   3node-m02   <none>           <none>
plain-app-6f55df75cb-xx86r   1/1     Running   0          8s    10.244.2.12    3node-m03   <none>           <none>
```

Now apply a `NoExecute` taint to `3node-m02`:

```bash
kubectl taint node 3node-m02 maintenance=true:NoExecute
```

```bash
kubectl get pods -o wide
```

**Expected output:**
```
NAME                         READY   STATUS        RESTARTS   AGE   IP             NODE        NOMINATED NODE   READINESS GATES
plain-app-6f55df75cb-bcdn5   1/1     Running       0          7s    10.244.0.13    3node       <none>           <none>
plain-app-6f55df75cb-mwzpx   1/1     Terminating   0          44s   10.244.1.174   3node-m02   <none>           <none>
plain-app-6f55df75cb-xx86r   1/1     Running       0          44s   10.244.2.12    3node-m03   <none>           <none>
```

**What happened:**
- `NoExecute` taint was applied
- The pod on `3node-m02` had **no matching toleration** → evicted immediately
- The Deployment controller created a replacement pod on `3node`

**Remove the taint and cleanup before the next step:**

```bash
kubectl taint node 3node-m02 maintenance=true:NoExecute-
kubectl delete deployment plain-app
```

---

### Step 9: tolerationSeconds — Time-Limited Toleration

`tolerationSeconds` is used with `NoExecute` only. It means: *"I tolerate this taint, but only for N seconds. After that, evict me."*

This is useful for **graceful draining** — give pods time to finish work before a node goes offline.

**toleration-seconds-demo.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: plain-deploy
spec:
  replicas: 2
  selector:
    matchLabels:
      app: plain-app
  template:
    metadata:
      labels:
        app: plain-app
    spec:
      tolerations:
        - key: "maintenance"
          operator: "Equal"
          value: "true"
          effect: "NoExecute"
          tolerationSeconds: 30   # Tolerated for 30s, then evicted
      containers:
        - name: busybox
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

**Key Configuration Points:**

- `tolerationSeconds: 30` — after the `env=test:NoExecute` taint is applied to the node, this pod will stay for 30 seconds, then be evicted
- This is NOT about blocking scheduling — it is about **how long the pod endures the condition before giving up**
- Omitting `tolerationSeconds` means the pod tolerates the taint **forever** (never evicted)

```bash
kubectl apply -f toleration-seconds-demo.yaml
kubectl get pods -o wide
```

Confirm pods are running, then apply the matching taint:

```bash
kubectl taint node 3node-m02 maintenance=true:NoExecute
```

**Open a second terminal and watch:**

```bash
# Terminal 2
kubectl get pods -o wide -w
```

**What you'll observe:**

```
# Immediately after taint applied — pods still running (30s grace period)
plain-deploy-xxxxxxxxx-xxxxx   1/1   Running      3node-m02   AGE: 45s

# ~30 seconds later — eviction triggered
plain-deploy-xxxxxxxxx-xxxxx   1/1   Terminating  3node-m02
plain-deploy-xxxxxxxxx-yyyyy   1/1   Running      3node-m02   ← NEW pod

# Another 30s — the replacement is also evicted (same timer applies!)
plain-deploy-xxxxxxxxx-yyyyy   1/1   Terminating  3node-m02
plain-deploy-xxxxxxxxx-zzzzz   1/1   Running      3node-m02   ← NEW pod
```

> ⚠️ **Important Observation:** You'll see a continuous eviction loop. The Deployment keeps creating replacement pods on `3node-m02` because the toleration **still permits** scheduling there. Each new pod is also evicted after 30 seconds. This loop continues until you remove the taint.

**Remove the taint to stop the loop and cleanup before the next step:**

```bash
kubectl taint node 3node-m02 maintenance=true:NoExecute-
kubectl delete -f toleration-seconds-demo.yaml
```

---

### Step 10: NoExecute — The Three Cases Summary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│               NoExecute Taint: maintenance=true:NoExecute                   │
├──────────────────────────┬──────────────────────────────────────────────────┤
│ Pod Configuration        │ Behaviour                                        │
├──────────────────────────┼──────────────────────────────────────────────────┤
│ No toleration            │ Evicted IMMEDIATELY                              │
├──────────────────────────┼──────────────────────────────────────────────────┤
│ Toleration, no           │ Stays on node FOREVER (never evicted)            │
│ tolerationSeconds        │                                                  │
├──────────────────────────┼──────────────────────────────────────────────────┤
│ Toleration with          │ Stays for N seconds after taint is applied,      │
│ tolerationSeconds: N     │ then evicted                                     │
└──────────────────────────┴──────────────────────────────────────────────────┘
```

> **Design Intent:** `tolerationSeconds` models *how long a pod is willing to endure a bad node condition* before requesting to be moved somewhere healthy. It is not an access permission — it is a **time-limited tolerance**.

> **Note:** `tolerationSeconds` is **silently ignored** on `NoSchedule` and `PreferNoSchedule` effects. It is only meaningful for `NoExecute`.

---

### Step 11: PreferNoSchedule Effect

`PreferNoSchedule` is a soft constraint. Kubernetes tries to avoid scheduling pods on this node but will do so if there is no better option.

```bash
kubectl taint node 3node-m02 tier=canary:PreferNoSchedule
```

Deploy a pod with **no toleration**:

```bash
kubectl create deployment soft-test --image=busybox --replicas=4 \
  -- sh -c "sleep 3600"
kubectl get pods -o wide
```

**What you'll observe:**
- Pods **prefer** `3node-m03` & `3node` (untainted nodes) — scheduled there first
- If they fill up, some pods may spill over to `3node-m02`

This is unlike `NoSchedule` which is a hard block.

```bash
# Clean up
kubectl taint node 3node-m02 tier=canary:PreferNoSchedule-
kubectl delete deployment soft-test
```

---

### Step 12: NoSchedule vs PreferNoSchedule vs NoExecute

```
NoSchedule         PreferNoSchedule       NoExecute
    │                     │                   │
    │  Hard block for      │  Soft preference  │  Evicts existing pods
    │  new pods            │  for new pods     │  (plus blocks new)
    │                      │                   │
    ↓                      ↓                   ↓
"DO NOT enter"        "Please avoid"        "LEAVE NOW"
(unless toleration)   (unless no choice)    (unless toleration, or
                                             wait tolerationSeconds)
```

---

### Step 13: Why Tolerations Don't Guarantee Placement

This is the most important and commonly misunderstood concept in this lab.

> **You already saw this in Step 6.** When you applied `toleration-multi.yaml` with 5
> replicas, pods spread across all three nodes — including `3node` (no taint) and
> `3node-m03` (only one taint, fully satisfied by Toleration 1). That was not a mistake.
> That is exactly how tolerations are designed to work.

The key rule:

> A toleration **unblocks** a node. It does not **attract** the pod to that node.
> The scheduler sees every node that passes taint checks as a valid candidate and
> distributes pods across all of them.
```
3node-m02 has taints → toleration unblocks it → valid candidate ✅
3node-m03 has taint  → toleration unblocks it → valid candidate ✅
3node     no taints  → always valid            → valid candidate ✅

Result: scheduler spreads pods across all three — not exclusively onto 3node-m02
```

**To force pods exclusively onto `3node-m02`**, you need Node Affinity alongside
the tolerations. 
> ⏭️ **Coming up in the Node Affinity lab:** You will learn how to combine
> Taints & Tolerations with Node Affinity to achieve guaranteed pod placement —
> where the node rejects unwanted pods AND the pod is attracted exclusively
> to its target node.

---

### Step 14: Automatic System Tolerations & Automatic System Taints

Kubernetes automatically manages both sides of the taint/toleration equation
for node health — you never configure these manually.

---

**Who applies the automatic taints?**

The **Node Lifecycle Controller** (part of `kube-controller-manager`) monitors
node health continuously. When it detects a problem, it automatically applies
a taint to that node.

The taint effect depends on the nature of the condition:

- **`not-ready` and `unreachable`** use `NoExecute` — the node is considered
  gone. Waiting makes no sense, but Kubernetes still gives a 300s grace window
  (via auto-injected tolerations) in case the node recovers from a brief blip.
  After 300s, pods are evicted and rescheduled on healthy nodes.

- **All other conditions** use `NoSchedule` — the node is still alive but under
  resource pressure. Existing pods keep running (evicting them would just move
  the problem elsewhere). Only new pods are blocked from scheduling there until
  the condition clears.

| Auto-Applied Taint | Effect | Existing Pods | New Pods | Reason |
|---|---|---|---|---|
| `node.kubernetes.io/not-ready` | NoExecute | Evicted after 300s | ❌ Blocked | Node may recover — wait 300s before evicting |
| `node.kubernetes.io/unreachable` | NoExecute | Evicted after 300s | ❌ Blocked | Node may recover — wait 300s before evicting |
| `node.kubernetes.io/memory-pressure` | NoSchedule | ✅ Keep running | ❌ Blocked | Node alive but constrained — don't add more load |
| `node.kubernetes.io/disk-pressure` | NoSchedule | ✅ Keep running | ❌ Blocked | Node alive but constrained — don't add more load |
| `node.kubernetes.io/pid-pressure` | NoSchedule | ✅ Keep running | ❌ Blocked | Node alive but constrained — don't add more load |
| `node.kubernetes.io/network-unavailable` | NoSchedule | ✅ Keep running | ❌ Blocked | Node alive, CNI issue — don't add more load |
| `node.kubernetes.io/unschedulable` | NoSchedule | ✅ Keep running | ❌ Blocked | Manual cordon — admin intentionally draining node |

---

**Who applies the automatic tolerations?**

The **`DefaultTolerationSeconds` admission controller** (inside `kube-apiserver`)
intercepts every pod creation and automatically injects these two tolerations
before the pod is stored — unless the pod already defines them:
```yaml
# Injected automatically on every pod — you never write these
tolerations:
- key: node.kubernetes.io/not-ready
  operator: Exists
  effect: NoExecute
  tolerationSeconds: 300
- key: node.kubernetes.io/unreachable
  operator: Exists
  effect: NoExecute
  tolerationSeconds: 300
```
Since only `not-ready` and `unreachable` use `NoExecute` and evict pods, those
are the only two conditions that need a grace window — hence only these two
tolerations are auto-injected:

**Verify on any pod:**
```bash
kubectl run inspect-pod --image=busybox -- sh -c "sleep 3600"
kubectl describe pod inspect-pod | grep -A6 Tolerations
```

**Expected output:**
```
Tolerations: node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
```

You never wrote these — the admission controller added them automatically.

**Cleanup:**
```bash
kubectl delete pod inspect-pod
```

---

**Why 300 seconds?**

The 300s window gives the Node Lifecycle Controller time to confirm the node
is genuinely down before evicting pods, preventing unnecessary disruption
during brief network blips or temporary restarts:
```
0s    — Node kubelet stops sending heartbeat
~40s  — Node Lifecycle Controller marks node NotReady
        → automatically applies not-ready:NoExecute taint
        → tolerationSeconds 300s countdown begins on all pods on that node
~340s — 300s elapsed → pods evicted and rescheduled on healthy nodes
```

> ⏱️ **This demo takes ~6-7 minutes end to end. Open two terminals before starting.**

---

**Simulate a node failure in Minikube — live demo:**

**Terminal 1 — deploy pods and start watching:**
```bash
# Deploy
kubectl create deployment failure-demo --image=busybox --replicas=4 \
  -- sh -c "sleep 3600"

# Verify pods are spread across nodes before starting
kubectl get pods -o wide
```

**Expected output:**
```
NAME                            READY   STATUS    RESTARTS   AGE   IP             NODE        NOMINATED NODE   READINESS GATES
failure-demo-57ccf95544-4pbld   1/1     Running   0          20s   10.244.0.19    3node       <none>           <none>
failure-demo-57ccf95544-dg25b   1/1     Running   0          20s   10.244.1.185   3node-m02   <none>           <none>
failure-demo-57ccf95544-k8869   1/1     Running   0          20s   10.244.1.186   3node-m02   <none>           <none>
failure-demo-57ccf95544-s4lzb   1/1     Running   0          20s   10.244.2.22    3node-m03   <none>           <none>
```
```bash
# Start watching — keep this running throughout the demo
kubectl get pods -o wide -w
```

---

**Terminal 2 — stop the kubelet on 3node-m02 to simulate failure:**
```bash
# SSH into the node
minikube ssh -n 3node-m02 -p 3node

# Stop the kubelet — this simulates the node going down
sudo systemctl stop kubelet

# Exit SSH
exit
```

---

**Terminal 2 — verify node status at each stage:**

**~40 seconds after kubelet stopped:**
```bash
kubectl get nodes
```

**Expected output:**
```
NAME        STATUS     ROLES           AGE
3node       Ready      control-plane   1d
3node-m02   NotReady   <none>          1d   ← node marked NotReady
3node-m03   Ready      <none>          1d
```
```bash
# Confirm Node Lifecycle Controller auto-applied the taint
kubectl describe node 3node-m02 | grep -A3 Taints
```

**Expected output:**
```
Taints: node.kubernetes.io/not-ready:NoExecute
```

> ⏱️ **Now wait ~5 minutes (300s) for the tolerationSeconds window to expire.**

**~6 minutes after kubelet stopped — check Terminal 1:**

You will see pods on `3node-m02` terminating and new pods being created on
`3node-m03`:
```
NAME                            READY   STATUS        RESTARTS   AGE   IP             NODE        NOMINATED NODE   READINESS GATES
failure-demo-57ccf95544-4pbld   1/1     Running       0          14m   10.244.0.19    3node       <none>           <none>
failure-demo-57ccf95544-dg25b   1/1     Terminating   0          14m   10.244.1.185   3node-m02   <none>           <none>  ← evicted
failure-demo-57ccf95544-hk25m   1/1     Running       0          34s   10.244.2.23    3node-m03   <none>           <none>  ← rescheduled
failure-demo-57ccf95544-k8869   1/1     Terminating   0          14m   10.244.1.186   3node-m02   <none>           <none>  ← evicted
failure-demo-57ccf95544-l4prz   1/1     Running       0          34s   10.244.0.20    3node       <none>           <none>  ← rescheduled
failure-demo-57ccf95544-s4lzb   1/1     Running       0          14m   10.244.2.22    3node-m03   <none>           <none>
```
```bash
# Confirm all running pods are now on healthy nodes only
kubectl get pods -o wide
```

**Expected output:**
```
NAME                            READY   STATUS        RESTARTS   AGE   IP             NODE        NOMINATED NODE   READINESS GATES
failure-demo-57ccf95544-4pbld   1/1     Running       0          24m   10.244.0.19    3node       <none>           <none>
failure-demo-57ccf95544-hk25m   1/1     Running       0          10m   10.244.2.23    3node-m03   <none>           <none>
failure-demo-57ccf95544-l4prz   1/1     Running       0          10m   10.244.0.20    3node       <none>           <none>
failure-demo-57ccf95544-s4lzb   1/1     Running       0          24m   10.244.2.22    3node-m03   <none>           <none>
```

---

**Terminal 2 — bring the node back up:**
```bash
minikube ssh -n 3node-m02 -p 3node
sudo systemctl start kubelet
exit
```

**Verify node recovers and taint is automatically removed:**
```bash
# Wait ~30s for kubelet to reconnect, then check
kubectl get nodes
```

**Expected output:**
```
NAME        STATUS   ROLES           AGE
3node       Ready    control-plane   1d
3node-m02   Ready    <none>          1d   ← back to Ready
3node-m03   Ready    <none>          1d
```
```bash
# Confirm taint is gone — removed automatically on recovery
kubectl describe node 3node-m02 | grep -A3 Taints
```

**Expected output:**
```
Taints: <none>
```

> Note: pods that were rescheduled to `3node-m03` will NOT move back to
> `3node-m02` automatically. They stay where they are until deleted or
> the deployment is restarted.

---

### Step 15: Final Cleanup

```bash
# Verify  any remaining taints , if any remove them
kubectl describe node | grep -A2 Taints


# Delete all deployments and pods from this lab
 kubectl delete deployment --all

# Verify clean state
kubectl get all
kubectl describe nodes | grep -A1 Taints
```

---

## Experiments to Try

1. **What happens when effect is mismatched?**
   ```bash
   # Taint with NoSchedule
   kubectl taint node 3node-m02 test=mismatch:NoSchedule

   # Pod with NoExecute toleration (wrong effect)
   kubectl run mismatch-test --image=nginx \
     --overrides='{"spec":{"tolerations":[{"key":"test","operator":"Equal","value":"mismatch","effect":"NoExecute"}]}}'

   kubectl get pods -o wide
   # Pod will NOT go to 3node-m02 — effect mismatch means no match!
   kubectl taint node 3node-m02 test=mismatch:NoSchedule-
   kubectl delete pod mismatch-test
   ```

2. **Wildcard — tolerate everything:**
   ```yaml
   tolerations:
   - operator: "Exists"   # No key, no effect = matches ALL taints
   ```
   Apply multiple taints to a node and confirm this pod schedules there.

3. **tolerationSeconds: 0 — instant eviction:**
   ```yaml
   tolerationSeconds: 0   # Same as having no toleration at all
   ```
   Apply a `NoExecute` taint and observe immediate eviction despite having a toleration.

4. **Cordon vs Taint:**
   ```bash
   # Cordon is a high-level wrapper over NoSchedule taint
   kubectl cordon 3node-m02
   kubectl describe node 3node-m02 | grep -i taint
   # You'll see: node.kubernetes.io/unschedulable:NoSchedule
   kubectl uncordon 3node-m02
   ```

---

## Common Questions

### Q: Where exactly does `tolerations:` go in a Deployment YAML?

**A:** It goes under `spec.template.spec` (the **pod spec**), not at `spec` (the Deployment spec):

```yaml
spec:                  # ← Deployment spec
  replicas: 3
  template:
    spec:              # ← Pod spec
      tolerations:     # ← HERE ✅
      - key: ...
      containers:
      - name: ...
```

Adding it at the Deployment spec level (`spec.tolerations`) will cause a validation error.

### Q: Can I have multiple taints on one node and multiple tolerations on one pod?

**A:** Yes. A pod must satisfy **ALL** taints on a node to be scheduled there. Each toleration independently satisfies one taint. If even one taint is unsatisfied, the pod is rejected from that node.

### Q: If I remove a taint, what happens to pods?

**A:** Nothing. Existing pods continue running. The taint removal only affects future scheduling decisions.

### Q: Does tolerationSeconds work for NoSchedule?

**A:** No. `tolerationSeconds` is **silently ignored** for `NoSchedule` and `PreferNoSchedule`. It is only meaningful for `NoExecute`, where eviction is time-based.

### Q: What's the difference between NoExecute and kubectl drain?

**A:** `kubectl drain` is a high-level command that: (1) cordons the node (`NoSchedule` taint), then (2) evicts all pods gracefully. Under the hood it uses the same NoExecute eviction mechanism but adds safety checks (respects PodDisruptionBudgets, ignores DaemonSets by default). Use `drain` for planned maintenance.

---

## What You Learned

In this lab, you:
- ✅ Applied and removed taints using `kubectl taint` with `NoSchedule`, `PreferNoSchedule`, and `NoExecute` effects
- ✅ Wrote tolerations using both `Equal` and `Exists` operators in Deployment and Pod manifests
- ✅ Applied multiple taints to a node and matched them with multiple tolerations (AND logic)
- ✅ Observed live `tolerationSeconds` eviction and understood the eviction loop behaviour
- ✅ Confirmed that tolerations permit but do not guarantee pod placement
- ✅ Discovered automatically injected system tolerations from `DefaultTolerationSeconds` admission controller

**Key Takeaway:** Taints repel, tolerations permit — but neither guarantees placement. For true pod isolation, always combine Taints+Tolerations with Node Affinity. Use `NoExecute` with `tolerationSeconds` for graceful node draining, and `NoSchedule` to direct new workloads without disturbing existing ones.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get nodes` | List all nodes |
| `kubectl describe nodes \| grep -A1 Taints` | Check taints on all nodes at once |
| `kubectl describe node <n> \| grep -i taint` | Check taints on a specific node |
| `kubectl taint node <n> key=value:Effect` | Apply a taint |
| `kubectl taint node <n> key=value:Effect-` | **Remove** a taint (trailing `-`) |
| `kubectl label node <n> key=value` | Label a node (for affinity) |
| `kubectl label node <n> key-` | Remove a label from a node |
| `kubectl cordon <n>` | Mark node unschedulable (adds NoSchedule taint) |
| `kubectl drain <n> --ignore-daemonsets` | Drain node for maintenance |
| `kubectl uncordon <n>` | Restore node scheduling |

### Generate Manifests Fast (CKA Time Saver)

```bash
# Generate deployment YAML and add tolerations manually
kubectl create deployment myapp --image=nginx --replicas=3 \
  --dry-run=client -o yaml > deploy.yaml
# Edit deploy.yaml to add tolerations, then:
kubectl apply -f deploy.yaml
```

---

## CKA Certification Tips

**For Taints & Tolerations questions:**

✅ **Know taint apply vs remove syntax:**
```bash
# Apply
kubectl taint node worker1 key=value:Effect

# Remove (trailing hyphen — easy to forget under pressure!)
kubectl taint node worker1 key=value:Effect-
```

✅ **Use `kubectl explain` as in-exam documentation:**
```bash
kubectl explain pod.spec.tolerations
kubectl explain pod.spec.tolerations.operator
# No internet needed — always available in CKA exam
```

✅ **KOVE memory aid for toleration fields:**
```
K → key | O → operator | V → value | E → effect
```

✅ **Effect must match exactly** — a toleration for `NoExecute` does NOT match a taint with `NoSchedule`. Mismatch = pod stays Pending.

✅ **Exists operator: never include `value:` field:**
```yaml
# ❌ Wrong — causes validation error
- key: storage
  operator: Exists
  value: ssd         # Remove this line!
  effect: NoSchedule

# ✅ Correct
- key: storage
  operator: Exists
  effect: NoSchedule
```

✅ **Check taints fast in exam:**
```bash
kubectl describe node <n> | grep -i taint
# or check all nodes at once:
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

✅ **tolerations: location in Deployment — most common exam mistake:**
```yaml
spec:            # Deployment spec ← WRONG location
  tolerations:

spec:            # Deployment spec
  template:
    spec:        # Pod spec
      tolerations:   # ← CORRECT location ✅
```


✅ **tolerationSeconds only works with NoExecute** — silently ignored on other effects.

✅ **Built-in control plane taint** (kubeadm clusters):
```
node-role.kubernetes.io/control-plane:NoSchedule
```
Minikube does NOT apply this by default — be aware in lab environments.

---

## Troubleshooting

**Pod stuck in Pending state?**
```bash
kubectl describe pod <pod-name>
# Look for: "0/N nodes are available: N node(s) had untolerated taint"
# This means no node has a taint that matches the pod's tolerations
# OR pod is missing a toleration for a taint on all available nodes
```

**Taint not removing?**
```bash
# Make sure you include the full key=value:Effect- (with trailing hyphen)
kubectl taint node worker1 storage=ssd:NoSchedule-

# If you get "not found" error, check exact taint on the node first
kubectl describe node worker1 | grep -i taint
```

**Pod not landing on expected node?**
```bash
# Check if toleration effect matches taint effect exactly
kubectl describe node <node> | grep -i taint   # See node's taint
kubectl describe pod <pod> | grep -A5 Tolerations  # See pod's tolerations

# Remember: toleration does not GUARANTEE placement, only PERMITS it
# Add nodeAffinity for guaranteed placement
```

**CrashLoopBackOff instead of scheduling issue?**
```bash
kubectl describe pod <pod-name>
kubectl logs <pod-name>
# CrashLoopBackOff means the pod WAS scheduled but the container crashed
# Check Exit Code: 0 means the container exited cleanly (e.g., busybox with no command)
# Fix: add command: ["sh", "-c", "sleep 3600"] to keep container running
```

**General debugging:**
```bash
kubectl describe pod <name>       # Events section shows scheduling decisions
kubectl get events --sort-by='.lastTimestamp'  # Cluster-wide event log
kubectl describe node <name>      # Full node state including taints and allocated pods
```