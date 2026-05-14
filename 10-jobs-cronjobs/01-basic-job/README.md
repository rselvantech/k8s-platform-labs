# Basic Job — Run-to-Completion Workloads

## Lab Overview

This lab introduces the Job workload — Kubernetes's mechanism for tasks that
must run to completion rather than run continuously. Unlike a Deployment
(which keeps pods running forever) or a DaemonSet (which runs on every node),
a Job creates pods that do work and then stop. The Job controller tracks
completions and retries failures until the task succeeds or exhausts its
retry budget.

Jobs are the right workload for database migrations, batch data processing,
report generation, one-time setup tasks, and any work that has a defined end.

**What you'll do:**
- Understand the Job controller and how it differs from Deployment and StatefulSet
- Walk through every field in the Job manifest with full explanation
- Run a simple batch job and observe the pod lifecycle: Pending → Running → Completed
- Understand `restartPolicy: Never` vs `restartPolicy: OnFailure`
- Observe Job failure and retry with `backoffLimit` and exponential backoff
- Use `ttlSecondsAfterFinished` for automatic Job cleanup
- Use `activeDeadlineSeconds` to enforce a hard Job timeout

## Prerequisites

**Required Software:**
- Minikube `3node` profile
- kubectl installed and configured

**Knowledge Requirements:**
- **REQUIRED:** Completion of `02-deployments/01-basic-deployment`
- Understanding of pod lifecycle phases

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain how the Job controller differs from Deployment and DaemonSet controllers
2. ✅ Explain every field in the Job manifest and its valid values
3. ✅ Observe the pod lifecycle for a successful Job: Pending → Running → Succeeded
4. ✅ Explain `restartPolicy: Never` vs `restartPolicy: OnFailure` and when to use each
5. ✅ Observe Job failure — pod statuses, exponential backoff, `backoffLimit` exhaustion
6. ✅ Use `ttlSecondsAfterFinished` to auto-delete completed Jobs
7. ✅ Use `activeDeadlineSeconds` to enforce a hard Job timeout
8. ✅ Read all columns of `kubectl get job` output

## Directory Structure

```
01-basic-job/
└── src/
    ├── basic-job.yaml        # Simple batch job — echo and sleep
    ├── failing-job.yaml      # Job that always fails — demonstrates backoffLimit
    └── ttl-job.yaml          # Job with automatic cleanup
```

---

## Understanding Jobs

### Job vs Deployment vs DaemonSet

```
Deployment:
  Goal:     keep pods running continuously
  Pod dies: restart it immediately
  Done:     never — runs until deleted
  Use for:  web servers, APIs, long-running services

DaemonSet:
  Goal:     run exactly one pod per matching node
  Pod dies: restart it on the same node
  Done:     never — runs until deleted
  Use for:  node agents, log collectors, monitoring

Job:
  Goal:     run until N pods succeed (exit code 0)
  Pod dies: retry up to backoffLimit times
  Done:     when N pods have Succeeded
  Use for:  batch processing, DB migrations, one-time tasks

Key difference:
  Deployment: pod in Succeeded phase → restart it (success is the wrong state)
  Job:        pod in Succeeded phase → count it  (success IS the goal state)
```

### The Job Controller — Reconcile Loop

```
Job Controller (inside kube-controller-manager):

  Every reconcile cycle:
    succeeded = pods with phase Succeeded
    failed    = pods with phase Failed

    if succeeded >= spec.completions   → mark Job Complete ✅
    if failed    >  spec.backoffLimit  → mark Job Failed  ❌
    otherwise                          → create more pods

  Failure backoff (exponential, capped at 6 minutes):
    1st failure → wait  10s → create replacement pod
    2nd failure → wait  20s → create replacement pod
    3rd failure → wait  40s → create replacement pod
    4th failure → wait  80s → create replacement pod
    ...capped at 360s per attempt
```

### Pod Phases for Job Pods

```
Pending    → scheduled, container not yet started
Running    → container executing
Succeeded  → container exited with code 0  ← Job counts as completion
Failed     → container exited non-zero      ← Job retries (up to backoffLimit)

kubectl get pods STATUS column:
  Completed  → Succeeded phase (human-readable alias)
  Error      → Failed phase

Job pods NEVER restart after Succeeded.
Succeeded is the terminal goal state — not an error to fix.
```

### restartPolicy — Critical Setting for Jobs

Job pods **must** use `Never` or `OnFailure`.
`Always` (the Deployment default) is **rejected** by the API server for Jobs —
it prevents the pod from ever reaching Succeeded, so the Job can never complete.

```
restartPolicy: Never
  On failure: pod goes to Error, Job creates a NEW pod
  Pod count grows with failures: pod-aaa Error, pod-bbb Error, pod-ccc Completed
  All failed pods remain for log inspection
  Use when: each retry needs a clean environment, or post-mortem debugging needed

restartPolicy: OnFailure
  On failure: SAME pod is restarted (container re-runs, RESTARTS counter increments)
  Only one pod object exists regardless of failure count
  Use when: task is idempotent and same environment is acceptable between retries
```

---

## Job Manifest — Every Field Explained

### basic-job.yaml

**basic-job.yaml:**
```yaml
apiVersion: batch/v1        # Jobs live in the batch API group (not apps)
kind: Job
metadata:
  name: batch-job
  namespace: default
  labels:
    app: batch-job
spec:

  # ── Completions ──────────────────────────────────────────────────────
  completions: 1
  # Number of pod Successes required for the Job to be Complete.
  # completions: 1  → single task (default)
  # completions: 6  → batch of 6; 6 pods must each succeed
  # nil + parallelism set → work-queue mode (see Lab 02)

  # ── Parallelism ──────────────────────────────────────────────────────
  parallelism: 1
  # Maximum pods running simultaneously.
  # parallelism: 1  → sequential, one pod at a time
  # parallelism: 3  → up to 3 pods run concurrently
  # parallelism > completions → capped at completions (no over-parallelisation benefit)

  # ── Failure budget ───────────────────────────────────────────────────
  backoffLimit: 3
  # Maximum pod failures before the Job itself is marked Failed.
  # Retries use exponential backoff: 10s, 20s, 40s, 80s... (capped at 6 minutes).
  # backoffLimit: 0 → no retries; one failure = Job Failed immediately.
  # Default: 6 if not specified.

  # ── Hard timeout ─────────────────────────────────────────────────────
  # activeDeadlineSeconds: 120
  # Elapsed wall-clock seconds after which the entire Job is terminated.
  # All running pods are killed. Job condition: Failed, reason: DeadlineExceeded.
  # Takes precedence over backoffLimit — whichever fires first wins.
  # Not set here — see Step 7 for the demo.

  # ── Automatic cleanup ────────────────────────────────────────────────
  # ttlSecondsAfterFinished: 300
  # Seconds after Job reaches terminal state (Complete or Failed) before it
  # and all its pods are automatically deleted.
  # Without this: completed Jobs accumulate in etcd indefinitely.
  # Production best practice: always set this. Common values: 3600 (1h), 86400 (24h).
  # Not set here — see ttl-job.yaml for the dedicated demo.

  # ── Pod Template ─────────────────────────────────────────────────────
  template:
    metadata:
      labels:
        app: batch-job
    spec:
      restartPolicy: Never    # Must be Never or OnFailure — not Always

      containers:
        - name: batch
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              echo "Job started at $(date)"
              echo "Processing batch task..."
              sleep 5
              echo "Job completed at $(date)"
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
| `completions` | 1 | Pod Successes required for Job completion |
| `parallelism` | 1 | Max pods running simultaneously |
| `backoffLimit` | 6 | Max pod failures before Job is Failed |
| `activeDeadlineSeconds` | none | Hard wall-clock timeout for entire Job |
| `ttlSecondsAfterFinished` | none | Auto-delete N seconds after finish |
| `restartPolicy` | — | Must be `Never` or `OnFailure` — not `Always` |

### failing-job.yaml

**failing-job.yaml:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: failing-job
  namespace: default
  labels:
    app: failing-job
spec:
  completions: 1
  backoffLimit: 3           # 3 failures allowed → 4 total pod attempts
                            # Backoff: 10s after 1st, 20s after 2nd, 40s after 3rd
  template:
    metadata:
      labels:
        app: failing-job
    spec:
      restartPolicy: Never  # New pod created per failure
      containers:
        - name: fail
          image: busybox:1.36
          # exit 1 — non-zero exit code → pod Failed → Job retries
          command: ["sh", "-c", "echo 'Task failed intentionally'; exit 1"]
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
```

### ttl-job.yaml

**ttl-job.yaml:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ttl-job
  namespace: default
  labels:
    app: ttl-job
spec:
  completions: 1
  # Auto-delete the Job and all its pods 30 seconds after completion.
  # Without this: completed Jobs accumulate in etcd indefinitely.
  # Production: use a longer value like 3600 (1h) or 86400 (24h).
  ttlSecondsAfterFinished: 30
  template:
    metadata:
      labels:
        app: ttl-job
    spec:
      restartPolicy: Never
      containers:
        - name: task
          image: busybox:1.36
          command: ["sh", "-c", "echo 'Task done'; sleep 2"]
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

### Step 1: Deploy the Basic Job

```bash
cd 01-basic-job/src
kubectl apply -f basic-job.yaml
```

**Open two terminals:**

```bash
# Terminal 1 — watch pods
kubectl get pods -w

# Terminal 2 — watch Job status
kubectl get job batch-job -w
```

**Terminal 1 — expected pod lifecycle:**
```
NAME              READY   STATUS              RESTARTS   AGE
batch-job-xxxxx   0/1     Pending             0          0s
batch-job-xxxxx   0/1     ContainerCreating   0          2s
batch-job-xxxxx   1/1     Running             0          3s   ← executing
batch-job-xxxxx   0/1     Completed           0          8s   ← exited code 0 ✅
```

**Terminal 2 — expected Job status:**
```
NAME        COMPLETIONS   DURATION   AGE
batch-job   0/1           3s         3s   ← running
batch-job   1/1           8s         8s   ← COMPLETE ✅
```

**COMPLETIONS column explained:**
```
0/1 → 0 pods succeeded of 1 required (in progress)
1/1 → 1 pod succeeded of 1 required (done)
```

---

### Step 2: Inspect Job Details

```bash
kubectl describe job batch-job
```

**Key sections to read:**
```
Parallelism:    1
Completions:    1
Duration:       8s
Pods Statuses:  0 Active / 1 Succeeded / 0 Failed

Events:
  Normal  SuccessfulCreate  pod/batch-job-xxxxx created
  Normal  Completed         Job completed
```

`Pods Statuses: 0 Active / 1 Succeeded / 0 Failed` — the definitive summary.

---

### Step 3: Read Pod Logs

Completed pods stay until the Job is deleted (or TTL expires):

```bash
kubectl logs -l app=batch-job
```

**Expected output:**
```
Job started at Mon Jan 15 09:41:03 UTC 2024
Processing batch task...
Job completed at Mon Jan 15 09:41:08 UTC 2024
```

---

### Step 4: Observe Job Failure and Backoff

```bash
kubectl apply -f failing-job.yaml

# Terminal 1 — watch pods appear and fail
kubectl get pods -l app=failing-job -w

# Terminal 2 — watch Job
kubectl get job failing-job -w
```

**Terminal 1 — 4 pods, all failing:**
```
NAME                READY   STATUS    AGE
failing-job-aaaaa   1/1     Running   2s
failing-job-aaaaa   0/1     Error     3s    ← failed, 10s backoff

failing-job-bbbbb   0/1     Pending   13s   ← new pod after backoff
failing-job-bbbbb   0/1     Error     15s   ← failed, 20s backoff

failing-job-ccccc   0/1     Error     38s   ← failed, 40s backoff

failing-job-ddddd   0/1     Error     81s   ← 4th failure = backoffLimit(3)+1
                                               Job now marked Failed
```

**Terminal 2:**
```
NAME          COMPLETIONS   DURATION
failing-job   0/1           81s        ← FAILED
```

```bash
kubectl describe job failing-job | grep -A5 "Conditions\|Pods Status"
```

**Expected:**
```
Pods Statuses:  0 Active / 0 Succeeded / 4 Failed
Conditions:
  Type    Status  Reason
  Failed  True    BackoffLimitExceeded
```

All 4 failed pods remain for debugging:
```bash
kubectl get pods -l app=failing-job
# 4 pods — all STATUS: Error — logs available on each

kubectl logs failing-job-aaaaa
# Task failed intentionally

kubectl delete job failing-job   # deletes Job AND all 4 pods
```

---

### Step 5: restartPolicy: OnFailure — Same Pod Restarts

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: retry-job
spec:
  completions: 1
  backoffLimit: 5
  template:
    spec:
      restartPolicy: OnFailure      # SAME pod container restarts on failure
      containers:
        - name: retry
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              ATTEMPTS=$(cat /tmp/count 2>/dev/null || echo 0)
              echo "Attempt: $ATTEMPTS"
              echo $((ATTEMPTS + 1)) > /tmp/count
              if [ "$ATTEMPTS" -lt "2" ]; then
                echo "Not ready — failing"
                exit 1
              fi
              echo "Succeeded on attempt $ATTEMPTS"
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
EOF

kubectl get pods -w
```

**Expected — SAME pod, RESTARTS increments:**
```
NAME             READY   STATUS    RESTARTS   AGE
retry-job-xxxxx  1/1     Running   0          2s
retry-job-xxxxx  0/1     Error     0          3s
retry-job-xxxxx  1/1     Running   1          13s   ← same pod, RESTARTS=1
retry-job-xxxxx  0/1     Error     1          14s
retry-job-xxxxx  1/1     Running   2          34s   ← RESTARTS=2
retry-job-xxxxx  0/1     Completed 2          35s   ← succeeded ✅
```

**Comparison:**

| Behaviour | `Never` | `OnFailure` |
|-----------|---------|-------------|
| On failure | New pod created | Same pod container restarts |
| Pod objects | 1 per attempt | 1 total |
| RESTARTS column | Always 0 | Increments each failure |
| Failed pods preserved | Yes — all visible | No — same pod object |
| Use when | Need per-attempt log inspection | Task is idempotent |

```bash
kubectl delete job retry-job
```

---

### Step 6: ttlSecondsAfterFinished — Automatic Cleanup

```bash
kubectl apply -f ttl-job.yaml
kubectl get job ttl-job -w
```

**Expected:**
```
NAME      COMPLETIONS   DURATION   AGE
ttl-job   0/1           2s         2s
ttl-job   1/1           4s         4s    ← completed
# ... 30 seconds pass ...
# ttl-job disappears — auto-deleted by TTL controller
```

```bash
kubectl get job ttl-job
# Error from server (NotFound): jobs.batch "ttl-job" not found
```

Job AND its pods are deleted automatically. No manual cleanup needed.

---

### Step 7: activeDeadlineSeconds — Hard Timeout

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: deadline-job
spec:
  completions: 1
  activeDeadlineSeconds: 10     # Must complete within 10 seconds
  backoffLimit: 5
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: slow-task
          image: busybox:1.36
          command: ["sh", "-c", "echo 'Starting long task...'; sleep 60"]
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
EOF

kubectl get job deadline-job -w
```

**Expected:**
```
NAME           COMPLETIONS   DURATION   AGE
deadline-job   0/1           1s         1s
deadline-job   0/1           10s        10s   ← FAILED: DeadlineExceeded
```

```bash
kubectl describe job deadline-job | grep -A3 Conditions
# Type    Status  Reason
# Failed  True    DeadlineExceeded

kubectl delete job deadline-job
kubectl delete job batch-job
```

---

## Common Questions

### Q: Why do completed Job pods stay after the Job is done?
**A:** By design — so you can inspect logs and exit codes after completion.
Without `ttlSecondsAfterFinished`, pods stay until you delete the Job.
In production, always set `ttlSecondsAfterFinished` to prevent etcd bloat.

### Q: What is the difference between `backoffLimit` and `activeDeadlineSeconds`?
**A:** `backoffLimit` limits the count of pod failures. `activeDeadlineSeconds`
limits elapsed wall-clock time. Both can fail the Job — whichever triggers
first wins. Use both together for a complete safety net.

### Q: Can I pause a Job mid-run?
**A:** Yes — `kubectl patch job <n> -p '{"spec":{"suspend":true}}'` stops
new pod creation. Running pods continue. Resume with `suspend: false`.

### Q: What happens if `activeDeadlineSeconds` fires while a pod is running?
**A:** The running pod receives SIGTERM then SIGKILL. The Job is marked
Failed with reason `DeadlineExceeded`. No more pods are created.

---

## What You Learned

In this lab, you:
- ✅ Explained the Job controller — run-to-completion, not run-forever
- ✅ Explained every field: `completions`, `parallelism`, `backoffLimit`, `activeDeadlineSeconds`, `ttlSecondsAfterFinished`
- ✅ Observed: Pending → Running → Completed pod lifecycle
- ✅ Observed Job failure: 4 pods, exponential backoff, BackoffLimitExceeded
- ✅ Compared `restartPolicy: Never` (new pod) vs `OnFailure` (same pod, RESTARTS++)
- ✅ Used `ttlSecondsAfterFinished` for automatic cleanup
- ✅ Used `activeDeadlineSeconds` for hard timeout

**Key Takeaway:** Jobs run to completion — not continuously. Completed is
success, not an error. Failed pods are preserved for debugging. Always set
`ttlSecondsAfterFinished` in production to keep etcd clean.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl create job <n> --image=<img> -- <cmd>` | Create Job imperatively |
| `kubectl get jobs` | List all Jobs — COMPLETIONS column |
| `kubectl describe job <n>` | Full detail — Pods Statuses, Conditions, Events |
| `kubectl logs -l job-name=<n>` | Logs from all pods of the Job |
| `kubectl delete job <n>` | Delete Job and all its pods |
| `kubectl get pods -l job-name=<n>` | All pods for a specific Job |

---

## CKA Certification Tips

✅ **Imperative creation:**
```bash
kubectl create job my-job --image=busybox:1.36 -- sh -c "echo done"
```

✅ **Generate YAML with dry-run:**
```bash
kubectl create job my-job --image=busybox:1.36 \
  --dry-run=client -o yaml -- sh -c "echo done"
```

✅ **Key fields to remember:**
```yaml
spec:
  completions: 1
  parallelism: 1
  backoffLimit: 3
  activeDeadlineSeconds: 60
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never    # NOT Always — rejected by API server
```

✅ **Read status fast:**
```bash
kubectl get job <n>    # COMPLETIONS: N/M
kubectl describe job <n> | grep "Pods Statuses"
```