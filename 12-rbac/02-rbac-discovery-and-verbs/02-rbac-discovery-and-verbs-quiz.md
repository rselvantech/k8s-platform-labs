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
