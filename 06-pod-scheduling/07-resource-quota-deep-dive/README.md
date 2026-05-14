# ResourceQuota — Deep Dive

## Lab Overview

Demo 06 introduced ResourceQuota basics — how to cap total resource
consumption in a namespace and how it interacts with LimitRange. This
demo goes deeper into the full capabilities of ResourceQuota:

```
Demo 06 covered:
  → Basic compute quotas (requests.cpu, limits.memory)
  → Object count quotas (pods, services, PVCs)
  → ResourceQuota + LimitRange interaction

This demo covers:
  → All quota scope types — BestEffort, NotBestEffort,
    Terminating, NotTerminating, PriorityClass,
    CrossNamespacePodAffinity
  → scopeSelector — filtering which objects count
  → Multiple quotas in one namespace
  → Quota per namespace — multi-team isolation
  → Quota status monitoring
```

Real-world use case: a cluster shared by multiple teams. Each team gets
their own namespace with a ResourceQuota limiting total CPU, memory, and
object counts — preventing any one team from consuming all cluster
resources.

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl installed and configured

**Knowledge Requirements:**
- **REQUIRED:** Completion of [06-resource-management](../06-resource-management/)
- Understanding of QoS classes (BestEffort, Burstable, Guaranteed)
- Understanding of `spec.activeDeadlineSeconds`

> 💡 `spec.activeDeadlineSeconds` is covered in depth in
> [04-pod-deep-dive/04-workload-lifetime-controls](../../04-pod-deep-dive/04-workload-lifetime-controls/).
> Here it is only relevant as the distinguishing criterion for the `Terminating` vs `NotTerminating` quota scopes.

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain all ResourceQuota scope types and when each applies
2. ✅ Use `scopeSelector` to filter which pods a quota counts
3. ✅ Apply BestEffort and NotBestEffort scopes
4. ✅ Apply Terminating and NotTerminating scopes
5. ✅ Use PriorityClass scope to limit priority pod consumption
6. ✅ Apply multiple quotas in one namespace simultaneously
7. ✅ Apply Three Quotas in One Namespace
8. ✅ Monitor quota status — Hard, Used, remaining capacity
9. ✅ Implement per-namespace quota for multi-team isolation

## Directory Structure

```
07-resource-quota-deep-dive/
├── README.md                          # This file
└── src/
    ├── quota-compute.yaml             # Basic compute quota — requests, limits
    ├── quota-objects.yaml             # Object count quota — pods, services, PVCs
    ├── quota-besteffort.yaml          # Quota scoped to BestEffort pods only
    ├── quota-notbesteffort.yaml       # Quota scoped to non-BestEffort pods
    ├── quota-terminating.yaml         # Quota scoped to Terminating pods
    ├── quota-notterminating.yaml      # Quota scoped to NotTerminating pods
    ├── quota-priorityclass.yaml       # Quota scoped to PriorityClass
    ├── global-quota.yaml          
    ├── best-effort-limiter.yaml   
    ├── critical-pods-only.yaml    
    ├── quota-team-a.yaml              # Team-A namespace quota
    └── quota-team-b.yaml              # Team-B namespace quota
```

---

## Understanding ResourceQuota Scopes

### ResourceQuota Syntax ( with scope ) — Memory Aid

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: my-quota
  namespace: default
spec:
  hard:                          # H — Hard limits
    pods: "10"
    requests.cpu: "4"
    requests.memory: "8Gi"
    limits.cpu: "8"
    limits.memory: "16Gi"
  scopeSelector:                 # S — Scope filter (optional)
    matchExpressions:
      - scopeName: PriorityClass # which scope
        operator: In             # how to match
        values:
          - critical             # what to match
```

**HS** — "Hard Scopes"
```
H → hard          required — the limits to enforce
S → scopeSelector optional — which objects to count
```

### What is a Scope

A scope filters which objects a ResourceQuota tracks. Without a scope,
the quota applies to all objects in the namespace. With a scope, only
objects matching the scope criteria are counted.

ResourceQuotas with a scope set can also have an optional scopeSelector
field. You define one or more match expressions that specify operators
and, if relevant, a set of values to match.

For a resource to match, both scopes AND scopeSelector (if specified
in spec) must be matched — AND logic between both fields.

### All Supported Scope Types

| Scope | Matches | Operator |
|---|---|---|
| `BestEffort` | Pods with BestEffort QoS class | `Exists` only |
| `NotBestEffort` | Pods without BestEffort QoS class | `Exists` only |
| `Terminating` | Pods where `spec.activeDeadlineSeconds >= 0` | `Exists` only |
| `NotTerminating` | Pods where `spec.activeDeadlineSeconds` is nil | `Exists` only |
| `PriorityClass` | Pods with a specific PriorityClass | `In`, `NotIn`, `Exists`, `DoesNotExist` |
| `CrossNamespacePodAffinity` | Pods with cross-namespace pod affinity | `Exists` only |

### Terminating vs NotTerminating

```
Terminating    → spec.activeDeadlineSeconds >= 0
                 Applies to: Jobs, CronJobs, pods with a deadline
                 Use to cap batch job resource consumption separately

NotTerminating → spec.activeDeadlineSeconds is nil (not set)
                 Applies to: long-running pods (Deployments, StatefulSets)
                 Use to cap service resource consumption separately
```

### scopeSelector Operators

```
Exists       → scope applies to all matching objects (no values needed)
               Used for: BestEffort, NotBestEffort, Terminating, NotTerminating

In           → scope applies to objects matching specific values
               Used for: PriorityClass with specific class names

NotIn        → scope applies to objects NOT matching specific values
DoesNotExist → scope applies to objects without the scope attribute
```

### What Each Scope Can Track

Not all quota resources are available for all scopes:

```
BestEffort scope → can only track:
  pods

NotBestEffort, Terminating, NotTerminating scopes → can track:
  pods, cpu, memory, requests.cpu, requests.memory,
  limits.cpu, limits.memory

PriorityClass scope → can track:
  pods, cpu, memory, requests.cpu, requests.memory,
  limits.cpu, limits.memory
```



---

## Lab Step-by-Step Guide

---

### Step 1: Setup — Create Test Namespace

This demo uses a dedicated namespace to keep quota tests isolated:

```bash
cd 07-resource-quota/src

kubectl create namespace quota-demo
kubectl config set-context --current --namespace=quota-demo
```

Verify:
```bash
kubectl config view --minify | grep namespace
```

**Expected output:**
```
namespace: quota-demo
```

---

### Step 2: Basic Compute and Object Quota — Review

Brief review of Demo 06 concepts before moving to scopes.

**quota-compute.yaml:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
  namespace: quota-demo
spec:
  hard:
    requests.cpu: "2"
    requests.memory: "2Gi"
    limits.cpu: "4"
    limits.memory: "4Gi"
```

**quota-objects.yaml:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: object-quota
  namespace: quota-demo
spec:
  hard:
    pods: "10"
    services: "5"
    persistentvolumeclaims: "4"
    secrets: "10"
    configmaps: "10"
    services.loadbalancers: "0"
    services.nodeports: "0"
```

```bash
kubectl apply -f quota-compute.yaml
kubectl apply -f quota-objects.yaml
kubectl describe quota -n quota-demo
```

**Expected output:**
```
Name:            compute-quota
Namespace:       quota-demo
Resource         Used  Hard
--------         ----  ----
limits.cpu       0     4
limits.memory    0     4Gi
requests.cpu     0     2
requests.memory  0     2Gi

Name:            object-quota
Namespace:       quota-demo
Resource                Used  Hard
--------                ----  ----
configmaps              1     10    ← kube-root-ca.crt counted
persistentvolumeclaims  0     4
pods                    0     10
secrets                 0     10    
services                0     5
services.loadbalancers  0     0
services.nodeports      0     0
```

> Existing namespace objects (kube-root-ca.crt configmap) are already counted against quota.

**Cleanup:**
```bash
kubectl delete -f quota-compute.yaml
kubectl delete -f quota-objects.yaml
```

---

### Step 3: BestEffort Scope

Scope a quota to count ONLY BestEffort pods.

**quota-besteffort.yaml:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: besteffort-quota
  namespace: quota-demo
spec:
  hard:
    pods: "3"
  scopeSelector:
    matchExpressions:
      - scopeName: BestEffort
        operator: Exists
```

```bash
kubectl apply -f quota-besteffort.yaml
kubectl describe quota besteffort-quota -n quota-demo
```

**Expected output:**
```
Name:       besteffort-quota
Namespace:  quota-demo
Scopes:     BestEffort
Resource  Used  Hard
--------  ----  ----
pods      0     3
```

**Test 1 — BestEffort pod → counted:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: besteffort-pod
  namespace: quota-demo
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
EOF

kubectl describe pod -n quota-demo besteffort-pod | grep "QoS Class"
```

**Expected output:**
```
QoS Class:                   BestEffort
```


**Check Quota**

```
kubectl describe quota besteffort-quota -n quota-demo
```

**Expected output:**
```
Resource  Used  Hard
--------  ----  ----
pods      1     3    ← BestEffort pod counted ✅
```

**Test 2 — Guaranteed pod → NOT counted:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: guaranteed-pod
  namespace: quota-demo
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
          cpu: "100m"
          memory: "64Mi"
EOF

kubectl describe pod -n quota-demo guaranteed-pod | grep "QoS Class" 

kubectl describe quota besteffort-quota -n quota-demo
```

**Expected output:**
```
QoS Class:                   Guaranteed

Resource  Used  Hard
--------  ----  ----
pods      1     3    ← still 1 — Guaranteed pod not counted ✅
```

**Cleanup:**
```bash
kubectl delete pod besteffort-pod guaranteed-pod \
  -n quota-demo --grace-period=0 --force
kubectl delete -f quota-besteffort.yaml
```

---

### Step 4: NotBestEffort Scope

Scope a quota to count all pods EXCEPT BestEffort.

**quota-notbesteffort.yaml:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: notbesteffort-quota
  namespace: quota-demo
spec:
  hard:
    pods: "5"
    requests.cpu: "2"
    requests.memory: "2Gi"
  scopeSelector:
    matchExpressions:
      - scopeName: NotBestEffort
        operator: Exists
```

```bash
kubectl apply -f quota-notbesteffort.yaml

kubectl describe quota notbesteffort-quota -n quota-demo
```

**Expected output:**
```
Name:            notbesteffort-quota
Namespace:       quota-demo
Resource         Used  Hard
--------         ----  ----
pods             0     5
requests.cpu     0     2
requests.memory  0     2Gi
```

**Test — one BestEffort and one Burstable pod:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: besteffort-pod
  namespace: quota-demo
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: burstable-pod
  namespace: quota-demo
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
EOF

kubectl describe quota notbesteffort-quota -n quota-demo
```

**Expected output:**
```
Name:            notbesteffort-quota
Namespace:       quota-demo
Resource         Used   Hard
--------         ----   ----
pods             1      5     ← only burstable counted, not besteffort ✅
requests.cpu     100m   2     ← burstable container's  requests.cpu ✅
requests.memory  64Mi   2Gi   ← burstable container's  requests.memory ✅
```

**Cleanup:**
```bash
kubectl delete pod besteffort-pod burstable-pod \
  -n quota-demo --grace-period=0 --force
kubectl delete -f quota-notbesteffort.yaml
```

---

### Step 5: Terminating and NotTerminating Scopes

Separate quotas for batch workloads (Jobs) vs long-running services
(Deployments) — only possible with these scope types.

**quota-terminating.yaml:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: terminating-quota
  namespace: quota-demo
spec:
  hard:
    pods: "5"
    requests.cpu: "1"
    requests.memory: "1Gi"
  scopeSelector:
    matchExpressions:
      - scopeName: Terminating
        operator: Exists
```

**quota-notterminating.yaml:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: notterminating-quota
  namespace: quota-demo
spec:
  hard:
    pods: "10"
    requests.cpu: "4"
    requests.memory: "8Gi"
  scopeSelector:
    matchExpressions:
      - scopeName: NotTerminating
        operator: Exists
```

```bash
kubectl apply -f quota-terminating.yaml
kubectl apply -f quota-notterminating.yaml

kubectl describe quota -n quota-demo notterminating-quota terminating-quota
```

**Expected output:**
```
Name:            notterminating-quota
Namespace:       quota-demo
Resource         Used  Hard
--------         ----  ----
pods             0     10
requests.cpu     0     4
requests.memory  0     8Gi


Name:            terminating-quota
Namespace:       quota-demo
Resource         Used  Hard
--------         ----  ----
pods             0     5
requests.cpu     0     1
requests.memory  0     1Gi
```

**Test — one long-running pod and one terminating pod:**

```bash
# Long-running — no activeDeadlineSeconds → NotTerminating
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: longrunning-pod
  namespace: quota-demo
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: "200m"
          memory: "128Mi"
        limits:
          cpu: "200m"
          memory: "128Mi"
EOF

# Terminating — activeDeadlineSeconds set → Terminating
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: terminating-pod
  namespace: quota-demo
spec:
  terminationGracePeriodSeconds: 0
  activeDeadlineSeconds: 300
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

kubectl describe quota -n quota-demo
```

**Expected output:**
```
Name:            terminating-quota
Scopes:          Terminating
Resource         Used   Hard
--------         ----   ----
pods             1      5     ← terminating-pod counted ✅
requests.cpu     100m   1
requests.memory  64Mi   1Gi

Name:            notterminating-quota
Scopes:          NotTerminating
Resource         Used   Hard
--------         ----   ----
pods             1      10    ← longrunning-pod counted ✅
requests.cpu     200m   4
requests.memory  128Mi  8Gi
```

Each pod counted by exactly one quota — clean separation between
batch and long-running workloads.

**Cleanup:**
```bash
kubectl delete pod longrunning-pod terminating-pod \
  -n quota-demo --grace-period=0 --force
kubectl delete -f quota-terminating.yaml
kubectl delete -f quota-notterminating.yaml
```

---

### Step 6: PriorityClass Scope

Scope a quota to count only pods using a specific PriorityClass.

> Create the required PriorityClasses if not already present:

```bash
kubectl create priorityclass critical --value=100000 --global-default=false
kubectl create priorityclass low --value=100 --global-default=true
```

**quota-priorityclass.yaml:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: critical-quota
  namespace: quota-demo
spec:
  hard:
    pods: "2"
    requests.cpu: "2"
    requests.memory: "2Gi"
  scopeSelector:
    matchExpressions:
      - scopeName: PriorityClass
        operator: In
        values:
          - critical
```

```bash
kubectl apply -f quota-priorityclass.yaml


kubectl describe quota -n quota-demo critical-quota 
```

**Expected output:**
```
Name:            critical-quota
Namespace:       quota-demo
Resource         Used  Hard
--------         ----  ----
pods             0     2
requests.cpu     0     2
requests.memory  0     2Gi
```

**Test 1 — critical pod counted, low pod not counted:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: critical-pod-1
  namespace: quota-demo
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

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: low-pod-1
  namespace: quota-demo
spec:
  terminationGracePeriodSeconds: 0
  priorityClassName: low
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

kubectl describe quota critical-quota -n quota-demo
```

**Expected output:**
```
Resource         Used    Hard
--------         ----    ----
pods             1       2    ← only critical-pod-1 counted ✅
requests.cpu     500m    2
requests.memory  256Mi   2Gi
```

**Test 2 — 3rd critical pod rejected:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: critical-pod-2
  namespace: quota-demo
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

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: critical-pod-3
  namespace: quota-demo
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

Priority abuse prevented ✅

```bash
#Check Quota
kubectl describe quota -n quota-demo critical-quota
```

**Expected output:**
```
Name:            critical-quota
Namespace:       quota-demo
Resource         Used   Hard
--------         ----   ----
pods             2      2
requests.cpu     1      2
requests.memory  512Mi  2Gi
```

**Cleanup:**
```bash
kubectl delete pod critical-pod-1 critical-pod-2 low-pod-1 \
  -n quota-demo --grace-period=0 --force
kubectl delete -f quota-priorityclass.yaml
kubectl delete priorityclass critical low
```

---


### Step 7: Multiple Quotas in One Namespace

Multiple ResourceQuotas coexist in one namespace. A pod must satisfy
ALL applicable quotas — most restrictive wins.

```bash
kubectl apply -f quota-compute.yaml
kubectl apply -f quota-objects.yaml

#Check Quota
kubectl describe quota -n quota-demo
```

```bash
Name:            compute-quota
Namespace:       quota-demo
Resource         Used  Hard
--------         ----  ----
limits.cpu       0     4
limits.memory    0     4Gi
requests.cpu     0     2
requests.memory  0     2Gi


Name:                   object-quota
Namespace:              quota-demo
Resource                Used  Hard
--------                ----  ----
configmaps              1     10
persistentvolumeclaims  0     4
pods                    0     10
secrets                 0     10
services                0     5
services.loadbalancers  0     0
services.nodeports      0     0
```

**Test a pod with a resource request and limit:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: multi-quota-pod
  namespace: quota-demo
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: "500m"
          memory: "256Mi"
        limits:
          cpu: "1"
          memory: "512Mi"
EOF

kubectl describe quota -n quota-demo
```

**Expected output:**
```
Name:            compute-quota
Resource         Used    Hard
--------         ----    ----
limits.cpu       1       4           ← counted here  ✅
limits.memory    512Mi   4Gi         ← counted here  ✅
requests.cpu     500m    2           ← counted here  ✅
requests.memory  256Mi   2Gi         ← counted here  ✅


Name:                   object-quota
Namespace:              quota-demo
Resource                Used  Hard
--------                ----  ----
configmaps              1     10
persistentvolumeclaims  0     4
pods                    1     10      ← counted here too  ✅
secrets                 0     10
services                0     5
services.loadbalancers  0     0
services.nodeports      0     0
```

Pod counted against both quotas simultaneously — all must be satisfied. ✅

**Cleanup:**
```bash
kubectl delete pod multi-quota-pod -n quota-demo --grace-period=0 --force
kubectl delete -f quota-compute.yaml
kubectl delete -f quota-objects.yaml
```

---

### Step 8: Three Quotas in One Namespace


Think of multiple ResourceQuota objects in a single namespace like a series of security checkpoints at an airport. To get to your gate (the Node), you must pass through every checkpoint that applies to you. If a checkpoint doesn't apply to you, you skip it, but you still have to pass the general ones.

In Kubernetes, if multiple quotas exist, they are additive and restrictive. A Pod is only admitted if it satisfies the aggregate of all applicable quotas.

Let's imagine a namespace where we want to strictly control "BestEffort" pods (those with no limits) while still having a "global ceiling" for the whole namespace.

> Create the required PriorityClasses if not already present:

```bash
kubectl create priorityclass critical --value=100000 --global-default=false
```

**Quota A - The "Global Ceiling" (No Scope)**

This applies to every single Pod created in the namespace, regardless of its priority or QoS.

**global-quota.yaml:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: global-quota
  namespace: quota-demo
spec:
  hard:
    pods: "10"
```

**Quota B - The "BestEffort" Sandbox (Scoped)**

This only tracks Pods that have no resource requests/limits defined.

**best-effort-limiter.yaml:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: best-effort-limiter
  namespace: quota-demo
spec:
  hard:
    pods: "4"
  scopeSelector:
    matchExpressions:
    - scopeName: BestEffort
      operator: Exists
```

**Quota C - The "Critical" VIP Lane (Scoped)**

This only tracks Pods assigned the high-priority PriorityClass.

**critical-pods-only.yaml:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: critical-pods-only
  namespace: quota-demo
spec:
  hard:
    pods: "2"
  scopeSelector:
    matchExpressions:
    - scopeName: PriorityClass
      operator: In
      values: ["critical"]
```

```bash
kubectl apply -f global-quota.yaml
kubectl apply -f best-effort-limiter.yaml
kubectl apply -f critical-pods-only.yaml

#Check Quota
kubectl describe quota -n quota-demo
```

```bash
Name:       best-effort-limiter
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        0     4


Name:       critical-pods-only
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        0     2


Name:       global-quota
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        0     10
```

**Test 1 — Create a BestEffort pod:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: besteffort-pod
  namespace: quota-demo
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
EOF

kubectl describe pod -n quota-demo besteffort-pod | grep "QoS Class"
```

**Expected output:**
```
QoS Class:                   BestEffort
```


**Check Quota:**
```
kubectl describe quota -n quota-demo
```

**Expected output:**
```
Name:       best-effort-limiter
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        1     4         ← counted here  ✅


Name:       critical-pods-only
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        0     2


Name:       global-quota
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        1     10        ← counted here  ✅
```

**Test 1 — Results**

- `Check Quota A:` Does the namespace have < 10 pods total? `Yes.` (Proceed)

- `Check Quota B:` Does the namespace have < 4 BestEffort pods? `Yes.` (Proceed)

- `Check Quota C:` Does this Pod have Citical priority? `No.` (Skip this check).

- `Result:` **Pod is Created. It consumes 1 count from Quota A and 1 count from Quota B.**

---

**Test 2 — Create a Guranteed pod with Critical Priority Pod:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: guaranteed-pod
  namespace: quota-demo
spec:
  priorityClassName: critical
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
          cpu: "100m"
          memory: "64Mi"
EOF

kubectl describe pod -n quota-demo guaranteed-pod | grep "QoS Class" 
```
**Expected output:**
```
QoS Class:                   Guaranteed
```

**Check Quota:**
```
kubectl describe quota -n quota-demo
```

**Expected output:**
```
Name:       best-effort-limiter
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        1     4


Name:       critical-pods-only
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        1     2               ← counted here  ✅


Name:       global-quota
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        2     10              ← counted here  ✅
```

**Test 2 — Results**

- `Check Quota A:` Does the namespace have < 10 pods total? `Yes.` (Proceed)

- `Check Quota B:` Does the namespace have < 4 BestEffort pods? No. (Skip this check).

- `Check Quota C:` Does this Pod have Citical priority? Yes. (Proceed)

- `Result:` **Pod is Created. It consumes 1 count from Quota A and 1 count from Quota C.**

---

**Test 3 — Create a Regular pod(Burstable):**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: burstable-pod
  namespace: quota-demo
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
EOF

kubectl describe pod -n quota-demo burstable-pod | grep "QoS Class"
```
**Expected output:**
```
QoS Class:                   Burstable
```

**Check Quota:**
```
kubectl describe quota -n quota-demo
```

**Expected output:**
```
Name:       best-effort-limiter
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        1     4


Name:       critical-pods-only
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        1     2


Name:       global-quota
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        3     10        ← counted here  ✅
```

**Test 3 — Results**

- `Check Quota A:` Does the namespace have < 10 pods total? `Yes.` (Proceed)

- `Check Quota B:` Does the namespace have < 4 BestEffort pods? `No.` (Skip).

- `Check Quota C:` Does this Pod have Citical priority? `No.` (Skip).

- `Result:` **Pod is Created. It only consumes 1 count from Quota A**

---

**Test 4 — Delete pods: Check quota recovered**

```
kubectl delete pod -n quota-demo besteffort-pod guaranteed-pod
```
**Check Quota:**
```
kubectl describe quota -n quota-demo
```

**Expected output:**
```
Name:       best-effort-limiter
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        0     4          ← Decremented by 1 here  ✅


Name:       critical-pods-only
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        0     2         ← Decremented by 1 here  ✅


Name:       global-quota
Namespace:  quota-demo
Resource    Used  Hard
--------    ----  ----
pods        1     10
```

**Test 4 — Results**

- `Result:` **`best-effort-limiter` and `critical-pods-only` quota are recovered by 1 count each**

**Cleanup:**
```bash
kubectl delete pod burstable-pod -n quota-demo --grace-period=0 --force
kubectl delete -f global-quota.yaml
kubectl delete -f best-effort-limiter.yaml
kubectl delete -f critical-pods-only.yaml
kubectl delete priorityclass critical
```

---


### Step 9: Multi-team Namespace Isolation

Real-world pattern — each team gets a dedicated namespace with quota.

```bash
kubectl create namespace team-a
kubectl create namespace team-b
```

**quota-team-a.yaml:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-a-quota
  namespace: team-a
spec:
  hard:
    pods: "10"
    requests.cpu: "4"
    requests.memory: "8Gi"
    limits.cpu: "8"
    limits.memory: "16Gi"
    services: "5"
    persistentvolumeclaims: "5"
```

**quota-team-b.yaml:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-b-quota
  namespace: team-b
spec:
  hard:
    pods: "5"
    requests.cpu: "2"
    requests.memory: "4Gi"
    limits.cpu: "4"
    limits.memory: "8Gi"
    services: "3"
    persistentvolumeclaims: "3"
```

```bash
kubectl apply -f quota-team-a.yaml
kubectl apply -f quota-team-b.yaml
kubectl describe quota -n team-a
kubectl describe quota -n team-b
```

Create resources in team-a and team-b namespaces and Monitor quota usage per namespace separately with jsonpath:

```bash
kubectl get quota team-a-quota -n team-a \
  -o jsonpath='{.status.used}' | python3 -m json.tool

kubectl get quota team-a-quota -n team-a \
  -o jsonpath='{.status.hard}' | python3 -m json.tool
```

**Cleanup:**
```bash
kubectl delete -f quota-team-a.yaml
kubectl delete -f quota-team-b.yaml
kubectl delete namespace team-a team-b
```

---

### Step 9: Final Cleanup

```bash
kubectl config set-context --current --namespace=default
kubectl delete namespace quota-demo
kubectl get quota -n default
```

---

## Common Questions

### Q: Can a pod be counted by multiple quotas simultaneously?

**A:** Yes. If multiple ResourceQuotas exist in a namespace, a pod can
be counted by all applicable quotas simultaneously. The pod must not
violate any of them.

### Q: What is the difference between scopes and scopeSelector?

**A:** `scopes` is the older field accepting a list of scope names
directly. `scopeSelector` is the newer, more flexible field using
`matchExpressions` with operators. Both can be set — a resource must
match both to be counted.

### Q: Does ResourceQuota apply to existing objects?

**A:** No. ResourceQuota only applies at admission time — to new objects
created after the quota is active. Existing objects that exceed the
quota are not deleted or affected.

---

## What You Learned

In this lab, you:
- ✅ Applied all scope types — BestEffort, NotBestEffort, Terminating,
  NotTerminating, PriorityClass
- ✅ Used `scopeSelector` with `matchExpressions` to filter quota targets
- ✅ Applied separate quotas for batch (Terminating) vs long-running
  (NotTerminating) workloads
- ✅ Used PriorityClass scope to prevent priority class abuse
- ✅ Applied multiple quotas in one namespace — all must be satisfied
- ✅ Applied Three Quotas in One Namespace
- ✅ Implemented per-namespace quota for multi-team isolation
- ✅ Monitored quota status using jsonpath

**Key Takeaway:** ResourceQuota is the primary multi-tenancy enforcement
tool in Kubernetes. Scopes allow fine-grained targeting — separate quotas
for batch jobs vs services, per-priority-class limits. Multiple quotas
in one namespace enforce multiple policies simultaneously. Always deploy
ResourceQuota alongside LimitRange in shared clusters.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get quota` | List all ResourceQuotas (short name) |
| `kubectl describe quota <n>` | Show quota status — Used and Hard |
| `kubectl get quota <n> -o jsonpath='{.status.used}'` | Get current usage as JSON |
| `kubectl get quota <n> -o jsonpath='{.status.hard}'` | Get hard limits as JSON |
| `kubectl create quota <n> --hard=cpu=1,memory=1G,pods=10` | Create quota imperatively |
| `kubectl create quota <n> --hard=pods=100 --scopes=BestEffort` | Create scoped quota imperatively |
| `kubectl explain resourcequota.spec.scopeSelector` | Browse scopeSelector field docs |

---

## CKA Certification Tips

✅ **Short name:**
```bash
kubectl get quota
kubectl describe quota <n>
```

✅ **All scope types — memorise:**
```
BestEffort              → BestEffort QoS pods only
NotBestEffort           → non-BestEffort QoS pods
Terminating             → pods with activeDeadlineSeconds set (Jobs)
NotTerminating          → pods without activeDeadlineSeconds (Deployments)
PriorityClass           → pods with specific priority class
CrossNamespacePodAffinity → pods with cross-namespace affinity
```

✅ **Operator rules for scopeSelector:**
```
BestEffort, NotBestEffort,
Terminating, NotTerminating    → Exists only (no values)
PriorityClass                  → In, NotIn, Exists, DoesNotExist
```

✅ **Imperative creation:**
```bash
kubectl create quota my-quota \
  --hard=cpu=1,memory=1G,pods=10,services=5

kubectl create quota besteffort-quota \
  --hard=pods=10 \
  --scopes=BestEffort
```

✅ **Multiple quotas = AND logic — all must be satisfied**

✅ **Quota only applies at admission — not to existing objects**

---

## Troubleshooting

**Pod rejected by quota unexpectedly:**
```bash
kubectl describe quota -n <namespace>
# Check Used vs Hard — which resource is exhausted
# Check Scopes — which quota is matching this pod
kubectl get pod <n> -o jsonpath='{.status.qosClass}' && echo
```

**Quota Used not updating after pod creation:**
```bash
# Quota counts pods in Running/Pending state
# Completed or Failed pods may not be counted
kubectl get pods -n <namespace>
kubectl describe quota <n> -n <namespace>
```

**Cannot delete namespace:**
```bash
kubectl delete all --all -n <namespace>
kubectl delete quota --all -n <namespace>
kubectl delete namespace <namespace>
```