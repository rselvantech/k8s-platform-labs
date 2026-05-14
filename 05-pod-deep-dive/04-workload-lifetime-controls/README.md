# Workload Lifetime Controls — Deep Dive

## Lab Overview

Demo 07 introduced ResourceQuota scopes — including `Terminating` and
`NotTerminating` scopes that classify pods based on `spec.activeDeadlineSeconds`.
This demo goes deeper into the full set of fields that control **how long a
workload is allowed to run, how gracefully it shuts down, and how failures are
handled over time**.

```
Demo 07 referenced:
  → spec.activeDeadlineSeconds as a scope classifier
    (Terminating = activeDeadlineSeconds >= 0)
    (NotTerminating = activeDeadlineSeconds is nil)

This demo covers:
  → spec.activeDeadlineSeconds                         — hard wall-clock limit on active time
  → spec.backoffLimit                                  — max Pod retry attempts before giving up
  → spec.startingDeadlineSeconds                       — CronJob schedule miss tolerance window
  → spec.jobTemplate.spec.activeDeadlineSeconds        — per-Job runtime cap via CronJob
  → spec.terminationGracePeriodSeconds                 — grace window between SIGTERM and SIGKILL
  → spec.backoffLimitPerIndex                          — per-index failure budget (Indexed Jobs v1.29+)
  → spec.podFailurePolicy                              — fine-grained rules on failure handling (v1.26+)
  → Default behaviour — what happens when each field is NOT set
  → How these fields interact with each other
```

Real-world use case: a batch processing platform running nightly Jobs alongside
long-running services. Without lifetime controls, a single stuck Job can hold
namespace CPU and memory quota indefinitely — starving service workloads.
With properly tuned deadlines, backoff limits, and grace periods, batch and
service workloads coexist safely within shared namespace quotas.

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl installed and configured

**Knowledge Requirements:**
- **REQUIRED:** Completion of [07-resource-quota-deep-dive](../../03-pod-scheduling/07-resource-quota-deep-dive/)
- Understanding of Pod lifecycle — Running, Succeeded, Failed states
- Understanding of `Terminating` vs `NotTerminating` quota scopes
- Understanding of Job, CronJob, and bare Pod resource types

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain `spec.activeDeadlineSeconds` and its default behaviour
2. ✅ Distinguish `activeDeadlineSeconds` from `backoffLimit` — time vs attempts
3. ✅ Explain `terminationGracePeriodSeconds` shutdown sequence (concept) — full demo in 01-pod-lifecycle-termination-errors Step 7
4. ✅ Configure `startingDeadlineSeconds` and `jobTemplate.spec.activeDeadlineSeconds` on a CronJob
5. ✅ Use `backoffLimitPerIndex` for safe Indexed Job failure budgets
6. ✅ Apply `podFailurePolicy` to ignore evictions and fail fast on bad exit codes
7. ✅ Understand how all fields interact — which limit fires first
8. ✅ Read `kubectl describe job` STATUS, Events, and jsonpath conditions to identify `DeadlineExceeded` vs `BackoffLimitExceeded`
9. ✅ Understand `FailureTarget` vs `Failed` Job status transition and what each means

## Directory Structure

```
04-workload-lifetime-controls/
├── README.md                          # This file
└── src/
    ├── 01-active-deadline.yaml        # activeDeadlineSeconds hard termination
    ├── 02-backoff-vs-deadline.yaml    # backoffLimit vs activeDeadlineSeconds race
    ├── 03-grace-period.yaml           # terminationGracePeriodSeconds reference YAML (demo → 01-pod-lifecycle-termination-errors Step 7)
    ├── 04-cronjob-deadline.yaml       # startingDeadlineSeconds + per-Job activeDeadlineSeconds
    └── 05-pod-failure-policy.yaml     # podFailurePolicy — ignore / fail fast
```

---

## Understanding Workload Lifetime Controls

### What Are Lifetime Controls?

Lifetime controls are `spec` fields that govern **when** and **how** a workload ends.
They are not scheduling concerns (where a Pod runs) — they govern the
**duration and termination behaviour** of a workload after it has been placed and started.

```
Scheduling concerns  → where Pods land
                        (node selectors, taints, affinity)

Lifetime concerns    → how long Pods run and how they end
                        (activeDeadlineSeconds, backoffLimit,
                         terminationGracePeriodSeconds, ...)
```

### All Lifetime Control Fields — Where They Live

These fields exist at different levels of the Kubernetes object hierarchy.
Understanding which object and which spec level each field belongs to is
critical — setting a field at the wrong level has no effect.

| Field | Object | Spec Level | Purpose | Default |
|---|---|---|---|---|
| `spec.activeDeadlineSeconds` | Pod | Pod spec | Hard wall-clock ceiling on active time | `nil` (unlimited) |
| `spec.activeDeadlineSeconds` | Job | Job spec | Hard wall-clock ceiling; kills all Pods | `nil` (unlimited) |
| `spec.backoffLimit` | Job **only** | Job spec | Max Pod retry attempts before Job fails | `6` |
| `spec.podFailurePolicy` | Job **only** | Job spec | Fine-grained rules — ignore or fail fast | `nil` |
| `spec.backoffLimitPerIndex` | Job (Indexed) **only** | Job spec | Per-index failure budget | `nil` |
| `spec.startingDeadlineSeconds` | CronJob **only** | CronJob spec | Max seconds a missed schedule can be late | `nil` |
| `spec.jobTemplate.spec.activeDeadlineSeconds` | CronJob **only** | JobTemplate spec | Per-Job runtime cap for every spawned Job | `nil` |
| `spec.terminationGracePeriodSeconds` | Pod | Pod spec | Grace window between SIGTERM and SIGKILL | `30s` |

> **Pod vs Job scope:** `activeDeadlineSeconds` and `terminationGracePeriodSeconds`
> apply to both Pods and Jobs (Jobs embed a Pod template). `backoffLimit`,
> `podFailurePolicy`, and `backoffLimitPerIndex` are **Job-only** — a bare Pod
> has no retry mechanism at the Pod level; restarts are controlled by
> `restartPolicy` on the Pod spec, not by `backoffLimit`.

> **Note:** There is **no** `completionDeadlineSeconds` field on CronJob.
> Applying a CronJob YAML with that field produces:
> `Error: strict decoding error: unknown field "spec.completionDeadlineSeconds"`
> To cap how long each spawned Job runs, use `spec.jobTemplate.spec.activeDeadlineSeconds`.

### Default Behaviour — With vs Without Each Field

Understanding the **default** is as important as understanding the field itself.

```
activeDeadlineSeconds NOT set (default):
  → Workload runs indefinitely until success, backoffLimit exhausted,
    or manual deletion. A stuck Pod holds quota forever.

activeDeadlineSeconds SET:
  → Workload is hard-terminated at the deadline regardless of progress.
    Remaining backoffLimit retries are discarded.
    Confirmed via: kubectl get job -o jsonpath='{.status.conditions[*].reason}'
                   → DeadlineExceeded
    Also visible: Warning DeadlineExceeded in kubectl describe job Events section

backoffLimit NOT set (default = 6):
  → Job retries up to 6 times with exponential backoff before failing.
    A fast-failing container can exhaust this in seconds.

backoffLimit SET to 0:
  → Job fails immediately on first Pod failure — no retries at all.
    Confirmed via: Warning BackoffLimitExceeded in Events section

terminationGracePeriodSeconds NOT set (default = 30):
  → Pod gets 30 seconds between SIGTERM and SIGKILL.
    Containers with slow shutdown (DB connections, in-flight requests)
    may be killed mid-operation with exit code 137 (SIGKILL).

terminationGracePeriodSeconds SET:
  → Grace window is explicitly controlled — tune to actual shutdown time.

startingDeadlineSeconds NOT set (default):
  → CronJob will attempt to start a missed schedule at any time.
    If the controller was down and > 100 schedules were missed,
    the CronJob stops running entirely.

startingDeadlineSeconds SET:
  → CronJob only starts a missed Job if the delay is within this window.
    Missed schedules beyond this window are skipped and counted as failed.
```

### spec.activeDeadlineSeconds — In Depth

Sets a **hard elapsed-time ceiling** on a workload. Once breached, all associated
Pods are terminated and the resource is recorded as failed.

**What does "active" mean in standard Kubernetes terms?**

```
For a Job:
  → Timer starts when Job status.startTime is set by the job-controller
  → This happens when the first Pod is admitted and assigned to a node
  → In Pod terms: Pod condition PodScheduled = True
  → NOT when the container image finishes pulling (ContainersReady = True)
  → NOT when object is created — scheduling delays do NOT consume the budget

For a bare Pod:
  → Timer starts when Pod phase = Running
  → In Pod terms: at least one container has started (status.phase = Running)

For a CronJob:
  → Set activeDeadlineSeconds inside spec.jobTemplate.spec — not CronJob spec
  → Applies independently to each spawned Job — timer resets every run
```

**Where to check `activeDeadlineSeconds` in kubectl output — Job:**

```bash
kubectl describe job <n>
# Summary header — confirms field is set:
#   Active Deadline Seconds:  15s
#
# Events section — confirms it fired:
#   Warning  DeadlineExceeded  Xs  job-controller  Job was active longer than specified deadline
#
# Job STATUS column transitions during deadline firing:
kubectl get job <n> -w
# NAME    STATUS         COMPLETIONS   DURATION   AGE
# <n>     FailureTarget  0/1           16s        16s   ← intermediate: deadline fired, Pod cleanup in progress
# <n>     Failed         0/1           44s        44s   ← final: all Pods gone, Job settled as complete failure
#
# Via jsonpath — conditions array returns two entries (FailureTarget then Failed):
kubectl get job <n> -o jsonpath='{.status.conditions[*].reason}' && echo
# → DeadlineExceeded DeadlineExceeded
# (two values because both FailureTarget and Failed conditions share the same reason)
#
# For structured inspection of a single condition object:
kubectl get job <n> -o jsonpath='{.status.conditions[0]}' | python3 -m json.tool
# {
#     "lastProbeTime": "...",
#     "lastTransitionTime": "...",
#     "message": "Job was active longer than specified deadline",
#     "reason": "DeadlineExceeded",
#     "status": "True",
#     "type": "FailureTarget"
# }
```

> **`FailureTarget` explained:** Introduced in newer Kubernetes versions as a
> clearer intermediate Job condition. It signals that the failure cause has been
> determined (deadline exceeded) and Pod termination is in progress. `Failed` is
> the final settled state once all Pods are gone. Both conditions carry
> `reason: DeadlineExceeded` — two entries in the conditions array is normal.
>
> **Why `{.status.conditions[*]}` without `.reason` fails python3 json.tool:**
> The jsonpath `{.status.conditions[*]}` returns multiple JSON objects
> concatenated without a separator — not valid JSON for a parser. Use
> `{.status.conditions[0]}` (single index) to get one parseable object,
> or append `.reason` to extract just the string values.

**Where to check `activeDeadlineSeconds` in kubectl output — bare Pod:**

```bash
kubectl describe pod <n>
# Summary header — confirms field is set:
#   Active Deadline Seconds:  30s
#
# Status — when fired, Pod phase shows:
#   Status:   Failed
#   Reason:   DeadlineExceeded
#
# Via jsonpath:
kubectl get pod <n> -o jsonpath='{.status.reason}' && echo
# → DeadlineExceeded
```

**Key facts:**

```
  → Applies to: Pod, Job, CronJob (via jobTemplate.spec)
  → Does NOT apply to: Deployment, StatefulSet, DaemonSet
  → Overrides backoffLimit — remaining retries are discarded at deadline
  → Visible in kubectl describe job header as: Active Deadline Seconds: Xs
  → Failure evidence: Events section Warning DeadlineExceeded
                      OR: .status.conditions[*].reason = DeadlineExceeded
```

**Relation to ResourceQuota scopes (from Demo 07):**

```
Terminating    → matches Pods where spec.activeDeadlineSeconds >= 0
NotTerminating → matches Pods where spec.activeDeadlineSeconds is nil

This is the only reason activeDeadlineSeconds appears in Demo 07 —
as a Pod classifier for quota scope targeting, not as a quota field itself.
```
> 💡 Refer [07-resource-quota-deep-dive](../../03-pod-scheduling/07-resource-quota-deep-dive/), for learning more on how `spec.activeDeadlineSeconds` is used in  `Terminating` vs `NotTerminating` quota scopes.

### spec.backoffLimit — In Depth

Controls **how many times** the Job controller retries by creating or restarting
a failed Pod before marking the Job as failed.

> **Job-only field.** Bare Pods have no `backoffLimit`. For a standalone Pod,
> restart behaviour is governed entirely by `restartPolicy` on the Pod spec —
> there is no retry budget or failure count. A Pod with `restartPolicy: Always`
> or `restartPolicy: OnFailure` restarts indefinitely (subject to node resources)
> with no upper bound. To apply a retry budget, wrap the workload in a Job.

**Where to check `backoffLimit` in kubectl output — Job:**

```bash
kubectl describe job <n>
# Summary header — shows configured value:
#   Backoff Limit:  3
#
# Events section — confirms it fired:
#   Warning  BackoffLimitExceeded  Xs  job-controller  Job has reached the specified backoff limit
#
# Via jsonpath — reason from status conditions:
kubectl get job <n> -o jsonpath='{.status.conditions[*].reason}' && echo
# → BackoffLimitExceeded
```

> **No equivalent for bare Pods.** A standalone Pod does not have
> `backoffLimit`. There is no `kubectl describe pod` section for it.
> Use `kubectl describe pod <n>` → `Restart Count:` to see how many times
> the container has restarted, but this has no upper limit — it is not
> the same concept as `backoffLimit`.

**Key facts:**

```
  → Job-only field — does NOT apply to bare Pods, Deployments, StatefulSets
  → Default: 6
  → Each failed Pod attempt = one retry consumed
  → Retries use exponential backoff: 10s → 20s → 40s → ... capped at 6 min
  → restartPolicy on the Pod template controls HOW retries happen:

      restartPolicy: OnFailure  → same Pod is restarted in-place
                                  RESTARTS column in kubectl get pods increments
                                  Pod shows CrashLoopBackOff between retries
                                  CrashLoopBackOff is NORMAL — it is the backoff
                                  wait, NOT an additional failure count

      restartPolicy: Never      → failed Pod is NOT restarted in-place
                                  job-controller creates a BRAND NEW Pod for each retry
                                  NO CrashLoopBackOff — you see a new Pod name each time
                                  old failed Pods remain visible with STATUS: Error
                                  until TTL or manual cleanup

  → restartPolicy: Always is NOT valid inside a Job template —
    only OnFailure and Never are allowed
  → activeDeadlineSeconds always wins — remaining retries discarded at deadline
  → backoffLimit and activeDeadlineSeconds are orthogonal:
      backoffLimit = limits ATTEMPTS (how many times)
      activeDeadlineSeconds = limits ELAPSED TIME (how long total)
      whichever fires first wins
```

### spec.startingDeadlineSeconds — In Depth (CronJob)

Defines a **schedule miss tolerance window** for a CronJob — how many seconds
after the scheduled time Kubernetes is still allowed to start the Job.

```
Key facts:
  → Field lives on the CronJob spec (not jobTemplate) — CronJob level
  → Controls whether a MISSED schedule is still started or skipped
  → Does NOT control how long the spawned Job runs
  → Default: nil — missed jobs can start at any time after their schedule
  → Risk when nil: if > 100 schedules are missed, CronJob stops scheduling
  → Missed schedules beyond this window are counted as failed executions
```

**Comparison — startingDeadlineSeconds vs jobTemplate.spec.activeDeadlineSeconds:**

```
spec.startingDeadlineSeconds                       → CronJob spec level
  Controls: how late can a Job START after its scheduled time
  Example: CronJob scheduled at 08:00, controller was down
           → startingDeadlineSeconds: 300 means it still starts
             if the controller recovers within 5 minutes of 08:00

spec.jobTemplate.spec.activeDeadlineSeconds        → JobTemplate spec level
  Controls: how long the spawned Job is allowed to RUN after it starts
  Example: Job started at 08:03, activeDeadlineSeconds: 60
           → Job killed at 08:04 regardless of progress
```

### spec.terminationGracePeriodSeconds — In Depth

Defines the **grace window** Kubernetes gives a container to shut down cleanly
after receiving `SIGTERM` before issuing a hard `SIGKILL`.

**Key facts:**

```
  → Default: 30 seconds
  → Applies to ALL Pod types — Jobs, Deployments, StatefulSets, bare Pods
  → Field lives on: spec.terminationGracePeriodSeconds (Pod spec level)
  → Works in conjunction with preStop lifecycle hooks
  → If container exits before grace period ends, Pod terminates immediately
  → preStop hook time counts WITHIN the grace period budget
  → SIGKILL exit code: 137 (128 + signal 9)
```

**Full Pod shutdown sequence:**

```
Pod deletion triggered
      │
      ▼
  Pod removed from Service endpoints (stops receiving traffic)
      │
      ▼
  preStop hook executes (if defined) ──► counts against grace period budget
      │
      ▼
  SIGTERM sent to all containers
      │
      ▼
  [terminationGracePeriodSeconds countdown begins]
      │
      ├── Container exits cleanly ──► Pod terminates immediately ✅
      │                               exit code 0
      │
      └── Grace period expires ──► SIGKILL sent ──► exit code 137 ⚠️
```

**Where to check termination evidence:**

```bash
kubectl describe pod <n>
# In Containers section, Last State:
#   Last State:  Terminated
#     Exit Code:  137   ← SIGKILL — grace period expired
#     Exit Code:  0     ← clean exit within grace period
#
# In Events section:
#   Normal  Killing  Xs  kubelet  Stopping container app
```

> 💡 Refer [01-pod-lifecycle-termination-errors](../../04-pod-deep-dive/01-pod-lifecycle-termination-errors/), for learning more on how `spec.terminationGracePeriodSeconds` work along with container lifecycle hooks — `preStop` with example

### spec.backoffLimitPerIndex — In Depth (Indexed Jobs, v1.29+)

For **Indexed Jobs**, sets a per-index failure budget instead of a global one.
Prevents one consistently failing index from burning the entire `backoffLimit`
and failing the whole Job prematurely.

```
Field location: spec.backoffLimitPerIndex (Job spec level)

Without backoffLimitPerIndex (default):
  → All indexes share one global backoffLimit pool
  → Index 3 failing 6 times fails the entire Job
    even if indexes 0, 1, 2, 4 are healthy

With backoffLimitPerIndex:
  → Each index has its own independent retry budget
  → Index 3 can exhaust its budget and be marked failed
    while the rest of the Job continues running
```

### spec.podFailurePolicy — In Depth (Job, v1.26+)

Allows **fine-grained rules** over how specific Pod failures are counted — or
entirely ignored — against `backoffLimit`.

**Field location:** `spec.podFailurePolicy` on Job spec.

```
Two actions available:
  Ignore   → failure does NOT count against backoffLimit — retry freely
  FailJob  → failure causes the entire Job to fail immediately — no retries

Two matching mechanisms:
  onPodConditions → match by Pod condition type
                    DisruptionTarget = node eviction
  onExitCodes     → match by container exit code (int value)

Where to confirm in kubectl output:
  kubectl describe job <n>
  Events section:
    Warning  PodFailurePolicy  Xs  job-controller
      Container worker for pod <ns>/<pod-name> failed with exit code 42
      matching FailJob rule at index 1
```

**Version availability:**

```
v1.26–v1.27  → alpha  (requires JobPodFailurePolicy feature gate)
v1.28–v1.30  → beta   (feature gate enabled by default)
v1.31+       → GA     (no feature gate required)
```

### How All Fields Interact

```
Job starts
    │
    ├─── activeDeadlineSeconds timer starts (at Job status.startTime)
    │
    ├─── Pod runs → fails
    │         │
    │         ├── podFailurePolicy rule matches "Ignore"
    │         │         └──► retry — does NOT count against backoffLimit
    │         │
    │         ├── podFailurePolicy rule matches "FailJob"
    │         │         └──► Job fails immediately
    │         │              Event: Warning PodFailurePolicy
    │         │
    │         └── no policy match → counts against backoffLimit
    │                   │
    │                   └── backoffLimit exhausted
    │                             └──► Job fails
    │                                  Event: Warning BackoffLimitExceeded
    │
    └─── activeDeadlineSeconds fires
              └──► Job fails — all Pods terminated
                   Event: Warning DeadlineExceeded
                   (remaining retries discarded regardless of backoffLimit)
```

### Field Precedence Summary

```
activeDeadlineSeconds fires  →  always wins — overrides backoffLimit
podFailurePolicy FailJob     →  wins over backoffLimit — immediate failure
backoffLimit exhausted       →  wins if deadline has not yet fired
```

---

## Lab Step-by-Step Guide

---

### Step 1: Setup — Create Test Namespace

```bash
cd 04-workload-lifetime-controls/src
kubectl create namespace lifetime-demo
kubectl config set-context --current --namespace=lifetime-demo
```

Verify:
```bash
kubectl config view --minify | grep namespace
```

**Expected output:**
```
namespace: lifetime-demo
```

---

### Step 2: activeDeadlineSeconds — Hard Termination

Observe a Job being hard-terminated at the deadline regardless of `backoffLimit`.

**01-active-deadline.yaml:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: demo-active-deadline
  namespace: lifetime-demo
spec:
  activeDeadlineSeconds: 15       # Hard ceiling — kill after 15 seconds
  backoffLimit: 10                # 10 retries allowed — deadline will win
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: worker
          image: busybox
          command: ["sh", "-c", "echo 'Starting...'; sleep 120"]
```

```bash
kubectl apply -f 01-active-deadline.yaml
```

**How to read the Job output — three methods:**

```bash
# Method 1: watch STATUS column — observe the FailureTarget → Failed transition
kubectl get job demo-active-deadline -w
```

**Expected output:**
```
NAME                   STATUS          COMPLETIONS   DURATION   AGE
demo-active-deadline   FailureTarget   0/1           16s        16s
demo-active-deadline   FailureTarget   0/1           33s        33s
demo-active-deadline   Failed          0/1           44s        44s
```

> **`FailureTarget`** — intermediate state. The 15s deadline fired. Kubernetes has
> determined the failure cause and is in the process of terminating the running Pod.
> This cleanup window (a few extra seconds) is normal — it is NOT part of the deadline.
>
> **`Failed`** — final settled state. All Pods are gone. Job is marked complete failure.
>
> After it settles:

```bash
kubectl get job demo-active-deadline
```

**Expected output:**
```
NAME                   STATUS   COMPLETIONS   DURATION   AGE
demo-active-deadline   Failed   0/1           60s        60s
```

```bash
# Method 2: describe — header confirms field values; Events confirm the failure reason
kubectl describe job demo-active-deadline
```

**Expected output (key sections):**
```
Name:                     demo-active-deadline
Namespace:                lifetime-demo
...
...
Parallelism:              1
Completions:              1
Completion Mode:          NonIndexed
Suspend:                  false
Backoff Limit:            10                    ← 10 retries configured — none consumed
Start Time:               Fri, 27 Mar 2026 12:45:57 -0400
Active Deadline Seconds:  15s                   ← this is what fired
Pods Statuses:            0 Active (0 Ready) / 0 Succeeded / 1 Failed

Events:
  Type     Reason            Age   From            Message
  ----     ------            ----  ----            -------
  Normal   SuccessfulCreate  80s   job-controller  Created pod: demo-active-deadline-gtp55
  Normal   SuccessfulDelete  65s   job-controller  Deleted pod: demo-active-deadline-gtp55
  Warning  DeadlineExceeded  36s   job-controller  Job was active longer than specified deadline
```

> `Backoff Limit: 10` — 10 retries configured, none consumed. Deadline fired first.
> `Active Deadline Seconds: 15s` — the field that triggered termination.
> `SuccessfulDelete` — job-controller forcibly terminated the running Pod.
> `Warning DeadlineExceeded` — explicit named reason confirming why the Job failed.
> This `Warning` event is the **primary** place to read the failure reason.

```bash
# Method 3: jsonpath — extract reason(s) from the status conditions array
kubectl get job demo-active-deadline \
  -o jsonpath='{.status.conditions[0]}' | python3 -m json.tool 
```

**Expected output:**
```
{
    "lastProbeTime": "2026-03-27T16:46:12Z",
    "lastTransitionTime": "2026-03-27T16:46:12Z",
    "message": "Job was active longer than specified deadline",
    "reason": "DeadlineExceeded",                            <- DeadlineExceeded
    "status": "True",
    "type": "FailureTarget"
}
```

> Two `DeadlineExceeded` values because there are **two conditions** in the array:
> one for `FailureTarget` (intermediate) and one for `Failed` (final).
> Both carry `reason: DeadlineExceeded`. This is not a duplicate error —
> it reflects the two-phase Job failure lifecycle.

```bash
# Inspect one condition as structured JSON (use index [0] not [*]):
kubectl get job demo-active-deadline \
  -o jsonpath='{.status.conditions[0]}' | python3 -m json.tool
```

**Expected output:**
```json
{
    "lastProbeTime": "2026-03-27T16:46:12Z",
    "lastTransitionTime": "2026-03-27T16:46:12Z",
    "message": "Job was active longer than specified deadline",
    "reason": "DeadlineExceeded",
    "status": "True",
    "type": "FailureTarget"
}
```

> **Why `{.status.conditions[*]}` fails `python3 -m json.tool`:**
> `[*]` returns multiple objects concatenated without a separator — not valid JSON.
> Use `[0]` for the first condition or `[1]` for the final `Failed` condition.

`backoffLimit: 10` — 10 retries remained completely unused.
The 15s deadline fired first and discarded all remaining retries. ✅

**Cleanup:**
```bash
kubectl delete -f 01-active-deadline.yaml
```

---

### Step 3: backoffLimit vs activeDeadlineSeconds Race

Demonstrate which limit fires first depending on failure speed.

**02-backoff-vs-deadline.yaml:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: demo-backoff-race
  namespace: lifetime-demo
spec:
  activeDeadlineSeconds: 120      # 2-minute ceiling
  backoffLimit: 3                 # Only 3 retries
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: worker
          image: busybox
          command: ["sh", "-c", "echo 'Failing immediately'; exit 1"]
```

```bash
kubectl apply -f 02-backoff-vs-deadline.yaml

# Watch Pod restarts — CrashLoopBackOff between retries is normal
kubectl get pods -l job-name=demo-backoff-race -w
```

**Expected output:**
```
NAME                      READY   STATUS             RESTARTS     AGE
demo-backoff-race-bl9zt   0/1     CrashLoopBackOff   1 (5s ago)   5s
demo-backoff-race-bl9zt   0/1     Error              2 (16s ago)  16s
demo-backoff-race-bl9zt   0/1     CrashLoopBackOff   2 (13s ago)  29s
demo-backoff-race-bl9zt   0/1     Error              3 (25s ago)  41s
demo-backoff-race-bl9zt   0/1     Terminating        3 (26s ago)  42s
demo-backoff-race-bl9zt   0/1     Error              3            43s
```

> `CrashLoopBackOff` is the normal intermediate state between retries —
> Kubernetes applies exponential backoff delay before restarting the container.
> This is NOT an additional failure — it is the waiting state.
> `Terminating` means the job-controller deleted the Pod after `backoffLimit` was exhausted.

```bash
kubectl describe job demo-backoff-race
```

**Expected output (key sections):**
```
Backoff Limit:            3
Active Deadline Seconds:  120s
Pods Statuses:            0 Active (0 Ready) / 0 Succeeded / 1 Failed

Events:
  Type     Reason                Age   From            Message
  ----     ------                ----  ----            -------
  Normal   SuccessfulCreate      56s   job-controller  Created pod: demo-backoff-race-bl9zt
  Normal   SuccessfulDelete      14s   job-controller  Deleted pod: demo-backoff-race-bl9zt
  Warning  BackoffLimitExceeded  13s   job-controller  Job has reached the specified backoff limit
```

> `Warning BackoffLimitExceeded` fired at ~43s — well before the 120s deadline. ✅
> The failure reason is explicit in the Events `Warning` line.

**Confirm via jsonpath:**
```bash
kubectl get job demo-backoff-race \
  -o jsonpath='{.status.conditions[0]}' | python3 -m json.tool 
```

**Expected output:**
```
{
    "lastProbeTime": "2026-03-27T17:02:23Z",
    "lastTransitionTime": "2026-03-27T17:02:23Z",
    "message": "Job has reached the specified backoff limit",
    "reason": "BackoffLimitExceeded",                           <- BackoffLimitExceeded
    "status": "True",
    "type": "FailureTarget"
}
```

Fast-failing containers exhaust `backoffLimit` before `activeDeadlineSeconds`.
Slow-hanging containers hit `activeDeadlineSeconds` first. Always set both.

**Cleanup:**
```bash
kubectl delete -f 02-backoff-vs-deadline.yaml
```

---

### Step 4: terminationGracePeriodSeconds — Concept and Cross-Reference

> 💡 The full `preStop → SIGTERM → SIGKILL` demo — including log capture,
> shutdown sequence observation, and SIGKILL exit code (137) verification —
> is in:
>
> **[01-pod-lifecycle-termination-errors](../01-pod-lifecycle-termination-errors/), Step 7**
>
> `03-grace-period.yaml` in this demo's `src/` is retained as a reference YAML.
> The live demo steps for this field are not repeated here.

**Concept recap — what `terminationGracePeriodSeconds` controls:**

```
Pod deletion triggered
      │
      ▼
  Pod removed from Service endpoints (stops receiving traffic)
      │
      ▼
  preStop hook executes (if defined) — counts against grace period budget
      │
      ▼
  SIGTERM sent to all containers
      │
      ▼
  [terminationGracePeriodSeconds countdown begins]
      │
      ├── container exits cleanly → Pod terminates immediately (exit code 0)  ✅
      └── grace period expires   → SIGKILL sent              (exit code 137) ⚠️
```

**Key distinction from `activeDeadlineSeconds`:**

```
terminationGracePeriodSeconds → controls the shutdown WINDOW after deletion is triggered
                                 applies to EVERY Pod deletion — whether normal or
                                 triggered by activeDeadlineSeconds firing
                                 Pod spec field — applies to all Pod types

activeDeadlineSeconds         → controls total ACTIVE LIFETIME before deletion triggers
                                 Job and Pod spec field — does NOT apply to Deployments
```

> When `activeDeadlineSeconds` fires on a Job, each Pod is then terminated through
> the normal `terminationGracePeriodSeconds` shutdown sequence.
> They work **sequentially**: deadline fires first → triggers Pod deletion →
> grace period applies to that cleanup. They do not conflict.

---


### Step 5: CronJob — startingDeadlineSeconds and Per-Job activeDeadlineSeconds

> ⚠️ **Important — field that does NOT exist:**
> `spec.completionDeadlineSeconds` is **not a valid CronJob field**.
> Applying a CronJob YAML with that field produces:
> ```
> Error from server (BadRequest): CronJob in version "v1" cannot be handled
> as a CronJob: strict decoding error: unknown field "spec.completionDeadlineSeconds"
> ```
>
> **Correct fields to use:**
> - `spec.startingDeadlineSeconds` — at CronJob spec level — controls how late after
>   schedule a missed Job is still allowed to start
> - `spec.jobTemplate.spec.activeDeadlineSeconds` — at JobTemplate spec level —
>   controls how long each spawned Job is allowed to run

**04-cronjob-deadline.yaml:**
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: demo-cronjob-deadline
  namespace: lifetime-demo
spec:
  schedule: "*/1 * * * *"         # Every minute
  startingDeadlineSeconds: 30     # Skip if more than 30s late starting
  jobTemplate:
    spec:
      activeDeadlineSeconds: 20   # Each spawned Job must finish within 20s
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: worker
              image: busybox
              command: ["sh", "-c", "echo 'Running...'; sleep 60"]
```

```bash
kubectl apply -f 04-cronjob-deadline.yaml
```

**Verify CronJob spec — confirm startingDeadlineSeconds is set:**
```bash
kubectl describe cronjob demo-cronjob-deadline
```

**Expected output (key sections):**
```
Name:                          demo-cronjob-deadline
Schedule:                      */1 * * * *
Starting Deadline Seconds:     30s        ← startingDeadlineSeconds confirmed ✅
Concurrency Policy:            Allow
Suspend:                       false
Successful Job History Limit:  3
Failed Job History Limit:      1
```

> Note: `Active Deadline Seconds` does NOT appear at the CronJob describe level.
> It is set inside `jobTemplate.spec` and will appear in the spawned Job's describe output.

Wait for the first Job to be spawned (up to 1 minute):
```bash
kubectl get jobs -w
```

**Expected output:**
```
NAME                               COMPLETIONS   DURATION   AGE
demo-cronjob-deadline-<hash>       0/1           0s         0s
demo-cronjob-deadline-<hash>       0/1           20s        20s
```

Check the spawned Job to confirm `activeDeadlineSeconds` is inherited
from the jobTemplate:
```bash
JOB=$(kubectl get jobs -n lifetime-demo \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')

kubectl describe job $JOB
```

**Expected output (key sections):**
```
Active Deadline Seconds:  20s      ← inherited from jobTemplate.spec ✅

Events:
  Type    Reason            Age   From            Message
  ----    ------            ----  ----            -------
  Normal  SuccessfulCreate  22s   job-controller  Created pod: demo-cronjob-deadline-<hash>-<id>
  Normal  SuccessfulDelete  2s    job-controller  Deleted pod: demo-cronjob-deadline-<hash>-<id>
```

**Confirm DeadlineExceeded via jsonpath:**
```bash
kubectl get job $JOB \
  -o jsonpath='{.status.conditions[*].reason}' && echo
```

**Expected output:**
```
DeadlineExceeded
```

**Field summary — two levels on a CronJob:**
```
spec.startingDeadlineSeconds             → CronJob level
  "how late can this Job start after schedule"
  → 30s: if CronJob controller misses the schedule,
         it still starts the Job if delay is ≤ 30 seconds

spec.jobTemplate.spec.activeDeadlineSeconds  → JobTemplate level (inherited by each Job)
  "how long can each spawned Job actually run"
  → 20s: every spawned Job is killed at 20s regardless of progress
```

**Cleanup:**
```bash
kubectl delete -f 04-cronjob-deadline.yaml
kubectl delete jobs --all -n lifetime-demo
```

---

### Step 6: podFailurePolicy — Ignore Evictions, Fail Fast on Bad Exit Code

Configure the Job to ignore transient node evictions (don't penalise
retries) but fail immediately on a known fatal exit code.

**05-pod-failure-policy.yaml:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: demo-failure-policy
  namespace: lifetime-demo
spec:
  backoffLimit: 6
  podFailurePolicy:
    rules:
      - action: Ignore
        onPodConditions:
          - type: DisruptionTarget   # Node evictions — do not count against backoffLimit
      - action: FailJob
        onExitCodes:
          containerName: worker
          operator: In
          values: [42]              # Exit code 42 = fatal config error — fail immediately
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: worker
          image: busybox
          command: ["sh", "-c", "echo 'Fatal config error'; exit 42"]
```

```bash
kubectl apply -f 05-pod-failure-policy.yaml

# Watch Pod — it should fail immediately without retrying
kubectl get pods -l job-name=demo-failure-policy -w
```

**Expected output:**
```
NAME                        READY   STATUS   RESTARTS   AGE
demo-failure-policy-dld74   0/1     Error    0          8s
```

Only one Pod attempt — no retries despite `backoffLimit: 6`. ✅

```bash
kubectl describe job demo-failure-policy
```

**Expected output (key sections):**
```
Backoff Limit:    6
Pods Statuses:    0 Active (0 Ready) / 0 Succeeded / 1 Failed

Events:
  Type     Reason            Age   From            Message
  ----     ------            ----  ----            -------
  Normal   SuccessfulCreate  28s   job-controller  Created pod: demo-failure-policy-dld74
  Warning  PodFailurePolicy  24s   job-controller  Container worker for pod lifetime-demo/demo-failure-policy-dld74 failed with exit code 42 matching FailJob rule at index 1
```

> `Warning PodFailurePolicy` is the failure evidence — note the full detail:
> which container, which Pod namespace/name, which exit code, which rule index matched.
> `Backoff Limit: 6` in the header — it was never consumed.
> No `Warning BackoffLimitExceeded` event — confirms retries were not involved. ✅

Exit code 42 triggered `FailJob` immediately. If a `DisruptionTarget` eviction
had occurred instead, the `Ignore` rule would have fired — the failure would not
count against `backoffLimit` and the Job would retry normally. ✅

**Cleanup:**
```bash
kubectl delete -f 05-pod-failure-policy.yaml
```

---

### Step 7: Final Cleanup

```bash
kubectl config set-context --current --namespace=default
kubectl delete namespace lifetime-demo
kubectl get jobs,pods -n default
```

**Expected output:**
```
Context "3node" modified.
namespace "lifetime-demo" deleted
NAME                 READY   STATUS    RESTARTS   AGE
pod/load-generator   1/1     Running   0          18h
```

---

## Common Questions

### Q: Does the activeDeadlineSeconds timer start at Pod creation or when the container starts?

**A:** Neither — it starts when the **Job's `status.startTime` is set** by the
job-controller. This happens when the first Pod is admitted and scheduled
(Pod condition `PodScheduled = True`). For a bare Pod it starts when
`status.phase = Running`. Scheduling delays, image pulls, and node selection
do NOT eat into the deadline.

### Q: Where do I see the failure reason — Conditions or Events?

**A:** Use **all three methods** depending on what is available:
- `kubectl get job <n> -o jsonpath='{.status.conditions[*].reason}'`
  → returns `DeadlineExceeded` / `BackoffLimitExceeded` / etc. directly
- `kubectl describe job <n>` → **Events section** always has `Warning` lines
  with the reason: `DeadlineExceeded`, `BackoffLimitExceeded`, `PodFailurePolicy`
- `kubectl describe job <n>` → **header section** shows `Backoff Limit:` and
  `Active Deadline Seconds:` so you can verify which fields were set

### Q: If both backoffLimit and activeDeadlineSeconds are set, which wins?

**A:** Whichever fires first. For fast-failing containers, `backoffLimit`
typically fires first. For hanging/stuck workloads, `activeDeadlineSeconds`
fires first. The Events `Warning` line in `kubectl describe job` confirms which fired.

### Q: Why is there no completionDeadlineSeconds on CronJob?

**A:** That field does not exist in the Kubernetes API — applying it causes a
`BadRequest` strict decoding error. To cap how long each spawned Job runs, use
`spec.jobTemplate.spec.activeDeadlineSeconds`. To control how late after the
schedule a missed Job is still allowed to start, use `spec.startingDeadlineSeconds`
at the CronJob level. These are two different concerns at two different spec levels.

### Q: What is CrashLoopBackOff — is it a separate failure?

**A:** It depends on `restartPolicy`:
- With `restartPolicy: OnFailure` — `CrashLoopBackOff` is the **normal waiting
  state** between retries. Kubernetes holds back before restarting the same
  container in-place using exponential backoff. It does NOT consume an extra retry
  count. Sequence: `Error → CrashLoopBackOff (waiting) → Error → ...`
  until `backoffLimit` is exhausted.
- With `restartPolicy: Never` — `CrashLoopBackOff` does **not appear**. The
  job-controller creates a brand new Pod for each retry. Old failed Pods remain
  visible with `STATUS: Error`. You see a different Pod name each attempt.

### Q: Does a bare Pod have backoffLimit?

**A:** No — `backoffLimit` is a **Job-only** field. A bare Pod has no retry budget.
Instead, a Pod's restart behaviour is controlled by `spec.restartPolicy`:
`Always` (Deployments default), `OnFailure`, or `Never`. There is no count-based
limit on Pod restarts — a Pod with `restartPolicy: Always` will restart indefinitely
unless the node fails or the Pod is deleted. To apply a retry limit, wrap the
workload in a Job.

### Q: Does podFailurePolicy require any feature gate to enable?

**A:** `podFailurePolicy` graduated to GA in Kubernetes v1.31 — no feature
gate required on v1.31+. On v1.26–v1.30 it required the `JobPodFailurePolicy`
feature gate (enabled by default from v1.28).

---

## What You Learned

In this lab, you:
- ✅ Observed `activeDeadlineSeconds` terminate a Job — confirmed via `STATUS: Failed`,
  Events `SuccessfulDelete`, and jsonpath `DeadlineExceeded`
- ✅ Read `kubectl describe job` header for `Backoff Limit:` and `Active Deadline Seconds:`
  and Events section for `Warning` failure lines
- ✅ Observed `backoffLimit` fire via `Warning BackoffLimitExceeded` Event before the deadline
- ✅ Confirmed `CrashLoopBackOff` is the normal backoff wait between retries — not a separate error
- ✅ Understood `terminationGracePeriodSeconds` concept and its distinction from `activeDeadlineSeconds` — full shutdown demo in [01-pod-lifecycle-termination-errors](../01-pod-lifecycle-termination-errors/) Step 7
- ✅ Observed `FailureTarget` intermediate Job status and understood it as the cleanup window before `Failed` settles
- ✅ Confirmed `completionDeadlineSeconds` is not a valid CronJob field — corrected to
  `spec.jobTemplate.spec.activeDeadlineSeconds` and `spec.startingDeadlineSeconds`
- ✅ Used `podFailurePolicy` to fail a Job immediately on exit code 42 — confirmed
  via `Warning PodFailurePolicy` event with full container/exit code details

**Key Takeaway:** Lifetime controls are the safety net for batch workloads in
shared clusters. `activeDeadlineSeconds` caps elapsed time. `backoffLimit` caps
attempts. `terminationGracePeriodSeconds` ensures clean shutdown. All three should
be explicitly set on every Job and CronJob — never rely on defaults in production,
especially in namespaces governed by ResourceQuota where stuck workloads silently
exhaust shared quota. For CronJobs, remember the two-level distinction:
`startingDeadlineSeconds` at CronJob spec level controls schedule lateness;
`jobTemplate.spec.activeDeadlineSeconds` controls per-Job runtime.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get job <n>` | Show STATUS column — Running / Failed / Complete |
| `kubectl describe job <n>` | Header: Backoff Limit + Active Deadline Seconds; Events: failure Warning |
| `kubectl get job <n> -o jsonpath='{.status.conditions[*].reason}'` | Extract failure reason directly |
| `kubectl get jobs -w` | Watch Job status changes in real time |
| `kubectl get pods -l job-name=<n> -w` | Watch Pods for a specific Job — shows CrashLoopBackOff between retries |
| `kubectl delete pod <n> --grace-period=0 --force` | Force delete — bypass grace period |
| `kubectl explain job.spec.activeDeadlineSeconds` | Browse field docs inline |
| `kubectl explain job.spec.podFailurePolicy` | Browse podFailurePolicy field docs |
| `kubectl explain cronjob.spec.startingDeadlineSeconds` | Browse CronJob schedule deadline docs |
| `kubectl explain cronjob.spec.jobTemplate.spec.activeDeadlineSeconds` | Browse per-Job runtime cap docs |

---

## CKA Certification Tips

✅ **How to read failure reason — three methods:**
```bash
# Method 1 — STATUS column (confirms failure, not the reason)
kubectl get job <n>
# STATUS: Failed

# Method 2 — Events in describe (always present, most detailed)
kubectl describe job <n>
# Warning  DeadlineExceeded      → activeDeadlineSeconds fired
# Warning  BackoffLimitExceeded  → backoffLimit exhausted
# Warning  PodFailurePolicy      → FailJob rule matched

# Method 3 — jsonpath on .status.conditions (precise, scriptable)
kubectl get job <n> -o jsonpath='{.status.conditions[*].reason}' && echo
# → DeadlineExceeded | BackoffLimitExceeded
```

✅ **Failure reason vocabulary — know these exactly:**
```
DeadlineExceeded        → activeDeadlineSeconds fired
BackoffLimitExceeded    → backoffLimit exhausted
PodFailurePolicy        → podFailurePolicy FailJob rule matched
```

✅ **Job status transitions for DeadlineExceeded — two-phase:**
```
FailureTarget  → intermediate: deadline fired, Pod cleanup in progress
                  .status.conditions[0].type = FailureTarget
                  .status.conditions[0].reason = DeadlineExceeded

Failed         → final: all Pods gone, Job settled
                  .status.conditions[1].type = Failed
                  .status.conditions[1].reason = DeadlineExceeded

jsonpath returns both:
  kubectl get job <n> -o jsonpath='{.status.conditions[*].reason}' && echo
  → DeadlineExceeded DeadlineExceeded   (one per condition — normal)

Use [0] or [1] index to inspect a single condition as JSON:
  kubectl get job <n> -o jsonpath='{.status.conditions[0]}' | python3 -m json.tool
  (using [*] returns concatenated objects — not valid JSON for python3 -m json.tool)
```

✅ **Field precedence — memorise:**
```
activeDeadlineSeconds fires   → always wins, overrides backoffLimit
podFailurePolicy FailJob      → wins over backoffLimit, immediate failure
backoffLimit exhausted        → wins only if deadline has not fired
```

✅ **Default values:**
```
activeDeadlineSeconds             → nil (unlimited — no deadline)
backoffLimit                      → 6
terminationGracePeriodSeconds     → 30 seconds
startingDeadlineSeconds           → nil (no schedule miss limit)
```

✅ **Which fields apply where — exact spec level:**
```
Job spec level:
  spec.activeDeadlineSeconds                          → Job runtime cap
  spec.backoffLimit                                   → retry budget
  spec.podFailurePolicy                               → exit code / eviction rules (v1.26+)
  spec.backoffLimitPerIndex                           → per-index budget, Indexed Jobs (v1.29+)

Pod spec level (inside Job template or standalone Pod):
  spec.terminationGracePeriodSeconds                  → SIGTERM to SIGKILL window

CronJob spec level:
  spec.startingDeadlineSeconds                        → schedule miss tolerance
  spec.jobTemplate.spec.activeDeadlineSeconds         → per-Job runtime cap
```

✅ **completionDeadlineSeconds does NOT exist on CronJob:**
```
❌ spec.completionDeadlineSeconds                     → unknown field — BadRequest error
✅ spec.jobTemplate.spec.activeDeadlineSeconds        → correct field for per-Job runtime cap
✅ spec.startingDeadlineSeconds                       → correct field for schedule miss tolerance
```

✅ **CrashLoopBackOff — only with restartPolicy: OnFailure:**
```
restartPolicy: OnFailure → same Pod restarts in-place
  Error → CrashLoopBackOff (waiting) → Error → ... → Warning BackoffLimitExceeded

restartPolicy: Never → new Pod created for each retry, no CrashLoopBackOff
  Error (Pod A) → Error (Pod B) → Error (Pod C) → ... → Warning BackoffLimitExceeded
```

✅ **backoffLimit is Job-only — bare Pods have no retry budget:**
```
Job  → spec.backoffLimit controls retry attempts (default 6)
Pod  → spec.restartPolicy controls restarts (Always / OnFailure / Never)
       no count-based limit — restarts indefinitely with Always or OnFailure
```

✅ **Timer starts at Job status.startTime — not object creation:**
```
Pod condition PodScheduled = True triggers the timer
Scheduling delays, image pulls do NOT consume the activeDeadlineSeconds budget
```

✅ **Exit code 137 = SIGKILL = grace period expired:**
```
137 = 128 + signal 9
Container did not exit within terminationGracePeriodSeconds → force killed
```

✅ **ResourceQuota scope connection (from Demo 07):**
```
Terminating scope    → matches Pods where spec.activeDeadlineSeconds >= 0
NotTerminating scope → matches Pods where spec.activeDeadlineSeconds is nil
```

---

## Troubleshooting

**Job stuck — never terminates:**
```bash
kubectl describe job <n>
# Check header: is "Active Deadline Seconds" present?
kubectl get job <n> -o jsonpath='{.spec.activeDeadlineSeconds}' && echo
# Empty output = nil — no deadline set. Add activeDeadlineSeconds to cap it.
```

**Job failed — need to know why:**
```bash
# Step 1 — check Events for Warning lines
kubectl describe job <n>
# Step 2 — extract reason from status conditions
kubectl get job <n> -o jsonpath='{.status.conditions[*].reason}' && echo
# Step 3 — check exit code of the failed Pod
kubectl get pods -l job-name=<n> \
  -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}' && echo
```

**Pod killed before completing graceful shutdown (exit code 137):**
```bash
kubectl describe pod <n>
# Last State — Terminated — Exit Code: 137 confirms SIGKILL
kubectl get pod <n> -o jsonpath='{.spec.terminationGracePeriodSeconds}' && echo
# Fix: increase terminationGracePeriodSeconds to cover actual shutdown time
```

**Job fails immediately despite backoffLimit > 0:**
```bash
kubectl describe job <n>
# Look in Events for: Warning PodFailurePolicy
# If present → a FailJob rule matched
kubectl get pods -l job-name=<n> \
  -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}' && echo
# Confirm which exit code triggered the rule
```

**CronJob spawned Jobs are not being killed after expected runtime:**
```bash
# activeDeadlineSeconds does NOT appear in kubectl describe cronjob
# Check it in the jobTemplate:
kubectl get cronjob <n> \
  -o jsonpath='{.spec.jobTemplate.spec.activeDeadlineSeconds}' && echo
# Empty output = nil — no per-Job runtime cap.
# Add activeDeadlineSeconds under spec.jobTemplate.spec in your CronJob YAML.
```

**CronJob stops creating new Jobs after long suspension:**
```bash
kubectl describe cronjob <n>
# Look for events: "too many missed start times"
kubectl get cronjob <n> \
  -o jsonpath='{.spec.startingDeadlineSeconds}' && echo
# If empty = nil: controller counts all missed schedules from last run to now.
# If > 100 missed: CronJob stops. Set startingDeadlineSeconds to bound the window.
```
