# Demo: 12-rbac/08-rbac-privilege-escalation-prevention — Stopping Self-Granted Access

## Lab Overview

Every demo so far assumed *you* (an admin) write Roles and RoleBindings for someone else. What happens when the subject who's allowed to create Roles and RoleBindings is a lower-privileged engineer, not an admin — can they grant themselves more than they already have, just by authoring the right YAML? Kubernetes RBAC has a built-in answer to exactly this, enforced by the API server itself, not a separate policy engine: the `escalate` and `bind` verbs.

**Real-world scenario:** A junior platform engineer manages CI pipeline permissions day-to-day — creating and updating Roles/RoleBindings within the `ci` namespace so they don't have to file a ticket for every small access change. They currently have only read access to Pods themselves. Can they write a Role granting `delete` on Secrets and bind it to their own account, escalating on the spot? This demo proves, live, that the answer is no — and shows exactly what changes that.

**What this lab covers:**
- The `escalate` verb: why creating/updating a Role or ClusterRole that grants more than the author already has is rejected by default
- The `bind` verb: why binding a Role/ClusterRole to anyone — even one you didn't author — requires either holding everything it grants, or holding `bind` itself
- Why `04`'s built-in `admin` ClusterRole can manage RBAC within its namespace at all — it's not a coincidence, it's these two verbs, granted deliberately

> **Scope note:** This lab covers the API-server-enforced escalation/bind checks specifically. It does not cover general privilege-escalation topics outside RBAC (container `privileged: true`, `allowPrivilegeEscalation` on a Pod's SecurityContext) — those are `16-security`.

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
- **REQUIRED:** `12-rbac/01-rbac-fundamentals` (Role/RoleBinding mechanics), `12-rbac/04-clusterroles-clusterrolebindings` (built-in `admin` ClusterRole)

---

## Lab Objectives

By the end of this lab, you will be able to:

1. ✅ Explain why creating a Role/ClusterRole granting more than the author already has is rejected by default
2. ✅ Explain why binding a Role/ClusterRole to anyone requires either holding its full grant already, or holding `bind`
3. ✅ Prove live that adding `escalate`/`bind` to a subject's own permissions changes both outcomes
4. ✅ Identify exactly which built-in ClusterRole grants these verbs, and why
5. ✅ Diagnose and fix three privilege-escalation-prevention misconfigurations from symptoms alone

---

## Directory Structure

```
12-rbac/08-rbac-privilege-escalation-prevention/
├── README.md
├── 08-rbac-privilege-escalation-prevention-anki.csv
├── 08-rbac-privilege-escalation-prevention-quiz.md
└── src/
    ├── 01-namespace-ci.yaml                       # reused pattern from 01-rbac-fundamentals
    ├── 02-role-pod-reader.yaml                     # junior-engineer's own base access
    ├── 03-rolebinding-junior-engineer.yaml          # binds them to it
    ├── 04-role-rbac-manager-no-escalate.yaml        # grants create on roles/rolebindings — WITHOUT escalate/bind
    ├── 05-rolebinding-rbac-manager.yaml
    └── break-fix/
        ├── 01-escalation-attempt-blocked.yaml
        ├── 02-bind-attempt-blocked.yaml
        └── 03-escalate-granted-but-bind-forgotten.yaml
```

---

## Recall Check — 07-aggregated-clusterroles

Answer from memory before continuing — no peeking at the previous demo.

1. Can you safely `kubectl edit` an aggregate ClusterRole's `rules` field to add a permission quickly?
2. How do `view`/`edit`/`admin` actually pick up permissions for a newly-installed CRD?
3. Is `cluster-admin` itself an aggregated ClusterRole?

<details>
<summary>Answers</summary>

1. Not durably — the aggregation controller reconciles continuously and overwrites a manual edit on the next pass; the rule has to live in a correctly-labeled ClusterRole instead.
2. A CRD's own ClusterRole can be labeled `rbac.authorization.k8s.io/aggregate-to-view`/`-edit`/`-admin`, absorbed automatically — no edit to the built-ins themselves.
3. No — it's a fixed wildcard rule; there's nothing meaningful for aggregation to add to something that already covers everything.

</details>

---

## Concepts

### The `escalate` Verb — Preventing Self-Granted Roles

**What it is:** By default, when a subject attempts to `create` or `update` a `Role` or `ClusterRole`, the API server compares the proposed `rules` against every permission that subject *already* has. If the proposed rules would grant anything the subject doesn't already possess, the request is rejected — **unless** the subject also holds the `escalate` verb on `roles`/`clusterroles` (in the `rbac.authorization.k8s.io` API group).

```yaml
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete", "escalate"]
```

- **Why it exists:** Without this check, a subject with only `create` on `roles` — no matter how narrow their own actual grants are — could write a Role containing `apiGroups: ["*"], resources: ["*"], verbs: ["*"]` and bind it to themselves, becoming a de facto cluster-admin despite never having been granted that. The escalation check closes exactly this gap, enforced by the API server itself at write time, not left to policy or convention.
- **How it works:** The comparison is rule-by-rule — a proposed Role's rules must each be a subset of (or equal to) some combination of rules the requesting subject already effectively has. A subject with `get`/`list`/`watch` on Pods can freely create a Role granting the same or narrower — but not one adding `delete`, or reaching into a resource type they've never been granted at all.
- **The escape hatch is deliberate, not a loophole:** `escalate` exists specifically for genuinely trusted subjects — namespace admins, cluster operators — who need to manage RBAC broadly without every single grant being pre-verified against their own. It's a conscious trust boundary, not an oversight.

### The `bind` Verb — Preventing Binding to Roles You Don't Hold

**What it is:** A parallel, separate check on `RoleBinding`/`ClusterRoleBinding` creation: by default, binding a Role or ClusterRole to any subject (including yourself) requires the *creator* of the binding to already hold every permission that Role/ClusterRole grants — **unless** the creator holds the `bind` verb on `roles`/`clusterroles`.

```yaml
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete", "bind"]
```

- **Why it's a separate check from `escalate`:** `escalate` governs *authoring* a Role/ClusterRole's rules; `bind` governs *attaching* an existing Role/ClusterRole (however it was authored, by anyone) to a subject. Without `bind`, a subject could reference a pre-existing, broad Role they had nothing to do with writing — e.g. a built-in `cluster-admin` — in a fresh RoleBinding pointed at themselves, achieving the same escalation through a different door. `bind` closes that door specifically.
- **Worked example:** a subject with `create` on `rolebindings` but no `bind` verb, and no `admin`-level access themselves, cannot create a RoleBinding referencing the built-in `admin` ClusterRole for anyone — including themselves — because they don't already hold everything `admin` grants, and lack the verb that would let them bind it anyway.

### Why `04`'s `admin` ClusterRole Could Manage RBAC At All

**What it is:** `04` noted that `admin` (unlike `edit`) can manage Roles and RoleBindings *within its own namespace* — this demo names exactly why: the built-in `admin` ClusterRole's rules include `escalate` and `bind` on `roles`/`rolebindings`, deliberately, as part of what makes it a genuine namespace-admin-level grant rather than just "broad read/write."

```bash
kubectl describe clusterrole admin | grep -A2 "roles\b"
```
- Without these two verbs baked into `admin`, a namespace admin bound via `admin` would be blocked from managing their own namespace's RBAC by the exact same checks this demo builds and tests — `edit` deliberately lacks both, which is precisely why `04` noted it "cannot view or modify RBAC objects."

---

## Lab Step-by-Step Guide

This lab builds a subject with real, narrow permissions, gives them the ability to create Roles/RoleBindings but deliberately withholds `escalate`/`bind`, and proves both checks fire — then adds each verb one at a time to watch the exact same attempts succeed with nothing else changed.

---

### Step 1 — Create the Junior Engineer's Base Access

Start narrow — this is the baseline the escalation check will compare every future Role-creation attempt against.

**`src/01-namespace-ci.yaml`:**

Reused from `01-rbac-fundamentals`.

**`src/02-role-pod-reader.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: ci
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

**`src/03-rolebinding-junior-engineer.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: junior-engineer-pod-reader
  namespace: ci
subjects:
- kind: User
  name: junior-engineer
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f src/01-namespace-ci.yaml
kubectl apply -f src/02-role-pod-reader.yaml
kubectl apply -f src/03-rolebinding-junior-engineer.yaml
```
```
⚠️ [VERIFY]
```

---

### Step 2 — Grant RBAC-Management Access, Without `escalate`/`bind`

This is deliberately incomplete — the whole point of this step is to create the exact gap Steps 3–4 will test.

**`src/04-role-rbac-manager-no-escalate.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: rbac-manager-limited
  namespace: ci
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # deliberately no "escalate" or "bind" yet
```

**`src/05-rolebinding-rbac-manager.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: junior-engineer-rbac-manager
  namespace: ci
subjects:
- kind: User
  name: junior-engineer
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: rbac-manager-limited
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f src/04-role-rbac-manager-no-escalate.yaml
kubectl apply -f src/05-rolebinding-rbac-manager.yaml
```
```
⚠️ [VERIFY]
```

---

### Step 3 — Prove the `escalate` Check Fires

Attempt to author a Role broader than what `junior-engineer` already holds — as `junior-engineer`, not as the cluster-admin identity used everywhere else in this series.

```bash
cat <<'EOF' | kubectl auth can-i create -f - --as=junior-engineer
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secrets-deleter
  namespace: ci
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["delete"]
EOF
```
```
⚠️ [VERIFY]
```
```
# Note: kubectl auth can-i -f evaluates a proposed object against the
# escalation check specifically, without actually creating anything —
# useful for testing this exact scenario safely. Expected: "no", since
# junior-engineer has no existing grant on secrets at all, let alone
# delete.
```

Attempt to actually apply it as `junior-engineer`, to see the real rejection message:
```bash
kubectl --as=junior-engineer apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secrets-deleter
  namespace: ci
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["delete"]
EOF
```
```
⚠️ [VERIFY — expected: an error naming "escalate" explicitly, e.g.
"user \"junior-engineer\" (groups=[...]) is attempting to grant RBAC
permissions not currently held"]
```

**Now attempt a Role that's a subset of what `junior-engineer` already has:**
```bash
kubectl --as=junior-engineer apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader-copy
  namespace: ci
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
EOF
```
```
⚠️ [VERIFY — expected: succeeds, since this is a strict subset of
junior-engineer's existing pod-reader grant]
```
```
# Observation: same subject, same rbac-manager-limited Role active for
# both attempts — the only variable is whether the proposed rules stay
# within what junior-engineer already holds. That's the escalation
# check operating exactly as designed, not a permissions gap anywhere
# else.
```

---

### Step 4 — Prove the `bind` Check Fires Independently

Even a Role `junior-engineer` didn't author — the built-in `admin` ClusterRole — can't be bound to anyone without `bind`.

```bash
kubectl --as=junior-engineer apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: junior-engineer-admin-attempt
  namespace: ci
subjects:
- kind: User
  name: junior-engineer
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: admin
  apiGroup: rbac.authorization.k8s.io
EOF
```
```
⚠️ [VERIFY — expected: rejected, naming "escalate" or a related
permission check — junior-engineer doesn't hold everything `admin`
grants, and lacks `bind`]
```

---

### Step 5 — Add `escalate` and `bind`, Retry Both, Cleanup

**Update `src/04-role-rbac-manager-no-escalate.yaml`'s `verbs` to include `escalate` and `bind`:**
```yaml
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete", "escalate", "bind"]
```

```bash
kubectl apply -f src/04-role-rbac-manager-no-escalate.yaml
kubectl --as=junior-engineer apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secrets-deleter
  namespace: ci
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["delete"]
EOF
```
```
⚠️ [VERIFY — expected: succeeds now, identical proposed Role as Step 3,
only escalate was added to junior-engineer's own permissions]
```

**(a) Demo-scoped resources:** everything created stays in place; Break-Fix reuses this state.

**(b) Cluster-scoped shared components:** none installed.

> **Stopping here without continuing to Break-Fix in this session?** Tear down manually:
> ```bash
> kubectl delete namespace ci --ignore-not-found
> ```

---

## What You Learned

- ✅ Explained why creating a Role/ClusterRole granting more than the author already has is rejected by default
- ✅ Explained why binding a Role/ClusterRole requires holding its full grant, or holding `bind`
- ✅ Proved live that adding `escalate`/`bind` changes both outcomes, with nothing else different
- ✅ Identified that `04`'s built-in `admin` ClusterRole grants both verbs deliberately, and `edit` doesn't
- ✅ Diagnosed and fixed three privilege-escalation-prevention misconfigurations from symptoms alone

**Key Takeaway:** Kubernetes RBAC doesn't just grant access — it actively prevents subjects with only `create`/`update` on RBAC objects from using that alone to escalate themselves, via two independent, API-server-enforced checks: `escalate` (governing what a Role/ClusterRole's *rules* can contain relative to the author) and `bind` (governing whether an *existing* Role/ClusterRole, however broad, can be attached to anyone). Both are off by default; both are exactly what the built-in `admin` ClusterRole deliberately turns on, and `edit` deliberately doesn't.

---

## Break-Fix

Three scenarios below. Diagnose from the symptom command output alone before opening the reveal.

**Restore known-good state before starting** (skip if continuing directly from Step 5):
```bash
kubectl apply -f ../01-namespace-ci.yaml
kubectl apply -f ../02-role-pod-reader.yaml
kubectl apply -f ../03-rolebinding-junior-engineer.yaml
kubectl apply -f ../04-role-rbac-manager-no-escalate.yaml
kubectl apply -f ../05-rolebinding-rbac-manager.yaml
```
```bash
cd src/break-fix/
```

### Error-1 — a broader Role gets rejected, and the error is misread as an RBAC bug

```bash
kubectl --as=junior-engineer apply -f 01-escalation-attempt-blocked.yaml
```
```
⚠️ [VERIFY — expected: rejected, error naming an attempt to grant
permissions not currently held]
```

**`src/break-fix/01-escalation-attempt-blocked.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: configmap-writer
  namespace: ci
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["create", "update", "delete"]
```

`junior-engineer` has `create`/`update`/`patch`/`delete` on `roles`/`rolebindings` themselves — this Role creation attempt still fails. Is RBAC misconfigured?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** Nothing is misconfigured. `junior-engineer` has never been granted anything on `configmaps` at all — this proposed Role would grant `create`/`update`/`delete` on a resource type the subject has zero existing access to, which is exactly what the `escalate` check exists to block, regardless of how much access they have to manage RBAC *objects* themselves.

**Fix:** Either grant `junior-engineer` the underlying `configmaps` permissions first (so the proposed Role is no longer broader than what they hold), or grant `escalate` if this subject is genuinely meant to author arbitrary Roles.

**Cascade:** Easy to misdiagnose as "my RBAC-manager Role isn't working" when the actual mechanism is a second, independent check layered on top of the `create`/`update` verbs — having those verbs on `roles` is necessary but not sufficient for authoring broader rules.

</details>

**Cleanup:** nothing applied successfully — no cleanup needed.

---

### Error-2 — binding an existing broad Role is blocked even though the binding itself "should" work

```bash
kubectl --as=junior-engineer apply -f 02-bind-attempt-blocked.yaml
```
```
⚠️ [VERIFY — expected: rejected]
```

**`src/break-fix/02-bind-attempt-blocked.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: teammate-pod-reader-elevated
  namespace: ci
subjects:
- kind: User
  name: teammate
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: edit
  apiGroup: rbac.authorization.k8s.io
```

`junior-engineer` has `create` on `rolebindings`. This RoleBinding doesn't even name `junior-engineer` as the subject — it's for a teammate. Why does it still fail?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** The `bind` check applies to the *creator* of the RoleBinding, not its subject — it doesn't matter who the grant is *for*; what matters is whether `junior-engineer` (the one creating the binding) already holds everything `edit` grants, or holds `bind`. Neither is true here, so the binding is rejected regardless of who it names.

**Fix:** Grant `junior-engineer` `bind` on `roles`/`clusterroles` (per Step 5), or don't ask them to create bindings referencing Roles broader than their own.

**Cascade:** A common misconception is that the `bind` check somehow inspects the *target* subject's existing access — it doesn't; it's entirely about the creator's own standing relative to what's being bound, which is why "but I'm not even granting this to myself" doesn't bypass it.

</details>

**Cleanup:** nothing applied successfully — no cleanup needed.

---

### Error-3 — `escalate` was granted, but `bind` was forgotten

```bash
kubectl --as=junior-engineer apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secrets-full-access
  namespace: ci
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "create", "update", "delete"]
EOF
```
```
⚠️ [VERIFY — expected: succeeds, since escalate is granted per Step 5]
```

```bash
kubectl --as=junior-engineer apply -f 03-escalate-granted-but-bind-forgotten.yaml
```
```
⚠️ [VERIFY — expected: rejected]
```

**`src/break-fix/03-escalate-granted-but-bind-forgotten.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: junior-engineer-secrets-full-access
  namespace: ci
subjects:
- kind: User
  name: junior-engineer
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: secrets-full-access
  apiGroup: rbac.authorization.k8s.io
```

`junior-engineer` successfully *authored* the broader Role (escalate worked) but can't bind it to themselves. Why, given they just proved they can create broad Roles?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `escalate` and `bind` are genuinely independent checks gating two different actions — authoring a Role's rules, and attaching a Role to a subject via a binding. Holding one says nothing about the other; `junior-engineer` has `escalate` (from Step 5) but was never separately granted `bind`, so the RoleBinding creation fails even though the Role it references now legitimately exists and was legitimately authored.

**Fix:** Grant `bind` as well — the two verbs are commonly needed together for a subject to fully self-manage RBAC, but they are never granted as a package automatically; each is its own explicit decision.

**Cascade:** This is the scenario most likely to confuse someone who's just seen `escalate` work — succeeding at authoring a broader Role creates a natural (but wrong) assumption that binding it will also now succeed, when it's actually gated by a completely separate grant.

</details>

**Cleanup — full teardown (end of Break-Fix):**
```bash
kubectl delete role secrets-full-access -n ci --ignore-not-found
kubectl delete namespace ci --ignore-not-found
cd ../..
```

---

## Interview Prep

**Q1. A subject has `create`, `update`, and `delete` on `roles` in a namespace, but no `escalate`. Can they create a Role granting `get` on a resource type they've never had any access to?**
No. The escalation check compares the proposed Role's rules against everything the subject already effectively holds — a resource type they have zero grants on is, by definition, broader than what they hold, so the creation is rejected regardless of how much access they have to manage Role *objects* themselves.

**Q2. Does the `bind` check evaluate the permissions of the subject being granted access, or the creator of the binding?**
The creator. Whether a RoleBinding successfully attaches a Role to someone depends entirely on whether the person creating that RoleBinding already holds everything the referenced Role grants, or holds `bind` themselves — not on anything about the target subject's own existing access.

**Q3. Why does the built-in `admin` ClusterRole grant `escalate` and `bind`, while `edit` deliberately doesn't?**
`admin` is meant to represent genuine namespace-administrator-level trust, including managing that namespace's own RBAC objects — which requires bypassing the default self-escalation checks deliberately. `edit` is meant for day-to-day workload management without RBAC authority; withholding both verbs is exactly what keeps `edit`-bound subjects from using their `create`/`update` access on Roles/RoleBindings (if granted at all) to escalate themselves.

**Q4. A subject successfully authors a broad Role (their `escalate` grant works), but fails to bind it to anyone, including themselves. What's the most likely gap?**
They likely have `escalate` but not `bind` — the two verbs gate genuinely separate actions (authoring rules vs. attaching an existing Role to a subject) and are never granted together automatically. Check specifically for `bind` on `roles`/`clusterroles` in their own grants.

**Q5. Could a subject bypass the escalation check by creating a RoleBinding that references a Role they didn't author themselves, rather than authoring a new broad Role directly?**
No — that's exactly what the `bind` check independently prevents. Referencing an existing Role/ClusterRole in a new binding still requires the binding's creator to already hold everything that Role grants, or to hold `bind` — regardless of who originally authored the Role being referenced.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Demo concept / command | CKA objective | CKAD objective | Notes |
|---|---|---|---|
| `escalate` verb on Role/ClusterRole creation | Cluster Architecture, Installation & Configuration (25%) | — | A CKA-heavy reasoning topic; rarely a CKAD hands-on task |
| `bind` verb on RoleBinding/ClusterRoleBinding creation | Cluster Architecture, Installation & Configuration (25%) | — | Same |
| Why `admin` differs from `edit` | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | Directly testable as a "why can/can't this built-in ClusterRole do X" scenario question |

### Common Exam Traps

| Scenario | What the task actually requires | Common wrong approach |
|---|---|---|
| "Why can't this subject create a broader Role, despite having create/update on roles?" | Recognize the `escalate` check is a separate gate from the `create`/`update` verbs themselves | Assuming `create`/`update` on `roles` alone is sufficient for authoring any rule content |
| "Why does binding an existing Role fail, even for a subject who didn't author it?" | Recognize `bind` gates the binding's creator, not the target subject or the Role's author | Assuming a pre-existing, already-correct Role can always be bound freely by anyone with `create` on bindings |
| Granting a subject full RBAC self-management | Grant `escalate` AND `bind` explicitly — both, deliberately | Assuming one implies the other, or that broad `create`/`update`/`delete` on `roles` is sufficient alone |

### Exam Task — Write it from scratch

**Task:** Grant a subject the ability to fully manage Roles and RoleBindings in namespace `ci`, including authoring rules broader than their own current access and binding existing ClusterRoles to others.

**Official documentation:**
- [Privilege Escalation Prevention and Bootstrapping](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#privilege-escalation-prevention-and-bootstrapping) — the `escalate`/`bind` reference

**What to practise:**
1. Identify both required verbs: `escalate` and `bind`, on `apiGroups: ["rbac.authorization.k8s.io"], resources: ["roles", "rolebindings"]`
2. Write the Role including both, alongside the usual `get`/`list`/`watch`/`create`/`update`/`patch`/`delete`
3. Bind it, then verify with a proposed-object check: `kubectl auth can-i create -f proposed-role.yaml --as=<subject>`

<details>
<summary>Reference solution (open only after attempting)</summary>

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: rbac-manager-full
  namespace: ci
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete", "escalate", "bind"]
```

**Fields you must know without looking up:**
- `escalate` and `bind` are both plain verb strings in the same `verbs` list as any other — no separate field or special YAML shape
- Both apply to `apiGroups: ["rbac.authorization.k8s.io"]` specifically — granting them on an unrelated resource type does nothing
- Neither verb is granted by any combination of `create`/`update`/`delete`/`*` on an unrelated resource — they're specific to `roles`/`clusterroles` (and by extension the bindings referencing them)

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| `escalate` gates authoring Role/ClusterRole rules broader than the author holds | Default-on protection, enforced by the API server itself at write time |
| `bind` gates attaching any existing Role/ClusterRole to a subject | Independent of who authored that Role — the check is entirely about the binding's creator |
| Both checks are off by default | A subject needs `create`/`update` on `roles`/`rolebindings` PLUS the relevant escalation verb — one without the other is insufficient |
| `bind` evaluates the binding's creator, not its target subject | "I'm not even granting this to myself" doesn't bypass the check |
| `escalate` and `bind` are independent — one doesn't imply the other | A subject can author broad Roles but still fail to bind them, or vice versa |
| The built-in `admin` ClusterRole grants both, deliberately | This is exactly why `admin` can manage RBAC within its namespace and `edit` cannot |
| `kubectl auth can-i create -f <file>` tests a proposed object against these checks | Without actually creating anything — safe for testing this exact mechanism |

> **Demo scope:** Primary concept: RBAC's built-in privilege-escalation prevention (`escalate`, `bind`). Supporting concept: why the built-in `admin`/`edit` ClusterRoles differ on exactly this.
> Estimated completion time: 55–60 minutes.
> Checkpoints: 2 natural stopping points — after Step 2 (baseline access granted, before testing) and after Step 4 (both checks proven to fire, before adding the verbs and retrying in Step 5).

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl auth can-i create -f <file> --as=<user>` | Tests a proposed Role/RoleBinding against the escalation/bind checks without creating anything |
| `kubectl describe clusterrole admin \| grep -A2 roles` | Confirms the built-in `admin` ClusterRole's `escalate`/`bind` grants directly |

### Generating YAML skeletons with --dry-run

**Supported:**
```bash
kubectl create role NAME --verb=get,list,watch,create,update,patch,delete,escalate,bind --resource=roles,rolebindings.rbac.authorization.k8s.io --dry-run=client -o yaml
```

**Not supported:** `kubectl get`, `describe`, `logs`, `exec`, `delete`, `apply`, `patch`, `label`

**Exam workflow:**
1. Generate the skeleton (note `escalate`/`bind` ARE settable via `--verb=` like any other verb string — no special flag needed) → apply

### Imperative Quick-Create Commands

| Object | Imperative command | Notes |
|---|---|---|
| Role (with escalate/bind) | `kubectl create role NAME --verb=get,create,escalate,bind --resource=roles.rbac.authorization.k8s.io` | `escalate`/`bind` are ordinary verb strings — no dedicated flag, just include them in `--verb=` |

---

## Troubleshooting

**A subject with `create`/`update` on `roles` still can't author a broader Role:**
```bash
kubectl auth can-i create -f <proposed-role.yaml> --as=<user>
```
```
# Cause: the subject lacks `escalate` — create/update on roles alone is
#        necessary but not sufficient for authoring rules broader than
#        what they already hold.
# Fix: Grant escalate on roles/clusterroles if this is genuinely intended.
```

**A RoleBinding creation is rejected even though the referenced Role isn't new or unusual:**
```
# Cause: the binding's CREATOR doesn't hold everything the referenced
#        Role grants, and lacks `bind` — this is independent of who the
#        binding's subject is or who authored the Role.
# Fix: Grant bind on roles/clusterroles to the binding's creator.
```

**A subject can author broad Roles but can't bind any of them:**
```
# Cause: they have escalate but not bind — the two verbs are independent
#        and neither implies the other.
# Fix: Grant bind explicitly alongside escalate.
```

---

## Appendix — Anki Cards

**`08-rbac-privilege-escalation-prevention-anki.csv`:**

```
#deck:k8s-platform-labs::12-rbac::08-rbac-privilege-escalation-prevention
#separator:Comma
#columns:Front,Back,Tags
"A subject has create/update/delete on roles, but no escalate. Can they author a Role granting access to a resource type they've never had any grant on?","No. The escalation check compares proposed rules against what the subject already effectively holds — create/update on Role OBJECTS is separate from being allowed to author arbitrary rule CONTENT.","privilege-escalation,escalate-verb,cka-cluster-architecture-installation-configuration"
"Does the bind check evaluate the permissions of the RoleBinding's target subject or its creator?","The creator. Whether a binding succeeds depends on whether the person CREATING it already holds everything the referenced Role grants, or holds bind themselves — not on the target subject's own access.","privilege-escalation,bind-verb,cka-cluster-architecture-installation-configuration"
"Why does the built-in admin ClusterRole grant escalate and bind, while edit deliberately doesn't?","admin represents genuine namespace-admin trust, including managing that namespace's own RBAC — which requires bypassing the default self-escalation checks. edit is for day-to-day workload management without RBAC authority.","privilege-escalation,admin,edit,cka-cluster-architecture-installation-configuration"
"A subject successfully authors a broader Role (escalate works) but fails to bind it to anyone. What's the likely gap?","They have escalate but not bind — the two verbs gate independent actions (authoring rules vs. attaching a Role to a subject) and neither is granted automatically by the other.","privilege-escalation,escalate-verb,bind-verb,cka-troubleshooting"
"Can a subject bypass the escalation check by referencing an existing Role they didn't author, instead of authoring a new broad Role themselves?","No — the bind check independently prevents this. Binding any existing Role/ClusterRole still requires the binding's creator to hold everything it grants, or to hold bind, regardless of who originally authored that Role.","privilege-escalation,bind-verb,cka-cluster-architecture-installation-configuration"
"What API groups and resources do the escalate and bind verbs apply to?","apiGroups: [\"rbac.authorization.k8s.io\"], resources: [\"roles\", \"clusterroles\"] (and by extension the bindings referencing them) — granting escalate/bind on an unrelated resource type has no effect.","privilege-escalation,escalate-verb,bind-verb,cka-cluster-architecture-installation-configuration"
"How can you test whether a proposed Role would pass the escalation check, without actually creating it?","kubectl auth can-i create -f <proposed-file.yaml> --as=<subject> — evaluates the proposed object against the escalation/bind checks without creating anything in the cluster.","privilege-escalation,can-i,testing,cka-cluster-architecture-installation-configuration"
"Are escalate and bind granted automatically whenever a subject has broad create/update/delete verbs on roles and rolebindings?","No. Both are separate, explicit verb grants that must be added deliberately — broad CRUD verbs on the Role/RoleBinding objects themselves say nothing about whether escalate or bind are also held.","privilege-escalation,escalate-verb,bind-verb,cka-cluster-architecture-installation-configuration"
```

## Appendix — Quiz

**`08-rbac-privilege-escalation-prevention-quiz.md`:**

````markdown
# Quiz — 12-rbac/08-rbac-privilege-escalation-prevention: Stopping Self-Granted Access

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next demo.

**Q1. A subject has `create`, `update`, and `delete` on `roles` in a namespace, with no `escalate`. Can they author a Role granting access to a resource type they have zero existing grants on?**

- A) Yes — `create`/`update` on `roles` is sufficient on its own
- B) No — the escalation check independently compares proposed rules against what the subject already holds
- C) Yes, but only for read-only (`get`/`list`/`watch`) verbs
- D) No — Role creation is always restricted to cluster-admins

<details>
<summary>Answer</summary>

**B** — `create`/`update` on the Role *object* is a separate permission from being allowed to author arbitrary rule *content*; the escalation check gates the latter independently.
Trap: A is the exact misconception this demo is built to correct. D overstates the restriction — plenty of non-cluster-admin subjects can legitimately author Roles, just not ones broader than their own access.

</details>

---

**Q2. Does the `bind` check evaluate the permissions of a RoleBinding's target subject, or its creator?**

- A) The target subject — whoever the access is being granted to
- B) The creator — whoever is authoring the RoleBinding object
- C) Both, equally
- D) Neither — `bind` only applies to `ClusterRoleBinding`, never `RoleBinding`

<details>
<summary>Answer</summary>

**B** — The check is entirely about whether the binding's creator already holds what's being bound, or holds `bind` themselves — irrelevant to who the binding ultimately grants access to.
Trap: A is the natural but incorrect assumption. D is false; this demo's own scenarios test it against ordinary `RoleBinding`s.

</details>

---

**Q3. Why does the built-in `admin` ClusterRole include `escalate` and `bind`, while `edit` doesn't?**

- A) `admin` is newer and simply has more permissions listed overall
- B) `admin` represents genuine namespace-administrator trust, including managing that namespace's own RBAC — which requires deliberately bypassing the default self-escalation checks
- C) `edit` cannot reference the `rbac.authorization.k8s.io` API group at all
- D) There's no meaningful difference; both grant identical RBAC-management capability

<details>
<summary>Answer</summary>

**B** — This is a deliberate design choice reflecting the trust level each built-in ClusterRole is meant to represent, not an arbitrary difference in permission count.
Trap: C invents a technical restriction that doesn't exist — `edit` simply doesn't include these two verbs, it isn't blocked from the API group entirely.

</details>

---

**Q4. A subject successfully creates a broader Role (their `escalate` grant works) but fails to bind it to anyone, including themselves. What's most likely missing?**

- A) `escalate` itself — it must not actually be working
- B) `bind` — a separate, independently-granted verb that `escalate` doesn't imply
- C) `list` on `rolebindings`
- D) Nothing is missing; this is expected default behavior with no fix

<details>
<summary>Answer</summary>

**B** — `escalate` and `bind` gate genuinely different actions and are never granted as a package — succeeding at one says nothing about the other.
Trap: A contradicts the premise (escalate already worked, per the question). D dismisses a fixable, well-understood gap as unfixable.

</details>

---

**Q5. Could a subject bypass the `escalate` check by creating a RoleBinding that references a pre-existing, broad Role they didn't author themselves?**

- A) Yes — `bind` only applies to Roles the creator authored
- B) No — `bind` independently requires the binding's creator to already hold everything the referenced Role grants, or to hold `bind`, regardless of who authored it
- C) Yes, as long as the Role was created by a different user
- D) Yes, if the Role is a `ClusterRole` rather than a `Role`

<details>
<summary>Answer</summary>

**B** — This is exactly why `bind` exists as a separate check from `escalate` — referencing someone else's already-broad Role doesn't sidestep anything.
Trap: A, C, and D all describe a loophole that would defeat the entire purpose of the `bind` check — none of them are real.

</details>

---

Score guide:
| Score | Action |
|---|---|
| 5/5 | Import Anki cards, move to 09-rbac-troubleshooting |
| 4/5 | Review the wrong answer, then proceed |
| 3/5 | Re-read the relevant section, retry those questions |
| Below 3/5 | Re-read the full demo and redo the walkthrough before proceeding |
````