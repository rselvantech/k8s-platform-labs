# Quiz — 02-deployments/02-rolling-update-recreate: Rolling Updates, Recreate Strategy, and Rollback

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. When a rolling update happens, what actually happens to the existing ReplicaSet?**

- A) It's mutated in place with the new pod template
- B) A new ReplicaSet is created with a new pod-template-hash; the old one scales to 0
- C) It's deleted immediately
- D) It's renamed to match the new image version

<details>
<summary>Answer</summary>

**B** — This is the same mechanism from `01-basic-deployment` made concrete: changing the template produces a new hash and therefore a new ReplicaSet.
Trap: A assumes in-place mutation, which contradicts the immutable, hash-based design covered previously.

</details>

---

**Q2. What does `maxSurge: 1` allow during a rollout with `replicas: 3`?**

- A) Exactly 3 pods at all times, no more
- B) Temporarily up to 4 pods
- C) Temporarily down to 2 pods
- D) Unlimited additional pods

<details>
<summary>Answer</summary>

**B** — `maxSurge` adds to the desired count temporarily; with `replicas: 3` and `maxSurge: 1`, you can briefly have 4.
Trap: C describes `maxUnavailable`'s effect, not `maxSurge`'s — easy to mix up which knob does which.

</details>

---

**Q3. Does `maxUnavailable: 0` guarantee zero downtime unconditionally?**

- A) Yes, always, regardless of anything else
- B) No — it depends on new pods actually becoming Ready, which depends on readiness probes
- C) No — it only works with the Recreate strategy
- D) Yes, but only for stateless applications

<details>
<summary>Answer</summary>

**B** — Without a real readiness probe, a container is considered Ready the instant it starts, which is a much weaker signal than most production setups actually rely on.
Trap: A treats this as an unconditional guarantee, ignoring what "Ready" actually depends on.

</details>

---

**Q4. Why might a rollout with `maxSurge: 1` stall indefinitely?**

- A) Kubernetes has a hard limit of 3 replicas per Deployment
- B) The surge pod's resource requests may exceed what any node can satisfy, so it never schedules
- C) maxSurge only works with Recreate strategy
- D) Rollouts always stall after exactly 1 pod

<details>
<summary>Answer</summary>

**B** — The surge pod is scheduled exactly like any other pod — if nothing has room for it, it stays Pending forever and the rollout never completes.
Trap: A invents a limit that doesn't exist — replica counts aren't capped at 3.

</details>

---

**Q5. Does `kubectl rollout undo` restore the old revision number, or create a new one?**

- A) It restores the exact old revision number
- B) It creates a new revision copying the old configuration forward
- C) It deletes all revision history
- D) It merges the old and current revisions

<details>
<summary>Answer</summary>

**B** — The old revision number disappears from history; what you get is a new revision with the old config.
Trap: A is the intuitive but incorrect assumption — revision numbers only ever increase, never get reused.

</details>

---

**Q6. What happens if you run `kubectl rollout undo --to-revision=99` and revision 99 was never created?**

- A) It rolls back to the closest available revision automatically
- B) It fails with an explicit "unable to find specified revision" error
- C) It creates revision 99 from the current state
- D) It silently does nothing

<details>
<summary>Answer</summary>

**B** — kubectl fails outright rather than guessing at your intent — check `kubectl rollout history` first to know which revisions actually exist.
Trap: A imagines a fallback behavior that doesn't exist — there's no "closest match" logic.

</details>

---

**Q7. What bounds how far back in history you can roll back a Deployment?**

- A) There's no limit, ever
- B) `spec.revisionHistoryLimit` (default 10) — older revisions get pruned
- C) Exactly 3 revisions, hardcoded
- D) `spec.replicas`

<details>
<summary>Answer</summary>

**B** — This field was introduced (deferred) back in `01-basic-deployment`'s Anatomy section — this is where it actually becomes relevant.
Trap: C invents a fixed number that isn't accurate — the real default is 10, and it's configurable.

</details>

---

**Q8. Is `--record` a reliable way to track why a Deployment changed on a current cluster?**

- A) Yes, it's the current best practice
- B) No — the official Deployments documentation marks it deprecated and slated for removal, and it may already be an unrecognized flag on recent kubectl
- C) `--record` was never a real flag
- D) It's required for `kubectl rollout history` to work at all

<details>
<summary>Answer</summary>

**B** — `--record` is officially deprecated, and current reports show it may already fail outright as an unrecognized flag; setting the `change-cause` annotation directly (in YAML or via `kubectl annotate`) is the current, reliable approach.
Trap: D overstates its necessity — `rollout history` works fine without any change-cause tracking, it just shows a blank `CHANGE-CAUSE` column.

</details>

---

**Q9. What does `kubectl rollout pause` actually do?**

- A) Stops all pods immediately
- B) Freezes the Deployment controller from acting on further changes, leaving a mix of old and new pods until resumed
- C) Deletes the current ReplicaSet
- D) Reverts to the previous revision automatically

<details>
<summary>Answer</summary>

**B** — It's a controlled stop, not a rollback — pods already updated stay updated, pods not yet touched stay as they were, until `kubectl rollout resume`.
Trap: D confuses pausing with rolling back — pause never changes the target revision, it just stops progress toward it.

</details>

---

**Q10. Is `kubectl rollout restart` the same thing as switching a Deployment to the `Recreate` strategy?**

- A) Yes, they behave identically
- B) No — `rollout restart` follows whichever strategy is already configured (RollingUpdate or Recreate) and does change the template via a `restartedAt` annotation; `Recreate` is a separate `spec.strategy.type` value that always kills all pods first, regardless of what triggered the update
- C) `rollout restart` only works if the strategy is already `Recreate`
- D) `rollout restart` changes the strategy to `Recreate` temporarily

<details>
<summary>Answer</summary>

**B** — `rollout restart` and `Recreate` are unrelated beyond sharing the word "recreate" in casual conversation: one is a way to *trigger* a rollout (via a template annotation change), the other is a `strategy.type` value that governs *how* any rollout — triggered by anything — replaces Pods.
Trap: D imagines `rollout restart` temporarily borrows the `Recreate` strategy — it never does; it always respects whatever strategy is already configured.

</details>

---

**Q11. You apply a second Deployment update while the first rollout is still in progress. What happens?**

- A) The second update queues and waits for the first to finish
- B) Kubernetes immediately creates a new ReplicaSet and rolls the previously-newest one into the old list, scaling it down alongside the rest — this is Rollover
- C) The second update is rejected until the first completes
- D) Both updates merge into a single ReplicaSet

<details>
<summary>Answer</summary>

**B** — There's no queue. A new `pod-template-hash` is computed the instant a new template is seen, regardless of what's already mid-rollout.
Trap: A assumes Kubernetes serializes updates for safety — it doesn't; Rollover is deliberate, not an edge case to guard against.

</details>

---

**Q12. You scale a Deployment while a rollout is still converging between two ReplicaSets. Where do the new replicas go?**

- A) All to the newest ReplicaSet
- B) All to the oldest ReplicaSet
- C) Distributed proportionally across every ReplicaSet still in play
- D) Evenly split 50/50 regardless of current state

<details>
<summary>Answer</summary>

**C** — Proportional scaling weights the distribution by each ReplicaSet's current share, keeping the configured surge/unavailable ratio roughly honored throughout.
Trap: A is the intuitive but incorrect assumption — it feels like new capacity should go to the new version, but Kubernetes spreads it proportionally instead.

</details>

---

**Q13. Can a Deployment be configured with `maxSurge: 0` and `maxUnavailable: 0` at the same time?**

- A) Yes, this is the safest possible configuration
- B) No — the API rejects it outright, since neither pod addition nor removal would ever be allowed
- C) Yes, but only with the Recreate strategy
- D) Only if `replicas` is also 0

<details>
<summary>Answer</summary>

**B** — With neither knob allowed to move, a rollout using this Deployment could never make progress at all, so Kubernetes rejects the configuration rather than accepting a guaranteed deadlock.
Trap: A assumes "zero everything" means "maximally safe" — it actually means "impossible," not safe.

</details>

---

**Q14. A Deployment shows `Progressing: False, Reason: ProgressDeadlineExceeded`. Did Kubernetes automatically roll it back?**

- A) Yes, automatically, to the previous revision
- B) No — this is purely a reported condition; the stalled ReplicaSet stays exactly as it was until you intervene
- C) Yes, but only if `revisionHistoryLimit` allows it
- D) It automatically scales the Deployment to 0

<details>
<summary>Answer</summary>

**B** — `ProgressDeadlineExceeded` is diagnostic, not corrective — `kubectl rollout status` also exits non-zero once it fires, but nothing reverts on its own; you still need `kubectl rollout undo` or to fix the underlying problem yourself.
Trap: A assumes Kubernetes protects you automatically from a stuck rollout — it only reports the problem, it doesn't fix it.

</details>

**Q15. What does `spec.strategy.type: Recreate` guarantee about Pod overlap?**

- A) New pods are always created before old ones are removed
- B) Old pods are always fully removed before any new pod is created
- C) Exactly 50% of pods are replaced at a time
- D) It behaves identically to RollingUpdate with `maxUnavailable: 100%`

<details>
<summary>Answer</summary>

**B** — Recreate strictly sequences termination then creation; there's never a moment with both old and new Pods present.
Trap: D sounds plausible but `maxUnavailable` doesn't apply to Recreate at all — it's a RollingUpdate-only field.

</details>

---

**Q16. A Deployment sets `strategy.type: Recreate` and also `strategy.rollingUpdate.maxSurge: 1`. What happens?**

- A) The API rejects the object as invalid
- B) `maxSurge` is silently ignored — Recreate never reads `rollingUpdate` fields
- C) Kubernetes automatically switches the strategy to RollingUpdate
- D) One pod is surged despite the Recreate setting

<details>
<summary>Answer</summary>

**B** — schema validation allows the field to be present; Recreate's controller logic simply never consults it.
Trap: A assumes stricter validation than actually exists.

</details>

---

**Q17. A bad image is rolled out under Recreate. Compared to the same mistake under RollingUpdate with `maxUnavailable: 0`, what's different?**

- A) Nothing — both result in full outages
- B) Recreate causes a full outage since the old ReplicaSet already scaled to 0; RollingUpdate keeps old pods running until the replacement is Ready
- C) RollingUpdate causes the outage instead
- D) Both stay fully available regardless of strategy

<details>
<summary>Answer</summary>

**B** — this is the clearest practical argument for why RollingUpdate is the default, not Recreate.
Trap: A ignores that `maxUnavailable: 0` specifically exists to prevent exactly this outage.

</details>

---

**Q18. Does `kubectl rollout undo` behave differently depending on whether the Deployment currently uses RollingUpdate or Recreate?**

- A) The command itself is different for each strategy
- B) The mechanism is identical, but Recreate rollback still causes a downtime window on the way back — RollingUpdate rollback doesn't
- C) Rollback isn't supported under Recreate
- D) Rollback always forces the strategy back to RollingUpdate

<details>
<summary>Answer</summary>

**B** — same command, same revision-history mechanism; only the replacement choreography during the rollback differs.
Trap: C wrongly assumes strategy limits rollback capability — only *how* the rollback plays out changes.

</details>

Score guide:
| Score | Action |
|---|---|
| 16-18/18 | Import Anki cards, move to next Demo |
| 14-15/18 | Review the wrong answers, then proceed |
| 11-13/18 | Re-read the relevant section, retry those questions |
| Below 11/18 | Re-read the full demo and redo the walkthrough before proceeding |
