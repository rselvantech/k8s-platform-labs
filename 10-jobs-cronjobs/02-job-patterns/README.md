# Job Patterns — Fixed Completions, Indexed Jobs, Work Queue

## Lab Overview

This lab covers the three production Job patterns beyond the basic single-task
Job covered in Lab 01. Each pattern fits a different class of batch workload:
processing a known set of N items in parallel, processing N items where each
pod knows exactly which item it owns, and draining a queue of unknown depth.

**What you'll do:**
- Run a fixed-completion parallel Job: 6 tasks, 2 running at a time
- Use `completionMode: Indexed` — each pod receives a unique index
- Understand the work-queue pattern — no fixed completions, first success ends the Job
- Use `suspend` to pause and resume a running Job

## Prerequisites

**Required Software:**
- Minikube `3node` profile
- kubectl installed and configured

**Knowledge Requirements:**
- **REQUIRED:** Completion of `01-basic-job`

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain the four Job patterns and choose the right one for a given scenario
2. ✅ Configure `completions` and `parallelism` for a fixed-completion parallel Job
3. ✅ Use `completionMode: Indexed` so each pod knows which item to process
4. ✅ Explain how the work-queue pattern terminates when one worker succeeds
5. ✅ Use `suspend: true/false` to pause and resume a running Job

## Directory Structure

```
02-job-patterns/
└── src/
    ├── fixed-completion-job.yaml    # 6 completions, parallelism 2
    ├── indexed-job.yaml             # completionMode: Indexed
    └── work-queue-job.yaml          # No completions — work-queue pattern
```

---

## The Four Job Patterns

### Pattern Overview

```
Pattern 1 — Single Task (Lab 01)
  completions: 1, parallelism: 1
  One pod, one task. Done when it succeeds.
  Use for: DB migration, one-time setup, single report

Pattern 2 — Fixed Completion Count
  completions: N, parallelism: M  (M <= N)
  N tasks total, M running at a time.
  Each pod runs the same command — the pod determines which item to
  process from an external source or completionMode: Indexed.
  Use for: process N files, N records, N shards

Pattern 3 — Indexed Job
  completions: N, parallelism: M, completionMode: Indexed
  Same as Pattern 2 but each pod receives a unique index (0 to N-1)
  via env var JOB_COMPLETION_INDEX.
  Pod uses index to select its specific item from a known list.
  Use for: sharded processing, array jobs, map-reduce

Pattern 4 — Work Queue
  parallelism: N, completions: nil
  N workers run simultaneously, each pulling from an external queue.
  Job completes when ONE worker exits 0 (signals queue empty).
  Remaining workers are terminated.
  Use for: SQS/RabbitMQ/Redis queue draining
```

### Choosing a Pattern

| Scenario | Pattern | Configuration |
|----------|---------|--------------|
| DB migration (once) | Single | `completions:1, parallelism:1` |
| Process 100 files, 10 at a time | Fixed completion | `completions:100, parallelism:10` |
| Generate 5 reports, each pod knows which | Indexed | `completions:5, completionMode:Indexed` |
| Drain a message queue (unknown count) | Work queue | `parallelism:5` (no completions) |

---

## Manifest — Every Field Explained

### fixed-completion-job.yaml

**fixed-completion-job.yaml:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: parallel-batch
  namespace: default
  labels:
    app: parallel-batch
spec:
  completions: 6          # 6 pods must succeed for Job completion
  parallelism: 2          # Up to 2 pods run simultaneously
                          # Creates 3 waves of 2 pods each
                          # Wall-clock time = (completions/parallelism) x pod_duration
                          #                = (6/2) x ~3s = ~9s  (vs 18s sequential)
  backoffLimit: 3
  ttlSecondsAfterFinished: 60
  template:
    metadata:
      labels:
        app: parallel-batch
    spec:
      restartPolicy: Never
      containers:
        - name: worker
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              echo "Worker $(hostname) starting"
              sleep 3
              echo "Worker $(hostname) done"
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
```

### indexed-job.yaml

**indexed-job.yaml:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: indexed-batch
  namespace: default
  labels:
    app: indexed-batch
spec:
  completions: 5
  parallelism: 2

  # completionMode: Indexed
  # The controller assigns each pod a unique completion index: 0 to completions-1.
  # The index is available inside the pod as:
  #   Environment variable: JOB_COMPLETION_INDEX
  #   Annotation: batch.kubernetes.io/job-completion-index
  #   Pod name suffix: <job>-<index>  (e.g. indexed-batch-0, indexed-batch-1)
  #
  # The controller guarantees: each index (0..N-1) has exactly one pod running or
  # succeeded at any time. If index-2 pod fails, a new pod for index-2 is created.
  completionMode: Indexed

  backoffLimit: 3
  ttlSecondsAfterFinished: 60

  template:
    metadata:
      labels:
        app: indexed-batch
    spec:
      restartPolicy: Never
      containers:
        - name: worker
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              echo "Processing index: $JOB_COMPLETION_INDEX"
              # Pod uses its index to select which item to process.
              # In production: index into a file list, partition ID, shard key, etc.
              ITEMS="report-jan report-feb report-mar report-apr report-may"
              ITEM=$(echo $ITEMS | tr ' ' '
' | sed -n "$((JOB_COMPLETION_INDEX + 1))p")
              echo "Generating: $ITEM"
              sleep 2
              echo "Completed: $ITEM"
          # JOB_COMPLETION_INDEX is injected automatically by the Job controller.
          # Listing it here makes it visible to readers of the manifest.
          env:
            - name: JOB_COMPLETION_INDEX
              valueFrom:
                fieldRef:
                  fieldPath: metadata.annotations['batch.kubernetes.io/job-completion-index']
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
```

### work-queue-job.yaml

**work-queue-job.yaml:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: work-queue
  namespace: default
  labels:
    app: work-queue
spec:
  # Work Queue Pattern:
  # - completions is NOT set (nil)
  # - parallelism: N workers run simultaneously
  # - Job completes when ONE worker exits code 0
  #   (signals the queue is empty — "I checked and there is nothing left")
  # - All other running workers are then terminated by the Job controller
  #
  # In production: workers pull from SQS/RabbitMQ/Redis in a loop.
  # Loop: pull item -> process -> acknowledge -> check queue -> repeat.
  # When queue is empty: worker exits 0 -> Job completes.
  parallelism: 3          # 3 workers run simultaneously
  # completions not set   # nil = work-queue mode
  backoffLimit: 3
  ttlSecondsAfterFinished: 60

  template:
    metadata:
      labels:
        app: work-queue
    spec:
      restartPolicy: Never
      containers:
        - name: worker
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              echo "Worker $(hostname) started"
              # Simulate: workers take different amounts of time.
              # In production: loop pulling from external queue.
              WORK_TIME=$((RANDOM % 5 + 2))
              echo "Worker $(hostname) processing for ${WORK_TIME}s"
              sleep $WORK_TIME
              # First worker to exit 0 -> Job Complete -> others terminated
              echo "Worker $(hostname) signalling queue empty"
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

### Step 1: Fixed Completion — 6 Tasks, 2 at a Time

```bash
cd 02-job-patterns/src
kubectl apply -f fixed-completion-job.yaml
```

```bash
# Terminal 1 — watch pods
kubectl get pods -l app=parallel-batch -w

# Terminal 2 — watch Job progress
kubectl get job parallel-batch -w
```

**Terminal 1 — 3 waves of 2 pods:**
```
NAME                   STATUS    AGE
parallel-batch-aaaaa   Running   2s    ← wave 1: 2 pods simultaneously
parallel-batch-bbbbb   Running   2s

parallel-batch-aaaaa   Completed 5s
parallel-batch-bbbbb   Completed 5s

parallel-batch-ccccc   Running   6s    ← wave 2
parallel-batch-ddddd   Running   6s

parallel-batch-ccccc   Completed 9s
parallel-batch-ddddd   Completed 9s

parallel-batch-eeeee   Running   10s   ← wave 3
parallel-batch-fffff   Running   10s

parallel-batch-eeeee   Completed 13s
parallel-batch-fffff   Completed 13s
```

**Terminal 2 — progress tracked:**
```
NAME            COMPLETIONS   DURATION
parallel-batch  0/6           2s
parallel-batch  2/6           5s    ← 2 done
parallel-batch  4/6           9s    ← 4 done
parallel-batch  6/6           13s   ← COMPLETE ✅
```

---

### Step 2: Indexed Job — Each Pod Knows Its Item

```bash
kubectl apply -f indexed-job.yaml
```

```bash
kubectl get pods -l app=indexed-batch
```

**Expected pod names — ordinal suffix, not random:**
```
NAME                STATUS    AGE
indexed-batch-0     Running   2s    ← index 0 -> report-jan
indexed-batch-1     Running   2s    ← index 1 -> report-feb
indexed-batch-2     Pending   0s    ← waiting (parallelism: 2)
indexed-batch-3     Pending   0s
indexed-batch-4     Pending   0s
```

```bash
# Each pod processed its specific item
kubectl logs indexed-batch-0
```

**Expected:**
```
Processing index: 0
Generating: report-jan
Completed: report-jan
```

```bash
kubectl logs indexed-batch-3
```

**Expected:**
```
Processing index: 3
Generating: report-apr
Completed: report-apr
```

Each pod processes exactly its assigned item. No coordination between pods
needed — the controller injects the index and guarantees uniqueness.

---

### Step 3: Work Queue — First Worker to Finish Ends the Job

```bash
kubectl apply -f work-queue-job.yaml
```

```bash
# Terminal 1 — watch pods
kubectl get pods -l app=work-queue -w

# Terminal 2 — watch Job
kubectl get job work-queue -w
```

**Terminal 1 — all 3 start together, first to finish ends the Job:**
```
NAME               STATUS    AGE
work-queue-aaaaa   Running   2s   ← all 3 workers start simultaneously
work-queue-bbbbb   Running   2s
work-queue-ccccc   Running   2s

work-queue-bbbbb   Completed 5s   ← FIRST to exit 0 -> Job Complete
work-queue-aaaaa   Terminating 5s ← others terminated immediately
work-queue-ccccc   Terminating 5s
```

**Terminal 2:**
```
NAME          COMPLETIONS
work-queue    0/1          ← waiting for first success
work-queue    1/1          ← COMPLETE ✅
```

Note: COMPLETIONS shows `0/1` even though parallelism is 3 — the `1` in
the denominator means "we need one success", not "we have one worker".

---

### Step 4: Suspend and Resume a Job

```bash
# Start the fixed-completion job again
kubectl apply -f fixed-completion-job.yaml

# Immediately suspend it — stops new pod creation
kubectl patch job parallel-batch -p '{"spec":{"suspend":true}}'

kubectl get job parallel-batch
# COMPLETIONS shows less than 6/6 — no new pods while suspended
kubectl get pods -l app=parallel-batch
# Only pods that were running before suspend — no new ones
```

```bash
# Resume — Job continues creating pods until 6 completions
kubectl patch job parallel-batch -p '{"spec":{"suspend":false}}'
kubectl get job parallel-batch -w
# Completes normally
```

**When to use suspend:**
- Cluster maintenance window
- Bug discovered mid-run — pause, fix the image, resume
- Cost control — pause during off-hours, resume at start of day

---

### Step 5: Cleanup

`ttlSecondsAfterFinished: 60` on each Job handles automatic cleanup.
For immediate cleanup:

```bash
kubectl delete job parallel-batch indexed-batch work-queue 2>/dev/null || true
```

---

## Common Questions

### Q: How does a work-queue Job know when the queue is empty?
**A:** The worker itself detects it. The worker code calls the queue API —
when the API returns empty, the worker exits 0. The Job controller sees
the Succeeded pod and terminates remaining workers. The queue client
(boto3 for SQS, pika for RabbitMQ) provides the empty-check.

### Q: With Indexed mode, can two pods get the same index?
**A:** No — the controller guarantees each index (0 to completions-1) is
assigned to exactly one pod at a time. If pod for index 2 fails, a new pod
for index 2 is created. No duplicate processing.

### Q: What is `parallelism: 0`?
**A:** Setting `parallelism: 0` effectively pauses the Job — same as
`suspend: true`. The `suspend` field (Kubernetes 1.24+) is preferred as
it is semantically clearer.

### Q: Can I use Indexed mode with work-queue?
**A:** No — `completionMode: Indexed` requires `completions` to be set.
Work-queue pattern requires `completions` to be nil. They are mutually exclusive.

---

## What You Learned

In this lab, you:
- ✅ Explained the four Job patterns and when to use each
- ✅ Ran a fixed-completion Job with `completions:6, parallelism:2` — 3 waves of 2
- ✅ Used `completionMode: Indexed` — each pod received its unique index via env var
- ✅ Ran a work-queue Job — 3 workers, first to exit 0 completed the Job
- ✅ Used `suspend:true/false` to pause and resume a Job mid-run

**Key Takeaway:** Choose your Job pattern based on what you know upfront.
Known N items → fixed-completion or indexed. Unknown count (queue) → work-queue.
Use indexed when each pod must process a specific known item — the controller
guarantees index uniqueness, eliminating coordination code.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get job <n>` | COMPLETIONS: N/M — progress |
| `kubectl get pods -l job-name=<n>` | All pods for a Job |
| `kubectl logs <indexed-job>-0` | Logs from indexed pod 0 |
| `kubectl patch job <n> -p '{"spec":{"suspend":true}}'` | Pause Job |
| `kubectl patch job <n> -p '{"spec":{"suspend":false}}'` | Resume Job |