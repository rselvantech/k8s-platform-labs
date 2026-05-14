## Lab Overview

Applications receive variable traffic throughout the day — fixed
replica counts and static resource allocations either waste money
during quiet periods or cause outages during peaks. Kubernetes
autoscaling adjusts both the number of pods and their resource
allocations automatically based on actual demand.

This demo covers the two autoscalers that can be demonstrated on
a local minikube cluster:

```
HPA                → adds/removes pod REPLICAS based on CPU, memory, or custom metrics
VPA                → adjusts CPU/memory REQUESTS per container based on usage history
Cluster Autoscaler → adds/removes NODES. requires a cloud provider
```

**Real-world scenario:** A nginx-based web application that receives
variable traffic. HPA handles traffic spikes by adding replicas. VPA
right-sizes resource requests based on observed usage — preventing
under-provisioning (OOMKill, throttling) and over-provisioning (waste).

**What this lab covers:**
- Types of scaling in Kubernetes — HPA, VPA, Cluster Autoscaler overview
- HPA architecture — metrics pipeline from cAdvisor to HPA controller
- HPA v2 API — CPU, memory, multiple metrics, ContainerResource
- HPA scaling algorithm — formula, tolerance, multiple metrics MAX rule
- Scale-down stabilisation — why pods stay up after load drops
- HPA behaviour — custom scale-up/down policies and windows
- VPA installation — three components and how they work together
- VPA update modes — Off, Initial, Recreate, InPlaceOrRecreate
- VPA recommendations — per-container CPU/memory right-sizing
- HPA + VPA conflict — safe and unsafe combinations
- Complete field reference for both HPA and VPA

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
- **REQUIRED:** Completion of Demo 06 (resource requests/limits — mandatory for HPA)
- Understanding of Deployments and replica management
- Understanding of QoS classes (helpful for VPA)

---

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain all three Kubernetes scaling types and when each applies
2. ✅ Describe the HPA metrics pipeline — cAdvisor → kubelet → metrics-server → HPA controller
3. ✅ Apply the HPA scaling formula and verify with real numbers
4. ✅ Create HPA v2 with CPU-based scaling and observe scale-up/down
5. ✅ Create HPA v2 with memory-based scaling and explain when it triggers
6. ✅ Create HPA v2 with multiple metrics and explain the MAX rule
7. ✅ Configure custom HPA behaviour — stabilisation windows and policies
8. ✅ Explain scale-down stabilisation — 5-minute default window
9. ✅ Install VPA and explain all three components (Recommender, Updater, Admission Controller)
10. ✅ Use VPA Off mode to get resource recommendations without pod changes
11. ✅ Use VPA Recreate mode and observe automatic resource adjustment
12. ✅ Explain HPA + VPA conflict and identify safe combinations
13. ✅ Read and interpret all fields in kubectl describe hpa and kubectl describe vpa

## Directory Structure

```
12-autoscaling/
├── README.md                        # This file
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

###  What Is Scaling — Types and Overview

Running fixed replicas and static resource allocations does not match
real-world traffic patterns. Applications receive low traffic at 3am
and peak traffic at 9am — fixed configurations either waste money or
cause outages.

Kubernetes provides three complementary autoscaling mechanisms:

```
HPA — Horizontal Pod Autoscaler
  What it does:  adds or removes pod REPLICAS
  Responds to:   traffic spikes — more pods = more capacity
  Best for:      stateless workloads (web servers, APIs, workers)
  Scales:        OUT (more pods) or IN (fewer pods)
  Built into:    Kubernetes core — no extra install
  CRD:           HorizontalPodAutoscaler (autoscaling/v2)

VPA — Vertical Pod Autoscaler
  What it does:  adjusts CPU/memory REQUESTS per container
  Responds to:   resource mis-sizing — too little or too much allocated
  Best for:      stateful workloads, single-pod apps, right-sizing
  Scales:        UP (more CPU/memory) or DOWN (less CPU/memory)
  Built into:    NOT included — requires separate install
  CRDs:          VerticalPodAutoscaler (autoscaling.k8s.io/v1)
                 VerticalPodAutoscalerCheckpoint (autoscaling.k8s.io/v1)

CA — Cluster Autoscaler
  What it does:  adds or removes NODES from the cluster
  Responds to:   pending pods that cannot schedule (insufficient capacity)
  Best for:      dynamic workloads on cloud infrastructure
  Scales:        nodes UP (provision) or DOWN (terminate)
  Built into:    NOT included — requires cloud provider integration
  Requires:      cloud provider API (AWS, GCP, Azure) — not on minikube
```

**How the three work together:**

```
Traffic spike:
  1. More pods needed → HPA scales out
  2. New pods cannot schedule (no node capacity) → Cluster Autoscaler
     adds a new node
  3. Pods schedule and run with initial resource settings

Over time:
  4. VPA observes actual CPU/memory usage
  5. VPA adjusts requests to match real usage (right-sizing)
  6. Better-sized requests → more accurate HPA calculations
```

**This demo covers HPA and VPA. Cluster Autoscaler is not covered in the
since it requires cloud provider integration.**

---

### Understanding HPA — Horizontal Pod Autoscaler

#### HPA Architecture and Components

```
┌─────────────────────────────────────────────────────────┐
│                    HPA Control Loop                      │
│                                                         │
│  cAdvisor → kubelet → metrics-server → Metrics API     │
│                                    ↓                    │
│              HPA Controller reads metrics               │
│                                    ↓                    │
│              Calculates desired replicas                │
│                                    ↓                    │
│              Updates Deployment/StatefulSet             │
│                                    ↓                    │
│              Deployment Controller creates/deletes pods  │
└─────────────────────────────────────────────────────────┘
```

**Components:**

```
cAdvisor:
  → embedded daemon inside every kubelet
  → reads from Linux cgroups — actual container CPU/memory usage
  → aggregates metrics per container, per pod, per node
  → does NOT store history — snapshots only

metrics-server:
  → cluster addon — not built in, must be enabled
  → queries each kubelet's /metrics/resource endpoint
  → aggregates across all nodes
  → stores only the most recent metrics (not historical)
  → exposes via Metrics API (metrics.k8s.io)
  → powers: kubectl top, HPA, VPA

HPA controller:
  → runs as part of kube-controller-manager on the control plane
  → queries Metrics API every 15 seconds (default sync period)
  → evaluates all HPA objects in the cluster
  → calculates desired replica count per HPA
  → updates the target workload's replica count via scale subresource
```

**The HPA metrics pipeline flows from container runtime through to the HPA controller:**

```
Container Runtime (Docker/containerd)
        ↓ reports resource usage via cgroups
cAdvisor (embedded in kubelet)
        ↓ collects, aggregates container metrics per node
kubelet
        ↓ exposes metrics at /metrics/resource endpoint
metrics-server (cluster addon)
        ↓ aggregates across all nodes, exposes Metrics API
Kubernetes API server (metrics.k8s.io)
        ↓ HPA controller reads from here every 15 seconds
HPA controller (inside kube-controller-manager)
        ↓ calculates desired replicas using algorithm
        ↓ updates scaleTargetRef (Deployment/StatefulSet)
Deployment controller
        ↓ creates or deletes pods to match desired replica count
```

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
               = 3  ← scale to 3 pods
```

**Tolerance — default 10%:**

```
HPA does not scale if metric is within 10% of target (to prevent flapping):
  Target 50%, current 46%  → within tolerance → NO scaling
  Target 50%, current 44%  → outside tolerance → scale DOWN
  Target 50%, current 55%  → within tolerance → NO scaling
  Target 50%, current 56%  → outside tolerance → scale UP
```

**Multiple metrics — MAX rule:**

```
When multiple metrics are configured, HPA evaluates EACH independently:
  CPU says:    ceil[ 1 × (115/50) ] = 3
  Memory says: ceil[ 1 × (8/70)  ] = 1
  HPA takes:   MAX(3, 1) = 3  ← uses highest proposed count

Safety rule:
  If ANY metric is unavailable AND it suggests scale-down
    → scaling is SKIPPED entirely (safe default)
  If ANY metric is unavailable AND it suggests scale-up
    → scale-up proceeds using only available metrics
```

#### What HPA Can Target

```
Supported:
  Deployment    → most common — stateless, parallel replicas
  StatefulSet   → supported — pods scale in ordered sequence (slower)
  ReplicaSet    → supported — prefer Deployment instead
  Custom resources implementing the scale subresource

NOT supported:
  DaemonSet     → runs exactly one pod per node — no replicas to adjust
  Job/CronJob   → run-to-completion — not long-running
```

#### HPA v1 vs v2

```
autoscaling/v1  → CPU only
                  targetCPUUtilizationPercentage field
                  kubectl autoscale creates this view by default
                  STORED as v2 internally (v1 is a simplified projection)
                  deprecated flag: --cpu-percent

autoscaling/v2  → CPU, memory, custom, external, container metrics
                  multiple metrics simultaneously
                  container-level metrics (stable since v1.30)
                  custom scale-up/down behaviour
                  current stable version — USE THIS
                  modern flag: --cpu=50%

Note: kubectl autoscale creates autoscaling/v2 internally regardless
of which flag format you use. Check with: kubectl get hpa -o yaml
```

#### Scale-Down Stabilisation — Why Pods Don't Scale Down Immediately

```
Default scale-up:   no stabilisation window → scales immediately
Default scale-down: 5-minute window (300 seconds)

How it works:
  → HPA evaluates metrics every 15 seconds
  → For scale-down: records all recommendations over last 5 minutes
  → Takes the HIGHEST recommendation from that window
  → Only scales down to that highest recommendation
  → Prevents removing pods only to immediately add them back

Verified from lab:
  Load removed   → CPU drops to 0%
  +1 minute      → still 3 replicas (within 5-min window)
  +5-9 minutes   → SuccessfulRescale: New size: 2
                   (window expired, scale-down triggered)
```

#### HPA and PodDisruptionBudget

HPA uses direct pod deletion when scaling down — it does NOT use the
Eviction API and does NOT respect PodDisruptionBudget:
```
HPA scale-down:
  → calls DELETE on pods directly via scale subresource
  → bypasses Eviction API
  → PDB is NOT consulted
  → pods removed immediately once stabilisation window expires

HPA scale-up:
  → adds replicas via Deployment controller
  → no eviction involved — only pod creation
```

> This is different from kubectl drain and VPA Updater, both of which
> use the Eviction API and respect PDB. If you need HPA to respect PDB
> during scale-down, use PDB alongside HPA but understand that HPA may
> still violate the budget during rapid scale-down events.

**Practical implication:**
```
Deployment: replicas=5
PDB: minAvailable=3 (allows 2 disruptions)
HPA: decides to scale to 2

HPA removes 3 pods directly → drops below PDB minAvailable
PDB does NOT block this — HPA bypasses Eviction API

Compare with VPA:
  VPA Updater → uses Eviction API → respects PDB
  → will not evict if budget would be violated
  → waits until budget allows
```

#### HPA CRD & kubectl commands

```
Kind:       HorizontalPodAutoscaler
API Group:  autoscaling
Version:    v2 (stable, current)
Short name: hpa

kubectl commands:
  kubectl get hpa
  kubectl describe hpa <n>
  kubectl get hpa <n> -w            # watch in real time
  kubectl get hpa <n> -o yaml       # full YAML including status
  kubectl delete hpa <n>            # deletes HPA only — pods unchanged
  kubectl autoscale deployment <n>  # imperative creation
    --cpu=50%                       # target CPU (modern format)
    --min=1                         # minimum replicas
    --max=5                         # maximum replicas
```

**kubectl get hpa — output explained:**

```
NAME           REFERENCE              TARGETS        MINPODS  MAXPODS  REPLICAS  AGE
nginx-hpa-cpu  Deployment/nginx       cpu: 37%/50%   1        5        3         38m

NAME       → HPA object name
REFERENCE  → workload being scaled (Kind/name)
TARGETS    → current/target per metric
             cpu: 37%/50%       → current 37%, target 50%
             cpu: <unknown>/50% → metrics not yet collected (pod starting)
MINPODS    → minimum replica count (never go below)
MAXPODS    → maximum replica count (never go above)
REPLICAS   → current replica count
```

**kubectl describe hpa — key sections explained:**

```
Metrics:
  resource cpu on pods (as a percentage of request): 37% (37m) / 50%
  ↑ metric type       ↑ what               ↑ current   ↑ target
  37% = utilisation % (current / request × 100)
  37m = actual CPU usage in milliCPU

Conditions:
  AbleToScale:    True   ReadyForNewScale
    → HPA can scale — not in cooldown period

  ScalingActive:  True   ValidMetricFound
    → metrics are working — HPA can calculate replicas
    → False + InvalidSelector or FailedGetScale = problem

  ScalingLimited: False  DesiredWithinRange
    → desired replicas is within min/max bounds
    → True + TooFewReplicas = at minReplicas (cannot scale down further)
    → True + TooManyReplicas = at maxReplicas (cannot scale up further)

Events:
  Normal   SuccessfulRescale  New size: 3; reason: cpu above target
    → scale event happened successfully
  Warning  FailedGetScale     Unauthorized
    → multiple HPAs targeting same deployment (AmbiguousSelector)
    → fix: delete the extra HPA — one HPA per workload
  Warning  FailedGetResourceMetric
    → metrics not available yet — wait 30-60s after pod creation
```

---

### (3) HorizontalPodAutoscaler — Complete Field Reference

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
    kind: Deployment            # Deployment, StatefulSet, ReplicaSet
    name: nginx-deploy          # name of the target workload

  # ── Replica bounds ─────────────────────────────────────────────
  minReplicas: 1                # never scale below this (default: 1)
  maxReplicas: 5                # never exceed this (REQUIRED — no default)

  # ── Metrics ────────────────────────────────────────────────────
  metrics:
    # ── Type 1: Resource — CPU or memory on pods (averaged)
    - type: Resource
      resource:
        name: cpu               # or: memory
        target:
          type: Utilization     # Utilization (%) or AverageValue (raw)
          averageUtilization: 50 # target % of request across all pods

    # ── Type 2: ContainerResource — specific container (stable v1.30+)
    - type: ContainerResource
      containerResource:
        name: cpu
        container: app          # target THIS container only (not sidecars)
        target:
          type: Utilization
          averageUtilization: 60

    # ── Type 3: Pods — custom metric averaged across pods
    - type: Pods
      pods:
        metric:
          name: requests_per_second   # custom metric name
        target:
          type: AverageValue
          averageValue: "1000"        # target 1000 req/s per pod

    # ── Type 4: Object — metric from a single Kubernetes object
    - type: Object
      object:
        metric:
          name: requests_per_second
        describedObject:
          apiVersion: networking.k8s.io/v1
          kind: Ingress
          name: main-ingress
        target:
          type: Value
          value: "10000"              # target total requests/s on Ingress

    # ── Type 5: External — metric from outside the cluster
    - type: External
      external:
        metric:
          name: sqs_queue_depth
          selector:
            matchLabels:
              queue: orders           # identifies which SQS queue
        target:
          type: AverageValue
          averageValue: "30"          # target 30 messages per pod

  # ── Custom Behaviour (optional) ────────────────────────────────
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0   # default: 0 (scale up immediately)
      selectPolicy: Max               # Max, Min, or Disabled
      tolerance: 0.1                  # default 10% — scale if outside range
      policies:
        - type: Pods                  # Pods (absolute) or Percent (relative)
          value: 4                    # add at most 4 pods per period
          periodSeconds: 15           # evaluation window
        - type: Percent
          value: 100                  # or: double pods per period
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300 # default: 300s (5 minutes)
      selectPolicy: Max
      policies:
        - type: Pods
          value: 2                    # remove at most 2 pods per period
          periodSeconds: 60
```

**Field detail reference:**

| Field | Default | Description |
|---|---|---|
| `minReplicas` | 1 | Never scale below this value |
| `maxReplicas` | none — required | Never exceed this value |
| `metrics[].type` | — | Resource, ContainerResource, Pods, Object, External |
| `metrics[].resource.target.type` | — | Utilization (%) or AverageValue (raw) |
| `behavior.scaleUp.stabilizationWindowSeconds` | 0 | How long to average before scaling up |
| `behavior.scaleDown.stabilizationWindowSeconds` | 300 | How long to average before scaling down |
| `behavior.*.selectPolicy` | Max | Max=most aggressive, Min=least, Disabled=block |
| `behavior.*.tolerance` | 0.1 (10%) | Scale only if metric deviates beyond this |

#### HPA Metric Types — Real-World Examples

**Type: Resource** — built-in, covered in this demo

```
Use case: web server with variable traffic
  Scale nginx pods when average CPU across all pods exceeds 50%
  No custom adapter needed — works with metrics-server alone
```

**Type: ContainerResource** — built-in, stable since v1.30

```
Use case: pod with main app + logging sidecar
  Without ContainerResource: HPA averages CPU across ALL containers
  → logging sidecar has high CPU → HPA thinks app is overloaded → scales up
  → incorrect scaling based on sidecar activity

  With ContainerResource: HPA only reads the 'app' container's CPU
  → scaling decision based purely on app workload
```

**Type: Pods** — requires custom metrics adapter (e.g. Prometheus Adapter)

```
Use case: message queue consumer
  Consumer pods publish 'messages_processed_per_second' metric
  HPA scales consumers to maintain 500 msg/s per pod average
  More messages in queue → metric rises → more consumer pods added
```

**Type: Object** — requires custom metrics adapter

```
Use case: scale backend based on Ingress request rate
  Ingress controller exposes 'requests_per_second' for each Ingress
  HPA scales backend Deployment when total requests exceed 10,000/s
  Single metric from one object (the Ingress) drives pod count
```

**Type: External** — requires external metrics adapter

```
Use case: SQS queue depth scaling
  AWS SQS queue depth metric published to cluster via adapter
  HPA scales worker Deployment to keep 30 messages per worker pod
  Queue grows → metric rises → more worker pods → queue drains
```

> Types Pods, Object, and External require a custom or external
> metrics adapter installed in the cluster. This demo covers Resource
> and ContainerResource (built-in with metrics-server only).

---

### Understanding VPA — Vertical Pod Autoscaler

#### VPA Architecture and Components

VPA consists of three independent components running in kube-system:

```
┌─────────────────────────────────────────────────────────────────┐
│                        VPA Components                            │
│                                                                  │
│  vpa-recommender                                                 │
│    → watches pod resource usage via Metrics API                  │
│    → builds histogram model of CPU/memory usage over time        │
│    → calculates percentile-based recommendations                 │
│    → writes recommendations to VPA object .status                │
│                                                                  │
│  vpa-updater                                                     │
│    → watches VPA objects and their recommendations               │
│    → identifies pods significantly below/above recommendations   │
│    → evicts those pods (respects PodDisruptionBudget)            │
│    → does NOT modify resources itself — eviction triggers recreate│
│                                                                  │
│  vpa-admission-controller (Mutating Webhook)                     │
│    → intercepts ALL pod creation requests to API server          │
│    → checks if VPA applies to this pod                           │
│    → injects recommended resources as JSON patch                 │
│    → called on initial create AND after updater evictions        │
└─────────────────────────────────────────────────────────────────┘
```

**How the three components work together:**

```
1. Recommender: observe pods → build usage model → write to VPA.status
2. Updater: read VPA.status → if pod resources differ → evict pod
3. Admission Controller: pod recreated → intercept → inject recommended resources
4. Pod runs with updated resources
5. Recommender: continues observing → refines recommendations
```

**Installation:**
```
VPA is NOT bundled with Kubernetes.
Source: github.com/kubernetes/autoscaler

# Install:
git clone https://github.com/kubernetes/autoscaler.git
cd autoscaler/vertical-pod-autoscaler/hack
./vpa-up.sh

# Uninstall:
./vpa-down.sh
```

#### VPA Algorithm — How Recommendations Are Calculated

The Recommender uses a histogram model of resource usage:

```
Observation period: continuous, using Metrics API data
Model: histogram of CPU and memory usage per container

Target     = 90th percentile of usage over observation window
             → 90% of the time, usage is at or below this value

Lower Bound = safety margin below Target
             → if set below this, high risk of OOM or throttling

Upper Bound = constrained by maxAllowed in resourcePolicy
             → VPA will not recommend above this

Uncapped Target = raw recommendation without min/max policy constraints
                 → may be outside your resourcePolicy bounds
```

**Example from lab verification:**

```
Container: nginx (running with load generator active)
Observation: ~60 seconds

Recommender calculated:
  Target CPU:     143m   ← 90th percentile of observed CPU usage
  Target Memory:  250Mi  ← 90th percentile of observed memory usage
  Lower Bound CPU: 50m   ← minimum safe (minAllowed from policy)
  Upper Bound CPU: 1     ← from maxAllowed in policy
  Uncapped CPU:   143m   ← same as Target (within policy bounds)

Current pod had: requests.cpu=100m, requests.memory=128Mi
VPA recommends:  requests.cpu=143m, requests.memory=250Mi
  → CPU: under-provisioned (100m vs 143m needed)
  → Memory: under-provisioned (128Mi vs 250Mi needed)
```

**Multi-container pod — per-container recommendations:**

```
Pod: web-app + log-sidecar

VPA tracks EACH container separately:
  web-app container:
    Target: cpu=500m, memory=512Mi
    VPA sets: requests.cpu=500m, requests.memory=512Mi

  log-sidecar container:
    Target: cpu=50m, memory=64Mi
    VPA sets: requests.cpu=50m, requests.memory=64Mi

Both containers right-sized independently.
Use containerPolicies to set min/max per container.
Use containerName: "*" wildcard for all remaining containers.
```

#### VPA Update Modes

```
Off:
  Recommender: ✅ runs — writes to VPA.status
  Updater:     ❌ does not evict pods
  Admission:   ❌ does not modify pod requests
  Result:      recommendations only — no pod changes
  Use for:     capacity planning, "what should my requests be?"

Initial:
  Recommender: ✅ runs — writes to VPA.status
  Updater:     ❌ does not evict pods
  Admission:   ✅ injects resources ONLY when pod is first created
  Result:      new pods get right-sized resources; running pods unchanged
  Use for:     new pods get correct resources without disrupting existing

Recreate (default):
  Recommender: ✅ runs
  Updater:     ✅ evicts pods when resources differ significantly
  Admission:   ✅ injects resources on every pod creation
  Result:      pods evicted and recreated with updated resources
  Use for:     stateless workloads where restart is acceptable

InPlaceOrRecreate:
  Recommender: ✅ runs
  Updater:     ✅ attempts in-place resize first (no restart)
  Admission:   ✅ injects on creation
  Result:      resize without restart if possible; falls back to Recreate
  Use for:     production — preferred over Recreate for less disruption

Auto (DEPRECATED since VPA v1.4+):
  Currently equivalent to Recreate
  Warning: UpdateMode "Auto" is deprecated and will be removed in a
  future API version. Use "Recreate", "Initial", or
  "InPlaceOrRecreate" instead.
  → DO NOT USE Auto in new manifests
```

**Updater eviction respects PodDisruptionBudget:**

```
VPA Updater uses the Eviction API (not direct deletion)
→ respects PDB minAvailable / maxUnavailable
→ will not evict if it would violate the budget
→ waits until budget allows eviction
```

#### What VPA Can Target

```
Supported:
  Deployment      → most common — stateless workloads
  StatefulSet     → supported — ordered pod eviction
  DaemonSet       → supported — use carefully (one pod per node)
  ReplicaSet      → supported
  Job/CronJob     → Initial mode only (no eviction of running pods)
  Custom resources → any resource implementing scale subresource
                     with label selector exposed

NOT supported:
  Standalone pods → no controller to recreate after eviction
                    VPA requires a controller to recreate evicted pods
                    → use Deployment even for single pods
  Pod-level resource stanzas → known limitation — VPA works at
                                container level only
```

#### VPA CRDs & kubectl commands

```
Two CRDs installed with VPA:

1. VerticalPodAutoscaler (vpa)
   API: autoscaling.k8s.io/v1
   → the configuration and recommendation object you create
   → contains: targetRef, updatePolicy, resourcePolicy, status/recommendations

2. VerticalPodAutoscalerCheckpoint (vpacheckpoint)
   API: autoscaling.k8s.io/v1
   → internal — stores Recommender's historical usage data
   → one checkpoint per container per VPA object
   → persists across Recommender restarts
   → you do not create these — VPA manages them automatically

kubectl commands:
  kubectl get vpa                    # list all VPAs (short name)
  kubectl describe vpa <n>           # full detail including recommendations
  kubectl get vpa <n> -o yaml        # full YAML including status
  kubectl get vpacheckpoint          # inspect historical data
  (no imperative create — VPA must be defined declaratively)
```

**kubectl get vpa — output explained:**
```bash
kubectl get vpa
```
```
NAME             MODE      CPU    MEM     PROVIDED   AGE
nginx-vpa-off    Off                      False      5s     ← no recommendation yet
nginx-vpa-auto   Recreate  143m   250Mi   True       2m50s  ← recommendation ready

NAME      → VPA object name
MODE      → update mode (Off, Initial, Recreate, InPlaceOrRecreate)
CPU       → recommended CPU request (from Target field)
MEM       → recommended memory request (from Target field)
PROVIDED  → True = recommendation available, False = still collecting
AGE       → how long this VPA has been running
```

**kubectl describe vpa — key sections explained:**
```bash
kubectl describe vpa nginx-vpa-off
```
```
Spec:
  Target Ref:
    Kind: Deployment            → what workload VPA is watching
    Name: nginx-deploy

  Update Policy:
    Update Mode: Off            → recommendations only — no eviction

  Resource Policy:
    Container Policies:
      Container Name: nginx
      Min Allowed: cpu=50m, memory=64Mi    → VPA floor
      Max Allowed: cpu=2, memory=2Gi       → VPA ceiling

Status:
  Conditions:
    Type: RecommendationProvided
    Status: True                ← True = recommendation available
                                  False = still collecting (wait ~1 min)
  Recommendation:
    Container Recommendations:
      Container Name: nginx

      Lower Bound:              → minimum safe resources
        cpu: 50m                  below this → high risk of throttling/OOM
        memory: 250Mi

      Target:                   → what VPA WILL SET as requests
        cpu: 143m                 90th percentile of observed usage
        memory: 250Mi

      Uncapped Target:          → recommendation WITHOUT min/max policy
        cpu: 49m                  may be outside resourcePolicy bounds
        memory: 250Mi             useful to compare vs policy-constrained Target

      Upper Bound:              → maximum observed need
        cpu: 2                    above this → wasteful allocation
        memory: 2Gi               constrained by maxAllowed
```

**kubectl get vpacheckpoint — what it contains:**
```bash
kubectl get vpacheckpoint
```
```
NAME                      AGE
nginx-vpa-off-nginx       2m

kubectl describe vpacheckpoint nginx-vpa-off-nginx
```
```
Spec:
  Container Name: nginx
  VPA Object Name: nginx-vpa-off

Status:
  Cpu Histogram:            → histogram of observed CPU usage
    BucketWeights: [...]      bucket = usage range, weight = frequency
    ReferenceTimestamp: ...   when this histogram was last updated
    TotalWeight: 1.0

  Memory Histogram: [...]   → histogram of observed memory usage

  LastUpdateTime: ...       → last time Recommender updated this checkpoint
  Version: ...
```
```
Checkpoint stores:
  → CPU and memory usage histograms per container
  → Persists across Recommender pod restarts
  → One checkpoint per container per VPA
  → You do not create these — Recommender manages them automatically
  → Used by Recommender to resume recommendations after restart
    without losing historical data
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
    name: nginx-deploy            # name of the target workload

  # ── Update mode ────────────────────────────────────────────────
  updatePolicy:
    updateMode: "Recreate"        # Off, Initial, Recreate, InPlaceOrRecreate
                                  # default: Recreate
                                  # DO NOT use "Auto" — deprecated

  # ── Resource constraints per container ─────────────────────────
  resourcePolicy:
    containerPolicies:
      - containerName: nginx      # specific container name
                                  # or "*" for all remaining containers
        mode: "Auto"              # Auto (default) or Off (exclude container)

        minAllowed:               # VPA will never recommend below this
          cpu: 50m
          memory: 64Mi

        maxAllowed:               # VPA will never recommend above this
          cpu: 2
          memory: 2Gi

        controlledResources:      # which resources VPA manages
          - cpu                   # default: [cpu, memory]
          - memory                # omit to manage specific resource only

        controlledValues:         # what VPA controls per resource
          # RequestsAndLimits (default) — VPA updates both requests and limits
          # RequestsOnly — VPA only updates requests, limits unchanged
```

**status — what VPA writes after observing:**

```yaml
status:
  conditions:
    - type: RecommendationProvided
      status: "True"              # True = recommendation is available
                                  # False = still collecting data (wait ~1min)
  recommendation:
    containerRecommendations:
      - containerName: nginx

        lowerBound:               # minimum safe resources
          cpu: 50m                # below this → high risk of throttling/OOM
          memory: 250Mi

        target:                   # recommended resources — VPA will SET this
          cpu: 143m               # 90th percentile of observed usage
          memory: 250Mi

        uncappedTarget:           # recommendation ignoring min/max policy
          cpu: 143m               # may be outside resourcePolicy bounds
          memory: 250Mi

        upperBound:               # maximum observed need
          cpu: 2                  # above this → wasteful allocation
          memory: 2Gi
```

| Field | Default | Description |
|---|---|---|
| `updatePolicy.updateMode` | Recreate | Off, Initial, Recreate, InPlaceOrRecreate |
| `resourcePolicy.containerPolicies[].containerName` | required | Container name or "*" wildcard |
| `resourcePolicy.containerPolicies[].mode` | Auto | Auto (manage) or Off (exclude this container) |
| `resourcePolicy.containerPolicies[].controlledValues` | RequestsAndLimits | What to update: requests+limits or requests only |
| `resourcePolicy.containerPolicies[].minAllowed` | none | VPA floor — never recommends below this |
| `resourcePolicy.containerPolicies[].maxAllowed` | none | VPA ceiling — never recommends above this |

---

### Cluster Autoscaler and Other Scaling Types

#### Cluster Autoscaler (CA)

Cluster Autoscaler scales the number of nodes in the cluster:

```
Trigger: pending pods that cannot schedule (insufficient node capacity)
Action:  calls cloud provider API → provisions new VM → joins cluster

Trigger: underutilised nodes (all pods could fit on fewer nodes)
Action:  drains pods → terminates node (respects PDB)

Requires: cloud provider integration (AWS, GCP, Azure, etc.)
          NOT demonstrable on minikube — no cloud API available
```

> On minikube, HPA can scale pods and they will schedule as long as
> cluster has capacity. Cluster Autoscaler is not needed locally.
> On EKS, CA or Karpenter handles node provisioning automatically.

**Safe combination with HPA:**

```
HPA scales pods → pods cannot schedule (no capacity)
CA detects pending pods → provisions new node
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
  Scale to zero supported (HPA cannot go below minReplicas)
  Use case: message queue consumer — scale to 0 when queue empty

Karpenter:
  AWS-native node provisioner — replaces Cluster Autoscaler on EKS
  Faster provisioning, more granular instance selection
```

### HPA vs VPA — Compare and Contrast

| | HPA | VPA |
|---|---|---|
| **What it scales** | Number of pod replicas | CPU/memory requests per container |
| **Scale direction** | Horizontal (out/in) | Vertical (up/down) |
| **Response to** | Traffic spikes — more pods needed | Resource mis-sizing — requests wrong |
| **Best for** | Stateless workloads (web, API, workers) | Stateful workloads, single-pod apps, right-sizing |
| **Minimum replicas** | minReplicas (default: 1) | N/A — no replica control |
| **Built into Kubernetes** | ✅ Yes | ❌ No — separate install required |
| **Requires metrics-server** | ✅ Yes | ✅ Yes (Recommender uses it) |
| **Metrics source** | Metrics API (metrics-server) | Metrics API (metrics-server) |
| **Eviction API** | ❌ No — direct deletion | ✅ Yes — respects PDB |
| **Respects PDB** | ❌ No | ✅ Yes |
| **API version** | autoscaling/v2 | autoscaling.k8s.io/v1 |
| **Short name** | hpa | vpa |
| **CRDs** | HorizontalPodAutoscaler | VerticalPodAutoscaler, VerticalPodAutoscalerCheckpoint |
| **Imperative creation** | ✅ kubectl autoscale | ❌ declarative only |
| **Pod restart needed** | ❌ No — adds/removes pods | ✅ Yes (Recreate mode) or ❌ No (InPlaceOrRecreate) |
| **Resource requests required** | ✅ Yes (for utilisation %) | ❌ No — VPA sets them |
| **Scale-down delay** | ✅ Yes — 5-min stabilisation | Depends on Updater frequency |
| **Can scale to zero** | ❌ No — minReplicas ≥ 1 | N/A |
| **Works with StatefulSet** | ✅ Yes (ordered scaling) | ✅ Yes |
| **Works with DaemonSet** | ❌ No | ✅ Yes (carefully) |
| **Works with standalone pod** | ❌ No (no replicas) | ❌ No (no controller to recreate) |

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

Use both together (safely):
  → HPA on CPU/memory + VPA in Off mode
    → HPA scales replicas, VPA only recommends (no conflict)
  → HPA on custom/external metrics + VPA on CPU/memory
    → HPA uses different signal — no interference

Avoid:
  → HPA on CPU/memory + VPA on CPU/memory (Recreate/Initial)
    → VPA changes requests → HPA recalculates → conflict cycle
```

---

## Lab Step-by-Step Guide

---

### Step 1: Cluster Setup and Prerequisites

```bash
cd 12-autoscaling/src

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
```

Verify control plane is tainted:
```bash
kubectl describe node 3node | grep Taints
# Should show: node-role.kubernetes.io/control-plane:NoSchedule
```

---

### Step 2: Deploy nginx Application

**nginx-deploy.yaml:**
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
              cpu: "100m"
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

### Step 3: Load Generator — busybox

`busybox` is used as the load generator — available on every node
without any additional pulls. It sends continuous HTTP requests to
the nginx service, driving CPU utilisation up.

**load-generator.yaml:**
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

**Start load generator:**
```bash
kubectl apply -f load-generator.yaml
kubectl get pod load-generator

# Watch CPU rise
watch kubectl top pods
```

**Expected output after ~30s:**
```
NAME                            CPU(cores)   MEMORY(bytes)
load-generator                  862m         6Mi
nginx-deploy-xxxxxxxxx-xxxxx    115m         15Mi
```

---

### Step 4: HPA — CPU Based (autoscaling/v2)

**hpa-cpu-v2.yaml:**
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
          averageUtilization: 50
```

```bash
kubectl apply -f hpa-cpu-v2.yaml

# Watch in real time
kubectl get hpa nginx-hpa-cpu -w
```

**Expected output — scale up observed:**
```
NAME           REFERENCE             TARGETS        MINPODS  MAXPODS  REPLICAS
nginx-hpa-cpu  Deployment/nginx-deploy  cpu: <unknown>/50%  1  5  0   ← starting
nginx-hpa-cpu  Deployment/nginx-deploy  cpu: 115%/50%       1  5  1   ← measuring
nginx-hpa-cpu  Deployment/nginx-deploy  cpu: 37%/50%        1  5  3   ← scaled up!
```

**Verify scale-up events:**
```bash
kubectl describe hpa nginx-hpa-cpu | grep -A10 Events
```

**Expected output:**
```
Events:
  Normal  SuccessfulRescale  New size: 3; reason: cpu resource utilization (percentage of request) above target
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

Min replicas: 1  Max replicas: 5
Deployment pods: 3 current / 3 desired

Conditions:
  AbleToScale:    True   ReadyForNewScale    → not in cooldown
  ScalingActive:  True   ValidMetricFound    → metrics working
  ScalingLimited: False  DesiredWithinRange  → within min/max bounds
```

**Observe scale-down — remove load:**
```bash
kubectl delete pod load-generator --grace-period=0 --force

# Watch scale-down (takes 5+ minutes due to stabilisation window)
kubectl get hpa nginx-hpa-cpu -w
```

**Expected output:**
```
nginx-hpa-cpu  Deployment/nginx-deploy  cpu: 38%/50%  1  5  3  ← load removed
nginx-hpa-cpu  Deployment/nginx-deploy  cpu: 0%/50%   1  5  3  ← CPU dropped
nginx-hpa-cpu  Deployment/nginx-deploy  cpu: 0%/50%   1  5  3  ← still 3 (window)
...
nginx-hpa-cpu  Deployment/nginx-deploy  cpu: 0%/50%   1  5  2  ← scaled down after 5min
```

```
Scale-down takes ~5+ minutes:
Default stabilisation window = 5 minutes (300 seconds)
HPA holds highest recommendation from last 5 minutes
Only scales down once window shows consistent lower demand
```

```bash
kubectl delete -f hpa-cpu-v2.yaml
```

---

### Step 5: HPA — Memory Based (autoscaling/v2)

**hpa-memory-v2.yaml:**
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
          averageUtilization: 70
```

```bash
kubectl apply -f hpa-memory-v2.yaml
kubectl get hpa nginx-hpa-memory
```

**Expected output:**
```
NAME               REFERENCE             TARGETS                 MINPODS  MAXPODS  REPLICAS
nginx-hpa-memory   Deployment/nginx-deploy  memory: <unknown>/70%  1       5        0
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
memory: 12%/70%  → 12% memory utilisation vs 70% target
                  → below threshold → no scaling
                  → nginx uses very little memory at idle
```

> Memory-based HPA is most useful for memory-intensive applications
> (JVM, Node.js, Python). nginx at idle uses minimal memory so
> scaling won't trigger without a memory-consuming load.

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

### Step 6: HPA — Multiple Metrics (autoscaling/v2)

**hpa-multi-metric.yaml:**
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
CPU says scale to: ceil[1 × (115/50)] = 3
Memory says scale to: ceil[1 × (8/70)] = 1 (below target)
HPA takes MAXIMUM → scales to 3 ✅
```

```bash
kubectl delete pod load-generator --grace-period=0 --force
kubectl delete -f hpa-multi-metric.yaml
```

---

### Step 7: Imperative HPA Creation

```bash
# Modern flag format (--cpu-percent is deprecated)
kubectl autoscale deployment nginx-deploy \
  --min=1 \
  --max=5 \
  --cpu=50%

kubectl get hpa nginx-deploy
```

**Expected output:**
```
NAME          REFERENCE             TARGETS       MINPODS  MAXPODS  REPLICAS
nginx-deploy  Deployment/nginx-deploy  cpu: 0%/50%  1       5        1
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

> `kubectl autoscale` creates `autoscaling/v2` internally even though
> the command feels like v1. The YAML output confirms v2.

```bash
kubectl delete hpa nginx-deploy
```

---

### Step 8: HPA Behaviour — Custom Scale-Down

**hpa-behaviour.yaml:**
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
      stabilizationWindowSeconds: 0    # scale up immediately
      policies:
        - type: Pods
          value: 4                     # add at most 4 pods per period
          periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 60   # wait 60s before scale-down
      policies:
        - type: Pods
          value: 2                     # remove at most 2 pods per period
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

# Watch scale-up behaviour
kubectl get hpa nginx-hpa-behaviour -w
```

**Expected output:**
```
NAME                  TARGETS              MINPODS  MAXPODS  REPLICAS
nginx-hpa-behaviour   cpu: <unknown>/50%   1        10       0
nginx-hpa-behaviour   cpu: 16%/50%         1        10       2
nginx-hpa-behaviour   cpu: 54%/50%         1        10       2
```

Check full behaviour config:
```bash
kubectl describe hpa nginx-hpa-behaviour
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

# Observe scale-down — faster than default (60s vs 300s stabilisation)
kubectl get hpa nginx-hpa-behaviour -w
```

**Expected output:**
```
nginx-hpa-behaviour  cpu: 54%/50%  ...  2  ← load removed
nginx-hpa-behaviour  cpu: 0%/50%   ...  2  ← within 60s window
nginx-hpa-behaviour  cpu: 0%/50%   ...  1  ← scaled down after 60s
```

```bash
kubectl delete -f hpa-behaviour.yaml
```

---

### Step 9: Install VPA

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
clusterrole.rbac.../system:vpa-actor created
...
deployment.apps/vpa-updater created
deployment.apps/vpa-recommender created
deployment.apps/vpa-admission-controller created
```

Verify VPA components are running:
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

---

### Step 10: VPA — Off Mode (Recommendations Only)

Off mode is the safest starting point — VPA observes and recommends
but does NOT change any pods. Use this for capacity planning.

**vpa-off.yaml:**
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
    updateMode: "Off"         # recommend only — never evict or modify pods
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

**Expected output (initially — no recommendation yet):**
```
NAME            MODE   CPU   MEM   PROVIDED   AGE
nginx-vpa-off   Off                           0s
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
    Type:   RecommendationProvided   ← recommendation ready ✅
  Recommendation:
    Container Recommendations:
      Container Name: nginx
      Lower Bound:         ← minimum safe resources
        Cpu:    50m
        Memory: 250Mi
      Target:              ← recommended resources to set
        Cpu:    50m
        Memory: 250Mi
      Uncapped Target:     ← recommendation ignoring min/max policy
        Cpu:    49m
        Memory: 250Mi
      Upper Bound:         ← maximum observed — above this is wasteful
        Cpu:    2
        Memory: 2Gi
```

**What these fields mean:**

```
Lower Bound   → if set below this → high risk of OOM or CPU throttling
Target        → what VPA recommends setting as requests
Uncapped Target → recommendation without min/max policy constraints
Upper Bound   → above this is wasteful — container never needed this much
```

**Compare current requests vs VPA recommendation:**
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

VPA says: CPU is over-provisioned (50m vs 100m)
          Memory is under-provisioned (250Mi vs 128Mi)
Mode=Off → no changes applied — these are recommendations only
```

```bash
kubectl delete -f vpa-off.yaml
```

---

### Step 11: VPA — Recreate Mode (Automatic Resource Adjustment)

Recreate mode evicts pods and recreates them with updated resource
requests when VPA determines the current resources differ significantly
from recommendations.

**vpa-recreate.yaml:**
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
    updateMode: "Recreate"    # evict and recreate pods with new resources
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

> **Note:** "Auto" mode is deprecated since VPA v1.4+. Use "Recreate",
> "Initial", or "InPlaceOrRecreate" instead. You will see this warning
> if you use "Auto":
> `Warning: UpdateMode "Auto" is deprecated...`

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
nginx-vpa-recreate Recreate  143m   250Mi   True       60s  ← recommendation ready
```

```bash
# After recommendation is available, check if pod was evicted and recreated
kubectl get pods
kubectl describe pod -l app=nginx | grep -A4 "Requests:"
```

**Expected output after VPA applies recommendation:**
```
Requests:
  cpu:     143m    ← updated by VPA (was 100m) ✅
  memory:  250Mi   ← updated by VPA (was 128Mi) ✅
```

**Watch for VPA events:**
```bash
kubectl get events --sort-by='.lastTimestamp' | grep -i vpa
```

```bash
kill $WATCH_PID 2>/dev/null
kubectl delete -f vpa-recreate.yaml
```

---

### Step 12: VPA + HPA Conflict Demo

This step demonstrates why running VPA (on CPU/memory) simultaneously
with HPA (on CPU/memory) causes conflict.

```bash
# Apply deployment, HPA on CPU, VPA on CPU/memory simultaneously
kubectl apply -f nginx-deploy.yaml
kubectl apply -f hpa-cpu-v2.yaml
kubectl apply -f vpa-conflict.yaml    # same as vpa-recreate.yaml targeting nginx-deploy
```

**vpa-conflict.yaml** (same as vpa-recreate but labelled for demo):
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

Apply load and observe the conflict:
```bash
kubectl apply -f load-generator.yaml
sleep 60

kubectl get hpa nginx-hpa-cpu
kubectl get vpa nginx-vpa-conflict
```

**Expected output showing conflict:**
```
HPA: cpu: 38%/50%  replicas: 3   ← HPA scaled up
VPA: cpu: 143m     provided: True ← VPA raised requests

After VPA raises requests:
  HPA sees: 38%/50% (with higher request denominator → lower %)
  HPA might scale DOWN ← conflict with HPA scaling up
```

**The conflict cycle:**
```
1. Load increases → HPA scales to 3 replicas
2. VPA raises cpu request from 100m to 143m per pod
3. HPA recalculates: same CPU usage / higher request = lower %
4. HPA may scale DOWN (misled by higher requests)
5. Fewer pods → higher per-pod load → VPA recommends more CPU
6. Cycle repeats → oscillation

Result: neither HPA nor VPA can stabilise the workload
```

**Safe solution:**
```bash
# Delete VPA on CPU/memory when using HPA on CPU/memory
kubectl delete -f vpa-conflict.yaml

# Keep HPA for horizontal scaling
# Use VPA in Off mode for recommendations only
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

### Step 13: Final Cleanup — Uninstall VPA

```bash
cd autoscaler/vertical-pod-autoscaler/hack
./vpa-down.sh
cd ../../..

kubectl get pods -n kube-system | grep vpa
# No VPA pods should remain
```

---

## Common Questions

### Q: Is resource request mandatory for HPA?

**A:** Yes — for CPU and memory utilisation-based scaling. HPA
calculates utilisation as `current usage / request × 100`. Without
requests, HPA cannot calculate utilisation and shows `<unknown>` in
TARGETS. For absolute value metrics (AverageValue type), requests are
not required.

### Q: Can HPA scale StatefulSets?

**A:** Yes. HPA can target any resource implementing the scale
subresource — including StatefulSets and ReplicaSets. However,
StatefulSet scaling is ordered (pods are added/removed sequentially)
which means scale-up and scale-down are slower than Deployments.

### Q: Why does HPA show `<unknown>` for metrics?

**A:** Common causes: pods are starting up and not yet reporting
metrics (wait ~30-60s), metrics-server is not running, resource
requests are not set on containers, or there is a mismatch between
HPA selector and pod labels.

### Q: What is VPA InPlaceOrRecreate?

**A:** It attempts to resize container resources in-place (without
restarting the pod) using the in-place pod resize feature. If in-place
resize is not supported or fails, it falls back to Recreate mode. This
is the preferred mode over the deprecated "Auto" mode.

### Q: Can HPA and VPA be used together?

**A:** Yes — with the right combination. VPA in Off mode (recommendations
only) + HPA on CPU/memory: safe. VPA in Recreate/Initial + HPA on
custom metrics (not CPU/memory): safe. VPA in Recreate + HPA on
CPU/memory: conflict — avoid.

---

## What You Learned

In this lab, you:
- ✅ Understood HPA architecture — cAdvisor → kubelet → metrics-server → HPA controller
- ✅ Applied the HPA scaling formula and verified calculation with real numbers
- ✅ Created HPA v2 with CPU, memory, and multiple metrics
- ✅ Observed scale-down stabilisation — 5-minute default window
- ✅ Configured custom HPA behaviour — faster scale-down with policies
- ✅ Installed VPA and understood three components (Recommender, Updater, Admission Controller)
- ✅ Used VPA Off mode for recommendations without pod changes
- ✅ Used VPA Recreate mode and observed automatic resource adjustment
- ✅ Demonstrated HPA + VPA conflict and the safe combination patterns
- ✅ Understood that "Auto" VPA mode is deprecated — use "Recreate" or "InPlaceOrRecreate"

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get hpa` | List all HPAs |
| `kubectl describe hpa <n>` | Full HPA status — metrics, conditions, events |
| `kubectl get hpa <n> -w` | Watch HPA scaling in real time |
| `kubectl get hpa <n> -o yaml` | Full YAML including current status |
| `kubectl autoscale deployment <n> --cpu=50% --min=1 --max=5` | Create HPA imperatively |
| `kubectl top pods` | Current pod CPU/memory (requires metrics-server) |
| `kubectl get vpa` | List all VPAs (short name) |
| `kubectl describe vpa <n>` | VPA recommendations and status |
| `kubectl get events --sort-by='.lastTimestamp' \| grep -i "scale\|vpa"` | Scaling events |

---

## CKA Certification Tips

✅ **HPA API version — autoscaling/v2:**
```yaml
apiVersion: autoscaling/v2   # ← use this
kind: HorizontalPodAutoscaler
```

✅ **HPA scaling formula:**
```
desiredReplicas = ceil[currentReplicas × (currentValue / targetValue)]
```

✅ **Resource requests are mandatory for utilisation-based HPA**

✅ **One HPA per workload — multiple HPAs targeting same deployment causes AmbiguousSelector conflict**

✅ **Scale-down default stabilisation = 5 minutes (300 seconds)**

✅ **kubectl autoscale modern format:**
```bash
kubectl autoscale deployment <n> --cpu=50% --min=1 --max=5
# NOT --cpu-percent (deprecated)
```

✅ **VPA modes:**
```
Off              → recommendations only — no pod changes
Initial          → inject resources at pod creation only
Recreate         → evict and recreate pods with new resources
InPlaceOrRecreate → try in-place first, fall back to Recreate
Auto             → DEPRECATED — do not use
```

✅ **HPA + VPA safe combinations:**
```
HPA (CPU/memory) + VPA (Off) → safe
HPA (custom metrics) + VPA (Recreate) → safe
HPA (CPU/memory) + VPA (Recreate) → conflict ❌
```

---

## Troubleshooting

**HPA TARGETS shows `<unknown>`:**
```bash
# Check metrics-server
kubectl get pods -n kube-system | grep metrics-server
kubectl top pods
# Check resource requests are set on deployment
kubectl describe deployment <n> | grep -A4 "Requests:"
# Wait 30-60s after pod creation for metrics to appear
```

**HPA not scaling up despite high CPU:**
```bash
kubectl describe hpa <n>
# Check Conditions section
# AmbiguousSelector → multiple HPAs on same deployment (delete the extra)
# FailedGetScale: Unauthorized → same issue
# ScalingLimited: True DesiredEqualToLimit → already at maxReplicas
```

**HPA not scaling down:**
```bash
# Normal — default 5-minute stabilisation window
# Check current time since load removed
kubectl describe hpa <n> | grep -A5 Events
# SuccessfulRescale event will appear after stabilisation period
```

**VPA shows no recommendations:**
```bash
kubectl describe vpa <n>
# Check Conditions: RecommendationProvided → wait 1+ minute
# Check vpa-recommender is running
kubectl get pods -n kube-system | grep vpa-recommender
kubectl logs -n kube-system -l app=vpa-recommender | tail -20
```

**VPA pod not being evicted despite recommendation:**
```bash
# Check updateMode is not "Off"
kubectl describe vpa <n> | grep "Update Mode"
# Check vpa-updater is running
kubectl get pods -n kube-system | grep vpa-updater
# Minimum of 2 replicas required for VPA eviction to work safely
# If replicas=1, VPA may not evict to avoid downtime
```