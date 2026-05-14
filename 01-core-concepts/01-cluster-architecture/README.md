# Cluster Architecture — Control Plane, Worker Nodes, and Component Interactions

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
01-cluster-architecture/
└── README.md    # This file — theory + observation steps
```

---

## Kubernetes Architecture Overview

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

## Control Plane Components — Deep Dive

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
          etcd speaks to NO other component. The scheduler speaks to
          NO other component except the apiserver.
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
```

---

## Worker Node Components — Deep Dive

### kubelet

```
Role:     The node agent. The only Kubernetes component that runs
          directly as a systemd service (not as a pod).

Responsibilities:
  1. Register the node with the apiserver on startup
  2. Watch apiserver for Pods assigned to this node
  3. Pull container images (via CRI)
  4. Start/stop containers (via CRI)
  5. Run liveness/readiness probes
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
```

---

## Static Pods — How Control Plane Bootstraps

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

## Add-on Components

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

## The Full Request Lifecycle — kubectl apply

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

## Observation Steps

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
cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep -E "command|--etcd|--tls|--service"

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
systemctl status kubelet

# View kubelet configuration
cat /var/lib/kubelet/config.yaml | grep -E "staticPod|resolverConfig|clusterDNS"
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
# Only kube-apiserver PID should appear — no other process connects to etcd

exit
```

---

## Component Failure Impact Reference

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

**Key Takeaway:** Kubernetes is a distributed state machine. The desired state
lives in etcd. Every controller continuously reconciles current state toward
desired state. The apiserver is the only gateway — making the entire cluster
auditable and consistent. Nothing is magic: every pod start, every service
update, every scale event is a chain of watch → compare → act loops.