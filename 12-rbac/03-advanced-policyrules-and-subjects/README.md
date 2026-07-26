# Demo: 12-rbac/03-advanced-policyrules-and-subjects — Composing Rules and Grouping Subjects

## Lab Overview

`01-rbac-fundamentals` built a Role with a single rule per resource type, bound to one `User`. Real Roles are rarely that simple: a single identity often needs different verb sets on different resources in one Role, sometimes scoped to one specific named object rather than every object of a type — and real teams bind Roles to entire groups of people, not one RoleBinding per engineer. This demo covers both gaps: composing a Role from multiple rules (including `resourceNames`), and the `Group` subject kind.

**Real-world scenario:** The `ci` pipeline from `01` has grown a second responsibility — reading rollout status and logs (already granted) plus reading and updating exactly one ConfigMap, `pipeline-config`, that holds its own runtime settings. It must never touch any other ConfigMap in the namespace, including one holding unrelated settings for a different tool. Separately, your platform team now has five engineers who all need the same log-reading access `01` granted to a single CI identity — creating five near-identical `RoleBinding`s doesn't scale, and a `Group` subject solves that in one object.

**What this lab covers:**
- Composing a `Role` from multiple rules, each with its own `apiGroups`/`resources`/`verbs`
- Restricting a rule to one specific named object with `resourceNames`
- The `Group` subject kind: theory, the `system:` prefix, and binding a Role to a Group instead of a User
- Verifying Group-based access with `kubectl auth can-i --as-group`

> **Scope note:** This lab does not cover `ClusterRole`/`ClusterRoleBinding` (cluster-scoped grants, built-in ClusterRoles) — that's `12-rbac/04-clusterroles-clusterrolebindings`. It does not cover authentication mechanics for how a Group actually gets attached to a real identity (OIDC claims, webhook token auth) — that's `12-rbac/05-authentication-methods`. It does not cover `api-resources`/subresource discovery — that's `12-rbac/02-rbac-discovery-and-verbs`, assumed already known here.

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
- **REQUIRED:** `12-rbac/01-rbac-fundamentals` (Role/RoleBinding/PolicyRule mechanics, `kubectl auth can-i`) and `12-rbac/02-rbac-discovery-and-verbs` (reading `kubectl api-resources` output) — neither is re-taught here

---

## Lab Objectives

By the end of this lab, you will be able to:

1. ✅ Compose a `Role` from multiple rules, each targeting a different resource with its own verb set
2. ✅ Restrict a rule to one specific named object using `resourceNames`, and explain why it can't combine with `create`
3. ✅ Explain the `Group` subject kind, including the reserved `system:` prefix
4. ✅ Bind a `Role` to a `Group` with a `RoleBinding`, and verify it with `kubectl auth can-i --as-group`
5. ✅ Diagnose and fix three common misconfigurations from symptoms alone

---

## Directory Structure

```
12-rbac/03-advanced-policyrules-and-subjects/
├── README.md
├── 03-advanced-policyrules-and-subjects-anki.csv
├── 03-advanced-policyrules-and-subjects-quiz.md
└── src/
    ├── 01-namespace-ci.yaml                     # the ci namespace used throughout this lab
    ├── 02-configmap-pipeline-config.yaml          # the ConfigMap the Role should grant access to
    ├── 03-configmap-other-config.yaml             # a second ConfigMap the Role must NOT grant access to
    ├── 04-role-multi-rule.yaml                    # multi-rule Role, includes resourceNames
    ├── 05-rolebinding-platform-team.yaml           # binds the Role to the platform-team Group
    └── break-fix/
        ├── 01-role-resourcenames-typo.yaml
        ├── 02-role-missing-second-rule.yaml
        └── 03-rolebinding-wrong-kind-group.yaml
```

---

## Recall Check — 02-rbac-discovery-and-verbs

Answer from memory before continuing — no peeking at the previous demo.

1. Does `kubectl api-resources -o wide` list a resource's subresources?
2. What two permissions does `kubectl exec` require?
3. What does `kubectl run` always create, and what permission does that require?

<details>
<summary>Answers</summary>

1. No — not at any verbosity level. Subresources only appear in the raw API discovery documents (`kubectl get --raw`).
2. `get` on `pods` (to resolve the target) and `create` on the `pods/exec` subresource — both required, neither implies the other.
3. A bare `Pod` object, never a `Deployment` — it requires `create` on `pods` in the core group.

</details>

---

## Concepts

### Composing a Role from Multiple Rules

**What it is:** A `Role`'s `rules` field is a list — nothing limits it to one entry. Each entry is independently evaluated, and a subject's effective access from that Role is the union of every rule in the list.

```yaml
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]                     # a third, unrelated rule in the same Role
  resources: ["configmaps"]
  verbs: ["get", "update"]
  resourceNames: ["pipeline-config"]
```

- **Why it exists:** A single identity's job is rarely expressible as one `apiGroups`/`resources` pair — the `ci` pipeline here needs Pods, Deployments, *and* one specific ConfigMap, three genuinely different resource types with different verb sets. One `Role` object with three rules is the natural expression of that, rather than three separate Roles bound together (which would also work, but adds objects to track for no benefit).
- **How it works:** Rules don't interact with each other — there's no ordering dependency, no "first match wins," no way for one rule to narrow another. Each is evaluated independently against the request, and if *any* rule in *any* Role/ClusterRole bound to the subject matches, the request is permitted. This is the same additive model from `01`, just visible now at the multi-rule level instead of only across multiple bindings.
- **When to combine into one Role vs. use separate Roles:** Combine when the rules genuinely belong to the same responsibility/identity (this demo's CI pipeline). Use separate Roles when different rules are conceptually different *jobs* that might need to be granted independently later — e.g. a "log reader" Role and a "config editor" Role, bound separately, so one can be revoked without touching the other. There's no mechanical difference in effect; it's a maintainability choice.

### `resourceNames` — Restricting to Specific Named Objects

**What it is:** An optional field on a `PolicyRule`, first named in `01` but not yet lab-tested there. When present, it restricts the rule to only the objects whose name matches — not every object of that resource type.

```yaml
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "update"]
  resourceNames: ["pipeline-config"]   # ONLY this ConfigMap — no other configmaps in the namespace
```

- **Why it exists:** Without `resourceNames`, granting `get`/`update` on `configmaps` grants it for *every* ConfigMap in the namespace — including ones with no relationship to the subject's actual job. `resourceNames` narrows a verb grant down to the specific object(s) that grant should actually apply to, which is a meaningfully tighter form of least-privilege than resource-type-level scoping alone.
- **How it works:** `resourceNames` is a plain list of strings, matched exactly against `metadata.name`. It's an AND with the rest of the rule, not an OR — the request must match the resource type, the verb, *and* be against one of the named objects, all three, for the rule to apply.
- **Cannot combine with `create`:** Already stated in `01`, proven here — at `create` time the object doesn't exist yet, so there is no name yet to restrict against. A rule with `resourceNames` and `verbs: ["create"]` in the same entry is not a functioning grant for `create` — the API accepts the YAML (no schema-level rejection), but `create` requests are never actually restricted by `resourceNames`, since Kubernetes has nothing to check the name against before the object exists.
- **Similar-term distinction — `resourceNames` vs. a Namespace boundary:** A namespace boundary (from `01`) restricts *which namespace* a Role's grant applies to; `resourceNames` restricts *which specific object, by name, within that already-namespace-scoped grant*. They compose — this demo's Role is scoped to `ci` (namespace) AND further scoped to `pipeline-config` specifically (resourceNames) for the ConfigMap rule.

### Groups — the Third Subject Kind, in Depth

**What it is:** `01` introduced `Group` as one of three subject kinds, alongside `User` and `ServiceAccount`, noting only that it's a plain string supplied by the authenticator. This demo goes further: how Groups are actually used to bind access to more than one identity at once, and the reserved `system:` prefix.

- **No API object, same as `User`:** There is no `kind: Group` object to `kubectl get` — a Group is nothing more than a string the authentication layer attaches to an identity alongside its username (e.g. a client certificate's Organization field, or an OIDC token's `groups` claim). RBAC never creates, validates, or even knows the full membership of a Group — it only checks whether the *current request's* identity carries a matching group string.
- **Why bind to a Group instead of repeating a RoleBinding per User:** A `RoleBinding`'s `subjects` list already supports multiple entries (from `01`), but that still means editing the RoleBinding every time someone joins or leaves the team. Binding to a Group instead means team membership is managed entirely at the authentication layer (who gets issued a certificate/token carrying that group) — the RoleBinding itself never changes as people join or leave.
- **The `system:` prefix is reserved for Kubernetes' own internal groups** — `system:masters` (implicitly bound to `cluster-admin`, built into the cluster's trust model, not visible as an ordinary ClusterRoleBinding), `system:authenticated` (every successfully authenticated identity, regardless of who they are), `system:unauthenticated`. Never name a custom Group starting with `system:` — the API server doesn't reject it outright, but it invites confusion with these reserved, cluster-critical groups, and some cluster configurations may treat the prefix specially depending on authenticator setup.
- **Worked example — decoding a Group-scoped RoleBinding:**
```yaml
subjects:
- kind: Group
  name: platform-team          # arbitrary string — no Group object exists to create
  apiGroup: rbac.authorization.k8s.io
```
This grants the bound Role to *any* identity whose authentication produced `platform-team` in its group list — five engineers with certificates carrying that Organization field all get the same access from this one binding, with zero changes to the binding itself as team membership changes.

---

## Lab Step-by-Step Guide

---

### Step 1 — Create the Namespace and ConfigMaps

**`src/01-namespace-ci.yaml`:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ci
```

**`src/02-configmap-pipeline-config.yaml`:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pipeline-config
  namespace: ci
data:
  retry-count: "3"
```

**`src/03-configmap-other-config.yaml`:**

A second, unrelated ConfigMap the Role must never grant access to:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: other-config
  namespace: ci
data:
  unrelated-setting: "true"
```

```bash
kubectl apply -f src/01-namespace-ci.yaml
kubectl apply -f src/02-configmap-pipeline-config.yaml
kubectl apply -f src/03-configmap-other-config.yaml
```
```
namespace/ci created
configmap/pipeline-config created
configmap/other-config created
```

---

### Step 2 — Write the Multi-Rule Role

**`src/04-role-multi-rule.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ci-pipeline-extended
  namespace: ci
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "update"]
  resourceNames: ["pipeline-config"]   # ONLY this ConfigMap, never other-config
```

```bash
kubectl apply -f src/04-role-multi-rule.yaml
kubectl -n ci describe role ci-pipeline-extended
```
```
Name:         ci-pipeline-extended
Labels:       <none>
Annotations:  <none>
PolicyRule:
  Resources         Non-Resource URLs  Resource Names     Verbs
  ---------         -----------------  --------------     -----
  pods/log          []                 []                 [get list watch]
  pods              []                 []                 [get list watch]
  deployments.apps  []                 []                 [get list watch]
  configmaps        []                 [pipeline-config]  [get update]
```
```
# Observation: three rules, three different resource/verb combinations, one
# Role object — this is the "composed from multiple rules" pattern from
# Concepts, now applied to a real, if small, multi-responsibility identity.
```

---

### Step 3 — Bind to a Group

**`src/05-rolebinding-platform-team.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: platform-team-ci-pipeline-extended
  namespace: ci
subjects:
- kind: Group
  name: platform-team
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: ci-pipeline-extended
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f src/05-rolebinding-platform-team.yaml
kubectl -n ci describe rolebinding platform-team-ci-pipeline-extended
```
```
Name:         platform-team-ci-pipeline-extended
Labels:       <none>
Annotations:  <none>
Role:
  Kind:  Role
  Name:  ci-pipeline-extended
Subjects:
  Kind   Name           Namespace
  ----   ----           ---------
  Group  platform-team
```
```
# Observation: the Subjects table shows Kind: Group, Name: platform-team —
# no Namespace column populated, same as a User subject in 01, since
# neither User nor Group is a real namespaced API object.
```

---

### Step 4 — Verify the `resourceNames` Scoping

**Positive case — the named ConfigMap is accessible:**
```bash
kubectl auth can-i get configmaps/pipeline-config -n ci --as-group=platform-team --as=someone
```
```
yes
```

**Negative case — a different ConfigMap of the identical resource type is not:**
```bash
kubectl auth can-i get configmaps/other-config -n ci --as-group=platform-team --as=someone
```
```
no
```
```
# Observation: identical verb, identical resource TYPE, only the specific
# object name differs — and the answer flips. This proves resourceNames
# is doing real work here, not just the resource-type-level grant from
# 01's pattern.
```

**Confirm the multi-rule composition — all three rules independently effective:**
```bash
kubectl auth can-i get pods -n ci --as-group=platform-team --as=someone
kubectl auth can-i list deployments -n ci --as-group=platform-team --as=someone
kubectl auth can-i get configmaps/pipeline-config -n ci --as-group=platform-team --as=someone
```
```
yes
yes
yes
```
```
# Note: --as-group requires --as to also be set (impersonating a group
# without impersonating some user is not a valid combination) — the
# --as value here is arbitrary since only its group membership matters
# for these checks, not the specific username.
```

---

### Step 5 — Cleanup

**(a) Demo-scoped resources:** everything created in this lab — the `ci` namespace, both ConfigMaps, the `ci-pipeline-extended` Role, and its RoleBinding — stays in place. The Break-Fix section below reuses this exact state; full teardown happens once, at the end of Break-Fix.

**(b) Cluster-scoped shared components:** None were installed in this demo.

> **Stopping here without continuing to Break-Fix in this session?** Tear down manually:
> ```bash
> kubectl delete namespace ci --ignore-not-found
> ```

---

## What You Learned

- ✅ Composed a `Role` from multiple rules, each targeting a different resource with its own verb set
- ✅ Restricted a rule to one specific named object with `resourceNames`, and confirmed live that it doesn't leak to same-type sibling objects
- ✅ Explained the `Group` subject kind, including the reserved `system:` prefix
- ✅ Bound a `Role` to a `Group` and verified it with `kubectl auth can-i --as-group`
- ✅ Diagnosed and fixed three misconfigurations from symptoms alone

**Key Takeaway:** A Role's `rules` list is exactly that — a list, unioned together with no interaction between entries — and `resourceNames` is the one place RBAC narrows a grant below "every object of a type," at the cost of needing to be re-specified if a new named object needs the same access later. Binding to a `Group` instead of individual `User`s moves membership management entirely to the authentication layer, so the RoleBinding itself never needs to change as a team's roster changes.

---

## Break-Fix

Three scenarios below. Diagnose from the symptom command output alone before opening the reveal.

**Restore known-good state before starting** (skip this if you're continuing directly from Step 4 without a break):
```bash
kubectl apply -f ../01-namespace-ci.yaml
kubectl apply -f ../02-configmap-pipeline-config.yaml
kubectl apply -f ../03-configmap-other-config.yaml
kubectl apply -f ../04-role-multi-rule.yaml
kubectl apply -f ../05-rolebinding-platform-team.yaml
```

From here on, all commands assume you're working from inside `src/break-fix/`:
```bash
cd src/break-fix/
```

### Error-1 — the named ConfigMap grant silently matches nothing

**`src/break-fix/01-role-resourcenames-typo.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ci-pipeline-extended
  namespace: ci
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "update"]
  resourceNames: ["pipleine-config"]   # typo — the actual ConfigMap is "pipeline-config"
```

```bash
kubectl apply -f 01-role-resourcenames-typo.yaml
kubectl auth can-i get configmaps/pipeline-config -n ci --as-group=platform-team --as=someone
```
```
role.rbac.authorization.k8s.io/ci-pipeline-extended configured
no
```

The Role applied without error, and the other two rules (Pods, Deployments) still work fine. Why does the ConfigMap check fail now?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `resourceNames: ["pipleine-config"]` has a typo. `resourceNames` is matched by exact string equality against `metadata.name` — there's no fuzzy matching, and the API doesn't validate that a named object with that exact name actually exists. The rule applies cleanly but never matches the real ConfigMap.
```bash
kubectl auth can-i --list -n ci --as-group=platform-team --as=someone
```
```
Resources                                       Non-Resource URLs   Resource Names      Verbs
...
configmaps                                      []                  [pipleine-config]   [get update]
...
```
```
# Observation: --list shows the typo verbatim in the Resource Names
# column — confirming directly that the Role's actual, live state
# carries the broken value, not just a description of what might be
# wrong.
```

**Fix:** Correct the typo to `pipeline-config` and reapply.

**Cascade:** This is the `resourceNames` equivalent of `01`'s `roleRef` typo and `02`'s `apiGroups: ["core"]` mistake — a silent, cleanly-applying typo that only surfaces as an unexpected `no` from `can-i`, with the other rules in the same Role masking the fact that anything is wrong at all.

</details>

**Cleanup — restore the correct Role for the next scenario:**
```bash
kubectl apply -f ../04-role-multi-rule.yaml
```

---

### Error-2 — one rule silently overwrites another

**`src/break-fix/02-role-missing-second-rule.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ci-pipeline-extended
  namespace: ci
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "update"]
  resourceNames: ["pipeline-config"]
# BUG: the "apps"/deployments rule from the working version was dropped
# entirely during an edit — not a typo inside a rule, a whole rule missing
```

```bash
kubectl apply -f 02-role-missing-second-rule.yaml
kubectl auth can-i get deployments -n ci --as-group=platform-team --as=someone
```
```
role.rbac.authorization.k8s.io/ci-pipeline-extended configured
no
```

Pods and the ConfigMap both still check out fine. Why does Deployment access disappear?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `kubectl apply` replaces the entire `rules` list with whatever the applied file contains — it doesn't merge rule-by-rule against what's already there. Whoever edited this file to "add" something (or fix a different rule) dropped the `apps`/`deployments` entry entirely, and the apply happily accepted the now-incomplete list as the object's new, complete state.
```bash
kubectl auth can-i --list -n ci --as-group=platform-team --as=someone
```
```
Resources                                       Non-Resource URLs   Resource Names      Verbs
selfsubjectreviews.authentication.k8s.io        []                  []                  [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []                  [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []                  [create]
pods/log                                        []                  []                  [get list watch]
pods                                            []                  []                  [get list watch]
configmaps                                      []                  [pipeline-config]   [get update]
...
```
```
# Observation: confirmed directly — there is no deployments.apps row
# anywhere in this list. Not a denied check, an absent one; the rule
# genuinely isn't part of the Role's live state anymore.
```

**Fix:** Restore the missing rule — re-add the `apps`/`deployments` block.

**Cascade:** This is a genuinely different failure mode from Error-1's typo — nothing here is *wrong* in the remaining rules, something is simply *absent*. It's a reminder that `kubectl apply` on a Role is a full-object replace of `rules`, not an additive patch — removing a rule from the file removes the grant from the cluster, with no warning that a previously-granted permission just disappeared.

</details>

**Cleanup — restore the correct Role for the next scenario:**
```bash
kubectl apply -f ../04-role-multi-rule.yaml
```

---

### Error-3 — Group binding applies, but nobody gets access

**`src/break-fix/03-rolebinding-wrong-kind-group.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: platform-team-ci-pipeline-extended
  namespace: ci
subjects:
- kind: User              # wrong — platform-team is meant to be a Group, not a User
  name: platform-team
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: ci-pipeline-extended
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f 03-rolebinding-wrong-kind-group.yaml
kubectl auth can-i get pods -n ci --as-group=platform-team --as=someone
kubectl auth can-i get pods -n ci --as=platform-team
```
```
⚠️ [VERIFY]
rolebinding.rbac.authorization.k8s.io/platform-team-ci-pipeline-extended configured
no
no
```

The binding applied without error, and `platform-team` is spelled correctly in both the file and the check. Why does neither check succeed?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `kind: User` and `kind: Group` are both just string-matched against whatever the authenticator supplied, but they're matched against *different* parts of that identity — a User subject matches against the request's username, a Group subject matches against the request's group list. Setting `kind: User` with `name: platform-team` means this binding now looks for a *user* literally named `platform-team` — which nobody impersonating via `--as-group=platform-team` actually is; that flag only adds `platform-team` to the group list, not the username. The binding is syntactically valid and creates cleanly, but it's checking the wrong field entirely.

**Fix:** Change `kind: User` to `kind: Group`.

**Cascade:** This is a subtle trap specifically because both `kind` values accept the identical `name` string with no error either way — there's nothing in the YAML that looks broken, and nothing in `kubectl get rolebinding` output flags the mismatch either; only a live `can-i` check against the intended impersonation reveals it.

</details>

**Cleanup — restore the correct RoleBinding, then full teardown (end of Break-Fix):**
```bash
kubectl apply -f ../05-rolebinding-platform-team.yaml
kubectl delete namespace ci --ignore-not-found
cd ../..
```

---

## Interview Prep

**Q1. A Role has three rules. Can the second rule narrow or override what the first rule grants?**
No. Rules within a Role don't interact — each is evaluated independently, and the subject's effective access is the union of all of them. There's no way for one rule to restrict, override, or cancel another; the only way to reduce what a Role grants is to remove or narrow a rule directly.

**Q2. When would you use `resourceNames` instead of just granting `get` on the whole resource type?**
When the intended access genuinely should be limited to one or a few specific objects, not every object of that type — e.g. one specific ConfigMap holding a pipeline's own settings, not every ConfigMap in the namespace. Without `resourceNames`, the grant covers every object of that resource type in the namespace, which is broader than "least privilege" usually calls for when the actual need is object-specific.

**Q3. Why can't `resourceNames` be combined with the `create` verb?**
`resourceNames` restricts a rule to matching specific existing object names, but at `create` time the object doesn't exist yet — there's no name for the API server to check against before creation happens. The combination isn't rejected at the schema level, but it has no meaningful effect on `create` requests.

**Q4. What's the actual difference between binding a Role to a `User` versus a `Group`, given both are just strings?**
They're matched against different parts of an authenticated identity — a `User` subject matches the request's username, a `Group` subject matches against the request's group membership list. A `RoleBinding` with `kind: Group` grants access to *every* identity whose authentication produced that group string, without the binding itself needing to change as membership changes; a `User` binding grants access to exactly one specific username.

**Q5. Why is the `system:` prefix reserved, and what happens if you name a custom Group starting with it anyway?**
Kubernetes uses `system:`-prefixed groups for its own internal identities and trust model — `system:masters`, `system:authenticated`, `system:unauthenticated`, and others tied to core cluster behavior. The API server doesn't outright reject a custom group using that prefix, but doing so risks confusion with these reserved groups and, depending on authenticator configuration, may interact with special handling those prefixes receive elsewhere in the cluster.

**Q6. `kubectl apply -f role.yaml` succeeds, but a permission that used to work is now gone, with no error anywhere. What's the most likely cause?**
`kubectl apply` replaces a Role's entire `rules` list with whatever the file contains — it's not an additive merge against the existing rules. If an edit to the file dropped a rule (intentionally or not), applying it removes that grant from the cluster silently; there's no diff-and-warn step that flags a rule disappearing.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Demo concept / command | CKA objective | CKAD objective | Notes |
|---|---|---|---|
| Multiple rules in one Role | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | Exam tasks combining two or more resource types in one grant expect this composition, not separate Roles |
| `resourceNames` | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | A frequently-tested least-privilege refinement beyond resource-type-level scoping |
| `Group` subject binding | Cluster Architecture, Installation & Configuration (25%) | — | Exam tasks referencing "a team" or "a group of users" expect a `Group` subject, not repeated `User` bindings |
| `kubectl auth can-i --as-group` | Troubleshooting (30%) | Application Environment, Configuration and Security (25%) | Requires pairing with `--as`; a common exam-time omission |

### Common Exam Traps

| Scenario | What the task actually requires | Common wrong approach |
|---|---|---|
| Task needs access to two different resource types for one subject | One Role, two rules | Creating two separate Roles and two RoleBindings when one Role with multiple rules is simpler and sufficient |
| "Grant access to this one specific ConfigMap only" | `resourceNames` naming that ConfigMap | Granting `get` on `configmaps` generally, which over-provisions to every ConfigMap in the namespace |
| "Grant access to a team of users" | A single `RoleBinding` with `kind: Group` | Creating one `RoleBinding` per user, or a single binding with a long `subjects` list of individually-named Users that needs editing every time membership changes |
| Editing an existing Role's rules | Confirm the full `rules` list still contains every intended rule before applying | Editing one rule in isolation without checking the file still has every other rule — `apply` replaces the whole list |

### Exam Task — Write it from scratch

**Task:** Create a Role named `config-reader` in namespace `ci` granting `get` access to exactly one ConfigMap, `app-settings` — and bind it to a Group named `sre-team`.

**Official documentation:**
- [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/) — the PolicyRule and subject field reference

**What to practise:**
1. Open the docs page — confirm `resourceNames` syntax and that `Group` is a valid `subjects[].kind` value
2. Identify the required fields: `resources`, `verbs`, `resourceNames` on the Role; `kind: Group` on the RoleBinding subject
3. Generate the Role skeleton: `kubectl create role config-reader -n ci --verb=get --resource=configmaps --dry-run=client -o yaml > task.yaml`
4. Hand-edit `task.yaml` to add `resourceNames: ["app-settings"]` — `kubectl create role` cannot set `resourceNames` imperatively
5. Write the RoleBinding by hand (no `--group` support gap here — `kubectl create rolebinding --group=` does work) and apply both

<details>
<summary>Reference solution (open only after attempting)</summary>

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: config-reader
  namespace: ci
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get"]
  resourceNames: ["app-settings"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: sre-team-config-reader
  namespace: ci
subjects:
- kind: Group
  name: sre-team
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: config-reader
  apiGroup: rbac.authorization.k8s.io
```

**Fields you must know without looking up:**
- `resourceNames` is never set by `kubectl create role` — always a manual edit after generating the skeleton
- `kind: Group` on a subject, not `kind: User` — easy to leave at the imperative command's default if you don't explicitly use `--group=`
- `resourceNames` takes a list of strings even for one object — `resourceNames: ["app-settings"]`, not a bare string

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| A Role's `rules` list is unioned, not layered | No rule can override, narrow, or interact with another — effective access is the sum of every rule |
| `resourceNames` narrows a grant to specific named objects | Without it, a verb/resource grant applies to every object of that type in the namespace |
| `resourceNames` cannot combine meaningfully with `create` | The object doesn't exist yet at create time, so there's no name to check against |
| `kubectl apply` replaces a Role's entire `rules` list | Not an additive merge — dropping a rule from the file silently removes that grant, with no warning |
| `Group` and `User` subjects match different parts of an identity | `User` matches the request's username; `Group` matches its group membership list — same string field shape, different match target |
| The `system:` prefix is reserved for Kubernetes' own internal groups | Never name a custom Group with it — invites confusion with `system:masters`/`system:authenticated`/`system:unauthenticated` |
| Binding to a Group moves membership management to the authentication layer | The RoleBinding itself never changes as team membership changes — unlike repeating or editing `User` entries |
| `--as-group` requires `--as` to also be set | Impersonating a group with no impersonated user is not a valid combination |
| `resourceNames` composes with namespace scope, not replaces it | A Role is still namespace-scoped first; `resourceNames` narrows further within that namespace |

> **Demo scope:** Primary concept: PolicyRule composition (multiple rules, `resourceNames`) paired with the `Group` subject kind. Supporting concepts: `kubectl apply`'s full-replace semantics on `rules`, `--as-group` impersonation.
> Estimated completion time: 55–60 minutes — flagged at the §0b sizing check as borderline given two related-but-distinct concept threads; kept as one demo per confirmed scope decision.
> Checkpoints: 2 natural stopping points — after Step 3 (Role + RoleBinding created, before verification) and after Step 4 (verification complete, before Break-Fix — an explicit off-ramp is called out in Step 5).

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl auth can-i <verb> <resource>/<name> -n <namespace> --as-group=<group> --as=<user>` | Checks a Group-impersonated identity's access to a specific named object |
| `kubectl -n <namespace> describe role <name>` | Shows all rules in a Role, including `resourceNames` per rule |
| `kubectl create rolebinding <name> --role=<role> --group=<group> -n <namespace>` | Imperatively creates a Group-bound RoleBinding |

### Generating YAML skeletons with --dry-run

`kubectl` can generate a valid YAML manifest for any object it can create imperatively, without actually creating the object. This is one of the most important exam techniques for CKA/CKAD — you rarely need to write YAML from scratch when you can generate a correct skeleton and edit it. Note `resourceNames` has no imperative flag at all — it always requires hand-editing the generated skeleton.

**Syntax:**
```bash
kubectl <create-command> <args> --dry-run=client -o yaml > filename.yaml
```

**Supported — any command that creates or modifies an object:**
```bash
# RBAC (this demo's objects)
kubectl create role NAME --verb=get,update --resource=configmaps --dry-run=client -o yaml
kubectl create rolebinding NAME --role=ROLE --group=GROUP --dry-run=client -o yaml

# ConfigMap
kubectl create configmap NAME --from-literal=KEY=VALUE --dry-run=client -o yaml
```

**Not supported** — commands that read, describe, or operate on running objects: `kubectl get`, `describe`, `logs`, `exec`, `delete`, `apply`, `patch`, `label`

**Exam workflow:**
1. Generate the skeleton → edit what you need to change (including adding `resourceNames`, which no imperative command sets) → `kubectl apply -f file.yaml`
2. Or pipe directly: `kubectl create role NAME --verb=get --resource=configmaps --dry-run=client -o yaml | kubectl apply -f -`

### Imperative Quick-Create Commands

Commands for creating this demo's key objects without YAML — useful under exam time pressure. Full `--dry-run=client -o yaml` skeleton generation is shown for each (see section above).

| Object | Imperative command | Notes |
|---|---|---|
| ConfigMap | `kubectl create configmap NAME --from-literal=KEY=VALUE -n NAMESPACE` | Multiple `--from-literal` flags allowed |
| Role | `kubectl create role NAME --verb=get,update --resource=configmaps` | `resourceNames` never settable imperatively — always a manual edit afterward |
| RoleBinding (Group) | `kubectl create rolebinding NAME --role=ROLE --group=GROUP -n NAMESPACE` | Distinct from `--user=`/`--serviceaccount=` — all three combinable in one call |

---

## Troubleshooting

**A grant that used to work is gone, with no error anywhere:**
```bash
kubectl -n <namespace> describe role <name>
```
```
# Cause: kubectl apply replaces a Role's entire rules list — an edit that
#        dropped a rule removes that grant silently.
# Fix: Compare the full rules list against what should be there; restore
#      any missing rule and reapply.
```

**`can-i` says `no` for a specific named object, but `yes` for the resource type generally isn't even being tested:**
```bash
kubectl -n <namespace> get role <name> -o jsonpath='{.rules}'
```
```
# Cause: a resourceNames entry likely has a typo or references a
#        different object name than the one you're checking.
# Fix: Confirm the exact object name with `kubectl get <resource> -n <namespace>`
#      and compare character-for-character against resourceNames.
```

**Group-based access doesn't work even though the RoleBinding looks correct:**
```bash
kubectl -n <namespace> describe rolebinding <name>
```
```
# Cause: the subject's kind is likely User instead of Group (or vice
#        versa) — both accept the identical name string with no error,
#        but match against different parts of an identity.
# Fix: Confirm Kind: Group in the describe output, and that --as-group
#      (not just --as) is used when testing.
```

---

## Appendix — Anki Cards

**`03-advanced-policyrules-and-subjects-anki.csv`:**

```
#deck:k8s-platform-labs::12-rbac::03-advanced-policyrules-and-subjects
#separator:Comma
#columns:Front,Back,Tags
"A Role has three rules. Can the second rule narrow or override what the first grants?","No. Rules within a Role don't interact — each is evaluated independently, and effective access is the union of all of them.","advanced-policyrules,multi-rule,cka-cluster-architecture-installation-configuration"
"When would you use resourceNames instead of granting access to a whole resource type?","When access should be limited to one or a few specific named objects, not every object of that type — resourceNames narrows a grant below resource-type-level scoping.","advanced-policyrules,resourcenames,ckad-application-environment-configuration-security"
"Why can't resourceNames be combined meaningfully with the create verb?","At create time the object doesn't exist yet, so there's no name for the API server to check the request against. The combination isn't rejected, but has no restrictive effect on create.","advanced-policyrules,resourcenames,cka-cluster-architecture-installation-configuration"
"What's the actual difference between a User subject and a Group subject in a RoleBinding, given both are just strings?","User matches the request's username; Group matches its group membership list. Same field shape (a plain string), different part of the identity being matched.","advanced-policyrules,subjects,groups,cka-cluster-architecture-installation-configuration"
"Why is binding to a Group preferable to listing five individual Users in a RoleBinding's subjects for a five-person team?","Because Group membership is managed entirely at the authentication layer — the RoleBinding itself never needs editing as people join or leave the team, unlike a subjects list of individual Users.","advanced-policyrules,groups,best-practice,ckad-application-environment-configuration-security"
"What is the system: prefix reserved for in Kubernetes Group names?","Kubernetes' own internal groups — system:masters, system:authenticated, system:unauthenticated, and others tied to core cluster trust. Custom groups should never use this prefix.","advanced-policyrules,groups,system-prefix,cka-cluster-architecture-installation-configuration"
"You edit a Role's YAML, fixing one rule, and reapply. A permission from a DIFFERENT rule that wasn't touched is now gone. Why?","kubectl apply replaces the entire rules list with the file's contents — it's not an additive merge. If the edit accidentally dropped a rule, that grant disappears silently on apply.","advanced-policyrules,kubectl-apply,cka-troubleshooting"
"Does kubectl auth can-i --as-group work without also specifying --as?","No. --as-group requires --as to also be set — impersonating a group with no impersonated user is not a valid combination.","advanced-policyrules,as-group,impersonation,cka-troubleshooting"
"A RoleBinding sets kind: User with name: platform-team, but platform-team is meant to be a Group. What happens?","It creates successfully with no error, but grants nothing to anyone using --as-group=platform-team — the binding is checking the username field, not the group membership field, even though the string is spelled correctly.","advanced-policyrules,subjects,groups,cka-troubleshooting"
"Can kubectl create role set resourceNames imperatively?","No. resourceNames has no imperative flag — generating a skeleton with --dry-run=client -o yaml and then hand-editing it to add resourceNames is always required.","advanced-policyrules,imperative-commands,resourcenames,cka-cluster-architecture-installation-configuration"
"A Role's resourceNames entry has a typo — it lists pipleine-config instead of the real ConfigMap pipeline-config. Does kubectl apply catch this?","No. resourceNames is matched by exact string equality against the object's actual name, with no validation that a matching object exists. The rule applies cleanly; the only symptom is that a can-i check against the real object name returns no, identical to the rule never having been written.","advanced-policyrules,resourcenames,troubleshooting,cka-troubleshooting"
"When should multiple PolicyRules live in one Role versus being split across separate Roles bound independently?","Combine them when the rules genuinely belong to one responsibility/identity. Use separate Roles when the rules represent conceptually different jobs that might need to be granted or revoked independently later — there's no mechanical difference in effect, it's purely a maintainability choice.","advanced-policyrules,multi-rule,best-practice,cka-cluster-architecture-installation-configuration"
"What's the imperative flag for binding a RoleBinding to a Group instead of a User?","--group=GROUP_NAME on kubectl create rolebinding, e.g. kubectl create rolebinding NAME --role=ROLE --group=GROUP -n NAMESPACE — distinct from --user= and --serviceaccount=, and combinable with either in the same call.","advanced-policyrules,groups,imperative-commands,ckad-application-environment-configuration-security"
"What's the difference between what a Role's namespace scope restricts and what resourceNames restricts, given both are forms of narrowing?","Namespace scope restricts WHICH NAMESPACE the grant applies to at all — a Role can't reach outside it regardless of resourceNames. resourceNames then further restricts WHICH SPECIFIC NAMED OBJECT within that already-namespace-scoped grant is covered. They compose rather than substitute for each other.","advanced-policyrules,resourcenames,namespace-scope,cka-cluster-architecture-installation-configuration"
```

## Appendix — Quiz

**`03-advanced-policyrules-and-subjects-quiz.md`:**

````markdown
# Quiz — 12-rbac/03-advanced-policyrules-and-subjects: Composing Rules and Grouping Subjects

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next demo.

**Q1. A Role has three rules. Can the third rule narrow what the first rule grants?**

- A) Yes, later rules override earlier ones
- B) No — rules don't interact; effective access is the union of all of them
- C) Only if the third rule uses the same `apiGroups`
- D) Only if `resourceNames` is present

<details>
<summary>Answer</summary>

**B** — Rules within a Role are evaluated independently and unioned together. There's no ordering dependency and no rule can narrow or cancel another.
Trap: A and C both invent an interaction mechanism that doesn't exist in RBAC's additive model.

</details>

---

**Q2. When is `resourceNames` the right tool, versus just granting access to a whole resource type?**

- A) When access should be limited to specific named objects, not every object of that type
- B) Whenever more than one object of a type exists
- C) `resourceNames` is required for every RBAC rule
- D) Only for cluster-scoped resources

<details>
<summary>Answer</summary>

**A** — `resourceNames` narrows a grant to one or more specific objects by name, appropriate when the actual need is object-specific rather than type-wide.
Trap: B and C both wildly overstate when it's needed — most rules never use it.

</details>

---

**Q3. Why doesn't `resourceNames` meaningfully restrict a rule that also grants `create`?**

- A) `create` and `resourceNames` are mutually exclusive and rejected at apply time
- B) At create time the object doesn't exist yet, so there's no name to check the request against
- C) `resourceNames` only applies to `delete` and `update`
- D) `create` always requires cluster-admin regardless of `resourceNames`

<details>
<summary>Answer</summary>

**B** — There's no schema-level rejection, but the combination has no restrictive effect on `create` requests specifically, since the check requires a name to compare against that doesn't exist pre-creation.
Trap: A assumes a validation error that doesn't happen — the YAML applies fine, it just doesn't do what might be expected.

</details>

---

**Q4. What's the structural difference between a `User` subject and a `Group` subject in a RoleBinding?**

- A) `Group` requires a real API object; `User` does not
- B) They match against different parts of an authenticated identity — username vs. group membership — despite both being plain strings
- C) `Group` subjects can only be used in `ClusterRoleBinding`, never `RoleBinding`
- D) There is no difference; they're interchangeable

<details>
<summary>Answer</summary>

**B** — Same string field shape, different match target: `User` matches the request's username, `Group` matches its group list.
Trap: A reverses reality — neither has a backing API object. C is false; both work in namespaced `RoleBinding`s, as this demo shows.

</details>

---

**Q5. Why is binding a Role to a `Group` preferable to listing five individual `User`s for a five-person team?**

- A) Group bindings are faster for the API server to evaluate
- B) Team membership is managed at the authentication layer — the RoleBinding itself never needs editing as membership changes
- C) `Group` subjects support more verbs than `User` subjects
- D) There's no actual benefit; it's purely stylistic

<details>
<summary>Answer</summary>

**B** — Whoever's certificate/token carries the group string gets the access; the binding object stays untouched as people join or leave, unlike editing a `subjects` list per person.
Trap: A and C invent technical advantages that don't exist — the benefit is operational (maintenance), not performance or capability.

</details>

---

**Q6. What is the `system:` prefix reserved for in Group names?**

- A) Nothing — it's just a naming convention teams can also use
- B) Kubernetes' own internal groups, like `system:masters` and `system:authenticated`
- C) Groups that only work with `ClusterRoleBinding`
- D) A required prefix for every custom Group

<details>
<summary>Answer</summary>

**B** — Reserved for Kubernetes' own internal trust model. Custom groups should avoid it to prevent confusion with these cluster-critical groups.
Trap: A downplays a real reservation that should be respected. D inverts the rule entirely.

</details>

---

**Q7. You edit a Role's YAML to fix one rule, reapply, and a completely different, untouched-seeming permission disappears. Why?**

- A) `kubectl apply` merges rule-by-rule, so this shouldn't happen
- B) `kubectl apply` replaces the entire `rules` list with the file's contents — if the edit accidentally dropped a rule, that grant is gone
- C) Roles have a maximum of two rules, and a third was silently discarded
- D) RBAC rules expire automatically after being unused

<details>
<summary>Answer</summary>

**B** — `apply` performs a full replace on `rules`; there's no partial merge. A rule missing from the file is a rule removed from the cluster object.
Trap: A describes the intuitive-but-wrong mental model this question specifically targets. C and D invent limits/behaviors that don't exist.

</details>

---

**Q8. Does `kubectl auth can-i --as-group=platform-team` work on its own, without `--as`?**

- A) Yes, `--as-group` is fully independent
- B) No — `--as-group` requires `--as` to also be specified
- C) Only for `ClusterRole`-based checks
- D) Only if the group is `system:authenticated`

<details>
<summary>Answer</summary>

**B** — Impersonating a group with no impersonated user isn't a valid combination; `--as` must be set alongside it.
Trap: A assumes independence that isn't how impersonation flags compose.

</details>

---

**Q9. A Role's `resourceNames` entry has a typo — `pipleine-config` instead of the real ConfigMap `pipeline-config`. Does `kubectl apply` catch this?**

- A) Yes — the API server validates `resourceNames` against existing object names
- B) No — `resourceNames` is matched by exact string equality with no existence check; the rule applies cleanly but matches nothing real
- C) No, but only because ConfigMaps are exempt from `resourceNames` validation
- D) Yes, but only in strict schema validation mode

<details>
<summary>Answer</summary>

**B** — Just like a typo'd `roleRef.name` in `01`, a `resourceNames` typo applies without error. There's no existence check against real object names at apply time — the only symptom is a `can-i` check against the real object returning `no`, identical to the rule never having been written at all.
Trap: A and D both invent a validation step the API server doesn't perform for `resourceNames`. C singles out ConfigMaps for no reason — the behavior is the same for any resource type.

</details>

---

Score guide:
| Score | Action |
|---|---|
| 9/9 | Import Anki cards, move to 04-clusterroles-clusterrolebindings |
| 8/9 | Review the wrong answer, then proceed |
| 6–7/9 | Re-read the relevant section, retry those questions |
| Below 6/9 | Re-read the full demo and redo the walkthrough before proceeding |
````