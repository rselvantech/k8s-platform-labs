# Demo: 11-auto-scaling/02-hpa-advanced — HPA Advanced

## Lab Overview

`01-hpa-basic` covered HPA's `Resource` metric type (CPU and memory, averaged across all containers in a pod), `behavior` with `Pods`-type scaling policies, and an introduction to VPA. This lab extends the HPA side of that picture into territory `01-hpa-basic` only documented conceptually.

Two gaps stand out once you have used HPA on a single-container pod: what happens when a pod has more than one container, and how do you control the shape of a scaling curve rather than just its target? This lab answers both — then goes one level deeper into the metrics pipeline itself, covering what serves HPA's `Pods`, `Object`, and `External` metric types when CPU/memory are not the right signal.

**Real-world scenario:** A containerised application runs with a main `app` container alongside a `sidecar` container for log shipping. CPU spikes from the sidecar were triggering unwanted HPA scale-outs because the original `Resource`-type HPA averaged CPU across both containers. The fix is `ContainerResource` — targeting only the `app` container. Additionally, the team needed finer control over how fast the fleet grows during a sudden spike vs how slowly it shrinks during a quiet period — this is what `Percent`-type behavior policies provide. Finally, the team needs to understand when to add a metrics adapter and which HPA metric type to use as the workload evolves toward queue-based and request-rate-based scaling signals.

**What this lab covers:**
- `ContainerResource` metric type — scaling based on ONE container's CPU/memory in a multi-container pod
- HPA `behavior` — `Percent`-type scale-up/scale-down policies, and how they differ from `01-hpa-basic`'s `Pods`-type policies
- The Custom Metrics API (`custom.metrics.k8s.io`) and the `Pods`/`Object` HPA metric types
- The External Metrics API (`external.metrics.k8s.io`), the `External` metric type, and metrics adapter architecture
- A decision framework for choosing among all five HPA metric types

> **Scope note:** Steps 1–3 are hands-on (minikube `3node`, the same cluster as `01-hpa-basic`, metrics-server already enabled). Step 4 (Decision Framework) is a short theory step — no cluster commands. For deeper adapter architecture and E2E flows, see `## Kubernetes Scaling — API & Adapter Reference` below. Prometheus-based custom metrics (`Pods`/`Object` types with Prometheus Adapter) are covered hands-on in later Prometheus Adapter demos in this series (minikube `3node`). AWS-specific external metrics (SQS, ALB, CloudWatch) are covered in `aws-eks-demos`.

> **Verification status:** Steps 1–3 expected outputs and Break-Fix scenarios are written from documented HPA v2 behaviour, consistent with the facts already verified in `01-hpa-basic`. They have not yet been run against this lab's manifests on a live cluster — run through Steps 1–3 and Break-Fix on your `3node` cluster and report back anything that differs.

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — same cluster used in `01-hpa-basic`
- kubectl installed and configured
- metrics-server enabled (already done in `01-hpa-basic` Step 1)

**Verify metrics-server before starting:**
```bash
kubectl get pods -n kube-system | grep metrics-server
kubectl top nodes
# Both must work before proceeding — if not, see 01-hpa-basic Step 1
```

**Knowledge Requirements:**
- **REQUIRED:** Completion of `01-hpa-basic` — HPA v2 `Resource` metric type, the HPA scaling formula (`desiredReplicas = ceil[currentReplicas × (currentValue / targetValue)]`), scale-down stabilisation, `behavior` with `Pods`-type and `selectPolicy` options
- **REQUIRED:** Understanding of multi-container pods — containers in the same pod share network and IPC namespaces but have independent resource requests/limits

---

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Deploy a multi-container pod and read each container's CPU/memory separately via `kubectl top`
2. ✅ Configure an HPA using `ContainerResource` to target a single container's CPU
3. ✅ Explain why a `Resource`-type HPA can scale based on a non-targeted container's load, and how `ContainerResource` avoids this
4. ✅ Configure HPA `behavior` using `Percent`-type scale-up and scale-down policies
5. ✅ Calculate the step-size effect of `Percent` policies and compare it against the `Pods`-based policies from `01-hpa-basic`
6. ✅ Explain the purpose of `selectPolicy` (Min/Max/Disabled) and how multiple policies interact
7. ✅ Choose the correct HPA metric type for a given scaling scenario across all five types
8. ✅ Describe the role of a metrics adapter and which HPA metric types require one

> **Reference:** For full adapter architecture, E2E flows, VPA/CA API usage, KEDA, and Prometheus Adapter configuration, see `## Kubernetes Scaling — API & Adapter Reference`.

---

## Directory Structure

```
11-auto-scaling/02-hpa-advanced/
├── README.md                              # this file
├── 02-hpa-advanced-anki.csv               # Anki flashcard deck
├── 02-hpa-advanced-quiz.md                # standalone quiz
└── src/
    ├── 01-deployment-sidecar.yaml          # multi-container pod: app + sidecar
    ├── 02-hpa-container-resource.yaml      # HPA — ContainerResource, targets "app"
    ├── 03-hpa-behavior-percent.yaml        # HPA — Resource + Percent behavior
    └── break-fix/
        ├── 01-wrong-container-name.yaml          # broken: container name mismatch
        ├── 02-stuck-scale-up-stabilization.yaml  # broken: scaleUp window left at 300s
        └── 03-deployment-missing-request.yaml    # broken: missing cpu request
```

---

## Recall Check — 01-hpa-basic

Answer from memory before continuing — these are scenario questions from `01-hpa-basic`.

1. A Deployment is running at 1 replica. An HPA's `kubectl describe` shows current CPU at 115% and target at 50%. Using the HPA scaling formula, how many replicas does the HPA scale to, and what is the calculation?
2. After that scale-up, load drops to 0% CPU. By default, how long does the HPA wait before scaling back down, and what is it doing during that wait?
3. You apply an HPA with `behavior.scaleDown.selectPolicy: Disabled`. Load drops to zero and stays there for 30 minutes. `kubectl get hpa` shows `cpu: 0%/50%` and REPLICAS stays at 5. `kubectl apply` produced no error when you created the HPA. What is wrong, and how do you fix it?

<details>
<summary>Answers</summary>

1. `desiredReplicas = ceil[1 x (115/50)] = ceil[2.3] = 3`. The HPA scales the Deployment to 3 replicas.
2. 5 minutes (300 seconds) — the default `scaleDown.stabilizationWindowSeconds`. During that window, the HPA records the highest replica-count recommendation seen over the last 5 minutes and will only scale down to that value, preventing it from removing pods and immediately needing to add them back.
3. `selectPolicy: Disabled` in the `scaleDown` block blocks all scale-down permanently, regardless of metric values or any `policies` entries listed alongside it. It is valid YAML and applies without error — nothing in the cluster signals a problem. Fix: change `selectPolicy: Disabled` to `selectPolicy: Max` (or `Min`) in the `scaleDown` block.
</details>

---

## Concepts

### Terminology Reference

Before the hands-on steps, a quick map of the terms used throughout this demo:

**Metric types** — the `type` field at the top of each `metrics[]` entry. The five types are:
`Resource`, `ContainerResource`, `Pods`, `Object`, `External`. Each selects a different
metrics pipeline (metrics-server or a custom/external adapter).

**Resource names** — the `name` field inside `resource:` or `containerResource:`. For
built-in types this is `cpu` or `memory`. For custom/external types it is an arbitrary
string the adapter exposes (e.g. `requests_per_second`, `sqs_queue_depth`).

**Target types** — the `type` field inside `target:`. Three possible values:
- `Utilization` — percentage of the container/pod's `resources.requests` value.
  Only valid for `Resource` and `ContainerResource`. Requires `resources.requests` to be set.
- `AverageValue` — a raw metric value averaged across all current pods of the target.
  Valid for all five metric types.
- `Value` — a raw metric value NOT divided by pod count. The total as-is from the source.
  Only valid for `Object` and `External`. Use when the metric is a cluster-level total
  (e.g. total Ingress requests/s), not a per-pod signal.


---

### HPA `ContainerResource` — Per-Container Metrics

`01-hpa-basic` used `type: Resource`, which computes utilisation across the **whole pod**:

```
Resource utilisation = sum(usage across ALL containers) / sum(requests across ALL containers)
```

This works fine for single-container pods. It breaks down for multi-container pods where one container's activity is unrelated to the workload you actually want to scale — for example, a logging or metrics-shipping **sidecar** that periodically spikes CPU. A `Resource`-type HPA averages that spike into the pod-level number, and may scale the Deployment based on sidecar noise rather than application demand.

`type: ContainerResource` (stable since Kubernetes v1.30, `autoscaling/v2`) solves this by measuring **one named container only**:

```yaml
metrics:
  - type: ContainerResource
    containerResource:
      name: cpu                  # cpu or memory
      container: app             # the specific container to measure
      target:
        type: Utilization
        averageUtilization: 50   # same target semantics as Resource
```

Everything else — the `target` block, the scaling formula, `behavior` — works identically to `Resource`. The only difference is the scope of the measurement.

**Diagnostic difference (`kubectl describe hpa`):**

```
Resource:           resource cpu on pods (as a percentage of request): 37% (37m) / 50%
ContainerResource:  resource cpu on container "app" (as a percentage of request): 37% (37m) / 50%
```

The `on container "X"` wording is the tell — if you see this, the HPA is scoped to one container, and load on other containers in the pod is invisible to it.

> **On older clusters:** `ContainerResource` requires Kubernetes >= v1.30 for GA stability. If `kubectl describe hpa` shows the metric as permanently `<unknown>` and the cluster predates v1.30, check the cluster version first — this is a version gap, not a configuration error.

---

### HPA Behavior — `Percent` vs `Pods` Scaling Policies

`01-hpa-basic` Step 8 used `behavior` policies of `type: Pods` — an **absolute** number of pods per period:

```yaml
scaleUp:
  policies:
    - type: Pods
      value: 4          # add at most 4 pods...
      periodSeconds: 15 # ...per 15-second window
```

`type: Percent` instead caps the step as a **percentage of the current replica count** per period:

```yaml
scaleUp:
  policies:
    - type: Percent
      value: 100         # increase by at most 100% of current replicas...
      periodSeconds: 30  # ...per 30-second window
```

**Critical point — `behavior` policies are step-size limiters, not the scaling decision itself.** The HPA still computes a desired replica count from the metric formula every evaluation cycle. The `behavior` policy limits how far the replica count can move toward that desired value in one period.

**Worked comparison — starting from 1 replica, metrics justify 8 replicas immediately:**

```
Pods,    value: 4, periodSeconds: 15:
  Window 1 (15s): 1 -> 5   (+4, linear)
  Window 2 (15s): 5 -> 8   (capped at desired, +3 of the allowed +4)

Percent, value: 100, periodSeconds: 30:
  Window 1 (30s): 1 -> 2   (+100% of 1)
  Window 2 (30s): 2 -> 4   (+100% of 2)
  Window 3 (30s): 4 -> 8   (+100% of 4, capped at desired)
```

At **small** replica counts, `Pods` with a large `value` reaches desired faster (linear, fixed step). At **large** replica counts, `Percent` reaches it faster (the step grows with current size). The same applies to `scaleDown`: `Percent, value: 50` halves per period vs `01-hpa-basic`'s `Pods, value: 2` which removed at most 2 per period regardless of fleet size.

---

## Kubernetes Scaling — API & Adapter Reference

> **Purpose:** Infrastructure and API layer reference for Kubernetes autoscaling. Covers
> the three metrics API groups, the adapter ecosystem, how HPA/VPA/CA relate to those
> APIs, E2E flows, and a Prometheus Adapter configuration checklist. Read this alongside
> the lab steps — not as a prerequisite to them.
>
> **Hands-on covered elsewhere:**
> - HPA usage, YAML, scaling behaviour → `01-hpa-basic`
> - VPA installation and usage → `03-vpa-fundamentals`
> - Prometheus Adapter hands-on → `06-prometheus-adapter-pods-type` / `07-prometheus-adapter-object-type`
> - AWS-specific sources (SQS, ALB, CloudWatch), CA, KEDA SQS → not covered here. will be covered in `aws-eks-demos` series
> - KEDA core (Kafka, Redis, Prometheus scalers) → `04-keda-fundamentals` / `05-keda-redis-scaler`

---

### 1. The Kubernetes Scaling Landscape

Kubernetes has three distinct autoscaling mechanisms. They operate at different levels and
are completely independent of each other — different problems, different APIs, different
components.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    KUBERNETES AUTOSCALING — THREE LAYERS                        │
├──────────────┬──────────────────────┬──────────────────────────────────────────┤
│  Mechanism   │  Answers             │  Scales                                  │
├──────────────┼──────────────────────┼──────────────────────────────────────────┤
│  HPA         │  How many pods?      │  Replica count of a Deployment/StatefulSet│
│  VPA         │  How big per pod?    │  CPU/memory requests on individual pods  │
│  CA          │  How many nodes?     │  Node count in the cluster               │
└──────────────┴──────────────────────┴──────────────────────────────────────────┘
```

They can and often do work together:
- HPA scales pod count based on load
- VPA right-sizes what each pod requests
- CA adds nodes when pods can't be scheduled due to insufficient cluster capacity

---

### 2. The Kubernetes Metrics APIs

Kubernetes defines three Metrics API groups. Each covers a different category of metric.
The key architectural point: **these are API contracts, not implementations**. Kubernetes
defines what the API looks like; separate components implement it.

```
API Group                      Implemented By       Consumers
──────────────────────────────────────────────────────────────────────────────
metrics.k8s.io                 metrics-server       HPA (Resource/ContainerResource)
                                                    VPA Recommender
                                                    kubectl top

custom.metrics.k8s.io          metrics adapter      HPA only (Pods, Object types)
                                                    VPA: never — VPA only reads
                                                         metrics.k8s.io regardless
                                                         of what adapters are installed
                                                    CA:  never — CA reads no metrics
                                                         API at all (watches scheduler
                                                         state, not metric values)

external.metrics.k8s.io        metrics adapter      HPA only (External type)
                                                    VPA: never (same reason as above)
                                                    CA:  never (same reason as above)
```

#### 2.1 `metrics.k8s.io` — The Resource Metrics API

Exposes **CPU and memory** for pods and nodes. Served by `metrics-server`, which reads
from the `cAdvisor` agent embedded in each kubelet.

This is the only API that VPA uses. It is also what HPA uses for `type: Resource` and
`type: ContainerResource` metrics. `kubectl top pods` and `kubectl top nodes` query this
API directly.

**Characteristics:**
- Scrape interval: metrics-server polls each kubelet's `/metrics/resource` endpoint every **60 seconds** (default, configurable via `--metric-resolution` flag)
- HPA evaluation interval: the HPA controller queries the Metrics API every **15 seconds** (default `--horizontal-pod-autoscaler-sync-period`)
- These are two separate intervals: metrics-server refreshes its data every 60s; HPA reads whatever is current every 15s
- In-memory only — no historical data, no persistence; only the most recent sample per pod is stored
- No configuration required beyond installing metrics-server

#### 2.2 `custom.metrics.k8s.io` — The Custom Metrics API

Exposes **arbitrary application-level metrics scoped to a Kubernetes object** (a pod,
an Ingress, a Service, etc.). Used by HPA `type: Pods` and `type: Object`.

Not implemented by metrics-server. Requires a **metrics adapter** to be installed and
registered. The adapter is the bridge between a metrics backend (Prometheus, Datadog,
etc.) and this API.

**Characteristics:**
- No built-in implementation — adapter required
- Any metric that can be expressed as a value per Kubernetes object
- Metric must be "owned by" a Kubernetes resource (a pod, ingress, service, etc.)

#### 2.3 `external.metrics.k8s.io` — The External Metrics API

Exposes **metrics from sources that have no Kubernetes representation** — AWS SQS queue
depth, Kafka consumer lag, Redis queue length, etc. Used by HPA `type: External`.

Also requires a **metrics adapter**. The `selector.matchLabels` in the HPA YAML is passed
to the adapter to identify which external resource to query.

**Characteristics:**
- No built-in implementation — adapter required
- Metric source exists entirely outside the Kubernetes object model
- No `kubectl get` resource corresponds to the metric source

---

### 3. How Each Scaler Uses (or Doesn't Use) These APIs

```
┌────────┬──────────────────────────┬────────────────────────┬───────────────────────┐
│        │  metrics.k8s.io          │  custom.metrics.k8s.io │  external.metrics.k8s │
│        │  (metrics-server)        │  (adapter required)    │  (adapter required)   │
├────────┼──────────────────────────┼────────────────────────┼───────────────────────┤
│  HPA   │  ✅ Resource,            │  ✅ Pods, Object       │  ✅ External          │
│        │     ContainerResource    │                        │                       │
├────────┼──────────────────────────┼────────────────────────┼───────────────────────┤
│  VPA   │  ✅ reads usage history  │  ✗ never               │  ✗ never              │
│        │     for recommendations  │                        │                       │
├────────┼──────────────────────────┼────────────────────────┼───────────────────────┤
│  CA    │  ✗ never                 │  ✗ never               │  ✗ never              │
│        │  (doesn't use any        │                        │                       │
│        │   metrics API)           │                        │                       │
└────────┴──────────────────────────┴────────────────────────┴───────────────────────┘
```

This table is the core insight: **only HPA uses the custom and external metrics APIs**.
VPA only ever reads from `metrics.k8s.io`. CA does not use any metrics API at all.

---

### 4. VPA — How It Gets Metrics (No Adapter Needed)

VPA Recommender reads only from `metrics.k8s.io` — the same API that `kubectl top` uses. No custom metrics adapter is involved. VPA does not scale replicas — it changes the `resources.requests` on the pod spec based on observed usage.

Full VPA component architecture (Recommender, Updater, Admission Controller), the histogram model, and update modes are covered in `03-vpa-fundamentals`.

**Key point for this reference:** VPA never queries `custom.metrics.k8s.io` or `external.metrics.k8s.io` regardless of what adapters are installed. This is why the table in Section 3 shows VPA only in the `metrics.k8s.io` column.

---

### 5. CA — No Metrics API Involved

CA (Cluster Autoscaler) operates entirely outside the metrics API layer. Its signal is
the **Kubernetes scheduler state**, not any metric value.

```
┌─────────────────────────────────────────────────────────────────────────┐
│  SCALE UP trigger:                                                       │
│    Pod enters Pending state because no node has enough CPU/memory        │
│    CA detects: "scheduler cannot place this pod"                         │
│    CA calls cloud provider API to add a node                             │
│    New node joins → scheduler places the pending pod                     │
│                                                                          │
│  SCALE DOWN trigger:                                                     │
│    CA identifies underutilised nodes where all pods could be             │
│    rescheduled onto other nodes                                          │
│    CA cordons and drains the node, then calls cloud provider to remove it│
└─────────────────────────────────────────────────────────────────────────┘
```

**What CA talks to:**

```
CA does NOT query:
  ✗  metrics.k8s.io
  ✗  custom.metrics.k8s.io
  ✗  external.metrics.k8s.io
  ✗  Prometheus
  ✗  Any metrics adapter

CA DOES talk to:
  ✅  Kubernetes API server (to watch pod scheduling state)
  ✅  Cloud provider API (to add/remove nodes)
        AWS   → EC2 Auto Scaling Groups API
        GCP   → Managed Instance Groups API
        Azure → Virtual Machine Scale Sets API
```

**Why CA requires cloud infrastructure:** It must be able to call a cloud provider API to
provision or deprovision nodes. On minikube or bare-metal clusters, there is no cloud
provider to call — CA has nothing to drive. This is why the CA lab is in the EKS demo
series: it requires real AWS Auto Scaling Groups behind the node groups.

**How CA and HPA interact in practice:**

```
1. HPA scales a Deployment from 3 → 10 pods (due to high traffic)
2. The cluster only has capacity for 7 more pods
3. 3 pods enter Pending state — scheduler cannot place them
4. CA detects the Pending pods and adds nodes
5. New nodes join → scheduler places the remaining 3 pods
6. Traffic drops → HPA scales back to 3 pods
7. Several nodes become underutilised → CA removes them
```

HPA and CA do not communicate directly. CA simply reacts to what the scheduler reports.

---

### 6. `metrics-server` — What It Is and Is Not

`metrics-server` is a lean, in-memory implementation of the `metrics.k8s.io` API. It is
the only standard component that implements this API and is a prerequisite for HPA
`type: Resource` and for VPA.

```
┌─────────────────────────────────────────────────────────────────────────┐
│  metrics-server                                                          │
│                                                                          │
│  Reads from:  cAdvisor (embedded in each kubelet)                        │
│  Exposes:     CPU and memory for pods and nodes                          │
│  API served:  metrics.k8s.io                                             │
│  Storage:     in-memory only (no persistence, no history)                │
│  Window:      most recent ~1 minute of data                              │
│                                                                          │
│  Does NOT:                                                               │
│    ✗ serve custom.metrics.k8s.io                                         │
│    ✗ serve external.metrics.k8s.io                                       │
│    ✗ store historical data                                               │
│    ✗ understand application-level metrics                                │
│    ✗ replace Prometheus (different purpose, different scope)             │
└─────────────────────────────────────────────────────────────────────────┘
```

`metrics-server` vs Prometheus is a common source of confusion:

```
metrics-server:
  Purpose:   serve the Kubernetes metrics.k8s.io API (for HPA + VPA + kubectl top)
  Scope:     CPU and memory only
  History:   none — in-memory, ~1 min window
  HPA use:   type: Resource, type: ContainerResource

Prometheus:
  Purpose:   general-purpose time-series metrics database
  Scope:     any metric any application exposes
  History:   configurable retention (days, weeks, months)
  HPA use:   indirect — via Prometheus Adapter serving custom.metrics.k8s.io
```

They are not alternatives to each other — they serve entirely different purposes.
Many clusters run both: metrics-server for the Kubernetes metrics API, Prometheus for
observability and as the backend for HPA custom metrics via the adapter.

---

### 7. What Is a Metrics Adapter?

A **metrics adapter** is a Kubernetes component (a Deployment) that:

1. Implements `custom.metrics.k8s.io` and/or `external.metrics.k8s.io`
2. Registers itself with the Kubernetes API server as an `APIService` for those groups
3. Fetches values from a backend (Prometheus, CloudWatch, etc.) when queried by HPA
4. Returns results in the format the HPA controller expects

> **"Metrics adapter" is a role, not a product.** Any component implementing the API
> contract fills this role. metrics-server is the built-in adapter for `metrics.k8s.io`;
> there is no built-in adapter for the other two — you choose and install one.

#### 7.1 How the Adapter Registers Itself

```yaml
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  name: v1beta1.custom.metrics.k8s.io
spec:
  service:
    name: prometheus-adapter
    namespace: monitoring
  group: custom.metrics.k8s.io
  version: v1beta1
  groupPriorityMinimum: 100
  versionPriority: 100
```

Once registered, all requests to `/apis/custom.metrics.k8s.io/...` arriving at
kube-apiserver are proxied to the adapter's Service. The HPA controller has no direct
connection to the adapter — it always goes through kube-apiserver.

#### 7.2 Available Adapter Implementations

| Adapter | Backend | API Groups Covered | Cluster Support |
|---|---|---|---|
| **Prometheus Adapter** | Prometheus | `custom.metrics.k8s.io` + `external.metrics.k8s.io` | Any cluster |
| **KEDA** | SQS, Kafka, Redis, Prometheus, HTTP, 50+ | `external.metrics.k8s.io` | Any cluster (scaler-dependent) |
| **CloudWatch Metrics Adapter** | AWS CloudWatch | `external.metrics.k8s.io` | EKS / AWS only — **archived**, no longer maintained. Use KEDA SQS scaler instead. |
| **Datadog Cluster Agent** | Datadog | `custom.metrics.k8s.io` + `external.metrics.k8s.io` | Any cluster (needs Datadog subscription) |

#### 7.3 Adapter Ownership, Licensing, and Resources

**Prometheus Adapter**
- Maintained by the Kubernetes community under `kubernetes-sigs` (official Kubernetes
  Special Interest Groups). Licensed Apache 2.0. Not tied to any company.
- GitHub: https://github.com/kubernetes-sigs/prometheus-adapter
- Helm: https://artifacthub.io/packages/helm/prometheus-community/prometheus-adapter

**KEDA (Kubernetes Event-Driven Autoscaling)**
- Originally created at Microsoft; donated to CNCF in 2020; reached CNCF **Graduated**
  status August 2023. Primary sponsors: Microsoft Azure, Snyk, VexxHost. Apache 2.0.
- Cloud-agnostic — runs on any Kubernetes cluster. Only specific scalers (e.g. SQS)
  require cloud access; scalers like Kafka, Redis, Prometheus run on minikube.
- Website: https://keda.sh | GitHub: https://github.com/kedacore/keda

**CloudWatch Metrics Adapter**
- Originally by AWS under `awslabs`. Now **archived** — no longer actively maintained.
  For new AWS-based scaling, KEDA's built-in SQS/CloudWatch scalers are the recommended
  active path.
- GitHub (archived): https://github.com/amazon-archives/k8s-cloudwatch-adapter

**Datadog Cluster Agent**
- Developed and maintained by Datadog (commercial). Requires a Datadog subscription.
  Not open source in the same sense as the others.
- Docs: https://docs.datadoghq.com/containers/cluster_agent

---

### 8. The HPA-Specific Metric Types and Which API Each Uses

When the HPA controller processes a metric, the `type` field unconditionally determines
which API group is queried. There is no configuration for this routing.

```
type: Resource          → queries metrics.k8s.io         (metrics-server)
type: ContainerResource → queries metrics.k8s.io         (metrics-server)
type: Pods              → queries custom.metrics.k8s.io  (adapter required)
type: Object            → queries custom.metrics.k8s.io  (adapter required)
type: External          → queries external.metrics.k8s.io (adapter required)
```

If the required API has no backend registered:
- HPA metric status shows `<unknown>` permanently
- HPA holds the current replica count (does not scale)
- No error is thrown — the HPA silently waits

#### 8.1 `Pods` Type — Per-Pod Custom Metric, Averaged

HPA gets one value per pod from the adapter, averages them, compares to `averageValue`.

```yaml
metrics:
  - type: Pods
    pods:
      metric:
        name: requests_per_second
      target:
        type: AverageValue
        averageValue: "1000"          # target 1000 req/s per pod (average)
```

API path queried:
```
GET /apis/custom.metrics.k8s.io/v1beta1/namespaces/{ns}/pods/*/{metric-name}
```

#### 8.2 `Object` Type — Single Value from One Kubernetes Object

HPA gets one aggregate value for a named Kubernetes object (not per-pod). The object
the metric belongs to (e.g. an Ingress) is usually different from the object being
scaled (e.g. a backend Deployment).

```yaml
metrics:
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
        value: "10000"                # TOTAL requests/s on the Ingress
```

API path queried:
```
GET /apis/custom.metrics.k8s.io/v1beta1/namespaces/{ns}/
        ingresses.networking.k8s.io/main-ingress/requests_per_second
```

Note: the Ingress itself does not emit this metric. The nginx-ingress-controller
Deployment does — Prometheus scrapes it, the adapter maps it to the Ingress object.

#### 8.3 `External` Type — Metric With No Kubernetes Owner

Used for signals from entirely outside the Kubernetes object model (SQS, Kafka, Redis,
databases). There is no `describedObject` — only a label selector that the adapter
interprets to identify which external resource to query.

```yaml
metrics:
  - type: External
    external:
      metric:
        name: sqs_queue_depth
        selector:
          matchLabels:
            queue: orders
      target:
        type: AverageValue
        averageValue: "30"            # target 30 messages per worker pod
```

API path queried:
```
GET /apis/external.metrics.k8s.io/v1beta1/namespaces/{ns}/
        sqs_queue_depth?labelSelector=queue=orders
```

---

### 9. Prometheus and the Prometheus Adapter — The Relationship

A common source of confusion: Prometheus and the Prometheus Adapter are two entirely
separate components with different jobs.

```
Prometheus:
  ├─ A time-series database and scraping engine
  ├─ Scrapes /metrics endpoints from pods (Prometheus exposition format)
  ├─ Stores time-series data with configurable retention
  ├─ Exposes a PromQL HTTP query API (used by Grafana, alerting rules, etc.)
  └─ Has NO knowledge of the Kubernetes Custom Metrics API

Prometheus Adapter:
  ├─ A separate Deployment in the cluster
  ├─ Implements custom.metrics.k8s.io and external.metrics.k8s.io
  ├─ Registered with kube-apiserver as an APIService
  ├─ When HPA requests a metric:
  │    1. Translates the request into a PromQL query
  │    2. Runs that query against Prometheus (same HTTP API Grafana uses)
  │    3. Returns the result in the Custom Metrics API format
  └─ All mapping rules live in the adapter's ConfigMap — Prometheus needs zero changes
```

#### 9.1 Full Component Stack — Prometheus-backed HPA

```
Application Pods  →  /metrics endpoint (Prometheus format)
        │
        │  scrape every 15s
        ▼
Prometheus  →  stores time-series  →  Grafana (dashboards)
        │
        │  PromQL queries (same HTTP API)
        ▼
Prometheus Adapter  →  registered as APIService for custom.metrics.k8s.io
        │
        │  Custom Metrics API (via kube-apiserver proxy)
        ▼
HPA Controller  →  calculates desiredReplicas  →  updates Deployment
```

#### 9.2 Prometheus Adapter ConfigMap — How Rules Work

```yaml
rules:
  - seriesQuery: 'http_requests_total{namespace!="",pod!=""}'
    #  which Prometheus metric series this rule covers

    resources:
      overrides:
        namespace: {resource: "namespace"}
        pod:       {resource: "pod"}
    #  maps Prometheus labels to Kubernetes resource names
    #  so the adapter knows which pod/namespace the metric belongs to

    name:
      matches: "^(.*)_total$"
      as: "${1}_per_second"
    #  the Custom Metrics API name exposed to HPA
    #  "http_requests_total" → "http_requests_per_second"

    metricsQuery: 'sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)'
    #  PromQL query run when HPA requests this metric
    #  template variables filled by the adapter per request
```

#### 9.3 What Needs to Be Configured in Prometheus?

**Nothing.** Prometheus only needs to already be scraping the relevant pods. The adapter
reads from Prometheus using the standard PromQL HTTP API — the same way Grafana does.
All mapping configuration lives in the adapter's ConfigMap, not in Prometheus.

#### 9.4 Cluster Requirements

| Component | Works On |
|---|---|
| metrics-server | Any cluster |
| Prometheus + Prometheus Adapter | Any cluster — minikube, kind, EKS, GKE, AKS (Prometheus must be separately deployed — not bundled) |
| KEDA (core + Kafka/Redis/Prometheus scalers) | Any cluster (cloud-specific scalers such as SQS require AWS credentials) |
| CloudWatch Metrics Adapter (archived) | EKS or any cluster with AWS credentials |
| Cluster Autoscaler | Cloud clusters only (EKS, GKE, AKS — needs cloud node API) |

---

### 10. KEDA — Event-Driven Scaling and Scale-to-Zero

KEDA (Kubernetes Event-Driven Autoscaling) fills the gap between native HPA and
event-driven workloads. It is a CNCF Graduated project (not AWS/cloud-specific) that
installs its own metrics adapter and extends HPA with two key capabilities:

**1. Scale to zero** — native HPA requires `minReplicas ≥ 1`. KEDA can scale a
Deployment to 0 replicas when there is no work, and from 0 when work arrives.

**2. 50+ built-in scalers** — no need to configure a separate adapter per source.

```
KEDA architecture:
  ScaledObject (CRD)  →  KEDA Operator  →  creates/manages an HPA
  KEDA Metrics Server →  implements external.metrics.k8s.io
  Scaler              →  polls the event source (SQS, Kafka, Redis, etc.)
```

KEDA does not replace HPA — it creates and manages HPA objects under the hood. The
HPA still does the actual pod scaling; KEDA feeds it the metric values via its own
adapter and handles the scale-to-zero logic that HPA cannot express.

**Scaler cloud requirements:**

| KEDA Scaler | Requires Cloud? | Works on Minikube? |
|---|---|---|
| SQS scaler | Yes — AWS credentials + SQS queue | No |
| Kafka scaler | No | Yes |
| Redis scaler | No | Yes |
| Prometheus scaler | No | Yes |
| Cron scaler | No | Yes |
| HTTP scaler | No | Yes |

---

### 11. Complete Comparison — All Three Scalers

```
┌──────────────┬──────────────────────┬──────────────────────┬─────────────────────┐
│              │  HPA                 │  VPA                 │  CA                 │
├──────────────┼──────────────────────┼──────────────────────┼─────────────────────┤
│ Scales       │  Pod replica count   │  Pod CPU/mem         │  Node count         │
│              │                      │  requests/limits     │                     │
├──────────────┼──────────────────────┼──────────────────────┼─────────────────────┤
│ Signal       │  Metric value vs     │  Observed CPU/mem    │  Pending pods       │
│              │  target threshold    │  usage over time     │  (scheduler state)  │
├──────────────┼──────────────────────┼──────────────────────┼─────────────────────┤
│ Uses         │  metrics.k8s.io      │  metrics.k8s.io      │  None               │
│ metrics API  │  custom.metrics.k8s  │  only                │                     │
│              │  external.metrics.k8s│                      │                     │
├──────────────┼──────────────────────┼──────────────────────┼─────────────────────┤
│ Adapter      │  Required for Pods,  │  Not required        │  Not required       │
│ needed?      │  Object, External    │                      │                     │
│              │  types               │                      │                     │
├──────────────┼──────────────────────┼──────────────────────┼─────────────────────┤
│ Talks to     │  kube-apiserver      │  kube-apiserver      │  kube-apiserver     │
│              │  (metrics APIs)      │  (metrics.k8s.io)    │  (pod scheduling)   │
│              │                      │                      │  Cloud provider API │
├──────────────┼──────────────────────┼──────────────────────┼─────────────────────┤
│ Cloud        │  No                  │  No                  │  Yes — needs cloud  │
│ required?    │                      │                      │  node provisioning  │
├──────────────┼──────────────────────┼──────────────────────┼─────────────────────┤
│ Minikube     │  Yes                 │  Yes                 │  No                 │
│ compatible?  │                      │                      │                     │
├──────────────┼──────────────────────┼──────────────────────┼─────────────────────┤
│ Scale to     │  No (min 1 replica)  │  N/A                 │  N/A                │
│ zero?        │  KEDA can            │                      │                     │
├──────────────┼──────────────────────┼──────────────────────┼─────────────────────┤
│ Safe to use  │  Yes, if HPA uses    │  Yes, if VPA manages │  Yes — CA reacts    │
│ together?    │  custom/external     │  CPU/mem and HPA     │  to HPA/VPA output; │
│              │  metrics (not CPU)   │  uses other metrics  │  no conflict        │
└──────────────┴──────────────────────┴──────────────────────┴─────────────────────┘
```

---

### 12. Typical Conflict: HPA + VPA on the Same Deployment

HPA and VPA should not both target **CPU or memory** on the same Deployment simultaneously.
They will fight:
- HPA adds replicas because average CPU is high
- VPA increases CPU requests per pod
- More CPU requested → pods are harder to schedule → CA adds nodes
- VPA increasing requests may lower the CPU *utilisation percentage* → HPA scales back down
- The loop repeats unpredictably

**Safe combinations:**

```
HPA on CPU/memory + VPA on CPU/memory  →  conflict (do not use)

HPA on custom metrics (req/s, queue)   →  safe (different signals, no conflict)
+ VPA on CPU/memory

HPA on anything + CA                   →  safe (CA just reacts to pending pods)

VPA + CA                               →  safe (VPA changes requests, CA responds
                                            to resulting scheduling pressure)

All three (HPA custom + VPA + CA)      →  safe and recommended for production:
                                            HPA: right pod count
                                            VPA: right pod size
                                            CA:  right node count
```

---

### 13. E2E Flows for Adapter-Dependent HPA Types

The following flows show the complete chain for each HPA metric type that requires
an adapter. Types `Resource` and `ContainerResource` (metrics-server, no adapter)
are not included — those are covered in the `01-hpa-basic` demo.

#### 13.1 `Pods` Type — Prometheus Adapter

```
Application pods → expose /metrics (Prometheus format)
        │ scrape every 15s
        ▼
Prometheus → stores http_requests_total time series per pod
        │ PromQL
        ▼
Prometheus Adapter (ConfigMap rule):
  seriesQuery:   http_requests_total{namespace!="",pod!=""}
  name:          → requests_per_second
  metricsQuery:  sum(rate(...[2m])) by (pod)
        │ custom.metrics.k8s.io
        ▼
kube-apiserver proxies GET /apis/custom.metrics.k8s.io/v1beta1/
  namespaces/default/pods/*/requests_per_second
        │
        ▼
HPA Controller:
  receives per-pod values [1200, 950, 800] req/s
  average = 983, target = 1000 → no change
  if average = 1500 → ceil[3 × (1500/1000)] = 5 replicas
```

#### 13.2 `Object` Type — Prometheus Adapter (Ingress example)

```
nginx-ingress-controller → exposes /metrics including
  nginx_ingress_controller_requests_total{ingress="main-ingress"}
        │ scrape
        ▼
Prometheus → stores the time series
        │ PromQL
        ▼
Prometheus Adapter (ConfigMap rule):
  seriesQuery:   nginx_ingress_controller_requests_total{ingress!=""}
  resources:     ingress label → networking.k8s.io/ingresses object
  name:          → requests_per_second
  metricsQuery:  sum(rate(...[2m]))   ← ONE value, not per-pod
        │ custom.metrics.k8s.io
        ▼
kube-apiserver proxies GET /apis/custom.metrics.k8s.io/v1beta1/
  namespaces/default/ingresses.networking.k8s.io/main-ingress/requests_per_second
        │
        ▼
HPA Controller:
  receives ONE value: 12,000 req/s
  target: 10,000 → ceil[3 × (12000/10000)] = 4 replicas

```
> **Critical design decision — `Value` vs `AverageValue` for Object type:**
> When using `target.type: Value`, the HPA compares the raw Ingress total directly
> to the target. Adding more backend pods does NOT reduce the Ingress total —
> traffic keeps arriving at the same rate. This means the HPA will keep scaling
> until it hits `maxReplicas`, because the metric never drops below the target
> just from adding pods.
>
> Use `target.type: AverageValue` instead to divide the total by the current pod
> count. This makes Object type behave like Pods type for the scaling math:
> adding a pod reduces the per-pod share of the total, which reduces the HPA's
> perceived demand and stabilises the replica count.
>
> ```yaml
> target:
>   type: AverageValue    # total Ingress req/s ÷ current pod count
>   averageValue: "3000"  # target 3000 req/s per backend pod
> ```

#### 13.3 `External` Type — KEDA SQS scaler (EKS)

```
AWS SQS queue "orders"
  ApproximateNumberOfMessages = 900
  CloudWatch records this automatically
        │ CloudWatch API
        ▼
KEDA Metrics Server (in kube-system):
  ScaledObject defines: SQS queue=orders, targetValue=30
  KEDA polls SQS/CloudWatch every 30s
        │ external.metrics.k8s.io
        ▼
kube-apiserver proxies GET /apis/external.metrics.k8s.io/v1beta1/
  namespaces/default/sqs_queue_depth?labelSelector=queue=orders
        │
        ▼
HPA Controller (created and managed by KEDA):
  current = 900, target = 30 per pod, current pods = 5
  desired = ceil[5 × (900/30)] = 150 → capped at maxReplicas

  Queue drains to 0:
  desired = 0 → KEDA scales to 0 (native HPA would floor at minReplicas=1)
```

---

### 14. Configuration Checklist — Prometheus Adapter Setup

For HPA `Pods` or `Object` metrics backed by Prometheus:

```
□ 1. Application pods expose /metrics in Prometheus exposition format

□ 2. Prometheus is scraping those pods
     verify: port-forward to Prometheus UI → query the metric series

□ 3. Prometheus Adapter installed and pointed at Prometheus service URL
     helm: prometheus-community/prometheus-adapter

□ 4. Adapter ConfigMap rule defines:
     a. seriesQuery  — which Prometheus series this rule covers
     b. resources    — maps Prometheus labels to Kubernetes resource names
     c. name.as      — the Custom Metrics API name HPA will reference
     d. metricsQuery — the PromQL query to run per HPA request

□ 5. APIService registered and healthy:
     kubectl get apiservices | grep custom.metrics
     → v1beta1.custom.metrics.k8s.io ... True

□ 6. Metric visible in the API:
     kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/ | jq .

□ 7. HPA metric name matches name.as in the adapter ConfigMap rule

□ 8. HPA status shows a current value (not <unknown>):
     kubectl describe hpa <name>
```

---

## Lab Step-by-Step Guide

---

### Step 1 — Deploy a Multi-Container Pod (App + Sidecar)

This Deployment runs two containers: `app` (nginx — the workload you care about) and `sidecar` (busybox, idle until told to burn CPU — standing in for a logging/metrics agent). Both containers have their own `resources.requests`, which is what makes per-container metrics possible.

**`src/01-deployment-sidecar.yaml`:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: multi-container-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: multi-container-app
  template:
    metadata:
      labels:
        app: multi-container-app
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        # Primary application container
        - name: app
          image: nginx:1.27
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "100m"      # ContainerResource HPA in Step 2 reads THIS container's usage
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"

        # Sidecar container — simulates a logging/monitoring agent
        - name: sidecar
          image: busybox:1.36
          command: ["sh", "-c", "sleep infinity"]
          resources:
            requests:
              cpu: "100m"      # has its own request — reports its own utilisation %
              memory: "32Mi"
            limits:
              cpu: "500m"
              memory: "64Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: multi-container-svc
spec:
  type: ClusterIP
  selector:
    app: multi-container-app
  ports:
    - port: 80
      targetPort: 80
```

```bash
cd 11-auto-scaling/02-hpa-advanced/src

kubectl apply -f 01-deployment-sidecar.yaml
kubectl rollout status deployment/multi-container-app
kubectl get pods -o wide
```

**Expected output:**
```
deployment "multi-container-app" successfully rolled out

NAME                                    READY   STATUS    NODE
multi-container-app-xxxxxxxxx-xxxxx     2/2     Running   3node-m02
```

```bash
kubectl top pod --containers
```

**Expected output:**
```
POD                                     NAME      CPU(cores)   MEMORY(bytes)
multi-container-app-xxxxxxxxx-xxxxx     app       0m           3Mi
multi-container-app-xxxxxxxxx-xxxxx     sidecar   0m           1Mi
```

```
# Observation: --containers breaks the pod-level totals down per container.
# "app" and "sidecar" report independent CPU/memory figures — this is the
# data ContainerResource will read from in Step 2.
```

---

### Step 2 — HPA with `ContainerResource`: Isolating the `app` Container

**`src/02-hpa-container-resource.yaml`:**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: app-hpa-container-resource
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: multi-container-app
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: ContainerResource       # targets ONE container, not the whole pod
      containerResource:
        name: cpu
        container: app              # only "app" container's CPU is measured
        target:
          type: Utilization
          averageUtilization: 50    # scale when "app" CPU > 50% of its request
```
⚡ **Imperative equivalent:** `kubectl autoscale deployment multi-container-app --min=1 --max=5 --cpu-percent=50`
— note this only generates `type: Resource`; `ContainerResource` has no imperative
equivalent and must always be written as YAML.

```bash
kubectl apply -f 02-hpa-container-resource.yaml
kubectl describe hpa app-hpa-container-resource | grep -A2 "Metrics:"
```

**Expected output:**
```
Metrics:
  resource cpu on container "app" (as a percentage of request):  0% (0m) / 50%
```

```
# Observation: "on container \"app\"" confirms this HPA is scoped to one
# container — unlike Resource's "on pods" wording from 01-hpa-basic.
```

**Burn CPU in the `sidecar` container — open a second terminal and run:**

```bash
kubectl exec deploy/multi-container-app -c sidecar -- \
  sh -c "while true; do dd if=/dev/urandom of=/dev/null bs=1M count=100; done"
```

**Watch per-container usage and the HPA in your first terminal:**

```bash
kubectl top pod --containers
kubectl get hpa app-hpa-container-resource -w
```

**Expected output:**
```
POD                                     NAME      CPU(cores)   MEMORY(bytes)
multi-container-app-xxxxxxxxx-xxxxx     app       0m           3Mi
multi-container-app-xxxxxxxxx-xxxxx     sidecar   850m         4Mi

NAME                        REFERENCE                       TARGETS       MINPODS  MAXPODS  REPLICAS
app-hpa-container-resource  Deployment/multi-container-app  cpu: 0%/50%   1        5        1
```

```
# Observation: sidecar CPU has spiked to ~850m, but the HPA's TARGETS
# for "app" stays at 0%/50% and REPLICAS stays at 1. ContainerResource
# is blind to sidecar load — by design.
```

**Stop the sidecar load (`Ctrl+C`), then burn CPU in `app` instead:**

```bash
kubectl exec deploy/multi-container-app -c app -- \
  sh -c "while true; do dd if=/dev/urandom of=/dev/null bs=1M count=100; done"

kubectl get hpa app-hpa-container-resource -w
```

**Expected output:**
```
NAME                        REFERENCE                       TARGETS          MINPODS  MAXPODS  REPLICAS
app-hpa-container-resource  Deployment/multi-container-app  cpu: <unknown>/50%  1     5        1
app-hpa-container-resource  Deployment/multi-container-app  cpu: 115%/50%    1        5        1
app-hpa-container-resource  Deployment/multi-container-app  cpu: 37%/50%     1        5        3
```

```
# Observation: the same load pattern that had no effect when applied to
# sidecar DOES trigger scaling now — because the load is in the container
# ContainerResource is actually watching.
```

**Cleanup:**
```bash
# Stop exec loop with Ctrl+C in the second terminal, then:
kubectl delete -f 02-hpa-container-resource.yaml
```

---

### Step 3 — HPA Behavior: `Percent`-Type Scaling Policies

**`src/03-hpa-behavior-percent.yaml`:**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: app-hpa-behavior-percent
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: multi-container-app
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: Resource                # pod-level, not ContainerResource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0  # scale up immediately (default)
      selectPolicy: Max
      policies:
        - type: Percent              # Percent, not Pods (compare with 01-hpa-basic Step 8)
          value: 100                 # double current replica count...
          periodSeconds: 30          # ...at most once per 30 seconds
    scaleDown:
      stabilizationWindowSeconds: 60
      selectPolicy: Max
      policies:
        - type: Percent
          value: 50                  # halve current replica count...
          periodSeconds: 60          # ...at most once per 60 seconds
```

```bash
kubectl apply -f 03-hpa-behavior-percent.yaml
kubectl describe hpa app-hpa-behavior-percent | grep -A8 "Behavior:"
```

**Expected output:**
```
Behavior:
  Scale Up:
    Stabilization Window: 0 seconds
    Select Policy: Max
    Policies:
      - Type: Percent  Value: 100  Period: 30 seconds
  Scale Down:
    Stabilization Window: 60 seconds
    Select Policy: Max
    Policies:
      - Type: Percent  Value: 50  Period: 60 seconds
```

**Burn CPU in `app`:**

**Burn CPU in `app`:**
```bash
kubectl exec deploy/multi-container-app -c app -- \
  sh -c "while true; do dd if=/dev/urandom of=/dev/null bs=1M count=100; done"
kubectl get hpa app-hpa-behavior-percent -w
```

> **Note:** `kubectl exec` against a Deployment always lands on exactly ONE
> pod — not every replica. As the HPA scales out, only this original pod
> carries any load; every new pod starts idle. Because `type: Resource`
> averages usage across ALL pods matching the target, each new idle pod
> dilutes the reported percentage. Expect doubling to accelerate initially,
> then decelerate and plateau well short of maxReplicas, rather than a
> clean run to 8 or 10.

**Real captured output (your exact numbers and timing will vary, but the shape will match):**
```
NAME                       REFERENCE                        TARGETS         MINPODS  MAXPODS  REPLICAS  AGE
app-hpa-behavior-percent   Deployment/multi-container-app   cpu: 0%/50%     1        10       1         2m30s
app-hpa-behavior-percent   Deployment/multi-container-app   cpu: 90%/50%    1        10       1         3m49s
app-hpa-behavior-percent   Deployment/multi-container-app   cpu: 90%/50%    1        10       2         4m2s
app-hpa-behavior-percent   Deployment/multi-container-app   cpu: 264%/50%   1        10       2         4m46s
app-hpa-behavior-percent   Deployment/multi-container-app   cpu: 264%/50%   1        10       4         5m1s
app-hpa-behavior-percent   Deployment/multi-container-app   cpu: 264%/50%   1        10       6         5m29s
app-hpa-behavior-percent   Deployment/multi-container-app   cpu: 132%/50%   1        10       6         5m43s
app-hpa-behavior-percent   Deployment/multi-container-app   cpu: 44%/50%    1        10       6         6m40s
```
```
# Observation: replicas double for the first two evaluations (1->2->4)
# while the metric stays pegged at 264% — the loaded pod's raw usage
# hasn't changed, but each new idle pod's request is added to the
# denominator, so the reported average keeps climbing toward (and past)
# the target ratio rather than staying flat. By replicas=6, dilution has
# pulled the average down to 44% — BELOW the 50% target — even though
# exactly one pod is still fully loaded. This is dilution, not throttling
# and not any stabilization effect.
```

**Find which pod is actually carrying the load, then stop it precisely:**
```bash
kubectl top pod -l app=multi-container-app --containers
```
```
POD                                    NAME      CPU(cores)   MEMORY(bytes)
multi-container-app-64d56889f5-4m764   app       0m           12Mi
multi-container-app-64d56889f5-5vlsc   app       0m           13Mi
multi-container-app-64d56889f5-dw7kh   app       0m           12Mi
multi-container-app-64d56889f5-g9d4g   app       0m           12Mi
multi-container-app-64d56889f5-hrqh7   app       528m         14Mi   <- this is the loaded pod
multi-container-app-64d56889f5-vcpds   app       0m           13Mi
```
```
# If every pod shows 0m, the metrics-server scrape window hasn't
# refreshed yet — wait ~15-30s and rerun.
```

> **Warning:** Pressing `Ctrl+C` on the `kubectl exec` session above does
> NOT reliably stop the loop — the client disconnecting does not signal
> the remote process, which keeps running in the background invisibly.
> Verify with `kubectl top pod` as above rather than trusting Ctrl+C.
> Also don't reach for `pkill`/`ps` inside the container — minimal images
> like `nginx:1.27` don't ship `procps`, so those commands fail with
> `executable file not found in $PATH`.

**Stop it by deleting only the specific loaded pod — no need to delete every pod:**
```bash
kubectl delete pod multi-container-app-64d56889f5-hrqh7   # use the pod name from YOUR OWN kubectl top output
```
```
pod "multi-container-app-64d56889f5-hrqh7" deleted from default namespace
```
```bash
kubectl top pod -l app=multi-container-app --containers
```
```
# Confirm every remaining pod shows 0m CPU before proceeding. If a
# different pod now shows load, repeat the identify-and-delete step
# for that one instead.
```

**Watch scale-down:**
```bash
kubectl get hpa app-hpa-behavior-percent -w
```
**Real captured output:**
```
NAME                       REFERENCE                        TARGETS       MINPODS  MAXPODS  REPLICAS  AGE
app-hpa-behavior-percent   Deployment/multi-container-app   cpu: 0%/50%   1        10       6         13m
app-hpa-behavior-percent   Deployment/multi-container-app   cpu: 0%/50%   1        10       6         14m
app-hpa-behavior-percent   Deployment/multi-container-app   cpu: 0%/50%   1        10       3         14m   <- -50% of 6, capped by the Percent policy
app-hpa-behavior-percent   Deployment/multi-container-app   cpu: 0%/50%   1        10       3         15m
app-hpa-behavior-percent   Deployment/multi-container-app   cpu: 0%/50%   1        10       1         15m   <- desired value (1, the minReplicas floor) reached directly
```
```
# Observation: the Deployment settled at 5 pods immediately after the
# delete — NOT back at 6 — because the ReplicaSet controller and the HPA
# controller both act on spec.replicas independently. By the time the
# ReplicaSet would normally have created a replacement for the deleted
# pod, the HPA had already started lowering spec.replicas toward its
# own (much smaller, post-dilution) desired count. Deleting a pod does
# NOT guarantee a same-count replacement if the HPA changes the target
# replica count around the same moment — the ReplicaSet reconciles
# toward whatever spec.replicas currently says, not toward "replace
# exactly what was deleted."
#
# The halving steps land on 6->3->1 rather than a clean 4->2->1: the
# scaleDown Percent policy caps the MAXIMUM removal per 60s window at
# ceil(currentReplicas * 0.5), but the actual step taken is whichever is
# LESS aggressive between that cap and the raw formula's desired value.
# At 3 replicas, the cap allows removing up to 2 (ceil(3*0.5)=2), and
# the desired value from 0% CPU is already 1 (the minReplicas floor) —
# so it drops straight to 1 in one step, rather than pausing at 2 first.
```

**Cleanup:**
```bash
kubectl delete -f 03-hpa-behavior-percent.yaml
```

---

### Step 4 — `selectPolicy: Min`: Conservative Scaling

This step demonstrates how `selectPolicy: Min` changes the scaling behaviour when two policies are defined. Instead of the most aggressive policy winning (Max), the least aggressive wins — useful when you want to cap burst scaling while still allowing gradual growth.

Add a second policy to the existing behavior block:

```yaml
# Modify src/03-hpa-behavior-percent.yaml — replace the behavior block:
behavior:
  scaleUp:
    stabilizationWindowSeconds: 0
    selectPolicy: Min              # ← changed from Max to Min
    policies:
      - type: Percent
        value: 100                 # doubles current count per 30s
        periodSeconds: 30
      - type: Pods
        value: 1                   # adds at most 1 pod per 15s
        periodSeconds: 15
  scaleDown:
    stabilizationWindowSeconds: 60
    selectPolicy: Max
    policies:
      - type: Percent
        value: 50
        periodSeconds: 60
```

```bash
kubectl apply -f 03-hpa-behavior-percent.yaml   # reapply with updated behavior

kubectl exec deploy/multi-container-app -c app -- \
  sh -c "while true; do dd if=/dev/urandom of=/dev/null bs=1M count=100; done"

kubectl get hpa app-hpa-behavior-percent -w
```

**Expected output:**
```
NAME                      REPLICAS
app-hpa-behavior-percent  1
app-hpa-behavior-percent  2   ← +1 (Pods policy wins — Min picks LEAST change)
app-hpa-behavior-percent  3   ← +1 (Pods: +1; Percent would be +100% of 2 = +2; Min picks +1)
app-hpa-behavior-percent  4   ← +1 (same logic — Pods wins at every step)
```

```
# Observation: with selectPolicy: Min, the Pods policy (value: 1) wins every cycle
# because it proposes less change (+1) than Percent (which doubles each time).
# Compare with Step 3 where selectPolicy: Max caused the doubling pattern (1→2→4→8).
# selectPolicy: Min gives controlled, linear growth even with an aggressive Percent policy defined.
```

```bash
kubectl delete -f 03-hpa-behavior-percent.yaml
```

---

### Step 5 — HPA Metric Type Decision Framework


| Metric type | API served by | Requires adapter? | Scope | Typical use case |
|---|---|---|---|---|
| `Resource` | metrics-server (`metrics.k8s.io`) | No | Whole pod (all containers) | CPU/memory, single-container pods |
| `ContainerResource` | metrics-server (`metrics.k8s.io`) | No | One named container | CPU/memory, multi-container pods with sidecars |
| `Pods` | metrics adapter (`custom.metrics.k8s.io`) | Yes | Averaged across pods of the target | App-level per-pod metric, e.g. requests/sec per pod |
| `Object` | metrics adapter (`custom.metrics.k8s.io`) | Yes | One named Kubernetes object | Total metric on a shared object, e.g. Ingress request rate |
| `External` | metrics adapter (`external.metrics.k8s.io`) | Yes | No Kubernetes object | Queue depth, external system load (SQS, Kafka, etc.) |

**Decision order:**

```
1. Scaling signal is CPU or memory?
     +-- Yes --> One container should be isolated from others?
                   +-- No  --> Resource
                   +-- Yes --> ContainerResource
                 (Neither requires anything beyond metrics-server)

2. App-level metric exposed per pod (e.g. requests/sec per pod)?
     +-- Yes --> Pods (requires adapter)

3. Single aggregate value from one Kubernetes object (e.g. Ingress total req rate)?
     +-- Yes --> Object (requires adapter)

4. Signal is external to Kubernetes entirely (queue depth, etc.)?
     +-- Yes --> External (requires adapter)
                 -- or KEDA if scale-to-zero is needed
```

**Practical takeaway:** `Resource`/`ContainerResource` cost nothing extra and should be the default whenever CPU/memory is a reasonable proxy for load. Reach for `Pods`/`Object`/`External` only when CPU/memory genuinely does not reflect demand — and budget for installing and maintaining a metrics adapter when you do.

---

### Step 6 — Cleanup

Steps 2 and 3 delete their own HPAs, but the Deployment and Service from Step 1 remain. Run this to return the cluster to its pre-lab state:

```bash
kubectl delete -f 01-deployment-sidecar.yaml --ignore-not-found
kubectl delete -f 02-hpa-container-resource.yaml --ignore-not-found
kubectl delete -f 03-hpa-behavior-percent.yaml --ignore-not-found

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
# Observation: unlike 01-hpa-basic Step 13 (uninstalling VPA), this lab
# installed nothing cluster-wide — metrics-server stays enabled for use
# by 03-vpa-fundamentals and later labs.
```

---

## What You Learned

In this lab, you:
- ✅ Deployed a multi-container pod and used `kubectl top pod --containers` to see per-container CPU/memory
- ✅ Configured `ContainerResource` to scale based on one container's CPU, isolating it from sidecar noise
- ✅ Demonstrated that `Resource`-type HPA averages across ALL containers, while `ContainerResource` does not
- ✅ Configured HPA `behavior` with `Percent`-type policies and observed the doubling/halving step pattern
- ✅ Compared `Percent`-type step sizes against `01-hpa-basic`'s `Pods`-type steps
- ✅ Explained the Custom Metrics API and the `Pods`/`Object` HPA metric types
- ✅ Explained the External Metrics API and metrics adapter architecture (Prometheus Adapter, CloudWatch adapter, KEDA)
- ✅ Built a decision framework covering all five HPA metric types

**Key Takeaway:** `Resource` and `ContainerResource` cover CPU/memory scaling with metrics-server alone — `ContainerResource` exists specifically to isolate one container's usage in a multi-container pod. `behavior` policies (`Pods` or `Percent`) are rate limiters on how fast the replica count moves toward the formula's desired value, never the scaling decision itself. Everything beyond CPU/memory — `Pods`, `Object`, `External` — requires a metrics adapter; Prometheus-based adapter hands-on is in Prometheus Adapter demos in this series, AWS-specific sources are in `aws-eks-demos`.

---

## Break-Fix

Three broken manifests below. For each: apply it, read the symptom from the cluster, diagnose, then reveal the answer. Each scenario ends with an explicit cleanup step — run it before starting the next scenario.

From here on, all commands in this section assume you're working from inside the `break-fix/` directory:
```bash
cd break-fix/
```

---

### Error-1

**`src/break-fix/01-wrong-container-name.yaml`:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: app-hpa-container-resource
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: multi-container-app
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: ContainerResource
      containerResource:
        name: cpu
        container: nginx              # BUG: no container named "nginx" —
                                      # the actual container is named "app"
        target:
          type: Utilization
          averageUtilization: 50
```

```bash
kubectl apply -f ../01-deployment-sidecar.yaml
kubectl apply -f 01-wrong-container-name.yaml
kubectl describe hpa app-hpa-container-resource
```

What do you observe in the Metrics and Conditions sections? Why?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
Metrics:
  resource cpu on container "nginx" (as a percentage of request): <unknown> / 50%

Conditions:
  ScalingActive: False  FailedGetResourceMetric
```

**Cause:** `containerResource.container` is set to `nginx`, but the pod's actual container is named `app`. The HPA controller cannot find a container named `nginx`, so the metric can never be populated.

**Fix:** Change `container: nginx` to `container: app`, then `kubectl apply` again.

**Cascade:** While `ScalingActive: False`, the HPA never scales the Deployment regardless of load — `REPLICAS` stays frozen at whatever it was when the HPA was created.

</details>

**Cleanup:**
```bash
kubectl delete -f 01-wrong-container-name.yaml --ignore-not-found
```
(the `multi-container-app` Deployment stays running — it's reused as-is by Error-2)

---

### Error-2 

**`src/break-fix/02-stuck-scale-up-stabilization.yaml`:**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: app-hpa-behavior-percent
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: multi-container-app
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
      stabilizationWindowSeconds: 300  # BUG: scale-down default copy-pasted into
                                       # scaleUp — valid YAML, no error at apply time
      selectPolicy: Max
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 60
      selectPolicy: Max
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
```

```bash
kubectl apply -f 02-stuck-scale-up-stabilization.yaml
kubectl exec deploy/multi-container-app -c app -- \
  sh -c "while true; do dd if=/dev/urandom of=/dev/null bs=1M count=100; done"
# wait ~2 minutes, then:
kubectl get hpa app-hpa-behavior-percent
kubectl describe hpa app-hpa-behavior-percent | grep -A8 "Behavior:"
```

The metric shows high CPU but `REPLICAS` has not moved after 2 minutes. `kubectl apply` produced no error. What is wrong?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
Metrics:
  resource cpu on pods (as a percentage of request): 115% (115m) / 50%

Behavior:
  Scale Up:
    Stabilization Window: 300 seconds   <- should be 0 for immediate scale-up
```

**Cause:** `scaleUp.stabilizationWindowSeconds: 300` is the scale-down default, copy-pasted into the `scaleUp` block by mistake. This is valid YAML and applies cleanly with no error. The HPA correctly computes that more replicas are needed but the stabilisation window forces it to wait 5 minutes before acting — exactly as it would for a scale-down.

**Fix:** Set `behavior.scaleUp.stabilizationWindowSeconds` to `0` (or remove the key — `0` is the scale-up default).

**Cascade:** Under sustained load, the Deployment under-serves traffic for up to 5 minutes after every load increase. Easy to misdiagnose as "the load generator is not working" or "metrics-server is slow" — nothing in the cluster reports an error.

</details>

**Cleanup:**
```bash
# stop the CPU load loop first — Ctrl+C the kubectl exec session from above
kubectl delete -f 02-stuck-scale-up-stabilization.yaml --ignore-not-found
kubectl delete -f ../01-deployment-sidecar.yaml --ignore-not-found
```

---

### Error-3  

**`src/break-fix/03-deployment-missing-request.yaml`:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: multi-container-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: multi-container-app
  template:
    metadata:
      labels:
        app: multi-container-app
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: app
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

        - name: sidecar
          image: busybox:1.36
          command: ["sh", "-c", "sleep infinity"]
          resources:
            requests:
              memory: "32Mi"    # BUG: cpu request missing on this container
            limits:
              cpu: "500m"
              memory: "64Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: multi-container-svc
spec:
  type: ClusterIP
  selector:
    app: multi-container-app
  ports:
    - port: 80
      targetPort: 80
```

```bash
kubectl apply -f 03-deployment-missing-request.yaml
kubectl apply -f ../03-hpa-behavior-percent.yaml
# wait ~1 minute, then:
kubectl describe hpa app-hpa-behavior-percent | grep -A2 "Metrics:"
kubectl top pod --containers
```

`kubectl top pod --containers` shows `app` reporting CPU usage normally. What does the HPA's metric show, and why?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
Metrics:
  resource cpu on pods (as a percentage of request): <unknown> / 50%
```

**Cause:** The `sidecar` container's `resources.requests` block has no `cpu` field. For `type: Resource`, every container in the pod must have a CPU request — usage / request, summed across containers. With one container missing its CPU request, the denominator cannot be computed and the entire pod's metric becomes `<unknown>`, even though `app` has a valid request and reports usage via `kubectl top`.

**Fix:** Add `resources.requests.cpu` to the `sidecar` container (e.g. `cpu: "100m"`, matching `01-deployment-sidecar.yaml`).

**Cascade:** Same root cause as `01-hpa-basic`'s documented `<unknown>` troubleshooting entry — but here it is caused by ONE container out of several, easy to miss when skimming a multi-container manifest.

</details>

**Cleanup:**
```bash
kubectl delete -f 03-deployment-missing-request.yaml --ignore-not-found
kubectl delete -f ../03-hpa-behavior-percent.yaml --ignore-not-found
cd ..
```

---

## Interview Prep

**Q1. You have a pod with an `app` container and a `sidecar` that occasionally spikes CPU for log shipping. You configured an HPA with `type: Resource` targeting CPU at 50%. During a log-shipping burst, the Deployment scales up even though `app`'s own load has not changed. What is happening, and how would you fix it?**

`Resource`-type utilisation is computed across ALL containers — usage summed and divided by requests summed. The sidecar's CPU spike raises the pod-level percentage and can push it past the target, triggering a scale-up driven by sidecar activity rather than application demand. Fix: switch the HPA metric to `type: ContainerResource` with `containerResource.container: app` — measures only the `app` container's CPU, ignores the sidecar entirely. Requires Kubernetes >= v1.30 for GA support and works with metrics-server alone, no adapter needed.

**Q2. An HPA has `maxReplicas: 10` and a `scaleUp` policy of `{type: Percent, value: 100, periodSeconds: 30}`. The metric currently justifies 8 desired replicas and the Deployment is at 1. How long does it take to reach 8, and why not instantly?**

`Percent` behavior policies cap the per-period step as a percentage of the current replica count, not a direct jump to the desired value: 1->2 (first 30s, +100% of 1), 2->4 (next 30s), 4->8 (next 30s) — roughly 90 seconds across three evaluation windows. This rate-limiting prevents a single noisy metric spike from instantly multiplying fleet size. The desired value is still recalculated every cycle, so if the metric drops back mid-ramp, the climb stops early.

**Q3. `kubectl describe hpa` shows `resource cpu on pods (as a percentage of request): <unknown> / 50%`, but `kubectl top pod` shows the main container using CPU normally. What is the most likely cause, and how do you confirm it?**

For `type: Resource`, every container in the pod must have `resources.requests.cpu` set. If even one container is missing it, the entire pod-level CPU metric becomes `<unknown>` — not just that container's contribution. Confirm with `kubectl describe deployment <name> | grep -A4 Requests` for each container and add the missing `requests.cpu`. This is distinct from "wait 30-60s for metrics to populate" — a missing request never resolves itself.

**Q4. Your team wants to scale a worker Deployment based on AWS SQS queue depth. Which HPA metric type, and what must exist in the cluster beyond metrics-server?**

`type: External`, reading `sqs_queue_depth` from `external.metrics.k8s.io`. metrics-server never serves this API — you need a metrics adapter that translates "SQS queue `orders`" into a value the HPA controller can query: a CloudWatch-based adapter (`k8s-cloudwatch-adapter`) or KEDA. KEDA also supports scaling to zero when the queue is empty — something `External`-type HPA alone cannot do since `minReplicas` must be >= 1.

**Q5. What is the practical difference between the `Pods` and `Object` HPA metric types, given that both read from the Custom Metrics API?**

`Pods` is a per-pod metric, averaged: the adapter reports a value per pod of the scale target, the HPA averages them and compares to `target.averageValue` — same formula shape as `Resource`. `Object` is a single value from one named Kubernetes object via `describedObject`, compared directly to `target.value` with no per-pod averaging — e.g. an Ingress's total request rate. Using them interchangeably causes either over-scaling (treating an aggregate Object value as if it were per-pod) or a metric that never changes with replica count (treating a shared aggregate as a Pods metric).

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Demo concept / command | CKA objective | CKAD objective | Notes |
|---|---|---|---|
| `ContainerResource` metric type | Workloads & Scheduling (15%) | Application Deployment (20%) | GA since v1.30; permanently `<unknown>` on older clusters is a version gap, not a config error |
| `behavior` with `Percent`-type policies | Workloads & Scheduling (15%) | Application Deployment (20%) | Task may define a partial `behavior` block and require the resulting replica count after N periods |
| `kubectl top pod --containers` | Troubleshooting (30%) | Application Observability and Maintenance (15%) | Per-container resource diagnosis — the step before choosing `Resource` vs `ContainerResource` |
| `<unknown>` metric caused by ONE container missing a request | Troubleshooting (30%) | Application Environment, Configuration and Security (25%) | Whole-pod metric goes `<unknown>`, not just that container's share — same mechanism as Demo 01, harder to spot in a multi-container manifest |
| Custom/External Metrics API concept (`Pods`/`Object`/`External`) | Workloads & Scheduling (15%) | Application Deployment (20%) | Adapter installation/configuration is generally out of scope for either exam — concept-level only |
| Metric-type decision framework | Workloads & Scheduling (15%) | Application Deployment (20%) | Task may present a scaling scenario and require identifying which metric type applies |

### Common Exam Traps

| Scenario | What the task actually requires | Common wrong approach |
|---|---|---|
| Task's pod has an `app` container and a `sidecar`; after applying a `Resource`-type HPA, a burst of sidecar activity causes an unwanted scale-out | Recognize `Resource` averages usage across all containers, and switch to `ContainerResource` scoped to `container: app` to isolate the signal | Raising `maxReplicas` to "absorb" the noise, or removing the sidecar, instead of switching metric type |
| Task defines `behavior.scaleUp` with a `Percent` policy of `value: 100` and expects the Deployment to jump straight from 1 replica to the formula's desired count of 8 in one evaluation | Understand `Percent` policies cap the step at 100% of the *current* count per period — reaching 8 from 1 takes multiple periods (1→2→4→8), not one | Concluding the behavior policy is broken because the jump isn't immediate, and removing the `behavior` block entirely |
| Task's 2-container pod has `resources.requests.cpu` on `app` but not on `sidecar`; the HPA metric shows `<unknown>` even though `kubectl top pod` shows `app`'s usage fine | Recognize that for `Resource`-type HPA, ANY container missing a CPU request makes the WHOLE pod's metric `<unknown>` — add the missing request to `sidecar`, not just double-check `app` | Assuming the metric is partially working because `app` clearly has a valid request, and looking elsewhere (metrics-server health, HPA YAML) for the fault |
| Task asks to scale on a metric that isn't CPU or memory, and the first instinct is to reach for a metrics adapter as step one | Recognize `ContainerResource` (like `Resource`) is served by metrics-server alone — no adapter needed; adapters are only required for `Pods`/`Object`/`External` types | Assuming any non-`Resource` metric type automatically needs a custom metrics adapter, including `ContainerResource` |

### Exam Task — Write it from scratch

**Task:** From scratch (no copy-paste), write an HPA that:
- Targets a Deployment named `web`, container named `api` (one of several containers in the pod)
- Scales on that container's CPU only, target 60% utilization
- Allows scale-up by at most 50% of current replicas per 30 seconds
- Allows scale-down by at most 2 pods per 60 seconds
- minReplicas: 2, maxReplicas: 8

<details>
<summary>Reference solution</summary>

\```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: ContainerResource
      containerResource:
        name: cpu
        container: api
        target:
          type: Utilization
          averageUtilization: 60
  behavior:
    scaleUp:
      policies:
        - type: Percent
          value: 50
          periodSeconds: 30
    scaleDown:
      policies:
        - type: Pods
          value: 2
          periodSeconds: 60
\```
</details>

Key fields to recall: `containerResource.container` (easy to forget vs plain `resource`),
and that `behavior` policies are independent step-size caps per direction — mixing `Percent`
(scale-up) and `Pods` (scale-down) in the same object is valid.

---

## Key Takeaways

| Concept | Detail |
|---|---|
| `ContainerResource` vs `Resource` | `ContainerResource` measures ONE named container's CPU/memory; `Resource` averages across ALL containers — sidecar load can trigger unwanted `Resource`-type scaling. |
| `ContainerResource` API stability | GA since Kubernetes v1.30 in `autoscaling/v2`. On older clusters a permanently `<unknown>` metric may be a version gap, not a config error. |
| `kubectl describe hpa` wording | `ContainerResource` shows `resource cpu on container "X" (as a percentage of request)`; `Resource` shows `resource cpu on pods (as a percentage of request)`. |
| `behavior` policies are step-size limits | `Pods`-type and `Percent`-type policies cap how fast the replica count moves toward the formula-computed desired value — neither sets it directly. |
| `Percent` scaleUp math | `value: 100` allows the replica count to increase by at most 100% of the current count per `periodSeconds` window (1->2->4->8, not 1->8). |
| `Percent` scaleDown math | `value: 50` allows the replica count to decrease by at most 50% of the current count per `periodSeconds` window. |
| `Pods` vs `Percent` growth shape | `Pods`-type steps are linear (fixed absolute size); `Percent`-type steps grow with current fleet size — `Percent` overtakes `Pods` at larger replica counts. |
| Copy-paste stabilisation window risk | `scaleUp.stabilizationWindowSeconds: 300` is valid YAML, applies cleanly, produces no error — but silently makes scale-up as slow as scale-down. |
| `<unknown>` on `Resource`-type HPA | If ANY container is missing a `resources.requests` entry for the measured resource, the WHOLE pod's metric becomes `<unknown>`. |
| `kubectl top pod --containers` | Breaks pod-level CPU/memory totals down per container — the diagnostic step before choosing `Resource` vs `ContainerResource`. |
| Custom Metrics API | `custom.metrics.k8s.io` — backs `Pods` and `Object` HPA types; requires a metrics adapter. metrics-server never serves it. |
| External Metrics API | `external.metrics.k8s.io` — backs the `External` HPA type, for metrics with no associated Kubernetes object (e.g. SQS queue depth). Also requires an adapter. |
| `Pods` vs `Object` | `Pods`: per-pod metric, averaged across pods (like `Resource`'s shape). `Object`: single metric from one named Kubernetes object via `describedObject`, compared directly — no per-pod averaging. |
| metrics-server scope | metrics-server only serves `metrics.k8s.io` (used by `Resource`/`ContainerResource`). It has no role in Custom or External Metrics APIs. |
| Adapter examples | Prometheus Adapter (generic, PromQL-based) — hands-on in Prometheus Adapter demos in this series. KEDA and CloudWatch-based adapters (AWS-native) — hands-on in `aws-eks-demos`. CloudWatch Metrics Adapter is archived; prefer KEDA SQS scaler for new AWS setups. |
| Metric type decision order | Prefer `Resource`/`ContainerResource` (no extra components) for CPU/memory; reach for `Pods`/`Object`/`External` only when the signal is application-level or external. |
| Scale-to-zero | `External`-type HPA cannot scale below `minReplicas: 1`. KEDA can scale to zero because it manages the scale-from-zero transition itself. |

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get hpa` | List all HPAs — TARGETS, MINPODS, MAXPODS, REPLICAS |
| `kubectl describe hpa <name>` | Full HPA status — metrics, conditions, behavior, events |
| `kubectl get hpa <name> -w` | Watch HPA scaling decisions in real time |
| `kubectl get hpa <name> -o yaml` | Full YAML including current status |
| `kubectl top pod --containers` | Per-container CPU/memory — diagnose Resource vs ContainerResource |
| `kubectl exec deploy/<name> -c <container> -- sh -c "..."` | Run a command in one specific container |
| `kubectl describe hpa <name> \| grep -A8 "Behavior:"` | Inspect configured scale-up/scale-down policies |
| `kubectl describe hpa <name> \| grep -A2 "Metrics:"` | Quick check of current vs target metric value |

### Generating YAML skeletons with --dry-run

```bash
kubectl create deployment multi-container-app --image=nginx:1.27 --dry-run=client -o yaml > deploy.yaml
kubectl autoscale deployment multi-container-app --min=1 --max=5 --cpu-percent=50 --dry-run=client -o yaml
```

**Not supported for this demo's key objects:** `ContainerResource`/`behavior` fields have
no imperative flags — `kubectl autoscale` only generates a basic `type: Resource` HPA.
Any HPA needing `ContainerResource` or `behavior` policies must be hand-written or
hand-edited from the generated skeleton.

### Imperative Quick-Create Commands

| Object | Imperative command | Notes |
|---|---|---|
| Deployment | `kubectl create deployment NAME --image=IMG` | Multi-container pods still require manual YAML editing |
| HPA (basic) | `kubectl autoscale deployment NAME --min=N --max=N --cpu-percent=N` | Only produces `type: Resource`; `ContainerResource`/`behavior` require YAML |

---

## Troubleshooting

**`ContainerResource` metric stays `<unknown>` indefinitely (container name is correct):**
```bash
kubectl version --short
# ContainerResource requires Kubernetes >= v1.30 for GA support.
# On older clusters it may not be recognised — this is a version gap,
# not a manifest error.
```

**HPA shows `ScalingLimited: True TooManyReplicas`:**
```bash
kubectl describe hpa <name> | grep -A3 Conditions
# Expected, not an error — the HPA wants more replicas but maxReplicas
# is capping it. Raise maxReplicas if more capacity is genuinely needed.
```

**`Pods`/`Object`/`External` metric shows `<unknown>` and never resolves:**
```bash
kubectl get apiservices | grep metrics
# custom.metrics.k8s.io and external.metrics.k8s.io must be registered
# by a metrics adapter. metrics-server alone does NOT serve these —
# see ## Kubernetes Scaling — API & Adapter Reference in this README.
```

**Two HPAs targeting the same Deployment:**
```bash
kubectl get hpa
# More than one HPA on the same scaleTargetRef causes ambiguous
# scaling decisions. Delete the extra one — one HPA per workload,
# same rule as 01-hpa-basic.
```

**`kubectl exec ... dd` loop does not raise CPU usage:**
```bash
kubectl exec deploy/multi-container-app -c <container> -- which dd sh
# Confirm both binaries exist. busybox (sidecar) and nginx:1.27
# (app, Debian-based) both include dd and sh. If missing, use
# "cat /dev/urandom > /dev/null" as an alternative.
```

---

## Appendix — Anki Cards

**`02-hpa-advanced-anki.csv`:**

```
#deck:k8s-platform-labs::11-auto-scaling::02-hpa-advanced
#separator:Comma
#columns:Front,Back,Tags
"You have a pod with an app container and a sidecar. You apply an HPA with type: Resource targeting CPU, and the sidecar starts using heavy CPU. What happens, and why?","The HPA may scale up even though app load has not changed. Resource type sums CPU usage across ALL containers vs the sum of their requests — the sidecar spike raises pod-level utilisation and can trigger scaling driven by sidecar activity, not app demand.","02-hpa-advanced,hpa,containerresource"
"How do you configure an HPA to scale based only on the app container CPU, ignoring a noisy sidecar?","Use type: ContainerResource with containerResource.container: app (plus name: cpu and a target block). Stable since Kubernetes v1.30, works with metrics-server alone — no adapter needed.","02-hpa-advanced,hpa,containerresource,syntax"
"What does kubectl describe hpa show in the Metrics section for a ContainerResource HPA vs a Resource HPA?","ContainerResource: resource cpu on container app (as a percentage of request): X% / 50%. Resource: resource cpu on pods (as a percentage of request): X% / 50%. The wording difference confirms which scope the metric covers.","02-hpa-advanced,hpa,containerresource,commands"
"An HPA has behavior.scaleUp.policies: [{type: Percent, value: 100, periodSeconds: 30}]. Metric suggests desired 8 replicas, current is 1. After the first 30-second evaluation, how many replicas?","2 — not 8. A Percent policy caps the step at 100% of the CURRENT replica count per period (1 to 2). Reaching 8 takes multiple periods: 1, 2, 4, 8.","02-hpa-advanced,hpa,behavior,percent"
"01-hpa-basic scaleUp policy was {type: Pods, value: 4, periodSeconds: 15}. Starting from 1 replica with high demand, how does its growth pattern differ from Percent value: 100?","Pods value: 4 is linear — adds at most 4 per period (1, 5, 9...). Percent value: 100 is relative — at most doubles per period (1, 2, 4, 8...). Percent grows faster at large replica counts, slower at small ones.","02-hpa-advanced,hpa,behavior,percent,pods"
"behavior.scaleUp.stabilizationWindowSeconds is set to 300. Manifest applies with no errors. HPA metric shows high CPU but replica count does not increase for 5 minutes. What is wrong?","300 is the scale-down default copy-pasted into scaleUp by mistake. Valid YAML, applies cleanly, no error message. Fix: set scaleUp.stabilizationWindowSeconds to 0 (the scale-up default) or remove it.","02-hpa-advanced,break-fix,behavior"
"kubectl describe hpa shows resource cpu on pods: unknown / 50%. kubectl top pod shows the main container using CPU normally. Most likely cause?","At least one container in the pod is missing resources.requests.cpu. For Resource-type HPA, if ANY container lacks the cpu request the WHOLE pod metric becomes unknown — not just that container's share. Confirm with kubectl describe deployment for every container's Requests block.","02-hpa-advanced,break-fix,unknown-metric"
"What command shows per-container CPU and memory within a multi-container pod, not just pod-level totals?","kubectl top pod --containers — breaks down kubectl top pod output by container, essential for diagnosing whether an HPA should use Resource or ContainerResource.","02-hpa-advanced,commands,diagnostics"
"What is the Custom Metrics API, and which HPA metric types depend on it?","custom.metrics.k8s.io — an API group HPA queries for application-level metrics not provided by metrics-server. The Pods and Object HPA metric types both read from this API and require a metrics adapter (e.g. Prometheus Adapter). metrics-server does not serve it.","02-hpa-advanced,custom-metrics-api"
"What is the difference between the Pods and Object HPA metric types, given both use the Custom Metrics API?","Pods: per-pod custom metric averaged across all pods of the target — HPA divides total demand by per-pod target. Object: single metric read from one specific Kubernetes object (e.g. total Ingress request rate) compared directly against the target — no per-pod averaging.","02-hpa-advanced,custom-metrics-api,pods-object"
"What is the External Metrics API, and give an example use case for the External HPA metric type.","external.metrics.k8s.io — an API group for metrics with NO associated Kubernetes object. Example: scaling a worker Deployment based on AWS SQS queue depth exposed via a metrics adapter.","02-hpa-advanced,external-metrics-api"
"Does metrics-server have any role in serving the Custom Metrics API or External Metrics API?","No. metrics-server only serves metrics.k8s.io (used by Resource and ContainerResource). custom.metrics.k8s.io and external.metrics.k8s.io are served entirely by separately-installed metrics adapters.","02-hpa-advanced,custom-metrics-api,external-metrics-api,metrics-server"
"Name two metrics adapter examples and where their hands-on setup is covered.","Prometheus Adapter (generic, PromQL-based) — hands-on in later Prometheus Adapter demos in this series (minikube). KEDA and CloudWatch-based adapters (AWS-native) — hands-on in aws-eks-demos. Note: CloudWatch Metrics Adapter is archived; KEDA SQS scaler is the recommended replacement.","02-hpa-advanced,adapters,forward-reference"
"Does ContainerResource require a custom metrics adapter like Pods/Object/External do?","No. ContainerResource, like Resource, is served by metrics-server alone. Only Pods, Object, and External require a separate adapter.","02-hpa-advanced,containerresource,metrics-server"
"Which HPA metric type should you reach for first when scaling on CPU or memory, and why?","Resource (or ContainerResource if one container's usage should be isolated) — both work with metrics-server alone, no extra components. Reach for Pods/Object/External only when the scaling signal is application-level or external.","02-hpa-advanced,decision-framework"
"A multi-container pod has app (web server) and sidecar (log shipping spikes). You want HPA to scale on web server load only. Which type and which field identifies the target container?","ContainerResource, with containerResource.container: app (plus name: cpu and a target block).","02-hpa-advanced,containerresource,syntax"
"(CKA) An HPA behavior.scaleUp.policies includes {type: Percent, value: 100, periodSeconds: 30}. True or false: load justifying 8 replicas brings the Deployment to 8 within the first 30-second evaluation.","False. Percent policies cap the step relative to the CURRENT count, not the desired one. From 1 replica, first window allows at most 1 to 2; reaching 8 takes multiple windows (1, 2, 4, 8).","02-hpa-advanced,cka-domain2,percent"
"(CKA) kubectl describe hpa reports unknown for a Resource-type CPU metric on a 2-container pod. One container has resources.requests.cpu set; the other does not. What is the pod metric value and why?","unknown for the whole pod — not partial. Resource-type HPA requires a CPU request on EVERY container; if any container lacks it the entire metric is unavailable.","02-hpa-advanced,cka-domain5,unknown-metric"
```

---

## Appendix — Quiz

**`02-hpa-advanced-quiz.md`:**

````
# Quiz — 11-auto-scaling/02-hpa-advanced: HPA Advanced — ContainerResource, Percent Behavior, and the Custom/External Metrics Pipeline

> One correct answer per question unless stated otherwise.
> Target: 7/8 or above before moving to next demo.

**Q1. You have a 2-container pod (`app` + `sidecar`) and apply an HPA with `type: Resource` targeting CPU. The `sidecar` starts consuming significant CPU. What is the risk?**

- A) None — sidecar containers are excluded from Resource-type metrics automatically
- B) The HPA may scale the Deployment based on the sidecar's load, not just app's load
- C) The HPA fails with a MultipleContainers error
- D) Resource type can only be used on single-container pods

<details>
<summary>Answer</summary>

**B** — Resource type sums CPU across ALL containers vs the sum of their requests; a noisy sidecar can drive scaling unrelated to application load. Use ContainerResource to isolate one container.

Trap A: no automatic exclusion — sidecars are included. Trap C: no such error exists. Trap D: Resource works on multi-container pods, just averaged across all containers.

</details>

---

**Q2. You want an HPA to scale based ONLY on the `app` container's CPU in a 2-container pod. Which `metrics[]` entry is correct?**

- A) {type: Resource, resource: {name: cpu, container: app, target: {...}}}
- B) {type: ContainerResource, containerResource: {name: cpu, container: app, target: {...}}}
- C) {type: Pods, pods: {metric: {name: app_cpu}, target: {...}}}
- D) {type: Resource, resource: {name: cpu, target: {...}}, selector: {matchLabels: {container: app}}}

<details>
<summary>Answer</summary>

**B** — ContainerResource is the dedicated type for targeting a single named container's CPU/memory.

Trap A: Resource has no container field — always covers the whole pod. Trap C: Pods is for custom application metrics via an adapter. Trap D: resource blocks have no selector field for filtering containers.

</details>

---

**Q3. An HPA's `behavior.scaleUp` has `{policies: [{type: Percent, value: 100, periodSeconds: 30}], stabilizationWindowSeconds: 0}`. Starting at 1 replica, the metric immediately justifies 8 replicas. After the first 30-second evaluation, what is the replica count?**

- A) 8 — Percent policies do not limit the jump to the formula's desired value
- B) 1 — value: 100 means scale-up is disabled
- C) 2 — the step is capped at 100% of the current replica count
- D) 0 — Percent requires minReplicas: 0 to function

<details>
<summary>Answer</summary>

**C** — Percent caps the step at 100% of the CURRENT count: 100% of 1 = +1, so 1->2. Reaching 8 takes multiple 30-second windows.

Trap A: the policy is a rate limiter, not a pass-through. Trap B: value: 100 means can double, not disabled. Trap D: Percent has no relationship to minReplicas: 0.

</details>

---

**Q4. 01-hpa-basic's scaleUp policy was `{type: Pods, value: 4, periodSeconds: 15}`. This lab's is `{type: Percent, value: 100, periodSeconds: 30}`. Starting from 10 replicas with sustained high demand, which adds more replicas in the first 30 seconds?**

- A) The Pods policy — up to 8 replicas (4 per 15s x 2 windows) vs Percent's +10
- B) The Percent policy — up to 10 replicas (100% of 10) vs Pods' +8
- C) They are identical — both capped at 4 replicas per evaluation
- D) Neither — periodSeconds must match to compare them

<details>
<summary>Answer</summary>

**B** — at 10 replicas, Percent value: 100 allows +10 (doubling) within 30s; Pods allows at most 4+4=8 over two 15s windows. Percent scales faster at larger replica counts.

Trap A: Pods arithmetic is correct but the conclusion is wrong. Trap C: the types use different units. Trap D: wall-clock outcomes can be compared without matching periodSeconds.

</details>

---

**Q5. A 2-container pod has `app` with `resources.requests.cpu: 100m` and `sidecar` with no `resources.requests` block. An HPA with `type: Resource` targeting cpu is applied. What does `kubectl describe hpa` show for the CPU metric?**

- A) The utilisation of app only, since it is the only container with a request
- B) unknown for the whole pod's CPU metric
- C) 0%, since the missing request is treated as zero
- D) The HPA fails to create with a validation error

<details>
<summary>Answer</summary>

**B** — for Resource-type HPA, ALL containers must have a request for the measured resource. If any is missing, the entire pod-level metric is unknown.

Trap A: no per-container fallback for Resource type. Trap C: missing request is not treated as 0m. Trap D: HPA creation succeeds, but the metric stays unknown.

</details>

---

**Q6. Which statement correctly distinguishes the `Pods` and `Object` HPA metric types?**

- A) Pods reads from metrics-server; Object reads from the Custom Metrics API
- B) Pods averages a custom metric across all pods of the target; Object reads a single metric from one specific Kubernetes object
- C) Object is for CPU/memory; Pods is for everything else
- D) They are interchangeable — both compute the same value with different syntax

<details>
<summary>Answer</summary>

**B** — Pods divides total per-pod demand by a per-pod target (averaged); Object compares one value from a named object directly against a target — no per-pod averaging.

Trap A: BOTH read from custom.metrics.k8s.io — metrics-server serves neither. Trap C: neither type is for CPU/memory. Trap D: averaging behaviour differs significantly.

</details>

---

**Q7. Your team wants to scale a worker Deployment based on the depth of an AWS SQS queue. Which combination is correct?**

- A) type: Resource, since SQS depth is a resource metric
- B) type: External, reading from external.metrics.k8s.io, exposed via a metrics adapter
- C) type: Object, since SQS is a Kubernetes object
- D) metrics-server alone, once kubectl top is enabled

<details>
<summary>Answer</summary>

**B** — SQS queue depth has no associated Kubernetes object and is not CPU/memory, so it is an External metric served via external.metrics.k8s.io by an adapter (CloudWatch-based adapter or KEDA).

Trap A: Resource is strictly CPU/memory from metrics-server. Trap C: SQS queues are not Kubernetes objects. Trap D: metrics-server never serves external/custom metrics.

</details>

---

**Q8. (CKA-style) A Deployment's pods each run a single container. You want to scale based on that container's memory usage and metrics-server is running. Which metric type requires the LEAST additional setup?**

- A) External, since it is the most flexible
- B) Object, targeting the Deployment itself
- C) Resource, with name: memory
- D) Pods, with a custom memory metric

<details>
<summary>Answer</summary>

**C** — for a single-container pod, Resource with name: memory works directly off metrics-server with zero extra components.

Trap A: External requires an adapter. Trap B: Object targeting the Deployment is not how memory-per-pod scaling works. Trap D: Pods requires a custom metrics adapter — unnecessary when metrics-server already provides memory data.

</details>

---

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read relevant section, retry those questions |
| Below 6/8 | Re-read full lab and redo walkthrough before proceeding |
````