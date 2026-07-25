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

**B** — A RoleBinding can reference only a Role in its own namespace. The API server does not verify that the referenced Role exists when the RoleBinding is created, so kubectl apply succeeds. Later, during authorization, the RBAC authorizer looks for the referenced Role only in the RoleBinding's namespace. Since the Role exists only in ci, no matching Role is found and the binding grants no permissions. This is effectively the same outcome as a typo in roleRef.name: the binding exists, but it is non-functional until the referenced Role exists in the same namespace.

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
