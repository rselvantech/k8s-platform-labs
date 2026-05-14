# API-initiated Eviction

## Lab Overview

API-initiated eviction is the process by which the Eviction API is used
to create an Eviction object that triggers graceful pod termination.
Unlike node-pressure eviction (Demo 09) — which the kubelet triggers
unilaterally when resources are exhausted — API-initiated eviction is a
policy-controlled operation that respects your PodDisruptionBudgets and
terminationGracePeriodSeconds.

```
API-initiated eviction:
  → triggered by: kubectl drain, direct API call, cluster autoscaler
  → respects PodDisruptionBudget → 429 if budget violated
  → respects terminationGracePeriodSeconds → graceful shutdown
  → like a policy-controlled DELETE on the pod

Node-pressure eviction (Demo 09):
  → triggered by: kubelet detecting resource exhaustion
  → does NOT respect PodDisruptionBudget
  → hard threshold: 0s grace period
```

> **PDB only applies to Eviction API — not to direct deletion:**
> Scaling down a Deployment (`kubectl scale --replicas=2`) uses direct
> pod deletion — it bypasses the Eviction API and PDB entirely.
> PDB does not prevent scale-down operations. PDB only protects against
> voluntary disruptions that go through the Eviction API:
> kubectl drain, direct eviction API calls, and cluster autoscaler.

**Real-world use cases:**
- Node maintenance — drain before OS patching or hardware replacement
- Cluster upgrades — safely evict pods before upgrading kubelet
- Autoscaler scale-down — gracefully remove pods before terminating a node

**What this lab covers:**
- Direct Eviction API call — 200 OK response
- PodDisruptionBudget interaction — 429 response when budget violated
- kubectl drain internals — uses Eviction API under the hood
- Node maintenance workflow — cordon, drain, uncordon
- kubectl drain flags — --ignore-daemonsets, --delete-emptydir-data
- Force drain — --disable-eviction bypasses PDB

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl installed and configured
- curl (for direct API calls)

**Knowledge Requirements:**
- **REQUIRED:** Completion of [10-pod-disruption-budget](../10-pod-disruption-budget/)
- Understanding of PDB — minAvailable, maxUnavailable, Allowed disruptions
- Understanding of kubectl drain basics

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Evict a pod directly using the Eviction API and observe 200 OK
2. ✅ Explain the difference between API eviction and kubectl delete pod
3. ✅ Observe 429 Too Many Requests when PDB budget is exhausted
4. ✅ Perform a complete node maintenance workflow — cordon, drain, uncordon
5. ✅ Explain --ignore-daemonsets and --delete-emptydir-data drain flags
6. ✅ Force drain with --disable-eviction and understand the risk

## Directory Structure

```
11-api-initiated-eviction/
├── README.md                        # This file
└── src/
    ├── web-deployment.yaml          # 3-replica deployment for eviction demo
    └── pdb-minavailable.yaml        # PDB with minAvailable: 2
```

---

## Understanding API-initiated Eviction

### What is an Eviction Object

Using the API to create an Eviction object for a pod is like performing
a policy-controlled DELETE operation on the pod. The API server performs
admission checks against any active PodDisruptionBudget before proceeding.

```
POST /api/v1/namespaces/{ns}/pods/{pod}/eviction

API server checks:
  → Is there a PDB protecting this pod?
  → Would eviction violate the budget?

Response:
  200 OK            → eviction allowed, pod deleted gracefully
  429 Too Many Requests → eviction blocked by PDB — retry later
  500 Internal Error → misconfiguration
```

### kubectl drain vs kubectl delete pod

```
kubectl drain <node>
  → uses Eviction API for every pod on the node
  → respects PodDisruptionBudget
  → respects terminationGracePeriodSeconds
  → returns 429 if PDB violated → retries automatically
  → safe for production node maintenance

kubectl delete pod <name>
  → direct deletion — bypasses Eviction API
  → bypasses PodDisruptionBudget
  → forceful with --grace-period=0
  → never use for node maintenance
```

### Node Maintenance Workflow

```
Step 1: kubectl cordon <node>
        → marks node SchedulingDisabled
        → no new pods scheduled here
        → existing pods keep running

Step 2: kubectl drain <node>
        → evicts all pods via Eviction API
        → respects PDB — waits if budget exhausted
        → pods rescheduled by their controllers on other nodes

Step 3: [perform maintenance — OS patch, hardware replace, kubelet upgrade]

Step 4: kubectl uncordon <node>
        → marks node schedulable again
        → new pods can schedule here
```

### drain Flags

```
--ignore-daemonsets
  → DaemonSet pods are skipped — they cannot be evicted
  → DaemonSet controller would recreate them immediately
  → required on almost every drain

--delete-emptydir-data
  → pods with emptyDir volumes block drain without this flag
  → emptyDir data is lost when pod is evicted — this flag acknowledges that
  → required when pods use emptyDir volumes

--disable-eviction
  → bypasses Eviction API entirely
  → uses direct DELETE — ignores PDB
  → drain completes regardless of budget
  → use ONLY when PDB protection must be overridden
  → risk: may cause application downtime
```

---

## Lab Step-by-Step Guide

---

### Step 1: Deploy Web Application

```bash
cd 11-api-initiated-eviction/src

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
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      terminationGracePeriodSeconds: 30
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
kubectl get pods -o wide
```

**Expected output:**
```
NAME                          READY   STATUS    NODE
web-deploy-xxxxxxxxx-aaaaa    1/1     Running   3node-m02
web-deploy-xxxxxxxxx-bbbbb    1/1     Running   3node-m02
web-deploy-xxxxxxxxx-ccccc    1/1     Running   3node-m03
```

---

### Step 2: Direct Eviction API Call — No PDB

Evict one pod directly using the Eviction API with no PDB active.
This shows the baseline 200 OK response.

```bash
# Get one pod name
POD_NAME=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
echo $POD_NAME

# Start API proxy
kubectl proxy &
PROXY_PID=$!
```

```bash
curl -v -H 'Content-type: application/json' \
  "http://localhost:8001/api/v1/namespaces/default/pods/${POD_NAME}/eviction" \
  -d "{
    \"apiVersion\": \"policy/v1\",
    \"kind\": \"Eviction\",
    \"metadata\": {
      \"name\": \"${POD_NAME}\",
      \"namespace\": \"default\"
    }
  }"
```

**Expected output:**
```
HTTP/1.1 200 OK
...
{
  "kind": "Status",
  "apiVersion": "v1",
  "status": "Success"
}
```

```bash
kubectl get pods -o wide
```

**Expected output:**
```
NAME                          READY   STATUS    NODE
web-deploy-xxxxxxxxx-bbbbb    1/1     Running   3node-m02
web-deploy-xxxxxxxxx-ccccc    1/1     Running   3node-m03
web-deploy-xxxxxxxxx-ddddd    1/1     Running   3node-m02   ← replacement created
```

The evicted pod was terminated gracefully. The Deployment controller
immediately created a replacement pod.

```bash
kill $PROXY_PID
```

---

### Step 3: PDB Active — Observe 429 Response

Create a PDB requiring at least 2 pods available:

**pdb-minavailable.yaml:**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: web
```

```bash
kubectl apply -f pdb-minavailable.yaml
kubectl describe pdb web-pdb
```

**Expected output:**
```
Name:           web-pdb
Min available:  2
Selector:       app=web
Status:
  Allowed disruptions:  1
  Current:              3
  Desired:              2
  Total:                3
```

```
Allowed disruptions = Current(3) - Desired(2) = 1
→ 1 pod can be evicted
```

**Evict one pod — should succeed (1 disruption allowed):**

```bash
kubectl proxy &
PROXY_PID=$!

POD_NAME=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
echo $POD_NAME

curl -v -H 'Content-type: application/json' \
  "http://localhost:8001/api/v1/namespaces/default/pods/${POD_NAME}/eviction" \
  -d "{
    \"apiVersion\": \"policy/v1\",
    \"kind\": \"Eviction\",
    \"metadata\": {
      \"name\": \"${POD_NAME}\",
      \"namespace\": \"default\"
    }
  }"
```

**Expected output:**
```
HTTP/1.1 200 OK   ← eviction allowed ✅
```

Wait for replacement pod to become Running:

```bash
kubectl get pods -o wide
# Wait until 3 pods Running again

# Scale down to make PDB restrictive
kubectl scale deployment web-deploy --replicas=2
kubectl describe pdb web-pdb
```

**Expected output:**
```
Status:
  Allowed disruptions:  0   ← no evictions allowed
  Current:              2
  Desired:              2
  Total:                2
```
```
Allowed disruptions = Current(2) - Desired(2) = 0
→ 0 pod can be evicted
```

**Now try to evict a pod:**

```bash
POD_NAME=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')

curl -v -H 'Content-type: application/json' \
  "http://localhost:8001/api/v1/namespaces/default/pods/${POD_NAME}/eviction" \
  -d "{
    \"apiVersion\": \"policy/v1\",
    \"kind\": \"Eviction\",
    \"metadata\": {
      \"name\": \"${POD_NAME}\",
      \"namespace\": \"default\"
    }
  }"
```

**Expected output when PDB budget is exhausted:**
```
HTTP/1.1 429 Too Many Requests
{
  "kind": "Status",
  "apiVersion": "v1",
  "reason": "TooManyRequests",
  "message": "Cannot evict pod as it would violate the pod's disruption budget."
}
```

```
429 = PDB protecting application ✅
Not an error — the guarantee is working as designed
Retry once budget is restored (evicted pod replacement becomes healthy)
```

```bash

kill $PROXY_PID
```

---

### Step 4: Node Maintenance Workflow — Cordon, Drain, Uncordon

The PDB from Step 3 `web-pdb` is still active and `web-deploy` deployment is still running. This demonstrates a complete
production node maintenance workflow with PDB protection.


```bash
#Check pdb
kubectl describe pdb web-pdb
#Scale up pods to 3
kubectl scale deploy web-deploy --replicas=3
kubectl get pods -o wide    
```

**Step 4a — Cordon the node:**

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

No new pods scheduled on `3node-m02`. Existing pods keep running.

```bash
kubectl get pods -o wide
# All pods still running — cordon only stops NEW scheduling
```

**Expected output:**
```
NAME                         READY   STATUS    RESTARTS   AGE     IP            NODE        NOMINATED NODE   READINESS GATES
web-deploy-6bc4bbd46-k7hcm   1/1     Running   0          2m37s   10.244.2.51   3node-m03   <none>           <none>
web-deploy-6bc4bbd46-pp294   1/1     Running   0          38m     10.244.1.30   3node-m02   <none>           <none>
web-deploy-6bc4bbd46-tl8rh   1/1     Running   0          21m     10.244.2.50   3node-m03   <none>           <none>
```

**Step 4b — Drain the node:**

```bash
kubectl drain 3node-m02 \
  --ignore-daemonsets \
  --delete-emptydir-data
```

**Expected output:**
```
node/3node-m02 already cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/kindnet-gr5gr, kube-system/kube-proxy-t4sp5
evicting pod default/web-deploy-6bc4bbd46-pp294
pod/web-deploy-6bc4bbd46-pp294 evicted
node/3node-m02 drained
```

```bash
kubectl get pods -o wide
```

**Expected output:**
```
NAME                         READY   STATUS    RESTARTS   AGE     IP            NODE        NOMINATED NODE   READINESS GATES
web-deploy-6bc4bbd46-k7hcm   1/1     Running   0          4m58s   10.244.2.51   3node-m03   <none>           <none>
web-deploy-6bc4bbd46-srqf7   1/1     Running   0          40s     10.244.2.52   3node-m03   <none>           <none>
web-deploy-6bc4bbd46-tl8rh   1/1     Running   0          24m     10.244.2.50   3node-m03   <none>           <none>
```

All pods moved to `3node-m03`. Node is safe for maintenance.

> `--ignore-daemonsets` — DaemonSet pods (kindnet, kube-proxy) are
> skipped. They cannot be evicted — DaemonSet controller would
> recreate them immediately.
>
> `--delete-emptydir-data` — pods with emptyDir volumes would block
> drain without this flag. This flag acknowledges emptyDir data loss.

**Step 4c — Maintenance complete, uncordon:**

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

```bash
kubectl get pods -o wide
# Existing pods stay on 3node-m03
# New pods will schedule on 3node-m02 as they are created
```

**Cleanup:**
```bash
kubectl delete -f pdb-minavailable.yaml
```

---

### Step 5: Force Drain — --disable-eviction

Demonstrates what happens when PDB is bypassed. Use only when you
must proceed regardless of application availability guarantees.

```bash
# Recreate PDB
kubectl apply -f pdb-minavailable.yaml
kubectl describe pdb web-pdb

# Scale down to make PDB restrictive
kubectl scale deployment web-deploy --replicas=2
kubectl describe pdb web-pdb
```

**Expected output:**
```
Status:
  Allowed disruptions:  0   ← no evictions allowed
  Current:              2
  Desired:              2
  Total:                2
```

```bash
kubectl get pods -o wide
```

**Expected output:**
```
NAME                         READY   STATUS    RESTARTS   AGE     IP            NODE        NOMINATED NODE   READINESS GATES
web-deploy-6bc4bbd46-k7hcm   1/1     Running   0          7m58s   10.244.2.51   3node-m03   <none>           <none>
web-deploy-6bc4bbd46-tl8rh   1/1     Running   0          27m     10.244.2.50   3node-m03   <none>           <none>
```

**Normal drain — blocked by PDB:**

```bash
kubectl cordon 3node-m03
kubectl drain 3node-m03 --ignore-daemonsets --delete-emptydir-data &
DRAIN_PID=$!
sleep 10
# Drain is hanging — PDB blocking eviction
kill $DRAIN_PID
kubectl uncordon 3node-m03
```
**Expected output:**
```
node/3node-m03 already cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/kindnet-8cbkl, kube-system/kube-proxy-75brx
evicting pod kube-system/metrics-server-85b7d694d7-v7w87
evicting pod default/web-deploy-6bc4bbd46-tl8rh
evicting pod default/web-deploy-6bc4bbd46-k7hcm
error when evicting pods/"web-deploy-6bc4bbd46-tl8rh" -n "default" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
error when evicting pods/"web-deploy-6bc4bbd46-k7hcm" -n "default" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
pod/metrics-server-85b7d694d7-v7w87 evicted
evicting pod default/web-deploy-6bc4bbd46-tl8rh
evicting pod default/web-deploy-6bc4bbd46-k7hcm
error when evicting pods/"web-deploy-6bc4bbd46-k7hcm" -n "default" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
error when evicting pods/"web-deploy-6bc4bbd46-tl8rh" -n "default" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
```

**Drain Failed- All pods running in the same nodes:**
```bash
kubectl get pods -o wide
```

**Expected output:**
```
NAME                         READY   STATUS    RESTARTS   AGE     IP            NODE        NOMINATED NODE   READINESS GATES
web-deploy-6bc4bbd46-k7hcm   1/1     Running   0          7m58s   10.244.2.51   3node-m03   <none>           <none>
web-deploy-6bc4bbd46-tl8rh   1/1     Running   0          27m     10.244.2.50   3node-m03   <none>           <none>
```

**Force drain — bypasses PDB:**

```bash
kubectl cordon 3node-m03
kubectl drain 3node-m03 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --disable-eviction
```

**Expected output:**
```
node/3node-m03 already cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/kindnet-8cbkl, kube-system/kube-proxy-75brx
pod/web-deploy-6bc4bbd46-k7hcm deleted   ← deleted not evicted
pod/web-deploy-6bc4bbd46-tl8rh deleted   ← deleted not evicted
node/3node-m03 drained
```

```
Note: output says "deleted" not "evicted"
→ --disable-eviction uses direct DELETE, bypasses Eviction API and PDB
→ application may have been unavailable during this operation
→ use only in emergency maintenance situations
```

**Check:**
```bash
kubectl get pods -o wide
```

**Expected output:**
```
NAME                         READY   STATUS    RESTARTS   AGE     IP            NODE        NOMINATED NODE   READINESS GATES
web-deploy-6bc4bbd46-8dt5l   1/1     Running   0          77s   10.244.1.38   3node-m02   <none>           <none>
web-deploy-6bc4bbd46-sk2c6   1/1     Running   0          77s   10.244.1.37   3node-m02   <none>           <none>
```

**Cleanup:**
```bash
kubectl uncordon 3node-m03
kubectl scale deployment web-deploy --replicas=3
kubectl delete -f pdb-minavailable.yaml
kubectl delete -f web-deployment.yaml
```

---

### Step 6: Final Cleanup

```bash
kubectl get pdb
kubectl get pods
kubectl get nodes
# All nodes should be Ready with no SchedulingDisabled
```

---

## Common Questions

### Q: What is the difference between kubectl drain and kubectl delete pod?

**A:** `kubectl drain` uses the Eviction API and respects
PodDisruptionBudget — it blocks and retries if eviction would violate
the PDB. `kubectl delete pod` is a direct deletion that bypasses PDB
entirely. Always use `kubectl drain` for node maintenance.

### Q: What does 429 mean?

**A:** 429 Too Many Requests means the Eviction API blocked the
eviction because it would violate the PodDisruptionBudget. This is not
an error — it means the PDB guarantee is working correctly. Retry once
the disruption budget is restored (a previously evicted pod recovers).

### Q: When should I use --disable-eviction?

**A:** Only in emergency situations where you need to proceed with
maintenance regardless of application availability. It bypasses all
PDB protection and could cause downtime. Always try normal drain first
and only escalate to --disable-eviction if absolutely necessary.

### Q: Do pods automatically rebalance after uncordon?

**A:** No. Existing pods stay where they are after uncordon. Only new
pods will schedule on the uncordoned node. To rebalance, you need to
trigger new pod creation — either by scaling up temporarily or by
deleting and recreating pods manually.

---

## What You Learned

In this lab, you:
- ✅ Evicted a pod directly using the Eviction API and observed 200 OK
- ✅ Observed 429 Too Many Requests when PDB budget was exhausted
- ✅ Performed a complete production node maintenance workflow — cordon,
  drain, uncordon — with PDB active throughout
- ✅ Used `--ignore-daemonsets` and `--delete-emptydir-data` drain flags
- ✅ Demonstrated force drain with `--disable-eviction` and understood
  the risk of bypassing PDB

**Key Takeaway:** API-initiated eviction is the safe, policy-controlled
way to evict pods. Always use `kubectl drain` for node maintenance —
it respects PDB and graceful termination. A 429 response means your
PDB is working — not a failure. Use `--disable-eviction` only in
emergencies — it bypasses all availability guarantees.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl cordon <node>` | Mark node unschedulable — existing pods unaffected |
| `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` | Safely drain all pods respecting PDB |
| `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --disable-eviction` | Force drain — bypasses PDB |
| `kubectl uncordon <node>` | Mark node schedulable again |
| `kubectl get pdb` | List all PodDisruptionBudgets |
| `kubectl describe pdb <n>` | Show PDB status including Allowed disruptions |
| `kubectl create pdb <n> --selector=app=<n> --min-available=2` | Create PDB imperatively |
| `kubectl explain pdb.spec` | Browse PDB field docs |

---

## CKA Certification Tips

✅ **Short name:**
```bash
kubectl get pdb
kubectl describe pdb <n>
```

✅ **API eviction response codes:**
```
200 OK                → eviction allowed and processed
429 Too Many Requests → PDB blocked eviction — retry later
500 Internal Error    → misconfiguration
```

✅ **429 = PDB working correctly — not an error**

✅ **Standard drain flags — memorise both:**
```bash
kubectl drain <node> \
  --ignore-daemonsets \     # skip DaemonSet pods
  --delete-emptydir-data    # allow emptyDir data loss
```

✅ **Node maintenance workflow:**
```
1. kubectl cordon <node>     → prevent new scheduling
2. kubectl drain <node>      → evict pods (respects PDB)
3. [perform maintenance]
4. kubectl uncordon <node>   → allow new scheduling
```

✅ **--disable-eviction bypasses PDB — use with caution**

✅ **kubectl drain vs kubectl delete pod:**
```
kubectl drain      → Eviction API → respects PDB → graceful
kubectl delete pod → direct DELETE → bypasses PDB → forceful
```

✅ **PDB API version:**
```yaml
apiVersion: policy/v1   # ← correct
kind: PodDisruptionBudget
```

---

## Troubleshooting

**kubectl drain hangs:**
```bash
kubectl describe pdb <n>
# Check Allowed disruptions — if 0, PDB is blocking
# Option 1: wait for disrupted pods to recover
# Option 2: set unhealthyPodEvictionPolicy: AlwaysAllow (Demo 10)
# Option 3: kubectl drain --disable-eviction (bypasses PDB — use with caution)
```

**429 on direct Eviction API call:**
```bash
kubectl describe pdb <n>
# Check Allowed disruptions — must be > 0 for eviction
# Wait for previously evicted pod replacement to become healthy
kubectl get pods -l <selector>
```

**Pods not rescheduling after uncordon:**
```bash
# Existing pods stay in place after uncordon — this is expected
# Only NEW pods schedule on the uncordoned node
kubectl get pods -o wide
# To force rebalance: delete and let controller recreate
kubectl rollout restart deployment/<n>
```

**Node stuck in SchedulingDisabled after drain:**
```bash
kubectl get nodes
# If node shows SchedulingDisabled after maintenance is complete
kubectl uncordon <node-name>
```