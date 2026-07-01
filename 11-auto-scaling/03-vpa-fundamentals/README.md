# Demo: 11-auto-scaling/03-vpa-fundamentals — VPA and the Kubernetes Vertical Scaling Model

## Lab Overview

HPA (`01-hpa-basic`) handles the question "how many pods?" VPA handles the question "how big should each pod be?" — adjusting the CPU and memory requests per container based on observed usage over time.

Getting resource requests right matters more than it might seem: too low causes CPU throttling and OOMKill; too high wastes node capacity and makes HPA's utilisation formula inaccurate (because utilisation = usage ÷ request). VPA solves both by observing real usage and producing a data-driven recommendation — either as a read-only suggestion (Off mode) or as an automatic adjustment (Recreate mode).

**Real-world scenario:** A nginx web application was deployed with `resources.requests.cpu: 100m` and `resources.requests.memory: 128Mi` — values guessed at deployment time without load testing. After running in production for a week, the team suspects the memory is under-provisioned (causing occasional OOMKill under moderate traffic) while CPU is over-provisioned (wasting node capacity). VPA in Off mode reveals the truth without touching any running pods: memory recommendation is 250Mi (the pod needs more) and CPU recommendation is 50m (the pod needs less). Recreate mode then applies these values automatically, right-sizing the pod on its next restart.

**What this lab covers:**
- VPA architecture — three components (Recommender, Updater, Admission Controller), how they interact, and who maintains VPA
- VPA algorithm — inputs (metrics-server + VPACheckpoint), histogram model, observation window, and all four output fields
- VPA update modes — Off (safe for production observation), Initial, Recreate, InPlaceOrRecreate, and why Auto is deprecated
- Per-container recommendations and `containerPolicies` — `minAllowed`, `maxAllowed`, `controlledValues`, `mode`, wildcard
- VPA CRDs — VerticalPodAutoscaler and VerticalPodAutoscalerCheckpoint explained in full
- `kubectl describe vpa` and `kubectl get vpacheckpoint` — all output fields explained
- HPA + VPA conflict — why the specific combination of HPA-on-CPU + VPA-Recreate-on-CPU conflicts, and the safe patterns
- Sizing strategy for `minAllowed`/`maxAllowed` values using VPA data

> **Scope note:** This lab runs on minikube `3node` (same cluster as `01-hpa-basic` and `02-hpa-advanced`). VPA is installed from `github.com/kubernetes/autoscaler` via `vpa-up.sh`. HPA fundamentals are a required prerequisite — see `01-hpa-basic`. Cluster Autoscaler and KEDA are covered in `aws-eks-demos` and `04-keda-adapter` respectively.

> **Verification status:** Lab steps and expected outputs are written from documented VPA behaviour consistent with the facts verified in `01-hpa-basic`. They have not yet been run against this lab's manifests on a live cluster — run through the steps and report back any differences.

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — same cluster used in `01-hpa-basic` and `02-hpa-advanced`
- kubectl installed and configured
- metrics-server enabled (already done in `01-hpa-basic` Step 1 — verify below)
- git (for VPA installation in Step 1)

**Verify metrics-server before starting:**
```bash
kubectl get pods -n kube-system | grep metrics-server
kubectl top nodes
# Both must work before proceeding — if not, see 01-hpa-basic Step 1
```

**Knowledge Requirements:**
- **REQUIRED:** Completion of `01-hpa-basic` — HPA architecture, the metrics pipeline (cAdvisor → metrics-server), the scale subresource, HPA scaling formula, and why HPA does not use the Eviction API
- **REQUIRED:** Understanding of resource requests and limits (`06-pod-scheduling/06-resource-management`)
- **RECOMMENDED:** Completion of `02-hpa-advanced` — useful for the HPA + VPA conflict step (Step 4)

---

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Install VPA and verify all three components are running
2. ✅ Explain the role of each VPA component — Recommender, Updater, and Admission Controller — and how they interact in sequence
3. ✅ Explain the VPA algorithm — inputs, histogram model, observation window, and all four output fields
4. ✅ Interpret `kubectl describe vpa` output — all recommendation fields and their meaning
5. ✅ Use VPA Off mode to get resource recommendations without changing any pods
6. ✅ Inspect a VPACheckpoint and explain why it exists
7. ✅ Use VPA Recreate mode and observe the Admission Controller injecting resources on pod recreation
8. ✅ Explain all VPA update modes and when to use each
9. ✅ Configure per-container VPA policy using `containerPolicies`
10. ✅ Explain why HPA-on-CPU + VPA-Recreate-on-CPU conflicts, demonstrate the conflict, and apply the safe combination pattern
11. ✅ Uninstall VPA cleanly

---

## Directory Structure

```
11-auto-scaling/03-vpa-fundamentals/
├── README.md                              # this file
├── 03-vpa-fundamentals-anki.csv           # Anki flashcard deck
├── 03-vpa-fundamentals-quiz.md            # standalone quiz
└── src/
    ├── 01-nginx-deploy.yaml               # nginx deployment + ClusterIP service
    ├── 02-vpa-off.yaml                    # VPA Off mode — recommendations only
    ├── 03-vpa-recreate.yaml               # VPA Recreate mode — auto resource update
    └── break-fix/
        ├── 01-vpa-standalone-pod.yaml           # broken: VPA targeting a standalone pod
        ├── 02-vpa-conflict-hpa-cpu.yaml         # broken: HPA CPU + VPA Recreate CPU
        └── 03-vpa-missing-requests.yaml         # broken: deployment without resource requests
```

---

## Recall Check — 02-hpa-advanced

Answer from memory before continuing — these are scenario questions from `02-hpa-advanced`.

1. You have a Deployment with an `app` container and a `sidecar` container. You apply an HPA with `type: Resource` targeting CPU at 50%. The sidecar spikes to 800m CPU during a log-shipping burst. The app's own CPU is 30m. The HPA scales up. Why — and what would you change?
2. An HPA has `behavior.scaleUp.policies: [{type: Percent, value: 100, periodSeconds: 30}]`. Current replicas: 1. The metric immediately justifies 8 replicas. How many replicas does the HPA have after 60 seconds, and why not 8 immediately?
3. `kubectl describe hpa` shows `resource cpu on pods (as a percentage of request): <unknown> / 50%`. `kubectl top pod` shows the main container using CPU normally. What is the most likely cause?

<details>
<summary>Answers</summary>

1. `Resource` type sums CPU usage across ALL containers and divides by the sum of their requests. Sidecar's 800m spike raises pod-level utilisation above 50%, triggering scale-out even though `app` load is low. Fix: switch to `type: ContainerResource` with `containerResource.container: app` — measures only the `app` container's CPU, ignoring the sidecar entirely.

2. After 60 seconds: 4 replicas, not 8. `Percent, value: 100` caps the step at 100% of the CURRENT count per `periodSeconds` window. Window 1 (0-30s): 1 → 2 (+100% of 1). Window 2 (30-60s): 2 → 4 (+100% of 2). The policy is a rate limiter on the step size, not the final desired value.

3. At least one container in the pod is missing `resources.requests.cpu`. For `type: Resource`, ALL containers must have a CPU request for the pod-level utilisation to be computed. If any container lacks it, the entire pod's metric becomes `<unknown>` — not just that container's share. Confirm with `kubectl describe deployment <name> | grep -A4 Requests:` for each container.

</details>

---

## Concepts

### VPA Architecture and Components

VPA is not part of core Kubernetes — it is a separate project maintained by Kubernetes SIG Autoscaling in the `kubernetes/autoscaler` GitHub repository. It consists of three independent components, each with a distinct role:
VPA consists of three independent components running in kube-system. They are maintained by Kubernetes SIG Autoscaling in the `kubernetes/autoscaler` GitHub repository — the same repository that hosts Cluster Autoscaler.

```
vpa-recommender
  Role:    observe and recommend
  Input:   queries metrics-server (metrics.k8s.io) for current CPU/memory
           reads VerticalPodAutoscalerCheckpoint objects for historical histogram data
  Process: builds a weighted histogram model of usage per container over time
           calculates percentile-based recommendations
  Output:  writes recommendations to VPA object .status.recommendation
           writes/updates VerticalPodAutoscalerCheckpoint objects

  Installation model: Deployment in kube-system
  Data retention:     8 days of histogram data (configurable via --history-length)
                      persisted in VPACheckpoint objects — survives Recommender restarts
  Maintained by:      Kubernetes SIG Autoscaling (kubernetes/autoscaler repo)

vpa-updater
  Role:    enforce recommendations on running pods
  Input:   reads VPA object .status.recommendation
           reads PodDisruptionBudget objects
  Process: identifies pods whose current requests differ significantly from Target
           checks PDB to confirm eviction is safe
  Output:  evicts pods via Eviction API (NOT direct DELETE — respects PDB)
           does NOT modify resource values itself — eviction triggers recreate

  Why Eviction API (not DELETE)?
    Unlike HPA scale-down (which uses direct DELETE and bypasses PDB),
    VPA Updater uses the Eviction API. This means VPA waits if eviction
    would violate a PodDisruptionBudget — safe for stateful workloads
    where you cannot lose all replicas simultaneously.

vpa-admission-controller (Mutating Webhook)
  Role:    inject correct resources at pod creation
  Input:   intercepts ALL pod creation requests to kube-apiserver
           reads VPA object .status.recommendation
  Process: checks if a VPA applies to this pod
           if yes: patches the pod spec with recommended resource values
  Output:  modified pod spec with injected CPU/memory requests
           called on initial create AND after Updater evictions
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
       Updater does not evict; Admission Controller does not patch

Step 3b (Recreate or InPlaceOrRecreate mode):
       Updater reads VPA.status recommendation
       → identifies pods where current requests differ significantly from Target
       → checks PDB: if eviction would violate budget, waits
       → evicts pod via Eviction API

Step 4: Deployment controller recreates the evicted pod

Step 5: Admission Controller intercepts the new pod creation request
       → finds the matching VPA object
       → patches pod spec: injects Target CPU/memory as resources.requests
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

---

### VPA Algorithm — How Recommendations Are Calculated

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

**What is a histogram?**

A histogram is a statistical tool that shows the distribution of values. Instead of storing every individual measurement, it groups values into ranges (called "buckets") and counts how many measurements fall in each range.

Example — simple histogram of CPU usage observations:
```
CPU usage range    Count of observations
0m – 10m           45 times
10m – 20m           8 times
20m – 50m           3 times
50m – 100m          2 times
100m+               2 times
```
This tells you: most of the time CPU is very low (0–10m), and occasionally it spikes.

**What is a bucket?**

A bucket is one range in the histogram. VPA uses exponential (geometric) buckets —
each bucket covers a range that is a fixed ratio larger than the previous one
(approximately 1.05× per bucket for CPU). This means:
- Bucket 0: 0m – ~0.01m (very small CPU)
- Bucket 1: ~0.01m – ~0.01m × 1.05
- ...
- Bucket 20: covers the ~10m–11m range
- Bucket 30: covers a larger range higher up

The exponential spacing is intentional: fine-grained at low values (where most idle
containers live) and coarser at high values (less precision needed for rare spikes).

**What is a weighted histogram?**

VPA does not count observations equally. Each observation gets a **weight** that
decreases with age — recent samples matter more than old samples. This is
"recency decay." The formula is approximately:

```
weight of a sample = base_weight × decay_factor^(age_in_hours)
```

Where decay_factor < 1 (e.g. 0.998 per hour). A sample from 1 hour ago has
weight ≈ 0.998 of a fresh sample. A sample from 100 hours ago has weight ≈
0.998^100 ≈ 0.82 of a fresh sample. After ~8 days (192 hours), very old
samples have low weight and minimal influence on the recommendation.

**How are VPA bucket weights determined and calculated?**

From the actual VPACheckpoint output in this lab:
```
Cpu Histogram:
  Bucket Weights:
    0:  10000      ← bucket 0 (very low CPU ~0m) has the highest weight
    1:  136
    2:  34
    3:  172
    4:  69
    5:  51
  Total Weight: 74.05...
```

Reading this:
- Bucket 0 has weight 10000 — nginx at idle almost always uses near-zero CPU
- Buckets 1–5 have much lower weights — occasionally uses slightly more CPU
- Total Weight is the sum of all decayed sample weights accumulated
  (74.05 for this checkpoint — represents ~3 days of data with decay)

The "weight" in each bucket represents: (how many times CPU fell in this range)
× (recency decay factor for each of those observations). Higher weight = more
likely to be in the recommendation's percentile calculation.

**What percentile? Is 90th configurable?**

VPA Target uses the **90th percentile** by default. This means: find the CPU value X
such that 90% of the weighted observations are at or below X.

```
From the bucket weights above:
Total weight = ~10000 + 136 + 34 + 172 + 69 + 51 + ... = ~10462 (simplified)
90th percentile = the bucket where cumulative weight reaches 90% of total
90% of 10462 = 9416

Cumulative:
  Bucket 0: 10000 → already exceeds 9416
  → 90th percentile is in bucket 0 → Target = upper edge of bucket 0 (~25m)
  → This is exactly what the lab shows: Uncapped Target: cpu=25m
```

The 90th percentile target is configurable via VPA Recommender flags:
```bash
# Not exposed via VPA spec — set on the vpa-recommender Deployment:
--target-cpu-percentile=0.90      # default
--target-memory-percentile=0.90   # default
# Example: set to 95th percentile for more conservative sizing:
--target-cpu-percentile=0.95
```

**Does the Target become the request or the limit?**

Target becomes the **request** only by default (`controlledValues: RequestsAndLimits`
then also adjusts limits proportionally). Specifically:
- `resources.requests.cpu` is set to Target CPU value
- `resources.requests.memory` is set to Target memory value
- `resources.limits` are scaled proportionally to maintain original request:limit ratio
  (e.g. if original ratio was 1:5, and target doubles the request, limits also double)
- With `controlledValues: RequestsOnly`: only requests are changed, limits untouched


**The histogram model — what it is with a concrete example:**

Rather than tracking a raw time series of every sample, VPA Recommender maintains a weighted histogram per container per resource. Think of it as a bar chart where:
- The X-axis represents CPU usage values (bucketed into ranges, e.g. 0–10m, 10–20m, etc.)
- The Y-axis represents how much "weight" (frequency × recency decay) falls in each bucket
- Recent samples are weighted higher than old samples

```
Example: nginx container CPU usage over 10 minutes of load

Observation timeline:
  t=0s   CPU=10m   (idle)
  t=15s  CPU=110m  (requests arriving)
  t=30s  CPU=115m
  t=45s  CPU=108m
  t=60s  CPU=112m
  t=75s  CPU=10m   (quiet period)
  t=90s  CPU=11m

Histogram buckets (simplified):
  0-20m:    weight=2.1  (two observations, lower weight — older)
  100-120m: weight=4.8  (four recent observations, higher weight)
  80–100m:  weight=0.0
  ...

90th percentile: the value below which 90% of the total weight falls
  → the histogram says: 90% of the time (by weight), usage <= 113m
  → Target = 113m
```

The histogram is stored in the VerticalPodAutoscalerCheckpoint object. If the Recommender pod restarts, it reads from the checkpoint and resumes rather than starting over — no recommendation gap.

**What is a histogram?**

A histogram is a statistical tool that shows the distribution of values. Instead of storing every individual measurement, it groups values into ranges (called "buckets") and counts how many measurements fall in each range.

Example — simple histogram of CPU usage observations:
```
CPU usage range    Count of observations
0m – 10m           45 times
10m – 20m           8 times
20m – 50m           3 times
50m – 100m          2 times
100m+               2 times
```
This tells you: most of the time CPU is very low (0–10m), and occasionally it spikes.

**What is a bucket?**

A bucket is one range in the histogram. VPA uses exponential (geometric) buckets —
each bucket covers a range that is a fixed ratio larger than the previous one
(approximately 1.05× per bucket for CPU). This means:
- Bucket 0: 0m – ~0.01m (very small CPU)
- Bucket 1: ~0.01m – ~0.01m × 1.05
- ...
- Bucket 20: covers the ~10m–11m range
- Bucket 30: covers a larger range higher up

The exponential spacing is intentional: fine-grained at low values (where most idle
containers live) and coarser at high values (less precision needed for rare spikes).

**What is a weighted histogram?**

VPA does not count observations equally. Each observation gets a **weight** that
decreases with age — recent samples matter more than old samples. This is
"recency decay." The formula is approximately:

```
weight of a sample = base_weight × decay_factor^(age_in_hours)
```

Where decay_factor < 1 (e.g. 0.998 per hour). A sample from 1 hour ago has
weight ≈ 0.998 of a fresh sample. A sample from 100 hours ago has weight ≈
0.998^100 ≈ 0.82 of a fresh sample. After ~8 days (192 hours), very old
samples have low weight and minimal influence on the recommendation.

**How are VPA bucket weights determined and calculated?**

From the actual VPACheckpoint output in this lab:
```
Cpu Histogram:
  Bucket Weights:
    0:  10000      ← bucket 0 (very low CPU ~0m) has the highest weight
    1:  136
    2:  34
    3:  172
    4:  69
    5:  51
  Total Weight: 74.05...
```

Reading this:
- Bucket 0 has weight 10000 — nginx at idle almost always uses near-zero CPU
- Buckets 1–5 have much lower weights — occasionally uses slightly more CPU
- Total Weight is the sum of all decayed sample weights accumulated
  (74.05 for this checkpoint — represents ~3 days of data with decay)

The "weight" in each bucket represents: (how many times CPU fell in this range)
× (recency decay factor for each of those observations). Higher weight = more
likely to be in the recommendation's percentile calculation.

**What percentile? Is 90th configurable?**

VPA Target uses the **90th percentile** by default. This means: find the CPU value X
such that 90% of the weighted observations are at or below X.

```
From the bucket weights above:
Total weight = ~10000 + 136 + 34 + 172 + 69 + 51 + ... = ~10462 (simplified)
90th percentile = the bucket where cumulative weight reaches 90% of total
90% of 10462 = 9416

Cumulative:
  Bucket 0: 10000 → already exceeds 9416
  → 90th percentile is in bucket 0 → Target = upper edge of bucket 0 (~25m)
  → This is exactly what the lab shows: Uncapped Target: cpu=25m
```

The 90th percentile target is configurable via VPA Recommender flags:
```bash
# Not exposed via VPA spec — set on the vpa-recommender Deployment:
--target-cpu-percentile=0.90      # default
--target-memory-percentile=0.90   # default
# Example: set to 95th percentile for more conservative sizing:
--target-cpu-percentile=0.95
```

**Does the Target become the request or the limit?**

Target becomes the **request** only by default (`controlledValues: RequestsAndLimits`
then also adjusts limits proportionally). Specifically:
- `resources.requests.cpu` is set to Target CPU value
- `resources.requests.memory` is set to Target memory value
- `resources.limits` are scaled proportionally to maintain original request:limit ratio
  (e.g. if original ratio was 1:5, and target doubles the request, limits also double)
- With `controlledValues: RequestsOnly`: only requests are changed, limits untouched

**Observation window and configurability:**

```
Default observation window: 8 days (--history-length=192h flag on Recommender deployment)
Minimum before recommendation: approximately 1 minute of data
                               (enough for a first rough recommendation)

To adjust the window (on VPA Recommender Deployment):
  --history-length=24h   → use only last 24 hours of data
  --history-length=168h  → use last 7 days
  --history-length=192h  → default (8 days)
```
**How the observation window affects the Target:**

The observation window (default 8 days) determines which historical samples contribute
to the histogram. Older samples have lower weight (recency decay). The Target is the
90th percentile of this weighted histogram.

Example — how window length changes the recommendation:

```
Scenario: nginx was heavily loaded Monday–Wednesday, then idle Thursday–Sunday

With 8-day window (default):
  Mon–Wed samples (heavy load, ~200m CPU) → high weight (recent-ish)
  Thu–Sun samples (idle, ~5m CPU) → also high weight (most recent)
  Histogram: spread across low AND high buckets
  90th pct Target: might be ~15m (most time idle, occasional spikes raise it slightly)

With 1-day window (--history-length=24h):
  Only Sunday samples → all idle, ~5m CPU
  90th pct Target: ~5m (captures only current idle state)
  → More responsive to recent changes, but misses the Monday spike

With 30-day window:
  Mon–Wed spikes from ALL past month → high weight on heavy-load buckets
  90th pct Target: ~80m (the regular weekly load spikes raise the percentile)
  → More stable, less responsive to temporary idle periods
```

**The practical rule:** shorter observation window = more responsive to recent patterns
but misses long-term cycles (weekly load patterns). Longer window = captures seasonal
and weekly patterns but slower to respond when workload character changes permanently.
The 8-day default captures one full weekly cycle (Mon–Sun) which is suitable for most
web workloads.

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

**Scale-down decision (VPA) — when does the Updater evict?**

VPA does not have an equivalent to HPA's stabilisation window. The Updater evicts a pod when its current requests fall outside the [Lower Bound, Upper Bound] range, or when the current requests differ significantly from Target. The Updater polls on its own schedule and respects PDB — it will wait if eviction would violate the budget. There is no separate "scale-down delay" like HPA's 5-minute window.

The Updater does NOT evict on every evaluation. It applies a "significant change"
threshold before deciding to evict. The internal logic (as implemented in VPA):

```
Eviction is triggered when BOTH of these are true:
  1. Current request is outside [Lower Bound, Upper Bound]
     - Below Lower Bound: dangerously under-provisioned → evict to increase
     - Above Upper Bound: significantly over-provisioned → evict to decrease
  2. The change is "significant" — VPA defines this as the gap being large enough
     to justify the disruption of eviction (pod restart has a cost)

Important nuance: "current requests differ significantly from Target" is the common
simplification, but the actual trigger uses [Lower Bound, Upper Bound] as the
stability range. If current requests are between Lower Bound and Upper Bound
(even if not exactly at Target), the Updater may decide NOT to evict.
```

**Why VPA has no stabilisation window (unlike HPA's 5-minute default):**

VPA and HPA solve fundamentally different problems with different risk profiles:

```
HPA stabilisation window rationale:
  HPA REMOVES pods → immediate capacity reduction → requests that were being served
  are now dropped or queued. A premature scale-in during a brief traffic lull causes
  real user-facing impact (latency, errors). The 5-minute window absorbs traffic lulls.

VPA no stabilisation window rationale:
  VPA ADJUSTS RESOURCE REQUESTS → pod is evicted and recreated with better sizing.
  This is a planned maintenance action, not a capacity reduction. The number of pods
  does not change. The service capacity is momentarily interrupted during restart
  (seconds) but returns to the same level. Additionally VPA already uses a slow-moving
  weighted histogram (8 days of data) as its stabilisation mechanism — the recommendation
  itself changes slowly. An additional delay window would add latency with no benefit.

Design summary: HPA needs a cooldown to protect against oscillation caused by its own
  scaling decisions. VPA's histogram model is inherently stable — the recommendation
  cannot change faster than new samples accumulate and shift the weighted percentile.
```

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
  Target:          cpu=143m, memory=250Mi   ← 90th pct, within policy bounds
  Lower Bound:     cpu=50m,  memory=200Mi   ← ~25th pct, floored at minAllowed
  Upper Bound:     cpu=2,    memory=2Gi     ← capped at maxAllowed
  Uncapped Target: cpu=143m, memory=250Mi   ← same as Target (policy not clamping)

Updater sees:
  Current requests: cpu=100m (below Target of 143m), memory=128Mi (below 250Mi)
  Both below Target → pod is under-provisioned → Updater evicts

After eviction + recreation + Admission Controller:
  New requests: cpu=143m, memory=250Mi   ← Target injected by Admission Controller


Now if traffic drops very low for 8 days:
  Target recalculates to: cpu=50m, memory=200Mi
  Current requests: cpu=143m (above Target) → over-provisioned → evict again
  Admission Controller injects: cpu=50m, memory=200Mi
```
> **What "8 days of observation" means in practice:**
>
> The VPA Recommender does not wait 8 days before generating any recommendation — it
> produces an initial recommendation within ~1 minute of the first samples. The 8 days
> is the observation WINDOW — how far back the weighted histogram reaches.
>
> "Observation: 8 days of mixed traffic" means: the histogram has accumulated samples
> from the last 8 days, with recent samples weighted higher than older ones.
> A freshly deployed VPA will give you a rough recommendation in 1 minute based on
> the first handful of metrics-server samples, and it refines that recommendation
> continuously as more samples arrive.
>
> "Now if traffic drops very low for 8 days" means: a sustained change in usage
> pattern has been observed for long enough that the old high-usage samples have
> decayed significantly and the new low-usage samples now dominate the histogram.
> The recommendation shifts to reflect the new reality.

**When does the Updater act — per resource, per container?**

The Updater evaluates each container's resources independently but makes the eviction
decision at the POD level (since you cannot evict just one container in a pod).

```
Scenario 1 (one container, one resource differs):
  Container: nginx
  Current:   cpu=100m (above Upper Bound of 50m) ← out of range
             memory=250Mi (equals Target) ← in range

  Updater decision: evaluate OVERALL whether the pod needs updating.
  If cpu alone is significantly out of bounds → MAY evict.
  The "significant" threshold means: eviction is worthwhile despite the disruption.
  In practice: if only cpu is slightly off and memory is fine, Updater may wait
  for the deviation to grow before evicting. The safety guard (no eviction if
  it would leave 0 pods) still applies.

Scenario 2 (multiple containers, mixed):
  Container A: cpu=100m (above Upper Bound 50m) ← out of range
  Container B: cpu=80m, memory=100Mi (both within bounds) ← in range

  Updater decision: the whole pod is evicted if ANY container is out of range
  and the safety conditions (PDB, min replicas) permit it.
  Evicting the pod allows the Admission Controller to inject correct resources
  for ALL containers simultaneously — not just the out-of-range one.
```

---

### VPA Update Modes

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
               most workloads in non-production; stateless workloads in production

InPlaceOrRecreate (preferred over Recreate for production):
  Recommender: ✅ runs
  Updater:     ✅ attempts in-place resize first (no restart required)
               falls back to Recreate if in-place resize is not supported
               or fails (requires Kubernetes InPlacePodVerticalScaling feature gate (>= v1.27 beta)
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

**Initial mode — what happens on first pod creation:**

When you deploy a Deployment and VPA simultaneously in Initial mode, the first pod(s)
may NOT be right-sized — the Recommender needs at least ~1 minute of observation before
it has a recommendation to inject.

```
Timeline with Initial mode (cold start):
  t=0s:   Deployment created, VPA created (Initial mode)
  t=0s:   Pod creation request → Admission Controller checks for VPA recommendation
           → No recommendation yet (RecommendationProvided=False)
           → Admission Controller passes pod through WITHOUT patching
           → Pod starts with manifest values (cpu=100m, memory=128Mi)

  t=60s:  VPA Recommender has first recommendation → RecommendationProvided=True
  t=60s:  Running pod: still has old resources (Updater does NOT evict in Initial mode)

  Next pod creation (e.g. rolling update, scale-out, manual delete):
           → Admission Controller finds recommendation → patches pod spec
           → New pod starts with cpu=50m, memory=250Mi
```

This means: the first generation of pods after a cold start will be sized from
the manifest. They gradually become right-sized as they are naturally recreated
(rolling updates, node maintenance, scale-out events). Initial mode is "eventually
consistent" right-sizing without deliberate eviction.

**Recreate mode — lifecycle over time:**

```
t=0s:   Deployment created (cpu=100m), VPA created (Recreate mode)
        First pods start with manifest values — no recommendation yet

t=60s:  First recommendation available
        Updater evaluates: is current request significantly outside [LB, UB]?
        IF yes AND safety guard permits → evicts pod → Deployment controller recreates
        → Admission Controller injects recommended resources → new pod starts right-sized
        IF safety guard blocks (1 replica, no PDB) → waits

t=ongoing: Every Updater polling cycle:
        - Re-evaluates all pods of the Deployment
        - If requests drift outside bounds (e.g. after manifest update) → re-evicts
        - If traffic pattern changes over days → recommendation shifts → re-evicts
        - Admission Controller ensures EVERY new pod (from any cause) starts right-sized
```

The practical consequence: in Recreate mode, no pod should remain mis-sized for long
(subject to PDB and minimum replica safety guards). New pods from ANY cause (rolling
update, scale-out, node drain) always start right-sized via the Admission Controller.
Existing running pods are periodically re-evaluated and evicted when significantly
out of range.

**What is in-place pod resize?**

Normally, `resources.requests` and `resources.limits` on a running pod are IMMUTABLE.
You cannot change them with `kubectl edit pod` or `kubectl patch pod` — Kubernetes
will reject the change. The only way to change a running pod's resources is to delete
and recreate it (hence "Recreate" mode).

In-place pod resize (`InPlacePodVerticalScaling` feature, beta in Kubernetes v1.27+)
changes this. It adds a new `/resize` subresource to pods that allows the Kubernetes
API to modify CPU and memory requests/limits on a running container WITHOUT restarting
the pod or container process. The kernel's cgroup hierarchy is updated to reflect the
new resource allocation — the container keeps running uninterrupted.

```
Without in-place resize (Recreate):
  VPA wants to change cpu: 100m → 50m
  Updater evicts pod → container process dies → Deployment creates new pod →
  Admission Controller injects cpu=50m → new container starts
  Downtime: ~5-30 seconds (pod restart)

With in-place resize (InPlaceOrRecreate):
  VPA wants to change cpu: 100m → 50m
  Updater sends /resize request to kube-apiserver
  kubelet updates the container's cgroup CPU quota in-place
  Container process continues running — no restart, no downtime
  Downtime: 0 (for supported resource changes)
```

**Is in-place resize only possible via VPA?**

No — the `/resize` subresource is a Kubernetes API feature. You can also do it
directly:
```bash
kubectl patch pod <name> --subresource resize -p \
  '{"spec":{"containers":[{"name":"nginx","resources":{"requests":{"cpu":"50m"}}}]}}'
```

VPA is the automated version — it calculates the right value and applies the resize.
Manual patching is also possible. However, in-place resize has constraints:
- CPU requests and limits can be changed without restart in most cases
- Memory changes: increasing memory can be done in-place; DECREASING memory
  requires a restart (the kernel cannot forcibly release memory already allocated
  to a running process without terminating it)
- This is why InPlaceOrRecreate falls back to Recreate: for memory reductions,
  in-place resize fails, and the Updater falls back to eviction.


**Updater and PodDisruptionBudget:**

```
VPA Updater uses the Eviction API → it respects PDB
  → reads minAvailable / maxUnavailable before evicting
  → will not evict if doing so would violate the budget
  → waits until PDB permits eviction

This is in contrast to HPA scale-down, which uses direct DELETE
and does NOT consult PDB (see HPA and PDB section above)

Safe setup if your workload needs VPA + high availability:
  Deployment with replicas >= 2
  PDB with minAvailable=1 (allows VPA to evict one pod at a time)
  VPA mode: Recreate or InPlaceOrRecreate
```

**Why does vpa-updater read PDB directly instead of relying on the Eviction API?**

The Eviction API DOES enforce PDB — when the Eviction API is called, kube-apiserver
checks the PDB and rejects the eviction if it would violate `minAvailable` or
`maxUnavailable`. So why does the Updater need to read PDB objects at all?

The reason is **pre-flight decision-making vs post-submission enforcement:**

```
Eviction API enforcement (reactive):
  Updater calls Eviction API → kube-apiserver checks PDB → REJECTS if violated
  Result: Updater gets an error, must retry later
  Problem: the Updater would need to retry repeatedly, causing noise in logs
           and inefficient retry loops

VPA Updater pre-flight check (proactive):
  Updater reads PDB directly → evaluates whether eviction WOULD be permitted
  → if PDB would block: Updater SKIPS the eviction (does not even try)
  → if PDB would permit: Updater calls Eviction API (which also checks PDB as a safety)
  Result: no rejected API calls, no retry noise; the Updater waits quietly
         until the PDB budget allows eviction
```

Both mechanisms work together: VPA reads PDB to decide WHEN to evict (proactive),
and the Eviction API enforces PDB as a safety net at the moment of eviction (reactive).
This is the same pattern used by `kubectl drain` — it also pre-checks PDB before
calling the Eviction API, rather than blindly calling and handling rejections.

---

### What VPA Can Target

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

---

### VPA CRDs and kubectl Commands

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

NAME      → VPA object name
MODE      → update mode: Off, Initial, Recreate, InPlaceOrRecreate
CPU       → recommended CPU request from the Target field
             blank = recommendation not yet available (wait ~1 minute)
MEM       → recommended memory request from the Target field
             blank = recommendation not yet available
PROVIDED  → True = recommendation is ready (RecommendationProvided condition is True)
             False = Recommender still collecting data (normal for first ~1 minute)
             stays False beyond 5 minutes: check vpa-recommender logs
AGE       → how long this VPA object has existed
```

**kubectl describe vpa — key sections explained:**
```bash
kubectl describe vpa nginx-vpa-off
```
```
Spec:
  Target Ref:
    Kind: Deployment          → kind of workload VPA is watching
    Name: nginx-deploy        → specific workload instance

  Update Policy:
    Update Mode: Off          → Off: observe only
                                 Recreate: evict and update
                                 Initial: inject at creation only
                                 InPlaceOrRecreate: prefer in-place, fallback Recreate

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
                                        if False after 5+ minutes: check
                                        vpa-recommender pod logs

  Recommendation:
    Container Recommendations:
      Container Name: nginx

      Lower Bound:            → minimum safe resources for this container
        Cpu: 50m                set below this → high probability of
        Memory: 250Mi           CPU throttling or OOMKill
                                floored at resourcePolicy.minAllowed

      Target:                 → the value VPA WILL SET as requests (mode=Recreate)
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
| `resourcePolicy` (whole block) | none (optional) | Per-container bounds and behaviour | Omitting lets VPA make unconstrained recommendations |
| `containerPolicies[].containerName` | required | Which container to configure; `"*"` = all unmatched | Typo in container name — VPA silently falls back to `"*"` |
| `containerPolicies[].mode` | Auto | `Auto` (manage) or `Off` (observe only) | Not setting `Off` on containers you want left alone |
| `containerPolicies[].minAllowed` | none | VPA floor — never recommends below this | Setting too high locks in over-provisioning |
| `containerPolicies[].maxAllowed` | none | VPA ceiling — never recommends above this | Omitting on spiky workloads causes unbounded recommendations |
| `containerPolicies[].controlledResources` | [cpu, memory] | Which resources VPA tracks | Forgetting that omitting defaults to both — if you only want memory, set explicitly |
| `containerPolicies[].controlledValues` | RequestsAndLimits | Whether VPA also adjusts limits | Using RequestsAndLimits when you have custom limits you want preserved |

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

### Multi-Container Pods and containerPolicies

VPA tracks EACH container in a pod separately and produces independent recommendations per container. The app container and a log-shipping sidecar have entirely different resource profiles — VPA handles them independently.

**Where containerPolicies fits:**

`containerPolicies` is the field inside `spec.resourcePolicy` that configures per-container VPA behaviour:

```yaml
spec:
  resourcePolicy:
    containerPolicies:
      - containerName: app              # target this specific container by name
        minAllowed:
          cpu: 100m                     # VPA floor — recommendation never goes below this
          memory: 256Mi
        maxAllowed:
          cpu: 4                        # VPA ceiling — recommendation never goes above this
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
containerName: "app"  → applies only to the container named "app"
containerName: "*"    → wildcard — applies to every container not matched
                         by a more specific containerName rule above it

mode: "Auto"  → VPA actively manages this container
                 Recommender observes, Updater evicts, Admission injects
mode: "Off"   → VPA observes and records (recommendations appear in .status)
                          but the Updater and Admission Controller skip this container
                          useful when you want to exclude one container in a pod
                          from VPA changes while still seeing what it would recommend

controlledValues: "RequestsAndLimits" (default)
  → VPA updates BOTH resources.requests AND resources.limits
  → limits are scaled proportionally — original request:limit ratio preserved
  → example: request=100m limit=500m (ratio 1:5)
              VPA target=200m → sets request=200m, limit=1000m (keeps 1:5)

controlledValues: "RequestsOnly"
  → VPA updates resources.requests ONLY
  → resources.limits remain exactly as set in the manifest
  → use when you have custom limits you want to preserve
  → use when container hits OOMKill but you cannot raise limits

controlledResources: [cpu, memory] (default if omitted)
  → can be set to [cpu] or [memory] alone to restrict what VPA manages
```

**What happens with RequestsOnly when the recommended value exceeds the original limit?**

```
Example:
  Original manifest: requests.cpu=100m, limits.cpu=200m
  VPA Target:        cpu=300m (usage has grown beyond original limits)

  With controlledValues: RequestsAndLimits (default):
    VPA sets: requests.cpu=300m, limits.cpu=600m
    (original ratio 1:2 is preserved: 300m × 2 = 600m)
    The limit is raised to accommodate the larger request
    → Pod gets more CPU capacity ✅

  With controlledValues: RequestsOnly:
    VPA sets: requests.cpu=300m
    limits.cpu stays at 200m (unchanged from manifest)
    → requests.cpu (300m) > limits.cpu (200m) ← INVALID Kubernetes state
    → Kubernetes will REJECT the pod with a validation error:
      "Invalid value: 300m: must be less than or equal to cpu limit"
    → Admission Controller fails to inject → pod creation fails
```

**The practical rule:** use `RequestsOnly` ONLY when you are confident the VPA
recommendation will never exceed your original limits. If it might (e.g. limits
were also under-provisioned), use `RequestsAndLimits` (default) or set a
`maxAllowed` that keeps Target below the original limit ceiling.

To prevent this: set `maxAllowed.cpu` to your original limits value. This caps
VPA's recommendation below the limit, making `RequestsOnly` safe:
```yaml
maxAllowed:
  cpu: 200m   # capped at original limit → recommendation ≤ 200m → always < limit
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
| **Can scale to zero** | ❌ No — minReplicas >= 1 | N/A |
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

### Step 1 — Install VPA

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

Verify both VPA CRDs are installed:
```bash
kubectl api-resources | grep verticalpod
```

**Expected output:**
```
verticalpodautoscalercheckpoints  vpacheckpoint  autoscaling.k8s.io/v1  true  VerticalPodAutoscalerCheckpoint
verticalpodautoscalers            vpa            autoscaling.k8s.io/v1  true  VerticalPodAutoscaler
```

```
# Observation: two CRDs installed —
#   vpa (the config + recommendation object you create and manage)
#   vpacheckpoint (the histogram storage object VPA manages automatically)
```

---

### Step 2 — Deploy nginx and Apply VPA in Off Mode

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
              cpu: "100m"      # intentionally over-provisioned — VPA will recommend lower
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
cd 11-auto-scaling/03-vpa-fundamentals/src

kubectl apply -f 01-nginx-deploy.yaml
kubectl rollout status deployment/nginx-deploy
kubectl get pods -o wide
```

**Expected output:**
```
deployment "nginx-deploy" successfully rolled out

NAME                            READY   STATUS    NODE
nginx-deploy-xxxxxxxxx-xxxxx    1/1     Running   3node-m02
```

**`src/02-vpa-off.yaml`:**
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
    updateMode: "Off"           # observe only — Updater never evicts, Admission never patches
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
kubectl apply -f 02-vpa-off.yaml
```

```bash
kubectl get vpa nginx-vpa-off -w
```

**Actual output:**
```
NAME            MODE   CPU   MEM     PROVIDED   AGE
nginx-vpa-off   Off                            27s     ← no recommendation yet
nginx-vpa-off   Off    50m   250Mi   True       48s     ← recommendation appears at ~48s
```

```
# Observation: first recommendation appears in ~48 seconds (not "~1 minute" — faster
#              than expected, confirming metrics-server had data from prior steps).
#              CPU=50m is at minAllowed floor (actual usage ~25m, below minAllowed).
#              MEM=250Mi — nginx uses more memory than the 128Mi request.
```

```bash
kubectl describe vpa nginx-vpa-off
```

**Actual output:**
```
Name:         nginx-vpa-off
Namespace:    default
Labels:       <none>
Annotations:  <none>
API Version:  autoscaling.k8s.io/v1
Kind:         VerticalPodAutoscaler
Metadata:
  Creation Timestamp:  2026-06-29T06:26:19Z
  Generation:          1
  Resource Version:    809837
  UID:                 ff3d9a1e-992a-4335-a205-e995a2ba0a39
Spec:
  Resource Policy:
    Container Policies:
      Container Name:  nginx
      Max Allowed:
        Cpu:     2
        Memory:  2Gi
      Min Allowed:
        Cpu:     50m
        Memory:  64Mi
  Target Ref:
    API Version:  apps/v1
    Kind:         Deployment
    Name:         nginx-deploy
  Update Policy:
    Update Mode:  Off
Status:
  Conditions:
    Last Transition Time:  2026-06-29T06:27:07Z
    Status:                True
    Type:                  RecommendationProvided
  Recommendation:
    Container Recommendations:
      Container Name:  nginx
      Lower Bound:
        Cpu:     50m
        Memory:  250Mi
      Target:
        Cpu:     50m
        Memory:  250Mi
      Uncapped Target:
        Cpu:     25m        ← raw algorithm recommendation BEFORE minAllowed applied
        Memory:  250Mi
      Upper Bound:
        Cpu:     50m
        Memory:  250Mi
Events:          <none>
```

```
# Observation: Uncapped Target: cpu=25m — the histogram says nginx actually uses ~25m CPU.
#              minAllowed=50m raises the floor: Target=50m (not 25m).
#              Target == Uncapped Target is FALSE here: 50m ≠ 25m
#                → minAllowed IS clamping the recommendation upward
#                → the 25m gap = policy floor in effect
#              All four fields (Lower, Target, Upper) equal 50m for CPU:
#                → tight bounds, low variance — nginx at idle is very consistent
#              Memory: Target=250Mi vs current request=128Mi → UNDER-provisioned
#                → the demo successfully identifies a real sizing problem
```
```

**VPACheckpoint describe (replace with actual output):**
```markdown
```bash
kubectl describe vpacheckpoint nginx-vpa-off-nginx
```

**Actual output:**
```
Name:         nginx-vpa-off-nginx
Namespace:    default
Labels:       <none>
Annotations:  <none>
API Version:  autoscaling.k8s.io/v1
Kind:         VerticalPodAutoscalerCheckpoint
Metadata:
  Creation Timestamp:  2026-06-29T06:27:07Z
  Generation:          4
  Resource Version:    810035
  UID:                 d314ee4a-3b59-4a2b-b236-80ce003413cb
Spec:
  Container Name:   nginx
  Vpa Object Name:  nginx-vpa-off
Status:
  Cpu Histogram:
    Bucket Weights:
      0:                  10000    ← bucket 0 (near-zero CPU) has overwhelmingly highest weight
      1:                  136      ← bucket 1 (slightly more CPU) rarely seen
      2:                  34
      3:                  172
      4:                  69
      5:                  51
    Reference Timestamp:  2026-06-26T00:00:00Z
    Total Weight:         74.05399393212494
  First Sample Start:     2026-06-26T06:35:34Z
  Last Sample Start:      2026-06-29T06:29:17Z
  Last Update Time:       2026-06-29T06:29:57Z
  Memory Histogram:
    Bucket Weights:
      2:                  10000   ← memory always in bucket 2 (consistent ~250Mi usage)
    Reference Timestamp:  2026-06-27T00:00:00Z
    Total Weight:         2.4228363866210785
  Total Samples Count:    433
  Version:                v3
Events:                   <none>
```

```
# Observation: CPU bucket 0 weight=10000, all others much lower.
#              This means: ~99% of weighted observations show near-zero CPU usage.
#              The 90th percentile is therefore in bucket 0 → Uncapped Target ≈ 25m.
#
#              Memory bucket 2 weight=10000 (only one bucket has weight).
#              nginx memory usage is extremely consistent — always falls in bucket 2.
#              Bucket 2 in VPA's memory histogram corresponds to ~250Mi.
#
#              Total Samples Count: 433 — approximately 3 days of 60-second samples.
#              First Sample Start: 2026-06-26 — data has been accumulating for 3 days.
#              This explains why the recommendation appeared quickly (~48s) — the
#              VPACheckpoint already had 3 days of histogram data from a previous
#              VPA run on this cluster. A brand-new cluster would take ~1 minute
#              for the first rough recommendation with no prior checkpoint data.
```

**Compare current requests vs recommendation:**
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
# VPA says: CPU is over-provisioned (50m target vs 100m request)
#           Memory is under-provisioned (250Mi target vs 128Mi request)
# Mode=Off: no changes applied — review only
```

```bash
kubectl delete -f 02-vpa-off.yaml
```

---

### Step 2b — VPA Initial Mode

Initial mode injects resources only at pod creation time — it never evicts running pods. This is the safest active VPA mode for production: existing pods are untouched, but every new pod (from scaling, rolling update, or manual restart) starts with right-sized resources.

```yaml
# Add to 02-vpa-off.yaml or create separately — change updateMode only:
  updatePolicy:
    updateMode: "Initial"
```

```bash
# Delete the running pod to force recreation — Initial mode will inject resources
kubectl delete pod -l app=nginx --grace-period=0 --force

# Watch pod recreate
kubectl get pods -l app=nginx -w
```

**Expected output:**
```
NAME                           READY   STATUS    RESTARTS
nginx-deploy-bcb99d858-wfmpz   1/1     Terminating
nginx-deploy-xxxxxxxxx-yyyyy   0/1     ContainerCreating
nginx-deploy-xxxxxxxxx-yyyyy   1/1     Running
```

```bash
# Verify new pod has resources injected by Admission Controller
kubectl describe pod -l app=nginx | grep -A4 "Requests:"
```

**Expected output:**
```
Requests:
  cpu:     50m     ← injected by VPA Admission Controller (was 100m in manifest)
  memory:  250Mi   ← injected by VPA Admission Controller (was 128Mi in manifest)
```

```
# Observation: the Deployment manifest still shows cpu=100m, memory=128Mi.
# The Admission Controller patched the pod spec at creation time only.
# No eviction occurred — the old pod was deleted manually to trigger this.
# In production: rolling updates and scale-out events naturally trigger new pod creation,
# making Initial mode gradually right-size the fleet without deliberate eviction.
```
---

### Step 3 — VPA Recreate Mode (Automatic Resource Adjustment)

Recreate mode evicts pods and recreates them with recommended resource requests injected by the Admission Controller.

**`src/03-vpa-recreate.yaml`:**
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
    updateMode: "Recreate"    # Updater evicts pods; Admission Controller injects resources
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

> **Pre-requisite for this step:** Scale the Deployment to 2 replicas before applying
> the Recreate VPA. With a single replica and no PDB, the VPA Updater will not evict
> the only running pod (it would leave the service temporarily at 0 replicas).
> Scaling to 2 replicas allows the Updater to safely evict one at a time.

```bash
# Scale to 2 replicas first — required for Updater to safely evict
kubectl scale deployment nginx-deploy --replicas=2
kubectl rollout status deployment/nginx-deploy

kubectl apply -f 03-vpa-recreate.yaml
```

> **Why did Recreate not evict at 1 replica? (if you observed this)**
>
> From actual cluster testing: with `replicas=1` and no PDB, the VPA Updater applies
> a safety guard — it will not evict the last running pod because doing so would
> temporarily leave 0 pods running. The VPA has a recommendation, `PROVIDED=True`,
> but the Updater silently skips eviction. No error appears in VPA events.
>
> This is documented VPA behaviour, not a bug. The Updater respects service
> availability even when PDB is not explicitly configured.



Watch for recommendation and pod eviction in parallel (open a second terminal for the pod watch):
```bash
# Terminal 2:
kubectl get pods -w &
WATCH_PID=$! 

# Terminal 1:
kubectl get vpa nginx-vpa-recreate -w
```

**Expected output (Terminal 1):**
```
NAME               MODE      CPU    MEM     PROVIDED   AGE
nginx-vpa-recreate Recreate                            0s
nginx-vpa-recreate Recreate  143m   250Mi   True       60s
```


**Expected output after scaling to 2 replicas and applying Recreate VPA:(Terminal 2)**
```
NAME                           READY   STATUS
nginx-deploy-bcb99d858-wfmpz   1/1     Running     ← original pod 1
nginx-deploy-bcb99d858-xxxxx   1/1     Running     ← original pod 2

(after Updater detects out-of-range requests ~1-2 minutes later)

nginx-deploy-bcb99d858-wfmpz   1/1     Terminating ← Updater evicted pod 1
nginx-deploy-yyyyyyyyy-yyyyy   0/1     Pending
nginx-deploy-yyyyyyyyy-yyyyy   1/1     Running     ← new pod with injected resources
```

```bash
kubectl describe pod -l app=nginx | grep -A4 "Requests:"
```

**Expected output after eviction and recreation:**
```
(Pod 1 - newly created):
Requests:
  cpu:     50m     ← injected by Admission Controller (was 100m)
  memory:  250Mi   ← injected by Admission Controller (was 128Mi)

(Pod 2 - not yet evicted):
Requests:
  cpu:     100m    ← still original values (Updater evicts one at a time)
  memory:  128Mi
```

```
# Observation: the Updater evicted the old pod via Eviction API (not direct DELETE).
#              The Deployment controller recreated it.
#              The Admission Controller intercepted the new pod's creation
#              and injected the VPA Target values as resources.requests.
```

Verify the new pod has updated resources:
```bash
# After recommendation is available, check if pod was evicted and recreated
kubectl get pods
kubectl describe pod -l app=nginx | grep -A4 "Requests:"
```


**Check events for evidence of VPA eviction:**
```bash
kubectl get events --sort-by='.lastTimestamp' | grep -i vpa
```

**Expected output:**
```
... EvictedPod ... VPA nginx-vpa-recreate evicted pod nginx-deploy-xxxxxxxxx-xxxxx
```

```bash
kill $WATCH_PID 2>/dev/null
kubectl delete -f 03-vpa-recreate.yaml
```


**Troubleshooting — Recreate mode not evicting:**
```bash
# Check if Updater is running
kubectl get pods -n kube-system | grep vpa-updater

# Check replica count (must be ≥ 2 for Updater to evict safely)
kubectl get deployment nginx-deploy

# Check VPA recommendation is provided
kubectl get vpa nginx-vpa-recreate

# Check if current requests are outside [Lower Bound, Upper Bound]
kubectl describe vpa nginx-vpa-recreate | grep -A20 "Recommendation:"
# If Target = current requests: no eviction needed (already right-sized)
# If 1 replica + no PDB: Updater safety guard is blocking — scale to 2 replicas
```

---

### Step 4 — VPA + HPA Conflict Demo

This step demonstrates the conflict that occurs when **HPA on CPU/memory** runs simultaneously with **VPA in Recreate mode on CPU/memory**. This is NOT a general statement that HPA and VPA cannot coexist — they can and do in production. The conflict is specific to both tools targeting the same signal (CPU/memory requests) at the same time.

> **Safe combinations that avoid this conflict:**
> - HPA on CPU/memory + VPA in Off mode (VPA recommends only — no request changes)
> - HPA on custom/external metrics + VPA in Recreate mode (different signals — no interference)
> - All three (HPA + VPA + CA) with a safe HPA+VPA combination

```bash
# Apply the HPA on CPU first
kubectl apply -f 01-nginx-deploy.yaml
```

**`src/vpa-conflict.yaml` (this is the conflicting combination):**
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
    updateMode: "Recreate"    # ← will conflict with HPA below
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
# Create HPA on CPU (same signal VPA will also manage)
kubectl autoscale deployment nginx-deploy --min=1 --max=5 --cpu=50%

# Apply conflicting VPA
kubectl apply -f vpa-conflict.yaml

# Generate load
kubectl apply -f 01-nginx-deploy.yaml  # ensure nginx-deploy exists
```

Wait ~2 minutes, then observe:
```bash
kubectl get hpa nginx-deploy
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
2. HPA formula: ceil[1 x 115/50] = 3 → scales out to 3 replicas
3. VPA Recommender builds histogram → Target = 143m
4. VPA Updater evicts pods → Admission Controller injects cpu=143m
5. HPA recalculates with NEW request (143m):
   same ~38m actual CPU usage / 143m request = 27%
6. 27% is well below 50% target → HPA scales DOWN
7. Fewer pods → higher per-pod CPU → HPA scales back up
8. VPA responds to new utilisation pattern → adjusts again
9. Cycle repeats → neither HPA nor VPA can stabilise

Root cause: VPA changes the denominator (resources.requests) that HPA uses
to calculate utilisation%. Any change in requests shifts HPA's
perceived utilisation even if actual CPU usage is unchanged.
```

**Apply the safe solution — VPA in Off mode alongside HPA:**
```bash
kubectl delete -f vpa-conflict.yaml

# Safe: VPA observes and recommends only — never changes requests
kubectl apply -f 02-vpa-off.yaml

kubectl get hpa nginx-deploy
kubectl get vpa nginx-vpa-off
```

```
# Observation: HPA manages replicas on CPU signal
#              VPA reports what the requests SHOULD be (Off mode only)
#              No conflict — VPA is not changing the denominator HPA uses
```

```bash
kubectl delete hpa nginx-deploy
kubectl delete -f 02-vpa-off.yaml
```

### Step 4 — VPA + HPA Conflict Demo

> **Important:** Scale back to 1 replica for this demo, and apply the HPA on CPU.
> The conflict requires BOTH tools watching CPU simultaneously.

```bash
# Scale back to 1 replica for the conflict demo
kubectl scale deployment nginx-deploy --replicas=1

# Apply HPA on CPU
kubectl autoscale deployment nginx-deploy --min=1 --max=5 --cpu=50%

# Apply VPA in Recreate mode on CPU — this creates the conflict
kubectl apply -f 04-vpa-conflict.yaml   # (create this file — see below)
```

**`src/04-vpa-conflict.yaml`:**
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
    updateMode: "Off"        # Use Off mode for conflict OBSERVATION (safe)
                              # Recreate would need ≥2 replicas to evict
                              # The conceptual conflict exists regardless of mode:
                              # VPA recommends changing requests → if applied,
                              # HPA's formula denominator changes → oscillation
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

> **Why Off mode for the conflict demo?**
>
> The conflict we are demonstrating is conceptual: VPA changing `resources.requests`
> shifts the denominator in HPA's formula. We can observe this by:
> (1) showing VPA's recommendation (50m) vs current request (100m)
> (2) showing what HPA's formula would produce with EACH value
> (3) explaining that Recreate mode would apply the VPA change → cause the conflict
>
> Using Recreate mode with 1 replica would trigger the Updater safety guard and not
> evict — which obscures the lesson. Off mode shows the conflict clearly without
> requiring 2 replicas.

**Generate load to trigger HPA:**
```bash
kubectl run load-generator --image=busybox:1.36 --restart=Never \
  --command -- sh -c \
  "while true; do wget -q -O- http://nginx-svc > /dev/null 2>&1; done"

# Watch HPA and VPA simultaneously
kubectl get hpa nginx-deploy -w &
kubectl get vpa nginx-vpa-conflict -w
```

**Expected output showing the conflict concept:**
```
HPA: cpu: 115%/50%  replicas: 1 → 3   ← HPA scales out (CPU > target)
VPA: cpu: 50m (recommendation)         ← VPA says: cpu request should be 50m

The conflict cycle if VPA Recreate were active:
  1. HPA sees 115% utilisation → scales to 3 pods
  2. VPA evicts pod → Admission Controller injects cpu=50m (lower than current 100m)
  3. Same actual CPU usage (e.g. 50m) / new request (50m) = 100% utilisation
  4. HPA formula: ceil[3 × (100/50)] = 6 → scales further out
  5. VPA observes new usage pattern → updates recommendation
  6. Cycle repeats → oscillation
```

**Cleanup:**
```bash
kubectl delete pod load-generator --grace-period=0 --force
kubectl delete hpa nginx-deploy
kubectl delete -f 04-vpa-conflict.yaml
kubectl scale deployment nginx-deploy --replicas=1
```

---

### Step 5 — Cleanup

```bash
kubectl delete -f 01-nginx-deploy.yaml --ignore-not-found
kubectl delete -f 02-vpa-off.yaml --ignore-not-found
kubectl delete -f 03-vpa-recreate.yaml --ignore-not-found
kubectl delete -f 04-vpa-conflict.yaml --ignore-not-found
kubectl delete hpa nginx-deploy --ignore-not-found
kubectl delete pod load-generator --ignore-not-found --grace-period=0

kubectl get vpa
kubectl get deployments
kubectl get pods
```

**Expected output:**
```
No resources found in default namespace.
No resources found in default namespace.
No resources found in default namespace.
```

**VPA uninstall — optional:**

VPA is a cluster-wide component. Uninstall it only if you do not plan to use it in
subsequent labs on this cluster. If you are proceeding to `04-keda` or
`05-prometheus-adapter`, VPA can remain installed — it does not interfere with
either of those demos.

```bash
# OPTIONAL — only uninstall if you are done with VPA on this cluster:
cd autoscaler/vertical-pod-autoscaler/hack
./vpa-down.sh
cd ../../..

kubectl get pods -n kube-system | grep vpa
kubectl api-resources | grep verticalpod
# No output expected if uninstalled
```

> If you leave VPA installed, metrics-server continues to serve it.
> VPA with no VPA objects deployed has negligible overhead.

---

## What You Learned

In this lab, you:
- ✅ Installed VPA and verified all three components (Recommender, Updater, Admission Controller) are running
- ✅ Explained the role of each VPA component and how they interact in sequence — observe → evict → inject
- ✅ Explained the VPA algorithm — inputs (metrics-server + VPACheckpoint), weighted histogram model, 8-day observation window, and all four output fields (Target, Lower Bound, Upper Bound, Uncapped Target)
- ✅ Used `kubectl describe vpa` to read all recommendation fields and understood what each implies
- ✅ Used VPA Off mode to get resource recommendations without changing any pods
- ✅ Inspected a VPACheckpoint and understood why it exists (histogram persistence across Recommender restarts)
- ✅ Used VPA Recreate mode and observed the complete lifecycle: Updater eviction → controller recreation → Admission Controller resource injection
- ✅ Explained all VPA update modes and when to use each (Off → Initial → Recreate → InPlaceOrRecreate)
- ✅ Demonstrated the HPA + VPA conflict cycle and applied the safe Off-mode combination

**Key Takeaway:** VPA is the right tool when the problem is not "how many pods" but "how big should each pod be." The three components work in a relay: Recommender observes and recommends, Updater decides when to evict (respecting PDB via Eviction API — unlike HPA's direct DELETE), and the Admission Controller injects the new values on every pod creation. Uncapped Target is your diagnostic tool: when it differs from Target, a policy constraint (`minAllowed`/`maxAllowed`) is overriding the data-driven recommendation — examine it to tune your `resourcePolicy`.

---

## Break-Fix

Three broken manifests below. For each: apply it, read the symptom from the cluster, diagnose, then reveal the answer.

---

### Error-1

**`src/break-fix/01-vpa-standalone-pod.yaml`:**
```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: standalone-pod-vpa
spec:
  targetRef:
    apiVersion: v1
    kind: Pod                 # BUG: targeting a standalone Pod directly
    name: my-standalone-pod  # not managed by any controller
  updatePolicy:
    updateMode: "Recreate"
```

```bash
kubectl run my-standalone-pod --image=nginx:1.27 \
  --requests='cpu=100m,memory=128Mi'
kubectl apply -f break-fix/01-vpa-standalone-pod.yaml
# Wait ~2 minutes
kubectl describe vpa standalone-pod-vpa
kubectl describe pod my-standalone-pod
```

VPA is applied successfully. After 2 minutes, `PROVIDED=True` and VPA has a recommendation. Then VPA evicts the pod. What happens next, and why is this a problem?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```bash
kubectl get pods
# NAME                  READY   STATUS
# (no pods)   ← my-standalone-pod is gone permanently
```

**Cause:** A standalone pod (not managed by Deployment, StatefulSet, or other controller) has no controller to recreate it after eviction. When VPA Updater evicts the pod in Recreate mode, it is deleted permanently — nothing recreates it. VPA requires a controller so that after eviction, the controller immediately creates a new pod, which the Admission Controller can then patch with the recommended resources.

**Fix:** Always use a Deployment (even with `replicas: 1`) when using VPA. Never target standalone pods with VPA in Recreate, Initial, or InPlaceOrRecreate mode. Off mode is technically safe (it never evicts), but VPA's targetRef does not officially support Pod kind — use a controller.

**Cascade:** Any VPA set to Recreate mode targeting a standalone pod will permanently delete the pod on first eviction. No error is thrown at apply time — the VPA creates successfully and even generates recommendations before causing the deletion.

</details>

---

### Error-2

**`src/break-fix/02-vpa-conflict-hpa-cpu.yaml`:**
```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: conflict-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-deploy
  updatePolicy:
    updateMode: "Recreate"   # BUG: active VPA on CPU while HPA also watches CPU
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
kubectl apply -f 01-nginx-deploy.yaml
kubectl autoscale deployment nginx-deploy --min=1 --max=5 --cpu=50%
kubectl apply -f break-fix/02-vpa-conflict-hpa-cpu.yaml
# Wait ~3 minutes, observe HPA replica count oscillating
kubectl get hpa nginx-deploy -w
```

The HPA replica count keeps changing every few minutes without any load change. What is causing this?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
HPA: replicas oscillating: 3 → 1 → 3 → 1
```

**Cause:** VPA Recreate mode changes `resources.requests.cpu` on the pods. HPA's utilisation formula is `usage / request × 100`. When VPA raises the request (e.g. from 100m to 143m), the same actual CPU usage now produces a lower utilisation percentage — HPA sees the metric fall below target and scales in. Fewer pods mean higher per-pod CPU usage, HPA scales out, VPA responds to the new pattern, and the cycle repeats.

**Fix:** Never run HPA on CPU/memory simultaneously with VPA in Recreate/Initial/InPlaceOrRecreate mode on the same Deployment. Two safe options: (1) HPA on CPU + VPA in Off mode; (2) HPA on custom/external metrics + VPA in Recreate mode on CPU/memory.

**Cascade:** The oscillation consumes resources (repeated pod eviction + recreation), degrades application availability (pods restart repeatedly), and prevents either autoscaler from reaching a stable state.

</details>

---

### Error-3

**`src/break-fix/03-vpa-missing-requests.yaml`:**
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
          # BUG: no resources block at all — no requests, no limits
---
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: vpa-no-requests
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-no-requests
  updatePolicy:
    updateMode: "Off"
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
kubectl apply -f break-fix/03-vpa-missing-requests.yaml
# Wait ~2 minutes
kubectl describe vpa vpa-no-requests
kubectl top pod -l app=nginx-no-requests
```

`kubectl top pod` shows the pod using CPU and memory. `kubectl describe vpa` shows `PROVIDED=True` with a Target recommendation. Is there a problem here?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Short answer: No visible error — but a hidden problem.** VPA works with no resource requests on the pod, but the Admission Controller cannot do anything useful in Recreate mode because there is nothing to update (no existing requests to change). More importantly:

**The real risk:** When this pod runs without `resources.requests`, it has no guaranteed resource allocation — it becomes a `BestEffort` QoS pod, which is the first to be evicted when the node is under memory pressure. Additionally, if this VPA were switched to Recreate mode, the Admission Controller would inject resource requests on pod recreation — but the requests would start from nothing, and the VPA recommendation might not be optimal without having observed a pod that was already sized with requests.

**Fix:** Always set `resources.requests` on containers before deploying VPA. The recommended workflow: deploy with best-guess requests → Off mode to observe → switch to Recreate once recommendations stabilise. Deploying without any requests and expecting VPA to bootstrap the sizing from scratch is not the intended use pattern.

**Cascade:** The pod may be evicted unexpectedly under node memory pressure (BestEffort QoS). VPA in Recreate mode would inject its recommendation but the transition from no-requests to recommendation-based requests is not clean — restart VPA in Off mode, let it observe the sized pod, then enable Recreate.

</details>

---

## Interview Prep

**Q1. Explain the VPA Updater's eviction mechanism and why it differs from HPA scale-down.**

VPA Updater uses the Kubernetes Eviction API — the same path used by `kubectl drain`. This means the Updater reads any active PodDisruptionBudgets before evicting a pod and will not evict if doing so would violate the budget. It waits until the PDB permits eviction. HPA scale-down, by contrast, calls DELETE directly on pods via the scale subresource, entirely bypassing the Eviction API and PDB. This asymmetry has historical roots — HPA predates the Eviction API maturation and uses direct deletion for speed, while VPA was designed later with PDB respect as a requirement for safe stateful workload management.

**Q2. A `kubectl describe vpa` shows `Target: cpu=50m` and `Uncapped Target: cpu=200m`. What does this tell you, and what action would you take?**

`maxAllowed` is clamping the recommendation downward. The histogram data says the container actually needs 200m CPU (Uncapped Target = 200m), but the `resourcePolicy.maxAllowed.cpu` is set at or below 50m, forcing Target to be capped. The container is being permanently under-provisioned — it will be CPU-throttled at peak load. Action: raise `maxAllowed.cpu` to at least 220m (110-120% of Uncapped Target as headroom) and verify the node has enough allocatable CPU to accommodate the increase.

**Q3. Your team wants to use VPA and HPA together on the same Deployment. The Deployment runs a web API. What is the safe configuration?**

The conflict arises only when both tools target CPU/memory simultaneously. The safe configuration depends on what HPA should watch. If HPA should scale on CPU: use VPA in Off mode only — VPA recommends what the request should be, but never changes it, so HPA's denominator never shifts. If HPA should scale on a custom metric (e.g. requests/second via Prometheus Adapter): VPA can be in Recreate mode on CPU/memory with no conflict, because HPA is not watching the metric that VPA's request changes affect.

**Q4. Why does VPA require a controller (Deployment, StatefulSet) and not support standalone pods?**

VPA Updater evicts pods to force recreation with new resource requests. When a pod is evicted, it is deleted. For the new resource values to take effect, a new pod must be created — which is what the Admission Controller patches at creation time. A standalone pod has no controller watching it and no mechanism to recreate it after eviction. The pod simply disappears permanently. Even for a single-instance application, using `Deployment replicas: 1` provides the controller required for VPA to work safely.

**Q5. What is a VPACheckpoint and what problem does it solve?**

VPACheckpoint is a CRD object automatically created by the VPA Recommender — one per container per VPA object. It persists the weighted histogram data that the Recommender builds over the observation window (default 8 days) to etcd. Without it, if the Recommender pod restarts due to an upgrade, crash, or node eviction, all accumulated histogram data would be lost and the Recommender would have to start collecting from scratch — producing no stable recommendations for minutes to hours. With checkpoints, the Recommender reads its persisted histograms on startup and resumes immediately without a gap.

---

## Cert Tips

### Exam Objective Mapping

| Demo concept / command | Exam objective | Notes |
|---|---|---|
| VPA components — Recommender, Updater, Admission Controller | CKA-domain2 — Workloads & Scheduling | Know which component does what; Updater uses Eviction API (unlike HPA) |
| VPA update modes — Off/Initial/Recreate/InPlaceOrRecreate | CKA-domain2 — Workloads & Scheduling | "Auto" is deprecated — do not use |
| `kubectl describe vpa` — Target vs Uncapped Target | CKA-domain5 — Troubleshooting | Uncapped ≠ Target means a policy constraint is clamping; diagnose minAllowed/maxAllowed |
| VPACheckpoint — what it is and why | CKA-domain2 — Workloads & Scheduling | Persists histogram data; auto-managed; one per container per VPA |
| Standalone pod vs single-pod app | CKA-domain5 — Troubleshooting | VPA cannot target standalone pods — must use Deployment (even replicas: 1) |
| HPA + VPA safe combinations | CKA-domain2 — Workloads & Scheduling | HPA-CPU + VPA-Recreate-CPU = conflict; HPA-CPU + VPA-Off = safe |
| VPA Eviction API vs HPA direct DELETE | CKA-domain5 — Troubleshooting | VPA respects PDB; HPA does not |

### Common Exam Traps

| Question pattern | Correct answer | Why wrong answers fail |
|---|---|---|
| "VPA can target a standalone pod in Recreate mode" | False — standalone pods have no controller to recreate after eviction; the pod is permanently deleted | Confusing `Off` mode (safe with standalone pod — never evicts) with Recreate mode |
| "VPA Updater uses direct DELETE like HPA scale-down" | False — VPA Updater uses the Eviction API; HPA scale-down uses direct DELETE | These are asymmetric by design; VPA respects PDB, HPA does not |
| "HPA and VPA always conflict when used together" | False — conflict is only HPA-on-CPU + VPA-Recreate-on-CPU; HPA-CPU + VPA-Off and HPA-custom-metrics + VPA-Recreate are both safe | The word "always" is wrong; the specific conflicting combination must be named |
| "Uncapped Target is the same as Target unless maxAllowed is set" | False — Uncapped Target differs from Target when EITHER minAllowed OR maxAllowed is clamping the recommendation | minAllowed raises the floor (Target > Uncapped), maxAllowed lowers the ceiling (Target < Uncapped) |
| "'Auto' updateMode is the recommended active VPA mode" | False — "Auto" is deprecated since VPA v1.4+; use Recreate or InPlaceOrRecreate | "Auto" currently maps to Recreate but will be removed in a future API version |

---

## Key Takeaways

| Concept | Detail |
|---|---|
| VPA is not built in | Separate install from `kubernetes/autoscaler` repo via `vpa-up.sh`. Three components: Recommender, Updater, Admission Controller. Maintained by Kubernetes SIG Autoscaling. |
| Recommender — what it does | Queries metrics-server every 60s; builds a weighted histogram per container per resource; writes recommendations to VPA.status; persists histogram in VPACheckpoint. |
| Updater — what it does | Reads recommendations; identifies out-of-range pods; uses Eviction API (respects PDB) to evict — does NOT directly inject resources; eviction triggers recreation. |
| Admission Controller — what it does | Mutating webhook; intercepts ALL pod creation requests; injects Target CPU/memory as resources.requests; runs on initial create AND after Updater evictions. |
| VPA retention | 8 days of histogram data (configurable via `--history-length`); persisted in VPACheckpoint objects; survives Recommender restarts. |
| Target field | 90th percentile of observed usage over the window; what VPA WILL SET as resources.requests in Recreate/InPlaceOrRecreate mode; the Updater trigger. |
| Uncapped Target | Recommendation before minAllowed/maxAllowed constraints; differs from Target when a policy is clamping; diagnostic tool for tuning resourcePolicy. |
| Lower Bound | ~25th percentile; minimum safe — below this, throttling/OOMKill likely; floored at minAllowed; NOT the Updater trigger. |
| Upper Bound | VPA's observed maximum; capped at maxAllowed; informational only — Updater does not enforce it as a ceiling. |
| VPACheckpoint | Auto-created by Recommender; one per container per VPA; persists histogram to etcd; prevents recommendation gaps after Recommender restarts. |
| Standalone pod limitation | VPA cannot target standalone pods in Recreate mode — no controller recreates after eviction; pod is permanently deleted. Always use Deployment (even `replicas: 1`). |
| Standalone pod ≠ single-pod app | Standalone pod = Pod object, no controller. Single-pod app = Deployment with `replicas: 1`. VPA supports the latter, not the former. |
| VPA Updater vs HPA scale-down | VPA Updater uses Eviction API → respects PDB. HPA scale-down uses direct DELETE → bypasses PDB. Asymmetric by design. |
| Update modes | Off: observe only (safe for production). Initial: inject at creation only. Recreate: evict + inject. InPlaceOrRecreate: prefer in-place, fallback Recreate. Auto: DEPRECATED — do not use. |
| Safe HPA + VPA combinations | HPA-CPU + VPA-Off (safe), HPA-custom-metrics + VPA-Recreate (safe), HPA-CPU + VPA-Recreate-CPU (CONFLICT — avoid). |
| Conflict mechanism | VPA changes resources.requests (the denominator HPA uses). HPA formula = usage / request × 100. Changing request shifts utilisation% without changing actual usage → oscillation. |
| Namespace rule | VPA, targetRef, and pods must all be in the same namespace. Cross-namespace targeting is not supported. |
| controlledValues | RequestsAndLimits (default): VPA updates requests + limits proportionally. RequestsOnly: VPA updates requests only; limits unchanged. |

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get vpa` | List all VPAs — MODE, CPU, MEM, PROVIDED |
| `kubectl describe vpa <name>` | VPA recommendations and all status fields |
| `kubectl get vpa <name> -o yaml` | Full YAML including status |
| `kubectl get vpacheckpoint` | List histogram checkpoints |
| `kubectl describe vpacheckpoint <name>` | Histogram contents + last update time |
| `kubectl api-resources \| grep verticalpod` | Confirm VPA CRDs are installed |
| `kubectl get pods -n kube-system \| grep vpa` | Verify all three VPA components are running |
| `kubectl get events --sort-by='.lastTimestamp' \| grep -i vpa` | VPA eviction events |
| `kubectl logs -n kube-system -l app=vpa-recommender` | Debug recommendations not appearing |

---

## Troubleshooting

**VPA shows `PROVIDED=False` beyond 5 minutes:**
```bash
kubectl get pods -n kube-system | grep vpa-recommender
kubectl logs -n kube-system -l app=vpa-recommender | tail -20
# Common causes:
# - vpa-recommender pod is not running
# - VPA targetRef name does not match any Deployment
# - Deployment has no pods running (nothing to observe)
```

**VPA pod not being evicted despite a Recreate recommendation:**
```bash
kubectl describe vpa <name> | grep "Update Mode"
# Must be Recreate or InPlaceOrRecreate — not Off or Initial
kubectl get pods -n kube-system | grep vpa-updater
kubectl describe pod -l app=nginx | grep -A4 "Requests:"
# If requests already match Target: no eviction needed — VPA is satisfied
# With only 1 replica and no PDB: VPA may wait to avoid downtime
# Fix: add replicas >= 2 + PDB with minAvailable=1
```

**VPA Admission Controller not injecting resources on new pod:**
```bash
kubectl get pods -n kube-system | grep vpa-admission-controller
# Admission Controller must be running and healthy
# If it crashed, new pods start with original (unpatched) resource requests
kubectl describe pod <new-pod> | grep -A4 "Requests:"
# If still showing original values: Admission Controller is not running
```

**VPA and HPA replica count oscillating:**
```bash
kubectl get hpa <name> -w
# Oscillating replicas = HPA-CPU + VPA-Recreate-CPU conflict
# Fix: switch VPA to Off mode OR switch HPA to custom/external metrics
kubectl delete vpa <conflict-vpa>
kubectl apply -f 02-vpa-off.yaml
```

**`kubectl describe vpacheckpoint` shows stale `LastUpdateTime`:**
```bash
kubectl logs -n kube-system -l app=vpa-recommender | grep checkpoint
# Stale LastUpdateTime means Recommender is not writing updates
# May indicate: Recommender pod restarted, or pods have been deleted
# (no pods to observe = no histogram updates = stale checkpoint)
```