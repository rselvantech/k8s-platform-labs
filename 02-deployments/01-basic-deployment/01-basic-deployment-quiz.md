# Quiz — 02-deployments/01-basic-deployment: Basic Deployment

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.


**Q1. `kubectl get deploy --show-labels` shows `<none>` for `nginx-deploy` even though every Pod clearly has labels. Why?**

- A) Labels only ever apply to Pods, never to Deployments
- B) `metadata.labels` (the Deployment's own labels) and `spec.template.metadata.labels` (the Pod's labels) are two separate fields, and this YAML never set the former
- C) This is a display bug in `--show-labels`
- D) Deployment labels are hidden by default and need `-o wide`

<details>
<summary>Answer</summary>

**B** — `kubectl apply -f` never sets labels on the Deployment object itself unless you put them in the YAML's own `metadata.labels`, which this demo's manifest doesn't.
Trap: A overgeneralizes — Deployments absolutely can carry their own labels, this one just doesn't.

</details>

---

**Q2. Raising `spec.minReadySeconds` above its default of 0 changes what, exactly?**

- A) How long the scheduler waits before assigning a node
- B) How long a newly created Pod must stay Ready before it counts as available
- C) How long `kubectl apply` blocks before returning
- D) The ReplicaSet's reconciliation interval

<details>
<summary>Answer</summary>

**B** — It's a soak period per Pod, useful when a Pod can pass its readiness probe before it's genuinely warmed up.
Trap: A confuses this with scheduling, which happens well before this field ever comes into play.

</details>

---

**Q3. If a rollout genuinely never progresses for the full `progressDeadlineSeconds` window (default 600s), what actually happens?**

- A) The Deployment automatically rolls back to the previous ReplicaSet
- B) The Deployment's `Conditions` reports it as failed to progress — nothing is reverted or halted automatically
- C) All Pods are force-deleted and recreated
- D) `kubectl apply` starts refusing further changes

<details>
<summary>Answer</summary>

**B** — This field is a stuck-rollout *detector*, not an automatic remediation — it only changes what `kubectl describe` reports in `Conditions`.
Trap: A assumes automatic rollback, which isn't what this field does at all.

</details>

---

**Q4. What capability does `kubectl.kubernetes.io/last-applied-configuration` actually give `kubectl apply` that `create`/`replace` don't have?**

- A) The ability to compute a proper 3-way diff on the next `apply`, instead of blindly overwriting
- B) Faster reconciliation
- C) Automatic rollback on failure
- D) It's purely cosmetic, shown only in `-o yaml`

<details>
<summary>Answer</summary>

**A** — It stores exactly what you last applied, which is what lets the next `apply` compare stored-vs-live-vs-new rather than overwrite wholesale.
Trap: D dismisses a field that has real functional purpose, not just display value.

</details>

---

**Q5. `generation` is `6` and `status.observedGeneration` is also `6` on this Deployment. What does that tell you?**

- A) The Deployment has been updated 6 times and rolled back once
- B) The controller has fully processed the latest spec change — a mismatch would mean it's behind or stuck
- C) There are 6 ReplicaSets currently active
- D) 6 Pods have been created in this Deployment's lifetime

<details>
<summary>Answer</summary>

**B** — `generation` increments on every `spec` change; `observedGeneration` catching up to it means the controller is caught up. A persistent gap between them is the actual signal to watch for.
Trap: C and D both invent unrelated meanings for a number that's really just a spec-change counter.

</details>

---

**Q6. What is `resourceVersion` actually for, and should you ever set it yourself?**

- A) It's etcd's internal version counter for optimistic concurrency control — you never set it yourself
- B) It's a user-facing version tag for your own release tracking
- C) It increments only when Pods are added or removed
- D) It's required in every YAML manifest before `apply`

<details>
<summary>Answer</summary>

**A** — It exists so two simultaneous updates to the same object can't silently clobber each other; it's entirely internal bookkeeping.
Trap: B mistakes it for something meant for humans to read meaning into, which it isn't.

</details>

---

**Q7. You delete `nginx-deploy` and immediately recreate a Deployment with the exact same name. Does it get the same `uid`?**

- A) Yes, `uid` is derived from the name
- B) No — `uid` is a new, cluster-wide unique identifier every time, regardless of name reuse
- C) Only if you recreate it within the same `resourceVersion` window
- D) Only if `revisionHistoryLimit` hasn't been exceeded

<details>
<summary>Answer</summary>

**B** — The name is not the real underlying identity; `uid` is, and a same-named recreated object gets a brand-new one.
Trap: A assumes name and identity are the same thing, which this field specifically disproves.

</details>

---

**Q8. In `kubectl describe deployment`, `Conditions` shows both `Available: True` and `Progressing: True`. Are these the same signal?**

- A) Yes, they always move together
- B) No — `Available` reflects whether enough Pods are currently up; `Progressing` reflects whether the controller is making forward progress (or has stalled)
- C) `Progressing` is only ever `True` during an active rolling update
- D) `Available` is deprecated in favor of `Progressing`

<details>
<summary>Answer</summary>

**B** — Both being `True` here just means "healthy and stable," not "actively doing something" — they're independent health signals.
Trap: C is a reasonable-sounding guess but wrong for this demo: both conditions are `True` even with nothing actively rolling out.

</details>

---

**Q9. Is `kubectl edit deployment nginx-deploy` a separate reconciliation mechanism from `kubectl apply -f`?**

- A) Yes, `edit` bypasses the normal controllers entirely
- B) No — saving from `edit` sends the full modified object back to the API server as an update, and everything downstream is identical to any other write
- C) `edit` only works on `spec.replicas`, nothing else
- D) `edit` requires `--record` to actually persist changes

<details>
<summary>Answer</summary>

**B** — It's closer to `kubectl replace`'s semantics than `apply`'s 3-way merge, but it still goes through the same reconciliation path once saved.
Trap: A imagines a special bypass path that doesn't exist — every write ends up in the same place.

</details>

---

**Q10. After scaling to 0 and back up to 3, does the Deployment create a brand-new ReplicaSet to bring the Pods back?**

- A) Yes, scaling to 0 deletes the ReplicaSet along with the Pods
- B) No — the same ReplicaSet (same `pod-template-hash`) is reused, since the pod template never changed
- C) Only if `revisionHistoryLimit` allows it
- D) A new ReplicaSet is created, but the old one is also kept as `OldReplicaSets`

<details>
<summary>Answer</summary>

**B** — Scaling never changes the pod template, so there's no new hash to compute — the existing ReplicaSet is just told to reconcile against a new number again.
Trap: A confuses "zero Pods" with "the ReplicaSet object itself is gone," which isn't what scaling to 0 does.

</details>

---

**Q11. This demo's YAML never sets `spec.strategy`, yet `kubectl describe` shows `RollingUpdateStrategy: 25% max unavailable, 25% max surge`. Where do these numbers come from?**

- A) They're hardcoded into every nginx image
- B) They're the API server's own default values, applied because `spec.strategy` was never set
- C) They only appear after the first `kubectl edit`
- D) minikube sets them at cluster install time

<details>
<summary>Answer</summary>

**B** — Same API-server-side defaulting behavior that fills in `progressDeadlineSeconds` and `revisionHistoryLimit` even when your YAML never mentions them.
Trap: D invents a cluster-level explanation for something that's actually just object-level defaulting, unrelated to minikube specifically.

</details>

---

**Q12. `kubectl describe deployment` shows `OldReplicaSets: <none>` in this demo. Under what circumstance would that field start showing an actual ReplicaSet instead?**

- A) After scaling up past the original replica count
- B) After the pod template changes, producing a new `pod-template-hash` and therefore a new ReplicaSet — the old one sticks around at 0 replicas
- C) After `kubectl edit` is used instead of `kubectl apply`
- D) After more than 3 replicas exist simultaneously

<details>
<summary>Answer</summary>

**B** — This field only ever has content once there's a template change to compare against — exactly the mechanism `02-rolling-update-recreate` builds on, just not yet exercised in this demo.
Trap: A and D both assume replica *count* changes are what populate this field, when it's actually template changes (and therefore hash changes) that do.

</details>

---

**Q13. Which namespace does the built-in `service/kubernetes` ClusterIP actually live in?**

- A) Every namespace, automatically
- B) Only the `default` namespace
- C) Only `kube-system`
- D) Whichever namespace you last ran `kubectl apply` in

<details>
<summary>Answer</summary>

**B** — It's created and pinned to `default` by the control plane. `kubectl get all -n <other-namespace>` will not show it.
Trap: A is the natural but incorrect assumption from seeing it appear in this demo's `get all` output — it only shows up here because the lab stays in `default`.

</details>

---

**Q14. How does `kubectl rollout restart deployment/nginx` differ from `kubectl scale deployment nginx --replicas=N`?**

- A) They're two names for the same operation
- B) `rollout restart` recreates every existing pod with the unchanged template; `scale` only changes the replica count
- C) `scale` recreates pods; `rollout restart` only changes the count
- D) `rollout restart` requires editing the YAML file first

<details>
<summary>Answer</summary>

**B** — `rollout restart` forces a fresh set of Pods (same `pod-template-hash`, same ReplicaSet) via a restart-timestamp annotation — useful for picking up a changed ConfigMap/Secret. `scale` never recreates existing Pods, it only changes how many exist.
Trap: C reverses the two operations' actual behavior.

</details>

---

**Q15. You run `kubectl scale replicaset nginx-deploy-85f7d4dd78 --replicas=1` directly. What happens?**

- A) It stays at 1 replica permanently
- B) The Deployment controller reconciles it back to match the Deployment's own `spec.replicas` within seconds
- C) The Deployment is deleted
- D) It's rejected outright — you can't scale a ReplicaSet directly

<details>
<summary>Answer</summary>

**B** — The ReplicaSet controller briefly honors your value, but the Deployment controller notices the mismatch against its own `spec.replicas` and reconciles it back.
Trap: D assumes a hard restriction that doesn't exist — the command succeeds, it just doesn't stick.

</details>

---

**Q16. What do the `deployment.kubernetes.io/desired-replicas` and `max-replicas` annotations on a ReplicaSet represent?**

- A) Values you're expected to set yourself in the ReplicaSet's YAML
- B) Values written by the Deployment controller — `max-replicas` includes the rounded-up `maxSurge`
- C) The ReplicaSet's own internal scaling limits, unrelated to any Deployment
- D) Historical values from the ReplicaSet's very first revision only

<details>
<summary>Answer</summary>

**B** — Visible via `kubectl describe rs`, these are the Deployment controller's own bookkeeping on the ReplicaSet it owns — `max-replicas` is exactly why `describe deployment`'s `RollingUpdateStrategy` percentages translate into a concrete extra Pod.
Trap: A assumes these are user-configurable fields — they aren't, they're controller-written.

</details>

---

**Q17. What does `kubectl delete deployment nginx-deploy --cascade=orphan` do differently from a plain `kubectl delete deployment nginx-deploy`?**

- A) Nothing — they're identical
- B) It deletes only the Deployment object, leaving the ReplicaSet and Pods running orphaned instead of cascading the delete to them
- C) It deletes the Deployment and ReplicaSet, but keeps the Pods' data in a PersistentVolume
- D) It pauses the Deployment instead of deleting it

<details>
<summary>Answer</summary>

**B** — A plain delete cascades via owner references (per `01-basic-deployment`'s End-to-End section) all the way down to the Pods; `--cascade=orphan` deletes only the top object, leaving everything below it running with no owner.
Trap: A ignores that this flag exists specifically to change cascade behavior — it wouldn't be documented separately if it behaved identically.

</details>

Score guide:

| Score | Action |
|---|---|
| 15-17/17 | Import Anki cards, move to next Demo |
| 12-14/17 | Review the wrong answers, then proceed |
| 9-11/17 | Re-read the relevant section, retry those questions |
| Below 9/17 | Re-read the full demo and redo the walkthrough before proceeding |
