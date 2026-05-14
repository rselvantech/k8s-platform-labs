# Node-pressure Eviction

## Lab Overview

Node-pressure eviction is the process by which the kubelet proactively
terminates pods to reclaim resources on nodes. The kubelet monitors
memory, disk space, and filesystem inodes. When one or more of these
resources reach specific consumption levels, the kubelet terminates
pods to prevent node starvation.

This is fundamentally different from preemption (Demo 08) and
API-initiated eviction (Demo 11):

```
Preemption           → scheduler-driven, at SCHEDULING time
                       high-priority pod needs resources → evicts lower-priority pods

Node-pressure        → kubelet-driven, at RUNTIME
eviction               node is running low on resources → terminates pods
                       does NOT respect PodDisruptionBudget
                       does NOT respect terminationGracePeriodSeconds (hard threshold)

API-initiated        → admin/controller-driven, at RUNTIME
eviction               explicit eviction request via API
                       DOES respect PodDisruptionBudget
                       DOES respect terminationGracePeriodSeconds
```

> ⚠️ **This demo is primarily theory-based.** Node-level memory and
> disk pressure cannot be reliably triggered on a local minikube cluster.
> Steps 1 and 2 are preparatory and observational steps that helps to  explain 
> the eviction theory in steps 3, 4 and 5.
 

**What this lab covers:**
- Eviction signals — what the kubelet monitors
- Hard vs soft eviction thresholds
- How and where thresholds are configured — minikube, kubeadm
- Eviction order — how the kubelet ranks pods for eviction
- QoS class and Priority influence on eviction order
- Memory pressure — eviction sequence and recovery (theory + commands)
- Disk pressure — node-level and container-level (theory + demo)
- OOM killer — kernel-level, separate from kubelet eviction
- Node conditions — MemoryPressure, DiskPressure, PIDPressure


---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl installed and configured
- metrics-server installed (from Demo 06)

**Knowledge Requirements:**
- **REQUIRED:** Completion of [06-resource-management](../06-resource-management/)
- **REQUIRED:** Completion of [07-resource-quota-deep-dive](../07-resource-quota-deep-dive/)
- **REQUIRED:** Completion of [08-priority-preemption](../08-priority-preemption/)
- Understanding of QoS classes (BestEffort, Burstable, Guaranteed)
- Understanding of resource requests and limits


## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain eviction signals and what the kubelet monitors
2. ✅ Explain the difference between hard and soft eviction thresholds
3. ✅ Read and update eviction thresholds from kubelet configuration
4. ✅ Explain eviction order — how QoS class and Priority influence ranking
5. ✅ Explain the full memory pressure eviction and recovery sequence
6. ✅ Explain disk pressure — node-level vs container-level eviction
7. ✅ Understand OOM killer behaviour vs kubelet eviction
8. ✅ Explain why node-pressure eviction does not respect PDB

## Directory Structure
```
09-node-pressure-eviction/
├── README.md                        # This file
└── src/
    ├── besteffort-pod.yaml          # Pod with no requests/limits — evicted first
    ├── burstable-pod.yaml           # Pod with requests < limits — evicted second
    └── guaranteed-pod.yaml          # Pod with requests = limits — evicted last
```

---

## Understanding Node-pressure Eviction

### Eviction Signals

The kubelet uses eviction signals to monitor node resource health.
An eviction signal is the current state of a particular resource:

| Signal | Description |
|---|---|
| `memory.available` | Available memory on the node |
| `nodefs.available` | Available disk space on node's root filesystem |
| `nodefs.inodesFree` | Available inodes on node's root filesystem |
| `imagefs.available` | Available disk space on container image filesystem |
| `imagefs.inodesFree` | Available inodes on container image filesystem |
| `pid.available` | Available process IDs on the node |

Each signal supports either a percentage or a literal value:
```
memory.available < 100Mi   → literal value
memory.available < 10%     → percentage of total node memory
```

---

### Eviction Signals — In Depth

Each eviction signal maps to a specific node-level resource. Understanding
what each signal covers, what consumes it, and how to check its current
value is essential for diagnosing node pressure issues.

| Signal | What it monitors | Default threshold |
|---|---|---|
| `memory.available` | Free node memory | `< 100Mi` |
| `nodefs.available` | Free space on node main filesystem | `< 10%` |
| `nodefs.inodesFree` | Free inodes on node main filesystem | `< 5%` |
| `imagefs.available` | Free space on container image filesystem | `< 15%` |
| `imagefs.inodesFree` | Free inodes on container image filesystem | none |
| `pid.available` | Available process IDs | `< 10%` of allocatable PIDs |

---

#### 1. `memory.available`

**What it is:**
```
Available memory on the node = total memory - memory in use
```

**What consumes it:**
```
→ Running container processes (heap, stack, buffers)
→ Kernel page cache
→ OS processes (kubelet, journald, sshd)
→ kube-system pods (coredns, metrics-server, kindnet)
```

**How to check:**
```bash
minikube ssh -p 3node -n 3node-m02 "free -h"
minikube ssh -p 3node -n 3node-m02 "cat /proc/meminfo | grep -E 'MemTotal|MemFree|MemAvailable'"
kubectl top node 3node-m02
```

**Sample output:**
```
               total    used    free    available
Mem:            15Gi    2.0Gi   3.5Gi   12Gi

Kubelet uses:  available column (~12Gi)
Threshold:     200Mi (Step 1c)
Distance:      12Gi - 200Mi = ~11.8Gi from eviction
```

---

#### 2. `nodefs.available` and `nodefs.inodesFree`

**What it is:**
```
nodefs = node's main filesystem (typically mounted at /)
         where kubelet stores pod logs, volumes, and internal data

nodefs.available  → free disk space on this filesystem
nodefs.inodesFree → free inode slots on this filesystem
```

**What consumes nodefs space — verified from official documentation:**
```
→ Container logs               (stdout/stderr stored by kubelet)
→ emptyDir volumes             (unless backed by memory)
→ Kubelet internal data        (/var/lib/kubelet)
→ ConfigMap and Secret mounts
→ Container image layers       (when no dedicated imagefs configured)
→ Container writable layers    (when no dedicated imagefs configured)
```

**What are Container Image & Writable layer**
```
Container image layers   → the read-only filesystem layers that make up
                           the image (e.g. busybox, nginx base OS files,
                           application binaries). Pulled from a registry
                           and stored on the node by the container runtime.
                           Shared across all containers using the same image.
```
```
Container writable layer → a thin read-write layer added ON TOP of the
                           read-only image layers for each running container.
                           Any file a running container creates or modifies
                           goes into this layer.
                           Unique per container instance — not shared.
                           Deleted when the container is removed.
```

**Simple analogy:**
```
Image layers     → a printed book (read-only, shared by all readers)
Writable layer   → your personal sticky notes on top of the book
                   (unique to you, gone when you return the book)
```

**How to check:**
```bash
# Disk space
minikube ssh -p 3node -n 3node-m02 "df -h /"

# Inodes
minikube ssh -p 3node -n 3node-m02 "df -i /"
```

**Verified output on this cluster:**
```
# df -h /
Filesystem  Size   Used  Avail  Use%  Mounted on
overlay     1007G   35G   921G    4%  /

nodefs.available: 921G free = 91% free
Threshold:        10% free → 91% >> 10% → no pressure

# df -i /
Filesystem    Inodes    IUsed     IFree  IUse%
overlay     65536000   120000  65416000     0%

nodefs.inodesFree: 99.8% free
Threshold:         5% free → 99.8% >> 5% → no pressure
```

---

#### 3. `imagefs.available` and `imagefs.inodesFree`

**What it is:**
```
imagefs = the filesystem where the container runtime stores
          container IMAGE LAYERS on the NODE

          When you apply a manifest → kubelet tells the container
          runtime to pull the image → runtime downloads and stores
          image layers on the node's disk → that storage location
          is imagefs

          This is NODE-level image storage — nothing to do with
          what happens inside a running container
```

**What consumes imagefs space:**
```
→ Container image layers pulled to the node
  (every new image pull adds read-only layers here)
→ Cached images from previous pod runs
  (layers stay cached until explicitly pruned)
```

**Relationship with nodefs — verified on this cluster:**
```
Docker Root Dir: /var/lib/docker  ← on nodefs (same / filesystem)

kubelet stats/summary imagefs:    ← empty — no separate imagefs reported

Conclusion: imagefs = nodefs on this cluster
            Docker stores image layers on the same filesystem as nodefs
            imagefs.available threshold monitors the same / filesystem
            Image layers and container writable layers both on nodefs
```

**How to check:**
```bash
# Where container runtime stores images
minikube ssh -p 3node -n 3node-m02 "docker info | grep 'Docker Root Dir'"

# Image and container disk usage
minikube ssh -p 3node -n 3node-m02 "docker system df"
```

**Verified output on this cluster:**
```
Docker Root Dir: /var/lib/docker

docker system df:
TYPE        TOTAL  ACTIVE    SIZE    RECLAIMABLE
Images         12       5  782.9MB  517.2MB (66%)
Containers     15       8    648B      324B (50%)
Volumes         0       0      0B         0B
```

**# Check if kubelet reports a separate imagefs**
```bash
kubectl proxy &
PROXY_PID=$!
# imagefs and containerFs
curl http://localhost:8001/api/v1/nodes/3node-m02/proxy/stats/summary \
  2>/dev/null | python3 -m json.tool | grep -A8 '"imageFs"\|"containerFs"'
```

**Verified output on this cluster:**
```

            "imageFs": {
                "time": "2026-03-18T06:47:29Z",
                "availableBytes": 988638646272,
                "capacityBytes": 1081101176832,
                "usedBytes": 784660583,
                "inodesFree": 66521478,
                "inodes": 67108864,
                "inodesUsed": 587386
            },
            "containerFs": {
                "time": "2026-03-18T06:47:29Z",
                "availableBytes": 988638646272,
                "capacityBytes": 1081101176832,
                "usedBytes": 784660583,
                "inodesFree": 66521478,
                "inodes": 67108864,
                "inodesUsed": 587386
            }
```
```
kubectl stats/summary imageFs:
  availableBytes:  988,639,137,792  ← identical to nodefs
  capacityBytes: 1,081,101,176,832  ← identical to nodefs
  usedBytes:         784,660,583    (~748Mi used by images)

  imageFs availableBytes = nodefs availableBytes ✅
  → confirms imagefs and nodefs are on the same filesystem
  → no dedicated image disk on this cluster
```

> **When `imagefs` is a separate filesystem (production clusters):**
> Some production clusters configure the container runtime to use a
> dedicated disk for image storage — separate from the node's main
> filesystem. In that case `imagefs` and `nodefs` are monitored
> independently with their own thresholds. On such clusters, container
> image layers and writable layers move to `imagefs`, while logs,
> emptyDir, kubelet data, ConfigMap and Secret mounts remain on `nodefs`.
> This behaviour is based on official documentation definitions and
> has not been verified by live test on a dedicated-imagefs cluster.

>**Summary:**
>```
>                        Default setup    Dedicated imagefs
>                        (nodefs only)    (nodefs + imagefs)
>                        -------------    ------------------
>Image layers            nodefs           imagefs
>Container writable      nodefs           imagefs
>Container logs          nodefs           nodefs
>emptyDir volumes        nodefs           nodefs
>Kubelet internal data   nodefs           nodefs
>ConfigMap/Secret mounts nodefs           nodefs
>```


#### 4. `pid.available`

**What it is:**
```
Available process IDs on the node.
Linux assigns a unique PID to every process and thread.
The kubelet tracks PIDs using its own allocatable limit —
not the kernel's pid_max.
```

**What consumes PIDs:**
```
→ Every container process and thread across all pods
→ OS processes (kubelet, containerd, journald)
→ kube-system pod processes
```

**Why it matters:**
```
If PIDs exhausted → no new processes can start on the node
                  → new containers cannot start
                  → existing containers cannot fork
                  → node becomes unresponsive
```

**How to check:**
```bash
# Kernel OS-level PID maximum
minikube ssh -p 3node -n 3node-m02 "cat /proc/sys/kernel/pid_max"

# Kubelet allocatable PID limit and current usage
kubectl proxy &
PROXY_PID=$!
curl http://localhost:8001/api/v1/nodes/3node-m02/proxy/stats/summary \
  2>/dev/null | python3 -m json.tool | grep -A4 '"rlimit"'
kill $PROXY_PID
```

**Verified output on this cluster:**
```
kernel.pid_max:  4,194,304   ← OS-level ceiling (rarely reached)

kubelet rlimit:
  maxpid:  124,930           ← kubelet allocatable PID limit
  curproc:   1,611           ← current processes across all pods and OS

Usage: 1,611 / 124,930 = 1.3% ← far from eviction threshold

Note: ps aux | wc -l shows only ~29 processes — this is the view
      from INSIDE the minikube SSH session (container-scoped view).
      kubelet curproc = 1,611 is the full node view across all
      containers and OS processes — this is what matters for eviction.
```

> **pid_max vs kubelet maxpid:**
> `kernel.pid_max` (4,194,304) is the OS-level ceiling for all PIDs
> on the system. `kubelet maxpid` (124,930) in the stats/summary
> rlimit field reflects resource limit set for the kubelet process — a 
> separate per-process limit enforced by the OS.
> The `pid.available` eviction signal is calculated from allocatable
> PIDs tracked by the kubelet — not from `kernel.pid_max`.
> For eviction purposes, use `kubectl top` or the stats/summary API
> rather than `kernel.pid_max` which does not reflect what the
> kubelet monitors.

---


### What is `inode`? Why it matter for Kubernetes?

**What is `inode`?**

An inode (index node) is a data structure on a filesystem that stores metadata(File type
,Permissions, size ...) about a file or directory — everything except the file name and its actual content.

**Why inodes matter for Kubernetes?**

Every file and directory on a filesystem consumes one inode
Filesystem has a FIXED number of inodes — set at format time
You can run out of inodes even if disk space is available

```
Example:
  Disk: 100Gi available space
  Inodes: 0 free

  Result: cannot create any new files — filesystem full
          even though disk has space

  This happens when: many small files created
                     many container images cached
                     many log files generated
```

**Kubernetes context:**
```
Each container image layer   → multiple files → multiple inodes consumed
Each pod log file            → 1 inode
Each emptyDir file           → 1 inode
Each secret/configmap mount  → multiple inodes

nodefs.inodesFree < 5%  → kubelet evicts pods to free inodes
imagefs.inodesFree      → same but for image filesystem
```

**Simple analogy:**
```
Disk space  → how much storage space is available (like shelf space)
Inodes      → how many items can be stored (like number of shelf slots)

Running out of disk space  → no room to store more data
Running out of inodes      → no slots left to track more files
                             even if there is physical space available
```

---

### Hard vs Soft Eviction Thresholds

```
Hard threshold  → no grace period
                → kubelet terminates pods IMMEDIATELY (0s grace period)
                → ignores terminationGracePeriodSeconds
                → triggers when resource crosses the threshold

Soft threshold  → has a grace period
                → kubelet waits for eviction-soft-grace-period before evicting
                → respects eviction-max-pod-grace-period
                → allows pods to finish in-flight requests before termination
                → suitable for less urgent resource pressure
```

> The kubelet does not respect your configured PodDisruptionBudget or
> the pod's terminationGracePeriodSeconds when using hard eviction
> thresholds. If you use soft eviction thresholds, the kubelet respects
> your configured eviction-max-pod-grace-period.

---

### How and Where Eviction Thresholds Are Configured

Eviction thresholds are configured in the **kubelet configuration file**
on each node. The kubelet reads this file at startup.
```
Who configures:  Cluster administrator
Where stored:    /var/lib/kubelet/config.yaml on each node
File type:       KubeletConfiguration (kubelet.config.k8s.io/v1beta1)
```

**KubeletConfiguration eviction fields:**
```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
evictionHard:                        # hard thresholds — immediate eviction
  memory.available:  "100Mi"
  nodefs.available:  "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"
evictionSoft:                        # soft thresholds — evict after grace period
  memory.available:  "200Mi"
  nodefs.available:  "15%"
evictionSoftGracePeriod:             # how long to wait before evicting
  memory.available:  "1m30s"
  nodefs.available:  "2m"
evictionMaxPodGracePeriod: 90        # max grace period for soft eviction (seconds)
evictionPressureTransitionPeriod: 5m # how long before node condition changes state
mergeDefaultEvictionSettings: false  # if true — custom values MERGE with defaults
                                     # if false (default) — custom values REPLACE defaults
```

> **Important — `mergeDefaultEvictionSettings`:**
> If you set any evictionHard threshold and this field is false (default),
> ALL other thresholds are set to zero. You must specify ALL threshold values
> when customising, or set `mergeDefaultEvictionSettings: true`.
> Verified from official documentation.

**How to check current eviction threshold configuration:**
```bash
# Via API proxy
kubectl proxy &
curl http://localhost:8001/api/v1/nodes/<node-name>/proxy/configz \
  2>/dev/null | python3 -m json.tool | grep -A10 "eviction"
```

```bash
 curl http://localhost:8001/api/v1/nodes/3node-m02/proxy/configz \ 
  2>/dev/null | python3 -m json.tool | grep -A10 "eviction"

        "evictionHard": {
            "imagefs.available": "15%",
            "memory.available": "200Mi",
            "nodefs.available": "10%",
            "nodefs.inodesFree": "5%"
        },
        "evictionPressureTransitionPeriod": "5m0s",
        "mergeDefaultEvictionSettings": false,
        "enableControllerAttachDetach": true,
        "makeIPTablesUtilChains": true,
        "iptablesMasqueradeBit": 14,
        "iptablesDropBit": 15,
        "failSwapOn": false,
        "memorySwap": {},
        "containerLogMaxSize": "10Mi",
        "containerLogMaxFiles": 5,
        "containerLogMaxWorkers": 1,
```
---

### Kubelet Proxy APIs — Node-level Inspection

The kubelet exposes HTTP endpoints accessible via `kubectl proxy`.
These APIs provide direct access to node-level configuration and
real-time resource data — useful for troubleshooting eviction issues,
auditing cluster configuration, and diagnosing node pressure.

**How to access:**
```bash
# Start proxy
kubectl proxy &
PROXY_PID=$!

# Query any endpoint
curl http://localhost:8001/api/v1/nodes/<node-name>/proxy/<endpoint> \
  2>/dev/null | python3 -m json.tool

# Stop proxy
kill $PROXY_PID
```

**Available endpoints:**

| Endpoint | What it returns | When to use |
|---|---|---|
| `/proxy/configz` | Full kubelet configuration | Audit eviction thresholds, verify cgroupDriver, maxPods, podPidsLimit |
| `/proxy/stats/summary` | Real-time resource usage per node, pod, container, volume | Diagnose pod-level disk/memory usage, check imagefs vs nodefs |
| `/proxy/metrics` | Prometheus-format kubelet internal metrics | Feed into Prometheus for kubelet health monitoring |
| `/proxy/metrics/resource` | CPU and memory usage per node and pod | Used by metrics-server v0.6.0+ — powers kubectl top |
| `/proxy/metrics/cadvisor` | Prometheus-format container-level resource metrics (CPU, memory, disk, network) | Granular per-container usage — scraped by Prometheus directly |
| `/proxy/metrics/probes` | Readiness, liveness and startup probe success/failure metrics | Diagnose probe failures at scale |
| `/proxy/pods` | All pods currently running on the node | Verify pod placement, cross-check with API server |
| `/proxy/healthz` | Kubelet health status | Quick node health check |
| `/proxy/spec` | Node hardware spec (CPU model, memory, OS) | Verify node capacity and hardware details |


**Can these APIs be used in production?**

Yes — they require authenticated access which `kubectl proxy` provides
using your kubeconfig credentials. They are read-only and safe to use
for troubleshooting. 

Some of the use cases are:
```
Monitoring systems (Prometheus)  → scrape /proxy/metrics directly
Node debugging                   → /proxy/stats/summary and /proxy/configz
Configuration auditing           → /proxy/configz across all nodes
```

**1. kubelet configz API — what it shows and when to use it:**


```bash
kubectl proxy &
PROXY_PID=$!

curl http://localhost:8001/api/v1/nodes/3node-m02/proxy/configz \ 
  2>/dev/null | python3 -m json.tool

kill $PROXY_PID
```

```bash
#Get eviction threshold for all nodes
  kubectl get nodes -o name | while read node; do
    echo "=== $node ==="
    curl http://localhost:8001/api/v1/$node/proxy/configz \
      2>/dev/null | python3 -m json.tool | grep -A6 "eviction"
  done
```

This endpoint returns the full kubelet configuration for a node.
Use it to audit eviction thresholds, verify cgroupDriver, maxPods,
and podPidsLimit settings across nodes.

**Key fields from `/proxy/configz` verified on this cluster:**
```json
"evictionHard": {
    "imagefs.available": "15%",
    "memory.available": "200Mi",
    "nodefs.available": "10%",
    "nodefs.inodesFree": "5%"
},
"evictionPressureTransitionPeriod": "5m0s",
"mergeDefaultEvictionSettings": false,
"podPidsLimit": -1,
"maxPods": 110,
"cgroupDriver": "systemd",
"cgroupsPerQOS": true,
"containerLogMaxSize": "10Mi",
"containerLogMaxFiles": 5
```

> `podPidsLimit: -1` means no per-pod PID limit is configured on this
> cluster. Each pod can use as many PIDs as the node allows.


**2. kubelet stats/summary API — what it shows and when to use it:**
```bash
kubectl proxy &
PROXY_PID=$!
curl http://localhost:8001/api/v1/nodes/3node-m02/proxy/stats/summary \
  2>/dev/null | python3 -m json.tool
kill $PROXY_PID
```

This endpoint returns real-time resource usage for every node, system
component, and pod — directly from the kubelet. It is the same data
source that `kubectl top` uses.

**What the output contains:**
```
node.fs                    → nodefs: available, capacity, used, inodes
node.runtime.imageFs       → imagefs: available, capacity, used, inodes
node.runtime.containerFs   → container writable layer filesystem
node.memory                → node memory usage
node.rlimit.maxpid         → maximum PIDs allowed
node.rlimit.curproc        → current running processes

per pod:
  ephemeral-storage        → pod total ephemeral storage usage
  containers[].rootfs      → container writable layer usage
  containers[].logs        → container log file usage
  volume[]                 → per-volume usage
  memory                   → pod memory usage
```

**Verified from this cluster's output:**
```
node.fs (nodefs):
  availableBytes:  988,639,137,792  (~920Gi free)
  capacityBytes: 1,081,101,176,832  (~1007Gi total)
  inodesFree:       66,521,478
  inodes:           67,108,864

node.runtime.imageFs:
  availableBytes:  988,639,137,792  ← same as nodefs ✅
  capacityBytes: 1,081,101,176,832  ← same as nodefs ✅
  usedBytes:         784,660,583    (~748Mi used by images)

node.runtime.containerFs:
  availableBytes:  988,639,137,792  ← same as nodefs ✅
  → confirms all three (nodefs, imagefs, containerFs)
    are on the same filesystem on this cluster

node.rlimit:
  maxpid:  124,930   ← PID limit
  curproc:   1,603   ← current processes (1.3% of limit)

burstable-pod ephemeral-storage:
  usedBytes: 12,288  ← 12Ki used (just the container layer)
```

**When to use this command:**
```
→ Diagnosing which pod is consuming the most ephemeral storage
→ Checking if imagefs is separate from nodefs on a cluster
→ Finding actual node memory available vs what kubelet sees
→ Identifying PID pressure before it becomes critical
→ Investigating unexplained evictions — check per-pod usage
→ Cross-checking kubectl top output with raw kubelet data
```

**Useful filtered queries:**
```bash
# Node filesystem summary only
curl http://localhost:8001/api/v1/nodes/3node-m02/proxy/stats/summary \
  2>/dev/null | python3 -m json.tool | grep -A8 '"fs"'

# imagefs and containerFs
curl http://localhost:8001/api/v1/nodes/3node-m02/proxy/stats/summary \
  2>/dev/null | python3 -m json.tool | grep -A8 '"imageFs"\|"containerFs"'

# Per-pod ephemeral storage usage
curl http://localhost:8001/api/v1/nodes/3node-m02/proxy/stats/summary \
  2>/dev/null | python3 -m json.tool | grep -B5 '"ephemeral-storage"'

# PID usage
curl http://localhost:8001/api/v1/nodes/3node-m02/proxy/stats/summary \
  2>/dev/null | python3 -m json.tool | grep -A4 '"rlimit"'
```

### How to Change Thresholds — By Cluster Type

#### Minikube

### How to Change Thresholds — Minikube

Edit `/var/lib/kubelet/config.yaml` directly on each node via the
script in Step 1c. This is the only reliable method on modern
Kubernetes versions where kubelet configuration is file-based rather
than flag-based.

```bash
# SSH into the node
minikube ssh -p 3node -n 3node-m02

# Edit kubelet config
sudo vi /var/lib/kubelet/config.yaml
# Change evictionHard values

# Restart kubelet
sudo systemctl restart kubelet
exit
```

**Verify change applied:**
```bash
kubectl proxy &
curl http://localhost:8001/api/v1/nodes/3node-m02/proxy/configz \
  2>/dev/null | python3 -m json.tool | grep -A8 "eviction"
```

#### kubeadm Clusters

When you call kubeadm init, the kubelet configuration is marshalled to disk at `/var/lib/kubelet/config.yaml`, and also uploaded to a `kubelet-config` ConfigMap in the kube-system namespace of the cluster. 

**Option A — patch the kubelet-config ConfigMap (applies to new nodes):**
```bash
kubectl edit configmap kubelet-config -n kube-system
# Edit the KubeletConfiguration section
# Add evictionHard values
```

**Option B — edit directly on each node:**
```bash
# On each node
sudo vi /var/lib/kubelet/config.yaml
# Add or modify evictionHard section
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

**Verify:**
```bash
kubectl describe node <node-name> | grep -E "MemoryPressure|DiskPressure"
kubectl proxy &
curl http://localhost:8001/api/v1/nodes/<node-name>/proxy/configz \
  2>/dev/null | python3 -m json.tool | grep -A8 "eviction"
```

---

### Eviction Order — How the Kubelet Ranks Pods

When the kubelet needs to evict pods, it ranks them in the following
order (evicted first to last):

```
1. BestEffort pods exceeding no requests (always first)
   → No requests set — guaranteed nothing — evicted first

2. Burstable pods where usage EXCEEDS requests
   → Consuming more than their guaranteed share

3. Guaranteed pods and Burstable pods where usage < requests
   → Evicted last — based on Priority

Within each tier, pods are ranked by:
  → Priority value (lower priority evicted first)
  → How much their usage exceeds requests
```

> The kubelet does not use the pod's QoS class to determine the
> eviction order directly. You can use the QoS class to estimate
> the most likely pod eviction order. QoS classification does not
> apply to EphemeralStorage requests.

**Verified from official documentation:**
```
BestEffort or Burstable pods where usage exceeds requests
→ evicted based on Priority then by how much usage exceeds request

Guaranteed pods and Burstable pods where usage < requests
→ evicted last, based on Priority
```

---

### QoS and Memory Pressure Taints

When a node experiences MemoryPressure, the control plane adds the
taint `node.kubernetes.io/memory-pressure`. Kubernetes also
automatically adds the `node.kubernetes.io/memory-pressure` toleration
to pods that have a QoS class other than BestEffort — meaning
Guaranteed and Burstable pods tolerate the memory pressure taint
and are not immediately prevented from scheduling on the node.
BestEffort pods are not scheduled onto the affected node.

---

### OOM Killer vs Kubelet Eviction

These are two separate mechanisms:

```
Kubelet eviction   → proactive, before node runs out of memory
                     kubelet monitors thresholds and evicts before OOM
                     sets pod phase to Failed
                     controller recreates the pod

OOM killer         → reactive, kernel-level
                     triggered when node actually runs out of memory
                     kills the container process directly
                     container is OOM killed (exit code 137 typically)
                     kubelet can restart based on restartPolicy
```

The kubelet sets an `oom_score_adj` value for each container based on
QoS class:

```
BestEffort  → oom_score_adj = 1000  (killed first by OOM killer)
Burstable   → oom_score_adj = 2-999 (proportional to memory usage vs request)
Guaranteed  → oom_score_adj = -998  (protected — killed last)
```

Containers in pods with `system-node-critical` priority get
`oom_score_adj = -997`.

---

## Lab Step-by-Step Guide


### Step 1: Inspect Default Eviction Thresholds

**Step 1a — Check nodes status:**

```bash
cd 08-node-pressure-eviction/src

# Check node conditions — normal state
kubectl describe nodes | grep -E "Name:|MemoryPressure|DiskPressure|PIDPressure"
```

**Expected output:**
```
Name:               3node
MemoryPressure     False   ...   KubeletHasSufficientMemory
DiskPressure       False   ...   KubeletHasNoDiskPressure
PIDPressure        False   ...   KubeletHasSufficientPID
Name:               3node-m02
MemoryPressure     False   ...
DiskPressure       False   ...
PIDPressure        False   ...
Name:               3node-m03
MemoryPressure     False   ...
DiskPressure       False   ...
PIDPressure        False   ...
```

All conditions False = node is healthy, no pressure.

Check node allocatable resources:

```bash
kubectl describe node 3node-m02 | grep -A6 "Allocatable:"
```

**Expected output:**
```
Allocatable:
  cpu:                16
  ephemeral-storage:  1055762868Ki
  memory:             16001216Ki
  pods:               110
```

> On minikube with WSL2, nodes share the host machine's resources.
> Actual available memory depends on your host configuration.


**Step 1b — Check minikube threshold values:**
```bash
kubectl proxy &
PROXY_PID=$!

curl http://localhost:8001/api/v1/nodes/3node-m02/proxy/configz \
  2>/dev/null | python3 -m json.tool | grep -A8 "eviction"
```

**Expected output on minikube:**
```json
"evictionHard": {
    "imagefs.available": "0%",
    "nodefs.available": "0%",
    "nodefs.inodesFree": "0%"
},
"evictionPressureTransitionPeriod": "5m0s",
"mergeDefaultEvictionSettings": false,
```

> **Why minikube sets 0%:** Minikube deliberately disables disk eviction
> thresholds to prevent evictions on developer machines where disk space
> is shared with the host OS. `0%` means the threshold is never crossed.
>
> `memory.available` is not listed — the built-in default of `100Mi`
> is used. Memory eviction is still active.
>
> `mergeDefaultEvictionSettings: false` — if you set any threshold,
> ALL others are zeroed unless you specify them all.


**Step 1c — Update eviction thresholds in minikube**

#### Create the script locally
```bash
cat > /tmp/update-eviction.sh << 'EOF'
#!/bin/bash
sed -i '/^evictionHard:/,/^[^ ]/{ /^evictionHard:/{ n; d }; /^  /d }' /var/lib/kubelet/config.yaml
cat >> /var/lib/kubelet/config.yaml << 'INNER'
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"
INNER
systemctl restart kubelet
echo "updated"
EOF
```
#### Copy and run on each node
```bash
for node in 3node-m02 3node-m03; do
  minikube cp /tmp/update-eviction.sh $node:/tmp/update-eviction.sh -p 3node
  minikube ssh -p 3node -n $node -- sudo bash /tmp/update-eviction.sh
  echo "$node done"
done
```

Wait for nodes to be Ready:
```bash
kubectl get nodes
```

Verify:
```bash
kubectl proxy &
PROXY_PID=$!
curl http://localhost:8001/api/v1/nodes/3node-m02/proxy/configz \
  2>/dev/null | python3 -m json.tool | grep -A6 "evictionHard"
kill $PROXY_PID
```

**Expected output:**
```json
"evictionHard": {
    "imagefs.available": "15%",
    "memory.available": "200Mi",
    "nodefs.available": "10%",
    "nodefs.inodesFree": "5%"
},
```
> These changes are not persistent across `minikube stop/start`.
> Re-run the script if you restart the cluster.

### Step 2: Deploy Pods of Each QoS Class

Deploy one pod of each QoS class on the same node. This gives a
concrete reference point for the eviction order theory in Step 3 —
you can see exactly which pods would be at risk and in what order.


**besteffort-pod.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: besteffort-pod
  labels:
    qos: besteffort
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      # No requests or limits → BestEffort
```

**burstable-pod.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: burstable-pod
  labels:
    qos: burstable
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          memory: "64Mi"
          cpu: "100m"
        limits:
          memory: "256Mi"
          cpu: "500m"
```

**guaranteed-pod.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: guaranteed-pod
  labels:
    qos: guaranteed
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          memory: "128Mi"
          cpu: "250m"
        limits:
          memory: "128Mi"
          cpu: "250m"
```

```bash
kubectl apply -f besteffort-pod.yaml
kubectl apply -f burstable-pod.yaml
kubectl apply -f guaranteed-pod.yaml

kubectl get pods -o wide
```

**Expected output:**
```
NAME              READY   STATUS    NODE
besteffort-pod    1/1     Running   3node-m02
burstable-pod     1/1     Running   3node-m02
guaranteed-pod    1/1     Running   3node-m02
```

Verify QoS classes:

```bash
kubectl get pod besteffort-pod -o jsonpath='{.status.qosClass}' && echo
kubectl get pod burstable-pod -o jsonpath='{.status.qosClass}' && echo
kubectl get pod guaranteed-pod -o jsonpath='{.status.qosClass}' && echo
```

**Expected output:**
```
BestEffort
Burstable
Guaranteed
```

---

### Step 3: Memory Pressure — Eviction Theory & Observation

> **minikube limitation:** On this local cluster, triggering genuine
> node-level memory and disk pressure is not reliably achievable.
> Steps 3, 4 and 5 are best observed on a real cluster (kubeadm or EKS).

#### What Happens During Memory Pressure

When available memory on a node falls below the eviction threshold
(`memory.available < 200Mi` as configured in Step 1c), the kubelet:
```
1. Detects available memory crossed the threshold
2. Sets node condition MemoryPressure = True
3. Adds taint: node.kubernetes.io/memory-pressure:NoSchedule
   → prevents new BestEffort pods from scheduling on the node
   → Guaranteed and Burstable pods tolerate this taint automatically
4. Selects pods to evict based on eviction order
5. Terminates selected pods gracefully
6. Continues until memory is reclaimed above threshold
```

#### Eviction Order — Which Pods Are Evicted First
```
Tier 1 — evicted FIRST:
  BestEffort pods
  → No requests set — guaranteed nothing
  → oom_score_adj = 1000 (OOM killer targets these first)

Tier 2 — evicted SECOND:
  Burstable pods where actual usage EXCEEDS their memory request
  → Consuming more than their guaranteed share
  → Ranked by how much usage exceeds request (highest first)

Tier 3 — evicted LAST:
  Guaranteed pods
  Burstable pods where actual usage is BELOW their memory request
  → Ranked by Priority (lower priority evicted first within tier)
```

Applied to our pods:
```
besteffort-pod   → Tier 1 — evicted FIRST  (no requests/limits)
burstable-pod    → Tier 2 — evicted SECOND (requests=64Mi, if usage > 64Mi)
                   OR Tier 3 if usage < 64Mi
guaranteed-pod   → Tier 3 — evicted LAST   (requests = limits)
```

#### Commands to Observe Memory Pressure (on a real cluster)

Monitor node condition in real time:
```bash
# Watch node memory pressure condition
watch -n2 "kubectl describe node 3node-m02 | grep -E 'MemoryPressure|Conditions' -A2"
```

Watch pod eviction sequence:
```bash
kubectl get pods -o wide -w
```

Check eviction events:
```bash
kubectl get events --sort-by='.lastTimestamp' | grep -i "evict\|pressure"
```

Check evicted pod status and reason:
```bash
kubectl describe pod <evicted-pod> | grep -E "Status:|Reason:|Message:"
```

**Expected output on a real cluster:**
```
# Node condition changes
MemoryPressure   True    ...   KubeletHasInsufficientMemory

# Pod watch output
besteffort-pod   1/1   Running    → 0/1   Evicted   (first)
burstable-pod    1/1   Running    → 0/1   Evicted   (second)
guaranteed-pod   1/1   Running    (survives longest)

# Eviction event
Warning   Evicted   pod/besteffort-pod
          The node was low on resource: memory.
          Threshold quantity: 200Mi, available: 150Mi
```

**Evicted pod describe output:**
```
Status:   Failed
Reason:   Evicted
Message:  The node was low on resource: memory.
          Threshold quantity: 200Mi, available: 150Mi.
```

> **Note on OOM kill vs kubelet eviction:**
> If the kubelet cannot evict pods fast enough, the Linux kernel OOM
> killer activates independently — it kills container processes directly
> based on `oom_score_adj` values. OOM kill sets exit code 137 typically.
> Kubelet eviction sets pod phase to `Failed` with `Reason: Evicted`.
> Both result in pod termination but via different mechanisms.

---

### Step 4: Node Condition Recovery

After the memory-consuming pod is removed, the kubelet monitors
available memory and recovers the node condition.

#### What Happens During Recovery
```
1. Memory-consuming pod terminated or deleted
2. Available memory rises above eviction threshold
3. Kubelet detects recovery after evictionPressureTransitionPeriod
   (default: 5 minutes — prevents flapping)
4. MemoryPressure condition → False
5. memory-pressure taint removed
6. Node accepts new BestEffort pods again
```

> **evictionPressureTransitionPeriod: 5m0s** — the kubelet waits
> this long after memory recovers before clearing the MemoryPressure
> condition. This prevents rapid condition flapping if memory usage
> is borderline. Verified from Step 1b configz output.

Monitor recovery:
```bash
# After deleting the memory-consuming pod
kubectl delete pod memory-hog --grace-period=0 --force

# Watch condition recovery
watch -n5 "kubectl describe node 3node-m02 | grep MemoryPressure"
```

**Expected output — immediately after deletion:**
```
MemoryPressure   True   ...   KubeletHasInsufficientMemory
```

**Expected output — after evictionPressureTransitionPeriod (5 min):**
```
MemoryPressure   False   ...   KubeletHasSufficientMemory
```

#### Evicted Pod Behaviour After Recovery
```
Standalone pods (no controller):
  → Remain in Evicted/Failed state permanently
  → Must be manually deleted and recreated
  → kubectl delete pod <evicted-pod>

Pods managed by Deployment/StatefulSet/ReplicaSet:
  → Controller detects pod is gone
  → Creates a NEW replacement pod (new UID)
  → New pod enters scheduling queue
  → If node still has MemoryPressure taint:
      BestEffort replacement → stays Pending (taint blocks it)
      Guaranteed/Burstable → tolerates taint → may schedule
  → Once taint removed → all replacements can schedule normally
```

> This is why running critical workloads as Deployments (not standalone
> pods) matters — the controller guarantees recreation after eviction.

Check node conditions on current cluster:
```bash
kubectl describe nodes | grep -E "Name:|MemoryPressure|DiskPressure|PIDPressure"
```

**Expected output (healthy cluster):**
```
Name:               3node
MemoryPressure     False   ...   KubeletHasSufficientMemory
DiskPressure       False   ...   KubeletHasNoDiskPressure
PIDPressure        False   ...   KubeletHasSufficientPID
Name:               3node-m02
MemoryPressure     False   ...
DiskPressure       False   ...
PIDPressure        False   ...
Name:               3node-m03
MemoryPressure     False   ...
DiskPressure       False   ...
PIDPressure        False   ...
```

---

### Step 5: Disk Pressure — Theory & Container Ephemeral Storage

Disk pressure eviction operates on two levels:
```
Level 1 — Container-level (demonstrable on minikube):
  Pod exceeds its own limits.ephemeral-storage
  → kubelet evicts that specific pod
  → Independent of node disk threshold
  → Verified in Demo 06 Step 7

Level 2 — Node-level DiskPressure (requires real cluster):
  Node filesystem falls below nodefs.available threshold (10%)
  → kubelet sets DiskPressure = True
  → Evicts pods in QoS order to reclaim disk space
  → Same eviction order as memory pressure
```

#### What Happens During Node DiskPressure
```
1. nodefs.available falls below 10% (or imagefs.available below 15%)
2. Kubelet sets DiskPressure = True
3. Adds taint: node.kubernetes.io/disk-pressure:NoSchedule
4. Evicts pods in order:
   → BestEffort pods first
   → Burstable pods second
   → Guaranteed pods last
5. Within each tier — pods using most ephemeral storage evicted first
   (unlike memory eviction which uses request vs usage comparison)
6. Continues until disk recovers above threshold
```

> **Key difference from memory eviction:**
> For disk pressure, the kubelet ranks pods by their actual ephemeral
> storage usage — not by how much they exceed their request.
> The pod using the most disk space is evicted first regardless of QoS.

#### Eviction Signal Reference

| Signal | Threshold | What it monitors |
|---|---|---|
| `nodefs.available` | 10% | Node root filesystem free space |
| `nodefs.inodesFree` | 5% | Node root filesystem free inodes |
| `imagefs.available` | 15% | Container image filesystem free space |
| `imagefs.inodesFree` | — | Container image filesystem free inodes |

> **Inodes:** Every file and directory consumes one inode — a fixed
> metadata slot on the filesystem. You can run out of inodes even when
> disk space is available. Each container image layer, log file, and
> emptyDir file consumes inodes. `nodefs.inodesFree < 5%` triggers
> eviction to free inode slots.

---

## Common Questions

### Q: Does node-pressure eviction respect PodDisruptionBudget?

**A:** No. The kubelet does not respect PodDisruptionBudget or
`terminationGracePeriodSeconds` when using hard eviction thresholds.
This is a key difference from API-initiated eviction (Demo 11) which
does respect PDB.

### Q: What is the difference between OOM kill and node-pressure eviction?

**A:** Node-pressure eviction is proactive — the kubelet monitors
thresholds and evicts before the node runs out of memory. OOM kill is
reactive — the Linux kernel kills processes when it actually runs out
of memory. OOM kill sets exit code 137 typically and the container is
restartable via `restartPolicy`. Node-pressure eviction sets pod phase
to `Failed` with `Reason: Evicted` and the controller recreates the pod.

### Q: Can I configure custom eviction thresholds?

**A:** Yes — via the `evictionHard` and `evictionSoft` fields in
`KubeletConfiguration` on each node. See the Understanding section for
how to change thresholds on minikube and  kubeadm clusters.

### Q: Why was my Guaranteed pod evicted?

**A:** Guaranteed pods are evicted last but not never. If all
BestEffort and Burstable pods have been evicted and the node is still
under pressure, Guaranteed pods will be evicted — ranked by Priority.
Also, if system daemons consume more resources than reserved via
`system-reserved` or `kube-reserved`, Guaranteed pods may be evicted.

### Q: What happens to evicted pods?

**A:** Standalone pods remain in `Evicted/Failed` state permanently —
they must be manually deleted and recreated. Pods managed by a
Deployment, StatefulSet, or ReplicaSet are automatically recreated by
their controller. The new pod enters the scheduling queue with a new UID.

---

## What You Learned

In this lab, you:
- ✅ Understood eviction signals and what each monitors
- ✅ Explained hard vs soft thresholds and grace period behaviour
- ✅ Read and updated eviction thresholds from kubelet configuration
- ✅ Deployed pods of each QoS class and verified QoS assignment
- ✅ Understood the full memory pressure eviction sequence and recovery
- ✅ Understood the difference between node-level and container-level
  disk pressure eviction
- ✅ Understood OOM killer vs kubelet eviction — two separate mechanisms
- ✅ Understood that node-pressure eviction does not respect PDB

**Key Takeaway:** Node-pressure eviction is the kubelet's self-defence
mechanism — it evicts pods to prevent the node from becoming
unresponsive. Eviction order: BestEffort first, then Burstable pods
exceeding requests, then Guaranteed — all ranked by Priority within
each tier. Hard thresholds are immediate and do not respect PDB or
grace periods. Use Guaranteed QoS for pods that must survive memory
pressure longest.

---

## Quick Commands Reference

Commands unique to this demo:

| Command | Description |
|---|---|
| `kubectl proxy &` | Start API proxy for kubelet configz access |
| `curl http://localhost:8001/api/v1/nodes/<n>/proxy/configz 2>/dev/null \| python3 -m json.tool \| grep -A8 "eviction"` | Read kubelet eviction thresholds |
| `kubectl describe nodes \| grep -E "Name:\|MemoryPressure\|DiskPressure\|PIDPressure"` | Check all node pressure conditions |
| `kubectl get pod <n> -o jsonpath='{.status.qosClass}' && echo` | Get QoS class of a pod |
| `kubectl describe pod <n> \| grep -E "Status:\|Reason:\|Message:"` | Check eviction reason and message |
| `kubectl get events --sort-by='.lastTimestamp' \| grep -i evict` | Find eviction events |
| `kubectl top node` | Monitor node resource usage (requires metrics-server) |
| `kubectl top pod --sort-by=memory` | Monitor pod memory usage — find pressure source |
| `minikube ssh -p 3node -n <node> "free -h"` | Check actual memory inside minikube node |

---

## CKA Certification Tips

✅ **Eviction order — memorise:**
```
BestEffort (no requests/limits)        → evicted FIRST
Burstable (usage > requests)           → evicted SECOND
Guaranteed / Burstable (usage < req)   → evicted LAST
Within each tier: lower Priority evicted first
```

✅ **Node-pressure eviction does NOT respect:**
```
PodDisruptionBudget            ← only API-initiated eviction respects this
terminationGracePeriodSeconds  ← only respected for soft thresholds
```

✅ **Hard vs soft threshold:**
```
Hard → immediate termination (0s grace period)
Soft → respects eviction-max-pod-grace-period
```

✅ **OOM kill vs node-pressure eviction:**
```
OOM kill      → kernel kills container process → exit code 137 typically
                container restartable via restartPolicy
Node-pressure → kubelet sets pod phase=Failed, Reason=Evicted
                controller recreates pod
```

✅ **Node conditions to know:**
```
MemoryPressure → memory.available below threshold
DiskPressure   → nodefs.available or imagefs.available below threshold
PIDPressure    → pid.available below threshold
```

✅ **oom_score_adj per QoS — OOM kill order:**
```
BestEffort  → 1000   (killed FIRST by OOM killer)
Burstable   → 2-999  (proportional to memory usage vs request)
Guaranteed  → -998   (protected — killed LAST)
```

---

## Troubleshooting

**Pod shows Status: Evicted:**
```bash
kubectl describe pod <pod-name> | grep -E "Status:|Reason:|Message:"
# Message shows which resource triggered eviction and threshold crossed
```

**Node shows MemoryPressure: True:**
```bash
# Find the memory-consuming pod
kubectl top pod --sort-by=memory
# Remove or reduce the offending pod
kubectl delete pod <pod-name> --grace-period=0 --force
# Wait evictionPressureTransitionPeriod (5m) for condition to clear
watch -n5 "kubectl describe node <node> | grep MemoryPressure"
```

**Evicted pods not restarting:**
```bash
# Standalone pods stay Evicted — delete manually
kubectl delete pod <evicted-pod>
# Pods managed by controller are recreated automatically
kubectl get deployment <name>
kubectl rollout status deployment/<name>
```
