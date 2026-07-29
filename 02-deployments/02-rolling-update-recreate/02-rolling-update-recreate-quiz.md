# Quiz — 02-deployments/02-rolling-update-recreate: Rolling Updates, Recreate Strategy, and Rollback

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.
> This quiz does not restate the Anki deck's facts verbatim — it tests
> other Concepts/Lab material the deck doesn't cover.

**Q1. Where is a Deployment's rollout history actually stored?**

- A) In a separate, dedicated history log object
- B) In the ReplicaSets themselves — each one represents one revision, storing the Pod template at the time it was created
- C) In the Deployment's own `status` field only
- D) In etcd's `resourceVersion` history

<details>
<summary>Answer</summary>

**B** — There's no separate log. `kubectl rollout history --revision=N` works by reading a specific ReplicaSet's stored template and its `deployment.kubernetes.io/revision` annotation.
Trap: A imagines infrastructure that doesn't exist — the ReplicaSets themselves *are* the history.

</details>

---

**Q2. `deployment.kubernetes.io/max-replicas: 4` appears on the ReplicaSet even before any rollout starts. Where does this number come from, and when does it first appear?**

- A) It only appears once a rollout is actively in progress
- B) It's precomputed up front from `replicas (3) + maxSurge (1)`, present from the moment the ReplicaSet is created
- C) It's set manually in the YAML
- D) It represents the cluster's total node capacity

<details>
<summary>Answer</summary>

**B** — It's not a mid-rollout artifact — it's calculated once, immediately, and just happens to only become operationally relevant once a surge actually occurs.
Trap: A assumes anything surge-related must be rollout-only — this field is present the whole time, whether or not it's ever exercised.

</details>

---

**Q3. If you're editing a Deployment via `kubectl edit` to change both the image and the change-cause annotation, does it matter whether you do both in one edit session or two separate ones?**

- A) No difference either way
- B) Yes — doing both in one session keeps them as a single revision; splitting them into two edits still only creates one revision (image change), and the annotation-only edit doesn't create a new one at all
- C) `kubectl edit` only allows one field change per session
- D) The annotation must always be set before the image, never after

<details>
<summary>Answer</summary>

**B** — Only `spec.template` changes create a new revision; an annotation-only edit afterward just updates the existing revision's annotation, it doesn't add a new row to `rollout history`. Doing both together in one session is simply the cleaner way to keep the change-cause accurate for the revision it actually describes.
Trap: C invents an artificial restriction — `kubectl edit` lets you change as many fields as you want in one session.

</details>

---

**Q4. Does a rollback to a previous revision always create a brand-new ReplicaSet?**

- A) Yes, always
- B) No — if the target revision's ReplicaSet still exists (not yet garbage-collected), it's reused as-is; a new one is only created if it's already gone
- C) Only if `maxSurge` is greater than 0
- D) Only under the Recreate strategy

<details>
<summary>Answer</summary>

**B** — The revision *number* always advances, but the underlying ReplicaSet *object* is reused whenever it's still around — same `pod-template-hash`, just its replica count and revision annotation get updated.
Trap: A conflates "new revision number" with "new ReplicaSet object" — those are two different things that don't always move together.

</details>

---

**Q5. In this demo's Step 8, rolling back to revision 3 didn't require scaling anything up. Why was this particular rollback narrower than a typical one?**

- A) Rollbacks never need to scale anything up
- B) Revision 3's ReplicaSet had never been scaled down — it was still the active, fully-scaled ReplicaSet right up until the bad update, so the rollback only had to scale the bad ReplicaSet down to 0
- C) `--to-revision` was omitted, so Kubernetes chose the fastest path
- D) The cluster had spare capacity, so scaling was instant

<details>
<summary>Answer</summary>

**B** — How much scaling a rollback actually does depends entirely on how far the target ReplicaSet had already drifted from its desired count — not every rollback looks like the general "scale target up, scale current down" description.
Trap: A overgeneralizes from this one example — other rollbacks (e.g. to a ReplicaSet already at 0) absolutely do need to scale up.

</details>

---

**Q6. Does `kubectl rollout restart` set a `change-cause` automatically, the way applying an annotated YAML file does?**

- A) Yes, it always records "restarted" as the cause
- B) No — it only adds a `restartedAt` timestamp annotation; `CHANGE-CAUSE` shows `<none>` unless you separately set it
- C) It reuses the previous revision's change-cause automatically
- D) It requires `--record` to set a change-cause

<details>
<summary>Answer</summary>

**B** — `rollout restart`'s entire mechanism is the `restartedAt` annotation — it has nothing to do with `kubernetes.io/change-cause`, so that column stays blank unless you separately annotate it.
Trap: C imagines an automatic carry-forward that doesn't happen here — a restart's change-cause is blank, not the prior entry's text (that "stale carry-forward" behavior is specifically what happens when you edit the image but forget to touch the annotation, a different situation from restart entirely).

</details>

---

**Q7. Do `minReadySeconds` and `progressDeadlineSeconds` still apply under the Recreate strategy?**

- A) No — they're RollingUpdate-only fields, same as `maxSurge`/`maxUnavailable`
- B) Yes — their meaning doesn't change under Recreate, only what happens to Pod count while the controller works toward satisfying them
- C) Only `progressDeadlineSeconds` applies; `minReadySeconds` is ignored
- D) They're replaced by a Recreate-specific timeout field

<details>
<summary>Answer</summary>

**B** — Unlike `maxSurge`/`maxUnavailable` (which genuinely are RollingUpdate-only and silently ignored under Recreate), `minReadySeconds` and `progressDeadlineSeconds` are strategy-agnostic — they still govern availability/stuck-rollout detection regardless of which strategy is active.
Trap: A incorrectly lumps these two fields in with the fields that actually are RollingUpdate-only.

</details>

---

**Q8. A Deployment's `spec.replicas` is scaled from 3 to 6. Does this create a new revision in `rollout history`?**

- A) Yes, every change to the Deployment creates a revision
- B) No — only changes to `spec.template` create a new revision; scaling alone doesn't touch the template
- C) Only if `revisionHistoryLimit` allows it
- D) Yes, but only if done via `kubectl edit`, not `kubectl scale`

<details>
<summary>Answer</summary>

**B** — Revisions track the Pod template specifically. Scaling changes `spec.replicas`, not `spec.template`, so there's nothing new to version — this is also why a rollback never restores a prior replica count, only a prior template.
Trap: A overgeneralizes "any Deployment change" into "any change creates a revision," which isn't how the mechanism works.

</details>

---

**Q9. This demo's `01-nginx-deploy-v1.yaml` sets a `kubernetes.io/change-cause` annotation before any update ever happens. Why does that first annotation matter for the rest of the demo?**

- A) It doesn't matter — only annotations added during updates are ever meaningful
- B) It establishes revision 1's own change-cause, so `rollout history` has a complete, meaningful record from the very first revision, not just the later ones
- C) It's required for `kubectl rollout undo` to function at all
- D) It sets the cluster-wide default change-cause for all future Deployments

<details>
<summary>Answer</summary>

**B** — Without it, revision 1 would show `<none>` in `CHANGE-CAUSE` forever, since there's no later opportunity to retroactively annotate a past revision — the initial apply is the only chance to give revision 1 a meaningful cause.
Trap: C overstates its necessity — rollback works via revision numbers and stored templates, completely independent of whether any change-cause was ever set.

</details>

---

**Q10. A rollback targets a revision whose ReplicaSet has already been garbage-collected (past `revisionHistoryLimit`). What happens?**

- A) It fails immediately, the same way as targeting a revision number that never existed
- B) It creates a brand-new ReplicaSet from the stored revision's template
- C) It automatically increases `revisionHistoryLimit` to recover the ReplicaSet
- D) It falls back to the oldest still-existing revision

<details>
<summary>Answer</summary>

**A** — If the target revision itself is gone (pruned past the limit, distinct from `--to-revision=99` never having existed at all), `rollout undo` has nothing to reconstruct from and fails the same way as an invalid revision number — knowing which revisions currently exist via `rollout history` is what avoids both failure modes.
Trap: B imagines Kubernetes can somehow reconstruct a pruned revision's template from nothing — once it's gone, it's gone.

</details>

---

**Q11. Does Recreate's "old Pods always fully terminate before new ones are created" guarantee apply to a Pod you delete manually, mid-lifecycle, unrelated to any template change?**

- A) Yes — Recreate enforces strict ordering for any Pod removal, manual or automatic
- B) No — that guarantee is specifically about upgrades (template changes); a manually deleted Pod is replaced immediately by the ReplicaSet controller, the same as under any other strategy
- C) Manual deletion is blocked entirely while using the Recreate strategy
- D) It depends on whether `minReadySeconds` is set

<details>
<summary>Answer</summary>

**B** — Recreate's ordering guarantee is scoped to how the Deployment controller replaces Pods during a rollout — it says nothing about the ReplicaSet controller's ordinary, always-on reconciliation of a manually deleted Pod, which behaves identically under any strategy.
Trap: A over-extends a rollout-specific guarantee to a completely different mechanism (ordinary self-healing) that Recreate has no special rule about at all.

</details>

---

**Q12. Under Recreate, can you ever observe two ReplicaSets both showing a nonzero `CURRENT` count from `kubectl get rs` at the same moment — the way you can under RollingUpdate?**

- A) Yes, briefly, just like RollingUpdate
- B) No — the old ReplicaSet always reaches 0 before the new one starts scaling up at all, so at most one ever has nonzero replicas
- C) Only if `maxSurge` is set alongside `Recreate`
- D) Only during a rollback, never during a forward rollout

<details>
<summary>Answer</summary>

**B** — This is the direct, observable consequence of Recreate's all-or-nothing design — there's no overlap window to catch mid-transition, unlike RollingUpdate where two ReplicaSets visibly coexist.
Trap: C imagines `maxSurge` has any effect under Recreate — it's a RollingUpdate-only field that Recreate's controller logic never reads at all.

</details>

Score guide:

| Score | Action |
|---|---|
| 11-12/12 | Import Anki cards, move to next Demo |
| 9-10/12 | Review the wrong answers, then proceed |
| 7-8/12 | Re-read the relevant section, retry those questions |
| Below 7/12 | Re-read the full demo and redo the walkthrough before proceeding |
