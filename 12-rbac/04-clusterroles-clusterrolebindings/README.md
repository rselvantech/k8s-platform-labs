# Demo: 12-rbac/04-clusterroles-clusterrolebindings — Cluster-Scoped RBAC and Built-In ClusterRoles

## Lab Overview

Every Role in this series so far has been trapped inside one namespace by design — `02` showed that `kubectl api-resources --namespaced=false` lists resources a `Role` can *never* reach, no matter how the `PolicyRule` is written. Nodes, PersistentVolumes, and RBAC's own `ClusterRole`/`ClusterRoleBinding` objects all live there. This demo covers the object type built specifically to reach them — and a detail most engineers miss: a `ClusterRole` isn't only for cluster-wide grants; it can also be bound to a single namespace, which is exactly how Kubernetes' own built-in `view`/`edit`/`admin` ClusterRoles are designed to be used.

**Real-world scenario:** Your SRE team needs cluster-wide read access to Nodes (to investigate capacity issues) and to the API server's health endpoints (for external monitoring tooling) — neither of which a `Role` can express. Separately, a new engineer joining one project team needs broad read access to everything in that project's namespace, without you hand-writing a Role that duplicates dozens of resource types Kubernetes already ships a built-in answer for.

**What this lab covers:**
- Writing a `ClusterRole` and binding it cluster-wide with a `ClusterRoleBinding`
- The binding matrix: the same `ClusterRole` object bound via `ClusterRoleBinding` (cluster-wide) versus via `RoleBinding` (namespace-scoped application of cluster-defined rules)
- `nonResourceURLs` hands-on — the one `PolicyRule` field exclusive to `ClusterRole`
- Kubernetes' built-in ClusterRoles (`view`, `edit`, `admin`, `cluster-admin`): what each grants, how they differ, and a real gap in `view` worth knowing before you rely on it

> **Scope note:** This lab does not cover ClusterRole aggregation (`aggregationRule`, combining multiple ClusterRoles into one) — that's `12-rbac/07-aggregated-clusterroles`. It does not cover ServiceAccount-specific binding patterns — that's `12-rbac/06-service-accounts-rbac`.

---

## Prerequisites

**Required Software:**
- minikube `3node` profile — control plane + 2 workers, already running from earlier topic groups
- kubectl v1.35.x (matched to cluster version)

**Verify before starting:**
```bash
kubectl get nodes
```

**Knowledge Requirements:**
- **REQUIRED:** `12-rbac/01-rbac-fundamentals` (Role/RoleBinding/PolicyRule mechanics), `12-rbac/02-rbac-discovery-and-verbs` (`--namespaced=true`/`false` filtering) — both assumed, not re-taught here

---

## Lab Objectives

By the end of this lab, you will be able to:

1. ✅ Write a `ClusterRole` granting access to a cluster-scoped resource, and bind it cluster-wide with a `ClusterRoleBinding`
2. ✅ Explain the difference between binding a `ClusterRole` via `ClusterRoleBinding` versus via a namespace-scoped `RoleBinding`
3. ✅ Write and verify a `nonResourceURLs` rule, and explain why it can only exist in a `ClusterRole`
4. ✅ Identify what each built-in ClusterRole (`view`/`edit`/`admin`/`cluster-admin`) grants, and name the one deliberate gap in `view`
5. ✅ Diagnose and fix three common ClusterRole/ClusterRoleBinding misconfigurations from symptoms alone

---

## Directory Structure

```
12-rbac/04-clusterroles-clusterrolebindings/
├── README.md
├── 04-clusterroles-clusterrolebindings-anki.csv
├── 04-clusterroles-clusterrolebindings-quiz.md
└── src/
    ├── 01-clusterrole-node-and-health-reader.yaml   # cluster-scoped ClusterRole: Nodes + nonResourceURLs
    ├── 02-clusterrolebinding-sre-team.yaml            # binds it cluster-wide to the sre-team Group
    ├── 03-namespace-project-a.yaml                    # namespace for the built-in-ClusterRole scenario
    ├── 04-rolebinding-view-project-a.yaml             # binds the built-in "view" ClusterRole via a namespaced RoleBinding
    └── break-fix/
        ├── 01-rolebinding-clusterrole-nodes.yaml
        ├── 02-role-nonresourceurls-rejected.yaml
        └── 03-view-secrets-assumption.yaml
```

---

## Recall Check — 03-advanced-policyrules-and-subjects

Answer from memory before continuing — no peeking at the previous demo.

1. Can a Role's `rules` list have one rule narrow or override another rule in the same Role?
2. What's the actual difference between a `User` subject and a `Group` subject in a `RoleBinding`?
3. Why does `resourceNames` have no effect when combined with the `create` verb?

<details>
<summary>Answers</summary>

1. No — rules within a Role don't interact; effective access is the union of every rule, with no ordering or override behavior between them.
2. They match against different parts of an authenticated identity — `User` matches the request's username, `Group` matches its group membership list — despite both being plain strings with no backing API object.
3. At `create` time the object doesn't exist yet, so there's no name for the API server to check the request against — the combination applies without error but restricts nothing.

</details>

---

## Concepts

### ClusterRole — Cluster-Scoped Permission Grants

**What it is:** A `ClusterRole` is structurally identical to a `Role` — the same `rules` field, the same `PolicyRule` shape (`apiGroups`, `resources`, `verbs`, `resourceNames`) — but it is **not** namespace-scoped. It has no `metadata.namespace` field at all.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-and-health-reader        # no namespace field — ClusterRole is cluster-scoped by definition
rules:
- apiGroups: [""]
  resources: ["nodes"]                # cluster-scoped resource — confirmed via 02's discovery skill:
  verbs: ["get", "list", "watch"]      # kubectl api-resources --namespaced=false | grep nodes
```

- **Why it exists:** Some resources — Nodes, PersistentVolumes, Namespaces themselves, and RBAC's own `ClusterRole`/`ClusterRoleBinding` — have no namespace to scope a grant to. A `Role` is physically incapable of referencing them (from `02`'s discovery lesson); `ClusterRole` is the object built to reach them.
- **`PolicyRule` rules are identical either way:** everything learned about `apiGroups`, `resources`, `verbs`, and `resourceNames` in `01` and `03` applies unchanged inside a `ClusterRole` — nothing about the rule syntax itself changes based on which object contains it.

### ClusterRoleBinding — Cluster-Wide Application

**What it is:** The cluster-scoped counterpart to `RoleBinding` — connects a `ClusterRole` to subjects, with the grant applying across **every** namespace in the cluster (for namespaced resources named in the rules) plus any cluster-scoped resources the rules reference.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sre-team-node-and-health-reader   # no namespace field here either
subjects:
- kind: Group
  name: sre-team
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole                        # must be ClusterRole — a ClusterRoleBinding cannot reference a Role
  name: node-and-health-reader
  apiGroup: rbac.authorization.k8s.io
```

- **Why it exists:** Nodes have no namespace at all — there is no namespace you could scope a Node-reading grant to even if you wanted to. `ClusterRoleBinding` is the only binding type that can reach a rule targeting a genuinely cluster-scoped resource.
- **`roleRef.kind` must be `ClusterRole`:** a `ClusterRoleBinding` cannot reference a `Role` — only a `RoleBinding` can do that (and only within the Role's own namespace, per `01`). The reverse combination — this section's next concept — is the one that surprises people.

### The Binding Matrix — the Same ClusterRole, Two Different Effects

**What it is:** A `ClusterRole` can be bound **two different ways**, with genuinely different effects, and this is the single most important thing to understand before touching built-in ClusterRoles:

| Object | Bound via | Effect |
|---|---|---|
| `Role` | `RoleBinding` | Namespace-scoped grant, from a namespace-scoped rule set (`01`) |
| `ClusterRole` | `ClusterRoleBinding` | Cluster-wide grant, reaching cluster-scoped resources too |
| `ClusterRole` | `RoleBinding` | **Namespace-scoped grant, from a cluster-defined rule set** |

- **Why the third row exists:** Writing the identical `PolicyRule` set once as a `ClusterRole`, then reusing it via ordinary `RoleBinding`s scoped to different namespaces, avoids maintaining N nearly-identical `Role` objects with the same rules. This is precisely why Kubernetes ships `view`/`edit`/`admin` as built-in **ClusterRoles**, not built-in Roles — they're meant to be bound per-namespace via `RoleBinding`, reusing one cluster-wide rule definition everywhere, while `cluster-admin` is meant to be bound via `ClusterRoleBinding` for genuine cluster-wide grants.
- **The critical limitation of row three:** binding a `ClusterRole` via `RoleBinding` only activates the parts of its rules that target **namespaced** resources, scoped to that RoleBinding's namespace. Any rule inside that same `ClusterRole` targeting a cluster-scoped resource (like `nodes`) is simply unreachable through this path — a `RoleBinding` cannot grant cluster-scoped access no matter what object it references, because the binding itself is still namespace-scoped. This is proven live in Break-Fix Error-1.

### `nonResourceURLs` — Hands-On

**What it is:** First named in `01`'s Concepts as a `PolicyRule` field matching API server endpoints with no backing Kubernetes object — health checks, version info, discovery paths — by literal path instead of by `apiGroups`/`resources`.

```yaml
rules:
- nonResourceURLs: ["/healthz", "/livez", "/readyz"]   # no apiGroups or resources field at all
  verbs: ["get"]                                         # nonResourceURLs rules only ever use "get"
```

- **Why it can only exist in `ClusterRole`:** these endpoints have no namespace to scope them to — `/healthz` isn't "in" any namespace, so there's no namespace-scoped object (`Role`) that could sensibly express a grant for it. Attempting to set `nonResourceURLs` inside a `Role` is rejected by the API server at admission time, not silently ignored — proven in Break-Fix Error-2.
- **Path matching:** `*` works as a path-prefix wildcard (`/api/*` matches `/api/v1`, `/api/apps`, etc.), but there's no equivalent to `apiGroups`/`resources` wildcarding within a literal path — you're matching URL structure, not a resource taxonomy.

### Built-In ClusterRoles — `view`, `edit`, `admin`, `cluster-admin`

**What they are:** Four ClusterRoles Kubernetes ships by default, covering the most common access levels so most teams never need to hand-write a broad read/write Role from scratch.

| ClusterRole | Grants | Notable exclusions |
|---|---|---|
| `view` | Read-only (`get`/`list`/`watch`) on almost all namespaced resources | **Does not include Secrets** — a deliberate security choice, not an oversight |
| `edit` | Read/write on most namespaced resources (Pods, Deployments, Services, ConfigMaps, Jobs, etc.) | Cannot view or modify RBAC objects (Roles/RoleBindings) in the namespace, and cannot modify ResourceQuotas |
| `admin` | Everything `edit` grants, plus the ability to manage Roles and RoleBindings *within that namespace* | Still cannot touch anything outside its bound namespace, and cannot modify the namespace's ResourceQuota |
| `cluster-admin` | `apiGroups: ["*"], resources: ["*"], verbs: ["*"]` — literally everything, everywhere | None — this is the wildcard grant from `01`'s Concepts, made concrete as an actual shipped object |

- **`view` excluding Secrets is worth internalizing specifically:** it's a common assumption that "read-only" means "can read everything," and `view` is deliberately narrower than that — a subject bound to `view` genuinely cannot `kubectl get secrets`, even though it can read almost everything else. This is proven live in Break-Fix Error-3.
- **Usage pattern — almost always via `RoleBinding`, not `ClusterRoleBinding`:** per the binding matrix above, the normal way to use `view`/`edit`/`admin` is a namespace-scoped `RoleBinding` referencing the built-in `ClusterRole` — giving one team broad access to one namespace, not the whole cluster. Reaching for `ClusterRoleBinding` with `admin` grants that team `admin` in *every* namespace, almost never the actual intent.
- **`kubectl describe clusterrole view` shows the full rule set** — worth running once to see the shape of a real, large, production-grade ClusterRole rather than only this series' small hand-written examples.

---

## Lab Step-by-Step Guide

---

### Step 1 — Confirm Nodes Are Cluster-Scoped

Reusing the discovery skill from `02` before writing anything:
```bash
kubectl api-resources --namespaced=false | grep -w nodes
```
```
⚠️ [VERIFY]
nodes   no   v1   false   Node
```
```
# Observation: NAMESPACED reads false — confirming, per 02, that no Role
# could ever grant access to this resource, regardless of how its
# PolicyRule were written. This is exactly the gap ClusterRole exists to
# close.
```

---

### Step 2 — Write the ClusterRole

**`src/01-clusterrole-node-and-health-reader.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-and-health-reader
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
- nonResourceURLs: ["/healthz", "/livez", "/readyz"]
  verbs: ["get"]
```

```bash
kubectl apply -f src/01-clusterrole-node-and-health-reader.yaml
kubectl describe clusterrole node-and-health-reader
```
```
⚠️ [VERIFY]
```
```
# Observation: two rules, one targeting a cluster-scoped resource by
# apiGroups/resources, one targeting non-resource URLs by literal path —
# both legal in a ClusterRole, neither legal (as we'll prove in
# Break-Fix) in a Role.
```

---

### Step 3 — Bind Cluster-Wide with ClusterRoleBinding

**`src/02-clusterrolebinding-sre-team.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sre-team-node-and-health-reader
subjects:
- kind: Group
  name: sre-team
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: node-and-health-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f src/02-clusterrolebinding-sre-team.yaml
kubectl auth can-i get nodes --as-group=sre-team --as=someone
kubectl auth can-i get --subresource=none /healthz --as-group=sre-team --as=someone 2>&1 || true
```
```
⚠️ [VERIFY]
yes
```
```
# Note: kubectl auth can-i's support for checking nonResourceURLs directly
# uses a different invocation shape than resource checks — confirm the
# exact working syntax against your cluster and replace this line;
# `kubectl auth can-i get /healthz --as-group=sre-team --as=someone` is
# the more likely correct form and should be verified directly.
```

Confirm this reaches every namespace, not just one, since no namespace was specified anywhere:
```bash
kubectl auth can-i get nodes -n default --as-group=sre-team --as=someone
kubectl auth can-i get nodes -n kube-system --as-group=sre-team --as=someone
```
```
⚠️ [VERIFY]
yes
yes
```
```
# Observation: identical answer regardless of -n, because nodes are
# cluster-scoped — the -n flag is accepted but has no effect on a
# cluster-scoped resource check. This is a ClusterRoleBinding's grant,
# reaching everywhere, exactly as designed.
```

---

### Step 4 — Bind a Built-In ClusterRole via Namespaced RoleBinding

**`src/03-namespace-project-a.yaml`:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: project-a
```

**`src/04-rolebinding-view-project-a.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: project-a-viewers
  namespace: project-a           # namespace-scoped, even though it references a ClusterRole
subjects:
- kind: User
  name: new-engineer
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole               # referencing the BUILT-IN ClusterRole, not a Role
  name: view
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f src/03-namespace-project-a.yaml
kubectl apply -f src/04-rolebinding-view-project-a.yaml
kubectl auth can-i get pods -n project-a --as=new-engineer
kubectl auth can-i get nodes --as=new-engineer
```
```
⚠️ [VERIFY]
yes
no
```
```
# Observation: read access inside project-a — yes (the RoleBinding's
# namespace scope activated the namespaced-resource parts of view's
# rules). Cluster-scoped access to Nodes — no, even though the same
# ClusterRole object would grant it if bound via ClusterRoleBinding
# instead. This is the binding-matrix limitation from Concepts, proven
# live: a RoleBinding cannot unlock a cluster-scoped rule, regardless of
# which object it references.
```

---

### Step 5 — Cleanup

**(a) Demo-scoped resources:** everything created in this lab — the ClusterRole, ClusterRoleBinding, `project-a` namespace, and its RoleBinding — stays in place. Break-Fix reuses this state; full teardown happens once, at the end of Break-Fix.

**(b) Cluster-scoped shared components:** the built-in `view` ClusterRole is not something this demo installs or should ever delete — it ships with the cluster.

> **Stopping here without continuing to Break-Fix in this session?** Tear down manually:
> ```bash
> kubectl delete clusterrolebinding sre-team-node-and-health-reader --ignore-not-found
> kubectl delete clusterrole node-and-health-reader --ignore-not-found
> kubectl delete namespace project-a --ignore-not-found
> ```

---

## What You Learned

- ✅ Wrote a `ClusterRole` granting access to a cluster-scoped resource, bound cluster-wide with a `ClusterRoleBinding`
- ✅ Proved live that binding a `ClusterRole` via `RoleBinding` activates only its namespaced-resource rules, never its cluster-scoped ones
- ✅ Wrote and verified a `nonResourceURLs` rule
- ✅ Identified what each built-in ClusterRole grants, including `view`'s deliberate Secrets exclusion
- ✅ Diagnosed and fixed three misconfigurations from symptoms alone

**Key Takeaway:** `ClusterRole` and `Role` share identical `PolicyRule` syntax, but the binding type — not the rule object type alone — determines whether a grant reaches cluster-scoped resources. A `ClusterRole` bound via `RoleBinding` is a legitimate, commonly-used pattern (exactly how built-in `view`/`edit`/`admin` are meant to be consumed), but it silently caps out at namespaced resources — the cluster-scoped parts of that same ClusterRole simply never activate through that path.

---

## Break-Fix

Three scenarios below. Diagnose from the symptom command output alone before opening the reveal.

**Restore known-good state before starting** (skip this if you're continuing directly from Step 4 without a break):
```bash
kubectl apply -f ../01-clusterrole-node-and-health-reader.yaml
kubectl apply -f ../02-clusterrolebinding-sre-team.yaml
kubectl apply -f ../03-namespace-project-a.yaml
kubectl apply -f ../04-rolebinding-view-project-a.yaml
```

From here on, all commands assume you're working from inside `src/break-fix/`:
```bash
cd src/break-fix/
```

### Error-1 — Nodes access via ClusterRole, bound with the wrong binding type

**`src/break-fix/01-rolebinding-clusterrole-nodes.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding                    # BUG: should be ClusterRoleBinding for cluster-scoped access
metadata:
  name: sre-team-nodes-attempt
  namespace: project-a               # a RoleBinding must live in SOME namespace
subjects:
- kind: Group
  name: sre-team
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: node-and-health-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f 01-rolebinding-clusterrole-nodes.yaml
kubectl auth can-i get nodes --as-group=sre-team --as=someone
```
```
⚠️ [VERIFY]
rolebinding.rbac.authorization.k8s.io/sre-team-nodes-attempt created
no
```

The binding applied without error, and it correctly references the `ClusterRole` that grants Node access. Why does the check still fail?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** A `RoleBinding` is namespace-scoped no matter which object it references — binding a `ClusterRole` via `RoleBinding` only activates the rules inside it that target namespaced resources, scoped to that binding's own namespace. `nodes` is cluster-scoped; there is no namespace-scoped path that can ever reach it, regardless of what the `ClusterRole` itself contains.

**Fix:** Use a `ClusterRoleBinding` instead (already done correctly in `02-clusterrolebinding-sre-team.yaml`) — there is no fix expressible with a `RoleBinding` here; the binding type itself must change.

**Cascade:** This is the binding-matrix limitation from Concepts, now a real failure a learner might hit by reasonably assuming "I bound the right ClusterRole, so it should work." Nothing in the YAML looks wrong, and the `apply` succeeds cleanly — the only signal is the `can-i` check itself.

</details>

**Cleanup:**
```bash
kubectl delete -f 01-rolebinding-clusterrole-nodes.yaml --ignore-not-found
```

---

### Error-2 — `nonResourceURLs` rejected outright in a Role

**`src/break-fix/02-role-nonresourceurls-rejected.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role                          # BUG: nonResourceURLs is not valid in a namespaced Role
metadata:
  name: health-reader-attempt
  namespace: project-a
rules:
- nonResourceURLs: ["/healthz"]
  verbs: ["get"]
```

```bash
kubectl apply -f 02-role-nonresourceurls-rejected.yaml
```
```
⚠️ [VERIFY — exact error text not yet confirmed against a live run; run
this and replace with the actual captured output]
error: error validating "02-role-nonresourceurls-rejected.yaml": error validating data: ValidationError(Role.rules[0]): unknown field "nonResourceURLs" in io.k8s.api.rbac.v1.PolicyRule for namespaced Role usage; if you choose to ignore these errors, turn validation off with --validate=false
```

Unlike Error-1, this doesn't apply cleanly at all. Why the different failure mode this time?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `nonResourceURLs` has no namespace to scope to — a `Role` object is inherently namespace-scoped, so the API server rejects the combination outright at admission time rather than accepting a rule it can never meaningfully apply. This is a loud, immediate failure, in direct contrast to Error-1's silent one.

**Fix:** Move the rule into a `ClusterRole` instead — `nonResourceURLs` is valid there unconditionally.

**Cascade:** Worth contrasting directly with Error-1: some cluster-scope mistakes fail loudly and immediately (this one), others apply cleanly and only reveal themselves under a live permission check (Error-1, and every silent-typo scenario across this series so far). Knowing which category a given mistake falls into changes how you'd even notice it went wrong.

</details>

**Cleanup:** nothing to clean up — this file never successfully applied.

---

### Error-3 — `view` doesn't grant what it's assumed to grant

**`src/break-fix/03-view-secrets-assumption.yaml`:**

No broken file this time; the "bug" is an incorrect assumption about already-correct, already-applied configuration from Step 4:

```bash
kubectl auth can-i get secrets -n project-a --as=new-engineer
```
```
⚠️ [VERIFY]
no
```

`new-engineer` is bound to the built-in `view` ClusterRole in `project-a`, and every other read check in this namespace has succeeded so far. Why does this one fail?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `view` deliberately excludes Secrets from its grant — this is not a bug or an oversight, it's a documented security design choice in the built-in ClusterRole itself. "Read-only" in Kubernetes' built-in roles does not mean "can read literally everything"; Secrets specifically are carved out.

**Fix:** There is no fix if this is actually the intended behavior — if `new-engineer` genuinely needs Secret access, that requires an additional, separate grant (a custom Role/RoleBinding adding `get` on `secrets`), not an assumption that `view` already covers it.

**Cascade:** This is the kind of assumption that surfaces late — someone builds and tests against Pods, Deployments, ConfigMaps, all of which `view` covers, concludes "read access is working," and only discovers the Secrets gap when a specific downstream task needs it. Checking `kubectl describe clusterrole view` directly, rather than assuming from the name, is the reliable way to know before it becomes a surprise.

</details>

**Cleanup — full teardown (end of Break-Fix):**
```bash
kubectl delete clusterrolebinding sre-team-node-and-health-reader --ignore-not-found
kubectl delete clusterrole node-and-health-reader --ignore-not-found
kubectl delete namespace project-a --ignore-not-found
cd ../..
```

---

## Interview Prep

**Q1. A `ClusterRole` grants `get` on both `nodes` (cluster-scoped) and `configmaps` (namespaced). It's bound via an ordinary `RoleBinding` in namespace `team-a`. What access does the bound subject actually have?**
`get` on ConfigMaps within `team-a` only — the namespaced part of the rule activates, scoped to the RoleBinding's namespace. The `nodes` rule never activates through this path at all, because a `RoleBinding` is namespace-scoped regardless of what object it references; there is no namespace a Node-reading grant could apply to via this binding type.

**Q2. Why does Kubernetes ship `view`/`edit`/`admin` as `ClusterRole`s rather than `Role`s, if they're normally applied to just one namespace?**
Shipping them as `ClusterRole`s lets the same rule definition be reused across every namespace via ordinary `RoleBinding`s, rather than maintaining N nearly-identical `Role` objects with the same rules. `ClusterRole` + `RoleBinding` is a fully supported combination specifically for this reuse pattern — the object type doesn't dictate how broadly it must be applied.

**Q3. Someone assumes the built-in `view` ClusterRole lets a subject read Secrets, since it grants broad read access to almost everything else. What's actually true?**
`view` deliberately excludes Secrets — a documented security design choice, not an oversight. A subject bound only to `view` cannot `kubectl get secrets`, even though nearly every other resource type is readable. Verifying against `kubectl describe clusterrole view` directly, rather than assuming from "read-only" framing, avoids this surfacing as a surprise later.

**Q4. A `Role` (not `ClusterRole`) is written with a `nonResourceURLs` rule. What happens when you try to apply it?**
The API server rejects it outright at admission time — unlike a typo'd `roleRef` or a wrong `apiGroups` value, which apply cleanly and fail silently later, this is a loud, immediate validation error. `nonResourceURLs` has no namespace to scope to, so a namespace-scoped `Role` can never legally contain it.

**Q5. What's the practical difference between granting `cluster-admin` via `ClusterRoleBinding` versus granting `admin` via `RoleBinding` in one namespace?**
`cluster-admin` via `ClusterRoleBinding` grants unrestricted access to literally everything, cluster-wide — every namespace, every cluster-scoped resource, every verb. `admin` via `RoleBinding` grants broad read/write and Role/RoleBinding management, but strictly within that one namespace — it cannot touch anything in any other namespace, and cannot reach cluster-scoped resources at all, since a `RoleBinding`'s namespace scope caps it regardless of which ClusterRole it references.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Demo concept / command | CKA objective | CKAD objective | Notes |
|---|---|---|---|
| `ClusterRole`/`ClusterRoleBinding` creation | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | Exam tasks referencing cluster-scoped resources (Nodes, PVs) expect this pair, not `Role`/`RoleBinding` |
| Binding a `ClusterRole` via `RoleBinding` | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | A frequently-missed valid combination — tasks asking for namespace-scoped access to built-in roles expect this, not a hand-written duplicate Role |
| `nonResourceURLs` | Cluster Architecture, Installation & Configuration (25%) | — | Object-type restriction (`ClusterRole` only) is a common trap in written/scenario questions |
| Built-in ClusterRoles (`view`/`edit`/`admin`/`cluster-admin`) | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | Knowing `view` excludes Secrets specifically is tested more than the broad-strokes grant descriptions |

### Common Exam Traps

| Scenario | What the task actually requires | Common wrong approach |
|---|---|---|
| "Grant cluster-wide read access to Nodes" | `ClusterRole` + `ClusterRoleBinding` | Using `RoleBinding`, which silently fails to reach the cluster-scoped resource despite applying cleanly |
| "Grant this team broad access to their own namespace only" | Built-in `admin` (or `edit`) `ClusterRole` bound via `RoleBinding` in that namespace | Hand-writing a new `Role` duplicating dozens of resource types the built-in ClusterRole already covers |
| "Grant access to a health/version endpoint" | `ClusterRole` with `nonResourceURLs` | Attempting a `Role`, which the API server rejects outright |
| Assuming `view` grants full read access | Confirm against `kubectl describe clusterrole view` — Secrets are excluded | Assuming "read-only" is synonymous with "every resource, readable," discovering the gap only when a Secrets-dependent task fails |

### Exam Task — Write it from scratch

**Task:** Create a `ClusterRole` named `pv-reader` granting `get`/`list`/`watch` on `persistentvolumes` (cluster-scoped), then bind it cluster-wide to a Group named `storage-team`.

**Official documentation:**
- [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/) — the `ClusterRole`/`ClusterRoleBinding` field reference

**What to practise:**
1. Confirm `persistentvolumes` is cluster-scoped: `kubectl api-resources --namespaced=false | grep persistentvolumes`
2. Generate the ClusterRole skeleton: `kubectl create clusterrole pv-reader --verb=get,list,watch --resource=persistentvolumes --dry-run=client -o yaml > task.yaml`
3. Generate the ClusterRoleBinding skeleton: `kubectl create clusterrolebinding storage-team-pv-reader --clusterrole=pv-reader --group=storage-team --dry-run=client -o yaml >> task.yaml`
4. Apply and verify with `kubectl auth can-i get persistentvolumes --as-group=storage-team --as=someone`

<details>
<summary>Reference solution (open only after attempting)</summary>

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pv-reader
rules:
- apiGroups: [""]
  resources: ["persistentvolumes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: storage-team-pv-reader
subjects:
- kind: Group
  name: storage-team
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: pv-reader
  apiGroup: rbac.authorization.k8s.io
```

**Fields you must know without looking up:**
- Neither object has a `metadata.namespace` field — including one is not an error, but it's meaningless and a sign of confusion between `Role`/`ClusterRole`
- `roleRef.kind: ClusterRole` in the binding — a `ClusterRoleBinding` referencing `kind: Role` is invalid
- `kubectl create clusterrolebinding` uses `--clusterrole=`, not `--role=` — an easy imperative-flag mixup under time pressure

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| `ClusterRole`/`Role` share identical `PolicyRule` syntax | Everything about `apiGroups`/`resources`/`verbs`/`resourceNames` from `01`/`03` applies unchanged inside a `ClusterRole` |
| The binding type determines scope, not just the role object type | `ClusterRole` + `RoleBinding` = namespace-scoped application of cluster-defined rules; only `ClusterRole` + `ClusterRoleBinding` reaches cluster-scoped resources |
| A `ClusterRole`'s cluster-scoped rules never activate through a `RoleBinding` | Regardless of what the `ClusterRole` contains, a `RoleBinding`'s own namespace scope caps what can ever be reached through it |
| `nonResourceURLs` is rejected outright in a `Role` | A loud, immediate validation error at apply time — unlike most other RBAC mistakes in this series, which apply cleanly and fail silently later |
| Built-in ClusterRoles exist so teams don't hand-write broad Roles from scratch | `view`/`edit`/`admin`/`cluster-admin` cover the most common access levels, usually applied via `RoleBinding` per namespace |
| `view` deliberately excludes Secrets | Not a bug — "read-only" in the built-in ClusterRoles does not mean every resource is readable |
| `cluster-admin` is the wildcard grant from `01`, shipped as a real object | `apiGroups: ["*"], resources: ["*"], verbs: ["*"]`, meant for `ClusterRoleBinding` only |
| Reaching for `ClusterRoleBinding` out of convenience over-provisions | Binding `admin` cluster-wide grants it in every namespace; the namespace-scoped `RoleBinding` path is almost always what's actually intended |

> **Demo scope:** Primary concept: `ClusterRole`/`ClusterRoleBinding`. Supporting concepts: the binding matrix, `nonResourceURLs` hands-on, built-in ClusterRoles.
> Estimated completion time: 55–60 minutes — flagged at the §0b sizing check as borderline, same shape as `01`; kept as one demo since all four facets are directly about the same object type.
> Checkpoints: 2 natural stopping points — after Step 3 (cluster-wide grant verified) and after Step 4 (binding-matrix distinction proven, before Break-Fix — an explicit off-ramp is called out in Step 5).

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl auth can-i <verb> <cluster-scoped-resource> --as-group=<group> --as=<user>` | Checks a cluster-scoped resource permission (no `-n` needed — it has no effect on cluster-scoped resources either way) |
| `kubectl describe clusterrole <name>` | Shows the full rule set of any ClusterRole, including the large built-in ones |
| `kubectl create clusterrolebinding <name> --clusterrole=<role> --group=<group>` | Imperatively creates a cluster-wide binding — note `--clusterrole=`, not `--role=` |

### Generating YAML skeletons with --dry-run

`kubectl` can generate a valid YAML manifest for any object it can create imperatively, without actually creating the object. This is one of the most important exam techniques for CKA/CKAD — you rarely need to write YAML from scratch when you can generate a correct skeleton and edit it. Note `nonResourceURLs` has no imperative flag at all — it always requires hand-editing the generated skeleton, same as `resourceNames` in `03`.

**Syntax:**
```bash
kubectl <create-command> <args> --dry-run=client -o yaml > filename.yaml
```

**Supported — any command that creates or modifies an object:**
```bash
kubectl create clusterrole NAME --verb=get,list,watch --resource=nodes --dry-run=client -o yaml
kubectl create clusterrolebinding NAME --clusterrole=ROLE --group=GROUP --dry-run=client -o yaml
```

**Not supported** — commands that read, describe, or operate on running objects: `kubectl get`, `describe`, `logs`, `exec`, `delete`, `apply`, `patch`, `label`

**Exam workflow:**
1. Generate the skeleton → edit what you need to change (including `nonResourceURLs`, which no imperative command sets) → `kubectl apply -f file.yaml`
2. Or pipe directly: `kubectl create clusterrole NAME --verb=get --resource=nodes --dry-run=client -o yaml | kubectl apply -f -`

### Imperative Quick-Create Commands

| Object | Imperative command | Notes |
|---|---|---|
| ClusterRole | `kubectl create clusterrole NAME --verb=get,list,watch --resource=nodes` | `nonResourceURLs` never settable imperatively |
| ClusterRoleBinding | `kubectl create clusterrolebinding NAME --clusterrole=ROLE --group=GROUP` | Or `--user=`/`--serviceaccount=`; note the flag is `--clusterrole=`, not `--role=` |

---

## Troubleshooting

**A `ClusterRole` reference applies cleanly, but a cluster-scoped resource check still fails:**
```bash
kubectl get rolebinding -n <namespace> -o yaml | grep -A2 roleRef
```
```
# Cause: the binding is a RoleBinding, not a ClusterRoleBinding — a
#        RoleBinding can never activate a cluster-scoped rule, regardless
#        of which ClusterRole it references.
# Fix: Use a ClusterRoleBinding for genuinely cluster-scoped access.
```

**`nonResourceURLs` fails to apply at all, with a validation error:**
```
# Cause: nonResourceURLs is not valid inside a namespaced Role — the API
#        server rejects it outright at admission time.
# Fix: Move the rule into a ClusterRole instead.
```

**A subject bound to `view` can't read Secrets, despite broad read access elsewhere:**
```bash
kubectl describe clusterrole view | grep -i secret
```
```
# Cause: view deliberately excludes Secrets — a documented design choice,
#        not a bug.
# Fix: If Secrets access is genuinely needed, grant it separately via a
#      custom Role/RoleBinding — do not assume view already covers it.
```

---

## Appendix — Anki Cards

**`04-clusterroles-clusterrolebindings-anki.csv`:**

```
#deck:k8s-platform-labs::12-rbac::04-clusterroles-clusterrolebindings
#separator:Comma
#columns:Front,Back,Tags
"A ClusterRole grants get on both nodes and configmaps. It's bound via an ordinary RoleBinding in namespace team-a. What access results?","get on configmaps within team-a only. The nodes rule never activates through this path — a RoleBinding is namespace-scoped regardless of which object it references, and there's no namespace a Node grant could apply to.","clusterroles,binding-matrix,cka-cluster-architecture-installation-configuration"
"Why does Kubernetes ship view/edit/admin as ClusterRoles instead of Roles, given they're normally applied to one namespace at a time?","So the same rule definition can be reused across every namespace via ordinary RoleBindings, instead of maintaining near-identical Role objects per namespace. ClusterRole + RoleBinding is a fully supported reuse pattern.","clusterroles,built-in-clusterroles,cka-cluster-architecture-installation-configuration"
"Does the built-in view ClusterRole grant read access to Secrets?","No. view deliberately excludes Secrets — a documented security design choice, not an oversight. Broad read access elsewhere doesn't imply Secrets are included.","clusterroles,view,secrets,cka-cluster-architecture-installation-configuration,ckad-application-environment-configuration-security"
"A Role (not ClusterRole) is written with a nonResourceURLs rule. What happens on apply?","The API server rejects it outright with a validation error at admission time — nonResourceURLs has no namespace to scope to, so it's invalid in a namespace-scoped Role by definition.","clusterroles,nonresourceurls,cka-cluster-architecture-installation-configuration"
"Can a ClusterRoleBinding reference a Role instead of a ClusterRole?","No. roleRef.kind must be ClusterRole in a ClusterRoleBinding — only a RoleBinding can reference either a Role or a ClusterRole.","clusterroles,clusterrolebinding,roleref,cka-cluster-architecture-installation-configuration"
"What's the practical difference between cluster-admin via ClusterRoleBinding and admin via RoleBinding in one namespace?","cluster-admin via ClusterRoleBinding grants unrestricted access everywhere, cluster-wide. admin via RoleBinding grants broad read/write and RBAC management, but strictly within that one namespace — it cannot touch other namespaces or cluster-scoped resources at all.","clusterroles,cluster-admin,admin,cka-cluster-architecture-installation-configuration"
"What does the edit built-in ClusterRole exclude that admin includes?","edit cannot view or modify RBAC objects (Roles/RoleBindings) within the namespace, and cannot modify ResourceQuotas — admin adds exactly those two capabilities on top of what edit already grants.","clusterroles,edit,admin,cka-cluster-architecture-installation-configuration"
"What imperative flag does kubectl create clusterrolebinding use to reference the ClusterRole, and how does it differ from kubectl create rolebinding?","--clusterrole=NAME, not --role=. kubectl create rolebinding uses --role= even when referencing a ClusterRole from a RoleBinding — the clusterrolebinding command specifically uses the different flag name.","clusterroles,imperative-commands,cka-cluster-architecture-installation-configuration"
"Is there an imperative flag for setting nonResourceURLs when creating a ClusterRole?","No. nonResourceURLs has no imperative flag at all — generating a skeleton with --dry-run=client -o yaml and hand-editing it is always required, the same pattern as resourceNames.","clusterroles,nonresourceurls,imperative-commands,cka-cluster-architecture-installation-configuration"
"A cluster-scoped resource check via kubectl auth can-i is run both with and without a -n flag. Does the result differ?","No. -n has no effect on a cluster-scoped resource like nodes — the check's answer is identical either way, since there's no namespace for the resource to be scoped to in the first place.","clusterroles,can-i,cluster-scoped,cka-troubleshooting"
```

## Appendix — Quiz

**`04-clusterroles-clusterrolebindings-quiz.md`:**

````markdown
# Quiz — 12-rbac/04-clusterroles-clusterrolebindings: Cluster-Scoped RBAC and Built-In ClusterRoles

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next demo.

**Q1. A ClusterRole grants `get` on both `nodes` and `configmaps`. It's bound via a `RoleBinding` in namespace `team-a`. What access results?**

- A) `get` on both `nodes` and `configmaps`, cluster-wide
- B) `get` on `configmaps` within `team-a` only; the `nodes` rule never activates through this binding
- C) The binding fails to apply entirely, since `ClusterRole` cannot be referenced by `RoleBinding`
- D) `get` on `nodes` cluster-wide, `configmaps` within `team-a` only

<details>
<summary>Answer</summary>

**B** — A `RoleBinding` is namespace-scoped regardless of what it references. Only the namespaced-resource rule activates, scoped to that namespace; the cluster-scoped `nodes` rule has no path to take effect through a `RoleBinding`.
Trap: C assumes an invalid combination — `RoleBinding` referencing a `ClusterRole` is fully valid, just limited in what it can activate. D reverses which rule actually works.

</details>

---

**Q2. Why does Kubernetes ship `view`/`edit`/`admin` as `ClusterRole`s, given they're typically applied to a single namespace?**

- A) `ClusterRole`s perform better than `Role`s for the API server
- B) So the same rule definition can be reused across every namespace via ordinary `RoleBinding`s, instead of duplicating near-identical Roles
- C) `Role`s cannot grant read access to Pods or Deployments
- D) It's a legacy naming artifact with no technical reason

<details>
<summary>Answer</summary>

**B** — Defining the rules once as a `ClusterRole` and binding it per-namespace via `RoleBinding` avoids maintaining N nearly-identical `Role` objects.
Trap: A invents a performance difference that doesn't exist. C is false — `Role`s can grant Pod/Deployment access fine, as `01` demonstrated extensively.

</details>

---

**Q3. Does the built-in `view` ClusterRole grant read access to Secrets?**

- A) Yes, `view` includes read access to every namespaced resource
- B) No — `view` deliberately excludes Secrets as a documented security choice
- C) Only if bound via `ClusterRoleBinding`, not `RoleBinding`
- D) Only for Secrets of type `Opaque`

<details>
<summary>Answer</summary>

**B** — This is a deliberate exclusion, not a gap in coverage or a binding-type quirk. A subject with only `view` cannot read Secrets regardless of how it's bound.
Trap: A is the natural but incorrect assumption this question targets. C and D both invent conditions that don't affect this exclusion.

</details>

---

**Q4. A `Role` (not `ClusterRole`) is written with a `nonResourceURLs` rule and applied. What happens?**

- A) It applies successfully but the rule is silently ignored
- B) The API server rejects it outright with a validation error
- C) It applies successfully and grants access to non-resource URLs within that namespace
- D) It's automatically converted to a `ClusterRole` on apply

<details>
<summary>Answer</summary>

**B** — Unlike most silent RBAC mistakes in this series, this one fails loudly and immediately — `nonResourceURLs` has no namespace to scope to, so a namespace-scoped `Role` can never legally contain it.
Trap: A and C both assume a silent-failure pattern that doesn't apply here — this is a validation-time rejection, not a runtime no-op. D invents behavior Kubernetes doesn't have.

</details>

---

**Q5. What's the actual difference between granting `cluster-admin` via `ClusterRoleBinding` and `admin` via `RoleBinding` in one namespace?**

- A) `cluster-admin` is unrestricted, cluster-wide; `admin` via `RoleBinding` is broad but capped to that one namespace, with no reach into cluster-scoped resources at all
- B) They're functionally identical; only the object names differ
- C) `admin` via `RoleBinding` also grants full cluster-wide access, just through a different binding path
- D) `cluster-admin` cannot be bound via `ClusterRoleBinding`, only `ClusterRole`

<details>
<summary>Answer</summary>

**A** — `cluster-admin` is the wildcard grant meant for cluster-wide use; `admin` via `RoleBinding` is intentionally namespace-capped, unable to reach other namespaces or cluster-scoped resources regardless of what the ClusterRole itself contains.
Trap: C is the exact misconception the binding-matrix concept exists to correct. D confuses the object with the binding — `cluster-admin` is a `ClusterRole`, and `ClusterRoleBinding` is exactly how it's meant to be bound.

</details>

---

**Q6. Does specifying `-n <namespace>` change the result of `kubectl auth can-i get nodes`?**

- A) Yes, it restricts the check to that namespace's view of Nodes
- B) No — `-n` has no effect on a cluster-scoped resource; the answer is identical with or without it
- C) It causes the command to fail with an error
- D) Only if the subject has `resourceNames` set

<details>
<summary>Answer</summary>

**B** — `nodes` has no namespace to begin with, so `-n` is accepted syntactically but has no bearing on the check's outcome.
Trap: A and D both invent an interaction between namespace flags and cluster-scoped resources that doesn't exist.

</details>

---

Score guide:
| Score | Action |
|---|---|
| 6/6 | Import Anki cards, move to 05-authentication-methods |
| 5/6 | Review the wrong answer, then proceed |
| 4/6 | Re-read the relevant section, retry those questions |
| Below 4/6 | Re-read the full demo and redo the walkthrough before proceeding |
````