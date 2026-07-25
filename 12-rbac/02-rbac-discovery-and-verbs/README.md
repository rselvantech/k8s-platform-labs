# Demo: 12-rbac/02-rbac-discovery-and-verbs — Discovering the Kubernetes API Surface for RBAC

## Lab Overview

`01-rbac-fundamentals` assumed you already knew the exact `apiGroups`/`resources`/`verbs` values a Role needed. In practice you rarely do — a new CRD gets installed, someone asks for "read access to whatever KEDA installed," or a debugging Role needs `kubectl exec` and you have to reason out exactly which permission that maps to. This demo is about the discovery skill itself: how to find, for any resource in your cluster, which API group it belongs to, whether it's namespaced, which verbs it actually supports, and — the one thing the obvious tool doesn't show you — what its subresources are.

**Real-world scenario:** Your on-call rotation needs a debugging identity that can `kubectl exec` into any Pod in the `ops` namespace to investigate live issues — and nothing else. No `delete`, no `create` on the Pod itself, no log-tailing beyond what `exec` already gives you interactively. Before you can write that Role correctly, you need to know exactly which verb(s) and which resource(s) `kubectl exec` actually requires — which `01`'s Concepts section named but never tested hands-on.

**What this lab covers:**
- Reading `kubectl api-resources` output precisely: what each column means, and what it deliberately leaves out
- Filtering discovery by API group and namespace-scope
- Finding verbs-per-resource with `-o wide`, and why that list isn't RBAC's `verbs` list
- Discovering subresources — the one thing `api-resources` never shows — via the raw API
- Building and verifying an `exec`-only debugging Role, proving the two-permission requirement from `01`'s Concepts live

> **Scope note:** This lab is about discovery and the `exec`/`run` verb mechanics specifically. It does not cover writing Roles with multiple rules, `resourceNames`, or Groups — those are `12-rbac/03-advanced-policyrules-and-subjects`. It does not cover ClusterRole-scoped discovery needs (cluster-scoped resources, built-in ClusterRoles) — that's `12-rbac/04-clusterroles-clusterrolebindings`.

---

## Prerequisites

**Required Software:**
- minikube `3node` profile — control plane + 2 workers, already running from earlier topic groups
- kubectl v1.35.x (matched to cluster version)
- `jq` — used throughout this demo to filter raw API discovery output

**Verify before starting:**
```bash
kubectl get nodes
jq --version
# Both must work before proceeding
```

**Knowledge Requirements:**
- **REQUIRED:** `12-rbac/01-rbac-fundamentals` — this demo assumes you already know `Role`/`RoleBinding` mechanics, `PolicyRule` structure, and `kubectl auth can-i`; none of that is re-taught here
- **RECOMMENDED:** Comfortable reading `jq` filter expressions, since raw API output is JSON

---

## Lab Objectives

By the end of this lab, you will be able to:

1. ✅ Read `kubectl api-resources` output precisely enough to state, for any resource, its API group and whether it's namespaced
2. ✅ Use `-o wide` to find which verbs a resource supports at the API level, and explain why that list differs in purpose from a PolicyRule's `verbs`
3. ✅ Discover a resource's subresources using the raw API, when `api-resources` itself provides no subresource listing
4. ✅ Build a Role granting exactly the two permissions `kubectl exec` requires, and prove — live — that `get` on the parent resource alone is insufficient
5. ✅ Diagnose two common discovery-related RBAC misconfigurations from symptoms alone

---

## Directory Structure

```
12-rbac/02-rbac-discovery-and-verbs/
├── README.md                                  # this file
├── 02-rbac-discovery-and-verbs-anki.csv        # Anki flashcard deck (also embedded in Appendix)
├── 02-rbac-discovery-and-verbs-quiz.md          # standalone quiz (also embedded in Appendix)
└── src/
    ├── 01-namespace-ops.yaml                    # the ops namespace used throughout this lab
    ├── 02-nginx-deployment.yaml                  # the workload the on-call engineer needs to exec into
    ├── 03-role-pod-exec.yaml                     # the Role granting exactly get + pods/exec create
    ├── 04-rolebinding-oncall.yaml                 # binds the Role to the oncall-engineer User
    └── break-fix/
        ├── 01-role-missing-exec-subresource.yaml
        └── 02-role-wrong-resource-for-run.yaml
```

---

## Recall Check — 01-rbac-fundamentals

Answer from memory before continuing — no peeking at the previous demo.

1. A RoleBinding's `roleRef.name` has a typo. Does `kubectl apply` catch it?
2. What's the actual value for the core API group in a PolicyRule's `apiGroups` field?
3. Does granting `resources: ["pods"]` include access to `pods/log`?

<details>
<summary>Answers</summary>

1. No — RoleBinding creation does not validate that `roleRef` points at an existing Role. It applies cleanly; the only symptom is every `can-i` check for that subject returning `no`.
2. The empty string `""` — not `"core"`. `"core"` is an informal spoken label, not a value Kubernetes recognizes.
3. No — subresources like `pods/log` are separate resources for RBAC purposes and must be listed explicitly.

</details>

---

## Concepts

### `kubectl api-resources` — Reading the Output Precisely

**What it is:** The authoritative, live, cluster-specific inventory of every resource type the API server currently knows about — built-in resources plus every CRD any operator has installed.

```bash
kubectl api-resources
```
```
NAME                              SHORTNAMES   APIVERSION                        NAMESPACED   KIND
pods                              po           v1                                true         Pod
services                          svc          v1                                true         Service
namespaces                        ns           v1                                false        Namespace
nodes                             no           v1                                false        Node
deployments                       deploy       apps/v1                           true         Deployment
horizontalpodautoscalers          hpa          autoscaling/v2                    true         HorizontalPodAutoscaler
poddisruptionbudgets              pdb          policy/v1                         true         PodDisruptionBudget
roles                                          rbac.authorization.k8s.io/v1      true         Role
rolebindings                                   rbac.authorization.k8s.io/v1      true         RoleBinding
clusterroles                                   rbac.authorization.k8s.io/v1      false        ClusterRole
clusterrolebindings                            rbac.authorization.k8s.io/v1      false        ClusterRoleBinding
...
...
...
```

**Five columns, and what each answers:**

| Column | Answers | RBAC relevance |
|---|---|---|
| `NAME` | The plural resource name | Exactly what goes in a PolicyRule's `resources` field — this is the authoritative spelling |
| `SHORTNAMES` | Abbreviations `kubectl` also accepts (`po` for `pods`) | Not valid in a PolicyRule — `resources: ["po"]` matches nothing; `resources` always takes the full name from the `NAME` column |
| `APIVERSION` | `<group>/<version>`, or bare `<version>` for the core group | Split this at the `/` — everything before it is what goes in `apiGroups`; the core group's row shows just `v1` with nothing before the slash because there is no group |
| `NAMESPACED` | Whether the resource lives inside a namespace (`true`) or is cluster-scoped (`false`) | Directly answers whether a `Role` can even express a grant for it — a `Role` cannot grant access to any resource where this column reads `false`; that's `ClusterRole` territory, covered in `04-clusterroles-clusterrolebindings` |
| `KIND` | The `kind:` value used in manifests | Not directly RBAC-relevant, but useful for cross-checking you have the right resource |

**Filtering to one group directly** — faster than scanning the full list when you already know the group:
```bash
kubectl api-resources --api-group=apps
```
```
NAME                  SHORTNAMES   APIVERSION   NAMESPACED   KIND
controllerrevisions                apps/v1      true         ControllerRevision
daemonsets            ds           apps/v1      true         DaemonSet
deployments           deploy       apps/v1      true         Deployment
replicasets           rs           apps/v1      true         ReplicaSet
statefulsets          sts          apps/v1      true         StatefulSet
```

**Filtering to namespace-scope directly** — answers "what could a `Role` possibly grant" in one shot:
```bash
kubectl api-resources --namespaced=true
kubectl api-resources --namespaced=false   # everything a Role can NEVER grant, regardless of rule
```

**`-o wide` adds two columns the default view hides — `VERBS` and `CATEGORIES`:**
```bash
kubectl api-resources -o wide --api-group=apps
```
```
NAME                  SHORTNAMES   APIVERSION   NAMESPACED   KIND                 VERBS                                                        CATEGORIES
controllerrevisions                apps/v1      true         ControllerRevision   create,delete,deletecollection,get,list,patch,update,watch   
daemonsets            ds           apps/v1      true         DaemonSet            create,delete,deletecollection,get,list,patch,update,watch   all
deployments           deploy       apps/v1      true         Deployment           create,delete,deletecollection,get,list,patch,update,watch   all
replicasets           rs           apps/v1      true         ReplicaSet           create,delete,deletecollection,get,list,patch,update,watch   all
statefulsets          sts          apps/v1      true         StatefulSet          create,delete,deletecollection,get,list,patch,update,watch   all
```

**Similar-term distinction — this `VERBS` column is not RBAC's `verbs`, even though the words are identical.** The `VERBS` column lists every verb the *resource type itself supports at the API level* — a fixed property of the resource, the same for every cluster and every subject. A PolicyRule's `verbs` field is a *subset you choose to grant* to one subject. `deployments` supporting `delete` at the API level doesn't mean any given Role grants `delete` — it means `delete` is a legal value to put in that Role's `verbs` list if you choose to. Conflating the two is a common source of "but the resource supports that verb!" confusion when a grant is intentionally narrower.

**`CATEGORIES`** groups resources into named collections `kubectl` recognizes for bulk operations — `all` is the one you'll see most often, and it's exactly what `kubectl get all` expands to under the hood (every resource tagged `all` in this column, unioned together). It has no RBAC relevance directly — a category is a `kubectl` client-side convenience grouping, not something a PolicyRule can reference — but it explains why `kubectl get all` includes some resource types and not others: only resources actually tagged with the `all` category show up.

---

### Discovering Subresources — the Gap `api-resources` Leaves

**What it is:** `kubectl api-resources` — in every column, default or `-o wide` — never lists a resource's subresources (`pods/log`, `pods/exec`, `deployments/scale`, and so on). This isn't a filtering option you're missing; the command genuinely does not expose this information, at any verbosity level.

**How to actually find them — the raw API:** Every API group's discovery document is available directly from the API server, and it's the one place subresources actually appear, listed as separate entries whose `name` contains a `/`.

```bash
# Core group (no group prefix in the path)
kubectl get --raw /api/v1 | jq -r '.resources[] | select(.name | contains("/")) | .name'
```
```
namespaces/finalize
namespaces/status
nodes/proxy
nodes/status
persistentvolumeclaims/status
persistentvolumes/status
pods/attach
pods/binding
pods/ephemeralcontainers
pods/eviction
pods/exec
pods/log
pods/portforward
pods/proxy
pods/resize
pods/status
replicationcontrollers/scale
replicationcontrollers/status
resourcequotas/status
serviceaccounts/token
services/proxy
services/status
```
```
# Observation: this is the real, complete core-group subresource list —
# note it isn't only Pods; Nodes, Services, ReplicationControllers, and
# even Namespaces themselves have subresources too (namespaces/finalize,
# namespaces/status). serviceaccounts/token is worth remembering for
# 06-service-accounts-rbac.
```

```bash
# Named groups: /apis/<group>/<version>
kubectl get --raw /apis/apps/v1 | jq -r '.resources[] | select(.name | contains("/")) | .name'
```
```
daemonsets/status
deployments/scale
deployments/status
replicasets/scale
replicasets/status
statefulsets/scale
statefulsets/status
```

- **Why it exists this way:** The raw discovery document is the same machine-readable structure `kubectl api-resources` itself parses to build its table — but that table's format was designed around whole resources, one row each, and was never extended to show a resource's subresources as additional rows. Going to the raw document is going to the actual source of truth `api-resources` is summarizing, not a workaround or a hack.
- **What each entry tells you beyond just the name:** The same `jq` query without the name-only projection shows `namespaced` and `verbs` per subresource too — a subresource can have a *different* verb set than its parent (`pods/log` typically only supports `get`, not the full CRUD set `pods` itself supports):
```bash
kubectl get --raw /api/v1 | jq '.resources[] | select(.name == "pods/log")'
```
```
{
  "name": "pods/log",
  "singularName": "",
  "namespaced": true,
  "kind": "Pod",
  "verbs": [
    "get"
  ]
}
```
```
# Observation: pods/log supports only "get" at the API level — there is
# no "list" or "watch" for a single Pod's log stream, which is exactly
# why a PolicyRule granting pods/log only ever needs "get" in its verbs,
# never list/watch alongside it, unlike the parent pods resource.
```

**`kubectl explain` is a related but different tool, worth distinguishing:** `kubectl explain <resource>` documents a resource's *spec fields* (what goes inside the YAML), not its subresources or supported verbs — `kubectl explain pods.log` or similar does not exist. Use `explain` for "what fields does this object have," and the raw API (`kubectl get --raw`) for "what subresources and verbs does this resource support."

---

### Verb Requirements for `kubectl exec` and `kubectl run`

**What it is:** Two `kubectl` commands whose RBAC requirements are easy to get wrong by reasoning from the parent resource alone, first named in `01`'s Concepts and proven hands-on here.

- **`kubectl exec`** requires **`get` on `pods`** (to resolve which Pod you're targeting) **and `create` on the `pods/exec` subresource** — exec is implemented as *creating* a new exec session against the subresource, not reading one. Granting `get`/`list`/`watch` on `pods` alone — even generously — never grants `exec`, because `create` on a subresource is a completely separate grant from anything on the parent resource.
- **`kubectl run`** requires **`create` on `pods`** directly, in the core group. Modern `kubectl run` always creates a bare `Pod` object, never a `Deployment` — `kubectl create deployment` is the separate command for that, requiring `create` on `deployments` in the `apps` group instead.

**Worked example, decoded:** A Role with `resources: ["pods"], verbs: ["get","list","watch","create"]` grants `kubectl run` (via `create` on `pods`) but still does **not** grant `kubectl exec` — `create` here applies to the `pods` resource, not the `pods/exec` subresource, and RBAC never lets a grant on a parent resource imply anything about a subresource. This is proven live in Step 5.

**Two `can-i` syntaxes for subresources — flagged as unresolved, not asserted as equivalent:** `kubectl auth can-i create pods/exec` and `kubectl auth can-i create pods --subresource=exec` read like they should ask the identical question. Live testing against this Role showed them giving **different answers** in the same session, against the same identity, with no configuration change in between — `pods/exec` (combined-slash form) returned `no` consistently, while `--subresource=exec` (flag form) returned `yes`, and a `can-i --list` run in between confirmed the grant genuinely existed (`pods/exec [create]` was listed). This is proven live in Step 5, and I'm not offering a confident explanation for the discrepancy here — possible causes range from a `kubectl` version-specific parsing quirk to something about how `can-i` resolves a combined `resource/subresource` string for `create` specifically (note `01`'s `get pod/log` combined-slash form worked fine — this may be verb-specific, or specific to `exec`, or something else entirely). Treat the `--subresource=` flag form as the reliable one until this is understood; don't assume the combined-slash form is safe for scripting a subresource `create` check.

**Note:** A trap worth naming explicitly — `kubectl exec` against a controller reference needs a THIRD permission: everything above describes `kubectl exec <pod-name> -- <command>` — exec against a Pod by its literal name. `kubectl exec deployment/web -- <command>` (or `deploy/web`, or any controller-object shorthand) is a different case: `kubectl` must first resolve *which Pod* that Deployment currently owns, which means it issues a `get` against the **Deployment** itself before ever reaching the Pod. A subject with exactly the two permissions described above — `get` on `pods` and `create` on `pods/exec` — will still be denied against a controller-reference exec, not because the exec grant is wrong, but because a completely separate permission (`get` on `deployments`) was never granted. This is proven live in Step 5, and it's a genuinely easy trap to misdiagnose as "the exec grant isn't working" when the actual gap is one level up, in resolving the target.

---

## Lab Step-by-Step Guide

This lab moves in two phases. Steps 1–3 are pure discovery — no objects are created yet, just reading the cluster's own API surface to answer the three questions Concepts just raised: which group is `pods` in, what verbs does it support, and where do its subresources actually show up. Steps 4–5 then apply that discovery skill for real: build a debugging Role from scratch using only what Steps 1–3 revealed, and prove live — including a genuine `kubectl exec` attempt, not just a `can-i` prediction — exactly which permissions it does and doesn't grant.

---

### Step 1 — Survey the Cluster's API Surface

Get the full inventory first, then narrow to the one resource this lab actually needs.

```bash
kubectl api-resources | head -20
```
```
NAME                                SHORTNAMES      APIVERSION                          NAMESPACED   KIND
bindings                                            v1                                  true         Binding
componentstatuses                   cs              v1                                  false        ComponentStatus
configmaps                          cm              v1                                  true         ConfigMap
endpoints                           ep              v1                                  true         Endpoints
events                               ev              v1                                  true         Event
limitranges                         limits          v1                                  true         LimitRange
namespaces                          ns              v1                                  false        Namespace
nodes                                no              v1                                  false        Node
persistentvolumeclaims              pvc             v1                                  true         PersistentVolumeClaim
persistentvolumes                   pv              v1                                  false        PersistentVolume
pods                                 po              v1                                  true         Pod
podtemplates                                        v1                                  true         PodTemplate
replicationcontrollers              rc              v1                                  true         ReplicationController
resourcequotas                      quota           v1                                  true         ResourceQuota
secrets                                              v1                                  true         Secret
serviceaccounts                     sa              v1                                  true         ServiceAccount
services                            svc             v1                                  true         Service
mutatingwebhookconfigurations                       admissionregistration.k8s.io/v1     false        MutatingWebhookConfiguration
validatingadmissionpolicies                         admissionregistration.k8s.io/v1     false        ValidatingAdmissionPolicy
```
```
# Observation: this is the full inventory this demo works from — every
# resource your cluster currently knows about, built-in and CRD alike.
# Yours will differ from this exact list past the core-group rows shown
# here — installed operators/CRDs vary per cluster — but the core group
# (no APIGROUP value, just a bare version) is always this stable set.
```

Filter to confirm the one resource this lab's Role will target:
```bash
kubectl api-resources --api-group='' | egrep  "NAME|pods"
```
```
NAME                     SHORTNAMES   APIVERSION   NAMESPACED   KIND
pods                     po           v1           true         Pod
```

---

### Step 2 — Find Verbs and Confirm Namespace Scope

Two separate questions, both answered by the same command family: what can this resource type do, and can a `Role` even grant it.

```bash
kubectl api-resources -o wide --api-group='' | egrep  "NAME|pods"
```
```
NAME                     SHORTNAMES   APIVERSION   NAMESPACED   KIND                    VERBS                                                        CATEGORIES
pods                     po           v1           true         Pod                     create,delete,deletecollection,get,list,patch,update,watch   all
```
```
# Observation: the VERBS column here lists every verb the Pod resource
# supports at the API level — this is not the same as what any Role
# grants; it's the ceiling, not a live permission. CATEGORIES reads
# "all" — confirming Pods show up under `kubectl get all`, per the
# CATEGORIES explanation in Concepts.
```

Confirm `pods` is namespaced (a prerequisite for it being grantable via `Role` at all, rather than requiring `ClusterRole`):
```bash
kubectl api-resources --namespaced=true --api-group='' | egrep  "NAME|pods"
```
```
NAME                     SHORTNAMES   APIVERSION   NAMESPACED   KIND
pods                     po           v1           true         Pod
```

---

### Step 3 — Discover the `pods/exec` Subresource

The one piece `api-resources` can't answer — go straight to the raw API discovery document instead.

```bash
kubectl get --raw /api/v1 | jq '.resources[] | select(.name == "pods/exec")'
```
```
{
  "name": "pods/exec",
  "singularName": "",
  "namespaced": true,
  "kind": "PodExecOptions",
  "verbs": [
    "create",
    "get"
  ]
}
```
```
# Observation: pods/exec supports both "create" and "get" at the API
# level, but kubectl exec specifically issues a create — this is the
# subresource api-resources itself never lists, confirmed here as the
# authoritative source instead.
```

---

### Step 4 — Create the `ops` Namespace and the Exec-Only Role

Everything Steps 1–3 discovered gets applied here: a Role granting exactly `get` on `pods` and `create` on `pods/exec` — nothing more, nothing assumed.

**`src/01-namespace-ops.yaml`:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ops
```

**`src/02-nginx-deployment.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: ops
spec:
  replicas: 1
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
        image: nginx:1.30.3     # Docker Official Image — pinned, matches 01-rbac-fundamentals
        ports:
        - containerPort: 80
```

**`src/03-role-pod-exec.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-exec-only
  namespace: ops
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get"]                # required to resolve the target Pod
- apiGroups: [""]
  resources: ["pods/exec"]      # separate resource — the subresource itself
  verbs: ["create"]             # exec IS a create against this subresource
```

Create the namespace and workload, then the Role:
```bash
kubectl apply -f src/01-namespace-ops.yaml
kubectl apply -f src/02-nginx-deployment.yaml
kubectl -n ops rollout status deployment/web
kubectl apply -f src/03-role-pod-exec.yaml
```
```
namespace/ops created
deployment.apps/web created
deployment "web" successfully rolled out
role.rbac.authorization.k8s.io/pod-exec-only created
```

**`src/04-rolebinding-oncall.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: oncall-pod-exec
  namespace: ops
subjects:
- kind: User
  name: oncall-engineer
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-exec-only
  apiGroup: rbac.authorization.k8s.io
```

Bind the Role to `oncall-engineer`:
```bash
kubectl apply -f src/04-rolebinding-oncall.yaml
```
```
rolebinding.rbac.authorization.k8s.io/oncall-pod-exec created
```

---

### Step 5 — Prove the Permissions Live, Including a Real `exec` Attempt

`can-i` checks predict what should happen; this step also runs the actual command, because a prediction and a real attempt can diverge for reasons that have nothing to do with the grant itself — as the controller-reference trap below shows directly.

**Positive case — both permissions present, tested two different ways:**
```bash
kubectl auth can-i get pods -n ops --as=oncall-engineer
kubectl auth can-i create pods/exec -n ops --as=oncall-engineer
```
```
yes
no
```
```
# Observation: the "no" here is real and reproducible — it was checked
# multiple times in the same session, including after independently
# confirming via `describe role`/`describe rolebinding` that both
# objects are configured exactly as intended, and it persisted. This is
# NOT the expected result for a grant that (per --list below) genuinely
# exists. See the flagged discrepancy in Concepts — don't paper over
# this with an assumption; it's currently unresolved.
```

**The `--subresource=` flag form, checked immediately after, for the identical permission:**
```bash
kubectl auth can-i create pods --subresource=exec -n ops --as=oncall-engineer
```
```
yes
```
```
# Observation: same subject, same namespace, same underlying permission
# (create on pods/exec) — opposite answer from the combined-slash form
# above. Both can't be describing kubectl's actual enforcement correctly
# at the same time; --list below is the tiebreaker.
```

**Now the real thing, not just a prediction:**
```bash
kubectl get all -n ops
```
```
NAME                      READY   STATUS    RESTARTS   AGE
pod/web-d558f67b6-56hx8   1/1     Running   0          21m

NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   1/1     1            1           21m

NAME                            DESIRED   CURRENT   READY   AGE
replicaset.apps/web-d558f67b6   1         1         1       21m
```

**Attempt exec against the literal Pod name instead:**
```bash
kubectl -n ops exec web-d558f67b6-56hx8 --as=oncall-engineer -- ls
```
```
bin
boot
dev
docker-entrypoint.d
docker-entrypoint.sh
etc
home
lib
lib64
media
mnt
opt
proc
root
run
sbin
srv
sys
tmp
usr
var
```
```
# Observation: succeeds, since this path only needs get on pods (to resolve
# THIS specific, already-named Pod — no Deployment lookup involved) and
# create on pods/exec, both of which this Role grants.
```

**Negative case — remove only the subresource grant, prove `get` on the parent is insufficient by itself:**
```bash
kubectl auth can-i create pods -n ops --as=oncall-engineer
```
```
no
```
```
# Observation: oncall-engineer can "get" pods, but has never been granted
# "create" on the parent pods resource — confirming kubectl run would
# also fail for this identity, since that requires create on pods
# directly, a completely different grant from pods/exec's create.
```

**Full listing — confirm nothing broader leaked in:**
```bash
kubectl auth can-i --list -n ops --as=oncall-engineer
```
```
Resources                                       Non-Resource URLs   Resource Names   Verbs
pods/exec                                        []                  []               [create]
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
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
pods                                             []                  []               [get]
```
```
# Observation: this is the tiebreaker for the discrepancy above —
# pods/exec [create] IS listed here, confirming the grant genuinely
# exists at the RBAC layer. The combined-slash `can-i create pods/exec`
# check returning "no" earlier is therefore most likely a `can-i`
# command-parsing quirk specific to that syntax, not a real gap in the
# Role — but that's a reasonable inference, not a confirmed explanation;
# treat the flagged discrepancy in Concepts as still open. Otherwise:
# exactly "get" on pods and "create" on pods/exec, no delete, no create
# on pods itself, no access to deployments (which is exactly why the
# controller-reference exec attempt above failed), no access to any
# other resource.
```

> **Note:** **Attempt exec via the Deployment shorthand deliberately, to see the trap from Concepts fire:**
>```bash
>kubectl -n ops exec deployment/web --as=oncall-engineer -- ls
>```
>```
>Error from server (Forbidden): deployments.apps "web" is forbidden: User "oncall-engineer" cannot get >resource "deployments" in API group "apps" in the namespace "ops"
>```
>```
># Observation: this is NOT the pods/exec grant failing — read the error
># closely: it names "deployments", not "pods" or "pods/exec" anywhere.
># kubectl had to resolve deployment/web to an actual Pod first, which
># requires get on deployments — a permission this Role never granted,
># on purpose, since it's scoped to exec-only debugging, not to reading
># Deployment objects. This is exactly the third-permission trap named
># in Concepts, now seen firsthand instead of just described.
>```

---

### Step 6 — Cleanup

Nothing to tear down yet if you're continuing straight into Break-Fix — it reuses this exact state as its starting point.

**(a) Demo-scoped resources:** everything created in this lab — the `ops` namespace, `web` Deployment, `pod-exec-only` Role, and `oncall-pod-exec` RoleBinding — stays in place. The Break-Fix section below reuses this exact state as its starting point; full teardown happens once, at the end of Break-Fix, not here.

**(b) Cluster-scoped shared components:** None were installed in this demo — nothing to optionally uninstall.

> **Stopping here without continuing to Break-Fix in this session?** Tear down manually:
> ```bash
> kubectl delete namespace ops --ignore-not-found
> ```

---

## What You Learned

- ✅ Read `kubectl api-resources` output precisely — API group, namespace-scope, and the difference between its `VERBS` column and a PolicyRule's `verbs`
- ✅ Filtered discovery by API group and namespace-scope
- ✅ Discovered a resource's subresources via the raw API, the one thing `api-resources` never shows
- ✅ Built and verified an `exec`-only Role, proving live that `get` on `pods` alone never grants `exec`
- ✅ Diagnosed two discovery-related RBAC misconfigurations from symptoms alone

**Key Takeaway:** `kubectl api-resources` is the authoritative source for a resource's API group and namespace-scope, but it is not a complete map of the grantable surface — subresources exist as separate, independently-permissioned resources that only the raw API discovery documents expose. Reasoning about a grant from the parent resource's verbs alone, without checking whether the actual operation you need targets a subresource instead, is exactly how `exec`-requires-`create`-on-`pods` gets assumed instead of verified.

---

## Break-Fix

Two scenarios below. Diagnose from the symptom command output alone before opening the reveal.

**Restore known-good state before starting** (skip this if you're continuing directly from Step 5 without a break):
```bash
kubectl apply -f ../01-namespace-ops.yaml
kubectl apply -f ../02-nginx-deployment.yaml
kubectl apply -f ../03-role-pod-exec.yaml
kubectl apply -f ../04-rolebinding-oncall.yaml
```

From here on, all commands in this section assume you're working from inside the `src/break-fix/` directory:
```bash
cd src/break-fix/
```
The `ops` namespace and its `web` Deployment, Role, and RoleBinding stay running throughout this section as the shared target — only the Role under test changes between scenarios. Each scenario's cleanup restores the known-good Role before the next scenario starts. Full teardown of `ops` happens once, at the end of the last scenario.

### Error-1 — `get` on pods works, but `exec` still fails

**`src/break-fix/01-role-missing-exec-subresource.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-exec-only
  namespace: ops
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]   # generous on the parent resource...
  # ...but no rule anywhere grants create on pods/exec
```

```bash
kubectl apply -f 01-role-missing-exec-subresource.yaml
kubectl auth can-i get pods -n ops --as=oncall-engineer
kubectl auth can-i create pods --subresource=exec -n ops --as=oncall-engineer
```
```
role.rbac.authorization.k8s.io/pod-exec-only configured
yes
no
```
```
# Note: using --subresource=exec here rather than the combined-slash
# pods/exec form, given the flagged discrepancy in Concepts/Step 5 —
# the combined form returned unreliable results there even for a
# confirmed-granted permission, so it isn't trustworthy for this
# negative-case check either. If you test with the combined-slash form
# instead and get a different answer than expected, that's the same
# open discrepancy, not a new bug in this scenario.
```

`get`/`list`/`watch` on `pods` all check out — even more than the original Role granted. Why does the `exec` permission check still say `no`?

**Full listing — confirm nothing broader leaked in:**
```bash
kubectl auth can-i --list -n ops --as=oncall-engineer
```
```
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
pods                                            []                  []               [get list watch]
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

# Observation: pods/exec [create] IS NOT listed here, confirming the grant genuinely
# does not exist at the RBAC layer. 

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `pods/exec` is a separate resource from `pods` for RBAC purposes, and no rule in this Role's `resources` list mentions it. No amount of generosity on the parent resource's verbs implies anything about a subresource — they're independently permissioned, always.

**Fix:** Add a second rule: `apiGroups: [""], resources: ["pods/exec"], verbs: ["create"]`.

**Cascade:** This is a natural mistake specifically because the Role "looks" more permissive than the working version — three verbs on `pods` instead of one — which makes the `exec` failure counterintuitive if you're reasoning from "more verbs should mean more access" instead of checking which *resource* each verb actually applies to.

</details>

**Cleanup — restore the correct Role for the next scenario:**
```bash
kubectl apply -f ../03-role-pod-exec.yaml
```

---

### Error-2 — `create` is granted, but `kubectl run` still fails

**`src/break-fix/02-role-wrong-resource-for-run.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-exec-only
  namespace: ops
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]
- apiGroups: ["apps"]
  resources: ["deployments"]      # BUG: kubectl run creates a bare Pod,
  verbs: ["create"]               # never a Deployment — this rule grants
                                   # the wrong resource entirely for that command
```

```bash
kubectl apply -f 02-role-wrong-resource-for-run.yaml
kubectl auth can-i create deployments -n ops --as=oncall-engineer
kubectl auth can-i create pods -n ops --as=oncall-engineer
```
```
role.rbac.authorization.k8s.io/pod-exec-only configured
yes
no
```

The Role grants `create` on `deployments`, and that check confirms it. Why does `kubectl run` (which this grant was intended to enable) still fail?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `kubectl run` always creates a bare `Pod` object directly — never a `Deployment` — regardless of what the command's name might suggest. `create` on `deployments` (apps group) has nothing to do with `kubectl run`; that permission would only matter for `kubectl create deployment`, a genuinely different command.

**Fix:** Replace the `deployments` rule with `apiGroups: [""], resources: ["pods"], verbs: ["get", "create"]` if `kubectl run` access is actually intended alongside `exec` — or remove the rule entirely if it isn't, since this Role's stated purpose (`pod-exec-only`) never called for `run` access in the first place.

**Cascade:** This mistake usually comes from pattern-matching the command name ("run" sounds deployment-like) rather than checking what object `kubectl run` actually issues a `create` against — exactly the discovery habit this demo is meant to replace with a verified answer instead of a guess.

</details>

**Cleanup — restore the correct Role, then full teardown (end of Break-Fix):**
```bash
kubectl apply -f ../03-role-pod-exec.yaml
kubectl delete namespace ops --ignore-not-found
cd ../..
```

---

## Interview Prep

**Q1. A teammate says "I granted `get`, `list`, and `watch` on `pods` — why can't this identity `kubectl exec` into anything?" What's the actual gap?**
`kubectl exec` requires `create` on the `pods/exec` subresource, which is a completely separate resource from `pods` for RBAC purposes. No combination of verbs on the parent `pods` resource implies anything about any subresource — the grant on `pods` and the grant on `pods/exec` are independent, and the teammate granted only the former.

**Q2. Where would you look to find a resource's subresources, given `kubectl api-resources` doesn't list them at any verbosity level?**
The raw API discovery document for that resource's group — `kubectl get --raw /api/v1` for the core group, or `kubectl get --raw /apis/<group>/<version>` for any named group — piped through `jq` and filtered for `.resources[].name` entries containing a `/`. This is the same underlying data `api-resources` itself reads, just at a level of detail that command's table format was never extended to display.

**Q3. `kubectl api-resources -o wide` shows `delete` in the `VERBS` column for `pods`. Does that mean any Role granting access to Pods can delete them?**
No. That column describes what the resource type supports at the API level generally — a fixed, cluster-wide property, not a permission. Whether any specific Role actually grants `delete` depends entirely on that Role's own `verbs` list; the `VERBS` column is the ceiling of what's *possible* to grant, not a statement about what's currently granted to anyone.

**Q4. An identity has exactly `get` on `pods` and `create` on `pods/exec` — the textbook-correct exec grant. `kubectl exec deployment/web -- sh` still fails with `Forbidden`. Is the RBAC grant wrong?**
No. Read the error message closely — it names `deployments`, not `pods` or `pods/exec`. `kubectl exec` against a controller-object reference (`deployment/web`, `deploy/web`, etc.) requires `kubectl` to first resolve which actual Pod that Deployment currently owns, which means a `get` against the Deployment itself before the exec request is ever issued. That's a third, separate permission this identity was never granted — the exec grant itself is fine; `kubectl exec <literal-pod-name>` would succeed. This is a genuinely easy trap to misdiagnose as a broken exec grant.

**Q5. `kubectl run --image=nginx debug-pod` fails with `Forbidden` for a given identity, even though that identity can successfully `kubectl create deployment`. Why doesn't the Deployment permission cover this?**
`kubectl run` always creates a bare `Pod` object directly — it never creates a Deployment, regardless of the command's name. It requires `create` on `pods` in the core group. `kubectl create deployment` requires `create` on `deployments` in the `apps` group — a genuinely different resource and group, so permission on one implies nothing about the other.

**Q6. A subresource like `pods/log` shows `"verbs": ["get"]` in the raw API discovery document — no `list`, no `watch`. Why would a subresource have a narrower verb set than its parent resource?**
Some subresources represent an operation that only makes sense as a single-object fetch — you can't meaningfully "list" or "watch" the log stream of an unspecified Pod, only `get` the log of one named Pod. The API server's discovery document reflects exactly which operations that subresource actually supports, which is why checking it directly (rather than assuming it mirrors the parent) matters when writing a PolicyRule.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Demo concept / command | CKA objective | CKAD objective | Notes |
|---|---|---|---|
| `kubectl api-resources` (group/namespace filtering) | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | Fast lookups under time pressure — both exams expect this over guessing resource names |
| `kubectl api-resources -o wide` (VERBS column) | Troubleshooting (30%) | — | Useful for confirming a resource genuinely supports an operation before debugging further |
| Raw API subresource discovery (`kubectl get --raw`) | Cluster Architecture, Installation & Configuration (25%) | — | Less commonly tested directly, but underlies correctly answering any exam task involving `pods/exec`, `pods/log`, or `deployments/scale` grants |
| `pods/exec` permission requirement | Troubleshooting (30%) | Application Environment, Configuration and Security (25%) | A frequently-tested "why doesn't this Role let me exec" trap |
| `kubectl run` vs `kubectl create deployment` resource targets | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | Exam tasks that say "run" and mean a bare Pod are a common source of over- or under-permissioning |

### Common Exam Traps

| Scenario | What the task actually requires | Common wrong approach |
|---|---|---|
| "Grant a debugging identity `exec` access to Pods in namespace X" | Two separate rules: `get` on `pods`, `create` on `pods/exec` | Granting only `get`/`list`/`watch` on `pods`, assuming broad read access is enough |
| Task says "allow running a Pod named X" | `create` on `pods` (core group) | Granting `create` on `deployments`, assuming "run" implies a Deployment |
| Task references a resource's subresource by name (e.g. "scale access") | Explicit rule for `deployments/scale`, separate from `deployments` | Granting `patch`/`update` on `deployments` alone, missing that `scale` is a distinct resource |
| Verifying a resource is namespaced before writing a `Role` for it | `kubectl api-resources --namespaced=true \| grep <resource>` | Assuming namespace-scope instead of checking — a `Role` cannot grant access to a cluster-scoped resource at all, no matter how the rule is written |

### Exam Task — Write it from scratch

**Task:** Create a Role named `debug-exec` in namespace `ops` granting exactly the two permissions `kubectl exec` requires — nothing else — then verify it with `kubectl auth can-i`.

**Official documentation:**
- [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/) — the PolicyRule field reference

**What to practise:**
1. Open the docs page — confirm subresources are expressed as `resource/subresource` strings in `resources`, not a separate field
2. Identify the two required rules: `get` on `pods`, `create` on `pods/exec`
3. Generate a skeleton for the first rule: `kubectl create role debug-exec -n ops --verb=get --resource=pods --dry-run=client -o yaml > task.yaml`
4. Hand-edit `task.yaml` to add the second rule (`resources: ["pods/exec"], verbs: ["create"]`) — `kubectl create role` cannot express two rules with different resources in one invocation
5. Apply with `kubectl apply -f task.yaml` and verify with `kubectl auth can-i create pods --subresource=exec -n ops --as=<subject>` (prefer this over the combined-slash form — see Concepts)

<details>
<summary>Reference solution (open only after attempting)</summary>

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: debug-exec
  namespace: ops
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get"]              # resolves the target Pod
- apiGroups: [""]
  resources: ["pods/exec"]    # separate resource — never implied by "pods" above
  verbs: ["create"]           # exec IS a create against this subresource
```

**Fields you must know without looking up:**
- `resources: ["pods/exec"]` — written as one string with a slash, not a nested field or separate `subresource:` key
- `verbs: ["create"]` on `pods/exec` — not `get`, even though "exec" sounds like a read operation
- Two separate rule entries are required — one `resources`/`verbs` pair cannot mix a parent resource and its subresource under a single `verbs` list meant for both

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| `kubectl api-resources` never lists subresources | At any verbosity level, including `-o wide` — subresources only appear in the raw API discovery documents |
| The `-o wide` `VERBS` column ≠ a PolicyRule's `verbs` | The column is a fixed, cluster-wide property of the resource type; a PolicyRule's `verbs` is a subject-specific subset chosen from that ceiling |
| Subresources are independently permissioned from their parent | Granting any combination of verbs on `pods` implies nothing about `pods/exec`, `pods/log`, or any other subresource — each needs its own explicit rule |
| `kubectl exec` requires two separate grants | `get` on `pods` (to resolve the target) AND `create` on `pods/exec` (the exec session itself) — both are required, neither implies the other |
| `kubectl run` always targets `pods`, never `deployments` | Regardless of the command name, it requires `create` on the core-group `pods` resource specifically |
| A resource's subresources can have a narrower verb set than the parent | E.g. `pods/log` supports only `get` at the API level — no `list`/`watch` exists for a single Pod's log stream |
| `--namespaced=true`/`false` filtering answers a Role-vs-ClusterRole question directly | Any resource listed under `--namespaced=false` can never be granted by a `Role`, regardless of how the rule is written |
| `kubectl explain` documents spec fields, not subresources or verbs | Use the raw API (`kubectl get --raw`) for subresource/verb discovery instead |

> **Demo scope:** Primary concept: API surface discovery (`kubectl api-resources`, raw API subresource discovery). Supporting concept: `exec`/`run` verb-requirement mechanics, proven live.
> Estimated completion time: 45–50 minutes (reading + hands-on + verification).
> Checkpoints: 2 natural stopping points — after Step 4 (Role + RoleBinding created, before verification) and after Step 5 (verification complete, before Break-Fix — an explicit off-ramp is called out in Step 6).

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl api-resources` | Lists every resource type the cluster knows about, with API group and namespace-scope |
| `kubectl api-resources --api-group=<group>` | Filters to one API group |
| `kubectl api-resources --namespaced=true` / `--namespaced=false` | Filters to namespace-scoped or cluster-scoped resources only |
| `kubectl api-resources -o wide` | Adds the `VERBS` and `CATEGORIES` columns |
| `kubectl get --raw /api/v1` | Raw discovery document for the core group — includes subresources, unlike `api-resources` |
| `kubectl get --raw /apis/<group>/<version>` | Raw discovery document for a named group |
| `kubectl auth can-i create pods --subresource=exec -n <namespace> --as=<user>` | Checks the exec-specific subresource permission — prefer this flag form over the combined-slash `pods/exec` form, which showed unreliable results live in this demo (see Concepts) |

### Generating YAML skeletons with --dry-run

`kubectl` can generate a valid YAML manifest for any object it can create imperatively, without actually creating the object. This is one of the most important exam techniques for CKA/CKAD — you rarely need to write YAML from scratch when you can generate a correct skeleton and edit it. Note that discovery commands themselves (`api-resources`, `get --raw`) have no imperative/dry-run equivalent — they're read-only queries, not object creation, so this technique applies only to this demo's Role/RoleBinding/Namespace/Deployment setup, not to the discovery commands that are the demo's actual subject.

**Syntax:**
```bash
kubectl <create-command> <args> --dry-run=client -o yaml > filename.yaml
```

**Supported — any command that creates or modifies an object:**
```bash
# RBAC (this demo's Role — note the two-rule limitation from Step 4)
kubectl create role NAME --verb=get --resource=pods --dry-run=client -o yaml
kubectl create rolebinding NAME --role=ROLE --user=USER --dry-run=client -o yaml

# Namespace and workload used to set up this demo's scenario
kubectl create namespace NAME --dry-run=client -o yaml
kubectl create deployment NAME --image=IMG --dry-run=client -o yaml > deploy.yaml
```

**Not supported** — commands that read, describe, or operate on running objects: `kubectl get`, `describe`, `logs`, `exec`, `delete`, `apply`, `patch`, `label` — this includes every discovery command in this demo's Concepts section; `api-resources` and `get --raw` have no `--dry-run` form because they don't create anything.

**Exam workflow:**
1. Generate the skeleton → edit what you need to change → `kubectl apply -f file.yaml`
2. Or pipe directly: `kubectl create role NAME --verb=get --resource=pods --dry-run=client -o yaml | kubectl apply -f -`

### Imperative Quick-Create Commands

Commands for creating this demo's key objects without YAML — useful under exam time pressure. Full `--dry-run=client -o yaml` skeleton generation is shown for each (see section above).

| Object | Imperative command | Notes |
|---|---|---|
| Namespace | `kubectl create namespace NAME` | |
| Role | `kubectl create role NAME --verb=get --resource=pods` | The `pods/exec` rule needs a second `kubectl create role` invocation against the same name, or a hand-edit — one invocation can only add one `resources` entry with its own `verbs` cleanly when mixing a parent and its subresource |
| RoleBinding | `kubectl create rolebinding NAME --role=ROLE --user=USER` | Or `--group=GROUP` / `--serviceaccount=NS:SA` |

---

## Troubleshooting

**Identity can `get`/`list`/`watch` Pods but `kubectl exec` still fails:**
```bash
kubectl auth can-i create pods --subresource=exec -n <namespace> --as=<user>
```
```
# If checking this with the combined-slash form (create pods/exec)
# instead gives a different answer than --subresource=exec, that's the
# flagged discrepancy from Concepts/Step 5, not a new issue — trust the
# --subresource= form and cross-check with `can-i --list` if unsure.
```
```
# Cause: pods/exec is a separate resource from pods — no verb combination
#        on the parent grants anything on the subresource.
# Fix: Add a rule with resources: ["pods/exec"], verbs: ["create"].
```

**`kubectl run` fails despite `create` access on `deployments`:**
```bash
kubectl auth can-i create pods -n <namespace> --as=<user>
```
```
# Cause: kubectl run always creates a bare Pod, never a Deployment —
#        create on deployments is unrelated to this command.
# Fix: Grant create on pods (core group) if run access is actually needed.
```

**A resource you expect to grant via `Role` seems impossible to scope correctly:**
```bash
kubectl api-resources --namespaced=false | grep <resource>
```
```
# Cause: the resource is cluster-scoped — a Role can never grant access
#        to it, regardless of how the PolicyRule is written.
# Fix: Use a ClusterRole + ClusterRoleBinding instead (12-rbac/04-clusterroles-clusterrolebindings).
```

---

## Appendix — Anki Cards

**`02-rbac-discovery-and-verbs-anki.csv`:**

```
#deck:k8s-platform-labs::12-rbac::02-rbac-discovery-and-verbs
#separator:Comma
#columns:Front,Back,Tags
"Does kubectl api-resources, at any verbosity level, list a resource's subresources?","No. Not even with -o wide. Subresources only appear in the raw API discovery documents (kubectl get --raw /api/v1 or /apis/<group>/<version>), filtered for names containing a slash.","rbac-discovery,api-resources,subresources,cka-cluster-architecture-installation-configuration"
"kubectl api-resources -o wide shows 'delete' in the VERBS column for pods. Does this mean a given Role grants delete access to Pods?","No. That column is a fixed, cluster-wide property of what the resource type supports at the API level — the ceiling of what's grantable. What any specific Role actually grants depends entirely on that Role's own verbs list.","rbac-discovery,api-resources,verbs,cka-troubleshooting"
"A Role grants get, list, and watch on pods. Does this grant kubectl exec access?","No. kubectl exec requires create on the pods/exec subresource, which is a separate resource from pods for RBAC purposes. No verb combination on the parent implies anything about a subresource.","rbac-discovery,exec,subresources,cka-troubleshooting,ckad-application-environment-configuration-security"
"What two permissions does kubectl exec actually require?","get on pods (to resolve the target Pod) AND create on the pods/exec subresource (the exec session itself). Both are required; neither implies the other.","rbac-discovery,exec,subresources,ckad-application-environment-configuration-security"
"Does kubectl run --image=nginx create a Deployment or a Pod, and what does that mean for RBAC?","It always creates a bare Pod directly, never a Deployment, regardless of the command name. It requires create on pods (core group) — create access on deployments is unrelated.","rbac-discovery,run,verbs,ckad-application-environment-configuration-security"
"How do you find a resource's subresources when kubectl api-resources doesn't show them?","Query the raw API discovery document directly: kubectl get --raw /api/v1 for the core group, or kubectl get --raw /apis/<group>/<version> for a named group, then filter .resources[].name for entries containing a slash.","rbac-discovery,api-resources,subresources,cka-cluster-architecture-installation-configuration"
"The raw API discovery document shows pods/log has verbs: [\"get\"] only — no list or watch. Why would a subresource support fewer verbs than its parent?","Some subresources represent operations that only make sense as a single-object fetch — you can't list or watch the log stream of an unspecified Pod, only get the log of one named Pod. The discovery document reflects exactly what that subresource supports.","rbac-discovery,subresources,verbs,cka-troubleshooting"
"kubectl api-resources --namespaced=false lists a resource you need to grant access to. Can a Role express that grant?","No. A Role can never grant access to a cluster-scoped resource, regardless of how the PolicyRule is written — that requires a ClusterRole + ClusterRoleBinding instead.","rbac-discovery,api-resources,role-vs-clusterrole,cka-cluster-architecture-installation-configuration"
"Does kubectl explain show a resource's subresources or supported verbs?","No. kubectl explain documents a resource's spec fields (what goes inside the YAML) — it does not list subresources or verbs. Use the raw API for that instead.","rbac-discovery,kubectl-explain,subresources,cka-troubleshooting"
"In kubectl api-resources output, how do you determine what goes in a PolicyRule's apiGroups field from the APIVERSION column?","Split APIVERSION at the slash — everything before the slash is the apiGroups value. The core group's row shows just a bare version (e.g. v1) with nothing before a slash, because apiGroups for it is the empty string.","rbac-discovery,api-resources,apigroups,cka-cluster-architecture-installation-configuration"
"A PolicyRule uses resources: [\"po\"] intending to grant access to Pods, since po is the SHORTNAMES value kubectl accepts. Does this work?","No. resources always takes the full plural name from the NAME column — SHORTNAMES abbreviations like po are a kubectl CLI convenience only, never valid in a PolicyRule. resources: [\"po\"] matches nothing.","rbac-discovery,api-resources,shortnames,cka-cluster-architecture-installation-configuration"
"What does the CATEGORIES column in kubectl api-resources -o wide actually group, and does it have any RBAC meaning?","It groups resources into named collections kubectl recognizes for bulk operations — most commonly all, which is exactly what kubectl get all expands to. It's a client-side convenience grouping only; a PolicyRule can never reference a category directly.","rbac-discovery,api-resources,categories,cka-cluster-architecture-installation-configuration"
"An identity has exactly get on pods and create on pods/exec. kubectl exec deployment/web -- sh fails with Forbidden naming 'deployments' in the error. Is the exec grant wrong?","No. kubectl exec against a controller reference (deployment/web) must first resolve which Pod that Deployment owns, requiring get on deployments — a third, separate permission never granted here. kubectl exec against the literal Pod name would succeed; the exec grant itself is fine.","rbac-discovery,exec,controller-reference,cka-troubleshooting,ckad-application-environment-configuration-security"
"Do kubectl auth can-i create pods/exec and kubectl auth can-i create pods --subresource=exec always give the same answer?","Not confirmed — live testing showed them giving different answers (no vs yes) for the identical, confirmed-granted permission in the same session. This is an open, unexplained discrepancy; prefer the --subresource= flag form, which matched what can-i --list actually showed as granted.","rbac-discovery,can-i,syntax-discrepancy,cka-troubleshooting"
```

## Appendix — Quiz

**`02-rbac-discovery-and-verbs-quiz.md`:**

````markdown
# Quiz — 12-rbac/02-rbac-discovery-and-verbs: Discovering the Kubernetes API Surface for RBAC

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next demo.

**Q1. Does `kubectl api-resources -o wide` list a resource's subresources?**

- A) Yes, in the CATEGORIES column
- B) Yes, in the VERBS column
- C) No — subresources are never listed by `api-resources`, at any verbosity level
- D) Only for core-group resources

<details>
<summary>Answer</summary>

**C** — Subresources are not exposed by `api-resources` at all, default or `-o wide`. They only appear in the raw API discovery documents (`kubectl get --raw`).
Trap: A and B both misattribute existing columns to a feature they don't provide. D invents a core-group-only exception that doesn't exist.

</details>

---

**Q2. A Role grants `get`, `list`, and `watch` on `pods`. Does this grant `kubectl exec` access?**

- A) Yes — those verbs are broad enough to cover exec
- B) No — `exec` requires `create` on the separate `pods/exec` subresource, which this Role never grants
- C) Yes, but only if `watch` is included
- D) No — `exec` requires a ClusterRole, never a Role

<details>
<summary>Answer</summary>

**B** — `pods/exec` is a distinct resource from `pods` for RBAC purposes. No combination of verbs on the parent implies anything about the subresource.
Trap: A and C both assume verb generosity on the parent transfers to the subresource — it never does. D is false; `pods/exec` can be granted via a namespaced `Role` just like any other namespaced (sub)resource.

</details>

---

**Q3. `kubectl run --image=nginx debug-pod` fails with `Forbidden`, even though the identity has `create` on `deployments`. Why?**

- A) `kubectl run` requires `create` on `pods` directly — it never creates a Deployment
- B) `kubectl run` requires both `pods` and `deployments` permissions simultaneously
- C) `create` on `deployments` should be sufficient; this is a Kubernetes bug
- D) `kubectl run` requires `update`, not `create`

<details>
<summary>Answer</summary>

**A** — `kubectl run` always creates a bare Pod object directly, regardless of the command's name — it requires `create` on the core-group `pods` resource, not `deployments`.
Trap: B invents a dual-requirement that doesn't exist. D substitutes the wrong verb entirely — this is a creation, not a modification.

</details>

---

**Q4. Where do you find a resource's subresources when `kubectl api-resources` doesn't list them?**

- A) `kubectl explain <resource> --recursive`
- B) The raw API discovery document (`kubectl get --raw /api/v1` or `/apis/<group>/<version>`), filtered for names containing a slash
- C) `kubectl describe apiresources`
- D) Subresources cannot be discovered via `kubectl` at all — only via cluster source code

<details>
<summary>Answer</summary>

**B** — The raw discovery document is the same underlying data `api-resources` reads, but at a level of detail its table format never surfaces. Subresource entries have a `name` field containing a `/`.
Trap: A describes a real command with an unrelated purpose (documenting spec fields, not subresources). C is not a real `kubectl` command.

</details>

---

**Q5. The raw API discovery document shows `pods/log` with `"verbs": ["get"]` only. What does this tell you?**

- A) This is an error in the discovery document — `list` and `watch` should also be present
- B) `pods/log` genuinely only supports `get` at the API level — there's no meaningful "list" or "watch" for a single Pod's log stream
- C) `list` and `watch` are implied even though not listed
- D) This subresource requires a ClusterRole to grant, unlike other subresources

<details>
<summary>Answer</summary>

**B** — The discovery document accurately reflects what operations that subresource supports. Some subresources genuinely have a narrower verb set than their parent because the operation only makes sense as a single-object fetch.
Trap: A and C both assume the document is incomplete or that RBAC has implicit grants — neither is true anywhere in Kubernetes RBAC. D invents a scope restriction with no basis.

</details>

---

**Q6. `kubectl api-resources --namespaced=false` lists a resource you need an identity to access. What does this tell you about how to grant it?**

- A) A `Role` can grant it as long as the `RoleBinding` is created in every namespace
- B) A `Role` can never grant access to it — a `ClusterRole` + `ClusterRoleBinding` is required instead
- C) It requires a special `ClusterResourceRole` object
- D) Nothing — namespace-scope has no bearing on which binding type is required

<details>
<summary>Answer</summary>

**B** — Cluster-scoped resources (`--namespaced=false`) can never be granted through a `Role`, no matter how the `PolicyRule` is written or how many namespaces get a `RoleBinding`. Only `ClusterRole` + `ClusterRoleBinding` can express this.
Trap: A describes a workaround that doesn't work — repeating a `RoleBinding` across namespaces still can't grant access to something with no namespace to scope to. C invents an object type that doesn't exist.

</details>

---

**Q7. A PolicyRule uses `resources: ["po"]`, since `po` is the `SHORTNAMES` abbreviation `kubectl` accepts for Pods. Does this grant work?**

- A) Yes — `kubectl` accepts `po`, so RBAC does too
- B) No — `resources` always requires the full plural name from the `NAME` column; `SHORTNAMES` is a CLI-only convenience
- C) Yes, but only for `get` operations
- D) No — `po` is reserved for `PodDisruptionBudget`, not `Pod`

<details>
<summary>Answer</summary>

**B** — `SHORTNAMES` abbreviations exist purely for `kubectl` command-line convenience; a `PolicyRule`'s `resources` field never accepts them. `resources: ["po"]` silently matches nothing, the same failure shape as the singular-vs-plural trap from `01`.
Trap: A assumes RBAC and the `kubectl` CLI share the same name-resolution behavior — they don't. D invents a naming conflict that doesn't exist (`pdb`, not `po`, is the shortname for PodDisruptionBudget).

</details>

---

Score guide:
| Score | Action |
|---|---|
| 7/7 | Import Anki cards, move to 03-advanced-policyrules-and-subjects |
| 6/7 | Review the wrong answer, then proceed |
| 5/7 | Re-read the relevant section, retry those questions |
| Below 5/7 | Re-read the full demo and redo the walkthrough before proceeding |
````