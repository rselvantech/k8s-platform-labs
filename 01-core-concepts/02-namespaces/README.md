# Namespaces — Isolation, Scoping, and Multi-Tenancy

## Lab Overview

A namespace is a virtual cluster inside a Kubernetes cluster. Every object
you create — a Pod, a Deployment, a Service, a ConfigMap — lives inside
exactly one namespace. Namespaces are the primary tool for organising
resources, enforcing access boundaries, and separating teams or environments
within a single physical cluster.

Understanding namespaces is foundational because they affect:
- How DNS resolves service names (the namespace is in the FQDN)
- How RBAC scopes permissions (Roles are namespace-scoped)
- How ResourceQuotas limit usage (quotas apply per namespace)
- Which objects `kubectl` commands see by default

**What you'll learn:**
- What namespaces provide and what they do not provide
- The four default namespaces and their purposes
- Creating, labelling, and deleting namespaces
- How namespace scope affects objects: namespaced vs cluster-scoped
- DNS impact: service names change across namespace boundaries
- Setting a default namespace context for your kubectl session

## Prerequisites

**Required:**
- Minikube `3node` profile running
- kubectl configured for `3node`

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain what namespaces provide and their limits (not a network boundary by default)
2. ✅ List the four built-in namespaces and explain the purpose of each
3. ✅ Distinguish namespaced objects from cluster-scoped objects
4. ✅ Create, label, annotate, and delete namespaces
5. ✅ Explain how DNS FQDNs change across namespace boundaries
6. ✅ Set a default namespace in your kubeconfig context
7. ✅ Use `-n` and `--all-namespaces` flags correctly

## Directory Structure

```
02-namespaces/
└── README.md    # This file — theory + hands-on steps
```

---

## Understanding Namespaces

### What Namespaces Provide

```
1. Scoping for names:
   Two teams can each have a Deployment named "api" if they are in
   different namespaces. Names are unique within a namespace, not
   across the cluster.

2. RBAC boundaries:
   A Role and RoleBinding in namespace "team-a" only grants permissions
   to resources in "team-a". A developer in "team-a" cannot see or
   modify resources in "team-b" unless explicitly granted.

3. ResourceQuota enforcement:
   A ResourceQuota object in a namespace limits the total CPU, memory,
   object count, etc. that can be consumed in that namespace.

4. Default context for kubectl:
   kubectl get pods (without -n) shows pods in your current namespace.
```

### What Namespaces Do NOT Provide

```
Network isolation:
  A pod in namespace "team-a" CAN by default send traffic to a pod
  in namespace "team-b". Namespaces are NOT network firewalls.
  For network isolation → use NetworkPolicy (section 13).

Node isolation:
  Pods from different namespaces run on the same nodes unless you
  use taints/tolerations or nodeAffinity to separate them.

Secret isolation between namespace admins:
  A namespace admin who has permission to exec into pods in their
  namespace can read Secrets mounted into those pods. Namespace
  boundaries do not prevent this.
```

### The Four Built-In Namespaces

```
default:
  Where your objects go if you do not specify -n.
  Not recommended for production — creates risk of accidental
  deletion and makes resource management harder.

kube-system:
  Kubernetes internal components:
  CoreDNS, kube-proxy, kube-apiserver (mirror), etcd (mirror), etc.
  Never create application workloads here.
  Restricted by default — few users have access.

kube-public:
  Readable by all users including unauthenticated ones.
  Contains one object by default: the cluster-info ConfigMap.
  Rarely used directly.

kube-node-lease:
  Contains Lease objects — one per node.
  Each kubelet renews its Lease every 10 seconds to signal node health.
  The node controller uses these to determine node availability
  more efficiently than the older heartbeat mechanism.
  Do not create objects here.
```

### Namespaced vs Cluster-Scoped Objects

Some Kubernetes objects belong to a namespace. Others are cluster-wide.

```
Namespaced objects (exist inside one namespace):
  Pod, Deployment, ReplicaSet, StatefulSet, DaemonSet
  Job, CronJob
  Service, Endpoints, EndpointSlice
  ConfigMap, Secret
  PersistentVolumeClaim
  ServiceAccount, Role, RoleBinding
  Ingress, NetworkPolicy
  HorizontalPodAutoscaler
  ResourceQuota, LimitRange

Cluster-scoped objects (no namespace — exist at cluster level):
  Node
  PersistentVolume          ← PVC is namespaced, PV is not
  StorageClass
  ClusterRole, ClusterRoleBinding
  Namespace                 ← namespaces cannot contain namespaces
  CustomResourceDefinition
  IngressClass
  PriorityClass
```

To check whether a resource type is namespaced:
```bash
kubectl api-resources --namespaced=true   | head -20   # namespaced
kubectl api-resources --namespaced=false  | head -20   # cluster-scoped
```

---

## Hands-On Steps

### Step 1: List existing namespaces and understand each

```bash
kubectl get namespaces
```

**Expected output:**
```
NAME              STATUS   AGE
default           Active   1h
kube-node-lease   Active   1h
kube-public       Active   1h
kube-system       Active   1h
```

```bash
# Show labels on namespaces — used by NetworkPolicy and RBAC
kubectl get namespaces --show-labels
```

```bash
# Kubernetes adds a default label since v1.21:
# kubernetes.io/metadata.name=<namespace-name>
# Used by NetworkPolicy namespaceSelector
kubectl get namespace kube-system -o yaml | grep labels -A3
```

---

### Step 2: Explore what lives in kube-system

```bash
kubectl get all -n kube-system
```

You should see: CoreDNS Deployment, kube-proxy DaemonSet, mirror pods
for apiserver/etcd/scheduler/controller-manager. This is the cluster's
infrastructure layer — never modify these unless you know what you are doing.

---

### Step 3: Create namespaces

**Imperative (fast, useful for exam):**
```bash
kubectl create namespace team-a
kubectl create namespace team-b
```

**Declarative (preferred for production):**
```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    environment: production
    team: platform
  annotations:
    contact: platform-team@example.com
    purpose: "Production workloads"
EOF
```

```bash
kubectl get namespaces
# Shows: team-a, team-b, production in addition to defaults
```

---

### Step 4: Deploy objects into specific namespaces

```bash
# Deploy nginx into team-a
kubectl create deployment nginx --image=nginx:1.27 -n team-a
kubectl create deployment nginx --image=nginx:1.27 -n team-b

# Both deployments named "nginx" coexist — different namespaces
kubectl get deployments -n team-a
kubectl get deployments -n team-b
```

```bash
# Without -n, you only see the current namespace (default)
kubectl get deployments
# No resources found in default namespace.

# -A / --all-namespaces shows everything across all namespaces
kubectl get deployments -A
# NAMESPACE   NAME    READY   UP-TO-DATE   AVAILABLE   AGE
# team-a      nginx   1/1     1            1           30s
# team-b      nginx   1/1     1            1           25s
```

---

### Step 5: Understand DNS across namespaces

Services in different namespaces get different DNS names.

```bash
# Create a service in team-a
kubectl expose deployment nginx -n team-a --port=80 --name=nginx-svc

# The DNS record for this service:
# Short form (within team-a):    nginx-svc
# Medium form:                   nginx-svc.team-a
# Full FQDN:                     nginx-svc.team-a.svc.cluster.local

# A pod in team-a can reach it as:  nginx-svc  OR  nginx-svc.team-a
# A pod in team-b MUST use:         nginx-svc.team-a  (or FQDN)
# A pod in default MUST use:        nginx-svc.team-a.svc.cluster.local
```

```bash
# Verify DNS from inside a pod
kubectl run dns-test -n team-b --image=busybox:1.36 --restart=Never -it --rm \
  -- sh -c "
    echo '=== Short name (resolves within team-b only) ==='
    nslookup nginx-svc 2>&1 | tail -3

    echo '=== Cross-namespace (works from team-b) ==='
    nslookup nginx-svc.team-a 2>&1 | tail -3

    echo '=== Full FQDN (always works) ==='
    nslookup nginx-svc.team-a.svc.cluster.local 2>&1 | tail -3
  "
```

**Expected — short name fails, cross-namespace and FQDN succeed:**
```
=== Short name (resolves within team-b only) ===
** server can't find nginx-svc: NXDOMAIN   ← no nginx-svc in team-b

=== Cross-namespace (works from team-b) ===
Name: nginx-svc.team-a.svc.cluster.local
Address: 10.96.x.x   ← resolves via the namespace in the name

=== Full FQDN (always works) ===
Name: nginx-svc.team-a.svc.cluster.local
Address: 10.96.x.x
```

**Key rule:** When crossing namespace boundaries, always use at minimum
`<service>.<namespace>`. Within the same namespace, the short name works.

---

### Step 6: Set a default namespace in your kubectl context

Tired of typing `-n team-a` on every command? Set it as the default:

```bash
# Set default namespace for current context
kubectl config set-context --current --namespace=team-a

# Now kubectl commands default to team-a
kubectl get pods         # shows pods in team-a
kubectl get deployments  # shows deployments in team-a

# Restore to default
kubectl config set-context --current --namespace=default
```

```bash
# Check current context and its default namespace
kubectl config view --minify | grep namespace
# namespace: team-a  (or default if not set)
```

---

### Step 7: Namespace resource quotas (preview)

A ResourceQuota limits what can be created in a namespace.
Full details in `06-pod-scheduling/07-resource-quota-limit-range`.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-a-quota
  namespace: team-a
spec:
  hard:
    pods: "10"                    # Max 10 pods in this namespace
    requests.cpu: "2"             # Max 2 CPU cores requested
    requests.memory: "2Gi"        # Max 2Gi memory requested
    limits.cpu: "4"
    limits.memory: "4Gi"
    count/deployments.apps: "5"   # Max 5 Deployments
EOF

# View current usage against quota
kubectl describe resourcequota team-a-quota -n team-a
```

---

### Step 8: List all objects across all namespaces

```bash
# Get all pods in every namespace
kubectl get pods -A

# Get all services in every namespace
kubectl get services -A

# Get everything (Pods, Deployments, Services, etc.) in one namespace
kubectl get all -n team-a
```

---

### Step 9: Deleting namespaces — cascading deletion

```bash
# WARNING: Deleting a namespace deletes EVERYTHING inside it
# All pods, deployments, services, configmaps, secrets — gone

kubectl delete namespace team-b
# namespace "team-b" deleted

# Verify: all team-b resources are gone
kubectl get all -n team-b
# No resources found in team-b namespace.
```

**namespace deletion is sometimes slow** — the namespace enters
`Terminating` state while all its objects are cleaned up:
```bash
kubectl get namespace team-a
# NAME     STATUS        AGE
# team-a   Terminating   5m    ← waiting for all objects inside to be deleted
```

If a namespace gets stuck in Terminating, it usually means a finalizer
on one of its resources is preventing deletion. Check:
```bash
kubectl get all -n team-a   # find the stuck resource
kubectl describe namespace team-a | grep Conditions -A10
```

---

### Step 10: Cleanup

```bash
kubectl delete namespace team-a production 2>/dev/null || true
kubectl delete deployment nginx -n default 2>/dev/null || true
```

---

## Namespace Naming Conventions (Production Guidance)

```
Environment-based:
  development, staging, production

Team-based:
  team-platform, team-payments, team-data

App-based:
  app-frontend, app-backend, app-database

Combined (recommended):
  payments-production, payments-staging, data-development

Rules:
  - Use lowercase letters, numbers, hyphens only
  - Max 63 characters
  - Must start and end with alphanumeric character
  - No underscores, no dots

Avoid: using "default" for production workloads
       One giant namespace per cluster (loses all namespace benefits)
       Overly granular namespaces (one per microservice is too many)
```

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get ns` | List namespaces (short alias: ns) |
| `kubectl create ns <n>` | Create namespace imperatively |
| `kubectl get pods -n <ns>` | Pods in specific namespace |
| `kubectl get pods -A` | Pods in ALL namespaces |
| `kubectl get all -n <ns>` | All objects in a namespace |
| `kubectl config set-context --current --namespace=<ns>` | Set default namespace |
| `kubectl api-resources --namespaced=true` | List namespaced resource types |
| `kubectl api-resources --namespaced=false` | List cluster-scoped resource types |
| `kubectl delete ns <n>` | Delete namespace (and ALL its contents) |

---

## What You Learned

In this lab, you:
- ✅ Explained what namespaces provide: name scoping, RBAC boundary, quota enforcement
- ✅ Explained what namespaces do NOT provide: network isolation (need NetworkPolicy for that)
- ✅ Listed the four built-in namespaces and the purpose of each
- ✅ Distinguished namespaced objects (Pod, Deployment, Service) from cluster-scoped (Node, PV, ClusterRole)
- ✅ Created namespaces imperatively and declaratively with labels and annotations
- ✅ Proved two Deployments named "nginx" can coexist in different namespaces
- ✅ Demonstrated DNS cross-namespace behaviour — short names only work within the same namespace
- ✅ Set a default namespace in your kubeconfig context
- ✅ Understood that namespace deletion cascades to all objects inside it

**Key Takeaway:** Namespaces are the organisational and access control boundary
for Kubernetes resources. They are NOT network firewalls — for that, you need
NetworkPolicy. Every DNS name includes the namespace, which is why service
names are portable within a namespace but require the namespace suffix when
crossing boundaries.