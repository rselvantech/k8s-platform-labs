# Demo: 12-rbac/01-rbac-fundamentals — RBAC and the Kubernetes Authorization Model

## Lab Overview

This is the first demo in the `12-rbac` topic group. Every previous topic group in this series (Deployments, Services, autoscaling, and so on) has assumed that whoever runs `kubectl` already has full permission to do so. In a real cluster that assumption breaks immediately — a CI pipeline, a junior engineer, or a monitoring tool should never hold the same permissions as a cluster administrator.

The tension this lab addresses: Kubernetes has no concept of "read-only user" or "deploy-only user" built into any workload object. Access control is a completely separate layer — Role-Based Access Control (RBAC) — that must be explicitly configured, or every authenticated identity gets whatever the cluster's default bindings happen to grant.

**Real-world scenario:** Your team runs a CI pipeline that needs to check the rollout status and read the logs of an `nginx` web-server Deployment after every deploy — and nothing else. Today the pipeline's credentials happen to have full cluster-admin access because nobody scoped them down. This lab builds the exact Role and RoleBinding that fixes that.

**What this lab covers:**
- The authentication → authorization → admission control request flow, and where RBAC sits in it
- Writing a `Role` with precise `PolicyRule` grants (apiGroups, resources, verbs)
- Binding a `Role` to a subject with a `RoleBinding`, scoped to one namespace
- Verifying effective permissions with `kubectl auth can-i`, including impersonation
- Diagnosing three common RBAC misconfigurations from symptoms alone

> **Scope note:** This lab covers RBAC only — the authorization layer. It does not cover Pod Security Admission, NetworkPolicy, or Secret access patterns; those are covered in `16-security` and `13-network-policy`. It also does not cover ServiceAccount-to-Role binding for workload identity — that is the primary concept of `12-rbac/05-service-accounts-rbac`. Here, the subject under test is a human/CI identity (a `User`), not a `ServiceAccount`.
>
> This lab also assumes authentication has already succeeded — establishing identity itself (client certificates, ServiceAccount tokens, OIDC, webhook token auth) is covered in `12-rbac/04-authentication-methods`. Everywhere this demo says "subject," it means an identity AuthN has already vouched for.

---

## Prerequisites

**Required Software:**
- minikube `3node` profile — control plane + 2 workers, already running from earlier topic groups
- kubectl v1.35.x (matched to cluster version)

**Verify cluster and RBAC mode before starting:**
```bash
kubectl get nodes
kubectl api-resources --api-group=rbac.authorization.k8s.io
# Both must work before proceeding
```

**Knowledge Requirements:**
- **REQUIRED:** Comfortable with `kubectl` basics, Deployments, Pods, and namespaces (covered throughout this series)
- **RECOMMENDED:** Prior exposure to Linux user/group permission concepts — RBAC's subject model (User/Group/ServiceAccount) maps loosely to that mental model, though the mechanics are different

---

## Lab Objectives

By the end of this lab, you will be able to:

1. ✅ Explain the authentication → authorization → admission control request flow and identify exactly where RBAC operates in it
2. ✅ Write a `Role` whose `PolicyRule` grants only the verbs actually needed on a specific resource — not broader
3. ✅ Bind that `Role` to a `User` subject with a `RoleBinding`, scoped to a single namespace
4. ✅ Verify effective permissions with `kubectl auth can-i`, including impersonation (`--as`) and negative-case testing
5. ✅ Diagnose and fix three common RBAC misconfigurations from symptoms alone, without being told the cause in advance

---

## Directory Structure

```
12-rbac/01-rbac-fundamentals/
├── README.md                              # this file
├── 01-rbac-fundamentals-anki.csv          # Anki flashcard deck (also embedded in Appendix)
├── 01-rbac-fundamentals-quiz.md            # standalone quiz (also embedded in Appendix)
└── src/
    ├── 01-namespace-ci.yaml                # the ci namespace used throughout this lab
    ├── 02-nginx-deployment.yaml             # the workload the CI pipeline needs to observe
    ├── 03-role-pod-log-reader.yaml           # the Role granting exactly the needed verbs
    ├── 04-rolebinding-ci-pipeline.yaml       # binds the Role to the ci-pipeline User
    └── break-fix/
        ├── 01-rolebinding-wrong-role-name.yaml
        ├── 02-role-wrong-apigroup.yaml
        └── 03-role-wildcard-overgrant.yaml
```

---

## Recall Check — [pending: last 11-auto-scaling ScaledJob demo]

> **⚠️ PENDING — placeholder, not yet populated.** This demo is not first in the series — `11-auto-scaling`'s final demo (KEDA ScaledJob, still under development as of this session) is its immediate predecessor. Per master's Recall Check source-verification rule, questions must trace to that demo's actual, finalized Key Takeaways, which don't exist yet. Once that demo is built and its Key Takeaways are locked, generate 3 scenario-based questions here (collapsible `<details>` answers, per the standard Kubernetes format), update the heading above to the real sibling folder name, and remove this notice.

---

## Concepts

### The Request Flow — Authentication → Authorization → Admission Control

**What it is:** Every request that hits the Kubernetes API server passes through three sequential gates before it is allowed to change cluster state.

```
 kubectl / client
        │
        ▼
 ┌─────────────────┐    "Who are you?"
 │ Authentication   │    Verifies identity: client cert, bearer token,
 │ (AuthN)          │    OIDC token, etc. Produces a username + group list.
 └────────┬─────────┘
          │ identity established
          ▼
 ┌─────────────────┐    "Are you allowed to do this?"
 │ Authorization    │    RBAC, ABAC, Webhook, or Node authorizer decides
 │ (AuthZ)          │    yes/no for THIS verb on THIS resource.
 └────────┬─────────┘
          │ request permitted
          ▼
 ┌─────────────────┐    "Is this request itself valid/safe?"
 │ Admission        │    Mutating + Validating webhooks, quota checks,
 │ Control          │    Pod Security Admission. Can still reject.
 └────────┬─────────┘
          │
          ▼
        etcd
```

- **Why it exists:** These are deliberately separate stages because they answer different questions. Merging "who are you" with "what can you do" would make it impossible to swap authentication mechanisms (certs today, OIDC tomorrow) without rewriting every permission rule.
- **How it works:** AuthN never looks at what resource is being requested — only at the identity. This demo starts from the assumption that AuthN has already succeeded; see the Scope note above. AuthZ never looks at request *content* — only at identity + verb + resource. Admission Control is the only stage that inspects the actual payload (e.g. "does this Pod spec violate a resource quota").
- **Where RBAC fits:** RBAC *is* one implementation of the Authorization stage. A cluster can run RBAC alongside other authorizers (Node authorizer is always present to let kubelets manage their own node's objects); if any authorizer says "allow," the request proceeds to Admission Control. Which authorizers are active, and in what order they're consulted, is controlled by the API server's `--authorization-mode` flag — for example `--authorization-mode=Node,RBAC` (a common production setting) runs the Node authorizer first, then RBAC, and admits the request the moment either one says yes; only if every configured authorizer says no is the request denied. Full comparison of RBAC against the other authorizer types — ABAC, Webhook, Node — including architecture and message flow for each: **Appendix — Authorization Methods Deep Dive**. **RBAC ≠ Admission Control:** RBAC decides whether you're allowed to *attempt* the action at all; Admission Control can still reject a permitted action for other reasons (e.g. a Pod that violates a ResourceQuota). A `403 Forbidden` means AuthZ denied you before your request content was ever evaluated.

**Foundational fact — stated explicitly:** By default, every subject is denied every action on every resource — there is no implicit allow for anything. The only way a request is ever permitted is if some Role/ClusterRole + Binding combination explicitly grants it; absent any grant at all, a subject can do nothing. RBAC is also purely additive on top of that default-deny baseline: there is no "deny" rule type. A subject's effective permissions are the union of every Role/ClusterRole granted to it through every RoleBinding/ClusterRoleBinding that targets it. You cannot write a rule that revokes a permission granted elsewhere — you can only grant less in the first place.

---

### PolicyRule Structure

**What it is:** The `rules` field inside a `Role` or `ClusterRole` — a list of `PolicyRule` objects, each specifying what can be done.

```yaml
rules:
- apiGroups: [""]                    # "" = the core API group (Pods, Services, ConfigMaps, etc.)
  resources: ["pods", "pods/log"]    # the resource types this rule applies to
  verbs: ["get", "list", "watch"]    # the actions permitted on those resources
  # resourceNames: ["specific-pod"]  # optional — restricts to named objects only
```

- **Why it exists:** This structure lets a single rule express fine-grained combinations (e.g. "read-only on pods AND their logs, nothing else") without needing one object per permission.
- **Worked example — decoding a real rule:** `apiGroups: ["apps"], resources: ["deployments"], verbs: ["get","list","watch"]` means: for any Deployment (which lives in the `apps` API group, not the core group), the subject may retrieve, list, and watch — but not create, update, patch, or delete. Attempting `kubectl scale deployment web --replicas=3` under this rule fails, because `scale` requires `patch` on `deployments` or `update`/`patch` on the `deployments/scale` subresource. This is proven live in Step 5.

**`apiGroups` — which part of the API each resource lives in.** Every Kubernetes resource belongs to exactly one API group, and RBAC rules must name it correctly or the rule silently matches nothing. The core group (Pods, Services, Namespaces, ConfigMaps, Secrets, Nodes, PersistentVolumes, ServiceAccounts, Events) is written as `""` — not `"core"`, not `"v1"` — this is the single most common first-time mistake, and exactly what Break-Fix Error-2 turns into a diagnosable symptom. Beyond the core group:

| API group | apiVersion (as written in manifests) | Example resources |
|---|---|---|
| `""` (core) | `v1` | pods, services, namespaces, configmaps, secrets, nodes, persistentvolumes, serviceaccounts, events |
| `apps` | `apps/v1` | deployments, replicasets, statefulsets, daemonsets |
| `batch` | `batch/v1` | jobs, cronjobs |
| `autoscaling` | `autoscaling/v2` (stable; `v1`/`v2beta2` also exist) | horizontalpodautoscalers |
| `networking.k8s.io` | `networking.k8s.io/v1` | ingresses, networkpolicies, ingressclasses |
| `rbac.authorization.k8s.io` | `rbac.authorization.k8s.io/v1` | roles, rolebindings, clusterroles, clusterrolebindings |
| `storage.k8s.io` | `storage.k8s.io/v1` | storageclasses, volumeattachments |
| `policy` | `policy/v1` | poddisruptionbudgets |
| `certificates.k8s.io` | `certificates.k8s.io/v1` | certificatesigningrequests (relevant to `04-authentication-methods`) |
| `apiextensions.k8s.io` | `apiextensions.k8s.io/v1` | customresourcedefinitions |
| `keda.sh`, `autoscaling.keda.sh`, etc. | version defined by the CRD itself (e.g. `keda.sh/v1alpha1`) | any CRD an operator installs gets its own group — KEDA's ScaledObject lives in `keda.sh`, for example |

**Relating `apiVersion` to `apiGroup`:** the `apiVersion` you write at the top of a manifest is `<apiGroup>/<version>` for every group except the core group, which omits the group entirely and is written as just `v1` (not `/v1`). A PolicyRule's `apiGroups` field is only ever the group portion — never the version. This is why a manifest creating a Deployment says `apiVersion: apps/v1`, but the matching PolicyRule says `apiGroups: ["apps"]` with no version anywhere in it — RBAC grants apply across every version of a resource within that group, not to one version specifically.

This list keeps growing as CRDs get installed — the authoritative source for what's actually in your cluster, right now, is `kubectl api-resources`, which lists every resource alongside its `APIGROUP` column. Filtering to one group directly: `kubectl api-resources --api-group=apps`.

**`resources` — the resource type(s), plural and lowercase**, exactly as `kubectl api-resources` lists them — the singular form silently matches nothing. Subresources use a slash, and are genuinely separate resources from their parent for RBAC purposes — granting `pods` never implies granting any of these:

| Resource kind | Subresource | Purpose |
|---|---|---|
| Pod | `log` | read container logs (`kubectl logs`) |
| Pod | `exec` | execute a command inside a container (`kubectl exec`) |
| Pod | `attach` | attach to a running container's console |
| Pod | `portforward` | forward a local port to the pod (`kubectl port-forward`) |
| Pod | `eviction` | evict the pod (used by `kubectl drain`, respects PDBs) |
| Deployment / ReplicaSet / StatefulSet | `scale` | read or update replica count via the generic Scale API — this is what HPA itself writes to |
| Node | `proxy` | proxy requests through to kubelet endpoints on the node |
| Service | `proxy` | proxy a request through to a backend pod |
| CertificateSigningRequest | `approval` | approve a pending CSR — covered hands-on in `04-authentication-methods` |

**`verbs` — the operations permitted**, each mapping to a specific HTTP method and API path underneath `kubectl`:

| Verb | Meaning | HTTP verb | API path example | kubectl example |
|---|---|---|---|---|
| `get` | retrieve one named object | `GET` | `/api/v1/namespaces/ci/pods/mypod` | `kubectl get pod mypod -n ci` |
| `list` | retrieve a collection of objects | `GET` | `/api/v1/namespaces/ci/pods` (no name) | `kubectl get pods -n ci` |
| `watch` | stream changes to an object/collection over a long-lived connection | `GET` with `?watch=true` | `/api/v1/namespaces/ci/pods?watch=true` | `kubectl get pods -n ci -w` |
| `create` | create a new object | `POST` | `/api/v1/namespaces/ci/pods` | `kubectl apply -f pod.yaml` (object doesn't exist yet) |
| `update` | replace an entire existing object | `PUT` | `/api/v1/namespaces/ci/pods/mypod` | `kubectl replace -f pod.yaml` |
| `patch` | partially modify an existing object | `PATCH` | `/api/v1/namespaces/ci/pods/mypod` | `kubectl edit`, `kubectl scale`, `kubectl set image`, and `kubectl apply` against an object that already exists |
| `delete` | remove one named object | `DELETE` | `/api/v1/namespaces/ci/pods/mypod` | `kubectl delete pod mypod -n ci` |
| `deletecollection` | remove every object of a type matching a selector | `DELETE` | `/api/v1/namespaces/ci/pods` (no name) | `kubectl delete pods --all -n ci` |

**`list` and `watch` are never implied by `get`, and this is worth being precise about since it's a genuinely common source of confusion**: `kubectl get pods` and `kubectl get pod mypod` are the *same CLI subcommand* — `get` — but they issue *different API verbs* depending on whether you name an object. Passing a name issues the `get` API verb; omitting one issues `list`. There is no separate `kubectl list pods` command — `list` is an API-level concept, not a CLI-level one, and `kubectl get` is the single CLI entry point for both. A Role granting only `get` lets `kubectl get pod mypod` succeed while `kubectl get pods` (no name) fails outright — you can prove this to yourself any time by temporarily removing `list` from a Role's `verbs` and comparing the two checks with `kubectl auth can-i`.

**`resourceNames`** — optional; when present, restricts the rule to specific named objects instead of every object of that resource type. Cannot be combined with `create` (the object doesn't exist yet, so there's no name to restrict to).

**Wildcards — `"*"` as a value in any of the three fields above:** `apiGroups: ["*"]`, `resources: ["*"]`, and `verbs: ["*"]` each independently mean "every value of this field," and they compose — the built-in `cluster-admin` ClusterRole is exactly `apiGroups: ["*"], resources: ["*"], verbs: ["*"]`, one rule granting everything on everything. Wildcards are legitimate and necessary for genuinely broad roles like `cluster-admin`, but every wildcard is also a direct violation of least-privilege the moment it's used anywhere narrower than that — a Role meant to be "read-only in one namespace" that uses `verbs: ["*"]` grants delete access nobody asked for, with nothing in `kubectl get role` warning you about the gap between intent and what was actually written. This is exactly what Break-Fix Error-3 demonstrates.

**Two more request types worth knowing exist, even though this lab's PolicyRules never reference them directly:** `kubectl exec` requires `get` on `pods` (to resolve the target pod) *and* `create` on the `pods/exec` subresource — exec is implemented as creating a new exec session, not reading one. `kubectl run` requires `create` on `pods` directly, since modern `kubectl run` always creates a bare Pod object (not a Deployment) — `kubectl create deployment` is the separate command for that.

---

### Role — Namespace-Scoped Permission Grants

**What it is:** A `Role` is a named, namespace-scoped collection of `PolicyRule`s. A `Role` only ever grants access to resources *within the namespace it is created in* — it cannot reference resources in another namespace, and it cannot grant access to genuinely cluster-scoped resources (Nodes, PersistentVolumes, Namespaces themselves).

- **Why it exists:** Most permission needs are namespace-local ("this CI pipeline only touches the `ci` namespace"). Scoping the grant object itself to a namespace means a mistake in one team's Role can never leak into another team's namespace.
- **How it works:** The Role object's own `metadata.namespace` field determines its scope — the same `rules` block, if placed in a `ClusterRole` instead, would mean something different (see below).
- **Best practice — why RoleBinding over ClusterRoleBinding when possible:** A Role + RoleBinding pair is the right default whenever access should be limited to one namespace, because it makes the blast radius of a misconfigured grant impossible to extend beyond that namespace — even a rule as broad as `resources: ["*"], verbs: ["*"]` inside a Role in `ci` cannot touch anything in `default` or `kube-system`. The same overly-broad rule in a ClusterRole bound cluster-wide would touch every namespace, including `kube-system`.

**Example:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-log-reader
  namespace: ci                       # scopes this Role to the ci namespace only
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
```

---

### Subjects — User, Group, ServiceAccount

**What it is:** A *subject* is who a binding grants permissions to. RBAC recognizes three subject kinds:
- **User** — a human or external system identity, represented as a plain string (`"alice"`, `"ci-pipeline"`). Kubernetes has no built-in User object or database — usernames come from whatever authentication method produced them (client cert CN, OIDC claim, etc.).
- **Group** — also just a string, supplied by the authenticator alongside the username. The `system:` prefix is reserved for Kubernetes' own internal groups.
- **ServiceAccount** — the one subject kind that *is* a real, first-class Kubernetes API object (`kind: ServiceAccount`), used for identifying workloads running inside the cluster rather than external humans.

**Similar-term distinction:** User ≠ ServiceAccount: a `User` is an external identity Kubernetes trusts an authenticator to vouch for and has no corresponding API object you can `kubectl get`; a `ServiceAccount` is a cluster-native object with its own lifecycle, namespace, and (via projected tokens) its own credential material that Kubernetes itself issues and can revoke.

This demo uses a `User` subject (`ci-pipeline`, via impersonation — see below) to isolate the RBAC grant mechanics from ServiceAccount mechanics. Binding a real `ServiceAccount` to a Role for an in-cluster workload is covered in full in `12-rbac/05-service-accounts-rbac`.

---

### RoleBinding — Binding a Role to a Subject

**What it is:** A `RoleBinding` connects a `Role` (the "what") to one or more subjects (the "who"), and — like the `Role` it references — is itself namespace-scoped. `subjects` is a list, not a single value: one `RoleBinding` can bind the identical Role to several Users, Groups, and ServiceAccounts at once, each getting the same grant.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-pipeline-pod-log-reader
  namespace: ci                          # must match the Role's namespace
subjects:
- kind: User
  name: ci-pipeline
  apiGroup: rbac.authorization.k8s.io
# A second (or third) subject can be added here to grant the same Role to
# more identities at once, e.g.:
# - kind: User
#   name: another-ci-pipeline
#   apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-log-reader                   # must exactly match an existing Role's metadata.name
  apiGroup: rbac.authorization.k8s.io
```

- **Why it exists:** Separating "what a role can do" (`Role`) from "who has it" (`RoleBinding`) lets the same Role be reused across many bindings and across many subjects within one binding — five different engineers can each appear in one `RoleBinding`'s `subjects` list against the identical `pod-log-reader` Role, or each get their own separate `RoleBinding`, without duplicating the rule set either way.
- **How it works:** `roleRef` is immutable once created — you cannot edit a `RoleBinding` to point at a different Role; you must delete and recreate it. This is a deliberate safety property: if `roleRef` were mutable, changing it could silently and invisibly re-grant a completely different set of permissions to every subject already bound.
- **Similar-term distinction:** `Role` ≠ `RoleBinding`: the `Role` defines the permission set; the `RoleBinding` is what actually takes effect — a `Role` that exists with no `RoleBinding` pointing at it grants nobody anything.

### Verifying Permissions — `kubectl auth can-i`

**What it is:** A client-side command that asks the API server's authorization stage directly: "would this specific request be allowed?" — without actually performing the action.

```bash
kubectl auth can-i get pods -n ci
# Checks against YOUR current identity in namespace ci

kubectl auth can-i get pods -n ci --as=ci-pipeline
# --as impersonates another User for the check — requires the impersonate
# verb on users yourself; minikube's default admin context has it

kubectl auth can-i --list -n ci --as=ci-pipeline
# Lists every verb/resource combination ci-pipeline can perform in ci
```

- **Why it exists:** Without this command, verifying a Role/RoleBinding actually works means logging in as that subject and attempting real actions — slow, and risky if the action has side effects (e.g. testing a `delete` grant by actually deleting something).
- **How it works:** `--as` triggers Kubernetes' **impersonation** feature — a separate authorization check (the `impersonate` verb) gates who is allowed to use `--as` at all. It does not change your actual identity; it tells the API server to evaluate the request *as if* the specified identity made it, then return the decision without executing anything.
- **What it does NOT do:** `can-i` reports the AuthZ-stage answer only. A `yes` from `can-i` does not guarantee the actual request will succeed — Admission Control (quotas, Pod Security Admission, validating webhooks) can still reject a request that AuthZ approved.

**`--list` with no verb/resource shows every permission a subject has, and running it for your own default (minikube admin) identity is worth doing once just to see the shape of the output:**

```bash
kubectl auth can-i --list
```
```
Resources                                       Non-Resource URLs   Resource Names   Verbs
*.*                                             []                  []               [*]
                                                [*]                 []               [*]
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
                                                [/api/*]            []               [get]
                                                [/api]              []               [get]
                                                [/healthz]          []               [get]
                                                [/livez]            []               [get]
                                                [/version]          []               [get]
```

Two things worth understanding directly from this output rather than skimming past them:

- **`*.*` under `Resources`, with `[*]` under `Verbs`, and an empty `Non-Resource URLs` column** is the wildcard grant from the earlier `cluster-admin` example made concrete — every resource, every API group, every verb. This is exactly why the default minikube identity can do anything.
- **The `Non-Resource URLs` column entries** (`/api/*`, `/healthz`, `/livez`, `/version`, etc.) are a genuinely different category from everything else in this table. RBAC doesn't only gate access to Kubernetes *objects* — it also gates access to a small number of API server *endpoints* that aren't backed by any resource at all: health checks, API discovery, version info. These are matched by literal path (with `*` as a path-prefix wildcard) rather than by `apiGroups`/`resources`/`verbs`, and a `PolicyRule` targeting them uses a `nonResourceURLs` field instead of `resources` — not used anywhere in this lab's own Role, but worth recognizing when it shows up in `can-i --list` output, since it's not a mistake or noise, it's a legitimate separate permission category. `nonResourceURLs` rules can only appear in `ClusterRole` (never `Role`), since these endpoints have no namespace to scope them to.

The same command against the scoped `ci-pipeline` identity from Step 5 shows a much smaller, expected set — three universal self-review permissions every authenticated identity gets regardless of any Role (`selfsubjectreviews`, `selfsubjectaccessreviews`, `selfsubjectrulesreviews` — these exist so any identity can always ask "what can I do," even with zero other grants), a handful of always-available non-resource discovery/health endpoints, and exactly the three resources this lab's Role actually granted:
```
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
pods/log                                        []                  []               [get list watch]
pods                                            []                  []               [get list watch]
deployments.apps                                []                  []               [get list watch]
                                                [/api/*]            []               [get]
                                                [/healthz]          []               [get]
                                                [/version]          []               [get]
```
No `*.*` wildcard row, no cluster-wide anything — this is what a properly scoped least-privilege identity's `--list` output looks like, in direct contrast to the admin identity's output above.

---

### What RBAC Does NOT Do

| What RBAC does NOT do | Why this matters |
|---|---|
| Authenticate identities | RBAC only evaluates already-authenticated identities; a broken or missing authenticator means RBAC is never even consulted |
| Encrypt data or Secrets | RBAC controls *who can read* a Secret object, not how it's stored — Secrets are base64-encoded, not encrypted, at the etcd layer unless encryption-at-rest is separately configured |
| Enforce resource limits or quotas | A Role can grant `create` on Pods with no cap on how many — that's ResourceQuota/LimitRange, a completely separate Admission Control mechanism |
| Provide deny rules | RBAC is purely additive (see the Foundational fact above) — you cannot use RBAC to explicitly block a permission granted by another binding |
| Audit or log access decisions by itself | Knowing *what happened* requires Kubernetes audit logging, a separate opt-in feature configured on the API server — RBAC only decides allow/deny in the moment |
| Restrict what a Pod can do at runtime (syscalls, privilege) | That's SecurityContext / Pod Security Admission — RBAC governs API requests, not in-container behavior |

---

## Lab Step-by-Step Guide

---

### Step 1 — Observe the Default Authorization State

Before creating anything, confirm what your current `kubectl` identity can already do — this is the baseline you're about to scope down for the `ci-pipeline` identity.

```bash
kubectl auth can-i '*' '*' -A
```
```
yes
```
```
# Observation: minikube's default context authenticates as a client
# certificate bound to the built-in cluster-admin ClusterRole via a
# ClusterRoleBinding. "yes" here means: unrestricted verbs, on every
# resource, across every namespace. This is the identity the CI pipeline
# should NOT have — the rest of this lab builds its actual scoped identity.
```

---

### Step 2 — Create the `ci` Namespace and Deploy nginx

This is the workload the CI pipeline needs to observe: rollout status and logs, nothing else.

**`src/01-namespace-ci.yaml`:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ci
```

**`src/02-nginx-deployment.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: ci
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.30.3     # Docker Official Image — pinned to the current stable line
        ports:
        - containerPort: 80
```

We use the [official nginx image](https://hub.docker.com/_/nginx) (Docker Official Image, maintained by the nginx project), pinned to `1.30.3` — the current stable release line — rather than `latest`, for reproducibility.

```bash
kubectl apply -f src/01-namespace-ci.yaml
kubectl apply -f src/02-nginx-deployment.yaml
kubectl -n ci rollout status deployment/web
```
```
Waiting for deployment "web" rollout to finish: 0 of 2 updated replicas are available...
deployment "web" successfully rolled out
```

---

### Step 3 — Write the Role

Grant exactly `get`/`list`/`watch` on Pods and their logs — nothing else, and only inside `ci`.

**`src/03-role-pod-log-reader.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-log-reader
  namespace: ci                        # ← namespace scope: this grant is invisible outside ci
rules:
- apiGroups: [""]                      # core API group — Pods and their log subresource live here
  resources: ["pods", "pods/log"]      # NOT "pod" (singular) — resource names are always plural
  verbs: ["get", "list", "watch"]      # read-only: no create/update/patch/delete
- apiGroups: ["apps"]                  # Deployments live in the "apps" group, not core
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]      # lets rollout status be checked without write access
```

| Field | Default | Controls | Most common mistake |
|---|---|---|---|
| `apiGroups` | none — must be explicit | which API group a rule's resources belong to | writing `"core"` instead of `""` for core-group resources |
| `resources` | none — must be explicit | which resource type(s) the rule covers | using the singular form (`"pod"` instead of `"pods"`) — silently matches nothing |
| `verbs` | none — must be explicit | which operations are permitted | assuming `get` implies `list`/`watch` — it does not |

```bash
kubectl apply -f src/03-role-pod-log-reader.yaml
kubectl -n ci get role pod-log-reader
```
```
NAME             CREATED AT
pod-log-reader   2026-07-08T03:32:08Z
```

The same Role can be created imperatively, without writing YAML at all — worth knowing since CKA/CKAD performance tasks are commonly done this way under time pressure:
```bash
kubectl create role pod-log-reader -n ci \
  --verb=get,list,watch \
  --resource=pods,pods/log \
  --dry-run=client -o yaml
```
This produces (almost) the same object as the YAML above — the one thing the imperative form can't express in a single invocation is *multiple separate rules with different `apiGroups`*, so the `deployments` rule (a different API group than `pods`) would need a second `kubectl create role` targeting the same Role name, or a follow-up `kubectl edit`. For a single-`apiGroups` Role, the imperative form alone is sufficient and faster.

There's no `--apigroup` flag on `kubectl create role` at all. The API group is inferred automatically from whatever you pass to `--resource`, by looking it up against the cluster's known API resources — the same mapping `kubectl api-resources` exposes. That's exactly why the imperative form can only express one `apiGroups` value per invocation: it resolves the group for you from the resource name, it never lets you state the group directly.

`kubectl -n ci describe role pod-log-reader` shows the same rules in a more exam-familiar table format than `get -o yaml`:
```bash
kubectl -n ci describe role pod-log-reader
```
```
Name:         pod-log-reader
Labels:       <none>
Annotations:  <none>
PolicyRule:
  Resources         Non-Resource URLs  Resource Names  Verbs
  ---------         -----------------  --------------  -----
  pods/log          []                 []              [get list watch]
  pods              []                 []              [get list watch]
  deployments.apps  []                 []              [get list watch]
```
```
# Observation: the Role exists, but grants nobody anything yet — no
# RoleBinding points at it. This is the "Role with no RoleBinding" trap
# named in the RoleBinding concept above. Note also that deployments
# appears as "deployments.apps" here — describe always qualifies
# non-core resources with their API group, even though the YAML just
# wrote "deployments" under apiGroups: ["apps"] separately.
```

---

### Step 4 — Bind the Role with a RoleBinding

**`src/04-rolebinding-ci-pipeline.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-pipeline-pod-log-reader
  namespace: ci                              # must match the Role's namespace — Roles and
                                              # RoleBindings must always live in the same namespace
subjects:
- kind: User
  name: ci-pipeline                          # arbitrary string — no User object exists to create
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-log-reader                       # must exactly match Step 3's Role name
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f src/04-rolebinding-ci-pipeline.yaml
kubectl -n ci get rolebindings ci-pipeline-pod-log-reader
```
```
NAME                         ROLE                  AGE
ci-pipeline-pod-log-reader   Role/pod-log-reader   38s
```

Imperatively:
```bash
kubectl create rolebinding ci-pipeline-pod-log-reader -n ci \
  --role=pod-log-reader \
  --user=ci-pipeline \
  --dry-run=client -o yaml
```
For a Group instead of a User, the equivalent flag is `--group=`; for a ServiceAccount, `--serviceaccount=<namespace>:<name>` — all three can be combined in one `kubectl create rolebinding` call to populate multiple `subjects` entries at once, matching the multi-subject capability covered in the RoleBinding concept above.

```bash
kubectl -n ci describe rolebindings ci-pipeline-pod-log-reader
```
```
Name:         ci-pipeline-pod-log-reader
Labels:       <none>
Annotations:  <none>
Role:
  Kind:  Role
  Name:  pod-log-reader
Subjects:
  Kind  Name         Namespace
  ----  ----         ---------
  User  ci-pipeline
```
```
# Observation: the Role block shows "Role/pod-log-reader" — confirming
# roleRef resolved correctly. If roleRef.name had a typo, this object
# would still create successfully (Kubernetes evaluates roleRef lazily,
# at permission-check time, not at admission) — the binding would
# simply grant nothing. Break-Fix Error-1 below confirms the creation
# part of this live; the resulting can-i denial is expected but still
# pending its own confirmation (see that section). Note the Subjects
# table's empty Namespace column for a User —
# Users have no namespace (they're not a real API object at all, per
# the Subjects concept above); that column is only ever populated for
# ServiceAccount subjects.
```

---

### Step 5 — Verify with `kubectl auth can-i`

**Positive case — the intended grant works:**
```bash
kubectl auth can-i get pods -n ci --as=ci-pipeline
```
```
yes
```

**Negative case — a verb that was never granted:**
```bash
kubectl auth can-i delete pods -n ci --as=ci-pipeline
```
```
no
```

**Negative case — proving the namespace scope:**
```bash
kubectl auth can-i get pods -n default --as=ci-pipeline
```
```
no
```
```
# Observation: identical verb and resource as the first check, only the
# namespace differs — and the answer flips. This proves the Role's
# metadata.namespace, not the RoleBinding alone, is what scopes access.
# A RoleBinding cannot widen a Role's scope beyond the namespace the
# Role itself lives in.
```

**Negative case — the worked example from Concepts, proven live:**
```bash
kubectl auth can-i patch deployments/scale -n ci --as=ci-pipeline
kubectl scale deployment web --replicas=3 -n ci --as=ci-pipeline
```
```
no
Error from server (Forbidden): deployments.apps "web" is forbidden: User "ci-pipeline" cannot patch resource "deployments/scale" in API group "apps" in the namespace "ci"
```
```
# Observation: CONFIRMED live — this output matches a captured run
# exactly, word for word. This confirms the PolicyRule Structure worked
# example directly — the Role grants get/list/watch on deployments,
# which is enough to check rollout status, but scale requires patch on
# deployments/scale (or update/patch on deployments), which was never
# granted. Read-only really does mean read-only, even for an object
# type this Role can otherwise see fine.
```

**Full effective-permission listing:**
```bash
kubectl auth can-i --list -n ci --as=ci-pipeline
```
```
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
pods/log                                        []                  []               [get list watch]
pods                                            []                  []               [get list watch]
deployments.apps                                []                  []               [get list watch]
                                                [/api/*]            []               [get]
                                                [/api]              []               [get]
                                                [/apis/*]           []               [get]
                                                [/apis]             []               [get]
                                                [/healthz]          []               [get]
                                                [/healthz]          []               [get]
                                                [/livez]            []               [get]
                                                [/livez]            []               [get]
                                                [/openapi/*]        []               [get]
                                                [/openapi]          []               [get]
                                                [/readyz]           []               [get]
                                                [/readyz]           []               [get]
                                                [/version/]         []               [get]
                                                [/version/]         []               [get]
                                                [/version]          []               [get]
                                                [/version]          []               [get]
```
```
# Observation: exactly the three resources this Role granted, the three
# universal self-review permissions every identity gets regardless of
# any Role, and a set of always-available non-resource discovery/health
# URLs — no more, no less. This is the same shape already walked through
# in the Verifying Permissions concept above, now confirmed on your own
# cluster rather than just described. Compare this against Step 1's
# admin-identity can-i --list (Concepts) and the difference is the whole
# point: a *.* wildcard row there, nothing of the sort here.
```

---

### Step 6 — Cleanup

**(a) Demo-scoped resources:** everything created in this lab — the `ci` namespace, `web` Deployment, `pod-log-reader` Role, and `ci-pipeline-pod-log-reader` RoleBinding — stays in place. The Break-Fix section below reuses this exact state as its starting point, so full teardown happens once, at the end of Break-Fix, not here.

**(b) Cluster-scoped shared components:** None were installed in this demo — nothing to optionally uninstall.

> **Stopping here without continuing to Break-Fix in this session?** Tear down manually:
> ```bash
> kubectl delete namespace ci --ignore-not-found
> ```

---

## What You Learned

- ✅ Explained the authentication → authorization → admission control request flow and identified where RBAC operates in it
- ✅ Wrote a `Role` whose `PolicyRule` grants matched exactly the verbs needed — no broader
- ✅ Bound that `Role` to a `User` subject with a namespace-scoped `RoleBinding`
- ✅ Verified effective permissions with `kubectl auth can-i`, including impersonation and negative-case testing
- ✅ Diagnosed and fixed three RBAC misconfigurations from symptoms alone

**Key Takeaway:** RBAC is a strictly additive, namespace-aware permission system layered entirely on top of authentication — it never asks who you are, only whether an already-established identity is allowed to perform a specific verb on a specific resource. Every permission traces back to exactly one `Role`/`ClusterRole` + `RoleBinding`/`ClusterRoleBinding` pair, and the moment that pair is missing, mismatched, or scoped to the wrong namespace, the request fails silently with `Forbidden` — never with a hint about which of the four objects (Role, RoleBinding, roleRef, or namespace) is wrong.

---

## Break-Fix

Three scenarios below, each demonstrating a distinct silent-failure mode: a typo that applies cleanly, a wrong API group that applies cleanly, and a wildcard overgrant that applies cleanly and even passes the checks you'd naturally think to run. Diagnose from the symptom command output alone before opening the reveal.

**Restore known-good state before starting** (skip this if you're continuing directly from Step 5 without a break):
```bash
kubectl apply -f ../01-namespace-ci.yaml
kubectl apply -f ../02-nginx-deployment.yaml
kubectl apply -f ../03-role-pod-log-reader.yaml
kubectl apply -f ../04-rolebinding-ci-pipeline.yaml
```

From here on, all commands in this section assume you're working from inside the `src/break-fix/` directory:
```bash
cd src/break-fix/
```
The `ci` namespace and its `web` Deployment, Role, and RoleBinding (from Steps 2–4) stay running throughout this section as the shared target — only the file under test changes between scenarios. Each scenario's cleanup restores the known-good Role or RoleBinding before the next scenario starts. Full teardown of `ci` happens once, at the very end of the last scenario — not between scenarios.

### Error-1 — a fresh RoleBinding, with a typo'd `roleRef`

> **Design note, worth reading before the scenario itself:** an earlier version of this scenario reused `ci-pipeline-pod-log-reader` — the same name as the RoleBinding already created in Step 4 — with a different `roleRef`. That produced a completely different, misleading error: `The RoleBinding "ci-pipeline-pod-log-reader" is invalid: roleRef: Invalid value: {...}: cannot change roleRef`. That's `roleRef` **immutability on update** (a real, separate, already-documented rule — see Concepts) firing because the object already existed under that name — it says nothing about whether a *fresh* RoleBinding validates `roleRef` against a real Role at creation time, which is the actual thing this scenario means to test. Below is the corrected version: a new name, a new subject, so this is unambiguously a **create**, not an update — and it's now been run for real (see the confirmed output below).

**`src/break-fix/01-rolebinding-wrong-role-name.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: new-hire-pod-log-reader        # a NEW name — does not collide with Step 4's RoleBinding
  namespace: ci
subjects:
- kind: User
  name: new-hire                       # a NEW subject — not ci-pipeline
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-log-raeder        # typo — the actual Role is named "pod-log-reader"
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f 01-rolebinding-wrong-role-name.yaml
kubectl -n ci describe rolebindings new-hire-pod-log-reader
```
```
rolebinding.rbac.authorization.k8s.io/new-hire-pod-log-reader created
Name:         new-hire-pod-log-reader
Labels:       <none>
Annotations:  <none>
Role:
  Kind:  Role
  Name:  pod-log-raeder
Subjects:
  Kind  Name      Namespace
  ----  ----      ---------
  User  new-hire
```
```
# Observation: CONFIRMED live — the object created successfully, and
# describe echoes the typo (pod-log-raeder) straight back with no
# rejection anywhere. This is the clean confirmation the earlier,
# collision-flawed version of this scenario couldn't produce: a fresh
# RoleBinding with a roleRef pointing at a Role that doesn't exist is
# accepted at creation time. Compare directly against the design-note
# error above — that was a rejection (updating an existing object's
# immutable field); this is a successful creation (a new object, with
# no existing-Role check at all).
```

Now confirm the practical consequence:
```bash
kubectl auth can-i get pods -n ci --as=new-hire
```
```
no
```

Does `apply` succeed, and if so, does `can-i` reveal anything about whether `roleRef` was checked against a real Role?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `roleRef.name` has a typo (`pod-log-raeder`). Kubernetes' RBAC authorization model evaluates `roleRef` lazily, at the moment a permission check actually happens — not at the moment the RoleBinding object is created. This is now confirmed directly above: the object created successfully with the typo intact, no validation error anywhere.A fresh RoleBinding with a `roleRef` pointing at a Role that doesn't exist is expected to create successfully, with the only symptom being that every `can-i` check for that subject returns `no`, identical to no RoleBinding existing at all.
```bash
kubectl -n ci get rolebinding new-hire-pod-log-reader -o jsonpath='{.roleRef.name}'
```
```
pod-log-raeder
```
```bash
kubectl -n ci get role pod-log-raeder
```
```
Error from server (NotFound): roles.rbac.authorization.k8s.io "pod-log-raeder" not found
```

**Fix:** Correct `roleRef.name` to `pod-log-reader` and reapply.

**Cascade:** Until caught, `new-hire` has zero effective permissions in `ci` even though a Role and a RoleBinding both exist and both look correct at a glance — anyone reviewing `kubectl get rolebinding` output alone, without checking `roleRef` against an actual Role, would conclude access is configured correctly. **Contrast with the design-note error above:** that was a *different* rule entirely (immutability, triggered only because the object already existed under that name) — worth keeping the two straight, since both produce "the RoleBinding didn't do what I expected," but for unrelated reasons.

</details>

**Cleanup:**
```bash
kubectl delete rolebinding new-hire-pod-log-reader -n ci --ignore-not-found
```

---

### Error-2 — Role applies cleanly but the rule matches nothing (and a second rule silently vanishes)

**`src/break-fix/02-role-wrong-apigroup.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-log-reader
  namespace: ci
rules:
- apiGroups: ["core"]           # wrong — the core group is "", not "core"
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
```

```bash
kubectl apply -f 02-role-wrong-apigroup.yaml
kubectl auth can-i get pods -n ci --as=ci-pipeline
```
```
role.rbac.authorization.k8s.io/pod-log-reader configured
no
```

The Role applied without error — "configured," not rejected, confirming a Role's `rules` **can** be freely replaced (unlike a RoleBinding's `roleRef`, which Error-1's design note showed is immutable). Why does `ci-pipeline` — which had working access before this apply — now fail the same check?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** Two separate things went wrong here, not one:
1. `apiGroups: ["core"]` is not a real group identifier — the core group's actual value is the empty string `""`. RBAC objects don't validate that a named group exists, so the Role updates without error; the rule simply never matches any real resource.
2. **This file also only has one rule.** `kubectl apply` replaces a Role's entire `rules` list with whatever the file contains — it doesn't merge rule-by-rule against what's already there. The original Role (Step 3) had a second rule granting `get`/`list`/`watch` on `deployments`; this file's `rules` list never mentions it, so applying this file doesn't just break the Pods rule — it silently deletes the Deployments rule too.
```bash
kubectl -n ci describe role pod-log-reader
```
```
Name:         pod-log-reader
Labels:       <none>
Annotations:  <none>
PolicyRule:
  Resources      Non-Resource URLs  Resource Names  Verbs
  ---------      -----------------  --------------  -----
  pods.core/log  []                 []              [get list watch]
  pods.core      []                 []              [get list watch]
```
```
# Observation: describe echoes the invalid group straight back — "pods.core"
# and "pods.core/log" — the same way it qualifies a real group like
# "deployments.apps" elsewhere in this demo. There is no group literally
# named "core"; it's a common informal spoken label for the empty-string
# core group, not a value Kubernetes recognizes.
#
# Just as importantly: notice there are only TWO rows here, not three.
# The deployments.apps row from Step 3's original Role is completely
# gone — not broken, gone — because this file's rules list never
# included it. This confirms live: kubectl apply on a Role is a full
# replace of rules, not an additive patch.
```
```bash
kubectl api-resources --api-group='' | grep pods
```
```
pods         po      v1        true         Pod
```
```
# Observation: the empty-string filter confirms Pods actually belong to
# apiGroup "", not "core".
```

**Fix:** Restoring the correct file (`03-role-pod-log-reader.yaml`) fixes both problems at once — it has the correct `apiGroups: [""]` AND both original rules, since it's the complete, correct `rules` list rather than a partial edit.

**Cascade:** This is the single most common first-time RBAC mistake (the `apiGroups` typo) compounded with a second, easy-to-miss failure mode (an incomplete `rules` list silently dropping an unrelated grant). Both are dangerous specifically because they degrade silently — a Role that "used to work" (per Step 3) can be broken by an edit that still applies successfully, with no error at any point in the pipeline until someone actually tests access, and the second problem (a vanished rule) is easy to miss entirely if you're only looking for the mistake you expected to find.

**Worth stating plainly, since it's easy to conflate the two objects:** a `Role`'s `rules` field is fully mutable — this apply succeeding and replacing all three original rules with one wrong one proves it. A `RoleBinding`'s `roleRef` field specifically is the immutable one (Error-1's design note); nothing about `RoleBinding` objects being immutable in general, and nothing about `Role` objects being immutable either — only that one field, on that one object type.

</details>

**Cleanup — restore the correct Role for the next scenario:**
```bash
kubectl apply -f ../03-role-pod-log-reader.yaml
```

---

### Error-3 — Role over-grants, but every check you'd think to run still passes


**`src/break-fix/03-role-wildcard-overgrant.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-log-reader
  namespace: ci
rules:
- apiGroups: [""]
  resources: ["*"]              # BUG: intended "pods" and "pods/log" only,
  verbs: ["get", "list", "watch"]  # but "*" silently grants every core-group
                                   # resource — configmaps, secrets, services,
                                   # everything — not just the two intended
```

```bash
kubectl apply -f 03-role-wildcard-overgrant.yaml
kubectl auth can-i get pods -n ci --as=ci-pipeline
kubectl auth can-i get pods/log -n ci --as=ci-pipeline
```
```
role.rbac.authorization.k8s.io/pod-log-reader configured
yes
yes
```

Both checks pass exactly as expected — no error, no `Forbidden` anywhere. Is this Role correctly scoped?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `resources: ["*"]` matches every resource in the rule's `apiGroups` — every core-group resource, not just `pods` and `pods/log`. The two checks above pass because the intended resources are a subset of what actually got granted; spot-checking only the resources you meant to grant will never reveal an over-grant like this.
```bash
kubectl auth can-i get pvc -n ci --as=ci-pipeline
kubectl auth can-i get service -n ci --as=ci-pipeline
```
```
yes
yes
```
```
# Observation: ci-pipeline can now read every PersistentVolumeClaim and
# Service in ci — nobody intended to grant a CI log-reading pipeline
# access to either. Only a full can-i --list audit, or reading the
# Role's YAML directly, surfaces this.
```

> **⚠️ Flagged for follow-up, not yet reconciled with other demos:** live-testing this Role also included `kubectl auth can-i get pv -n ci --as=ci-pipeline` (`persistentvolumes` — cluster-scoped, `NAMESPACED: false` per `02`'s discovery lesson). It returned `yes` (with a warning that the resource isn't namespace-scoped), even though this Role is namespace-scoped and bound via an ordinary `RoleBinding`. That's a real, live result — not something I'm asserting from documentation — and it's in tension with the "a `Role` can never reach a cluster-scoped resource, period" framing stated elsewhere in this demo and built into `04`'s entire binding-matrix teaching. I haven't changed that framing anywhere yet, and I'm not going to unilaterally rewrite `04` on the strength of one `pv` check — this needs a deliberate look (possibly: does `can-i`'s namespace-scoped warning mean the check itself is unreliable for cluster-scoped resources, independent of what the RoleBinding actually enforces at the API server?) before deciding what, if anything, changes. Flagging it here rather than either ignoring it or quietly rewriting prior content.

**Fix:** Replace `resources: ["*"]` with the explicit list: `resources: ["pods", "pods/log"]`.

**Cascade:** In a real incident, this is exactly how a "read-only logging Role" ends up able to read every PersistentVolumeClaim and Service in its namespace. Nobody testing `kubectl auth can-i get pods` would ever catch it, because that specific check genuinely returns the expected answer — the over-grant only shows up under a full permissions audit, never under spot-checking.

</details>

**Cleanup — restore the correct Role, then full teardown (end of Break-Fix):**
```bash
kubectl apply -f ../03-role-pod-log-reader.yaml
kubectl delete namespace ci --ignore-not-found
cd ../..
```

---

## Interview Prep

**Q1. A developer says "I created the Role, but the user still can't do anything." What's your first diagnostic step and why?**
Check whether a RoleBinding actually references that Role — a `Role` object existing in the cluster grants nobody anything by itself; it only takes effect once a `RoleBinding` (or `ClusterRoleBinding`, for a ClusterRole) points `roleRef` at it. Run `kubectl get rolebinding -n <namespace> -o yaml` and check every `roleRef.name` and `subjects` entry. This is the single most common RBAC support ticket, because `kubectl apply` on a RoleBinding with a typo'd `roleRef.name` succeeds with no error — the mismatch is only visible when you actually test with `kubectl auth can-i`.

**Q2. Why does Kubernetes RBAC have no explicit "deny" rule, and what does that mean operationally?**
RBAC is designed as a strictly additive system — every applicable Role/ClusterRole grant is unioned together, and there is no rule type that subtracts from that union. Operationally this means you can never "fix" an overly broad grant by adding a narrower deny rule elsewhere; the only way to reduce access is to remove or narrow the binding/role that granted it. This also means auditing RBAC requires checking *every* binding that targets a subject, not just the one you think is relevant — a forgotten broad ClusterRoleBinding from months ago still applies in full.

**Q3. Your `kubectl auth can-i list pods` returns `yes`, but the same user's `kubectl get pods` in production still fails. What are you missing?**
`can-i` only evaluates the Authorization stage. A `yes` there guarantees RBAC allows the request, but Admission Control runs afterward and can still reject it — a ResourceQuota, a validating webhook, or (for creates) Pod Security Admission can all independently block the same request. Check the actual error from `kubectl get pods` itself, not just the `can-i` result, and look for admission-related messages rather than assuming it's an RBAC gap.

**Q4. When would you use a Role + RoleBinding instead of a ClusterRole + ClusterRoleBinding, given they can express overlapping permission sets?**
Whenever the access genuinely only needs to apply within one namespace. The reasoning isn't just convention — it's blast-radius control: a Role is physically incapable of referencing resources outside its own namespace, so even a badly overbroad rule (`resources: ["*"], verbs: ["*"]`) inside a Role can never touch `kube-system` or any other namespace. The same overbroad rule in a ClusterRole bound with a ClusterRoleBinding grants that access cluster-wide, including to system namespaces. Reach for ClusterRole + ClusterRoleBinding only when the access is genuinely cluster-scoped (Nodes, PersistentVolumes) or intentionally spans every namespace.

**Q5. A RoleBinding's `roleRef` field can't be edited after creation — why would Kubernetes design it that way, and what's the practical consequence?**
If `roleRef` were mutable, changing which Role a binding points to would silently and invisibly re-grant a completely different permission set to every subject already listed in that binding — nobody reviewing the original binding creation would see the change. Making it immutable forces a delete-and-recreate, which produces an explicit audit trail (a delete event and a create event) instead of a silent patch. Practically: if you need to change what a binding grants, you `kubectl delete` the old RoleBinding and apply a new one — you cannot `kubectl edit` your way around it.

**Q6. A Role uses `resources: ["*"]` intending to grant access to two specific resources. It "works" — the two intended checks both return `yes`. Why is this still a serious problem, and how would you actually catch it?**
Wildcards compose with everything else in the rule: `resources: ["*"]` matches every resource in whatever `apiGroups` the rule lists, not just the two the author had in mind — in the core group alone, that includes Secrets, ConfigMaps, ServiceAccounts, and more. The two intended checks return correct answers precisely because they're a subset of what got granted, which is exactly why spot-checking with `kubectl auth can-i <verb> <specific-resource>` never catches this class of bug — every check you'd naturally think to run passes. The only way to catch it is a full `kubectl auth can-i --list` audit, or reviewing the Role's YAML directly rather than trusting behavioral testing of the resources you happen to be thinking about.

**Q7. `kubectl auth can-i --list` output includes rows with an empty `Resources` column and values like `/healthz` or `/version` under `Non-Resource URLs`. What are these, and why can't a namespaced `Role` grant them?**
These are non-resource URLs — API server endpoints (health checks, version info, API discovery paths) that aren't backed by any Kubernetes object at all, so they have no `apiGroups`/`resources` to match against. RBAC handles them through a separate `nonResourceURLs` field on the `PolicyRule`, matched by literal path (with `*` as a prefix wildcard) rather than by resource type. Because these endpoints have no namespace to scope them to — `/healthz` isn't "in" any namespace — `nonResourceURLs` rules can only be expressed in a cluster-scoped `ClusterRole`, never a namespaced `Role`.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Demo concept / command | CKA objective | CKAD objective | Notes |
|---|---|---|---|
| Role / RoleBinding creation | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | Both exams expect fast imperative creation via `kubectl create role` / `kubectl create rolebinding`, not just YAML authoring |
| `apiGroups`/`resources`/`verbs` syntax | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | Core group as `""` is the single most exam-tested trap in this area |
| `kubectl auth can-i` / `--as` | Troubleshooting (30%) | Application Environment, Configuration and Security (25%) | CKA leans on this for cluster-level debugging tasks; CKAD leans on it for verifying app-level permission scoping |
| Diagnosing `Forbidden` from a broken RoleBinding | Troubleshooting (30%) | — | This is a CKA-heavy skill; CKAD tasks rarely require diagnosing pre-broken RBAC, only creating correct RBAC |
| Role vs ClusterRole scope distinction | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | Both exams test whether you default to the narrowest correct scope |
| Wildcard (`*`) usage in `apiGroups`/`resources`/`verbs` | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | Exam scenarios that ask for "least privilege" are testing whether you avoid wildcards, not just whether the grant technically works |
| Non-resource URLs (`nonResourceURLs`) | Cluster Architecture, Installation & Configuration (25%) | — | Only valid in `ClusterRole`, never `Role` — a task requiring a health/version endpoint grant that specifies a `Role` is untestable as written |

### Common Exam Traps

| Scenario | What the task actually requires | Common wrong approach |
|---|---|---|
| "Grant user X read access to Pods in namespace Y" | A `Role` + `RoleBinding`, both created in namespace `Y` | Creating a `ClusterRole` + `ClusterRoleBinding` — technically works but grants access cluster-wide, over-provisioning and likely losing exam points for over-permissioning |
| Task specifies `get`, `list`, and `watch` explicitly | All three verbs must be present — `kubectl create role` with `--verb=get` alone is insufficient | Assuming `--verb=get` covers listing too, then wondering why `kubectl get pods` (a list call) fails verification |
| Task references "pods and pod logs" | Two resource entries: `pods` AND `pods/log` — they are separate resources requiring separate (or combined) rule entries | Granting only `pods`, which does not include the `/log` subresource — log access silently fails |
| Task needs rules across two different `apiGroups` (e.g. pods + deployments) | `kubectl create role` in one invocation can only express a single `apiGroups` value — either run it twice against the same Role name, or hand-edit the resulting YAML to add the second rule block | Assuming one `kubectl create role --resource=pods,deployments` call correctly splits resources across their respective apiGroups — it doesn't; both end up assumed core-group |
| Fast imperative RoleBinding creation under time pressure | `kubectl create rolebinding NAME --role=ROLE --user=USER -n NAMESPACE` | Hand-writing YAML from memory under time pressure, mistyping `roleRef` or `apiGroup` and losing time debugging a typo instead of using the imperative command |
| Verifying a grant actually works before moving on | `kubectl auth can-i <verb> <resource> --as=<user> -n <namespace>` immediately after creating the binding | Trusting that `kubectl apply` succeeding means the grant is correct — confirmed live in Break-Fix Error-1: a RoleBinding with a bad `roleRef` applies cleanly with no rejection |
| "Grant least-privilege access to X" | Explicit `resources`/`verbs` lists naming exactly what's needed | Reaching for `resources: ["*"]` or `verbs: ["*"]` because it's faster to write and "technically" satisfies the functional requirement — Break-Fix Error-3 shows why this passes casual testing while still failing the actual requirement |

### Exam Task — Write it from scratch

**Task:** Create a Role named `log-viewer` in namespace `ci` granting `get`/`list`/`watch` on `pods` and `pods/log` only, then bind it to a User named `auditor` with a RoleBinding — entirely via imperative commands, no hand-written YAML.

**Official documentation:**
- [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/) — the PolicyRule field reference, not just the overview

**What to practise:**
1. Open the docs page — navigate to the `Role` and `RoleBinding` field reference, not just the overview
2. Identify which fields are required (`apiGroups`, `resources`, `verbs`) vs optional (`resourceNames`)
3. Generate a skeleton: `kubectl create role log-viewer -n ci --verb=get,list,watch --resource=pods,pods/log --dry-run=client -o yaml > task.yaml`
4. Generate the RoleBinding skeleton: `kubectl create rolebinding log-viewer-auditor -n ci --role=log-viewer --user=auditor --dry-run=client -o yaml >> task.yaml`
5. Apply with `kubectl apply -f task.yaml` and verify with `kubectl auth can-i get pods -n ci --as=auditor`

<details>
<summary>Reference solution (open only after attempting)</summary>

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: log-viewer
  namespace: ci
rules:
- apiGroups: [""]              # core group — pods and pods/log both live here
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: log-viewer-auditor
  namespace: ci
subjects:
- kind: User
  name: auditor
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: log-viewer
  apiGroup: rbac.authorization.k8s.io
```

**Fields you must know without looking up:**
- `apiGroups: [""]` — not `["core"]"` — the single most common field-name trap in this entire demo
- `resources: ["pods", "pods/log"]` — two separate entries; `pods/log` is never implied by `pods`
- `roleRef.apiGroup` on the RoleBinding — easy to omit, but required; it's `rbac.authorization.k8s.io`, not blank

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| RBAC is additive-only | No deny rules exist; effective permissions are the union of every applicable binding — you can only reduce access by removing/narrowing a grant, never by adding an explicit denial |
| RBAC ≠ Admission Control | `kubectl auth can-i` yes only proves the Authorization stage would allow the request — quotas, webhooks, and Pod Security Admission can still reject it afterward |
| `list`/`watch` are not implied by `get` | A Role with only `get` lets you fetch one named object but breaks `kubectl get <resource>` (a list call) — all three verbs are usually needed together for normal `kubectl` usage |
| Core API group is `""`, not `"core"` | `apiGroups: ["core"]` is a silently-empty rule — it matches nothing because no group is literally named `core` |
| `roleRef` is immutable | A RoleBinding cannot be edited to point at a different Role — delete and recreate instead; this is a deliberate audit-trail design choice |
| A `Role` with no `RoleBinding` grants nothing | Creating the Role is necessary but not sufficient — always verify with `kubectl auth can-i` after binding, not just after creating the Role |
| Role scope cannot be widened by its RoleBinding | The Role's own `metadata.namespace` is the hard boundary; the RoleBinding only decides *who*, never *where* |
| `resourceNames` cannot be combined with `create` | The object doesn't exist yet at create time, so there is nothing to name-restrict against |
| Resource names in rules are always plural and lowercase | `"pod"` (singular) silently matches nothing — use `kubectl api-resources` to confirm exact names |
| Pod logs are a separate resource: `pods/log` | Granting `pods` alone does not include log access — subresources need explicit listing |
| `--as` triggers real API-server-side impersonation | It doesn't just filter client output — it requires the `impersonate` verb on your own identity and is evaluated exactly as if that identity made the request |
| Prefer Role+RoleBinding over ClusterRole+ClusterRoleBinding by default | Namespace-scoped objects physically cannot leak access into other namespaces, even with an overly broad rule — this bounds the blast radius of a mistake |
| A ServiceAccount is a real API object; a User is not | `kubectl get serviceaccounts` works; there is no `kubectl get users` — Users are supplied entirely by the authenticator, with no backing object in the cluster |
| By default, every subject is denied everything | There is no implicit allow anywhere in RBAC — a subject can act only where some Role/ClusterRole + Binding explicitly says so |
| A wildcard (`*`) in `apiGroups`/`resources`/`verbs` composes with the others | `cluster-admin` is exactly one rule with all three set to `*` — any wildcard used somewhere narrower than that is a direct least-privilege violation, with nothing in `kubectl get role` warning you about the gap |
| `Non-Resource URLs` in `can-i --list` output is a separate permission category | Health/discovery endpoints (`/healthz`, `/version`, etc.) aren't backed by any Kubernetes object — they're matched by literal path via `nonResourceURLs`, which can only appear in a `ClusterRole`, never a `Role` |
| `kubectl get` is one CLI command covering two different API verbs | Passing a name issues `get`; omitting one issues `list` — there is no separate `kubectl list` command, `list` only exists at the API level |
| A `RoleBinding`'s `subjects` field is a list | One `RoleBinding` can grant the same Role to several Users, Groups, and ServiceAccounts at once, not just one |
| `apiVersion` and `apiGroups` are related but not interchangeable | `apiVersion: apps/v1` in a manifest names group + version; `apiGroups: ["apps"]` in a PolicyRule names only the group — RBAC grants apply across every version of a resource in that group |
| Authorization mode order matters, and either authorizer saying yes is enough | The API server's `--authorization-mode` flag (e.g. `Node,RBAC`) sets which authorizers run and in what order; a request is admitted the moment any one of them says allow |

> **Demo scope:** Primary concept: Role + RoleBinding (namespace-scoped RBAC authorization). Supporting concepts: AuthN/AuthZ/Admission Control request flow (incl. `--authorization-mode` and the authorizer landscape — Appendix), PolicyRule structure (apiGroups, apiVersion relationship, resources, subresources, verbs, wildcards), Subjects, `kubectl auth can-i` (including non-resource URLs and the scale-subresource worked example), imperative command equivalents.
> Estimated completion time: 55–60 minutes (reading + hands-on + verification) — Break-Fix dropped from five scenarios to three, but Concepts and Step 5 both grew (Appendix cross-reference, apiVersion table, live scale-subresource check); still one primary concept, covered in more depth than the original estimate.
> Checkpoints: 3 natural stopping points — after Step 4 (Role + RoleBinding created, before verification), after Step 5 (verification complete, before Break-Fix — an explicit off-ramp is called out in Step 6), and after Break-Fix (before Interview Prep/Cert Tips).

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl auth can-i <verb> <resource> -n <namespace>` | Checks whether the current identity can perform an action |
| `kubectl auth can-i <verb> <resource> --as=<user> -n <namespace>` | Checks whether an impersonated identity can perform an action |
| `kubectl auth can-i --list -n <namespace> --as=<user>` | Lists every verb/resource combination a subject can perform in a namespace |
| `kubectl create role <name> --verb=<v1>,<v2> --resource=<r> -n <namespace>` | Imperatively creates a Role without writing YAML |
| `kubectl create rolebinding <name> --role=<role> --user=<user> -n <namespace>` | Imperatively creates a RoleBinding without writing YAML |
| `kubectl get role,rolebinding -n <namespace>` | Lists Roles and RoleBindings in a namespace |
| `kubectl get rolebinding <name> -n <namespace> -o jsonpath='{.roleRef.name}'` | Extracts exactly which Role a RoleBinding references |
| `kubectl api-resources --api-group=<group>` | Confirms the exact plural resource names belonging to an API group |
| `kubectl api-resources --api-group=''` | Lists core-group resources — confirms the correct `apiGroups: [""]` value |

### Generating YAML skeletons with --dry-run

`kubectl` can generate a valid YAML manifest for any object it can create imperatively, without actually creating the object. This is one of the most important exam techniques for CKA/CKAD — you rarely need to write YAML from scratch when you can generate a correct skeleton and edit it.

**Syntax:**
```bash
kubectl <create-command> <args> --dry-run=client -o yaml > filename.yaml
```

**Supported — any command that creates or modifies an object:**
```bash
# RBAC (this demo's objects)
kubectl create role NAME --verb=get,list --resource=pods --dry-run=client -o yaml
kubectl create rolebinding NAME --role=ROLE --user=USER --dry-run=client -o yaml

# Namespace and workloads used to set up this demo's scenario
kubectl create namespace NAME --dry-run=client -o yaml
kubectl create deployment NAME --image=IMG --dry-run=client -o yaml > deploy.yaml
```

**Not supported** — commands that read, describe, or operate on running objects: `kubectl get`, `describe`, `logs`, `exec`, `delete`, `apply`, `patch`, `label`

**Exam workflow:**
1. Generate the skeleton → edit what you need to change → `kubectl apply -f file.yaml`
2. Or pipe directly: `kubectl create role NAME --verb=get,list --resource=pods --dry-run=client -o yaml | kubectl apply -f -`

### Imperative Quick-Create Commands

Commands for creating this demo's key objects without YAML — useful under exam time pressure. Full `--dry-run=client -o yaml` skeleton generation is shown for each (see section above).

| Object | Imperative command | Notes |
|---|---|---|
| Namespace | `kubectl create namespace NAME` | |
| Role | `kubectl create role NAME --verb=get,list,watch --resource=pods,pods/log` | Multiple verbs: comma-separated, not repeated flags; multiple `apiGroups` need a second invocation against the same Role name |
| RoleBinding | `kubectl create rolebinding NAME --role=ROLE --user=USER` | Or `--group=GROUP` / `--serviceaccount=NS:SA` — all combinable in one call |

---

## Troubleshooting

**`Forbidden` error with no further detail:**
```bash
kubectl get pods -n ci --as=ci-pipeline
```
```
# Cause: AuthZ denied the request — no RoleBinding grants this verb/resource
#        combination to this subject in this namespace.
# Fix: kubectl auth can-i --list -n ci --as=ci-pipeline
#      Compare the listed grants against the verb/resource you attempted.
```

**RoleBinding created successfully but grants nothing:**
```bash
kubectl get rolebinding <name> -n <namespace> -o jsonpath='{.roleRef.name}'
```
```
# Cause: roleRef.name does not match any Role that actually exists in
#        this namespace — often a typo, silently accepted at creation.
# Fix: kubectl get role -n <namespace>
#      Confirm the exact Role name, correct roleRef, and reapply.
```

**A grant that worked yesterday stops working today:**
```bash
kubectl get rolebinding -n <namespace> -o yaml | grep -A3 subjects
```
```
# Cause: RBAC has no versioning or change history built in — someone may
#        have edited or deleted the RoleBinding/Role, or the Role's rules
#        were narrowed. There is no "who changed this" without cluster
#        audit logging enabled separately.
# Fix: Check kubectl get events -n <namespace>, and if audit logging is
#      configured, check the audit log for recent rbac.authorization.k8s.io
#      object changes.
```

**`error: the server doesn't have a resource type "role"`:**
```bash
kubectl api-resources --api-group=rbac.authorization.k8s.io
```
```
# Cause: RBAC is not enabled as an authorization mode on this cluster's
#        API server (rare on managed/minikube clusters, but possible on
#        custom kubeadm setups with --authorization-mode misconfigured).
# Fix: This is a cluster-level configuration issue, not a Role/RoleBinding
#      mistake — verify with your cluster administrator; not fixable from
#      the RBAC objects themselves.
```

**`can-i` says `no` but you're certain the RoleBinding is correct:**
```bash
kubectl auth can-i get pods -n ci --as=ci-pipeline
```
```
# Cause: Most often apiGroups mismatch (see Break-Fix Error-2) — the rule
#        exists but never matches because of a wrong group string.
# Fix: kubectl api-resources --api-group=<group-you-used>
#      Confirm the resource is actually listed under that exact group.
```

---

## Appendix — Authorization Methods Deep Dive

Full comparison of the four authorizer types Kubernetes supports, referenced from the Request Flow concept above. This lab uses RBAC exclusively — the other three exist to give you the full landscape, not because this demo's hands-on steps touch them.

### The `--authorization-mode` flag

The API server is configured with one or more authorizer modules via `--authorization-mode=<Mode1>,<Mode2>,...` — a comma-separated, **ordered** list. Every configured authorizer is consulted for every request; the request is admitted the moment **any one** of them returns `allow`, and denied only if **every** configured authorizer returns `no opinion` or `deny`. A common production setting is:

```
--authorization-mode=Node,RBAC
```

This runs the Node authorizer first (a narrow, purpose-built check for kubelet-originated requests), then RBAC for everything else. Order matters for efficiency (cheap, narrow checks run first) but not for correctness — the union-of-allows behavior is the same regardless of order.

### RBAC (Role-Based Access Control)

**What it is:** Grants are expressed as `Role`/`ClusterRole` + `RoleBinding`/`ClusterRoleBinding` objects, stored in etcd like any other Kubernetes resource, evaluated by the API server on every request.

**Architecture:** No separate process — the RBAC authorizer is compiled into `kube-apiserver` itself. On each request it reads the subject's identity + verb + resource, then checks it against every Role/ClusterRole bound to that subject via any Role/ClusterRoleBinding, unioning the results.

**Message flow:** `kube-apiserver` (RBAC authorizer module) → in-memory cache of Role/ClusterRole/RoleBinding/ClusterRoleBinding objects (kept current via the normal etcd watch mechanism, same as any controller) → allow/deny decision returned synchronously, no network hop.

**When to use:** The default choice for essentially everything in modern Kubernetes. Declarative, version-controllable (grants are YAML, just like everything else you already manage), and natively understands Kubernetes' own resource model.

### ABAC (Attribute-Based Access Control)

**What it is:** The authorization model Kubernetes used before RBAC matured. Policies are defined as newline-delimited JSON objects in a **static file on the API server's local disk**, matching on attributes of the request (user, group, namespace, resource, verb, readonly).

**Architecture:** The policy file is read once at `kube-apiserver` startup. There is no API object, no `kubectl get` for ABAC policies, and no way to change a policy without editing the file on disk and restarting (or `SIGHUP`-ing, on some versions) the API server.

**Message flow:** `kube-apiserver` (ABAC authorizer module) → reads the static policy file loaded at process start → allow/deny decision, same synchronous, no-network-hop shape as RBAC.

**When to use:** Essentially never, for new clusters. It's still a valid `--authorization-mode` value for backward compatibility, but the static-file model (no API objects, no dynamic updates, no audit trail of who changed what) is exactly what RBAC was built to replace. You'll mostly encounter ABAC in exam trivia or very old clusters, not in anything you'd design today.

### Webhook

**What it is:** Delegates the authorization decision to an **external HTTP(S) service** you run and maintain. The API server sends the request's attributes to your webhook; your service returns an allow/deny decision.

**Architecture:** Requires a `kubeconfig`-style file on the API server pointing at your webhook's URL and TLS credentials, configured via `--authorization-webhook-config-file`. Your webhook service implements the `SubjectAccessReview` API (`authorization.k8s.io/v1`) — it receives a `SubjectAccessReview` object as input and returns one back with `status.allowed` set.

**Message flow:** `kube-apiserver` (Webhook authorizer module) → HTTPS POST containing a `SubjectAccessReview` request body → your external service → HTTPS response containing a `SubjectAccessReview` with the decision → `kube-apiserver` uses that decision. Unlike RBAC/ABAC, this is a genuine network round-trip per request (subject to the API server's own caching of recent decisions).

**When to use:** When authorization logic needs to reach outside Kubernetes entirely — checking against a corporate LDAP/IAM system in real time, applying organization-specific policy engines (OPA/Gatekeeper can also be wired in this way), or enforcing rules that change too dynamically for RBAC's binding-object model to express cleanly. The cost is an external dependency in the authorization hot path — if your webhook service is down or slow, every request that reaches it is affected.

### Node authorizer

**What it is:** A narrow, special-purpose authorizer that grants kubelets permission to read/write only the objects related to their own node — the Pods scheduled to them, their own Node object, Services/Endpoints/ConfigMaps/Secrets referenced by those Pods.

**Architecture:** Compiled into `kube-apiserver`, always active on any cluster running `--authorization-mode=Node,...` (the standard on kubeadm, minikube, and every major managed offering). It doesn't use Role/RoleBinding objects at all — the logic is a fixed, built-in rule: "a request identified as `system:node:<nodename>` may only touch objects related to `<nodename>`."

**Message flow:** `kube-apiserver` (Node authorizer module) → checks the requesting identity's username against the `system:nodes` group and the `system:node:<name>` pattern → checks the target object against that specific node's owned Pods/objects → allow/deny, synchronous, no network hop.

**When to use:** You don't configure this directly — it exists specifically so kubelets don't need broad RBAC grants (e.g. `get` on every Secret in the cluster) just to read the Secrets mounted into pods on their own node. It's always paired with RBAC (`Node,RBAC`) so that everything *other* than kubelet-to-apiserver traffic still goes through normal RBAC evaluation.


---

## Appendix — Anki Cards

**`01-rbac-fundamentals-anki.csv`:**

```
#deck:k8s-platform-labs::12-rbac::01-rbac-fundamentals
#separator:Comma
#columns:Front,Back,Tags
"You run kubectl auth can-i get pods -n ci --as=ci-pipeline and get 'no', even though you're sure you created a RoleBinding. What's the single most likely cause?","The RoleBinding's roleRef.name doesn't match an existing Role's name (typo). kubectl apply succeeds on a RoleBinding with a bad roleRef with no error — it applies cleanly but grants nothing. Verify with kubectl get role -n ci and compare exactly.","rbac-fundamentals,rolebinding,troubleshooting,cka-cluster-architecture-installation-configuration,ckad-application-environment-configuration-security"
"A Role's rule has verbs: [""get""] only. kubectl get pods (no name) still fails for that subject even though single-Pod fetches work. Why?","list and watch are not implied by get. 'kubectl get pods' with no name performs a list call under the hood, which was never granted. All three verbs are usually needed together.","rbac-fundamentals,policyrule,verbs,cka-cluster-architecture-installation-configuration,ckad-application-environment-configuration-security"
"A Role rule uses apiGroups: [""core""] for a Pods rule, and the grant silently matches nothing. What's wrong?","The core API group's correct value is the empty string """", not the literal word ""core"". ""core"" is an informal label, not the actual apiGroup identifier — Kubernetes accepts any string in apiGroups without validating it exists.","rbac-fundamentals,policyrule,apigroups,cka-cluster-architecture-installation-configuration"
"You need a subject to read Pod logs, and you've granted resources: [""pods""] with verbs get/list/watch. Log access still fails. What's missing?","pods/log is a separate resource (a subresource) from pods. Granting access to pods does not include access to pods/log — it must be listed explicitly in the resources array.","rbac-fundamentals,policyrule,subresources,ckad-application-environment-configuration-security"
"What's the practical difference between a Role and a ClusterRole with an identical rules block?","A Role is scoped to the namespace it's created in and can never grant access outside it, even with an overly broad rule. A ClusterRole with the same rules, if bound via ClusterRoleBinding, grants that access across every namespace including kube-system.","rbac-fundamentals,role,clusterrole,cka-cluster-architecture-installation-configuration"
"Why does RBAC have no explicit deny rule type?","RBAC is designed as strictly additive — effective permissions are the union of every applicable Role/ClusterRole grant. There's no mechanism to subtract from that union; you can only reduce access by removing or narrowing the grant that created it.","rbac-fundamentals,rbac-model,cka-cluster-architecture-installation-configuration"
"You edit a RoleBinding's roleRef to point at a different Role. What happens?","Nothing changes — roleRef is immutable after creation. The API server rejects the edit. You must delete and recreate the RoleBinding to change which Role it references.","rbac-fundamentals,rolebinding,immutability,cka-cluster-architecture-installation-configuration"
"kubectl auth can-i delete pods -n ci --as=alice returns yes. Does this guarantee alice's delete request will actually succeed?","No. can-i only evaluates the Authorization stage. Admission Control (quotas, validating webhooks, Pod Security Admission) runs afterward and can still reject the request for reasons unrelated to RBAC.","rbac-fundamentals,can-i,admission-control,cka-troubleshooting,ckad-application-environment-configuration-security"
"What does the --as flag on kubectl auth can-i actually do under the hood?","It triggers Kubernetes' impersonation feature — a real API-server-side mechanism gated by the impersonate verb on your own identity. The API server evaluates the request as if the impersonated identity made it, not just as a client-side filter.","rbac-fundamentals,impersonation,can-i,cka-troubleshooting"
"A RoleBinding named ci-pipeline-pod-log-reader is created in namespace default, but the Role pod-log-reader lives in namespace ci. What happens when you apply the RoleBinding?","It fails immediately at apply time with NotFound — a RoleBinding's roleRef lookup is scoped to its own namespace, so a same-named Role in a different namespace is invisible to it, even though it exists elsewhere in the cluster.","rbac-fundamentals,rolebinding,namespace-scope,cka-cluster-architecture-installation-configuration"
"Is there a kubectl get users command in Kubernetes?","No. Users are not backed by any API object — they're supplied entirely by the authenticator (client cert CN, OIDC claim, etc.) as plain strings. ServiceAccounts, by contrast, are real API objects you can kubectl get.","rbac-fundamentals,subjects,user-vs-serviceaccount,ckad-application-environment-configuration-security"
"Can resourceNames be combined with the create verb in a PolicyRule?","No. resourceNames restricts a rule to specific named objects, but at create time the object doesn't exist yet, so there's no name to restrict against.","rbac-fundamentals,policyrule,resourcenames,cka-cluster-architecture-installation-configuration"
"What's the exam-fast way to create a RoleBinding without writing YAML?","kubectl create rolebinding NAME --role=ROLE_NAME --user=USER_NAME -n NAMESPACE","rbac-fundamentals,imperative-commands,cka-cluster-architecture-installation-configuration,ckad-application-environment-configuration-security"
"What's the exam-fast way to create a Role granting get/list/watch on pods without writing YAML?","kubectl create role NAME --verb=get,list,watch --resource=pods -n NAMESPACE","rbac-fundamentals,imperative-commands,cka-cluster-architecture-installation-configuration,ckad-application-environment-configuration-security"
"Where does RBAC sit in the AuthN → AuthZ → Admission Control request flow, and what does it never inspect?","RBAC is one implementation of the AuthZ stage — it decides yes/no for a given identity + verb + resource combination. It never inspects the actual content/payload of the request; that's Admission Control's job.","rbac-fundamentals,request-flow,cka-cluster-architecture-installation-configuration,cka-troubleshooting"
"You create a Role but never create a matching RoleBinding. What access does any subject have as a result of that Role?","None. A Role with no RoleBinding pointing at it grants nobody anything — the Role object existing is necessary but not sufficient.","rbac-fundamentals,role,rolebinding,cka-cluster-architecture-installation-configuration"
"Why is preferring Role+RoleBinding over ClusterRole+ClusterRoleBinding considered a best practice when both could technically express the same grant?","Because a Role's namespace scope physically bounds the blast radius of a mistake — even a rule as broad as resources: [""*""], verbs: [""*""] inside a Role can never touch another namespace, including kube-system. The same rule via ClusterRoleBinding applies cluster-wide.","rbac-fundamentals,best-practice,least-privilege,cka-cluster-architecture-installation-configuration"
"A rule specifies resources: [""pod""] (singular). What actually gets matched?","Nothing. Resource names in PolicyRules must be plural and lowercase, exactly as kubectl api-resources lists them — the singular form silently matches zero resources with no error.","rbac-fundamentals,policyrule,resource-naming,cka-cluster-architecture-installation-configuration"
"By default, before any Role or RoleBinding is ever created, what can a new subject do in Kubernetes?","Nothing. There is no implicit allow anywhere in RBAC — every action requires an explicit grant from some Role/ClusterRole + Binding combination. Absent any grant, the answer to every authorization check is no.","rbac-fundamentals,default-deny,rbac-model,cka-cluster-architecture-installation-configuration"
"Can a single RoleBinding grant a Role to more than one subject at once?","Yes. subjects is a list, not a single value — one RoleBinding can bind the identical Role to several Users, Groups, and ServiceAccounts simultaneously, each getting the same grant.","rbac-fundamentals,rolebinding,subjects,ckad-application-environment-configuration-security"
"What does resources: [""*""] mean in a PolicyRule, and why is it dangerous even when your specific test checks still return the expected answers?","It matches every resource in the rule's apiGroups, not just the ones you intended. Spot-checking with can-i for the resources you meant to grant will pass, since they're a subset of what got granted — the over-grant (e.g. Secrets, ConfigMaps) is invisible unless you run a full can-i --list audit or read the YAML directly.","rbac-fundamentals,wildcards,least-privilege,cka-cluster-architecture-installation-configuration"
"kubectl auth can-i --list shows rows with an empty Resources column and a path like /healthz under Non-Resource URLs. What are these, and can a namespaced Role grant them?","Non-resource URLs are API server endpoints (health checks, version info, discovery paths) not backed by any Kubernetes object, matched via a separate nonResourceURLs field by literal path. They have no namespace to scope to, so nonResourceURLs rules can only appear in a ClusterRole, never a Role.","rbac-fundamentals,non-resource-urls,clusterrole,cka-cluster-architecture-installation-configuration"
"Is there a kubectl list pods command?","No. list is an API-level verb, not a CLI-level command. kubectl get is the single CLI entry point covering both get and list — passing an object name issues the get verb, omitting one issues list.","rbac-fundamentals,verbs,kubectl-cli,cka-troubleshooting"
"What two things does kubectl exec require permission-wise, beyond just being able to see the pod exists?","get on pods (to resolve the target pod) AND create on the pods/exec subresource — exec is implemented as creating a new exec session, not reading one. Both are required; get alone is not sufficient.","rbac-fundamentals,subresources,exec,ckad-application-environment-configuration-security"
"Which apiGroup does kubectl run --image=... require create access to, and why not Deployments?","create on pods (core group). Modern kubectl run always creates a bare Pod object directly, never a Deployment — kubectl create deployment is the separate command for that.","rbac-fundamentals,verbs,run,ckad-application-environment-configuration-security"
"You need a Role granting get/list/watch on both pods (core group) and deployments (apps group). Can kubectl create role express this in one invocation?","No. A single kubectl create role call can only target one apiGroups value at a time (inferred from --resource). Two different apiGroups require either two separate kubectl create role invocations against the same Role name, or hand-editing the resulting YAML to add the second rule block.","rbac-fundamentals,imperative-commands,apigroups,cka-cluster-architecture-installation-configuration"
"kubectl -n ci describe role pod-log-reader shows 'deployments.apps' in its output, but the YAML just wrote resources: [""deployments""] under a separate apiGroups: [""apps""] entry. Why the different formatting?","kubectl describe always qualifies non-core resources with their API group in its display output (resource.group), even though the YAML expresses apiGroups and resources as separate fields. This is a display convention, not a difference in what was actually granted.","rbac-fundamentals,describe,apigroups,cka-troubleshooting"
"A manifest creating a Deployment says apiVersion: apps/v1. What does the matching PolicyRule's apiGroups field contain?","Just [""apps""] — the group portion only, never the version. RBAC grants apply across every version of a resource within that group, so the version part of apiVersion has no equivalent in a PolicyRule.","rbac-fundamentals,apiversion,apigroups,cka-cluster-architecture-installation-configuration"
"The API server is started with --authorization-mode=Node,RBAC. A request is denied by the Node authorizer but allowed by RBAC. What's the final outcome?","Allowed. Every configured authorizer is consulted, and the request is admitted the moment any one of them returns allow — it's only denied if every configured authorizer returns no opinion or deny.","rbac-fundamentals,authorization-mode,request-flow,cka-cluster-architecture-installation-configuration"
"What's the key architectural difference between the Webhook authorizer and RBAC?","RBAC evaluates entirely inside kube-apiserver against cached Role/RoleBinding objects, with no network hop. Webhook sends a SubjectAccessReview over HTTPS to an external service you run and waits for its response — a genuine per-request network round-trip.","rbac-fundamentals,webhook-authorizer,architecture,cka-cluster-architecture-installation-configuration"
"According to what RBAC does NOT do, if a Role grants unlimited create access on Pods, can that subject create 10,000 Pods with no cap?","Yes — RBAC has no concept of resource limits or quotas. A grant is unlimited in quantity unless ResourceQuota/LimitRange (a separate Admission Control mechanism) is configured to cap it.","rbac-fundamentals,rbac-limitations,quotas,cka-cluster-architecture-installation-configuration"
"Does RBAC control how a Secret is stored at the etcd layer?","No. RBAC only controls who is allowed to read a Secret object — it says nothing about storage. Secrets are base64-encoded, not encrypted, at the etcd layer unless encryption-at-rest is separately configured.","rbac-fundamentals,rbac-limitations,secrets,cka-cluster-architecture-installation-configuration"
"Can an RBAC grant restrict what a Pod is allowed to do at runtime, like which syscalls it makes?","No. RBAC governs API requests to the control plane — it has no visibility into in-container runtime behavior. That's the job of SecurityContext / Pod Security Admission.","rbac-fundamentals,rbac-limitations,securitycontext,cka-cluster-architecture-installation-configuration"
"Does RBAC itself keep a record of who was granted or denied access, over time?","No, not by itself. RBAC only decides allow/deny in the moment, with no history. Knowing what happened over time requires Kubernetes audit logging, a separate opt-in feature configured on the API server.","rbac-fundamentals,rbac-limitations,audit-logging,cka-cluster-architecture-installation-configuration"
"In the verbs table, what's the difference between update and patch, and which everyday kubectl commands map to patch rather than update?","update (PUT) replaces an entire existing object; patch (PATCH) partially modifies one. kubectl edit, kubectl scale, kubectl set image, and kubectl apply against an object that already exists all map to patch, not update.","rbac-fundamentals,verbs,patch-vs-update,cka-troubleshooting"
"What does the deletecollection verb do, and what kubectl command triggers it?","Removes every object of a type matching a selector in one call, with no specific name — kubectl delete pods --all triggers deletecollection, distinct from delete, which removes exactly one named object.","rbac-fundamentals,verbs,deletecollection,cka-cluster-architecture-installation-configuration"
"Does kubectl create role NAME --verb=get --resource=pods --dry-run=client -o yaml actually create the Role in the cluster?","No. --dry-run=client only builds and prints the object locally — it never sends a request to the API server. Nothing exists in the cluster until the output is piped or applied separately.","rbac-fundamentals,dry-run,imperative-commands,cka-cluster-architecture-installation-configuration"
"Why is ABAC rarely used in modern Kubernetes clusters, compared to RBAC?","ABAC policies live in a static JSON file readable only at API server startup — no API object, no kubectl get, no dynamic updates without a restart. RBAC's dynamic, declarative, version-controllable model has replaced it for essentially all new clusters.","rbac-fundamentals,abac,authorizer-comparison,cka-cluster-architecture-installation-configuration"
"What makes the Node authorizer different from RBAC, and why is it typically paired with RBAC rather than used alone?","Node authorizer is a fixed, built-in rule — not Role/RoleBinding-based — letting each kubelet touch only objects tied to its own node. It's paired with RBAC (--authorization-mode=Node,RBAC) so every other kind of request still goes through normal, configurable RBAC evaluation.","rbac-fundamentals,node-authorizer,authorizer-comparison,cka-cluster-architecture-installation-configuration"
```

## Appendix — Quiz

**`01-rbac-fundamentals-quiz.md`:**

````markdown
# Quiz — 12-rbac/01-rbac-fundamentals: RBAC and the Kubernetes Authorization Model

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next demo.

**Q1. You apply a RoleBinding whose `roleRef.name` has a typo pointing to a Role that doesn't exist. What happens?**

- A) The `apply` command fails immediately with a `NotFound` error
- B) The `apply` command succeeds, and the binding silently grants no permissions
- C) Kubernetes auto-corrects the typo using fuzzy matching against existing Role names
- D) The RoleBinding is created in a `Pending` state until a matching Role appears

<details>
<summary>Answer</summary>

**B** — RoleBinding creation does not validate that `roleRef` points at an existing Role. The apply succeeds cleanly; the only symptom is that `kubectl auth can-i` checks for that subject return `no`, identical to no binding existing at all.
Trap: A is wrong because this only happens when the RoleBinding's namespace doesn't contain a same-named Role at all (a different failure mode). C and D describe behaviors Kubernetes RBAC does not have — there is no fuzzy matching or pending state for RBAC objects.

</details>

---

**Q2. A Role named `pod-log-reader` exists in namespace `ci`. You create a RoleBinding referencing it, but the RoleBinding's `metadata.namespace` is set to `default`. What happens?**

- A) The RoleBinding is created successfully and grants access in `default`
- B) The RoleBinding is created but silently grants nothing, exactly like a typo'd `roleRef.name`
- C) `kubectl apply` fails immediately with a `NotFound` error, because `roleRef` lookups are scoped to the RoleBinding's own namespace
- D) Kubernetes automatically moves the RoleBinding to the `ci` namespace to match the Role

<details>
<summary>Answer</summary>

**C** — Unlike a typo'd Role name (which applies silently, per Q1), a cross-namespace reference is caught immediately at apply time, because the lookup for `roleRef` only searches the RoleBinding's own namespace — a same-named Role elsewhere is invisible to it.
Trap: B is the tempting answer because it feels consistent with Q1's "silent failure" pattern, but the two failure modes are genuinely different — same-namespace-wrong-name fails silently; wrong-namespace-correct-name fails loudly. D is not real Kubernetes behavior.

</details>

---

**Q3. A Role's only rule is `apiGroups: [""], resources: ["pods"], verbs: ["get"]`. A subject bound to this Role runs `kubectl get pods` (no Pod name). What happens?**

- A) It succeeds — `get` covers listing since you're "getting" the pods
- B) It fails — `list` is a separate verb from `get` and was never granted
- C) It succeeds only for the first Pod alphabetically
- D) It fails because `pods` must be written as `pod` (singular) for list operations

<details>
<summary>Answer</summary>

**B** — `kubectl get pods` with no specific name performs a `list` API call, which is a distinct verb from `get`. A rule granting only `get` lets you fetch one specifically-named Pod but does not cover listing.
Trap: A is the most common real-world mistake — assuming `get` is a superset of list access. D inverts the actual rule (resource names must be plural, not singular).

</details>

---

**Q4. You need to grant a subject read access to Pod logs. Your Role's rule is `apiGroups: [""], resources: ["pods"], verbs: ["get","list","watch"]`. Log access still fails. Why?**

- A) `pods/log` is a separate resource that must be explicitly listed
- B) Log access requires the `read` verb, which is missing
- C) Pod logs are only accessible via ClusterRole, never Role
- D) The rule needs `apiGroups: ["logs"]` instead of `""`

<details>
<summary>Answer</summary>

**A** — Pod logs are exposed as the `pods/log` subresource, which is a distinct entry from `pods` in the `resources` array. Granting `pods` alone does not include its subresources.
Trap: B invents a verb that doesn't exist in Kubernetes RBAC. D confuses subresource naming with apiGroup naming — logs are still in the core group (`""`), just a different resource string.

</details>

---

**Q5. Why does Kubernetes RBAC have no "deny" rule type?**

- A) Deny rules were removed in a past Kubernetes version for performance reasons
- B) RBAC is designed as strictly additive — effective permissions are the union of every applicable grant, with no mechanism to subtract from it
- C) Deny rules exist but require a separate `DenyPolicy` object not covered in this demo
- D) Namespaces implicitly deny everything not explicitly granted, making deny rules redundant

<details>
<summary>Answer</summary>

**B** — RBAC's model is purely additive by design. You cannot write a rule that revokes a permission granted by another binding — the only way to reduce access is to remove or narrow the grant itself.
Trap: C describes something that does not exist in core Kubernetes RBAC (that's closer to what NetworkPolicy or OPA/Gatekeeper provide for other concerns, not RBAC). D conflates "no binding exists" (implicit no) with an active deny rule, which is a different concept.

</details>

---

**Q6. You run `kubectl auth can-i delete pods -n ci --as=alice` and get `yes`. What does this guarantee?**

- A) Alice's actual `kubectl delete pod` command will always succeed
- B) Only that the Authorization (RBAC) stage would allow the request — Admission Control could still reject it
- C) Alice has cluster-admin access
- D) The Pod alice wants to delete does not have a finalizer blocking deletion

<details>
<summary>Answer</summary>

**B** — `can-i` only evaluates the AuthZ stage. A `yes` confirms RBAC permits the attempt, but Admission Control (quotas, validating webhooks, Pod Security Admission) evaluates independently afterward and can still reject the same request.
Trap: A is the common misconception this question targets directly. D introduces a real but unrelated Kubernetes concept (finalizers) that `can-i` has no visibility into either way.

</details>

---

**Q7. A Role's rule uses `apiGroups: ["core"]` for a Pods rule. What's the effect?**

- A) It works identically to `apiGroups: [""]` — "core" is just a human-readable alias
- B) It silently matches nothing, because the actual core group identifier is the empty string, not the literal word "core"
- C) It throws a validation error at apply time
- D) It grants access to all API groups, treating "core" as a wildcard

<details>
<summary>Answer</summary>

**B** — The core API group's real identifier is `""` (empty string). `"core"` is a common informal/spoken label for it, not a value Kubernetes recognizes. RBAC does not validate `apiGroups` values against real groups, so the rule applies cleanly but matches zero real resources.
Trap: A is the exact misconception the informal name creates. D confuses this with an actual wildcard, which would be written as `apiGroups: ["*"]`.

</details>

---

**Q8. You need to edit an existing RoleBinding so it references a different Role. What must you do?**

- A) `kubectl edit rolebinding` and change the `roleRef.name` field directly
- B) `kubectl patch` the `roleRef` field with a JSON merge patch
- C) Delete the RoleBinding and create a new one with the desired `roleRef`
- D) Use `kubectl replace --force`, which is the only command allowed to touch `roleRef`

<details>
<summary>Answer</summary>

**C** — `roleRef` is immutable after creation, by design — this forces a delete-and-recreate, which produces an explicit audit trail instead of a silent in-place change that could invisibly re-grant different permissions to existing subjects.
Trap: A and B both describe edit-style operations that the API server will reject specifically because `roleRef` is immutable. D describes real `kubectl replace --force` behavior inaccurately — it isn't a documented special case for RBAC immutability.

</details>

---

**Q9. When would granting access via a `ClusterRole` + `ClusterRoleBinding` be the correct choice instead of `Role` + `RoleBinding`?**

- A) Whenever the Role's rule list has more than 3 entries
- B) Whenever the access is genuinely cluster-scoped (e.g. Nodes) or intentionally needs to span every namespace
- C) Never — Role + RoleBinding should always be preferred for any use case
- D) Whenever the subject is a ServiceAccount rather than a User

<details>
<summary>Answer</summary>

**B** — ClusterRole + ClusterRoleBinding is correct when the resource itself is cluster-scoped (Nodes, PersistentVolumes) or when the intent is genuinely cluster-wide access. Using it purely out of convenience for a namespace-local need over-provisions and widens blast radius unnecessarily.
Trap: A introduces an irrelevant heuristic (rule count has nothing to do with scope choice). D is a distractor — ServiceAccounts can be bound via either Role+RoleBinding or ClusterRole+ClusterRoleBinding depending on the actual scope needed, not automatically the latter.

</details>

---

**Q10. What is the key structural difference between a `User` subject and a `ServiceAccount` subject in RBAC?**

- A) There is no difference — both are backed by the same underlying API object
- B) `ServiceAccount` is a real, first-class API object with its own lifecycle; `User` is just a string supplied by the authenticator with no backing object
- C) `User` subjects can only be bound via ClusterRoleBinding, never RoleBinding
- D) `ServiceAccount` subjects cannot be used with impersonation (`--as`)

<details>
<summary>Answer</summary>

**B** — A `ServiceAccount` is a genuine Kubernetes API object (`kubectl get serviceaccounts` works) with its own namespace and token lifecycle. A `User` has no corresponding object at all — it's a plain string that Kubernetes trusts the authentication layer to have already verified.
Trap: C is false — Users can be bound via RoleBinding, as this entire demo demonstrates. D is also false — ServiceAccounts can be impersonated with `--as=system:serviceaccount:<ns>:<name>`, just as Users can.

</details>

---

**Q11. A Role uses `resources: ["*"]`, intending to grant only two specific resources. `kubectl auth can-i` checks for those two resources both return `yes`, exactly as expected. Is this Role correctly scoped?**

- A) Yes — the checks that matter both pass
- B) No — `resources: ["*"]` grants every resource in the rule's `apiGroups`, and the two passing checks are just a subset of a much larger over-grant that spot-checking will never reveal
- C) Yes, as long as `verbs` is not also set to `["*"]`
- D) No — wildcards are rejected by the API server at apply time

<details>
<summary>Answer</summary>

**B** — A wildcard in `resources` matches everything in the listed `apiGroups`, not just the resources the author had in mind. Because the intended resources are a subset of what actually got granted, every check aimed at them returns the "correct" answer — the over-grant is invisible unless you audit with `can-i --list` or read the YAML directly.
Trap: A treats passing spot-checks as sufficient verification, which is exactly the trap. C wrongly assumes only one wildcard field matters. D is false — wildcards are valid RBAC syntax and apply without error.

</details>

---

**Q12. `kubectl auth can-i --list` shows a row with an empty `Resources` column and `/healthz` under `Non-Resource URLs`. Which object type can express a rule matching this?**

- A) A `Role` in any namespace
- B) A `ClusterRole` only
- C) Both `Role` and `ClusterRole` equally
- D) A `TriggerAuthentication`

<details>
<summary>Answer</summary>

**B** — `nonResourceURLs` rules match API server endpoints with no backing Kubernetes object and therefore no namespace to scope to — they can only be expressed in a cluster-scoped `ClusterRole`, never a namespaced `Role`.
Trap: A and C both wrongly assume `Role` can express this. D confuses this with an unrelated KEDA concept from a different demo.

</details>

---

**Q13. Is there a `kubectl list pods` command?**

- A) Yes, it's equivalent to `kubectl get pods`
- B) No — `list` is an API-level verb only; `kubectl get` (with no object name) is the CLI command that issues it
- C) Yes, but only for cluster-scoped resources
- D) No — Kubernetes has no `list` verb at all, only `get`

<details>
<summary>Answer</summary>

**B** — `kubectl get` is the single CLI entry point covering both the `get` and `list` API verbs — passing a name issues `get`, omitting one issues `list`. There's no separate `kubectl list` subcommand.
Trap: A implies a command that doesn't exist. C invents a scope restriction that isn't real. D is wrong — `list` is a real, distinct API verb, just not a distinct CLI command.

</details>

---

**Q14. Can one `RoleBinding` grant a Role to multiple subjects at once?**

- A) No — each RoleBinding may reference exactly one subject
- B) Yes — `subjects` is a list; one RoleBinding can bind the same Role to several Users, Groups, and ServiceAccounts simultaneously
- C) Only if all subjects are the same `kind`
- D) Only for ClusterRoleBindings, not RoleBindings

<details>
<summary>Answer</summary>

**B** — `subjects` is a list field. A single RoleBinding can include multiple Users, Groups, and ServiceAccounts together, all receiving the identical grant from the one referenced Role.
Trap: A understates what the field actually supports. C invents a same-kind restriction that doesn't exist — a RoleBinding can mix subject kinds freely. D wrongly restricts this to ClusterRoleBindings; RoleBindings support the same list structure.

</details>

---

**Q15. A manifest creating a Deployment declares `apiVersion: apps/v1`. What does the corresponding PolicyRule's `apiGroups` field contain?**

- A) `["apps/v1"]` — the full apiVersion string
- B) `["apps"]` — the group portion only, never the version
- C) `["v1"]` — the version portion only
- D) `["apps.v1"]`

<details>
<summary>Answer</summary>

**B** — `apiGroups` in a PolicyRule names only the group, never the version. RBAC grants apply across every version of a resource within that group, which is exactly why the version has no equivalent field in a PolicyRule.
Trap: A and D both smuggle the version into the group field, which the API server would reject or silently fail to match. C drops the group entirely, losing the actual identifying information.

</details>

---

**Q16. The API server runs with `--authorization-mode=Node,RBAC`. A request is denied by the Node authorizer but allowed by RBAC. What's the outcome?**

- A) Denied — the first authorizer in the list wins
- B) Allowed — any single authorizer returning allow is sufficient to admit the request
- C) The request is queued for manual review
- D) Denied — authorizers must unanimously agree to allow

<details>
<summary>Answer</summary>

**B** — Every configured authorizer is consulted; the request is admitted the moment any one of them says allow. Order affects which authorizer is checked first for efficiency, not the final outcome.
Trap: A and D both assume a stricter model (first-wins or unanimous-required) that isn't how `--authorization-mode` actually composes multiple authorizers. C describes behavior that doesn't exist in Kubernetes authorization.

</details>

---

**Q17. A Role grants `create` on `pods` with no other constraints. Can the bound subject create 10,000 Pods in that namespace?**

- A) No — RBAC caps object creation at a reasonable default
- B) Yes — RBAC has no concept of quantity limits; that requires ResourceQuota/LimitRange separately
- C) No, not without also granting `deletecollection`
- D) Only if `resourceNames` lists 10,000 names

<details>
<summary>Answer</summary>

**B** — RBAC governs whether an action is allowed at all, never how many times. Capping the count is ResourceQuota/LimitRange's job, a completely separate Admission Control mechanism.
Trap: A invents a default RBAC doesn't have. D confuses `resourceNames` (restricting to existing named objects) with a quantity limit on new creates, which `resourceNames` can't express anyway (see Q4 on `resourceNames` + `create`).

</details>

---

**Q18. Your organization needs an authorization decision that checks a live external HR/IAM system in real time for group membership. Which authorizer type is actually designed for this?**

- A) RBAC, using a `ClusterRole` that references the external system
- B) ABAC, using its static policy file
- C) Webhook, since it delegates the decision to an external HTTP(S) service per request
- D) Node authorizer, since it's the only one that supports external calls

<details>
<summary>Answer</summary>

**C** — Webhook is specifically designed to delegate authorization decisions to an external service via a `SubjectAccessReview` HTTP(S) round-trip per request. RBAC and ABAC both evaluate entirely from local, static configuration; Node authorizer is a fixed, narrow, kubelet-only rule with no external-call capability at all.
Trap: A invents a capability RBAC doesn't have — Roles reference Kubernetes resources, not external systems. D misattributes network-calling ability to the one authorizer that's explicitly local-only.

</details>

---

**Q19. You run `kubectl scale deployment web --replicas=5`. Which RBAC verb does this actually require on the subject?**

- A) `update` on `deployments`
- B) `patch` on `deployments` (or `update`/`patch` on `deployments/scale`)
- C) `create` on `deployments`
- D) `list` on `deployments`

<details>
<summary>Answer</summary>

**B** — `kubectl scale` performs a partial modification, which maps to the `patch` verb (or a `patch`/`update` grant on the `scale` subresource specifically) — not a full-object `update`, and not `create` or `list`, which are unrelated to changing an existing object's replica count.
Trap: A picks the plausible-sounding but wrong verb — `update` implies a full-object PUT replace, which `kubectl scale` doesn't perform.

</details>

---

Score guide:
| Score | Action |
|---|---|
| 19/19 | Import Anki cards, move to 02-rbac-discovery-and-verbs |
| 17–18/19 | Review the wrong answers, then proceed |
| 14–16/19 | Re-read the relevant section, retry those questions |
| Below 14/19 | Re-read the full demo and redo the walkthrough before proceeding |
````