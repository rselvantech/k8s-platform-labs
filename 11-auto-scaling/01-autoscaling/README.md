# Demo: 11-auto-scaling/01-autoscaling — HPA, VPA, and the Kubernetes Scaling Model

## Lab Overview

Applications receive variable traffic throughout the day — fixed replica counts and static resource allocations either waste money during quiet periods or cause outages during peaks. Kubernetes autoscaling adjusts both the number of pods and their resource allocations automatically based on actual demand.

This lab builds the complete mental model for Kubernetes autoscaling before any hands-on work begins. You will understand cAdvisor (where metrics originate), metrics-server (how metrics reach the control plane), the HPA controller (how scaling decisions are made), and VPA (how resource requests are right-sized over time). The hands-on steps then verify each concept with real numbers from a live cluster.
**Real-world scenario:** A nginx-based web application that receives
variable traffic. HPA handles traffic spikes by adding replicas. VPA
right-sizes resource requests based on observed usage — preventing
under-provisioning (OOMKill, throttling) and over-provisioning (waste).


**What this lab covers:**
- Types of scaling in Kubernetes — HPA, VPA, Cluster Autoscaler — what each does, when each applies, who builds and maintains each
- cAdvisor — what it is, how it reads from cgroups vs /proc, how long it retains data
- metrics-server — architecture, the Metrics API, what "cluster addon" means, storage model
- HPA architecture — the full pipeline from container runtime to HPA controller
- The scale subresource and scaleTargetRef — what HPA actually updates
- HPA v2 API — CPU, memory, multiple metrics, ContainerResource (stable v1.30+)
- HPA metric types — Resource, ContainerResource, Pods, Object, External — the full pipeline for each
- HPA scaling algorithm — formula, tolerance, multiple metrics MAX rule
- Scale-down stabilisation — why pods stay up after load drops
- HPA behaviour — custom scale-up/down policies and windows
- Why HPA does not use the Eviction API and what that means for PDB
- VPA installation — three components and how they work together — who maintains VPA
- VPA algorithm — inputs, histogram model, output fields (Target, Lower Bound, Upper Bound, Uncapped Target)
- VPA update modes — Off, Initial, Recreate, InPlaceOrRecreate
- VPA per-container recommendations and containerPolicies
- What VPA can and cannot target — standalone pod vs single-pod app distinction
- VPA CRDs — VerticalPodAutoscaler and VerticalPodAutoscalerCheckpoint
- HPA + VPA conflict — safe and unsafe combinations
- Complete field reference for both HPA and VPA with field-level explanations

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl installed and configured
- metrics-server enabled (required by both HPA and VPA)
- git (for VPA installation — Steps 9+)

**Verify metrics-server before starting:**
```bash
kubectl get pods -n kube-system | grep metrics-server
kubectl top nodes
# Both must work before proceeding
```

**Knowledge Requirements:**
- **REQUIRED:** Completion of `06-pod-scheduling/06-resource-management` — resource requests/limits, cgroups enforcement, QoS classes (mandatory for HPA utilisation calculations)
- **REQUIRED:** Understanding of Deployments and replica management
- **RECOMMENDED:** Understanding of QoS classes (helpful for VPA eviction behaviour)

---

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain all three Kubernetes scaling types, when each applies, and who maintains each
2. ✅ Explain what cAdvisor is, why it reads from cgroups rather than /proc, and how long it retains data
3. ✅ Describe the metrics-server architecture and the Metrics API, and explain what "cluster addon" means
4. ✅ Describe the HPA metrics pipeline — cAdvisor → kubelet → metrics-server → HPA controller
5. ✅ Explain the scale subresource and scaleTargetRef
6. ✅ Apply the HPA scaling formula and verify with real numbers
7. ✅ Explain why HPA does not use the Eviction API and what this means for PDB
8. ✅ Create HPA v2 with CPU-based, memory-based, and multiple-metric scaling and observe scale-up/down
9. ✅ Configure custom HPA behaviour — stabilisation windows and policies
10. ✅ Explain the difference between all five HPA metric types and which metrics pipeline each uses
11. ✅ Install VPA and explain all three components and who maintains the project
12. ✅ Explain the VPA algorithm — inputs, histogram model, and all recommendation output fields
13. ✅ Use VPA Off mode to get resource recommendations without pod changes
14. ✅ Use VPA Recreate mode and observe automatic resource adjustment
15. ✅ Explain HPA + VPA conflict and identify safe combinations

---

## Directory Structure

```
11-auto-scaling/01-autoscaling/
├── README.md                        # this file
└── src/
    ├── nginx-deploy.yaml            # nginx deployment + ClusterIP service
    ├── load-generator.yaml          # busybox load generator
    ├── hpa-cpu-v2.yaml              # HPA v2 — CPU based
    ├── hpa-memory-v2.yaml           # HPA v2 — memory based
    ├── hpa-multi-metric.yaml        # HPA v2 — CPU + memory
    ├── hpa-behaviour.yaml           # HPA v2 — custom scale-down behaviour
    ├── vpa-off.yaml                 # VPA Off mode — recommendations only
    ├── vpa-recreate.yaml            # VPA Recreate mode — auto resource update
    └── vpa-conflict.yaml            # VPA + HPA conflict demo
```

---

## Understanding Autoscaling in Kubernetes

### What Is Scaling — Types and Overview

Running fixed replicas and static resource allocations does not match real-world traffic patterns. Applications receive low traffic at 3am and peak traffic at 9am — fixed configurations either waste money or cause outages.

Kubernetes provides three complementary autoscaling mechanisms. Each operates at a different layer of the stack:

```
HPA — Horizontal Pod Autoscaler
  What it does:  adds or removes pod REPLICAS
  Responds to:   traffic spikes — more pods = more capacity
  Best for:      stateless workloads (web servers, APIs, workers)
  Scales:        OUT (more pods) or IN (fewer pods)
  Built into:    Kubernetes core — no extra install required
  CRD:           HorizontalPodAutoscaler (autoscaling/v2)
  Maintained by: Kubernetes SIG Autoscaling — part of the core project

VPA — Vertical Pod Autoscaler
  What it does:  adjusts CPU/memory REQUESTS per container
  Responds to:   resource mis-sizing — too little or too much allocated
  Best for:      stateful workloads, single-pod apps, right-sizing
  Scales:        UP (more CPU/memory per pod) or DOWN (less CPU/memory)
  Built into:    NOT included — requires separate install
  CRDs:          VerticalPodAutoscaler (autoscaling.k8s.io/v1)
                 VerticalPodAutoscalerCheckpoint (autoscaling.k8s.io/v1)
  Maintained by: Kubernetes SIG Autoscaling — lives in the
                 kubernetes/autoscaler GitHub repository (separate from
                 core Kubernetes, but same SIG ownership)

CA — Cluster Autoscaler
  What it does:  adds or removes NODES from the cluster
  Responds to:   pending pods (cannot schedule — no node capacity)
  Best for:      dynamic workloads on cloud infrastructure
  Scales:        nodes UP (provision) or DOWN (terminate)
  Built into:    NOT included — requires cloud provider integration
  Requires:      cloud provider API (AWS, GCP, Azure) — not on minikube
  CRD:           none — CA does not install CRDs; it watches core Pod
                 and Node objects and calls the cloud provider API
                 directly. On AWS EKS, Karpenter is the modern
                 replacement and does use CRDs (NodePool, EC2NodeClass)
  Maintained by: Kubernetes SIG Autoscaling — also in
                 kubernetes/autoscaler. Each cloud provider contributes
                 and maintains their own cloud provider plugin within
                 that repo. CA can integrate with any cloud provider
                 that has contributed a plugin (AWS, GCP, Azure,
                 DigitalOcean, OpenStack, and others).
```

**What is resource mis-sizing (VPA trigger)?**

When you write a Kubernetes manifest you must set `resources.requests.cpu` and `resources.requests.memory` for each container. These values are guesses — you may guess too low, too high, or correctly:

```
Under-provisioned (too little):
  requests.cpu: 50m   ← but the container actually needs 300m
  Effect: CPU throttling (performance degradation), or OOMKill if memory
  HPA consequence: HPA sees utilisation% = usage/request = 300/50 = 600%
                   → triggers aggressive scaling even when a bigger
                     request would have solved the problem alone

Over-provisioned (too much):
  requests.cpu: 2000m ← but the container actually uses 100m
  Effect: node capacity wasted, fewer pods can schedule, higher cost
  HPA consequence: HPA sees utilisation% = 100/2000 = 5%
                   → never scales up, even under real load

VPA's job: observe actual usage over time, then tell you (or set)
           the requests that reflect reality — this is "right-sizing"
```

Right-sizing means setting resource requests that accurately reflect a container's actual observed usage — not too high (waste), not too low (throttling/OOMKill). VPA automates this by building a statistical model of observed usage and producing recommendations based on percentile-based targets.

**Why HPA is best for stateless workloads:**

Stateless workloads — web servers, API servers, worker processes — have two properties that make horizontal scaling safe and effective:
- Every replica is identical. Any request can be handled by any pod. Adding a new pod immediately increases capacity.
- Replicas do not share local state. Removing a pod loses nothing — the next request goes to a surviving replica.

This means HPA can scale in/out freely without worrying about data consistency, ordered shutdown, or pod identity.

**Why VPA is better for stateful workloads:**

Stateful workloads — databases, message queues, caches — have properties that make horizontal scaling complex or dangerous:
- Pods have identity. A MySQL primary cannot be replaced by simply adding another MySQL pod — replication must be set up, leader election must run, etc.
- Adding replicas requires coordination — you cannot just double the replica count and have twice the write capacity.
- Data may be pinned to a specific pod's local storage.

For these workloads, the correct lever is not "add more pods" but "give the existing pod the resources it needs." That is exactly what VPA does.

**Why VPA is best for single-pod apps (not multi-pod):**

VPA Recreate and InPlaceOrRecreate modes work by evicting pods so they restart with updated resource requests. If your Deployment has only one replica, the Updater will evict that one pod — your application goes down momentarily until the pod restarts.

With multiple replicas, VPA respects PDB and evicts pods one at a time, maintaining availability. But VPA does NOT do load balancing or parallel processing — it only adjusts requests per pod. If your workload genuinely needs more compute, you need more pods (HPA), not bigger pods (VPA). So in practice:
- Single-pod stateful app → VPA is the correct tool (adjusts the one pod's resources)
- Multi-replica stateless app → HPA is the correct tool (adjusts pod count)
- Multi-replica stateful app → VPA in Off mode for recommendations; operator-managed scaling for replicas

**Why VPA does NOT support standalone pods:**

A standalone pod (not managed by a Deployment, StatefulSet, or other controller) cannot be recreated after eviction — when the VPA Updater evicts it, it is gone permanently. There is no controller watching it to recreate it. VPA requires a controller to recreate evicted pods; without one, Recreate mode would just delete your pod. Even for a single-pod application, use a Deployment with `replicas: 1` — VPA will then evict and the Deployment controller will recreate it with updated resources.

**Scale-down behaviour — all three autoscalers:**

```
HPA scale-down:
  Trigger:   metric drops below target × (1 - tolerance)
  Mechanism: default 5-minute stabilisation window
             → records all recommended replica counts over last 5 min
             → only scales down to the HIGHEST recommendation seen
             → prevents premature scale-down during traffic lulls
  Action:    calls DELETE on pods via scale subresource (NOT Eviction API)
  PDB:       NOT respected — direct deletion bypasses it

VPA scale-down (reducing requests):
  Trigger:   Recommender's Target CPU/memory is significantly below current requests
  Mechanism: Updater polls recommendations, identifies out-of-range pods
             → evicts pods using Eviction API (respects PDB)
             → Admission Controller injects lower requests on restart
  Timing:    depends on Updater polling interval and PDB constraints
  Action:    pod is evicted → controller recreates → admission injects lower requests

CA scale-down (removing nodes):
  Trigger:   node has been underutilised for 10 minutes (configurable)
             AND all pods on it could fit on other nodes
  Mechanism: drains pods (uses Eviction API → respects PDB)
             → calls cloud provider API to terminate the VM
  Action:    pods reschedule to other nodes, VM is terminated
```

**How the three work together:**

```
Traffic spike arrives:
  1. More requests → per-pod CPU rises above HPA target
  2. HPA scales out → new pods created

  3. New pods cannot schedule (all nodes full)
  4. Cluster Autoscaler detects Pending pods
  5. CA calls AWS/GCP/Azure API → provisions new node
  6. New pods schedule on new node

Over time (with VPA in Off or Recreate mode):
  4. VPA Recommender observes actual CPU/memory per container
  5. VPA adjusts requests to match real usage (right-sizing)
  6. Better-sized requests → more accurate HPA calculations

Why step 6 matters:
  HPA formula: desiredReplicas = ceil[currentReplicas × (usage / request)]
  If request is inflated (over-provisioned):
    usage=300m, request=2000m → utilisation=15% → HPA never scales up
  If request is correct (right-sized by VPA):
    usage=300m, request=350m → utilisation=86% → HPA scales appropriately
  VPA right-sizing makes HPA's signal more accurate
```

---

### cAdvisor — Container Advisor

**Full name:** cAdvisor = **c**ontainer **Advis**or

cAdvisor is an open-source agent embedded directly inside every kubelet process. It is not a separate deployment or daemonset — it runs as part of the kubelet binary on every node. cAdvisor was originally a standalone Google project; it was integrated into the kubelet and is now maintained as part of Kubernetes itself.

**What cAdvisor does:**
- Reads container CPU and memory usage from the Linux kernel's cgroup filesystem
- Aggregates metrics per container, per pod, and per node
- Exposes them at the kubelet's `/metrics/cadvisor` endpoint (detailed Prometheus metrics) and `/metrics/resource` endpoint (lightweight summary — what metrics-server reads)

**What cAdvisor does NOT do:**
- Does NOT store historical data — it provides snapshots of the current moment only
- Does NOT expose metrics cluster-wide — only the local node's containers
- Does NOT feed HPA directly — metrics-server reads from it and exposes the Metrics API

**Why cgroups, not /proc?**

This is an important distinction. The Linux `/proc` filesystem does expose process-level CPU and memory statistics — for example, `/proc/<pid>/stat` for CPU and `/proc/<pid>/status` for memory. So why does cAdvisor read from cgroups instead?

```
/proc gives you:     process-level view
                     tied to a specific PID
                     does not know about container boundaries
                     cannot aggregate "all processes in this container"

cgroups gives you:   container-level view
                     the kernel groups all processes in a container
                     into a cgroup hierarchy
                     reading the cgroup gives you the TOTAL usage
                     of ALL processes inside the container
                     this is exactly what Kubernetes needs

Example:
  A Python web server forks worker processes.
  The container has PIDs: 1 (master), 10, 11, 12 (workers)
  /proc/1/stat → usage of the master process only
  cgroup for the container → total CPU used by ALL four processes
```

The cgroup filesystem is at `/sys/fs/cgroup/` on modern Linux systems (cgroups v2). Each container runtime (containerd, CRI-O) creates a cgroup hierarchy when it starts a container. cAdvisor walks this hierarchy to collect per-container totals.

**How long cAdvisor stores data:**

cAdvisor does not store data at all — it is a live reader. Every time metrics-server calls the kubelet's `/metrics/resource` endpoint, cAdvisor reads current cgroup values and returns them. There is no historical buffer, no rolling window, no time series in cAdvisor itself. If you need historical data, you need a separate time-series database (Prometheus, Grafana) that regularly scrapes cAdvisor's Prometheus endpoint and stores the samples.

```
cAdvisor retention:     NONE — current snapshot only
metrics-server:         1 data point (most recent) — not a time series
Prometheus (if deployed): configurable — default 15 days
VPA Recommender:        maintains its own histogram (in VPACheckpoint)
                        across multiple metrics-server snapshots
                        default observation window: 8 days
                        (configurable via --history-length flag)
```

---

### metrics-server — Architecture, Cluster Addon, and the Metrics API

**What is metrics-server?**

metrics-server is the component that aggregates resource metrics from all nodes in the cluster and exposes them through a single API endpoint — the Metrics API (`metrics.k8s.io`). It is what powers `kubectl top`, HPA, and VPA.

**What "cluster addon" means:**

A cluster addon is a component that is not part of the core Kubernetes control plane binaries (`kube-apiserver`, `kube-scheduler`, `kube-controller-manager`, `etcd`), but is expected to be present in a functional cluster and is managed through the cluster's own Kubernetes API (deployed as a Deployment or DaemonSet, not as a system service). metrics-server is a cluster addon — it runs as a Deployment in `kube-system`, and you interact with it using `kubectl`. It is not bundled into any Kubernetes binary.

On different distributions:
```
minikube:    enabled as an addon — minikube addons enable metrics-server -p 3node
             not enabled by default
kubeadm:     not installed — must apply components.yaml manually:
             kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/
               releases/latest/download/components.yaml
EKS:         not installed by default — must deploy separately
             (Amazon Managed Prometheus or metrics-server)
k3s:         bundled and enabled by default
kind:        not installed by default
```

**metrics-server architecture:**

```
Every node — kubelet process
  ├── cAdvisor (embedded)
  │     reads from /sys/fs/cgroup (cgroups v2) or /sys/fs/cgroup/... (v1)
  │     produces: per-container CPU usage (nanocores), memory working set (bytes)
  │
  └── /metrics/resource endpoint
        lightweight HTTP endpoint (not Prometheus format)
        returns: ResourceMetricsList — one entry per pod/container on this node
        format: protobuf (efficient) or JSON

metrics-server Deployment (in kube-system)
  → scrapes /metrics/resource on EVERY node every 60 seconds (default)
  → aggregates into an in-memory store (not persisted to disk)
  → exposes the aggregated data via Metrics API

Kubernetes API server (kube-apiserver)
  → registers metrics-server as an APIService for metrics.k8s.io
  → proxies requests to metrics-server
  → kubectl top, HPA, VPA all read from metrics.k8s.io via kube-apiserver
```

**How the Metrics API is registered:**

metrics-server registers itself as an API extension using an `APIService` object. This is how `kubectl top` works — it calls `kube-apiserver` at `/apis/metrics.k8s.io/v1beta1/nodes` or `/apis/metrics.k8s.io/v1beta1/pods`, and `kube-apiserver` proxies the request to the metrics-server service.

```bash
kubectl get apiservices | grep metrics
# Expected output:
# v1beta1.metrics.k8s.io   kube-system/metrics-server   True   5m
#                                                         ↑
#                           True = metrics-server is reachable and serving
```

**How long metrics-server stores data:**

metrics-server keeps only the most recent metric sample per pod/container — it is not a time-series database. There is no configurable retention window. If you query `kubectl top` twice a second apart, both queries return the same sample until the next 60-second scrape cycle.

```
metrics-server retention:  1 sample per pod/container (most recent)
                           scraped from kubelet every 60s (default)
                           no historical data, no time series
                           restarting metrics-server clears all data
```

**What metrics-server does NOT provide:**
```
- Historical data (point-in-time only — use Prometheus for history)
- Disk or network metrics
- Long-term storage or alerting
- High-cardinality application-level metrics
- Not for monitoring — strictly for autoscaling decisions
```

**Verification:**
```bash
# Check deployment
kubectl get deployment metrics-server -n kube-system

# Verify Metrics API is registered and ready
kubectl get apiservices | grep metrics
# v1beta1.metrics.k8s.io ... True

# Test — both of these read from the Metrics API via kube-apiserver
kubectl top nodes
kubectl top pods -A
```

> The values returned by `kubectl top` may differ from OS tools like `top` or `htop`. This is expected — metrics-server is optimised for stable autoscaling signals, not for real-time accuracy. In particular, memory reports "working set" (active memory minus recently-used-but-releasable cache), not RSS. This produces a more meaningful signal for HPA decisions than raw RSS.

---

### Understanding HPA — Horizontal Pod Autoscaler

#### HPA Architecture and the Full Metrics Pipeline

```
Container Runtime (containerd / CRI-O)
        | runs container processes inside a cgroup
        v
cAdvisor (embedded in kubelet on each node)
        | reads cgroup filesystem — current CPU nanocores, memory working set
        | no storage — live snapshot only
        v
kubelet /metrics/resource endpoint
        | lightweight HTTP endpoint per node
        | exposes ResourceMetricsList for all pods on this node
        v
metrics-server (Deployment in kube-system)
        | scrapes every kubelet every 60 seconds
        | aggregates across all nodes into in-memory store
        | exposes via Metrics API (metrics.k8s.io)
        v
Kubernetes API server
        | proxies metrics.k8s.io requests to metrics-server
        v
HPA controller (inside kube-controller-manager on control plane)
        | queries Metrics API every 15 seconds (default sync period)
        | evaluates all HPA objects in the cluster
        | calculates desired replica count per HPA using the formula
        v
Scale subresource of target workload (Deployment / StatefulSet)
        | HPA updates the replica count via the scale subresource
        v
Deployment controller (inside kube-controller-manager)
        | creates or deletes pods to match desired replica count
        v
New pods start, cAdvisor begins reading their cgroup metrics
```

**What is the scale subresource?**

Every Kubernetes workload that supports scaling (Deployment, StatefulSet, ReplicaSet) exposes a `/scale` subresource — a special sub-path on the resource's API endpoint that contains only the replica count and selector, without the full spec. For example:

```
Full Deployment:  /apis/apps/v1/namespaces/default/deployments/nginx-deploy
Scale subresource: /apis/apps/v1/namespaces/default/deployments/nginx-deploy/scale
```

The HPA controller updates ONLY the scale subresource — it never touches the full Deployment spec. This keeps the change lightweight and is why `kubectl get deployment nginx-deploy -o yaml` shows `replicas: 3` after HPA scales, even though HPA never modified the deployment YAML directly.

Any resource can support HPA as long as it implements the scale subresource — this includes Deployments, StatefulSets, ReplicaSets, and any custom resource (CRD) that declares `subresources: scale:` in its schema.

**What is scaleTargetRef?**

`scaleTargetRef` in an HPA spec is the pointer from the HPA object to the workload it manages:

```yaml
scaleTargetRef:
  apiVersion: apps/v1    # which API group owns the target resource
  kind: Deployment       # what kind of resource it is
  name: nginx-deploy     # the name of the specific instance
```

The HPA controller uses this to:
1. Find the target's scale subresource URL
2. Read current replica count
3. Write desired replica count after calculation

One HPA targets exactly one scaleTargetRef. Two HPAs pointing at the same scaleTargetRef cause an `AmbiguousSelector` conflict — the controller cannot determine which is authoritative and refuses to scale.

#### HPA Algorithm — Scaling Formula

The same formula applies for both v1 and v2:

```
desiredReplicas = ceil[ currentReplicas × (currentMetricValue / desiredMetricValue) ]
```

**Example — CPU scale-up:**

```
currentReplicas = 1
currentCPU      = 115%  (average across all pods)
targetCPU       = 50%

desiredReplicas = ceil[ 1 × (115 / 50) ]
               = ceil[ 2.3 ]
               = 3  → scale to 3 pods
```

**Tolerance — default 10%:**

```
HPA does not scale if metric is within 10% of target (prevents flapping):
  Target 50%, current 46%  → ratio = 0.92 → within tolerance → NO scaling
  Target 50%, current 44%  → ratio = 0.88 → outside tolerance → scale DOWN
  Target 50%, current 55%  → ratio = 1.10 → within tolerance → NO scaling
  Target 50%, current 56%  → ratio = 1.12 → outside tolerance → scale UP
```

**Multiple metrics — MAX rule:**

```
When multiple metrics are configured, HPA evaluates EACH independently
and takes the MAXIMUM desired replica count:
  CPU says:    ceil[ 1 × (115/50) ] = 3
  Memory says: ceil[ 1 × (8/70)  ] = 1
  HPA takes:   MAX(3, 1) = 3  → uses highest proposed count

Safety rule:
  If ANY metric is unavailable AND it suggests scale-down
    → scaling is SKIPPED entirely (safe default — avoid false scale-down)
  If ANY metric is unavailable AND it suggests scale-up
    → scale-up proceeds using only available metrics
```

#### HPA and PodDisruptionBudget — Why HPA Does Not Use the Eviction API

HPA scale-down removes pods by calling DELETE directly on the pods via the scale subresource. It does NOT use the Eviction API.

**Why the difference?**

The Eviction API (`/eviction` subresource on a pod) was designed for node drains and voluntary disruptions — scenarios where you explicitly want the scheduler to consider the PDB before removing a pod. The HPA controller was designed before the Eviction API matured, and its scale-down path uses direct deletion for simplicity and speed. This is a known design limitation, not an oversight — it has been discussed in Kubernetes SIG Autoscaling but not changed to avoid breaking existing behaviour.

**Practical consequence:**

```
Deployment: replicas=5
PDB: minAvailable=3 (allows 2 disruptions at once)
HPA: decides to scale to 2

HPA removes 3 pods directly via DELETE
→ drops to 2 replicas, below PDB minAvailable=3
→ PDB is NOT consulted — HPA bypasses Eviction API

Compare with VPA Updater:
  VPA Updater → uses Eviction API → PDB IS respected
  → will not evict a pod if the budget would be violated
  → waits until PDB allows it

Compare with kubectl drain:
  Uses Eviction API → PDB IS respected
```

**What you can do:**

PDB alongside HPA is still useful — it protects against other sources of disruption (node drains, manual deletions, rolling updates). Just understand that HPA scale-down will violate the PDB if it decides to remove enough pods. Setting `minReplicas` in the HPA to match or exceed PDB's `minAvailable` is the practical safeguard.

#### What HPA Can Target

```
Supported (implement the scale subresource):
  Deployment         → most common — stateless, parallel replicas
  StatefulSet        → supported — pods scale in ordered sequence (slower)
  ReplicaSet         → supported — prefer Deployment instead
  Custom resources   → any CRD that declares "subresources: scale:" in its
                       CustomResourceDefinition schema
                       Example: a "WebApp" CRD with a /scale subresource
                       works with HPA the same way a Deployment does

NOT supported (no scale subresource):
  DaemonSet          → runs exactly one pod per node — no replicas to adjust
  Job/CronJob        → run-to-completion — not long-running services
```

#### HPA v1 vs v2

```
autoscaling/v1  → CPU only
                  targetCPUUtilizationPercentage field
                  kubectl autoscale creates this view
                  STORED as v2 internally (v1 is a simplified read-only projection)
                  deprecated flag: --cpu-percent

autoscaling/v2  → CPU, memory, custom, external, container metrics
                  multiple metrics simultaneously
                  container-level metrics (stable since v1.30)
                  custom scale-up/down behaviour
                  current stable version — USE THIS
                  modern flag: --cpu=50%
```

> `kubectl autoscale` creates `autoscaling/v2` internally regardless of which
> flag format you use. Verify with: `kubectl get hpa -o yaml`

#### Scale-Down Stabilisation — Why Pods Do Not Scale Down Immediately

```
Default scale-up:   no stabilisation window → scales immediately
Default scale-down: 5-minute window (300 seconds)

How it works:
  → HPA evaluates metrics every 15 seconds
  → For scale-down: records all recommendations over the last 5 minutes
  → Takes the HIGHEST recommendation from that window
  → Only scales down to that highest recommendation
  → Prevents removing pods only to immediately add them back
    (traffic burst just ended does not mean it won't start again)

Verified from lab:
  Load removed   → CPU drops to 0%
  +1 minute      → still 3 replicas (within 5-min window)
  +5-9 minutes   → SuccessfulRescale: New size: 2
                   (window expired, scale-down triggered)
```

#### HPA CRD and kubectl Commands

```
Kind:       HorizontalPodAutoscaler
API Group:  autoscaling
Version:    v2 (stable, current)
Short name: hpa

kubectl get hpa
kubectl describe hpa <name>
kubectl get hpa <name> -w                      # watch in real time
kubectl get hpa <name> -o yaml                 # full YAML including status
kubectl delete hpa <name>                      # deletes HPA only — pods unchanged
kubectl autoscale deployment <name> \
  --cpu=50% --min=1 --max=5                    # imperative creation (creates v2)
```

**kubectl get hpa — output explained:**

```
NAME           REFERENCE                TARGETS        MINPODS  MAXPODS  REPLICAS  AGE
nginx-hpa-cpu  Deployment/nginx-deploy  cpu: 37%/50%   1        5        3         38m

NAME       → HPA object name (from metadata.name)
REFERENCE  → scaleTargetRef (Kind/name) — the workload being scaled
TARGETS    → current metric value / target value per metric
             cpu: 37%/50%          → 37% current utilisation, 50% target
             cpu: <unknown>/50%    → metrics not yet available (pod starting up;
                                     wait 30-60s for first metrics-server scrape)
             cpu: <unknown>/50%    → (persistent) missing resources.requests.cpu
                                     on one or more containers
MINPODS    → minReplicas — HPA will never scale below this
MAXPODS    → maxReplicas — HPA will never exceed this
REPLICAS   → current replica count as last set by HPA
AGE        → how long the HPA object has existed
```

**kubectl describe hpa — key sections explained:**

```bash
kubectl describe hpa nginx-hpa-cpu
```

```
Name:           nginx-hpa-cpu
Namespace:      default
Reference:      Deployment/nginx-deploy
Metrics:        ( current / target )
  resource cpu on pods (as a percentage of request):  37% (37m) / 50%
  │           │            │                           │    │       │
  │           │            │                           │    │       └─ target: 50% averageUtilization
  │           │            │                           │    └─ actual CPU usage in milliCPU
  │           │            │                           └─ utilisation% = usage/request × 100
  │           │            └─ "on pods" = Resource type, averaged across all pods
  │           └─ metric source: "cpu" resource
  └─ metric type: "resource"

  37% = (37m current CPU usage) / (100m request) × 100
  If this shows "on container X" instead of "on pods"
    → this is a ContainerResource-type metric (02-hpa-advanced)

Min replicas:   1     ← never scale below this (from minReplicas)
Max replicas:   5     ← never scale above this (from maxReplicas)
Deployment pods: 3 current / 3 desired

Conditions:
  Type            Status  Reason              Meaning
  ----            ------  ------              -------
  AbleToScale     True    ReadyForNewScale    HPA is not in cooldown; ready to scale
                  False   BackoffBoth         HPA recently scaled; in cooldown window
                  False   BackoffDownscale    In scale-down stabilisation window
                  False   BackoffUpscale      In scale-up stabilisation window

  ScalingActive   True    ValidMetricFound    Metrics are working; HPA can calculate replicas
                  False   InvalidSelector     HPA selector does not match any pods
                  False   FailedGetScale      Could not read current replica count
                  False   FailedGetResourceMetric  Metrics unavailable (pod starting, or
                                             missing resources.requests — wait 30-60s
                                             or check all containers have requests set)

  ScalingLimited  False   DesiredWithinRange  Desired replicas is within min/max bounds
                  True    TooFewReplicas      Already at minReplicas — cannot scale down further
                  True    TooManyReplicas     Already at maxReplicas — cannot scale up further
                          (this is EXPECTED when at max — not an error)

Events:
  Normal  SuccessfulRescale    New size: 3; reason: cpu resource utilization above target
    → Scale event happened successfully — new size and reason both shown

  Warning FailedGetScale       Unauthorized: ...AmbiguousSelector
    → Two HPAs targeting the same Deployment — delete the extra one

  Warning FailedGetResourceMetric
    → Metrics not available yet — wait 30-60s after pod creation
    → Or: resources.requests not set on all containers
```

---

### HPA Metric Types — The Full Metrics Pipeline for Each

The five HPA metric types use different data sources and require different infrastructure. Understanding WHICH pipeline each type uses determines how complex your setup needs to be.

```
API Group              Served by          HPA metric types using it
metrics.k8s.io       → metrics-server  → Resource, ContainerResource
custom.metrics.k8s.io → metrics adapter → Pods, Object
external.metrics.k8s.io → metrics adapter → External
```

**Valid target types per metric type:**

| Metric type | Valid `target.type` values | Field used | Notes |
|---|---|---|---|
| `Resource` | `Utilization`, `AverageValue` | `averageUtilization` or `averageValue` | `Utilization` = % of request; requires `resources.requests` set |
| `ContainerResource` | `Utilization`, `AverageValue` | `averageUtilization` or `averageValue` | Same as Resource but scoped to one container |
| `Pods` | `AverageValue` only | `averageValue` | No % concept — averaged raw value per pod; no "request" to compare against |
| `Object` | `Value`, `AverageValue` | `value` or `averageValue` | `Value` = raw total on the object; `AverageValue` = total divided by current pod count |
| `External` | `Value`, `AverageValue` | `value` or `averageValue` | Same options as Object; `AverageValue` is most common for queue-based scaling |

```
Utilization:  only valid for Resource and ContainerResource
              computes: usage / request × 100
              requires resources.requests to be set on all containers
              expressed as an integer percentage: averageUtilization: 50

AverageValue: valid for Resource, ContainerResource, Pods, Object, External
              raw metric value averaged across all pods of the target
              expressed as a quantity string: averageValue: "500m" or "1000"

Value:        only valid for Object and External
              the raw metric value NOT divided by pod count
              expressed as a quantity string: value: "10000"
              use when the metric is a cluster-level or object-level total,
              not per-pod (e.g. total Ingress requests/s, not per-backend-pod)
```

**Type: Resource** — built-in, covered in this demo

```
Pipeline: cAdvisor → kubelet → metrics-server → metrics.k8s.io → HPA
Requires: metrics-server only (no adapter)
Scope:    pod-level (all containers averaged)

Use case: web server with variable traffic
  Scale nginx pods when average CPU across all pods exceeds 50%
  No adapter needed — works with metrics-server alone
```

**Type: ContainerResource** — built-in, stable since v1.30 — covered in `02-hpa-advanced`

```
Pipeline: cAdvisor → kubelet → metrics-server → metrics.k8s.io → HPA
Requires: metrics-server only (no adapter)
Scope:    one named container within a pod (not the whole pod)

Use case: pod with main app + logging sidecar
  HPA watches only the "app" container's CPU, ignores sidecar spikes
  Full hands-on: see 02-hpa-advanced Steps 1–2
```

**Type: Pods** — requires custom metrics adapter

```
Pipeline: application → Prometheus (or other store)
          → custom metrics adapter (e.g. Prometheus Adapter)
          → custom.metrics.k8s.io → HPA
Requires: a metrics adapter installed in the cluster
Scope:    per-pod metric, averaged across all pods of the target

Use case: message queue consumer
  Consumer pods publish 'messages_processed_per_second' metric
  HPA scales consumers to maintain 500 msg/s per pod average
  More messages in queue → metric rises → more consumer pods added

Why Pods and not Object?
  The metric is PER-POD — each consumer pod exposes its own throughput.
  HPA averages across all pods. Adding a pod adds capacity linearly.
  Object would read a single total value from one Kubernetes object —
  wrong shape for a per-pod throughput metric.
```

**Type: Object** — requires custom metrics adapter

```
Pipeline: Kubernetes object (e.g. Ingress) → adapter → custom.metrics.k8s.io → HPA
Requires: a metrics adapter installed in the cluster
Scope:    single metric from one specific Kubernetes object

Use case: scale backend based on Ingress request rate
  Ingress controller exposes 'requests_per_second' on the Ingress object
  HPA scales backend Deployment when total requests exceed 10,000/s
  Single metric from one object drives pod count

Why Object and not Pods?
  The metric belongs to the INGRESS, not to the backend pods.
  There is one Ingress, so one metric value — not one per pod.
  HPA compares that single total value against the target.
  Pods type would try to read the metric from each backend pod,
  which does not apply here — the metric source is the Ingress itself.
```

**Type: External** — requires external metrics adapter

```
Pipeline: external system (SQS, Kafka) → adapter
          → external.metrics.k8s.io → HPA
Requires: an external metrics adapter installed in the cluster
Scope:    metric with NO associated Kubernetes object

Use case: SQS queue depth scaling
  AWS SQS queue depth metric published to cluster via adapter
  HPA scales worker Deployment to keep 30 messages per worker pod
  Queue grows → metric rises → more worker pods → queue drains

Why External and not Object?
  SQS is not a Kubernetes object — it has no Kind, no namespace,
  no API in the Kubernetes API server.
  Object type's describedObject field must name a real Kubernetes
  object (Ingress, Service, etc.). An SQS queue is AWS infrastructure,
  not a Kubernetes resource, so External is the correct type.

Why External and not Pods?
  Queue depth is not a per-pod metric — it is a property of the
  external queue itself. There is one queue, not one queue per pod.
```

**Custom metrics adapter vs external metrics adapter — the distinction:**

```
custom metrics adapter:  implements custom.metrics.k8s.io
                         for Pods and Object types
                         metric IS associated with a Kubernetes object
                         (a pod, or a named Kubernetes object)
                         Example adapters: Prometheus Adapter

external metrics adapter: implements external.metrics.k8s.io
                           for External type
                           metric has NO Kubernetes object association
                           metric comes from outside the cluster entirely
                           Example adapters: CloudWatch adapter, KEDA

Note: in practice, many adapters implement BOTH APIs.
  Prometheus Adapter: implements both custom.metrics.k8s.io AND
                      external.metrics.k8s.io — covers Pods, Object,
                      and External types from one installation.
  KEDA: its own controller + adapter — implements external.metrics.k8s.io
        and supports scale-to-zero (HPA minReplicas ≥ 1, KEDA can go to 0)

Hands-on for these types: see 02-hpa-advanced Steps 4–6 (theory) and
aws-eks-demos (practical with Prometheus Adapter / CloudWatch adapter)
```

> Types Pods, Object, and External require a metrics adapter installed in the cluster. This demo covers Resource and ContainerResource (built-in with metrics-server only).

---

### HorizontalPodAutoscaler — Complete Field Reference

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: nginx-hpa
  namespace: default
spec:

  # ── What to scale ──────────────────────────────────────────────
  scaleTargetRef:
    apiVersion: apps/v1         # API group of target workload
    kind: Deployment            # Deployment, StatefulSet, ReplicaSet,
                                # or any CRD with scale subresource
    name: nginx-deploy          # name of the target workload instance
                                # MUST be in the same namespace as the HPA
                                # cross-namespace scaleTargetRef is not supported
                                # the HPA object, scaleTargetRef, and any
                                # Object metric's describedObject must all
                                # share the same namespace

  # ── Replica bounds ─────────────────────────────────────────────
  minReplicas: 1                # never scale below this (default: 1)
                                # must be ≥ 1 — HPA cannot scale to zero
  maxReplicas: 5                # never exceed this (REQUIRED — no default)
                                # set this based on your infrastructure
                                # capacity and cost ceiling

  # ── Metrics ────────────────────────────────────────────────────
  metrics:
    # Type 1: Resource — CPU or memory averaged across all containers in pod
    - type: Resource
      resource:
        name: cpu               # "cpu" or "memory"
        target:
          type: Utilization     # Utilization = % of request
                                # AverageValue = raw value (e.g. "500m")
          averageUtilization: 50 # target 50% of request across all pods

    # Type 2: ContainerResource — specific container only (stable v1.30+)
    - type: ContainerResource
      containerResource:
        name: cpu
        container: app          # target ONLY this container (not sidecars)
        target:
          type: Utilization
          averageUtilization: 60

    # Type 3: Pods — custom metric averaged across pods
    #          requires metrics adapter implementing custom.metrics.k8s.io
    #          valid target.type: AverageValue ONLY (no Utilization, no Value)
    - type: Pods
      pods:
        metric:
          name: requests_per_second   # metric name adapter exposes
        target:
          type: AverageValue          # averaged across all pods of scaleTargetRef
          averageValue: "1000"        # target 1000 req/s PER POD average

    # Type 4: Object — metric from a single Kubernetes object
    #          requires metrics adapter implementing custom.metrics.k8s.io
    #          valid target.type: Value or AverageValue
    - type: Object
      object:
        metric:
          name: requests_per_second
        describedObject:              # the Kubernetes object the metric belongs to
          apiVersion: networking.k8s.io/v1   # must be in the SAME namespace
          kind: Ingress
          name: main-ingress
        target:
          type: Value                 # Value = raw total on the Ingress object
          value: "10000"              # scale when total Ingress req/s exceeds 10000
                                      # use AverageValue to divide by current pod count

    # Type 5: External — metric from outside Kubernetes entirely
    #          requires metrics adapter implementing external.metrics.k8s.io
    #          valid target.type: Value or AverageValue
    - type: External
      external:
        metric:
          name: sqs_queue_depth
          selector:
            matchLabels:
              queue: orders           # adapter uses this to identify the external resource
        target:
          type: AverageValue          # total queue depth / current replicas
          averageValue: "30"          # target 30 messages per worker pod

  # ── Custom Behaviour (optional) ────────────────────────────────
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0   # 0 = scale up immediately (default)
                                      # > 0 = wait this many seconds before
                                      #       acting on scale-up recommendation
      selectPolicy: Max               # Max: use most aggressive policy
                                      # Min: use least aggressive policy
                                      # Disabled: block all scale-ups
      tolerance: 0.1                  # default 10% — scale if outside range
      policies:
        - type: Pods                  # Pods: absolute pod count per period
          value: 4                    # add at most 4 pods per periodSeconds
          periodSeconds: 15           # evaluation window for this policy
        - type: Percent               # Percent: % of current count per period
          value: 100                  # double pod count per period
          periodSeconds: 60           # evaluation window for this policy
    scaleDown:
      stabilizationWindowSeconds: 300 # 300 = 5 minutes (default)
                                      # records highest recommendation over
                                      # this window; only scales to that high
      selectPolicy: Max
      policies:
        - type: Pods
          value: 2                    # remove at most 2 pods per 60 seconds
          periodSeconds: 60
```

**Field-by-field explanation:**

| Field | Default | What it controls | Common mistake |
|---|---|---|---|
| `minReplicas` | 1 | Floor — HPA never goes below this | Setting too high wastes resources during quiet periods |
| `maxReplicas` | none (required) | Ceiling — HPA never exceeds this | Forgetting to set this causes unbounded scale-out |
| `metrics[].type` | — | Which metrics pipeline to use | Using `Pods`/`Object`/`External` without installing an adapter |
| `metrics[].resource.target.type` | — | `Utilization` (% of request) or `AverageValue` (raw) | Using `Utilization` without `resources.requests` set on all containers |
| `metrics[].pods.target.type` | — | Must be `AverageValue` — only valid option | Using `Utilization` or `Value` with Pods type — invalid |
| `metrics[].object.target.type` | — | `Value` (raw total) or `AverageValue` (÷ pod count) | Using `Value` when you want per-pod scaling — use `AverageValue` instead |
| `metrics[].external.target.type` | — | `Value` (raw total) or `AverageValue` (÷ pod count) | Same as Object — choose based on whether metric is a total or per-pod signal |
| `behavior.scaleUp.stabilizationWindowSeconds` | 0 | How long HPA waits before acting on scale-up | Setting this to 300 (scale-down default) silently delays scale-up |
| `behavior.scaleDown.stabilizationWindowSeconds` | 300 | How long HPA waits before acting on scale-down | Setting to 0 causes aggressive scale-down on transient load drops |
| `behavior.*.selectPolicy` | Max | Which policy wins when multiple policies apply | `Disabled` blocks ALL scaling in that direction |
| `behavior.*.policies[].type` | — | `Pods` (absolute count) or `Percent` (relative %) | Percent at small replica counts can be slower than Pods |
| `behavior.*.policies[].periodSeconds` | — | Window for this policy | Too short allows rapid oscillation |

**Namespace rule:**

HPA, scaleTargetRef, and any `Object` metric's `describedObject` must all be in the same namespace. Cross-namespace HPA targeting is not supported. If `scaleTargetRef.name` points to a Deployment in a different namespace, the HPA will silently fail with `ScalingActive: False` / `FailedGetScale` — no error at apply time.

**`behavior.*.selectPolicy`** 

when you define multiple policies inside a `scaleUp` or `scaleDown` block, the HPA evaluates all of them every cycle and uses `selectPolicy` to decide which result wins:

```
selectPolicy: Max   (default)
  → picks the policy that results in the MOST change (most aggressive)
  → for scaleUp: the policy that adds the most pods wins
  → for scaleDown: the policy that removes the most pods wins
  → use when you want fast reaction — the most aggressive policy drives the outcome

selectPolicy: Min
  → picks the policy that results in the LEAST change (most conservative)
  → for scaleUp: the policy that adds the fewest pods wins
  → for scaleDown: the policy that removes the fewest pods wins
  → use when you want to cap the rate of change conservatively

selectPolicy: Disabled
  → blocks ALL scaling in this direction entirely
  → example: scaleDown.selectPolicy: Disabled prevents any scale-down
  → useful during an incident: block scale-down while investigating

Real-world example — two policies, Max vs Min:
  policies:
    - type: Percent  value: 100  periodSeconds: 30   → doubles current count
    - type: Pods     value: 4    periodSeconds: 15   → adds 4 per 15s

  Starting at 1 replica, sustained high load, after 30s:
    Percent says: 1 → 2  (+1)
    Pods says:    1 → 5  (+4, two 15s windows in 30s)
    selectPolicy: Max → takes Pods result → 5 replicas
    selectPolicy: Min → takes Percent result → 2 replicas
```

**Can you use both `Pods`-type and `Percent`-type policies in the same HPA?**

Yes — `policies` is a list and accepts multiple entries of different types. This is exactly
the example above. The `selectPolicy` field then arbitrates which one drives the outcome
each cycle.

```yaml
behavior:
  scaleUp:
    selectPolicy: Max
    policies:
      - type: Percent   # relative — doubles current count per window
        value: 100
        periodSeconds: 30
      - type: Pods      # absolute — adds at most 4 per window
        value: 4
        periodSeconds: 15
```

Both policies are evaluated every cycle. `selectPolicy: Max` means the one proposing the
larger replica count wins. The field is named `policies` (plural) because it accepts a list
from the start — the design explicitly allows mixing `Pods` and `Percent` entries to express
complex scaling shapes (e.g. "double up to 10, then add 2 at a time above that").

---

### Understanding VPA — Vertical Pod Autoscaler

#### VPA Architecture and Components

VPA consists of three independent components running in kube-system. They are maintained by Kubernetes SIG Autoscaling in the `kubernetes/autoscaler` GitHub repository — the same repository that hosts Cluster Autoscaler.

```
vpa-recommender
  Role:    observe and recommend
  Input:   queries metrics-server (metrics.k8s.io) for current CPU/memory
           reads VerticalPodAutoscalerCheckpoint objects for historical data
  Process: builds a histogram model of usage per container over time
           calculates percentile-based recommendations
  Output:  writes recommendations to VPA object .status.recommendation
           writes/updates VerticalPodAutoscalerCheckpoint objects

vpa-updater
  Role:    enforce recommendations on running pods
  Input:   reads VPA object .status.recommendation
           reads PodDisruptionBudget objects
  Process: identifies pods whose current requests differ significantly
           from the Target recommendation
           checks PDB to confirm eviction is safe
  Output:  evicts pods via Eviction API (NOT direct DELETE — respects PDB)
           does NOT modify resource values itself — eviction triggers recreate

vpa-admission-controller (Mutating Webhook)
  Role:    inject correct resources at pod creation
  Input:   intercepts ALL pod creation requests to kube-apiserver
           reads VPA object .status.recommendation
  Process: checks if a VPA applies to this pod
           if yes: patches the pod spec with recommended resource values
  Output:  modified pod spec with injected CPU/memory requests
           called on initial create AND after updater evictions
```

**How the three components work together — lifecycle:**

```
Step 1: You deploy a Deployment and create a VPA object (any mode)

Step 2 (Recommender): begins querying metrics-server every 60s
       → accumulates CPU/memory samples into a histogram per container
       → after ~1 minute: writes initial recommendation to VPA.status
       → continues refining as more data accumulates (default: 8 days)
       → writes/updates VPACheckpoint for persistence across restarts

Step 3a (Off mode only — stops here):
       Recommendations visible in VPA.status, but nothing is applied

Step 3b (Recreate or InPlaceOrRecreate mode):
       Updater reads VPA.status recommendation
       → identifies pods where current requests differ significantly
       → checks PDB: if eviction would violate budget, waits
       → evicts pod via Eviction API

Step 4: Deployment controller recreates the evicted pod

Step 5: Admission Controller intercepts the new pod's creation
       → finds the matching VPA object
       → patches pod spec: injects Target CPU/memory as requests
       → pod starts with right-sized resources

Step 6: Recommender continues observing the newly-sized pod
       → refines recommendations over time
```

**Installation:**
```bash
# VPA is NOT bundled with Kubernetes
# Source: github.com/kubernetes/autoscaler

git clone https://github.com/kubernetes/autoscaler.git
cd autoscaler/vertical-pod-autoscaler/hack
./vpa-up.sh

# Uninstall:
./vpa-down.sh
```

#### VPA Algorithm — How Recommendations Are Calculated

**Inputs to the algorithm:**

```
Input 1: Current metrics — from metrics-server (metrics.k8s.io)
         CPU usage (nanocores), memory working set (bytes) per container
         polled every 60 seconds

Input 2: Historical data — from VerticalPodAutoscalerCheckpoint
         CPU and memory usage histograms persisted across Recommender restarts
         decayed over time — older samples have less weight than recent ones
         default observation window: 8 days (configurable via --history-length)

Input 3: resourcePolicy — from the VPA spec
         containerPolicies[].minAllowed → floor constraint
         containerPolicies[].maxAllowed → ceiling constraint
```

**The histogram model — what it is with a concrete example:**

Rather than tracking a raw time series of every sample, VPA Recommender maintains a weighted histogram per container per resource. Think of it as a bar chart where:
- The X-axis represents CPU usage values (bucketed into ranges, e.g. 0–10m, 10–20m, etc.)
- The Y-axis represents how much "weight" (frequency × recency decay) falls in each bucket
- Recent samples are weighted higher than old samples

```
Example: nginx container CPU usage over 10 minutes of load

Observation timeline:
  t=0s   CPU=10m   (idle)
  t=15s  CPU=110m  (request arriving)
  t=30s  CPU=115m
  t=45s  CPU=108m
  t=60s  CPU=112m
  t=75s  CPU=10m   (quiet period)
  t=90s  CPU=11m

Histogram buckets (simplified):
  0–20m:   weight=2.1  (two observations, lower weight due to older)
  100–120m: weight=4.8  (four recent observations, higher weight)
  80–100m:  weight=0.0
  ...

90th percentile: the value below which 90% of the total weight falls
  → the histogram says: 90% of the time (by weight), usage is at or below 113m
  → Target = 113m
```

The histogram is stored in the VerticalPodAutoscalerCheckpoint object. If the Recommender pod restarts, it resumes from the checkpoint rather than starting over.

**Observation window and configurability:**

```
Default observation window: 8 days (--history-length flag)
Minimum before recommendation: approximately 1 minute of data
                               (enough for a first rough recommendation)

To adjust the window (on VPA Recommender deployment):
  --history-length=24h   → use only last 24 hours of data
  --history-length=168h  → use last 7 days (default is 192h = 8 days)
```

**The output fields — what each means and what triggers scaling:**

```
Target:
  → 90th percentile of observed usage over the history window
  → This is what VPA WILL SET as resources.requests if mode=Recreate/InPlaceOrRecreate
  → "90% of the time, the container needs at most this much"
  → Scaling trigger: Updater compares current requests to Target
                    if they differ significantly, Updater evicts the pod

Lower Bound:
  → safety margin below Target
  → calculated as approximately 25th percentile (varies by VPA version)
  → "if requests are set this low, there is high risk of throttling or OOMKill"
  → VPA will not recommend below minAllowed from resourcePolicy
  → NOT directly used by Updater for eviction decisions — that uses Target

Upper Bound:
  → VPA's estimate of the maximum the container could ever need
  → constrained by maxAllowed from resourcePolicy — VPA will not recommend above it
  → "above this value is wasteful — the container has never needed this much"
  → NOT a ceiling the Updater enforces — it is informational

Uncapped Target:
  → the raw percentile recommendation BEFORE applying any resourcePolicy constraints
    (minAllowed / maxAllowed)
  → represents what the algorithm actually sees from usage data alone
  → may be below minAllowed (algorithm wants to go lower but policy blocks it)
  → may be above maxAllowed (algorithm wants to go higher but policy blocks it)

Why Uncapped Target exists:
  When Target and Uncapped Target differ, it tells you that a policy constraint
  is overriding the algorithm's data-driven recommendation. Without Uncapped Target
  you would not know whether Target reflects actual usage or a policy floor/ceiling.

  If Target = Uncapped Target:
    → policy constraints are not affecting the recommendation
    → Target accurately reflects observed usage — trust it

  If Target > Uncapped Target:
    → minAllowed is raising the floor above what usage data warrants
    → action: your minAllowed may be too conservative — consider lowering it
    → example: container never uses more than 30m CPU, but minAllowed=100m
               forces Target to 100m even though usage data suggests 30m

  If Target < Uncapped Target:
    → maxAllowed is capping the recommendation below what usage data warrants
    → action: your maxAllowed may be too restrictive — the container needs more
    → example: container peaks at 2 CPU, but maxAllowed=500m
               forces Target to 500m even though usage suggests 2000m
               → the container will be CPU-throttled at peaks

Concrete example (from Step 10 lab output):
  Container: nginx (idle after lab cleanup)
  resourcePolicy: minAllowed.cpu=50m

  Raw histogram 90th pct: 49m  ← below minAllowed (container barely uses CPU)
  Uncapped Target: cpu=49m     ← what the algorithm wants to set
  minAllowed:      cpu=50m     ← policy floor
  Target:          cpu=50m     ← policy raises it to floor

  Target (50m) ≠ Uncapped Target (49m):
    → minAllowed is active: the 1m difference is a policy floor, not real usage
    → in this case the effect is trivial (1m)
    → in a busier scenario the difference could be significant:
      Uncapped=5m vs Target=100m → minAllowed is making the pod 20x over-provisioned
      → lower minAllowed to reclaim wasted capacity
```

**Scale-down decision:**

VPA does not have an equivalent to HPA's stabilisation window. The Updater evicts a pod when its current requests fall outside the [Lower Bound, Upper Bound] range, or when the current requests differ significantly from Target. The Updater polls on its own schedule and respects PDB — it will wait if eviction would violate the budget. There is no separate "scale-down delay" like HPA's 5-minute window.

**Complete worked example — all fields:**

```
Container: nginx
Observation: 8 days of mixed traffic
Resources currently set: cpu=100m, memory=128Mi

Recommender builds histogram:
  CPU:    90th pct = 143m, 25th pct = 50m
  Memory: 90th pct = 250Mi, 25th pct = 200Mi

resourcePolicy:
  minAllowed: cpu=50m, memory=64Mi
  maxAllowed: cpu=2, memory=2Gi

Recommendation output:
  Target:         cpu=143m, memory=250Mi   ← 90th pct, within policy bounds
  Lower Bound:    cpu=50m,  memory=200Mi   ← ~25th pct, floored at minAllowed
  Upper Bound:    cpu=2,    memory=2Gi     ← capped at maxAllowed
  Uncapped Target: cpu=143m, memory=250Mi  ← same as Target (policy not clamping)

Updater sees:
  Current requests: cpu=100m (below Target of 143m), memory=128Mi (below 250Mi)
  Both below Target → pod is under-provisioned → Updater evicts

After eviction + recreation + Admission Controller:
  New requests: cpu=143m, memory=250Mi   ← Target injected by Admission Controller

Now if traffic drops to very low for 8 days:
  Target might recalculate to: cpu=50m, memory=200Mi
  Current requests: cpu=143m (above Target of 50m) → over-provisioned
  Updater evicts again → Admission Controller injects cpu=50m, memory=200Mi
```

#### Multi-Container Pods and containerPolicies

VPA tracks EACH container in a pod separately and produces independent recommendations per container. This is by design — the app container and a log-shipping sidecar have entirely different resource profiles.

**Where containerPolicies fits:**

`containerPolicies` is the field inside `spec.resourcePolicy` that lets you configure per-container VPA behaviour:

```yaml
spec:
  resourcePolicy:
    containerPolicies:
      - containerName: app              # target this specific container
        minAllowed:
          cpu: 100m
          memory: 256Mi
        maxAllowed:
          cpu: 4
          memory: 4Gi
        controlledValues: RequestsAndLimits

      - containerName: sidecar          # different settings for the sidecar
        minAllowed:
          cpu: 10m
          memory: 32Mi
        maxAllowed:
          cpu: 500m
          memory: 128Mi
        controlledValues: RequestsOnly  # only adjust requests; leave limits alone

      - containerName: "*"             # wildcard: applies to all containers
        mode: "Off"                    # not matched by the above rules
                                       # Off = VPA observes but never changes
                                       # Use to exclude containers from updates
                                       # while still getting recommendations
```

```
containerName: "app"   → applies only to the container named "app"
containerName: "*"     → wildcard — applies to every container not matched
                          by a more specific containerName rule above it

mode: "Auto"           → VPA manages this container (observe + recommend + update)
mode: "Off"            → VPA observes and records (recommendations appear in status)
                          but the Updater and Admission Controller skip this container
                          useful when you want to exclude one container in a pod
                          from VPA changes while still seeing what it would recommend

controlledValues: "RequestsAndLimits"
  → VPA adjusts BOTH resources.requests and resources.limits
  → limits are scaled proportionally to maintain the original request:limit ratio

controlledValues: "RequestsOnly"
  → VPA adjusts resources.requests only
  → resources.limits remain exactly as set in the manifest
  → use when you want VPA to right-size requests but preserve custom limits
```

#### VPA Update Modes

```
Off:
  Recommender: ✅ runs — writes to VPA.status
  Updater:     ❌ does not evict pods
  Admission:   ❌ does not modify pod resources
  Result:      recommendations visible — no pod changes ever
  Use for:     capacity planning; "what should my requests be?"
               safe to run on any workload in production without disruption

Initial:
  Recommender: ✅ runs — writes to VPA.status
  Updater:     ❌ does not evict running pods
  Admission:   ✅ injects resources only when pod is first created
  Result:      new pods start right-sized; running pods unchanged
  Use for:     gradual right-sizing — new pods get correct resources
               without disrupting currently running pods

Recreate (most common active mode):
  Recommender: ✅ runs
  Updater:     ✅ evicts pods when resources differ significantly from Target
               uses Eviction API — respects PDB
  Admission:   ✅ injects resources on every pod creation
  Result:      pods evicted and recreated with updated resources
  Use for:     active right-sizing where pod restart is acceptable
               most stateless workloads

InPlaceOrRecreate (preferred over Recreate for production):
  Recommender: ✅ runs
  Updater:     ✅ attempts in-place resize first (no restart required)
               falls back to Recreate if in-place resize is not supported
               or fails (requires Kubernetes InPlacePodVerticalScaling feature gate)
  Admission:   ✅ injects resources on creation
  Result:      resize without restart if possible — less disruption
  Use for:     production — preferred over bare Recreate

Auto (DEPRECATED since VPA v1.4+):
  Currently equivalent to Recreate
  DO NOT USE — will be removed in a future API version
  If you see this warning:
  "Warning: UpdateMode 'Auto' is deprecated and will be removed in a
   future API version. Use 'Recreate', 'Initial', or
   'InPlaceOrRecreate' instead."
  → Replace "Auto" with "Recreate" or "InPlaceOrRecreate" immediately
```

**Updater and PodDisruptionBudget:**

```
VPA Updater uses the Eviction API — it respects PDB
  → reads minAvailable / maxUnavailable before evicting
  → will not evict if doing so would violate the budget
  → waits until PDB permits eviction

This is in contrast to HPA scale-down, which uses direct DELETE
and does NOT consult PDB (see HPA and PDB section above)

Practical setup: if your workload needs VPA + high availability:
  Deployment with replicas ≥ 2
  PDB with minAvailable=1 (allows VPA to evict one at a time)
  VPA mode: Recreate or InPlaceOrRecreate
```

#### What VPA Can Target

```
Supported:
  Deployment      → most common — Deployment controller recreates evicted pods
  StatefulSet     → supported — ordered pod eviction preserved
  DaemonSet       → supported — use carefully (one pod per node; eviction
                    temporarily removes the pod from that node)
  ReplicaSet      → supported (prefer Deployment)
  Job/CronJob     → Initial mode only — Updater will not evict running Job pods
                    since they are run-to-completion (no controller to recreate them
                    mid-run); Initial injects correct resources at pod start
  Custom resources → any resource whose pods have labels matching the VPA
                     targetRef selector and whose controller recreates evicted pods
```

```
NOT supported:

Standalone pods (pods not managed by any controller):
  Why: VPA Updater evicts pods so the controller recreates them with new resources.
       A standalone pod has no controller — eviction just deletes it permanently.
       The pod is gone and nothing recreates it.
       Fix: always use a Deployment (even with replicas: 1) for VPA to work.
       A Deployment with replicas: 1 is a "single-pod app", which IS supported.

  "Standalone pod" ≠ "single-pod app":
    Standalone pod    → no controller, exists directly as a Pod object
                        VPA cannot target it
    Single-pod app    → Deployment with replicas: 1 (or StatefulSet, etc.)
                        VPA CAN target it — the controller recreates evicted pods

Pod-level resource stanzas (kubernetes.io/pod-level resources, beta v1.34+):
  Why: VPA operates at the CONTAINER level. It reads per-container usage from
       cAdvisor and produces per-container recommendations. The pod-level
       resource spec (spec.resources at pod level, not container level) is a
       newer feature that VPA does not currently handle — it will not inject
       pod-level resources, and pod-level specs may interfere with VPA's
       container-level injection. Use container-level resources with VPA.
```

#### VPA CRDs and kubectl Commands

```
Two CRDs installed with VPA:

1. VerticalPodAutoscaler (vpa) — autoscaling.k8s.io/v1
   What you create: the configuration and recommendation object
   Contains: targetRef, updatePolicy, resourcePolicy, status/recommendations
   You create and manage these directly

2. VerticalPodAutoscalerCheckpoint (vpacheckpoint) — autoscaling.k8s.io/v1
   Why it exists: the Recommender builds a histogram model of usage over days.
                  If the Recommender pod restarts (upgrade, crash, eviction),
                  all that accumulated histogram data would be lost and the
                  Recommender would have to start from scratch — no recommendations
                  for ~1 minute minimum, up to hours for a stable recommendation.
   What it does:  persists the histogram data to etcd via this CRD object.
                  On restart, the Recommender reads its checkpoints and resumes
                  from where it left off — no data loss, no recommendation gap.
   How it works:  one VPACheckpoint object per container per VPA object
                  Recommender creates and updates them automatically
                  You do not create these — VPA manages them

kubectl commands:
  kubectl get vpa                          # list all VPAs
  kubectl describe vpa <name>              # full detail including recommendations
  kubectl get vpa <name> -o yaml           # full YAML including status
  kubectl get vpacheckpoint                # inspect historical histogram data
  kubectl describe vpacheckpoint <name>    # histogram contents + last update time
  # No imperative create for VPA — must be defined declaratively
```

**kubectl get vpa — output explained:**

```bash
kubectl get vpa
```

```
NAME               MODE      CPU    MEM     PROVIDED   AGE
nginx-vpa-off      Off                      False      5s
nginx-vpa-recreate Recreate  143m   250Mi   True       2m50s

NAME      → VPA object name (from metadata.name)
MODE      → update mode: Off, Initial, Recreate, InPlaceOrRecreate
CPU       → recommended CPU request from Target field
            blank = recommendation not yet available (wait ~1 min)
MEM       → recommended memory request from Target field
            blank = recommendation not yet available
PROVIDED  → True = recommendation is ready (RecommendationProvided condition is True)
            False = Recommender still collecting data
            stay False beyond 5 minutes: check vpa-recommender logs
AGE       → how long this VPA object has existed
```

**kubectl describe vpa — key sections explained:**

```bash
kubectl describe vpa nginx-vpa-off
```

```
Spec:
  Target Ref:
    Kind: Deployment          → the kind of workload VPA is watching
    Name: nginx-deploy        → the specific workload instance

  Update Policy:
    Update Mode: Off          → Off: observe only; Recreate: evict and update;
                                Initial: inject at creation; InPlaceOrRecreate: prefer in-place

  Resource Policy:
    Container Policies:
      Container Name: nginx
      Min Allowed:
        Cpu: 50m              → VPA will never recommend below this
        Memory: 64Mi            (protects against over-aggressive downsizing)
      Max Allowed:
        Cpu: 2                → VPA will never recommend above this
        Memory: 2Gi             (prevents runaway recommendation)

Status:
  Conditions:
    Type: RecommendationProvided
    Status: True              → True:  recommendation is ready and current
                                False: still collecting — wait ~1 minute
                                       if False after 5+ minutes, check
                                       vpa-recommender pod logs

  Recommendation:
    Container Recommendations:
      Container Name: nginx

      Lower Bound:            → minimum safe resources for this container
        Cpu: 50m                set below this → high probability of
        Memory: 250Mi           CPU throttling or OOMKill
                                floored at resourcePolicy.minAllowed

      Target:                 → the value VPA WILL SET as requests
        Cpu: 143m               90th percentile of observed usage
        Memory: 250Mi           the Updater compares current requests to this
                                if different, it triggers eviction

      Uncapped Target:        → Target recommendation BEFORE policy constraints
        Cpu: 49m                if this differs from Target, a policy constraint
        Memory: 250Mi           is clamping the recommendation:
                                Uncapped < Target → minAllowed is raising the floor
                                Uncapped > Target → maxAllowed is capping the ceiling
                                Uncapped == Target → policy is not affecting anything

      Upper Bound:            → maximum observed need (informational)
        Cpu: 2                  above this → wasteful allocation
        Memory: 2Gi             capped at resourcePolicy.maxAllowed
                                this is NOT a ceiling VPA enforces —
                                it is a signal that your maxAllowed
                                matches actual observed peaks

Events:                       → check for warnings if PROVIDED stays False
  Warning  FailedToReconcileVPA  → check vpa-recommender logs
  Normal   EvictedPod            → Updater evicted a pod (mode=Recreate)
```

**kubectl get vpacheckpoint — what it contains:**

```bash
kubectl get vpacheckpoint
# NAME                      AGE
# nginx-vpa-off-nginx       2m

kubectl describe vpacheckpoint nginx-vpa-off-nginx
```

```
Spec:
  Container Name: nginx           → which container this checkpoint covers
  VPA Object Name: nginx-vpa-off  → which VPA this checkpoint belongs to

Status:
  Cpu Histogram:                  → the stored histogram of observed CPU usage
    BucketWeights: [...]            bucket = usage range, weight = accumulated
                                    frequency × recency decay factor
    ReferenceTimestamp: ...         when this histogram segment was recorded
    TotalWeight: 1.0

  Memory Histogram: [...]         → same structure for memory usage

  LastUpdateTime: ...             → when Recommender last wrote to this checkpoint
                                    stale LastUpdateTime may indicate Recommender
                                    is not running or not finding the pods
  Version: ...                    → histogram format version

What this tells you:
  Recommender uses this to restore its model after restart
  BucketWeights show which CPU/memory ranges are most common
  TotalWeight shows how much data has been accumulated
  You should not need to edit or delete checkpoints manually
  VPA creates one checkpoint per container per VPA object
```

---

### VerticalPodAutoscaler — Complete Field Reference

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: nginx-vpa
  namespace: default
spec:

  # ── What to scale ──────────────────────────────────────────────
  targetRef:
    apiVersion: apps/v1           # API group of target workload
    kind: Deployment              # Deployment, StatefulSet, DaemonSet, etc.
                                  # NOT standalone Pod — must have a controller
    name: nginx-deploy            # name of the target workload instance
                                  # MUST be in the same namespace as the VPA
                                  # cross-namespace VPA targeting is not supported

  # ── Update mode ────────────────────────────────────────────────
  updatePolicy:
    updateMode: "Recreate"        # Off:               recommend only, never evict
                                  # Initial:           inject at pod creation only
                                  # Recreate:          evict + recreate with new resources
                                  # InPlaceOrRecreate: try in-place first, fallback Recreate
                                  # "Auto":            DEPRECATED — do not use

  # ── Resource constraints per container ─────────────────────────
  # resourcePolicy is OPTIONAL — omitting it lets VPA manage all containers
  # with no bounds (unconstrained recommendations from usage data alone)
  resourcePolicy:
    containerPolicies:
      # Each entry targets one container by name, or "*" for all unmatched
      - containerName: nginx      # exact container name from the pod spec
                                  # or "*" for wildcard (all remaining containers)

        mode: "Auto"              # Auto: VPA actively manages this container
                                  #       Recommender observes, Updater evicts,
                                  #       Admission Controller injects
                                  # Off:  VPA observes and records usage only
                                  #       Recommendations appear in .status
                                  #       but Updater and Admission Controller
                                  #       skip this container entirely

        minAllowed:               # VPA floor — recommendation never goes below this
          cpu: 50m                # protects against CPU throttling from too-small requests
          memory: 64Mi            # protects against OOMKill from too-small memory
                                  # if omitted: no floor — VPA can recommend arbitrarily low

        maxAllowed:               # VPA ceiling — recommendation never goes above this
          cpu: 2                  # prevents unbounded resource recommendations
          memory: 2Gi             # set based on node capacity and cost tolerance
                                  # if omitted: no ceiling — VPA can recommend arbitrarily high

        controlledResources:      # which resources VPA manages for this container
          - cpu                   # default if omitted: [cpu, memory]
          - memory                # omit a resource to leave it entirely unmanaged
                                  # example: [memory] only → VPA adjusts memory, never CPU

        controlledValues:         # what VPA updates per managed resource
          # RequestsAndLimits (default if omitted):
          #   VPA updates resources.requests AND resources.limits
          #   limits are scaled proportionally — original request:limit ratio maintained
          #   example: request=100m limit=500m (ratio 1:5)
          #            VPA target=200m → sets request=200m limit=1000m (preserves 1:5)
          #
          # RequestsOnly:
          #   VPA updates resources.requests ONLY
          #   resources.limits remain exactly as set in the manifest
          #   use when you have custom limits you want to preserve
          #   use when container hits OOMKill but you cannot raise limits
```

**status — written by VPA after observing:**

```yaml
status:
  conditions:
    - type: RecommendationProvided
      status: "True"              # "True" = recommendation available
                                  # "False" = still collecting (wait ~1 min)
      lastTransitionTime: ...
      reason: RecommendationProvided

  recommendation:
    containerRecommendations:
      - containerName: nginx

        lowerBound:               # minimum safe — throttling/OOMKill likely below this
          cpu: 50m
          memory: 250Mi

        target:                   # recommended value — VPA will SET this as requests
          cpu: 143m               # 90th percentile of observed usage
          memory: 250Mi

        uncappedTarget:           # recommendation before min/max policy applied
          cpu: 49m                # compare with target to diagnose policy clamping
          memory: 250Mi

        upperBound:               # maximum observed — wasteful to allocate above this
          cpu: 2                  # informational only — not enforced by Updater
          memory: 2Gi
```

**Field-by-field explanation:**

| Field | Default | What it controls | Common mistake |
|---|---|---|---|
| `updatePolicy.updateMode` | Recreate | Off/Initial/Recreate/InPlaceOrRecreate | Using "Auto" — deprecated since v1.4 |
| `resourcePolicy` (whole block) | none (optional) | Per-container bounds and behaviour | Omitting entirely lets VPA make unconstrained recommendations |
| `resourcePolicy.containerPolicies[].containerName` | required | Which container to configure; `"*"` = all unmatched | Typo in container name — VPA silently falls back to `"*"` |
| `resourcePolicy.containerPolicies[].mode` | Auto | `Auto` (manage) or `Off` (observe only for this container) | Not setting `Off` on containers you want VPA to leave alone |
| `resourcePolicy.containerPolicies[].minAllowed` | none | VPA floor — recommendation never goes below this | Setting too high locks in over-provisioning regardless of actual usage |
| `resourcePolicy.containerPolicies[].maxAllowed` | none | VPA ceiling — recommendation never goes above this | Omitting maxAllowed allows unbounded recommendations on spiky workloads |
| `resourcePolicy.containerPolicies[].controlledResources` | [cpu, memory] | Which resources VPA tracks and adjusts | Forgetting to set [memory] only — VPA then also adjusts CPU unexpectedly |
| `resourcePolicy.containerPolicies[].controlledValues` | RequestsAndLimits | Whether VPA also adjusts limits proportionally | Using RequestsAndLimits when you have custom limits you want preserved |

**Namespace rule:**

VPA, `targetRef`, and the pods being managed must all be in the same namespace. Cross-namespace VPA targeting is not supported. A VPA in `namespace: monitoring` cannot target a Deployment in `namespace: default` — it will silently fail to find the target and produce no recommendations.

**All resourcePolicy options summary:**

```
containerPolicies[].mode:
  Auto  → VPA observes, recommends, and updates this container
  Off   → VPA observes and recommends ONLY; Updater and Admission skip it

containerPolicies[].controlledValues:
  RequestsAndLimits → VPA updates requests + limits (proportional ratio preserved)
  RequestsOnly      → VPA updates requests only; limits unchanged

containerPolicies[].controlledResources: [cpu, memory]
  Any subset:  [cpu]         → VPA manages CPU only
               [memory]      → VPA manages memory only
               [cpu, memory] → VPA manages both (default)

containerPolicies[].minAllowed / maxAllowed:
  No defaults — omitting means no constraint in that direction
  When set: recommendation is clamped to [minAllowed, maxAllowed]
  Uncapped Target shows what the algorithm would recommend without these bounds
```

---

### Cluster Autoscaler and Other Scaling Types

#### Cluster Autoscaler (CA)

```
Trigger (scale-up):   pods in Pending state (cannot schedule — no node capacity)
Action:               calls cloud provider API → provisions new VM → VM joins cluster
                      → pending pods schedule on new node

Trigger (scale-down): node has been underutilised for 10 minutes (configurable)
                      AND all pods on it could fit on other nodes
                      AND no pods with "cluster-autoscaler.kubernetes.io/safe-to-evict: false"
Action:               drains node → terminates VM
                      drain uses Eviction API → respects PDB

Cloud provider support:
  CA uses a cloud provider plugin model. Plugins exist for:
  AWS (EC2 Auto Scaling Groups), GCP (Managed Instance Groups), Azure (Scale Sets),
  DigitalOcean, OpenStack, Hetzner, and others.
  Each cloud provider contributes and maintains their plugin in the
  kubernetes/autoscaler repository. CA itself is cloud-agnostic —
  the cloud provider plugin handles the actual API calls.

CRDs:  none — CA watches core Pod and Node objects.
       On AWS EKS, Karpenter (the modern CA replacement) DOES use CRDs:
       NodePool, EC2NodeClass. Karpenter is not covered in this series
       (minikube-based); refer to aws-eks-demos for hands-on coverage.

Requires: cloud provider API (AWS, GCP, Azure) — NOT demonstrable on minikube
```

> On minikube, HPA can scale pods and they will schedule as long as the cluster has capacity. CA is not needed locally. On EKS, CA or Karpenter handles node provisioning automatically.

**Safe combination with HPA:**
```
HPA scales pods → pods cannot schedule (no node capacity) → Pending
CA detects Pending pods → provisions new node (1–3 min typically)
New pods schedule → application scales out completely
```

#### Other Scaling Types

```
Cluster Proportional Autoscaler (CPA):
  Scales workloads in proportion to cluster size
  Use case: scale CoreDNS replicas as cluster grows
  Not covered in this demo

KEDA — Kubernetes Event-Driven Autoscaling:
  Event-driven scaling based on external queues, streams, metrics
  Scale-to-zero supported (HPA cannot go below minReplicas=1)
  Use case: message queue consumer — scale to 0 when queue empty
  Implements both custom.metrics.k8s.io and external.metrics.k8s.io
  Hands-on: aws-eks-demos

Karpenter:
  AWS-native node provisioner — modern replacement for CA on EKS
  Faster provisioning, more granular instance selection, spot/on-demand mix
  Uses NodePool and EC2NodeClass CRDs
  Hands-on: aws-eks-demos
```

---

### HPA vs VPA — Compare and Contrast

| | HPA | VPA |
|---|---|---|
| **What it scales** | Number of pod replicas | CPU/memory requests per container |
| **Scale direction** | Horizontal (out/in) | Vertical (up/down) |
| **Responds to** | Traffic spikes — more pods needed | Resource mis-sizing — requests wrong |
| **Best for** | Stateless workloads (web, API, workers) | Stateful workloads, single-pod apps, right-sizing |
| **Built into Kubernetes** | ✅ Yes — core, no extra install | ❌ No — separate install from kubernetes/autoscaler |
| **Maintained by** | Kubernetes SIG Autoscaling (core repo) | Kubernetes SIG Autoscaling (kubernetes/autoscaler) |
| **Requires metrics-server** | ✅ Yes | ✅ Yes (Recommender uses it) |
| **Eviction API** | ❌ No — direct DELETE | ✅ Yes — respects PDB |
| **Respects PDB** | ❌ No | ✅ Yes |
| **API version** | autoscaling/v2 | autoscaling.k8s.io/v1 |
| **CRDs** | HorizontalPodAutoscaler | VerticalPodAutoscaler, VerticalPodAutoscalerCheckpoint |
| **Imperative creation** | ✅ kubectl autoscale | ❌ declarative only |
| **Pod restart needed** | ❌ No — adds/removes pods | ✅ Yes (Recreate) or ❌ No (InPlaceOrRecreate) |
| **Works with standalone pod** | ❌ No (no replicas) | ❌ No (no controller to recreate after eviction) |
| **Can scale to zero** | ❌ No — minReplicas ≥ 1 | N/A |
| **Data retention** | N/A — reads live metrics | 8 days (histogram in VPACheckpoint) |

**Key parameters compared:**
```
HPA key parameters:
  minReplicas       → floor for replica count
  maxReplicas       → ceiling for replica count
  metrics[]         → what to measure (cpu, memory, custom, external)
  behavior          → scale speed and stabilisation windows
  averageUtilization → target % of request across pods

VPA key parameters:
  updateMode        → Off, Initial, Recreate, InPlaceOrRecreate
  minAllowed        → floor for recommended request
  maxAllowed        → ceiling for recommended request
  containerName     → which container to manage
  controlledValues  → RequestsAndLimits or RequestsOnly
```

**When to use which:**
```
Use HPA when:
  → traffic is variable and unpredictable
  → workload is stateless (each replica is identical)
  → application can handle multiple parallel instances
  → you want fast response to traffic spikes (seconds)

Use VPA when:
  → you do not know the right resource requests for a new app
  → traffic is steady but resource usage is unclear
  → workload is stateful (database, queue consumer)
  → you want to prevent OOMKill or CPU throttling
  → you want to reduce resource waste from over-provisioning

Safe combinations (HPA + VPA can coexist):
  HPA on CPU/memory + VPA in Off mode
    → HPA scales replicas on CPU/memory; VPA only recommends — no conflict
    → this is the most common safe pattern in production
  HPA on custom/external metrics + VPA in Recreate mode on CPU/memory
    → HPA uses a different signal (queue depth, request rate) — no interference
    → VPA adjusts requests; HPA is not watching requests — no conflict cycle
  All three together (HPA + VPA + CA):
    → CA responds to Pending pods (no node capacity)
    → CA does not interact with HPA or VPA decisions at all
    → CA adds nodes so HPA-created pods can schedule; VPA right-sizes those pods
    → SAFE as long as the HPA+VPA combination itself is safe (see above)

Conflict — only one specific combination:
  HPA on CPU/memory + VPA on CPU/memory (Recreate/Initial mode)
    → both tools watch and modify the same signal (CPU/memory requests)
    → VPA changes the denominator HPA uses → conflict cycle
    → the cycle: HPA scales out → VPA raises per-pod requests →
                 HPA sees lower % (higher denominator) → scales in →
                 fewer pods → higher per-pod load → VPA raises again
    → AVOID this combination ❌
```

**Sizing strategy — how to choose min/max values:**

Finding the right `minReplicas`/`maxReplicas` (HPA) and `minAllowed`/`maxAllowed` (VPA) is not guesswork — there is a methodology:

```
Step 1: Start with VPA in Off mode — no risk, observations only
  → deploy with best-guess resource requests (too high is safer than too low)
  → deploy a VPA with updateMode: "Off" and no resourcePolicy constraints
  → let it observe for at least 24-48 hours of representative traffic
  → read Target (90th pct) and Upper Bound from kubectl describe vpa
  → these become your starting resource requests in the Deployment manifest

Step 2: Right-size resource requests using VPA recommendations
  CPU request:    set to VPA Target (90th pct) — handles normal load
  Memory request: set to VPA Upper Bound (or slightly above) — memory OOMKill
                  is more disruptive than CPU throttling; be conservative
  Example:
    VPA Target:       cpu=143m, memory=250Mi
    VPA Upper Bound:  cpu=2,    memory=2Gi
    Set in manifest:  cpu=150m, memory=300Mi  (slight headroom above Target)

Step 3: Set HPA minReplicas
  Rule: number of replicas needed to handle baseline/off-peak traffic
        without HPA scaling (your always-on floor)
  Start at: 1 for dev/test; 2 for production (HA — tolerates one pod failure)
  Increase if: single pod at idle already uses >40% CPU (scale out before load)
  Example: if idle CPU is 30% of request → 1 replica is fine baseline

Step 4: Set HPA maxReplicas
  Rule: maximum replicas your infrastructure (nodes) can accommodate,
        capped by cost tolerance
  Formula: maxReplicas = (total schedulable node CPU) / (CPU request per pod) × 0.8
           (0.8 = 20% headroom for system pods and overhead)
  Example: 3 nodes × 2 CPU = 6 CPU total
           one system pod per node ≈ 0.2 CPU overhead each
           schedulable = 6 - 0.6 = 5.4 CPU
           CPU request per pod = 150m = 0.15 CPU
           maxReplicas = 5.4 / 0.15 × 0.8 = 28 (theoretical)
           Apply cost ceiling: if 10 pods is your cost limit → maxReplicas: 10
  Start conservative, raise based on observed peak traffic

Step 5: Set VPA minAllowed
  Rule: the minimum safe resource floor — below which the container
        will be throttled or OOMKilled under ANY traffic
  Start at: 50% of VPA Lower Bound (25th pct recommendation)
  Never set below: minimum needed for the container to start successfully
  Example: VPA Lower Bound cpu=50m → minAllowed.cpu=50m is reasonable
           If container crashes at startup with cpu=25m → set minAllowed=30m

Step 6: Set VPA maxAllowed
  Rule: maximum resources a single container should ever use
  Start at: 110-120% of VPA Upper Bound (observed maximum)
  Cap at:   node allocatable capacity (no point recommending more than fits)
  Watch:    Uncapped Target — if it exceeds maxAllowed, raise maxAllowed
            or the container will be perpetually under-provisioned
  Example: VPA Upper Bound = 2 CPU on a 4-CPU node → maxAllowed.cpu=2 is safe

Step 7: Monitor and iterate
  kubectl top pods                   → ongoing CPU/memory usage
  kubectl describe vpa               → Uncapped Target vs Target (policy impact)
  kubectl get hpa -w                 → scaling frequency (too often = threshold too tight)
  kubectl get events | grep Scale    → scale events (frequency and reason)
  Revise thresholds every 2-4 weeks for the first 2 months
```

---

## Lab Step-by-Step Guide

---

### Step 1 — Cluster Setup and Prerequisites

```bash
cd 11-auto-scaling/01-autoscaling/src

# Verify metrics-server is running (required for HPA and VPA)
kubectl get pods -n kube-system | grep metrics-server
kubectl top nodes
```

**Expected output:**
```
metrics-server-xxxxxxxxx-xxxxx   1/1   Running   0   ...

NAME        CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
3node       ...
3node-m02   ...
3node-m03   ...
```

If metrics-server is not running:
```bash
minikube addons enable metrics-server -p 3node
# Wait ~60 seconds, then verify:
kubectl get pods -n kube-system | grep metrics-server
kubectl top nodes
```

Verify control plane taint (pods should not schedule to control plane):
```bash
kubectl describe node 3node | grep Taints
# Expected: node-role.kubernetes.io/control-plane:NoSchedule
```

---

### Step 2 — Deploy nginx Application

**`src/nginx-deploy.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deploy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "100m"      # HPA target = 50% of this = 50m before scaling
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-svc
spec:
  type: ClusterIP
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
```

```bash
kubectl apply -f nginx-deploy.yaml
kubectl rollout status deployment/nginx-deploy
kubectl get pods -o wide
kubectl top pods
```

**Expected output:**
```
NAME                            READY   STATUS    NODE
nginx-deploy-xxxxxxxxx-xxxxx    1/1     Running   3node-m02

NAME                            CPU(cores)   MEMORY(bytes)
nginx-deploy-xxxxxxxxx-xxxxx    0m           3Mi
```

---

### Step 3 — Load Generator— busybox

`busybox` is used as the load generator — available on every node
without any additional pulls. It sends continuous HTTP requests to
the nginx service, driving CPU utilisation up.

**`src/load-generator.yaml`:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: load-generator
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: load
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          while true; do
            wget -q -O- http://nginx-svc > /dev/null 2>&1
          done
      resources:
        requests:
          cpu: "100m"
          memory: "32Mi"
        limits:
          cpu: "500m"
          memory: "64Mi"
```
> **Why busybox?** Lightweight, pre-cached on most nodes, no registry
> pull needed, simple wget-based load generation. For more realistic
> load patterns, `fortio` or `k6` are production-grade alternatives
> — both are open source, CNCF projects with rich reporting.
> `busybox` is sufficient for demonstrating HPA scaling behaviour.

```bash
kubectl apply -f load-generator.yaml
kubectl get pod load-generator

# Watch CPU rise (~30s)
watch kubectl top pods
```

**Expected output after ~30s:**
```
NAME                            CPU(cores)   MEMORY(bytes)
load-generator                  862m         6Mi
nginx-deploy-xxxxxxxxx-xxxxx    115m         15Mi
```

```
# Observation: nginx CPU is 115m against a request of 100m = 115% utilisation
# This is above the 50% target we will set in Step 4 — HPA will scale up
```

---

### Step 4 — HPA: CPU Based (autoscaling/v2)

**`src/hpa-cpu-v2.yaml`:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: nginx-hpa-cpu
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-deploy
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50    # target 50% of the 100m request = 50m average per pod
```

```bash
kubectl apply -f hpa-cpu-v2.yaml

# Watch in real time
kubectl get hpa nginx-hpa-cpu -w
```

**Expected output — scale-up observed:**
```
NAME           REFERENCE                  TARGETS           MINPODS  MAXPODS  REPLICAS
nginx-hpa-cpu  Deployment/nginx-deploy    cpu: <unknown>/50%  1      5        0
nginx-hpa-cpu  Deployment/nginx-deploy    cpu: 115%/50%       1      5        1
nginx-hpa-cpu  Deployment/nginx-deploy    cpu: 37%/50%        1      5        3
```

```
# Observation: <unknown>/50% → first scrape not yet done (metrics-server polls every 60s)
#              115%/50%     → current 115%, target 50% → formula: ceil[1 × 115/50] = ceil[2.3] = 3
#              37%/50%      → after 3 replicas: same load spread across 3 pods → 115/3 ≈ 38%
#              REPLICAS: 3  → HPA updated the scale subresource to 3
```

**Scale-up calculation verified:**
```
currentReplicas = 1
currentCPU = 115%
targetCPU = 50%

desiredReplicas = ceil[1 × (115/50)] = ceil[2.3] = 3 ✅
```

**Check full HPA status:**
```bash
kubectl describe hpa nginx-hpa-cpu
```

**Expected output:**
```
Metrics:
  resource cpu on pods (as a percentage of request): 37% (37m) / 50%

Conditions:
  AbleToScale:    True   ReadyForNewScale    → not in stabilisation window
  ScalingActive:  True   ValidMetricFound    → metrics pipeline working
  ScalingLimited: False  DesiredWithinRange  → 3 is within [1, 5]
```

**Observe scale-down — remove load:**
```bash
kubectl delete pod load-generator --grace-period=0 --force

# Watch scale-down (takes 5+ minutes — default stabilisation window)
kubectl get hpa nginx-hpa-cpu -w
```

**Expected output:**
```
nginx-hpa-cpu  Deployment/nginx-deploy  cpu: 0%/50%   1  5  3   ← CPU dropped to 0
nginx-hpa-cpu  Deployment/nginx-deploy  cpu: 0%/50%   1  5  3   ← still 3 (window)
...wait 5+ minutes...
nginx-hpa-cpu  Deployment/nginx-deploy  cpu: 0%/50%   1  5  2   ← scaled down
nginx-hpa-cpu  Deployment/nginx-deploy  cpu: 0%/50%   1  5  1   ← scaled down again
```

```
# Observation: 5-minute stabilisation window prevents immediate scale-down
#              HPA records the highest recommendation (3) across the 5-min window
#              Only starts removing pods after the window consistently shows lower demand
```

```bash
kubectl delete -f hpa-cpu-v2.yaml
```

---

### Step 5 — HPA: Memory Based (autoscaling/v2)

**`src/hpa-memory-v2.yaml`:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: nginx-hpa-memory
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-deploy
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 70    # target 70% of the 128Mi request = ~90Mi
```

```bash
kubectl apply -f hpa-memory-v2.yaml
kubectl get hpa nginx-hpa-memory
```

**Expected output (initial — metrics not yet collected):**
```
NAME               REFERENCE                  TARGETS                MINPODS  MAXPODS  REPLICAS
nginx-hpa-memory   Deployment/nginx-deploy    memory: <unknown>/70%  1        5        0
```

```
memory: <unknown>/70%  → metrics not yet collected
                          wait ~30s for metrics-server to report
```

Wait and re-check:
```bash
kubectl get hpa nginx-hpa-memory
```

**Expected output:**
```
NAME               TARGETS              MINPODS  MAXPODS  REPLICAS
nginx-hpa-memory   memory: 12%/70%      1        5        1
```

```
# Observation: 12%/70% → nginx uses ~15Mi memory of the 128Mi request = 12%
#              Below 70% target → no scaling triggered
#              Memory-based HPA requires a memory-consuming load to trigger
#              nginx at idle is not memory-intensive
```

```bash
kubectl describe hpa nginx-hpa-memory | grep -A5 "Metrics:"
```

**Expected output:**
```
Metrics:
  resource memory on pods (as a percentage of request): 12% (16Mi) / 70%
```

```bash
kubectl delete -f hpa-memory-v2.yaml
```

---

### Step 6 — HPA: Multiple Metrics (autoscaling/v2)

**`src/hpa-multi-metric.yaml`:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: nginx-hpa-multi
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-deploy
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 70
```

```bash
kubectl apply -f hpa-multi-metric.yaml
kubectl describe hpa nginx-hpa-multi | grep -A8 "Metrics:"
```

**Expected output:**
```
Metrics:
  resource cpu on pods (as a percentage of request):     <unknown> / 50%
  resource memory on pods (as a percentage of request):  <unknown> / 70%
```

Wait for metrics:
```bash
kubectl describe hpa nginx-hpa-multi | grep -A8 "Metrics:"
```

**Expected output:**
```
Metrics:
  resource cpu on pods (as a percentage of request):     0% (0m) / 50%
  resource memory on pods (as a percentage of request):  12% (16Mi) / 70%
```

**Apply load and observe multi-metric scaling:**
```bash
kubectl apply -f load-generator.yaml
sleep 30
kubectl describe hpa nginx-hpa-multi | grep -A8 "Metrics:"
```

**Expected output with load:**
```
Metrics:
  resource cpu on pods (as a percentage of request):     115% (115m) / 50%
  resource memory on pods (as a percentage of request):  8% (11Mi) / 70%
```

```
# Observation: CPU says scale to ceil[1 × 115/50] = 3
#              Memory says scale to ceil[1 × 8/70] = 1
#              MAX rule: HPA takes MAX(3, 1) = 3 — scales to 3 ✅
#              Memory is well below target — CPU is the driving metric here
```

```bash
kubectl delete pod load-generator --grace-period=0 --force
kubectl delete -f hpa-multi-metric.yaml
```

---

### Step 7 — Imperative HPA Creation

```bash
kubectl autoscale deployment nginx-deploy \
  --min=1 \
  --max=5 \
  --cpu=50%                    # modern format (--cpu-percent is deprecated)

kubectl get hpa nginx-deploy
```

**Expected output:**
```
NAME          REFERENCE                  TARGETS       MINPODS  MAXPODS  REPLICAS
nginx-deploy  Deployment/nginx-deploy    cpu: 0%/50%   1        5        1
```

```
TARGETS: cpu: 0%/50%  → current 0%, target 50%
                        no load → no scaling
```

View the generated YAML (stored as v2 internally):
```bash
kubectl get hpa nginx-deploy -o yaml | grep -A5 "apiVersion\|kind\|metrics"
```

**Expected output:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metrics:
- resource:
    name: cpu
    target:
      averageUtilization: 50
      type: Utilization
```

```
# Observation: kubectl autoscale creates autoscaling/v2 internally
#              even though the flag feels like v1 syntax
```

```bash
kubectl delete hpa nginx-deploy
```

---

### Step 8 — HPA Behaviour: Custom Scale-Up/Down Policies

**`src/hpa-behaviour.yaml`:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: nginx-hpa-behaviour
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-deploy
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0    # scale up immediately (no cooldown)
      policies:
        - type: Pods
          value: 4                     # add at most 4 pods per 15 seconds
          periodSeconds: 15            # prevents burst creation of many pods at once
    scaleDown:
      stabilizationWindowSeconds: 60   # wait 60s before scale-down (vs default 300s)
      policies:
        - type: Pods
          value: 2                     # remove at most 2 pods per 60 seconds
          periodSeconds: 60
```

**Behaviour fields explained:**

```
scaleUp:
  stabilizationWindowSeconds: 0
    → scale up without waiting (aggressive — responds fast)

  policies:
  - type: Pods
    value: 4
    periodSeconds: 15
    → add at most 4 pods every 15 seconds
    → prevents sudden burst of pod creation

scaleDown:
  stabilizationWindowSeconds: 60
    → wait 60 seconds before starting scale-down
    → shorter than default 300s — faster scale-down

  policies:
  - type: Pods
    value: 2
    periodSeconds: 60
    → remove at most 2 pods every 60 seconds
    → gradual, controlled scale-down
```

```bash
kubectl apply -f hpa-behaviour.yaml
kubectl apply -f load-generator.yaml

kubectl get hpa nginx-hpa-behaviour -w
```

**Expected output:**
```
NAME                  TARGETS             MINPODS  MAXPODS  REPLICAS
nginx-hpa-behaviour   cpu: <unknown>/50%  1        10       0
nginx-hpa-behaviour   cpu: 115%/50%       1        10       1
nginx-hpa-behaviour   cpu: 38%/50%        1        10       3
```

Check configured behaviour:
```bash
kubectl describe hpa nginx-hpa-behaviour | grep -A10 "Behavior:"
```

**Expected output:**
```
Behavior:
  Scale Up:
    Stabilization Window: 0 seconds
    Select Policy: Max
    Policies:
      - Type: Pods  Value: 4  Period: 15 seconds
  Scale Down:
    Stabilization Window: 60 seconds
    Select Policy: Max
    Policies:
      - Type: Pods  Value: 2  Period: 60 seconds
```

> **FailedGetScale: Unauthorized warning explained:**
> This warning appears when a SECOND HPA is created targeting the same
> deployment that already has an HPA. Multiple HPAs on the same
> deployment cause an AmbiguousSelector conflict. Kubernetes refuses
> to scale because it cannot determine which HPA should be authoritative.
>
> In the verification output this occurred because the old nginx-deploy
> HPA from `kubectl autoscale` was not deleted before applying
> hpa-behaviour.yaml.
>
> **Rule: one HPA per workload — never create two HPAs targeting the same deployment.**

```bash
kubectl delete pod load-generator --grace-period=0 --force

# Observe scale-down — 60s stabilisation vs default 300s
kubectl get hpa nginx-hpa-behaviour -w
```

**Expected output:**
```
nginx-hpa-behaviour  cpu: 0%/50%  ...  3   ← load removed
nginx-hpa-behaviour  cpu: 0%/50%  ...  3   ← within 60s window
nginx-hpa-behaviour  cpu: 0%/50%  ...  1   ← scaled down after 60s
```

```
# Observation: scale-down took 60s (behaviour window), not the default 300s
```

```bash
kubectl delete -f hpa-behaviour.yaml
```

---

### Step 9 — Install VPA

VPA is not bundled with Kubernetes. Install from the official repo:

```bash
git clone https://github.com/kubernetes/autoscaler.git
cd autoscaler/vertical-pod-autoscaler/hack
./vpa-up.sh
cd ../../..
```

**Expected output:**
```
customresourcedefinition.../verticalpodautoscalers created
customresourcedefinition.../verticalpodautoscalercheckpoints created
clusterrole.../system:vpa-actor created
...
deployment.apps/vpa-updater created
deployment.apps/vpa-recommender created
deployment.apps/vpa-admission-controller created
```

Verify all three VPA components are running:
```bash
kubectl get pods -n kube-system | grep vpa
```

**Expected output:**
```
vpa-admission-controller-xxxxxxxxx-xxxxx   1/1   Running   0   52s
vpa-recommender-xxxxxxxxx-xxxxx            1/1   Running   0   53s
vpa-updater-xxxxxxxxx-xxxxx                1/1   Running   0   53s
```

Verify VPA CRDs installed:
```bash
kubectl api-resources | grep verticalpod
```

**Expected output:**
```
verticalpodautoscalercheckpoints  vpacheckpoint  autoscaling.k8s.io/v1  true  VerticalPodAutoscalerCheckpoint
verticalpodautoscalers            vpa            autoscaling.k8s.io/v1  true  VerticalPodAutoscaler
```

```
# Observation: two CRDs installed — vpa (the config + recommendation object you create)
#              and vpacheckpoint (the histogram storage object VPA manages automatically)
```

---

### Step 10 — VPA: Off Mode (Recommendations Only)

Off mode is safe to run on any workload in production — VPA observes and recommends but never changes pods.

**`src/vpa-off.yaml`:**
```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: nginx-vpa-off
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-deploy
  updatePolicy:
    updateMode: "Off"         # observe only — Updater never evicts, Admission never patches
  resourcePolicy:
    containerPolicies:
      - containerName: nginx
        minAllowed:
          cpu: 50m
          memory: 64Mi
        maxAllowed:
          cpu: 2
          memory: 2Gi
```

```bash
kubectl apply -f vpa-off.yaml
kubectl get vpa nginx-vpa-off
```

**Expected output (initial — no recommendation yet):**
```
NAME            MODE   CPU   MEM   PROVIDED   AGE
nginx-vpa-off   Off                False      0s
```

Wait ~1 minute for Recommender to gather data:
```bash
kubectl describe vpa nginx-vpa-off
```

**Expected output (after recommendation available):**
```
Status:
  Conditions:
    Status: True
    Type:   RecommendationProvided
  Recommendation:
    Container Recommendations:
      Container Name: nginx
      Lower Bound:
        Cpu:    50m
        Memory: 250Mi
      Target:
        Cpu:    50m
        Memory: 250Mi
      Uncapped Target:
        Cpu:    49m
        Memory: 250Mi
      Upper Bound:
        Cpu:    2
        Memory: 2Gi
```

```
# Observation: Target CPU = 50m (at minAllowed floor — nginx idle uses very little CPU)
#              Uncapped Target = 49m (raw recommendation before policy)
#              → minAllowed is raising the floor by 1m
#              Target Memory = 250Mi — nginx uses more memory than the 128Mi request
#              → this pod is UNDER-provisioned for memory (request=128Mi, target=250Mi)
#              → Mode=Off means nothing is applied — these are recommendations only
```

Compare current requests vs recommendation:
```bash
kubectl describe pod -l app=nginx | grep -A4 "Requests:"
```

**Expected output:**
```
Requests:
  cpu:     100m     ← current manifest setting
  memory:  128Mi    ← current manifest setting
```

```
VPA recommends: cpu=50m, memory=250Mi
Current setting: cpu=100m, memory=128Mi

VPA says: CPU is over-provisioned (50m target vs 100m request)
          Memory is under-provisioned (250Mi target vs 128Mi request)
Mode=Off: no changes applied — review only
```

```bash
kubectl delete -f vpa-off.yaml
```

---

### Step 11 — VPA: Recreate Mode (Automatic Resource Adjustment)

Recreate mode evicts pods and recreates them with recommended resource requests injected by the Admission Controller.

**`src/vpa-recreate.yaml`:**
```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: nginx-vpa-recreate
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-deploy
  updatePolicy:
    updateMode: "Recreate"    # Updater will evict pods; Admission will inject resources
  resourcePolicy:
    containerPolicies:
      - containerName: nginx
        minAllowed:
          cpu: 50m
          memory: 64Mi
        maxAllowed:
          cpu: 1
          memory: 1Gi
```

> **Note:** "Auto" mode is deprecated since VPA v1.4+. If you use "Auto" you will see:
> `Warning: UpdateMode "Auto" is deprecated and will be removed in a future API version.`
> Use "Recreate", "Initial", or "InPlaceOrRecreate" instead. Do not use "Auto" in new manifests.

```bash
kubectl apply -f vpa-recreate.yaml
kubectl get vpa nginx-vpa-recreate
```

Wait for recommendation and watch for pod eviction:
```bash
kubectl get pods -w &
WATCH_PID=$!
kubectl get vpa nginx-vpa-recreate -w
```

**Expected output:**
```
NAME               MODE      CPU    MEM     PROVIDED   AGE
nginx-vpa-recreate Recreate                            0s
nginx-vpa-recreate Recreate  143m   250Mi   True       60s
```

After recommendation is available, check pod resources:
```bash
# After recommendation is available, check if pod was evicted and recreated
kubectl get pods
kubectl describe pod -l app=nginx | grep -A4 "Requests:"
```

**Expected output after VPA applies recommendation:**
```
Requests:
  cpu:     143m    ← updated by VPA Admission Controller (was 100m) ✅
  memory:  250Mi   ← updated by VPA Admission Controller (was 128Mi) ✅
```

```
# Observation: Updater evicted the old pod (Eviction API — respects PDB)
#              Deployment controller recreated it
#              Admission Controller intercepted the new pod creation
#              and injected cpu=143m, memory=250Mi as requests
#              These are exactly the VPA Target values from the recommendation
```

Check events for evidence of eviction:
```bash
kubectl get events --sort-by='.lastTimestamp' | grep -i vpa
```

```bash
kill $WATCH_PID 2>/dev/null
kubectl delete -f vpa-recreate.yaml
```

---

### Step 12 — VPA + HPA Conflict Demo

This step demonstrates the conflict that occurs when **HPA on CPU/memory** runs simultaneously with **VPA in Recreate mode on CPU/memory** — both tools watching and modifying the same signal. This is NOT a general statement that HPA and VPA cannot coexist — they can and do in production. The conflict is specific to both tools targeting CPU/memory at the same time.

> **Safe combinations that avoid this conflict:** HPA on CPU/memory + VPA in Off mode (VPA recommends only); HPA on custom/external metrics + VPA in Recreate mode (different signals — no interference). See the HPA vs VPA section for the full breakdown and sizing strategy.

```bash
kubectl apply -f nginx-deploy.yaml
kubectl apply -f hpa-cpu-v2.yaml
```

**`src/vpa-conflict.yaml`:**
```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: nginx-vpa-conflict
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-deploy
  updatePolicy:
    updateMode: "Recreate"
  resourcePolicy:
    containerPolicies:
      - containerName: nginx
        minAllowed:
          cpu: 50m
          memory: 64Mi
        maxAllowed:
          cpu: 1
          memory: 1Gi
```

```bash
kubectl apply -f vpa-conflict.yaml
kubectl apply -f load-generator.yaml
sleep 60

kubectl get hpa nginx-hpa-cpu
kubectl get vpa nginx-vpa-conflict
```

**Expected output showing conflict:**
```
HPA: cpu: 38%/50%  replicas: 3   ← HPA scaled out under CPU load
VPA: cpu: 143m     provided: True ← VPA raised CPU request to 143m

After VPA raises requests:
  HPA sees: 38%/50% (with higher request denominator → lower %)
  HPA might scale DOWN ← conflict with HPA scaling up
```

**The conflict cycle:**
```
1. Load increases → pod CPU rises to 115% of 100m request
2. HPA scales to 3 replicas — load spread across 3 pods
3. VPA raises CPU request from 100m to 143m per pod
4. HPA recalculates: same 38m CPU usage / new 143m request = 27%
5. 27% is well below 50% target → HPA scales DOWN
6. Fewer pods → higher per-pod CPU → VPA may recommend more CPU
7. Cycle continues → neither HPA nor VPA can stabilise

Root cause: VPA changes the denominator (request) that HPA uses to
calculate utilisation%. Any change in requests shifts HPA's
perceived load even if actual CPU usage is unchanged.
```

**Safe solution:**
```bash
kubectl delete -f vpa-conflict.yaml

# Keep HPA for horizontal scaling
# Use VPA in Off mode — recommendations only, no request changes
kubectl apply -f vpa-off.yaml
```

**Cleanup:**
```bash
kubectl delete pod load-generator --grace-period=0 --force
kubectl delete -f hpa-cpu-v2.yaml
kubectl delete -f vpa-off.yaml
kubectl delete -f nginx-deploy.yaml
```

---

### Step 13 — Final Cleanup: Uninstall VPA

```bash
cd autoscaler/vertical-pod-autoscaler/hack
./vpa-down.sh
cd ../../..

kubectl get pods -n kube-system | grep vpa
# No VPA pods should remain
```

---

## What You Learned

In this lab, you:
- ✅ Understood the three Kubernetes autoscaling types — HPA, VPA, CA — what each does, when each applies, and who maintains each
- ✅ Explained cAdvisor — embedded in kubelet, reads from cgroups (not /proc), provides current-snapshot-only data with no historical retention
- ✅ Explained metrics-server — cluster addon, aggregates cAdvisor data across all nodes, exposes the Metrics API, retains only the most recent sample
- ✅ Traced the full HPA metrics pipeline — cAdvisor → kubelet → metrics-server → kube-apiserver → HPA controller → scale subresource
- ✅ Explained the scale subresource and scaleTargetRef — what HPA actually reads and writes
- ✅ Applied the HPA scaling formula with real numbers and verified the result
- ✅ Observed scale-down stabilisation — 5-minute default window prevents premature scale-down
- ✅ Configured custom HPA behaviour — shorter stabilisation window and Pods-type policies
- ✅ Explained all five HPA metric types and which metrics pipeline each uses
- ✅ Understood why HPA does not use the Eviction API and what that means for PDB
- ✅ Installed VPA and understood all three components (Recommender, Updater, Admission Controller)
- ✅ Explained the VPA algorithm — histogram model, 90th percentile target, all output fields
- ✅ Used VPA Off mode for recommendations without pod changes
- ✅ Used VPA Recreate mode and observed Admission Controller injecting resources on pod recreation
- ✅ Demonstrated HPA + VPA conflict and understood the safe combination patterns

**Key Takeaway:** HPA and VPA are complementary, not competing — HPA adjusts replica count in response to traffic; VPA adjusts resource requests based on observed usage. Together they converge toward a cluster that scales efficiently and allocates precisely. The conflict arises only when both target the same signal (CPU/memory). The safe pattern is HPA on traffic signals + VPA in Off mode for visibility, or HPA on custom metrics + VPA in Recreate mode for active right-sizing.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get hpa` | List all HPAs — TARGETS, MINPODS, MAXPODS, REPLICAS |
| `kubectl describe hpa <name>` | Full HPA status — metrics, conditions, events |
| `kubectl get hpa <name> -w` | Watch HPA scaling decisions in real time |
| `kubectl autoscale deployment <name> --cpu=50% --min=1 --max=5` | Create HPA imperatively (v2 internally) |
| `kubectl top pods` | Current pod CPU/memory (requires metrics-server) |
| `kubectl top nodes` | Current node CPU/memory |
| `kubectl get vpa` | List all VPAs — MODE, CPU, MEM, PROVIDED |
| `kubectl describe vpa <name>` | VPA recommendations and all status fields |
| `kubectl get vpacheckpoint` | List histogram checkpoints |
| `kubectl get events --sort-by='.lastTimestamp' \| grep -i "scale\|vpa"` | Scaling and eviction events |
| `kubectl get apiservices \| grep metrics` | Verify Metrics API is registered |

---

## CKA Certification Tips

✅ **HPA API version — always autoscaling/v2:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
```

✅ **HPA scaling formula — know and apply it:**
```
desiredReplicas = ceil[currentReplicas × (currentValue / targetValue)]
```

✅ **Resource requests are mandatory for utilisation-based HPA** — without them, TARGETS shows `<unknown>`

✅ **One HPA per workload** — two HPAs on the same Deployment cause AmbiguousSelector conflict

✅ **Scale-down default stabilisation = 5 minutes (300 seconds)**

✅ **kubectl autoscale modern format:**
```bash
kubectl autoscale deployment <name> --cpu=50% --min=1 --max=5
# NOT --cpu-percent (deprecated)
```

✅ **VPA modes — know all four:**
```
Off              → recommendations only — no pod changes
Initial          → inject at pod creation only — running pods unchanged
Recreate         → evict and recreate with new resources
InPlaceOrRecreate → try in-place resize first, fall back to Recreate
Auto             → DEPRECATED — do not use
```

✅ **HPA + VPA safe combinations:**
```
HPA (CPU/memory) + VPA (Off)       → safe — VPA only recommends
HPA (custom metrics) + VPA (active) → safe — different signals
HPA (CPU/memory) + VPA (Recreate)  → conflict ❌ — avoid
```

✅ **cAdvisor vs metrics-server retention:**
```
cAdvisor:       zero retention — live snapshot only
metrics-server: one sample per pod (most recent only)
VPA:            8 days (in VPACheckpoint histogram)
```

---

## Troubleshooting

**HPA TARGETS shows `<unknown>`:**
```bash
# Check metrics-server is running
kubectl get pods -n kube-system | grep metrics-server
kubectl top pods
# Check resource requests are set on ALL containers
kubectl describe deployment <name> | grep -A4 "Requests:"
# Wait 30-60s after pod creation for first metrics-server scrape
```

**HPA not scaling up despite high CPU:**
```bash
kubectl describe hpa <name>
# AmbiguousSelector / FailedGetScale: Unauthorized
#   → two HPAs target the same Deployment → delete the extra one
# ScalingLimited: True TooManyReplicas
#   → already at maxReplicas — raise maxReplicas if more scale is needed
# ScalingActive: False FailedGetResourceMetric
#   → metrics unavailable — check metrics-server and requests
```

**HPA not scaling down:**
```bash
# Normal — default 5-minute stabilisation window prevents it
kubectl describe hpa <name> | grep -A5 Events
# SuccessfulRescale event will appear after 5 minutes of consistent low demand
```

**VPA shows no recommendations (PROVIDED stays False):**
```bash
kubectl describe vpa <name>
# RecommendationProvided: False → wait ~1 minute for first data
# Still False after 5 minutes:
kubectl get pods -n kube-system | grep vpa-recommender
kubectl logs -n kube-system -l app=vpa-recommender | tail -20
```

**VPA pod not being evicted despite recommendation (Recreate mode):**
```bash
kubectl describe vpa <name> | grep "Update Mode"
# Must be Recreate or InPlaceOrRecreate — not Off
kubectl get pods -n kube-system | grep vpa-updater
# With only 1 replica: VPA may not evict to avoid downtime
# Add a second replica or a PDB allowing disruption, or use InPlaceOrRecreate
```

**HPA or VPA targeting a workload in a different namespace:**
```bash
# HPA and its scaleTargetRef must be in the same namespace
kubectl get hpa -n <namespace>
kubectl describe hpa <name> -n <namespace>
# ScalingActive: False FailedGetScale → target not found
# Check: HPA namespace == Deployment namespace
# Cross-namespace targeting is not supported — create the HPA in the
# same namespace as the Deployment it manages
```
# v1beta1.metrics.k8s.io should show True
# If False or absent: metrics-server pod may be crash-looping
kubectl describe pod -n kube-system -l k8s-app=metrics-server
```