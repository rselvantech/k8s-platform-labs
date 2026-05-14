# Manual Scheduling & Static Pods - Taking Control of Pod Placement

## Lab Overview

This lab explores two mechanisms that bypass the Kubernetes scheduler entirely:
**Manual Scheduling** and **Static Pods**. While the scheduler handles pod
placement automatically in most scenarios, understanding these two techniques
is essential for troubleshooting, node-specific testing, and understanding how
Kubernetes bootstraps its own control plane components.

In this lab you will manually assign a pod to a specific node using `nodeName`,
observe what happens when the node name is wrong, create static pods on both
control plane and worker nodes, and understand how the kubelet manages them
independently of the API server.

**What you'll do:**
- Inspect how the scheduler sets `nodeName` on normal pods
- Manually schedule pods onto specific nodes using `nodeName`
- Observe Pending state caused by an invalid node name
- Explore the static pod manifest directory on the control plane
- Create and delete static pods on both control plane and worker nodes
- Understand mirror pods and why `kubectl delete` does not remove static pods

## Prerequisites

**Required Software:**
- Minikube multi-node cluster (`3node` profile) — 1 control plane + 2 workers
- kubectl installed and configured
- Text editor (VS Code recommended with Kubernetes extension)

**Knowledge Requirements:**
- Understanding of Kubernetes architecture (control plane components)
- Familiarity with `kubectl apply`, `kubectl get`, `kubectl describe`
- Basic YAML syntax

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Manually schedule a pod onto a specific node using `nodeName`
2. ✅ Explain what happens when `nodeName` references a non-existent node
3. ✅ Locate and inspect the static pod manifest directory
4. ✅ Create a static pod on the control plane node
5. ✅ Create a static pod on a worker node
6. ✅ Explain why `kubectl delete` cannot permanently remove a static pod
7. ✅ Correctly delete a static pod by removing its manifest file
8. ✅ Identify mirror pods and explain their purpose

## Directory Structure

```
01-manual-scheduling/
├── README.md                    # This file
└── src/
    ├── manual-pod.yaml          # Pod with nodeName targeting a worker node
    ├── manual-pod-cp.yaml       # Pod with nodeName targeting the control plane
    ├── manual-pod-wrong.yaml    # Pod with an invalid nodeName (Pending demo)
    └── static-pod.yaml          # Static pod manifest (copied onto nodes manually)
```

---

## Understanding Manual Scheduling & Static Pods

### How the Scheduler Normally Works

```
You apply a pod manifest (no nodeName set)
        ↓
API Server stores the pod object
        ↓
Scheduler detects pod has no nodeName
        ↓
Scheduler evaluates all nodes:
  • Resource availability (CPU, memory)
  • Taints & Tolerations
  • Affinity rules
        ↓
Scheduler assigns nodeName to the pod
        ↓
kubelet on that node picks up the pod → creates container
```

### What Manual Scheduling Changes

```
You apply a pod manifest (nodeName already set by YOU)
        ↓
API Server stores the pod object
        ↓
Scheduler is SKIPPED entirely
        ↓
kubelet on the named node picks up the pod → creates container
```

### What Static Pods Change

```
YAML file placed in /etc/kubernetes/manifests/ on a node
        ↓
kubelet on that node detects the file (watches directory continuously)
        ↓
kubelet creates the container directly — no API server, no scheduler
        ↓
kubelet creates a mirror pod in API Server (read-only view)
        ↓
kubectl get pods shows the mirror pod
```

### The Bootstrapping Problem Static Pods Solve

> **Applicable to kubeadm and Minikube clusters** — which is what the CKA exam
> uses. Other distributions (k3s, managed clouds like EKS/GKE/AKS) bootstrap
> the control plane differently.

```
❓ Who scheduled kube-scheduler?
❓ Who scheduled kube-apiserver?
❓ Who scheduled kube-controller-manager?
❓ Who scheduled etcd?

The scheduler didn't exist yet. In a kubeadm/Minikube cluster,
the answer is static pods — the kubelet reads YAML files from
/etc/kubernetes/manifests/ and creates containers directly,
before any control plane component is running.
```

---

## Lab Step-by-Step Guide

---

### Step 1: Inspect Your Cluster

```bash
cd 01-manual-scheduling/src

kubectl get nodes
```

**Expected output:**
```
NAME        STATUS   ROLES           AGE   VERSION
3node       Ready    control-plane   18h   v1.34.0
3node-m02   Ready    <none>          18h   v1.34.0
3node-m03   Ready    <none>          18h   v1.34.0
```

Note the exact node names — you will use them in `nodeName` fields.

---

### Step 2: See How the Scheduler Sets nodeName

Run a normal pod and inspect how the scheduler fills in `nodeName`:

```bash
kubectl run pod-demo --image=busybox -- sh -c "sleep 3600"
kubectl get pod pod-demo -o yaml | grep nodeName
```

**Expected output:**
```
  nodeName: 3node-m02
```

The scheduler assigned this — you did not set it. This is the field manual
scheduling lets you control yourself.

**Cleanup:**
```bash
kubectl delete pod pod-demo
```

---

### Step 3: Manually Schedule a Pod onto a Worker Node

**manual-pod.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-manual
spec:
  nodeName: 3node-m03    # ← you set this, not the scheduler
  containers:
    - name: busybox
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
```

**Key YAML Fields Explained:**

- `nodeName` — goes under `spec`, same level as `containers`
- Value must be an **exact match** of the node name shown in `kubectl get nodes`
- The scheduler is completely bypassed — it never evaluates this pod

```bash
kubectl apply -f manual-pod.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME           READY   STATUS    RESTARTS   AGE   IP            NODE
pod-manual   1/1     Running   0          5s    10.244.2.5    3node-m03
```

Pod is running exactly on the node you specified.

**Cleanup:**
```bash
kubectl delete -f manual-pod.yaml
```

---

### Step 4: Manually Schedule a Pod onto the Control Plane

Minikube does NOT apply the `node-role.kubernetes.io/control-plane:NoSchedule`
taint by default — so `nodeName` alone is sufficient to target the control plane.

**manual-pod-cp.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-manual-cp
spec:
  nodeName: 3node    # ← control plane node
  containers:
    - name: busybox
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f manual-pod-cp.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME              READY   STATUS    RESTARTS   AGE   IP            NODE
pod-manual-cp   1/1     Running   0          5s    10.244.0.8    3node
```

> **Note (kubeadm clusters):** The control plane has
> `node-role.kubernetes.io/control-plane:NoSchedule` taint applied by default.
> To manually schedule onto the control plane in a kubeadm cluster, add a
> matching toleration in your pod spec. Minikube does not apply this taint —
> so this step works without any toleration here.

**Cleanup:**
```bash
kubectl delete -f manual-pod-cp.yaml
```

---

### Step 5: What Happens with a Wrong Node Name

**manual-pod-wrong.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-manual-wrong
spec:
  nodeName: 3node-m03-typo    # node does not exist
  containers:
    - name: busybox
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f manual-pod-wrong.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                 READY   STATUS    RESTARTS   AGE   NODE
pod-manual-wrong   0/1     Pending   0          10s   <none>
```

Pod is created in the API server but stuck in **Pending** — Kubernetes cannot
find the named node.

```bash
kubectl describe pod pod-manual-wrong
```

**Expected output (Events section):**
```
Events:
  Warning  FailedScheduling  ...  0/3 nodes are available: ...
```

> ⚠️ Unlike a normally unschedulable pod where the scheduler reports detailed
> reasons, a manually scheduled pod with a wrong `nodeName` shows minimal
> events — because the scheduler was bypassed entirely. The pod simply waits
> for a node that will never appear.

**Cleanup:**
```bash
kubectl delete -f manual-pod-wrong.yaml
```

---

### Step 6: Explore the Static Pod Manifest Directory

The control plane components (kube-apiserver, kube-scheduler, etc.) are all
static pods. Let's inspect their manifest files on the control plane node.

```bash
minikube ssh -n 3node -p 3node
```

**Inside the node:**
```bash
ls /etc/kubernetes/manifests/
```

**Expected output:**
```
etcd.yaml
kube-apiserver.yaml
kube-controller-manager.yaml
kube-scheduler.yaml
```

These four YAML files are what creates the entire control plane. The kubelet
on this node reads them and keeps these pods running at all times.

Inspect one to confirm it is a standard pod spec:
```bash
sudo cat /etc/kubernetes/manifests/kube-scheduler.yaml | head -20
```

```bash
exit
```

---

### Step 7: Verify Control Plane Static Pods via kubectl

```bash
kubectl get pods -n kube-system
```

**Expected output:**
```
NAME                          READY   STATUS    RESTARTS   AGE
etcd-3node                    1/1     Running   0          18h
kube-apiserver-3node          1/1     Running   0          18h
kube-controller-manager-3node 1/1     Running   0          18h
kube-scheduler-3node          1/1     Running   0          18h
```

**Naming pattern:** `<manifest-file-name>-<node-hostname>`

The node hostname (`3node`) is always appended to the name defined in the
manifest file — this is how you identify static pods.

---

### Step 8: Create a Static Pod on the Control Plane

**static-pod.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-static
spec:
  containers:
    - name: busybox
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
```

> There is no `nodeName` field — static pods run on whichever node holds the
> manifest file. The node is determined by file location, not a YAML field.

```bash
minikube ssh -n 3node -p 3node

cat <<EOF | sudo tee /etc/kubernetes/manifests/pod-static.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-static
spec:
  containers:
    - name: busybox
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
EOF

ls /etc/kubernetes/manifests/

exit
```

**Verify the static pod was created automatically — no kubectl apply needed:**
```bash
kubectl get pods -o wide
```

**Expected output:**
```
NAME                READY   STATUS    RESTARTS   AGE   NODE
pod-static-3node  1/1     Running   0          10s   3node
```

The kubelet detected the new file and created the pod automatically.

---

### Step 9: Understand Mirror Pods

The static pod is visible via `kubectl` because the kubelet created a
**mirror pod** — a read-only object in the API server.

```bash
kubectl get pod pod-static-3node -o yaml | grep mirror
```

**Expected output:**
```
kubernetes.io/config.mirror: <hash-value>
```

This annotation marks it as a mirror pod — a view into the static pod,
not the pod itself. You can read it but cannot modify or permanently delete
it through the API server.

---

### Step 10: Try to Delete the Static Pod via kubectl

```bash
kubectl delete pod pod-static-3node
```

**Expected output:**
```
pod "pod-static-3node" deleted
```

Looks deleted. Check immediately:
```bash
kubectl get pods -o wide
```

**Expected output:**
```
NAME                READY   STATUS    RESTARTS   AGE
pod-static-3node  1/1     Running   0          3s
```

**The pod is back.** What happened:
- `kubectl delete` removed the mirror pod from the API server
- The kubelet detected the manifest file still exists on disk
- kubelet immediately recreated the container and the mirror pod
- The container itself never stopped running

> `kubectl delete` on a static pod only removes the mirror object. The kubelet
> recreates it immediately because the manifest file still exists on disk.

---

### Step 11: Correctly Delete a Static Pod

To truly delete a static pod, remove its manifest file from the node:

```bash
minikube ssh -n 3node -p 3node
rm /etc/kubernetes/manifests/pod-static.yaml
exit
```

```bash
kubectl get pods -o wide
# pod-static-3node no longer appears
```

The kubelet detected the file was removed → stopped the container → removed
the mirror pod. Pod is gone and does not return.

---

### Step 12: Create a Static Pod on a Worker Node

Static pods are not limited to the control plane. Any node can host them.

```bash
minikube ssh -n 3node-m02 -p 3node

# The manifests directory exists but is empty on worker nodes by default
ls /etc/kubernetes/manifests/

cat <<EOF | sudo tee /etc/kubernetes/manifests/pod-static.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-static-worker
spec:
  containers:
    - name: busybox
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
EOF

exit
```

```bash
kubectl get pods -o wide
```

**Expected output:**
```
NAME                            READY   STATUS    NODE
pod-static-worker-3node-m02   1/1     Running   3node-m02
```

Naming confirms: `pod-static-worker` (manifest name) + `3node-m02` (node hostname).

**Cleanup:**
```bash
minikube ssh -n 3node-m02 -p 3node
rm /etc/kubernetes/manifests/pod-static-worker.yaml
exit
```

---

### Step 13: Final Cleanup

```bash
# Verify all pods from this lab are gone
kubectl get pods -o wide

# Verify kube-system only has the original control plane static pods
kubectl get pods -n kube-system
```

---

## Experiments to Try

1. **Modify a static pod manifest and watch it restart:**
   ```bash
   # First recreate the static pod from Step 8, then:
   minikube ssh -n 3node -p 3node
   vi /etc/kubernetes/manifests/pod-static.yaml
   # Change the sleep duration — save and exit
   exit

   kubectl get pods -o wide -w
   # Pod restarts automatically — kubelet detects the file change
   ```

2. **Find staticPodPath from kubelet config:**
   ```bash
   minikube ssh -n 3node -p 3node
   cat /var/lib/kubelet/config.yaml | grep staticPodPath
   exit
   ```
**Note:** `--pod-manifest-path` is the older deprecated flag — in kubeadm and Minikube clusters `staticPodPath` in the kubelet config file is the current standard.

3. **Compare scheduler events — manual vs normal pod:**
   ```bash
   kubectl run normal-pod --image=busybox -- sh -c "sleep 3600"
   kubectl describe pod normal-pod | grep -A5 Events
   # Notice: "Scheduled" event from default-scheduler

   kubectl apply -f manual-pod.yaml
   kubectl describe pod pod-manual | grep -A5 Events
   # Notice: no "Scheduled" event — scheduler was bypassed

   kubectl delete pod normal-pod
   kubectl delete -f manual-pod.yaml
   ```

4. **Same manifest name on two different nodes:**
   ```bash
   # Place pod-static.yaml on both 3node and 3node-m02
   # Each pod gets a unique name from the node hostname suffix:
   # pod-static-3node
   # pod-static-3node-m02
   # Both are visible via kubectl get pods simultaneously
   ```

---

## Common Questions

### Q: Can I change `nodeName` on a running pod?

**A:** No. Pod spec fields are largely immutable after creation. To move a
manually scheduled pod to a different node, delete it and recreate it with
the updated `nodeName`.

### Q: What if the same `nodeName` is specified for two different pods?

**A:** Both pods run on the same node — nothing prevents this. Unlike a
Deployment which spreads pods, manual scheduling does exactly what you tell
it, including stacking all pods on one node.

### Q: Can a static pod be part of a Deployment or ReplicaSet?

**A:** No. Static pods are managed solely by the local kubelet. The controller
manager cannot own or manage static pods. Each static pod is a standalone unit.

### Q: Why does `/etc/kubernetes/manifests/` exist on worker nodes if it is empty?

**A:** The kubelet on every node is configured to watch that directory. On
worker nodes it is empty by default — worker nodes don't need control plane
components. But any manifest placed there will be picked up and run by the
local kubelet.

### Q: Can I edit a static pod using `kubectl edit`?

**A:** You can run `kubectl edit` on the mirror pod, but changes will not
persist — the kubelet overwrites them with the manifest file contents on disk.
To make lasting changes to a static pod, edit the YAML file on the node directly.

---

## What You Learned

In this lab, you:
- ✅ Observed how the scheduler automatically fills `nodeName` on normal pods
- ✅ Manually scheduled pods onto specific nodes using `nodeName` in the pod spec
- ✅ Confirmed that a wrong `nodeName` results in a permanently Pending pod
- ✅ Explored `/etc/kubernetes/manifests/` and saw the control plane static pod definitions
- ✅ Created static pods on both the control plane (`3node`) and a worker node (`3node-m02`)
- ✅ Confirmed that `kubectl delete` cannot permanently remove a static pod
- ✅ Correctly deleted static pods by removing their manifest files from disk
- ✅ Understood mirror pods as read-only API server representations of static pods

**Key Takeaway:** Manual scheduling gives you direct control of pod placement
by setting `nodeName` — the scheduler is bypassed entirely. Static pods give
the kubelet the ability to run pods independently of the API server — which is
how Kubernetes bootstraps its own control plane. Both mechanisms skip the
scheduler, but through completely different paths.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `minikube ssh -n <node> -p 3node` | SSH into a specific minikube node |
| `ls /etc/kubernetes/manifests/` | List static pod manifests on a node |
| `rm /etc/kubernetes/manifests/<file>.yaml` | Delete a static pod (correct method) |
| `cat /var/lib/kubelet/config.yaml \| grep staticPodPath` | Find configured manifest directory |
| `kubectl get pod <n> -o yaml \| grep mirror` | Confirm mirror pod annotation |

---

## CKA Certification Tips

✅ **`nodeName` must be under `spec` — not `metadata`:**
```yaml
spec:              # ← correct level
  nodeName: 3node-m02
  containers:
  - name: ...
```

✅ **Generate pod YAML fast then add `nodeName`:**
```bash
kubectl run mypod --image=busybox --dry-run=client -o yaml \
  -- sh -c "sleep 3600" > pod.yaml
# Add nodeName under spec, then:
kubectl apply -f pod.yaml
```

✅ **Identify static pods quickly:**
```bash
kubectl get pods -n kube-system
# Static pods have node hostname appended: kube-scheduler-<node-name>
# Confirm: kubectl get pod <n> -o yaml | grep config.mirror
```

✅ **Find static pod directory — never assume the path:**
```bash
# On the node
cat /var/lib/kubelet/config.yaml | grep staticPodPath
```

✅ **Never delete static pods via kubectl in the exam** — SSH into the node
and remove the manifest file. `kubectl delete pod` only removes the mirror
and the kubelet recreates it immediately.

✅ **To modify a static pod** — edit the file on disk, not via `kubectl edit`.
The kubelet detects file changes immediately.

✅ **Know the difference — DaemonSet vs Static Pod:**
- DaemonSet → API server managed, supports rolling updates, used for node agents
- Static Pod → kubelet managed, no updates, used for control plane bootstrapping

✅ **Static pods + kubeadm clusters in CKA exam:**
```
node-role.kubernetes.io/control-plane:NoSchedule
```
This taint exists on kubeadm control plane nodes. Add a matching toleration
if you need to manually schedule a pod onto the control plane during the exam.

---

## Troubleshooting

**Pod stuck in Pending after manual scheduling?**
```bash
kubectl describe pod <pod-name>
# Check Events — verify nodeName matches exactly
kubectl get nodes
# Most likely cause: nodeName typo
```

**Static pod not appearing after placing manifest?**
```bash
minikube ssh -n <node> -p 3node

# Verify file is in the correct directory
ls /etc/kubernetes/manifests/

# Verify staticPodPath configured for kubelet
cat /var/lib/kubelet/config.yaml | grep staticPodPath

# Check kubelet logs for manifest errors
sudo journalctl -u kubelet --no-pager | tail -20

exit
```

**Static pod reappearing after `kubectl delete`?**
```bash
# Expected behaviour — remove the manifest file instead
minikube ssh -n <node> -p 3node
rm /etc/kubernetes/manifests/<file>.yaml
exit
```

**General debugging:**
```bash
kubectl describe pod <n>                       # Events and status
kubectl get events --sort-by='.lastTimestamp'  # Cluster-wide events
```
