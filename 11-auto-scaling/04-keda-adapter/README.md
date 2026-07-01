## What This Lab Adds

| Topic | Prior demos | `04-keda-adapter` |
|---|---|---|
| KEDA overview (role, scale-to-zero, adapter) | `01-hpa-basic` brief; `02-hpa-advanced` §10 theory | ✅ full architecture + hands-on |
| ScaledObject CRD | Not covered | ✅ |
| ScaledJob CRD | Not covered | ✅ |
| TriggerAuthentication / ClusterTriggerAuthentication | Not covered | ✅ |
| KEDA + HPA relationship (KEDA creates/manages HPA) | `02-hpa-advanced` 1 line | ✅ deep explanation |
| Scale-from-zero mechanics | Not covered | ✅ |
| Prometheus scaler (minikube) | Not covered hands-on | ✅ Steps 1–3 |
| Redis scaler (minikube) | Not covered | ✅ Steps 4–5 |
| Cron scaler (minikube) | Not covered | ✅ Step 6 |
| SQS scaler (EKS) | `02-hpa-advanced` E2E flow theory | Theory only — `aws-eks-demos` for hands-on |

---

## Lab Overview

`01-hpa-basic` showed that HPA's `minReplicas` must be ≥ 1 — it cannot scale to zero. For event-driven workloads like message queue consumers, running idle workers 24/7 waiting for work that may not arrive for hours is pure waste. KEDA solves this by adding scale-to-zero and scale-from-zero capability, plus 50+ built-in scalers that remove the need to install and configure a separate metrics adapter for each event source.

KEDA does not replace HPA. It extends HPA — under the hood, KEDA creates and manages HPA objects on your behalf, and feeds them metric values through its own built-in metrics server. The result is that your Deployments still scale via the familiar Kubernetes reconciliation loop, but KEDA adds the ability to go all the way to zero replicas when the event source is empty.

**Real-world scenario:** A data processing pipeline has worker pods that consume tasks from a Redis queue. Traffic is bursty — for 20 hours a day the queue is empty; during a 4-hour processing window it fills to thousands of tasks. Without KEDA, you run `minReplicas: 1` and pay for an idle worker all day. With KEDA, the Deployment scales to 0 when the queue is empty and springs back to life when tasks arrive.

**What this lab covers:**
- KEDA architecture — Operator, Metrics Server, ScaledObject, ScaledJob, TriggerAuthentication
- How KEDA creates and manages HPA objects — the relationship between ScaledObject and HPA
- Scale-to-zero and scale-from-zero mechanics — how KEDA handles the `minReplicas: 0` case HPA cannot express
- Prometheus scaler — scale a Deployment based on a Prometheus metric (minikube `3node`)
- Redis scaler — scale a Deployment based on Redis list/stream length (minikube `3node`)
- Cron scaler — scheduled scaling with cron expressions (minikube `3node`)
- TriggerAuthentication — how KEDA connects to secured backends
- SQS scaler — theory and E2E flow (hands-on in `aws-eks-demos`)

> **Scope note:** Steps 1–6 are hands-on on minikube `3node`. The SQS scaler (Step 7) is theory only — it requires AWS credentials and an SQS queue; hands-on is in `aws-eks-demos`. All other scalers in this lab (Prometheus, Redis, Cron) are cloud-agnostic and run on minikube without AWS access.

> **Verification status:** Steps 1–6 expected outputs are written from documented KEDA behaviour. They have not yet been run against this lab's manifests on a live cluster — run through the steps and report back any differences.

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — same cluster used in `01-hpa-basic`–`03-vpa-fundamentals`
- kubectl installed and configured
- Helm v3 (for KEDA installation)
- metrics-server enabled (already done in `01-hpa-basic` Step 1)

**Verify before starting:**
```bash
kubectl get pods -n kube-system | grep metrics-server
helm version --short
# Both must succeed before proceeding
```

**Knowledge Requirements:**
- **REQUIRED:** Completion of `01-hpa-basic` — HPA architecture, the HPA metrics pipeline, scale subresource, HPA v2 API
- **REQUIRED:** Completion of `02-hpa-advanced` — HPA metric types (especially `External` type), adapter architecture, `external.metrics.k8s.io`
- **RECOMMENDED:** Completion of `03-vpa-fundamentals` — useful for understanding how KEDA coexists with VPA

---

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain the KEDA architecture — Operator, Metrics Server, ScaledObject, ScaledJob
2. ✅ Explain how KEDA creates and manages HPA objects, and why it can achieve scale-to-zero while HPA alone cannot
3. ✅ Explain scale-from-zero mechanics — how KEDA activates a Deployment from 0 replicas
4. ✅ Install KEDA via Helm and verify all components are running
5. ✅ Create a ScaledObject using the Prometheus scaler and observe scaling based on a Prometheus metric
6. ✅ Create a ScaledObject using the Redis scaler and observe scale-to-zero and scale-from-zero
7. ✅ Create a ScaledObject using the Cron scaler for scheduled scaling
8. ✅ Configure TriggerAuthentication for a secured event source
9. ✅ Explain the SQS scaler E2E flow and why it requires AWS infrastructure
10. ✅ Uninstall KEDA cleanly

---

## Directory Structure

```
11-auto-scaling/04-keda-adapter/
├── README.md                              # this file
├── 04-keda-adapter-anki.csv                       # Anki flashcard deck
├── 04-keda-adapter-quiz.md                        # standalone quiz
└── src/
    ├── 01-redis-deploy.yaml                   # Redis deployment for Redis scaler demo
    ├── 02-worker-deploy.yaml                  # worker Deployment — target of all ScaledObjects
    ├── 03-scaledobject-prometheus.yaml        # ScaledObject — Prometheus scaler
    ├── 04-scaledobject-redis.yaml             # ScaledObject — Redis list scaler
    ├── 05-scaledobject-cron.yaml              # ScaledObject — Cron scaler
    ├── 06-triggerauth-redis.yaml              # TriggerAuthentication example
    └── break-fix/
        ├── 01-scaledobject-wrong-target.yaml     # broken: scaleTargetRef name mismatch
        ├── 02-scaledobject-missing-auth.yaml     # broken: Redis scaler without TriggerAuth
        └── 03-scaledobject-conflict-hpa.yaml     # broken: ScaledObject + manual HPA on same target
```

---

## Recall Check — 03-vpa-fundamentals

Answer from memory before continuing — these are scenario questions from `03-vpa-fundamentals`.

1. You apply a VPA with `updateMode: "Recreate"` to a Deployment with `replicas: 1`. After a recommendation appears, the pod is evicted. What recreates it, and what determines the resource requests the new pod starts with?
2. `kubectl describe vpa` shows `Target: cpu=50m` and `Uncapped Target: cpu=200m`. What does this tell you, and what would you check or change?
3. You want to run HPA and VPA together on a production Deployment that serves HTTP traffic. HPA should respond to traffic spikes; VPA should right-size the resource requests. What is the safe configuration for each, and why?

<details>
<summary>Answers</summary>

1. The Deployment controller recreates the evicted pod (VPA Updater only evicts — it does not recreate). The VPA Admission Controller intercepts the new pod's creation request and patches the pod spec, injecting the VPA Target values (90th percentile recommendation) as `resources.requests`. The Deployment spec is not changed — only the pod spec at creation time.

2. `maxAllowed` is clamping the recommendation downward. The histogram data says the container needs 200m CPU (Uncapped Target), but `resourcePolicy.containerPolicies[].maxAllowed.cpu` is set at or below 50m, forcing Target to be capped at the ceiling. The container is permanently under-provisioned and will be CPU-throttled at peak. Action: raise `maxAllowed.cpu` to at least 220m (110-120% of Uncapped Target as headroom).

3. Safe configuration: HPA on CPU/memory targeting the Deployment (scales replicas); VPA in `Off` mode observing the same Deployment (recommendations only — never changes requests). The conflict arises only when VPA is in Recreate/Initial/InPlaceOrRecreate mode AND HPA watches CPU/memory — because VPA changing `resources.requests` shifts HPA's utilisation denominator without changing actual usage, causing oscillation. With VPA in Off mode, the denominator never changes and HPA operates stably.

</details>

---

## Concepts

### KEDA Architecture

KEDA (Kubernetes Event-Driven Autoscaling) is a CNCF Graduated project (graduated August 2023). It was originally created at Microsoft and donated to CNCF in 2020. It is cloud-agnostic — the core runs on any Kubernetes cluster; only specific scalers (e.g. SQS) require cloud access.

**Why KEDA exists — the gap HPA leaves:**

HPA requires `minReplicas ≥ 1`. This means:
- A queue consumer must always run at least one pod, even when the queue is empty
- There is no built-in way to respond to an event source going from empty to non-empty (scale-from-zero)
- Adding a new event source (SQS, Kafka, Redis, HTTP) requires installing and configuring a separate metrics adapter

KEDA addresses all three gaps: it supports `minReplicaCount: 0`, implements scale-from-zero natively, and bundles 50+ scalers that each know how to query their specific event source.

**KEDA components:**

```
keda-operator (Deployment in kube-system or keda namespace)
  Role:    watches ScaledObject and ScaledJob CRDs
  Process: when a ScaledObject is created:
           -> creates or updates an HPA object targeting the same workload
           -> configures the HPA to use KEDA Metrics Server as its metric source
           -> manages the HPA lifecycle (updates, deletion)
  Scale-to-zero special handling:
           -> when the scaler reports 0 active messages/events:
              HPA would floor at minReplicas=1 (cannot go lower)
              KEDA Operator takes over: directly scales the Deployment to 0
              (bypasses HPA for the 0-replica case)
  Scale-from-zero special handling:
           -> KEDA Operator polls the scaler even when Deployment is at 0
           -> when scaler reports > 0 events: Operator scales Deployment to
              at least minReplicaCount (e.g. 1) before HPA takes over
           -> HPA then scales up further based on the metric value

keda-operator-metrics-apiserver (Deployment in keda namespace)
  Role:    implements external.metrics.k8s.io for KEDA scalers
  Process: when HPA controller queries the External Metrics API:
           -> KEDA Metrics Server translates the request to a scaler-specific query
           -> runs the scaler logic (e.g. queries Redis for list length)
           -> returns the metric value to HPA in External Metrics API format
  Replaces: the need to install a separate metrics adapter per event source
            (one KEDA Metrics Server handles all 50+ scalers)
```

**KEDA CRDs:**

```
ScaledObject — autoscaling.keda.sh/v1alpha1
  What it is: the primary resource you create to tell KEDA what to scale and when
  Contains:   scaleTargetRef (which Deployment to scale)
              triggers (one or more scalers with their configuration)
              minReplicaCount, maxReplicaCount (KEDA equivalents of HPA min/max)
              pollingInterval, cooldownPeriod (KEDA-specific timing)
  Who creates it: you (declaratively)
  Who manages it: KEDA Operator watches it and creates/manages the corresponding HPA

ScaledJob — autoscaling.keda.sh/v1alpha1
  What it is: KEDA's equivalent of ScaledObject, but for Kubernetes Jobs
  Use case:  process one batch of events → create a Job → Job completes → Job deleted
             each "unit of work" gets its own Job pod, not a long-running Deployment
  Contains:  jobTargetRef (Job template), triggers, scalingStrategy
  When to use: run-to-completion workloads (batch processing, one-shot tasks)
               vs ScaledObject for long-running Deployments

TriggerAuthentication — keda.sh/v1alpha1
  What it is: stores credentials for a KEDA scaler (Redis password, Kafka API key, etc.)
  Scope:      namespace-scoped — applies to ScaledObjects in the same namespace
  Mechanism:  references a Kubernetes Secret; KEDA reads the Secret to authenticate
              to the event source (Redis, Kafka, Prometheus, etc.)

ClusterTriggerAuthentication — keda.sh/v1alpha1
  What it is: same as TriggerAuthentication but cluster-scoped
  Scope:      cluster-wide — any ScaledObject in any namespace can reference it
  Use case:  shared credentials (e.g. one Redis instance used by multiple teams)
```

**How KEDA and HPA coexist:**

```
You create:  ScaledObject (04-keda-adapter CRD)
KEDA creates: HPA (autoscaling/v2 standard object)

The HPA KEDA creates:
  scaleTargetRef: -> same Deployment as ScaledObject
  metrics:
    - type: External
      external:
        metric:
          name: s0-redis-mylist   <- KEDA-internal metric name
          selector:
            matchLabels:
              scaledobject.keda.sh/name: my-scaledobject
        target:
          type: AverageValue
          averageValue: "5"       <- your targetValue from ScaledObject

HPA queries: external.metrics.k8s.io (KEDA Metrics Server serves this)
KEDA Metrics Server: queries Redis, returns list length
HPA: calculates desiredReplicas = ceil[current × (listLength / targetValue)]
HPA: updates Deployment scale subresource

For 0 replicas:
  HPA says: desiredReplicas = 0, but floor at minReplicas=1 -> stays at 1
  KEDA Operator: detects scaler reports 0 -> directly scales Deployment to 0
  (KEDA bypasses HPA for the final step to zero)
```

**What "KEDA manages the HPA" means in practice:**

```
DO NOT manually edit the HPA that KEDA creates.
  -> KEDA will overwrite your changes
  -> it owns the HPA lifecycle

DO NOT create a separate HPA targeting the same Deployment as a ScaledObject.
  -> causes AmbiguousSelector conflict (same as two manually-created HPAs)
  -> KEDA detects this and will report an error

kubectl get hpa
  -> you will see the KEDA-managed HPA with a name like "keda-hpa-my-scaledobject"
  -> this is expected — KEDA creates it, you do not manage it

kubectl delete scaledobject my-scaledobject
  -> KEDA automatically deletes the corresponding HPA
  -> do not delete the HPA directly
```

---

### ScaledObject — Complete Field Reference

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: my-scaledobject
  namespace: default
spec:

  # What to scale
  scaleTargetRef:
    apiVersion: apps/v1           # default: apps/v1
    kind: Deployment              # Deployment, StatefulSet, or custom resource
    name: worker                  # name of the target workload
                                  # MUST be in the same namespace as the ScaledObject

  # Replica bounds (KEDA equivalents of HPA minReplicas/maxReplicas)
  minReplicaCount: 0             # default: 0 — can scale to zero (unlike HPA minReplicas >= 1)
  maxReplicaCount: 10            # default: 100 — ceiling on replica count

  # Timing
  pollingInterval: 30            # seconds between scaler queries (default: 30)
                                 # how often KEDA checks the event source
  cooldownPeriod: 300            # seconds to wait after last trigger fires before
                                 # scaling to zero (default: 300 = 5 minutes)
                                 # prevents scale-to-zero during brief quiet periods

  # Activation threshold (scale-from-zero)
  # When Deployment is at 0 replicas, KEDA compares the raw metric value
  # to activationThreshold (not targetValue) to decide whether to start pods.
  # Default: 0 (any non-zero metric activates the Deployment)
  # activationThreshold: 5       # only activate if queue depth > 5

  # Triggers (one or more — KEDA evaluates all and takes the MAX)
  triggers:
    # Trigger type determines which scaler KEDA uses.
    # Each trigger type has its own metadata fields.
    - type: redis                 # scaler type (redis, prometheus, kafka, cron, aws-sqs-queue, etc.)
      metadata:
        address: redis-svc:6379   # scaler-specific configuration
        listName: task-queue
        listLength: "5"           # target: 5 list items per worker pod

    # Multiple triggers: KEDA evaluates each and takes the MAX desired replica count
    # (same MAX rule as HPA multiple metrics)
    - type: cron
      metadata:
        timezone: UTC
        start: "0 9 * * 1-5"     # scale up at 9am Mon-Fri
        end: "0 18 * * 1-5"      # scale down at 6pm Mon-Fri
        desiredReplicas: "3"      # target replica count during the window

  # Advanced HPA configuration (passed through to the managed HPA)
  advanced:
    restoreToOriginalReplicaCount: true
    # true: when ScaledObject is deleted, restore Deployment to its original replica count
    # false (default): leave at whatever count KEDA last set
    horizontalPodAutoscalerConfig:
      behavior:                   # same behavior block as HPA autoscaling/v2
        scaleDown:
          stabilizationWindowSeconds: 60
          policies:
            - type: Percent
              value: 50
              periodSeconds: 60
```

**Field-by-field explanation:**

| Field | Default | What it controls | Common mistake |
|---|---|---|---|
| `minReplicaCount` | 0 | Floor — can be 0 (unlike HPA's minimum of 1) | Setting to 1 defeats the scale-to-zero benefit |
| `maxReplicaCount` | 100 | Ceiling on replica count | Leaving at 100 may cause unbounded scale-out on unexpected traffic |
| `pollingInterval` | 30 | How often (seconds) KEDA queries the event source | Too low hammers the event source; too high causes slow reaction |
| `cooldownPeriod` | 300 | Seconds after last event before scaling to zero | Too short → pods destroyed and recreated repeatedly; too long → idle pods waste resources |
| `activationThreshold` | 0 | Minimum metric value to start pods from zero | Leaving at 0 activates on a single message — set higher for noisy queues |
| `triggers[].type` | required | Which KEDA scaler to use | Mismatched trigger type for the event source (e.g. `redis` for Kafka) |
| `triggers[].metadata` | required | Scaler-specific configuration | Address format, auth reference, metric name — all vary per scaler type |
| `advanced.restoreToOriginalReplicaCount` | false | Whether to restore replicas on ScaledObject delete | Leaving false means deleting ScaledObject strands Deployment at 0 replicas |

---

### Scale-to-Zero and Scale-from-Zero Mechanics

Understanding the sequence is important because HPA and KEDA handle different parts:

```
SCALE-TO-ZERO SEQUENCE:
  1. Event source becomes empty (queue depth = 0)
  2. KEDA Metrics Server returns 0 to HPA
  3. HPA calculates: desiredReplicas = 0
  4. HPA floors at minReplicas=1 (HPA cannot go below 1)
  5. KEDA Operator detects: scaler returning 0 AND cooldownPeriod has elapsed
  6. KEDA Operator directly patches Deployment.spec.replicas = 0
     (bypasses HPA entirely for this final step)
  7. All pods terminate; Deployment sits at 0 replicas

  Key point: HPA takes the Deployment from N down to 1.
             KEDA Operator takes it from 1 down to 0.
             Two different components, two different mechanisms.

SCALE-FROM-ZERO SEQUENCE:
  1. Event source receives new events (queue depth > activationThreshold)
  2. KEDA Operator polls the scaler (not HPA — HPA is suspended when at 0)
  3. KEDA Operator detects: metric > activationThreshold
  4. KEDA Operator directly patches Deployment.spec.replicas = 1
     (or minReplicaCount if > 1)
  5. Pod(s) start up; HPA takes over once at least 1 pod is running
  6. HPA calculates normal desiredReplicas from the current metric value
  7. HPA scales to the appropriate replica count

  Key point: KEDA Operator handles 0 -> 1 transition.
             HPA handles 1 -> N scaling.
             During scale-from-zero, there is a brief period where the
             queue is non-empty but the pod is still starting — this is
             the "cold start" latency of scale-from-zero.
```

**activationThreshold — preventing noise-driven cold starts:**

```
Default activationThreshold: 0
  -> Any single message activates the Deployment from 0
  -> If the queue occasionally gets 1-2 test messages, pods start unnecessarily

activationThreshold: 5
  -> KEDA waits until queue depth > 5 before starting pods from zero
  -> Prevents cold starts from low-volume noise
  -> The targetValue (per-pod threshold for scaling) is separate from activationThreshold

Example:
  listLength (targetValue): "5"       # 5 messages per pod for ongoing scaling
  activationThreshold: 5              # 5 messages needed to start from zero
  queue depth = 3 -> stays at 0 replicas (below activationThreshold)
  queue depth = 6 -> starts 1 pod, HPA takes over: ceil[1 x (6/5)] = 2 pods
```

---

### KEDA Scaler Examples — Minikube-Compatible

This demo covers three scalers that run on minikube without cloud access:

```
Prometheus scaler:
  Event source: any metric in Prometheus
  Query:        PromQL expression
  Use case:     scale based on request rate, error rate, custom app metrics
  Requires:     Prometheus running in the cluster (kube-prometheus-stack or standalone)

Redis scaler:
  Event source: Redis list length or stream consumer group lag
  Query:        LLEN <listName> (for list) or XLEN/consumer lag (for stream)
  Use case:     queue consumer that processes items from a Redis list
  Requires:     Redis running in the cluster

Cron scaler:
  Event source: wall-clock time (no external service)
  Query:        cron expression + timezone
  Use case:     predictable scheduled scaling (business hours, batch windows)
  Requires:     nothing external — KEDA handles it natively
```

---

### SQS Scaler (Theory — Hands-on in `aws-eks-demos`)

```
Event source: AWS SQS queue (ApproximateNumberOfMessages)
Authentication: IRSA (IAM Role for Service Accounts) on EKS
                -> no long-lived credentials; Pod identity via service account
Query: SQS GetQueueAttributes API call
Scale logic: desiredReplicas = ceil[currentReplicas x (queueDepth / targetQueueLength)]

E2E flow:
  1. SQS queue "orders" fills with messages
  2. KEDA Metrics Server: calls SQS GetQueueAttributes via IRSA credentials
  3. Returns queue depth to HPA via external.metrics.k8s.io
  4. HPA calculates desiredReplicas
  5. Workers process messages; queue drains
  6. Queue empties -> KEDA scales to 0
  7. New messages arrive -> KEDA scales from 0

Why EKS only:
  IRSA (IAM Role for Service Accounts) requires EKS control plane integration.
  Can also use Kubernetes Secret with static AWS credentials — but this is
  not recommended for production.
  The SQS queue and CloudWatch metrics are AWS services.
  Hands-on: aws-eks-demos
```

---

## Lab Step-by-Step Guide

---

### Step 1 — Install KEDA via Helm

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm install keda kedacore/keda \
  --namespace keda \
  --create-namespace

# Wait for all components to be ready
kubectl get pods -n keda -w
```

**Expected output:**
```
NAME                                      READY   STATUS    RESTARTS
keda-operator-xxxxxxxxx-xxxxx             1/1     Running   0
keda-operator-metrics-apiserver-yyy-yyy   1/1     Running   0
keda-webhooks-xxxxxxxxx-xxxxx             1/1     Running   0
```

Verify KEDA CRDs are installed:
```bash
kubectl api-resources | grep keda
```

**Expected output:**
```
clustertriggerauthentications    cta       keda.sh/v1alpha1   false  ClusterTriggerAuthentication
scaledjobs                       sj        keda.sh/v1alpha1   true   ScaledJob
scaledobjects                    so        keda.sh/v1alpha1   true   ScaledObject
triggerauthentications           ta        keda.sh/v1alpha1   true   TriggerAuthentication
```

Verify the External Metrics API is registered (KEDA Metrics Server):
```bash
kubectl get apiservices | grep external
```

**Expected output:**
```
v1beta1.external.metrics.k8s.io   keda/keda-operator-metrics-apiserver   True   2m
```

```
# Observation: KEDA Metrics Server has registered itself as the handler for
#              external.metrics.k8s.io — the same API group that HPA External
#              type metrics use. Any HPA querying External metrics will now
#              route through KEDA Metrics Server.
```

---

### Step 2 — Deploy Worker Application

This Deployment represents a queue consumer — it will be the target of all ScaledObjects in this lab.

**`src/02-worker-deploy.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: worker
  template:
    metadata:
      labels:
        app: worker
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: worker
          image: busybox:1.36
          command: ["sh", "-c", "while true; do sleep 30; done"]
          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
            limits:
              cpu: "500m"
              memory: "128Mi"
```

```bash
cd 11-auto-scaling/04-keda-adapter/src

kubectl apply -f 02-worker-deploy.yaml
kubectl rollout status deployment/worker
kubectl get pods -l app=worker
```

**Expected output:**
```
deployment "worker" successfully rolled out
NAME                      READY   STATUS    RESTARTS
worker-xxxxxxxxx-xxxxx    1/1     Running   0
```

---

### Step 3 — Prometheus Scaler

This step uses the `kube-prometheus-stack` Prometheus instance (installed in `kube-system` or `monitoring` namespace). If kube-prometheus-stack is not installed, see the note below.

> **If kube-prometheus-stack is not installed:** Install it first: `helm install kube-prom prometheus-community/kube-prometheus-stack -n monitoring --create-namespace`. Wait for all pods to be Running. The Prometheus service is typically at `kube-prom-kube-promethe-prometheus.monitoring.svc:9090`. Verify with: `kubectl get svc -n monitoring | grep prometheus`.

The Prometheus scaler queries a PromQL expression. We will scale the worker based on the number of Kubernetes pods running in the default namespace — a simple metric available without any application changes, purely to demonstrate the scaler mechanics.

**`src/03-scaledobject-prometheus.yaml`:**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-prometheus-scaler
spec:
  scaleTargetRef:
    name: worker                            # target Deployment
  minReplicaCount: 1                        # keep at least 1 for this demo (not zero)
  maxReplicaCount: 5
  pollingInterval: 15                       # query Prometheus every 15s
  cooldownPeriod: 60
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://kube-prom-kube-promethe-prometheus.monitoring.svc:9090
        # adjust this address to match your kube-prometheus-stack service name:
        # kubectl get svc -n monitoring | grep prometheus
        metricName: pods_in_default_ns
        threshold: "2"                      # target: 2 pods per worker replica
        query: count(kube_pod_info{namespace="default"})
        # PromQL: count pods in default namespace
        # threshold: scale when (metric / threshold) > current replicas
```

```bash
kubectl apply -f 03-scaledobject-prometheus.yaml
kubectl get scaledobject worker-prometheus-scaler
```

**Expected output:**
```
NAME                       SCALETARGETKIND   SCALETARGETNAME   MIN   MAX   TRIGGERS     READY   ACTIVE   FALLBACK   AGE
worker-prometheus-scaler   Deployment        worker            1     5     prometheus   True    True     False      30s
```

```
# Observation: READY=True -> KEDA can reach the Prometheus server
#              ACTIVE=True -> the metric exceeds the activation threshold
#              FALLBACK=False -> no fallback behaviour triggered
```

Check what HPA KEDA created:
```bash
kubectl get hpa
```

**Expected output:**
```
NAME                                  REFERENCE             TARGETS              MINPODS   MAXPODS   REPLICAS
keda-hpa-worker-prometheus-scaler     Deployment/worker     <unknown>/2 (avg)    1         5         1
```

```
# Observation: KEDA created this HPA automatically.
#              Its name is keda-hpa-<scaledobject-name>.
#              Do not edit or delete this HPA directly — KEDA owns it.
```

Wait ~30 seconds for the metric to stabilise:
```bash
kubectl describe scaledobject worker-prometheus-scaler | grep -A5 "Conditions:"
kubectl get hpa keda-hpa-worker-prometheus-scaler
```

**Expected output:**
```
Conditions:
  Active: True   ScalerActive   "Scaler worker-prometheus-scaler is active"
  Ready:  True   ScalerReady    "Scaler worker-prometheus-scaler is ready"

NAME                               TARGETS       MINPODS  MAXPODS  REPLICAS
keda-hpa-worker-prometheus-scaler  3/2 (avg)     1        5        2
```

```
# Observation: pods_in_default_ns query returns ~3 (worker pod + load-generator if present)
#              threshold is 2 per replica -> desired = ceil[1 x (3/2)] = 2 replicas
#              HPA scales worker to 2
```

Cleanup:
```bash
kubectl delete -f 03-scaledobject-prometheus.yaml
# KEDA automatically deletes the keda-hpa-worker-prometheus-scaler HPA
kubectl get hpa
# No HPAs should remain
```

---

### Step 4 — Deploy Redis

Redis will serve as the event source for the Redis scaler in Step 5.

**`src/01-redis-deploy.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: redis
          image: redis:7.2
          ports:
            - containerPort: 6379
          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: redis-svc
spec:
  type: ClusterIP
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6379
```

```bash
kubectl apply -f 01-redis-deploy.yaml
kubectl rollout status deployment/redis
kubectl get pods -l app=redis
```

**Expected output:**
```
deployment "redis" successfully rolled out
NAME                     READY   STATUS
redis-xxxxxxxxx-xxxxx    1/1     Running
```

Verify Redis is reachable:
```bash
kubectl exec deploy/redis -- redis-cli ping
```

**Expected output:**
```
PONG
```

---

### Step 5 — Redis Scaler (Scale to Zero and Scale from Zero)

The Redis scaler monitors the length of a Redis list. When the list is empty, worker scales to 0. When items are pushed, worker scales up.

**`src/04-scaledobject-redis.yaml`:**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-redis-scaler
spec:
  scaleTargetRef:
    name: worker
  minReplicaCount: 0              # scale to zero when queue is empty
  maxReplicaCount: 10
  pollingInterval: 10             # check Redis every 10s (faster for demo)
  cooldownPeriod: 30              # scale to zero 30s after queue empties
  triggers:
    - type: redis
      metadata:
        address: redis-svc:6379   # Redis service address (no auth for this demo)
        listName: task-queue      # Redis list to monitor
        listLength: "5"           # target: 5 list items per worker pod
        # activationThreshold: "1"  # default: 0 — any item activates from zero
```

```bash
kubectl apply -f 04-scaledobject-redis.yaml

# Watch for scale-to-zero (cooldownPeriod=30s after queue empty)
kubectl get scaledobject worker-redis-scaler -w &
SO_PID=$!
kubectl get pods -l app=worker -w &
POD_PID=$!
```

**Expected output — scale to zero:**
```
NAME                   SCALETARGETKIND   SCALETARGETNAME   MIN   MAX   TRIGGERS   READY   ACTIVE
worker-redis-scaler    Deployment        worker            0     10    redis      True    False

NAME                      READY   STATUS
worker-xxxxxxxxx-xxxxx    1/1     Running
worker-xxxxxxxxx-xxxxx    1/1     Terminating    <- KEDA scales to 0
(no pods)                                        <- Deployment at 0 replicas
```

```
# Observation: ACTIVE=False -> Redis list is empty -> KEDA scaled to 0
#              The Deployment still exists (spec.replicas=0), but no pods are running
#              This is the scale-to-zero state HPA alone cannot achieve
```

**Push items to the Redis queue — trigger scale-from-zero:**
```bash
# Push 20 items to the task-queue list
kubectl exec deploy/redis -- \
  redis-cli rpush task-queue item1 item2 item3 item4 item5 \
            item6 item7 item8 item9 item10 \
            item11 item12 item13 item14 item15 \
            item16 item17 item18 item19 item20
```

**Watch scale-from-zero in the background watchers:**
```
NAME                   ACTIVE   <- KEDA detects 20 items
worker-redis-scaler    True     <- ACTIVE=True, scaling begins

NAME                       READY   STATUS
worker-yyyyyyyyy-yyyyy     0/1     ContainerCreating   <- KEDA starts pod 1 from 0
worker-yyyyyyyyy-yyyyy     1/1     Running
worker-zzzzzzzzz-zzzzz     0/1     ContainerCreating   <- HPA adds more pods
worker-zzzzzzzzz-zzzzz     1/1     Running
```

**Expected HPA calculation:**
```
Redis list length: 20
listLength (target per pod): 5
currentReplicas: 1 (after KEDA starts the first pod)
desiredReplicas = ceil[1 x (20/5)] = 4 pods
```

Verify:
```bash
kubectl get pods -l app=worker
kubectl get hpa
```

**Expected output:**
```
NAME                           READY   STATUS
worker-yyyyyyyyy-yyyyy         1/1     Running
worker-zzzzzzzzz-zzzzz         1/1     Running
worker-aaaaaaaa-aaaaa          1/1     Running
worker-bbbbbbbb-bbbbb          1/1     Running

NAME                          TARGETS       MINPODS  MAXPODS  REPLICAS
keda-hpa-worker-redis-scaler  20/5 (avg)    1        10       4
```

```
# Observation: 4 replicas as predicted by the formula
#              KEDA handled the 0->1 transition; HPA handled 1->4
```

Drain the queue to observe scale-to-zero:
```bash
# Remove all items from the list
kubectl exec deploy/redis -- redis-cli del task-queue

# Wait for cooldownPeriod (30s) then watch scale-to-zero
kubectl get pods -l app=worker -w
```

**Expected output after ~30s:**
```
NAME                       READY   STATUS
worker-yyyyyyyyy-yyyyy     1/1     Terminating
worker-zzzzzzzzz-zzzzz     1/1     Terminating
worker-aaaaaaaa-aaaaa      1/1     Terminating
worker-bbbbbbbb-bbbbb      1/1     Terminating
(no pods)                          <- back to 0
```

```bash
kill $SO_PID $POD_PID 2>/dev/null
kubectl delete -f 04-scaledobject-redis.yaml
```

---

### Step 6 — Cron Scaler (Scheduled Scaling)

The Cron scaler scales based on a schedule — no external event source required. Useful for predictable load patterns (business hours, batch windows, overnight maintenance).

**`src/05-scaledobject-cron.yaml`:**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-cron-scaler
spec:
  scaleTargetRef:
    name: worker
  minReplicaCount: 0              # 0 outside of business hours
  maxReplicaCount: 5
  triggers:
    - type: cron
      metadata:
        timezone: UTC
        start: "*/2 * * * *"     # every 2 minutes (for demo — replace with real schedule)
        end: "*/3 * * * *"       # 1 minute later (3 - 2 = 1 minute active window)
        desiredReplicas: "3"     # scale to 3 during the active window
```

> **Note on cron schedule for this demo:** The schedule above runs every 2 minutes for 1 minute to make the lab observable quickly. In production, typical schedules are:
> ```yaml
> start: "0 9 * * 1-5"    # 9am Mon-Fri
> end: "0 18 * * 1-5"     # 6pm Mon-Fri
> desiredReplicas: "10"
> ```

```bash
kubectl apply -f 05-scaledobject-cron.yaml

# Watch for cron window to open
kubectl get scaledobject worker-cron-scaler -w
```

**Expected output — outside the cron window:**
```
NAME                 READY   ACTIVE   FALLBACK
worker-cron-scaler   True    False    False
```

```
# Observation: ACTIVE=False -> currently outside the cron window
#              KEDA is monitoring the clock and will activate at the next scheduled start
```

**Expected output — inside the cron window:**
```
NAME                 READY   ACTIVE   FALLBACK
worker-cron-scaler   True    True     False
```

```bash
kubectl get pods -l app=worker
```

**Expected output during active window:**
```
NAME                       READY   STATUS
worker-xxxxxxxxx-xxxxx     1/1     Running
worker-yyyyyyyyy-yyyyy     1/1     Running
worker-zzzzzzzzz-zzzzz     1/1     Running
```

```
# Observation: desiredReplicas=3 during the cron window -> 3 pods running
#              When the window closes (*/3 in this demo), KEDA scales back to 0
```

Wait for the window to close:
```bash
kubectl get pods -l app=worker -w
# After window closes: pods terminate -> 0 replicas
```

```bash
kubectl delete -f 05-scaledobject-cron.yaml
```

---

### Step 7 — Theory: SQS Scaler and AWS Infrastructure

> No cluster commands in this step — theory only. Hands-on: `aws-eks-demos`.

The SQS scaler requires:
1. An AWS SQS queue (`orders` queue with messages)
2. KEDA deployed on EKS with IRSA (IAM Role for Service Accounts)
3. A TriggerAuthentication referencing the IRSA-backed service account
4. A ScaledObject with `type: aws-sqs-queue` trigger

```yaml
# TriggerAuthentication for SQS via IRSA
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: sqs-trigger-auth
spec:
  podIdentity:
    provider: aws             # use IRSA — no credentials stored in Kubernetes
    # the Pod's ServiceAccount is annotated with the IAM role ARN:
    # eks.amazonaws.com/role-arn: arn:aws:iam::123456789:role/keda-sqs-role
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-sqs-scaler
spec:
  scaleTargetRef:
    name: worker
  minReplicaCount: 0
  maxReplicaCount: 20
  pollingInterval: 30
  triggers:
    - type: aws-sqs-queue
      authenticationRef:
        name: sqs-trigger-auth        # reference to TriggerAuthentication above
      metadata:
        queueURL: https://sqs.us-east-1.amazonaws.com/123456789/orders
        queueLength: "30"             # target: 30 messages per worker pod
        awsRegion: us-east-1
        identityOwner: operator       # use the KEDA operator's identity (IRSA)
```

**Why this requires EKS:**
- IRSA links a Kubernetes ServiceAccount to an IAM role — this binding is provided by the EKS control plane
- Without IRSA, you must store static AWS credentials in a Kubernetes Secret — acceptable for development, not for production
- The SQS queue and CloudWatch metrics (which SQS publishes to) are AWS services, not available locally

Full hands-on with real SQS queue, IRSA setup, and end-to-end verification: `aws-eks-demos`.

---

### Step 8 — TriggerAuthentication for Redis with Password

For secured Redis instances (Redis AUTH), KEDA uses a TriggerAuthentication that references a Kubernetes Secret:

**`src/06-triggerauth-redis.yaml`:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: redis-secret
type: Opaque
stringData:
  redis-password: "mysecretpassword"   # in production: use sealed secrets or external secrets
---
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: redis-trigger-auth
spec:
  secretTargetRef:
    - parameter: password              # KEDA parameter name (matches trigger metadata)
      name: redis-secret               # Kubernetes Secret name
      key: redis-password              # key within the Secret
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-redis-auth-scaler
spec:
  scaleTargetRef:
    name: worker
  minReplicaCount: 0
  maxReplicaCount: 10
  triggers:
    - type: redis
      authenticationRef:
        name: redis-trigger-auth       # reference to TriggerAuthentication above
      metadata:
        address: redis-secured-svc:6379
        listName: secure-queue
        listLength: "5"
        # password field is injected by TriggerAuthentication — not specified here
```

```
TriggerAuthentication flow:
  Secret "redis-secret" contains key "redis-password"
  TriggerAuthentication maps: parameter "password" -> Secret "redis-secret" key "redis-password"
  KEDA scaler reads parameter "password" -> gets the actual password from the Secret
  KEDA uses this password to authenticate to Redis before querying list length

  The password is never stored in the ScaledObject or visible in ScaledObject YAML.
  Only the TriggerAuthentication name is referenced.
```

> **Note:** This step is for reference only — no hands-on in this lab since the Redis instance we deployed in Step 4 has no password. In Step 5, the Redis scaler worked without authentication. Use this pattern when deploying against secured Redis in production.

---

### Step 9 — Cleanup and Uninstall KEDA

```bash
# Remove all demo resources
kubectl delete -f 02-worker-deploy.yaml --ignore-not-found
kubectl delete -f 01-redis-deploy.yaml --ignore-not-found
kubectl delete -f 03-scaledobject-prometheus.yaml --ignore-not-found
kubectl delete -f 04-scaledobject-redis.yaml --ignore-not-found
kubectl delete -f 05-scaledobject-cron.yaml --ignore-not-found
kubectl delete -f 06-triggerauth-redis.yaml --ignore-not-found

# Verify no ScaledObjects or HPAs remain
kubectl get scaledobject
kubectl get hpa
kubectl get pods
```

**Expected output:**
```
No resources found in default namespace.
No resources found in default namespace.
No resources found in default namespace.
```

**Uninstall KEDA:**
```bash
helm uninstall keda -n keda
kubectl delete namespace keda

kubectl get pods -n keda
kubectl api-resources | grep keda
```

**Expected output:**
```
(no output — KEDA namespace and CRDs are removed)
```

```
# Observation: KEDA CRDs are removed along with the Helm release.
#              external.metrics.k8s.io APIService is also removed.
#              metrics-server remains — still needed for 05-prometheus-adapter.
```

---

## What You Learned

In this lab, you:
- ✅ Explained the KEDA architecture — Operator, Metrics Server, and the ScaledObject, ScaledJob, TriggerAuthentication CRDs
- ✅ Explained how KEDA creates and manages HPA objects and why the combination enables scale-to-zero while HPA alone cannot
- ✅ Traced the scale-to-zero sequence (KEDA Operator takes over from HPA at the final 1→0 step) and scale-from-zero sequence (KEDA Operator handles 0→1; HPA handles 1→N)
- ✅ Installed KEDA via Helm and verified all components including the External Metrics API registration
- ✅ Created a ScaledObject using the Prometheus scaler and observed KEDA creating and managing the corresponding HPA
- ✅ Created a ScaledObject using the Redis scaler and observed complete scale-to-zero and scale-from-zero cycles
- ✅ Created a ScaledObject using the Cron scaler for scheduled scaling without an external event source
- ✅ Explained TriggerAuthentication and how KEDA passes credentials to secured event sources
- ✅ Explained the SQS scaler E2E flow and why it requires AWS infrastructure

**Key Takeaway:** KEDA does not replace HPA — it extends it. KEDA creates and manages HPA objects; HPA still does the actual pod scaling via the familiar reconciliation loop. What KEDA adds is the 0↔1 transition (which HPA's `minReplicas ≥ 1` prevents), plus 50+ built-in scalers that eliminate the need to install and configure a separate metrics adapter per event source. The core concept is that `pollingInterval` and `cooldownPeriod` govern how quickly KEDA reacts to event source changes, while HPA's `behavior` block (passed through `advanced.horizontalPodAutoscalerConfig`) controls how fast the replica count moves once HPA takes over.

---

## Break-Fix

Three broken manifests below. For each: apply it, read the symptom, diagnose, then reveal the answer.

---

### Error-1

**`src/break-fix/01-scaledobject-wrong-target.yaml`:**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-broken-target
spec:
  scaleTargetRef:
    name: wroker          # BUG: typo — "wroker" instead of "worker"
  minReplicaCount: 0
  maxReplicaCount: 5
  triggers:
    - type: cron
      metadata:
        timezone: UTC
        start: "*/1 * * * *"
        end: "*/2 * * * *"
        desiredReplicas: "2"
```

```bash
kubectl apply -f break-fix/01-scaledobject-wrong-target.yaml
kubectl get scaledobject worker-broken-target
kubectl describe scaledobject worker-broken-target | grep -A5 "Conditions:"
```

The ScaledObject is created successfully. What does `kubectl describe` show, and why?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
Conditions:
  Ready:  False   ScalerNotReady   "deployments.apps "wroker" not found"
  Active: False
```

**Cause:** The `scaleTargetRef.name` field contains a typo — `wroker` instead of `worker`. KEDA successfully creates the ScaledObject but cannot find the target Deployment. The KEDA Operator reports `ScalerNotReady` and never creates the managed HPA.

**Fix:** Correct the typo: `name: worker`. Apply and verify `READY=True`.

**Cascade:** While `READY=False`, no HPA is created and no scaling occurs. The Deployment is unmanaged — its replica count stays at whatever it was last set to manually.

</details>

---

### Error-2

**`src/break-fix/02-scaledobject-missing-auth.yaml`:**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-missing-auth
spec:
  scaleTargetRef:
    name: worker
  minReplicaCount: 0
  maxReplicaCount: 5
  triggers:
    - type: redis
      metadata:
        address: redis-svc:6379
        listName: secure-queue
        listLength: "5"
        password: "mysecretpassword"    # BUG: password in plaintext in ScaledObject metadata
                                         # This works, but violates security best practice
                                         # The correct approach is TriggerAuthentication
```

```bash
kubectl apply -f break-fix/02-scaledobject-missing-auth.yaml
kubectl get scaledobject worker-missing-auth
kubectl get scaledobject worker-missing-auth -o yaml | grep password
```

The ScaledObject works — Redis is queried successfully. What is the security problem?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
kubectl get scaledobject worker-missing-auth -o yaml | grep password
      password: mysecretpassword   <- plaintext in the ScaledObject spec
```

**Cause:** The Redis password is stored in plaintext in the ScaledObject's `metadata` block. ScaledObjects are stored in etcd (not encrypted by default in most clusters) and are visible to anyone with `kubectl get scaledobject -o yaml` permission. The password is also visible in audit logs and any GitOps repository where this manifest is stored.

**Fix:** Remove the `password` field from the trigger metadata. Instead, create a Kubernetes Secret containing the password, create a TriggerAuthentication that references the Secret, and reference the TriggerAuthentication from the ScaledObject via `authenticationRef`. This keeps the credential out of the ScaledObject spec and out of version control.

**Cascade:** In a production cluster with GitOps, the plaintext password in the ScaledObject YAML gets committed to the git repository — visible to anyone with repository read access, in perpetuity (even after rotation). Use TriggerAuthentication with Secrets (and ideally external secrets management) for all production credentials.

</details>

---

### Error-3

**`src/break-fix/03-scaledobject-conflict-hpa.yaml`:**
```yaml
# A ScaledObject already exists on the "worker" Deployment from a previous step.
# This manifest creates a SECOND, manually-managed HPA on the same Deployment.
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: manual-hpa-worker       # BUG: manual HPA on a Deployment already managed by KEDA
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: worker
  minReplicas: 1
  maxReplicas: 3
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```

```bash
# First ensure a ScaledObject exists on worker
kubectl apply -f 04-scaledobject-redis.yaml

# Then apply the conflicting manual HPA
kubectl apply -f break-fix/03-scaledobject-conflict-hpa.yaml

# Wait ~30s then check
kubectl get hpa
kubectl describe scaledobject worker-redis-scaler | grep -A10 "Conditions:"
```

Two HPAs now target the same Deployment. What does KEDA report, and what is the consequence?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
kubectl get hpa:
  NAME                          REFERENCE          TARGETS       REPLICAS
  keda-hpa-worker-redis-scaler  Deployment/worker  <unknown>/5   1
  manual-hpa-worker             Deployment/worker  0%/50%        1

kubectl describe scaledobject worker-redis-scaler:
  Conditions:
    Ready:  False   ScalerNotReady   "AmbiguousSelector: found multiple HPAs targeting..."
```

**Cause:** KEDA detects that a second HPA (`manual-hpa-worker`) is also targeting the `worker` Deployment. This creates an AmbiguousSelector conflict — the Kubernetes HPA controller cannot determine which HPA is authoritative and stops processing both. KEDA reports `ScalerNotReady` and the managed HPA shows `<unknown>` metrics.

**Fix:** Delete the manually-created HPA (`kubectl delete hpa manual-hpa-worker`). KEDA owns the HPA lifecycle for any Deployment it manages via a ScaledObject. Never create a manual HPA alongside a ScaledObject on the same target.

**Cascade:** While the conflict exists, neither HPA scales the Deployment. The replica count freezes at whatever it was when the conflict was introduced. The Deployment is effectively unmanaged during this period.

</details>

---

## Interview Prep

**Q1. Explain how KEDA achieves scale-to-zero when HPA cannot. What is the exact mechanism?**

HPA's `minReplicas` must be ≥ 1 — it will never set a Deployment to 0 replicas. KEDA achieves scale-to-zero in two separate steps handled by two separate components. When the event source empties, HPA scales the Deployment down to 1 (its floor). KEDA Operator then monitors the scaler independently — when the scaler reports 0 AND the cooldownPeriod has elapsed, the Operator directly patches `Deployment.spec.replicas = 0`, bypassing HPA entirely for this final step. Scale-from-zero is the reverse: KEDA Operator polls the scaler even when the Deployment is at 0, detects a non-zero metric, and patches the Deployment to `minReplicaCount` (e.g. 1). Once at least 1 pod is running, HPA takes over and scales further based on the metric value.

**Q2. What happens if you create a manual HPA targeting the same Deployment as a KEDA ScaledObject?**

An AmbiguousSelector conflict. KEDA creates an HPA for every ScaledObject it manages. If a second HPA exists for the same `scaleTargetRef`, the HPA controller cannot determine which is authoritative and stops processing both HPAs. KEDA reports `ScalerNotReady` on the ScaledObject. The Deployment replica count freezes and is effectively unmanaged. Fix: delete the manually-created HPA — KEDA owns the HPA for any Deployment it manages via ScaledObject.

**Q3. What is the difference between `pollingInterval`, `cooldownPeriod`, and `activationThreshold` in a ScaledObject?**

`pollingInterval` (default 30s) controls how frequently KEDA queries the event source — it determines reaction latency. `cooldownPeriod` (default 300s) controls how long KEDA waits after the last non-zero event before scaling to zero — it prevents scale-to-zero during brief quiet periods. `activationThreshold` (default 0) controls the minimum metric value needed to start pods from zero — it prevents cold starts from low-volume noise. They work at different phases: `pollingInterval` affects every evaluation; `cooldownPeriod` affects the transition from active to zero; `activationThreshold` affects the transition from zero to active.

**Q4. Your team runs a Redis queue consumer on EKS. During business hours the queue fills with thousands of tasks; overnight the queue is empty. You want zero worker pods overnight. What KEDA configuration achieves this, and what is the tradeoff?**

ScaledObject with `type: redis`, `minReplicaCount: 0`, `maxReplicaCount: N`, `listLength: <target-per-pod>`, and a `cooldownPeriod` tuned to your business hours pattern (e.g. 300s = 5 min after queue empties). The tradeoff is cold-start latency: when the first task arrives at the start of the business day, workers are at 0 replicas. KEDA must detect the queue filling (one pollingInterval), start a pod (container pull + startup time), and then HPA scales up from there. For latency-sensitive workloads, set `minReplicaCount: 1` to keep a warm pod overnight at the cost of one idle pod, or use `activationThreshold` to buffer small early-morning noise before starting pods.

**Q5. What is a TriggerAuthentication and when would you use ClusterTriggerAuthentication instead?**

TriggerAuthentication is a namespace-scoped CRD that stores credentials (typically via reference to a Kubernetes Secret) for a KEDA scaler to authenticate to a secured event source — Redis with AUTH, Kafka with SASL, SQS with AWS credentials. It is referenced from a ScaledObject via `authenticationRef`. ClusterTriggerAuthentication is the cluster-scoped equivalent — it can be referenced by ScaledObjects in any namespace. Use ClusterTriggerAuthentication when multiple teams or multiple namespaces share the same event source (e.g. one Redis instance used by `team-a` and `team-b`) and you want to manage the credentials in one place rather than duplicating TriggerAuthentication objects per namespace.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Demo concept / command | CKA objective | CKAD objective | Notes |
|---|---|---|---|
| ScaledObject CRD — structure and fields | Workloads & Scheduling (15%) | Application Deployment (20%) | Know `scaleTargetRef`, `triggers`, `minReplicaCount`, `cooldownPeriod` |
| KEDA manages HPA — no manual HPA alongside | Troubleshooting (30%) | Application Deployment (20%) | `AmbiguousSelector` is the failure mode; delete the manual HPA to fix |
| Scale-to-zero / scale-from-zero two-component mechanism | Workloads & Scheduling (15%) | Application Deployment (20%) | HPA handles 1↔N; KEDA Operator handles 0↔1 directly |
| TriggerAuthentication vs plaintext credentials | — | Application Environment, Configuration and Security (25%) | Credential handling is a CKAD-owned concern; not a distinct CKA-weighted item |
| `kubectl get scaledobject` — READY/ACTIVE/FALLBACK columns | Troubleshooting (30%) | Application Observability and Maintenance (15%) | READY=False → connectivity/target issue; ACTIVE=False → metric below threshold |
| ScaledJob vs ScaledObject | Workloads & Scheduling (15%) | Application Design and Build (20%) | Same workload-type decision family as choosing Job vs Deployment |
| Multiple triggers → MAX rule | Workloads & Scheduling (15%) | Application Deployment (20%) | Same MAX rule as HPA's multiple-metric evaluation |

### Common Exam Traps

| Scenario | What the task actually requires | Common wrong approach |
|---|---|---|
| Task deploys a ScaledObject with `minReplicaCount: 0` on a Redis-backed consumer, then edits the resulting HPA directly to change scaling behavior | Recognize the HPA is KEDA-managed (named `keda-hpa-<scaledobject-name>`) — changes belong in the ScaledObject spec, or `advanced.horizontalPodAutoscalerConfig.behavior` | Editing the generated HPA object directly, which KEDA silently overwrites on its next reconcile |
| Redis queue has been empty for several minutes with `cooldownPeriod: 60`, yet the Deployment is still at 1 replica | Check when the last event actually arrived — `cooldownPeriod` restarts on every non-zero reading, so a recent small event resets the countdown even if the queue looks empty now | Concluding KEDA is malfunctioning and manually scaling the Deployment to 0 |
| A scaler credential is stored directly in `triggers[].metadata` because the ScaledObject "works" that way | Move the credential into a Secret + TriggerAuthentication, referenced via `authenticationRef` | Leaving the credential inline since it functions correctly — functioning isn't the same as correct |
| A ScaledObject and a manually-written HPA both end up targeting the same Deployment, and scaling stops entirely | Recognize `AmbiguousSelector` from `kubectl describe scaledobject`, and delete the manual HPA — KEDA owns the HPA lifecycle for any Deployment under a ScaledObject | Deleting and recreating the ScaledObject, which doesn't resolve the conflict since the manual HPA still exists |

---

## Key Takeaways

| Concept | Detail |
|---|---|
| KEDA origin and status | CNCF Graduated (August 2023); originally Microsoft; cloud-agnostic core; 50+ built-in scalers |
| KEDA extends HPA, not replaces it | KEDA creates and manages HPA objects; HPA still reconciles pod count via the standard Kubernetes loop |
| Scale-to-zero mechanism | HPA floors at minReplicas=1; KEDA Operator detects zero metric + cooldownPeriod elapsed → directly patches Deployment to 0 |
| Scale-from-zero mechanism | KEDA Operator polls scaler at 0 replicas; detects metric > activationThreshold → patches Deployment to minReplicaCount; HPA takes over for 1→N |
| ScaledObject | Primary KEDA CRD; references scaleTargetRef + triggers; KEDA Operator creates and manages the corresponding HPA |
| ScaledJob | KEDA CRD for run-to-completion workloads; one Job per unit of work; not long-running Deployments |
| TriggerAuthentication | Namespace-scoped credential store for KEDA scalers; references Kubernetes Secrets; never put credentials in ScaledObject metadata |
| ClusterTriggerAuthentication | Cluster-scoped TriggerAuthentication; one credential object for multiple namespaces |
| pollingInterval | How often KEDA queries the event source (default: 30s); affects reaction latency |
| cooldownPeriod | How long KEDA waits after last event before scaling to zero (default: 300s); prevents thrashing |
| activationThreshold | Minimum metric value to activate from zero (default: 0); prevents cold starts from noise |
| KEDA Metrics Server | Implements `external.metrics.k8s.io`; serves metric values to HPA; registered as an APIService |
| Do not create manual HPA alongside ScaledObject | Causes AmbiguousSelector conflict; both HPAs stop functioning; delete the manual HPA |
| Prometheus scaler | Executes PromQL against Prometheus; works on minikube; no cloud required |
| Redis scaler | Monitors Redis list length or stream lag; works on minikube; scale-to-zero demonstrated |
| Cron scaler | Schedule-based; no external event source; UTC or named timezone; works on minikube |
| SQS scaler | AWS-specific; requires IRSA on EKS; hands-on in `aws-eks-demos` |
| KEDA + HPA behavior | Pass `behavior` block through `advanced.horizontalPodAutoscalerConfig` in ScaledObject |
| KEDA + VPA | Safe combination — KEDA/HPA manages replicas; VPA manages resource requests (different signals) |

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get scaledobject` | List all ScaledObjects — READY, ACTIVE, FALLBACK status |
| `kubectl describe scaledobject <name>` | Full ScaledObject status, conditions, and scaler details |
| `kubectl get scaledobject <name> -o yaml` | Full YAML including status |
| `kubectl get scaledjob` | List all ScaledJobs |
| `kubectl get triggerauthentication` | List TriggerAuthentication objects |
| `kubectl get clustertriggerauthentication` | List ClusterTriggerAuthentication objects |
| `kubectl get hpa` | List HPAs — includes KEDA-managed HPAs (named `keda-hpa-<scaledobject-name>`) |
| `kubectl get apiservices \| grep external` | Verify KEDA Metrics Server is registered for external.metrics.k8s.io |
| `kubectl api-resources \| grep keda` | List all KEDA CRDs |
| `kubectl logs -n keda -l app=keda-operator` | KEDA Operator logs — scaling decisions and errors |
| `kubectl logs -n keda -l app=keda-operator-metrics-apiserver` | Metrics Server logs — scaler queries |
| `helm uninstall keda -n keda` | Uninstall KEDA (also removes CRDs and managed HPAs) |

---

## Troubleshooting

**ScaledObject shows `READY=False`:**
```bash
kubectl describe scaledobject <name> | grep -A10 "Conditions:"
# ScalerNotReady: "deployments.apps <name> not found"
#   -> typo in scaleTargetRef.name — check spelling
# ScalerNotReady: "error connecting to redis..."
#   -> scaler cannot reach the event source
#   -> check service name, port, and TriggerAuthentication credentials
# ScalerNotReady: "AmbiguousSelector: found multiple HPAs..."
#   -> a manual HPA also targets this Deployment — delete it
```

**ScaledObject shows `READY=True` but Deployment stays at 0:**
```bash
kubectl get scaledobject <name>
# ACTIVE=False -> metric is at or below activationThreshold
# This is expected if the event source is empty
# Push test data to the queue to verify scale-from-zero works
kubectl exec deploy/redis -- redis-cli rpush task-queue test-item
```

**KEDA Metrics Server not registered:**
```bash
kubectl get apiservices | grep external
# v1beta1.external.metrics.k8s.io should show True
# If missing or False: keda-operator-metrics-apiserver pod may be crashing
kubectl get pods -n keda
kubectl logs -n keda -l app=keda-operator-metrics-apiserver | tail -20
```

**ScaledObject not scaling down to zero after queue empties:**
```bash
# Normal — cooldownPeriod must elapse before scale-to-zero
kubectl describe scaledobject <name> | grep cooldown
# Default: 300s (5 minutes)
# If faster scale-to-zero is needed, reduce cooldownPeriod in ScaledObject spec
```

**Prometheus scaler shows `READY=False` (cannot reach Prometheus):**
```bash
kubectl describe scaledobject <name> | grep serverAddress
# Verify the Prometheus service address matches your installation
kubectl get svc -n monitoring | grep prometheus
# Use the correct ClusterIP service name and port (typically 9090)
# The kube-prometheus-stack service name varies by Helm release name
```

---

## Appendix — Anki Cards

**`04-keda-adapter-anki.csv`:**

```
#deck:k8s-platform-labs::11-auto-scaling::04-keda-adapter
#separator:Comma
#columns:Front,Back,Tags
"HPA requires minReplicas >= 1. How does KEDA enable scale-to-zero when HPA cannot?","KEDA Operator monitors the scaler independently. When metric=0 AND cooldownPeriod has elapsed, KEDA Operator directly patches Deployment.spec.replicas=0, bypassing HPA. Scale-from-zero: Operator polls scaler at 0 replicas; when metric > activationThreshold, Operator patches to minReplicaCount; then HPA takes over for 1->N.","04-keda-adapter,architecture,scale-to-zero"
"Does KEDA replace HPA?","No. KEDA creates and manages HPA objects. HPA still reconciles pod count via the standard Kubernetes loop. KEDA adds: (1) scale-to-zero by direct Deployment patching, (2) scale-from-zero by polling at 0 replicas, (3) 50+ built-in scalers via its Metrics Server.","04-keda-adapter,architecture"
"What is a ScaledObject, and what does the KEDA Operator create from it?","ScaledObject (keda.sh/v1alpha1) is the primary KEDA CRD. It references a scaleTargetRef (Deployment), triggers (scaler type + config), minReplicaCount, maxReplicaCount, pollingInterval, cooldownPeriod. KEDA Operator creates a corresponding HPA (named keda-hpa-<scaledobject-name>) that uses KEDA Metrics Server as its External metric source.","04-keda-adapter,scaledobject,architecture"
"You kubectl get hpa and see keda-hpa-worker-redis-scaler. Who created it and can you edit it?","KEDA Operator created it automatically when a ScaledObject targeting the worker Deployment was applied. Do NOT edit or delete it directly — KEDA will overwrite any changes and will recreate it if deleted. Manage scaling by editing the ScaledObject instead.","04-keda-adapter,scaledobject,hpa"
"What happens if you create a manual HPA alongside a KEDA ScaledObject targeting the same Deployment?","AmbiguousSelector conflict. The HPA controller cannot determine which HPA is authoritative and stops processing both. KEDA reports ScalerNotReady. The Deployment replica count freezes. Fix: delete the manual HPA. KEDA owns the HPA for any Deployment it manages via ScaledObject.","04-keda-adapter,break-fix,conflict"
"What is the difference between pollingInterval, cooldownPeriod, and activationThreshold in a ScaledObject?","pollingInterval (default 30s): how often KEDA queries the event source — affects reaction latency. cooldownPeriod (default 300s): how long KEDA waits after last event before scaling to zero — prevents thrashing. activationThreshold (default 0): minimum metric value to start pods from zero — prevents cold starts from noise.","04-keda-adapter,scaledobject,timing"
"What is a TriggerAuthentication, and when would you use ClusterTriggerAuthentication?","TriggerAuthentication (keda.sh/v1alpha1) is namespace-scoped; stores credentials for a KEDA scaler via reference to a Kubernetes Secret. Referenced from ScaledObject via authenticationRef. ClusterTriggerAuthentication is cluster-scoped — any namespace can reference it. Use ClusterTriggerAuthentication when multiple namespaces share the same event source and credentials.","04-keda-adapter,triggerauthentication"
"A ScaledObject shows READY=True but ACTIVE=False. What does this mean?","READY=True: KEDA can reach the event source and the target Deployment exists. ACTIVE=False: the current metric value is at or below activationThreshold (e.g. the queue is empty). This is the expected state when the event source has no work — the Deployment may be at 0 replicas waiting for work to arrive.","04-keda-adapter,troubleshooting,status"
"What KEDA CRD would you use for batch processing (one Job per unit of work) vs long-running queue consumer (Deployment)?","ScaledJob for batch/run-to-completion: each trigger fires a Kubernetes Job that processes one unit of work and completes. ScaledObject for long-running Deployment: the Deployment scales up/down continuously based on queue depth, never completing.","04-keda-adapter,scaledjob,scaledobject"
"What is the scale-from-zero sequence in KEDA?","1. Deployment is at 0 replicas. HPA is inactive (KEDA suspends it at 0). 2. KEDA Operator polls the scaler every pollingInterval. 3. Scaler reports metric > activationThreshold. 4. KEDA Operator patches Deployment to minReplicaCount (e.g. 1). 5. Pod starts; HPA activates and calculates desired replicas. 6. HPA scales from 1 to N based on metric.","04-keda-adapter,scale-from-zero,architecture"
"You want KEDA to only activate from zero when the Redis queue has more than 10 items (to avoid cold starts from noise). Which field do you set and where?","Set activationThreshold: 10 in the ScaledObject spec (top-level, not inside triggers). This means KEDA will not start pods from 0 unless the scaler reports > 10 items. The listLength (targetValue) field controls per-pod scaling once active and is separate from activationThreshold.","04-keda-adapter,activationthreshold,scaledobject"
"The Prometheus scaler in KEDA uses a PromQL query. Does KEDA query Prometheus directly?","Yes. The KEDA Metrics Server executes the PromQL query against the Prometheus HTTP API (serverAddress in trigger metadata). No additional adapter is needed — KEDA's built-in Prometheus scaler knows the Prometheus query format. This differs from the generic Prometheus Adapter (05-prometheus-adapter), which configures HPA to query Prometheus indirectly.","04-keda-adapter,prometheus-scaler,architecture"
"Why does the SQS scaler require EKS and cannot run on minikube?","SQS GetQueueAttributes requires AWS credentials. The recommended authentication method is IRSA (IAM Role for Service Accounts), which requires EKS control plane integration to link a Kubernetes ServiceAccount to an IAM role. Without IRSA, static AWS credentials in a Kubernetes Secret are an alternative but not recommended for production. The SQS queue itself is also an AWS service.","04-keda-adapter,sqs-scaler,eks"
""(CKA/CKAD) A KEDA ScaledObject with minReplicaCount: 0 has had an empty Redis queue for 10 minutes (cooldownPeriod: 60). kubectl get pods shows 0 pods. A new item arrives. Describe the exact sequence of events to reach 2 running pods.","1. KEDA Operator detects metric=1 (> activationThreshold=0). 2. Operator patches Deployment.spec.replicas=1. 3. Pod starts (container pull + init). 4. HPA activates: queries KEDA Metrics Server, gets listLength=1, targetValue=5 per pod. 5. desiredReplicas=ceil[1 x (1/5)]=1. 6. HPA stays at 1 (metric below target). 7. Queue grows to 10: desiredReplicas=ceil[1 x (10/5)]=2. 8. HPA scales to 2.","04-keda-adapter,cka-workloads-scheduling,ckad-application-deployment,scale-from-zero"
"(CKA/CKAD) kubectl describe scaledobject shows ScalerNotReady: AmbiguousSelector. What caused this and how do you fix it?","Cause: a manually-created HPA also targets the same Deployment as the ScaledObject. The HPA controller finds multiple HPAs for the same scaleTargetRef and refuses to process either. Fix: kubectl get hpa to identify the manual HPA (the KEDA-managed one is named keda-hpa-<scaledobject-name>); kubectl delete hpa <manual-hpa-name>. KEDA will restore normal operation within one pollingInterval.","04-keda-adapter,cka-troubleshooting,ckad-observability-maintenance,break-fix"
```

---

## Appendix — Quiz

````markdown
# Quiz — 11-auto-scaling/04-keda-adapter: KEDA — Event-Driven Autoscaling and Scale to Zero

> One correct answer per question unless stated otherwise.
> Target: 13/15 or above before moving to 05-prometheus-adapter.

**Q1. HPA requires `minReplicas >= 1`. How does KEDA achieve scale-to-zero?**

A. KEDA replaces HPA with its own controller that supports 0 replicas
B. KEDA Operator directly patches Deployment.spec.replicas=0, bypassing HPA for the final 1→0 step
C. KEDA sets HPA `minReplicas: 0` on the managed HPA object
D. KEDA uses the VPA Updater to evict the last pod

<details>
<summary>Answer</summary>

**B** — HPA scales from N down to 1 (its floor); KEDA Operator then handles 1→0 by directly patching the Deployment spec, bypassing HPA entirely for this final step.

Trap A: KEDA does not replace HPA — it creates and manages HPA objects. Trap C: HPA does not support `minReplicas: 0` in the HPA spec; `minReplicaCount: 0` is a ScaledObject field. Trap D: VPA Updater has no role in KEDA scaling.

</details>

---

**Q2. You create a ScaledObject targeting the `worker` Deployment. What does KEDA create automatically?**

A. A VPA targeting the same Deployment
B. A Pod that runs the KEDA scaler logic
C. An HPA named `keda-hpa-<scaledobject-name>` targeting the same Deployment
D. A ClusterTriggerAuthentication for the event source

<details>
<summary>Answer</summary>

**C** — KEDA Operator creates and manages an HPA object for every ScaledObject. The HPA is named `keda-hpa-<scaledobject-name>` and uses KEDA Metrics Server as its External metric source.

Trap A: VPA is unrelated to KEDA. Trap B: the scaler logic runs inside the KEDA Operator and Metrics Server — not as a separate Pod per ScaledObject. Trap D: TriggerAuthentication is created by you, not by KEDA.

</details>

---

**Q3. You create both a ScaledObject and a manual HPA targeting the same Deployment. What happens?**

A. The ScaledObject takes precedence; the manual HPA is ignored
B. The manual HPA takes precedence; the ScaledObject is ignored
C. AmbiguousSelector conflict — both HPAs stop functioning; Deployment replica count freezes
D. KEDA merges the two HPAs into one

<details>
<summary>Answer</summary>

**C** — The HPA controller detects two HPAs targeting the same Deployment and cannot determine which is authoritative. Both stop processing. KEDA reports `ScalerNotReady`. Fix: delete the manual HPA.

Trap A: there is no precedence — the conflict breaks both. Trap B: same reason. Trap D: KEDA does not merge HPAs.

</details>

---

**Q4. What is `cooldownPeriod` in a ScaledObject?**

A. How often KEDA queries the event source
B. How long KEDA waits between scale-up events
C. How long KEDA waits after the last non-zero event before scaling to zero
D. The minimum time between two consecutive pod evictions

<details>
<summary>Answer</summary>

**C** — `cooldownPeriod` (default 300s) is the grace period KEDA waits after the event source becomes empty before scaling the Deployment to 0. This prevents unnecessary scale-to-zero during brief quiet periods.

Trap A: that is `pollingInterval`. Trap B: scale-up timing is controlled by HPA `behavior`. Trap D: pod eviction is not a KEDA concept.

</details>

---

**Q5. Your Deployment is at 0 replicas. The Redis queue receives 1 test message every few hours from a monitoring tool — not real work. You want to avoid unnecessary cold starts from this noise. Which field do you set?**

A. `cooldownPeriod: 0`
B. `pollingInterval: 3600`
C. `activationThreshold: 5`
D. `minReplicaCount: 1`

<details>
<summary>Answer</summary>

**C** — `activationThreshold` sets the minimum metric value needed to activate the Deployment from 0 replicas. Setting it to 5 means KEDA will only start pods if queue depth exceeds 5 — single test messages are ignored.

Trap A: `cooldownPeriod: 0` makes scale-to-zero more aggressive, not less reactive to noise. Trap B: reducing polling frequency helps but means slower response to real work. Trap D: `minReplicaCount: 1` keeps a pod always running — defeats scale-to-zero.

</details>

---

**Q6. What is the correct way to store Redis credentials for use by a KEDA scaler?**

A. Set `password: mysecret` in the ScaledObject trigger metadata
B. Create a TriggerAuthentication referencing a Kubernetes Secret; reference it from the ScaledObject via `authenticationRef`
C. Set `password: mysecret` in the KEDA Operator's environment variables
D. Annotate the Redis Service with the password

<details>
<summary>Answer</summary>

**B** — TriggerAuthentication references a Kubernetes Secret and injects the credential into the scaler at runtime. The ScaledObject never contains the credential directly.

Trap A: plaintext in ScaledObject metadata is stored in etcd and visible in `kubectl get scaledobject -o yaml` — a security risk. Trap C and D: neither approach is supported by KEDA.

</details>

---

**Q7. Which KEDA CRD would you use to process one batch of S3 files — where each file should be processed by its own short-lived pod that exits when done?**

A. ScaledObject
B. ScaledJob
C. TriggerAuthentication
D. ClusterTriggerAuthentication

<details>
<summary>Answer</summary>

**B** — ScaledJob creates one Kubernetes Job per unit of work. Each Job pod processes one item and exits. ScaledObject is for long-running Deployments that scale based on queue depth but never "complete."

Trap A: ScaledObject targets Deployments (long-running). Trap C and D: these are for credentials, not scaling targets.

</details>

---

**Q8. What does the KEDA Metrics Server implement, and how does HPA use it?**

A. It implements `metrics.k8s.io` — HPA reads CPU/memory from it
B. It implements `external.metrics.k8s.io` — HPA queries it for event source metrics via the External Metrics API
C. It implements `custom.metrics.k8s.io` — HPA queries it for Pods and Object metric types
D. It runs as a sidecar in each worker pod

<details>
<summary>Answer</summary>

**B** — KEDA Metrics Server registers as an APIService for `external.metrics.k8s.io`. The HPA KEDA creates uses `type: External` metrics, querying KEDA Metrics Server for scaler values (Redis list length, queue depth, etc.).

Trap A: `metrics.k8s.io` is served by metrics-server, not KEDA. Trap C: KEDA does not serve the Custom Metrics API (though Prometheus Adapter does). Trap D: KEDA Metrics Server is a cluster-wide Deployment, not per-pod.

</details>

---

**Q9. A ScaledObject has `triggers: [{type: redis, listLength: "5"}, {type: cron, desiredReplicas: "3"}]`. The Redis queue has 20 items and the cron window is active. What replica count does KEDA target?**

A. 4 (Redis: ceil[1 x 20/5] = 4)
B. 3 (Cron: desiredReplicas)
C. 7 (4 + 3 combined)
D. 4 (MAX of Redis=4 and Cron=3)

<details>
<summary>Answer</summary>

**D** — When multiple triggers are configured, KEDA (via the managed HPA) evaluates each and takes the MAX desired replica count — the same MAX rule as HPA multiple metrics. Redis says 4; Cron says 3; MAX = 4.

Trap A: correct calculation for Redis alone but ignores Cron. Trap B: correct for Cron alone but ignores Redis. Trap C: triggers are not summed — MAX is applied.

</details>

---

**Q10. `kubectl get scaledobject` shows `READY=False` for your Redis-backed ScaledObject. The Redis pod is running. What is the most likely cause?**

A. The Redis queue is empty
B. KEDA cannot reach the Redis service (wrong address, port, or auth)
C. The Deployment has 0 replicas
D. metrics-server is not running

<details>
<summary>Answer</summary>

**B** — `READY=False` means KEDA cannot successfully query the event source — typically a connection error (wrong service address, wrong port, missing authentication). An empty queue shows `READY=True, ACTIVE=False`.

Trap A: empty queue → `ACTIVE=False`, not `READY=False`. Trap C: 0 replicas is the expected scale-to-zero state, not a readiness error. Trap D: KEDA Metrics Server implements external.metrics.k8s.io independently of metrics-server.

</details>

---

**Q11. Which of these scalers requires cloud infrastructure (AWS) and CANNOT run on minikube?**

A. Prometheus scaler
B. Redis list scaler
C. Cron scaler
D. SQS queue scaler

<details>
<summary>Answer</summary>

**D** — The SQS scaler requires an AWS SQS queue and AWS credentials (IRSA on EKS). Prometheus, Redis, and Cron scalers are all cloud-agnostic and run on minikube without AWS access.

</details>

---

**Q12. You delete a ScaledObject. What happens to the managed HPA and the Deployment?**

A. HPA is deleted by KEDA; Deployment replica count is unchanged
B. HPA is deleted by KEDA; Deployment is restored to its original replica count (if `restoreToOriginalReplicaCount: true`)
C. HPA remains; Deployment is scaled to 0
D. Both HPA and Deployment are deleted

<details>
<summary>Answer</summary>

**B** — KEDA automatically deletes the managed HPA when its ScaledObject is deleted. If `advanced.restoreToOriginalReplicaCount: true` is set in the ScaledObject, the Deployment is restored to its pre-KEDA replica count. If false (default), the Deployment stays at whatever replica count KEDA last set — potentially 0.

Trap A: replica count behaviour depends on `restoreToOriginalReplicaCount`. Trap C: HPA is deleted along with the ScaledObject. Trap D: KEDA never deletes the target Deployment.

</details>

---

**Q13. (CKA/CKAD-style) You have a KEDA ScaledObject with `minReplicaCount: 0` and `cooldownPeriod: 60`. The Redis queue has been empty for 2 minutes. `kubectl get pods -l app=worker` shows 1 running pod. What is the most likely cause?**

A. KEDA is malfunctioning — it should have scaled to 0 by now
B. The cooldownPeriod has not elapsed since the last event (1 event arrived 30 seconds ago)
C. `minReplicaCount: 0` is invalid — HPA requires min >= 1
D. The KEDA Operator pod is not running

<details>
<summary>Answer</summary>

**B** — `cooldownPeriod: 60` means KEDA waits 60 seconds after the LAST non-zero event before scaling to zero. If an event arrived 30 seconds ago, the cooldown restarts. 2 minutes of empty queue does not mean 2 minutes since the last event.

Trap A: KEDA is functioning as designed — the cooldown timer resets on each event. Trap C: `minReplicaCount: 0` is valid in ScaledObject (unlike HPA where `minReplicas: 0` is invalid). Trap D: if the Operator were down, the ScaledObject would show `READY=False`.

</details>

---

**Q14. What is the key difference between TriggerAuthentication and ClusterTriggerAuthentication?**

A. TriggerAuthentication supports Secrets; ClusterTriggerAuthentication supports only IRSA
B. TriggerAuthentication is namespace-scoped; ClusterTriggerAuthentication is cluster-scoped and reusable across namespaces
C. ClusterTriggerAuthentication is only for AWS credentials
D. They are identical — the names are interchangeable

<details>
<summary>Answer</summary>

**B** — TriggerAuthentication is namespace-scoped; ScaledObjects in the same namespace can reference it. ClusterTriggerAuthentication is cluster-scoped; ScaledObjects in ANY namespace can reference it. Use ClusterTriggerAuthentication when multiple teams/namespaces share the same secured event source.

Trap A: both support Secrets and IRSA. Trap C: ClusterTriggerAuthentication works with any backend. Trap D: the scope difference is significant.

</details>

---

**Q15. (CKA/CKAD-style) A KEDA ScaledObject uses the Prometheus scaler. `READY=False`, with error "error calling Prometheus API". Prometheus is running. What should you check first?**

A. Whether the Redis pod is running
B. The `serverAddress` in the trigger metadata — verify it matches the actual Prometheus ClusterIP service name and port
C. Whether metrics-server is enabled
D. Whether the ScaledObject has a TriggerAuthentication reference

<details>
<summary>Answer</summary>

**B** — The most common cause of Prometheus scaler `READY=False` is a wrong `serverAddress`. The kube-prometheus-stack service name varies by Helm release name and namespace. Verify with `kubectl get svc -n monitoring | grep prometheus` and update the ScaledObject trigger metadata accordingly.

Trap A: Redis is unrelated to the Prometheus scaler. Trap C: KEDA Metrics Server is independent of metrics-server. Trap D: Prometheus does not require authentication by default — no TriggerAuthentication is needed unless Prometheus has auth enabled.

</details>

---

| Score | Action |
|---|---|
| 15/15 | Import Anki cards, move to next Demo |
| 14/15 | Review the wrong answer, then proceed |
| 13/15 | Re-read the relevant Concepts section, retry those questions |
| Below 13/15 | Re-read the full lab and redo the walkthrough before proceeding |
````