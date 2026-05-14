# Pod and Container Basics — The Fundamental Execution Unit

## Lab Overview

A Pod is the smallest deployable unit in Kubernetes. Everything in Kubernetes —
Deployments, StatefulSets, DaemonSets, Jobs — ultimately creates Pods. Before
you can understand any workload controller, you must understand what a Pod is,
what it contains, and how it behaves.

This lab covers the Pod spec in depth: containers, init containers, restart
policies, resource requests and limits, image pull policies, pod phases, and
container states. You will create pods directly (naked pods) to observe the
mechanics without a controller abstracting them away.

**What you'll learn:**
- Pod anatomy: what a Pod spec contains and why
- Container spec: image, command, args, env, ports, resources, volumeMounts
- Init containers: run before app containers, must succeed
- Pod phases: Pending, Running, Succeeded, Failed, Unknown
- Container states: Waiting, Running, Terminated
- `restartPolicy`: Always, OnFailure, Never — and which workloads use which
- Resource requests vs limits — what they mean and why both matter
- Image pull policy: Always, IfNotPresent, Never
- Why naked pods are not used in production

## Prerequisites

**Required:**
- Minikube `3node` profile running
- kubectl configured for `3node`
- Completion of `01-cluster-architecture` (understand what kubelet does)

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain a Pod and why it is the atomic unit of scheduling in Kubernetes
2. ✅ Explain every field in a container spec
3. ✅ Explain init containers and their ordering guarantee
4. ✅ Explain all five pod phases and when each occurs
5. ✅ Explain `restartPolicy` values and which workload uses which
6. ✅ Explain resource requests vs limits and their effects on scheduling and QoS
7. ✅ Create and inspect pods with `kubectl run` and YAML
8. ✅ Read pod events and container logs for troubleshooting
9. ✅ Explain why naked pods should not be used in production

## Directory Structure

```
03-pod-container-basics/
├── README.md
└── src/
    ├── basic-pod.yaml          # Single-container pod with all common fields
    ├── init-container-pod.yaml # Pod with init container before app container
    └── multi-env-pod.yaml      # Pod demonstrating env, envFrom, downward API
```

---

## Understanding Pods

### What Is a Pod?

```
A Pod is a group of one or more containers that:
  - Share the same network namespace  → same IP address and port space
  - Share the same IPC namespace      → can communicate via shared memory
  - Can share storage volumes         → containers in the pod can mount
                                         the same volume

Pod = the unit of scheduling (the scheduler assigns pods to nodes)
Pod = the unit of scaling (HPA scales pod count)
Pod = the unit of deployment (rolling update replaces pods)

Most pods have ONE container.
Multi-container pods (sidecar pattern) exist — covered in 05-pod-deep-dive.
```

### Why Not Just Schedule Containers Directly?

```
The Pod abstraction solves several problems:

1. Co-location: A log shipper container needs to run on the SAME node as
   the app container to read its log files. A Pod groups them.

2. Shared networking: Two containers in a Pod share localhost. The sidecar
   can call the main app via localhost:8080 — no service discovery needed.

3. Atomic scheduling: The scheduler assigns a Pod to a node. All containers
   in the Pod land on the same node. You cannot split a Pod across nodes.

4. Lifecycle coupling: All containers in a Pod start and stop together
   (barring restartPolicy differences). They share a fate.
```

---

## Pod Spec — Every Field Explained

### basic-pod.yaml

**basic-pod.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-pod
  namespace: default
  labels:
    app: nginx                  # Labels for selector matching
    version: "1.27"
  annotations:
    description: "Demo pod for core concepts lab"
spec:
  # ── Scheduling directives ───────────────────────────────────────────
  nodeName: ""                  # Leave empty — scheduler chooses the node
                                # Set to a specific node for manual scheduling
                                # (covered in 06-pod-scheduling/01-manual-scheduling)

  # ── Restart policy ─────────────────────────────────────────────────
  restartPolicy: Always
  # Always:    Restart any container that stops, regardless of exit code
  #            Use with: Deployments, DaemonSets, StatefulSets
  # OnFailure: Restart only if exit code != 0
  #            Use with: Jobs (restartPolicy: OnFailure)
  # Never:     Never restart. Container exits → pod stays in Completed/Failed
  #            Use with: Jobs (restartPolicy: Never), one-shot tasks

  # ── Termination grace period ────────────────────────────────────────
  terminationGracePeriodSeconds: 30
  # When a pod is deleted:
  #   1. Pod gets Terminating status — no new traffic routed to it
  #   2. kubelet sends SIGTERM to all containers
  #   3. Containers have terminationGracePeriodSeconds to shut down cleanly
  #   4. After the period: SIGKILL is sent regardless
  # Set higher for databases/stateful apps that need time to flush

  # ── DNS policy ─────────────────────────────────────────────────────
  dnsPolicy: ClusterFirst       # Default: use CoreDNS for DNS resolution
  # ClusterFirst:     Prefer cluster DNS, fall back to upstream DNS
  # ClusterFirstWithHostNet: Same but for pods using hostNetwork
  # None:             All DNS config from dnsConfig field
  # Default:          Use node's DNS resolver directly (not CoreDNS)

  # ── Service account ─────────────────────────────────────────────────
  serviceAccountName: default   # Which ServiceAccount's token to mount
                                # Gives the pod an identity for RBAC
                                # Covered in 12-rbac/03-serviceaccounts

  # ── Containers ──────────────────────────────────────────────────────
  containers:
    - name: nginx               # Container name — unique within the pod
      image: nginx:1.27         # image:tag — always specify an explicit tag
                                # Never use :latest in production

      # ── Image pull policy ────────────────────────────────────────────
      imagePullPolicy: IfNotPresent
      # Always:        Always pull from registry, even if image exists locally
      #                Use for: :latest tag, ensuring freshness
      # IfNotPresent:  Only pull if not already on the node (default for tagged images)
      #                Use for: immutable tags (1.27, sha256:...)
      # Never:         Never pull — must exist on node already
      #                Use for: air-gapped environments, pre-loaded images

      # ── Command and args ─────────────────────────────────────────────
      # command overrides the Dockerfile ENTRYPOINT
      # args overrides the Dockerfile CMD
      # If neither is set: use the image's ENTRYPOINT and CMD
      # command: ["nginx", "-g", "daemon off;"]
      # args: []

      # ── Ports ────────────────────────────────────────────────────────
      ports:
        - name: http            # Named port — Services can reference by name
          containerPort: 80     # Port the container listens on
          protocol: TCP         # TCP (default), UDP, SCTP
      # Note: ports here are informational only — they do NOT open firewall rules
      # Containers are reachable on any port they listen on regardless of this spec

      # ── Environment variables ────────────────────────────────────────
      env:
        - name: ENV_NAME
          value: "production"   # Direct value

        - name: POD_NAME        # Downward API — injects pod metadata
          valueFrom:
            fieldRef:
              fieldPath: metadata.name

        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace

        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP

        - name: CPU_REQUEST     # Downward API — injects resource values
          valueFrom:
            resourceFieldRef:
              containerName: nginx
              resource: requests.cpu

        # From a Secret (covered in 04-configmaps-secrets):
        # - name: DB_PASSWORD
        #   valueFrom:
        #     secretKeyRef:
        #       name: db-secret
        #       key: password

      # ── Resource requests and limits ─────────────────────────────────
      resources:
        requests:
          cpu: "100m"           # 100 millicores = 0.1 CPU core
          memory: "128Mi"       # 128 MiB
        limits:
          cpu: "500m"           # 500 millicores = 0.5 CPU core
          memory: "256Mi"       # 256 MiB
        # requests: minimum guaranteed resources (used for SCHEDULING)
        #   The scheduler places the pod on a node that has >= requests available
        # limits: maximum allowed resources (enforced by kernel cgroups)
        #   CPU limit: process is CPU-throttled at the limit (not killed)
        #   Memory limit: process is OOM-killed if it exceeds the limit
        #
        # QoS Classes (determine eviction order under pressure):
        #   Guaranteed: requests == limits for ALL containers  ← safest
        #   Burstable:  requests < limits for at least one container
        #   BestEffort: NO requests or limits set              ← evicted first

      # ── Lifecycle hooks ──────────────────────────────────────────────
      lifecycle:
        postStart:              # Runs immediately after container starts
          exec:                 # exec: run command, httpGet: call endpoint
            command: ["/bin/sh", "-c", "echo Container started >> /tmp/startup.log"]
        preStop:                # Runs before SIGTERM is sent
          exec:
            command: ["/bin/sh", "-c", "nginx -s quit; sleep 5"]
          # preStop gives a chance to flush connections before the kill signal
          # Useful for graceful shutdown of HTTP servers, queue consumers

      # ── Volume mounts ────────────────────────────────────────────────
      # volumeMounts:
      #   - name: config-volume       # must match volumes[].name below
      #     mountPath: /etc/nginx/conf.d
      #     readOnly: true

  # ── Volumes ─────────────────────────────────────────────────────────
  # volumes:
  #   - name: config-volume
  #     configMap:
  #       name: nginx-config        # ConfigMap must exist in same namespace
```

---

### init-container-pod.yaml

**init-container-pod.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: init-demo
  namespace: default
spec:
  restartPolicy: Never

  # ── Init Containers ─────────────────────────────────────────────────
  # Init containers run BEFORE app containers, in ORDER.
  # Each init container must succeed (exit 0) before the next starts.
  # If any init container fails → pod restarts (per restartPolicy).
  # App containers do NOT start until ALL init containers succeed.
  #
  # Use cases:
  #   - Wait for a dependency (database, service) to be ready
  #   - Pre-populate a shared volume with data
  #   - Perform schema migrations before the app starts
  #   - Clone a git repo that the app container will serve
  initContainers:
    - name: wait-for-service
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "Waiting for DNS to resolve..."
          until nslookup kubernetes.default.svc.cluster.local; do
            echo "DNS not ready yet, retrying in 2s..."
            sleep 2
          done
          echo "DNS is ready — proceeding to app container"
      resources:
        requests:
          cpu: "50m"
          memory: "32Mi"

    - name: copy-config
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "Init container 2: preparing configuration..."
          echo "server { listen 80; location / { return 200 'Hello from init-demo\n'; } }" \
            > /work-dir/default.conf
          echo "Config written"
      volumeMounts:
        - name: work-dir
          mountPath: /work-dir
      resources:
        requests:
          cpu: "50m"
          memory: "32Mi"

  # ── App Container ────────────────────────────────────────────────────
  # Only starts after BOTH init containers have succeeded
  containers:
    - name: nginx
      image: nginx:1.27
      ports:
        - containerPort: 80
      volumeMounts:
        - name: work-dir
          mountPath: /etc/nginx/conf.d
          readOnly: true
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"
        limits:
          cpu: "100m"
          memory: "128Mi"

  volumes:
    - name: work-dir
      emptyDir: {}              # Shared between init and app containers
                                # Lives as long as the pod — deleted with it
```

### multi-env-pod.yaml

**multi-env-pod.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: env-demo
  namespace: default
  labels:
    app: env-demo
spec:
  restartPolicy: Never
  containers:
    - name: env-printer
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "=== Direct env vars ==="
          echo "APP_ENV:     $APP_ENV"
          echo "APP_VERSION: $APP_VERSION"
          echo ""
          echo "=== Downward API — pod metadata ==="
          echo "POD_NAME:      $POD_NAME"
          echo "POD_NAMESPACE: $POD_NAMESPACE"
          echo "POD_IP:        $POD_IP"
          echo "NODE_NAME:     $NODE_NAME"
          echo ""
          echo "=== Downward API — resource values ==="
          echo "CPU_REQUEST:    $CPU_REQUEST"
          echo "MEMORY_LIMIT:   $MEMORY_LIMIT"
          sleep 3600
      env:
        # Direct values
        - name: APP_ENV
          value: "development"
        - name: APP_VERSION
          value: "1.0.0"
        # Downward API — pod metadata
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        # Downward API — resource values
        - name: CPU_REQUEST
          valueFrom:
            resourceFieldRef:
              containerName: env-printer
              resource: requests.cpu
        - name: MEMORY_LIMIT
          valueFrom:
            resourceFieldRef:
              containerName: env-printer
              resource: limits.memory
      resources:
        requests:
          cpu: "100m"
          memory: "64Mi"
        limits:
          cpu: "200m"
          memory: "128Mi"
```

---

## Pod Phases and Container States

### Pod Phases

```
Pending:    Pod accepted by Kubernetes but not yet running.
            Possible reasons:
              - Scheduler has not yet assigned it to a node
              - Images are being pulled
              - Init containers are running
              - Persistent volumes not yet bound

Running:    Pod has been bound to a node. At least one container is
            running, or is starting/restarting.

Succeeded:  All containers exited with code 0 and restartPolicy is
            not Always. Terminal state — pod will not restart.
            Typical for completed Jobs.

Failed:     All containers terminated, at least one with non-zero exit
            code or was killed by the system. Terminal state.

Unknown:    Pod state cannot be determined — usually means the node
            the pod was on is unreachable. kubelet cannot report status.
```

### Container States

```
Waiting:    Container is not yet running.
            Reason field explains why:
              ContainerCreating  → image being pulled, volumes being mounted
              PodInitializing    → init containers still running
              CrashLoopBackOff   → container keeps crashing, backing off
              ImagePullBackOff   → image pull failed, retrying with backoff
              ErrImagePull       → image pull failed (bad name, auth error)

Running:    Container is executing. startedAt timestamp is set.

Terminated: Container ran and stopped.
            exitCode: 0  → success
            exitCode: non-zero → failure
            Reason: Completed, Error, OOMKilled, etc.
```

### CrashLoopBackOff

```
This is one of the most common pod problems.
It means: container is crashing, Kubernetes is restarting it,
          but applying an exponential backoff between attempts.

Backoff durations: 10s, 20s, 40s, 80s, 160s, 300s (capped)
The RESTARTS counter in kubectl get pods shows how many times it restarted.

Common causes:
  - Application crashes on startup (bug, missing config, bad env var)
  - Command/args are wrong — container exits immediately
  - Port already in use (rare — each pod has its own network namespace)
  - Missing file or dependency the app needs at startup
  - OOM — process killed immediately on start due to memory limit too low

Debugging:
  kubectl logs <pod>                # current container logs
  kubectl logs <pod> --previous     # logs from PREVIOUS (crashed) container
  kubectl describe pod <pod>        # events section shows the restart reason
  kubectl get pod <pod> -o yaml     # full spec + status including exit code
```

---

## Lab Step-by-Step Guide

### Step 1: Create and observe a basic pod

```bash
cd 03-pod-container-basics/src
kubectl apply -f basic-pod.yaml

# Watch the pod start
kubectl get pod nginx-pod -w
```

**Expected lifecycle:**
```
NAME        READY   STATUS              RESTARTS   AGE
nginx-pod   0/1     Pending             0          0s   ← scheduler assigning
nginx-pod   0/1     ContainerCreating   0          2s   ← image pulling/running
nginx-pod   1/1     Running             0          5s   ← ready ✅
```

```bash
# Inspect the pod spec and status
kubectl describe pod nginx-pod
```

**Key sections in describe output:**
```
Node:         3node-m02/...   ← which node the scheduler chose
Status:       Running
IP:           10.244.1.x      ← pod IP (from pod network CIDR)
Containers:
  nginx:
    State:     Running
    Ready:     True
    Image:     nginx:1.27
    Limits/Requests: as set in YAML
Conditions:
  PodScheduled:   True   ← scheduler assigned a node
  Initialized:    True   ← init containers (none) done
  ContainersReady: True  ← all containers passed readiness
  Ready:          True   ← pod is ready to serve traffic
Events:
  Scheduled  Successfully assigned to 3node-m02
  Pulling    Pulling image nginx:1.27
  Pulled     Successfully pulled image
  Created    Created container nginx
  Started    Started container nginx
```

---

### Step 2: Verify environment variables with Downward API

```bash
kubectl apply -f multi-env-pod.yaml

# Wait for it to start
kubectl get pod env-demo -w

# Once running, exec in and check the env vars
kubectl exec env-demo -- env | grep -E "APP_|POD_|NODE_|CPU_|MEMORY_"
```

**Expected:**
```
APP_ENV=development
APP_VERSION=1.0.0
POD_NAME=env-demo
POD_NAMESPACE=default
POD_IP=10.244.x.x
NODE_NAME=3node-m02
CPU_REQUEST=100m
MEMORY_LIMIT=134217728   ← 128Mi in bytes
```

The Downward API injects runtime values that are not known at YAML
authoring time — pod IP, node name, actual resource values.

---

### Step 3: Observe init containers running in sequence

```bash
kubectl apply -f init-container-pod.yaml

# Watch in two terminals
# Terminal 1
kubectl get pod init-demo -w

# Terminal 2
kubectl get events --field-selector involvedObject.name=init-demo -w
```

**Terminal 1 — expected sequence:**
```
NAME        READY   STATUS                  AGE
init-demo   0/1     Pending                 0s
init-demo   0/1     Init:0/2                2s   ← first init container running
init-demo   0/1     Init:1/2                8s   ← second init container running
init-demo   0/1     PodInitializing         12s  ← init done, app starting
init-demo   1/1     Running                 15s  ← app container ready ✅
```

`Init:0/2` means: 0 of 2 init containers done.
`Init:1/2` means: 1 of 2 init containers done.

```bash
# View logs from each init container
kubectl logs init-demo -c wait-for-service
kubectl logs init-demo -c copy-config
kubectl logs init-demo -c nginx
```

---

### Step 4: Observe resource requests and QoS class

```bash
kubectl get pod nginx-pod -o jsonpath='{.status.qosClass}'
# Burstable   (requests < limits — not guaranteed, not best-effort)

# Create a Guaranteed QoS pod (requests == limits)
kubectl run guaranteed-pod --image=nginx:1.27 \
  --requests='cpu=100m,memory=128Mi' \
  --limits='cpu=100m,memory=128Mi'

kubectl get pod guaranteed-pod -o jsonpath='{.status.qosClass}'
# Guaranteed

# Under memory pressure, Kubernetes evicts BestEffort first,
# then Burstable, then Guaranteed (never evicted if possible)
```

---

### Step 5: Observe a failing pod and debug it

```bash
# Create a pod that crashes immediately
kubectl run crasher --image=busybox:1.36 -- sh -c "echo 'About to crash'; exit 1"

kubectl get pod crasher -w
```

**Expected — CrashLoopBackOff after a few restarts:**
```
NAME      READY   STATUS             RESTARTS   AGE
crasher   0/1     Error              0          2s
crasher   0/1     CrashLoopBackOff   1          10s
crasher   0/1     Error              2          30s
crasher   0/1     CrashLoopBackOff   3          50s
```

```bash
# Read the crash logs
kubectl logs crasher
# About to crash

# Read PREVIOUS container's logs (when currently in backoff)
kubectl logs crasher --previous
# About to crash

# See the exit code in describe
kubectl describe pod crasher | grep -A5 "Last State:"
# Last State:  Terminated
#   Reason:    Error
#   Exit Code: 1

# Clean up
kubectl delete pod crasher
```

---

### Step 6: Pod lifecycle — exec, copy, port-forward

```bash
# Exec into a running container
kubectl exec -it nginx-pod -- bash
# (inside) nginx -v; exit

# Copy a file from pod to local
kubectl cp nginx-pod:/etc/nginx/nginx.conf ./nginx-from-pod.conf
cat nginx-from-pod.conf | head -5

# Access the pod directly (without a Service)
kubectl port-forward pod/nginx-pod 8080:80 &
curl http://localhost:8080
# Returns nginx welcome page
kill %1  # stop port-forward
```

---

### Step 7: Why naked pods are not used in production

```bash
# Naked pod: created directly, not managed by a controller

# Delete the pod
kubectl delete pod nginx-pod

# What happens? It is GONE. No controller recreates it.
kubectl get pod nginx-pod
# Error from server (NotFound)

# With a Deployment: controller notices the pod is gone and recreates it
kubectl create deployment nginx-managed --image=nginx:1.27
kubectl get pods -l app=nginx-managed
# 1 pod running

kubectl delete pod -l app=nginx-managed
kubectl get pods -l app=nginx-managed
# New pod already being created — controller recreated it
```

**Rule:** Never create naked pods in production.
Always use a controller: Deployment, StatefulSet, DaemonSet, or Job.
The only legitimate naked pods are one-shot debugging pods
(`kubectl run debug --rm -it --image=busybox -- sh`).

---

### Step 8: Cleanup

```bash
kubectl delete pod nginx-pod init-demo env-demo guaranteed-pod 2>/dev/null || true
kubectl delete deployment nginx-managed 2>/dev/null || true
rm -f nginx-from-pod.conf
```

---

## Common Questions

### Q: Can two containers in a Pod listen on the same port?
**A:** No — they share the same network namespace, so the same port
space. If both containers try to bind port 80, one will fail to start
with "address already in use." Use different ports per container.

### Q: What is the difference between command and args?
**A:** `command` overrides the Docker image's `ENTRYPOINT`. `args`
overrides the Docker image's `CMD`. If you set only `args`, the image's
ENTRYPOINT runs with your args. If you set only `command`, it runs as-is
with no args (unless you also set `args`). If you set both, both override.

### Q: Can I update a pod spec after creation?
**A:** Most fields are immutable after creation. You cannot change the
container image, command, or most spec fields on a running pod. That is
why Deployments use rolling updates — they replace pods with new ones
rather than mutating running pods.

### Q: What is the difference between READY and STATUS in kubectl get pods?
**A:** `READY` is `ready_containers/total_containers` — how many containers
have passed their readiness probe. `STATUS` is the pod phase (Running,
Pending, CrashLoopBackOff, etc.). A pod can show `STATUS: Running` but
`READY: 0/1` if the readiness probe is failing.

---

## What You Learned

In this lab, you:
- ✅ Explained a Pod as the atomic scheduling unit — containers share network and can share storage
- ✅ Explained every container spec field: image, imagePullPolicy, command, args, env, ports, resources, lifecycle
- ✅ Explained init containers — ordered, must succeed, block app containers
- ✅ Explained all five pod phases (Pending, Running, Succeeded, Failed, Unknown)
- ✅ Explained container states (Waiting, Running, Terminated) and CrashLoopBackOff
- ✅ Explained restartPolicy: Always (Deployments), OnFailure/Never (Jobs)
- ✅ Explained requests (scheduling) vs limits (kernel enforcement) and QoS classes
- ✅ Used Downward API to inject pod metadata into env vars
- ✅ Debugged a crashing pod with kubectl logs --previous and kubectl describe
- ✅ Proved naked pods are not self-healing — use controllers in production

**Key Takeaway:** A Pod is a wrapper around one or more containers that share
identity (network, IPC) and optionally storage. The Pod spec is the contract
between you and the kubelet — everything from how many CPUs to how long to wait
before killing the container. All workload controllers (Deployment, StatefulSet,
DaemonSet, Job) exist to manage the Pod lifecycle for you — they add
self-healing, rolling updates, and scheduling intelligence on top of the raw Pod.