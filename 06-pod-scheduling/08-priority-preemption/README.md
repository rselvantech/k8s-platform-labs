# Pod Priority & Preemption

## Lab Overview

When a cluster runs out of resources, the scheduler needs to decide which
pods to evict to make room for new ones. Without priority, the decision
is arbitrary. With priority, you control it explicitly.

<u>Pod Priority tells the scheduler how important a pod is relative to
others.</u> When a high-priority pod cannot be scheduled because no node has
sufficient resources, the scheduler preempts (evicts) lower-priority pods
to make room — within seconds, not minutes.

This is fundamentally different from node autoscaling. Adding a new node
takes minutes. Preemption happens in seconds. For latency-sensitive
critical services, preemption is the preferred mechanism.

Real-world use case: you run CI/CD pipelines, ML training jobs, and a
critical web service in the same cluster. The web service must always
have capacity. CI/CD and ML jobs fill unused capacity but yield it
immediately when the web service needs resources.

**What this lab covers:**
- PriorityClass — defining priority levels
- priorityClassName — assigning priority to pods
- Preemption — high-priority pod evicts lower-priority pods
- preemptionPolicy: Never — priority without preemption
- globalDefault — default priority for pods without a class
- Built-in system priority classes
- ResourceQuota + PriorityClass — preventing priority abuse

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl installed and configured

**Knowledge Requirements:**
- **REQUIRED:** Completion of [06-resource-management](../06-resource-management/)
- **REQUIRED:** Completion of [07-resource-quota-deep-dive](../07-resource-quota-deep-dive/)
- Understanding of resource requests and limits
- Understanding of QoS classes

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Create PriorityClasses with different priority values
2. ✅ Assign priorityClassName to pods and verify spec.priority is auto-populated
3. ✅ Observe preemption — high-priority pod evicts lower-priority pods
4. ✅ Explain the difference between PreemptLowerPriority and Never
5. ✅ Use globalDefault to set a default priority for all pods
6. ✅ Identify built-in system priority classes and their reserved values
7. ✅ Use ResourceQuota scoped to PriorityClass to prevent priority abuse

## Directory Structure

```
08-priority-preemption/
├── README.md                        # This file
└── src/
    ├── priority-classes.yaml        # PriorityClass definitions — critical, high, low
    ├── low-priority-deploy.yaml     # Deployment using low priority — fills cluster capacity
    ├── high-priority-pod.yaml       # Pod using critical priority — triggers preemption
    ├── non-preempting-class.yaml    # PriorityClass with preemptionPolicy: Never
    ├── non-preempting-pod.yaml      # Pod using non-preempting class
    └── quota-with-priority.yaml     # ResourceQuota scoped to PriorityClass
```

---

## Understanding Pod Priority & Preemption

### What is Priority

Pods can have priority. Priority indicates the importance of a Pod
relative to other Pods. If a Pod cannot be scheduled, the scheduler
tries to preempt (evict) lower priority Pods to make scheduling of
the pending Pod possible.

**Priority is an integer value. Higher value = higher priority.**

```
User-defined   :      -2,147,483,648 to 1,000,000,000
System reserved:      above 1,000,000,000

(Simple form):
User-defined   :  -ve 2 billion  to +ve 1 billion
System reserved:  > 1 billion
```


> Negative priority values are valid. If you give a negative priority
> to your non-critical workload, Cluster Autoscaler does not add more
> nodes to your cluster when the non-critical pods are pending. Negative
> priority pods act as capacity fillers — they use idle capacity and
> yield it immediately when real workloads need it.


### priorityClassName — Assigning Priority to a Pod

`priorityClassName` is the pod-level field that links a pod to a
PriorityClass. It is set in the pod spec — not in the PriorityClass
itself.
```yaml
spec:
  priorityClassName: critical   # ← references the PriorityClass by name
  containers:
    - name: app
      ...
```

When a pod is created with `priorityClassName` set:
```
1. The priority admission controller looks up the PriorityClass by name
2. Copies the integer value into spec.priority (read-only field)
3. Pod enters the scheduling queue with that priority value
```
```
priorityClassName: critical   → human-readable reference
spec.priority: 100000         → integer value — what the scheduler uses

spec.priority is READ-ONLY — populated automatically by the admission
controller. Never set it directly in a manifest.
```

If `priorityClassName` references a PriorityClass that does not exist
— the pod is rejected at admission with a validation error.

If `priorityClassName` is not set and a `globalDefault` PriorityClass
exists — that class's value is used. If no `globalDefault` exists —
`spec.priority` defaults to 0.
```
priorityClassName set    → admission controller copies value → spec.priority set
priorityClassName absent + globalDefault exists → globalDefault value used
priorityClassName absent + no globalDefault     → spec.priority = 0
```

### PriorityClass Fields

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000              # priority integer — higher = more important
globalDefault: false         # if true, applied to pods without priorityClassName
preemptionPolicy: PreemptLowerPriority  # default
description: "..."
```

| Field | Required | Purpose |
|---|---|---|
| `value` | ✅ | Priority integer — higher = more important |
| `globalDefault` | ❌ | If true — applied to pods without priorityClassName. Only one PriorityClass can have globalDefault: true |
| `preemptionPolicy` | ❌ | `PreemptLowerPriority` (default) or `Never` |
| `description` | ❌ | Human-readable note on intended use |

### PriorityClass Syntax — Memory Aid
```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: critical
preemptionPolicy: PreemptLowerPriority   # P
globalDefault: false                      # G
value: 100000                             # V
description: "Critical workloads"         # D
```

**PGVD** — "Preempt God, Value Daemon"
```
P → preemptionPolicy   PreemptLowerPriority (default) or Never
G → globalDefault      true or false (default) — only one PriorityClass can be true
V → value              priority integer — higher = more important
D → description        human-readable note on intended use
```

### preemptionPolicy — PreemptLowerPriority vs Never

```
PreemptLowerPriority (default)
  → Pod CAN preempt lower-priority pods
  → If no node has capacity, scheduler evicts lower-priority pods
  → Standard behaviour for critical workloads

Never
  → Pod CANNOT preempt other pods
  → Pod goes to front of scheduling queue ahead of lower-priority pods
  → Waits until resources are naturally available — no eviction
  → Use for workloads that need priority ordering but must not
    disrupt running pods
```

### Built-in System Priority Classes

Two built-in PriorityClasses exist in every Kubernetes cluster:

```
system-cluster-critical   → value: 2000000000 (2 Billion)
                            Used for cluster-level addons (coredns, metrics-server)

system-node-critical      → value: 2000001000  ( 2 Billion + 1,000)
                            Used for node-level critical components
                            (highest possible)
```
>`Node beats Cluster by 1,000`

`User-defined PriorityClass` values must stay below 1,000,000,000 ( `1 Billion`) to
avoid conflicting with the system-reserved range.

### How Preemption Works

```
1. High-priority pod created → enters scheduling queue
2. Scheduler tries to find a node with sufficient resources
3. No node found → preemption logic triggered
4. Scheduler finds a node where evicting lower-priority pods
   would free enough resources for the preemptor
5. Lower-priority pods terminated gracefully
6. High-priority pod scheduled on the freed node
7. Evicted lower-priority pods' controllers create NEW replacement pods
   → new pods enter the scheduling queue
   → if no capacity available → new pods go Pending
   → they stay Pending until capacity is freed
   → standalone pods (no controller) are gone permanently —
     no automatic recreation
```

Preemption happens only when the priority of the pending Pod is higher
than the victim Pods, and the cluster does not have enough resources.

### Priority vs QoS — Two Separate Systems

```
Priority (PriorityClass)  → scheduler decision at SCHEDULING time
                            controls which pending pod gets resources first
                            controls which running pod gets evicted to make room

QoS (requests/limits)     → kubelet decision at RUNTIME
                            controls which running pod gets evicted under node pressure
                            controls CPU throttling

The kube-scheduler does not consider QoS class when selecting which
Pods to preempt. Preemption is driven purely by priority value.
QoS class affects node-pressure eviction order (covered in Demo 09).
```

---

## Lab Step-by-Step Guide

---

### Step 1: Inspect Built-in Priority Classes

```bash
cd 07-priority-preemption/src

kubectl get priorityclass
```

**Expected output:**
```
NAME                      VALUE        GLOBAL-DEFAULT   AGE
system-cluster-critical   2000000000   false            ...
system-node-critical      2000001000   false            ...
```

```bash
kubectl describe priorityclass system-cluster-critical
```

**Expected output:**
```
Name:             system-cluster-critical
Value:            2000000000
GlobalDefault:    false
PreemptionPolicy: PreemptLowerPriority
Description:      Used for system critical pods that must not be moved
                  from their current node.
```

> These two built-in classes are present in every Kubernetes cluster.
> User-defined values must stay below 1,000,000,000.

---

### Step 2: Create PriorityClasses

**priority-classes.yaml:**
```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: critical
value: 100000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "Critical workloads — web service, API tier. Can preempt lower priority pods."
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high
value: 10000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "High priority workloads — background services."
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: low
value: 100
globalDefault: true
preemptionPolicy: PreemptLowerPriority
description: "Low priority — CI/CD jobs, batch processing. Default for all pods."
```

```bash
kubectl apply -f priority-classes.yaml
kubectl get priorityclass
```

**Expected output:**
```
NAME                      VALUE        GLOBAL-DEFAULT   AGE
critical                  100000       false            5s
high                      10000        false            5s
low                       100          true             5s
system-cluster-critical   2000000000   false            ...
system-node-critical      2000001000   false            ...
```

> `globalDefault: true` on `low` means any pod without a
> `priorityClassName` gets priority value 100 automatically.
> Only one PriorityClass can have `globalDefault: true`.

---

### Step 3: Deploy Low-Priority Pods to Fill Cluster Capacity

This step fills both worker nodes with low-priority pods consuming most
of the available CPU. When the high-priority pod arrives in Step 4 and
needs 2000m CPU, it cannot schedule on either node — triggering preemption.

**Step 3a — Taint control plane and check baseline capacity:**

Taint the control plane so no workload pods land on it — minikube does
not apply this taint by default unlike kubeadm clusters:
```bash
kubectl taint nodes 3node node-role.kubernetes.io/control-plane:NoSchedule
kubectl describe nodes | grep -E "Name:|Taints:"
```

**Expected output:**
```
Name:               3node
Taints:             node-role.kubernetes.io/control-plane:NoSchedule
Name:               3node-m02
Taints:             <none>
Name:               3node-m03
Taints:             <none>
```

Now check baseline allocatable resources and current allocation on
both worker nodes:
```bash
kubectl describe node 3node-m02 | grep -E "Allocatable:" -A6
kubectl describe node 3node-m02 | grep -E "Allocated resources:" -A6

kubectl describe node 3node-m03 | grep -E "Allocatable:" -A6
kubectl describe node 3node-m03 | grep -E "Allocated resources:" -A6
```

**Expected output:**
```
# 3node-m02
Allocatable:
  cpu:     16          ← 16 physical cores = 16,000m
  memory:  16001216Ki  ← ~15.3Gi

Allocated resources:
  cpu     200m  (1%)   ← kindnet(100m) + metrics-server(100m)
  memory  250Mi (1%)   ← kindnet(50Mi) + metrics-server(200Mi)

# 3node-m03
Allocatable:
  cpu:     16          ← 16 physical cores = 16,000m
  memory:  16001216Ki  ← ~15.3Gi

Allocated resources:
  cpu     100m  (0%)   ← kindnet(100m) only
  memory  50Mi  (0%)   ← kindnet(50Mi) only
```

> **How 16,000m is derived:**
> `Allocatable: cpu: 16` means 16 physical CPU cores.
> 1 CPU core = 1000 millicores (m).
> 16 cores × 1000m = 16,000m total allocatable CPU.

**Step 3b — Calculate how many pods are needed to fill nodes:**
```
3node-m02:
  Allocatable CPU:    16,000m  (from Allocatable: cpu: 16)
  Already allocated:    200m   (kube-system pods from Allocated resources)
  Available for pods: 15,800m  (16,000 - 200)
  Pod CPU request:     1,500m  each
  Pods that fit:      15,800 ÷ 1,500 = 10.5 → 10 pods (floor)
  CPU after 10 pods:  15,200m  (200 + 10 × 1,500)
  CPU remaining:         800m  (16,000 - 15,200)

3node-m03:
  Allocatable CPU:    16,000m  (from Allocatable: cpu: 16)
  Already allocated:    100m   (kube-system pods from Allocated resources)
  Available for pods: 15,900m  (16,000 - 100)
  Pod CPU request:     1,500m  each
  Pods that fit:      15,900 ÷ 1,500 = 10.6 → 10 pods (floor)
  CPU after 10 pods:  15,100m  (100 + 10 × 1,500)
  CPU remaining:         900m  (16,000 - 15,100)

Total replicas needed: 10 + 10 = 20

High-priority pod will request 2,000m CPU:
  2,000m > 800m (3node-m02 free) → cannot schedule ✅
  2,000m > 900m (3node-m03 free) → cannot schedule ✅
  Preemption must trigger on one of the worker nodes ✅
```

**Step 3c — Deploy low-priority pods:**

**low-priority-deploy.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: low-priority-deploy
spec:
  replicas: 20
  selector:
    matchLabels:
      app: low-priority
  template:
    metadata:
      labels:
        app: low-priority
    spec:
      terminationGracePeriodSeconds: 0
      priorityClassName: low
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
          resources:
            requests:
              cpu: "1500m"
              memory: "500Mi"
            limits:
              cpu: "1500m"
              memory: "500Mi"
```
```bash
kubectl apply -f low-priority-deploy.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                   READY   STATUS    NODE
low-priority-deploy-xxxxxxxxx-aaaaa    1/1     Running   3node-m02
low-priority-deploy-xxxxxxxxx-bbbbb    1/1     Running   3node-m02
low-priority-deploy-xxxxxxxxx-ccccc    1/1     Running   3node-m02
low-priority-deploy-xxxxxxxxx-ddddd    1/1     Running   3node-m02
low-priority-deploy-xxxxxxxxx-eeeee    1/1     Running   3node-m02
low-priority-deploy-xxxxxxxxx-fffff    1/1     Running   3node-m02
low-priority-deploy-xxxxxxxxx-gggggg   1/1     Running   3node-m02
low-priority-deploy-xxxxxxxxx-hhhhhh   1/1     Running   3node-m02
low-priority-deploy-xxxxxxxxx-iiiiii   1/1     Running   3node-m02
low-priority-deploy-xxxxxxxxx-jjjjjj   1/1     Running   3node-m02
low-priority-deploy-xxxxxxxxx-kkkkkk   1/1     Running   3node-m03
low-priority-deploy-xxxxxxxxx-llllll   1/1     Running   3node-m03
low-priority-deploy-xxxxxxxxx-mmmmmm   1/1     Running   3node-m03
low-priority-deploy-xxxxxxxxx-nnnnnn   1/1     Running   3node-m03
low-priority-deploy-xxxxxxxxx-oooooo   1/1     Running   3node-m03
low-priority-deploy-xxxxxxxxx-pppppp   1/1     Running   3node-m03
low-priority-deploy-xxxxxxxxx-qqqqqq   1/1     Running   3node-m03
low-priority-deploy-xxxxxxxxx-rrrrrr   1/1     Running   3node-m03
low-priority-deploy-xxxxxxxxx-ssssss   1/1     Running   3node-m03
low-priority-deploy-xxxxxxxxx-tttttt   1/1     Running   3node-m03
```

**Step 3d — Verify nodes are filled as calculated:**
```bash
kubectl describe nodes | grep -E "Name:|Allocated" -A6
```

**Expected output after filling:**
```
Name:               3node-m02
Allocated resources:
  Resource  Requests      Limits
  cpu       15200m (95%)  15100m (94%)
  memory    5250Mi (33%)  5050Mi (32%)

Name:               3node-m03
Allocated resources:
  Resource  Requests      Limits
  cpu       15100m (94%)  15100m (94%)
  memory    5050Mi (32%)  5050Mi (32%)
```

**Confirming the math:**
```
3node-m02:
  Before: 200m  used
  After:  15,200m used  (200m + 10 × 1500m)
  Free:   800m           ← less than 2000m needed by high-priority pod ✅

3node-m03:
  Before: 100m  used
  After:  15,100m used  (100m + 10 × 1500m)
  Free:   900m           ← less than 2000m needed by high-priority pod ✅
```

Verify priority value on one low-priority pod:
```bash
kubectl get pod <low-priority-pod-name> \
  -o jsonpath='{.spec.priority}' && echo
```

**Expected output:**
```
100
```

> Both nodes are now filled. Neither can accommodate a new pod
> requesting 2000m CPU. Step 4 deploys the high-priority pod —
> the scheduler will have no choice but to preempt lower-priority
> pods to make room.

---

### Step 4: Deploy High-Priority Pod — Observe Preemption

**high-priority-pod.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: high-priority-pod
spec:
  terminationGracePeriodSeconds: 0
  priorityClassName: critical
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: "3000m"
          memory: "3Gi"
        limits:
          cpu: "3000m"
          memory: "3Gi"
```

```bash
# Watch in a separate windows
kubectl get pods -o wide -w
```

```bash
# Apply this in another window
kubectl apply -f high-priority-pod.yaml
```

```bash
#Verify preemption events:
kubectl get events --sort-by='.lastTimestamp' | grep -i "preempt\|Preempted"
```

**Expected output — observe preemption sequence:**
```bash
╰─ kubectl get pods -o wide -w
NAME                                   READY   STATUS    RESTARTS   AGE   IP            NODE        NOMINATED NODE   READINESS GATES
low-priority-deploy-666584d7fc-5dhbj   1/1     Running   0          19m   10.244.2.31   3node-m03   <none>           <none>
low-priority-deploy-666584d7fc-5nskp   1/1     Running   0          19m   10.244.2.33   3node-m03   <none>           <none>
low-priority-deploy-666584d7fc-8pvnn   1/1     Running   0          19m   10.244.1.27   3node-m02   <none>           <none>
low-priority-deploy-666584d7fc-b5tsw   1/1     Running   0          19m   10.244.1.24   3node-m02   <none>           <none>
low-priority-deploy-666584d7fc-bwf7m   1/1     Running   0          19m   10.244.1.25   3node-m02   <none>           <none>
low-priority-deploy-666584d7fc-cprnm   1/1     Running   0          19m   10.244.1.23   3node-m02   <none>           <none>
low-priority-deploy-666584d7fc-d6tnv   1/1     Running   0          19m   10.244.2.30   3node-m03   <none>           <none>
low-priority-deploy-666584d7fc-db6zp   1/1     Running   0          19m   10.244.1.21   3node-m02   <none>           <none>
low-priority-deploy-666584d7fc-fl48p   1/1     Running   0          19m   10.244.1.29   3node-m02   <none>           <none>
low-priority-deploy-666584d7fc-hsnzl   1/1     Running   0          19m   10.244.1.20   3node-m02   <none>           <none>
low-priority-deploy-666584d7fc-ktzp8   1/1     Running   0          19m   10.244.2.29   3node-m03   <none>           <none>
low-priority-deploy-666584d7fc-ldrz8   1/1     Running   0          19m   10.244.2.37   3node-m03   <none>           <none>
low-priority-deploy-666584d7fc-lr6vm   1/1     Running   0          19m   10.244.1.22   3node-m02   <none>           <none>
low-priority-deploy-666584d7fc-prbqb   1/1     Running   0          19m   10.244.2.34   3node-m03   <none>           <none>
low-priority-deploy-666584d7fc-sdmv7   1/1     Running   0          19m   10.244.1.26   3node-m02   <none>           <none>
low-priority-deploy-666584d7fc-tjvsj   1/1     Running   0          19m   10.244.2.28   3node-m03   <none>           <none>
low-priority-deploy-666584d7fc-v5dch   1/1     Running   0          19m   10.244.2.35   3node-m03   <none>           <none>
low-priority-deploy-666584d7fc-w5dv5   1/1     Running   0          19m   10.244.2.32   3node-m03   <none>           <none>
low-priority-deploy-666584d7fc-xgtcb   1/1     Running   0          19m   10.244.1.28   3node-m02   <none>           <none>
low-priority-deploy-666584d7fc-xt74b   1/1     Running   0          19m   10.244.2.36   3node-m03   <none>           <none>
high-priority-pod                      0/1     Pending   0          0s    <none>        <none>      <none>           <none>
high-priority-pod                      0/1     Pending   0          0s    <none>        <none>      3node-m03        <none>
low-priority-deploy-666584d7fc-ktzp8   1/1     Running   0          22m   10.244.2.29   3node-m03   <none>           <none>
low-priority-deploy-666584d7fc-ktzp8   1/1     Terminating   0          22m   10.244.2.29   3node-m03   <none>           <none>
low-priority-deploy-666584d7fc-ktzp8   1/1     Terminating   0          22m   10.244.2.29   3node-m03   <none>           <none>
low-priority-deploy-666584d7fc-czbsv   0/1     Pending       0          0s    <none>        <none>      <none>           <none>
low-priority-deploy-666584d7fc-ldrz8   1/1     Running       0          22m   10.244.2.37   3node-m03   <none>           <none>
low-priority-deploy-666584d7fc-czbsv   0/1     Pending       0          0s    <none>        <none>      <none>           <none>
low-priority-deploy-666584d7fc-ldrz8   1/1     Terminating   0          22m   10.244.2.37   3node-m03   <none>           <none>
low-priority-deploy-666584d7fc-ldrz8   1/1     Terminating   0          22m   10.244.2.37   3node-m03   <none>           <none>
high-priority-pod                      0/1     Pending       0          0s    <none>        3node-m03   3node-m03        <none>
low-priority-deploy-666584d7fc-w22rf   0/1     Pending       0          0s    <none>        <none>      <none>           <none>
low-priority-deploy-666584d7fc-w22rf   0/1     Pending       0          0s    <none>        <none>      <none>           <none>
high-priority-pod                      0/1     ContainerCreating   0          0s    <none>        3node-m03   <none>           <none>
high-priority-pod                      1/1     Running             0          3s    10.244.2.38   3node-m03   <none>           <none>
```

```bash
╰─ k get events --sort-by='.lastTimestamp' | grep -i "preempt\|Preempted"
3m57s       Warning   FailedScheduling    pod/low-priority-deploy-666584d7fc-w22rf    0/3 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/contril-plane: }, 2 Insufficient cpu. no new claims to deallocate, preemption: 0/3 nodes are available: 1 Preemption is not helpful for scheduling, 2 Insufficient cpu.
3m57s       Normal    Preempted           pod/low-priority-deploy-666584d7fc-ktzp8    Preempted by pod f30b92f4-60e3-4d83-ad71-b3ca5fd61275 on node 3node-m03
3m57s       Warning   FailedScheduling    pod/low-priority-deploy-666584d7fc-czbsv    0/3 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/contril-plane: }, 2 Insufficient cpu. no new claims to deallocate, preemption: 0/3 nodes are available: 1 Preemption is not helpful for scheduling, 2 Insufficient cpu.
3m57s       Normal    Preempted           pod/low-priority-deploy-666584d7fc-ldrz8    Preempted by pod f30b92f4-60e3-4d83-ad71-b3ca5fd61275 on node 3node-m03
3m57s       Warning   FailedScheduling    pod/low-priority-deploy-666584d7fc-czbsv    0/3 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/contril-plane: }, 2 Insufficient cpu. no new claims to deallocate, preemption: 0/3 nodes are available: 1 Preemption is not helpful for scheduling, 2 Insufficient cpu.
```

**Observations from the live preemption sequence:**

**1. Nominated node appears before eviction:**
```
high-priority-pod   0/1   Pending   <none>     ← created, no node yet
high-priority-pod   0/1   Pending   3node-m03  ← NOMINATED NODE set
low-priority-deploy-...-ktzp8   Terminating   ← eviction starts AFTER nomination
```
The scheduler identified `3node-m03` as the target node and set
`nominatedNodeName` before evicting any pods — confirmed by the
watch output order. This is the scheduler's best candidate node.
The evictions follow nomination, not the other way around.

**2. Two low-priority pods evicted — not one:**
```
low-priority-deploy-...-ktzp8   Terminating   3node-m03   ← evicted (1500m freed)
low-priority-deploy-...-ldrz8   Terminating   3node-m03   ← evicted (1500m freed)
```
High-priority pod needs 3000m CPU. One eviction frees 1500m:
```
After 1 eviction: 900m + 1500m = 2400m free → still not enough (2400m < 3000m)
After 2 evictions: 2400m + 1500m = 3900m free → fits with headroom ✅
```
Scheduler calculated exactly how many pods to evict to satisfy the
request — no more, no fewer.

**3. High-priority pod scheduled immediately after eviction:**
```
high-priority-pod   ContainerCreating   3node-m03
high-priority-pod   Running             3node-m03   ← Running within seconds
```

**4. Evicted pods' controller created replacements — went Pending:**
```
low-priority-deploy-...-czbsv   Pending   ← replacement for ktzp8
low-priority-deploy-...-w22rf   Pending   ← replacement for ldrz8
```
Deployment controller detected 2 pods were terminated and immediately
created 2 new replacement pods. Both went Pending — no capacity left
on either node after high-priority pod consumed 3000m.

This confirms the verified behaviour from documentation:
```
Evicted pod itself → NOT rescheduled (pod UID is gone)
Controller → creates a NEW pod (new UID) → enters scheduling queue
No capacity available → new pod goes Pending
Stays Pending until capacity is freed naturally
```

**5. Events confirm preemption — identified by pod UID:**
```
Normal   Preempted   pod/...-ktzp8
         Preempted by pod f30b92f4-60e3-4d83-ad71-b3ca5fd61275 on node 3node-m03

Normal   Preempted   pod/...-ldrz8
         Preempted by pod f30b92f4-60e3-4d83-ad71-b3ca5fd61275 on node 3node-m03
```
Both preemption events reference the same pod UID — the high-priority
pod. The UID is used instead of the name because the pod was still
being scheduled when the event was generated.

**6. Replacement pods cannot preempt — same priority floor:**
Replacement low-priority pods (priority=100) cannot preempt anything
— there are no running pods with priority lower than 100 to evict.
They stay Pending until capacity is freed naturally.

**Complete verified preemption sequence:**
```
T+0s  high-priority-pod created → Pending (no node has 3000m free)
T+0s  scheduler nominates 3node-m03 → nominatedNodeName=3node-m03
T+0s  900m free on 3node-m03 → evict ktzp8 (1500m) → 2400m still not enough
T+0s  evict ldrz8 (1500m) → 3900m free → sufficient for 3000m request
T+0s  ktzp8 → Terminating, ldrz8 → Terminating
T+0s  Deployment controller creates czbsv and w22rf (new UIDs)
T+3s  high-priority-pod → ContainerCreating → Running on 3node-m03
      czbsv → Pending (no capacity — cannot preempt)
      w22rf → Pending (no capacity — cannot preempt)
```

Verify priority on high-priority pod:

```bash
kubectl get pod high-priority-pod -o jsonpath='{.spec.priority}' && echo
```

**Expected output:**
```
100000
```

> `spec.priority` is populated automatically by the priority admission
> controller from the `priorityClassName` value. You never set it directly.

---

### Step 5: preemptionPolicy: Never — Priority Without Preemption

A pod can have high priority (goes to front of queue) without being
allowed to preempt running pods.

**non-preempting-class.yaml:**
```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-non-preempting
value: 50000
globalDefault: false
preemptionPolicy: Never
description: "High priority but will not preempt running pods."
```

**non-preempting-pod.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: non-preempting-pod
spec:
  terminationGracePeriodSeconds: 0
  priorityClassName: high-non-preempting
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: "3000m"
          memory: "3Gi"
        limits:
          cpu: "3000m"
          memory: "3Gi"
```

```bash
# Watch in a separate windows
kubectl get pods -o wide -w
```

```bash
# Apply this in another window
kubectl apply -f non-preempting-class.yaml
kubectl apply -f non-preempting-pod.yaml
```

**Expected output:**
```
NAME                  READY   STATUS    NODE
non-preempting-pod    0/1     Pending   <none>
```

Pod stays Pending — it does not preempt running pods despite priority
value 50000.

```bash
kubectl describe pod non-preempting-pod | grep -A8 Events
```

**Expected output:**
```
Events:
  Warning  FailedScheduling  ...  0/3 nodes are available:
  1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane},
  2 node(s) had insufficient cpu.
  preemption: not eligible due to preemptionPolicy=Never                <--- This pod not eligible for preempt
```

> Pods with `preemptionPolicy: Never` will be placed in the scheduling
> queue ahead of lower-priority pods, but they cannot preempt other pods.
> They wait until sufficient resources are naturally available.

**Cleanup:**
```bash
kubectl delete -f low-priority-deploy.yaml
kubectl delete -f non-preempting-pod.yaml
kubectl delete priorityclass high-non-preempting
```

---

### Step 6: ResourceQuota + PriorityClass — Preventing Priority Abuse

Without controls, any developer can assign `critical` priority to their
pods — potentially preempting genuinely critical workloads. ResourceQuota
scoped to a PriorityClass prevents this by capping how many critical-priority
pods can exist in a namespace.

> **Note:** This step introduces `scopeSelector` with `PriorityClass` scope.
> Full ResourceQuota concepts including all scope types, object count quotas,
> and cross-namespace patterns are covered in
> [Demo 07 — ResourceQuota Deep Dive](../07-resource-quota-deep-dive/).

**quota-with-priority.yaml:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: critical-quota
  namespace: default
spec:
  hard:
    pods: "2"
    requests.cpu: "4"
    requests.memory: "4Gi"
  scopeSelector:
    matchExpressions:
      - operator: In
        scopeName: PriorityClass
        values:
          - critical
```

> `scopeSelector` with `PriorityClass` scope means this quota only
> counts pods that use the `critical` PriorityClass. Pods using `high`,
> `low`, or no priority class are completely unaffected by this quota.

```bash
kubectl apply -f quota-with-priority.yaml
kubectl describe resourcequota critical-quota
```

**Expected output:**
```
Name:       critical-quota
Namespace:  default
Scopes:     PriorityClass=critical
Resource         Used   Hard
--------         ----   ----
pods             1      2
requests.cpu     3      4
requests.memory  3Gi    4Gi
```

`Used: 1 pod` — the `high-priority-pod` from Step 4 is already counted.
`Hard: pods: 2` — only one more critical pod is allowed.

**Test 1 — verify non-critical pods are unaffected by quota:**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: low-priority-test
spec:
  terminationGracePeriodSeconds: 0
  priorityClassName: low
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: "100m"
          memory: "64Mi"
        limits:
          cpu: "100m"
          memory: "64Mi"
EOF

kubectl get pod low-priority-test
kubectl describe resourcequota critical-quota
```

**Expected output:**
```
NAME                READY   STATUS    AGE
low-priority-test   1/1     Running   5s
```
```
Resource         Used   Hard
--------         ----   ----
pods             1      2    ← still 1 — low-priority pod not counted ✅
requests.cpu     3      4    ← unchanged
requests.memory  3Gi    4Gi  ← unchanged
```

Low-priority pod scheduled and running — quota did not count it. ✅
```bash
kubectl delete pod low-priority-test --grace-period=0 --force
```

**Test 2 — add one more critical pod — should succeed (quota allows 2):**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: critical-pod-2
spec:
  terminationGracePeriodSeconds: 0
  priorityClassName: critical
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: "500m"
          memory: "256Mi"
        limits:
          cpu: "500m"
          memory: "256Mi"
EOF

kubectl get pod critical-pod-2
kubectl describe resourcequota critical-quota
```

**Expected output:**
```
NAME             READY   STATUS    AGE
critical-pod-2   1/1     Running   5s
```
```
Resource         Used    Hard
--------         ----    ----
pods             2       2    ← quota at limit
requests.cpu     3500m   4
requests.memory  3.25Gi  4Gi
```

**Test 3 — try to create a 3rd critical pod — should be rejected:**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: critical-pod-3
spec:
  terminationGracePeriodSeconds: 0
  priorityClassName: critical
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: "100m"
          memory: "64Mi"
        limits:
          cpu: "100m"
          memory: "64Mi"
EOF
```

**Expected output:**
```
Error from server (Forbidden): pods "critical-pod-3" is forbidden:
exceeded quota: critical-quota,
requested: pods=1,
used: pods=2,
limited: pods=2
```

3rd critical pod rejected — quota enforced. ✅
```bash
kubectl delete pod critical-pod-2 --grace-period=0 --force
```

**Test 4 — verify quota tracks correctly after deletion:**
```bash
kubectl describe resourcequota critical-quota
```

**Expected output:**
```
Resource         Used   Hard
--------         ----   ----
pods             1      2    ← back to 1 after critical-pod-2 deleted ✅
requests.cpu     3      4
requests.memory  3Gi    4Gi
```

**Cleanup:**
```bash
kubectl delete -f quota-with-priority.yaml
```
---

### Step 6: Final Cleanup

```bash
#Delete Resource quota
kubectl delete -f quota-with-priority.yaml

#Delete all pods
kubectl delete pod --all
kubectl delete deployment --all

#Delete all Priority Class
kubectl delete priorityclass critical high low

#Un-taint control plane
kubectl taint nodes 3node node-role.kubernetes.io/control-plane:NoSchedule-
```

---

## Common Questions

### Q: What happens to preempted pods?

**A:** Preempted pods are terminated gracefully (respecting
`terminationGracePeriodSeconds`) and then rescheduled by their
controller (Deployment, StatefulSet, etc.) on another node if capacity
exists. If no capacity exists, they go Pending. They are not permanently
deleted — their controller recreates them.

### Q: Does preemption respect PodDisruptionBudget?

**A:** Higher-priority Pods are considered for preemption only if the
removal of the lowest priority Pods is not sufficient to allow the
scheduler to schedule the preemptor Pod, or if the lowest priority
Pods are protected by PodDisruptionBudget. The scheduler tries to
respect PDB but preemption may still occur if no other option exists.
PDB is covered in Demo 10.

### Q: Does priority affect node-pressure eviction order?

**A:** The kubelet uses Priority to determine pod order for node-pressure
eviction alongside QoS class and resource usage. Node-pressure eviction
is covered in Demo 09.

### Q: Can I set a negative priority value?

**A:** Yes. Negative values are valid for user-defined PriorityClasses.
Negative priority pods act as cluster capacity fillers — they use idle
capacity and yield it immediately when real workloads need it. Cluster
Autoscaler does not add nodes when only negative priority pods are Pending.

---

## What You Learned

In this lab, you:
- ✅ Inspected built-in system priority classes and their reserved values
- ✅ Created PriorityClasses with different priority values and policies
- ✅ Assigned `priorityClassName` to pods and verified `spec.priority`
  is populated automatically by the admission controller
- ✅ Observed live preemption — high-priority pod evicted lower-priority
  pods and scheduled within seconds
- ✅ Used `preemptionPolicy: Never` — priority without eviction
- ✅ Used `globalDefault: true` to set a default priority for all pods
- ✅ Scoped ResourceQuota to a PriorityClass to prevent priority abuse

**Key Takeaway:** Priority controls scheduling order and preemption.
A high-priority pod that cannot schedule will preempt lower-priority
pods within seconds. `preemptionPolicy: Never` gives queue ordering
without eviction. Always scope ResourceQuota to PriorityClasses in
multi-tenant clusters to prevent abuse. Priority and QoS are separate
systems — Priority drives preemption, QoS drives node-pressure
eviction order.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get priorityclass` | List all priority classes including built-in |
| `kubectl describe priorityclass <n>` | Inspect a priority class |
| `kubectl get pod <n> -o jsonpath='{.spec.priority}'` | Get resolved priority value of a pod |
| `kubectl get events --sort-by='.lastTimestamp' \| grep -i preempt` | Find preemption events |
| `kubectl create priorityclass <n> --value=<v> --global-default=false --description="..."` | Create imperatively |
| `kubectl create priorityclass <n> --value=<v> --preemption-policy="Never"` | Create non-preempting class |
| `kubectl explain priorityclass` | Browse PriorityClass field docs |

---

## CKA Certification Tips

✅ **Short names — use in exam to save time:**
```bash
kubectl get pc          # PriorityClass
kubectl get quota       # ResourceQuota

# Examples
kubectl get pc
kubectl describe pc critical
kubectl get quota
kubectl describe quota critical-quota
```

✅ **PriorityClass API group — not v1:**
```yaml
apiVersion: scheduling.k8s.io/v1   # ← not apps/v1 or v1
kind: PriorityClass
```

✅ **Assign to pod via `priorityClassName` — spec.priority is read-only:**
```yaml
spec:
  priorityClassName: critical   # ← set this
  # spec.priority populated automatically — never set directly
```

✅ **Only one PriorityClass can have `globalDefault: true`**

✅ **preemptionPolicy values:**
```
PreemptLowerPriority  → default — can evict lower priority pods
Never                 → queue priority only — no eviction
```

✅ **Built-in system classes — memorise values:**
```
system-node-critical    → 2000001000  (highest)
system-cluster-critical → 2000000000
User-defined max        → below 1,000,000,000
```

✅ **Imperative creation:**
```bash
# Standard
kubectl create priorityclass high-priority --value=1000 --description="high priority"

# Non-preempting
kubectl create priorityclass high-priority --value=1000 --preemption-policy="Never"

# Global default
kubectl create priorityclass default-priority --value=1000 --global-default=true
```

---

## Troubleshooting

**High-priority pod still Pending after preemption should have triggered:**
```bash
kubectl describe pod <pod-name> | grep -A8 Events
# "No preemption victims found" → no node has enough capacity even
# after evicting all lower-priority pods — request too large
kubectl describe nodes | grep -E "Name:|Allocatable" -A5
```

**Pod not being preempted as expected:**
```bash
# Verify priority values
kubectl get pod <preemptor> -o jsonpath='{.spec.priority}' && echo
kubectl get pod <victim> -o jsonpath='{.spec.priority}' && echo
# Preemptor priority must be strictly HIGHER than victim priority
```

**Non-preempting pod unexpectedly evicting pods:**
```bash
kubectl describe priorityclass <n> | grep PreemptionPolicy
# Must show: PreemptionPolicy: Never
```
