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
