# Resource Management — Requests, Limits, QoS, LimitRange & ResourceQuota

## Lab Overview

Without resource constraints, a single misbehaving pod can consume all CPU
and memory on a node, starving every other workload. This is the **noisy
neighbour problem** — and it is the motivation for everything in this lab.

Kubernetes solves this through a layered resource management model:

- **Requests** — the minimum a container needs, used by the scheduler to
  find an eligible node
- **Limits** — the ceiling a container cannot exceed, enforced by the
  Linux kernel via cgroups
- **QoS Classes** — derived automatically from how requests and limits are
  set, determines eviction priority under memory pressure
- **LimitRange** — namespace-scoped defaults and constraints for any pod
  that does not define its own requests and limits
- **ResourceQuota** — namespace-scoped total cap across all pods combined

**What you'll do:**
- Observe the noisy neighbour problem without resource constraints
- Define requests and limits for CPU and memory
- Observe CPU throttling and memory OOM kill behaviour
- Understand the limit-only shortcut and its effect on scheduling
- Inspect QoS classes on running pods
- Define ephemeral storage limits
- Use pod-level resources (beta in v1.34)
- Create a LimitRange with defaults and min/max enforcement
- Create a ResourceQuota and understand its interaction with LimitRange

## Prerequisites

**Required Software:**
- Minikube multi-node cluster (`3node` profile) — 1 control plane + 2 workers
- kubectl installed and configured
- Text editor (VS Code recommended with Kubernetes extension)

**Knowledge Requirements:**
- Familiarity with Deployments and pod specs
- Understanding of how the scheduler places pods (covered in scheduling demos)

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Define CPU and memory requests and limits for containers
2. ✅ Explain what happens when CPU limit is exceeded (throttle)
3. ✅ Explain what happens when memory limit is exceeded (OOM kill)
4. ✅ Explain the limit-only behaviour — Kubernetes copies limit to request
5. ✅ Identify the QoS class of any running pod
6. ✅ Explain eviction priority under memory pressure
7. ✅ Define ephemeral storage requests and limits
8. ✅ Use pod-level resource specification (v1.34 beta)
9. ✅ Create a LimitRange with defaults, minimum, and maximum
10. ✅ Create a ResourceQuota and explain its interaction with LimitRange

## Directory Structure

```
06-resource-management/
├── README.md                       # This file
└── src/
    ├── noisy-neighbour.yaml        # Deployment without requests/limits
    ├── requests-demo.yaml          # Deployment with requests defined
    ├── cpu-limit.yaml              # Pod with CPU limit — throttle demo
    ├── memory-limit.yaml           # Pod with memory limit — OOM kill demo
    ├── memory-exceed.yaml          # Pod exceeding memory limit — OOM kill
    ├── limit-only.yaml             # Pod with limit but no request
    ├── qos-besteffort.yaml         # Pod with no requests or limits
    ├── qos-burstable.yaml          # Pod with requests != limits
    ├── qos-guaranteed.yaml         # Pod with requests == limits
    ├── ephemeral-storage.yaml      # Pod with ephemeral storage limits
    ├── pod-level-resources.yaml    # Pod-level resource spec (v1.34 beta)
    ├── limit-range.yaml            # LimitRange — defaults and min/max
    └── resource-quota.yaml         # ResourceQuota — namespace total cap
```

---

## Understanding Resource Management

### The Resource Management Stack

```
ResourceQuota        ← namespace total cap (all pods combined)
      ↓
LimitRange           ← per-pod/container defaults and constraints
      ↓
requests / limits    ← per-container specification
      ↓
cgroups              ← Linux kernel enforcement
```

Each layer applies independently. A pod must satisfy all layers.

### Requests vs Limits

```
requests:
  cpu: "500m"        → scheduler uses this to find an eligible node
  memory: "256Mi"    → node must have at least this much free

limits:
  cpu: "1000m"       → Linux kernel throttles at this ceiling
  memory: "512Mi"    → Linux kernel OOM kills if exceeded
```

```
Node eligibility:    based on REQUESTS (not actual usage)
Runtime enforcement: based on LIMITS (via cgroups)
```

### CPU Units

```
1 CPU    = 1 vCPU = 1 core = 1000 millicores
500m     = 0.5 CPU = half a core
250m     = 0.25 CPU = one quarter of a core
100m     = 0.1 CPU = one tenth of a core
```

Millicores (`m`) allow fine-grained CPU allocation. `500m` and `0.5` are
equivalent in the YAML.

### Memory Units

```
Mi  = Mebibytes (1 Mi = 1,048,576 bytes)  — binary, power of 2
Gi  = Gibibytes (1 Gi = 1,073,741,824 bytes)
M   = Megabytes (1 M  = 1,000,000 bytes)  — decimal, power of 10
G   = Gigabytes (1 G  = 1,000,000,000 bytes)

Use Mi and Gi for memory — they are more precise and consistent
```

### Ephemeral Storage

Ephemeral storage is the temporary disk space a pod uses on the node's
local filesystem while it is running. It is not a cache — it is local
disk, and it is gone when the pod is deleted or moved to another node.

Each node has local disk storage used by containers for logs, temporary
files, and writable container layers. This is **ephemeral storage** — it
disappears when the pod is removed.

Ephemeral storage is part of the node's main filesystem (`nodefs`).
Every byte a container writes to its writable layer, logs, or emptyDir
volumes consumes space from `nodefs`.


**What counts as ephemeral storage:**
```
Container writable layer  → any files written inside the container
                            that are not in a mounted volume
Container logs            → stdout/stderr logs stored by kubelet on
                            the node filesystem
emptyDir volumes          → temporary volumes that exist only for the
                            pod's lifetime (unless backed by memory)
```

**Why limits matter:**

A pod that writes large temporary files — log files, downloaded
datasets, build artifacts — can fill the node's disk. A full disk
affects every pod on that node. Ephemeral storage limits prevent one
pod from consuming all available local disk, the same way CPU and
memory limits prevent one pod from starving others.

Without limits, a single container can fill the node's disk, triggering
`nodefs.available` threshold eviction — evicting ALL pods on that node
in QoS order, not just the offending one. Setting
`limits.ephemeral-storage` prevents this by capping each pod's share
before the node-wide threshold is reached.


**How it differs from memory and persistent storage:**
```
Memory             → RAM — for running processes and in-memory data
                     Gone when container restarts

Ephemeral storage  → Local disk — for temporary files, logs, writes
                     Gone when pod is deleted or rescheduled
                     Survives container restarts within the same pod

PersistentVolume   → Network-attached or provisioned disk
                     Survives pod deletion and rescheduling
                     Can follow the pod to a new node
```

**What happens when the limit is exceeded:**

The kubelet evicts the pod — not OOMKilled, but evicted. The pod is
then rescheduled on another node.


### `nodefs` and Ephemeral Storage

Refer Demo 09 , for more info on `nodefs` and related node level eviction signals 

`nodefs` = **node's main filesystem (/var/lib/kubelet)**

```
What counts against nodefs:
  → container writable layers      ← ephemeral storage writes go here
  → container logs                 ← stdout/stderr stored here
  → emptyDir volumes               ← unless backed by memory
  → kubelet data

So:
  limits.ephemeral-storage  → per-pod cap on how much of nodefs a pod can use
  nodefs.available threshold → node-wide cap — when total nodefs free space
                               drops below threshold, kubelet evicts pods
```

```
Container ephemeral storage usage  →  consumes nodefs space
                                       ↓
                          if pod exceeds limits.ephemeral-storage
                                       ↓
                          kubelet evicts THAT pod (container-level)

                          if ALL pods together consume too much nodefs
                          and nodefs.available drops below threshold
                                       ↓
                          kubelet evicts pods in QoS order (node-level)
```

### cgroups — Why the Kernel Enforces Limits, Not Kubernetes

```
Kubernetes (kubelet)
  → instructs container runtime (containerd/CRI-O)
    → container runtime creates a cgroup for each container
      → Linux kernel enforces cgroup boundaries

CPU  limit exceeded → kernel throttles CPU cycles
Memory limit exceeded → kernel OOM kills the process (the container)

The keyword is KERNEL — not kubelet, not kube-controller-manager
```

### Resource Limit Behaviour — What Happens When a Pod Exceeds Its Limit

Understanding what happens when each resource limit is exceeded is
critical for debugging and production incident response. Each resource
type has a different enforcement mechanism:
```
CPU              → compressible resource
                   pod exceeds limit → THROTTLED
                   cgroups reduce CPU time allocated to the container
                   pod slows down but keeps running
                   never killed or evicted for CPU alone

Memory           → incompressible resource
                   pod exceeds limit → container KILLED (OOMKilled)
                   kernel OOM killer sends SIGKILL to the container process
                   exit code 137 typically
                   container restarts based on restartPolicy
                   pod stays on the same node

Ephemeral Storage → incompressible resource
                    pod exceeds limit → POD EVICTED
                    kubelet terminates the entire pod (not just container)
                    pod phase = Failed, Reason = Evicted
                    controller recreates pod on same or different node
```

**Why memory kills the container but ephemeral storage evicts the pod:**
```
Memory    → container-level enforcement
            cgroup kills the specific container that exceeded the limit
            other containers in the pod keep running
            pod can restart the killed container via restartPolicy

Ephemeral → pod-level enforcement
            disk is shared across all containers in the pod
            cannot isolate which container caused the excess
            entire pod must be evicted to reclaim the disk space
```
```
| Resource | Exceeds limit | Mechanism | Pod stays on node? | Recovery |
|---|---|---|---|---|
| CPU | Throttled | cgroups reduce CPU time | ✅ Yes — slows down | Automatic — unthrottled when usage drops |
| Memory | OOMKilled | Kernel kills container | ✅ Yes — container restarts | restartPolicy controls restart |
| Ephemeral Storage | Evicted | Kubelet evicts entire pod | ❌ No — pod recreated | Controller recreates pod |
```

### Metrics-server — How It Works

Metrics-server is a cluster addon component that collects and
aggregates resource metrics pulled from each kubelet. The API server
serves the Metrics API for use by HPA, VPA, and by the kubectl top
command. 

**How Metrics-server collects data:**
```
Metrics-server v0.6.0+  → queries /metrics/resource on each kubelet
                           lightweight — CPU and memory only
                           optimised for autoscaling decisions

Metrics-server < v0.6.0 → queried /stats/summary (older behaviour)

kubectl top             → queries metrics-server → metrics.k8s.io API
                          NOT directly from the kubelet
```

**VPA and HPA both require metrics-server:**
```
HPA → uses metrics.k8s.io API → requires metrics-server ✅
VPA → fetches from metrics.k8s.io API → requires metrics-server ✅
```

The VPA components fetch metrics from the metrics.k8s.io API.
The Metrics Server needs to be launched separately as it is not
deployed by default in most clusters. 

**What Metrics-server does NOT provide:**
```
→ Historical data — point-in-time only
→ Disk or network metrics
→ Long-term storage — use Prometheus for that
→ Not meant for monitoring solutions — for autoscaling only
```

**Installation — minikube:**
```bash
minikube addons enable metrics-server -p 3node
kubectl get deployment metrics-server -n kube-system
```

**Installation — kubeadm:**

To install the latest Metrics Server release from the
components.yaml manifest, run the following command: 
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

**Verify Metrics-server is working:**
```bash
# Check deployment
kubectl get deployment metrics-server -n kube-system

# Verify Metrics API is registered
kubectl get apiservices | grep metrics

# Test
kubectl top node
kubectl top pod -A
```

**Expected output:**
```
# kubectl get apiservices | grep metrics
v1beta1.metrics.k8s.io   kube-system/metrics-server   True   5m

# kubectl top node
NAME        CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
3node       196m         1%       626Mi           4%
3node-m02   1070m        6%       2807Mi          18%
3node-m03   46m          0%       207Mi           1%
```

> The metrics shown are specifically optimized for Kubernetes
> autoscaling decisions. Because of this, the values may not match
> those from standard OS tools like `top`, as the metrics are
> designed to provide a stable signal for autoscalers rather than
> for pinpoint accuracy. 
>
> For more details on node-level resource data and available kubelet proxy APIs,
> refer Demo 09.

---

## Lab Step-by-Step Guide


### Step 1: Enable Metrics Server

The metrics server collects CPU and memory usage from each node's kubelet
(via the built-in cAdvisor component) and exposes it through the Kubernetes
metrics API. Without it, `kubectl top` returns an error.

```bash
minikube addons enable metrics-server -p 3node
```

**Expected output:**
```
* metrics-server is an addon maintained by Kubernetes. For any concerns
  contact minikube on GitHub.
* Starting 'metrics-server' addon...
* The 'metrics-server' addon is enabled
```

Wait ~60 seconds for the metrics server pod to be ready:

```bash
kubectl get pods -n kube-system | grep metrics-server
```

**Expected output:**
```
metrics-server-xxxxxxxxx-aaaaa   1/1   Running   0   60s
```

Verify it is working:

```bash
kubectl top nodes
```

**Expected output:**
```
NAME        CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
3node       150m         3%     900Mi           15%
3node-m02   80m          2%     600Mi           10%
3node-m03   75m          2%     580Mi           10%
```

> Numbers will vary based on what is currently running on your cluster.
> As long as you see values (not an error), metrics server is working.

---

### Step 2: The Noisy Neighbour Problem

Before defining any resource constraints, observe what happens when a
misbehaving pod consumes all available resources.

**noisy-neighbour.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: well-behaved
spec:
  replicas: 2
  selector:
    matchLabels:
      app: well-behaved
  template:
    metadata:
      labels:
        app: well-behaved
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
          # No resources section — no requests, no limits
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: noisy-neighbour
spec:
  replicas: 2
  selector:
    matchLabels:
      app: noisy-neighbour
  template:
    metadata:
      labels:
        app: noisy-neighbour
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: app
          image: polinux/stress
          command: ["stress"]
          args: ["--vm", "1", "--vm-bytes", "512M", "--vm-hang", "1"]
          # No limits — free to consume as much as available
```

```bash
cd 06-resource-management/src

kubectl apply -f noisy-neighbour.yaml

# Wait ~15 seconds for metrics to be collected
kubectl top pods
```

**Expected output (approximate — values will vary):**
```
NAME                              CPU(cores)   MEMORY(bytes)
well-behaved-xxxxxxxxx-aaaaa      1m           1Mi
well-behaved-xxxxxxxxx-bbbbb      1m           1Mi
noisy-neighbour-xxxxxxxxx-ccccc   10m          520Mi
noisy-neighbour-xxxxxxxxx-ddddd   10m          520Mi
```

The noisy-neighbour pods consume hundreds of MiB with no ceiling. In a
real cluster with CPU-intensive workloads, this starvation forces
well-behaved pods into resource contention — slower responses, OOM kills,
or failed scheduling of new pods.

**Cleanup:**
```bash
kubectl delete -f noisy-neighbour.yaml
```

---

### Step 3: Requests — Scheduler Uses These to Find Eligible Nodes

Requests tell the scheduler the **minimum** a container needs. The scheduler
only places a pod on a node that has at least this much **unallocated**
(not necessarily unused) resource available.

> **Important distinction:** The scheduler compares requests against
> **allocated** resources (sum of all pod requests on the node), not
> against actual current usage. A node can be lightly loaded but fully
> allocated — new pods are rejected from it.

**requests-demo.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: requests-demo
spec:
  replicas: 3
  selector:
    matchLabels:
      app: requests-demo
  template:
    metadata:
      labels:
        app: requests-demo
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
          resources:
            requests:
              cpu: "250m"       # scheduler reserves 0.25 CPU per pod
              memory: "64Mi"    # scheduler reserves 64Mi per pod
```

```bash
kubectl apply -f requests-demo.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                            READY   STATUS    NODE
requests-demo-xxxxxxxxx-aaaaa   1/1     Running   3node-m02
requests-demo-xxxxxxxxx-bbbbb   1/1     Running   3node-m03
requests-demo-xxxxxxxxx-ccccc   1/1     Running   3node
```

Now inspect one of the node(where pod runs) to see how requests appear in the allocated resources
section:

```bash
kubectl describe node 3node-m02
```

Scroll to the **Non-terminated Pods:** and **Allocated resources:** section:

**Expected output (excerpt):**
```
Non-terminated Pods:          (4 in total)
  Namespace                   Name                               CPU Requests  CPU Limits  Memory Requests  Memory Limits  Age
  ---------                   ----                               ------------  ----------  ---------------  -------------  ---
  default                     requests-demo-868d49d5f-m2znh      250m (1%)     0 (0%)      64Mi (0%)        0 (0%)         67s
  kube-system                 kindnet-gr5gr                      100m (0%)     100m (0%)   50Mi (0%)        50Mi (0%)      6d20h
  kube-system                 kube-proxy-t4sp5                   0 (0%)        0 (0%)      0 (0%)           0 (0%)         7d
  kube-system                 metrics-server-85b7d694d7-q2tkt    100m (0%)     0 (0%)      200Mi (1%)       0 (0%)         40m
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests    Limits
  --------           --------    ------
  cpu                450m (2%)   100m (0%)
  memory             314Mi (2%)  50Mi (0%)
  ephemeral-storage  0 (0%)      0 (0%)
  hugepages-1Gi      0 (0%)      0 (0%)
  hugepages-2Mi      0 (0%)      0 (0%)
Events:              <none>
```

What the output shows:
```
requests-demo pod    → 250m CPU request, 0 limits (no limit set)
                     → 64Mi memory request, 0 limits (no limit set)
Node allocated total → cpu: 450m requests, 100m limits
                     → memory: 314Mi requests, 50Mi limits
```


> This node also has kube-system pods (kindnet, kube-proxy, metrics-server) in addition to  `requests-demo` pod, all are shown in 
> Non-terminated Pods list. Focus on the
> `requests-demo` pod row and the `Allocated resources` summary at the
> bottom which shows the node-level totals including all pods.

> The `Requests` column in `Allocated resources` shows the total CPU and memory **reserved** by
> all pods on this node. The scheduler uses this number — not actual usage
> — to decide if a new pod fits.

**Cleanup:**
```bash
kubectl delete -f requests-demo.yaml
```

---

### Step 4: CPU Limits — Throttling Demo

CPU limits are enforced by the Linux kernel via cgroups. When a container
tries to use more CPU than its limit, the kernel **throttles** it — the
container keeps running but is slowed down. It is never killed for CPU.

**cpu-limit.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cpu-demo
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: cpu-stress
      image: polinux/stress
      resources:
        requests:
          cpu: "250m"
        limits:
          cpu: "500m"       # ceiling: 0.5 CPU
      command: ["stress"]
      args: ["--cpu", "2"]  # tries to use 2 full CPUs
```

```bash
kubectl apply -f cpu-limit.yaml

# Wait ~15 seconds for metrics to be collected
kubectl top pod cpu-demo
```

**Expected output:**
```
NAME       CPU(cores)   MEMORY(bytes)
cpu-demo   500m         1Mi
```

The pod attempts to use 2 CPUs (2000m) but is throttled at 500m by the
kernel. The pod continues running — CPU throttling never kills a container.

Verify requests and limits on the node:
```bash
╰─ kubectl get pods -o wide       
NAME       READY   STATUS    RESTARTS   AGE     IP           NODE        NOMINATED NODE   READINESS GATES
cpu-demo   1/1     Running   0          6m27s   10.244.2.5   3node-m03   <none>           <none>


╰─ kubectl describe node 3node-m03
Name:               3node-m03
Roles:              <none>
...
...
...
Non-terminated Pods:          (3 in total)
  Namespace                   Name                CPU Requests  CPU Limits  Memory Requests  Memory Limits  Age
  ---------                   ----                ------------  ----------  ---------------  -------------  ---
  default                     cpu-demo            250m (1%)     500m (3%)   0 (0%)           0 (0%)         5m11s
  kube-system                 kindnet-8cbkl       100m (0%)     100m (0%)   50Mi (0%)        50Mi (0%)      7d
  kube-system                 kube-proxy-75brx    0 (0%)        0 (0%)      0 (0%)           0 (0%)         7d1h
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests   Limits
  --------           --------   ------
  cpu                350m (2%)  600m (3%)
  memory             50Mi (0%)  50Mi (0%)
  ephemeral-storage  0 (0%)     0 (0%)
  hugepages-1Gi      0 (0%)     0 (0%)
  hugepages-2Mi      0 (0%)     0 (0%)
Events:              <none>

```

**Key observation on `cpu-demo` pod**:
```
CPU limit set → pod can burst up to 500m
CPU request   → scheduler guaranteed 250m
No memory limits → pod can use node memory freely
```

> CPU throttling is enforced by cgroups at the limit boundary —
> not by actual node utilisation. A pod hitting its CPU limit is
> throttled even if the node has significant free CPU capacity.
> This is by design — limits protect other pods on the same node.

**Cleanup:**
```bash
kubectl delete pod cpu-demo --grace-period=0 --force
```

---

### Step 5: Memory Limits — OOM Kill Demo

Memory limits are also enforced by the Linux kernel via cgroups. Unlike
CPU throttling, exceeding a memory limit results in the container being
**killed** — OOM (Out Of Memory) killed. The kubelet then restarts it,
causing CrashLoopBackOff if the memory demand persists.

First deploy a pod that stays **within** its memory limit:

**memory-limit.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: memory-demo
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: memory-stress
      image: polinux/stress
      resources:
        requests:
          memory: "100Mi"
        limits:
          memory: "200Mi"     # ceiling: 200Mi
      command: ["stress"]
      args: ["--vm", "1", "--vm-bytes", "150M", "--vm-hang", "1"]
      # load: 150M — within the 200Mi limit
```

```bash
kubectl apply -f memory-limit.yaml

# Wait ~15 seconds for metrics to be collected
kubectl top pod memory-demo
```

**Expected output:**
```
NAME          CPU(cores)   MEMORY(bytes)   
memory-demo   167m         150Mi 
```

Pod is running within limits — stable.

Now deploy a pod that **exceeds** its memory limit:

**memory-exceed.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: memory-exceed
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: memory-stress
      image: polinux/stress
      resources:
        requests:
          memory: "100Mi"
        limits:
          memory: "200Mi"     # ceiling: 200Mi
      command: ["stress"]
      args: ["--vm", "1", "--vm-bytes", "250M", "--vm-hang", "1"]
      # load: 250M — EXCEEDS the 200Mi limit
```

```bash
kubectl apply -f memory-exceed.yaml
kubectl get pod memory-exceed -w
```

**Expected output:**
```
NAME             READY   STATUS    RESTARTS
memory-exceed    0/1     OOMKilled  0
memory-exceed    0/1     CrashLoopBackOff  1
memory-exceed    0/1     OOMKilled  2
```

The kernel kills the container the moment it exceeds 200Mi. The kubelet
restarts it, it exceeds the limit again, gets killed again — CrashLoopBackOff.

```bash
kubectl describe pod memory-exceed | grep -A5 "Last State"
```

**Expected output:**
```
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    1
      Started:      ...
      Finished:     ...
    Ready:          False
```


> **Exit Code:** The `stress` tool exits with code 1 when
> killed — it catches the OOM signal and exits with its own error code
> rather than propagating the raw SIGKILL exit code (137). The
> authoritative OOM indicator is `Reason: OOMKilled` — not the exit
> code. Exit code varies by container image and application.

> **Documentation note:** The official Kubernetes docs state containers
> are only OOM killed under node memory pressure. In practice, the Linux
> kernel enforces cgroup memory limits strictly regardless of overall node
> pressure. Most production kernels kill on limit breach — not just during
> node-wide pressure. This is a known documentation gap.

**Cleanup:**
```bash
kubectl delete pod memory-demo memory-exceed --grace-period=0 --force
```

---

### Step 6: Limit Only — No Request Behaviour

If you define a `limit` but no `request`, Kubernetes automatically copies
the limit value and uses it as the request. This has two consequences:

1. The scheduler reserves the full limit amount — potentially wasting
   allocatable capacity if actual usage is much lower
2. The pod gets `Guaranteed` QoS class (covered in Step 8) — which affects
   eviction priority

**limit-only.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: limit-only-demo
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      resources:
        limits:
          cpu: "500m"
          memory: "128Mi"
        # No requests section — Kubernetes will copy limits to requests
```

```bash
kubectl apply -f limit-only.yaml
kubectl describe pod limit-only-demo | grep -A8 "Requests\|Limits"
```

**Expected output:**
```
    Limits:
      cpu:     500m
      memory:  128Mi
    Requests:
      cpu:      500m      ← automatically copied from limits
      memory:   128Mi     ← automatically copied from limits
```

Kubernetes silently set requests equal to limits. The scheduler now
reserves 500m CPU and 128Mi memory on the target node — the same as if
you had explicitly set both. This is often unintentional and leads to
over-reservation in clusters where actual usage is much lower than limits.

**Cleanup:**
```bash
kubectl delete pod limit-only-demo --grace-period=0 --force
```

---

### Step 7: Ephemeral Storage — Requests, Limits and Eviction

Ephemeral storage is the temporary disk space a pod uses on the node's
local filesystem. Like CPU and memory, you can set requests and limits.
When a pod exceeds its ephemeral storage limit, the kubelet evicts it.

**ephemeral-storage.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: disk-hog
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: app
      image: busybox
      command:
        - sh
        - -c
        - |
          dd if=/dev/zero of=/tmp/largefile bs=1M count=600
          sleep 3600
      resources:
        requests:
          ephemeral-storage: "100Mi"             # scheduler reserves 100Mi disk
        limits:
          ephemeral-storage: "500Mi"             # ceiling: 500Mi disk usage
```

**Understanding the `dd` command:**
```
dd if=/dev/zero of=/tmp/largefile bs=1M count=600

dd          → disk/data duplicator — copies data from source to destination

if=/dev/zero → input file = /dev/zero
               a special Linux device that produces an infinite stream
               of zero bytes (null bytes)
               used here as a source of data to write

of=/tmp/largefile → output file = /tmp/largefile
               writes to the container's writable layer (/tmp)
               this counts toward ephemeral storage usage
               /tmp is always available inside any container

bs=1M       → block size = 1 Megabyte
               reads and writes 1MB at a time
               larger block size = faster write speed

count=600   → number of blocks = 600
               total written = 600 × 1MB = 600MB

Result: writes 600MB of zeros to /tmp/largefile
        pod has limits.ephemeral-storage: 500Mi
        600MB > 500Mi → kubelet detects limit exceeded → pod evicted
```
```bash
kubectl apply -f ephemeral-storage.yaml
kubectl get pods -o wide -w
```

**Expected output — watch the eviction happen:**
```
NAME       READY   STATUS              NODE
disk-hog   0/1     ContainerCreating   3node-m02
disk-hog   1/1     Running             3node-m02   ← dd starts writing
disk-hog   0/1     Error               3node-m02   ← evicted after 600MB written
```

**Check the logs — confirm dd completed writing:**
```bash
kubectl logs disk-hog
```

**Expected output:**
```
600+0 records in
600+0 records out
629145600 bytes (600.0MB) copied, 1.152646 seconds, 520.5MB/s
```

**Check eviction event:**
```bash
kubectl get events --sort-by='.lastTimestamp' | grep -i evict
```

**Expected output:**
```
Warning   Evicted   pod/disk-hog
          Pod ephemeral local storage usage exceeds the total limit of containers 500Mi.
```

**Check pod status:**
```bash
kubectl describe pod disk-hog | grep -E "Status:|Reason:|Message:"
```

**Expected output:**
```
Status:   Failed
Reason:   Evicted
Message:  Pod ephemeral local storage usage exceeds the total limit
          of containers 500Mi.
```

**Check Requests/Limits**
```bash
kubectl describe pod disk-hog | grep -A10 "Requests\|Limits"
```

**Expected output:**
```
    Limits:
      ephemeral-storage: 500Mi
    Requests:
      ephemeral-storage: 100Mi
```

**Key observations:**
```
1. dd completed in ~1 second — wrote 600MB at 520MB/s
2. Pod status → Error immediately after dd completed
3. Eviction event shows exact reason — limit exceeded
4. This is container-level enforcement — kubelet detected the pod
   exceeded its own limits.ephemeral-storage limit
5. This is NOT node-level DiskPressure — the node filesystem
   did not run low. Only this pod's limit was exceeded.
```

> **Container-level vs node-level disk eviction:**
> ```
> Container limit exceeded  → only THAT pod is evicted
>                             nodefs.available threshold not involved
>                             node DiskPressure condition stays False
>
> Node DiskPressure         → kubelet evicts pods in QoS order
>                             until node disk recovers above threshold
>                             covered in Demo 09
> ```

> Ephemeral storage limits are enforced by the kubelet (not the kernel
> directly) — the kubelet periodically scans disk usage and evicts pods
> that exceed their limit. Unlike memory, there is no immediate kill —
> there is a scan interval before enforcement.

**Cleanup:**
```bash
kubectl delete pod disk-hog --grace-period=0 --force
```

---

### Step 8: Pod QoS Classes

Kubernetes automatically assigns one of three **Quality of Service** classes
to every pod based on how its requests and limits are configured. The QoS
class determines eviction priority when a node runs low on memory.

```
Guaranteed  → requests == limits for ALL containers (CPU AND memory)
              Highest priority — evicted last
              Also assigned when limit-only (no request) — Kubernetes copies limit to request

Burstable   → at least one container has a request OR a limit defined
              but requests != limits for at least one resource
              Medium priority — evicted after BestEffort

BestEffort  → NO requests AND NO limits defined on ANY container
              Lowest priority — evicted first
```

**Eviction order under memory pressure:**
```
BestEffort → Burstable → Guaranteed
(evicted first)          (evicted last)
```

**qos-besteffort.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: qos-besteffort
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      # No resources section at all
```

**qos-burstable.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: qos-burstable
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
          cpu: "500m"
          memory: "256Mi"   # requests != limits → Burstable
```

**qos-guaranteed.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: qos-guaranteed
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
          cpu: "200m"       # requests == limits for CPU
          memory: "128Mi"   # requests == limits for memory → Guaranteed
```

```bash
kubectl apply -f qos-besteffort.yaml
kubectl apply -f qos-burstable.yaml
kubectl apply -f qos-guaranteed.yaml
```

Verify QoS class on each pod:

```bash
kubectl get pod qos-besteffort -o jsonpath='{.status.qosClass}'
kubectl get pod qos-burstable  -o jsonpath='{.status.qosClass}'
kubectl get pod qos-guaranteed -o jsonpath='{.status.qosClass}'
```

**Expected output:**
```
BestEffort
Burstable
Guaranteed
```

Confirm via describe:

```bash
kubectl describe pod qos-guaranteed | grep "QoS Class"
```

**Expected output:**
```
QoS Class:                   Guaranteed
```

**QoS class rules summary:**

| Rule | QoS Class |
|---|---|
| All containers have no requests AND no limits | BestEffort |
| All containers have requests = limits | Guaranteed |
| All containers have limits only (no requests) — Kubernetes copies limit to request | Guaranteed |
| Any container with requests < limits | Burstable |
| Any container with requests but no limits | Burstable |
| Any mix — BestEffort + Burstable | Burstable |
| Any mix — BestEffort + Guaranteed | Burstable |
| Any mix — Burstable + Guaranteed | Burstable |


**Simplified:**

| Rule | QoS Class |
|---|---|
| ALL containers have no requests AND no limits | BestEffort |
| ALL containers have requests = limits (or limits only — Kubernetes copies limit to request) | Guaranteed |
| Anything else | Burstable |

**Cleanup:**
```bash
kubectl delete pod qos-besteffort qos-burstable qos-guaranteed \
  --grace-period=0 --force
```

---

### Step 9: Pod-Level Resources (v1.34 Beta)

From Kubernetes v1.34, you can define resource requests and limits at the
**pod level** in addition to (or instead of) container level. Pod-level
resources define the total resource budget for the entire pod.

> **Status:** Beta, enabled by default in v1.34. Use in production with
> care — per-container specification is still recommended for precise
> control over individual container resource allocation.

**pod-level-resources.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-level-demo
spec:
  terminationGracePeriodSeconds: 0
  resources:               # ← pod-level resources (v1.34 beta)
    requests:
      cpu: "300m"
      memory: "128Mi"
    limits:
      cpu: "600m"
      memory: "256Mi"
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      # No container-level resources — pod-level applies
    - name: sidecar
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      # Pod-level budget shared across both containers
```

**Check Requests/Limits**

```bash
kubectl apply -f pod-level-resources.yaml
kubectl describe pod pod-level-demo 
```

**Expected output:**
```
    Limits:
      cpu:     600m
      memory:  256Mi
    Requests:
      cpu:     300m
      memory:  128Mi
```


**Check QoS Class**

```bash
kubectl describe pod pod-level-demo | grep "QoS Class"
```

**Expected output:**
```
QoS Class:                   Burstable
```


> **QoS note:** When pod-level resources are set, the QoS class is
> determined by the pod-level values — container-level values (if also
> set) are used for scheduling but QoS is evaluated at pod level.

**Observations:**

- Pod-level resources appear under `Resources:` section — above the `Containers:` section in `kubectl describe` output
- Neither `app` nor `sidecar` container shows individual resource entries — pod-level budget applies to both containers collectively
- The pod-level budget is shared
across ALL containers in the pod. Individual containers can burst within
the pod budget.
- When pod-level resources are set, the QoS class is
determined by the pod-level values
- Here `QoS Class` is `Burstable` — This is since **pod-level requests < limits**: follows the same   QoS rules as container-level resources


**Cleanup:**
```bash
kubectl delete pod pod-level-demo --grace-period=0 --force
```

---

### Step 10: LimitRange — Namespace Defaults and Constraints

A LimitRange is a policy to constrain the resource allocations (limits
and requests) that you can specify for each applicable object kind (such
as Pod or PersistentVolumeClaim) in a namespace. 

Without LimitRange, a developer can create a pod with no resource
constraints — bypassing QoS, overcommitting the node, and affecting
all other pods on it.

**LimitRange does two things:**
```
1. Injects defaults — applies default requests and limits to any
   pod that does not define them (at admission time)

2. Enforces boundaries — rejects pods whose resource values fall
   outside the allowed min/max range
```

> LimitRange validations occur only at Pod admission stage, not on
> running Pods. If you add or modify a LimitRange, the Pods that
> already exist in that namespace continue unchanged. 


**limit-range.yaml:**
```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: resource-limits
  namespace: default
spec:
  limits:
    - type: Container
      default:             # injected as limit when none set
        cpu: "500m"
        memory: "256Mi"
      defaultRequest:      # injected as request when none set
        cpu: "100m"
        memory: "128Mi"
      max:                 # container limit must be ≤ max
        cpu: "2"
        memory: "1Gi"
      min:                 # container request must be ≥ min
        cpu: "50m"
        memory: "32Mi"
```

**Supported `type` values:**
```
Container              → limits applied per container (most common)
Pod                    → limits applied across all containers in a pod combined
PersistentVolumeClaim  → controls storage request size for PVCs
```

**Supported resources per type:**
```
Container / Pod:
  cpu
  memory
  ephemeral-storage

PersistentVolumeClaim:
  storage
```

**LimitRange fields explained:**
```
type            → scope — Container, Pod, or PersistentVolumeClaim

default         → default LIMIT injected when container has no limit set

defaultRequest  → default REQUEST injected when container has no request set

max             → validated directly against container LIMIT
                  container limit must be ≤ max

min             → validated directly against container REQUEST
                  container request must be ≥ min
```

> If max is set but default/defaultRequest are omitted, Kubernetes
> automatically sets both equal to max.

| Field | Applied to | Rule | What happens if field missing |
|---|---|---|---|
| `type` | Scope | Container / Pod / PVC | Required |
| `default` | Container limit | Injected when no limit set | Pod has no limit — unlimited |
| `defaultRequest` | Container request | Injected when no request set | Pod has no request — BestEffort |
| `max` | Container **limit** | limit must be ≤ max | No ceiling enforced |
| `min` | Container **request** | request must be ≥ min | No floor enforced |


> **Indirect effect:** Kubernetes always enforces request ≤ limit.
> Since limit ≤ max, requests cannot exceed max either — but the
> direct LimitRange validation is max → limit, min → request.

```bash
kubectl apply -f limit-range.yaml
kubectl describe limitrange resource-limits
```

**Expected output:**
```
Name:       resource-limits
Namespace:  default
Type        Resource  Min   Max   Default Request  Default Limit
----        --------  ---   ---   ---------------  -------------
Container   cpu       50m   2     100m             500m
Container   memory    32Mi  1Gi   128Mi            256Mi
```

**Test 1 — pod without any resources gets defaults injected:**
```bash
kubectl run default-test --image=busybox -- sh -c "sleep 3600"
kubectl describe pod default-test | grep -A8 "Requests\|Limits"
```

**Expected output:**
```
    Limits:
      cpu:     500m        ← injected from LimitRange default
      memory:  256Mi       ← injected from LimitRange default
    Requests:
      cpu:     100m        ← injected from LimitRange defaultRequest
      memory:  128Mi       ← injected from LimitRange defaultRequest
```

The pod never defined any resources — LimitRange injected them
automatically at admission time before the pod was created.
```bash
kubectl delete pod default-test --grace-period=0 --force
```

**Test 2 — pod below minimum is rejected:**
```bash
apiVersion: v1
kind: Pod
metadata:
  name: below-min
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: "10m"
          memory: "16Mi"
        limits:
          cpu: "10m"
          memory: "16Mi"
EOF
```

**Expected output:**
```
Error from server (Forbidden): pods "below-min" is forbidden:
[minimum memory usage per Container is 32Mi, but request is 16Mi,
 minimum cpu usage per Container is 50m, but request is 10m]
```

`min` validated against REQUEST — confirmed by error message.

**Test 3 — pod above maximum is rejected:**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: above-max
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: "3"
          memory: "2Gi"
        limits:
          cpu: "3"
          memory: "2Gi"
EOF
```

**Expected output:**
```
Error from server (Forbidden): pods "above-max" is forbidden:
[maximum memory usage per Container is 1Gi, but limit is 2Gi,
 maximum cpu usage per Container is 2, but limit is 3]
```

`max` validated against LIMIT — confirmed by error message.

**Test 4 — request above max (no limit set):**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: above-max-req
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: "600m"
          memory: "128Mi"
EOF
```

**Expected output:**
```
The Pod "above-max-req" is invalid:
spec.containers[0].resources.requests: Invalid value: "600m":
must be less than or equal to cpu limit of 500m
```

LimitRange injected `500m` as the default limit. The request `600m`
now exceeds the injected limit — rejected. This confirms the indirect
effect: requests cannot exceed `max` because request ≤ limit ≤ max.

**Cleanup:**
```bash
kubectl delete limitrange resource-limits

kubectl delete pods --all
```

---

### Step 11: ResourceQuota — Namespace Total Cap

A ResourceQuota provides constraints that limit aggregate resource
consumption per namespace. It can limit the quantity of objects that
can be created in a namespace by API kind, as well as the total amount
of infrastructure resources that may be consumed. 
```
LimitRange    → per pod/container ceiling
ResourceQuota → entire namespace total ceiling
```

**What ResourceQuota can constrain:**
```
Compute resources (totals across all pods in namespace):
  requests.cpu        → total CPU requests
  requests.memory     → total memory requests
  limits.cpu          → total CPU limits
  limits.memory       → total memory limits
  requests.ephemeral-storage
  limits.ephemeral-storage

Object count (number of objects of each kind):
  pods                → max number of pods
  services            → max number of services
  secrets             → max number of secrets
  configmaps          → max number of configmaps
  persistentvolumeclaims → max number of PVCs
  services.loadbalancers → max number of LoadBalancer services
  services.nodeports     → max number of NodePort services
  replicationcontrollers
  resourcequotas
```

**resource-quota.yaml:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: namespace-quota
  namespace: default
spec:
  hard:
    requests.cpu: "2"           # total CPU requests across all pods ≤ 2
    requests.memory: "1Gi"      # total memory requests across all pods ≤ 1Gi
    limits.cpu: "4"             # total CPU limits across all pods ≤ 4
    limits.memory: "2Gi"        # total memory limits across all pods ≤ 2Gi
    pods: "10"                  # max pods in namespace ≤ 10
    services: "5"               # max services in namespace ≤ 5
    persistentvolumeclaims: "4" # max PVCs in namespace ≤ 4
```
```bash
kubectl apply -f resource-quota.yaml
kubectl describe resourcequota namespace-quota
```

**Expected output:**
```
Name:                   namespace-quota
Namespace:              default
Resource                Used   Hard
--------                ----   ----
limits.cpu              0      4
limits.memory           0      2Gi
persistentvolumeclaims  0      4
pods                    0      10
requests.cpu            0      2
requests.memory         0      1Gi
services                0      5
```

**Deploy a pod and watch quota consumption:**
```bash
kubectl apply -f qos-burstable.yaml
kubectl describe resourcequota namespace-quota
```

**Expected output:**
```
Resource         Used    Hard
--------         ----    ----
limits.cpu       500m    4
limits.memory    256Mi   2Gi
pods             1       10
requests.cpu     100m    2
requests.memory  64Mi    1Gi
```

**Critical behaviour — ResourceQuota without LimitRange:**

When a ResourceQuota enforcing compute resources is active in a
namespace, every pod must have explicit requests and limits — the
quota admission controller requires them.

If a LimitRange is also active, its defaults are injected before
quota admission runs — pods without resources are accepted because
LimitRange fills in the values automatically.

If NO LimitRange is active, pods without explicit resources are
rejected:
```bash
# No LimitRange — quota active
kubectl run quota-test2 --image=busybox -- sh -c "sleep 3600"
```

**Expected output:**
```
Error from server (Forbidden): pods "quota-test2" is forbidden:
failed quota: namespace-quota:
must specify limits.cpu for: quota-test2;
limits.memory for: quota-test2;
requests.cpu for: quota-test2;
requests.memory for: quota-test2
```
```
ResourceQuota alone    → pods must explicitly define resources
ResourceQuota + LimitRange → LimitRange injects defaults, quota accepts
```

> Best practice: always deploy LimitRange alongside ResourceQuota.
> LimitRange ensures pods without explicit resources still get
> sensible defaults — preventing unexpected quota rejections.


**Cleanup:**
```bash
kubectl delete -f qos-burstable.yaml
kubectl delete resourcequota namespace-quota
kubectl delete limitrange resource-limits
```

---

### Step 12: Final Cleanup

```bash
# Remove all remaining pods and deployments
kubectl delete deployment --all
kubectl delete pod --all

# Disable metrics server if no longer needed
# minikube addons disable metrics-server -p 3node

# Verify clean state
kubectl get all
kubectl get limitrange
kubectl get resourcequota
```

---

## Experiments to Try

1. **Observe scheduler allocation vs actual usage:**
   ```bash
   # Deploy requests-demo.yaml (250m CPU request per pod)
   kubectl apply -f requests-demo.yaml
   # Check allocated vs actual
   kubectl describe node 3node-m02 | grep -A8 "Allocated resources"
   kubectl top node 3node-m02
   # Allocated (requests) may be much higher than actual usage
   # This is intentional — scheduler reserves for worst case
   ```

2. **ResourceQuota for object counts:**
   ```yaml
   spec:
     hard:
       pods: "5"
       services: "3"
       persistentvolumeclaims: "4"
       secrets: "10"
       configmaps: "10"
   # Not just CPU/memory — quota controls any namespace-scoped object count
   ```


3. **LimitRange for Pod type (not just Container):**
   ```yaml
   spec:
     limits:
       - type: Pod          # applies to the whole pod (all containers summed)
         max:
           cpu: "4"
           memory: "4Gi"
       - type: Container    # applies per container
         max:
           cpu: "2"
           memory: "2Gi"
   ```


---

## Common Questions

### Q: What happens if I set requests higher than limits?

**A:** Kubernetes rejects the pod with a validation error. Requests must
always be less than or equal to limits. The relationship is:
`0 ≤ requests ≤ limits`.

### Q: Can a container actually use more than its request but less than its limit?

**A:** Yes — this is the normal operating range for Burstable pods. The
container is guaranteed its request amount. If the node has spare capacity,
it can burst up to the limit. This is the recommended pattern for most
workloads — set requests to the typical usage and limits to the peak.

### Q: Does ResourceQuota apply to existing pods or only new ones?

**A:** ResourceQuota only affects new pod creation. Existing pods that were
running before the quota was created continue running even if they would
violate the quota. Only new pod creation is blocked once the quota is reached.

---

## What You Learned

In this lab, you:
- ✅ Observed the noisy neighbour problem that motivates resource management
- ✅ Defined CPU and memory requests — used by the scheduler for node selection
- ✅ Defined CPU and memory limits — enforced by the Linux kernel via cgroups
- ✅ Observed CPU throttling — container slows but keeps running
- ✅ Observed memory OOM kill — container is killed and restarted
- ✅ Understood the limit-only shortcut — Kubernetes copies limit to request
- ✅ Defined ephemeral storage requests and limits
- ✅ Used pod-level resources (v1.34 beta)
- ✅ Identified QoS classes — BestEffort, Burstable, Guaranteed
- ✅ Understood eviction priority — BestEffort evicted first
- ✅ Created a LimitRange with defaults, minimum, and maximum
- ✅ Created a ResourceQuota and observed the LimitRange interaction gotcha

**Key Takeaway:** Always define requests and limits for every container.
Requests protect the scheduler's placement decisions. Limits protect the
node from runaway containers. QoS class is automatic — it rewards pods
that define precise constraints with higher eviction protection. LimitRange
and ResourceQuota are the administrator's tools to enforce this discipline
namespace-wide.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `minikube addons enable metrics-server -p 3node` | Enable metrics server |
| `kubectl top nodes` | Show CPU and memory usage per node |
| `kubectl top pods` | Show CPU and memory usage per pod |
| `kubectl describe node <n> \| grep -A8 "Allocated resources"` | Show requests vs limits per node |
| `kubectl get pod <n> -o jsonpath='{.status.qosClass}'` | Show QoS class of a pod |
| `kubectl describe limitrange <n>` | Show LimitRange defaults and constraints |
| `kubectl describe resourcequota <n>` | Show quota usage vs hard limits |
| `kubectl api-resources \| grep -E "limitrange\|resourcequota"` | Confirm API resource names |

---

## CKA Certification Tips

✅ **CPU units — know both formats:**
```yaml
cpu: "0.5"     # same as 500m
cpu: "500m"    # millicores — preferred in exam
cpu: "1"       # 1000m = 1 vCPU
```


✅ **QoS class quick check:**
```bash
kubectl get pod <n> -o jsonpath='{.status.qosClass}'
```

✅ **LimitRange default only applies when pod has NO resources defined.**
Once a pod defines any requests or limits, LimitRange defaults are not
injected for that container.

---

## Troubleshooting

**Pod stuck in Pending — resource related?**
```bash
kubectl describe pod <n> | grep -A5 Events
# Look for: "Insufficient cpu" or "Insufficient memory"
# Check node allocation:
kubectl describe node <node> | grep -A8 "Allocated resources"
```

**Pod rejected by LimitRange:**
```bash
# Error message will state which constraint was violated
kubectl describe limitrange <name>
# Adjust pod requests/limits to be within min/max range
```

**Pod rejected by ResourceQuota:**
```bash
kubectl describe resourcequota <name>
# Check Used vs Hard — identify which resource is exhausted
# Either reduce existing pod requests or increase quota
```

