# Demo: 01-core-concepts/03-pod-container-basics — Pod and Container Basics

## Lab Overview

A Pod is the smallest deployable unit in Kubernetes. Everything in Kubernetes —
Deployments, StatefulSets, DaemonSets, Jobs — ultimately creates Pods. Before
you can understand any workload controller, you must understand what a Pod is,
what it contains, how it's built out of Linux primitives, and what actually
happens end-to-end when you create one.

This lab covers the pod-only fundamentals: what a Pod and a container can
each contain, how the sharing between containers in a Pod actually works
under the hood, a minimal-to-essential YAML walkthrough, the full
create-to-terminate lifecycle with every component and field that drives it,
and the `kubectl` commands you'll use to observe all of it. Deeper pod
topics — init containers, multi-container patterns, health probes, and
lifecycle/error states — have their own dedicated demos later in
`05-pod-deep-dive` and are intentionally not covered here.

**What you'll learn:**
- What a Pod actually is — and that it's not the same thing as a container
- Everything a Pod can contain, and everything a container spec can contain
- How Kubernetes actually implements "containers in a Pod share a network" at the Linux level
- A minimal valid Pod vs. an essential, production-reasonable one
- The full end-to-end flow from `kubectl apply` to a running container to termination — every component involved, and which pod/container field drives each step
- The essential `kubectl` commands for creating and inspecting pods, and what their output actually tells you
- Pod phases and container states
- Why naked pods are not used in production

## Prerequisites

**Required:**
- Minikube `3node` profile running
- kubectl configured for `3node`
- Completion of `01-cluster-architecture` (understand what kubelet, kube-scheduler, kube-apiserver, and kube-proxy do at a basic level — this demo goes deeper on how they interact with a single Pod)

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain a Pod and why it's not the same thing as a container
2. ✅ Enumerate what a Pod can contain and what a container spec can contain, including what's deferred to later demos
3. ✅ Explain how Kubernetes implements shared networking/IPC between containers in a Pod using the pause container and Linux namespaces
4. ✅ Explain the difference between a minimal valid Pod and an essential, production-reasonable one
5. ✅ Explain how a Pod's QoS class is calculated from requests/limits and why it determines eviction priority
6. ✅ Explain what `securityContext` controls and what a container's privilege defaults are if you don't set it
7. ✅ Walk through the full end-to-end flow of creating a Pod — every component involved, including admission control, and which field drives each step
8. ✅ Use `kubectl run`, `get`, `describe`, `logs`, `exec`, `cp`, `port-forward`, and `delete` — and read their output correctly
9. ✅ Explain all five pod phases and when each occurs
10. ✅ Debug a failing pod using `kubectl logs --previous` and `kubectl describe`
11. ✅ Explain why naked pods should not be used in production

## Directory Structure

```
01-core-concepts/03-pod-container-basics/
├── README.md
├── src/
│   ├── 01-basic-pod.yaml                          # Single-container pod with essential fields
│   └── break-fix/
│       ├── 01-command-args-crash.yaml          
│       ├── 02-label-selector-typo.yaml         
│       └── 03-bad-image-tag.yaml               
├── 03-pod-container-basics-anki.csv
└── 03-pod-container-basics-quiz.md
```

---

## Recall Check — 02-namespaces

Answer from memory before continuing — no peeking at Demo 02.

1. A pod in `team-b` tries to reach a Service in `team-a` using only the short name `nginx-svc`. Does it resolve? Why or why not?
2. What's the minimum you need to add to a Service name to reach it reliably from a different namespace?
3. What happens to every object inside a namespace when you delete that namespace?

<details>
<summary>Answers</summary>

1. No — DNS names are scoped to the namespace they're created in by default. The short form only resolves within the same namespace.
2. At minimum `<service>.<namespace>` — this works via the pod's DNS search-domain expansion, without needing the full FQDN.
3. Everything inside is deleted too — namespace deletion cascades completely, there is no selective delete.

</details>

---

## Concepts

### What Is a Pod?

```
A Pod is a group of one or more containers that:
  - Share the same network namespace  → same IP address and port space
  - Share the same IPC namespace      → can communicate via shared memory
  - Can share storage volumes         → containers in the pod can mount
                                         the same volume

Pod = the unit of scheduling (the scheduler assigns pods to nodes)
Pod = the unit of scaling — to run multiple instances of an app, you run
      multiple Pods, not one bigger Pod (covered properly once we reach
      Deployments in 02-deployments)
Pod = the unit of deployment (rolling update replaces pods)

Most pods have ONE container.
Multi-container pods (sidecar pattern) exist — covered in 05-pod-deep-dive.
```

A Pod is not a process — it's an environment for running one or more
containers. This distinction matters in practice: if a container inside a
pod crashes and restarts, the **Pod itself is not recreated** — same Pod
object, same IP address, same UID, just a new container instance running
inside it. "The pod restarted" and "a container in the pod restarted" are
often used loosely as if they mean the same thing — they don't. (The
**Pod and Container Internals** section below explains exactly how this
sharing is implemented, and why it's able to survive a container restart.)

---

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

### Anatomy of a Pod — What a Pod Can Contain

**Fields directly on the Pod object:**

| Field | Notes |
|---|---|
| `apiVersion`, `kind` | Top-level, not under `metadata` or `spec` — `v1`/`Pod` for a bare Pod. Tells the API server which schema to validate the rest of the manifest against. |
| `metadata.name`, `metadata.namespace` | Object identity — namespace scoping covered in Demo 02 |
| `metadata.labels` | Key/value pairs for selector matching — powers `kubectl get pods -l` and every controller's pod selection |
| `metadata.annotations` | Non-identifying metadata — tools and humans read these, Kubernetes itself mostly doesn't act on them |
| `spec.containers[]` | See **Anatomy of a Container** below |
| `spec.restartPolicy` | `Always` (default) — required by Deployments/ReplicaSets/DaemonSets/StatefulSets; the API rejects any other value on a pod template owned by one of these. `OnFailure`/`Never` — required by Jobs (Always is rejected there); also what you set on a standalone debug pod. `OnFailure` restarts only on non-zero exit; `Never` never restarts the container at all, regardless of exit code. |
| `spec.terminationGracePeriodSeconds` | Governs the SIGTERM → SIGKILL window on deletion |
| `spec.initContainers` | Run-before-app-container pattern — full pattern in `05-pod-deep-dive` |
| `spec.volumes` | Covered in `04-configmaps-secrets` and `08-storage` |
| `spec.serviceAccountName` | Gives the pod an RBAC identity — covered in `12-rbac/03-serviceaccounts` |
| `spec.nodeName` | Manual scheduling — covered in `06-pod-scheduling/01-manual-scheduling` |
| `spec.dnsPolicy` | Controls DNS resolution behavior — more detail in a future demo |
| `spec.priorityClassName` | Determines the pod's scheduling/preemption priority via a referenced `PriorityClass` object — defaults to `0` if unset, as seen in every `describe pod` output in this demo (`Priority: 0`). Higher-priority pods can preempt (evict) lower-priority ones when a node is full. Not used in this demo — full treatment in `06-pod-scheduling`. |

**Objects a Pod can *reference*, not contain directly:**

A Pod doesn't just have fields — several of those fields point at separate
objects that must already exist. Worth naming explicitly here so you know
they exist, even though each has its own dedicated demo:

- **ConfigMap** — referenced from a container's `env`/`envFrom` or as a
  volume source, for non-secret configuration data. Full treatment in
  `04-configmaps-secrets`.
- **Secret** — same two reference paths as ConfigMap (env or volume), for
  sensitive data. Also covered in `04-configmaps-secrets`.
- **PersistentVolumeClaim** — referenced as a volume source for storage
  that outlives the Pod. Covered in `08-storage`.

---

### Anatomy of a Container — What a Container Spec Can Contain

**Fields inside one entry of `spec.containers[]`:**

| Field | Notes |
|---|---|
| `name`, `image`, `imagePullPolicy` | Identity and image-pull behavior |
| `command`, `args` | Override ENTRYPOINT/CMD — see below |
| `ports` | Informational only — see below |
| `env` | One direct-value example here; env can also pull from ConfigMap/Secret via `envFrom`/`valueFrom` — covered in `04-configmaps-secrets` |
| `resources.requests` / `resources.limits` | Scheduling input vs. kernel-enforced ceiling — also what determines the pod's QoS class, see below. Good to know: since Kubernetes v1.35 these are resizable in place without delete/recreate — full treatment in a later demo. |
| `securityContext` | Container-level identity/privilege controls — see **Container `securityContext`** below |
| `volumeMounts` | Covered in `04-configmaps-secrets` and `08-storage`, alongside `spec.volumes` above |
| `livenessProbe`, `readinessProbe`, `startupProbe` | Covered in `05-pod-deep-dive/03-health-probes` |
| `lifecycle.postStart`, `lifecycle.preStop` | Container-lifecycle hooks — covered in `05-pod-deep-dive` |

> **Requests vs. Limits — the practical difference:**
>
> | | `resources.requests` | `resources.limits` |
> |---|---|---|
> | Who reads it | kube-scheduler, at scheduling time only | The kernel (cgroups), continuously, at runtime |
> | What it means | "Reserve at least this much" — a promise used to filter/rank nodes | "Never let this container use more than this" — an enforced ceiling |
> | What happens if exceeded | Nothing — it isn't checked again after scheduling | CPU: throttled. Memory: the container is OOM-killed |
> | Can it change your fate | Determines *where* the pod lands | Determines *whether the pod survives* a spike |
>
> Getting the two confused is one of the most common real-world and exam
> mistakes: setting only a `limit` with no `request` means the scheduler
> treats the pod as needing *zero* guaranteed resources, which can pack it
> onto an already-busy node — the limit protects the node from the pod,
> not the pod from the node.
>
> `cpu` and `memory` aren't the only two resources you can set here —
> `ephemeral-storage` (the node's local disk, for things like container
> logs, writable layers, and `emptyDir` volumes without their own medium)
> works the same way and is commonly forgotten.

---

### QoS Classes

`resources.requests`/`limits` don't just affect scheduling and enforcement
— together they also assign every pod a **Quality of Service (QoS)
class**, and that class is what decides eviction order the moment a node
runs low on memory.

| Class | How it's assigned | Eviction priority under memory pressure |
|---|---|---|
| **Guaranteed** | Every container sets `requests == limits`, for *both* cpu and memory | Evicted last |
| **Burstable** | At least one container has a request or limit set, but the pod doesn't qualify for Guaranteed | Evicted after BestEffort, before Guaranteed |
| **BestEffort** | No `requests`/`limits` set on *any* container | Evicted first |

`src/01-basic-pod.yaml` sets `cpu`/`memory` requests lower than its
limits, so it's **Burstable** — same reasoning as the Exam Task pod later
in this demo. Check any pod's class directly:
```bash
kubectl get pod nginx-pod -o jsonpath='{.status.qosClass}'
```
The class is computed once, at admission time, from whatever the pod's
manifest resolves to (including any `LimitRanger` defaults from **End-to-End**
below) — it isn't recalculated later, and it isn't something you set
directly as a field.

---

### Pod and Container Internals

The bullet list at the top of this page — "containers in a Pod share a
network namespace, share an IPC namespace, can share volumes" — isn't magic.
Here's the actual mechanism.

**One process per container.** A container should run a single main
process, not a supervisor managing multiple daemons inside it. This is why
Kubernetes uses multi-container *Pods* for tightly coupled processes instead
of stuffing multiple processes into one container — it keeps each
container's lifecycle, restart behavior, and resource accounting simple and
independent. (This is also the seed of *why* multi-container pods exist —
the full pattern is covered in `05-pod-deep-dive/02-multi-container-pods`.)

**The pause container.** When kubelet creates a Pod, the very first
container it starts isn't any of yours — it's a hidden, minimal container
called the **pause container** (also called the infra or sandbox
container). It runs a single process that does nothing but sleep. Its only
job is to be the first process to claim a fresh set of Linux namespaces.
Every container you actually define then *joins* those same namespaces
instead of getting its own.

**ENTRYPOINT/CMD, and how `command`/`args` relate to them.** Every container
image defines a default `ENTRYPOINT` (the executable) and `CMD` (default
arguments to it) in its Dockerfile. In a Pod spec:
- `command` overrides the image's `ENTRYPOINT`
- `args` overrides the image's `CMD`
- If you set neither, the image's own ENTRYPOINT/CMD run unchanged



**Container `securityContext`**

Not shown in `src/01-basic-pod.yaml`, but worth knowing before you write
your own: by default a container runs as whatever user its image
specifies — often **root** — with no restriction on gaining more
privileges. `securityContext` is the field that controls that, settable
pod-wide (`spec.securityContext`) or per container
(`spec.containers[].securityContext`, which overrides the pod-wide value).

Full treatment — `runAsNonRoot`, `allowPrivilegeEscalation`,
`readOnlyRootFilesystem`, Linux capabilities, and cluster-wide enforcement
via Pod Security Admission — is a dedicated topic on its own, covered in
a later demo.

**What's shared by default, and what isn't:**

```
Network namespace   → SHARED by default
                       Same IP, same port space, containers reach each
                       other via localhost. This is the mechanism behind
                       "containers in a Pod share a network namespace."

IPC namespace        → SHARED by default
                       Containers can communicate via shared memory,
                       semaphores, message queues if they need to.

UTS namespace         → SHARED by default
                       All containers in the Pod see the same hostname.

PID namespace        → NOT shared by default
                       Each container gets its own PID 1. `ps aux` inside
                       one container will NOT show processes from a
                       sibling container. This can be turned on explicitly
                       (spec.shareProcessNamespace: true) but it's opt-in,
                       not automatic — don't assume it.

Mount namespace       → NEVER shared, even for "shared" volumes
                       A shared volume isn't one shared filesystem view —
                       it's the SAME volume bind-mounted separately into
                       each container's own, still-isolated mount
                       namespace. Each container still only sees its own
                       filesystem plus whatever's explicitly mounted.

Cgroup hierarchy      → Always separate per container
                       This is a different kind of Linux mechanism from
                       the five rows above — namespaces control what a
                       process can SEE (its own network, its own
                       hostname, etc.); cgroups control what resources a
                       process can USE. Each container gets its own
                       cgroup, which is the actual thing enforcing its
                       resources.requests/limits independently of its
                       sibling containers. That's why this row says
                       "hierarchy," not "namespace" — it's a genuinely
                       different piece of the kernel, doing a different
                       job. (There is also a separate, optional "cgroup
                       namespace" that most modern runtimes enable by
                       default — but that's a runtime detail, not
                       something Kubernetes itself guarantees.)
```

> **Cgroup hierarchy vs. cgroup namespace — don't confuse the two:**
> the **hierarchy** decides what a container can *use* (its CPU/memory
> limits) — always separate per container, guaranteed by Kubernetes.
> The **namespace** decides what a container can *see* of its own
> resource path — whether it sees the real host path (leaking info about
> other pods) or just `0::/` (rerooted, sees nothing above itself). Most
> modern runtimes turn this on by default, but it's a runtime setting,
> not something Kubernetes controls. Check your own pod:
> ```bash
> kubectl exec -it nginx-pod -- cat /proc/self/cgroup
> ```
> `0::/` means you have one; a long host-rooted path means you don't.

**Why bother with a pause container at all?** Linux namespaces only persist
as long as at least one process is attached to them. If Kubernetes didn't
use a pause container and your app container were the only process holding
the network namespace open, a crash would destroy that namespace along with
the container — the Pod would lose its IP address the moment the app
crashed. The pause container exists purely to outlive your app containers'
crashes and restarts, keeping the Pod's network identity (IP, hostname)
stable the whole time the Pod exists. This is the actual mechanical reason
behind the earlier claim that a container restarting is not the same as the
Pod restarting.

**How containers in the same Pod actually talk to each other.** Knowing
*which* namespaces are shared is one thing — here's what that concretely
enables. Full multi-container patterns (sidecars, adapters) are covered in
`05-pod-deep-dive`; this is just the mechanism each pattern relies on:

- **Over the network, via `localhost`.** Because the network namespace is
  shared, every container in a Pod sees the same network stack and the
  same IP. A sidecar can reach the main container with `localhost:8080` —
  no Service, no DNS lookup, no pod IP needed. The one catch: since they
  share the same port space, **two containers in the same Pod can't both
  listen on the same port** — that's a real collision, not a
  namespace-isolation failure.
- **Through a shared volume, as files.** `spec.volumes` (full treatment in
  `04-configmaps-secrets`/`08-storage`) lets two containers mount the same
  volume. Because the mount namespace is still separate per container
  (see above), this isn't a shared filesystem view — it's the same
  underlying volume bind-mounted into each container's own isolated view.
  A log-shipping sidecar reading a file the main container writes is the
  classic example.
- **Via shared memory / IPC primitives.** Because the IPC namespace is
  shared, POSIX shared-memory segments, semaphores, and message queues
  created by one container are visible to the others. This is the least
  used of the three in practice, but it's the direct, literal payoff of
  "containers in a Pod share an IPC namespace."

All three require the containers to actually be written to use them —
sharing the namespace only makes it *possible*, not automatic.

---

### Minimal and Essential Pod YAML

**The actual floor — a minimal valid Pod:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: minimal-pod
spec:
  containers:
    - name: app
      image: nginx:1.30.4
```
Nothing else is required. Everything else you've seen — `restartPolicy`,
`dnsPolicy`, `serviceAccountName`, `imagePullPolicy` — gets a default value
if you omit it (some defaults come from the API server's own defaulting,
others from admission controllers, covered in the **End-to-End** section
below). This matters for reading other people's YAML: a short manifest
isn't necessarily an incomplete one, it may just be relying on defaults.

**An essential, production-reasonable Pod** — this is `src/01-basic-pod.yaml`,
used in Step 1 below. Every field here was fully explained in **Anatomy of
a Pod** and **Anatomy of a Container** above — comments here just point
back rather than re-explaining:

> **This is the exact manifest you'll apply in Step 1** — the command
> output shown throughout **Essential Pod Commands** just below is what
> creating *this* pod actually produces. You don't need to run anything
> yet; read it here first, then apply it for real in the Lab section.

**src/01-basic-pod.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-pod
  namespace: default
  labels:
    app: nginx                  # see Anatomy of a Pod
    version: "1.30.4"
spec:
  restartPolicy: Always              # see Anatomy of a Pod
  terminationGracePeriodSeconds: 30  # see Anatomy of a Pod
  containers:
    - name: nginx
      image: nginx:1.30.4            # see Anatomy of a Container
      imagePullPolicy: IfNotPresent  # see Anatomy of a Container
      command: ["nginx"]             # overrides ENTRYPOINT — see Anatomy of a Container
      args: ["-g", "daemon off;"]    # overrides CMD — see Anatomy of a Container
      ports:
        - name: http                # see Anatomy of a Container — informational only
          containerPort: 80
          protocol: TCP
      env:
        - name: ENV_NAME
          value: "production"       # see Anatomy of a Container
      resources:
        requests:
          cpu: "100m"                # see Anatomy of a Container
          memory: "128Mi"
        limits:
          cpu: "500m"
          memory: "256Mi"
```

---

### End-to-End: What Happens When You Create a Pod

A full walkthrough of every component involved, from `kubectl apply` all
the way through a running container to eventual termination — not just
creation. Demo 01 already introduced kube-apiserver, kube-scheduler,
kubelet, and kube-proxy at a basic level; this section goes one level
deeper on all of them, plus the admission control and container runtime
pieces Demo 01 didn't cover. Specifically, for each step below: which
Pod/container field actually drives it, and which single component —
kube-apiserver (including admission control), kube-scheduler, kubelet,
the container runtime, or kube-proxy — is the one responsible for it.

**1. `kubectl apply`/`run` → kube-apiserver.** The request goes through, in
order: **Authentication** → **Authorization (RBAC)** → **Admission
Control** → **Schema Validation** → persisted to **etcd**. Admission
control itself runs in two ordered phases — mutating controllers first,
then validating — and several built-in ones act directly on fields already
in this demo's YAML:
   - `LimitRanger` (mutating, then validating): if `resources.requests`/
     `limits` are unset and a `LimitRange` object exists in the namespace,
     this **injects defaults for you** before the Pod is ever scheduled.
     If you did set values explicitly, it validates them against the
     namespace's configured min/max.
   - `ResourceQuota` (validating, deliberately runs last): checks the
     (possibly LimitRanger-defaulted) resource values against the
     namespace's quota — the same mechanism behind Demo 02's Break-Fix.
     Kubernetes' own admission-controller reference explicitly recommends
     running `ResourceQuota` last, precisely so quota isn't incremented
     against a request that a later controller might still reject.
   - `ServiceAccount` (mutating + validating): if `serviceAccountName` is
     unset, this is what injects `default` and sets up the token mount.
   - Schema validation runs *between* the mutating and validating phases —
     this is what rejects a Pod with a missing `image` or a typo'd field
     name before any validating controller even sees it.

**2. kube-scheduler picks a node.** Field: `resources.requests` — the
scheduler filters nodes by available capacity, then ranks the rest. Field:
`nodeName` — if you set this yourself, the scheduler skips the Pod
entirely; there's nothing left to decide. Managed by: **kube-scheduler**.

**3. kubelet on the assigned node notices the Pod.** Field:
`serviceAccountName` — kubelet mounts the resolved SA's token as a
projected volume. Field: `dnsPolicy` — kubelet writes the Pod's
`/etc/resolv.conf` per this policy before any container starts. Managed
by: **kubelet**.

**4. kubelet asks the CRI to create a sandbox.** This is where the
**pause container** gets created first (see Internals above), claiming
the network/IPC/UTS namespaces. Managed by: **kubelet** (orchestrates) +
**container runtime** (executes, via the CRI).

**5. CNI plugin wires up networking.** The CNI plugin assigns the Pod's IP
into the pause container's network namespace. **kube-proxy plays no role
in this step at all** — it's not involved in individual Pod creation or
pod-to-pod networking. kube-proxy's only job, entirely separate from this
flow, is Service routing: watching Services/Endpoints and writing the
iptables/IPVS rules that redirect traffic sent to a Service's virtual IP
toward real Pod IPs. It only becomes relevant once a Service exists.Full depth on exactly how kube-proxy programs those rules — iptables vs nftables vs IPVS modes, and the actual DNAT chains it creates — is 03-services/02-service-internals's entire subject. Field:
`ports` (`containerPort`) is consumed by **nothing** at this stage —
not kube-proxy, not the CNI, not kubelet as a firewall rule. It's
informational metadata, useful mainly for `kubectl` display and so a
Service you write later can reference it by name.

**6. kubelet pulls images and starts containers via CRI.** Field:
`imagePullPolicy` — kubelet's own logic decides whether to instruct the CRI
to pull or reuse a cached image. Field: `image` — handed to the CRI, which
the container runtime pulls. Field: `command`/`args` — handed to the CRI,
which the runtime uses to override the OCI image's Entrypoint/Cmd at exec
time. Field: `env` — handed to the CRI, injected into the process
environment at exec time. Field: `resources.requests`/`limits` — kubelet
translates these into cgroup parameters, configured via the CRI when the
container is created; **enforcement itself then happens at the
kernel/cgroup level**, not by kubelet continuously policing it afterward.
Managed by: **kubelet** (decides/orchestrates) + **container runtime**
(executes).

**7. kubelet reports status back to apiserver, continuously.** This is
what `kubectl get pods` is actually reading — not a live poll of the node,
but kubelet's periodic status reports already persisted via apiserver.

**8. Termination.** Field: `terminationGracePeriodSeconds` — kubelet uses
this to time the gap between sending SIGTERM (via the CRI) and issuing
SIGKILL. Field: `restartPolicy` — kubelet's own decision logic for
whether and how to restart a container after it exits.

---

### Essential Pod Commands

**`kubectl run`** — create a pod imperatively
```bash
kubectl run nginx-pod --image=nginx:1.30.4 --labels="app=nginx"
# pod/nginx-pod created
```

**`kubectl get pods`** — list pods, with column meanings
```bash
kubectl get pods
```
```
NAME        READY   STATUS    RESTARTS   AGE
nginx-pod   1/1     Running   0          5s
```
- `NAME` — pod name
- `READY` — ready containers / total containers (reflects the readiness probe outcome, not just "is it running")
- `STATUS` — the pod phase, or a container-state reason if not simply Running (e.g. `CrashLoopBackOff`, `ImagePullBackOff`)
- `RESTARTS` — how many times containers in this pod have restarted
- `AGE` — time since the pod object was created

**`kubectl get pod -o wide`** — adds scheduling-relevant columns
```bash
kubectl get pod nginx-pod -o wide
```
```
NAME        READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
nginx-pod   1/1     Running   0          10s   10.244.1.5    3node-m02  <none>           <none>
```
- `IP` — the pod's IP address (from the pod network CIDR)
- `NODE` — which node the scheduler placed it on

**`kubectl describe pod`** — full detail, the primary debugging tool
```bash
kubectl describe pod nginx-pod
```
Key sections in the output:
- **Status / IP / Node** — current phase, assigned IP, assigned node
- **Containers** — per-container State (Waiting/Running/Terminated), Ready, Image, Limits/Requests
- **Conditions** — five boolean checkpoints in a pod's readiness path, set
  roughly in this order: `PodScheduled` (scheduler assigned a node) →
  `PodReadyToStartContainers` (the pause-container sandbox exists and the
  CNI has configured networking — see **Pod and Container Internals**
  above) → `Initialized` (init containers, if any, finished) →
  `ContainersReady` (all containers passed readiness) → `Ready` (pod is
  ready to serve traffic). On a pod with no init containers, the middle
  three tend to flip to `True` almost together — the gap between them only
  becomes visible on a pod with slow init containers or a slow CNI.
- **Events** — chronological log of what happened: Scheduled → Pulling → Pulled → Created → Started. This is where almost all debugging information actually lives.

**`kubectl logs`** — container output
```bash
kubectl logs nginx-pod              # current container's logs
kubectl logs nginx-pod --previous   # logs from the PREVIOUS container instance
                                     # (needed after a crash + restart — the
                                     # current container's logs won't show why
                                     # the last one died)
```

**`kubectl exec`** — run a command inside a running container
```bash
kubectl exec nginx-pod -- nginx -v                # one-shot command
kubectl exec -it nginx-pod -- bash                # interactive shell
```

**`kubectl cp`** — copy files between a pod and your local machine
```bash
kubectl cp nginx-pod:/etc/nginx/nginx.conf ./nginx-from-pod.conf   # pod → local
kubectl cp ./local-file.txt nginx-pod:/tmp/local-file.txt          # local → pod
```
Copies through the API server (not a direct connection to the node), so it
works from anywhere `kubectl` is configured — but it's also slower than a
direct `scp` and not meant for large files. Requires `tar` to exist inside
the target container (the official nginx image has it; minimal
distroless-style images may not).

**`kubectl port-forward`** — reach a pod directly, without a Service
```bash
kubectl port-forward pod/nginx-pod 8080:80   # local:8080 → pod:80
```
Opens a tunnel from a local port to a port inside the pod, over the API
server connection. Useful for debugging a single pod before any Service
exists to route to it — but it's a point-to-point debugging tool, not a
substitute for a Service: it only reaches the one pod you named, doesn't
load-balance, and stops the moment you kill the command.

**`kubectl delete pod`** — what actually happens
```bash
kubectl delete pod nginx-pod
```
This isn't instant — see step 8 of **End-to-End** above: the pod enters
`Terminating`, kubelet sends `SIGTERM`, and only if
`terminationGracePeriodSeconds` elapses without the container exiting does
kubelet send `SIGKILL`.

---

### Pod Phases and Container States

**Pod Phases**
```
Pending:    Pod accepted by Kubernetes but not yet running.
            Possible reasons:
              - Scheduler has not yet assigned it to a node
              - Images are being pulled
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

**Container States**
```
Waiting:    Container is not yet running.
            Reason field explains why:
              ContainerCreating  → image being pulled, volumes being mounted
              CrashLoopBackOff   → container keeps crashing, backing off
                                   with an exponential delay (10s → 20s →
                                   40s → 80s → 160s, capped at 5 minutes;
                                   the backoff resets to 10s after 10
                                   consecutive minutes of the container
                                   staying up). Root-cause debugging is
                                   covered in depth in
                                   05-pod-deep-dive/01-pod-lifecycle-termination-errors
              ImagePullBackOff   → image pull failed, retrying with backoff
              ErrImagePull       → image pull failed (bad name, auth error)

Running:    Container is executing. startedAt timestamp is set.

Terminated: Container ran and stopped.
            exitCode: 0  → success
            exitCode: non-zero → failure
            Reason: Completed, Error, OOMKilled, etc.
```

**`OOMKilled` specifically** means the container exceeded its
`resources.limits.memory` and the kernel's OOM killer terminated it —
you'll see `exitCode: 137` and `Reason: OOMKilled` together in
`kubectl describe`. This is memory-only: there's no CPU equivalent,
because a CPU limit throttles the process instead of killing it (see
**Requests vs. Limits** above) — a container can run at 100% of its CPU
limit indefinitely without ever being terminated for it.

**Pods Are Ephemeral** A pod's IP address is not stable — if the pod is deleted and recreated
(even by a controller replacing it with an "identical" one), it gets a **new** IP. This is exactly why you never hardcode a pod IP anywhere, and it's the foundational reason Services exist (covered fully in `03-services`) — a Service gives you a stable address that doesn't change
as the pods behind it come and go.

---

### What Actually Happens During a "Restart"?

**What a restart actually is.** Container doesn't pause and resume — it runs its process to completion, one way or another:
exits `0` (success), exits non-zero (failure), or gets killed outright
(OOM, a failed liveness probe, `SIGKILL`). There is no "resume." What
kubelet calls a *restart* is: the old container is gone for good, and a
**brand-new container instance** — fresh process, fresh container ID,
fresh writable filesystem layer, built from the exact same image/command/
env/resources in the pod spec — gets created **inside the same, still-
existing Pod sandbox**. "Restart" is really "replace the container, keep
the Pod" — which is exactly why it's able to happen without touching the
Pod's IP, UID, or hostname: those all belong to the pause container's
sandbox, described just above, and the sandbox is never torn down.

**When restart happens, and what changes.** Governed entirely by
`spec.restartPolicy` (see the **Anatomy of a Pod** table above) reacting
to *this specific container's* exit:

- `Always` — restarts regardless of exit code, success included
- `OnFailure` — restarts only on non-zero exit; a clean `exit 0` is left alone
- `Never` — never restarts; the container just stays `Terminated`

If a restart is warranted and this isn't the container's first failure,
kubelet waits out the `CrashLoopBackOff` delay from **Pod Phases and
Container States** first. Then: a new container instance starts, `RESTARTS`
increments by one, `Last State` in `describe` shows the *old* instance's
exit info, `State` shows the *new* instance's status. Anything in a
mounted volume (`emptyDir`, a ConfigMap, a PVC) survives untouched, because
volumes aren't part of the container's own filesystem layer — but anything
the old container wrote *outside* a mount is gone with it. Init containers
are the one exception worth repeating from earlier: they already ran to
completion once, and an app-container restart doesn't re-trigger them.

**c. Does this Pod restart require a Deployment/StatefulSet/DaemonSet/Job?** No — and this is worth being precise about, because it's easy to conflate with "naked pods have no self-healing" from earlier. Two genuinely different mechanisms are at play:

- **Container restart** (what this section describes) is purely a
  kubelet + `restartPolicy` behavior, scoped to *one Pod*. It has nothing
  to do with controllers — your own `crasher` pod from Step 2 proved this:
  a completely naked pod, created with bare `kubectl run`, still restarted
  three times on its own.
- **Pod recreation** — a brand-new Pod object, new UID, new IP — is the
  *different* thing a controller (ReplicaSet/StatefulSet/DaemonSet/Job)
  provides. That only happens when the **Pod object itself** disappears
  (you delete it, the node dies, etc.), which is exactly the "naked pods
  are gone for good" lesson from earlier in this demo.

So: restart = kubelet acting alone, any pod, container-level. Recreation =
a controller acting, Pod-level, only if one exists.

**The one case where this split gets blurry: a Job with
`restartPolicy: Never`.** You already know `Never` means kubelet will not
restart the container — that's unconditional, covered in the previous
question. But a Job can still retry a failed attempt, up to
`spec.backoffLimit` times — it just does it the *other* way: instead of
kubelet restarting the container in place, the **Job controller** creates
a **brand-new Pod object** for the next attempt, the same class of action
a ReplicaSet takes when a Pod disappears. Compare the two Job configurations:

- `restartPolicy: OnFailure` → failed attempts retry via **container
  restart**, same Pod, same IP, `RESTARTS` column increments
- `restartPolicy: Never` → failed attempts retry via a **new Pod**, new
  IP, new UID, `RESTARTS` stays `0` on each one — the Job's *own* retry
  count is what's tracking attempts, not any single Pod's restart count

Same underlying rule as before — `Never` really does mean zero restarts,
at the container level, always. The Job controller compensating one level
up is a separate mechanism, not an exception to it. Full Job/CronJob
treatment, including `backoffLimit`, is its own future demo — this is
just enough to not leave `Never` looking like a dead end.

So: restart = kubelet acting alone, any pod, container-level, governed
strictly by `restartPolicy`. Recreation = a controller acting, Pod-level,
either reactively (ReplicaSet replacing a deleted Pod) or as part of its
own retry logic (Job creating a new Pod after a `Never`-attempt fails).


**d. Message flow — single-container pod:**
```
1. Container process running (its own PID 1, inside its own PID namespace)
2. Process exits — crash, OOM-kill, or a failed liveness probe → SIGKILL
3. Container runtime reports the exit to kubelet, via the CRI
4. kubelet checks spec.restartPolicy
     Never              → stop here; container stays Terminated
     Always / OnFailure → continue
5. If this is a repeat failure, kubelet waits out the current
   CrashLoopBackOff delay
6. kubelet asks the CRI for a NEW container instance:
     - same image/command/args/env/resources — nothing in the spec changed
     - fresh container ID, fresh writable layer
     - joins the SAME sandbox — same network/IPC/UTS namespaces, still
       held open by the pause container
     - mounted volumes are re-attached, same data as before
7. New container starts → RESTARTS +1; Pod's IP/UID/hostname: unchanged
   throughout every step above
```

**Message flow — multi-container pod (app + sidecar):**
```
1. App container and sidecar both running, sharing one pod sandbox
2. App container crashes — sidecar is completely unaffected, keeps running,
   keeps its own container ID, never restarts
3. kubelet detects the app container's exit and applies steps 3-6 above
   to that ONE container only — the sidecar plays no part in this
4. New app-container instance joins the same shared sandbox — same Pod
   IP as before, so if the sidecar was calling it over localhost, it
   briefly can't connect, then can again on the exact same address —
   no reconfiguration needed on the sidecar's side
5. The Pod-level RESTARTS column in `kubectl get pods` sums restarts
   across every container — it tells you at least one container
   restarted, not which one. `kubectl describe pod` breaks this out
   per-container.
```

Full multi-container patterns (sidecars, shared lifecycles) are still deferred to `05-pod-deep-dive` — this flow is just the mechanism, not a worked multi-container example.

---

## Lab Step-by-Step Guide

### Step 1: Create and observe a basic pod

```bash
cd 01-core-concepts/03-pod-container-basics/src
kubectl apply -f 01-basic-pod.yaml

# Watch the pod start
kubectl get pod nginx-pod -w
```

**Observed lifecycle (real run):**
```
NAME        READY   STATUS              RESTARTS   AGE
nginx-pod   0/1     ContainerCreating   0          5s
...
nginx-pod   1/1     Running             0          9s
```
In practice you may not catch `Pending` at all — on this run scheduling was
fast enough that the first `kubectl get pod` already showed
`ContainerCreating`. All three phases from **Pod Phases** above still
happen in order; `-w`/polling just doesn't guarantee you'll observe every
one before it moves to the next, especially on a lightly loaded cluster.

```bash
# Wide output — see the IP and NODE columns
kubectl get pod nginx-pod -o wide

# Full detail — see "Essential Pod Commands" above for what each section means
kubectl describe pod nginx-pod
```

**Observed `describe` output (trimmed to what's worth reading):**
```
Name:             nginx-pod
Service Account:  default
Node:             3node-m03/192.168.58.4
Labels:           app=nginx
                  version=1.30.4
Status:           Running
IP:               10.244.2.19
Containers:
  nginx:
    Image:         nginx:1.30.4
    Port:          80/TCP (http)
    Host Port:     0/TCP (http)
    Command:
      nginx
    Args:
      -g
      daemon off;
    State:          Running
    Ready:          True
    Restart Count:  0
    Limits:
      cpu:     500m
      memory:  256Mi
    Requests:
      cpu:     100m
      memory:  128Mi
    Environment:
      ENV_NAME:  production
    Mounts:
      /var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-h52p7 (ro)
Conditions:
  Type                        Status
  PodReadyToStartContainers   True
  Initialized                 True
  Ready                       True
  ContainersReady             True
  PodScheduled                True
Volumes:
  kube-api-access-h52p7:
    Type:                    Projected (a volume that contains injected data from multiple sources)
    TokenExpirationSeconds:  3607
QoS Class:                   Burstable
Tolerations:                 node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
                             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  25s   default-scheduler  Successfully assigned default/nginx-pod to 3node-m03
  Normal  Pulling    24s   kubelet            Pulling image "nginx:1.30.4"
  Normal  Pulled     20s   kubelet            Successfully pulled image "nginx:1.30.4" in 4.715s
  Normal  Created    19s   kubelet            Created container: nginx
  Normal  Started    19s   kubelet            Started container nginx
```

**A few things worth actually reading here, not skimming past:**

- **`Conditions` shows five entries — `PodReadyToStartContainers` is the fifth.**
  It's set the moment the pause container's sandbox exists and the CNI
  has wired up networking (the exact mechanism from **Pod and Container
  Internals** above) — and it's set *before* `Initialized`, which is why
  it appears first in the list. On a pod with no init containers (like
  this one), it and `Initialized` will both flip to `True` almost
  immediately, but on a pod with slow init containers, `PodReadyToStart
  Containers` going `True` while `Initialized` stays `False` is exactly
  how you'd tell "the sandbox is up" apart from "the app hasn't finished
  initializing yet."
- **`Mounts` shows a volume you never wrote — `kube-api-access-h52p7`.**
  This is live, concrete confirmation of two things covered only in
  theory in **End-to-End** above: the `ServiceAccount` admission
  controller injected `default` (see `Service Account: default` at the
  top), and kubelet mounted that identity as a projected token volume
  before the container ever started — exactly as described in
  End-to-End step 3.
- **`Tolerations` shows two entries you never wrote either.** These come
  from the `DefaultTolerationSeconds` admission controller — another
  built-in admission controller not mentioned elsewhere in this demo —
  which injects a 300-second tolerance for `NoExecute` taints on
  `node.kubernetes.io/not-ready` and `node.kubernetes.io/unreachable`
  unless you specify your own. In practice: if this pod's node briefly
  drops out of contact, the pod is *not* evicted immediately — it gets a
  5-minute grace window first.
- **`Host Port: 0/TCP` next to `Port: 80/TCP`** — this demo's YAML never
  set `hostPort`, and `0` is how "unset" renders here, not `<none>`.
  Doesn't change the earlier claim that `containerPort` is purely
  informational — `hostPort` is the genuinely different field that *would*
  bind a port on the node itself, and it's a separate, much rarer setting
  from the one this demo actually uses.
- **`QoS Class: Burstable`** — this is the live confirmation of the QoS
  Classes section above: `01-basic-pod.yaml` sets requests below limits,
  so it lands on Burstable, exactly as predicted there.

```bash
kubectl get pod nginx-pod -o wide
```
```
NAME        READY   STATUS    RESTARTS   AGE   IP            NODE        NOMINATED NODE   READINESS GATES
nginx-pod   1/1     Running   0          67s   10.244.2.19   3node-m03   <none>            <none>
```

---

### Step 2: Observe a failing pod and debug it

```bash
# Create a pod that crashes immediately
kubectl run crasher --image=busybox:1.38.0 -- sh -c "echo 'About to crash'; exit 1"

kubectl get pod crasher -w
```

**Before you look — predict it first:** the container runs `exit 1`
immediately after printing one line. What do you expect `STATUS` and
`RESTARTS` to do over the next minute? Will `READY` ever reach `1/1`?
Write down your answer, then compare it against the actual output below.

**Observed output (real run):**
```
NAME      READY   STATUS             RESTARTS      AGE
crasher   0/1     CrashLoopBackOff   1 (5s ago)    8s
crasher   0/1     Error              2 (14s ago)   17s
crasher   0/1     CrashLoopBackOff   2 (11s ago)   27s
crasher   0/1     Error              3 (26s ago)   42s
```

**Two things worth noticing that differ from a "clean" trace:**
- **This run's first line is `CrashLoopBackOff`, not `Error`.** The
  sequence you actually see with `-w` depends on exactly when you start
  watching — by the time this `kubectl get pod -w` was issued as its own
  command (after `kubectl run` had already returned), the pod had already
  crashed once and was already in backoff. The underlying pattern from
  **Pod Phases and Container States** — start, crash, `Error`, wait,
  retry, repeat — is unchanged; you just aren't guaranteed to observe it
  from `Error` #1 onward unless your watch is already running before you
  create the pod.
- **`RESTARTS` shows `2 (14s ago)`, not a bare `2`.** Current kubectl
  appends how long ago the *last* restart happened, in parentheses — this
  is the actual column format you'll see today, not just a plain integer.

**What this output means:** the container starts, runs `exit 1`
immediately, and dies — `STATUS` alternates between `Error` (right after
each exit) and `CrashLoopBackOff` (Kubernetes waiting out the exponential
backoff described in **Pod Phases and Container States** above before the
next restart attempt). `READY: 0/1` throughout, because the container is
never actually up long enough to be considered ready — it never will be,
since `exit 1` is unconditional.

```bash
# Read the crash logs
kubectl logs crasher
# About to crash

# Read PREVIOUS container's logs (when currently in backoff)
kubectl logs crasher --previous
# About to crash

# See the exit code in describe
kubectl describe pod crasher | grep -A5 "Last State:"
```

**Observed output (real run):**
```
Name:             crasher
Namespace:        default
Priority:         0
Service Account:  default
Node:             3node-m03/192.168.58.4
Start Time:       Mon, 20 Jul 2026 16:20:59 -0400
Labels:           run=crasher
Annotations:      <none>
Status:           Running
IP:               10.244.2.20
IPs:
  IP:  10.244.2.20
Containers:
  crasher:
...
...
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      Mon, 20 Jul 2026 16:21:41 -0400
      Finished:     Mon, 20 Jul 2026 16:21:41 -0400
    Ready:          False
    Restart Count:  3
...
...
Conditions:
  Type                        Status
  PodReadyToStartContainers   True 
  Initialized                 True 
  Ready                       False 
  ContainersReady             False 
  PodScheduled                True 
...
...
QoS Class:                   BestEffort
...
...
Events:
  Type     Reason     Age                From               Message
  ----     ------     ----               ----               -------
  Normal   Scheduled  81s                default-scheduler  Successfully assigned default/crasher to 3node-m03
  Normal   Pulling    81s                kubelet            Pulling image "busybox:1.38.0"
  Normal   Pulled     80s                kubelet            Successfully pulled image "busybox:1.38.0" in 544ms (544ms including waiting). Image size: 4445830 bytes.
  Normal   Pulled     41s (x3 over 79s)  kubelet            Container image "busybox:1.38.0" already present on machine
  Normal   Created    40s (x4 over 80s)  kubelet            Created container: crasher
  Normal   Started    40s (x4 over 80s)  kubelet            Started container crasher
  Warning  BackOff    11s (x7 over 78s)  kubelet            Back-off restarting failed container crasher in pod crasher_default(eb35013f-7989-4b10-95f1-ae1ed119255e)
```

**Two more things worth pulling from the full `describe pod crasher`
output while you're here:**
- **`Conditions` for this pod show `Ready: False` and
  `ContainersReady: False`**, while `PodScheduled`, `PodReadyToStart
  Containers`, and `Initialized` are all still `True`. Side-by-side with
  Step 1's all-`True` nginx-pod, this is the clearest possible
  illustration of what those five conditions are actually for: scheduling
  and sandbox setup succeeded and stayed succeeded; it's specifically
  the container's own health that's failing, and only the two
  conditions actually downstream of container health reflect that.
- **`QoS Class: BestEffort`** — `crasher` was created via `kubectl run`
  with no `--requests`/`--limits` at all (and, per **Essential Pod
  Commands** above, those flags don't even exist anymore), so nothing was
  ever set on any resource. This is the live counterpart to Step 1's
  `Burstable` pod: same demo, two real pods, two different QoS classes,
  for exactly the reason the QoS Classes section predicts.
- **The `Events` list includes a `BackOff` event** reading (approximately)
  "Back-off restarting failed container" — this is the literal event text
  behind the `CrashLoopBackOff` status string, generated once kubelet
  starts throttling restart attempts rather than retrying immediately.

```bash
# Clean up
kubectl delete pod crasher
```

---

### Step 3: Pod/Container Restart behavior

```bash
kubectl run restart-demo --image=busybox:1.38.0 --restart=Always \
  -- sh -c "sleep 5; exit 1"

# Capture "before" identity — do this within the first 5 seconds
kubectl get pod restart-demo -o jsonpath='{.metadata.uid}{"\n"}'
kubectl get pod restart-demo -o jsonpath='{.status.podIP}{"\n"}'
kubectl get pod restart-demo -o jsonpath='{.status.containerStatuses[0].containerID}{"\n"}'

**Observed output (real run):**
```
953b5820-3eb3-4f15-88a8-9b891830a612
10.244.2.25
docker://359b785427fa5e58f89869f6d5c0207439233f84ca17d60962b905338c6d5505
```

# Wait past the crash + restart (5s sleep + restart overhead)
sleep 15

# Capture "after" identity
kubectl get pod restart-demo -o jsonpath='{.metadata.uid}{"\n"}'
kubectl get pod restart-demo -o jsonpath='{.status.podIP}{"\n"}'
kubectl get pod restart-demo -o jsonpath='{.status.containerStatuses[0].containerID}{"\n"}'
kubectl get pod restart-demo -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
```

**Observed output (real run):**
```
953b5820-3eb3-4f15-88a8-9b891830a612
10.244.2.25
docker://f73184c76ad6c2c5ffc649257e191406c49542e02f4d5eb8b7a951ddbc67b04f
2
```

**What this output means:** `uid` and `podIP` identical both times; `containerID` different; `restartCount` now `2`. That's the entire "restart vs. recreation" claim, proven with four numbers instead of asserted.

```bash
kubectl delete pod restart-demo
```

---

### Step 4: Pod lifecycle — exec, copy, port-forward

```bash
# Exec into a running container
kubectl exec -it nginx-pod -- bash
```
```
root@nginx-pod:/# who am i
root@nginx-pod:/# pwd
/
root@nginx-pod:/# exit
```
Two things worth noticing in that exec session: the prompt itself
(`root@nginx-pod:/#`) is the live confirmation of **Container
`securityContext`** above — this pod set none, so it's running as
whatever the `nginx` image defaults to, which is root. And `who am i`
prints nothing at all — not an error, just an empty line. That's a
container quirk, not a bug: `who` reads login records from `/var/run/utmp`,
and a container's shell session was never a real interactive login, so
there's no record for it to find. `whoami` (one word) would print `root`
correctly; `who am i` (a different, older command) legitimately has
nothing to report in a container.

```bash
# Copy a file from pod to local
kubectl cp nginx-pod:/etc/nginx/nginx.conf ./nginx-from-pod.conf
```
```
tar: Removing leading `/' from member names
```
This line on `stderr` is expected, harmless output from `kubectl cp`'s
underlying `tar` mechanism (`kubectl cp` copies via a `tar` stream over
`exec`, not a purpose-built file-transfer protocol) — it is not an error,
even though it looks like one the first time you see it.

```bash
cat nginx-from-pod.conf | head -5
```
```
user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log notice;
```

```bash
# Access the pod directly (without a Service)
kubectl port-forward pod/nginx-pod 8080:80 &
curl http://localhost:8080
```
```
Forwarding from 127.0.0.1:8080 -> 80
Handling connection for 8080
<!DOCTYPE html>
...
<title>Welcome to nginx!</title>
...
```
```bash
kill %1  # stop port-forward
```

---

### Step 5: Why naked pods are not used in production

```bash
# Naked pod: created directly, not managed by a controller

# Delete the pod
kubectl delete pod nginx-pod
```
```
pod "nginx-pod" deleted from default namespace
```
```bash
# What happens? It is GONE. No controller recreates it.
kubectl get pod nginx-pod
```
```
Error from server (NotFound): pods "nginx-pod" not found
```

```bash
# With a Deployment: controller notices the pod is gone and recreates it
# (kubectl create deployment is used here only to demonstrate self-healing —
# Deployments themselves are covered in full in the 02-deployments topic group)
kubectl create deployment nginx-managed --image=nginx:1.30.4
kubectl get pods -l app=nginx-managed
```
```
NAME                             READY   STATUS    RESTARTS   AGE
nginx-managed-8469697f6d-sr6dp   1/1     Running   0          10s
```
Notice the pod name — `nginx-managed-8469697f6d-sr6dp` isn't something you
named. That auto-generated middle segment is a preview of the
`pod-template-hash` mechanism the `02-deployments` topic group covers in
full; nothing to act on here, just worth recognizing the shape when you
see it.

```bash
kubectl delete pod -l app=nginx-managed
kubectl get pods -l app=nginx-managed
```
```
pod "nginx-managed-8469697f6d-sr6dp" deleted from default namespace
NAME                             READY   STATUS    RESTARTS   AGE
nginx-managed-8469697f6d-cthgp   1/1     Running   0          7s
```
Same hash segment, new random suffix, new pod — the controller replaced it
immediately, and this is the actual proof: gone at `sr6dp`, replaced by
`cthgp` seconds later.

**Rule:** Never create naked pods in production.
Always use a controller: Deployment, StatefulSet, DaemonSet, or Job.
The only legitimate naked pods are one-shot debugging pods
(`kubectl run debug --rm -it --image=busybox:1.38.0 --restart=Never -- sh`).

---

### Step 5: Cleanup

```bash
kubectl delete pod nginx-pod 2>/dev/null || true
kubectl delete deployment nginx-managed 2>/dev/null || true
rm -f nginx-from-pod.conf
```

---

## What You Learned

In this lab, you:
- ✅ Explained a Pod as an environment for running containers — and that a container restarting inside a pod is not the same as the pod restarting
- ✅ Enumerated everything a Pod and a container spec can contain, including what's deferred to later demos
- ✅ Explained how the pause container and Linux namespaces (network/IPC/UTS shared, PID/mount not, cgroup accounting always separate) actually implement pod-level sharing
- ✅ Compared a minimal valid Pod to an essential, production-reasonable one
- ✅ Calculated a pod's QoS class from its requests/limits and explained why it drives eviction order
- ✅ Explained what `securityContext` controls and that containers run as root by default without it
- ✅ Walked the full end-to-end flow of creating a Pod — including admission control's mutating/validating phases, and which component (apiserver, scheduler, kubelet, container runtime, kube-proxy) manages which field
- ✅ Used `kubectl run`, `get`, `describe`, `logs`, `exec`, `cp`, `port-forward`, and `delete`, and know what each column/section of their output means
- ✅ Explained all five pod phases (Pending, Running, Succeeded, Failed, Unknown)
- ✅ Debugged a crashing pod with `kubectl logs --previous` and `kubectl describe`
- ✅ Proved naked pods are not self-healing — use controllers in production
- ✅ Understood that pod IPs are ephemeral, which is why Services exist

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1

**`src/break-fix/01-command-args-crash.yaml`:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: command-crash
spec:
  restartPolicy: Never
  containers:
    - name: app
      image: nginx:1.30.4
      command: ["nginx"]
      args: ["-c", "/does/not/exist.conf"]   # points at a config file that doesn't exist
```

```bash
kubectl apply -f 01-command-args-crash.yaml
kubectl get pod command-crash -w
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** The `args` override points nginx at a config file path that doesn't exist. nginx fails to start immediately and exits with a non-zero code — this is exactly the "incorrect command/args override" failure mode described in **Anatomy of a Container** above.

**Fix:** Correct the `args` to point at a real config path, or remove the override entirely so the image's default `CMD` runs unchanged.

**Cascade:** `kubectl logs command-crash` shows nginx's own startup error (`open() "/does/not/exist.conf" failed`) — the container never gets stuck in a confusing state, but the trap is assuming the image itself is broken when the real cause is the `args` override you added on top of it.

</details>

**Cleanup:**
```bash
kubectl delete pod command-crash 2>/dev/null || true
```

---

### Error-2

**`src/break-fix/02-label-selector-typo.yaml`:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: typo-pod
  labels:
    app: web-fronted    # typo: should be "web-frontend"
spec:
  containers:
    - name: nginx
      image: nginx:1.30.4
```

```bash
kubectl apply -f 02-label-selector-typo.yaml
kubectl get pods -l app=web-frontend
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** The pod's actual label is `app=web-fronted` (typo), but the query filters for `app=web-frontend`. There's no error — `kubectl get pods -l` with a selector that matches nothing simply returns an empty result, silently.

**Fix:** Either fix the typo in the pod's label and reapply, or fix the typo in the selector you're querying with — depends on which one is actually wrong in a real scenario.

**Cascade:** This is a "looks like nothing exists" trap, not a "something is broken" trap — `kubectl get pods` (no selector) shows the pod is there and Running the whole time. The failure is entirely in the query, not the object, which is easy to misdiagnose as "my pod never got created" when it's actually running fine under an unexpected label.

</details>

**Cleanup:**
```bash
kubectl delete pod typo-pod 2>/dev/null || true
```

---

### Error-3

**`src/break-fix/03-bad-image-tag.yaml`:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bad-image-pod
spec:
  containers:
    - name: app
      image: nginx:1.30.4-typo
```

```bash
kubectl apply -f 03-bad-image-tag.yaml
kubectl get pod bad-image-pod -w
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `nginx:1.30.4-typo` is not a real published tag. The pod is scheduled successfully (this isn't a scheduling problem), but kubelet can't pull the image.

**Fix:** Correct the tag to a real one (`nginx:1.30.4`) and reapply, or `kubectl delete` and recreate — the pod's image field is immutable once created.

**Cascade:** `kubectl get pod bad-image-pod` shows `ErrImagePull` briefly, then settles into `ImagePullBackOff` with retries on an exponential backoff — same backoff pattern as CrashLoopBackOff, but the root cause is entirely different (registry/tag problem, not application code). `kubectl describe pod bad-image-pod` events show the exact registry error message.

</details>

**Cleanup:**
```bash
kubectl delete pod bad-image-pod 2>/dev/null || true
```

---

## Interview Prep

**Q: Why does Kubernetes schedule Pods instead of individual containers?**
A: Because some containers need to be co-located, share a network namespace, or share storage — a sidecar log shipper needs to run on the exact same node as the app container it's reading logs from. The Pod is the atomic unit the scheduler places, guaranteeing everything inside it lands together.

**Q: If a container inside a pod crashes and Kubernetes restarts it, has the Pod restarted?**
A: No — the Pod object itself is untouched. Same Pod, same IP, same UID; only the container instance inside it is new. Mechanically, this is because the network/IPC/UTS namespaces are held open by the pause container, not by your app container — your container can crash and restart without ever affecting the namespaces it joined.

**Q: A teammate says an unset `resources.requests` field just means "no request." Is that always true?**
A: Not necessarily — if the namespace has a `LimitRange` configured, the `LimitRanger` admission controller can inject a default value before the Pod is ever scheduled. What you see in the applied YAML and what actually got persisted to etcd can differ.

**Q: Does setting `containerPort` in a Pod spec open a port or configure a firewall rule?**
A: No — it's purely informational. Nothing in the pod-creation path (not kubelet, not the CNI, not kube-proxy) consumes it to actually open anything. A container is reachable on any port it listens on regardless of what's declared here; the field mainly helps `kubectl` display output and lets a Service reference the port by name.

**Q: What's the practical difference between a resource request and a resource limit?**
A: Requests are what the scheduler uses to decide if a node has room — they're a promise, not an enforcement mechanism. Limits are enforced by the kernel at runtime: CPU limits throttle the process, memory limits get it OOM-killed if exceeded. Setting a CPU limit isn't automatically "safer," either — it protects against noisy neighbors but can throttle your own workload even when the node has spare capacity.

**Q: Two pods have identical `resources.requests`, but one has no `limits` set and the other has `limits` equal to its requests. Do they get the same QoS class?**
A: No — the one with `limits` equal to `requests` (on every resource, every container) is Guaranteed. The one with only requests set is Burstable. Under memory pressure, the Burstable pod is evicted first.

**Q: You need a one-off debugging pod that cleans itself up. What do you run?**
A: `kubectl run debug --image=busybox:1.38.0 --restart=Never -it --rm -- sh` — `--rm` deletes the pod as soon as the interactive session ends, so nothing lingers.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Application Design and Build | CKAD | 20% | Pod/container anatomy, command/args, restartPolicy |
| Application Deployment | CKAD | 20% | Naked pods vs controllers |
| Application Observability and Maintenance | CKAD | 15% | Pod phases, container states, CrashLoopBackOff debugging |
| Workloads & Scheduling | CKA | 15% | Resource requests/limits, QoS classes, admission control on resources |
| Cluster Architecture, Installation & Configuration | CKA | 25% | End-to-end pod creation flow, admission control, component responsibilities |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Confusing `command` and `args` with ENTRYPOINT/CMD | `command` overrides ENTRYPOINT, `args` overrides CMD — mixing these up under time pressure produces a container that runs the wrong thing or crashes immediately |
| Assuming a `Pending` pod is "broken" the same way a `CrashLoopBackOff` pod is | Pending usually means a *scheduling* problem (resources, taints, affinity) — checking `kubectl logs` (which requires a running container) wastes exam time; `kubectl describe` is the right first move |
| Forgetting `cpu` units | `cpu: "1"` means 1 whole core; `cpu: "100m"` means 0.1 core — dropping the `m` by habit is one of the most common exam typos |
| Trying to edit an immutable field on a running pod | Most pod spec fields (image, command, most of `containers[]`) can't be changed in place — you must delete and recreate, which is why controllers exist (resources are a recent, narrow exception — more later) |
| A label selector query returns nothing | Not always "the object doesn't exist" — check for a label typo before assuming the pod was never created |
| Assuming `containerPort` controls reachability | It's informational only — it doesn't open anything |
| Reaching for `kubectl run --requests=`/`--limits=` from memory or an old tutorial | Both flags were deprecated around kubectl 1.20 and fully removed by 1.24 — they no longer exist. Use `--dry-run=client -o yaml`, edit the resources block, then `apply` |

### Exam Task — Write it from scratch

Create a Pod named `exam-pod` running `nginx:1.30.4`, with a CPU request of `100m` and a memory limit of `128Mi`, then verify its QoS class.

Official docs: [Pod Overview](https://kubernetes.io/docs/concepts/workloads/pods/), [Managing Resources](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)

<details>
<summary>Reveal solution</summary>

```bash
# kubectl run's --requests/--limits flags no longer exist (removed in kubectl 1.24) —
# generate a skeleton and edit it instead, exactly per the workflow in
# Quick Commands Reference above.
kubectl run exam-pod --image=nginx:1.30.4 --dry-run=client -o yaml > exam-pod.yaml
```

Edit `exam-pod.yaml` to add the resources block under the container:
```yaml
      resources:
        requests:
          cpu: "100m"
        limits:
          memory: "128Mi"
```

```bash
kubectl apply -f exam-pod.yaml
kubectl get pod exam-pod -o jsonpath='{.status.qosClass}'
```

**Key fields to recall:** `spec.containers[].resources.requests`, `spec.containers[].resources.limits`, `status.qosClass` (Guaranteed only if requests == limits for every resource on every container — this example is Burstable since only some fields match).

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| A Pod is an environment for containers, not a process itself | If a container restarts, the Pod object is untouched — same IP, same UID |
| Pod = atomic scheduling unit | The scheduler places whole Pods on nodes — never splits containers within a Pod across nodes |
| The pause container is what actually implements pod-level sharing | It claims network/IPC/UTS namespaces first; your containers join them, and can crash/restart without destroying them |
| PID and mount namespaces are NOT shared by default | Each container gets its own PID 1 and its own filesystem view — only network/IPC/UTS are shared automatically |
| `command`/`args` override ENTRYPOINT/CMD | Get these wrong and the container may never even start — a different failure mode than a bad env var |
| Admission control can silently change what you applied | `LimitRanger` can inject default resource requests/limits before scheduling ever happens — what you wrote and what got persisted can differ |
| Requests drive scheduling, limits drive enforcement | Requests are what the scheduler checks against node capacity; limits are enforced by the kernel (CPU throttled, memory OOM-killed) |
| CPU limits are a trade-off, not a free safety net | They prevent noisy-neighbor problems but can throttle your workload even when the node has spare capacity |
| kube-proxy has no role in individual pod creation | Its entire job is Service routing — it's irrelevant until a Service exists |
| `containerPort` is informational only | Nothing in the pod-creation path enforces or opens it |
| Pending ≠ CrashLoopBackOff ≠ ImagePullBackOff | Three different failure classes with three different root causes — scheduling, application code, and registry/tag respectively |
| Most pod spec fields are immutable after creation | You can't patch a running pod's image or most of its spec — this is exactly why Deployments exist (resources became a narrow exception in Kubernetes v1.35 — covered later) |
| A pod's QoS class comes from its requests/limits, not a field you set | Guaranteed (requests==limits everywhere) is evicted last under memory pressure; BestEffort (nothing set) is evicted first |
| Containers run as root by default | `securityContext` is what changes that — `runAsNonRoot`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem`, and dropped capabilities are the common hardening levers |
| Naked pods have no self-healing | Delete a naked pod and it's simply gone — only a controller notices and recreates it |
| Pod IPs are ephemeral | A recreated pod gets a new IP — this is the foundational reason Services exist |
| `kubectl delete pod` isn't instant | SIGTERM → `terminationGracePeriodSeconds` → SIGKILL, in that order, driven by kubelet |
| `kubectl run --requests`/`--limits` don't exist anymore | Removed in kubectl 1.24 — generate a skeleton with `--dry-run=client -o yaml` and edit it instead |

---

> **Demo scope:** Primary concept: A Kubernetes Pod's full lifecycle and
> composition — what it is, what it contains, how sharing is implemented at
> the Linux level, and everything that happens between `kubectl apply` and
> a running/terminated container. Supporting concepts: admission control's
> mutating/validating split (needed to explain why applied YAML and
> persisted YAML can differ), Linux namespace mechanics (needed to explain
> pod-level sharing), QoS classes and `securityContext` (both fall directly
> out of fields already covered in Anatomy of a Pod/Container, not separate
> topics).
> Estimated completion time: 65–80 minutes (reading the Concepts section in
> full, 5 Lab steps, 3 Break-Fix scenarios, the 11-question quiz).
> Checkpoints: 1 explicit checkpoint (after Step 2); Break-Fix scenarios
> and the quiz are also natural stopping points.
>
> **Note on the time estimate:** this exceeds the series' 30–45 minute
> per-demo budget (§0b Rule 2). See "Open Questions" in the review summary
> below for the split-vs-keep-as-is decision this should get before the
> series' next revision pass.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get pod <name> -w` | Watch a pod's status change live |
| `kubectl describe pod <name>` | Full spec, status, and events — primary debugging tool |
| `kubectl logs <name>` | Current container logs |
| `kubectl logs <name> --previous` | Logs from the previous (crashed) container instance |
| `kubectl exec -it <name> -- bash` | Interactive shell into a running container |
| `kubectl cp <pod>:<path> <local>` | Copy a file out of a pod |
| `kubectl port-forward pod/<name> <local>:<remote>` | Access a pod directly without a Service |
| `kubectl get pod <name> -o jsonpath='{.status.qosClass}'` | Check a pod's QoS class |
| `kubectl delete pod <name> --force --grace-period=0` | Force-delete a stuck pod (last resort) |

### Generating YAML skeletons with --dry-run

```bash
kubectl run nginx --image=nginx:1.30.4 --dry-run=client -o yaml > pod.yaml
```

**Not supported** — commands that read, describe, or operate on running objects:
`kubectl get`, `describe`, `logs`, `exec`, `delete`, `apply`, `patch`, `label`

**Also not supported (as of kubectl 1.24+)** — `kubectl run --requests=`/`--limits=`.
Both flags were deprecated around kubectl 1.20 and removed entirely by 1.24; setting
resources imperatively now always means dry-run → edit the YAML → apply.

**Exam workflow:** generate the skeleton → edit fields the imperative command doesn't support → `kubectl apply -f pod.yaml`.

### Imperative Quick-Create Commands

| Object | Imperative command | Notes |
|---|---|---|
| Pod | `kubectl run NAME --image=IMG` | Add `--env=`, `--labels=`, `--port=` as needed. `--requests`/`--limits` no longer exist — use dry-run + edit for resources |
| One-shot debug pod | `kubectl run NAME --image=IMG --restart=Never -it --rm -- CMD` | `--rm` auto-deletes on exit — never leaves a naked pod behind |

---

## Appendix — Anki Cards

**`03-pod-container-basics-anki.csv`:**

````
#deck:k8s-platform-labs::01-core-concepts::03-pod-container-basics
#separator:Comma
#columns:Front,Back,Tags
"Is a Pod restarting the same thing as a container inside it restarting?","No — the Pod object itself is untouched (same IP, same UID); only the container instance is new","demo03,pods,ckad-application-design-build"
"What is the pause container's job?","It's the first container kubelet creates for a Pod — it claims the network/IPC/UTS namespaces first, then your containers join them","demo03,internals,pause-container,cka-cluster-architecture-installation-configuration"
"Which namespaces are shared between containers in a Pod by default, and which aren't?","Network, IPC, and UTS are shared by default; PID is NOT shared by default (opt-in via shareProcessNamespace); mount is never shared; each container gets its own cgroup for accounting","demo03,internals,namespaces,cka-cluster-architecture-installation-configuration"
"Why does a shared volume not mean containers see one shared filesystem?","Each container still has its own separate mount namespace — a shared volume is the same volume bind-mounted separately into each container's own isolated view","demo03,internals,volumes,cka-cluster-architecture-installation-configuration"
"What does command override, and what does args override?","command overrides the image's ENTRYPOINT; args overrides the image's CMD","demo03,containers,entrypoint-cmd,ckad-application-design-build"
"Can an admission controller change your Pod's resources.requests before scheduling?","Yes — if a LimitRange exists in the namespace, the LimitRanger admission controller can inject default requests/limits before the Pod is ever scheduled","demo03,admission-control,resources,cka-cluster-architecture-installation-configuration"
"Does containerPort actually open a port or configure a firewall rule?","No — it's informational only. A container is reachable on any port it listens on regardless of what's declared here","demo03,containers,networking,cka-services-networking"
"Is kube-proxy involved in creating a Pod's network namespace?","No — kube-proxy's only job is Service routing (writing iptables/IPVS rules); it plays no role in individual pod creation or pod-to-pod networking","demo03,kube-proxy,networking,cka-services-networking"
"Do CPU limits only help, with no downside?","No — they prevent noisy-neighbor problems but can throttle your own container even when the node has spare CPU capacity","demo03,resources,cka-workloads-scheduling"
"What does READY: 0/1 mean if STATUS shows Running?","The container process is running, but it's failing its readiness probe — READY and STATUS are separate signals","demo03,debugging,ckad-application-observability-maintenance"
"What are the five Pod phases?","Pending, Running, Succeeded, Failed, Unknown","demo03,pod-phases,cka-workloads-scheduling"
"What does ImagePullBackOff mean vs CrashLoopBackOff?","ImagePullBackOff = kubelet can't pull the image (registry/tag problem); CrashLoopBackOff = the container starts but keeps exiting (application problem)","demo03,troubleshooting,ckad-application-observability-maintenance"
"How is a pod's QoS class calculated?","Guaranteed = requests==limits for every resource, every container. BestEffort = no requests/limits set at all. Burstable = anything in between","demo03,qos,resources,cka-workloads-scheduling"
"What order does Kubernetes evict pods under node memory pressure?","BestEffort first, then Burstable, then Guaranteed last","demo03,qos,eviction,cka-workloads-scheduling"
"Does a container run as root by default?","Yes, unless securityContext (runAsUser/runAsNonRoot) says otherwise","demo03,security,securitycontext,ckad-application-environment-configuration-security"
"What actually happens when you run kubectl delete pod?","The pod enters Terminating, kubelet sends SIGTERM, and only after terminationGracePeriodSeconds elapses without exit does kubelet send SIGKILL","demo03,pod-lifecycle,cka-workloads-scheduling"
"Why are pod IPs considered ephemeral?","A recreated pod gets a new IP — this is exactly why Services exist, to provide a stable address","demo03,pods,networking,ckad-services-networking"
"What happens if you delete a naked pod (no controller)?","Nothing recreates it — it's simply gone. Only a controller notices and recreates pods","demo03,pods,controllers,ckad-application-deployment"
"A label-selector query returns nothing. Does that mean the object doesn't exist?","Not necessarily — check for a label typo before assuming nothing was created; the object could be running under an unexpected label","demo03,troubleshooting,cka-troubleshooting"
"What flag makes a one-shot debug pod delete itself automatically?","--rm, combined with --restart=Never -it","demo03,debugging,ckad-application-observability-maintenance"
"Do kubectl run --requests and --limits flags still work?","No — both were deprecated around kubectl 1.20 and removed entirely by 1.24. Use --dry-run=client -o yaml, edit the resources block, then apply","demo03,kubectl,imperative,ckad-application-design-build"
"What's the exponential backoff sequence for CrashLoopBackOff, and when does it reset?","10s, 20s, 40s, 80s, 160s, capped at 5 minutes; resets to 10s after 10 consecutive minutes of the container staying up","demo03,troubleshooting,crashloopbackoff,ckad-application-observability-maintenance"
````

---

## Appendix — Quiz

**`03-pod-container-basics-quiz.md`:**

````markdown
# Quiz — 01-core-concepts/03-pod-container-basics: Pod and Container Basics

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. What is the pause container's job in a Pod?**

- A) It runs the main application logic before your containers start
- B) It's the first container created — it claims the network/IPC/UTS namespaces so your containers can join them
- C) It only exists in multi-container pods
- D) It monitors resource usage and enforces limits

<details>
<summary>Answer</summary>

**B** — The pause container does nothing but hold namespaces open; every container in the pod, including single-container pods, joins its namespaces.
Trap: C is wrong — every Pod has a pause container, not just multi-container ones.

</details>

---

**Q2. Which namespaces are shared between containers in a Pod by default?**

- A) Network, IPC, UTS
- B) PID, mount, cgroup
- C) All Linux namespaces are shared by default
- D) None are shared by default — you must opt in to all sharing

<details>
<summary>Answer</summary>

**A** — Network, IPC, and UTS are shared automatically. PID sharing is opt-in (`shareProcessNamespace: true`), and mount namespace is never shared; each container also gets its own cgroup accounting.
Trap: B lists exactly the namespaces/mechanisms that are NOT shared by default — a common mix-up.

</details>

---

**Q3. A container inside a running Pod crashes and Kubernetes restarts it. What happens to the Pod itself?**

- A) The Pod is deleted and a brand new Pod is created with a new IP
- B) The Pod object is untouched — same IP, same UID, only the container instance is new
- C) The Pod moves to a different node automatically
- D) The Pod's labels are reset to default

<details>
<summary>Answer</summary>

**B** — The network namespace is held by the pause container, not the app container, so a container crash doesn't affect the Pod's identity.
Trap: A assumes "restart" always means full recreation — that's what happens when a *controller* replaces a pod, not when a container inside an existing pod restarts.

</details>

---

**Q4. A namespace has a LimitRange configured. You create a Pod with no `resources.requests` set. What happens?**

- A) The Pod is rejected outright
- B) The LimitRanger admission controller can inject a default request before the Pod is scheduled
- C) Nothing — LimitRange only affects Deployments, not Pods
- D) The Pod runs with unlimited resources

<details>
<summary>Answer</summary>

**B** — LimitRanger's mutating phase can inject defaults for unset resource fields before the object is ever scheduled — what you applied and what got persisted can differ.
Trap: D assumes omitting a field means no constraint at all, ignoring namespace-level defaulting.

</details>

---

**Q5. Does setting `containerPort` in a Pod spec open a port or configure a firewall rule?**

- A) Yes, it opens the port at the node's firewall
- B) No — it's informational only; a container is reachable on any port it listens on regardless
- C) It only matters if kube-proxy is running
- D) It configures the CNI plugin's port mapping

<details>
<summary>Answer</summary>

**B** — Nothing in the pod-creation path consumes this field to actually open anything. It mainly helps `kubectl` display output and lets a Service reference the port by name.
Trap: C wrongly ties this field to kube-proxy, which isn't involved in pod creation at all.

</details>

---

**Q6. What's the difference between `command` and `args` in a container spec?**

- A) They're interchangeable — either can be used for anything
- B) command overrides ENTRYPOINT; args overrides CMD
- C) command sets environment variables; args sets the image
- D) args overrides ENTRYPOINT; command overrides CMD

<details>
<summary>Answer</summary>

**B** — This is the actual mapping. Getting it backwards (D) is a common mix-up under time pressure.
Trap: D swaps the two — a classic exam-day error since the names don't obviously map to ENTRYPOINT/CMD without having memorized the direction.

</details>

---

**Q7. A pod shows `STATUS: Running` but `READY: 0/1`. What does that mean?**

- A) The pod is about to be deleted
- B) The container is running but failing its readiness probe
- C) The pod has no containers at all
- D) The node is out of resources

<details>
<summary>Answer</summary>

**B** — Running and Ready are two separate signals; a container can be executing and still not pass its readiness check.
Trap: This is one of the most common real-world misreadings — assuming "Running" alone means the pod is fully healthy.

</details>

---

**Q8. You run `kubectl get pods -l app=web-frontend` and get no results, even though you're sure you created the pod. What's a likely explanation?**

- A) The cluster lost the pod
- B) A label typo — the pod may exist under a slightly different label value
- C) Label selectors only work with 100% certainty on Deployments, not Pods
- D) You must use `--all-namespaces` for label selectors to work at all

<details>
<summary>Answer</summary>

**B** — An empty selector result doesn't mean the object doesn't exist — it means nothing currently matches that exact label. Run `kubectl get pods` without a selector to check.
Trap: A assumes cluster-level data loss for what's almost always a much simpler typo.

</details>

---

**Q9. In the end-to-end pod creation flow, which component actually enforces `resources.limits` at runtime?**

- A) kube-scheduler
- B) kube-apiserver, via admission control
- C) The kernel, via cgroups configured by kubelet through the CRI
- D) kube-proxy

<details>
<summary>Answer</summary>

**C** — kubelet translates `resources.limits` into cgroup parameters at container-creation time, but the actual throttling/OOM-killing enforcement happens at the kernel level, not through kubelet continuously policing it.
Trap: A confuses `requests` (a scheduling input) with `limits` (a runtime enforcement mechanism) — they're used by entirely different components.

</details>

---

**Q10. What actually happens, in order, when you run `kubectl delete pod`?**

- A) SIGKILL is sent immediately
- B) The pod is removed from etcd instantly, then containers stop afterward
- C) Terminating status → SIGTERM → grace period → SIGKILL if still running
- D) The pod is paused, not deleted, until manually confirmed

<details>
<summary>Answer</summary>

**C** — Deletion gives the container a chance to shut down cleanly within `terminationGracePeriodSeconds` before being forcefully killed, all driven by kubelet.
Trap: A skips the entire graceful-shutdown mechanism that `terminationGracePeriodSeconds` exists to provide.

</details>

---

**Q11. A pod's single container has `resources.requests` set for CPU and memory, but no `resources.limits` set at all. What's its QoS class?**

- A) Guaranteed
- B) Burstable
- C) BestEffort
- D) It has no QoS class unless limits are also set

<details>
<summary>Answer</summary>

**B** — Guaranteed requires requests *equal to* limits for every resource on every container; BestEffort requires *neither* requests nor limits set on any container. Anything else — including "only requests, no limits" — is Burstable.
Trap: C assumes any missing field defaults to the lowest tier; it doesn't — BestEffort specifically means *nothing at all* is set.

</details>

Score guide:
| Score | Action |
|---|---|
| 9/11 or above | Import Anki cards, move to next Demo |
| 8/11 | Review the wrong answers, then proceed |
| 6–7/11 | Re-read the relevant section, retry those questions |
| Below 6/11 | Re-read the full demo and redo the walkthrough before proceeding |
````