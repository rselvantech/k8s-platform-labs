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

## CKA Certification Tips

✅ **HPA API version — always autoscaling/v2:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
```

✅ **HPA scaling formula — know and apply it:**
```
desiredReplicas = ceil[currentReplicas x (currentValue / targetValue)]
```

✅ **Resource requests are mandatory for utilisation-based HPA** — without them, TARGETS shows `<unknown>`

✅ **One HPA per workload** — two HPAs on the same Deployment cause AmbiguousSelector conflict

✅ **Scale-down default stabilisation = 5 minutes (300 seconds)**

✅ **kubectl autoscale modern format:**
```bash
kubectl autoscale deployment <name> --cpu=50% --min=1 --max=5
# NOT --cpu-percent (deprecated)
```

✅ **`<unknown>` in TARGETS:**
```
Transient:   wait 30-60s after pod creation (first metrics-server scrape)
Persistent:  resources.requests not set on all containers in the pod
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
