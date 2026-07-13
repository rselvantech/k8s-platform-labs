# Demo: 11-auto-scaling/04-keda-fundamentals — KEDA Architecture, ScaledObjects, and Scale-to-Zero

## Lab Overview

`03-vpa-fundamentals` closed out the resource-sizing side of autoscaling — HPA and VPA both assume a workload is always running at least one replica. That assumption breaks down for event-driven workloads: a queue consumer, a scheduled batch job, or a webhook processor may have nothing to do for hours at a time. HPA's `minReplicas` must be ≥ 1 — it has no concept of "zero," and no way to notice an event source going from empty to non-empty on its own.

KEDA (Kubernetes Event-Driven Autoscaling) closes that gap. It does not replace HPA — it extends it. KEDA creates and manages HPA objects on your behalf, and adds exactly the two things HPA structurally cannot do: scale a Deployment to zero replicas, and scale it back up the moment an event source has work again.

**Real-world scenario:** A scheduled reporting job's worker pods only need to run during a fixed nightly batch window — say, 1 AM–3 AM — and sit completely idle the other 22 hours. Running `minReplicas: 1` around the clock means paying for 22 hours of idle compute every day for a workload that does nothing outside its 2-hour window. KEDA's Cron scaler expresses this directly: zero replicas outside the window, a defined replica count inside it, no external event source required at all.

**What this lab covers:**
- The big picture first: KEDA is two components doing two different jobs — read this before anything else if the mechanics below ever feel disconnected
- KEDA architecture — Operator, Metrics Server, and how the two pieces divide responsibility
- Kubernetes Objects KEDA Creates — orientation section, moved early so the abstract diagram has something concrete to anchor to
- ScaledObject CRD — full field reference
- How KEDA creates and manages HPA objects underneath a ScaledObject
- The two separate polling loops (KEDA's own activation poll vs. HPA's own metric-fetch poll) — one consolidated explanation, not scattered across three places
- Activation vs. Scaling — the two separate numeric decisions a single trigger makes
- Scale-to-zero and scale-from-zero mechanics — the capstone section that ties every earlier piece together into one end-to-end sequence, deliberately placed right before the hands-on lab
- Cron scaler — scheduled scaling with no external event source (this lab's hands-on vehicle)
- Where KEDA's Prometheus scaler and the Redis scaler fit, and why they're covered in later demos, not here

> **Scope note:** This demo covers KEDA's architecture and mechanics using the Cron scaler, which needs no additional infrastructure (no Redis, no Prometheus) — keeping the hands-on focused on KEDA itself rather than a second system's setup. The Redis scaler, full scale-to-zero/from-zero cycle against a real queue, and TriggerAuthentication hands-on are covered in `05-keda-redis-scaler`. KEDA's Prometheus scaler is covered as a short theory comparison later in this demo's Concepts — the hands-on Prometheus work belongs to the Prometheus Adapter demos (`06`, `07`), which teach a different (but related) bridging mechanism.
>
> **Verification status:** Steps 1–4's command outputs are real, captured output from a live `3node` minikube cluster (KEDA chart `2.20.0`) — not idealized/invented output. The worked numeric example for `activationThreshold` is an illustrative walkthrough, not captured from a live run. The `cooldownPeriod` worked example, however, **is** confirmed against real captured timestamps from this cluster — see the timestamped `ACTIVE` transition and event data in the `cooldownPeriod` subsection of Concepts., since they use round numbers chosen for clarity — the mechanism they describe is what Step 3's real output demonstrates directly. This revision's Concepts additions (the CPU/Memory trigger scale-to-zero limitation, the admission-webhook order-matters nuance, the `HPAScaleToZero` alpha feature gate) are sourced from current upstream KEDA and Kubernetes documentation, not captured from this cluster — they describe general KEDA/Kubernetes behavior, not something this specific lab exercises hands-on.

---

## Prerequisites

**Required Software:**
- minikube `3node` profile — same cluster used throughout `11-auto-scaling`
- kubectl installed and configured
- Helm v3 (used to install KEDA)
- metrics-server enabled (already done in `01-hpa-basic`)

**Verify before starting:**
```bash
kubectl get pods -n kube-system | grep metrics-server
helm version --short
# Both must succeed before proceeding
```

**Knowledge Requirements:**
- **REQUIRED:** Completion of `01-hpa-basic` — HPA architecture, the metrics pipeline, scale subresource
- **REQUIRED:** Completion of `03-vpa-fundamentals` — this demo's Recall Check draws on it directly
- **RECOMMENDED:** Completion of `02-hpa-advanced` — HPA's `External` metric type is the API group KEDA relies on

---

## Lab Objectives

1. ✅ Explain the KEDA architecture — Operator and Metrics Server, and what each is responsible for
2. ✅ Explain how KEDA creates and manages an HPA object from a ScaledObject
3. ✅ Explain the scale-to-zero and scale-from-zero sequences, and which component (KEDA Operator vs. HPA) handles each part
4. ✅ Write a ScaledObject using the Cron scaler and observe a full outside-window → inside-window → outside-window cycle
5. ✅ Diagnose a `scaleTargetRef` typo, an AmbiguousSelector conflict, and a `cooldownPeriod`-related scale-down delay from symptoms alone
6. ✅ Explain why KEDA's Prometheus scaler and the Prometheus Adapter aren't really competing for the same job

---

## Directory Structure

```
11-auto-scaling/04-keda-fundamentals/
├── README.md                              # this file
├── 04-keda-fundamentals-anki.csv          # Anki flashcard deck
├── 04-keda-fundamentals-quiz.md            # standalone quiz
└── src/
    ├── 01-worker-deploy.yaml                  # the Deployment all ScaledObjects in this lab target
    ├── 02-scaledobject-cron.yaml               # ScaledObject — Cron scaler
    └── break-fix/
        ├── 01-scaledobject-wrong-target.yaml     # broken: scaleTargetRef name mismatch
        ├── 02-scaledobject-conflict-hpa.yaml     # broken: ScaledObject + manual HPA on same target
        └── 03-scaledobject-cooldown-surprise.yaml # broken (conceptually): default cooldownPeriod misread as instant
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

2. `maxAllowed` is clamping the recommendation downward. The histogram data says the container needs 200m CPU (Uncapped Target), but `resourcePolicy.containerPolicies[].maxAllowed.cpu` is set at or below 50m, forcing Target to be capped at the ceiling. The container is permanently under-provisioned and will be CPU-throttled at peak. Action: raise `maxAllowed.cpu` to at least 220m (110–120% of Uncapped Target as headroom).

3. The underlying conflict to avoid: HPA's Resource/ContainerResource utilisation formula is `usage / request × 100`. If VPA changes `request` while HPA is scaling on that same CPU/memory metric, the formula's output shifts with no change in actual usage, and the two feed each other into oscillation. There are two safe configurations:
   - **Option A — HPA on CPU/memory + VPA in `Off` mode:** VPA observes and recommends only; it never touches `resources.requests` automatically, so HPA's denominator never shifts. VPA stays in Off mode indefinitely here — periodically review `kubectl describe vpa` and manually apply a diverged recommendation as a deliberate, reviewed change, not a continuous automated one.
   - **Option B — HPA on a custom/external metric (e.g. `http_request_count`) + VPA in `Recreate` or `InPlaceOrRecreate` mode:** since HPA's formula has no dependency on `resources.requests` at all, VPA is free to actively resize CPU/memory. Caveat: this removes the direct formula-level coupling, but not every system-level interaction — VPA resizing CPU can still change how much traffic a pod sustains before latency degrades, indirectly moving a metric like `http_request_count`. That's a weak, indirect effect, not the guaranteed direct distortion Option A and B both exist to eliminate.

</details>

---

## Concepts

### The Big Picture — Two Components, Two Jobs

Read this paragraph before anything else below. Every mechanic in this demo is one of two components doing exactly one job — if you keep this straight, the rest of Concepts is filling in detail, not adding new moving parts.

KEDA installs as two working Deployments (a third, the admission webhook, only validates config — it doesn't participate in scaling). **`keda-operator`** watches your ScaledObjects and owns the 0↔1 edge directly: it decides when a target should wake up from zero or go back to zero, and it makes that happen by patching the Deployment itself — no HPA involved. **`keda-operator-metrics-apiserver`** does something completely different: it answers questions. When the ordinary Kubernetes HPA (which `keda-operator` created on your behalf) wants to know "what's the current queue length / event rate / cron state," it asks this component, which translates the question into a live query against the real event source and hands back an answer in the format HPA expects.

So there are two tracks, not one pipeline:
- **Track 1 — the 0↔1 edge:** `keda-operator` alone, directly patching the Deployment. HPA is never consulted for this step.
- **Track 2 — the 1↔N range:** the ordinary HPA `keda-operator` created, asking `keda-operator-metrics-apiserver` for numbers, exactly the way any other HPA asks metrics-server for CPU numbers.

Everything from here — the architecture diagram, the two polling loops, activation vs. scaling, `cooldownPeriod` — is detail on top of this one split. The "Scale-to-Zero and Scale-from-Zero Mechanics" section near the end of Concepts is the moment all of that detail gets reassembled into one worked sequence; if you want the short version before diving into the detail, skim that section first, then come back here.

### KEDA Architecture

```
 External Event Sources (50+ scalers)          KEDA Control Plane (keda namespace)              Kubernetes Control Plane
 ┌─────────────────────────────┐        ┌───────────────────────────────────────┐        ┌───────────────────────────────┐
 │ Kafka · RabbitMQ · Redis    │        │  keda-operator (Deployment)           │        │   kube-apiserver              │
 │ Azure Service Bus · AWS SQS │        │  - Watches ScaledObject/ScaledJob CRDs│        │                               │
 │ Google Pub/Sub · Prometheus │        │  - Creates/updates the managed HPA    │        │                               │
 │ Cron (no external source)   │        │  - Handles scale-to-zero/from-zero    │        │                               │
 │ ...and 40+ more             │        │    (activates/deactivates scalers)    │        │                               │
 └──────────────┬──────────────┘        └─────────────────┬─────────────────────┘        └─────────────────┬─────────────┘
                │    Metrics queries                      │ Activates/                                     │
                │◄────────────────────────────────────────│ Deactivates                                    │
                │    Metric values                        │ scalers                                        │
                │────────────────────────────────────────►│                                                │
                │                          ┌──────────────▼───────────────────────┐        ┌───────────────▼───────────────┐
                │                          │  keda-operator-metrics-apiserver     │◄──────►│  APIService                   │
                │                          │  (Deployment)                        │  Reads │  external.metrics.k8s.io      │
                │                          │  - Implements external.metrics.k8s.io│        │  (routes to keda-operator-    │
                │                          │  - Receives metric requests from HPA │        │   metrics-apiserver)          │
                │                          │  - Maps request to the right scaler  │        └───────────────┬───────────────┘
                │                          │  - Queries external system, returns  │                        │    HPA requests
                │                          │    metric value                      │                        │    metric via
                │                          └──────────────▲───────────────────────┘                        │    External API
                │                                         │ Reads                                          ▼
                │                          ┌──────────────┴──────────────────────┐         ┌───────────────────────────────┐
                │                          │  KEDA CRDs                          │         │  HPA (generated by KEDA)      │
                │                          │  ScaledObject / ScaledJob           │◄────────│  - Gets metrics from          │
                │                          │  TriggerAuthentication /            │         │    external.metrics.k8s.io    │
                │                          │  ClusterTriggerAuthentication       │ Creates │  - Calculates desired replicas│
                │                          └─────────────────────────────────────┘ /Updates└──────────────┬────────────────┘
                │                                                                                         │
                │                                                                             ┌───────────▼────────────────┐
                │                                                                             │  Workload (Deployment)     │
                │                                                                             │  - Scale target            │
                │                                                                             │  - Pods created/scaled     │
                │                                                                             └──────────────┬─────────────┘
                │                                                                                            ▼
                │                                                                                         Pods
```

This is the same two-track split from "The Big Picture" above, now with every box labelled. `keda-operator` on the left drives activation directly. `keda-operator-metrics-apiserver` on the right only ever answers metric questions for the HPA — it never touches replica count itself.


**Message flow — three separate scenarios, because "how KEDA works" isn't one single path:**

KEDA's message flow genuinely differs depending on what's happening — collapsing it into one numbered list (as an earlier version of this diagram did) hides that there are two entirely independent tracks, plus failure modes that never reach either track at all.

**Scenario A — normal 1↔N scaling (Deployment already has ≥1 replica, ordinary HPA loop):**
1. HPA controller's own reconcile loop (its sync period, default 15s — not KEDA's `pollingInterval`) requests a metric via the External Metrics API
2. `keda-operator-metrics-apiserver` receives the request, queries the trigger source fresh (Redis, Prometheus, etc. — by default, no caching; see "The Two Polling Loops" below)
3. The metric value is returned to HPA in External Metrics API format
4. HPA calculates desired replicas and updates the workload's scale subresource
5. The ReplicaSet controller reconciles actual pod count to match

**Scenario B — scale-to-zero / scale-from-zero (the 0↔1 edge, entirely outside HPA):**
1. `keda-operator` polls the trigger on its own separate schedule (`pollingInterval`) — this is a different poll from Scenario A's HPA-driven query
2. `keda-operator` evaluates the trigger's `IsActive` condition (for Cron: is the current time inside the scheduled window; for Redis: does the metric exceed `activationThreshold`)
3. If activating from zero: `keda-operator` directly patches `Deployment.spec.replicas` to `minReplicaCount` — HPA is not involved in this step at all
4. If deactivating to zero: `keda-operator` waits until `cooldownPeriod` has elapsed since the last active reading, then directly patches `Deployment.spec.replicas` to 0 — again, HPA is not involved

**Scenario C — failure paths (must-know negative scenarios):**
- **Target Deployment doesn't exist** (typo in `scaleTargetRef.name`): `keda-operator` never creates the managed HPA at all. ScaledObject shows `READY=False`. Nothing in Scenario A or B ever starts. (Break-Fix Error-1)
- **A second HPA already targets the same Deployment**: whether this is caught depends on the order the two objects were created in, not just their existence — see "What Each Component Does" below for the precise rule. (Break-Fix Error-2)
- **Trigger source is unreachable** (wrong Redis address, expired credentials): `keda-operator`'s poll (Scenario B, step 1) fails. ScaledObject shows `READY=False` with a connection-specific error in Conditions. Scenario A's HPA-driven query would fail the same way if it ever got that far, but with `READY=False` it usually never does — Scenario B fails first since `keda-operator`'s own poll runs regardless of HPA's involvement.

---

### What Each Component Does

```
keda-operator (Deployment)
  Role:    watches ScaledObject and ScaledJob CRDs
  Process: when a ScaledObject is created:
           -> creates or updates an HPA object targeting the same workload
           -> configures the HPA to use KEDA Metrics Server as its metric source
           -> manages the HPA lifecycle (updates, deletion)
           -> runs its OWN separate poll of every trigger (see below) to decide
              activation state and drive the 0<->1 edge directly

keda-operator-metrics-apiserver (Deployment)
  Role:    implements external.metrics.k8s.io for KEDA scalers
  Process: when HPA controller queries the External Metrics API:
           -> KEDA Metrics Server translates the request to a scaler-specific query
           -> queries the trigger source live (by default -- see caching note below)
           -> returns the metric value to HPA in External Metrics API format
  Replaces: the need to install a separate metrics adapter per event source

keda-admission-webhooks (Deployment)
  Role:    validates KEDA resources (ScaledObject, ScaledJob, TriggerAuthentication)
           at the moment they're applied
  Catches: two ScaledObjects targeting the same Deployment -- rejected at apply time.
           Also catches a NEW ScaledObject being created when a conflicting HPA
           (KEDA-managed or manual) already exists on that target -- rejected at
           apply time, same as the duplicate-ScaledObject case.
  Does NOT catch: a manual, non-KEDA HPA created AFTER a ScaledObject already
           exists on that target. Order is what decides this, not just whether a
           conflict exists: the webhook validates KEDA resources being applied
           against the CURRENT state of the cluster at that moment. If the
           ScaledObject already existed first, the manual HPA is not itself a KEDA
           resource, so this webhook never runs against it at all -- it applies
           successfully, and the conflict only surfaces afterward at the ordinary
           Kubernetes HPA-controller level (see Scenario C above).
```

---

### Kubernetes Objects KEDA Creates — What to Expect When You `kubectl get` Around the Cluster

Since this is likely your first time installing a genuinely new operator-pattern tool in this series, here's what actually exists in the cluster after `helm install keda` — the same kind of orientation you'd want for any new product before trusting its output. This is deliberately placed right after the architecture diagram above, before the CRD and field-level detail below, so the abstract boxes in that diagram have something concrete to anchor to.

```
Namespace: keda
  Pods (3, one per Deployment below):
    keda-operator-<hash>                       -- the controller described above
    keda-operator-metrics-apiserver-<hash>      -- the External Metrics API implementation
    keda-admission-webhooks-<hash>              -- validates KEDA resources at apply time

  Deployments (3): one per pod above -- each is a normal, ordinary Kubernetes
    Deployment; KEDA itself is scaled/managed the same way any other workload
    in this series has been (this is not circular -- KEDA's own pods are NOT
    autoscaled by KEDA)

  Services: ClusterIP services fronting each Deployment above, used for the
    APIService registration (keda-operator-metrics-apiserver) and for the
    admission webhook's HTTPS endpoint (keda-admission-webhooks) that
    kube-apiserver calls into on every KEDA resource apply

  ConfigMaps / Secrets: KEDA's Helm chart creates a small number of internal
    ConfigMaps (chart metadata) and a Secret holding the admission webhook's
    TLS certificate -- nothing you interact with directly in this demo

Cluster-scoped (not namespaced to keda):
  CRDs: ScaledObject, ScaledJob, TriggerAuthentication, ClusterTriggerAuthentication,
    CloudEventSource, ClusterCloudEventSource (the last two are for KEDA's
    event-emission feature -- out of scope for this demo)
  APIService: v1beta1.external.metrics.k8s.io, routed to
    keda-operator-metrics-apiserver

No GUI ships with KEDA itself -- kubectl and the resources above are the
entire interface for this demo. (Third-party dashboards like Kedify's exist,
but are separate products, not part of open-source KEDA.)
```

---

### KEDA CRDs — Full Picture (Cron Used Hands-On Here; the Others Are Covered in `05-keda-redis-scaler`)

```
ScaledObject — keda.sh/v1alpha1
  What it is: the primary resource you create to tell KEDA what to scale and when
  Who creates it: you (declaratively)
  Who manages it: KEDA Operator watches it and creates/manages the corresponding HPA

ScaledJob — keda.sh/v1alpha1
  What it is: KEDA's equivalent of ScaledObject, but for Kubernetes Jobs
  Use case:  process one batch of events -> create a Job -> Job completes -> Job deleted
             each "unit of work" gets its own Job pod, not a long-running Deployment

TriggerAuthentication — keda.sh/v1alpha1
  What it is: stores credentials for a KEDA scaler (Redis password, Kafka API key, etc.)
  Scope:      namespace-scoped
  Not used hands-on in this demo — the Cron scaler needs no credentials at all.
  Hands-on coverage: 05-keda-redis-scaler.

ClusterTriggerAuthentication — keda.sh/v1alpha1
  What it is: same as TriggerAuthentication but cluster-scoped
  Use case:  shared credentials (e.g. one Redis instance used by multiple teams)
```

---

### ScaledObject — Field Reference

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-cron-scaler
  namespace: default
spec:

  # What to scale
  scaleTargetRef:
    apiVersion: apps/v1           # default: apps/v1
    kind: Deployment              # Deployment, StatefulSet, or custom resource
    name: worker                  # MUST be in the same namespace as the ScaledObject

  # Replica bounds (KEDA equivalents of HPA minReplicas/maxReplicas)
  minReplicaCount: 0             # default: 0 -- can scale to zero (unlike HPA minReplicas >= 1 by default)
  maxReplicaCount: 10            # default: 100 -- ceiling on replica count

  # Timing -- see "The Two Polling Loops" and the dedicated cooldownPeriod subsection below
  pollingInterval: 30
  cooldownPeriod: 300

  # Activation -- see "Activation vs. Scaling" below
  # activationThreshold: 5

  # Triggers -- see "Activation vs. Scaling" below
  triggers:
    - type: cron
      metadata:
        timezone: UTC
        start: "0 1 * * *"        # scale up at 1am UTC
        end: "0 3 * * *"          # scale down at 3am UTC
        desiredReplicas: "3"      # target replica count during the window
```

**Similar-term distinction — why `scaleTargetRef` here but `targetRef` in VPA:** this isn't inconsistency for its own sake. HPA's API (`autoscaling/v2`) defines `scaleTargetRef`, and KEDA's ScaledObject deliberately mirrors that exact field name, since KEDA describes itself as a drop-in extension of HPA — matching HPA's own naming reinforces that mental model. VPA uses `targetRef` (no `scale` prefix) precisely because VPA doesn't scale anything — it never touches replica count, only resource requests on the pods that already exist. The naming difference reflects a genuine difference in what each object does to its target, not an oversight.

**Field-by-field explanation (simple fields — see the dedicated subsections below for `triggers`, `pollingInterval`, `cooldownPeriod`, and `activationThreshold`):**

| Field | Default | What it controls | Common mistake |
|---|---|---|---|
| `minReplicaCount` | 0 | Floor — can be 0 (unlike HPA's default minimum of 1) | Setting to 1 defeats the scale-to-zero benefit |
| `maxReplicaCount` | 100 | Ceiling on replica count | Leaving at 100 may cause unbounded scale-out on unexpected traffic |

`minReplicaCount: 0` looks like it should translate directly into the managed HPA's own `minReplicas`, but by default it never does — the HPA API itself rejects `minReplicas: 0` at the schema-validation level, since HPA's own algorithm needs at least one running pod to observe a metric from in order to make any scaling decision at all. At literally 0 replicas there's no CPU/memory/request-rate data to read, nothing to compute against — HPA structurally cannot be the thing that decides "should we go from 0 to 1." KEDA's managed HPA always has `minReplicas: 1` (never 0) so it stays within HPA's legal range, and `keda-operator` handles the entire 0↔1 edge itself, completely outside HPA, by directly patching the Deployment. Step 3's captured output below makes this concrete: `keda-hpa-worker-cron-scaler` shows `MINPODS: 1 MAXPODS: 5 REPLICAS: 0` — an ordinary HPA could never show a replica count below its own `MINPODS` through its own control loop, so the only way that combination exists is that something outside the HPA's own reconciliation set it directly.

> **Exam-trap footnote — the "by default" above is doing real work.** Kubernetes HPA has an alpha feature gate, `HPAScaleToZero`, which — when enabled — allows `minReplicas: 0` directly on the HPA object itself, but only when at least one Object or External metric is configured (never for plain CPU/memory Resource metrics). KEDA's External-metrics-only architecture (see "What Each Component Does" above) would technically qualify. This gate is off by default on essentially every standard cluster, including the minikube profile used in this demo, which is why the unconditional rejection above is what you'll actually observe here — but "HPA can never have minReplicas: 0, full stop" is not a universally true statement, and a certification question could legitimately test the exception. Treat the exception as a fact worth knowing, not something to configure in this lab.

The same asymmetry exists at the top end, on the ordinary HPA side rather than anything KEDA-specific: when HPA's own math recommends more replicas than `maxReplicas` allows, it caps `desiredReplicas` at the ceiling and sets a status condition `ScalingLimited: True, reason: TooManyReplicas`, visible via `kubectl describe hpa`. Unlike VPA's `Uncapped Target` field, which shows the actual uncapped number it would have chosen, HPA only ever exposes the boolean condition — never the number itself (already covered in `01-hpa-basic`'s quiz, Q20).

---

### Default `scaleTargetRef.kind` — KEDA vs. native HPA

```yaml
spec:
  scaleTargetRef:
    name: worker    # kind omitted here
```

When `scaleTargetRef.kind` is omitted, **KEDA defaults it to `Deployment`** (`apps/v1`) — confirmed in
KEDA's own spec docs: `kind: {kind-of-target-resource} # Optional. Default: Deployment`. Only `name` is
strictly required to scale a Deployment; targeting a `StatefulSet` or a Custom Resource requires specifying
both `apiVersion` and `kind` explicitly.

**This is NOT the same behavior as a native `HorizontalPodAutoscaler`.** In a plain HPA manifest,
`scaleTargetRef.kind` is a **required** field with no default — omitting it fails API validation. The reason
this doesn't come up often in practice is that `kubectl autoscale deployment <name> ...` fills in `kind:
Deployment` for you automatically as part of the imperative command — but if you write HPA YAML by hand from
scratch, `kind` must be present. KEDA choosing to default this field is a deliberate scaler-authoring
convenience specific to ScaledObject, not something native Kubernetes autoscaling does anywhere else.

---

### The `triggers.metadata` field — what it actually is

`triggers` is a list, and each trigger's `metadata` block is **scaler-specific** — its fields are defined
by whichever `type` you chose, not by KEDA itself. For the `cron` scaler used in this demo:

```yaml
triggers:
  - type: cron
    metadata:
      timezone: UTC              # IANA timezone name, e.g. "America/New_York" — affects how start/end are read
      start: "*/1 * * * *"       # standard cron expression — when the ACTIVE window begins
      end: "*/2 * * * *"         # standard cron expression — when the ACTIVE window ends
      desiredReplicas: "2"       # replica count to hold WHILE the window is active — always a string, not a number
```

- `timezone` — required for the `cron` scaler specifically (most other scalers don't have this field at all).
  Cron expressions are evaluated against this timezone, not the cluster's local time.
- `start` / `end` — two separate standard 5-field cron expressions defining when the window opens and closes.
  Note these aren't a single "active during X" range — they're independently-evaluated schedules, which is
  why overlapping or nonsensical `start`/`end` pairs are a real misconfiguration risk (see Common Exam Traps).
- `desiredReplicas` — **always a string** in `metadata`, even though it represents a number. This is true of
  every scaler's `metadata` values — KEDA's CRD schema stores all trigger metadata as `map[string]string`,
  so `"2"` is correct and `2` (unquoted) will fail validation.
- Every other scaler type (`redis`, `prometheus`, `aws-sqs-queue`, etc.) has a **completely different** set of
  metadata fields — there's no shared schema across trigger types beyond the outer `type`/`metadata`/
  `authenticationRef` structure. Always check the specific scaler's docs for its field names.

**What these specific cron expressions mean, combined:**

```yaml
timezone: UTC              # IANA timezone name, e.g. "America/New_York" — affects how start/end are read
start: "*/1 * * * *"       # standard cron expression — when the ACTIVE window begins
end: "*/2 * * * *"         # standard cron expression — when the ACTIVE window ends
```

A cron expression is five space-separated fields — `minute hour day-of-month month day-of-week` — each
accepting a number, `*` (any), or `*/N` (every N units). Reading each expression on its own:

- `*/1 * * * *` — fires every single minute (`:00`, `:01`, `:02`, `:03`, ...)
- `*/2 * * * *` — fires every 2 minutes, on even minute marks only (`:00`, `:02`, `:04`, ...)

**What the pair means together:** per KEDA's own model, the scaler is active whenever the current time
falls between the most recent `start` occurrence and the next `end` occurrence. Because `start` fires on
*every* minute but `end` fires only on *every other* minute, this pairing produces a fast, repeatedly
toggling window — roughly on/off every 1–2 minutes — rather than a single long daily block. That's exactly
what you'd want for a demo (fast enough to observe multiple cycles in one session) but is **not** how this
scaler is used in practice — see the real-world example below.

**Contrast with typical real-world usage** — a single daily window, evaluated once per day rather than
toggling every minute:
```yaml
timezone: America/New_York
start: "0 6 * * *"     # 6:00 AM every day
end: "0 20 * * *"       # 8:00 PM every day
desiredReplicas: "10"
```
This scales up once at 6 AM, stays active all day, and scales back down once at 8 PM — the pattern this
scaler is actually designed for (business hours, batch windows), not the rapid toggling this demo's
expressions deliberately create for observability.

**Confirms against this demo's own real test data:** the `ACTIVE` transitions captured in this session
(`True` at `3m43s` → `False` at `4m15s`, then activating again shortly after) are consistent with this
fast-toggling pairing — multiple on/off cycles within a few minutes, not a single stable daily window.

---

### KEDA's `cron` scaler vs. Kubernetes' native `CronJob` — not the same thing

Easy to conflate since both involve "cron" and "schedule," but they solve different problems:

| | KEDA `cron` scaler | Kubernetes `CronJob` |
|---|---|---|
| What it controls | Replica **count** of an existing, always-present Deployment/StatefulSet | **Creates** new Job/Pod objects on a schedule |
| Workload lifecycle | The Deployment exists continuously; KEDA changes how many replicas it has | Each scheduled run is a brand-new Pod that starts, runs to completion, and exits |
| Use case | "Keep N replicas of this always-on service running only during business hours" | "Run this batch task every night at 2am, then it's done" |
| Runs on a schedule itself? | Yes — a schedule window (`start`/`end`) defines when to scale up | Yes — a single cron expression defines when to start each run |
| Completion concept | None — replicas just exist or don't; no notion of a run "finishing" | Yes — each run has a defined completion, exit code, retry policy |

If your workload is a long-running service (an API, a web server) that just needs *more or fewer* copies of
itself at certain times, that's the `cron` scaler. If your workload is a discrete task that starts, does
something, and exits, that's a `CronJob` — the `cron` scaler and `CronJob` are not interchangeable and solve
different halves of "do something on a schedule."

---

### The Two Polling Loops

Everything about *when* KEDA checks anything comes down to two independent loops. This is the one place this demo explains polling — the field reference above and the Scale-to-Zero/from-Zero synthesis below both point back here rather than re-explaining it.

Each of KEDA's 50+ scalers is a small piece of code that knows how to do exactly one thing: given its `metadata` config, produce a current value from its specific source. For the Cron scaler, that logic is simply evaluating the cron expression against the current time and returning either an activation signal or `desiredReplicas`. For a Redis scaler, it's issuing an `LLEN` command and returning the list length. This logic runs inside `keda-operator-metrics-apiserver`'s process — and the word "polling" ends up covering two genuinely different things here, which is worth separating cleanly. Per KEDA's own FAQ: *polling interval really only impacts the time-to-activation (scaling from 0 to 1) — once scaled to one, it's really up to the HPA, which polls KEDA on its own schedule.*

```
Loop 1 — keda-operator's activation poll (governed by ScaledObject's pollingInterval):
  Purpose: decide IsActive (0<->1 edge only)
  Frequency: pollingInterval (default 30s)
  Not involved in 1->N scaling math at all

Loop 2 — HPA controller's metric-fetch poll (governed by HPA's own sync period,
          NOT pollingInterval -- default ~15s, a cluster-wide kube-controller-manager
          flag, unrelated to anything in the ScaledObject spec):
  Purpose: get the current metric value to compute 1->N scaling
  Frequency: HPA's own sync period
  Runs independently of Loop 1
```

By default, the scaler logic runs fresh and live on every single request from either loop — nothing is stored in a CRD or database. There's an opt-in `useCachedMetrics` feature that changes this (Loop 2 reads a value cached from Loop 1's last poll instead of querying fresh), but it's off by default, and isn't supported for the Cron scaler at all — so for this demo, every poll genuinely re-evaluates the schedule from scratch.

**Official terminology cross-reference:** KEDA's own documentation for scalers with a numeric activation condition (Redis, Kafka, etc.) calls Loop 1's decision the **"Activation Phase"** and the 1→N scaling math the **"Scaling Phase."** This demo uses "Loop 1 / Loop 2" and "activation vs. scaling" interchangeably with those official terms — if you see "Activation Phase" in KEDA's docs for a scaler this series hasn't covered yet, it's the same concept as Loop 1 here.

---

### Activation vs. Scaling — What a "Trigger" Actually Decides

A `triggers[]` entry is one complete configuration for one scaler — its type, its connection details, and
the values that decide both whether the target should be active at all (0↔1, Loop 1 above) and how many
replicas it needs once active (1↔N, Loop 2 above) — though, as detailed below, those two decisions reach
their respective loops through genuinely different paths, not one unified mechanism. A ScaledObject can
have multiple triggers; KEDA evaluates each independently and the managed HPA takes the MAX desired replica
count across all of them, the same way HPA already does for multiple metrics.

Every trigger has two separate numeric concerns, not one:

- **Activation** — should the target be at 0 or ≥1 right now? Governed by an activation-scoped field
  (Loop 1, `keda-operator`'s own poll) — **the field name is scaler-specific, not universal**:
  `activationListLength` for redis, `activationThreshold` for prometheus, `activationLagThreshold` for
  kafka, `activationQueueLength` for SQS, and so on. There is no single field called `activationThreshold`
  that applies across all scaler types — always check the specific scaler's own docs for its exact name.

- **Scaling (1↔N, Loop 2)** — given the target is active, how many replicas? The trigger's scaling field is
  written **once** into the underlying HPA's own target value when `keda-operator` creates/updates that
  HPA — **the field name is scaler-specific too, same pattern as activation**: `listLength` for redis,
  `threshold` for prometheus, `lagThreshold` for kafka, `queueLength` for aws-sqs-queue, and so on. Loop 2
  itself is the **native, generic Kubernetes HPA controller** — running independently on
  `--horizontal-pod-autoscaler-sync-period` (~15s), with no awareness of ScaledObjects, trigger types, or
  field names at all. It only ever sees a metric name, a current value, and a target, and does
  `ceil(current/target)` the same way regardless of scaler.

  What Loop 2 fetches each cycle is a **live re-query of the same trigger's connection details**, performed
  by `keda-operator-metrics-apiserver` on Loop 2's request — by default, this is a fresh query every time,
  not a reuse of Loop 1's separate `pollingInterval` poll (unless `useCachedMetrics: true` is set on that
  trigger, which isn't supported for `cpu`, `memory`, or `cron` triggers).

  **Cron is a genuinely different case, worth calling out specifically.** It has no backlog to measure —
  there's no `listLength`/`threshold`-style field on the cron trigger at all, only `desiredReplicas`, a
  direct value. To fit this into the same generic Loop 2 machinery (which only ever knows how to do
  `ceil(current/target)`), KEDA reports the metric value **as `desiredReplicas` itself** while inside the
  active window, with the HPA's target fixed at `1` — so `ceil(desiredReplicas / 1) = desiredReplicas`
  exactly, reproducing the direct value through ordinary division math. Confirmed against this demo's own
  real captured output: the HPA event read `"New size: 3; reason: external metric
  s0-cron-UTC-xSl2xxxx-xSl3xxxx(...) above target"` — a completely generic-sounding HPA message, with no
  cron-specific language anywhere in it, exactly because Loop 2 has no idea it's dealing with a schedule
  rather than a queue. Outside the active window, the reported metric value drops in a way that resolves to
  `0` replicas, and Loop 1's `cooldownPeriod`-gated 0↔1 handling takes over from there, same as any other
  scaler.

  *(Cross-reference: this scaling-field naming pattern mirrors the `triggers.metadata` field table earlier
  in Concepts — both activation and scaling fields follow the same "scaler-specific name" rule; keep both
  explanations consistent with each other rather than re-deriving the pattern twice.)*

These two concerns — activation and scaling — can genuinely disagree, and activation always wins when they
do. Suppose a Redis-type trigger has `listLength: "10"` (scaling target) and `activationListLength: "50"`
(activation floor) — using the correct Redis-specific field names, not a universal `activationThreshold`.
The queue has 40 messages. Doing the scaling math alone would say `ceil(40/10) = 4` replicas are needed. But
40 is below the activation floor of 50 — so KEDA treats the trigger as **not active**, and scales to zero
regardless of what the scaling math would otherwise say. This is precisely why the activation field matters
even though it looks like a minor optional field: without it (default `0`), a single stray message would
activate the Deployment from zero every time, even if the real intent was "don't bother starting a pod for
anything less than a real batch of work."

This demo's Cron manifest never sets an activation field, because Cron's activation decision is a boolean
(inside the window or not), not a numeric floor to compare against — the activation concept only applies to
trigger types whose activation condition is inherently numeric (queue depth, request rate, etc.). It's
covered hands-on with a real numeric trigger (`activationListLength`) in `05-keda-redis-scaler`.

> **Limitation worth knowing — CPU/Memory triggers never get scale-to-zero on their own.** Everything above
> assumes an External-metrics trigger (Cron, Redis, Prometheus, etc.), which is what
> `keda-operator-metrics-apiserver` serves. KEDA also supports plain `cpu`/`memory` Resource triggers, but
> for those, the managed HPA reads directly from the ordinary Kubernetes `metrics-server` — the same source
> `01-hpa-basic`'s HPA used — bypassing `keda-operator-metrics-apiserver` entirely. That has a real
> consequence: with zero pods running, there is no CPU/memory data to read at all, so there is no signal
> `keda-operator` could use to decide when to scale back up. A CPU/memory-**only** ScaledObject can still
> set `minReplicaCount: 0`, but it will never actually reach zero in practice, and if it somehow did, it
> could never recover on its own.
>
> **The actual workaround, if CPU/memory-aware scaling with true zero is needed:** add a second,
> non-CPU/Memory trigger to the same ScaledObject (e.g. Kafka lag, Prometheus, or even Cron) — that trigger
> supplies a valid activation signal even at zero pods, while the CPU/memory trigger still contributes to
> the `1→N` replica math once active. A CPU/memory trigger genuinely cannot be the *only* trigger on a
> scale-to-zero ScaledObject; it can absolutely be one of several. Scale-to-zero is an External-metrics
> capability at its core — this demo's Cron trigger and `05-keda-redis-scaler`'s Redis trigger both work
> precisely because they're External, not Resource, triggers.
>
> **Version note, confirmed against this cluster:** native Kubernetes has its own separate, unrelated
> mechanism for this — the `HPAScaleToZero` feature gate, which allows a plain (non-KEDA) HPA's
> `minReplicas` to be set to `0` directly, but only for `Object`/`External` metric types, never `Resource`
> (CPU/memory) alone — the same restriction described above, enforced one layer down at the Kubernetes API
> level. This gate graduated from alpha to **beta-and-enabled-by-default in Kubernetes v1.36** (April 2026).
> This cluster (`kubectl get nodes` confirms `v1.34.0` on all three nodes) predates that change, so the gate
> is still alpha and off by default here — moot either way for this series, since KEDA-managed HPAs never
> set `minReplicas: 0` on the HPA object itself regardless of trigger type (confirmed in `05`: KEDA handles
> the `0↔1` transition directly, outside the HPA's own bounds) — this native-HPA feature gate only matters
> for someone building a plain HPA without KEDA at all.

---

### `cooldownPeriod` — mechanism, worked example, and confirmed real behavior

`cooldownPeriod` is a single number: seconds to wait, after the trigger's underlying signal last reported
active, before `keda-operator` actually patches the Deployment down to zero. It is a **flat delay applied
every single time** — not an adaptive debounce that only kicks in for ambiguous signals. It applies
identically whether the deactivation signal is genuinely ambiguous (a bursty queue that might refill any
second) or completely unambiguous (a Cron window that has definitively closed) — the field isn't
trigger-aware.

**Two different things share a confusingly similar meaning — worth separating clearly:**
- The trigger's **internal signal** (e.g., "is the cron window currently open?") changes the instant the
  underlying condition changes — this is what starts the cooldown countdown.
- The **externally-visible `ACTIVE` condition** (`kubectl get scaledobject`) is a *reported* status, and it
  stays `True` for the entire cooldown window — it only flips to `False` at the exact moment the scale-down
  actually happens, not when the underlying signal first changed.

**Worked example:** `cooldownPeriod: 30`, Cron window closes at `10:03:00`.
- `10:03:00` — the trigger's underlying signal goes inactive (window closed). The cooldown clock starts.
  The `ACTIVE` condition is still `True` at this instant — nothing externally visible has changed yet.
- `10:03:00` through `10:03:29` — Deployment still has its active-window pods running, and `ACTIVE` still
  reads `True` the whole time. This is expected, not a bug, even though the window has genuinely closed.
- `10:03:30` — 30 seconds have elapsed with no re-activation in between. `keda-operator` now, in one
  combined action, patches `Deployment.spec.replicas = 0` **and** flips `ACTIVE` to `False`.
- If the window had reopened at, say, `10:03:15` (before the 30s elapsed), the countdown resets — no
  scale-to-zero happens at all, `ACTIVE` never leaves `True`, and the Deployment stays at its
  active-window replica count.

**Confirmed live, this session, with real timestamped data — matching the worked example exactly:**
```
kubectl get scaledobject worker-cron-scaler -w
worker-cron-scaler   ...   ACTIVE   True    3m43s
worker-cron-scaler   ...   ACTIVE   False   4m15s     ← ~32s later, matching cooldownPeriod: 30
```
```
5s   KEDAScaleTargetDeactivated   Deactivated apps/v1.Deployment default/worker from 3 to 0
5s   Killing   pod/worker-...-n6jhc   Stopping container worker
5s   Killing   pod/worker-...-wg8wl   Stopping container worker
5s   Killing   pod/worker-...-8kdrs   Stopping container worker
```
`ACTIVE→False` and every pod's `Terminating` land in the same few-second window — confirming the "combined
action at `10:03:30`" step of the worked example above, not a separately-gapped pair of events. **The real
gap to look for isn't between two Kubernetes events — it's between the cron window closing (a fact you know
from the schedule itself, not from any K8s status field) and this combined `ACTIVE=False`/`Terminating`
moment**, roughly `cooldownPeriod` seconds later.

**Why this field exists at all — the problem it solves:** without it, any workload with even slightly
intermittent load would flap — scale to zero the moment activity pauses, then immediately scale back up
seconds later when it resumes. Each `0→1` transition has real cost (scheduling, image pull if not cached,
container start, app warm-up), paid again on every flap. `cooldownPeriod` absorbs short gaps so the
workload stays warm through them. Cron doesn't strictly need this protection, since its signal is never
ambiguous — but the field applies the same fixed delay regardless, since it isn't trigger-aware.

**Scope — what it does NOT cover:** only the `0↔1` transition, and only on the way *down*. Scaling `1→N`
(or staying above zero) is handled entirely by the underlying HPA's own
`behavior.scaleDown.stabilizationWindowSeconds` — the same knob used in `02-hpa-advanced`'s Percent-policy
scale-down. Scale-*up* from zero has no equivalent grace period at all — the very next `pollingInterval`
that sees activation triggers it immediately, no delay.

**A related but different gotcha this field does NOT solve:** if a trigger's metric drops to zero while a
pod is still mid-processing an item — before it's acknowledged/completed — KEDA can still scale that pod
away, interrupting real work. That's a separate problem (usually solved with `preStop` hooks / graceful
termination in the workload itself), not something `cooldownPeriod` protects against.

**Tuning guidance:**

| Scenario | Direction | Why |
|---|---|---|
| Cheap, fast-starting containers + genuinely idle-most-of-the-time workload | Short (15–60s, this demo's `30s`) | Cold-start cost is negligible; reclaim resources aggressively |
| Expensive cold starts (JVM, large model load, big image pull) | Long (minutes+) | Repeated 0→1 transitions cost more than staying warm a bit longer |
| Bursty traffic with short gaps between bursts | Long enough to bridge the typical gap | Shorter than the real idle gap between bursts = flapping on every burst |
| Production default | `300s` (KEDA's own default) | Conservative baseline when the real idle/burst pattern isn't yet known |

Also keep `cooldownPeriod` a sensible multiple of `pollingInterval` — the check only happens each poll, so
a `cooldownPeriod` shorter than `pollingInterval` doesn't behave as genuinely shorter; it just rounds up to
the next poll regardless.

**Not used in this demo, but worth knowing exists:** `initialCooldownPeriod` (default `0`) delays when the
*first* `cooldownPeriod` countdown is allowed to start, measured from the ScaledObject's own creation time
— useful if you don't want a brand-new ScaledObject to scale to zero immediately just because it happened
to be created outside an active window. This demo's manifest doesn't set it, so the default (no extra
delay) applies throughout Step 3.

**Also note:** 
- if `minReplicaCount >= 1`, `ACTIVE` is always `True` and this entire scale-to-zero mechanism
never engages.
- `cooldownPeriod` only has anything to do when `minReplicaCount: 0` is set.
- If the minimum replicas is >= 1, the scaler is always active and the activation value will be ignored. 
- Everything in the cooldown/activation discussion only becomes observable at all because `minReplicaCount: 0` is set. If someone changes that to `1` later, `ACTIVE` will read True permanently, `cooldownPeriod's` `scale-to-zero` path never fires, and none of Error-3's scenario is even reachable anymore. 
---

### What "trigger active" means, generalized across scaler types

Cron's active/inactive signal is schedule-based: active inside the `[start, end)` window, inactive outside
it. Every other scaler type uses the same active/inactive *concept* but a different input — the live
metric value compared against that scaler's own activation threshold (`activationListLength` for redis,
`activationThreshold` for prometheus, etc.), active when the value exceeds it. CPU/Memory triggers don't
support this concept at all, for a simple reason: you can't measure CPU% on zero running pods.

**One case that disables this entire mechanism:** if `minReplicaCount >= 1`, `ACTIVE` reads `True`
permanently and the activation value is ignored outright — the 0↔1 decision (and everything about
`cooldownPeriod`'s scale-to-zero path) simply doesn't apply. This demo's `minReplicaCount: 0` is what
makes any of this observable at all.

---

### Scale-to-Zero and Scale-from-Zero Mechanics — Putting It All Together

This is the payoff section — every piece introduced above (the two-track split, the two polling loops, activation vs. scaling, `cooldownPeriod`) comes together here into one worked sequence. If you read nothing else in Concepts twice, read this section twice.

```
SCALE-TO-ZERO SEQUENCE:
  1. Event source becomes empty / inactive (for Cron: the schedule window closes)
  2. keda-operator's Loop 1 poll (every pollingInterval) detects: trigger inactive
  3. keda-operator waits for cooldownPeriod to elapse (see worked example above). During this ENTIRE
     wait, the ScaledObject's own ACTIVE condition remains True -- it has not yet been updated to
     reflect the trigger's already-inactive state. This is not a reporting lag or a bug; ACTIVE and the
     scale-down are one combined action, deferred together until this moment.
  4. keda-operator, in that same single action, patches Deployment.spec.replicas = 0 AND flips ACTIVE
     to False simultaneously (bypasses HPA entirely for this step -- HPA's own stabilization/tolerance
     settings are NEVER consulted for this transition). Confirmed via real event timestamps this
     session -- see the cooldownPeriod subsection.
  5. All pods terminate; Deployment sits at 0 replicas. The managed HPA's own
     ScalingActive condition flips to False, with a message to the effect of
     "scaling is disabled since the replica count of the target is zero" --
     this is the HPA correctly reporting that it has nothing to do, not an error


SCALE-FROM-ZERO SEQUENCE:
  1. Event source activates (for Cron: the schedule window opens)
  2. keda-operator's Loop 1 poll (every pollingInterval) detects: trigger active
  3. keda-operator directly patches Deployment.spec.replicas = minReplicaCount
     (or the Cron trigger's desiredReplicas, if higher) -- again, no HPA
     involvement, so no stabilization window applies here either
  4. Pod(s) start up; HPA takes over once at least 1 pod is running
  5. HPA scales further (1->N) using its OWN ordinary stabilization/tolerance
     rules -- the same default 10% tolerance band and scaleUp/scaleDown
     stabilization windows covered in 01-hpa-basic and 02-hpa-advanced apply
     here completely unchanged, since this part IS handled by a real HPA
```

There are two entirely separate timing/stability systems operating at two different layers here, and it's easy to assume KEDA's `cooldownPeriod`/`pollingInterval` are "KEDA's version of" HPA's stabilization/tolerance — they aren't.

| | Layer 1 — the 0↔1 edge | Layer 2 — the 1↔N range |
|---|---|---|
| Who's in control | `keda-operator`, directly | The ordinary HPA `keda-operator` created |
| Timing controls | `cooldownPeriod` (deactivation delay), `pollingInterval` (Loop 1 check frequency) | HPA's own `behavior.scaleUp`/`scaleDown` stabilization windows (settable via `advanced.horizontalPodAutoscalerConfig.behavior` in the ScaledObject), driven by Loop 2 |
| Tolerance concept | None — activation is a binary decision, no "close enough" band | HPA's default ±10% tolerance band, exactly as covered in `01-hpa-basic` |
| Does one affect the other? | No — Layer 1's settings have zero effect on Layer 2's behavior and vice versa | |

**One practical consequence worth knowing before you rely on this in production:** scale-to-zero isn't free. The first request or event after a scale-from-zero hits an empty Deployment — you pay the full cold-start cost (image pull if evicted from the node's cache, pod scheduling, container start, readiness probe) before anything can actually process work. For a nightly batch job like this demo's scenario, that's a non-issue — nothing is waiting on the response. For a request-driven workload (a webhook receiver, say), that same cold start becomes latency the first caller after an idle period actually feels. This is a design trade-off, not a defect — it's the same trade-off any serverless-style platform makes for the resource savings scale-to-zero provides.

---

### KEDA Metrics API Support

One common point of confusion is whether KEDA implements the Kubernetes **Custom Metrics API** (`custom.metrics.k8s.io`) in addition to the **External Metrics API** (`external.metrics.k8s.io`). KEDA implements **only** the **External Metrics API** (`external.metrics.k8s.io`). It does **not** implement the **Custom Metrics API** (`custom.metrics.k8s.io`), which means HPA **Pods** and **Object** metrics are **not supported by KEDA**.

**Why it does not support `Custom Metrics API`?**

KEDA is designed for **event-driven autoscaling**, where scaling decisions are based on metrics from **external systems** rather than metrics generated by Kubernetes objects or pods.

Examples of supported event sources include:

- Redis
- RabbitMQ
- Kafka
- Azure Service Bus
- AWS SQS
- Google Pub/Sub
- Prometheus
- Datadog
- and 50+ other built-in scalers

Since these metrics originate outside the Kubernetes cluster, KEDA exposes them through the **External Metrics API**, which is the API that the Horizontal Pod Autoscaler (HPA) uses to consume external metrics.

**KEDA Metrics API Server**

When KEDA is installed, it deploys the following component:

```text
keda-operator-metrics-apiserver
```

Its responsibilities are:

- Implements the **`external.metrics.k8s.io`** API.
- Receives external metric requests from the HPA controller.
- Translates each request into a scaler-specific query.
- Executes the corresponding scaler logic (for example, querying Redis, Kafka, RabbitMQ, Azure Service Bus, etc.).
- Returns the metric value in the Kubernetes **External Metrics API** format.
- Eliminates the need to install a separate metrics adapter for each supported event source, since one KEDA Metrics API Server supports all built-in scalers.

**What KEDA Does Not Support**

KEDA **does not** implement the **`custom.metrics.k8s.io`** API.

As a result, HPA metric types that depend on the Custom Metrics API (**Pods** and **Object** metrics) are outside KEDA's scope. If those metric types are required, a dedicated **Custom Metrics Adapter** (such as the Prometheus Adapter) must be deployed separately.

| Kubernetes Metrics API | Implemented by KEDA | Purpose |
|-------------------------|---------------------|---------|
| `external.metrics.k8s.io` | ✅ Yes | Event-driven autoscaling using metrics from external systems |
| `custom.metrics.k8s.io` | ❌ No | Pods and Object metrics require a separate Custom Metrics Adapter |

**KEDA's Prometheus Scaler vs. the Prometheus Adapter**

Both tools can implement `external.metrics.k8s.io`, which is worth stating plainly: the Prometheus Adapter isn't limited to Custom metrics, it genuinely supports an `external:` rule type too. The real difference is how much each tool is actually used for that job in practice:

- **Prometheus Adapter's real strength is Custom metrics** (`type: Pods`, `type: Object`) — metrics tied to actual Kubernetes objects, with native per-pod averaging. KEDA cannot do this at all — every KEDA scaler, Prometheus included, only ever produces `external.metrics.k8s.io` metrics, never `custom.metrics.k8s.io`.
- **For the External-metrics case specifically** (where both tools genuinely overlap), KEDA is simpler in practice: one raw PromQL `query` field in a ScaledObject, versus a full ConfigMap rule (`seriesQuery`, `resources`, `name`, `metricsQuery`) in the Adapter — plus KEDA gives you scale-to-zero for free, which Adapter's External rule type does not provide on its own.

**In short:** reach for the Prometheus Adapter when the metric is naturally tied to a Pod or another Kubernetes object and you want native per-pod averaging. Reach for KEDA when the metric is a plain aggregate with no natural Kubernetes-object owner, or you want scale-to-zero — that's the case where configuring Adapter's External rule would just be extra ConfigMap maintenance for something KEDA already does with one field.


---

## Lab Step-by-Step Guide

---

### Step 1 — Install KEDA via Helm

This installs the two KEDA components described in Concepts above, plus the CRDs and webhook validation.

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

# Pin to the current stable chart version rather than installing unpinned --
# check what's actually current before you run this:
helm search repo kedacore/keda --versions | head -5

helm install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --version 2.20.0
```
> **Version note:** `2.20.0` was the latest stable chart version at the time of writing (confirmed via `helm search repo kedacore/keda --versions`, which also showed `2.20.0`, `2.19.0`, and the `2.18.x` series behind it). There's no indication of a known regression in `2.20.0` specifically — always re-run the `helm search` command above yourself before installing, since this will drift over time, and pin whatever is actually current rather than copying `2.20.0` blindly from this document months later.

**Watch the pods come up:**
```bash
kubectl get pods -n keda -w
```

**Real captured output** (yours will have different hashes, but the same shape):
```
NAME                                               READY   STATUS              RESTARTS      AGE
keda-operator-6bb79ff79-86qbt                      1/1     Running             1 (26s ago)   32s
keda-operator-metrics-apiserver-656749fd7c-765nm   1/1     Running             0             32s
keda-admission-webhooks-85957885bf-tzvzn           1/1     Running             0             41s
```
```
# Observation:
# -  keda-operator waits on a TLS certificate that keda-admission-webhooks 
#   generates; if it starts first and that cert isn't ready yet, 
#   it restarts once cleanly after the cert appears. If you see
#   MORE than one or two restarts, or CrashLoopBackOff, that's a real problem
#   worth checking logs for -- one restart in the first ~30s is not.
# - All three pods reach READY 1/1 within roughly 40s of the helm install
#   completing. Don't proceed to Step 2 until all three show 1/1 -- the
#   admission webhook in particular must be ready before any ScaledObject
#   apply will succeed (kube-apiserver calls into it synchronously on every
#   KEDA resource apply).
```

Verify the CRDs:
```bash
kubectl api-resources | grep keda
```
**Real captured output:**
```
cloudeventsources                                            eventing.keda.sh/v1alpha1           true         CloudEventSource
clustercloudeventsources                                     eventing.keda.sh/v1alpha1           false        ClusterCloudEventSource
clustertriggerauthentications       cta,clustertriggerauth   keda.sh/v1alpha1                    false        ClusterTriggerAuthentication
scaledjobs                          sj                       keda.sh/v1alpha1                    true         ScaledJob
scaledobjects                       so                       keda.sh/v1alpha1                    true         ScaledObject
triggerauthentications              ta,triggerauth           keda.sh/v1alpha1                    true         TriggerAuthentication
```

> **What these two are, briefly:** `CloudEventSource`/`ClusterCloudEventSource` let KEDA emit its own
> internal events (ScaledObject errors, scaling actions) as CloudEvents to an external endpoint — useful for
> piping KEDA's operational events into a monitoring/alerting system. Not used in this demo. 
> you'll only interact with ScaledObject, and TriggerAuthentication starting in 05-keda-redis-scaler.
> Note also the short aliases (so, sj, ta, ta,triggerauth, cta,clustertriggerauth)
> -- "kubectl get so" is equivalent to "kubectl get scaledobjects".

Verify the External Metrics API registration:
```bash
kubectl get apiservices | grep external
```
**Expected output:**
```
v1beta1.external.metrics.k8s.io     keda/keda-operator-metrics-apiserver   True        7m29s
```
```
# Observation: KEDA Metrics Server has registered as the handler for
# external.metrics.k8s.io -- the same API group HPA's External type uses.
# True here means the registration succeeded and kube-apiserver can reach
# the keda-operator-metrics-apiserver Service. False or missing would mean
# the Service/Deployment isn't healthy yet -- re-check the pods above.
```

---

### Step 2 — Deploy the Worker Application

This Deployment is the target of the Cron ScaledObject in Step 3.

**`src/01-worker-deploy.yaml`:**
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
kubectl apply -f src/01-worker-deploy.yaml
kubectl rollout status deployment/worker
```

**Expected output:**
```
deployment.apps/worker created
Waiting for deployment "worker" rollout to finish: 0 of 1 updated replicas are available...
deployment "worker" successfully rolled out
```

Check the pod directly before moving on — this is the baseline you'll compare against once the ScaledObject starts scaling it:
```bash
kubectl get pods
```
**Expected output:**
```
NAME                     READY   STATUS    RESTARTS   AGE
worker-87f46db94-bcb4v   1/1     Running   0          10s
```

---

### Step 3 — Cron Scaler: Full Outside-Window / Inside-Window Cycle

 You're about to create one ScaledObject that puts everything from Concepts into motion end to end, on your own cluster, and watch it happen — KEDA creating a managed HPA you never asked for directly, that HPA showing an impossible-looking `REPLICAS: 0` below its own `MINPODS: 1`, the Deployment actually scaling from 0 to 3 pods with no metric involved at all (just a clock), and then scaling back to 0 a fixed delay after the window closes rather than instantly. Every one of those is a direct, observable consequence of a mechanism already explained in Concepts — this step's job is to make you watch the mechanism, not just read about it. The Cron scaler needs no external event source at all — KEDA evaluates the schedule against the clock, nothing else. This step uses a fast demo schedule (every 2 minutes) so the cycle is observable in a few minutes instead of waiting for a real business-hours window; production schedules use real expressions like the commented example in the manifest below.

**Before you start — open three terminals.** This step involves three things changing at once (the ScaledObject's own status, the HPA KEDA creates, and the actual pods), and a single `-w` watch only shows you one of them. Recommended layout:
```bash
# Terminal 1:
kubectl get scaledobject worker-cron-scaler -w

# Terminal 2:
kubectl get hpa -w

# Terminal 3:
kubectl get pods -l app=worker -w
```
Run the `kubectl apply` below from a fourth terminal (or any one of the three once you've started its watch), then switch between the three to see how they relate to each other in real time.

**`src/02-scaledobject-cron.yaml`:**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-cron-scaler
spec:
  scaleTargetRef:
    name: worker
  minReplicaCount: 0              # 0 outside the scheduled window
  maxReplicaCount: 5
  cooldownPeriod: 30               # shortened for this demo (default: 300) -- see the
                                   # Concepts note above; this still delays scale-to-zero
                                   # by 30s after the window closes, not instantly
  triggers:
    - type: cron
      metadata:
        timezone: UTC
        start: "*/2 * * * *"     # every 2 minutes (for demo -- replace with a real schedule)
        end: "*/3 * * * *"       # 1-minute active window
        desiredReplicas: "3"     # scale to 3 during the active window
        # Production example:
        # start: "0 9 * * 1-5"    # 9am Mon-Fri
        # end: "0 18 * * 1-5"     # 6pm Mon-Fri
        # desiredReplicas: "10"
```

```bash
kubectl apply -f src/02-scaledobject-cron.yaml
kubectl get scaledobject worker-cron-scaler -w
```

**Real captured output — the first few seconds after apply:**
```
scaledobject.keda.sh/worker-cron-scaler created
NAME                 SCALETARGETKIND      SCALETARGETNAME   MIN   MAX   READY     ACTIVE    FALLBACK   PAUSED   TRIGGERS   AUTHENTICATIONS   AGE
worker-cron-scaler   apps/v1.Deployment   worker            0     5     Unknown   Unknown   Unknown    False    cron                         1s
worker-cron-scaler   apps/v1.Deployment   worker            0     5     Unknown   Unknown   Unknown    False    cron                         1s
worker-cron-scaler   apps/v1.Deployment   worker            0     5     True      Unknown   False      False    cron                         1s
worker-cron-scaler   apps/v1.Deployment   worker            0     5     True      True      Unknown    False    cron                         1s
worker-cron-scaler   apps/v1.Deployment   worker            0     5     True      False     False      False    cron                         29s
worker-cron-scaler   apps/v1.Deployment   worker            0     5     True      False     False      False    cron                         57s
```

**What every column means, and why it flickers through several states in the first second:**
```
SCALETARGETKIND / SCALETARGETNAME -- confirms which object KEDA resolved
  scaleTargetRef to. If this were blank or wrong, that's the same class of
  problem as Break-Fix Error-1 (target not found).

MIN / MAX -- directly from minReplicaCount/maxReplicaCount in the spec.
  Nothing to diagnose here, just a readback of your own config.

READY -- can KEDA reach everything it needs (the target Deployment exists,
  the trigger config is valid)? Starts Unknown while the admission webhook
  and operator are still processing the brand-new object, settles to True
  within about a second once keda-operator's first reconcile completes.

ACTIVE -- is the trigger's activation condition currently met? This is
  what actually drives the 0<->1 edge -- the Loop 1 decision from Concepts.
  Notice it briefly shows True right after creation, then flips to False at
  29s -- this is NOT a bug: the demo schedule's window (*/2 to */3, a
  1-minute window every 2 minutes) happened to be active for a few seconds
  right as this ScaledObject was created, then closed. Your own timing will
  differ depending on exactly which second you applied the manifest
  relative to the schedule.

FALLBACK -- whether KEDA is serving a configured fallback metric value
  because the real trigger query failed. Not configured in this demo, so
  this should settle to False and stay there; anything else means the
  trigger query is failing (see Troubleshooting).

PAUSED -- whether autoscaling.keda.sh/paused annotation has been set to
  manually freeze this ScaledObject (a real KEDA feature for maintenance
  windows, not used in this demo). Stays False throughout.

TRIGGERS -- lists the trigger type(s) configured (cron here). With
  multiple triggers this would be a comma-separated list.

AUTHENTICATIONS -- which TriggerAuthentication/ClusterTriggerAuthentication
  this ScaledObject references, if any. Blank here because Cron needs no
  credentials -- this column becomes meaningful in 05-keda-redis-scaler.
```


**Check the managed HPA (Terminal 2):**
```bash
kubectl get hpa
```
**Real captured output:**
```
NAME                          REFERENCE           TARGETS             MINPODS   MAXPODS   REPLICAS   AGE
keda-hpa-worker-cron-scaler   Deployment/worker   <unknown>/1 (avg)   1         5         0          2m21s
```
```
# Observation -- read this output against the "Why minReplicaCount: 0 but
# the generated HPA shows MINPODS: 1" explanation in Concepts: MINPODS is
# 1 here (never 0 by default -- HPA's own API validation forbids it), yet
# REPLICAS shows 0. An ordinary HPA could never produce REPLICAS below its
# own MINPODS through its own control loop -- the only way this specific
# combination exists is that keda-operator set spec.replicas=0 directly,
# completely outside the HPA's own reconciliation. This one line of
# output is the concrete proof of the two-track architecture from
# Concepts, not just a description of it.
#
# TARGETS shows <unknown>/1 (avg) -- the "1" here is not desiredReplicas,
# it's the Cron trigger's internal target value representation (Cron
# doesn't have a real "metric" the way Redis/Prometheus do, so KEDA
# represents it this way internally for HPA's benefit). Don't read this
# as "targeting 1 replica" -- the real target during an active window is
# desiredReplicas: "3" from the ScaledObject spec, which the Cron trigger
# communicates to HPA through a different path than the usual metric math.
```

**Optional but instructive — look at the HPA's own Conditions while REPLICAS is 0:**
```bash
kubectl describe hpa keda-hpa-worker-cron-scaler | grep -A8 "Conditions:"
```
```
# Expected shape (exact wording may vary slightly by Kubernetes version):
# Conditions:
#   Type            Status  Reason              Message
#   ----            ------  ------              -------
#   ScalingActive   False   ScalingDisabled     scaling is disabled since the replica count of the target is zero
#
# This is the HPA itself confirming, in its own words, exactly what Concepts
# describes: at zero replicas there's nothing for the HPA to read a metric
# from, so it correctly reports its own scaling as disabled rather than
# erroring. ScalingActive: False here is the expected, healthy state while
# outside the cron window -- not a symptom of anything wrong.
```

**Watch the pods (Terminal 3) once the next window opens:**
```bash
kubectl get pods -l app=worker -w
```
**Real captured output — scale-from-zero:**
```
NAME                     READY   STATUS    RESTARTS   AGE
worker-87f46db94-9ld5h   1/1     Running   0          86s
worker-87f46db94-kbvkb   1/1     Running   0          86s
worker-87f46db94-llfmn   1/1     Running   0          86s
```
```
# Observation: all three appear with the SAME age (86s) -- because
# keda-operator's direct Deployment patch set spec.replicas=3 in one
# single write, not incrementally. This is a genuine difference from
# ordinary HPA scale-up, which (per 02-hpa-advanced's Percent-policy
# behavior) can add replicas across multiple evaluation windows. Cron's
# desiredReplicas is a flat target applied all at once by keda-operator,
# not a gradual HPA-style ramp.
```
Cross-check against Terminal 1 at the same moment:
```bash
kubectl get scaledobjects.keda.sh worker-cron-scaler
```
```
NAME                 SCALETARGETKIND      SCALETARGETNAME   MIN   MAX   READY   ACTIVE   FALLBACK   PAUSED   TRIGGERS   AUTHENTICATIONS   AGE
worker-cron-scaler   apps/v1.Deployment   worker            0     5     True    True     False      False    cron                         5m17s
```
```
# ACTIVE=True here confirms this is the moment the window opened again --
# 5m17s after creation, consistent with the "every 2 minutes" schedule.
```

**Wait for the window to close, then watch scale-to-zero (Terminal 3 continued):**
```
NAME                     READY   STATUS        RESTARTS   AGE
worker-87f46db94-9ld5h   1/1     Running       0          2m13s
worker-87f46db94-kbvkb   1/1     Running       0          2m13s
worker-87f46db94-llfmn   1/1     Running       0          2m13s
worker-87f46db94-llfmn   1/1     Terminating   0          2m19s
worker-87f46db94-kbvkb   1/1     Terminating   0          2m19s
worker-87f46db94-9ld5h   1/1     Terminating   0          2m19s
```
```
# Observation: ACTIVE flipping to False (Terminal 1) and this Terminating event happen
# together, as one combined transition -- not with a gap between them. cooldownPeriod
# (30s here) already elapsed BEFORE this moment, invisibly -- the real gap is between
# the window closing (a fact you know from the schedule, not from any K8s status field)
# and this combined ACTIVE=False/Terminating moment.see the cooldownPeriod subsection in Concepts for the full evidence.
```

Confirm the end state across all three:
```bash
kubectl get pods
```
```
No resources found in default namespace.
```
```bash
kubectl get hpa
```
```
NAME                          REFERENCE           TARGETS             MINPODS   MAXPODS   REPLICAS   AGE
keda-hpa-worker-cron-scaler   Deployment/worker   <unknown>/1 (avg)   1         5         0          8m35s
```
```
# The HPA object itself is NOT deleted between cycles -- it persists for
# as long as the ScaledObject exists, cycling REPLICAS between 0 and the
# active-window count each time the schedule fires. It's only deleted
# when the ScaledObject itself is deleted (Step 4).
```

---

### Step 4 — Cleanup

**(a) Demo-scoped resources:**
```bash
kubectl delete -f src/02-scaledobject-cron.yaml --ignore-not-found
kubectl delete -f src/01-worker-deploy.yaml --ignore-not-found
kubectl get scaledobject
kubectl get hpa
```
**Real captured output:**
```
scaledobject.keda.sh "worker-cron-scaler" deleted from default namespace
deployment.apps "worker" deleted from default namespace
No resources found in default namespace.
No resources found in default namespace.
```

**(b) Cluster-scoped shared components:** **Leave KEDA installed.** `05-keda-redis-scaler` needs it too, and reinstalling from scratch for the very next demo would just be wasted setup time — `05`'s Prerequisites will check for KEDA's existing pods and only fall back to installing if it's genuinely missing (e.g. if you're running these demos out of order, or on a fresh cluster). Nothing to run here — this is a deliberate no-op, not a skipped step.
```
# Observation: unlike VPA/HPA teardowns elsewhere in this series where the
# tool itself gets uninstalled at the end of its own demo, KEDA stays
# installed across 04 and 05 since both demos in this split genuinely need
# it. It gets uninstalled for real at the end of 05, once nothing later in
# the split still depends on it.
```

---

## What You Learned

- ✅ Explained the KEDA architecture — Operator and Metrics Server, and what each is responsible for
- ✅ Explained how KEDA creates and manages an HPA object from a ScaledObject
- ✅ Traced the scale-to-zero sequence (HPA takes N→1, KEDA Operator takes 1→0) and scale-from-zero sequence (KEDA Operator takes 0→1, HPA takes 1→N)
- ✅ Wrote a ScaledObject using the Cron scaler and observed a full outside-window → inside-window → outside-window cycle, including the `cooldownPeriod` delay on the way back to zero
- ✅ Diagnosed a `scaleTargetRef` typo, an AmbiguousSelector conflict, and a `cooldownPeriod`-related scale-down delay from symptoms alone
- ✅ Explained why KEDA's Prometheus scaler and the Prometheus Adapter aren't really competing for the same job

**Key Takeaway:** KEDA does not replace HPA — it extends it with exactly the one thing HPA cannot express by default: zero. Every scale-to-zero or scale-from-zero transition is handled by KEDA Operator directly patching the Deployment's replica count, completely bypassing HPA for that specific step; everything else (1→N scaling) still runs through the ordinary HPA reconciliation loop KEDA created for you. `cooldownPeriod` is not a noise filter here the way it might first appear — for Cron specifically, it's a flat, unconditional delay applied after every window close, regardless of how clean or unambiguous the "window closed" signal was.

---

## Break-Fix

Each scenario below is independent. Diagnose from the symptom command output alone before reading the fix. Each scenario ends with an explicit cleanup step — run it before starting the next scenario.

From here on, all commands in this section assume you're working from inside the `break-fix/` directory:
```bash
cd src/break-fix/
```
The `worker` Deployment (from Step 2) is one level up in `src/` and is referenced as `../01-worker-deploy.yaml`. Files specific to a scenario live in this directory and are referenced directly, with no path prefix.

---

### Error-1

**`01-scaledobject-wrong-target.yaml`:**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-broken-target
spec:
  scaleTargetRef:
    name: wroker          # BUG: typo -- "wroker" instead of "worker"
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
kubectl apply -f ../01-worker-deploy.yaml
kubectl apply -f 01-scaledobject-wrong-target.yaml
kubectl get scaledobject worker-broken-target
kubectl describe scaledobject worker-broken-target | grep -A5 "Conditions:"
```

The ScaledObject is created successfully. What does `kubectl describe` show, and why?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
kubectl get scaledobjects worker-broken-target :
NAME                   SCALETARGETKIND   SCALETARGETNAME   MIN   MAX   READY   ACTIVE    FALLBACK   PAUSED   TRIGGERS   AUTHENTICATIONS   AGE
worker-broken-target                     wroker            0     5     False   Unknown   False      False                                 13s


kubectl describe scaledobject worker-broken-target | grep -A5 "Conditions:" :
  Conditions:
    Message:  ScaledObject doesn't have correct scaleTargetRef specification: deployments.apps "wroker" not found
    Reason:   ScaledObjectCheckFailed
    Status:   False
    Type:     Ready
    Message:  ScaledObject check failed
    

kubectl get hpa :
No resources found in default namespace.
```

**Cause:** `scaleTargetRef.name` contains a typo — `wroker` instead of `worker`. KEDA successfully creates the ScaledObject but cannot find the target Deployment. The Operator reports `ScalerNotReady` and never creates the managed HPA.

**Fix:** Correct the typo to `name: worker`. Apply and verify `READY=True`.

**Cascade:** While `READY=False`, no HPA is created and no scaling occurs — the Deployment stays at whatever replica count it was manually set to.

</details>

**Cleanup:**
```bash
kubectl delete -f 01-scaledobject-wrong-target.yaml --ignore-not-found
```

---

### Error-2

**`02-scaledobject-conflict-hpa.yaml`:**
```yaml
# A ScaledObject already exists on the "worker" Deployment (created below).
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
# Ensure a ScaledObject exists on worker first (reapply the working one from Step 3):
kubectl apply -f ../02-scaledobject-cron.yaml

# Then apply the conflicting manual HPA:
kubectl apply -f 02-scaledobject-conflict-hpa.yaml

# Wait ~30s then check:
kubectl get hpa
kubectl describe scaledobject worker-cron-scaler | grep -A10 "Conditions:"
```

Two HPAs now target the same Deployment. What does KEDA report, and what is the consequence? (Notice this test applies the ScaledObject *first*, then the manual HPA *second* — that order is deliberate, not incidental. Keep it in mind while diagnosing.)

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
kubectl get hpa:
  NAME                          REFERENCE          TARGETS       REPLICAS
  keda-hpa-worker-cron-scaler   Deployment/worker  <unknown>     0
  manual-hpa-worker             Deployment/worker  0%/50%        1

kubectl describe scaledobject worker-cron-scaler | grep -A10 "Conditions:" :
  Conditions:
    Message:  ScaledObject is configured correctly but HPA is not healthy: AmbiguousSelector
    Reason:   HPAMetricsUnavailable
    Status:   False
    Type:     Ready
    Message:  Scaling is performed because triggers are active
    Reason:   ScalerActive
    Status:   True
    Type:     Active
    Message:  No fallbacks are active on this scaled object
    Reason:   NoFallbackFound

kubectl describe hpa manual-hpa-worker | grep -A10 "Conditions:" :         
Conditions:
  Type           Status  Reason             Message
  ----           ------  ------             -------
  AbleToScale    True    SucceededGetScale  the HPA controller was able to get the target's current scale
  ScalingActive  False   AmbiguousSelector  pods by selector app=worker are controlled by multiple HPAs: [default/keda-hpa-worker-cron-scaler default/manual-hpa-worker]
Events:
  Type     Reason                        Age                 From                       Message
  ----     ------                        ----                ----                       -------
  Warning  AmbiguousSelector             23s (x3 over 3m5s)  horizontal-pod-autoscaler  pods by selector app=worker are controlled by multiple HPAs: [default/manual-hpa-worker default/keda-hpa-worker-cron-scaler]
```

**Cause:** KEDA detects that a second HPA (`manual-hpa-worker`) also targets the `worker` Deployment. The HPA controller cannot determine which HPA is authoritative and stops processing both. KEDA reports `ScalerNotReady`.

**Why the manual `kubectl apply` succeeded at all — this is the part that trips people up:** KEDA's admission webhook does validate ScaledObject creation against an *existing* conflicting HPA — if you tried to create a ScaledObject on a Deployment that already had a manual HPA, that apply would be rejected immediately, the same way a duplicate ScaledObject is. But the order here is reversed: the ScaledObject was created first, and the manual HPA came second. A plain `HorizontalPodAutoscaler` is not a KEDA resource, so KEDA's webhook has no hook into validating it at all — it applies successfully every time, regardless of what it conflicts with. The conflict is only caught afterward, at the ordinary Kubernetes HPA-controller level, as `AmbiguousSelector`. Creation order is what determines whether you get an immediate rejection or a silent success followed by a delayed failure — not just whether a conflict exists.

**Fix:** Delete the manually-created HPA: `kubectl delete hpa manual-hpa-worker`. KEDA owns the HPA lifecycle for any Deployment it manages via a ScaledObject — never create a manual HPA alongside one.

**Cascade:** While the conflict exists, neither HPA scales the Deployment. The replica count freezes at whatever it was when the conflict was introduced.

</details>

**Cleanup:**
```bash
kubectl delete -f 02-scaledobject-conflict-hpa.yaml --ignore-not-found
kubectl delete -f ../02-scaledobject-cron.yaml --ignore-not-found
```

---

### Error-3

**`03-scaledobject-cooldown-surprise.yaml`:**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-cooldown-surprise
spec:
  scaleTargetRef:
    name: worker
  minReplicaCount: 0
  maxReplicaCount: 5
  cooldownPeriod: 300              # the DEFAULT value -- not actually a bug in the YAML,
                                   # the "bug" is the assumption in how it's operated (see below)
  triggers:
    - type: cron
      metadata:
        timezone: UTC
        start: "*/2 * * * *"
        end: "*/3 * * * *"
        desiredReplicas: "2"
```

```bash
kubectl apply -f ../01-worker-deploy.yaml
kubectl apply -f 03-scaledobject-cooldown-surprise.yaml

# Wait for one active window to open and close, then immediately check:
kubectl get scaledobject worker-cooldown-surprise
kubectl get pods -l app=worker
```

You know from the schedule that the window closed a couple minutes ago. But `ACTIVE` still reads `True`,
and `kubectl get pods` still shows running pods -- nothing has changed at all. Someone on your team files
this as a bug: "KEDA isn't detecting that the cron window closed." What's actually happening?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
kubectl get scaledobject worker-cooldown-surprise:
  NAME                        READY   ACTIVE   FALLBACK
  worker-cooldown-surprise    True    True     False     <- still True, ~4 min after window closed

kubectl get pods -l app=worker:
  NAME                       READY   STATUS
  worker-xxxxxxxxx-xxxxx     1/1     Running    <- still running, unchanged
```

**Cause:** This isn't a bug -- `cooldownPeriod` defaults to 300 seconds (5 minutes), and `ACTIVE` does
**not** flip to `False` the moment the trigger goes inactive. `ACTIVE` and the scale-down action are one
combined event, deferred together until the full `cooldownPeriod` has elapsed since the trigger's last
active reading -- confirmed via real timestamped events in this demo's Concepts section. For the first
~5 minutes after the window closes, everything will look completely unchanged: `ACTIVE` still `True`,
pods still `Running`, nothing in `kubectl get` output hints that KEDA has even noticed the window closed.
The team's assumption that a closed window should be visible in `ACTIVE` immediately conflates the
trigger's internal signal with the reported condition, which are deliberately decoupled by the full
cooldown duration.

**Fix:** Not a misconfiguration to fix in the usual sense -- either wait out the full `cooldownPeriod`
(at `5:00` after window-close, `ACTIVE` and the scale-down will happen together), or if faster scale-down
is genuinely wanted for a Cron-based schedule (where there's no real risk of "noise" to protect against),
explicitly lower `cooldownPeriod` to a small value like `10` or `30`, as Step 3's manifest already does.

**Cascade:** Reported as a false "KEDA isn't detecting schedule changes" ticket if the team doesn't know
that `ACTIVE` intentionally lags the real trigger state by up to the full `cooldownPeriod`. No actual
malfunction -- the Deployment scales to zero correctly, `ACTIVE` updates correctly, both simply happen
later, together, than the cron schedule alone would suggest.

</details>

**Cleanup:**
```bash
kubectl delete -f 03-scaledobject-cooldown-surprise.yaml --ignore-not-found
kubectl delete -f ../01-worker-deploy.yaml --ignore-not-found
cd ../..
```

---

## Interview Prep

**Q1. Explain how KEDA achieves scale-to-zero when HPA cannot. What is the exact mechanism?**

HPA's `minReplicas` must be ≥ 1 by default — it will never set a Deployment to 0 replicas under the standard configuration this series uses. KEDA achieves scale-to-zero in two separate steps handled by two separate components. When the event source deactivates, HPA scales the Deployment down to 1 (its floor). KEDA Operator then monitors the scaler independently — when the scaler reports inactive AND the `cooldownPeriod` has elapsed, the Operator directly patches `Deployment.spec.replicas = 0`, bypassing HPA entirely for this final step. Scale-from-zero is the reverse: KEDA Operator polls the scaler even when the Deployment is at 0, detects activation, and patches the Deployment to `minReplicaCount`. Once at least 1 pod is running, HPA takes over and scales further based on the metric value.

**Q2. What happens if you create a manual HPA targeting the same Deployment as a KEDA ScaledObject?**

It depends on the order. If the ScaledObject already exists and you apply a manual HPA afterward: the manual HPA is not a KEDA resource, so KEDA's admission webhook never validates it — the apply succeeds. The conflict only surfaces afterward as `AmbiguousSelector`: the HPA controller cannot determine which of the two HPAs is authoritative and stops processing both. KEDA reports `ScalerNotReady` on the ScaledObject, and the Deployment's replica count freezes. If the order were reversed — a manual HPA already exists, and you try to create a ScaledObject on the same target — KEDA's webhook does catch that at apply time and rejects it immediately, the same way it rejects two ScaledObjects on the same target. Either way, the fix is the same: delete the manually-created HPA — KEDA owns the HPA for any Deployment it manages via ScaledObject.

**Q3. A ScaledObject's cron window closed two minutes ago, but the Deployment still has running pods. Is this a bug?**

Not necessarily. `cooldownPeriod` (default 300 seconds) is a flat delay KEDA Operator waits after a trigger deactivates before actually scaling to zero — it applies unconditionally, not just when the "inactive" signal is ambiguous or noisy. For Cron specifically, the window-closed signal is completely unambiguous, but the delay still applies the same way it would for a noisy queue-based scaler. Before treating this as a defect, check `cooldownPeriod` in the ScaledObject spec — the Deployment will still scale to zero once that full duration has elapsed since the last active reading.

**Q4. What is the difference between `pollingInterval`, `cooldownPeriod`, and how do they interact during a scale-to-zero cycle?**

`pollingInterval` (default 30s) controls how often KEDA queries the event source — it determines how quickly KEDA notices a change in either direction (this is Loop 1 from Concepts, distinct from HPA's own separate sync period). `cooldownPeriod` (default 300s) only applies on the way to zero: how long KEDA waits after the last active reading before actually patching the Deployment to 0 replicas. There's no equivalent grace period on the way from zero to active — scale-from-zero happens as soon as the next `pollingInterval` detects activation, with no cooldown-style delay in that direction.

**Q5. Why doesn't KEDA implement `custom.metrics.k8s.io`, and what does that mean practically when comparing it to the Prometheus Adapter?**

KEDA's uniform architecture serves every one of its 50+ scalers through a single mechanism — `external.metrics.k8s.io` — regardless of whether the underlying metric conceptually belongs to a Kubernetes object or not. This keeps KEDA simple to extend with new scalers, but it means KEDA never provides the native per-pod or per-object averaging that `custom.metrics.k8s.io`'s `Pods`/`Object` types give you through the Prometheus Adapter. Practically: if a metric is naturally per-pod (like requests-per-second per replica), the Prometheus Adapter's `type: Pods` gives you that averaging for free; the same metric through KEDA would need to be expressed as a single aggregate PromQL query with no per-pod breakdown.

**Q6. A ScaledObject's `pollingInterval` is set to 60 seconds. Does that mean the managed HPA only recalculates desired replicas once a minute?**

No — this is a common misreading of what `pollingInterval` actually governs. It only controls how often `keda-operator`'s own activation poll (Loop 1) runs, deciding the 0↔1 edge. Once the Deployment has at least one running pod, the ordinary HPA controller takes over the 1↔N scaling math (Loop 2) on its own independent sync period (a cluster-wide `kube-controller-manager` setting, typically ~15 seconds, unrelated to anything in the ScaledObject). `pollingInterval` only affects how quickly KEDA notices activation from zero — it has no bearing on how often replicas are recalculated once already active.

**Q7. Two ScaledObjects are accidentally created targeting the same Deployment. Separately, someone creates a manual HPA targeting a Deployment that already has a ScaledObject. Do both mistakes get caught the same way?**

No, and the difference matters operationally. KEDA's admission webhook validates KEDA-native resources against each other at apply time, including against an existing conflicting resource — two ScaledObjects targeting the same Deployment are rejected immediately, before the second one is ever created; so is a new ScaledObject applied against a Deployment that already has a conflicting HPA. But a manually-created HPA applied *after* a ScaledObject already exists is not itself a KEDA resource, so the webhook never validates it at all — that conflict only surfaces later, at the ordinary Kubernetes HPA-controller level, as `AmbiguousSelector` in the ScaledObject's Conditions. The `kubectl apply` for the manual HPA succeeds without any error in that ordering, and the failure only becomes visible once you check the ScaledObject's status afterward. The rule to remember: KEDA's webhook protects KEDA resources being created, not arbitrary resources being created against KEDA state.

**Q8. `minReplicaCount: 0` is set in a ScaledObject. What does the resulting HPA's own `minReplicas` field show, and why can't it match?**

By default it always shows `1`, never `0` — the HPA API rejects `minReplicas: 0` at schema validation under the standard configuration, since HPA's algorithm requires at least one running pod to have any metric to compute against. KEDA's managed HPA stays within that legal range, and `keda-operator` handles the entire 0↔1 transition itself by directly patching the Deployment's replica count outside the HPA object entirely. (There is a Kubernetes alpha feature gate, `HPAScaleToZero`, that allows `minReplicas: 0` directly for Object/External-metric HPAs when explicitly enabled — it's off by default on essentially every standard cluster, which is why the unconditional behavior above is what you'll actually see.) The tell in `kubectl get hpa` output is a Deployment showing `REPLICAS` below the HPA's own `MINPODS` — something an ordinary HPA could never produce through its own reconciliation loop alone.

**Q9. Does scale-to-zero work the same way for a CPU/memory-triggered ScaledObject as it does for Cron or Redis?**

No — this is a real limitation, not a configuration mistake. Scale-to-zero depends on `keda-operator` being able to poll the trigger source even while the Deployment has zero pods, which is exactly what KEDA's External-metrics architecture (`keda-operator-metrics-apiserver`) enables. Plain CPU/memory Resource-type triggers don't go through that path at all — the managed HPA reads CPU/memory directly from the cluster's ordinary `metrics-server`, the same source `01-hpa-basic` used. With zero pods running, there's no CPU/memory data to read, so there's no signal available to decide when to scale back up. You can technically set `minReplicaCount: 0` on a CPU/memory-triggered ScaledObject, but it won't reliably reach zero, and if it did, it couldn't recover on its own. Scale-to-zero is specifically an External-metrics capability.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Demo concept / command | CKA objective | CKAD objective | Notes |
|---|---|---|---|
| ScaledObject CRD — structure and fields | Cluster Architecture, Installation & Configuration (25%) | Application Deployment (20%) | Know `scaleTargetRef`, `triggers`, `minReplicaCount`, `cooldownPeriod` |
| KEDA manages HPA — do not create manual HPA alongside | Troubleshooting (30%) | Application Deployment (20%) | AmbiguousSelector is the failure mode; order of creation determines whether it's caught at apply time or later — delete the manual HPA to fix either way |
| Scale-to-zero sequence (KEDA Operator, not HPA) | Cluster Architecture, Installation & Configuration (25%) | Application Deployment (20%) | HPA takes to 1; KEDA takes to 0 — two-component mechanism; External-metrics triggers only, not CPU/memory |
| `kubectl get scaledobject` — READY/ACTIVE/FALLBACK/PAUSED columns | Troubleshooting (30%) | — | READY=False → scaler cannot reach source or target not found; ACTIVE=False → trigger currently inactive; PAUSED=True → manually frozen via annotation |
| `cooldownPeriod` vs. `pollingInterval` | Troubleshooting (30%) | — | Common exam trap — read Break-Fix Error-3 |
| `activationThreshold` vs. a trigger's scaling threshold | Cluster Architecture, Installation & Configuration (25%) | Application Deployment (20%) | Two separate numeric concerns on the same trigger — activation always overrides scaling when they disagree |
| Admission webhook validation scope | Troubleshooting (30%) | — | Catches ScaledObject-vs-existing-HPA and ScaledObject-vs-ScaledObject conflicts at apply time; does NOT catch a manual HPA applied after a ScaledObject already exists |

### Common Exam Traps

| Question pattern | Correct answer | Why wrong answers fail |
|---|---|---|
| "KEDA replaces HPA" | False — KEDA creates and manages HPA objects; HPA still does the pod scaling | KEDA extends HPA; it does not bypass or replace the HPA reconciliation loop |
| "Set `minReplicas: 0` in the HPA to achieve scale-to-zero with KEDA" | False — the KEDA-managed HPA is auto-generated; do not edit it. Use `minReplicaCount: 0` in the ScaledObject | Editing the KEDA-managed HPA is overwritten; `minReplicaCount` in ScaledObject is the correct field |
| "`cooldownPeriod` only matters for noisy event sources" | False — it applies as a flat, unconditional delay for every trigger type, including Cron, where the deactivation signal is never ambiguous | The delay exists regardless of whether the underlying signal needed debouncing |
| "Delete the KEDA-managed HPA directly to stop scaling" | False — KEDA recreates it; delete the ScaledObject instead | KEDA owns the HPA lifecycle; directly deleting the HPA only stops scaling temporarily |
| "KEDA implements `custom.metrics.k8s.io` for Kubernetes-native metrics" | False — KEDA only ever implements `external.metrics.k8s.io`, even for metrics that are conceptually per-pod | This is why Prometheus Adapter, not KEDA, is the right tool when you need native Pods/Object type averaging |
| "`pollingInterval` controls how often the managed HPA recalculates replicas" | False — it only governs `keda-operator`'s own 0↔1 activation poll (Loop 1); the 1↔N math runs on HPA's own independent sync period (Loop 2) | A common conflation of KEDA's two separate polling loops into one |
| "A manual HPA applied after a ScaledObject already exists gets rejected at apply time, same as a duplicate ScaledObject would" | False — the admission webhook only validates KEDA-native resources being applied; a non-KEDA HPA slips past it entirely regardless of what it conflicts with, and only surfaces as `AmbiguousSelector` later. (Reversed order — a ScaledObject applied against an existing conflicting HPA — IS caught at apply time.) | Two different conflict-detection layers, with different timing and different visibility depending on creation order |
| "`minReplicaCount: 0` always means the ScaledObject can genuinely reach zero replicas" | False for CPU/memory Resource triggers specifically — those read from ordinary metrics-server, which has no data at zero pods, so KEDA has no signal to scale back up | Scale-to-zero is an External-metrics-architecture capability, not automatic for every trigger type KEDA supports |

### Exam Task — Write it from scratch

<details>
<summary>Task: Given a Deployment named <code>report-worker</code> in namespace <code>default</code>, write a ScaledObject named <code>report-worker-scaler</code> that scales it to 0 replicas outside 06:00–08:00 UTC daily, and to 4 replicas during that window. Use a 60-second cooldownPeriod.</summary>

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: report-worker-scaler
  namespace: default
spec:
  scaleTargetRef:
    name: report-worker
  minReplicaCount: 0
  maxReplicaCount: 4
  cooldownPeriod: 60
  triggers:
    - type: cron
      metadata:
        timezone: UTC
        start: "0 6 * * *"
        end: "0 8 * * *"
        desiredReplicas: "4"
```

Verify with `kubectl get scaledobject report-worker-scaler` (expect `READY=True`) and `kubectl get hpa` (expect `keda-hpa-report-worker-scaler` with `MINPODS: 1`, not 0, per the default HPA validation behavior).

**Key fields to recall without looking them up:** `scaleTargetRef.name` (not `deploymentName` — that's a pre-2.0 field name), `minReplicaCount`/`maxReplicaCount` (not `minReplicas`/`maxReplicas` — those are HPA's own field names, easy to confuse under exam pressure), `triggers[].metadata` (Cron's `start`/`end`/`timezone`/`desiredReplicas` live inside `metadata`, not as top-level trigger fields).

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| KEDA is two components doing two different jobs | `keda-operator` owns the 0↔1 edge directly; `keda-operator-metrics-apiserver` only ever answers metric questions for the HPA. Every mechanic in this demo is one of these two doing its one job |
| KEDA extends HPA, not replaces it | KEDA creates and manages HPA objects; HPA still reconciles pod count via the standard Kubernetes loop |
| Scale-to-zero mechanism | HPA floors at minReplicas=1 by default; KEDA Operator detects inactive trigger + cooldownPeriod elapsed → directly patches Deployment to 0 |
| Scale-from-zero mechanism | KEDA Operator polls the trigger at 0 replicas; detects activation → patches Deployment to minReplicaCount; HPA takes over for 1→N |
| Scale-to-zero is External-metrics only | CPU/memory Resource triggers read from ordinary metrics-server, which has no data at zero pods — those triggers can never reliably reach or recover from zero |
| ScaledObject | Primary KEDA CRD; references scaleTargetRef + triggers; KEDA Operator creates and manages the corresponding HPA |
| ScaledJob | KEDA CRD for run-to-completion workloads; one Job per unit of work; not long-running Deployments |
| TriggerAuthentication / ClusterTriggerAuthentication | Namespace- and cluster-scoped credential stores for KEDA scalers; not needed for Cron (no credentials); hands-on in `05-keda-redis-scaler` |
| The two polling loops | Loop 1 (`keda-operator`, `pollingInterval`, default 30s) decides activation only. Loop 2 (ordinary HPA's own sync period, ~15s, unrelated to `pollingInterval`) decides 1→N scaling. Independent of each other |
| cooldownPeriod | Flat, unconditional delay after a trigger deactivates before scaling to zero (default: 300s) — applies even to unambiguous signals like Cron's window close; only applies on the way to zero, never on the way up |
| Cron scaler | Schedule-based; no external event source; UTC or named timezone; needs no credentials or extra infrastructure |
| Admission webhook conflict detection depends on order | Catches a new ScaledObject applied against an existing conflicting HPA/ScaledObject at apply time. Does NOT catch a manual HPA applied after a ScaledObject already exists — that surfaces later as AmbiguousSelector |
| KEDA Metrics Server | Implements `external.metrics.k8s.io` only — never `custom.metrics.k8s.io`; registered as an APIService |
| KEDA vs. Prometheus Adapter | KEDA: uniform External-only architecture, simpler for aggregate metrics, native scale-to-zero. Adapter: native Pods/Object per-object averaging that KEDA cannot provide |
| `kubectl get scaledobject` columns | READY: can KEDA reach the source and find the target? ACTIVE: is the trigger currently above its activation condition? |

> **Demo scope:** Primary concept: KEDA architecture and the two-component scale-to-zero/from-zero mechanism (KEDA Operator handles 0↔1, HPA handles 1↔N). Supporting concepts: KEDA components (Operator, Metrics Server), Kubernetes objects KEDA creates, ScaledObject field reference, the two polling loops, activation vs. scaling, Cron scaler as the zero-infrastructure hands-on vehicle, KEDA-vs-Adapter callout for External metrics.
> Estimated completion time: 40–45 minutes (reading + hands-on + verification), including unavoidable wait time for the cron window cycle.
> Checkpoints: 2 natural stopping points — after Step 2 (worker deployed, before creating the ScaledObject) and after Step 3 (full cron cycle observed, before cleanup).

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get scaledobject` | List all ScaledObjects — READY, ACTIVE, FALLBACK status |
| `kubectl describe scaledobject <name>` | Full ScaledObject status, conditions, and scaler details |
| `kubectl get hpa` | List HPAs — includes KEDA-managed HPAs (named `keda-hpa-<scaledobject-name>`) |
| `kubectl describe hpa <name> \| grep -A8 Conditions` | See the HPA's own ScalingActive/AbleToScale conditions — useful to confirm `ScalingActive: False` is expected at zero replicas, not an error |
| `kubectl get apiservices \| grep external` | Verify KEDA Metrics Server is registered for external.metrics.k8s.io |
| `kubectl api-resources \| grep keda` | List all KEDA CRDs |
| `kubectl logs -n keda -l app=keda-operator` | KEDA Operator logs — scaling decisions and errors |
| `kubectl create deployment worker --image=busybox:1.36 --dry-run=client -o yaml` | Generate the base Deployment skeleton this demo's `worker` targets — a plain Deployment, not a KEDA object, so the ordinary imperative equivalent applies. ScaledObject itself has no `kubectl create` imperative shortcut — it's a CRD you always write declaratively |
| `helm uninstall keda -n keda` | Uninstall KEDA (also removes CRDs and managed HPAs) |

---

## Troubleshooting

**ScaledObject shows `READY=False`:**
```bash
kubectl describe scaledobject <name> | grep -A10 "Conditions:"
# ScalerNotReady: "deployments.apps <name> not found"
#   -> typo in scaleTargetRef.name -- check spelling
# ScalerNotReady: "AmbiguousSelector: found multiple HPAs..."
#   -> a manual HPA also targets this Deployment -- delete it
```

**ScaledObject shows `READY=True` but Deployment stays at 0 outside expectations:**
```bash
kubectl get scaledobject <name>
# ACTIVE=False -> outside the current trigger's active condition
# For Cron: check the current UTC time against start/end
# This is expected, not an error, if you're simply outside the window
```

**Deployment doesn't scale to zero immediately after the trigger deactivates:**
```bash
kubectl describe scaledobject <name> | grep cooldown
# Default: 300s (5 minutes) -- this is expected, not a bug (see Break-Fix Error-3)
# Reduce cooldownPeriod in the ScaledObject spec if faster scale-down is genuinely needed
```

**A CPU/memory-triggered ScaledObject with `minReplicaCount: 0` never actually reaches or recovers from zero:**
```bash
# This is a known limitation, not a misconfiguration -- see the "Limitation worth
# knowing" callout under Activation vs. Scaling in Concepts. CPU/memory triggers
# read from ordinary metrics-server, which has no data at zero pods, so there's
# no signal to scale back up from. Switch to an External-metrics trigger
# (Cron, Redis, Prometheus, etc.) if scale-to-zero is actually required.
```

---

## Appendix — Anki Cards

**`04-keda-fundamentals-anki.csv`:**

```
#deck:k8s-platform-labs::11-auto-scaling::04-keda-fundamentals
#separator:Comma
#columns:Front,Back,Tags
"HPA requires minReplicas >= 1 by default. How does KEDA enable scale-to-zero when HPA cannot?","KEDA Operator monitors the scaler independently. When the trigger is inactive AND cooldownPeriod has elapsed, KEDA Operator directly patches Deployment.spec.replicas=0, bypassing HPA. Scale-from-zero: Operator polls the trigger at 0 replicas; when it activates, Operator patches to minReplicaCount; then HPA takes over for 1->N.","04-keda-fundamentals,architecture,scale-to-zero"
"Does KEDA replace HPA?","No. KEDA creates and manages HPA objects. HPA still reconciles pod count via the standard Kubernetes loop. KEDA adds: (1) scale-to-zero by direct Deployment patching, (2) scale-from-zero by polling at 0 replicas, (3) 50+ built-in scalers via its Metrics Server.","04-keda-fundamentals,architecture"
"What is a ScaledObject, and what does the KEDA Operator create from it?","ScaledObject (keda.sh/v1alpha1) is the primary KEDA CRD. It references a scaleTargetRef (Deployment), triggers, minReplicaCount, maxReplicaCount, pollingInterval, cooldownPeriod. KEDA Operator creates a corresponding HPA (named keda-hpa-<scaledobject-name>) that uses KEDA Metrics Server as its External metric source.","04-keda-fundamentals,scaledobject,architecture"
"A ScaledObject already exists on a Deployment. Someone then applies a manual HPA on the same Deployment. Is the manual HPA's apply rejected immediately?","No. KEDA's admission webhook only validates KEDA-native resources. A plain HPA is not a KEDA resource, so it applies successfully even though it conflicts. The conflict only surfaces afterward as AmbiguousSelector at the ordinary HPA-controller level -- both HPAs then stop functioning.","04-keda-fundamentals,break-fix,conflict,admission-webhook"
"A manual HPA already exists on a Deployment. Someone then tries to create a ScaledObject targeting the same Deployment. Is that apply rejected?","Yes -- this is the reverse order from the more common break-fix scenario. KEDA's admission webhook DOES validate a new ScaledObject being created against an existing conflicting HPA (or ScaledObject), and rejects it at apply time. Creation order determines whether a conflict is caught immediately or only surfaces later.","04-keda-fundamentals,admission-webhook,conflict-detection,order-matters"
"A ScaledObject's cron window closed 2 minutes ago but pods are still running. Is this a bug?","No -- cooldownPeriod (default 300s) is a flat, unconditional delay after a trigger deactivates, applied even when the deactivation signal (like a cron window closing) is completely unambiguous. Check cooldownPeriod before assuming a defect.","04-keda-fundamentals,cooldownperiod,break-fix"
"What is the difference between pollingInterval and cooldownPeriod?","pollingInterval (default 30s): how often KEDA queries the event source -- affects reaction latency in both directions (Loop 1). cooldownPeriod (default 300s): only applies on the way to zero -- how long KEDA waits after the last active reading before actually scaling to 0. There is no equivalent delay on the way from zero to active.","04-keda-fundamentals,timing,scaledobject"
"Why doesn't the Cron scaler need a TriggerAuthentication?","Cron scales purely against the system clock -- there's no external event source to authenticate to. TriggerAuthentication is only needed for scalers that connect to a real backend (Redis, Kafka, cloud APIs, etc.).","04-keda-fundamentals,cron-scaler,triggerauthentication"
"What KEDA CRD would you use for batch processing (one Job per unit of work) vs long-running queue consumer (Deployment)?","ScaledJob for batch/run-to-completion: each trigger fires a Kubernetes Job that processes one unit of work and completes. ScaledObject for long-running Deployment: the Deployment scales up/down continuously, never completing.","04-keda-fundamentals,scaledjob,scaledobject"
"What is the scale-from-zero sequence in KEDA?","1. Deployment at 0 replicas; HPA suspended. 2. KEDA Operator polls the trigger every pollingInterval. 3. Trigger activates. 4. KEDA Operator patches Deployment to minReplicaCount. 5. Pod starts; HPA activates and calculates desired replicas. 6. HPA scales from 1 to N based on the metric.","04-keda-fundamentals,scale-from-zero,architecture"
"Does KEDA implement custom.metrics.k8s.io?","No. KEDA implements ONLY external.metrics.k8s.io, for every one of its 50+ scalers, regardless of whether the underlying metric is conceptually per-pod or per-object. This is why KEDA cannot provide the native per-pod averaging that the Prometheus Adapter's type: Pods gives you.","04-keda-fundamentals,architecture,custom-metrics"
"Why isn't KEDA's Prometheus scaler really in competition with the Prometheus Adapter?","They solve different problems in practice. Adapter's real value is Custom metrics (Pods/Object) tied to Kubernetes objects with native per-pod averaging -- something KEDA cannot do. KEDA's real value for Prometheus-sourced metrics is when you'd otherwise use Adapter's rarely-used external: rule type -- KEDA does the same job with a single raw PromQL query field instead of a 4-field ConfigMap rule, plus native scale-to-zero.","04-keda-fundamentals,prometheus-scaler,comparison"
"You kubectl get hpa and see keda-hpa-worker-cron-scaler. Who created it and can you edit it?","KEDA Operator created it automatically when a ScaledObject targeting the worker Deployment was applied. Do NOT edit or delete it directly -- KEDA will overwrite any changes and will recreate it if deleted. Manage scaling by editing the ScaledObject instead.","04-keda-fundamentals,scaledobject,hpa"
"A ScaledObject shows READY=True but ACTIVE=False. What does this mean?","READY=True: KEDA can reach the event source and the target Deployment exists. ACTIVE=False: the trigger's current condition is not met (e.g. outside a cron window, or queue below activationThreshold). This is expected when there's genuinely no work, not an error.","04-keda-fundamentals,troubleshooting,status"
"(CKA) A ScaledObject has minReplicaCount: 0 and cooldownPeriod: 60. Its cron window closed 90 seconds ago. Is 0 pods expected right now?","Yes -- 90 seconds have elapsed, which is longer than the 60-second cooldownPeriod, so KEDA Operator should have already patched the Deployment to 0. If pods are still running at 90+ seconds past window-close with cooldownPeriod: 60, that WOULD indicate a genuine problem worth investigating.","04-keda-fundamentals,cka-cluster-architecture-installation-configuration,cooldownperiod"
"(CKA) kubectl describe scaledobject shows ScalerNotReady: AmbiguousSelector. What caused this and how do you fix it?","Cause: a manually-created HPA also targets the same Deployment as the ScaledObject. The HPA controller finds multiple HPAs for the same scaleTargetRef and refuses to process either. Fix: kubectl get hpa to identify the manual HPA (the KEDA-managed one is named keda-hpa-<scaledobject-name>); kubectl delete hpa <manual-hpa-name>.","04-keda-fundamentals,cka-troubleshooting,break-fix"
"A ScaledObject's pollingInterval is set to 60s. Does the managed HPA only recalculate replicas once a minute?","No. pollingInterval only governs keda-operator's own activation poll (the 0<->1 edge, Loop 1). Once at least one pod is running, the ordinary HPA controller recalculates on its OWN independent sync period (Loop 2, a cluster-wide setting, ~15s by default), completely unrelated to pollingInterval.","04-keda-fundamentals,pollinginterval,polling-loops"
"What are KEDA's two separate polling loops, and what does each one govern?","Loop 1: keda-operator's activation poll, governed by pollingInterval, decides IsActive (0<->1 only) -- officially called the Activation Phase in KEDA's docs. Loop 2: the ordinary HPA controller's own metric-fetch poll, governed by HPA's own sync period (not pollingInterval), decides 1->N scaling -- the Scaling Phase. They run independently of each other.","04-keda-fundamentals,polling-loops,architecture"
"By default, does keda-operator-metrics-apiserver cache scaler values, or query fresh every time?","Fresh, live, on every single request from either polling loop -- nothing is stored in a CRD or database by default. An opt-in useCachedMetrics feature changes this, but it's off by default and unsupported for the Cron scaler entirely.","04-keda-fundamentals,scaler-logic,caching"
"A trigger has a scaling threshold of 10 and an activationThreshold of 50. The metric is currently 40. Scaling math alone would want 4 replicas. What actually happens?","The Deployment scales to zero. Activation always overrides scaling when they disagree -- 40 is below the activationThreshold of 50, so KEDA treats the trigger as not active regardless of what the scaling math (ceil(40/10)=4) would otherwise recommend.","04-keda-fundamentals,activationthreshold,worked-example"
"Why does this demo's Cron ScaledObject never set activationThreshold?","Cron's activation decision is a boolean (inside the scheduled window or not), not a numeric value to compare against a floor. activationThreshold only applies to trigger types with an inherently numeric activation condition, like queue depth -- covered hands-on with Redis in 05-keda-redis-scaler.","04-keda-fundamentals,activationthreshold,cron-scaler"
"Does scale-to-zero work for a CPU/memory-triggered ScaledObject the same way it does for Cron or Redis?","No. CPU/memory Resource triggers read directly from ordinary metrics-server, bypassing keda-operator-metrics-apiserver entirely. With zero pods, there's no CPU/memory data to read, so KEDA has no signal to scale back up from zero. Scale-to-zero reliably works only for External-metrics triggers (Cron, Redis, Prometheus, etc.).","04-keda-fundamentals,limitation,cpu-memory-trigger,scale-to-zero"
"Can the HPA API ever accept minReplicas: 0 directly, without KEDA's involvement?","Yes, but only via the alpha feature gate HPAScaleToZero, and only for HPAs using at least one Object or External metric (never plain CPU/memory Resource metrics). This gate is off by default on essentially every standard cluster, which is why KEDA's managed HPA always shows MINPODS: 1 in this demo.","04-keda-fundamentals,hpa,exam-trap,alpha-feature"
"What does the keda-admission-webhooks component actually validate, and what does it NOT catch?","It validates KEDA CRDs (ScaledObject, ScaledJob, TriggerAuthentication) at the moment they're applied -- e.g. rejecting a new ScaledObject against an already-conflicting HPA or ScaledObject. It does NOT catch a manually-created, non-KEDA HPA applied AFTER a ScaledObject already exists, since that HPA isn't a KEDA resource the webhook validates -- order of creation determines catchability.","04-keda-fundamentals,admission-webhook,architecture"
"What Kubernetes objects does a fresh KEDA Helm install actually create, beyond the three keda namespace pods?","3 Deployments (one per pod) and their Services; a small set of internal ConfigMaps and a Secret holding the admission webhook's TLS cert; and cluster-scoped CRDs (ScaledObject, ScaledJob, TriggerAuthentication, ClusterTriggerAuthentication, plus CloudEventSource/ClusterCloudEventSource for KEDA's event-emission feature) and an APIService for external.metrics.k8s.io. No GUI ships with open-source KEDA.","04-keda-fundamentals,keda-objects,orientation"
"When a ScaledObject is at 0 replicas, what does kubectl describe hpa show for the ScalingActive condition, and is that a problem?","ScalingActive: False, with a message like 'scaling is disabled since the replica count of the target is zero.' This is expected and healthy -- there are no pods to read a metric from, so the HPA correctly reports it has nothing to do. It is not an error.","04-keda-fundamentals,hpa-conditions,scale-to-zero"
```

## Appendix — Quiz

**`04-keda-fundamentals-quiz.md`:**

````markdown
# Quiz — 11-auto-scaling/04-keda-fundamentals: KEDA Architecture, ScaledObjects, and Scale-to-Zero

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next demo.

**Q1. HPA requires `minReplicas >= 1` by default. How does KEDA achieve scale-to-zero?**

- A) KEDA replaces HPA with its own controller that supports 0 replicas
- B) KEDA Operator directly patches Deployment.spec.replicas=0, bypassing HPA for the final 1→0 step
- C) KEDA sets HPA `minReplicas: 0` on the managed HPA object
- D) KEDA uses the VPA Updater to evict the last pod

<details>
<summary>Answer</summary>

**B** — HPA scales from N down to 1 (its floor); KEDA Operator then handles 1→0 by directly patching the Deployment spec, bypassing HPA entirely for this final step.

Trap A: KEDA does not replace HPA — it creates and manages HPA objects. Trap C: the KEDA-managed HPA's `minReplicas` stays at 1 by default — HPA rejects 0 at schema validation unless the alpha `HPAScaleToZero` gate is explicitly enabled. Trap D: VPA Updater has no role in KEDA scaling.

</details>

---

**Q2. You create a ScaledObject targeting the `worker` Deployment. What does KEDA create automatically?**

- A) A VPA targeting the same Deployment
- B) A Pod that runs the KEDA scaler logic
- C) An HPA named `keda-hpa-<scaledobject-name>` targeting the same Deployment
- D) A ClusterTriggerAuthentication for the event source

<details>
<summary>Answer</summary>

**C** — KEDA Operator creates and manages an HPA object for every ScaledObject, named `keda-hpa-<scaledobject-name>`.

Trap A: VPA is unrelated to KEDA. Trap B: scaler logic runs inside the Operator and Metrics Server, not a separate Pod per ScaledObject. Trap D: TriggerAuthentication is created by you, not KEDA.

</details>

---

**Q3. A ScaledObject already exists on a Deployment. You then apply a manual HPA targeting the same Deployment. What happens?**

- A) The apply is rejected immediately by KEDA's admission webhook
- B) The apply succeeds; the conflict only surfaces afterward as AmbiguousSelector, and both HPAs stop functioning
- C) The manual HPA silently overrides the KEDA-managed one
- D) KEDA merges the two HPAs into one

<details>
<summary>Answer</summary>

**B** — A plain HPA is not a KEDA resource, so KEDA's admission webhook never validates it. The apply succeeds; the HPA controller then finds two HPAs targeting the same Deployment and cannot determine which is authoritative — both stop processing.

Trap A: this is true only in the REVERSE order (a ScaledObject applied against an already-existing conflicting HPA) — order matters. Trap C, D: no override or merge occurs — the conflict just breaks both.

</details>

---

**Q4. A ScaledObject's cron window closed 2 minutes ago (`cooldownPeriod: 300`, the default). `kubectl get pods` still shows the Deployment's pods running. Is this a bug?**

- A) Yes — KEDA should scale to zero the instant the window closes
- B) No — cooldownPeriod is a flat, unconditional delay applied after any trigger deactivation, including an unambiguous one like a cron window closing
- C) Yes — this only happens if pollingInterval is misconfigured
- D) No, but only because Cron scalers never actually scale to zero

<details>
<summary>Answer</summary>

**B** — `cooldownPeriod` (default 300s) applies as a flat delay regardless of whether the deactivation signal needed debouncing. 2 minutes is well within the 5-minute default.

Trap A: conflates the ACTIVE flag flipping with the scale-to-zero action actually happening — they're separated by cooldownPeriod. Trap C: pollingInterval controls query frequency, unrelated to this delay. Trap D: Cron scalers fully support scale-to-zero.

</details>

---

**Q5. What is the difference between `pollingInterval` and `cooldownPeriod`?**

- A) They are two names for the same setting
- B) pollingInterval controls query frequency in both directions; cooldownPeriod only delays the scale-to-zero action after deactivation
- C) pollingInterval only applies to Cron; cooldownPeriod only applies to Redis
- D) cooldownPeriod controls how fast pods scale up from zero

<details>
<summary>Answer</summary>

**B** — `pollingInterval` affects how often KEDA checks the event source, in both the activation and deactivation direction. `cooldownPeriod` only applies once on the way to zero — there's no equivalent grace period scaling up from zero.

Trap C: both settings are generic to all trigger types. Trap D: scale-from-zero has no cooldown-equivalent delay — it reacts at the next pollingInterval.

</details>

---

**Q6. Why doesn't the Cron scaler require a TriggerAuthentication?**

- A) Cron scalers are exempt from KEDA's authentication requirements by design
- B) Cron has no external event source to authenticate to — it scales purely against the system clock
- C) TriggerAuthentication is optional for every scaler type
- D) Cron uses the KEDA Operator's own service account instead

<details>
<summary>Answer</summary>

**B** — There's no backend system to connect to for a schedule-based trigger, so there's nothing to authenticate. TriggerAuthentication matters for scalers connecting to a real backend (Redis, Kafka, cloud APIs).

Trap A: it's not a special exemption — there's simply nothing to authenticate against. Trap C: some scalers absolutely require authentication for real use. Trap D: not how Cron works — it needs no external connection at all.

</details>

---

**Q7. Which KEDA CRD would you use to process one batch of files, where each file is handled by its own short-lived pod that exits when done?**

- A) ScaledObject
- B) ScaledJob
- C) TriggerAuthentication
- D) ClusterTriggerAuthentication

<details>
<summary>Answer</summary>

**B** — ScaledJob creates one Kubernetes Job per unit of work; each Job pod processes one item and exits. ScaledObject targets long-running Deployments that never "complete."

Trap A: ScaledObject is for long-running workloads. Trap C, D: these are for credentials, not scaling targets.

</details>

---

**Q8. What does the KEDA Metrics Server implement, and how does HPA use it?**

- A) It implements `metrics.k8s.io` — HPA reads CPU/memory from it
- B) It implements `external.metrics.k8s.io` — HPA queries it for trigger metrics via the External Metrics API
- C) It implements `custom.metrics.k8s.io` — HPA queries it for Pods and Object metric types
- D) It runs as a sidecar in each target pod

<details>
<summary>Answer</summary>

**B** — KEDA Metrics Server registers as an APIService for `external.metrics.k8s.io`. Every KEDA scaler, regardless of type, surfaces through this one API group.

Trap A: `metrics.k8s.io` is served by metrics-server, unrelated to KEDA — and it's exactly what a CPU/memory-triggered ScaledObject's HPA reads from directly, bypassing KEDA's own metrics server entirely. Trap C: KEDA never implements the Custom Metrics API — that's the Prometheus Adapter's domain. Trap D: KEDA Metrics Server is a cluster-wide Deployment, not per-pod.

</details>

---

**Q9. `kubectl get scaledobject` shows `READY=False` with `ScalerNotReady: deployments.apps "wroker" not found`. What is the most likely cause?**

- A) The target Deployment has 0 replicas
- B) A typo in `scaleTargetRef.name`
- C) KEDA is not installed correctly
- D) The trigger type is misconfigured

<details>
<summary>Answer</summary>

**B** — The error message names the exact missing Deployment name ("wroker"), which is a spelling mismatch against the real Deployment name ("worker") in `scaleTargetRef.name`.

Trap A: 0 replicas would still mean the Deployment exists — this error means it can't find the Deployment at all. Trap C: if KEDA itself were broken, you wouldn't get this specific, well-formed error. Trap D: the error is about finding the Deployment, not about the trigger.

</details>

---

**Q10. Why isn't KEDA's Prometheus scaler really in competition with the Prometheus Adapter's Custom metrics types?**

- A) They serve completely unrelated use cases with no overlap at all
- B) KEDA only implements `external.metrics.k8s.io`, so it can't provide the native per-pod/per-object averaging that Adapter's Pods/Object types give you — Adapter is the right tool whenever that averaging is needed
- C) KEDA's Prometheus scaler is strictly worse in every scenario
- D) The Prometheus Adapter cannot connect to the same Prometheus instance KEDA uses

<details>
<summary>Answer</summary>

**B** — The real division: Adapter's Custom metrics types provide native Kubernetes-object-aware averaging KEDA cannot replicate (KEDA is External-only, uniformly, for all 50+ scalers). KEDA is the simpler choice specifically for the External use case, where Adapter's `external:` rule type is the (rarely-used) alternative.

Trap A: there is real overlap in the External-metrics case, just not where most people assume. Trap C: KEDA is genuinely better for scale-to-zero and simple external aggregates. Trap D: both can point at the same Prometheus instance — that's not a limitation of either.

</details>

---

**Q11. A ScaledObject's `pollingInterval` is 60 seconds. The Deployment already has 2 running pods and load is increasing. How often does the managed HPA recalculate desired replicas?**

- A) Every 60 seconds, matching `pollingInterval`
- B) On HPA's own independent sync period (~15s by default), unrelated to `pollingInterval`
- C) Only when `keda-operator` explicitly triggers a recalculation
- D) Continuously, with no fixed interval

<details>
<summary>Answer</summary>

**B** — `pollingInterval` only governs `keda-operator`'s own activation poll (Loop 1, the 0↔1 edge). Once at least one pod is running, the ordinary HPA controller (Loop 2) takes over on its own sync period, which has nothing to do with `pollingInterval`.

Trap A: conflates KEDA's two separate polling loops into one. Trap C: `keda-operator` isn't involved in 1→N scaling at all once active. Trap D: HPA still operates on a fixed sync period, not continuously.

</details>

---

**Q12. A Redis trigger has `listLength: "10"` (scaling target) and `activationThreshold: "50"`. The queue currently has 40 items. What replica count does KEDA target?**

- A) 4 replicas — `ceil(40/10)`
- B) 0 replicas — 40 is below `activationThreshold`, so the trigger is not active regardless of the scaling math
- C) 5 replicas — rounds up from the activation threshold
- D) 1 replica — the minimum non-zero value

<details>
<summary>Answer</summary>

**B** — Activation always overrides scaling when they disagree. The scaling math alone would suggest 4 replicas, but since 40 is below the `activationThreshold` of 50, KEDA treats the trigger as inactive and scales to zero regardless.

Trap A: correct scaling-only arithmetic, but ignores that activation gates the whole decision first. Trap C, D: neither reflects how activation vs. scaling actually interact.

</details>

---

**Q13. A ScaledObject is applied targeting a Deployment that already has a manual HPA. Separately, a manual HPA is applied targeting a different Deployment that already has a ScaledObject. Are both conflicts caught the same way?**

- A) Yes — KEDA's admission webhook rejects both at apply time
- B) No — the webhook rejects the new ScaledObject at apply time (it validates against the existing HPA); the manual HPA in the second case isn't a KEDA resource, so it passes the webhook and only surfaces later as `AmbiguousSelector`
- C) No — neither is caught automatically; both require manual detection
- D) Yes — but only the manual HPA case produces an immediate error

<details>
<summary>Answer</summary>

**B** — KEDA's admission webhook validates KEDA-native resources being applied, including against pre-existing conflicting HPAs — so a new ScaledObject targeting an already-HPA'd Deployment is rejected immediately. A manually-created HPA is invisible to that webhook entirely, so it applies successfully when created after the ScaledObject, and only reveals the conflict later via the ScaledObject's `AmbiguousSelector` condition.

Trap A: overstates the webhook's scope — it only validates KEDA resources being applied, not arbitrary resources. Trap C: the ScaledObject-vs-existing-HPA case IS caught automatically. Trap D: inverts which case gets the immediate error.

</details>

---

**Q14. `minReplicaCount: 0` is set in a ScaledObject. What does `kubectl get hpa` show for that ScaledObject's managed HPA's `MINPODS` column?**

- A) 0, matching the ScaledObject exactly
- B) 1 by default — the HPA API rejects `minReplicas: 0` at schema validation unless the alpha `HPAScaleToZero` feature gate is explicitly enabled
- C) It depends on `maxReplicaCount`
- D) The column is blank until the first scaling event

<details>
<summary>Answer</summary>

**B** — HPA's own API validation requires `minReplicas ≥ 1` by default, since its algorithm needs at least one running pod to have any metric to compute against. KEDA's managed HPA respects this unconditionally on a standard cluster — `MINPODS` shows 1 regardless of `minReplicaCount` in the ScaledObject, and `keda-operator` handles the 0↔1 edge itself, outside the HPA entirely. (The `HPAScaleToZero` alpha gate is a real exception that exists, but is off by default on essentially every standard cluster, including this demo's.)

Trap A: this is exactly the mismatch that trips people up — the ScaledObject and the generated HPA genuinely disagree on this field, and that's expected. Trap C, D: neither reflects the actual mechanism.

</details>

---

**Q15. A ScaledObject uses a plain CPU Resource trigger (not Cron, Redis, or another External-metrics trigger) with `minReplicaCount: 0`. Can it reliably scale to zero and back?**

- A) Yes — KEDA handles all trigger types identically for scale-to-zero
- B) No — CPU/memory triggers read from ordinary metrics-server, which has no data at zero replicas, so there's no signal to scale back up from zero
- C) Yes, but only if `activationThreshold` is set
- D) No — CPU/memory triggers are entirely unsupported by KEDA

<details>
<summary>Answer</summary>

**B** — CPU/memory Resource-type triggers bypass `keda-operator-metrics-apiserver` entirely; the managed HPA reads directly from ordinary Kubernetes `metrics-server`, the same source `01-hpa-basic` used. At zero pods there is no CPU/memory data at all, so `keda-operator` has no basis to decide when to reactivate. Reliable scale-to-zero requires an External-metrics trigger.

Trap A: this is precisely the exception — not every trigger type behaves the same way for scale-to-zero. Trap C: `activationThreshold` doesn't fix a missing data source. Trap D: CPU/memory triggers work fine for ordinary 1→N scaling; the limitation is specific to zero.

</details>

---

Score guide:
| Score | Action |
|---|---|
| 15/15 | Import Anki cards, move to next demo |
| 13–14/15 | Review the wrong answers, then proceed |
| 11–12/15 | Re-read the relevant section, retry those questions |
| Below 11/15 | Re-read the full demo and redo the walkthrough before proceeding |
````