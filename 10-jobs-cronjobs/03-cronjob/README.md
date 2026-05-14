# CronJob — Scheduled Batch Workloads

## Lab Overview

This lab introduces CronJobs — Kubernetes's mechanism for running Jobs on a
schedule. A CronJob is a controller that creates a new Job object at each
scheduled interval. The Job then creates pods and runs them to completion,
exactly as in Labs 01 and 02.

CronJobs are the right workload for: nightly database backups, hourly report
generation, periodic data cleanup, health-check tasks, and any work that
must run on a defined schedule.

**What you'll do:**
- Understand the CronJob controller and its relationship to Jobs
- Walk through every field in the CronJob manifest
- Deploy a CronJob and watch scheduled Jobs be created
- Manually trigger a Job from a CronJob outside the schedule
- Suspend and resume a CronJob
- Understand `concurrencyPolicy` — what happens when a Job is still running
  when the next scheduled run fires
- Understand `startingDeadlineSeconds` — missed schedule tolerance

## Prerequisites

**Required Software:**
- Minikube `3node` profile
- kubectl installed and configured

**Knowledge Requirements:**
- **REQUIRED:** Completion of `01-basic-job`
- **RECOMMENDED:** Completion of `02-job-patterns`

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain the CronJob controller — creates a Job per schedule tick
2. ✅ Read and write cron schedule expressions correctly
3. ✅ Explain every field in the CronJob manifest and its valid values
4. ✅ Watch scheduled Jobs being created and completing automatically
5. ✅ Manually trigger a Job from a CronJob with `kubectl create job --from`
6. ✅ Explain `concurrencyPolicy` Allow, Forbid, and Replace — and choose correctly
7. ✅ Explain `startingDeadlineSeconds` — the missed-schedule tolerance window
8. ✅ Suspend a CronJob to pause scheduling and resume it
9. ✅ Understand `successfulJobsHistoryLimit` and `failedJobsHistoryLimit`

## Directory Structure

```
03-cronjob/
└── src/
    ├── basic-cronjob.yaml        # CronJob running every minute
    └── concurrent-cronjob.yaml   # CronJob with slow tasks — demonstrates concurrencyPolicy
```

---

## Understanding CronJobs

### CronJob → Job → Pod Relationship

```
CronJob (schedule: "*/1 * * * *")
  │
  ├── At :00 → creates Job "hello-28123456"
  │               └── creates Pod "hello-28123456-xxxxx"
  │                     └── runs to Completed
  │
  ├── At :01 → creates Job "hello-28123457"
  │               └── creates Pod "hello-28123457-xxxxx"
  │                     └── runs to Completed
  │
  └── At :02 → creates Job "hello-28123458" ...

CronJob is the scheduler. Job is the unit of work. Pod is the executor.
Deleting the CronJob does NOT delete existing Jobs or pods.
```

### Cron Schedule Syntax

```
┌───────────── minute        (0 - 59)
│ ┌─────────── hour          (0 - 23)
│ │ ┌───────── day of month  (1 - 31)
│ │ │ ┌─────── month         (1 - 12)
│ │ │ │ ┌───── day of week   (0 - 6, Sunday=0)
│ │ │ │ │
* * * * *

Common examples:
  */1 * * * *        every minute
  0 * * * *          every hour (at :00)
  0 0 * * *          every day at midnight
  0 2 * * *          every day at 02:00
  0 0 * * 0          every Sunday at midnight
  0 9 * * 1-5        weekdays at 09:00
  */15 * * * *       every 15 minutes
  0 0 1 * *          first day of every month

Special strings (supported by Kubernetes):
  @yearly    = 0 0 1 1 *     once a year, Jan 1
  @monthly   = 0 0 1 * *     once a month, 1st at midnight
  @weekly    = 0 0 * * 0     once a week, Sunday midnight
  @daily     = 0 0 * * *     once a day at midnight
  @hourly    = 0 * * * *     once an hour at :00
```

### concurrencyPolicy — What Happens at the Next Tick

```
Scenario: CronJob runs every minute. A Job takes 90 seconds.
At minute 2, the minute-1 Job is still running.
What should happen?

concurrencyPolicy: Allow (default)
  → Create the minute-2 Job regardless.
  → Both Jobs run simultaneously.
  → Use when: jobs are independent and overlap is acceptable.
  → Risk: if jobs keep running long, many pile up.

concurrencyPolicy: Forbid
  → Skip the minute-2 run entirely.
  → The minute-1 Job continues undisturbed.
  → Use when: parallel runs cause problems (e.g. two DB backups at once).
  → Note: skipped runs count toward startingDeadlineSeconds.

concurrencyPolicy: Replace
  → Terminate the minute-1 Job (and its pods).
  → Create the minute-2 Job.
  → At any time only ONE Job is running.
  → Use when: only the latest run matters, old runs are stale.
  → Example: a "refresh cache" job where stale runs waste resources.
```

### startingDeadlineSeconds

```
If the CronJob controller misses a scheduled run (e.g. controller was down),
it will try to catch up — but only within the startingDeadlineSeconds window.

startingDeadlineSeconds: nil (default)
  → Catch up on ALL missed runs.
  → Risk: after a long outage, hundreds of Jobs created at once.

startingDeadlineSeconds: 60
  → Only catch up on missed runs within the last 60 seconds.
  → Missed runs older than 60s are skipped.
  → Recommended for production: set to a reasonable value like 200.

Important: if more than 100 schedules are missed within the deadline window,
the CronJob controller marks it as failed and stops scheduling.
Always set startingDeadlineSeconds to avoid this.
```

### Job History Limits

```
successfulJobsHistoryLimit: 3  (default)
  → Keep only the 3 most recent successful Jobs.
  → Older successful Jobs are deleted automatically.

failedJobsHistoryLimit: 1  (default)
  → Keep only the most recent failed Job.

Setting both to 0: no history kept — Jobs deleted immediately after completion.
Setting both to nil: unlimited history — Jobs accumulate forever (not recommended).

Production guidance:
  successfulJobsHistoryLimit: 3    # enough for recent log review
  failedJobsHistoryLimit: 3        # keep a few for debugging
```

---

## CronJob Manifest — Every Field Explained

### basic-cronjob.yaml

**basic-cronjob.yaml:**
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hello
  namespace: default
  labels:
    app: hello
spec:

  # ── Schedule ─────────────────────────────────────────────────────────
  schedule: "*/1 * * * *"
  # Cron expression defining when to create a new Job.
  # "*/1 * * * *" = every minute (use "*/2 * * * *" for every 2 minutes)
  # Uses UTC timezone by default.
  # timeZone field (Kubernetes 1.27+): set explicit timezone
  #   timeZone: "America/New_York"
  #   timeZone: "Asia/Kolkata"
  #   timeZone: "Europe/London"

  # ── Concurrency control ───────────────────────────────────────────────
  concurrencyPolicy: Allow
  # Allow:   create new Job even if previous is still running (default)
  # Forbid:  skip new Job if previous is still running
  # Replace: terminate previous Job, create new one

  # ── Missed schedule tolerance ─────────────────────────────────────────
  startingDeadlineSeconds: 200
  # If a scheduled run is missed, catch up only if within this many seconds.
  # Prevents a burst of Jobs after a controller restart or outage.
  # nil = catch up on all missed runs (dangerous after long outage).
  # Recommended: set to a reasonable value (100-300 for minute-level schedules).

  # ── History limits ────────────────────────────────────────────────────
  successfulJobsHistoryLimit: 3   # Keep last 3 successful Jobs for log review
  failedJobsHistoryLimit: 3       # Keep last 3 failed Jobs for debugging

  # ── Suspend ───────────────────────────────────────────────────────────
  suspend: false
  # true:  pause scheduling — no new Jobs created
  # false: scheduling active (default)
  # Existing running Jobs are NOT affected by suspend.
  # Use for: planned maintenance, temporary pause, disable without deleting

  # ── Job Template ─────────────────────────────────────────────────────
  # jobTemplate wraps a full Job spec — everything from Lab 01 applies here.
  jobTemplate:
    spec:
      backoffLimit: 2
      # ttlSecondsAfterFinished on the Job template:
      # Each spawned Job auto-deletes 120s after completion.
      # This is separate from successfulJobsHistoryLimit which limits Job count.
      ttlSecondsAfterFinished: 120
      template:
        metadata:
          labels:
            app: hello
        spec:
          restartPolicy: OnFailure
          containers:
            - name: hello
              image: busybox:1.36
              command:
                - sh
                - -c
                - |
                  echo "CronJob fired at: $(date)"
                  echo "Job name: $JOB_NAME"
                  echo "Task complete"
              env:
                - name: JOB_NAME
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.name
              resources:
                requests:
                  cpu: "50m"
                  memory: "32Mi"
                limits:
                  cpu: "100m"
                  memory: "64Mi"
```

**Field reference table:**

| Field | Default | Meaning |
|-------|---------|---------|
| `schedule` | — | Cron expression (required) |
| `concurrencyPolicy` | `Allow` | Behaviour when previous Job still running |
| `startingDeadlineSeconds` | nil | Missed-schedule catchup window in seconds |
| `successfulJobsHistoryLimit` | 3 | Successful Jobs to retain |
| `failedJobsHistoryLimit` | 1 | Failed Jobs to retain |
| `suspend` | false | Pause scheduling without deleting CronJob |
| `timeZone` | UTC | Timezone for schedule interpretation (k8s 1.27+) |

### concurrent-cronjob.yaml

**concurrent-cronjob.yaml:**
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: slow-task
  namespace: default
  labels:
    app: slow-task
spec:
  schedule: "*/1 * * * *"   # Every minute
  # Each Job takes 90 seconds — longer than the 60s schedule interval.
  # With concurrencyPolicy: Forbid, the overlapping run is skipped.
  # With concurrencyPolicy: Replace, the running Job is terminated.
  # With concurrencyPolicy: Allow (default), both Jobs run simultaneously.
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 200
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      ttlSecondsAfterFinished: 120
      template:
        metadata:
          labels:
            app: slow-task
        spec:
          restartPolicy: Never
          containers:
            - name: slow-task
              image: busybox:1.36
              command:
                - sh
                - -c
                - |
                  echo "Slow task started at $(date)"
                  sleep 90          # Takes 90s — longer than 60s schedule interval
                  echo "Slow task done at $(date)"
              resources:
                requests:
                  cpu: "50m"
                  memory: "32Mi"
                limits:
                  cpu: "100m"
                  memory: "64Mi"
```

---

## Lab Step-by-Step Guide

### Step 1: Deploy the CronJob

```bash
cd 03-cronjob/src
kubectl apply -f basic-cronjob.yaml
```

```bash
kubectl get cronjob hello
```

**Expected output:**
```
NAME    SCHEDULE      SUSPEND   ACTIVE   LAST SCHEDULE   AGE
hello   */1 * * * *   False     0        <none>          5s
```

**Columns explained:**

| Column | Meaning |
|--------|---------|
| `SCHEDULE` | Cron expression |
| `SUSPEND` | False = actively scheduling, True = paused |
| `ACTIVE` | Number of currently running Jobs |
| `LAST SCHEDULE` | When the most recent Job was created |

---

### Step 2: Watch Scheduled Jobs Being Created

```bash
# Terminal 1 — watch Jobs appear each minute
kubectl get jobs -w

# Terminal 2 — watch pods
kubectl get pods -w
```

**Terminal 1 — Jobs created at each minute boundary:**
```
NAME               COMPLETIONS   DURATION   AGE
hello-28123456     0/1           3s         3s    ← created at :00
hello-28123456     1/1           8s         8s    ← completed ✅
hello-28123457     0/1           3s         63s   ← created at :01
hello-28123457     1/1           8s         68s   ← completed ✅
hello-28123458     0/1           3s         123s  ← created at :02
```

**Job naming convention:** `<cronjob-name>-<unix-timestamp-in-minutes>`
The timestamp suffix makes each Job name unique and traceable to its
scheduled time.

```bash
# Show the CronJob updated state
kubectl get cronjob hello
# LAST SCHEDULE now shows the time of the most recent run
# ACTIVE shows 0 between runs, 1 during a run
```

---

### Step 3: Read the CronJob Status and History

```bash
kubectl describe cronjob hello
```

**Key sections:**
```
Schedule:                */1 * * * *
Concurrency Policy:      Allow
Suspend:                 False
Successful Job History:  3
Failed Job History:      3
Starting Deadline:       200s

Active Jobs:             <none>

Events:
  Normal  SuccessfulCreate  Created job hello-28123456
  Normal  SawCompletedJob   Saw completed job: hello-28123456
  Normal  SuccessfulCreate  Created job hello-28123457
  Normal  SawCompletedJob   Saw completed job: hello-28123457
```

```bash
# List all Jobs created by this CronJob
kubectl get jobs -l app=hello
```

**Expected (after a few minutes):**
```
NAME             COMPLETIONS   DURATION   AGE
hello-28123456   1/1           8s         3m
hello-28123457   1/1           8s         2m
hello-28123458   1/1           8s         1m
```

Only the 3 most recent are shown — older ones deleted by `successfulJobsHistoryLimit: 3`.

---

### Step 4: Read Logs from a Scheduled Run

```bash
# Get the most recent Job name
LATEST_JOB=$(kubectl get jobs -l app=hello --sort-by=.metadata.creationTimestamp   -o jsonpath='{.items[-1].metadata.name}')

kubectl logs -l job-name=$LATEST_JOB
```

**Expected:**
```
CronJob fired at: Mon Jan 15 09:43:00 UTC 2024
Job name: hello-28123458
Task complete
```

---

### Step 5: Manually Trigger a Job Outside the Schedule

`kubectl create job --from=cronjob/<name>` creates a Job using the CronJob's
`jobTemplate` immediately, regardless of the schedule. Useful for:
- Testing that the job works before the next scheduled run
- Running an on-demand backfill
- Debugging the job logic

```bash
kubectl create job --from=cronjob/hello manual-run-001
```

**Expected output:**
```
job.batch/manual-run-001 created
```

```bash
kubectl get job manual-run-001
# NAME              COMPLETIONS   DURATION
# manual-run-001    1/1           8s       ← ran immediately

kubectl logs -l job-name=manual-run-001
# CronJob fired at: Mon Jan 15 09:44:35 UTC 2024
# Job name: manual-run-001
# Task complete
```

The manually created Job uses the exact same template as scheduled runs.
It is NOT tracked by the CronJob's history limits — it is an independent Job.

```bash
kubectl delete job manual-run-001
```

---

### Step 6: Suspend and Resume the CronJob

```bash
# Suspend — stop creating new Jobs
kubectl patch cronjob hello -p '{"spec":{"suspend":true}}'

kubectl get cronjob hello
# SUSPEND: True — no new Jobs will be created
```

Wait 2-3 minutes and verify no new Jobs appear:
```bash
kubectl get jobs -l app=hello
# Same jobs as before — no new ones created while suspended
```

```bash
# Resume
kubectl patch cronjob hello -p '{"spec":{"suspend":false}}'

kubectl get cronjob hello
# SUSPEND: False — scheduling resumes at the next interval
```

---

### Step 7: Demonstrate concurrencyPolicy with Slow Tasks

Deploy the slow task CronJob (90s task, 60s schedule interval):

```bash
kubectl apply -f concurrent-cronjob.yaml
```

**Watch for 2+ minutes:**
```bash
kubectl get jobs -l app=slow-task -w
```

**Expected with `concurrencyPolicy: Forbid`:**
```
NAME              COMPLETIONS   DURATION   AGE
slow-task-aaaaa   0/1           30s        30s   ← minute 1 Job running

# At the 1-minute mark, a new run would be scheduled
# but the previous Job is still running — it is SKIPPED

slow-task-aaaaa   1/1           90s        90s   ← minute 1 Job finally completes

slow-task-bbbbb   0/1           3s         93s   ← minute 2 Job starts now
```

```bash
kubectl describe cronjob slow-task | grep -A3 Events
```

**Expected events:**
```
Normal  SuccessfulCreate  Created job slow-task-aaaaa
Normal  JobAlreadyActive  Not starting job because prior execution is still running
Normal  SuccessfulCreate  Created job slow-task-bbbbb
```

`JobAlreadyActive` — the skipped run is recorded in Events for observability.

**Change to `Replace` and observe:**
```bash
kubectl patch cronjob slow-task   -p '{"spec":{"concurrencyPolicy":"Replace"}}'
```

At the next minute boundary: the running Job is terminated and a new one starts.

**Change to `Allow` and observe:**
```bash
kubectl patch cronjob slow-task   -p '{"spec":{"concurrencyPolicy":"Allow"}}'
```

After 2 minutes: two Jobs running simultaneously.

---

### Step 8: Cleanup

```bash
kubectl delete cronjob hello slow-task

# Jobs created by the CronJob remain after CronJob deletion
# Delete them explicitly:
kubectl delete jobs -l app=hello
kubectl delete jobs -l app=slow-task
```

---

## Common Questions

### Q: What timezone does the schedule use?
**A:** UTC by default. Use the `timeZone` field (Kubernetes 1.27+) to specify
a timezone:
```yaml
spec:
  schedule: "0 9 * * 1-5"    # 09:00 weekdays
  timeZone: "America/New_York"
```

Supported values follow the IANA timezone database (e.g. `Asia/Kolkata`,
`Europe/London`). Without `timeZone`, all cron times are UTC.

### Q: What happens to running Jobs when I delete the CronJob?
**A:** Running Jobs and their pods continue to completion — deleting the
CronJob only stops future scheduling. To also delete existing Jobs:
```bash
kubectl delete cronjob hello --cascade=foreground
# or:
kubectl delete cronjob hello
kubectl delete jobs -l app=hello
```

### Q: How do I see the next scheduled run time?
**A:** The CronJob status includes `nextScheduleTime`:
```bash
kubectl get cronjob hello -o jsonpath='{.status.nextScheduleTime}'
# 2024-01-15T09:45:00Z
```

### Q: Can a CronJob create multiple Jobs at once?
**A:** Only if `concurrencyPolicy: Allow` is set and the previous run is
still active. Each schedule tick creates at most one new Job (unless
startingDeadlineSeconds allows catch-up of multiple missed runs).

### Q: How do I disable a CronJob without deleting it?
**A:** `kubectl patch cronjob <n> -p '{"spec":{"suspend":true}}'`
This preserves the CronJob definition and history for later resumption.

---

## What You Learned

In this lab, you:
- ✅ Explained the CronJob → Job → Pod relationship
- ✅ Read and wrote cron schedule expressions
- ✅ Explained every CronJob manifest field with valid values
- ✅ Watched scheduled Jobs created automatically at each minute boundary
- ✅ Manually triggered a Job with `kubectl create job --from=cronjob/<n>`
- ✅ Suspended and resumed a CronJob with the `suspend` field
- ✅ Demonstrated `concurrencyPolicy: Forbid` — skipped run when Job already active
- ✅ Explained `startingDeadlineSeconds` — missed-schedule safety window
- ✅ Explained `successfulJobsHistoryLimit` and `failedJobsHistoryLimit`

**Key Takeaway:** A CronJob is just a scheduler that creates Jobs. Everything
you know about Jobs applies inside the `jobTemplate`. `concurrencyPolicy` is
the most important production decision — choose `Forbid` for jobs that must
not overlap (backups, migrations), `Allow` for independent parallel runs, and
`Replace` when only the latest run has value. Always set
`startingDeadlineSeconds` to prevent a burst of catch-up Jobs after an outage.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get cronjobs` | List CronJobs — SCHEDULE, SUSPEND, ACTIVE, LAST SCHEDULE |
| `kubectl describe cronjob <n>` | Full detail — policy, history, events |
| `kubectl get jobs -l app=<n>` | Jobs spawned by this CronJob |
| `kubectl create job --from=cronjob/<n> <job-name>` | Manual trigger |
| `kubectl patch cronjob <n> -p '{"spec":{"suspend":true}}'` | Suspend |
| `kubectl patch cronjob <n> -p '{"spec":{"suspend":false}}'` | Resume |
| `kubectl logs -l job-name=<n>` | Logs from a spawned Job's pods |

---

## CKA Certification Tips

✅ **Create CronJob imperatively:**
```bash
kubectl create cronjob my-cron --image=busybox:1.36   --schedule="*/1 * * * *" -- sh -c "echo hello"
```

✅ **Generate YAML with dry-run:**
```bash
kubectl create cronjob my-cron --image=busybox:1.36   --schedule="*/1 * * * *" --dry-run=client -o yaml   -- sh -c "echo hello"
```

✅ **Manual trigger:**
```bash
kubectl create job test-run --from=cronjob/my-cron
```

✅ **Key fields the exam tests:**
```yaml
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  suspend: false
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
```

✅ **Check if CronJob is scheduled:**
```bash
kubectl get cronjob <n>    # SUSPEND column: False = active
kubectl describe cronjob <n> | grep "Last Schedule"
```