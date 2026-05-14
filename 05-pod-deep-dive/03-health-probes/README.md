# Health Probes — Readiness, Liveness & Startup

## Lab Overview

This lab teaches you how to configure Kubernetes health probes — the mechanism
that bridges the gap between "container process started" and "application is
actually healthy and ready to serve traffic."

Without probes, Kubernetes only knows whether a container's **process exists**.
It has no way to know if the application inside is deadlocked, still loading,
or broken. Health probes give Kubernetes application-level visibility, enabling
it to stop routing traffic to unhealthy pods, restart deadlocked containers,
and protect slow-starting apps from premature termination.

You will work through three probe types across three probe mechanisms, verify
every probe result through the correct commands in the correct order, and
connect probe results to the `ready` flag, pod conditions, and Service endpoint
behaviour.

**What you'll do:**
- Configure a readiness probe (`exec`) and verify the full probe→ready→condition→traffic chain
- Prove probe success is silent and probe failure is visible through Events
- Use a polling loop to reliably capture state transitions
- Configure a liveness probe (`httpGet`) and watch RESTARTS climb into CrashLoopBackOff
- Prove readiness and liveness run in parallel with independent timers
- Configure `tcpSocket` probes on Redis — port-level health checking
- Configure a startup probe to protect slow-starting PostgreSQL
- Inspect all five probe parameters and see Kubernetes fill in defaults

## Prerequisites

**Required Software:**
- Minikube multi-node cluster (`3node` profile) — 1 control plane + 2 workers
- kubectl installed and configured
- Text editor (VS Code recommended)

**Knowledge Requirements:**
- **REQUIRED:** Completion of Lab 01 (Pod Lifecycle, Termination, Restart Policies)
- **REQUIRED:** Completion of Lab 02 (Multi-Container Pods) — especially `ready` flag concept
- Understanding of pod conditions and the `ready` flag per container

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain what a readiness probe does and how kubelet executes it
2. ✅ Trace the full probe result chain: probe → `ready` flag → conditions → Service endpoints
3. ✅ Explain why probe success is silent and how to verify it indirectly
4. ✅ Explain why probe failure IS visible and where to find it
5. ✅ Configure readiness, liveness, and startup probes with the correct mechanisms
6. ✅ Prove readiness and liveness run in parallel and independently
7. ✅ Calculate a startup probe time budget from `failureThreshold × periodSeconds`
8. ✅ Identify all five probe parameters and know their defaults
9. ✅ Explain what readiness gates are and which real-world systems use them

## Directory Structure

```
03-health-probes/
└── src/
    ├── 01-readiness-exec.yaml               # Readiness probe: exec mechanism
    ├── 02-liveness-httpget.yaml             # Liveness probe: httpGet mechanism
    ├── 03-readiness-liveness-parallel.yaml  # Both probes, independent timers
    ├── 04-readiness-tcpsocket-redis.yaml    # tcpSocket probe on Redis
    ├── 05-startup-probe-postgres.yaml       # Startup probe: protect PostgreSQL
    └── 06-probe-timers-defaults.yaml        # All five probe parameters
```

## Understanding Health Probes — The Foundation

### Why `Running` Is Not Enough

```
Container state = Running
        │
        └── Means: the PROCESS exists (PID is alive)
                   Does NOT mean: app is healthy, ready, or functional

Examples where Running ≠ healthy:
  - JVM app: process started but still loading 50,000 classes
  - API server: process running but deadlocked on a mutex
  - Web server: process running but DB connection pool not initialised
  - Any app: process alive but dependent service not yet reachable
```

Without probes, Kubernetes marks the container `ready = true` the instant
the process starts and immediately sends traffic — potentially before the
app can handle any requests.

### What Each Probe Does on Failure

```
┌────────────────┬───────────────────────────────────┬───────────┐
│  Probe         │  On Failure                       │  Restarts │
├────────────────┼───────────────────────────────────┼───────────┤
│  Readiness     │  container ready = false          │    No     │
│                │  pod removed from LB endpoints    │           │
├────────────────┼───────────────────────────────────┼───────────┤
│  Liveness      │  ONLY that container restarted    │   Yes     │
│                │  other containers unaffected      │           │
├────────────────┼───────────────────────────────────┼───────────┤
│  Startup       │  container restarted              │   Yes     │
│                │  blocks liveness + readiness      │           │
└────────────────┴───────────────────────────────────┴───────────┘
```

### Probe Lifecycle and Interaction

```
Container state = Running
        │
        ├── Startup probe configured?
        │       YES → Startup fires first. Blocks readiness + liveness.
        │             Their timers do not start at all.
        │             Startup passes once → stops forever → R+L activate.
        │       NO  → Readiness and Liveness activate immediately.
        │
        └── Readiness + Liveness run in PARALLEL and INDEPENDENTLY
                Each has its own initialDelaySeconds and periodSeconds.
                They do not wait for each other.
                A liveness failure does NOT cause readiness to fail.
                A readiness failure does NOT cause liveness to fail.
```

### Probe Result Chain — From Probe to Traffic

```
Probe result (Success / Failure / Unknown)
        │
        ▼
container ready flag (true / false)          ← per container
        │
        ▼
ContainersReady condition                    ← True if ALL containers ready=true
        │
        ▼
Ready condition                              ← True if ContainersReady=True
        │                                       AND all readinessGates pass
        ▼
Service Endpoints                            ← pod IP added/removed
        │
        ▼
Traffic                                      ← flows only if pod IP in Endpoints
```

### Probe Success vs Probe Failure — What Is Visible

```
┌──────────────────────────────────────────────────────────────────┐
│  Probe SUCCESS                                                   │
│  → Completely silent                                             │
│  → No events, no log lines, no kubectl output changes           │
│  → Verify INDIRECTLY: READY=1/1, ready=true in containerStatus, │
│    ContainersReady=True in conditions                            │
│                                                                  │
│  Probe FAILURE                                                   │
│  → Warning Unhealthy event in kubectl describe pod              │
│  → READY drops to 0/1                                           │
│  → ready=false in containerStatus                               │
│  → ContainersReady=False in conditions                          │
└──────────────────────────────────────────────────────────────────┘
```

### Four Probe Mechanisms

```
┌────────────────┬──────────────────────────────────────────────────────┐
│  Mechanism     │  Success Condition                                   │
├────────────────┼──────────────────────────────────────────────────────┤
│  httpGet       │  HTTP response code 200–399                          │
│                │  Best for: REST APIs, web servers                    │
├────────────────┼──────────────────────────────────────────────────────┤
│  tcpSocket     │  TCP connection accepted on the specified port       │
│                │  Best for: databases, message queues, Redis          │
├────────────────┼──────────────────────────────────────────────────────┤
│  exec          │  Command exits with code 0                           │
│                │  Best for: custom checks, file-based health signals  │
├────────────────┼──────────────────────────────────────────────────────┤
│  grpc          │  gRPC health check returns SERVING (v1.24+ stable)  │
│                │  Best for: gRPC services                             │
└────────────────┴──────────────────────────────────────────────────────┘
```

### `jsonpath` Output and `python3 -m json.tool`

```
Scalar string output (ready, True, False, 0...)
  → Do NOT pipe to python3 -m json.tool
  → It expects JSON — a bare string causes "Expecting value" error

JSON object output ({...})
  → ALWAYS pipe to python3 -m json.tool

Rule: query containerStatuses[0] as a full object — one command shows
      ready, restartCount, state, and lastState together — safe for json.tool
```

```bash
# ❌ Scalar — do NOT pipe to json.tool
kubectl get pod <n> -o jsonpath='{.status.containerStatuses[0].ready}'

# ✅ Object — ALWAYS pipe to json.tool
kubectl get pod <n> -o jsonpath='{.status.containerStatuses[0]}' \
  | python3 -m json.tool
```

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

---

### Part 1: Readiness Probe — exec Mechanism

---

### Step 2: Understand the YAML

#### What This Demo Shows

This demo teaches how kubelet executes a readiness probe, how the probe
result flows through to the `ready` flag and pod conditions, and how the
entire chain connects to Service endpoint membership.

We use the `exec` mechanism — kubelet runs a command inside the container
and uses the exit code as the probe result. The container creates a signal
file `/tmp/ready` at startup. The probe checks for this file. We observe the complete lifecycle:

1. Probe passing → `1/1 Running` → pod in Service endpoints
2. File deleted → probe fails → `0/1 Running` → removed from endpoints
3. `Unhealthy` event in `kubectl describe` proves kubelet fired the probe
4. File recreated → probe passes again → automatic recovery
5. `restartCount = 0` throughout — readiness never triggers a restart

**01-readiness-exec.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: readiness-exec-demo
spec:
  restartPolicy: Never
  containers:
    - name: app
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "[app] Starting at $(date +%T)"
          touch /tmp/ready
          echo "[app] Ready file created at $(date +%T)"
          echo "[app] Running — staying alive for probe demos"
          sleep 3600
      readinessProbe:
        exec:
          command:
            - cat
            - /tmp/ready        # exit 0 if file exists → probe Success
                                # exit 1 if file missing → probe Failure
        initialDelaySeconds: 5  # Wait 5s after container starts
        periodSeconds: 5        # Fire every 5 seconds continuously
        failureThreshold: 1     # 1 failure → ready=false immediately
        successThreshold: 1     # 1 success → ready=true
        timeoutSeconds: 2       # Timeout after 2 seconds
```

**Key YAML Fields Explained:**

- `readinessProbe` is defined inside `spec.containers[]` — per-container,
  not per-pod. Each container has its own independent probe.
- `exec.command` — kubelet executes this command inside the container using
  the container's own filesystem and process namespace. Exit `0` = Success.
  Non-zero = Failure.
- `cat /tmp/ready` — exits 0 if file exists (Success), exits 1 if file
  missing (Failure).
- `initialDelaySeconds: 5` — kubelet waits 5 seconds after the container
  enters `Running` before the first probe. The container creates the file
  at startup — this buffer ensures the file exists before the first probe.
- `periodSeconds: 5` — probe fires continuously every 5 seconds for the
  entire pod lifetime. Readiness never stops checking.
- `failureThreshold: 1` — one failure immediately flips `ready=false`.
  Use `3` in production to tolerate transient failures.

> **Important — probe command output is NOT in `kubectl logs`:**
> The probe command (`cat /tmp/ready`) runs as a kubelet-managed child
> process. Its stdout is captured internally by kubelet for result
> evaluation — it is NOT written to the container log stream.
> Only the app's own stdout (`[app]` lines) appears in `kubectl logs`.
> Probe execution is only observable through: READY column, pod
> conditions, containerStatus, and `Warning Unhealthy` failure events in `kubectl describe pod`.

---

### Step 3: Deploy and Observe Probe Passing

**Terminal 1 — watch pod status:**
```bash
cd 03-health-probes/src
kubectl get pods -w
```

**Terminal 2 — apply:**
```bash
kubectl apply -f 01-readiness-exec.yaml
```

**Terminal 3 — follow container logs:**
```bash
kubectl logs -f readiness-exec-demo -c app
```

**Terminal 1 — Expected output:**
```
NAME                  READY   STATUS              RESTARTS   AGE
readiness-exec-demo   0/1     Pending             0          0s
readiness-exec-demo   0/1     Pending             0          0s
readiness-exec-demo   0/1     ContainerCreating   0          0s
readiness-exec-demo   0/1     Running             0          2s
                      ↑
                  0/1 — container process started
                         initialDelaySeconds:5 not elapsed
                         probe has NOT fired yet
                         default state = ready=false

readiness-exec-demo   1/1     Running             0          8s
                      ↑
                  1/1 — probe fired at ~7s (5s delay + ~2s first probe)
                         cat /tmp/ready → exit 0 → ready=true
                         ContainersReady=True → Ready=True
                         pod IP added to Service endpoints
```

> **Why `0/1` before `1/1`:**
> Without a probe result, the default state is `ready=false`. The
> container must PROVE it is ready by passing the probe.

**Terminal 3 — Expected log output:**
```
[app] Starting at 09:41:07
[app] Ready file created at 09:41:07
[app] Running — staying alive for probe demos
```

> Only `[app]` lines appear. The probe command runs inside the container
> but kubelet captures its output — it never reaches the log stream.

---

### Step 4: Verify Probe Passing — All State in One Command

Run after Terminal 1 shows `1/1 Running`:

```bash
kubectl get pod readiness-exec-demo \
  -o jsonpath='{.status.containerStatuses[0]}' \
  | python3 -m json.tool
```

**Expected output:**
```json
{
    "containerID": "docker://...",
    "image": "busybox:1.36",
    "name": "app",
    "ready": true,
    "restartCount": 0,
    "started": true,
    "state": {
        "running": {
            "startedAt": "2026-03-24T09:41:07Z"
        }
    }
}
```

> `ready: true` — probe passed.
> `restartCount: 0` — readiness NEVER triggers a restart.
> `state.running` — container is alive.

**Verify the probe→condition chain:**
```bash
kubectl get pod readiness-exec-demo -o yaml | grep -A 30 "conditions:"
```

**Expected output:**
```yaml
conditions:
- lastProbeTime: null
  lastTransitionTime: "2026-03-24T09:41:06Z"
  observedGeneration: 1
  status: "True"
  type: PodScheduled

- lastProbeTime: null
  lastTransitionTime: "2026-03-24T09:41:06Z"
  observedGeneration: 1
  status: "True"
  type: Initialized

- lastProbeTime: null
  lastTransitionTime: "2026-03-24T09:41:08Z"
  observedGeneration: 1
  status: "True"
  type: PodReadyToStartContainers

- lastProbeTime: null
  lastTransitionTime: "2026-03-24T09:41:14Z"
  observedGeneration: 1
  status: "True"
  type: ContainersReady       ← flipped at 09:41:14 (when probe first passed)

- lastProbeTime: null
  lastTransitionTime: "2026-03-24T09:41:14Z"
  observedGeneration: 1
  status: "True"
  type: Ready                 ← same second — pod joined Service endpoints
```

> **Reading the timestamps:**
> ```
> 09:41:06  PodScheduled, Initialized    ← pod accepted and scheduled
> 09:41:08  PodReadyToStartContainers    ← sandbox + CNI ready (2s later)
> 09:41:14  ContainersReady, Ready       ← 8s after start
>                                           = 5s initialDelay + ~3s first probe
>                                           probe passed → ready=true
>                                           → both conditions flipped
>                                           → pod joins endpoints
> ```
> Before `09:41:14` the pod was `Running` but NOT in Service endpoints.
> Traffic only flows AFTER the probe passes.

**Verify probe configuration as stored:**
```bash
kubectl describe pod readiness-exec-demo | grep -A 5 "Readiness:"
```

**Expected output:**
```
Readiness:  exec [cat /tmp/ready] delay=5s timeout=2s period=5s #success=1 #failure=1
```

**Verify probe success is silent — no Unhealthy events:**
```bash
kubectl describe pod readiness-exec-demo | grep -A 8 "Events:"
```

**Expected output:**
```
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  60s   default-scheduler  Successfully assigned...
  Normal  Pulled     59s   kubelet            Container image already present
  Normal  Created    59s   kubelet            Created container: app
  Normal  Started    59s   kubelet            Started container app
```

> Only `Normal` events — no `Warning Unhealthy`.
> Successful probe firings generate zero events — silence is success.

---

### Step 5: Simulate Probe Failure — Delete the File

```bash
echo "Deleting ready file at $(date +%T)"
kubectl exec readiness-exec-demo -- rm /tmp/ready
echo "File deleted — polling for ready=false..."

#Poll the `ready` flag — reliable for capturing brief transitions
for i in 1 2 3 4 5 6 7 8 9 10; do
  READY=$(kubectl get pod readiness-exec-demo \
    -o jsonpath='{.status.containerStatuses[0].ready}')
  echo "$(date +%T) — ready = $READY"
  [ "$READY" = "false" ] && \
    echo "Probe failed — pod removed from Service endpoints" && break
  sleep 2
done
```

**Expected output:**
```
09:45:02 — ready = true
09:45:04 — ready = true
09:45:06 — ready = true
09:45:08 — ready = false
Probe failed — pod removed from Service endpoints
```

**Terminal 1 — Expected watch output showing READY drop:**
```
NAME                  READY   STATUS    RESTARTS   AGE
readiness-exec-demo   0/1     Pending   0          0s
readiness-exec-demo   0/1     Pending   0          0s
readiness-exec-demo   0/1     ContainerCreating   0          0s
readiness-exec-demo   0/1     Running             0          2s
readiness-exec-demo   1/1     Running             0          8s
readiness-exec-demo   0/1     Running             0          3m43s   ← probe failed : ready=false
```


> **Why polling is more reliable than `kubectl get pods -w` here:**
> `kubectl get pods -w` outputs a line only when the API server sends
> a watch event. For brief failure windows, the watch event may be missed
> entirely. Polling every 2 seconds captures the exact moment `ready`
> flips regardless of how long the failure lasts.

**Verify the `Unhealthy` event — proof that kubelet fired the probe:**
```bash
kubectl describe pod readiness-exec-demo | grep -A 8 "Events:"
```

**Expected output:**
```
Events:
  Type     Reason     Age   From     Message
  ----     ------     ----  ----     -------
  Normal   Scheduled  5m    default-scheduler  Successfully assigned...
  Normal   Pulled     5m    kubelet  Container image already present
  Normal   Created    5m    kubelet  Created container: app
  Normal   Started    5m    kubelet  Started container app
  Warning  Unhealthy  5s    kubelet  Readiness probe failed:
                                     cat: can't open '/tmp/ready':
                                     No such file or directory
```

> **`Warning Unhealthy` is the probe in action.** This is the ONLY place
> where probe execution becomes visible when it fails. The message shows
> exactly what the probe command returned — `cat` failed because the file
> is missing. A new `Unhealthy` event is created every `periodSeconds`
> while the probe continues to fail.

**Verify full container state after failure:**
```bash
kubectl get pod readiness-exec-demo \
  -o jsonpath='{.status.containerStatuses[0]}' \
  | python3 -m json.tool
```

**Expected output:**
```json
{
    "name": "app",
    "ready": false,
    "restartCount": 0,
    "started": true,
    "state": {
        "running": {
            "startedAt": "2026-03-24T09:41:07Z"
        }
    }
}
```

> `ready: false` — probe failing.
> `restartCount: 0` — container NOT restarted.
> `state.running` — container process still alive.
> `startedAt` unchanged — same timestamp from the very beginning.

**Verify conditions changed:**
```bash
kubectl get pod readiness-exec-demo -o yaml | grep -A 30 "conditions:"
```

**Expected output:**
```yaml
conditions:
- status: "True"
  type: PodScheduled

- status: "True"
  type: Initialized

- status: "True"
  type: PodReadyToStartContainers

- lastTransitionTime: "2026-03-24T09:45:08Z"
  message: 'containers with unready status: [app]'
  reason: ContainersNotReady
  status: "False"
  type: ContainersReady       ← flipped to False with reason field

- lastTransitionTime: "2026-03-24T09:45:08Z"
  message: 'containers with unready status: [app]'
  reason: ContainersNotReady
  status: "False"
  type: Ready                 ← flipped to False — pod removed from endpoints
```

> When conditions flip to `False`, Kubernetes adds `message` and `reason`
> fields that were absent when `True`. `reason: ContainersNotReady` and
> `message: 'containers with unready status: [app]'` confirm exactly which
> container caused the flip and why.

> **Readiness failure vs Liveness failure:**
> ```
> Readiness fails → ready=false → READY 1/1→0/1 → RESTARTS=0
> Liveness fails  → container restarted       → RESTARTS++
> ```
> The container is alive. Only traffic routing is affected.

---

### Step 6: Recover — Recreate the File

```bash
echo "Recreating ready file at $(date +%T)"
kubectl exec readiness-exec-demo -- touch /tmp/ready
echo "File recreated — polling for ready=true..."

#Poll for recovery:
for i in 1 2 3 4 5 6 7 8 9 10; do
  READY=$(kubectl get pod readiness-exec-demo \
    -o jsonpath='{.status.containerStatuses[0].ready}')
  echo "$(date +%T) — ready = $READY"
  [ "$READY" = "true" ] && \
    echo "Probe passing — pod rejoined Service endpoints" && break
  sleep 2
done
```


**Expected output:**
```
09:46:10 — ready = false
09:46:12 — ready = false
09:46:14 — ready = true
Probe passing — pod rejoined Service endpoints
```

> Recovery takes up to `periodSeconds: 5` — depending on where the probe
> is in its cycle when the file is recreated. May be as fast as 2 seconds.

**Terminal 1 — Expected watch output showing READY recovery:**
```
NAME                  READY   STATUS    RESTARTS   AGE
readiness-exec-demo   0/1     Pending   0          0s
readiness-exec-demo   0/1     Pending   0          0s
readiness-exec-demo   0/1     ContainerCreating   0          0s
readiness-exec-demo   0/1     Running             0          2s
readiness-exec-demo   1/1     Running             0          8s
readiness-exec-demo   0/1     Running             0          3m43s      ← probe failed before : ready=false
readiness-exec-demo   1/1     Running             0          8m32s      ← probe succeeds now  : ready=true, again
```


**Final state verification:**
```bash
kubectl get pod readiness-exec-demo \
  -o jsonpath='{.status.containerStatuses[0]}' \
  | python3 -m json.tool
```

**Expected output:**
```json
{
    "name": "app",
    "ready": true,
    "restartCount": 0,
    "started": true,
    "state": {
        "running": {
            "startedAt": "2026-03-24T09:41:07Z"
        }
    }
}
```

> `ready: true` — probe passing again.
> `restartCount: 0` — never restarted throughout entire demo.
> `startedAt` unchanged — same from the very beginning.
> The container ran continuously through all three states.

**The complete readiness probe lifecycle demonstrated:**
```
09:41:07  Container starts, creates /tmp/ready
09:41:14  Probe fires (5s delay + probe) → exit 0 → READY 1/1
          ContainersReady=True, Ready=True — in Service endpoints

09:45:08  File deleted → probe fires → exit 1 → READY 0/1
          ContainersReady=False, Ready=False (with reason: ContainersNotReady)
          Pod removed from endpoints
          Unhealthy event created ← only visible sign of probe
          RESTARTS=0 throughout

09:46:14  File recreated → probe fires → exit 0 → READY 1/1
          Pod rejoined endpoints — RESTARTS=0 still
```

**Cleanup:**
```bash
kubectl delete -f 01-readiness-exec.yaml
```

---

### Part 2: Liveness Probe — httpGet Mechanism

---

### Step 7: Understand the YAML

#### What This Demo Shows

This demo uses `registry.k8s.io/e2e-test-images/agnhost:2.40` — the
official Kubernetes e2e test image used in Kubernetes own CI/CD pipeline.
It is purpose-built for health probe demonstrations and exactly what the
official Kubernetes documentation uses.

`agnhost` stands for **"agnostic host"** — a multi-purpose Kubernetes test
binary that consolidates many testing utilities into one image. The `liveness`
subcommand specifically simulates an app lifecycle:
```
agnhost liveness behaviour:
  0s → 10s  → serves HTTP 200 on /healthz (healthy window)
  10s+      → serves HTTP 500 on /healthz (permanently unhealthy)
```

This simulates a real-world application that starts healthy but enters a
deadlocked or broken state. The liveness probe detects the failure, restarts the container, and the cycle repeats — RESTARTS climbs and eventually CrashLoopBackOff appears as the backoff mechanism kicks in.

**02-liveness-httpget.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: liveness-httpget-demo
spec:
  containers:
    - name: liveness-app
      image: registry.k8s.io/e2e-test-images/agnhost:2.40
      args:
        - liveness             # Subcommand: HTTP server, 200 for 10s then 500
      livenessProbe:
        httpGet:
          path: /healthz
          port: 8080
          httpHeaders:
            - name: Custom-Header     # Optional — demonstrates header syntax
              value: awesome
        initialDelaySeconds: 3
        periodSeconds: 3
        failureThreshold: 3           # 3 consecutive failures → restart
        timeoutSeconds: 1
```

**Key YAML Fields Explained:**

- `registry.k8s.io/e2e-test-images/agnhost:2.40` — the official Kubernetes
  e2e test image. Used in Kubernetes own CI/CD pipeline. OCI compliant,
  modern manifest format, actively maintained by the Kubernetes project.
- `args: - liveness` — the agnhost subcommand. Starts an HTTP server
  on port 8080 returning 200 for the first 10 seconds, then 500 permanently.
- `httpGet.path: /healthz` — probe sends `GET /healthz HTTP/1.1`.
  Response `200–399` = Success. `400+` = Failure.
- `httpHeaders` — optional custom headers. Useful when health endpoints
  require auth tokens. Shown here for syntax reference.
- With `periodSeconds: 3` and `failureThreshold: 3`:
  restarts after = 10s (healthy window) + 3s delay + (3 × 3s failures) = ~22s
- **Liveness probe failure restarts ONLY the failing container.**
- After repeated restarts, CrashLoopBackOff kicks in — same backoff
  mechanism as any crashing container (10s → 20s → 40s → ...).
**HTTP Status Code Reference:**
```
200–399 → ✅ Success
400+    → ❌ Failure
Timeout → ❌ Failure
```

---

### Step 8: Deploy and Watch RESTARTS Climb

**Terminal 1 — watch status:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply:**
```bash
kubectl apply -f 02-liveness-httpget.yaml
```

**Terminal 1 — Expected output:**
```
NAME                    READY   STATUS              RESTARTS        AGE
liveness-httpget-demo   0/1     Pending             0               0s
liveness-httpget-demo   0/1     ContainerCreating   0               0s
liveness-httpget-demo   1/1     Running             0               7s
                                                                      ↑ first run
                                                                        probe passing (200)

liveness-httpget-demo   1/1     Running             1 (1s ago)      24s   ← RESTART 1
liveness-httpget-demo   1/1     Running             2 (1s ago)      42s   ← RESTART 2
liveness-httpget-demo   1/1     Running             3 (2s ago)      60s   ← RESTART 3

liveness-httpget-demo   0/1     CrashLoopBackOff    3 (1s ago)      77s
                                ↑
                            Backoff kicks in after 3 rapid restarts
                            CrashLoopBackOff = waiting period before next retry
                            same mechanism as Lab 01 — backoff doubles each time

liveness-httpget-demo   1/1     Running             4 (24s ago)     100s  ← backoff expired
liveness-httpget-demo   1/1     Running             5 (1s ago)      117s  ← RESTART 5
liveness-httpget-demo   0/1     CrashLoopBackOff    5 (2s ago)      2m16s ← longer backoff
liveness-httpget-demo   1/1     Running             6               3m35s ← resumed
```

> **Each restart cycle (~17s):**
> ```
> 10s  agnhost returns 200 (healthy window after restart)
> + 3s  initialDelaySeconds
> + 9s  3 failures × 3s period
> ────
> ~22s  per cycle — shorter than expected 22s because agnhost starts fast
> ```
>
> **CrashLoopBackOff appears** after rapid restarts because kubelet applies
> exponential backoff (10s → 20s → 40s...) to protect cluster resources.
> The container is not stuck — it is in the waiting period before the
> next restart attempt. See Lab 01 for full CrashLoopBackOff theory.

**Verify container state during Running (probe currently passing):**
```bash
kubectl get pod liveness-httpget-demo \
  -o jsonpath='{.status.containerStatuses[0]}' \
  | python3 -m json.tool
```

**Expected output (during Running, after several restarts):**
```json
{
    "name": "liveness-app",
    "ready": true,
    "restartCount": 5,
    "started": true,
    "lastState": {
        "terminated": {
            "exitCode": 2,
            "reason": "Error",
            "finishedAt": "2026-03-24T19:44:49Z",
            "startedAt": "2026-03-24T19:44:32Z"
        }
    },
    "state": {
        "running": {
            "startedAt": "2026-03-24T19:44:50Z"
        }
    }
}
```

> `restartCount: 5` — liveness probe triggered restarts.
> `lastState.terminated.exitCode: 2` — agnhost exits with code `2`
>   (its own exit code, not SIGKILL). agnhost handles its own shutdown.
> `state.running` — currently in the 10-second healthy window again.

**Verify container state during CrashLoopBackOff:**
```bash
kubectl get pod liveness-httpget-demo \
  -o jsonpath='{.status.containerStatuses[0]}' \
  | python3 -m json.tool
```

**Expected output (during CrashLoopBackOff):**
```json
{
    "name": "liveness-app",
    "ready": false,
    "restartCount": 3,
    "started": false,
    "lastState": {
        "terminated": {
            "exitCode": 2,
            "reason": "Error",
            "finishedAt": "2026-03-24T19:44:09Z",
            "startedAt": "2026-03-24T19:43:51Z"
        }
    },
    "state": {
        "waiting": {
            "message": "back-off 20s restarting failed container=liveness-app ...",
            "reason": "CrashLoopBackOff"
        }
    }
}
```

> `state.waiting.reason: CrashLoopBackOff` — container is in the backoff
>   waiting period. Not running, not crashed — deliberately paused.
> `started: false` — container process not currently running.
> `ready: false` — not ready during backoff wait.

**Verify liveness failure events:**
```bash
kubectl describe pod liveness-httpget-demo | grep -A 12 "Events:"
```

**Expected output:**
```
Events:
  Type     Reason     Age                   From     Message
  ----     ------     ----                  ----     -------
  Normal   Scheduled  3m                    ...      Successfully assigned...
  Normal   Pulling    3m                    kubelet  Pulling image...
  Normal   Pulled     3m                    kubelet  Successfully pulled...
  Normal   Created    2m1s (x6 over 3m52s)  kubelet  Created container: liveness-app
  Normal   Started    2m1s (x6 over 3m52s)  kubelet  Started container liveness-app
  Warning  Unhealthy  104s (x18 over 3m40s) kubelet  Liveness probe failed:
                                                      HTTP probe failed with statuscode: 500
  Normal   Killing    104s (x6 over 3m35s)  kubelet  Container liveness-app failed
                                                      liveness probe, will be restarted
  Warning  BackOff    74s (x7 over 2m42s)   kubelet  Back-off restarting failed container
```

> Three distinct event types for liveness failure:
>
> `Warning Unhealthy` — probe detected failure (HTTP 500). Repeats every
>   `periodSeconds` while probe keeps failing. Count shows `x18` —
>   probe has fired 18 times total.
>
> `Normal Killing` — kubelet acting on it (restarting container). Count
>   `x6` — 6 restarts triggered. Unique to liveness/startup failure.
>   Compare with Part 1 readiness: only `Unhealthy`, no `Killing`.
>
> `Warning BackOff` — CrashLoopBackOff backoff mechanism active.
>   Appears after rapid repeated restarts. Count shows `x7`.

**Cleanup:**
```bash
kubectl delete -f 02-liveness-httpget.yaml
```

---

### Part 3: Readiness and Liveness Are Parallel and Independent

---

### Step 9: Understand the YAML

#### What This Demo Shows

A single pod with BOTH readiness and liveness probes configured using
different mechanisms and different timers on the same container.

- **Readiness** (`exec`, every 10s) — checks for a file `/tmp/app-ready`
- **Liveness** (`httpGet`, every 20s) — checks nginx HTTP endpoint

We deploy without the readiness file so readiness fails immediately.
Liveness passes because nginx is serving HTTP correctly.

The independence is proven through three pieces of evidence simultaneously:
1. `0/1 Running` — readiness failing (file missing)
2. `RESTARTS=0` — liveness passing (nginx HTTP working)
3. Only `Readiness probe failed` event 
4. No `Liveness probe failed` event

**03-readiness-liveness-parallel.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: parallel-probes-demo
spec:
  containers:
    - name: web-app
      image: nginx:1.27
      ports:
        - containerPort: 80

      readinessProbe:
        exec:
          command: ["cat", "/tmp/app-ready"]
        initialDelaySeconds: 5    # Different delay from liveness
        periodSeconds: 10         # Different period — fires every 10s
        failureThreshold: 3

      livenessProbe:
        httpGet:
          path: /
          port: 80
        initialDelaySeconds: 10   # Different delay — fires later
        periodSeconds: 20         # Different period — fires every 20s
        failureThreshold: 3
```

**Key YAML Fields Explained:**

- Both probes on the same container — completely independent timers
- Readiness: `exec` every 10s — checks for a file
- Liveness: `httpGet` every 20s — checks nginx HTTP endpoint
- Different `initialDelaySeconds` and `periodSeconds` prove independence

---

### Step 10: Deploy and Prove Independence

**Terminal 1 — watch status:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply:**
```bash
kubectl apply -f 03-readiness-liveness-parallel.yaml
```

**Terminal 1 — Expected output:**
```
NAME                   READY   STATUS    RESTARTS   AGE
parallel-probes-demo   0/1     Running   0          1s
                       ↑   ↑   ↑         ↑
                       │   │   │         └── RESTARTS=0
                       │   │   │              liveness probe passing ✅
                       │   │   │              nginx HTTP returns 200
                       │   │   │              no restart triggered
                       │   │   └── STATUS=Running — container process alive
                       │   └── STATUS=Running, not Error/CrashLoop
                       └── 0/1 — readiness probe failing
                              /tmp/app-ready missing → cat exits 1
                              pod removed from Service endpoints
```

> `0/1 Running RESTARTS=0` is the definitive proof of independence.
> Readiness is failing, liveness is passing — they do not affect each other.

> **Note on timing:** The pod shows `0/1 Running` almost immediately at
> `1s` because readiness fires after `initialDelaySeconds: 5` and starts
> failing right away. The watch shows `1/1` only after the file is created.

---

#### Verification — While Readiness Is Failing (BEFORE file creation)

**Verify both probe configurations and independent timers:**
```bash
kubectl describe pod parallel-probes-demo | grep -A 5 "Liveness:\|Readiness:"
```

**Expected output:**
```
Liveness:   http-get http://:80/ delay=10s timeout=1s period=20s #success=1 #failure=3
Readiness:  exec [cat /tmp/app-ready] delay=5s timeout=1s period=10s #success=1 #failure=3
```

**Verify container state — `ready=false` but `restartCount=0`:**
```bash
kubectl get pod parallel-probes-demo \
  -o jsonpath='{.status.containerStatuses[0]}' \
  | python3 -m json.tool
```

**Expected output:**
```json
{
    "name": "web-app",
    "ready": false,
    "restartCount": 0,
    "started": true,
    "state": {
        "running": {
            "startedAt": "2026-03-24T19:55:22Z"
        }
    }
}
```

> `ready: false` — readiness probe failing.
> `restartCount: 0` — liveness probe passing (no restart triggered).
> `state.running` — container alive.
> Container-level proof of independence.

**Verify pod conditions:**
```bash
kubectl get pod parallel-probes-demo -o yaml | grep -A 30 "conditions:"
```

**Expected output:**
```yaml
conditions:
- status: "True"
  type: PodScheduled

- status: "True"
  type: Initialized

- status: "True"
  type: PodReadyToStartContainers

- lastTransitionTime: "2026-03-24T19:55:21Z"
  message: 'containers with unready status: [web-app]'
  observedGeneration: 1
  reason: ContainersNotReady
  status: "False"
  type: ContainersReady       ← False with reason field populated

- lastTransitionTime: "2026-03-24T19:55:21Z"
  message: 'containers with unready status: [web-app]'
  observedGeneration: 1
  reason: ContainersNotReady
  status: "False"
  type: Ready
```

**Verify Events — only readiness failures, no liveness failures:**
```bash
kubectl describe pod parallel-probes-demo | grep -A 12 "Events:"
```

**Expected output:**
```
Events:
  Type     Reason     Age                 From     Message
  ----     ------     ----                ----     -------
  Normal   Scheduled  2m11s               ...      Successfully assigned...
  Normal   Pulled     2m11s               kubelet  Container image already present
  Normal   Created    2m11s               kubelet  Created container: web-app
  Normal   Started    2m11s               kubelet  Started container web-app
  Warning  Unhealthy  8s (x13 over 2m1s)  kubelet  Readiness probe failed:
                                                    cat: /tmp/app-ready:
                                                    No such file or directory
```

> Only `Readiness probe failed` events — no `Liveness probe failed`.
> Liveness is passing silently. Readiness is failing visibly.
> Event-level proof of independence.

---

#### Recovery — Create the File

**Terminal 2:**
```bash
echo "Creating readiness file at $(date +%T)"
kubectl exec parallel-probes-demo -- touch /tmp/app-ready

# Poll for recovery — readiness fires every periodSeconds:10
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  READY=$(kubectl get pod parallel-probes-demo \
    -o jsonpath='{.status.containerStatuses[0].ready}')
  echo "$(date +%T) — ready = $READY"
  [ "$READY" = "true" ] && \
    echo "Readiness passed — pod rejoined endpoints" && break
  sleep 2
done
```

**Expected output:**
```
Creating readiness file at 15:58:58
15:58:58 — ready = false
15:59:00 — ready = true
Readiness passed — pod rejoined endpoints
```

> Recovery can be as fast as 2 seconds — depends on where the probe
> is in its `periodSeconds: 10` cycle when the file is created.

**Terminal 1 — watch transition:**
```
parallel-probes-demo   0/1   Running   0   60s
parallel-probes-demo   1/1   Running   0   3m38s   ← readiness passed ✅
```

**Final state verification AFTER recovery:**
```bash
kubectl get pod parallel-probes-demo \
  -o jsonpath='{.status.containerStatuses[0]}' \
  | python3 -m json.tool
```

**Expected output:**
```json
{
    "name": "web-app",
    "ready": true,
    "restartCount": 0,
    "started": true,
    "state": {
        "running": {
            "startedAt": "2026-03-24T19:55:22Z"
        }
    }
}
```

> `ready: true` — readiness recovered.
> `restartCount: 0` — liveness never triggered throughout entire demo.
> `startedAt` unchanged — same timestamp from the beginning.

**Verify pod conditions after recovery:**
```bash
kubectl get pod parallel-probes-demo -o yaml | grep -A 30 "conditions:"
```

**Expected output:**
```yaml
conditions:
- status: "True"
  type: PodScheduled

- status: "True"
  type: Initialized

- status: "True"
  type: PodReadyToStartContainers

- lastTransitionTime: "2026-03-24T19:58:59Z"
  observedGeneration: 1
  status: "True"
  type: ContainersReady   ← True again — message and reason fields gone

- lastTransitionTime: "2026-03-24T19:58:59Z"
  observedGeneration: 1
  status: "True"
  type: Ready             ← True — pod rejoined Service endpoints
```

> When conditions flip back to `True`, the `message` and `reason` fields
> disappear — they only appear when `status: "False"`.
> `lastTransitionTime` updated to `19:58:59` — the moment readiness passed.

**Cleanup:**
```bash
kubectl delete -f 03-readiness-liveness-parallel.yaml
```

---

### Part 4: tcpSocket Probe — Redis

---

### Step 11: Understand the YAML

#### What This Demo Shows

Redis has no HTTP endpoint. The `tcpSocket` probe solves this — it
attempts to open a TCP connection to port 6379. If Redis accepts the
connection, the probe succeeds. No protocol knowledge, no authentication. We configure
both readiness and liveness using `tcpSocket`, verify with `redis-cli ping`,
and inspect both probe configurations.

This demo shows:
- How to configure `tcpSocket` for both readiness and liveness
- The same probe lifecycle as Part 1 — `0/1 → 1/1` on startup
- Probe failure simulation — stop Redis, observe `0/1`, verify `Unhealthy`
  event shows TCP connection refused (not a missing file this time)
- `redis-cli ping` to distinguish TCP-layer from application-layer health
- `tcpSocket` `Unhealthy` event message vs `exec` event message

**04-readiness-tcpsocket-redis.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: redis-with-probe
  labels:
    app: redis
spec:
  containers:
    - name: redis
      image: redis:7
      ports:
        - containerPort: 6379
      readinessProbe:
        tcpSocket:
          port: 6379             # Attempt TCP connection to port 6379
        initialDelaySeconds: 5   # Redis starts in ~2s — 5s buffer
        periodSeconds: 10
        failureThreshold: 3
      livenessProbe:
        tcpSocket:
          port: 6379             # Same check — is Redis still listening?
        initialDelaySeconds: 15  # More time before liveness starts
        periodSeconds: 20
        failureThreshold: 3
      resources:
        requests:
          cpu: "100m"
          memory: "64Mi"
        limits:
          cpu: "200m"
          memory: "128Mi"
```

**Key YAML Fields Explained:**

- `tcpSocket.port: 6379` — kubelet opens a TCP connection. If accepted →
  Success. No Redis commands, no authentication needed.
- `redis:7` — starts in under 2 seconds, zero configuration required.
- Different `initialDelaySeconds` (5 vs 15) — readiness fires sooner;
  liveness waits longer before it can cause a restart.

---

### Step 12: Deploy and Verify tcpSocket Probe

**Terminal 1 — watch status:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply:**
```bash
kubectl apply -f 04-readiness-tcpsocket-redis.yaml
```

**Terminal 1 — Expected output:**
```
NAME               READY   STATUS              RESTARTS   AGE
redis-with-probe   0/1     Pending             0          0s
redis-with-probe   0/1     ContainerCreating   0          0s
redis-with-probe   0/1     Running             0          19s   ← Redis process started
                                                                   (image pull adds time
                                                                    on first run — cached
                                                                    runs are ~2s)
                                                                   initialDelaySeconds:5
                                                                   probe not fired yet

redis-with-probe   1/1     Running             0          30s   ← TCP to :6379 accepted
                   ↑                                               probe passed → ready=true
               1/1 — Redis listening on 6379, tcpSocket succeeded
```

> **First run vs cached:** On first deployment Redis image is pulled (~16s).
> On subsequent runs with cached image the `Running` transition appears at
> ~2s instead of ~19s.

**Verify both probe configurations:**
```bash
kubectl describe pod redis-with-probe | grep -A 5 "Liveness:\|Readiness:"
```

**Expected output:**
```
Liveness:     tcp-socket :6379 delay=15s timeout=1s period=20s #success=1 #failure=3
Readiness:    tcp-socket :6379 delay=5s  timeout=1s period=10s #success=1 #failure=3
```

**Verify full container status:**
```bash
kubectl get pod redis-with-probe \
  -o jsonpath='{.status.containerStatuses[0]}' \
  | python3 -m json.tool
```

**Expected output:**
```json
{
    "name": "redis",
    "ready": true,
    "restartCount": 0,
    "started": true,
    "state": {
        "running": {
            "startedAt": "2026-03-24T21:06:29Z"
        }
    }
}
```

**Verify Redis is actually responding (application-layer check):**
```bash
kubectl exec redis-with-probe -- redis-cli ping
# PONG
```

> `PONG` confirms Redis is responding to the Redis protocol.
> The tcpSocket probe only verified the TCP layer — connection accepted.
> `redis-cli ping` verifies the application layer — Redis is processing commands.

---

#### Failure Simulation — Stop Redis

**Terminal 1 — keep watching (already running from earlier):**
```bash
kubectl get pods -w
```

**Terminal 2 — stop Redis and poll for probe failure:**
```bash
echo "Stopping Redis at $(date +%T)"
kubectl exec redis-with-probe -- redis-cli shutdown nosave 2>/dev/null || true
echo "Polling for ready=false..."

for i in 1 2 3 4 5 6 7 8 9 10; do
  READY=$(kubectl get pod redis-with-probe \
    -o jsonpath='{.status.containerStatuses[0].ready}')
  echo "$(date +%T) — ready = $READY"
  [ "$READY" = "false" ] && \
    echo "tcpSocket probe failed — TCP connection refused" && break
  sleep 2
done
```

**Terminal 2 — Expected poll output:**
```
Stopping Redis at 17:08:54
Polling for ready=false...
17:08:55 — ready = true
17:08:57 — ready = false
tcpSocket probe failed — TCP connection refused
```

**Terminal 1 — Expected watch output (full sequence):**
```
NAME               READY   STATUS    RESTARTS   AGE
redis-with-probe   1/1     Running   0          30s      ← probe passing, Redis healthy

redis-with-probe   0/1     Completed   0          2m44s  ← Redis exited cleanly
                            ↑
                        STATUS=Completed — Redis process exited exit 0
                        (redis-cli shutdown nosave = graceful shutdown)
                        READY=0/1 — probe immediately fails (port closed)
                        restartPolicy:Always kicks in immediately

redis-with-probe   0/1     Running     1 (2s ago)   2m45s  ← restart in progress
                                        ↑
                                    RESTARTS=1 — kubelet restarted Redis
                                    Still 0/1 — initialDelaySeconds:5 not elapsed
                                    new container starting up

redis-with-probe   1/1     Running     1 (12s ago)  2m55s  ← new Redis ready
                   ↑
               1/1 — probe fired on new container → port 6379 open → passed
               Full failure window: ~11 seconds (2m44s to 2m55s)
```

> **What the watch output reveals:**
> ```
> 2m44s  STATUS: Completed  READY: 0/1  RESTARTS: 0
>          Redis exited → port closed → readiness probe fails immediately
>
> 2m45s  STATUS: Running    READY: 0/1  RESTARTS: 1
>          New container started → still in initialDelaySeconds window
>
> 2m55s  STATUS: Running    READY: 1/1  RESTARTS: 1
>          New container probed → port open → ready=true
> ```

**Verify full container state AFTER restart:**
```bash
kubectl get pod redis-with-probe \
  -o jsonpath='{.status.containerStatuses[0]}' \
  | python3 -m json.tool
```

**Expected output:**
```json
{
    "name": "redis",
    "ready": true,
    "restartCount": 1,
    "started": true,
    "lastState": {
        "terminated": {
            "exitCode": 0,
            "reason": "Completed",
            "finishedAt": "2026-03-24T21:08:54Z",
            "startedAt": "2026-03-24T21:06:29Z"
        }
    },
    "state": {
        "running": {
            "startedAt": "2026-03-24T21:08:55Z"
        }
    }
}
```

> `restartCount: 1` — Redis was restarted by kubelet (`restartPolicy: Always`).
> `lastState.terminated.exitCode: 0` — Redis exited cleanly (graceful shutdown).
> `lastState.terminated.reason: Completed` — clean exit, not a crash.
> `state.running.startedAt: 21:08:55` — 1 second after the shutdown at `21:08:54`.

**Check Events — and observe the absence of `Unhealthy`:**
```bash
kubectl describe pod redis-with-probe | grep -A 10 "Events:"
```

**Expected output:**
```
Events:
  Type    Reason     Age                    From     Message
  ----    ------     ----                   ----     -------
  Normal  Scheduled  5m34s                  ...      Successfully assigned...
  Normal  Pulling    5m33s                  kubelet  Pulling image "redis:7"
  Normal  Pulled     5m16s                  kubelet  Successfully pulled image...
  Normal  Created    2m50s (x2 over 5m16s)  kubelet  Created container: redis
  Normal  Started    2m50s (x2 over 5m16s)  kubelet  Started container redis
  Normal  Pulled     2m50s                  kubelet  Container image already present
```

> **Why no `Warning Unhealthy` event appears — critical observation:**
>
> The readiness probe DID fail — the poll confirmed `ready=false` at
> `17:08:57`. But no `Unhealthy` event is visible in `kubectl describe`.
> This is expected behaviour, not missing data. Here is exactly why:
>
> ```
> 17:08:54  redis-cli shutdown → Redis exits
>            Port 6379 immediately closes
>
> 17:08:55  restartPolicy:Always triggers immediately
>            Kubelet starts new Redis container
>            (no delay — restartPolicy fires on container exit, not on probe)
>
> 17:08:57  Poll captures ready=false (one probe cycle failed)
>
> 17:09:00  initialDelaySeconds:5 elapses on new container
>            Readiness probe fires on NEW container → port open → passes
>            ready=true restored
>
> ~17:09:05  kubectl describe run AFTER redis is already back up
>            No Unhealthy event visible
> ```
>
> The `Unhealthy` event is attached to the **pod** not the container
> instance. When `describe` was run, Redis had already recovered —
> the probe passed on the new container and Kubernetes cleared the
> failure state. The window was ~11 seconds total.
>
> **This demonstrates a fundamental difference from Part 1 (readiness
> exec):**
>
> ```
> Part 1 (exec readiness):
>   Container process stays alive — failure window is long
>   Unhealthy events accumulate every periodSeconds
>   Events are always visible in describe
>
> Part 4 (tcpSocket readiness + restartPolicy:Always):
>   Redis exits → restartPolicy restarts it immediately
>   New container starts → probe passes → failure window is very short
>   Unhealthy event may not persist or may not be generated at all
>   Watch output is the reliable evidence — STATUS=Completed then RESTARTS=1
> ```
>
> **The watch terminal is the authoritative proof of the failure** —
> `STATUS=Completed` at `2m44s` → `RESTARTS=1` at `2m45s` shows Redis
> stopped and was restarted. The `describe` Events section confirms
> `Created (x2)` and `Started (x2)` — two container starts, one restart.
> `(x2 over 5m16s)` = two container instances ran during the pod's lifetime.

**Cleanup:**
```bash
kubectl delete -f 04-readiness-tcpsocket-redis.yaml
```

---

### Part 5: Startup Probe — Protecting Slow-Starting PostgreSQL

---

### Step 13: Understand the YAML

#### What This Demo Shows

PostgreSQL takes 3–60 seconds to start depending on node resources and
first-time image pull. Without a startup probe, a liveness probe fires
during startup, fails (PostgreSQL not yet accepting connections), and
restarts the container — creating `CrashLoopBackOff`. The startup probe
blocks liveness entirely until PostgreSQL passes the startup check.
After passing once, it stops forever.

**05-startup-probe-postgres.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: postgres-with-startup
spec:
  containers:
    - name: postgres
      image: postgres:17
      env:
        - name: POSTGRES_PASSWORD   # Required — image won't start without it
          value: "demo-password"
        - name: POSTGRES_DB
          value: "demodb"
      ports:
        - containerPort: 5432
      startupProbe:
        tcpSocket:
          port: 5432               # Check if PostgreSQL accepting TCP
        failureThreshold: 12       # 12 × 5s = 60s budget to start
        periodSeconds: 5
        # Blocks liveness + readiness until passes
        # Passes once, then stops forever

      readinessProbe:
        exec:
          command:
            - pg_isready            # PostgreSQL built-in health check
            - -U
            - postgres
        initialDelaySeconds: 0     # Safe — startup passed first
        periodSeconds: 10
        failureThreshold: 3

      livenessProbe:
        exec:
          command:
            - pg_isready
            - -U
            - postgres
        initialDelaySeconds: 0     # Safe — startup passed first
        periodSeconds: 20
        failureThreshold: 3

      resources:
        requests:
          cpu: "100m"
          memory: "128Mi"
        limits:
          cpu: "500m"
          memory: "256Mi"
```

**Key YAML Fields Explained:**

- `startupProbe` fires first and blocks `readinessProbe` and `livenessProbe`
  completely. Their timers do not start at all until startup passes.
- `failureThreshold: 12` × `periodSeconds: 5` = **60 seconds** budget.
- `pg_isready` — PostgreSQL built-in utility. Returns exit 0 when ready
  to accept connections.
- `initialDelaySeconds: 0` on readiness and liveness — safe because their
  timers only start after startup passes.

**Startup budget formula:**
```
Maximum startup time = failureThreshold × periodSeconds
                     = 12             × 5s
                     = 60 seconds

Measure actual startup time → add 25-50% buffer
PostgreSQL: ~5s typical → 60s = 12× buffer
```

---

### Step 14: Deploy and Observe Startup Probe

**Terminal 1 — watch status:**
```bash
kubectl get pods -w
```

**Terminal 2 — apply:**
```bash
kubectl apply -f 05-startup-probe-postgres.yaml
```

**Terminal 1 — Expected output:**
```
NAME                    READY   STATUS              RESTARTS   AGE
postgres-with-startup   0/1     Pending             0          0s
postgres-with-startup   0/1     ContainerCreating   0          0s
postgres-with-startup   0/1     Running             0          41s
                                                                 ↑ first run: image pull ~40s
                                                                   cached: ~3s

postgres-with-startup   0/1     Running             0          45s   ← startup probe firing
                                                                        liveness + readiness BLOCKED

postgres-with-startup   1/1     Running             0          45s   ← startup PASSED ✅
                        ↑                                              startup stops forever
                    1/1 ready                                          readiness + liveness activated
                    RESTARTS=0                                         no restart triggered
```

> **First run note:** postgres:17 image is ~430MB. On first deployment
> the image pull takes ~40 seconds — which is why `Running` appears at
> `41s`. On subsequent runs with cached image, `Running` appears at ~3s
> and `1/1` at ~45s (PostgreSQL startup time). The startup probe budget
> of 60s covers both scenarios.

> `RESTARTS=0` proves the startup probe worked. Without it, liveness
> would have fired during the `0/1` window and killed PostgreSQL.

**Verify all three probes:**
```bash
kubectl describe pod postgres-with-startup | grep -A 5 "Startup:\|Liveness:\|Readiness:"
```

**Expected output:**
```
Liveness:   exec [pg_isready -U postgres] delay=0s timeout=1s period=20s #success=1 #failure=3
Readiness:  exec [pg_isready -U postgres] delay=0s timeout=1s period=10s #success=1 #failure=3
Startup:    tcp-socket :5432 delay=0s timeout=1s period=5s #success=1 #failure=12
```

> `describe` shows probes in alphabetical order (Liveness, Readiness,
> Startup) — not in execution order. Startup always fires first regardless
> of display order.

**Verify full container state:**
```bash
kubectl get pod postgres-with-startup \
  -o jsonpath='{.status.containerStatuses[0]}' \
  | python3 -m json.tool
```

**Expected output:**
```json
{
    "name": "postgres",
    "ready": true,
    "restartCount": 0,
    "started": true,
    "state": {
        "running": {
            "startedAt": "2026-03-24T21:15:57Z"
        }
    }
}
```

**Verify PostgreSQL is accepting connections:**
```bash
kubectl exec postgres-with-startup -- pg_isready -U postgres
# /var/run/postgresql:5432 - accepting connections

kubectl exec postgres-with-startup -- psql -U postgres -c "SELECT version();"
# PostgreSQL 17.9 (Debian ...) ...
```

**Cleanup:**
```bash
kubectl delete -f 05-startup-probe-postgres.yaml
```

---

### Part 6: Probe Parameters — Defaults and Tuning

---

### Step 15: Understand All Five Probe Parameters

#### What This Demo Shows

Deploy with all five parameters explicitly set, read live YAML to confirm
storage, then deploy a minimal probe to see Kubernetes fill in all defaults.

**06-probe-timers-defaults.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: probe-timers-demo
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      ports:
        - containerPort: 80
      readinessProbe:
        httpGet:
          path: /
          port: 80
        initialDelaySeconds: 5
        periodSeconds: 10
        timeoutSeconds: 3
        successThreshold: 1
        failureThreshold: 3
```

```bash
kubectl apply -f 06-probe-timers-defaults.yaml
```

**Verify all five parameters stored correctly:**
```bash
kubectl get pod probe-timers-demo -o yaml | grep -A 15 "readinessProbe"
```


**Expected output (spec.containers section):**
```yaml
readinessProbe:
  failureThreshold: 3
  httpGet:
    path: /
    port: 80
    scheme: HTTP
  initialDelaySeconds: 5
  periodSeconds: 10
  successThreshold: 1
  timeoutSeconds: 3
```


Now deploy with only the minimum — just `httpGet` path and port:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: minimal-probe
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      readinessProbe:
        httpGet:
          path: /
          port: 80
EOF

kubectl get pod minimal-probe -o yaml | grep -A 10 "readinessProbe"
```

**Expected output — Kubernetes fills defaults:**
```yaml
readinessProbe:
  failureThreshold: 3        ← DEFAULT: 3
  httpGet:
    path: /
    port: 80
    scheme: HTTP
  periodSeconds: 10          ← DEFAULT: 10 seconds
  successThreshold: 1        ← DEFAULT: 1
  timeoutSeconds: 1          ← DEFAULT: 1 second
```

> **Note:** `initialDelaySeconds` is `0` (the default),
> Kubernetes does NOT included it in the stored YAML — it is omitted
> entirely. 

**Probe Parameters Reference:**

| Parameter | Default | Stored when default? | What it controls |
|-----------|---------|---------------------|-----------------|
| `initialDelaySeconds` | `0` | No — omitted | Wait after container starts before first probe |
| `periodSeconds` | `10` | Yes | Interval between probe attempts |
| `timeoutSeconds` | `1` | Yes | Max wait for probe response |
| `successThreshold` | `1` | Yes | Consecutive successes to flip to healthy |
| `failureThreshold` | `3` | Yes | Consecutive failures to flip to unhealthy |

> **`successThreshold` for liveness MUST be 1.** Setting it higher causes
> the Kubernetes API server to reject the pod spec with a validation error
> at admission — enforced, not just convention.

**Cleanup:**
```bash
kubectl delete -f 06-probe-timers-defaults.yaml
kubectl delete pod minimal-probe
```

---

### Part 7: Readiness Gates — Theory

---

### Step 16: What Readiness Gates Are (and Why They Exist)

Readiness probes solve application-level health checking. But there is a gap:
what if the pod's containers are all healthy, but an external system is not?

**The concrete problem:**

```
Rolling update: new pod replaces old pod

Step 1: New pod deployed
  → Readiness probe passes ✅
  → Kubernetes marks new pod Ready ✅

Step 2: Old pod terminated
  → Old pod is removed ✅

The gap:
  → AWS ALB has NOT yet registered the new pod as a healthy backend target
  → It takes 10-30s for ALB to run its own health checks and add the pod
  → During this window: traffic hits the new pod → connection refused
  → Service outage for ~10-30 seconds even though pod is "Ready"
```

> **"Old pod"** refers to the previous version of the pod that was serving
> traffic before the rolling update — it is terminated after the new pod
> passes its readiness probe.

The readiness probe cannot know about the ALB's target group health status.
Only the AWS Load Balancer Controller knows that. **Readiness Gates** solve
this by allowing external controllers to hold a pod in Not Ready state until
their own external condition is satisfied.

---

#### How Readiness Gates Work

```yaml
spec:
  readinessGates:
    - conditionType: "target-health.elbv2.k8s.aws/my-tg-group"
```

> **Is this user-defined?** The `conditionType` string must match exactly
> what the external controller uses — you copy it from the controller's
> documentation. AWS LBC defines `target-health.elbv2.k8s.aws/...` —
> you use their exact string. You do not invent the string.

> **Do you add this manually to your pods?** No — you never add readiness
> gates directly. External controllers inject them automatically via a
> **mutating admission webhook**. When you annotate your Ingress or Service
> correctly, the AWS LBC webhook intercepts pod creation and patches the
> pod spec to add the readiness gate. You configure the controller — the
> controller modifies your pods.

```
How it flows with AWS LBC:

1. You create an Ingress with ALB annotations
2. AWS LBC's admission webhook intercepts new pod creation
3. Webhook patches pod spec — adds readinessGates entry
4. Pod starts → readiness probe passes → pod is ContainersReady=True
5. BUT Ready=False because readiness gate condition not yet True
6. AWS LBC registers pod with ALB, ALB runs health checks (~10-30s)
7. ALB confirms pod healthy → LBC patches pod condition to True
8. Now Ready=True — pod joins Service endpoints
9. No traffic gap between old pod removal and new pod readiness
```

**Real-world systems that use readiness gates:**

| System | What the gate checks |
|--------|---------------------|
| **AWS Load Balancer Controller** | Pod registered and healthy in ALB/NLB target group |
| **Istio Service Mesh** | Envoy proxy sidecar fully configured and ready |
| **Argo Rollouts** | Canary/blue-green traffic shift confirmed healthy |
| **AWS VPC Lattice** | Pod healthy in VPC Lattice target group |

```
Readiness Probe →  Kubelet asks container: "are you healthy?"
Readiness Gate  →  External controller tells Kubernetes: "I'm ready for this pod"
```

The `READINESS GATES` column in `kubectl get pods -o wide` shows `n/n`
when all gates are satisfied — this column is only shown when at least
one pod in the namespace has readiness gates configured.

> **CKA exam:** Readiness gates are not in the CKA exam syllabus.
> Understanding what they solve and which systems use them is sufficient.

---

## Experiments to Try

1. **Verify readiness removes pod from Service endpoints:**
   ```bash
   kubectl apply -f 04-readiness-tcpsocket-redis.yaml
   kubectl expose pod redis-with-probe --port=6379
   kubectl get endpoints redis-with-probe   # pod IP listed

   # Force probe failure
   kubectl exec redis-with-probe -- redis-cli shutdown nosave || true

   # Poll for endpoint removal
   for i in 1 2 3 4 5 6; do
     echo "$(date +%T) endpoints:"
     kubectl get endpoints redis-with-probe
     sleep 5
   done
   # Pod IP disappears from endpoints within periodSeconds
   ```

2. **Startup probe protection — WITHOUT probe first:**
   ```bash
   # Edit 05-startup-probe-postgres.yaml
   # Remove the startupProbe block
   # Set livenessProbe initialDelaySeconds: 2
   # Apply and watch — liveness fires before postgres is ready → CrashLoopBackOff
   kubectl get pods -w

   # Restore startupProbe — RESTARTS=0 because liveness is blocked
   ```

3. **gRPC probe (v1.24+ stable):**
   ```yaml
   livenessProbe:
     grpc:
       port: 9090
       service: my-grpc-service   # optional
     initialDelaySeconds: 10
     periodSeconds: 15
   ```

---

## Common Questions

### Q: Why does `READY=0/1` show `Running` in STATUS when readiness fails?

**A:** `STATUS` (pod phase) and `READY` (container ready flag) are
independent. Phase `Running` means the container process is alive.
`READY=0/1` means the readiness probe is failing — the app is not ready.

### Q: How do I know the probe is actually firing if success is silent?

**A:** Check `ContainersReady` condition `lastTransitionTime` — the timestamp
shows when the probe last changed the state. For failures, `Warning Unhealthy`
events in `kubectl describe pod` show each execution and its result.

### Q: Can readiness and liveness use different mechanisms on the same container?

**A:** Yes — and it's common. `httpGet` for liveness, `exec` for readiness.
Demonstrated in Part 3.

### Q: Why did `initialDelaySeconds: 0` not appear in the minimal probe YAML?

**A:** Kubernetes omits fields that are set to their zero value in the stored
YAML. `0` is the zero value for `initialDelaySeconds`, so it is not stored.
This does not mean the field is missing — it defaults to `0` when absent.

### Q: Should I always add both readiness and liveness probes?

**A:** For production: yes. Readiness is the minimum. Liveness for apps that
can deadlock. Startup only for slow-starting apps.

---

## What You Learned

In this lab, you:

- ✅ Explained why `Running` is not enough — process alive ≠ app healthy
- ✅ Traced the full chain: probe → `ready` flag → conditions → endpoints
- ✅ Configured readiness probe (`exec`) — used polling loop to reliably
     capture `ready` flag transitions
- ✅ Proved probe success is completely silent — only `READY=1/1`,
     `ready=true`, and condition timestamps prove it
- ✅ Proved probe failure IS visible — `Warning Unhealthy` events show
     the exact probe mechanism error message
- ✅ Observed that False conditions include `message` and `reason` fields
     that disappear when the condition flips back to True
- ✅ Used `containerStatuses[0]` as a single JSON object query — one
     command shows `ready`, `restartCount`, `state`, and `lastState`
- ✅ Distinguished scalar vs object jsonpath output — scalars never
     piped to `python3 -m json.tool`
- ✅ Configured liveness probe (`httpGet`) using `agnhost:2.40` — watched
     RESTARTS climb and CrashLoopBackOff appear
- ✅ Proved readiness and liveness run in parallel with independent timers —
     `0/1 Running RESTARTS=0` is the definitive evidence
- ✅ Configured `tcpSocket` probes on Redis — TCP-level vs application-level
     health checking distinction
- ✅ Protected slow-starting PostgreSQL with startup probe — `RESTARTS=0`
     despite image pull + slow startup
- ✅ Observed that `initialDelaySeconds: 0` is not stored in pod YAML
- ✅ Explained readiness gates — what they solve, how controllers inject
     them via admission webhooks, which systems use them

**Key Takeaway:** Probes bridge the gap between process-level health
(Running) and application-level health (ready). Readiness removes from
traffic without restarting — `RESTARTS=0` is the proof. Liveness restarts
the broken container — `RESTARTS` climbing and `CrashLoopBackOff` is the
proof. Startup protects initialization — `RESTARTS=0` despite slow startup
is the proof. Probe success is silent. Probe failure is always visible in
`Warning Unhealthy` events. Always query `containerStatuses[0]` as a full
JSON object — one command shows the complete picture including `lastState`.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get pods -w` | Watch READY column and RESTARTS live |
| `kubectl describe pod <n> \| grep -A5 "Startup:\|Liveness:\|Readiness:"` | View all probe configs |
| `kubectl get pod <n> -o yaml \| grep -A15 "readinessProbe"` | Full probe config with defaults |
| `kubectl get pod <n> -o jsonpath='{.status.containerStatuses[0]}' \| python3 -m json.tool` | Full container status — ready, restartCount, state, lastState |
| `kubectl get pod <n> -o jsonpath='{.status.containerStatuses[0].ready}'` | Container ready flag (scalar — no json.tool) |
| `kubectl get pod <n> -o yaml \| grep -A30 "conditions:"` | All five conditions with timestamps and reason fields |
| `kubectl describe pod <n> \| grep -A8 "Events:"` | Probe failure events (Unhealthy, Killing, BackOff) |

---

## Troubleshooting

**Pod stuck at `0/1 Running` and RESTARTS=0?**
```bash
kubectl describe pod <n>
# Look for: "Readiness probe failed" in Events
# → readiness failing — check what the probe checks
# → liveness passing (no restart) → container is alive
```

**RESTARTS climbing and CrashLoopBackOff appearing?**
```bash
kubectl describe pod <n>
# Look for: "Liveness probe failed" + "Killing" + "BackOff" events
kubectl logs <n> --previous
# App logs from the previous (crashed) run
```

**Pod in `CrashLoopBackOff` despite startup probe?**
```bash
kubectl describe pod <n>
# Startup probe exhausted its budget (failureThreshold × periodSeconds)
# Fix: increase failureThreshold or periodSeconds
```

**`Expecting value: line 1 column 1 (char 0)` from python3 -m json.tool?**
```bash
# You piped a scalar string to json.tool — use the full object instead
kubectl get pod <n> \
  -o jsonpath='{.status.containerStatuses[0]}' \
  | python3 -m json.tool
```

---

## CKA Certification Tips

✅ **Probe → Outcome — never confuse:**
```
Readiness fails → removed from LB, NO restart, RESTARTS=0
Liveness fails  → container restarted, RESTARTS increments
Startup fails   → container restarted, RESTARTS increments
```

✅ **Events per probe failure type:**
```
Readiness fails → Warning Unhealthy only
Liveness fails  → Warning Unhealthy + Normal Killing + Warning BackOff
```

✅ **Probe success is silent — verify indirectly:**
```bash
# READY=1/1, ready=true, ContainersReady=True
kubectl get pod <n> -o jsonpath='{.status.containerStatuses[0]}' | python3 -m json.tool
```

✅ **Always use full object query:**
```bash
kubectl get pod <n> \
  -o jsonpath='{.status.containerStatuses[0]}' \
  | python3 -m json.tool
# ready, restartCount, state, AND lastState all in one command
```

✅ **`kubectl set probe` — fastest way in the exam:**
```bash
kubectl set probe deploy/my-app \
  --readiness \
  --http-get-path=/ready \
  --http-get-port=8080 \
  --initial-delay-seconds=5
```

✅ **Startup budget formula:**
```
failureThreshold × periodSeconds = maximum startup time
12 × 5s = 60s
30 × 10s = 300s
```

✅ **Probe skeletons:**
```yaml
# Readiness (httpGet)
readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10

# Liveness (exec)
livenessProbe:
  exec:
    command: ["cat", "/tmp/healthy"]
  initialDelaySeconds: 5
  periodSeconds: 10

# Startup (tcpSocket)
startupProbe:
  tcpSocket:
    port: 5432
  failureThreshold: 12
  periodSeconds: 5
```

✅ **`successThreshold` for liveness MUST be 1 — API server enforces:**
```yaml
livenessProbe:
  successThreshold: 1   # only valid value for liveness
```

✅ **Probes are per-container — inside `containers[]`:**
```yaml
containers:
  - name: my-app
    image: nginx:1.27
    readinessProbe:      # ← inside container spec
      httpGet:
        path: /
        port: 80
```

✅ **`initialDelaySeconds: 0` is not stored in YAML** — it is the zero
value and is omitted. All other defaults (periodSeconds, timeoutSeconds,
successThreshold, failureThreshold) ARE stored.