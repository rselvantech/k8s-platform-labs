# Demo: 12-rbac/07-aggregated-clusterroles — Composing ClusterRoles Automatically

## Lab Overview

`04` covered the built-in `view`/`edit`/`admin` ClusterRoles as if they were simply large, hand-maintained rule lists. They aren't. All three are **aggregated** ClusterRoles — their `rules` field is entirely computed by a controller, continuously recomputed from every ClusterRole in the cluster carrying a specific label. This is exactly how a newly-installed CRD operator can grant itself into `view`/`edit`/`admin` without anyone editing those objects by hand — and it's a pattern worth using for your own ClusterRoles too, not just Kubernetes' built-in ones.

**Real-world scenario:** Your platform team keeps installing CRD-based operators (this series' `11-auto-scaling` demos installed several). Every time one lands, someone has to remember to grant the platform team read/write access to its new resource types — a manual step that gets forgotten. Instead, you'll build one `platform-operator` ClusterRole that automatically absorbs the rules from any ClusterRole labeled to opt into it — so installing a new operator's correctly-labeled ClusterRole is the only step needed, ever again.

**What this lab covers:**
- The `aggregationRule`/`clusterRoleSelectors` mechanism: how an aggregate ClusterRole's `rules` gets computed, not written
- Proving live that the aggregate ClusterRole updates automatically when a new matching ClusterRole appears — no edit, no reapply of the aggregate itself
- The real labeling convention behind `view`/`edit`/`admin` (`rbac.authorization.k8s.io/aggregate-to-{view,edit,admin}`), and using it directly
- Why aggregation only ever combines other ClusterRoles — never a namespaced `Role`

> **Scope note:** This lab assumes `04-clusterroles-clusterrolebindings`'s ClusterRole/ClusterRoleBinding mechanics and built-in-ClusterRole content — it doesn't re-teach either, only extends them.

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
- **REQUIRED:** `12-rbac/04-clusterroles-clusterrolebindings` (ClusterRole/ClusterRoleBinding mechanics, built-in ClusterRoles)

---

## Lab Objectives

By the end of this lab, you will be able to:

1. ✅ Write an `aggregationRule` using `clusterRoleSelectors` to combine other ClusterRoles' rules automatically
2. ✅ Prove live that an aggregate ClusterRole's `rules` field updates on its own when a new matching ClusterRole appears
3. ✅ Use the real `rbac.authorization.k8s.io/aggregate-to-{view,edit,admin}` labels to extend a built-in ClusterRole without editing it
4. ✅ Explain why an aggregate ClusterRole's `rules` field should never be hand-edited directly
5. ✅ Diagnose and fix three common aggregation misconfigurations from symptoms alone

---

## Directory Structure

```
12-rbac/07-aggregated-clusterroles/
├── README.md
├── 07-aggregated-clusterroles-anki.csv
├── 07-aggregated-clusterroles-quiz.md
└── src/
    ├── 01-clusterrole-widgets-viewer.yaml        # a small, labeled child ClusterRole
    ├── 02-clusterrole-platform-operator.yaml      # the aggregate ClusterRole, selecting by label
    ├── 03-clusterrole-widgets-editor.yaml         # a SECOND child, added after the aggregate exists
    ├── 04-clusterrolebinding-platform-team.yaml    # binds the aggregate to the platform-team Group
    └── break-fix/
        ├── 01-clusterrole-label-mismatch.yaml
        ├── 02-manual-rules-edit-attempt.yaml
        └── 03-role-labeled-for-aggregation.yaml
```

---

## Recall Check — 06-service-accounts-rbac

Answer from memory before continuing — no peeking at the previous demo.

1. Must a RoleBinding's ServiceAccount subject live in the same namespace as the RoleBinding itself?
2. What does `automountServiceAccountToken: false` actually do, and how does the resulting failure differ from an RBAC `Forbidden`?
3. What subresource does `kubectl create token` use to mint a ServiceAccount token?

<details>
<summary>Answers</summary>

1. No — the RoleBinding must share a namespace with the Role it references, but its subject can be a ServiceAccount from any namespace.
2. It stops the projected token from being mounted at all — no credential exists for the client to authenticate with, so the failure happens before AuthN is even attempted, not at the Authorization stage.
3. `serviceaccounts/token` — the TokenRequest API mechanism.

</details>

---

## Concepts

### `aggregationRule` — a ClusterRole Whose Rules Are Computed, Not Written

**What it is:** An optional field on `ClusterRole` that, when present, tells a controller to continuously compute this ClusterRole's `rules` from every *other* ClusterRole matching a label selector — rather than the author writing `rules` directly.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-operator
aggregationRule:
  clusterRoleSelectors:
  - matchLabels:
      rbac.example.com/aggregate-to-platform-operator: "true"
rules: []    # deliberately empty — the controller populates this; do not write rules here
```

- **Why it exists:** Without aggregation, extending a broad role (like granting the platform team access to a newly-installed CRD) means editing that broad role's `rules` directly every time — fragile, easy to forget, and requires whoever maintains the platform-operator ClusterRole to know about every operator anyone ever installs. Aggregation inverts this: each CRD/operator ships its own small ClusterRole, labeled to opt in, and the broad role absorbs it automatically.
- **How it works:** A controller inside `kube-controller-manager` watches every ClusterRole in the cluster. Whenever one is created, updated, or deleted, it re-evaluates every aggregate ClusterRole's `clusterRoleSelectors` against the current set, and rewrites the aggregate's `rules` field to be the union of every matching ClusterRole's own rules. This is continuous and automatic — not a one-time computation at creation.
- **The `rules` field on an aggregate ClusterRole is not yours to write:** anything you put there manually is a starting value at best — the controller will overwrite it on the next reconciliation pass regardless, since the field is meant to be fully computed. Writing it as `rules: []` (or omitting it) is the honest representation of "this field isn't authored here."

### The Real Convention Behind `view`/`edit`/`admin`

**What it is:** `04`'s built-in ClusterRoles are themselves aggregate ClusterRoles, using a documented, reserved label convention:

| Label | Aggregates into |
|---|---|
| `rbac.authorization.k8s.io/aggregate-to-view: "true"` | `view` |
| `rbac.authorization.k8s.io/aggregate-to-edit: "true"` | `edit` |
| `rbac.authorization.k8s.io/aggregate-to-admin: "true"` | `admin` |

- **`cluster-admin` is deliberately NOT aggregated** — it's a fixed, hand-written `apiGroups: ["*"], resources: ["*"], verbs: ["*"]` wildcard (per `04`), and a wildcard has nothing meaningful to aggregate into it.
- **Why this matters practically:** any CRD operator's installation manifest can ship a small ClusterRole labeled `rbac.authorization.k8s.io/aggregate-to-view: "true"` (read-only) and/or `...-to-edit: "true"` (read/write), and every subject already bound to the real, built-in `view`/`edit` ClusterRoles automatically gains access to the new CRD — with zero edits to `view`/`edit` themselves, ever. This is the mechanism, not a convention layered on top of something else.
- **Aggregation can chain:** an aggregate ClusterRole can itself carry an aggregation label for a *different* aggregate ClusterRole, letting one small ClusterRole's rules flow into multiple broader roles at once, several levels deep if needed.

### Aggregation Is ClusterRole-Only

**What it is:** `clusterRoleSelectors` matches against `ClusterRole` objects specifically — there's no equivalent mechanism for aggregating namespaced `Role` objects into anything.

- **Why:** Aggregation exists to solve a cluster-wide composition problem (built-in roles, cluster-wide operator access) — `Role`'s namespace-scoped nature makes "aggregate this Role's rules into a cluster-wide ClusterRole" a conceptually different operation than what this field does, so it was never built to support it. Labeling a `Role` with an aggregation label does nothing — `clusterRoleSelectors` simply never looks at `Role` objects at all, regardless of labels.

---

## Lab Step-by-Step Guide

This lab builds the aggregate ClusterRole first with one matching child, proves the composition happened, then adds a *second* child afterward specifically to prove the aggregate updates itself with no further action — that live, after-the-fact update is the entire point of this mechanism, not just the initial composition.

---

### Step 1 — Create the First Child ClusterRole

A small, focused ClusterRole granting read access to a hypothetical CRD, labeled to opt into the aggregate we're about to build.

**`src/01-clusterrole-widgets-viewer.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: widgets-viewer
  labels:
    rbac.example.com/aggregate-to-platform-operator: "true"
rules:
- apiGroups: ["example.com"]
  resources: ["widgets"]
  verbs: ["get", "list", "watch"]
```

```bash
kubectl apply -f src/01-clusterrole-widgets-viewer.yaml
```
```
⚠️ [VERIFY]
```

---

### Step 2 — Create the Aggregate ClusterRole

Note there's no `rules` content to write here at all — only the selector.

**`src/02-clusterrole-platform-operator.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-operator
aggregationRule:
  clusterRoleSelectors:
  - matchLabels:
      rbac.example.com/aggregate-to-platform-operator: "true"
rules: []
```

```bash
kubectl apply -f src/02-clusterrole-platform-operator.yaml
kubectl describe clusterrole platform-operator
```
```
⚠️ [VERIFY]
```
```
# Observation: expect the PolicyRule table to show the widgets get/list/
# watch rule from Step 1, even though this file's own rules field was
# empty — that's the controller having already computed it from the
# matching ClusterRole.
```

---

### Step 3 — Add a Second Child, After the Fact

This is the step that actually proves aggregation is live and continuous, not a one-time computation.

**`src/03-clusterrole-widgets-editor.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: widgets-editor
  labels:
    rbac.example.com/aggregate-to-platform-operator: "true"
rules:
- apiGroups: ["example.com"]
  resources: ["widgets"]
  verbs: ["create", "update", "patch", "delete"]
```

```bash
kubectl apply -f src/03-clusterrole-widgets-editor.yaml
kubectl describe clusterrole platform-operator
```
```
⚠️ [VERIFY]
```
```
# Observation: platform-operator itself was never touched — no apply,
# no edit — and its rules should now show BOTH the read verbs from
# widgets-viewer AND the write verbs from widgets-editor, unioned. This
# is the mechanism actually doing its job: a new correctly-labeled
# ClusterRole appeared, and the aggregate absorbed it automatically.
```

---

### Step 4 — Bind and Verify

**`src/04-clusterrolebinding-platform-team.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-team-operator
subjects:
- kind: Group
  name: platform-team
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: platform-operator
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f src/04-clusterrolebinding-platform-team.yaml
kubectl auth can-i get widgets.example.com --as-group=platform-team --as=someone
kubectl auth can-i delete widgets.example.com --as-group=platform-team --as=someone
```
```
⚠️ [VERIFY]
yes
yes
```
```
# Observation: both the read and write grants are active for platform-team
# — composed entirely from the two small, independently-authored child
# ClusterRoles, via the one aggregate binding.
```

**Confirm the real built-in convention works identically — label a ClusterRole to extend `view` directly:**
```bash
kubectl label clusterrole widgets-viewer rbac.authorization.k8s.io/aggregate-to-view=true
kubectl describe clusterrole view | grep -A3 widgets
```
```
⚠️ [VERIFY]
```
```
# Observation: the same widgets-viewer ClusterRole, now ALSO labeled for
# the real built-in "view" — expect its rule to show up inside `view`
# itself, proving this is the exact same mechanism `04` used, not a
# separate custom system built for this demo.
```

---

### Step 5 — Cleanup

**(a) Demo-scoped resources:** the three custom ClusterRoles and the ClusterRoleBinding stay in place; Break-Fix reuses this state.

**(b) Cluster-scoped shared components:** the label added to `widgets-viewer` for the real `view` ClusterRole should be removed before final cleanup, since it affects a shared, built-in object's *composition* (not the object itself) — leaving it in place would mean `view` keeps granting `widgets` access after this demo's own ClusterRole is deleted, until Kubernetes' garbage collection catches up or the label is removed.

> **Stopping here without continuing to Break-Fix in this session?** Tear down manually:
> ```bash
> kubectl label clusterrole widgets-viewer rbac.authorization.k8s.io/aggregate-to-view-
> kubectl delete clusterrolebinding platform-team-operator --ignore-not-found
> kubectl delete clusterrole platform-operator widgets-viewer widgets-editor --ignore-not-found
> ```

---

## What You Learned

- ✅ Wrote an `aggregationRule` combining other ClusterRoles' rules automatically via label selection
- ✅ Proved live that adding a new matching ClusterRole updates the aggregate with no further action
- ✅ Used the real `aggregate-to-view` label to extend a built-in ClusterRole directly
- ✅ Explained why an aggregate ClusterRole's `rules` field is controller-computed, not hand-authored
- ✅ Diagnosed and fixed three aggregation misconfigurations from symptoms alone

**Key Takeaway:** Aggregation turns "extend this broad role" from an edit into a label. The aggregate ClusterRole's `rules` field is never something you author directly — it's the continuously-recomputed union of every ClusterRole currently matching its selector, which is exactly the mechanism `view`/`edit`/`admin` already use for every resource type they cover. The moment a new ClusterRole appears carrying the right label, every subject already bound to the aggregate gains that access, with no further changes anywhere.

---

## Break-Fix

Three scenarios below. Diagnose from the symptom command output alone before opening the reveal.

**Restore known-good state before starting** (skip if continuing directly from Step 4):
```bash
kubectl apply -f ../01-clusterrole-widgets-viewer.yaml
kubectl apply -f ../02-clusterrole-platform-operator.yaml
kubectl apply -f ../03-clusterrole-widgets-editor.yaml
kubectl apply -f ../04-clusterrolebinding-platform-team.yaml
```
```bash
cd src/break-fix/
```

### Error-1 — the label value doesn't match, and nothing merges

**`src/break-fix/01-clusterrole-label-mismatch.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: widgets-approver
  labels:
    rbac.example.com/aggregate-to-platform-operator: "True"   # wrong — "True" ≠ "true", label values are exact-match strings
rules:
- apiGroups: ["example.com"]
  resources: ["widgets/approval"]
  verbs: ["create"]
```

```bash
kubectl apply -f 01-clusterrole-label-mismatch.yaml
kubectl describe clusterrole platform-operator | grep widgets
```
```
⚠️ [VERIFY]
clusterrole.rbac.authorization.k8s.io/widgets-approver created
```

The new ClusterRole exists. Why doesn't `platform-operator` pick up its `widgets/approval` rule?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** Label values are matched by exact string equality, case included. `"True"` and `"true"` are different strings as far as `matchLabels` is concerned — the selector never matches, so this ClusterRole is invisible to the aggregation controller, with no error anywhere; the object itself is completely valid on its own.

**Fix:** Correct the label value to `"true"` (lowercase) and the aggregate will pick it up on the next reconciliation, with no further action needed on `platform-operator` itself.

**Cascade:** This is the label-based equivalent of every silent-typo failure elsewhere in this series (`roleRef`, `apiGroups`) — the object creates cleanly, and the only symptom is an absence: a rule that should be there, isn't, with nothing pointing at why.

</details>

**Cleanup:**
```bash
kubectl delete clusterrole widgets-approver --ignore-not-found
```

---

### Error-2 — manually editing the aggregate's `rules` gets silently reverted

```bash
kubectl edit clusterrole platform-operator
# (interactively add a new rule directly to `rules`, save and exit)
kubectl describe clusterrole platform-operator
```
```
⚠️ [VERIFY — this requires an interactive kubectl edit session to
reproduce; run it and confirm whether the manually-added rule persists
or is reverted on the next describe]
```

If you added a rule by hand and it's already gone by the time `describe` runs again, what happened?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `platform-operator` has `aggregationRule` set, which means its `rules` field is owned by the aggregation controller, not by whoever last applied/edited it. The controller reconciles continuously — a manual edit to `rules` survives only until the next reconciliation pass recomputes the field from the actual matching ClusterRoles, at which point the hand-added rule is overwritten with no warning.

**Fix:** There is no fix that keeps a hand-edited rule in an aggregate ClusterRole — if a rule genuinely needs to be part of `platform-operator`, it must live in a ClusterRole carrying the matching label, not be added directly.

**Cascade:** This is a fundamentally different kind of "silent failure" from everything else in this series — not a typo that never matches, but a successful edit that doesn't stick, because the field being edited was never meant to be authored directly in the first place. Recognizing `aggregationRule`'s presence is the signal that `rules` on that object is read-only in practice, even though nothing in the schema itself technically blocks writing to it.

</details>

**Cleanup:** none needed — the controller already reverted the manual edit on its own.

---

### Error-3 — labeling a `Role` the same way does nothing

**`src/break-fix/03-role-labeled-for-aggregation.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role                        # BUG: aggregation only ever looks at ClusterRoles
metadata:
  name: widgets-namespaced-viewer
  namespace: ci
  labels:
    rbac.example.com/aggregate-to-platform-operator: "true"
rules:
- apiGroups: ["example.com"]
  resources: ["widgets"]
  verbs: ["get"]
```

```bash
kubectl apply -f 03-role-labeled-for-aggregation.yaml
kubectl describe clusterrole platform-operator | grep -c widgets
```
```
⚠️ [VERIFY]
role.rbac.authorization.k8s.io/widgets-namespaced-viewer created
```

The label is spelled identically to the working examples. Why does `platform-operator` never reflect this Role's rule?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `clusterRoleSelectors` only ever evaluates `ClusterRole` objects — a `Role`, regardless of its labels, is invisible to it entirely. This isn't a matching failure to debug; it's a structural fact about what the field looks at. There is no version of `aggregationRule` that can absorb a namespaced `Role`'s rules, by design.

**Fix:** If this rule genuinely needs to be part of `platform-operator`, it has to be rewritten as a `ClusterRole` with the same label — a `Role` can never participate in aggregation, however it's labeled.

**Cascade:** Worth remembering precisely because the label syntax is identical and the mistake produces no error at all — someone reasonably familiar with Errors 1 and 2 above might assume this is "just another label mismatch" and hunt for a typo that doesn't exist, when the actual issue is the object *type*, not anything about how it's labeled.

</details>

**Cleanup — full teardown (end of Break-Fix):**
```bash
kubectl delete role widgets-namespaced-viewer -n ci --ignore-not-found
kubectl label clusterrole widgets-viewer rbac.authorization.k8s.io/aggregate-to-view- --ignore-not-found 2>/dev/null || true
kubectl delete clusterrolebinding platform-team-operator --ignore-not-found
kubectl delete clusterrole platform-operator widgets-viewer widgets-editor --ignore-not-found
cd ../..
```

---

## Interview Prep

**Q1. A ClusterRole has `aggregationRule` set. Can you safely `kubectl edit` its `rules` field to add a permission quickly?**
No — not durably. The aggregation controller continuously recomputes `rules` from every ClusterRole matching the selector; a manual edit survives only until the next reconciliation pass, which overwrites it with no warning. Any rule that genuinely needs to be part of an aggregate ClusterRole has to live in a separately-authored, correctly-labeled ClusterRole instead.

**Q2. How do `view`, `edit`, and `admin` actually pick up permissions for a newly-installed CRD, without Kubernetes' maintainers editing those objects for every possible CRD in existence?**
Through the same aggregation mechanism this demo builds directly — a CRD's own installation manifest can ship a small ClusterRole labeled `rbac.authorization.k8s.io/aggregate-to-view: "true"` (and/or `-to-edit`), and the built-in ClusterRoles absorb it automatically via their own `clusterRoleSelectors`. No edit to `view`/`edit`/`admin` themselves is ever required.

**Q3. Why can't you aggregate a namespaced `Role`'s rules into a `ClusterRole`, even if you label the `Role` identically to a working `ClusterRole` example?**
`clusterRoleSelectors` structurally only evaluates `ClusterRole` objects — it never looks at `Role` objects at all, regardless of labels. This isn't a selector-matching failure to debug; it's a design boundary, and there's no version of `aggregationRule` that spans the namespace/cluster-scope divide.

**Q4. A label on a child ClusterRole is spelled identically to a working example, but the aggregate still doesn't pick it up. What's a subtle cause worth checking beyond an obvious typo?**
Label value casing and exact string equality — `"true"` and `"True"` (or any other casing difference) are different strings under `matchLabels`, with no normalization. Confirm the exact label value on both the child ClusterRole and the aggregate's selector match character-for-character, not just "looks the same at a glance."

**Q5. Is `cluster-admin` an aggregated ClusterRole like `view`/`edit`/`admin`?**
No — `cluster-admin` is a fixed, hand-written wildcard rule (`apiGroups: ["*"], resources: ["*"], verbs: ["*"]`). A wildcard already covers everything, so there's nothing meaningful for aggregation to add to it; only the three narrower built-ins use the aggregation mechanism.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Demo concept / command | CKA objective | CKAD objective | Notes |
|---|---|---|---|
| `aggregationRule`/`clusterRoleSelectors` | Cluster Architecture, Installation & Configuration (25%) | — | Less commonly hands-on tested directly, but understanding it is often needed to correctly reason about `view`/`edit`/`admin` scenario questions |
| `rbac.authorization.k8s.io/aggregate-to-*` labels | Cluster Architecture, Installation & Configuration (25%) | — | Knowing these exact label names is the practical, testable skill here |
| Why aggregate `rules` shouldn't be hand-edited | Troubleshooting (30%) | — | A reasoning question more than a command-recall one |

### Common Exam Traps

| Scenario | What the task actually requires | Common wrong approach |
|---|---|---|
| "Grant a CRD's access to everyone who already has `view`" | Label a ClusterRole for that CRD with `aggregate-to-view: "true"` | Manually editing the `view` ClusterRole's `rules` directly — technically possible in the moment, but gets silently reverted on the next reconciliation |
| Debugging why an aggregate ClusterRole is missing an expected rule | Check the exact label value (case, whitespace) on the child ClusterRole against the aggregate's selector | Assuming the child ClusterRole itself must be broken, when the label string mismatch is the actual cause |
| Wanting a namespaced Role's rules reflected in a cluster-wide aggregate | Rewrite the rule as a `ClusterRole` with the matching label | Labeling the existing `Role` the same way and expecting it to work — it structurally can't |

### Exam Task — Write it from scratch

**Task:** Create a ClusterRole `crd-x-viewer` granting `get`/`list`/`watch` on a hypothetical CRD `widgets.example.com`, labeled to aggregate into the built-in `view` ClusterRole.

**Official documentation:**
- [Aggregated ClusterRoles](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles) — the `aggregationRule` field reference

**What to practise:**
1. Confirm the exact reserved label: `rbac.authorization.k8s.io/aggregate-to-view: "true"`
2. Write the ClusterRole with that label and the CRD's rule
3. Apply, then confirm via `kubectl describe clusterrole view | grep widgets`

<details>
<summary>Reference solution (open only after attempting)</summary>

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: crd-x-viewer
  labels:
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules:
- apiGroups: ["example.com"]
  resources: ["widgets"]
  verbs: ["get", "list", "watch"]
```

**Fields you must know without looking up:**
- The exact label key `rbac.authorization.k8s.io/aggregate-to-view` — a typo'd key means silent non-inclusion, same as any other label mismatch
- The label value `"true"` (lowercase, quoted string) — case-sensitive
- This ClusterRole needs no `ClusterRoleBinding` of its own — it does its job purely by being absorbed into `view`, which is presumably already bound to whoever needs it

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| `aggregationRule` makes a ClusterRole's `rules` computed, not authored | A controller continuously recomputes it from every ClusterRole matching `clusterRoleSelectors` |
| The computation is continuous, not one-time | A new matching ClusterRole appearing later updates the aggregate automatically, with zero changes to the aggregate itself |
| `view`/`edit`/`admin` are aggregated ClusterRoles | Using the reserved `rbac.authorization.k8s.io/aggregate-to-{view,edit,admin}` labels — the exact mechanism this demo builds directly |
| `cluster-admin` is NOT aggregated | It's a fixed wildcard rule; there's nothing for aggregation to meaningfully add to `apiGroups: ["*"], resources: ["*"], verbs: ["*"]` |
| Manually editing an aggregate's `rules` doesn't stick | The next reconciliation pass overwrites it from the real matching ClusterRoles, with no warning |
| Aggregation is ClusterRole-only, structurally | `clusterRoleSelectors` never evaluates `Role` objects, regardless of labels — this is a design boundary, not a bug to work around |
| Label matching is exact-string, case-sensitive | `"true"` and `"True"` are different values under `matchLabels` — no normalization |
| Aggregation can chain | An aggregate ClusterRole can itself carry an aggregation label for a different, broader aggregate |

> **Demo scope:** Primary concept: ClusterRole aggregation (`aggregationRule`/`clusterRoleSelectors`). Supporting concepts: the built-in `view`/`edit`/`admin` labeling convention, label-selector exact-match semantics.
> Estimated completion time: 55–60 minutes.
> Checkpoints: 2 natural stopping points — after Step 3 (aggregation proven live via a second child) and after Step 4 (binding verified, built-in convention confirmed, before Break-Fix — an explicit off-ramp is called out in Step 5).

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl describe clusterrole <name>` | Shows an aggregate ClusterRole's current computed `rules` |
| `kubectl label clusterrole <name> <key>=<value>` | Adds an aggregation label to an existing ClusterRole |
| `kubectl label clusterrole <name> <key>-` | Removes a label (trailing `-`) — used to un-opt a ClusterRole out of an aggregate |

### Generating YAML skeletons with --dry-run

`aggregationRule` has no imperative `kubectl create clusterrole` flag at all — it must always be hand-authored, since it's a structural field with no equivalent in the imperative command's flag set.

**Supported — the child ClusterRoles' base rules, then hand-add the label:**
```bash
kubectl create clusterrole NAME --verb=get,list,watch --resource=widgets.example.com --dry-run=client -o yaml
```

**Not supported:** `aggregationRule` itself (always hand-authored), `kubectl get`, `describe`, `logs`, `exec`, `delete`, `apply`, `patch`, `label` (though `label` is itself the tool used to opt a ClusterRole in, it's not a `--dry-run`-style generator)

### Imperative Quick-Create Commands

| Object | Imperative command | Notes |
|---|---|---|
| ClusterRole (child, base rules) | `kubectl create clusterrole NAME --verb=get,list,watch --resource=widgets.example.com` | Then hand-add the aggregation label — `create clusterrole` has no flag for labels or `aggregationRule` |
| Label (opt into an aggregate) | `kubectl label clusterrole NAME KEY=VALUE` | The only imperative step in this entire mechanism that has a direct command |

---

## Troubleshooting

**An aggregate ClusterRole is missing a rule you expect from a labeled child:**
```bash
kubectl get clusterrole <child-name> -o jsonpath='{.metadata.labels}'
```
```
# Cause: label key or value doesn't exactly match the aggregate's
#        clusterRoleSelectors — often a case mismatch (true vs True).
# Fix: Compare character-for-character against the selector in the
#      aggregate ClusterRole's aggregationRule.
```

**A manually-added rule in an aggregate ClusterRole keeps disappearing:**
```bash
kubectl get clusterrole <name> -o jsonpath='{.aggregationRule}'
```
```
# Cause: this ClusterRole has aggregationRule set — its rules field is
#        controller-owned and gets recomputed continuously.
# Fix: Move the rule into a separately-authored, correctly-labeled
#      ClusterRole instead of editing the aggregate directly.
```

**A labeled Role's rules never show up in any aggregate ClusterRole:**
```
# Cause: aggregation only ever evaluates ClusterRole objects — Role is
#        structurally invisible to clusterRoleSelectors, regardless of
#        labels.
# Fix: Rewrite the rule as a ClusterRole with the same label.
```

---

## Appendix — Anki Cards

**`07-aggregated-clusterroles-anki.csv`:**

```
#deck:k8s-platform-labs::12-rbac::07-aggregated-clusterroles
#separator:Comma
#columns:Front,Back,Tags
"What does aggregationRule actually do to a ClusterRole's rules field?","Makes it computed rather than authored — a controller continuously recomputes rules as the union of every ClusterRole matching clusterRoleSelectors, rather than the rules being written directly.","aggregated-clusterroles,aggregationrule,cka-cluster-architecture-installation-configuration"
"Is aggregation a one-time computation at creation, or continuous?","Continuous. A new ClusterRole matching the selector, created at any point later, gets absorbed into the aggregate automatically with no further action on the aggregate itself.","aggregated-clusterroles,aggregationrule,cka-cluster-architecture-installation-configuration"
"How do view, edit, and admin actually pick up permissions for newly-installed CRDs?","Via the same aggregation mechanism — CRD installation manifests can ship a ClusterRole labeled rbac.authorization.k8s.io/aggregate-to-view (or -edit/-admin) that gets absorbed automatically, with zero edits to the built-in ClusterRoles themselves.","aggregated-clusterroles,built-in-clusterroles,cka-cluster-architecture-installation-configuration"
"Is cluster-admin an aggregated ClusterRole?","No. It's a fixed wildcard rule (apiGroups/resources/verbs all *) — there's nothing meaningful for aggregation to add to something that already covers everything.","aggregated-clusterroles,cluster-admin,cka-cluster-architecture-installation-configuration"
"Can you safely kubectl edit an aggregate ClusterRole's rules field to quickly add a permission?","Not durably. The aggregation controller reconciles continuously and will overwrite a manual edit on the next pass, with no warning. Any rule that needs to be part of the aggregate must live in a correctly-labeled ClusterRole instead.","aggregated-clusterroles,manual-edit,cka-troubleshooting"
"Can a namespaced Role's rules be aggregated into a ClusterRole by labeling the Role the same way as a working ClusterRole example?","No. clusterRoleSelectors only ever evaluates ClusterRole objects — a Role is structurally invisible to it regardless of labels. This is a design boundary, not a matching failure to fix.","aggregated-clusterroles,role-vs-clusterrole,cka-cluster-architecture-installation-configuration"
"A child ClusterRole's label is spelled identically to a working example but still isn't picked up by the aggregate. What's a subtle cause to check?","Label value casing/exact-match — 'true' and 'True' are different strings under matchLabels, with no normalization. Compare the exact value character-for-character against the aggregate's selector.","aggregated-clusterroles,label-matching,cka-troubleshooting"
"Can an aggregate ClusterRole itself be aggregated into another, broader aggregate ClusterRole?","Yes. Aggregation can chain — an aggregate ClusterRole can carry an aggregation label for a different aggregate, letting rules flow through multiple levels.","aggregated-clusterroles,chaining,cka-cluster-architecture-installation-configuration"
"Does kubectl create clusterrole have a flag for setting aggregationRule or labels?","No. aggregationRule must always be hand-authored — there's no imperative flag for it, and create clusterrole has no label-setting flag either; labels are added afterward via kubectl label.","aggregated-clusterroles,imperative-commands,cka-cluster-architecture-installation-configuration"
```

## Appendix — Quiz

**`07-aggregated-clusterroles-quiz.md`:**

````markdown
# Quiz — 12-rbac/07-aggregated-clusterroles: Composing ClusterRoles Automatically

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next demo.

**Q1. What does setting `aggregationRule` on a ClusterRole actually do to its `rules` field?**

- A) It validates `rules` against a schema
- B) It makes `rules` a continuously-computed union of every ClusterRole matching `clusterRoleSelectors`, rather than something authored directly
- C) It encrypts the `rules` field
- D) It has no effect unless `rules` is also explicitly set

<details>
<summary>Answer</summary>

**B** — The field's presence hands ownership of `rules` to a reconciling controller. Whatever's written in `rules` directly gets overwritten by the computed union.
Trap: D assumes `rules` must be set for this to work — the correct pattern is actually to leave it empty, since it's computed regardless.

</details>

---

**Q2. Is aggregation computed once at creation, or continuously?**

- A) Once, at creation — later ClusterRoles never get picked up automatically
- B) Continuously — a new matching ClusterRole created later is absorbed automatically, with no changes to the aggregate itself
- C) Only when `kubectl apply` is rerun against the aggregate ClusterRole
- D) Only during cluster upgrades

<details>
<summary>Answer</summary>

**B** — This is the mechanism's entire value: a controller reconciles continuously, so new correctly-labeled ClusterRoles are absorbed with zero further action.
Trap: A and C both assume a one-time or manually-triggered computation, which defeats the purpose of the mechanism.

</details>

---

**Q3. How do the built-in `view`/`edit`/`admin` ClusterRoles gain permissions for a newly-installed CRD?**

- A) Kubernetes automatically detects new CRDs and edits `view`/`edit`/`admin` directly
- B) A CRD's own ClusterRole can be labeled `rbac.authorization.k8s.io/aggregate-to-view`/`-edit`/`-admin`, and gets absorbed via the same aggregation mechanism
- C) They don't — CRD access must always be granted through a separate, manually-bound ClusterRole
- D) Only `cluster-admin` can be extended this way

<details>
<summary>Answer</summary>

**B** — This is the real, documented convention — no special Kubernetes-internal magic, just the same `aggregationRule` mechanism this demo builds directly against a custom aggregate.
Trap: A invents automatic detection that doesn't exist — the label has to be deliberately added by whoever ships the CRD. D is backwards; `cluster-admin` is specifically NOT aggregated.

</details>

---

**Q4. You `kubectl edit` an aggregate ClusterRole and manually add a rule to `rules`. What happens over time?**

- A) It persists indefinitely, exactly like editing any other ClusterRole
- B) It's overwritten by the next reconciliation pass, since `rules` on an aggregate ClusterRole is controller-computed
- C) The edit is rejected immediately with a validation error
- D) It persists only for the ClusterRole's `resourceVersion` lifetime

<details>
<summary>Answer</summary>

**B** — The reconciliation loop recomputes `rules` from the matching ClusterRoles on an ongoing basis; a manual addition survives only until the next pass.
Trap: C assumes upfront rejection, which doesn't happen — the edit succeeds in the moment, which is exactly why this is a trap rather than an obvious error.

</details>

---

**Q5. A namespaced `Role` is labeled identically to a working aggregation example. Does its rule get absorbed into a matching aggregate ClusterRole?**

- A) Yes, as long as the label matches exactly
- B) No — `clusterRoleSelectors` only evaluates `ClusterRole` objects; `Role` is structurally invisible to it regardless of labels
- C) Yes, but only if the Role is in the `kube-system` namespace
- D) No, but only because Roles can't have labels

<details>
<summary>Answer</summary>

**B** — This is a design boundary, not a selector-matching detail — aggregation was never built to reach across the namespace/cluster-scope divide.
Trap: A is the exact misconception this question targets. D is false — Roles can absolutely have labels; that's not why this fails.

</details>

---

**Q6. Is `cluster-admin` an aggregated ClusterRole, the same way `view`/`edit`/`admin` are?**

- A) Yes, identically
- B) No — it's a fixed wildcard rule with nothing meaningful for aggregation to add to it
- C) Yes, but only in clusters with more than one node
- D) No — `cluster-admin` doesn't support `ClusterRoleBinding` at all

<details>
<summary>Answer</summary>

**B** — `cluster-admin` is `apiGroups: ["*"], resources: ["*"], verbs: ["*"]`, a fixed wildcard — aggregation exists to compose narrower, growing rule sets, which a wildcard already subsumes entirely.
Trap: D is flatly false — `cluster-admin` is the canonical example of a ClusterRole bound via `ClusterRoleBinding`.

</details>

---

Score guide:
| Score | Action |
|---|---|
| 6/6 | Import Anki cards, move to 08-rbac-privilege-escalation-prevention |
| 5/6 | Review the wrong answer, then proceed |
| 4/6 | Re-read the relevant section, retry those questions |
| Below 4/6 | Re-read the full demo and redo the walkthrough before proceeding |
````