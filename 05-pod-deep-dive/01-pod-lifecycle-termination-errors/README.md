# Pod Lifecycle, Termination, Restart & Image Pull Policies

## Lab Overview

This lab gives you a deep, hands-on understanding of how Kubernetes manages the
full lifecycle of a pod — from the moment you run `kubectl apply` to the moment
a pod is deleted. You will observe every phase transition live, understand how
Kubernetes terminates containers gracefully, control restart behaviour with
restart policies, and manage image pulling with image pull policies.

You will also learn how to read and interpret the five pod conditions and
understand the difference between a pod's **phase** (what stage it is in) and
its **conditions** (which specific milestones it has passed). This distinction
is one of the most commonly misunderstood topics in Kubernetes.

Finally, you will deliberately trigger the most common pod errors and walk
through a systematic debugging workflow to resolve each one.

**What you'll do:**
- Observe all five pod conditions and understand what each one checks
- Watch every pod phase transition live using `kubectl get pods -w`
- Configure graceful shutdown with `terminationGracePeriodSeconds` and a `preStop` hook
- Compare force delete vs graceful delete
- Deploy the same job with all three restart policies and observe different outcomes
- Understand and configure `imagePullPolicy` with all three values
- Trigger `ErrImagePull`, `ImagePullBackOff`, `CrashLoopBackOff`, and `OOMKilled`
- Debug each error using `kubectl describe`, `kubectl logs --previous`, and `kubectl events`

## Prerequisites

**Required Software:**
- Minikube multi-node cluster (`3node` profile) — 1 control plane + 2 workers
- kubectl installed and configured
- Text editor (VS Code recommended)

**Knowledge Requirements:**
- Basic understanding of Pods and containers
- Familiarity with `kubectl apply`, `kubectl get`, `kubectl describe`
- Basic YAML syntax

## Lab Objectives

By the end of this lab, you will be able to:

1. ✅ Explain the difference between pod phase and pod conditions
2. ✅ Read and interpret all five pod conditions including the `reason` field
      and `lastTransitionTime` from live pod YAML
3. ✅ Observe every phase transition live:
      Pending → ContainerCreating → Running → Completed
4. ✅ Explain what SIGTERM and SIGKILL are and why Kubernetes uses SIGTERM first
5. ✅ Explain what PID 1 is in a container and why the signal forwarding
      problem causes silent graceful shutdown failures in production
6. ✅ Explain both container lifecycle hooks — `postStart` and `preStop` —
      their execution order, handler options (`exec` vs `httpGet`),
      and how they share the `terminationGracePeriodSeconds` budget
7. ✅ Configure graceful shutdown using `terminationGracePeriodSeconds`,
      a `preStop` hook, and a shell `trap` signal handler
8. ✅ Configure all three restart policies and predict the outcome for
      any exit code combination
9. ✅ Configure `imagePullPolicy` correctly for development and production
      environments and explain the tag collision risk
10. ✅ Identify and debug `ErrImagePull`, `ImagePullBackOff`, `OOMKilled`,
       and `CrashLoopBackOff` using the standard debug workflow

## Directory Structure

```
01-pod-lifecycle-termination-errors/
└── src/
    ├── 01-phase-conditions-demo.yaml       # Pod phase and conditions observation
    ├── 02-graceful-shutdown.yaml           # terminationGracePeriodSeconds + preStop hook
    ├── 03-restart-policy-always.yaml       # restartPolicy: Always (web server)
    ├── 04-restart-policy-onfailure.yaml    # restartPolicy: OnFailure (batch job)
    ├── 05-restart-policy-never.yaml        # restartPolicy: Never (diagnostic pod)
    ├── 06-image-pull-policy.yaml           # imagePullPolicy: Always vs IfNotPresent
    ├── 07-error-imagepull.yaml             # Triggers ErrImagePull → ImagePullBackOff
    └── 08-error-oomkilled.yaml             # Triggers OOMKilled → CrashLoopBackOff
```

## Understanding Pod Phase vs Pod Conditions

### Phase — The High-Level Summary

The **phase** is a single string that gives a bird's-eye view of where the pod
is in its lifecycle. You see it in the `STATUS` column of `kubectl get pods`.

```
Pending  →  ContainerCreating  →  Running  →  Completed
                                          ↘  Error / CrashLoopBackOff
```

> **Important:** `ContainerCreating` and `CrashLoopBackOff` are NOT official
> Kubernetes phases. They are display strings that kubectl constructs from
> the container state to give you a human-readable status. The five official
> phases are: `Pending`, `Running`, `Succeeded`, `Failed`, and `Unknown`.

### Conditions — The Granular Checkpoints

While the phase answers "what stage is the pod in overall?", conditions answer
"which specific milestones has this pod passed?". A pod has five conditions,
each set by **kubelet**, each independently `True` or `False`:

```
┌──────────────────────────────────────────────────────────────────────┐
│                    5 POD CONDITIONS                                  │
│                                                                      │
│  PodScheduled              → Scheduler assigned pod to a node        │
│  PodReadyToStartContainers → Sandbox created, IP assigned, CNI ready │
│  Initialized               → All init containers completed (or none) │
│  ContainersReady           → All containers running + probes passing  │
│  Ready                     → Pod eligible to receive Service traffic  │
└──────────────────────────────────────────────────────────────────────┘
```

### How Phase and Conditions Relate

```
CONDITIONS STATE                   POD PHASE    STATUS column      READY
─────────────────────────────────────────────────────────────────────────
PodScheduled         = False       Pending      Pending            0/1
─────────────────────────────────────────────────────────────────────────
PodScheduled         = True        Pending      ContainerCreating  0/1
PodReadyToStart      = True
Initialized          = True
ContainersReady      = False  ← container process NOT started yet
Ready                = False
─────────────────────────────────────────────────────────────────────────
PodScheduled         = True        Running      Running            0/1
PodReadyToStart      = True
Initialized          = True
ContainersReady      = False  ← process running, probe failing
Ready                = False       (readiness probe not passing)
─────────────────────────────────────────────────────────────────────────
All five             = True        Running      Running            1/1 ✅
─────────────────────────────────────────────────────────────────────────
ContainersReady      = False       Succeeded    Completed          0/1
Ready                = False       (container exited exit 0, not restarting)
─────────────────────────────────────────────────────────────────────────
ContainersReady      = False       Failed       Error              0/1
Ready                = False       (container exited non-zero, not restarting)
```

> **Key insight:** `ContainersReady = False` appears in BOTH the
> `ContainerCreating` state and the `Running 0/1` state. The CONDITIONS alone
> do not tell you which. The difference is the **container state** underneath:
> - `ContainerCreating` → container state is `Waiting` (process not started)
> - `Running 0/1` → container state is `Running` (process started, probe failing)
>
> Check this with: `kubectl get pod <n> -o jsonpath='{.status.containerStatuses[0].state}'`

### container `ready` Flag — What Controls It

The per-container `ready` flag drives `ContainersReady` at the pod level:

```
Container state = Running
    ├── readiness probe configured → ready = probe result (true/false)
    └── readiness probe NOT configured → ready = true (default Success)

Container state = Waiting or Terminated → ready = false (always)
```

This means: without a readiness probe, Kubernetes assumes the container is
ready the instant the process starts. It has no way to know if the application
inside is actually working.

---

## Understanding Pod Termination — Key Concepts

Before running the graceful shutdown demo, these three concepts must be
understood clearly. Each one is a building block — Step 7 builds on all three.


### Concept A — Linux Signals & SIGTERM

#### What Is a Signal?

A signal is a simple notification that the operating system sends to a running
process. You can think of it as a tap on the shoulder — a way to tell a process
"something has happened, do something about it."

Signals have numbers and names. Only two matter for Kubernetes:
```
SIGTERM  (signal 15)  →  "Please shut down gracefully"
SIGKILL  (signal 9)   →  "Die immediately, no exceptions"
```

#### SIGTERM — The Polite Request

SIGTERM is the standard way to ask a process to shut down. The key property
is that SIGTERM **can be caught and handled** by the application. When a
process receives SIGTERM, it has a choice:

- Handle it → run cleanup code, close connections, flush buffers, then exit
- Ignore it → keep running (Kubernetes will escalate to SIGKILL after the
  grace period)

This is why well-written applications register a SIGTERM handler — so they
can shut down cleanly when asked.

#### SIGKILL — The Hard Stop

SIGKILL is fundamentally different. It is sent directly by the OS kernel and
**cannot be caught, trapped, or ignored** by any application — ever. There
is no handler to register. When SIGKILL arrives, the process is terminated
immediately with no opportunity for cleanup.
```
SIGTERM  →  Application can handle it  →  graceful shutdown possible
SIGKILL  →  Application cannot handle it  →  immediate death, no cleanup
```

#### What Kubernetes Does

Kubernetes always tries SIGTERM first and only escalates to SIGKILL if the
process does not exit within `terminationGracePeriodSeconds`:
```
kubectl delete pod
    │
    ▼
SIGTERM sent  →  application has time to clean up
    │
    │  if not done within terminationGracePeriodSeconds
    ▼
SIGKILL sent  →  process terminated immediately
```

> **Why this matters for a payment service:** If SIGKILL hits mid-transaction,
> there is no cleanup. The database write may be half-complete. The client
> response may never be sent. SIGTERM with a long enough grace period is what
> gives the payment service a chance to complete the transaction cleanly.

---

### Concept B — PID 1 and the Signal Forwarding Problem

#### What Is PID 1?

Every Linux process has a process ID (PID). The first process that starts in
any Linux environment gets PID 1. In a container, **PID 1 is whatever your
container's `command` or `ENTRYPOINT` starts as.**
```
Container starts
    └── PID 1 = your ENTRYPOINT / command
              └── may spawn child processes (PID 2, 3, ...)
```

#### Why PID 1 Is Special for Signals

Kubernetes sends SIGTERM to **PID 1 only** — not to child processes, not
broadcast to all running processes. Just PID 1.

This means: **if PID 1 does not forward the signal to your application, your
application never receives SIGTERM.**

#### The Signal Forwarding Problem

This is a very common production bug. It happens when a shell script is PID 1
but the actual application is a child process:
```
Container starts
    └── PID 1 = /bin/sh start.sh        ← shell script is PID 1
              └── PID 47 = java -jar app.jar  ← real app is a child

kubectl delete pod
    └── SIGTERM sent to PID 1 (/bin/sh)
        /bin/sh exits immediately
        ← does NOT forward SIGTERM to PID 47
        PID 47 (java) never receives SIGTERM
        terminationGracePeriodSeconds expires
        SIGKILL sent to all processes
        Java dies without cleanup
```

#### The Fix — `exec` in Entrypoint Scripts

Replace the shell with your application using `exec`. This makes the
application itself become PID 1 rather than a child of the shell:
```bash
# ❌ WRONG — shell is PID 1, java is a child
java -jar app.jar

# ✅ CORRECT — exec replaces the shell with java
# java becomes PID 1 and receives SIGTERM directly
exec java -jar app.jar
```
```
With exec:
    └── PID 1 = java -jar app.jar   ← java IS PID 1

kubectl delete pod
    └── SIGTERM sent to PID 1 (java)
        java receives it directly
        java runs its shutdown hook
        java exits cleanly ✅
```

#### In Our Demo

In the graceful shutdown demo, `/bin/sh` is PID 1 and it has a `trap`
handler registered for SIGTERM. When Kubernetes sends SIGTERM to PID 1, the
shell catches it via `trap` and runs the cleanup logic. This works correctly
because the shell itself is the application we care about — there is no child
process that needs the signal.

---

### Concept C — Container Lifecycle Hooks

#### What Are Lifecycle Hooks?

Lifecycle hooks are callbacks that allow containers to run code at specific
points in their own lifecycle — immediately after starting, and immediately
before being terminated. 

Kubernetes provides two hooks, both defined inside the container spec under
`lifecycle`:
```yaml
containers:
  - name: my-app
    image: busybox:1.36
    lifecycle:
      postStart: ...   # fires after container starts
      preStop:   ...   # fires before container is terminated
```

#### postStart — After Container Starts

Kubernetes sends the postStart event immediately after the Container is
created. There is no guarantee, however, that the postStart handler is called
before the Container's entrypoint is called. 
```
Container created
    ├── ENTRYPOINT starts  ──┐
    └── postStart fires  ────┘  (concurrent — no guaranteed order)
```

The container's status is not set to Running until the postStart handler
completes. If the PostStart hook takes too long to execute or if it hangs,
it can prevent the container from transitioning to a running state. 

**Use cases for postStart:**
- Register service with a discovery system (Consul, etcd)
- Pre-warm a local cache before the app starts serving
- Write a startup timestamp to a shared volume

> **Important:** Because postStart races with ENTRYPOINT, do not use it for
> anything that must complete before the application starts. Use an init
> container for that — init containers have a guaranteed completion guarantee
> that postStart does not.

#### preStop — Before Container Is Terminated

The preStop hook is called immediately before a container is terminated.
It must complete its execution before the TERM signal to stop the container
can be sent. 
```
kubectl delete pod triggered
    │
    ├── Pod marked Terminating in API server
    │
    ▼
terminationGracePeriodSeconds countdown BEGINS
    │
    ▼
preStop hook fires (if configured) →  runs to completion (or grace period expires)
    │
    ▼
SIGTERM sent to PID 1
    │
    ▼
Application shuts down (or grace period expires → SIGKILL)
        ├── App handles SIGTERM? → graceful shutdown
        └── Not done within terminationGracePeriodSeconds?
                   → SIGKILL sent (forced, cannot be caught)

Default grace period: 30 seconds
```


> **Critical rule from official docs:** The termination grace period
> countdown begins before the PreStop hook is executed. Regardless of the
> outcome of the handler, the container will eventually terminate within the
> Pod's termination grace period.  This means preStop duration and
> SIGTERM handling time share the same budget.

**Use cases for preStop:**
- Add a sleep to allow load balancer endpoint propagation to drain
- Deregister from service discovery before the application stops
- Flush write buffers or pending queue acknowledgements

#### Two Handler Options

Both `postStart` and `preStop` support two handler types:

**Option 1 — `exec`**

Runs a command **inside the container**. Same filesystem, same network,
same environment variables as the main process.
```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "echo draining; sleep 5"]
```

- The `exec` handler is executed in the container itself. 
- Exit code 0 = success. Non-zero = hook failed.
- A failed preStop does not prevent termination — the container is terminated
  regardless, but a `FailedPreStopHook` event is recorded.

**Option 2 — `httpGet`**

Makes an HTTP GET request to an endpoint on the container.
```yaml
lifecycle:
  preStop:
    httpGet:
      path: /shutdown
      port: 8080
      scheme: HTTP          # HTTP or HTTPS
      httpHeaders:
        - name: X-Shutdown-Token
          value: "secret"
```

- The `httpGet` handler is executed by the kubelet process, not inside
  the container. 
- HTTP response 200–299 = success. Any other code = failure.
- Kubernetes does not treat the hook as failed if the HTTP server
  responds with 404 Not Found — make sure you specify the correct URI. 

**Which handler to use:**

| Situation | Handler |
|-----------|---------|
| Run a shell script or CLI command for cleanup | `exec` |
| Notify the app via its own HTTP API to begin shutdown | `httpGet` |
| Simple sleep for LB drain | `exec` |
| App has no shell — distroless image | `httpGet` |

#### `terminationGracePeriodSeconds` — The Shared Budget
```
terminationGracePeriodSeconds: 40
│
├── preStop runs         →  uses some of the budget (e.g. 5s)
│
└── SIGTERM handling     →  uses the remaining budget (e.g. 35s)
                              │
                              └── If combined > 40s → SIGKILL
```

If the terminationGracePeriodSeconds is 60, and the preStop hook takes
55 seconds to complete, and the container takes 10 seconds to stop normally
after receiving the signal, then the container will be killed before it can
stop normally, since 60 is less than the total time (55+10). 

**Rule:** set `terminationGracePeriodSeconds` to your measured
`preStop duration + SIGTERM handling time + 25% buffer`.

---



## Lab Step-by-Step Guide

---

### Step 1: Verify Your Cluster

```bash
kubectl get nodes
```

**Expected output:**
```
NAME        STATUS   ROLES           AGE   VERSION
3node       Ready    control-plane   1h    v1.34.0
3node-m02   Ready    <none>          1h    v1.34.0
3node-m03   Ready    <none>          1h    v1.34.0
```

> **Note:** Minikube does NOT apply a `NoSchedule` taint on the control plane
> node by default. All three nodes — including `3node` — can schedule workloads.
> This differs from kubeadm clusters where the control plane is tainted.

---

### Part 1: Pod Phase and Conditions

---

### Step 2: Understand the YAML

**01-phase-conditions-demo.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: phase-demo
spec:
  restartPolicy: Never           # Key: lets pod reach Completed/Error without restart
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "echo 'App started'; sleep 10; echo 'App done'"]
```

**Key YAML Fields Explained:**

- `restartPolicy: Never` — without this, pod exits and Kubelet restarts it
  immediately (`Always` is default value) . You would never see the `Completed` phase. `Never` is essential
  to observe the full phase lifecycle from Running to Completed.
- `command` — overrides busybox's default command. The container runs for 10
  seconds then exits with code 0 (success).

---

### Step 3: Watch All Phase Transitions and Conditions

Open two terminals side by side.

**Terminal 1 — watch all status changes:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply the pod & check condition:**
```bash
cd 01-pod-lifecycle-termination-errors/src

#Apply the pod
kubectl apply -f 01-phase-conditions-demo.yaml

#Check all 5 Pod Conditions - While Pod is still Running
kubectl get pod phase-demo -o yaml | grep -A 30 "conditions:"
```

**All 5 Pod Conditions - While Pod is still Running:**
```yaml
conditions:
- lastProbeTime: null
  lastTransitionTime: "2026-03-19T20:22:31Z"
  observedGeneration: 1
  status: "True"
  type: PodReadyToStartContainers    ← Sandbox + CNI ready (2s after scheduling)

- lastProbeTime: null
  lastTransitionTime: "2026-03-19T20:22:29Z"
  observedGeneration: 1
  status: "True"
  type: Initialized                  ← No init containers → True immediately

- lastProbeTime: null
  lastTransitionTime: "2026-03-19T20:22:31Z"
  observedGeneration: 1
  status: "True"
  type: Ready                        ← Pod in Service endpoints, traffic flows

- lastProbeTime: null
  lastTransitionTime: "2026-03-19T20:22:31Z"
  observedGeneration: 1
  status: "True"
  type: ContainersReady              ← All containers running + ready flag true

- lastProbeTime: null
  lastTransitionTime: "2026-03-19T20:22:29Z"
  observedGeneration: 1
  status: "True"
  type: PodScheduled                 ← Node assigned by scheduler
```

> **Note:** Array order in `.status.conditions[]` is not guaranteed.
> Always read `lastTransitionTime` to determine sequence — never assume
> position means order.


**All 5 Pod conditions Sequence — From Timestamps, Not Position:**
```
20:22:29  PodScheduled = True
          Initialized  = True    ← same second, no init containers → instant

          (2 seconds pass — image pull, sandbox creation, CNI setup)

20:22:31  PodReadyToStartContainers = True
          ContainersReady          = True    ← process started, no probe = ready immediately
          Ready                    = True    ← pod joins Service endpoints
```

**Status Changes : What you will observe in Terminal 1:**
```
NAME          READY   STATUS              RESTARTS   AGE
phase-demo    0/1     Pending             0          0s      ← Scheduler working
phase-demo    0/1     ContainerCreating   0          1s      ← Image pulling, sandbox creating
phase-demo    1/1     Running             0          3s      ← Process started + ready (no probe)
phase-demo    0/1     Completed           0          13s     ← sleep 10 finished, exit 0
```

Press `Ctrl+C` to stop watching.

> **Why does it show `1/1 Running` immediately without a probe?**
> No readiness probe is defined. Per official docs, when no readiness probe is
> configured, the default state is `Success` — the container is marked ready
> the instant the process starts.

---

### Step 4: Inspect All 5 Pod Conditions - After Pod is Completed

```bash
kubectl get pod phase-demo -o yaml | grep -A 30 "conditions:"
```

**All 5 Pod Conditions - After Pod is Completed**
```yaml
  conditions:
  - lastProbeTime: null
    lastTransitionTime: "2026-03-19T20:22:42Z"
    observedGeneration: 1
    status: "False"                   ← False because pod Completed
    type: PodReadyToStartContainers  

  - lastProbeTime: null
    lastTransitionTime: "2026-03-19T20:22:29Z"
    observedGeneration: 1
    reason: PodCompleted
    status: "True"
    type: Initialized                 

  - lastProbeTime: null
    lastTransitionTime: "2026-03-19T20:22:41Z"
    observedGeneration: 1
    reason: PodCompleted
    status: "False"                   ← False because pod Completed
    type: Ready

  - lastProbeTime: null
    lastTransitionTime: "2026-03-19T20:22:41Z"
    observedGeneration: 1
    reason: PodCompleted
    status: "False"                   ← False because pod Completed
    type: ContainersReady

  - lastProbeTime: null
    lastTransitionTime: "2026-03-19T20:22:29Z"
    observedGeneration: 1
    status: "True"
    type: PodScheduled                

```

> **Important — `lastTransitionTime` records the LAST flip, not the first.**
> `ContainersReady` was `True` while the container ran, then flipped to `False`
> when it completed. The timestamp shows when it last changed — not when the
> pod started.


#### The Conditions Reference

Based on your above output, here is the picture of conditions after
a pod completes with `restartPolicy: Never`:
```
Condition                    Status   Reason          What it means
──────────────────────────────────────────────────────────────────────────────
PodScheduled                 True     (none)          Pod assigned to node
Initialized                  True     PodCompleted    Init containers done
PodReadyToStartContainers    False    (none)          Sandbox torn down after exit
ContainersReady              False    PodCompleted    Container finished (not a failure)
Ready                        False    PodCompleted    No longer in LB (completed its job)
```
---

### Step 5: Check Container State Directly

```bash
kubectl get pod phase-demo -o jsonpath='{.status.containerStatuses[0].state}' | python3 -m json.tool
```

**Expected output:**
```json
{
    "terminated": {
        "containerID": "docker://3656280d159b51343649b1ee6f5e902a5c6e1f14802a433483934e1f1791a8f9",
        "exitCode": 0,
        "finishedAt": "2026-03-19T20:22:40Z",
        "reason": "Completed",
        "startedAt": "2026-03-19T20:22:30Z"
    }
}
```

The container state is `Terminated` with `exitCode: 0` and `reason: Completed`.
This is why `ContainersReady = False` — a terminated container is never ready.

```bash
# Also check the ready flag directly
kubectl get pod phase-demo -o jsonpath='{.status.containerStatuses[0].ready}'
# false
```

**Cleanup:**
```bash
kubectl delete -f 01-phase-conditions-demo.yaml
```

---

### Part 2: Pod Termination — Graceful Shutdown

### Step 7: Understanding the Demo — Graceful Shutdown of a Payment Service

#### What This Demo Simulates

This demo simulates a **payment service** that is processing a live transaction
when the pod is deleted. In production, abruptly killing a payment service
mid-transaction risks:

- Half-written database records
- Double charges (transaction retried by client after timeout)
- Orphaned locks in the payment gateway
- Client receiving no response

The YAML demonstrates both layers of Kubernetes graceful shutdown working
together — a `preStop` hook that drains the load balancer, and a SIGTERM
handler that completes the in-flight transaction before exiting.

#### Full Shutdown Sequence for This Demo
```
kubectl delete pod graceful-shutdown-demo
        │
        ① Pod marked Terminating in API server
          Pod IP removed from Service endpoints immediately
          (no new traffic will arrive from this point)
        │
        ② terminationGracePeriodSeconds: 40 countdown begins
        │
        ③ preStop hook fires:
          echo 'Draining connections...'; sleep 5
          ↑ 5 seconds — gives load balancer time to finish
            routing any requests that were already in-flight
            before the endpoint removal propagated
        │
        ④ preStop completes (5s elapsed of 40s budget)
        │
        ⑤ SIGTERM sent to PID 1 (/bin/sh)
          trap handler catches it:
          → echo 'SIGTERM received. Shutting down...'
          → sleep 3  (simulates completing current transaction)
          → echo 'Shutdown complete'
          → exit 0
        │
        ⑥ Container exits cleanly (exit code 0)
          Total time: ~8 seconds
          Well within the 40s budget
        │
   If NOT done within 40s:
        ⑦ SIGKILL → immediate death, no cleanup
```

#### YAML
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: graceful-shutdown-demo
spec:
  terminationGracePeriodSeconds: 40
  containers:
    - name: payment-service
      image: busybox:1.36
      lifecycle:
        preStop:
          exec:
            command: ["/bin/sh", "-c", "echo 'Draining connections...'; sleep 5"]
      command:
        - /bin/sh
        - -c
        - |
          trap 'echo SIGTERM received. Shutting down...; sleep 3; echo Shutdown complete; exit 0' TERM
          echo "Payment service started"
          while true; do sleep 1; done
```

**`terminationGracePeriodSeconds: 40`**
Pod-level field under `spec`. Total shutdown budget for preStop + SIGTERM
handling combined. Set to 40 because this payment service needs up to 35
seconds in a real scenario (5s preStop LB drain + up to 30s transaction
completion). The extra 5 seconds is the safety buffer.

**`lifecycle.preStop.exec`**
Runs inside this container before SIGTERM is sent. The `sleep 5` simulates
waiting for the load balancer endpoint removal to propagate across all
upstream nodes. Without this, the LB may still route 1–2 new requests to
this pod after Kubernetes removes it from endpoints — the 5-second window
absorbs that propagation delay. See *Concept C* for full preStop behaviour.

**`trap '...' TERM`**
Registers a SIGTERM signal handler on the shell (PID 1). Without `trap`,
the shell would exit immediately when SIGTERM arrives. With it, the shell
runs the cleanup block first. The `sleep 3` represents completing the
in-flight payment transaction. See *Concept A* for signals and *Concept B*
for why PID 1 matters here.

**`while true; do sleep 1; done`**
Keeps PID 1 alive and in a signal-interruptible state. The `sleep 1` loop
wakes up every second to check for pending signals. When SIGTERM arrives
during a `sleep`, the shell wakes, sees the signal, and runs the trap handler.



### Step 8: Demo Graceful Shutdown

**Terminal 1 — watch the pod:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply:**
```bash
kubectl apply -f 02-graceful-shutdown.yaml
```

**Terminal 3 — watch for logs:**
```bash
kubectl logs -f graceful-shutdown-demo
```

**Terminal 2 — delete:**
```bash
# Wait for Running state, then delete
kubectl delete pod graceful-shutdown-demo
```

**Expected output in Terminal 1: Status**
```
NAME                     READY   STATUS    RESTARTS   AGE
graceful-shutdown-demo   0/1     Pending   0          0s
graceful-shutdown-demo   0/1     Pending   0          0s
graceful-shutdown-demo   0/1     ContainerCreating   0          0s
graceful-shutdown-demo   1/1     Running             0          2s
graceful-shutdown-demo   1/1     Terminating         0          14s  ← delete issued
graceful-shutdown-demo   1/1     Terminating         0          14s
graceful-shutdown-demo   0/1     Completed           0          22s  ← container exited
graceful-shutdown-demo   0/1     Completed           0          22s
graceful-shutdown-demo   0/1     Completed           0          22s
```


**Shutdown Timeline:**
```bash
0s   → Pod created
2s   → Running (container started)
14s  → kubectl delete issued
       ① Pod marked Terminating in API server
       ② Pod IP removed from Service endpoints
       ③ terminationGracePeriodSeconds: 40 countdown begins
       ④ preStop fires: sleep 5
14s–19s → preStop running (READY still 1/1 — container alive)
19s  → preStop completes
       ⑤ SIGTERM sent to PID 1
       ⑥ trap handler: sleep 3
19s–22s → trap handler running (READY still 1/1)
22s  → exit 0
       ⑦ Container exits → READY drops to 0/1
       ⑧ STATUS → Completed
       Total shutdown time: 8 seconds (well within 40s budget)
```


**Expected output in Terminal 3: Logs**
```
Payment service started
SIGTERM received. Shutting down...
Shutdown complete
```

> **The log proves** the application received SIGTERM, handled it gracefully,
> and exited cleanly. Without the trap handler, the process would exit
> immediately when SIGTERM arrived — no cleanup.

**Check exit code was 0 (clean exit):**
```bash
kubectl get pod graceful-shutdown-demo \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}' \
  | python3 -m json.tool
```

> **Note:** If the pod is already deleted from the API server this command
> returns empty. Run it immediately after deletion or while the pod is still
> in `Terminating` state.


---

### Step 9: Compare Force Delete


**Terminal 1 — watch the pod:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply:**
```bash
kubectl apply -f 02-graceful-shutdown.yaml
```

**Terminal 3 — watch for logs:**
```bash
kubectl logs -f graceful-shutdown-demo
```

**Terminal 2 — delete:**
```bash
# Wait for Running state, then force delete
kubectl delete pod graceful-shutdown-demo --force --grace-period=0
```

**Check immediately:**
```bash
kubectl get pods
# Pod is already gone from API server — but the container may still be
# shutting down on the node (kubelet handles the actual cleanup)
```

#### Expected Outputs

**Terminal 2 — delete confirmation:**
```
Warning: Immediate deletion does not wait for confirmation that the running
resource has been terminated. The resource may continue to run on the cluster
indefinitely.
pod "graceful-shutdown-demo" force deleted
```

**Terminal 1 — Status:**
```bash
NAME                     READY   STATUS              RESTARTS   AGE
graceful-shutdown-demo   0/1     Pending             0          0s
graceful-shutdown-demo   0/1     Pending             0          0s
graceful-shutdown-demo   0/1     ContainerCreating   0          0s
graceful-shutdown-demo   1/1     Running             0          1s
graceful-shutdown-demo   1/1     Terminating         0          41s
graceful-shutdown-demo   1/1     Terminating         0          41s
← watch stream ends here — pod object deleted from API server
  no Completed line — the object is gone before the container exits
```

**Terminal 3 — Logs:**
```bash
Payment service started
SIGTERM received. Shutting down...
← stops here — "Shutdown complete" never appears
   SIGKILL arrived before the 3-second trap handler sleep finished
```

#### Comparing Graceful Delete vs Force Delete
```bash
                      Graceful delete         Force delete
                      ─────────────────────   ──────────────────────────────
preStop hook          ✅ Runs (5s sleep)       ❌ Skipped entirely
SIGTERM sent          ✅ Yes                   ✅ Yes — still sent
SIGKILL timing        After grace period       Almost immediately after SIGTERM
                      (40s in our YAML)
Trap handler result   ✅ Runs to completion    ❌ Cut off mid-execution
                      "Shutdown complete"      SIGKILL kills it during sleep 3
Watch stream          Shows Completed         Ends at Terminating
                                              (object deleted before exit)
Log output            Full 3 lines            2 lines — truncated by SIGKILL
Total time            ~8 seconds              ~1–2 seconds
```


#### What `--force --grace-period=0` Actually Does


- `--force` → pod object removed from API server immediately
- `--grace-period=0` → SIGTERM is sent, then SIGKILL follows almost immediately — not after waiting `terminationGracePeriodSeconds`
- `preStop` hook → **is skipped**
- The net result: cleanup logic that takes more than a fraction of a second is cut off

```bash
--force --grace-period=0
        │
        ├── Pod OBJECT deleted from API server immediately
        │   (no longer visible in kubectl get pods)
        │
        ├── preStop hook SKIPPED
        │   (confirmed by experiment — no preStop output in logs)
        │
        ├── SIGTERM sent to PID 1
        │   (confirmed by experiment — trap handler ran and printed output)
        │
        └── SIGKILL follows almost immediately
            (confirmed by experiment — trap handler cut off mid-execution)
```
> ⚠️ Forced deletions can be potentially disruptive for some workloads and their Pods.  Use only for pods stuck in `Terminating` state that will not terminate on their own. Never in normal operations.

---


### Part 3: Restart Policies

### Step 10: Understand Restart Policy Rules

Restart policy is a **pod-level** setting — applies to ALL containers in the pod.

```
┌────────────────┬────────────────────────────────┬──────────────────────────┐
│ Policy         │ Behavior                       │ Default For              │
├────────────────┼────────────────────────────────┼──────────────────────────┤
│ Always         │ Restart regardless of exit code │ Deployments, StatefulSets│
│                │ (exit 0 OR non-zero)            │ DaemonSets, manual pods  │
├────────────────┼────────────────────────────────┼──────────────────────────┤
│ OnFailure      │ Restart ONLY on non-zero exit   │ Jobs, CronJobs           │
│                │ Exit 0 → stays Completed        │                          │
├────────────────┼────────────────────────────────┼──────────────────────────┤
│ Never          │ Never restart                   │ No object (manual only)  │
│                │ Exit 0 → Completed              │                          │
│                │ Non-zero → Error                │                          │
└────────────────┴────────────────────────────────┴──────────────────────────┘
```

**Exit codes:**
- `0` — success (container completed its job)
- Non-zero (1, 2, 127...) — failure
- `137` — killed by SIGKILL (OOMKilled or force delete)
- `143` — killed by SIGTERM (graceful termination)

---

### Step 11: Observe restartPolicy: Always (Default)

**03-restart-policy-always.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: restart-always-demo
spec:
  restartPolicy: Always       # Default — can be omitted, shown explicitly for clarity
  containers:
    - name: nginx
      image: nginx:1.27
      ports:
        - containerPort: 80
```

**Terminal 1 — watch the pod:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply:**
```bash
kubectl apply -f 03-restart-policy-always.yaml
```


**Terminal 1 — Status:**
```
NAME                  READY   STATUS            RESTARTS   AGE
restart-always-demo   0/1     Pending             0          0s
restart-always-demo   0/1     Pending             0          0s
restart-always-demo   0/1     ContainerCreating   0          0s
restart-always-demo   1/1     Running             0          12s
```

Now kill the busybox process inside the container to simulate a crash:

**Terminal 2 — kill the busybox process:**
```bash
kubectl exec restart-always-demo -- nginx -s quit
```


**Terminal 1 — Status:**
```
NAME                  READY   STATUS          RESTARTS   AGE
restart-always-demo   0/1     Pending             0          0s
restart-always-demo   0/1     Pending             0          0s
restart-always-demo   0/1     ContainerCreating   0          0s
restart-always-demo   1/1     Running             0          12s
restart-always-demo   0/1     Completed           0          55s  ← nginx exited
restart-always-demo   1/1     Running             1 (2s ago) 56s   ← Kubelet restarted it!
```


The RESTARTS counter is now `1`. Kubelet restarted the container because
`restartPolicy: Always` restarts on ANY exit, including exit code 0.


**Cleanup:**
```bash
kubectl delete -f 03-restart-policy-always.yaml
```

---

### Step 12: Observe restartPolicy: OnFailure

**04-restart-policy-onfailure.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: restart-onfailure-demo
spec:
  restartPolicy: OnFailure     # Restart only if exit code is non-zero
  containers:
    - name: csv-processor
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "Processing CSV file..."
          sleep 5
          echo "Processing complete"
          exit 0               # Simulates a successful batch job completion
```


**Terminal 1 — watch the pod:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply:**
```bash
kubectl apply -f 04-restart-policy-onfailure.yaml
```


**Terminal 1 — Status:**
```
NAME                     READY   STATUS           RESTARTS   AGE
restart-onfailure-demo   0/1     Pending             0          0s
restart-onfailure-demo   0/1     Pending             0          0s
restart-onfailure-demo   0/1     ContainerCreating   0          0s
restart-onfailure-demo   1/1     Running             0          1s
restart-onfailure-demo   0/1     Completed           0          7s
restart-onfailure-demo   0/1     Completed           0          8s
```

RESTARTS stays at `0`. The job completed successfully and Kubelet did NOT
restart it — which is exactly what you want for a batch job.


**Terminal 2 - Now test with a failure — edit the exit code:**
```bash
kubectl delete -f 04-restart-policy-onfailure.yaml

# Temporarily change exit 0 to exit 1 in the file, then apply

kubectl apply -f 04-restart-policy-onfailure.yaml
```



**Terminal 1 — Status:**
```
```
NAME                     READY   STATUS              RESTARTS       AGE
restart-onfailure-demo   0/1     Pending             0              0s
restart-onfailure-demo   0/1     Pending             0              0s
restart-onfailure-demo   0/1     ContainerCreating   0              0s
restart-onfailure-demo   1/1     Running             0              1s    ← Attempt 0 running
restart-onfailure-demo   0/1     Error               0              6s    ← Attempt 0 FAILED (exit 1)

restart-onfailure-demo   1/1     Running             1 (2s ago)     7s    ← Attempt 1 running
restart-onfailure-demo   0/1     Error               1 (7s ago)     12s   ← Attempt 1 FAILED (exit 1)
restart-onfailure-demo   0/1     CrashLoopBackOff    1 (13s ago)    24s   ← backoff wait ~10s (next retry in ~10s)

restart-onfailure-demo   1/1     Running             2 (14s ago)    25s   ← Attempt 2 running
restart-onfailure-demo   0/1     Error               2 (19s ago)    30s   ← Attempt 2 FAILED (exit 1)
restart-onfailure-demo   0/1     CrashLoopBackOff    2 (12s ago)    41s   ← backoff wait ~20s (next retry in ~15s)

restart-onfailure-demo   1/1     Running             3 (27s ago)    56s   ← Attempt 3 running
restart-onfailure-demo   0/1     Error               3 (32s ago)    61s   ← Attempt 3 FAILED (exit 1)
restart-onfailure-demo   0/1     CrashLoopBackOff    3 (12s ago)    72s   ← backoff wait ~40s (next retry in ~38s)

restart-onfailure-demo   1/1     Running             4 (50s ago)    110s  ← Attempt 4 running
restart-onfailure-demo   0/1     Error               4 (55s ago)    115s  ← Attempt 4 FAILED (exit 1)
restart-onfailure-demo   0/1     CrashLoopBackOff    4 (14s ago)    2m8s  ← backoff wait ~80s (next retry in ~81s)

restart-onfailure-demo   1/1     Running             5 (95s ago)    3m29s ← Attempt 5 running
restart-onfailure-demo   0/1     Error               5 (100s ago)   3m34s ← Attempt 5 FAILED (exit 1)
restart-onfailure-demo   0/1     CrashLoopBackOff    5 (12s ago)    3m45s ← backoff wait ~160s (continuing...)
```
```

>The pod is stuck in `Error → restart → Error` loop because exit code is non-zero and `restartPolicy: OnFailure` keeps retrying.

>Also the kubelet introduces an exponential back-off delay between restart attempts — starting at 10 seconds and capped at five minutes. During this waiting period, the pod's status shows as CrashLoopBackOff.

>So CrashLoopBackOff is not a final stuck state — it is the waiting period between restart attempts. Your output shows exactly this:


**Reading the RESTARTS Column**

One point worth noting here — the RESTARTS column value and the attempt number are offset by one:
```
RESTARTS = 0  →  Attempt 0  (first run, no restarts yet)
RESTARTS = 1  →  Attempt 1  (first restart — kubelet tried once more)
RESTARTS = 2  →  Attempt 2  (second restart)
RESTARTS = n  →  Attempt n  (nth restart)
```

**What this output tells us — reading the backoff pattern:**
```
RESTART   Error→CrashLB   CrashLB→Running   Total wait (Error→Running)
────────────────────────────────────────────────────────────────────────
1         ~12s             ~1s               ~18s
2         ~11s             ~15s              ~31s
3         ~11s             ~38s              ~54s
4         ~13s             ~81s              ~99s
5         ~11s             still running...
```

Two distinct timers are visible:

**Timer 1 — Error → CrashLoopBackOff (~10–13s, stays constant)**
This is NOT the backoff. This is kubelet's container exit detection
time — the time between the container process exiting and kubelet
registering the failure state. It stays roughly constant because it is
just process exit + kubelet status sync. It is not affected by the
backoff algorithm.

**Timer 2 — CrashLoopBackOff → Running (increases each cycle)**
This IS the actual backoff wait. Kubelet holds the container in
`CrashLoopBackOff` display state for the full backoff duration before
attempting the next restart. This is what doubles each cycle:
```
~1s  →  ~15s  →  ~38s  →  ~81s  →  ...
```

The `CrashLoopBackOff` label in STATUS is the **waiting room display**.
The container is not broken in a new way — kubelet is intentionally
delaying the next restart attempt to protect cluster resources.


**Cleanup:**
```bash
kubectl delete -f 04-restart-policy-onfailure.yaml
```

---

### Step 13: Observe restartPolicy: Never (Diagnostic)

**05-restart-policy-never.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: restart-never-demo
spec:
  restartPolicy: Never         # Never restart — stay in Completed or Error
  containers:
    - name: diagnostic
      image: busybox:1.36
      command: ["sh", "-c", "echo 'Diagnostic complete'; exit 0"]
```

**Terminal 1 — watch the pod:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply:**
```bash
kubectl apply -f 05-restart-policy-never.yaml
```


**Terminal 1 — Status:**
```
NAME                READY     STATUS          RESTARTS   AGE
restart-never-demo   0/1     Pending             0          0s
restart-never-demo   0/1     Pending             0          0s
restart-never-demo   0/1     ContainerCreating   0          0s
restart-never-demo   0/1     Completed           0          1s
restart-never-demo   0/1     Completed           0          2s ← stays here, no restart
```

RESTARTS stays `0`, pod stays `Completed`. It never restarts even though
Kubelet sees it exited.

> **Real-world use of Never:** When a Job is crashing and you can't read its
> logs because it keeps restarting into CrashLoopBackOff, change the policy
> to `Never`. The pod stays in `Error` state and you can `kubectl logs` at
> your leisure to diagnose the problem.

**Cleanup:**
```bash
kubectl delete -f 05-restart-policy-never.yaml
```

---

### Part 4: Image Pull Policies

---

### Step 14: Understand Image Pull Policy Rules

Image pull policy is a **container-level** setting — each container can have
a different policy.

```
┌──────────────────────────────────────────────────────────────────────┐
│               imagePullPolicy DEFAULT RULES                          │
│                                                                      │
│  busybox                  → Always        (no tag = :latest implied) │
│  busybox:latest           → Always                                   │
│  busybox:1.36             → IfNotPresent  (specific version tag)     │
│  my-app:v1.2.3            → IfNotPresent  (specific version tag)     │
└──────────────────────────────────────────────────────────────────────┘
```

**The tag collision problem — why IfNotPresent can be risky:**
```
Developer A pushes my-app:v1.0.1  ← contains Feature A code
Developer B pushes my-app:v1.0.1  ← OVERWRITES with different code!

Node 1 pulled A's image → runs Feature A code
Node 2 pulled B's image → runs different code

Same deployment, different behavior across nodes!
```

**Solution:** Enforce in CI/CD — never allow overwriting an existing tag.
Use immutable tags based on git SHA: `my-app:1.0.1-abc1234`.

---

### Step 15: Deploy with Different Pull Policies

**06-image-pull-policy.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pull-policy-demo
spec:
  restartPolicy: Never
  containers:
    - name: dev-container
      image: busybox:latest        # Development: always pull latest
      imagePullPolicy: Always    # Explicitly set — matches default for :latest
      command: ["sh", "-c", "echo 'Dev container started'; sleep 5"]

    - name: prod-container
      image: busybox:1.36          # Production: pinned version
      imagePullPolicy: IfNotPresent  # Use cached if available — bandwidth efficient
      command: ["sh", "-c", "echo 'Prod container started'; sleep 5"]
```

**Key YAML Fields Explained:**

- `imagePullPolicy` is under `spec.containers[]` — container level, not pod level
- `Always` — pulls from registry every time the container starts. Guarantees
  freshest image. Correct for development but wrong for production (you don't
  know what version you're actually running).
- `IfNotPresent` — uses the image cached on the node if available. Only pulls
  if the image is not present on that node. Bandwidth-efficient and stable
  for production with pinned tags.
- `Never` — never pulls. Pod fails if image is not pre-loaded on the node.
  Used in air-gapped (internet-isolated) environments.

```bash
kubectl apply -f 06-image-pull-policy.yaml
kubectl describe pod pull-policy-demo | grep -A 2 "Pull"
```

**Expected output in Events section:**
```
Pulling image "busybox:latest"         ← Always: pulled even if cached
Pulled image "busybox:latest"
Pulling image "busybox:1.36"           ← IfNotPresent: pulled only because not cached yet
Pulled image "busybox:1.36"
```

On subsequent pod restarts (or on a node that already has the image), `Always`
would pull again while `IfNotPresent` would skip the pull.

**Cleanup:**
```bash
kubectl delete -f 06-image-pull-policy.yaml
```

---

### Part 5: Common Pod Errors

---

### Step 16: Trigger ErrImagePull → ImagePullBackOff

**07-error-imagepull.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: error-imagepull-demo
spec:
  restartPolicy: Never
  containers:
    - name: app
      image: busybox:99.99.99      # This version does not exist on Docker Hub
```

```bash
kubectl apply -f 07-error-imagepull.yaml
kubectl get pods -w
```

**Expected output:**
```
NAME                    READY   STATUS         RESTARTS   AGE
error-imagepull-demo    0/1     ErrImagePull   0          5s    ← first failure
error-imagepull-demo    0/1     ErrImagePull   0          10s
error-imagepull-demo    0/1     ImagePullBackOff 0        20s   ← exponential backoff starts
```

**Why two different statuses?**
`ErrImagePull` is the first failure. After repeated failures, Kubernetes
applies exponential backoff (10s → 20s → 40s...) and reports
`ImagePullBackOff` to show it is backing off. Same root cause — different stage.

**Debug it:**
```bash
kubectl describe pod error-imagepull-demo
```

**Look for the Events section at the bottom:**
```
Events:
  Warning  Failed     5s    kubelet  Failed to pull image "busybox:99.99.99":
                                     rpc error: ... manifest for busybox:99.99.99
                                     not found in registry
  Warning  Failed     5s    kubelet  Error: ErrImagePull
  Warning  BackOff    2s    kubelet  Back-off pulling image "busybox:99.99.99"
```

The event message tells you exactly what is wrong — the image tag does not
exist in the registry. No need to guess.

**Cleanup:**
```bash
kubectl delete -f 07-error-imagepull.yaml
```

---

### Step 17: Trigger OOMKilled → CrashLoopBackOff

#### What This Demo Shows

A container that exceeds its memory limit is killed by the **Linux kernel OOM
(Out Of Memory) killer** — not by Kubernetes, not by kubelet. The kernel sends
SIGKILL directly to the process the moment it tries to allocate memory beyond
the container's cgroup memory limit.

Without memory limits, a memory-leaking container can consume all available
node memory — starving and crashing every other pod on the same node. Memory
limits are not optional in production.

> **Who kills the container — Kubernetes or the kernel?**
> The Linux kernel OOM killer kills the process directly with SIGKILL.
> Kubernetes does not initiate the kill — it detects the termination, reads
> the cgroup memory event, and records the reason as `OOMKilled`. No preStop
> hook, no SIGTERM, no graceful shutdown — the process is gone instantly.

#### YAML
```yaml
# 08-error-oomkilled.yaml
apiVersion: v1
kind: Pod
metadata:
  name: oomkilled-demo
spec:
  restartPolicy: Always
  containers:
    - name: memory-hog
      image: polinux/stress          # Purpose-built stress tool — used in official K8s docs
      command: ["stress"]
      args:
        - --vm                       # Start 1 virtual memory worker
        - "1"
        - --vm-bytes                 # Worker allocates 20MB — double the 10Mi limit
        - "20M"
        - --vm-hang                  # Hold the allocation — do not free and reallocate
        - "60"                       # Hold for 60 seconds
      resources:
        requests:
          memory: "5Mi"
          cpu: "50m"
        limits:
          memory: "10Mi"             # Hard cap — stress tries 20M → kernel OOM kills it
          cpu: "100m"
```

**Key YAML Fields Explained:**

- `polinux/stress` — purpose-built memory and CPU stress tool. This is the
  exact image the official Kubernetes documentation uses to demonstrate memory
  limits and OOMKilled behaviour.
- `--vm 1` — start 1 virtual memory worker process
- `--vm-bytes 20M` — worker attempts to allocate 20MB of RAM — double the limit
- `--vm-hang 60` — hold the allocation for 60 seconds instead of freeing and
  reallocating. Without `--vm-hang`, stress frees and reallocates in a loop —
  OOMKill timing becomes inconsistent. With it, OOMKill triggers reliably
  within 2–3 seconds of the container starting.
- `memory limits: 10Mi` — the hard ceiling. The Linux kernel OOM killer sends
  SIGKILL the moment stress tries to hold 20MB against a 10Mi cgroup limit.
- `memory requests: 5Mi` — what the scheduler reserves on the node for
  placement decisions. The limit is the runtime enforcement ceiling.

#### Deploy and Observe

**Terminal 1 — watch status:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply:**
```bash
kubectl apply -f 08-error-oomkilled.yaml
```

**Terminal 1 — Expected output:**
```
NAME             READY   STATUS              RESTARTS       AGE
oomkilled-demo   0/1     Pending             0              0s
oomkilled-demo   0/1     Pending             0              0s
oomkilled-demo   0/1     ContainerCreating   0              0s
oomkilled-demo   0/1     OOMKilled           0              4s    ← Attempt 0: killed by kernel
oomkilled-demo   1/1     Running             1 (2s ago)     5s    ← Attempt 1: running
oomkilled-demo   0/1     OOMKilled           1 (3s ago)     6s    ← Attempt 1: killed instantly
oomkilled-demo   0/1     CrashLoopBackOff    1 (2s ago)     7s    ← waiting ~10s before retry

oomkilled-demo   0/1     OOMKilled           2 (16s ago)    21s   ← Attempt 2: killed
oomkilled-demo   0/1     CrashLoopBackOff    2 (12s ago)    32s   ← waiting ~20s before retry

oomkilled-demo   0/1     OOMKilled           3 (26s ago)    46s   ← Attempt 3: killed
oomkilled-demo   0/1     CrashLoopBackOff    3 (1s ago)     47s   ← waiting ~40s before retry

oomkilled-demo   0/1     OOMKilled           4              90s   ← Attempt 4: killed
oomkilled-demo   0/1     CrashLoopBackOff    4 (13s ago)    102s  ← waiting ~80s before retry

oomkilled-demo   0/1     OOMKilled           5 (90s ago)    2m59s ← Attempt 5: killed
oomkilled-demo   0/1     CrashLoopBackOff    5 (11s ago)    3m9s  ← waiting ~160s before retry
```

**What this output tells us — four observations:**

**Observation 1 — `OOMKilled` directly, not `Error`**

The status goes directly to `OOMKilled` — never through `Error`. This is
because the kernel sends SIGKILL directly and Kubernetes maps it to its own
distinct status label using cgroup memory events — not the generic `Error`
label used for non-zero exits from application code.
```
Application crash (exit 1)   →  Error      →  CrashLoopBackOff
OOM kill (kernel SIGKILL)    →  OOMKilled  →  CrashLoopBackOff
```

**Observation 2 — `Running` state disappears after restart 1**

Attempt 0 and 1 briefly show a `Running` line. From restart 2 onwards,
`Running` is no longer visible — only `OOMKilled` and `CrashLoopBackOff`
appear. The container is killed so quickly (~2s) that the watch stream
misses the `Running` transition entirely. The container ran — the watch
just could not capture it within its polling interval.

**Observation 3 — Same two-timer pattern as Step 12**
```
RESTART   OOMKilled→CrashLB   CrashLB→OOMKilled   Backoff wait
──────────────────────────────────────────────────────────────────
1         ~1s                  ~15s                ~10s
2         ~11s                 ~14s                ~20s
3         ~1s                  ~43s                ~40s
4         ~12s                 ~57s                ~80s
5         ~10s                 ~109s               ~160s
```

- `OOMKilled → CrashLoopBackOff` (~10s, constant) — kubelet detection time,
  not the backoff. Stays constant across all restarts.
- `CrashLoopBackOff → OOMKilled` (doubles each cycle) — the actual backoff
  wait. This is what increases.

**Observation 4 — READY column stays `0/1` throughout**

Unlike Step 12 (`restartPolicy: OnFailure`, exit 1) where `Running` briefly
showed `1/1`, here READY never reaches `1/1` after restart 1. The container
is killed before kubelet can mark it ready — the process dies in ~2 seconds,
faster than kubelet's readiness check cycle.

#### Verify OOMKilled
```bash
kubectl describe pod oomkilled-demo
```

**Look for in the Containers section:**
```
Last State:  Terminated
  Reason:    OOMKilled       ← set by Kubernetes from cgroup memory events
  Exit Code: 1               ← varies by container runtime (see note below)
```
```bash
# Primary check — reason is set by Kubernetes from cgroup events
# This is the reliable indicator regardless of container runtime
kubectl get pod oomkilled-demo \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
# OOMKilled ✅

# Secondary check — exit code varies by runtime
kubectl get pod oomkilled-demo \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'
# 137 on containerd runtime
# 1   on Docker runtime (as seen in this cluster)
```

> **Why exit code varies by runtime:**
> The `reason: OOMKilled` field is set by Kubernetes independently, by
> reading cgroup memory limit events — it does not depend on the exit code.
> The exit code comes from how the container runtime reports the process
> termination. `containerd` typically reports `137` (128 + SIGKILL signal 9).
> Docker runtime may report the stress tool's own exit code (`1`) depending
> on how it handles the kernel signal internally.
> **Always check `reason` first. Exit code is secondary confirmation.**

> **Exit code 137 — the theory:**
> In Unix/Linux, when a process is terminated by a signal, its exit code
> equals 128 plus the signal number. SIGKILL is signal 9, therefore the
> expected exit code is 128 + 9 = 137. In practice the reported exit code
> depends on the container runtime as shown above.

#### Cleanup
```bash
kubectl delete -f 08-error-oomkilled.yaml
```

---

### Step 18: CrashLoopBackOff — What It Actually Is

`CrashLoopBackOff` is frequently misread as a final error state. It is not.

**`CrashLoopBackOff` is the status label shown during the backoff waiting
period between restart attempts.** The container is not stuck — kubelet is
intentionally delaying the next restart to protect cluster resources from a
rapidly failing container consuming CPU in a tight restart loop.

This lab has already produced two real cases of `CrashLoopBackOff`. Reading
them side by side makes the mechanism precise.

#### Case 1 — Step 12: restartPolicy OnFailure, exit 1 (application crash)
```
Running      0    1s    ← Attempt 0 running
Error        0    6s    ← Attempt 0 FAILED (exit 1)

Running      1    7s    ← Attempt 1 running
Error        1   12s    ← Attempt 1 FAILED (exit 1)
CrashLoopBackOff 1 24s ← waiting ~10s before retry

Running      2   25s    ← Attempt 2 running
Error        2   30s    ← Attempt 2 FAILED (exit 1)
CrashLoopBackOff 2 41s ← waiting ~20s before retry
...
```

Cycle: `Running → Error → CrashLoopBackOff → Running → ...`

#### Case 2 — Step 17: restartPolicy Always, OOMKilled (kernel kill)
```
OOMKilled    0    4s    ← Attempt 0 killed by kernel
Running      1    5s    ← Attempt 1 running (briefly)
OOMKilled    1    6s    ← Attempt 1 killed instantly
CrashLoopBackOff 1 7s  ← waiting ~10s before retry

OOMKilled    2   21s    ← Attempt 2 killed (Running not visible)
CrashLoopBackOff 2 32s ← waiting ~20s before retry
...
```

Cycle: `OOMKilled → CrashLoopBackOff → OOMKilled → ...`

#### What the Two Cases Tell Us
```
                      Case 1 (exit 1)         Case 2 (OOMKilled)
                      ──────────────────────  ──────────────────────
Status before CrashLB Error                  OOMKilled
Running visible?      Yes — 1/1 briefly       Only on attempt 1
                                              Too fast after that
Exit code             1 (non-zero)            1 or 137 (runtime-dependent)
Reason field          (absent — just Error)   OOMKilled
restartPolicy         OnFailure               Always
Backoff pattern       Same doubling sequence  Same doubling sequence
```

Both cases share the **identical backoff mechanism** — only the triggering
condition and the status label before `CrashLoopBackOff` differ.

#### The Cycle — What Actually Happens
```
Container exits (any non-zero, or any exit with restartPolicy: Always)
        │
        ▼  ~10s (kubelet detects exit, registers failure)
CrashLoopBackOff  ← STATUS label shown during backoff wait
        │
        ▼  backoff period expires
Running           ← kubelet attempts the next restart
        │
        ├── runs long enough → stays Running, backoff resets
        └── fails again → Error/OOMKilled → CrashLoopBackOff
                          with longer wait next time
```

#### Two Timers — Both Cases Show the Same Pattern
```
Timer 1: Error/OOMKilled → CrashLoopBackOff   (~10s, CONSTANT)
         Not the backoff. This is kubelet's container exit
         detection and status sync time. Constant across all
         restarts regardless of backoff iteration.

Timer 2: CrashLoopBackOff → Running/OOMKilled  (DOUBLES each cycle)
         This IS the actual backoff wait.
         Kubelet holds the pod in CrashLoopBackOff for this
         duration before attempting the next restart.
```

#### Backoff Timer Sequence
```
Restart 1  →  backoff  10s  →  CrashLoopBackOff
Restart 2  →  backoff  20s  →  CrashLoopBackOff
Restart 3  →  backoff  40s  →  CrashLoopBackOff
Restart 4  →  backoff  80s  →  CrashLoopBackOff
Restart 5  →  backoff 160s  →  CrashLoopBackOff
Restart 6+ →  backoff 300s  →  CrashLoopBackOff (capped at 5 min, stays here)
```

> **Backoff reset:** If the container runs successfully for 10 minutes,
> the backoff resets to 10s — any new crash is treated as the first.

#### Which restartPolicy Enters CrashLoopBackOff
```
restartPolicy: Always    + any exit         →  CrashLoopBackOff ✅
restartPolicy: OnFailure + non-zero exit    →  CrashLoopBackOff ✅
restartPolicy: OnFailure + exit 0           →  Completed (no restart) ❌
restartPolicy: Never     + any exit         →  Completed or Error ❌
                                               (never restarts, no backoff)
```

> **`CrashLoopBackOff` with exit 0 and `restartPolicy: Always`:**
> A container that exits with code 0 repeatedly and quickly will also enter
> `CrashLoopBackOff`. Kubelet treats any rapid repeated exit as instability —
> regardless of exit code. This is why long-running services (web servers,
> APIs) should never exit with code 0 during normal operation. If they do,
> it signals to Kubernetes that something is wrong — and kubelet responds
> with the same backoff mechanism.

#### `CrashLoopBackOff` Is a Symptom — The Root Cause Is Always Underneath

Common causes:
- Application code bug or panic on startup
- Missing required environment variable or ConfigMap
- OOMKilled — memory limit too low or memory leak
- Liveness probe misconfigured — killing healthy container
- Missing dependency — trying to connect to a service that does not exist
- Container exits too quickly — main process completes and exits (wrong image
  or missing long-running command)

Debug sequence:
```bash
# 1. What did the container print before crashing?
kubectl logs <pod> --previous

# 2. What was the exit reason and code?
kubectl get pod <pod> \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' \
  | python3 -m json.tool

# 3. What does Kubernetes report?
kubectl describe pod <pod>
# Look for: "Back-off restarting failed container" in Events section
# Look for: OOMKilled in Last State section
```
---

### Step 19: Full Debug Workflow

When you encounter any pod error, follow this sequence:

```bash
# 1. What is the STATUS and RESTARTS count?
kubectl get pod <pod-name>

# 2. What happened? Check Events at the bottom (most useful)
kubectl describe pod <pod-name>

# 3. What did the application output?
kubectl logs <pod-name>

# 4. If it crashed and restarted — check PREVIOUS container's logs
kubectl logs <pod-name> --previous

# 5. Cluster-wide recent events (sorted newest first)
kubectl get events --sort-by='.lastTimestamp'

# 6. If you need to get inside a running container
kubectl exec -it <pod-name> -- /bin/sh

# 7. Check specific container status fields
kubectl get pod <pod-name> \
  -o jsonpath='{.status.containerStatuses[0].state}'

kubectl get pod <pod-name> \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
```

---

### Step 20: Final Cleanup

```bash
# Delete everything from this lab
kubectl delete pods --all

# Verify
kubectl get pods
# No resources found in default namespace.
```

---

## Experiments to Try

1. **Observe `lastTransitionTime` meaning:**
   ```bash
   # Create a pod that runs for 2 minutes
   kubectl run long-runner --image=busybox:1.36 --restart=Never \
     -- sh -c "sleep 120"
   
   kubectl get pod long-runner -o yaml | grep -A5 "ContainersReady"
   # Note the lastTransitionTime
   
   # Wait for it to complete (2 min)
   kubectl get pod long-runner -o yaml | grep -A5 "ContainersReady"
   # lastTransitionTime changed — shows when it last FLIPPED, not when pod started
   ```

2. **Force vs graceful delete timing:**
   ```bash
   kubectl run sleeper --image=busybox:1.36 -- sleep 3600
   
   # Measure graceful delete time
   time kubectl delete pod sleeper
   # Should take ~30 seconds (default grace period)
   
   kubectl run sleeper --image=busybox:1.36 -- sleep 3600
   
   # Measure force delete time
   time kubectl delete pod sleeper --force --grace-period=0
   # Should be near instant
   ```

---

## Common Questions

### Q: When should I use `--force --grace-period=0`?

**A:** Only for pods that are stuck in `Terminating` state and won't terminate
after the grace period. It removes the pod object from the API server
immediately but kubelet still cleans up the container on the node. Never use
it in normal operations — it risks leaving in-flight work (open DB transactions,
unacknowledged queue messages) in an inconsistent state.

### Q: If `restartPolicy: Always` restarts even on exit 0, how do Deployments work with short-lived tasks?

**A:** They shouldn't — use a `Job` for finite tasks. Deployments are for
long-running workloads (web servers, APIs) that are supposed to run forever.
The restart is intentional for those. Using a Deployment for a one-time batch
job is an architectural mistake — the pod would loop forever due to `Always`.

### Q: What is the difference between `Succeeded` (in the docs) and `Completed` (in kubectl output)?

**A:** They refer to the same state. The Kubernetes documentation uses
`Succeeded` as the official phase name. `kubectl get pods` displays `Completed`
in the STATUS column as a more user-friendly term. Both mean: all containers
exited with code 0 and will not restart.

### Q: When should I increase `terminationGracePeriodSeconds`?

**A:** When you know your application's graceful shutdown takes longer than
30 seconds. Common cases: JVM applications with large heap taking time to
checkpoint, services that need to drain all open connections, or batch workers
that need to finish the current unit of work. Measure your actual shutdown
time, then set the grace period to that time + 25% buffer.

### Q: What is the difference between `ErrImagePull` and `ImagePullBackOff`?

**A:** Same root cause — image cannot be pulled. `ErrImagePull` is reported
on the first failure. After repeated failures, Kubernetes starts the
exponential backoff and reports `ImagePullBackOff` to indicate it is
intentionally waiting before retrying. Debug both the same way: `kubectl
describe pod` → look at Events.

---

## What You Learned

In this lab, you:

- ✅ Observed all five pod conditions and understood exactly what each one
     checks, who sets it, and what the `reason` field adds to `status` alone
- ✅ Explained the difference between pod phase and pod conditions — phase is
     a summary, conditions are the granular checkpoints
- ✅ Understood why `ContainersReady = False` appears in both `ContainerCreating`
     AND `Running 0/1` — and how to tell them apart using container state and
     the `reason` field (`PodCompleted` vs absent)
- ✅ Understood Linux signals at the level needed for Kubernetes — SIGTERM as
     a catchable graceful shutdown request, SIGKILL as an uncatchable forced
     termination, and why Kubernetes always tries SIGTERM first
- ✅ Understood PID 1 in a container — why Kubernetes sends SIGTERM to PID 1
     only, and why the signal forwarding problem causes applications to be
     killed without cleanup when an entrypoint script does not use `exec`
- ✅ Understood both container lifecycle hooks — `postStart` fires after
     container start (async with ENTRYPOINT), `preStop` fires before SIGTERM
     (blocking), both share the `terminationGracePeriodSeconds` budget
- ✅ Configured a production-style graceful shutdown using
     `terminationGracePeriodSeconds`, a `preStop` exec hook for LB drain,
     and a shell `trap` handler for SIGTERM — and verified it via logs
- ✅ Compared force delete (`--force --grace-period=0`) vs graceful delete
     and explained when each is appropriate
- ✅ Observed all three restart policies with real exit codes — `Always`
     restarting on exit 0, `OnFailure` stopping on exit 0, `Never` staying
     in `Completed` or `Error` without restart
- ✅ Configured `imagePullPolicy` for development (`Always`) and production
     (`IfNotPresent`) and understood the tag collision risk with `IfNotPresent`
- ✅ Triggered and debugged `ErrImagePull → ImagePullBackOff`, `OOMKilled`,
     and `CrashLoopBackOff` — including reading exit code 137 from
     `lastState.terminated.reason`
- ✅ Applied the standard debug workflow:
     `describe` → `logs` → `logs --previous` → `events`

**Key Takeaway:** Pod phase is a summary; conditions are the truth; the
`reason` field is the precision. The container `ready` flag bridges conditions
to traffic — driven by readiness probe results or defaulting to `true` when no
probe is configured. Graceful shutdown is a three-layer contract between
Kubernetes (`terminationGracePeriodSeconds`), the container (`preStop` hook),
and the application (SIGTERM handler) — all three must be configured correctly
for production-safe pod termination.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get pods -w` | Watch live phase transitions |
| `kubectl get pod <n> -o yaml \| grep -A30 conditions` | View all 5 conditions with timestamps |
| `kubectl describe pod <n>` | Full details + Events (most useful for debugging) |
| `kubectl logs <n>` | Container stdout/stderr |
| `kubectl logs <n> --previous` | Logs from PREVIOUS (crashed) container |
| `kubectl get events --sort-by='.lastTimestamp'` | Cluster events sorted newest first |
| `kubectl delete pod <n> --force --grace-period=0` | Emergency force delete |

---

## Troubleshooting

**Pod in `CrashLoopBackOff`?**
```bash
kubectl logs <n> --previous      # Logs from the CRASHED instance
kubectl describe pod <n>         # Exit code and reason
# Most common causes: missing env vars, failed config, probe misconfiguration
```

**Pod in `OOMKilled`?**
```bash
kubectl get pod <n> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
# Shows: OOMKilled
# Fix: increase memory limit OR fix memory leak in application
```

**Pod in `ImagePullBackOff`?**
```bash
kubectl describe pod <n>
# Events will show: "manifest for <image> not found" → wrong tag
# OR: "unauthorized" → missing imagePullSecret for private registry
```

---

## CKA Certification Tips

✅ **Know the 5 official pod phases:**
`Pending`, `Running`, `Succeeded`, `Failed`, `Unknown`

✅ **`ContainerCreating` and `CrashLoopBackOff` are NOT phases** — they are
display strings constructed by kubectl from container state.

✅ **`Succeeded` = `Completed`** — docs say Succeeded, kubectl shows Completed.

✅ **Quick pod with specific restart policy:**
```bash
kubectl run my-pod --image=busybox:1.36 --restart=Never -- sleep 300
kubectl run my-job --image=busybox:1.36 --restart=OnFailure -- sh -c "exit 0"
```


✅ **Logs from crashed container (exam favourite):**
```bash
kubectl logs <pod-name> --previous
```

✅ **`terminationGracePeriodSeconds` is at `spec` level** (pod level),
NOT inside `containers[]`:
```yaml
spec:
  terminationGracePeriodSeconds: 40   # ← correct
  containers:
    - name: app
```

✅ **`imagePullPolicy` is at `containers[]` level** (container level),
NOT at `spec` level:
```yaml
containers:
  - name: app
    image: busybox:1.36
    imagePullPolicy: IfNotPresent   # ← correct
```
