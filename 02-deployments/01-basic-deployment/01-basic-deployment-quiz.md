# Quiz — 02-deployments/01-basic-deployment: Basic Deployment

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. Does a Deployment ever create or delete a Pod directly?**

- A) Yes, it manages Pods directly with no intermediate object
- B) No — it manages a ReplicaSet, which manages Pods
- C) Only during a rolling update
- D) Only when replicas is set to 0

<details>
<summary>Answer</summary>

**B** — It's a strict two-hop chain of command: Deployment → ReplicaSet → Pod, each level reconciling only its own tier.
Trap: A is the common oversimplified mental model that this demo specifically corrects.

</details>

---

**Q2. What is `pod-template-hash` and where does it come from?**

- A) A random UUID assigned at cluster install time
- B) A hash computed from the pod template, added to the ReplicaSet's name, selector, and Pods
- C) A checksum of the container image
- D) The Deployment's own resourceVersion

<details>
<summary>Answer</summary>

**B** — It's derived from `spec.template`, which is exactly why changing the template produces a new hash and a new ReplicaSet.
Trap: C confuses this with image content — it has nothing to do with the image itself, only the pod template as a whole.

</details>

---

**Q3. Which controller actually recreates a manually deleted pod under a Deployment?**

- A) The Deployment controller
- B) The ReplicaSet controller
- C) kube-scheduler
- D) kubelet

<details>
<summary>Answer</summary>

**B** — The ReplicaSet controller is the one watching actual Pod count against `spec.replicas` and reconciling the difference.
Trap: A is the common but imprecise "the Deployment self-heals" framing — technically it's one level down.

</details>

---

**Q4. When would you actually need `matchExpressions` instead of `matchLabels`?**

- A) Whenever you have more than one label
- B) Only when you need NotIn, Exists, or DoesNotExist
- C) matchExpressions is always required for Deployments
- D) Never — matchLabels can express everything matchExpressions can

<details>
<summary>Answer</summary>

**B** — Those three operators have no `matchLabels` equivalent at all; a plain equality match should just use `matchLabels`.
Trap: D overcorrects — `matchExpressions` genuinely can express things `matchLabels` cannot, it's just unnecessary for simple cases.

</details>

---

**Q5. Can you change `spec.selector` on an existing Deployment with `kubectl apply`?**

- A) Yes, it updates immediately
- B) No — it's immutable; the only fix is delete and recreate
- C) Yes, but only if replicas is 0
- D) Yes, but it requires `--force`

<details>
<summary>Answer</summary>

**B** — Same immutability rule already seen on certain Pod fields, applied here to a different object's field.
Trap: C invents a workaround condition that doesn't exist — immutability isn't conditional on replica count.

</details>

---

**Q6. What mechanism makes deleting a Deployment cascade to its ReplicaSet and Pods automatically?**

- A) A hardcoded cleanup script in kube-controller-manager
- B) Owner references
- C) The pod-template-hash label
- D) Finalizers on the Deployment object itself

<details>
<summary>Answer</summary>

**B** — Each ReplicaSet declares its Deployment as owner, and each Pod declares its ReplicaSet as owner; Kubernetes' garbage collector uses these to cascade deletes.
Trap: C is a real, related mechanism but doesn't drive deletion — it's used for selector precision, not ownership/GC.

</details>

---

**Q7. What does `kubectl scale deployment nginx --replicas=5` actually modify?**

- A) It directly creates 5 pods itself
- B) Only the Deployment's `spec.replicas` — the ReplicaSet controller does the actual Pod work
- C) It modifies the ReplicaSet's pod-template-hash
- D) It triggers a rolling update

<details>
<summary>Answer</summary>

**B** — Scaling never touches Pods directly; it's a one-field change that the Deployment controller propagates down to the ReplicaSet.
Trap: D is wrong for this demo's scope — no template change occurred, so there's nothing for a rolling update to do.

</details>

---

**Q8. A Deployment's `spec.template.metadata.labels` doesn't satisfy `spec.selector`. What happens?**

- A) The Deployment is created but manages zero pods
- B) The apply is rejected outright with a schema validation error
- C) Kubernetes automatically fixes the mismatched label
- D) The ReplicaSet is created but stuck at 0 replicas forever

<details>
<summary>Answer</summary>

**B** — This fails immediately at `apply` time — one of the more catchable Kubernetes errors, provided you recognize the message shape.
Trap: A and D both imagine a partial-success state that doesn't actually happen here — the whole object is rejected, nothing is created.

</details>

---

**Q9. Why does a Deployment use `apiVersion: apps/v1` instead of `v1` like a Pod?**

- A) apps/v1 is just a newer, interchangeable name for v1
- B) Core/foundational types use v1; controller types that manage other objects use the separate apps group
- C) apiVersion doesn't actually matter, kubectl infers it from `kind`
- D) apps/v1 is only used in production clusters

<details>
<summary>Answer</summary>

**B** — Pod, Service, Namespace stay in the core `v1` group; Deployment, ReplicaSet, StatefulSet, DaemonSet live in the separate `apps` group since they're controllers managing other objects.
Trap: C is wrong and dangerous to believe — getting `apiVersion` wrong produces a real schema-validation rejection, not silent inference.

</details>

---

**Q10. A pod is named `nginx-deploy-85f7d4dd78-29r6g`. What does the `29r6g` part represent?**

- A) The same pod-template-hash as `85f7d4dd78`, just truncated
- B) A separate random suffix generated per-pod, purely for name uniqueness among siblings
- C) The node the pod is scheduled on
- D) A checksum of the container's image

<details>
<summary>Answer</summary>

**B** — Every pod from the same ReplicaSet shares `85f7d4dd78` (the pod-template-hash) but gets its own distinct second suffix, which is what keeps sibling pod names unique.
Trap: A conflates the two suffixes as if they were the same thing, which is exactly the confusion this section exists to clear up.

</details>

---

**Q11. Does `kubectl get all` include ConfigMaps and Secrets in its output?**

- A) Yes, along with everything else in the namespace
- B) No — it only covers a fixed set of common types like Pods, Services, Deployments, ReplicaSets
- C) Only if `--all-namespaces` is added
- D) Only ConfigMaps, not Secrets

<details>
<summary>Answer</summary>

**B** — "all" is narrower than it sounds; ConfigMaps, Secrets, Ingress, PVCs, and any CRD-based object all need to be queried separately.
Trap: A is the natural but incorrect assumption the command's name invites.

</details>

---

**Q12. Can `kubectl exec deployment/nginx-deploy -- <cmd>` run without naming a specific pod?**

- A) No — Deployments don't support exec at all
- B) Yes — kubectl resolves it to the ReplicaSet and picks one arbitrary pod
- C) Yes, but it runs the command on every pod simultaneously
- D) Only if the Deployment has exactly one replica

<details>
<summary>Answer</summary>

**B** — Convenient when you don't care which specific replica, but it's still just one pod, not all of them — the same resolution pattern already seen with `kubectl port-forward deployment/...`.
Trap: C assumes fan-out behavior that doesn't exist — it's always exactly one pod, chosen arbitrarily.

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

Score guide:
| Score | Action |
|---|---|
| 13-14/14 | Import Anki cards, move to next Demo |
| 10-12/14 | Review the wrong answers, then proceed |
| 8-9/14 | Re-read the relevant section, retry those questions |
| Below 8/14 | Re-read the full demo and redo the walkthrough before proceeding |
