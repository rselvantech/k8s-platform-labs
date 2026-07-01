# Demo: 11-auto-scaling/01-hpa-basic — HPA and the Kubernetes Horizontal Scaling Model

## Lab Overview

Applications receive variable traffic throughout the day — fixed replica counts and static resource allocations either waste money during quiet periods or cause outages during peaks. Kubernetes autoscaling adjusts the number of pods automatically based on actual demand.

This lab builds the complete mental model for Kubernetes horizontal autoscaling before any hands-on work begins. You will understand cAdvisor (where metrics originate), metrics-server (how metrics reach the control plane), and the HPA controller (how scaling decisions are made). The hands-on steps then verify each concept with real numbers from a live cluster.

**Real-world scenario:** A nginx-based web application receives variable traffic throughout the day. HPA handles traffic spikes by adding replicas, then scales back in during quiet periods — doing so gradually to avoid premature removal during transient lulls(i.e temporary short periods of reduced activity or calm).

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
- HPA behaviour — custom scale-up/down policies, windows, and selectPolicy
- Why HPA does not use the Eviction API and what that means for PDB

> **Scope note:** This lab covers HPA fundamentals hands-on (Steps 1–8). VPA installation, algorithm, update modes, and hands-on are in `03-vpa-fundamentals`. Cluster Autoscaler requires cloud infrastructure and is covered in `aws-eks-demos`. Custom/external metrics adapter hands-on is in `05-prometheus-adapter` (minikube) and `aws-eks-demos` (AWS-specific sources).

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl installed and configured
- metrics-server enabled (required by both HPA and VPA)

**Verify metrics-server before starting:**
```bash
kubectl get pods -n kube-system | grep metrics-server
kubectl top nodes
# Both must work before proceeding
```

If metrics-server is not running:
```bash
minikube addons enable metrics-server -p 3node
# Wait ~60 seconds, then verify again
```

**Knowledge Requirements:**
- **REQUIRED:** Completion of `06-pod-scheduling/06-resource-management` — resource requests/limits, cgroups enforcement, QoS classes (mandatory for HPA utilisation calculations)
- **REQUIRED:** Understanding of Deployments and replica management
- **RECOMMENDED:** Understanding of QoS classes (helpful for understanding HPA interaction with pod scheduling)

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
9. ✅ Configure custom HPA behaviour — stabilisation windows, policies, and selectPolicy
10. ✅ Explain the difference between all five HPA metric types and which metrics pipeline each uses

---

## Directory Structure

```
11-auto-scaling/01-hpa-basic/
├── README.md                        # this file
└── src/
    ├── 01-nginx-deploy.yaml         # nginx deployment + ClusterIP service
    ├── 02-load-generator.yaml       # busybox load generator
    ├── 03-hpa-cpu-v2.yaml           # HPA v2 — CPU based
    ├── 04-hpa-memory-v2.yaml        # HPA v2 — memory based
    ├── 05-hpa-multi-metric.yaml     # HPA v2 — CPU + memory
    └── 06-hpa-behaviour.yaml        # HPA v2 — custom scale-down behaviour
```

---

## Recall Check — 06-pod-scheduling/06-resource-management

Answer from memory before continuing — these are scenario questions from `06-resource-management`.

1. A container has `resources.requests.cpu: 200m` and `resources.limits.cpu: 500m`. The container's process is currently using 450m CPU. What happens, and why does Kubernetes allow this?
2. A node has 2 CPU allocatable. Three pods are scheduled: Pod A requests 800m, Pod B requests 700m, Pod C requests 600m. A fourth pod requests 100m. Why does the fourth pod stay Pending even though the total usage on the node is only 1.2 CPU?
3. You set `resources.requests.memory: 128Mi` and `resources.limits.memory: 128Mi` (requests equals limits). What QoS class does this pod get, and what does that mean for eviction priority?

<details>
<summary>Answers</summary>

1. The container uses CPU freely up to its limit (500m). The kernel's cgroup CPU throttler allows bursting above the request (200m) as long as node capacity permits — Kubernetes does not "block" usage above the request. The request is only a scheduling guarantee: the scheduler ensures 200m is available on the node. Usage above the request is allowed up to the limit; beyond the limit, the CPU is throttled (usage is capped, not killed).

2. Kubernetes uses requests for scheduling decisions, not actual usage. Total requests scheduled: 800m + 700m + 600m = 2,100m — which exceeds the node's 2,000m (2 CPU) allocatable. The scheduler rejects the fourth pod because adding 100m more requests (2,100m + 100m = 2,200m) would exceed the node's capacity in terms of reserved resources. Actual CPU usage being lower is irrelevant — the scheduler works with requests, not live usage.

3. QoS class: **Guaranteed** — when requests equals limits for all resources (both CPU and memory) on all containers in the pod, the pod receives Guaranteed QoS. This means it is the last class to be evicted under node memory pressure. Eviction order is: BestEffort (evicted first) → Burstable (evicted second) → Guaranteed (evicted last).

</details>

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
  Hands-on:      03-vpa-fundamentals

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
  Hands-on:      aws-eks-demos
```

**What is resource mis-sizing (VPA trigger)?**

Resource mis-sizing is the condition where `resources.requests` in a container spec does
not reflect the container's actual CPU or memory usage. It has nothing to do with traffic
spikes — it is a static configuration error that persists whether or not there is load.

When you write a Kubernetes manifest you must set `resources.requests.cpu` and
`resources.requests.memory` for each container. These values are guesses:

```
Under-provisioned (request too low):
  requests.cpu: 50m   ← but the container actually needs 300m at normal load
  Effect: CPU throttling (performance degradation), or OOMKill if memory
  HPA impact: HPA sees utilisation% = usage/request = 300/50 = 600%
              → HPA scales out aggressively, adding pods that are all equally
                under-provisioned — the problem multiplies, not solves

Over-provisioned (request too high):
  requests.cpu: 2000m ← but the container actually uses 100m at peak
  Effect: node capacity wasted; fewer pods can schedule; higher cost
  HPA impact: HPA sees utilisation% = 100/2000 = 5%
              → HPA never scales up; the cluster appears to have headroom
                even under real load

VPA's job: observe actual usage over time → recommend or set the correct request
           This is "right-sizing" — matching the request to reality
```

Right-sizing means setting resource requests that accurately reflect a container's actual observed usage — not too high (waste), not too low (throttling/OOMKill). VPA automates this by building a statistical model of observed usage and producing recommendations based on percentile-based targets.

**Why HPA alone cannot fix mis-sizing:**

HPA changes the number of pods, not the size of each pod. If every pod is under-provisioned
(requests too low), scaling out adds more under-provisioned pods — you get more throttled
pods, not more capacity. The correct fix is to raise the request (VPA's job), which then
makes the HPA formula more accurate.

**Why VPA alone cannot fix traffic spikes:**

VPA changes the request per pod, not the number of pods. A correctly-sized pod that receives
10× its normal traffic still needs more pods — not a bigger request. VPA's histogram model
is not designed to respond to sudden traffic changes; it smooths over days of data.

**How Kubernetes "decides":** it does not. You configure both:
- HPA for traffic-driven replica count changes (fast)
- VPA for resource right-sizing (slow — Off mode is safe to run alongside HPA)

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

For these workloads, the correct lever is not "add more pods" but "give the existing pod the resources it needs." That is exactly what VPA does. Full VPA hands-on is in `03-vpa-fundamentals`.

**Why VPA is best for single-pod apps (not multi-pod):**

VPA Recreate and InPlaceOrRecreate modes work by evicting pods so they restart with updated resource requests. If your Deployment has only one replica, the Updater will evict that one pod — your application goes down momentarily until the pod restarts.

With multiple replicas, VPA respects PDB and evicts pods one at a time, maintaining availability. But VPA does NOT do load balancing or parallel processing — it only adjusts requests per pod. If your workload genuinely needs more compute, you need more pods (HPA), not bigger pods (VPA). So in practice:
- Single-pod stateful app → VPA is the correct tool (adjusts the one pod's resources)
- Multi-replica stateless app → HPA is the correct tool (adjusts pod count)
- Multi-replica stateful app → VPA in Off mode for recommendations; operator-managed scaling for replicas

**Why VPA does NOT support standalone pods:**

A standalone pod (not managed by a Deployment, StatefulSet, or other controller) cannot be recreated after eviction — when the VPA Updater evicts it, it is gone permanently. There is no controller watching it to recreate it. VPA requires a controller to recreate evicted pods; without one, Recreate mode would just delete your pod. Even for a single-pod application, use a Deployment with `replicas: 1` — VPA will then evict and the Deployment controller will recreate it with updated resources.

**Single-pod stateful app → VPA is the correct tool:**

A single-pod stateful application is something like a Redis cache, a single-node database,
or a message broker where you run exactly one instance (not for HA — just for the workload).
Adding a second pod does not give you twice the capacity for these workloads; it gives you
two independent instances that don't share state.

```
Real example: a Redis cache for session data
  You cannot add a second Redis pod and have it automatically serve the same data
  unless you configure Redis replication — which is a separate operational concern.

  With VPA in Recreate mode:
    Redis starts with requests.cpu=500m, requests.memory=256Mi (guesses)
    VPA observes: actual peak = 120m CPU, 400Mi memory
    VPA evicts the pod → controller recreates → Admission Controller injects:
      requests.cpu=120m, requests.memory=400Mi
    Redis restarts with right-sized resources — brief downtime (seconds)
    Result: more accurate scheduling, prevents OOMKill from under-sized memory request
```

**Multi-replica stateful app → VPA in Off mode; operator-managed scaling for replicas:**

A multi-replica stateful app is something like a Kafka cluster, a Cassandra ring, or
PostgreSQL with a primary + read replicas. Scaling replicas is not a simple `kubectl scale`
operation — it requires rebalancing partitions, joining the cluster, promoting replicas,
etc. This is managed by a Kubernetes operator (e.g. Strimzi for Kafka, CloudNativePG for
Postgres).

```
Real example: a 3-node Kafka cluster managed by Strimzi operator
  Adding a 4th broker requires: partition reassignment, rebalancing topic replicas
  Strimzi handles this → NOT HPA territory

  VPA in Off mode (safe alongside operator):
    Strimzi manages replica count (3 brokers is the right count, not variable)
    VPA observes each broker's CPU/memory usage over days
    VPA recommendation: increase broker memory request from 1Gi to 2.5Gi
    Operator applies the change during next rolling restart
    Result: better resource allocation without disrupting cluster operations
```

The distinction: HPA or an operator handles "how many replicas"; VPA handles
"how big is each replica". For stateful apps, VPA in Off mode gives you the sizing
data to inform manual or operator-managed changes safely.

**Scale-down behaviour — all three autoscalers:**

```
HPA scale-down:
  Trigger:   metric drops below target x (1 - tolerance)
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
  Full detail: 03-vpa-fundamentals

CA scale-down (removing nodes):
  Trigger:   node has been underutilised for 10 minutes (configurable)
             AND all pods on it could fit on other nodes
  Mechanism: CA drains the NODE (not individual pods)
             Draining a node means: CA evicts all pods on that node
             using the Eviction API (respects PDB for each pod)
             Once all pods are evicted → CA calls cloud provider API to terminate the VM
  Action:    pods reschedule to other nodes, VM is terminated

  "Draining a node" vs "evicting a pod":
    Draining: an operation on the node — marks it unschedulable (cordon) then
              evicts all pods running on it one by one
    Evicting:  an operation on a single pod — uses the Eviction API, which
               checks PDB before proceeding
    CA drains the node → which triggers eviction of each pod on it
    The distinction matters: PDB is respected per-pod during the drain,
    so a node drain that would violate a PDB for any pod on that node
    will be blocked until PDB permits it
```

**How the three work together — and when VPA activates:**

```
Traffic spike arrives (HPA responds — seconds to minutes):
  1. More requests → per-pod CPU rises above HPA target
  2. HPA formula: ceil[currentReplicas × (currentCPU/target)] → adds pods
  3. New pods cannot schedule (all nodes full)
  4. Cluster Autoscaler detects Pending pods → provisions new node
  5. New pods schedule on new node → traffic load distributed

VPA operates on a completely different timescale (hours to days):
  6. VPA Recommender has been observing CPU/memory usage since deployment
  7. Over days, VPA builds a histogram: 90th percentile usage = 143m CPU
  8. VPA recommendation: raise requests from 100m to 143m (if Recreate mode)
     OR simply reports this (if Off mode)
```

**Why step 6–8 are NOT triggered by the traffic spike in step 1:**

VPA uses a histogram smoothed over days with recency decay. A single traffic spike
adds a few high-usage samples to the histogram but does not immediately change the
90th percentile significantly — the spike must be representative of sustained usage
to shift the recommendation. VPA is not a real-time responder; it is a long-term
capacity planner.

**Why VPA right-sizing improves HPA accuracy:**

```
HPA formula: desiredReplicas = ceil[currentReplicas × (usage / request)]

Before VPA right-sizing (request over-provisioned):
  actual usage = 80m, request = 500m → utilisation = 16%
  → HPA never scales up even if the application is slow
  → The denominator (request) is too large; signal is muted

After VPA right-sizing (request matches actual 90th pct):
  actual usage = 80m, request = 90m → utilisation = 89%
  → HPA scales up when the application is actually under load
  → The denominator (request) reflects reality; signal is accurate
```

The practical takeaway: run VPA in Off mode first to establish correct requests.
Once requests are right-sized, HPA's utilisation formula becomes meaningful.
Then optionally enable VPA Recreate to keep requests right-sized automatically.

**How does Kubernetes decide which autoscaler to trigger — HPA or VPA?**

It does not. HPA and VPA are independent systems that do not communicate with each other
and do not "decide" between themselves. Each watches different signals and acts on them
independently. You — the operator — configure which one applies to a given workload.

```
HPA watches: a metric value vs a target threshold
             (CPU%, memory%, custom metric, external metric)
             When the metric exceeds the target → HPA adds pods
             When the metric falls below the target → HPA removes pods

VPA watches: the gap between observed resource usage and configured requests
             (actual CPU used vs cpu request, actual memory used vs memory request)
             When actual usage consistently exceeds the request → VPA raises the request
             When actual usage is consistently well below the request → VPA lowers it
```

**Real-world example — the same pod, two different signals:**

```
Application: nginx web server
resources.requests.cpu: 100m
Load pattern: traffic spike at 9am, quiet from 10pm–8am

HPA perspective:
  9am: CPU rises to 180m = 180% of 100m request → above 50% target
  HPA formula: ceil[1 × (180/50)] = 4 pods → scales out
  10pm: traffic drops → CPU falls → HPA scales back in

VPA perspective (running in Off mode alongside HPA):
  Over 8 days: VPA histogram shows 90th percentile usage = 85m
  VPA Target: cpu=85m (vs current request of 100m → over-provisioned)
  VPA recommendation: lower requests to 85m to reclaim wasted capacity

Neither autoscaler "triggers" the other. They run in parallel:
  HPA handles the traffic spike → adds temporary pods
  VPA handles the baseline right-sizing → corrects the long-term request value
```

The practical rule: **HPA responds to traffic changes (fast, seconds to minutes)**;
**VPA responds to systematic mis-sizing (slow, hours to days)**. If you see high CPU
utilisation and HPA is scaling out pods, that is expected — HPA is doing its job. Whether
the requests were right to begin with is VPA's question, answered over a longer timeframe.

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
cAdvisor retention:       NONE — current snapshot only
metrics-server:           1 data point (most recent) — not a time series
Prometheus (if deployed): configurable — default 15 days
VPA Recommender:        maintains its own histogram (in VPACheckpoint)
                        across multiple metrics-server snapshots
                        default observation window: 8 days
                        (configurable via --history-length flag).see 03-vpa-fundamentals
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


**The Metrics API resource types — NodeMetrics and PodMetrics:**

```bash
kubectl api-resources | grep metrics
# nodes  metrics.k8s.io/v1beta1  false  NodeMetrics
# pods   metrics.k8s.io/v1beta1  true   PodMetrics
```

These are the two resource kinds that metrics-server exposes via the Metrics API:

```
NodeMetrics (namespaced: false — cluster-scoped):
  Represents the CPU and memory usage of a Node at a point in time.
  One NodeMetrics object per node in the cluster.
  Queried by: kubectl top nodes
  API path: /apis/metrics.k8s.io/v1beta1/nodes/<node-name>
  Contains: CPU usage (nanocores), memory working set (bytes), timestamp

PodMetrics (namespaced: true — namespace-scoped):
  Represents the CPU and memory usage of all containers in a Pod at a point in time.
  One PodMetrics object per running pod.
  Queried by: kubectl top pods
  API path: /apis/metrics.k8s.io/v1beta1/namespaces/<ns>/pods/<pod-name>
  Contains: per-container CPU and memory usage, timestamp

  Note: PodMetrics includes per-container breakdown — this is the same data
  that HPA uses for type: Resource and type: ContainerResource calculations.
  The HPA controller reads PodMetrics, not NodeMetrics.
```

**How to query them directly:**

```bash
# Get all node metrics
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes | python3 -m json.tool

# Get all pod metrics in default namespace
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/default/pods \
  | python3 -m json.tool

# Same data that kubectl top shows — just the raw API response
```

These are not stored CRDs you create — they are API resources whose values are
served live by metrics-server (from cAdvisor data). There are no `etcd` entries
for NodeMetrics or PodMetrics; each request returns a fresh read from metrics-server's
in-memory store.

**How long metrics-server stores data:**

metrics-server keeps only the most recent metric sample per pod/container — it is not a time-series database. There is no configurable retention window. If you query `kubectl top` twice a second apart, both queries return the same sample until the next 60-second scrape cycle.

```
metrics-server retention:  1 sample per pod/container (most recent)
                           scraped from kubelet every 60s (default)
                           no historical data, no time series
                           restarting metrics-server clears all data
```

**cAdvisor → metrics-server: what aggregates what?**

cAdvisor provides metrics at the **container level** — one set of values per container
in each pod on that node. It does not aggregate to pod level; it simply exposes raw
per-container data.

metrics-server reads the per-container data from every node's `/metrics/resource`
endpoint (where cAdvisor data is served) and:

```
Aggregates UP to pod level:
  Pod CPU = sum of all container CPU values in that pod
  Pod memory = sum of all container memory values in that pod
  (This is what kubectl top pods shows)

Aggregates UP to node level:
  Node CPU = sum of all pod CPU values on that node (plus system overhead)
  Node memory = sum of all pod memory values on that node
  (This is what kubectl top nodes shows)

Keeps container-level breakdown available:
  PodMetrics contains per-container breakdown
  This is what HPA ContainerResource type reads
  This is what kubectl top pod --containers shows
```

So the data flow is:

```
cAdvisor (per container) → metrics-server reads →
  stores as PodMetrics (per container, aggregated per pod)
  stores as NodeMetrics (aggregated per node)
```

metrics-server does NOT receive pre-aggregated data from cAdvisor — it receives
raw per-container values and does the aggregation itself.

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

> **Working set vs RSS — why kubectl top differs from OS tools:**
>
> `kubectl top` reports memory as **working set**, not RSS (Resident Set Size).
>
> **RSS (Resident Set Size):** all physical memory pages currently mapped to the process,
> including pages that are in active use AND pages that were recently used but could be
> released to other processes if memory pressure increases (e.g. file-backed pages,
> shared libraries). RSS overstates actual "committed" memory.
>
> **Working set:** the subset of RSS that is actually in active use and cannot be readily
> reclaimed without causing performance degradation. In Kubernetes, it is defined as:
> ```
> working set = RSS - recently-used-but-releasable file cache
>             = the memory the container genuinely needs right now
> ```
>
> **Why working set is better for HPA decisions:**
>
> An HPA based on RSS might see memory "in use" that is actually idle file cache that
> the kernel would release the moment another pod needs the memory. This could trigger
> unnecessary scale-out. Working set represents memory that is genuinely committed —
> if it exceeds the request, the container truly needs more memory. This makes working
> set a more meaningful signal for both HPA scaling decisions and OOMKill prevention
> (OOMKill is triggered based on working set, not RSS).


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
        | exposes ResourceMetricsList — one entry per CONTAINER (not per pod)
        | each entry contains: container name, pod name, namespace,
        |   CPU usage in nanocores, memory working set in bytes, timestamp
        | metrics-server reads this and aggregates per-pod and per-node
        | the per-container breakdown is preserved in PodMetrics for ContainerResource HPA
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

**Reading the Conditions block at a glance:**

The three conditions form a state machine. Read them in order:

```
Step 1: Is ScalingActive True?
  → No (False):  HPA cannot calculate replicas at all.
                 The metric pipeline is broken.
                 Check: metrics-server running? resources.requests set?
                 Fix the metrics problem first — nothing else matters yet.
  → Yes (True):  HPA has a valid metric and can calculate. Move to step 2.

Step 2: Is AbleToScale True?
  → No (False):  HPA has a calculation but is in a cooldown/backoff window.
                 BackoffBoth: just scaled, waiting for stability
                 BackoffDownscale: in scale-down stabilisation window (normal after load drops)
                 BackoffUpscale: in scale-up stabilisation (unusual — check behavior config)
                 This is often EXPECTED behaviour, not an error. Wait for the window to clear.
  → Yes (True):  HPA is ready to act on its calculation. Move to step 3.

Step 3: Is ScalingLimited True?
  → No (False):  Desired replicas is within [minReplicas, maxReplicas]. HPA is scaling freely.
  → Yes (True):  Desired replicas hit a bound.
                 TooFewReplicas: at minReplicas floor — cannot scale down further (correct)
                 TooManyReplicas: at maxReplicas ceiling — cannot scale up further
                   → this is EXPECTED when load exceeds capacity
                   → if unexpected: raise maxReplicas
```

**AbleToScale True means:** "I am not in a cooldown period — I am allowed to act on my
calculation right now." AbleToScale False does NOT mean something is broken — it usually
means HPA recently scaled and is respecting a stabilisation window.

**The most important condition for troubleshooting:** `ScalingActive`. If it is False, HPA
is completely non-functional regardless of what the other conditions say. Fix the metric
source first.

---

### HPA Metric Types — The Full Metrics Pipeline for Each

The five HPA metric types use different data sources and require different infrastructure. Understanding WHICH pipeline each type uses determines how complex your setup needs to be.

```
API Group                 Served by             HPA metric types using it
metrics.k8s.io          → metrics-server       → Resource, ContainerResource
custom.metrics.k8s.io   → metrics adapter      → Pods, Object
external.metrics.k8s.io → metrics adapter      → External
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
Hands-on: 05-prometheus-adapter (minikube)
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
Hands-on: 05-prometheus-adapter (minikube)
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
Hands-on: aws-eks-demos
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
```

> Types Pods, Object, and External require a metrics adapter. This demo covers Resource only. ContainerResource is in `02-hpa-advanced`. Adapter hands-on is in `05-prometheus-adapter` and `aws-eks-demos`.

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
| `metrics[].object.target.type` | — | `Value` (raw total) or `AverageValue` (÷ pod count) | Using `Value` when the Ingress total never drops as pods scale — use `AverageValue` |
| `metrics[].external.target.type` | — | `Value` (raw total) or `AverageValue` (÷ pod count) | Same as Object — choose based on whether metric is a total or per-pod signal |
| `behavior.scaleUp.stabilizationWindowSeconds` | 0 | How long HPA waits before acting on scale-up | Setting to 300 (scale-down default) silently delays scale-up |
| `behavior.scaleDown.stabilizationWindowSeconds` | 300 | How long HPA waits before acting on scale-down | Setting to 0 causes aggressive scale-down on transient load drops |
| `behavior.*.selectPolicy` | Max | Which policy wins when multiple policies apply | `Disabled` blocks ALL scaling in that direction |
| `behavior.*.policies[].type` | — | `Pods` (absolute count) or `Percent` (relative %) | Percent at small replica counts can be slower than Pods |
| `behavior.*.policies[].periodSeconds` | — | Window for this policy | Too short allows rapid oscillation |

**Namespace rule:**

HPA, scaleTargetRef, and any `Object` metric's `describedObject` must all be in the same namespace. Cross-namespace HPA targeting is not supported. If `scaleTargetRef.name` points to a Deployment in a different namespace, the HPA will silently fail with `ScalingActive: False` / `FailedGetScale` — no error at apply time.


### HPA Behavior — `selectPolicy` and Multiple Policies

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
```

**Can you use both `Pods`-type and `Percent`-type policies in the same HPA?**

`selectPolicy` determines which policy wins when you define more than one entry under
a `scaleUp` or `scaleDown` block. The HPA evaluates ALL policies every cycle and uses
`selectPolicy` to choose one result.

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


**Worked example — same two policies, Max vs Min:**

```
Starting at 1 replica, sustained high load. After 30 seconds:

  Percent (value: 100, period: 30s): 1 → 2   (+1 = +100% of current)
  Pods    (value: 4,   period: 15s): 1 → 5   (+4, because two 15s windows fit in 30s)

  selectPolicy: Max → Pods wins → 5 replicas
    (Pods proposed the most change: +4 vs Percent's +1)

  selectPolicy: Min → Percent wins → 2 replicas
    (Percent proposed the least change: +1 vs Pods' +4)

Starting at 20 replicas, sustained high load. After 30 seconds:

  Percent (value: 100, period: 30s): 20 → 40  (+20 = +100% of current)
  Pods    (value: 4,   period: 15s): 20 → 28  (+8, because two 15s windows)

  selectPolicy: Max → Percent wins → 40 replicas
    (at large counts, Percent produces more change than Pods)

  selectPolicy: Min → Pods wins → 28 replicas
```

The crossover point: `Pods` wins at small replica counts (absolute step > relative step);
`Percent` wins at large replica counts (relative step > absolute step). `selectPolicy`
lets you choose which behaviour dominates.

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
  50+ built-in scalers (SQS, Kafka, Redis, cron, HTTP, Prometheus)
  Hands-on: 04-keda-adapter

Karpenter:
  AWS-native node provisioner — modern replacement for CA on EKS
  Faster provisioning, more granular instance selection, spot/on-demand mix
  Uses NodePool and EC2NodeClass CRDs
  Hands-on: aws-eks-demos
```

---

## Lab Step-by-Step Guide

---

### Step 1 — Cluster Setup and Prerequisites

```bash
cd 11-auto-scaling/01-hpa-basic/src

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

**`src/01-nginx-deploy.yaml`:**
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
kubectl apply -f 01-nginx-deploy.yaml
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

**`src/02-load-generator.yaml`:**
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
kubectl apply -f 02-load-generator.yaml
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

**`src/03-hpa-cpu-v2.yaml`:**
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
kubectl apply -f 03-hpa-cpu-v2.yaml

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
#              115%/50%     → current 115%, target 50%
#                             formula: ceil[1 x 115/50] = ceil[2.3] = 3
#              37%/50%      → after 3 replicas: 115/3 ~ 38% (within tolerance)
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
kubectl delete -f 03-hpa-cpu-v2.yaml
```

---

### Step 5 — HPA: Memory Based (autoscaling/v2)

**`src/04-hpa-memory-v2.yaml`:**
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
kubectl apply -f 04-hpa-memory-v2.yaml
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
kubectl delete -f 04-hpa-memory-v2.yaml
```

---

### Step 6 — HPA: Multiple Metrics (autoscaling/v2)

**`src/05-hpa-multi-metric.yaml`:**
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
kubectl apply -f 05-hpa-multi-metric.yaml
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
kubectl apply -f 02-load-generator.yaml
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
kubectl delete -f 05-hpa-multi-metric.yaml
```

---

### Step 7 — Imperative HPA Creation

```bash
kubectl autoscale deployment nginx-deploy \
  --min=1 \
  --max=5 \
  --cpu=50%    # modern format (--cpu-percent is deprecated)

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
#              even though the --cpu=50% flag feels like v1 syntax
```

```bash
kubectl delete hpa nginx-deploy
```

---

### Step 8 — HPA Behaviour: Custom Scale-Up/Down Policies

**`src/06-hpa-behaviour.yaml`:**
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
kubectl apply -f 06-hpa-behaviour.yaml
kubectl apply -f 02-load-generator.yaml

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
> 06-hpa-behaviour.yaml.
>
> **Rule: one HPA per workload — never create two HPAs targeting the same deployment.**

```bash
kubectl delete pod load-generator --grace-period=0 --force

# Observe scale-down — 60s stabilisation vs default 300s
kubectl get hpa nginx-hpa-behaviour -w
```

**Expected output:**
```
nginx-hpa-behaviour  cpu: 0%/50%  ...  3   <- load removed
nginx-hpa-behaviour  cpu: 0%/50%  ...  3   <- within 60s window
nginx-hpa-behaviour  cpu: 0%/50%  ...  1   <- scaled down after 60s
```

```
# Observation: scale-down took 60s (behaviour window), not the default 300s
```

```bash
kubectl delete -f 06-hpa-behaviour.yaml
```

---

### Step 9 — Cleanup

```bash
kubectl delete -f 01-nginx-deploy.yaml --ignore-not-found
kubectl delete -f 02-load-generator.yaml --ignore-not-found
kubectl delete -f 03-hpa-cpu-v2.yaml --ignore-not-found
kubectl delete -f 04-hpa-memory-v2.yaml --ignore-not-found
kubectl delete -f 05-hpa-multi-metric.yaml --ignore-not-found
kubectl delete -f 06-hpa-behaviour.yaml --ignore-not-found
kubectl delete hpa nginx-deploy --ignore-not-found

kubectl get hpa
kubectl get deployments
kubectl get pods
```

**Expected output:**
```
No resources found in default namespace.
No resources found in default namespace.
No resources found in default namespace.
```

```
# Observation: metrics-server stays enabled — required by 02-hpa-advanced,
#              03-vpa-fundamentals, and all later scaling demos.
#              VPA is not installed in this lab — see 03-vpa-fundamentals.
```

---

## What You Learned

In this lab, you:
- ✅ Explained all three Kubernetes autoscaling types — HPA, VPA, CA — what each does, when each applies, and who maintains each
- ✅ Explained cAdvisor — embedded in kubelet, reads from cgroups (not /proc), current-snapshot-only data with no historical retention
- ✅ Explained metrics-server — cluster addon, aggregates cAdvisor data across all nodes, exposes the Metrics API, retains only the most recent sample
- ✅ Traced the full HPA metrics pipeline — cAdvisor → kubelet → metrics-server → kube-apiserver → HPA controller → scale subresource
- ✅ Explained the scale subresource and scaleTargetRef — what HPA actually reads and writes
- ✅ Applied the HPA scaling formula with real numbers and verified the result
- ✅ Observed scale-down stabilisation — 5-minute default window prevents premature scale-down
- ✅ Configured custom HPA behaviour — shorter stabilisation window and Pods-type policies
- ✅ Explained all five HPA metric types and which metrics pipeline each uses
- ✅ Understood why HPA does not use the Eviction API and what that means for PDB

**Key Takeaway:** HPA is the right tool when adding more pods solves the problem — stateless workloads where every replica is interchangeable. The metrics pipeline (cAdvisor → metrics-server → HPA controller) runs at 60-second and 15-second intervals respectively; the scale subresource is what HPA writes to, never the full Deployment spec. Correct resource requests are the prerequisite for a meaningful HPA signal — a wrong request value makes the formula produce wrong answers. For right-sizing those requests, see `03-vpa-fundamentals`.

---

## Break-Fix

Four broken scenarios below. For each: apply the configuration, read the symptom from the cluster, diagnose, then reveal the answer.

---

### Error-1 — HPA TARGETS stays `<unknown>` permanently

**`src/break-fix/01-hpa-missing-requests.yaml`:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-no-requests
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-no-requests
  template:
    metadata:
      labels:
        app: nginx-no-requests
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
          # BUG: no resources block — no requests, no limits
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hpa-no-requests
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-no-requests
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```

```bash
kubectl apply -f src/break-fix/01-hpa-missing-requests.yaml
# Wait 90 seconds, then:
kubectl get hpa hpa-no-requests
kubectl describe hpa hpa-no-requests | grep -A3 "Conditions:"
kubectl top pods -l app=nginx-no-requests
```

`kubectl top pods` shows CPU usage. `kubectl get hpa` shows `<unknown>/50%` after 90 seconds. What is wrong?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
NAME              TARGETS           MINPODS   MAXPODS   REPLICAS
hpa-no-requests   <unknown>/50%     1         5         1

Conditions:
  ScalingActive: False  FailedGetResourceMetric
    "missing request for cpu"
```

**Cause:** `target.type: Utilization` requires `resources.requests.cpu` to be set on every container in the pod. Utilisation is computed as `usage / request × 100` — without a request, the denominator is missing and the metric cannot be calculated. The HPA controller reports `<unknown>` permanently (not transiently — this never resolves on its own).

Note: `kubectl top pods` can still show CPU usage because cAdvisor reads directly from cgroups regardless of whether requests are set. The HPA controller is the one that needs requests — not cAdvisor.

**Fix:** Add `resources.requests.cpu` (and optionally `resources.limits.cpu`) to the container spec. Minimum viable:
```yaml
resources:
  requests:
    cpu: "100m"
```

**Cascade:** HPA holds the current replica count (1) and never scales, regardless of actual load. No error is visible in pod events — the symptom is entirely in the HPA conditions.

</details>

---

### Error-2 — HPA never scales down

**`src/break-fix/02-hpa-scaledown-disabled.yaml`:**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hpa-no-scaledown
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
      stabilizationWindowSeconds: 0
      policies:
        - type: Pods
          value: 4
          periodSeconds: 15
    scaleDown:
      selectPolicy: Disabled    # BUG: all scale-down is blocked
      policies:
        - type: Pods
          value: 2
          periodSeconds: 60
```

```bash
kubectl apply -f 01-nginx-deploy.yaml
kubectl apply -f 02-load-generator.yaml
kubectl apply -f src/break-fix/02-hpa-scaledown-disabled.yaml
# Wait for scale-up (~2 min), then remove load:
kubectl delete pod load-generator --grace-period=0 --force
# Watch for 10+ minutes — replicas never decrease
kubectl get hpa hpa-no-scaledown -w
kubectl describe hpa hpa-no-scaledown | grep -A8 "Behavior:"
```

Load is removed. CPU drops to 0%. After 15 minutes, REPLICAS has not decreased. `kubectl apply` produced no error. What is wrong?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
Behavior:
  Scale Down:
    Select Policy: Disabled
    Policies:
      - Type: Pods  Value: 2  Period: 60 seconds
```

**Cause:** `scaleDown.selectPolicy: Disabled` blocks ALL scale-down regardless of any policies defined. The `policies` list entries are irrelevant when `selectPolicy: Disabled` is set — the select policy overrides them entirely. This is valid YAML and applies without error.

**Fix:** Change `selectPolicy: Disabled` to `selectPolicy: Max` (or `Min`). The `Disabled` value is intentional — it is a legitimate way to freeze scale-down during an incident. In this case it was applied by mistake (or copy-pasted from an incident runbook without reverting).

**Cascade:** Pods accumulate indefinitely after a load spike. If this behaviour goes unnoticed, the Deployment slowly wastes cluster resources until maxReplicas is reached and stays there. Cost impact can be significant in production.

</details>

---

### Error-3 — AmbiguousSelector: two HPAs on same Deployment

**`src/break-fix/03-hpa-ambiguous-selector.yaml`:**

```yaml
# This file creates a SECOND HPA targeting nginx-deploy.
# The first HPA (nginx-hpa-cpu) already exists from Step 4.
# Apply this while nginx-hpa-cpu is still running.
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hpa-duplicate       # BUG: different name, same scaleTargetRef
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-deploy      # same Deployment as nginx-hpa-cpu
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 70
```

```bash
# Ensure nginx-hpa-cpu exists first:
kubectl apply -f 01-nginx-deploy.yaml
kubectl apply -f 03-hpa-cpu-v2.yaml
# Now apply the conflicting second HPA:
kubectl apply -f src/break-fix/03-hpa-ambiguous-selector.yaml

# Wait ~30 seconds then check both HPAs:
kubectl get hpa
kubectl describe hpa nginx-hpa-cpu | grep -A3 "Events:"
kubectl describe hpa hpa-duplicate | grep -A3 "Events:"
```

Both HPAs apply successfully. What happens to scaling, and why?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
Events:
  Warning  FailedGetScale  Unauthorized: ... AmbiguousSelector ...
  (same warning appears in BOTH HPA event logs)
```

**Cause:** Two HPA objects reference the same `scaleTargetRef` (the `nginx-deploy` Deployment). The HPA controller detects multiple HPAs competing for the same workload and reports `AmbiguousSelector` — it cannot determine which HPA is authoritative and refuses to act on either. Both HPAs stop scaling. The Deployment replica count freezes at whatever it was when the conflict was introduced.

**Fix:** Delete one of the two HPAs. Only one HPA may target any given workload:
```bash
kubectl delete hpa hpa-duplicate
```

**Cascade:** The `nginx-deploy` Deployment is effectively unmanaged — no scaling in either direction — for the entire duration the conflict exists. Neither HPA's minReplicas/maxReplicas are enforced.

</details>

---

### Error-4 — HPA formula miscalculation (Utilization vs AverageValue confusion)

**`src/break-fix/04-hpa-wrong-target-type.yaml`:**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hpa-wrong-target
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
          type: AverageValue      # BUG: using AverageValue instead of Utilization
          averageValue: "50"      # BUG: this means "50 nanocores", not "50%"
                                  # For Utilization: 50 means 50% of request
                                  # For AverageValue: 50 means 50 nanocores (0.05m)
                                  # nginx at idle already uses ~2m CPU
                                  # so HPA immediately sees usage >> target
```

```bash
kubectl apply -f 01-nginx-deploy.yaml
kubectl apply -f src/break-fix/04-hpa-wrong-target-type.yaml
kubectl get hpa hpa-wrong-target -w
```

Without any load generator, the HPA immediately scales to maxReplicas. Why?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
NAME              TARGETS           MINPODS   MAXPODS   REPLICAS
hpa-wrong-target  2m/50             1         5         1
hpa-wrong-target  2m/50             1         5         5    ← scaled to max immediately
```

**Cause:** `target.type: AverageValue` with `averageValue: "50"` means "target 50 nanocores of average CPU per pod." Nanocores is the unit in which metrics-server reports CPU — `2m` (2 millicores) displayed by `kubectl top` is actually `2,000,000 nanocores`. Even nginx at idle uses far more than 50 nanocores, so the HPA immediately computes a desiredReplicas far above maxReplicas and caps at 5.

The intended configuration was:
```yaml
target:
  type: Utilization
  averageUtilization: 50    # 50% of request — correct for CPU percentage target
```

**Fix:** Change `type: AverageValue` to `type: Utilization` and rename `averageValue` to `averageUtilization`. Alternatively, if `AverageValue` is intentional, the value should be a millicore quantity like `"50m"` (50 millicores) not `"50"` (50 nanocores).

**Cascade:** HPA pegs at maxReplicas immediately on creation, wastes resources, and cannot scale down below maxReplicas until the configuration is corrected.

</details>

---

## Interview Prep

**Q1. You set up an HPA with `type: Resource` targeting CPU at 50%. Load is applied and `kubectl top pods` shows 180m CPU per pod against a 200m request (90% utilisation). But `kubectl get hpa` shows `<unknown>/50%` and REPLICAS stays at 1. What do you check first, and why might this happen?**

The `<unknown>` in TARGETS means the HPA controller cannot compute the metric, not that it cannot act. First check: `kubectl describe hpa <name> | grep -A5 Conditions` — look at `ScalingActive`. If `FailedGetResourceMetric`, the likely cause is that `resources.requests.cpu` is not set on one or more containers in the pod. HPA uses `type: Utilization` which computes `usage / request × 100` — without a request, the formula has no denominator and the metric is undefined. `kubectl top pods` can still show usage because cAdvisor reads from cgroups directly; the issue is HPA-side. Second check: wait 60–90 seconds — the first `<unknown>` after pod creation is transient (metrics-server hasn't scraped yet). Transient resolves; missing request does not.

**Q2. Explain the HPA scale-down stabilisation window. Why does it exist, and what is the consequence of setting it to 0?**

The default `scaleDown.stabilizationWindowSeconds: 300` (5 minutes) means HPA records every recommended replica count over the last 5 minutes and only scales down to the HIGHEST recommendation seen in that window. This prevents thrashing: traffic bursts are rarely isolated — if load drops briefly and HPA immediately removes pods, the next traffic spike requires scaling back out (which takes time and causes a gap in capacity). With `stabilizationWindowSeconds: 0`, HPA scales down immediately when the metric drops below target. This is appropriate when workloads genuinely have sharp, isolated traffic peaks with no concern about churn — but in most web workloads it causes scale-in/scale-out oscillation that is worse than the idle pod cost.

**Q3. You have `behavior.scaleUp.policies` with two entries: `{type: Pods, value: 4, periodSeconds: 15}` and `{type: Percent, value: 100, periodSeconds: 30}`, with `selectPolicy: Max`. At 1 replica with sustained high demand, how many replicas does HPA target after 30 seconds, and which policy won?**

After 30 seconds: `Pods` policy allows 4+4=8 pods (two 15-second windows in 30 seconds). `Percent` policy allows +100% of 1 = 2 pods in 30 seconds. `selectPolicy: Max` picks the result with the most change — `Pods` wins (8 > 2). HPA targets min(8, maxReplicas). Note: the `Pods` policy wins at small replica counts because the absolute step (4 per window) exceeds the relative step (100% of 1 = 1). The crossover point where `Percent` overtakes `Pods` is at 4+ replicas: at 5 replicas, Pods gives +8 (5+4+4) while Percent gives +10 (5+100%=10, then 10+100% capped at two windows but starting from 5, not 10 — actually 5→10 in first 30s, Percent wins). The selectPolicy governs which policy drives the outcome each cycle.

**Q4. What is the difference between `ScalingActive: False` and `AbleToScale: False` in `kubectl describe hpa` output? Which is more serious?**

`ScalingActive: False` is more serious. It means HPA cannot compute a desired replica count at all — the metric pipeline is broken (no metrics-server, missing resource requests, or invalid selector). HPA is completely non-functional; no scaling occurs in any direction. `AbleToScale: False` means HPA CAN compute a desired replica count but is temporarily prevented from acting on it — usually because it recently scaled and is in a stabilisation window (BackoffDownscale, BackoffUpscale, BackoffBoth). This is often expected behaviour, not an error. The sequence to read conditions: check `ScalingActive` first (is the metric pipeline working?); only if True, check `AbleToScale` (is HPA allowed to act right now?); only if True, check `ScalingLimited` (is the desired count hitting min/max bounds?).

**Q5. Why does HPA use direct pod DELETE for scale-down instead of the Eviction API, and what practical problem does this create?**

HPA was designed before the Eviction API matured. Its scale-down path uses direct deletion for simplicity and speed — this is a known design limitation discussed in Kubernetes SIG Autoscaling but not changed to avoid breaking existing behaviour. The practical problem: HPA scale-down bypasses PodDisruptionBudgets. If a Deployment has `minAvailable: 3` and HPA decides to scale from 5 to 1, it will DELETE 4 pods simultaneously via the scale subresource, dropping below the PDB's minimum of 3. The PDB is never consulted. By contrast, `kubectl drain` and VPA Updater both use the Eviction API and DO respect PDB. The workaround: set HPA `minReplicas` to match or exceed the PDB's `minAvailable` — this prevents HPA from ever trying to scale below the PDB floor.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Demo concept / command | CKA objective | CKAD objective | Notes |
|---|---|---|---|
| HPA, VPA, CA — types and ownership overview | Workloads & Scheduling (15%) | Application Deployment (20%) | Conceptual foundation for both exams; CA requires cloud infra and is theory-only in this demo |
| cAdvisor / metrics-server architecture, Metrics API | Troubleshooting (30%) | Application Observability and Maintenance (15%) | Understanding the pipeline is the prerequisite for diagnosing `<unknown>` HPA/VPA metrics on either exam |
| HPA v2 YAML — `scaleTargetRef`, `minReplicas`/`maxReplicas`, `Resource` metric | Workloads & Scheduling (15%) | Application Deployment (20%) | Both exams expect a working HPA manifest under time pressure; `kubectl autoscale` + edit is faster than writing YAML from scratch |
| HPA scaling formula and tolerance | Workloads & Scheduling (15%) | Application Deployment (20%) | Task may show `kubectl describe hpa` output and require the resulting replica count |
| Scale-down stabilisation window (default 300s) | Workloads & Scheduling (15%) | Application Deployment (20%) | Common trap: expecting scale-down within seconds of load dropping |
| HPA `behavior` — `Pods`-type policies | Workloads & Scheduling (15%) | Application Deployment (20%) | CKAD tasks are more likely to probe `behavior` tuning specifics; CKA tasks more likely to test default values |
| HPA + PDB — why HPA bypasses the Eviction API | Troubleshooting (30%) | Application Observability and Maintenance (15%) | More heavily weighted on CKA (cluster-level disruption behaviour) than CKAD |
| `<unknown>` HPA metric — missing `resources.requests` | Troubleshooting (30%) | Application Environment, Configuration and Security (25%) | CKAD's Environment/Config/Security domain directly owns resource requests/limits |

### Common Exam Traps

| Scenario | What the task actually requires | Common wrong approach |
|---|---|---|
| `kubectl describe hpa` shows `<unknown>` right after creating the HPA and starting load | Wait 30-60s for metrics-server's first scrape cycle before treating this as broken; only check `resources.requests` if it's still `<unknown>` after that | Immediately rewriting the HPA manifest, or checking `resources.requests` first when the real issue is just transient timing |
| Load has dropped to 0% but the task's time budget expects scale-down to have happened already | Know that default `scaleDown.stabilizationWindowSeconds` is 300s; wait it out, or set a shorter `behavior.scaleDown.stabilizationWindowSeconds` if the task calls for fast scale-down | Treating a still-high replica count after 30-60 seconds as a bug and deleting/recreating the HPA |
| Task says "create an HPA that scales at 50% CPU" via the imperative command | `kubectl autoscale deployment X --cpu=50% --min=1 --max=5` — current, non-deprecated flag, with `--min`/`--max` both set | Using the deprecated `--cpu-percent=50` flag, or omitting `--min`/`--max` (both required) |
| Task ends up with two HPA objects both targeting the same Deployment | Recognize `AmbiguousSelector` in HPA events and delete the extra HPA — only one HPA per workload is valid | Assuming the HPAs will "merge" their metrics, or that the most recently applied one silently takes over |

---

## Key Takeaways

| Concept | Detail |
|---|---|
| cAdvisor role | Embedded in kubelet; reads container CPU/memory from cgroup filesystem; no storage — live snapshot only; exposes per-container data at `/metrics/resource` |
| metrics-server role | Cluster addon; scrapes every kubelet every 60s; aggregates per-container data into PodMetrics and NodeMetrics; exposes via `metrics.k8s.io`; retains only the most recent sample |
| cAdvisor → metrics-server aggregation | cAdvisor provides per-container values; metrics-server aggregates to pod level (sum of containers) and node level |
| HPA metrics pipeline | cAdvisor → kubelet `/metrics/resource` → metrics-server → `metrics.k8s.io` → HPA controller (every 15s) → scale subresource |
| Scale subresource | `/scale` sub-path on a workload's API endpoint; HPA writes ONLY to this, never to the full Deployment spec |
| HPA scaling formula | `desiredReplicas = ceil[currentReplicas × (currentMetricValue / desiredMetricValue)]` |
| 10% tolerance | HPA does not scale if metric is within ±10% of target — prevents flapping |
| MAX rule | Multiple metrics: HPA evaluates each independently and takes the maximum desired replica count |
| `<unknown>` — transient | First 30-60s after pod creation: metrics-server hasn't scraped yet. Wait and it resolves |
| `<unknown>` — permanent | Missing `resources.requests` on one or more containers: HPA cannot compute utilisation% |
| Scale-down stabilisation | Default 300s window; HPA records highest recommendation seen over that window; only scales to that high; prevents premature scale-down |
| `selectPolicy: Max` | Most aggressive policy wins each evaluation cycle (default) |
| `selectPolicy: Min` | Most conservative policy wins — controlled, cautious scaling |
| `selectPolicy: Disabled` | Blocks ALL scaling in that direction; policies list is ignored; valid YAML with no apply-time error |
| `type: Pods` and `type: Percent` can mix | `policies` is a list; both types valid simultaneously; `selectPolicy` arbitrates each cycle |
| HPA does not use Eviction API | Scale-down uses direct DELETE via scale subresource; PDB is NOT respected; this is a known design limitation |
| PDB + HPA safeguard | Set `minReplicas` ≥ PDB `minAvailable` — prevents HPA from trying to scale below the PDB floor |
| `Utilization` vs `AverageValue` for CPU | `Utilization: 50` = 50% of cpu request; `AverageValue: "50m"` = 50 millicores raw; `AverageValue: "50"` = 50 nanocores (almost certainly wrong for CPU) |
| Namespace rule | HPA and scaleTargetRef must be in the same namespace; cross-namespace targeting silently fails |
| `kubectl autoscale` modern flag | `--cpu=50%` not `--cpu-percent` (deprecated); internally creates `autoscaling/v2` |
| One HPA per workload | Two HPAs on the same Deployment → AmbiguousSelector → both HPAs stop working |

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get hpa` | List all HPAs — TARGETS, MINPODS, MAXPODS, REPLICAS |
| `kubectl describe hpa <name>` | Full HPA status — metrics, conditions, events |
| `kubectl get hpa <name> -w` | Watch HPA scaling decisions in real time |
| `kubectl get hpa <name> -o yaml` | Full YAML including current status |
| `kubectl autoscale deployment <name> --cpu=50% --min=1 --max=5` | Create HPA imperatively (v2 internally) |
| `kubectl top pods` | Current pod CPU/memory (requires metrics-server) |
| `kubectl top nodes` | Current node CPU/memory |
| `kubectl get apiservices \| grep metrics` | Verify Metrics API is registered |
| `kubectl get events --sort-by='.lastTimestamp' \| grep -i scale` | Scaling events |

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
# SuccessfulRescale event appears after 5 minutes of consistent low demand
```

**HPA targeting a workload in a different namespace:**
```bash
# HPA and its scaleTargetRef must be in the same namespace
kubectl get hpa -n <namespace>
kubectl describe hpa <name> -n <namespace>
# ScalingActive: False FailedGetScale → target not found
# Check: HPA namespace == Deployment namespace
# Cross-namespace targeting is not supported — create the HPA in the
# same namespace as the Deployment it manages

# v1beta1.metrics.k8s.io should show True
# If False or absent: metrics-server pod may be crash-looping
kubectl describe pod -n kube-system -l k8s-app=metrics-server
```
## Appendix — Anki Cards

**`01-hpa-basic-anki.csv`:**

```
#deck:k8s-platform-labs::11-auto-scaling::01-hpa-basic
#separator:Comma
#columns:Front,Back,Tags
"What is cAdvisor and where does it run?","cAdvisor (container Advisor) is an open-source agent embedded directly inside every kubelet process — not a separate Deployment. It reads container CPU and memory usage from the Linux cgroup filesystem, aggregates per container, and exposes the data at the kubelet's /metrics/resource endpoint. It stores nothing — it is a live snapshot reader only.","01-hpa-basic,cadvisor,architecture"
"Why does cAdvisor read from cgroups instead of /proc?","/proc gives a process-level view tied to a specific PID and cannot aggregate all processes in a container. cgroups groups all processes in a container into a hierarchy — reading the cgroup gives the TOTAL usage of ALL processes inside the container. A forking application with PIDs 1, 10, 11, 12 would show only PID 1 via /proc but ALL four combined via cgroup.","01-hpa-basic,cadvisor,cgroups"
"How long does cAdvisor retain metrics?","Zero retention. cAdvisor is a live reader — every time metrics-server calls the kubelet endpoint, cAdvisor reads current cgroup values and returns them. No historical buffer, no rolling window. For historical data, use Prometheus.","01-hpa-basic,cadvisor,retention"
"What is metrics-server and what does it aggregate?","metrics-server is a cluster addon (Deployment in kube-system) that scrapes cAdvisor data from every node's /metrics/resource endpoint every 60 seconds. It aggregates: per-container data → PodMetrics (pod-level + container breakdown); pod data → NodeMetrics (node-level). Exposes via metrics.k8s.io API. Retains only the most recent sample per pod — not a time-series database.","01-hpa-basic,metrics-server,architecture"
"What is working set memory, and why does kubectl top use it instead of RSS?","Working set = RSS minus recently-used-but-releasable file cache = memory the container genuinely needs right now. RSS overstates committed memory because it includes idle file cache that the kernel would release under memory pressure. Working set is more meaningful for HPA decisions (avoids false scale-out from idle cache) and matches OOMKill triggering (OOMKill is based on working set, not RSS).","01-hpa-basic,metrics-server,working-set"
"What are NodeMetrics and PodMetrics?","Two resource kinds exposed by metrics-server via the metrics.k8s.io API. NodeMetrics (cluster-scoped): CPU and memory per node — queried by kubectl top nodes. PodMetrics (namespace-scoped): CPU and memory per pod with per-container breakdown — queried by kubectl top pods. Not stored CRDs — each request returns a fresh live read from metrics-server's in-memory store.","01-hpa-basic,metrics-server,api-resources"
"What is the HPA scaling formula?","desiredReplicas = ceil[currentReplicas × (currentMetricValue / desiredMetricValue)]. Example: 1 replica, CPU at 115%, target 50%: ceil[1 × (115/50)] = ceil[2.3] = 3. The formula applies the same way for CPU%, memory%, and custom metrics using AverageValue.","01-hpa-basic,hpa,formula"
"What is the HPA 10% tolerance and why does it exist?","HPA does not scale if the metric ratio (current/target) is within 10% of 1.0 — i.e. between 0.9 and 1.1. This prevents flapping: a metric that oscillates around the target would otherwise trigger constant scale-up and scale-down events. Example: target 50%, current 54% — ratio = 1.08, within tolerance, no scaling. Current 56%: ratio = 1.12, outside tolerance, scale-up triggered.","01-hpa-basic,hpa,tolerance"
"What does HPA do when multiple metrics are configured?","HPA evaluates each metric independently and takes the MAXIMUM desired replica count across all of them. Example: CPU suggests 3 replicas, memory suggests 1 replica — HPA targets 3. Safety rule: if ANY metric is unavailable AND suggests scale-down, scaling is skipped entirely (safe default). If ANY metric is unavailable AND suggests scale-up, scale-up proceeds using available metrics only.","01-hpa-basic,hpa,multiple-metrics"
"What is the scale subresource and why does HPA use it?","The scale subresource is a /scale sub-path on a workload's API endpoint (e.g. /apis/apps/v1/namespaces/default/deployments/nginx-deploy/scale) that contains only the replica count and selector — not the full spec. HPA updates ONLY the scale subresource, never the full Deployment spec. This keeps changes lightweight and is why `kubectl get deployment -o yaml` shows updated replicas even though HPA never modified the YAML.","01-hpa-basic,hpa,scale-subresource"
"Why does HPA not use the Eviction API for scale-down?","HPA was designed before the Eviction API matured. Its scale-down path uses direct DELETE on pods via the scale subresource — simpler and faster but bypasses PodDisruptionBudgets. This is a known design limitation discussed in Kubernetes SIG Autoscaling but not changed to avoid breaking existing behaviour. VPA Updater and kubectl drain DO use the Eviction API and respect PDB.","01-hpa-basic,hpa,eviction-api,pdb"
"kubectl top shows CPU usage but HPA TARGETS shows <unknown>. What is the most likely cause?","Missing resources.requests.cpu on at least one container in the pod. HPA type: Utilization computes usage/request × 100 — without a request, the denominator is missing and the metric cannot be computed. kubectl top works because cAdvisor reads from cgroups regardless of whether requests are set. The <unknown> is permanent until requests are added.","01-hpa-basic,break-fix,unknown-metric"
"What does ScalingActive: False mean in kubectl describe hpa, and how is it different from AbleToScale: False?","ScalingActive: False means the metric pipeline is broken — HPA cannot compute a desired replica count at all. The most common causes: metrics-server not running, missing resources.requests, or invalid pod selector. Fix the metric source first. AbleToScale: False means HPA CAN compute but is temporarily blocked — usually in a stabilisation/cooldown window after a recent scale event. This is often normal expected behaviour, not an error.","01-hpa-basic,hpa,conditions,troubleshooting"
"What is the default scaleDown stabilisation window and what does it prevent?","Default: 300 seconds (5 minutes). During this window, HPA records every recommended replica count and only scales down to the HIGHEST recommendation seen. This prevents thrashing: if load drops briefly, HPA waits to confirm the drop is sustained before removing pods, avoiding a scale-in/scale-out cycle within minutes.","01-hpa-basic,hpa,stabilisation-window"
"What does selectPolicy: Disabled do in a behavior block?","Blocks ALL scaling in that direction entirely — scale-up or scale-down is frozen. Any policies listed alongside it are ignored. Valid YAML, applies without error. Use during incidents to freeze a direction while investigating. Setting scaleDown.selectPolicy: Disabled means the Deployment will never scale in, regardless of how low the metric drops.","01-hpa-basic,hpa,selectpolicy"
"Describe the selectPolicy: Max worked example: 1 replica, policies: [{Pods, 4, 15s}, {Percent, 100, 30s}]. After 30 seconds, how many replicas?","Pods policy: 1→5 (+4, then +4 again but desire already 5 by second 15s window). Percent policy: 1→2 (+100% of 1). selectPolicy: Max picks Pods (proposes more change: +4 vs +1). Result: 5 replicas. At large replica counts the crossover reverses — Percent proposes more than the fixed Pods step.","01-hpa-basic,hpa,selectpolicy,behavior"
"What is the difference between type: Utilization and type: AverageValue for CPU?","Utilization: expressed as an integer percentage of the request (averageUtilization: 50 means 50% of resources.requests.cpu). Requires resources.requests to be set. AverageValue: raw quantity (averageValue: 50m means 50 millicores; averageValue: 50 means 50 nanocores — almost never intended). Common mistake: averageValue: 50 for CPU looks like 50% but means 50 nanocores, causing immediate runaway scale-out.","01-hpa-basic,hpa,target-type"
"Two HPAs target the same Deployment. What happens?","AmbiguousSelector conflict — the HPA controller cannot determine which HPA is authoritative and stops processing BOTH. Both HPAs report FailedGetScale: Unauthorized with AmbiguousSelector in events. The Deployment replica count freezes. Fix: delete the extra HPA. Rule: one HPA per workload.","01-hpa-basic,break-fix,ambiguous-selector"
"(CKA) kubectl autoscale deployment nginx --min=1 --max=5 --cpu=50%. Which API version does this create internally?","autoscaling/v2 — kubectl autoscale creates v2 internally regardless of flag format. Verify with: kubectl get hpa nginx -o yaml | grep apiVersion. The --cpu=50% flag is the current form; --cpu-percent is deprecated.","01-hpa-basic,cka-domain2,imperative"
"(CKA) An HPA has behavior.scaleDown.selectPolicy: Disabled. The metric drops to 0%. After 10 minutes, REPLICAS is still at 5. kubectl apply produced no error. What is wrong?","selectPolicy: Disabled in the scaleDown block blocks all scale-down permanently regardless of metric values or policies listed. Valid YAML, no error at apply time. Fix: change selectPolicy to Max or Min.","01-hpa-basic,cka-domain5,break-fix,selectpolicy"
```

---

## Appendix — Quiz

````markdown
# Quiz — 11-auto-scaling/01-hpa-basic: HPA and the Kubernetes Horizontal Scaling Model

> One correct answer per question unless stated otherwise.
> Target: 17/20 or above before moving to 02-hpa-advanced.

**Q1. What does cAdvisor read to collect container CPU and memory usage?**

A. `/proc/<pid>/stat` for each process in the container
B. The Linux cgroup filesystem (`/sys/fs/cgroup/`)
C. The `metrics.k8s.io` API endpoint
D. The kubelet's internal in-memory cache

<details>
<summary>Answer</summary>

**B** — cAdvisor reads the Linux cgroup filesystem. Each container runtime creates a cgroup hierarchy per container; cAdvisor reads the hierarchy totals to get ALL processes in the container, not just PID 1.

Trap A: `/proc/<pid>/stat` gives per-process view, cannot aggregate across all processes in a container. Trap C: cAdvisor feeds metrics-server, not the other way around. Trap D: no such cache.

</details>

---

**Q2. metrics-server scrapes kubelet every 60 seconds. What does it retain after each scrape?**

A. The last 5 minutes of samples (rolling window)
B. The last 15 seconds of samples
C. Only the most recent sample per pod/container
D. All samples since metrics-server started, up to 1GB

<details>
<summary>Answer</summary>

**C** — metrics-server retains only the most recent sample. It is not a time-series database. Restarting metrics-server clears all data.

Trap A and B: no rolling window. Trap D: no accumulation.

</details>

---

**Q3. `kubectl top pods` shows a container using 180m CPU. `kubectl get hpa` shows `<unknown>/50%` after 90 seconds. What is the most likely cause?**

A. metrics-server is not running
B. The HPA controller sync period has not elapsed yet
C. `resources.requests.cpu` is not set on the container
D. The Deployment has 0 replicas

<details>
<summary>Answer</summary>

**C** — `<unknown>` after 90 seconds is permanent — transient `<unknown>` resolves within 60s. `kubectl top` working confirms metrics-server is running and cAdvisor is producing data. Missing `resources.requests.cpu` means the HPA formula denominator is undefined.

Trap A: kubectl top working proves metrics-server is up. Trap B: 90 seconds is well past the 60s scrape cycle. Trap D: 0 replicas would show 0 pods in kubectl get pods, and REPLICAS: 0 in kubectl get hpa.

</details>

---

**Q4. A Deployment has 2 replicas. HPA target is CPU 50%. Current average CPU is 140%. What does HPA scale to?**

A. 4 — ceil[2 × (140/50)] = ceil[5.6] = 6... wait that's 6
B. 3 — ceil[2 × (140/100)] = ceil[2.8] = 3
C. 6 — ceil[2 × (140/50)] = ceil[5.6] = 6
D. 5 — ceil[2 × (140/50)] = 5.6, rounded down

<details>
<summary>Answer</summary>

**C** — `ceil[2 × (140/50)] = ceil[5.6] = 6`. The formula always uses `ceil()` (ceiling, rounds up).

Trap B: uses 100 as the denominator — the target is 50%, not 100%. Trap D: the formula uses ceiling, not floor or round.

</details>

---

**Q5. HPA tolerance is 10%. Target is 50%. Current CPU is 53%. Does HPA scale up?**

A. Yes — 53% > 50%, HPA scales up
B. No — 53/50 = 1.06, within the 10% tolerance band, no scaling
C. No — HPA only scales up if CPU exceeds 100%
D. Yes — tolerance only applies to scale-down

<details>
<summary>Answer</summary>

**B** — ratio = 53/50 = 1.06. The tolerance band is ±10% around 1.0, so ratios between 0.9 and 1.1 do not trigger scaling. 1.06 is within that band.

Trap A: crossing the target does not automatically trigger scaling — must be outside the tolerance. Trap C: no such rule. Trap D: tolerance applies to both scale-up and scale-down.

</details>

---

**Q6. HPA has two metrics: CPU at 115% (target 50%) and memory at 8% (target 70%). How many replicas does HPA target from a starting point of 1?**

A. 1 — memory is below target, so no scaling
B. 3 — CPU says ceil[1×(115/50)]=3, memory says ceil[1×(8/70)]=1, MAX=3
C. 2 — average of 3 and 1
D. 4 — CPU + memory combined

<details>
<summary>Answer</summary>

**B** — HPA evaluates each metric independently and takes the MAX. CPU: ceil[1×(115/50)] = ceil[2.3] = 3. Memory: ceil[1×(8/70)] = ceil[0.11] = 1. MAX(3,1) = 3.

Trap A: the MAX rule means one metric exceeding target is sufficient. Trap C: metrics are not averaged. Trap D: metrics are not summed.

</details>

---

**Q7. What is the scale subresource, and what does HPA write to it?**

A. A separate object in etcd that stores the Deployment's YAML
B. A sub-path on the Deployment's API endpoint that contains only the replica count; HPA writes the desired replica count here
C. A Kubernetes Event that records the scaling decision
D. The `/metrics/resource` endpoint on the kubelet

<details>
<summary>Answer</summary>

**B** — the scale subresource is at `.../deployments/<name>/scale` and contains only replica count and selector. HPA writes the desired replica count to it; the Deployment controller then reconciles. HPA never modifies the full Deployment spec.

Trap A: no separate etcd object for scale. Trap C: Events are read-only audit records. Trap D: that is a kubelet endpoint, not part of the HPA pipeline.

</details>

---

**Q8. Why does HPA NOT use the Eviction API for scale-down?**

A. The Eviction API does not exist in autoscaling/v2
B. HPA was designed before the Eviction API matured; it uses direct DELETE for speed
C. The Eviction API only works for nodes, not pods
D. Using the Eviction API would prevent HPA from scaling below minReplicas

<details>
<summary>Answer</summary>

**B** — this is a known design decision/limitation: HPA predates the Eviction API and uses direct pod DELETE via the scale subresource. This means PDB is not respected during HPA scale-down.

Trap A: the Eviction API exists and works for pods. Trap C: the Eviction API applies to pods. Trap D: minReplicas is enforced separately, unrelated to which deletion mechanism is used.

</details>

---

**Q9. `kubectl describe hpa` shows `ScalingActive: False, FailedGetScale`. What is the correct first action?**

A. Check if the HPA is in the default scale-down stabilisation window
B. Check if the metric pipeline is working — metrics-server running and resources.requests set
C. Raise maxReplicas — the HPA has hit its ceiling
D. Delete and recreate the HPA

<details>
<summary>Answer</summary>

**B** — `ScalingActive: False` means the HPA cannot compute replicas at all. Fix the metric source first. `AbleToScale: False` (not ScalingActive) indicates cooldown. `ScalingLimited: True, TooManyReplicas` indicates hitting maxReplicas.

Trap A: that describes AbleToScale False, BackoffDownscale. Trap C: ScalingLimited True TooManyReplicas would show that. Trap D: recreating the HPA does not fix the metric problem.

</details>

---

**Q10. What does the default `scaleDown.stabilizationWindowSeconds: 300` prevent?**

A. HPA from scaling up too fast after a brief quiet period
B. HPA from removing pods immediately after a short load drop, preventing thrashing
C. HPA from scaling to maxReplicas in a single step
D. The Deployment from going below minReplicas

<details>
<summary>Answer</summary>

**B** — the stabilisation window records all scale-down recommendations over 5 minutes and only scales to the highest (least aggressive) recommendation seen. If load spikes again within the window, the scale-down is deferred. This prevents removing pods only to immediately add them back.

Trap A: the stabilisation window is for scale-DOWN, not scale-UP. Scale-up default window is 0 (immediate). Trap C: that is the job of behavior policies (Pods, Percent). Trap D: minReplicas is a hard floor independent of the stabilisation window.

</details>

---

**Q11. Two HPAs target the same Deployment. What happens?**

A. The HPA with lower minReplicas takes precedence
B. The HPA created first takes precedence
C. Both HPAs stop working — AmbiguousSelector conflict
D. The Deployment scales to the average of both HPAs' desired replica counts

<details>
<summary>Answer</summary>

**C** — the HPA controller cannot determine which HPA is authoritative and refuses to act on either. Both report FailedGetScale with AmbiguousSelector. The Deployment replica count freezes.

Traps A, B, D: no precedence or averaging — the conflict breaks both HPAs.

</details>

---

**Q12. `behavior.scaleDown.selectPolicy: Disabled` is set. After load drops to zero, what happens over the next 30 minutes?**

A. HPA scales down normally but slowly
B. HPA scales down after the stabilisationWindowSeconds elapses
C. HPA never scales down — Disabled blocks all scale-down regardless of metric
D. HPA scales down to minReplicas only

<details>
<summary>Answer</summary>

**C** — `Disabled` overrides all policies; the policies list is completely ignored. This is intentional behaviour for incident management, but is a common misconfiguration when copy-pasted.

Trap A, B, D: Disabled has no exceptions — it blocks all scale-down in that block.

</details>

---

**Q13. `kubectl autoscale deployment nginx --min=1 --max=5 --cpu=50%` creates which API version internally?**

A. autoscaling/v1
B. autoscaling/v2beta1
C. autoscaling/v2
D. autoscaling/v3

<details>
<summary>Answer</summary>

**C** — `kubectl autoscale` creates `autoscaling/v2` internally, even with the v1-style `--cpu=50%` flag. Verify with `kubectl get hpa nginx -o yaml | grep apiVersion`.

Trap A: v1 is stored as v2 internally. Trap B: v2beta1 is deprecated. Trap D: does not exist.

</details>

---

**Q14. What is the correct `kubectl autoscale` flag for CPU (not deprecated)?**

A. `--cpu-percent=50`
B. `--cpu=50%`
C. `--target-cpu=50`
D. `--averageUtilization=50`

<details>
<summary>Answer</summary>

**B** — `--cpu=50%` is the current form. `--cpu-percent` is deprecated.

Traps A, C, D: not the current standard form.

</details>

---

**Q15. A pod has `resources.requests.cpu: 200m`. `kubectl top` shows 180m CPU usage. What utilisation% does HPA calculate?**

A. 180% — usage/limit × 100
B. 90% — 180/200 × 100
C. 36% — 180/500 × 100 (using the limit)
D. Cannot calculate — usage exceeds limit

<details>
<summary>Answer</summary>

**B** — HPA `type: Utilization` computes `usage / request × 100` = 180/200 × 100 = 90%. It uses the request, not the limit.

Trap A: would require dividing by limit (100m) — wrong denominator. Trap C: uses limits not requests. Trap D: 180m is below the 200m request, well within limits.

</details>

---

**Q16. `kubectl describe hpa` shows `AbleToScale: False, BackoffDownscale`. What does this mean?**

A. The metric pipeline is broken — check metrics-server
B. HPA recently scaled down and is in the scale-down stabilisation window — normal expected behaviour
C. HPA is blocked because the Deployment is at minReplicas
D. A PodDisruptionBudget is preventing scale-down

<details>
<summary>Answer</summary>

**B** — BackoffDownscale means HPA computed a scale-down recommendation but is in the stabilisation window (still recording recommendations to take the highest). This is normal expected behaviour after a load drop — not an error.

Trap A: that is `ScalingActive: False`. Trap C: that is `ScalingLimited: True, TooFewReplicas`. Trap D: HPA does not consult PDB.

</details>

---

**Q17. Which HPA metric types require a metrics adapter beyond metrics-server?**

A. Resource and ContainerResource
B. Pods, Object, and External
C. All five metric types
D. Only External

<details>
<summary>Answer</summary>

**B** — Pods (custom.metrics.k8s.io), Object (custom.metrics.k8s.io), and External (external.metrics.k8s.io) all require a metrics adapter. Resource and ContainerResource are served by metrics-server alone.

Trap A: those two work with metrics-server. Trap C: not all five. Trap D: External is one, but Pods and Object also need an adapter.

</details>

---

**Q18. What is the difference between HPA `type: Utilization` and `type: AverageValue` for CPU?**

A. Utilization is for CPU only; AverageValue is for memory only
B. Utilization expresses the target as a percentage of resources.requests; AverageValue expresses it as a raw quantity (millicores, bytes)
C. AverageValue averages across all nodes; Utilization averages across all pods
D. They are interchangeable — same formula, different field names

<details>
<summary>Answer</summary>

**B** — Utilization: `averageUtilization: 50` means 50% of the cpu request. Requires requests to be set. AverageValue: `averageValue: "50m"` means 50 millicores raw; `averageValue: "50"` means 50 nanocores (almost certainly wrong for CPU targets).

Trap A: both work for CPU and memory. Trap C: both average across pods of the target. Trap D: different formulas — Utilization divides usage by request; AverageValue compares usage directly.

</details>

---

**Q19. (CKA-style) You run `kubectl get hpa nginx-hpa -w` and observe REPLICAS going 1→3→1→3 every 5 minutes with no traffic changes. What is the most likely cause, and how do you fix it?**

A. The HPA has two conflicting metrics — remove one
B. `scaleDown.stabilizationWindowSeconds: 0` is set — raise it to 300 or higher
C. AmbiguousSelector — delete the duplicate HPA
D. maxReplicas is set too low — raise it

<details>
<summary>Answer</summary>

**B** — oscillation between 3 and 1 every 5 minutes with no traffic change is the classic symptom of `stabilizationWindowSeconds: 0` on scaleDown. The metric briefly dips below target after scale-out, immediately triggering scale-in, then load returns and triggers scale-out again. The 5-minute default window prevents this by waiting to confirm the load has genuinely dropped.

Trap A: conflicting metrics would show `<unknown>` or AmbiguousSelector, not oscillation. Trap C: AmbiguousSelector freezes both HPAs. Trap D: hitting maxReplicas would show ScalingLimited True.

</details>

---

**Q20. (CKA-style) `kubectl describe hpa` shows `ScalingLimited: True, TooManyReplicas`. Deployment has 10 replicas. Is this an error?**

A. Yes — HPA should never hit maxReplicas; increase resources
B. No — this is expected when demand exceeds what maxReplicas can handle; raise maxReplicas if more scale is genuinely needed
C. Yes — it means minReplicas and maxReplicas are equal
D. No — it means HPA is paused by the operator

<details>
<summary>Answer</summary>

**B** — `TooManyReplicas` means HPA wants to scale beyond maxReplicas but cannot because of the configured ceiling. This is expected behaviour. If the load genuinely requires more pods, raise `maxReplicas`. If the cap is intentional (cost or capacity limit), the Deployment will stay at maxReplicas under load.

Trap A: this is not an error — it is expected functioning. Trap C: ScalingLimited TooFewReplicas would indicate minReplicas constraint. Trap D: no such pause mechanism in HPA.

</details>

---

Score guide:
| Score | Action |
|---|---|
| 20/20 | Import Anki cards, move to next Demo |
| 18–19/20 | Review the wrong answers, then proceed |
| 17/20 | Re-read relevant Concepts sections, retry those questions |
| Below 17/20 | Re-read the full lab and redo the walkthrough before proceeding |
````
