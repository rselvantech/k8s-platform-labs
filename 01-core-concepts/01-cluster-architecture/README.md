# Demo: 01-core-concepts/01-cluster-architecture — Cluster Architecture

## Lab Overview

Before you can meaningfully work with any Kubernetes object — a Pod, a
Deployment, a Service — you need to understand the system that manages those
objects. This lab explains the Kubernetes cluster architecture: what components
exist, where they run, what each one does, and how a request flows from your
kubectl command through the system until a container is running on a node.

This is a theory-and-observation lab. There are no manifests to deploy. You
will inspect the components of your running `3node` minikube cluster, locate
their processes, read their logs, and confirm the architecture from inside the
cluster.

**What you'll learn:**
- The two-tier architecture: control plane and worker nodes
- Every control plane component: kube-apiserver, etcd, kube-scheduler,
  kube-controller-manager, cloud-controller-manager
- Every worker node component: kubelet, kube-proxy, container runtime
- Static pods — how control plane components bootstrap themselves
- The full lifecycle of a `kubectl apply` — what happens at each step
- How the API server is the single point of truth and the only component
  that talks to etcd
- Add-on components: CoreDNS, metrics-server

## Prerequisites

**Required:**
- Minikube `3node` profile running (1 control-plane + 2 workers)
- kubectl configured for `3node`

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Name every control plane component and explain its single responsibility
2. ✅ Name every worker node component and explain what it does on each node
3. ✅ Explain why kube-apiserver is the only component that talks to etcd
4. ✅ Explain what static pods are and why control plane components use them
5. ✅ Trace the full flow of `kubectl apply -f deployment.yaml` step by step
6. ✅ Locate and inspect each component's process or pod in your cluster
7. ✅ Explain what happens when each component fails

## Directory Structure

```
01-core-concepts/01-cluster-architecture/
├── README.md                                # this file
├── 01-cluster-architecture-anki.csv         # Anki flashcard deck
└── 01-cluster-architecture-quiz.md          # standalone quiz
```

---

## Concepts

### Kubernetes Architecture Overview

### The Two-Tier Model

```
┌─────────────────────────────────────────────────────────────────┐
│  CONTROL PLANE  (runs on the control-plane node: 3node)         │
│                                                                  │
│  kube-apiserver      ← single entry point for all API calls     │
│  etcd                ← cluster state database (only apiserver   │
│                         talks to this)                          │
│  kube-scheduler      ← decides WHICH node a pod runs on        │
│  kube-controller-manager ← runs all built-in controllers       │
│  cloud-controller-manager ← cloud-provider integration (EKS,   │
│                              GKE, AKS — not used in minikube)   │
└─────────────────────────────────────────────────────────────────┘
            ▲  All components talk TO the apiserver
            │  (apiserver is the only one that talks TO etcd)
            ▼
┌─────────────────────────────────────────────────────────────────┐
│  WORKER NODES  (3node-m02, 3node-m03)                           │
│                                                                  │
│  kubelet         ← node agent: runs pods, reports status        │
│  kube-proxy      ← implements Service networking rules          │
│  container runtime (containerd) ← actually runs containers      │
└─────────────────────────────────────────────────────────────────┘
```

**The most important architectural rule:**
kube-apiserver is the ONLY component that reads from and writes to etcd.
Every other component watches the apiserver, never etcd directly.
This design makes the cluster auditable, securable, and consistent.

---

### Control Plane Components — Deep Dive

### kube-apiserver

```
Role:     Front door to the cluster. Every kubectl command, every
          controller, every kubelet communicates through here.

What it does:
  1. Authentication  — who is making this request?
  2. Authorisation   — is this user/serviceaccount allowed to do this?
  3. Admission control — should this request be mutated or rejected?
  4. Validation      — is this object spec valid?
  5. Persistence     — write the object to etcd
  6. Notification    — tell watchers the object changed

Scaling:  Horizontal — you can run multiple apiserver replicas behind
          a load balancer. Each replica is stateless (state is in etcd).

Key fact: All communication in the cluster flows through the apiserver.
          etcd speaks to NO other component. Neither kube-scheduler nor
          kube-controller-manager speak to any other component except
          the apiserver — confirmed by their Command flags, which only
          reference a kubeconfig pointing at the apiserver, never etcd.
```

### etcd

```
Role:     The cluster's single source of truth. A distributed,
          strongly-consistent key-value store.

What it stores:
  - All Kubernetes objects (Pods, Deployments, Services, Secrets, ...)
  - Cluster state (node statuses, lease records)
  - Configuration data

Consistency model: Raft consensus — a write is only acknowledged after
  a majority of etcd members agree. This prevents split-brain.

Fault tolerance: Requires quorum (majority) to operate.
  1 member → tolerates 0 failures
  3 members → tolerates 1 failure   ← minimum for production HA
  5 members → tolerates 2 failures
  Formula: can tolerate floor(N/2) failures

Scaling:  Fixed-size cluster (odd member count, 3 or 5) — does not scale by
          adding arbitrary replicas. More capacity comes from faster
          disks/more RAM per member, not more members past what quorum
          math tolerates.

Key fact: etcd stores data as key/value pairs under /registry/.
  kubectl get pod nginx -o yaml
  → apiserver reads /registry/pods/default/nginx from etcd
  → returns it to you as YAML
```

### kube-scheduler

```
Role:     Assigns unscheduled Pods to Nodes.

Process:
  1. Watch apiserver for Pods with nodeName == "" (not yet scheduled)
  2. For each unscheduled Pod, run the scheduling cycle:
     a. Filtering: remove nodes that CANNOT run this pod
        - Insufficient CPU/memory
        - Node has taint the pod does not tolerate
        - Node does not satisfy nodeAffinity required rules
        - Node is cordoned (unschedulable)
     b. Scoring: rank remaining nodes
        - Prefer nodes with fewer pods (spread)
        - Prefer nodes with requested resources already cached
        - Apply preferred affinity weights
     c. Bind: write spec.nodeName to the Pod object in etcd (via apiserver)
  3. Kubelet on that node notices the Pod is assigned to it → starts it

Scaling:  NOT horizontal like apiserver. Multiple replicas can run for HA,
          but only one is active (the leader) at a time — coordinated via
          a Lease object in kube-system, using --leader-elect=true. Standby
          replicas do nothing until the leader's lease expires. This
          cluster runs with --leader-elect=false (single control-plane
          node, no HA needed — confirmed in the Command flags).

Key fact: The scheduler only DECIDES where a pod goes.
          It writes to the apiserver. The kubelet does the actual work.
```

### kube-controller-manager

```
Role:     Runs all the built-in controllers as goroutines in one process.

A controller is a loop:
  WATCH current state (via apiserver)
  COMPARE to desired state (spec)
  ACT to reconcile the difference

Built-in controllers (subset):
  Node controller         watches nodes, handles NotReady transitions
  ReplicaSet controller   ensures spec.replicas pods exist
  Deployment controller   manages ReplicaSets for rolling updates
  Job controller          creates pods for Jobs, tracks completions
  CronJob controller      creates Jobs on schedule
  StatefulSet controller  manages StatefulSet pods with ordering
  DaemonSet controller    ensures one pod per matching node
  Namespace controller    creates default resources for new namespaces
  ServiceAccount controller creates default SA for new namespaces
  EndpointSlice controller  keeps EndpointSlices in sync with pods

Scaling:  Same leader-election model as kube-scheduler — multiple replicas
          can run for HA, but only one is active at a time, coordinated via
          a Lease object in kube-system (--leader-elect=true in production).
          This cluster runs with --leader-elect=false (confirmed in the
          Command flags).

Key fact: All controllers watch the apiserver and write back to the
          apiserver. No controller talks directly to etcd.
```

### cloud-controller-manager

```
Role:     Integrates Kubernetes with cloud provider APIs.
          Runs only when Kubernetes is deployed on a cloud.

Handles:
  LoadBalancer Services  → create AWS NLB / GCP LB / Azure LB
  Node lifecycle         → detect when cloud VMs are terminated
  Route management       → configure VPC routes for pod networking
  PersistentVolumes      → provision EBS / GCE PD / Azure Disk

In minikube: Not used. In EKS/GKE/AKS: runs as a separate process
managed by the cloud provider.

Scaling:  Same leader-election model as kube-controller-manager when run
          in HA clouds — single active instance.

Key fact: Only exists when the cluster runs on a supported cloud provider.
          minikube and bare-metal clusters have no cloud-controller-manager
          process at all — this is why it's absent from your `kubectl get
          pods -n kube-system` output.

```

---

### Worker Node Components — Deep Dive

### kubelet

```
Role:     The node agent. The only Kubernetes component that runs
          directly as a systemd service (not as a pod).

Responsibilities:
  1. Register the node with the apiserver on startup
  2. Watch apiserver for Pods assigned to this node
  3. Pull container images (via CRI)
  4. Start/stop containers (via CRI)
  5. Run liveness/readiness/startup probes
  6. Mount volumes (ConfigMaps, Secrets, PVCs)
  7. Report node and pod status back to apiserver
  8. Enforce resource limits via cgroups

CRI (Container Runtime Interface): kubelet does NOT directly create
  containers. It calls the CRI API. The CRI implementation
  (containerd, CRI-O) actually runs containers.

Static Pods: kubelet also reads pod manifests from
  /etc/kubernetes/manifests/ on the node filesystem.
  These pods are started by kubelet WITHOUT the apiserver.
  This is how control plane components bootstrap themselves.

Scaling:  Exactly one instance per node, always. Not horizontally scaled —
          more capacity means more nodes, not more kubelets per node.

Key fact: kubelet is the executor. It does what the scheduler decided.
          It never modifies the scheduler's decision or rebalances pods
          across nodes.
```

### kube-proxy

```
Role:     Implements the Services networking model on each node.

What it does:
  - Watches apiserver for Service and EndpointSlice changes
  - Translates Service VIPs (ClusterIP) → real Pod IPs using one of:
    iptables mode  (default): writes iptables DNAT rules
    IPVS mode:     uses Linux IPVS for faster, more scalable routing
    nftables mode: new in Kubernetes 1.31 (replaces iptables)

Example: Service nginx has ClusterIP 10.96.100.10, port 80
  Three pods behind it: 10.244.0.5, 10.244.1.8, 10.244.2.3
  kube-proxy writes iptables rules:
    DNAT 10.96.100.10:80 → randomly select one of the three pod IPs

Scaling:  Runs as one DaemonSet pod per node — scales automatically with
          node count, not independently configurable.

Key fact: kube-proxy does NOT proxy traffic at the application layer.
          It only writes kernel networking rules. The kernel forwards
          the packets, not kube-proxy.
          
Note: Some CNI plugins (Cilium with eBPF mode) can replace kube-proxy
      entirely, implementing service routing in eBPF instead.
```

### Container Runtime (containerd)

```
Role:     The low-level component that actually runs containers.

CRI flow:
  kubelet → CRI gRPC API → containerd → runc → container process

containerd responsibilities:
  - Pull images from registries (with image cache)
  - Create container filesystem snapshots (overlayfs)
  - Configure namespaces (pid, net, mnt, uts, ipc, user)
  - Configure cgroups (resource limits)
  - Manage container lifecycle (create, start, stop, delete)

Supported runtimes in Kubernetes:
  containerd  ← default in modern clusters (minikube, EKS, GKE)
  CRI-O       ← used in OpenShift
  Docker      ← removed in Kubernetes 1.24 (use containerd instead)

Scaling:  One instance per node, same as kubelet — not independently
          scaled.

Key fact: containerd predates Kubernetes' CRI standard. It was donated to
          CNCF and later adapted to implement CRI so kubelet could use it
          as a pluggable, swappable runtime.
```

---

### Static Pods — How Control Plane Bootstraps

```
Problem: The control plane components (apiserver, scheduler, etcd,
         controller-manager) are themselves Kubernetes pods.
         But the apiserver must exist before Kubernetes can create pods.
         How does the chicken-and-egg problem get solved?

Answer: Static Pods.

The kubelet can read pod manifests from a local directory:
  /etc/kubernetes/manifests/

When kubelet starts, it reads:
  kube-apiserver.yaml          → starts kube-apiserver container
  etcd.yaml                    → starts etcd container
  kube-scheduler.yaml          → starts kube-scheduler container
  kube-controller-manager.yaml → starts kube-controller-manager container

These are static pods — they are managed by kubelet directly,
NOT through the apiserver. They appear in kubectl get pods -n kube-system
as mirror pods (read-only reflections of what kubelet is running).

Static pods always have the node name as a suffix:
  kube-apiserver-3node           ← running on node 3node
  etcd-3node
  kube-scheduler-3node
  kube-controller-manager-3node
```

---

### Add-on Components

```
CoreDNS
  Runs as: Deployment in kube-system namespace (2 replicas)
  Role:    DNS server for the cluster
           Automatically creates DNS records for all Services and Pods
           Every pod's /etc/resolv.conf points to CoreDNS IP
  Explained in: 03-services/04-dns-coredns

metrics-server
  Runs as: Deployment in kube-system namespace
  Role:    Collects CPU/memory metrics from kubelets (via Metrics API)
           Powers: kubectl top nodes, kubectl top pods, HPA
  Enable:  minikube addons enable metrics-server --profile 3node
  Note:    Not deployed by default in minikube — metrics stored in memory
           only (not persistent). For persistent metrics: use Prometheus.
```

---

### The Full Request Lifecycle — kubectl apply

What happens when you run `kubectl apply -f deployment.yaml`?

```
Step 1: kubectl reads kubeconfig (~/.kube/config)
        Finds the server URL: https://192.168.49.2:8443
        Finds the client certificate for authentication

Step 2: kubectl sends HTTP POST to kube-apiserver
        POST /apis/apps/v1/namespaces/default/deployments
        Body: your Deployment YAML (serialised to JSON internally)

Step 3: kube-apiserver — Authentication
        Validates the client certificate
        Identifies the user: kubernetes-admin

Step 4: kube-apiserver — Authorisation (RBAC)
        Checks: can kubernetes-admin create Deployments in default?
        Result: Yes (kubernetes-admin has cluster-admin ClusterRoleBinding)

Step 5: kube-apiserver — Admission control
        Mutating webhooks run first (e.g. inject sidecars, add defaults)
        Validating webhooks run after (e.g. enforce naming policies)

Step 6: kube-apiserver — Schema validation
        Validates all required fields, correct types, valid values

Step 7: kube-apiserver writes Deployment to etcd
        Key: /registry/apps/deployments/default/nginx-deployment
        Returns HTTP 201 Created to kubectl

Step 8: Deployment controller (inside kube-controller-manager) notices
        new Deployment (it watches apiserver for Deployment changes)
        Creates a ReplicaSet with the desired replica count

Step 9: ReplicaSet controller notices new ReplicaSet
        Creates N Pod objects (spec.nodeName is empty — not yet scheduled)
        Writes Pods to etcd via apiserver

Step 10: kube-scheduler notices Pods with nodeName == ""
         Filters nodes, scores nodes, selects best node for each Pod
         Writes spec.nodeName = "3node-m02" back to the Pod via apiserver

Step 11: kubelet on 3node-m02 notices Pod assigned to it
         Pulls the container image via containerd
         Creates the container namespaces and cgroups
         Starts the container
         Runs readiness probe

Step 12: kubelet reports Pod status = Running back to apiserver
         apiserver writes updated status to etcd

Step 13: kube-proxy on all nodes notices new EndpointSlices
         Updates iptables/IPVS rules to include this Pod's IP

Step 14: kubectl poll returns: deployment.apps/nginx-deployment created
```

---

### Reference — Component Failure Impact

| Component fails | Immediate impact | Cluster still works? |
|-----------------|-----------------|----------------------|
| kube-apiserver | No kubectl, no new deployments, no scaling | Existing pods keep running |
| etcd | kube-apiserver cannot read/write — all API calls fail | Existing pods keep running |
| kube-scheduler | New pods stay Pending — no new scheduling | Existing pods keep running |
| kube-controller-manager | No new ReplicaSets, no rolling updates, no self-healing | Existing pods keep running |
| kubelet (one node) | Pods on that node not restarted if they crash | Other nodes unaffected |
| kube-proxy (one node) | Service routing broken on that node | Other nodes unaffected |
| CoreDNS | DNS resolution fails across entire cluster | Pods still run, cannot resolve names |

**Key insight:** The control plane being down does NOT kill running workloads.
Pods that are already running continue until the node they are on fails.
The cluster cannot CHANGE state without the control plane — it cannot scale,
heal, or schedule new pods.

---

## Lab Step-by-Step Guide

### Step 1: View the control plane components as static pods

```bash
kubectl get pods -n kube-system
```

**Expected — look for these:**
```
NAME                               READY   STATUS    NODE
coredns-xxxxxxxxxx-xxxxx           1/1     Running   3node
coredns-xxxxxxxxxx-xxxxx           1/1     Running   3node
etcd-3node                         1/1     Running   3node      ← static pod
kube-apiserver-3node               1/1     Running   3node      ← static pod
kube-controller-manager-3node      1/1     Running   3node      ← static pod
kube-proxy-xxxxx                   1/1     Running   3node      ← DaemonSet
kube-proxy-xxxxx                   1/1     Running   3node-m02
kube-proxy-xxxxx                   1/1     Running   3node-m03
kube-scheduler-3node               1/1     Running   3node      ← static pod
```

Static pods have the node name suffix. kube-proxy runs as a DaemonSet
(one pod per node). CoreDNS runs as a Deployment.

---

### Step 2: Inspect the static pod manifests on the control-plane node

```bash
# SSH into the control-plane node
minikube ssh --profile 3node

# List the static pod manifests
ls /etc/kubernetes/manifests/
# etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml

# View the apiserver manifest (note the flags — auth, tls, etcd endpoint)
# (sudo is required — the manifest file is root-owned)
sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep -E "command|--etcd|--tls|--service"

exit
```

---

### Step 3: View the apiserver flags

```bash
kubectl describe pod kube-apiserver-3node -n kube-system | grep -A50 "Command:"
```

**Key flags to notice:**
```
--etcd-servers=https://127.0.0.1:2379      ← apiserver talks to local etcd
--etcd-certfile / --etcd-keyfile            ← mTLS to etcd
--tls-cert-file / --tls-private-key-file    ← TLS for clients
--service-cluster-ip-range=10.96.0.0/12    ← ClusterIP range
--authorization-mode=Node,RBAC             ← RBAC enabled
--enable-admission-plugins=...             ← admission controllers
```

---

### Step 4: View the scheduler configuration

```bash
kubectl describe pod kube-scheduler-3node -n kube-system | grep -A20 "Command:"
```

```bash
# Confirm scheduler is watching for unscheduled pods
kubectl get events --field-selector reason=Scheduled | head -10
# Shows: Successfully assigned default/xxx to 3node-m02
```

> **Note:** Events have a short retention window (about 1 hour by default).
> If nothing has been scheduled recently, this may return `No resources
> found in default namespace.` — that's expected, not a problem. To see a
> live event, create a quick test pod/deployment first (Step 8 does
> exactly this).

---

### Step 5: View the controller-manager

```bash
kubectl describe pod kube-controller-manager-3node -n kube-system | grep -A30 "Command:"
```

**Note in the flags:**
```
--controllers=*          ← all controllers enabled
--node-monitor-period    ← how often to check node health
--pod-eviction-timeout   ← how long before evicting pods from NotReady node
```

---

### Step 6: Inspect the kubelet on a worker node

```bash
# SSH into a worker node
minikube ssh -n 3node-m02 --profile 3node

# kubelet runs as a systemd service (not a pod)
sudo systemctl status kubelet

# View kubelet configuration
sudo cat /var/lib/kubelet/config.yaml | grep -E "staticPod|resolverConfig|clusterDNS"
# staticPodPath: /etc/kubernetes/manifests  ← reads static pods from here
# clusterDNS: [10.96.0.10]                 ← CoreDNS IP injected into pods

exit
```

---

### Step 7: Inspect kube-proxy

```bash
kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide
# One pod per node — it is a DaemonSet

kubectl logs -n kube-system -l k8s-app=kube-proxy | head -20
# Shows: "Using iptables mode" or "Using ipvs mode"
```

```bash
# SSH into a worker node and view the iptables rules kube-proxy created
minikube ssh -n 3node-m02 --profile 3node
sudo iptables -t nat -L KUBE-SERVICES | head -20
# Each ClusterIP Service has DNAT rules here
exit
```

---

### Step 8: Watch the controller-manager react in real time

```bash
# Terminal 1 — watch events
kubectl get events -w

# Terminal 2 — create then delete a deployment
kubectl create deployment test-arch --image=nginx:1.27 --replicas=2
# Events: ScalingReplicaSet, SuccessfulCreate, Scheduled, Pulled, Started
kubectl delete deployment test-arch
# Events: ScalingReplicaSet, Killing
```

The sequence of events shows: Deployment controller → ReplicaSet controller
→ Scheduler → kubelet. Each step is a separate controller responding to
an API object change.

---

### Step 9: Verify the single-apiserver rule — etcd only talks to apiserver

```bash
# SSH into control-plane
minikube ssh --profile 3node

# Check what connects to etcd port 2379
sudo ss -tnp | grep 2379
# Only kube-apiserver and etcd's own process should appear here —
no other component's process name should ever show up

exit
```

---

## What You Learned

In this lab, you:
- ✅ Named all control plane components and their single responsibilities
- ✅ Named all worker node components and what each does on every node
- ✅ Explained why apiserver is the only component that speaks to etcd
- ✅ Located static pod manifests in `/etc/kubernetes/manifests/`
- ✅ Traced a `kubectl apply` through all 14 steps from CLI to running container
- ✅ Observed the components running in your minikube cluster
- ✅ Inspected apiserver flags: etcd endpoint, RBAC, admission plugins
- ✅ Confirmed kube-proxy is a DaemonSet writing iptables rules
- ✅ Understood the failure impact of each component


## Break-Fix

> This lab has no manifests to break. These are diagnostic scenarios based on
> symptoms you might observe in a real cluster — work out the answer, then
> check yourself against the explanation.

### Scenario-1 — `etcd-3node` is missing from `kubectl get pods -n kube-system`

**Symptom:** `kubectl get pods -n kube-system` no longer lists `etcd-3node`, and every `kubectl` command now hangs or times out.

**Diagnosis:** etcd is down, so kube-apiserver cannot read or write cluster state — the apiserver itself typically becomes unresponsive to most requests since almost every API call needs etcd. Existing running pods are unaffected (kubelet keeps them running independently), but nothing can be created, updated, scaled, or even listed reliably until etcd is restored.

**What to check:** SSH into the control-plane node and confirm the static pod manifest at `/etc/kubernetes/manifests/etcd.yaml` is present and unmodified — kubelet restarts static pods automatically if the manifest is intact but the container crashed.

### Scenario-2 — New Deployment stuck with all Pods in `Pending`

**Symptom:** You create a Deployment. `kubectl get pods` shows all replicas stuck in `Pending`, forever, with no scheduling events.

**Diagnosis:** kube-scheduler is not running, crashed, or not watching the apiserver. The apiserver and etcd are healthy (the Pod objects were created and written to etcd fine — that's why they show up in `kubectl get pods` at all), but nothing is assigning `spec.nodeName`.

**What to check:** `kubectl get pods -n kube-system | grep scheduler` — if `kube-scheduler-3node` is missing or `CrashLoopBackOff`, that's the cause. Existing already-scheduled pods are unaffected.

### Scenario-3 — Deleted Pod never comes back, even though a Deployment manages it

**Symptom:** You delete a Pod that belongs to a Deployment. Normally a new one appears within seconds. This time, nothing happens — the replica count stays down.

**Diagnosis:** kube-controller-manager is down, so the ReplicaSet controller's reconcile loop (watch → compare → act) isn't running. The Deployment and ReplicaSet objects still exist correctly in etcd — they're just not being reconciled.

**What to check:** `kubectl get pods -n kube-system | grep controller-manager`. Also confirm this is the actual cause and not a scheduler issue — a missing scheduler still creates the Pod object (stuck Pending), while a missing controller-manager never even creates the replacement Pod object at all.

### Scenario-4 — One node's Pods keep failing DNS-based Service calls, other nodes are fine

**Symptom:** Pods on `3node-m02` can't resolve `myservice.default.svc.cluster.local` or reach other Services by ClusterIP. Pods on `3node-m03` work fine.

**Diagnosis:** kube-proxy on `3node-m02` specifically is down or hasn't updated its iptables rules — since kube-proxy runs as a DaemonSet (one independent instance per node), a failure is node-scoped, not cluster-wide. CoreDNS itself is fine (that's why other nodes resolve correctly).

**What to check:** `kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide` — confirm the pod on `3node-m02` is `Running`; if it is but rules are still stale, check its logs for iptables write errors.

## Interview Prep

**Q1: "Why does Kubernetes route everything through the apiserver instead of letting components talk to etcd directly?"**
Centralizing all reads/writes through one component means every request goes through the same authentication, authorization, admission control, and validation pipeline — and etcd never has to implement any of that itself. It also means etcd can be swapped, backed up, or scaled without any other component needing to know it exists.

**Q2: "If etcd loses quorum, are running workloads affected immediately?"**
No — kubelets on each node keep running the containers they already know about, independent of etcd or the apiserver. What breaks immediately is anything that requires a *change*: no new pods, no scaling, no self-healing if a pod crashes and needs recreation via a controller. The cluster becomes read/execute-only for existing state until quorum is restored.

**Q3: "Explain static pods and why the control plane specifically needs them."**
Static pods are manifests the kubelet reads directly from a local directory (`/etc/kubernetes/manifests/`) and runs without ever talking to the apiserver. The control plane needs this because there's a bootstrapping problem — the apiserver itself is a pod, but pods normally require a working apiserver to be scheduled. Static pods break that circular dependency by letting kubelet start them independently.

**Q4: "Walk through what happens between running `kubectl apply` and a container actually starting."**
At a high level: kubectl authenticates and sends the object to the apiserver → apiserver runs authn/authz/admission/validation and persists it to etcd → the relevant controller (e.g. Deployment controller) notices the new object and creates the next object down the chain (ReplicaSet, then Pods) → kube-scheduler assigns a node to each unscheduled Pod → kubelet on that node pulls the image via the container runtime and starts the container → kube-proxy updates networking rules once the pod has an IP.

**Q5: "Why can kube-apiserver run multiple replicas, but etcd can't just be scaled the same way?"**
kube-apiserver is stateless — all state lives in etcd, so any apiserver replica behind a load balancer can serve any request identically. etcd is the opposite: it holds the actual state and uses Raft consensus, where adding members changes the quorum math (majority requirement) and every additional write must be acknowledged by a majority of members — so etcd is scaled deliberately in odd numbers for fault tolerance, not simply "add more replicas" for throughput.

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Demo concept / command | CKA objective | CKAD objective | Notes |
|---|---|---|---|
| Control plane components and their single responsibilities | Cluster Architecture, Installation & Configuration (25%) | — | Core CKA topic; CKAD does not test control plane internals |
| etcd role, Raft consensus, quorum math | Cluster Architecture, Installation & Configuration (25%) | — | CKA may ask "how many etcd members tolerate N failures" |
| Static pods — location, naming, bootstrap purpose | Cluster Architecture, Installation & Configuration (25%) | — | Classic CKA task: diagnose a broken static pod manifest on a node |
| kube-scheduler filtering/scoring process | Workloads & Scheduling (15%) | Application Deployment (20%) | Both exams expect you to reason about why a pod stays Pending |
| kubelet responsibilities, CRI | Cluster Architecture, Installation & Configuration (25%) | — | CKA-heavy; understanding the CRI boundary matters for runtime troubleshooting |
| kube-proxy modes (iptables/IPVS/nftables) | Services & Networking (20%) | Services and Networking (20%) | Genuinely dual-relevant — both exams touch Service networking behavior |
| Full `kubectl apply` request lifecycle | Cluster Architecture, Installation & Configuration (25%) | Application Deployment (20%) | Useful mental model for diagnosing "where in the chain did this stall" on either exam |
| Component-down failure impact (Reference table) | Troubleshooting (30%) | Application Observability and Maintenance (15%) | Directly tests the ability to localize a fault to one component from symptoms alone |

### Common Exam Traps

| Scenario | What the task actually requires | Common wrong approach |
|---|---|---|
| Task shows a cluster where new pods stay `Pending` indefinitely with no scheduling events, and asks you to identify the likely cause | Recognize this points specifically at kube-scheduler being down or unhealthy — not the apiserver or etcd, since the Pod object clearly exists (visible via `kubectl get pods`) | Investigating etcd/apiserver health first, when the fact that `kubectl get pods` works at all already rules those out |
| Task asks you to fix a static pod that won't start on a control-plane node | Edit or replace the manifest file in `/etc/kubernetes/manifests/` directly on that node — kubelet picks up filesystem changes automatically, no `kubectl apply` involved | Trying to `kubectl edit` or `kubectl apply` a static pod's mirror pod — mirror pods are read-only reflections and cannot be edited via the API |
| Task states etcd has 3 members and asks how many member failures the cluster can tolerate before losing quorum | 1 — quorum requires a majority (2 of 3); losing 2 members loses quorum | Assuming "3 members" means "tolerates 3 failures," or miscalculating majority incorrectly |
| Task shows Service routing broken on exactly one node while every other node works fine, and asks for the root cause | Since kube-proxy runs as a per-node DaemonSet, a single-node routing failure points at that node's kube-proxy instance specifically, not CoreDNS or the Service object itself | Assuming a Service/DNS-level problem (which would be cluster-wide) when the symptom is explicitly node-scoped |

### Exam Task

Not applicable — this demo is theory/observation-only and creates no
Kubernetes objects with a kubectl imperative equivalent (no Deployment,
Pod, Job, ConfigMap, etc. is ever applied — Step 8's test-arch Deployment
is created and deleted purely to observe controller events, not as a
persistent lab artifact). Per the master's object-less exception, no
`Exam Task — Write it from scratch` is fabricated here.

## Key Takeaways

| Concept | Detail |
|---|---|
| Two-tier architecture | Control plane (kube-apiserver, etcd, kube-scheduler, kube-controller-manager, cloud-controller-manager) and worker nodes (kubelet, kube-proxy, container runtime) |
| Single point of truth | kube-apiserver is the ONLY component that reads from or writes to etcd; every other component watches the apiserver |
| etcd consistency | Raft consensus — requires a majority (quorum) of members to acknowledge a write; 3 members tolerate 1 failure, 5 members tolerate 2 |
| kube-scheduler's job | Decides WHICH node a pod runs on via filtering (eliminate impossible nodes) then scoring (rank remaining nodes) — it only decides, it doesn't execute |
| kube-controller-manager | Runs all built-in controllers as goroutines in one process, each following watch → compare → act |
| Static pods | Manifests kubelet reads directly from `/etc/kubernetes/manifests/`, started without the apiserver — solves the control plane's bootstrap chicken-and-egg problem |
| kubelet is the executor | Runs directly as a systemd service (not a pod); does what the scheduler decided, never rebalances or overrides scheduling decisions |
| CRI boundary | kubelet never creates containers directly — it calls the CRI API, and the runtime (containerd) does the actual work |
| kube-proxy | Implements Service networking as kernel-level rules (iptables/IPVS/nftables) on each node — a DaemonSet, so failures are node-scoped |
| Request lifecycle | `kubectl apply` → apiserver (authn → authz → admission → validation → etcd write) → Deployment controller → ReplicaSet controller → scheduler → kubelet → containerd → kube-proxy |
| Control plane down ≠ workloads down | Existing running pods keep running without any control plane component — what breaks is the cluster's ability to CHANGE state (scale, heal, schedule new pods) |
| Add-ons | CoreDNS (Deployment, cluster DNS) and metrics-server (Deployment, powers `kubectl top` and HPA) are not core control plane components but are near-universal additions |

## Quick Commands Reference

| Command | Purpose |
|---|---|
| `kubectl get pods -n kube-system` | List all control-plane static pods, CoreDNS, kube-proxy |
| `kubectl get pods -n kube-system -o wide` | Same, with node placement visible |
| `kubectl describe pod kube-apiserver-<node> -n kube-system` | View apiserver's actual startup flags |
| `kubectl describe pod kube-scheduler-<node> -n kube-system` | View scheduler's startup flags |
| `kubectl describe pod kube-controller-manager-<node> -n kube-system` | View controller-manager's startup flags |
| `kubectl get events -w` | Watch controllers react to object changes in real time |
| `kubectl get events --field-selector reason=Scheduled` | See only scheduling decisions |
| `minikube ssh --profile 3node` | SSH into the control-plane node |
| `minikube ssh -n <node> --profile 3node` | SSH into a specific worker node |
| `ls /etc/kubernetes/manifests/` | List static pod manifests on a control-plane node |
| `systemctl status kubelet` | Check kubelet's systemd service status on any node |
| `cat /var/lib/kubelet/config.yaml` | View kubelet's own configuration |
| `sudo ss -tnp \| grep 2379` | Confirm only kube-apiserver connects to etcd's port |
| `kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide` | List kube-proxy DaemonSet pods, one per node |
| `sudo iptables -t nat -L KUBE-SERVICES` | View kube-proxy's generated iptables rules on a node |

> **Note:** This demo creates no Kubernetes objects with a `kubectl`
> imperative equivalent, so the `--dry-run=client -o yaml` and
> `Imperative Quick-Create Commands` subsections are not applicable here
> (per the master's object-less exception) — they are omitted
> deliberately, not missing.

## Troubleshooting

| Symptom | Likely cause | Fix / check |
|---|---|---|
| `kubectl` commands hang or time out entirely | apiserver unreachable or etcd has lost quorum | Check `kube-apiserver-<node>` and `etcd-<node>` pod status; check etcd member count and quorum |
| New pods stuck `Pending` forever, no scheduling events | kube-scheduler down or not watching apiserver | `kubectl get pods -n kube-system \| grep scheduler`; check its logs |
| Deleted pod (managed by a Deployment) never replaced | kube-controller-manager down | `kubectl get pods -n kube-system \| grep controller-manager` |
| Static pod won't start / keeps restarting | Manifest syntax error, or referenced volume/cert missing on that node | SSH to the node, inspect `/etc/kubernetes/manifests/<component>.yaml` directly |
| `kubectl edit` on a static pod's mirror pod fails or has no effect | Mirror pods are read-only reflections — the real source is the manifest file | Edit the manifest file on the node's filesystem instead |
| Service routing broken on one node only | That node's kube-proxy pod is down or has stale rules | `kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide`; check that specific pod's logs |
| DNS resolution fails cluster-wide | CoreDNS pods down or crashlooping | `kubectl get pods -n kube-system -l k8s-app=kube-dns` (or your CoreDNS label) |

## Appendix — Anki Cards

**`01-cluster-architecture-anki.csv`:**

```
#deck:k8s-platform-labs::01-core-concepts::01-cluster-architecture
#separator:Comma
#columns:Front,Back,Tags
"What's the single most important architectural rule about etcd access in Kubernetes?","kube-apiserver is the ONLY component that reads from or writes to etcd — every other component (scheduler, controllers, kubelets) only ever talks to the apiserver, never etcd directly.","demo01,architecture,etcd,apiserver,cka-cluster-architecture"
"List the five things kube-apiserver does to every incoming request, in order.","1) Authentication (who is this?) 2) Authorization (are they allowed?) 3) Admission control (mutate/reject) 4) Validation (is the spec valid?) 5) Persistence (write to etcd), then notify watchers.","demo01,etcd,quorum,raft,cka-cluster-architecture"
"How many etcd members are needed to tolerate 2 node failures, and why?","5 members. Quorum requires a majority; with 5 members, quorum is 3 — losing 2 still leaves 3 available. The formula is floor(N/2) tolerated failures.","demo01,etcd,quorum,raft"
"What are the two phases of kube-scheduler's decision process for each unscheduled pod?","Filtering (eliminate nodes that CANNOT run the pod — insufficient resources, untolerated taints, failed required affinity) then Scoring (rank the remaining nodes and pick the best one).","demo01,scheduler,cka-workloads-scheduling,ckad-application-deployment"
"What does kube-scheduler actually DO once it picks a node for a pod — does it start the pod?","No — it only writes spec.nodeName to the Pod object via the apiserver. The kubelet on that node notices the assignment and does the actual work of starting the pod.","demo01,scheduler,kubelet,cka-workloads-scheduling,ckad-application-deployment"
"Describe the generic controller pattern that every built-in controller in kube-controller-manager follows.","WATCH current state via the apiserver, COMPARE it to desired state (the spec), ACT to reconcile any difference — repeated continuously.","demo01,controller-manager,reconcile-loop,cka-cluster-architecture"
"Why do static pods exist — what problem do they solve?","They solve Kubernetes' bootstrap chicken-and-egg problem: control plane components like kube-apiserver are themselves pods, but pods normally need a working apiserver to be scheduled. Static pods are read directly from a local manifest directory by kubelet, with no apiserver involved, breaking the circular dependency.","demo01,static-pods,cka-cluster-architecture"
"Where does kubelet look for static pod manifests, and how can you recognize a static pod in kubectl get pods?","/etc/kubernetes/manifests/ on the node's filesystem. Static pods show up as mirror pods with the node name appended as a suffix, e.g. etcd-3node.","demo01,static-pods,kubelet,cka-cluster-architecture"
"Is kubelet itself a Kubernetes pod?","No — kubelet is the one Kubernetes component that runs directly as a systemd service on the node, not as a pod. It's what starts every other pod, including the static pods that make up the control plane.","demo01,kubelet,cka-cluster-architecture"
"What is the CRI, and why does it matter that kubelet uses it instead of running containers directly?","CRI (Container Runtime Interface) is the API kubelet calls to pull images and start/stop containers — it never talks to the container runtime directly. This decouples Kubernetes from any specific runtime; containerd, CRI-O, etc. can all implement the same CRI API.","demo01,kubelet,cri,containerd,cka-cluster-architecture"
"Name the three kube-proxy modes and which is newest.","iptables (default), IPVS (faster/more scalable using Linux IPVS), and nftables (new in Kubernetes 1.31, replaces iptables). All three implement the same job: translating Service ClusterIPs to real Pod IPs.","demo01,kube-proxy,cka-services-networking,ckad-services-networking"
"Does kube-proxy proxy application-layer traffic itself?","No — kube-proxy only writes kernel-level networking rules (iptables/IPVS/nftables). The kernel actually forwards the packets; kube-proxy never touches the traffic itself.","demo01,kube-proxy,networking,cka-services-networking,ckad-services-networking"
"In the full kubectl apply request lifecycle, what's the very first thing that happens after kube-apiserver persists the new Deployment to etcd?","The Deployment controller (running inside kube-controller-manager) notices the new Deployment via its watch on the apiserver, and creates a ReplicaSet with the desired replica count.","demo01,request-lifecycle,deployment-controller,cka-cluster-architecture,ckad-application-deployment"
"In the request lifecycle, at what point does the container actually start running?","Only after: apiserver persists the object, Deployment controller creates a ReplicaSet, ReplicaSet controller creates Pod objects (unscheduled), kube-scheduler assigns a node — THEN kubelet on that node pulls the image via containerd and starts the container.","demo01,request-lifecycle,kubelet,cka-cluster-architecture,ckad-application-deployment"
"If kube-controller-manager goes down, does an already-running Deployment's existing pods get deleted?","No — pods that are already running are managed by kubelet independently and keep running. What breaks is the cluster's ability to reconcile: no new ReplicaSets, no rolling updates, no self-healing if a pod crashes.","demo01,controller-manager,failure-impact,cka-troubleshooting"
"What does CoreDNS do, and what breaks cluster-wide if it goes down versus what still works?","CoreDNS provides DNS resolution for all Services and Pods — every pod's /etc/resolv.conf points to it. If it goes down, name-based resolution fails everywhere, but pods that are already running keep running; only DNS lookups (not existing connections) are affected.","demo01,coredns,add-ons,cka-cluster-architecture"
```

## Appendix — Quiz

**`01-cluster-architecture-quiz.md`:**

````markdown
# Quiz — 01-core-concepts/01-cluster-architecture: Cluster Architecture

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. A cluster's `kubectl get nodes` and `kubectl get pods -n kube-system` commands both hang indefinitely with no response. What's the most likely root cause?**

- A) kube-scheduler is down
- B) kube-controller-manager is down
- C) kube-apiserver or etcd is down/unreachable
- D) kube-proxy is down on the control-plane node

<details>
<summary>Answer</summary>

**C** — kubectl itself can't get any response, which only happens when the apiserver (or the etcd it depends on) is unreachable.
Trap: A and B would still let kubectl commands succeed — you'd just see stuck Pending pods or missing reconciliation, not a total hang. D affects Service routing, not kubectl's ability to talk to the API at all.

</details>

---

**Q2. You create a Deployment with 3 replicas. `kubectl get pods` shows 3 Pod objects, all stuck in `Pending` with zero scheduling-related events. What's the most precise diagnosis?**

- A) kubelet is down on all nodes
- B) kube-scheduler is down or not watching the apiserver
- C) etcd has lost quorum
- D) The container image doesn't exist

<details>
<summary>Answer</summary>

**B** — the Pod objects clearly exist and are visible, which already rules out an etcd/apiserver problem; the missing piece is scheduling.
Trap: C would likely prevent reliable listing of the Pods at all; A would show pods assigned to nodes but never actually starting, not stuck unscheduled; D would show an image-pull error after scheduling, not zero events pre-scheduling.

</details>

---

**Q3. A 5-member etcd cluster has just lost 3 members simultaneously. What happens?**

- A) The cluster continues operating normally since 2 members remain
- B) Quorum is lost (a majority of 5 is 3) — no more writes are acknowledged, though existing pods keep running
- C) etcd automatically promotes remaining members to compensate
- D) Only read operations are affected; writes continue normally

<details>
<summary>Answer</summary>

**B** — with only 2 of 5 members left, there's no majority, so quorum is lost.
Trap: A and D wrongly assume 2 surviving members are enough; C invents automatic recovery behavior that doesn't happen — losing quorum requires manual/operational intervention.

</details>

---

**Q4. A static pod's manifest on a control-plane node needs to be corrected. What's the correct way to do it?**

- A) `kubectl edit pod kube-apiserver-<node> -n kube-system`
- B) `kubectl apply -f` a corrected version of the pod spec
- C) Edit the manifest file directly at `/etc/kubernetes/manifests/` on that node — kubelet picks up the change automatically
- D) Delete the pod with `kubectl delete pod` and let it recreate itself with the corrected spec

<details>
<summary>Answer</summary>

**C** — static pods are sourced from the filesystem, not the API.
Trap: A and D both treat the static pod's mirror pod as a normal apiserver-managed object — mirror pods are read-only reflections; the real source of truth is the file on disk.

</details>

---

**Q5. Pods on `3node-m02` can't reach a ClusterIP Service. Identical pods on `3node-m03` reach it fine. Which component is the most likely cause, and why is the failure node-scoped rather than cluster-wide?**

- A) CoreDNS — but this would typically be cluster-wide, not node-scoped
- B) kube-proxy on `3node-m02` — it runs as a DaemonSet with one independent instance per node
- C) The Service object itself is misconfigured
- D) kube-scheduler placed the pods incorrectly

<details>
<summary>Answer</summary>

**B** — a per-node DaemonSet failure explains a single-node-scoped symptom.
Trap: A and C both describe causes that would produce cluster-wide symptoms, which doesn't match this scenario; D confuses scheduling placement with runtime networking behavior.

</details>

---

**Q6. What's the correct order of events after `kubectl apply -f deployment.yaml` succeeds, before any container starts running?**

- A) apiserver writes to etcd → kubelet starts container → scheduler assigns node
- B) apiserver writes to etcd → Deployment controller creates ReplicaSet → ReplicaSet controller creates Pods → scheduler assigns node → kubelet starts container
- C) Deployment controller creates ReplicaSet → apiserver writes to etcd → scheduler assigns node
- D) scheduler assigns node → apiserver writes to etcd → Deployment controller creates ReplicaSet

<details>
<summary>Answer</summary>

**B** — this is the actual watch-driven chain, in order.
Trap: A skips the entire controller chain, jumping straight from the etcd write to kubelet; C and D reorder steps that must happen in a fixed sequence — the apiserver write must occur before any controller can observe the object via its watch.

</details>

---

**Q7. kube-controller-manager crashes. A Deployment already has 3 healthy running pods. One of those pods is manually deleted. What happens?**

- A) A replacement pod is created within seconds, same as normal
- B) No replacement pod is ever created until kube-controller-manager is restored
- C) kubelet on another node automatically creates a replacement
- D) The remaining 2 pods automatically absorb the missing pod's traffic and no replacement is needed

<details>
<summary>Answer</summary>

**B** — the ReplicaSet controller, which enforces replica count, isn't running.
Trap: A ignores that the reconciliation loop responsible for this is down; C misattributes ReplicaSet-controller responsibility to kubelet, which only manages pods already assigned to its own node; D confuses Service load-balancing with replica-count enforcement — unrelated mechanisms.

</details>

---

**Q8. Why does cloud-controller-manager not run in a minikube cluster,and what would it do if it did?**

- A) It's deprecated and no longer used in any Kubernetes cluster
- B) It only runs on cloud-managed clusters (EKS/GKE/AKS) to integrate with cloud-provider APIs — e.g. provisioning LoadBalancers, managing cloud VM node lifecycle, configuring VPC routes
- C) It's merged into kube-controller-manager in all clusters now
- D) minikube disables it purely for performance; it's fully functional if manually enabled

<details>
<summary>Answer</summary>

**B** — it exists specifically to bridge Kubernetes to a cloud provider's own APIs.
Trap: A is factually wrong — it's actively used on all major managed cloud clusters; C invents a merge that hasn't happened; D wrongly implies it's just switched off for speed, when the real reason is there's no cloud API for it to integrate with locally.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
````