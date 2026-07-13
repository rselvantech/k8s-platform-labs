# Demo: 01-core-concepts/02-namespaces — Namespaces

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

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

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
01-core-concepts/02-namespaces/
├── README.md                     # This file — theory + hands-on steps
├── src/
│   └── break-fix/                # Embedded-manifest convention — YAML lives inline in README
├── 02-namespaces-anki.csv        # Anki cards
└── 02-namespaces-quiz.md         # Quiz
```

---

## Recall Check — 01-cluster-architecture

Answer from memory before continuing — no peeking at Demo 01.

1. A pod is stuck `Pending` with no scheduling events at all. Which control plane component would you check first, and why?
2. You delete the entire control plane node. What happens to pods that were already running on the worker nodes, and why?
3. Why can't kube-scheduler write `spec.nodeName` directly to etcd instead of going through the apiserver?

<details>
<summary>Answers</summary>

1. kube-scheduler — it's the only component responsible for assigning `spec.nodeName`; no scheduling events means it may be down or the pod is unschedulable for a reason it hasn't logged yet.
2. They keep running — kubelet doesn't need the apiserver to keep an already-started container alive. The cluster just can't change state (no rescheduling, scaling, or healing) until the control plane is back.
3. apiserver is the only component that enforces authentication, authorization, admission control, and schema validation. Writing to etcd directly would bypass every one of those safeguards and remove the single audit trail for cluster state changes.

</details>

---

## Concepts

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

### Namespace Naming Conventions (Production Guidance)

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

## Lab Step-by-Step Guide

---

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
# Verify DNS from inside a pod, from team-b
kubectl run dns-test -n team-b --image=nicolaka/netshoot --restart=Never \
  -- sh -c "
    echo '=== Short name (resolves within team-b only) ==='
    dig +short +search nginx-svc
    echo '=== Cross-namespace (works from team-b via search-domain expansion) ==='
    dig +short +search nginx-svc.team-a
    echo '=== Full FQDN (always works, no search expansion needed) ==='
    dig +short nginx-svc.team-a.svc.cluster.local
  "

# Give the pod a moment to finish, then read its output
sleep 3
kubectl logs dns-test -n team-b
kubectl delete pod dns-test -n team-b
```

**Expected output:**
```
=== Short name (resolves within team-b only) ===
                                            ← empty: no nginx-svc in team-b, correctly fails
=== Cross-namespace (works from team-b via search-domain expansion) ===
10.101.129.194                             ← resolves: found via the svc.cluster.local search suffix
=== Full FQDN (always works, no search expansion needed) ===
10.101.129.194                             ← resolves: this is the record's real name, no search needed
```

**Observation:** the short name fails because nothing named `nginx-svc` exists in `team-b` — DNS names are scoped to the namespace they're created in. The cross-namespace form succeeds because every pod's `/etc/resolv.conf` includes a `svc.cluster.local` entry in its search list, and `nginx-svc.team-a` with that suffix appended is exactly `nginx-svc.team-a.svc.cluster.local` — the service's real DNS name.

> **Note on tooling:** this step uses `nicolaka/netshoot` with `dig +search` rather than `busybox`'s `nslookup`. Testing this specific scenario (a `resolv.conf` with more than one `search` entry) with `nslookup` on a musl-libc image like `busybox` can produce misleading empty results — musl has a documented limitation walking multi-entry DNS search lists, acknowledged by Kubernetes' own DNS maintainers. It's a test-tooling quirk, not a difference in actual Kubernetes DNS behavior, but it's worth knowing if you reach for `nslookup` in a busybox pod elsewhere in this repo and get an unexpected empty result.

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
```

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

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1

**`01-namespace-wrong-apiversion.yaml`:**
```yaml
apiVersion: apps/v1
kind: Namespace
metadata:
  name: staging
```

```bash
kubectl apply -f 01-namespace-wrong-apiversion.yaml
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `Namespace` only exists in the core `v1` API group, not `apps/v1` — that group is for Deployments, ReplicaSets, StatefulSets, and DaemonSets. The error is `error: unable to recognize "01-namespace-wrong-apiversion.yaml": no matches for kind "Namespace" in version "apps/v1"`.

**Fix:** Change `apiVersion: apps/v1` to `apiVersion: v1` and reapply.

**Cascade:** Since the namespace was never created, any later `kubectl apply -n staging` for another object fails with `namespaces "staging" not found` — a second, misleading-looking error that's actually a downstream consequence of this one.

</details>

**Cleanup:**
```bash
kubectl delete namespace staging 2>/dev/null || true
kubectl get namespace staging
# Error from server (NotFound) — confirms clean state
```

---

### Error-2

**`02-quota-zero-pods.yaml`:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: qa
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: qa-quota
  namespace: qa
spec:
  hard:
    pods: "0"
    requests.cpu: "2"
```

```bash
kubectl apply -f 02-quota-zero-pods.yaml
kubectl create deployment web --image=nginx:1.27 -n qa
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** The quota applies cleanly (it's valid YAML), but `pods: "0"` means zero pods are allowed in this namespace at all. The Deployment object gets created, but its ReplicaSet controller fails to create any Pods: `Error creating: pods "web-xxx" is forbidden: exceeded quota: qa-quota, requested: pods=1, used: pods=0, limited: pods=0`.

**Fix:** Edit the ResourceQuota's `pods` field to a realistic value (e.g. `"10"`) and reapply — existing Deployments will then create their pods automatically once the quota allows it.

**Cascade:** `kubectl get deployment web -n qa` shows `0/1` ready indefinitely with no obvious top-level error — the actual failure only surfaces in `kubectl describe deployment web -n qa` (ReplicaSet events) or `kubectl get events -n qa`, not in the Deployment's own status line. This is a common "looks stuck, not obviously broken" trap.

</details>

**Cleanup:**
```bash
kubectl delete namespace qa 2>/dev/null || true
kubectl get namespace qa
# Error from server (NotFound) — confirms clean state
```

---

### Error-3

**`03-cross-namespace-dns.yaml`:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: backend
---
apiVersion: v1
kind: Namespace
metadata:
  name: frontend
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: backend
spec:
  replicas: 1
  selector:
    matchLabels: { app: api }
  template:
    metadata:
      labels: { app: api }
    spec:
      containers:
      - name: api
        image: nginx:1.27
---
apiVersion: v1
kind: Service
metadata:
  name: api-svc
  namespace: backend
spec:
  selector: { app: api }
  ports:
  - port: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: frontend
spec:
  replicas: 1
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      containers:
      - name: web
        image: nginx:1.27
        env:
        - name: API_HOST
          value: "api-svc"          # short name — wrong namespace context
```

```bash
kubectl apply -f 03-cross-namespace-dns.yaml
kubectl exec -n frontend deploy/web -- getent hosts api-svc
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `API_HOST=api-svc` uses the short DNS form, which only resolves inside the `backend` namespace where `api-svc` actually lives. From inside `frontend`, `getent hosts api-svc` returns nothing — `api-svc` doesn't exist in `frontend`'s local resolution scope.

**Fix:** Set `API_HOST` to `api-svc.backend` (or the full FQDN `api-svc.backend.svc.cluster.local`) and roll the Deployment (`kubectl rollout restart deployment web -n frontend`).

**Cascade:** `kubectl get pods -n frontend` shows the pod as `Running` the entire time — the failure is invisible at the pod-status level. Only application-level symptoms (connection refused / DNS resolution errors in app logs, or a crash loop if the app treats a missing dependency as fatal) reveal the problem — a classic "healthy-looking but broken" scenario.

</details>

**Cleanup:**
```bash
kubectl delete namespace backend frontend 2>/dev/null || true
kubectl get namespace backend frontend
# Error from server (NotFound) — confirms clean state
```

---

## Interview Prep

**Q: A developer says "namespaces give us security isolation between teams." What's wrong with that statement?**
A: Namespaces give organizational and RBAC isolation, not network or security isolation. By default, any pod can reach any other pod across namespace boundaries — you need a NetworkPolicy for actual network isolation, and RBAC alone doesn't stop lateral movement at the network layer.

**Q: Why does `nginx-svc` resolve inside `team-a` but not from `team-b`?**
A: Kubernetes DNS names are scoped to the namespace they're created in by default — the short form only resolves within the same namespace. Crossing a namespace boundary requires at least `<service>.<namespace>`, because that's literally how the DNS record is structured (`<svc>.<ns>.svc.cluster.local`).

**Q: A namespace is stuck in `Terminating` for 20 minutes. Where do you look first?**
A: Check for resources still inside it (`kubectl get all -n <ns>`) and check the namespace's own status conditions (`kubectl describe namespace <ns>`) for a finalizer that hasn't been cleared — a stuck finalizer is the most common cause, often from a custom resource or admission webhook that never responded.

**Q: Why can two Deployments both be named "nginx" without conflict?**
A: Object names are only required to be unique within a namespace, not cluster-wide — namespaces exist specifically to give teams that kind of naming freedom without collisions.

**Q: When would you deliberately NOT split workloads into more namespaces?**
A: When the operational overhead of managing more RBAC rules, quotas, and NetworkPolicies per namespace outweighs the isolation benefit — e.g., a small team's tightly coupled services that always deploy together often don't need per-service namespaces.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Cluster Architecture, Installation & Configuration | CKA | 25% | Namespace scope, namespaced vs cluster-scoped objects |
| Services & Networking | CKA | 20% | Cross-namespace DNS resolution |
| Application Environment, Configuration & Security | CKAD | 25% | Namespace-scoped resource creation and RBAC boundary |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Forgetting `-n` and assuming `default` | Most exam tasks specify a namespace explicitly — missing `-n` silently creates the object in the wrong place, and it still "succeeds" |
| Treating ResourceQuota failures as Deployment failures | The Deployment object itself shows no error — the quota rejection only appears in ReplicaSet events, easy to miss under time pressure |
| Assuming short DNS names always work | Only true within the same namespace — exam tasks that reference a Service across namespaces require the `.namespace` suffix |
| Forgetting that `kubectl delete namespace` cascades | Deleting a namespace to "clean up one resource" deletes everything in it — costly if done to the wrong namespace under time pressure |

### Exam Task — Write it from scratch

Create a namespace called `exam-ns`, then create a Deployment named `web` in it running `nginx:1.27` with 2 replicas, then expose it as a ClusterIP Service on port 80.

Official docs: [Namespaces](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/), [kubectl expose](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#expose)

<details>
<summary>Reveal solution</summary>

```bash
kubectl create namespace exam-ns
kubectl create deployment web --image=nginx:1.27 --replicas=2 -n exam-ns
kubectl expose deployment web -n exam-ns --port=80
```

**Key fields to recall:** `metadata.namespace` (must match on every referencing object), `spec.replicas`, `spec.selector` (auto-generated by `expose`, must match the Deployment's pod labels).

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| Namespaces are organizational, not a security/network boundary | Any pod can reach any pod across namespaces by default — NetworkPolicy is required for actual isolation |
| Names are unique per namespace, not cluster-wide | Two Deployments can both be named "nginx" if they live in different namespaces |
| DNS scope follows namespace | Short service names resolve only within the same namespace; crossing namespaces requires `<service>.<namespace>` at minimum |
| Four built-in namespaces exist by default | `default`, `kube-system`, `kube-public`, `kube-node-lease` — each with a distinct purpose, never repurpose `kube-system` for workloads |
| Not everything is namespaced | Node, PersistentVolume, StorageClass, ClusterRole/ClusterRoleBinding, Namespace itself, and CRDs are cluster-scoped |
| ResourceQuota scopes to one namespace | A quota object only limits usage within the namespace it's created in — it has no cluster-wide effect |
| RBAC Roles are namespace-scoped by default | A Role/RoleBinding in one namespace grants no access elsewhere — ClusterRole/ClusterRoleBinding is required for cluster-wide permissions |
| Namespace deletion cascades completely | Deleting a namespace deletes every object inside it — there is no selective delete |
| Terminating namespaces are usually blocked by a finalizer | A stuck deletion almost always traces back to a resource or finalizer that hasn't cleared, not a generic "slow" delete |
| `kubectl config set-context --current --namespace=<ns>` changes your default | This is a client-side convenience, not a cluster-side change — it doesn't affect what any other user's kubectl sees |
| Quota failures surface at the ReplicaSet level, not the Deployment level | `kubectl get deployment` can look fine while pods silently fail to create — always check events when replicas don't match desired count |
| Namespace naming should reflect environment or team, not be overly granular | One namespace per microservice is typically too fine-grained; one giant namespace per cluster loses all the benefits namespaces provide |

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

### Generating YAML skeletons with --dry-run

`kubectl` can generate a valid YAML manifest for any object it can create imperatively,
without actually creating the object. This is one of the most important exam techniques
for CKA/CKAD — you rarely need to write YAML from scratch when you can generate a
correct skeleton and edit it.

**Syntax:**
```bash
kubectl <create-command> <args> --dry-run=client -o yaml > filename.yaml
```

**Applicable to this demo:**
```bash
kubectl create namespace team-a --dry-run=client -o yaml > namespace.yaml
kubectl create deployment nginx --image=nginx:1.27 -n team-a --dry-run=client -o yaml > deploy.yaml
kubectl expose deployment nginx -n team-a --port=80 --dry-run=client -o yaml > svc.yaml
```

**Not supported** — commands that read, describe, or operate on running objects:
`kubectl get`, `describe`, `logs`, `exec`, `delete`, `apply`, `patch`, `label`

**Exam workflow:**
1. Generate the skeleton → edit what you need to change → `kubectl apply -f file.yaml`
2. Or pipe directly: `kubectl create namespace team-a --dry-run=client -o yaml | kubectl apply -f -`

### Imperative Quick-Create Commands

Commands for creating this demo's key objects without YAML — useful under exam time pressure.
Full `--dry-run=client -o yaml` skeleton generation is shown for each (see section above).

| Object | Imperative command | Notes |
|---|---|---|
| Namespace | `kubectl create namespace NAME` | Or `kubectl create ns NAME` (alias) |
| Deployment | `kubectl create deployment NAME --image=IMG -n NS` | Add `--replicas=N` to set replica count at creation |
| Service (ClusterIP) | `kubectl expose deployment NAME --port=80 -n NS` | Selector auto-generated from the Deployment's pod labels |

---

## Appendix — Anki Cards

```csv
#deck:k8s-platform-labs::01-core-concepts::02-namespaces
#separator:Comma
#columns:Front,Back,Tags
"Do namespaces provide network isolation by default?","No — any pod can reach any pod across namespaces by default; use NetworkPolicy for actual isolation","demo02,namespaces,cka-services-networking"
"Are object names unique cluster-wide or per-namespace?","Per-namespace — two Deployments can both be named nginx if they're in different namespaces","demo02,namespaces,cka-cluster-architecture"
"What are the four built-in Kubernetes namespaces?","default, kube-system, kube-public, kube-node-lease","demo02,namespaces,cka-cluster-architecture"
"Name three cluster-scoped (non-namespaced) object types.","Node, PersistentVolume, ClusterRole/ClusterRoleBinding, Namespace itself, CustomResourceDefinition (any 3)","demo02,namespaces,cka-cluster-architecture"
"What DNS suffix must you add to reach a Service from a different namespace?","At minimum <service>.<namespace>; the full FQDN is <service>.<namespace>.svc.cluster.local","demo02,dns,namespaces,cka-services-networking"
"Are RBAC Roles namespace-scoped or cluster-scoped?","Namespace-scoped — a Role/RoleBinding in one namespace grants no access elsewhere; use ClusterRole/ClusterRoleBinding for cluster-wide permissions","demo02,rbac,namespaces,ckad-application-environment"
"What happens to all objects inside a namespace when you delete it?","They are all deleted too — namespace deletion cascades completely, there is no selective delete","demo02,namespaces,cka-cluster-architecture"
"A namespace is stuck in Terminating. What's the most likely cause?","A finalizer on one of its resources hasn't cleared — check kubectl describe namespace <ns> for Conditions","demo02,namespaces,troubleshooting,cka-troubleshooting"
"Does kubectl config set-context --current --namespace=<ns> change anything cluster-side?","No — it's a client-side kubeconfig change only; it doesn't affect what other users' kubectl commands see","demo02,namespaces,kubeconfig,cka-cluster-architecture"
"A ResourceQuota sets pods: \"0\" for a namespace. What happens when you create a Deployment there?","The Deployment object is created, but its ReplicaSet controller fails to create any Pods — the failure shows up in events, not the Deployment's own status line","demo02,resourcequota,namespaces,ckad-application-environment"
"Which Kubernetes API group does the Namespace object belong to?","The core v1 API group — not apps/v1","demo02,namespaces,cka-cluster-architecture"
"What flag shows resources across every namespace at once?","-A or --all-namespaces","demo02,namespaces,cka-cluster-architecture"
```

---

## Appendix — Quiz

````markdown
1. A pod in namespace `team-b` tries to reach a Service in `team-a` using only the short name. What happens?
   a) It resolves normally — DNS is cluster-wide
   b) It fails with NXDOMAIN — short names only resolve within the same namespace
   c) It resolves but the connection is blocked by RBAC
   d) It works only if both namespaces have the same labels

2. Which of these is a cluster-scoped (non-namespaced) object?
   a) Deployment
   b) ConfigMap
   c) ClusterRole
   d) Service

3. A ResourceQuota sets `pods: "0"` in a namespace. You then create a Deployment there. What do you see?
   a) The apply command itself fails immediately
   b) The Deployment is created but no Pods are ever created, visible in ReplicaSet events
   c) The Deployment silently redirects to the default namespace
   d) Kubernetes automatically raises the quota

4. What is required to reach a Service from a different namespace?
   a) Nothing extra — namespaces don't affect DNS
   b) At minimum `<service>.<namespace>`
   c) A NetworkPolicy explicitly allowing it
   d) The full pod IP address

5. What happens when you delete a namespace that contains 10 Pods and 3 Deployments?
   a) Only the namespace object is removed; the Pods and Deployments remain
   b) You're prompted to delete each object individually first
   c) Everything inside the namespace is deleted too — deletion cascades
   d) The Pods survive but the Deployments are deleted

6. Why can two Deployments both be named "nginx" without any conflict?
   a) Kubernetes automatically renames the second one
   b) Object names are unique per-namespace, not cluster-wide
   c) Deployment names aren't required to be unique at all
   d) They must be in the same namespace to share a name

7. A namespace has been `Terminating` for 20 minutes. What should you check first?
   a) Restart the cluster
   b) Check for a finalizer blocking deletion via `kubectl describe namespace`
   c) Delete and recreate the namespace with the same name
   d) This is always expected — no action needed

8. Does `kubectl config set-context --current --namespace=<ns>` affect other users?
   a) Yes — it changes the cluster's default namespace for everyone
   b) No — it's a local kubeconfig change only
   c) Yes, but only for users in the same RBAC group
   d) No, but it does change the default for future namespaces created

**Answers:** 1-b, 2-c, 3-b, 4-b, 5-c, 6-b, 7-b, 8-b

### Score Guide

| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next demo |
| 7/8 | Review the wrong answer, then proceed |
| 5–6/8 | Re-read the relevant Concepts section, retry the quiz |
| 4/8 or below | Re-read the full demo before proceeding |
````