# Quiz — 11-auto-scaling/05-keda-redis-scaler: KEDA Redis Scaler — Secured Queue Consumer

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next demo.

**Q1. What does `activationListLength: 1` mean for a redis-type KEDA trigger?**

- A) The scaler activates once the list reaches exactly 1 item
- B) The scaler stays inactive while the list length is at or below 1; activation requires strictly more than 1
- C) The scaler always keeps at least 1 replica running
- D) The scaler polls every 1 second

<details>
<summary>Answer</summary>

**B** — the activation comparison is strictly greater-than, not `>=`. A queue at exactly the activation
value stays inactive.

Trap A: reverses the comparison direction — "at 1" is exactly the boundary that stays inactive, not the
trigger point. Trap C: confuses activation threshold with `minReplicaCount`; a value in the trigger's
`metadata` doesn't set a replica floor. Trap D: confuses `activationListLength` with `pollingInterval`,
a completely separate field governing poll frequency, not the activation value itself.

</details>

---

**Q2. In `TriggerAuthentication.spec.secretTargetRef`, what does the `parameter` field refer to?**

- A) A Kubernetes API field name
- B) The name the specific scaler expects internally for that credential
- C) The namespace the Secret lives in
- D) A label selector

<details>
<summary>Answer</summary>

**B** — it maps a Secret's value to an argument name in the scaler's own configuration; the exact name
varies by scaler type (`password` for redis).

Trap A: `parameter` looks like it should be a standard Kubernetes API concept given the surrounding YAML,
but it's scaler-internal, not part of the Kubernetes object model. Trap C: namespace scoping is handled by
`metadata.namespace` on the TriggerAuthentication itself, unrelated to `parameter`. Trap D: label selectors
use `matchLabels`/`matchExpressions`, an entirely different mechanism with no relation to credential wiring.

</details>

---

**Q3. Why does editing a TriggerAuthentication's secretTargetRef key have no immediate effect on an
already-running scaler?**

- A) KEDA caches TriggerAuthentication objects for 24 hours
- B) Redis doesn't re-check credentials on an already-open, authenticated connection
- C) The patch command silently failed
- D) TriggerAuthentication changes require a full cluster restart

<details>
<summary>Answer</summary>

**B** — an existing connection isn't re-validated; the failure only surfaces on the next fresh connection
attempt.

Trap A: there's no such fixed caching window documented anywhere in KEDA — this invents a plausible-sounding
but fictional mechanism. Trap C: the patch genuinely succeeds (confirmed via `kubectl get ... -o yaml`
showing the new key) — the object updates correctly, it's the live connection that doesn't re-check it.
Trap D: wildly overstates the fix — a targeted operator restart (not a full cluster restart) is enough to
force reconnection, as shown in Break-Fix 2.

</details>

---

**Q4. `kubectl describe hpa` shows `Min replicas: 1` for a KEDA-managed HPA whose ScaledObject specifies
`minReplicaCount: 0`. What's the correct interpretation?**

- A) This is a bug — the values should always match
- B) KEDA manages the 0-to-1 transition itself, outside the HPA's own bounds
- C) The ScaledObject failed to apply correctly
- D) minReplicaCount only takes effect after the first successful scale event

<details>
<summary>Answer</summary>

**B** — check the ScaledObject's own `minReplicaCount`, not the HPA's derived field, for the true
scale-to-zero floor.

Trap A: assumes the two fields are meant to mirror each other; they deliberately don't — this is expected
behavior, not a defect. Trap C: the ScaledObject applies and reports `Ready: True` correctly in this
scenario — nothing failed. Trap D: invents a timing condition that doesn't exist; the discrepancy is present
from the very first `describe hpa`, not something that resolves after a scale event.

</details>

---

**Q5. Why does the Bitnami Redis chart deploy a StatefulSet rather than a Deployment, even in single-replica
standalone mode?**

- A) StatefulSets are required for all Helm charts
- B) Deployments can't run containers that use persistent volumes
- C) Stable, predictable pod identity is architecturally needed for stateful services, even if the
  multi-replica benefit isn't exercised at one replica
- D) StatefulSets start faster than Deployments

<details>
<summary>Answer</summary>

**C** — stateful services need stable, predictable pod identity (ordinal naming) and, at multiple replicas,
storage that follows a specific ordinal across rescheduling — the chart is architected this way so it works
correctly the moment you scale beyond standalone mode.

Trap A: false — the vast majority of Helm charts, including most workloads in this series, deploy
Deployments; there's no such blanket requirement. Trap B: Deployments can absolutely mount persistent
volumes — the distinction is about pod *identity* (stable naming/ordinal storage), not volume support at
all. Trap D: no meaningful startup-speed difference between the two controller types; this isn't a real
consideration in choosing between them.

</details>

---

**Q6. A producer pushes items to a Redis list named `jobs-queue`, but the ScaledObject's trigger specifies
`listName: work-queue`. What happens?**

- A) KEDA scales based on the total across all lists in the Redis instance
- B) An error appears in the ScaledObject's events immediately
- C) Nothing visible happens — the ScaledObject never activates, with no error anywhere
- D) KEDA automatically detects and corrects the mismatch

<details>
<summary>Answer</summary>

**C** — the ScaledObject's `listName: work-queue` trigger is scoped precisely; Redis Lists at any other key
are invisible to it, no matter how much data accumulates there.

Trap A: the redis scaler watches exactly one named list, never an aggregate across the whole instance —
this overstates its scope. Trap B: confirmed directly in Break-Fix 3 — no error surfaces anywhere; this is
precisely what makes the mismatch dangerous in practice. Trap D: KEDA has no name-matching or auto-correction
logic; a typo or mismatch is silent until someone notices manually.

</details>

---

**Q7. Is there an imperative `kubectl create` shortcut for `ScaledObject`, `TriggerAuthentication`, or
`StatefulSet`?**

- A) Yes, for all three
- B) Yes, only for StatefulSet
- C) No, for all three — all must be written as full YAML
- D) Yes, only for ScaledObject

<details>
<summary>Answer</summary>

**C** — `ScaledObject` and `TriggerAuthentication` are CRDs with no generic imperative verb, and
`StatefulSet`, despite being a built-in Kubernetes type, was never given a `kubectl create` shortcut either.

Trap A and D: both assume at least one of these has an imperative path, likely by analogy to
`kubectl create deployment`/`kubectl autoscale`. Trap B: singles out StatefulSet as the exception, but it's
equally YAML-only as the two CRDs — no partial exception exists here.

</details>

---

**Q8. A container fails to resolve a valid Kubernetes Service DNS name with "Name has no usable address,"
while `nslookup` against the same name succeeds. What's the most likely cause?**

- A) The Service doesn't actually exist
- B) A musl libc (Alpine Linux) DNS resolver limitation
- C) CoreDNS is down
- D) The container has no network connectivity at all

<details>
<summary>Answer</summary>

**B** — confirm via `nslookup` (works) vs `getent hosts` (fails) inside the affected container; fix by
switching to a glibc-based image.

Trap A: ruled out by the premise itself — `nslookup` succeeding confirms the Service and its DNS record
genuinely exist. Trap C: also ruled out by the same fact — if CoreDNS were down, `nslookup` would fail too,
not just the application's own resolution path. Trap D: a total connectivity failure would break `nslookup`
as well; the split between "one tool works, one doesn't" is the specific signature that points to the
resolver library itself, not the network.

</details>

---

**Q9. What kubectl action can force KEDA to attempt a fresh Redis connection, useful for surfacing a stale
credential problem?**

- A) `kubectl delete scaledobject <name>` then reapply
- B) `kubectl rollout restart deployment keda-operator -n keda`
- C) `kubectl edit triggerauthentication <name>`
- D) `kubectl scale deployment <name> --replicas=0`

<details>
<summary>Answer</summary>

**B** — restarting the operator drops any cached/open scaler connections, forcing a genuinely fresh
connection attempt on the next reconcile, exactly as demonstrated in Break-Fix 2.

Trap A: deleting and reapplying the ScaledObject is disruptive and unnecessary — it doesn't target the
actual stale resource (the operator's live connection), and risks losing state unrelated to the auth issue.
Trap C: editing the TriggerAuthentication again is what *causes* a stale-vs-fresh mismatch in the first
place in Break-Fix 2 — it doesn't by itself force reconnection, as the test directly showed (no immediate
error after the first patch). Trap D: scaling the target Deployment doesn't touch KEDA's own connection to
Redis at all; the scaler's connection lives at the operator level, not the workload level.

</details>

---

**Q10. `RPUSH` and `BRPOP` from opposite ends of a Redis List gives what ordering?**

- A) LIFO (last-in-first-out)
- B) FIFO (first-in-first-out)
- C) Random order
- D) Priority order based on value

<details>
<summary>Answer</summary>

**B** — pushing onto the right end and popping from the right end (with `RPUSH`/`BRPOP`, opposite operations
on the same "tail vs head" axis as their names suggest) drains items in the order they arrived.

Trap A: LIFO would result from pushing and popping the *same* end (e.g. `RPUSH`+`RPOP`) — a common
confusion since Lists support both ends. Trap C: Redis Lists are strictly ordered by insertion; there's no
randomness anywhere in the data structure. Trap D: Lists have no concept of value-based priority at all —
that would require a Sorted Set (`ZADD`/`ZRANGE`), a different Redis data type entirely.

</details>

Score guide:
| Score | Action |
|---|---|
| 10/10 | Import Anki cards, move to next Demo |
| 8–9/10 | Review the wrong answers, then proceed |
| 6–7/10 | Re-read the relevant section, retry those questions |
| Below 6/10 | Re-read the full demo and redo the walkthrough before proceeding |
