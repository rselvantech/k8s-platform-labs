# Quiz — 02-deployments/03-deployment-strategies: Deployment Strategies

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. What makes Blue-Green's traffic switch instant?**

- A) Both Deployments are updated simultaneously
- B) The Service's selector changes, and its Endpoints list is recomputed immediately — no Deployment changes at all
- C) kubectl restarts all pods
- D) DNS propagation completes instantly in Kubernetes

<details>
<summary>Answer</summary>

**B** — Neither Deployment is touched; only the Service's selector changes, and Endpoints recompute against whichever Pods currently match.
Trap: A assumes both Deployments need coordinated changes, which defeats the entire point of the pattern.

</details>

---

**Q2. Is Canary traffic split ever an exact percentage with native Kubernetes Services?**

- A) Yes, always exact
- B) No — it's approximate, based on pod-count ratio and round-robin balancing
- C) Only if replicas are a multiple of 10
- D) Only with a LoadBalancer type Service

<details>
<summary>Answer</summary>

**B** — 4 stable + 1 canary is "roughly" 20%, not a guaranteed percentage — exact control requires something beyond native Services.
Trap: C invents a mathematical condition that doesn't actually change how load balancing works.

</details>

---

**Q3. A canary pod is stuck in `ImagePullBackOff`. Does it receive any real user traffic?**

- A) Yes, a small amount, since it matches the selector
- B) No — only Ready pods become Service Endpoints
- C) Yes, but only error responses
- D) It depends on the Service type

<details>
<summary>Answer</summary>

**B** — Matching a selector isn't sufficient; a pod must also be `Ready` to become an Endpoint, so a broken canary is invisible to real traffic entirely.
Trap: A assumes label matching alone determines traffic eligibility, ignoring the Ready requirement.

</details>

---

**Q4. Does `kubectl label deployment nginx-canary track=stable --overwrite` change what its Pods are labeled?**

- A) Yes, immediately
- B) No — it only changes the Deployment object's own labels, not `spec.template.metadata.labels`
- C) Yes, but only after the next rollout
- D) It deletes and recreates the Pods with new labels

<details>
<summary>Answer</summary>

**B** — The Deployment's own `metadata.labels` and its Pods' labels (via `spec.template.metadata.labels`) are two separate, independently-set fields — relabeling one never touches the other.
Trap: C imagines a delayed effect that doesn't exist — there's no mechanism that would eventually propagate this relabel to Pods.

</details>

---

**Q5. What happens if a Service selector has a typo'd key, like `versoin` instead of `version`?**

- A) Kubernetes rejects the YAML as invalid
- B) It's accepted as valid YAML but matches zero pods, with no error message
- C) Kubernetes auto-corrects the typo
- D) It falls back to matching all pods

<details>
<summary>Answer</summary>

**B** — Any key name is syntactically legal in a selector map, so this is silently accepted — the failure is a Service matching nothing, not a rejected apply.
Trap: D imagines a permissive fallback that doesn't exist — an empty match stays empty, it doesn't broaden.

</details>

---

**Q6. What is the real resource cost of Blue-Green deployment?**

- A) None — it's completely free
- B) Roughly 2x compute, since both environments run simultaneously during the overlap
- C) Only the cost of the Service object itself
- D) Cost scales with the number of rollbacks performed

<details>
<summary>Answer</summary>

**B** — "Zero downtime" doesn't mean zero cost — running two full production-sized environments at once is genuinely 2x the compute footprint for that window.
Trap: A treats "no downtime" and "no cost" as the same thing, which they aren't.

</details>

---

**Q7. What does native Kubernetes Service-based Canary lack compared to a tool like Argo Rollouts?**

- A) The ability to route traffic to more than one version at all
- B) Precise traffic percentages, automated analysis, and automatic rollback
- C) Support for more than 2 replicas
- D) The ability to use labels

<details>
<summary>Answer</summary>

**B** — Native Services can route to multiple versions, but everything about *when* and *how much* traffic shifts, and whether to roll back, is manual with plain Kubernetes objects.
Trap: A overstates the limitation — basic multi-version routing is exactly what this demo already achieved natively.

</details>

---

**Q8. In a Service's `ports` block, what happens if `targetPort` doesn't match the port the container actually listens on?**

- A) Kubernetes rejects the Service as invalid
- B) Requests silently fail — no apply-time error, since it's only a runtime mismatch
- C) Kubernetes automatically detects and corrects the correct port
- D) The Service falls back to using `port` as the target too

<details>
<summary>Answer</summary>

**B** — There's nothing invalid about the YAML itself — a `targetPort` is just a number Kubernetes doesn't verify against what's actually listening inside the container, so a mismatch only shows up as a runtime failure (a hang or connection-refuse), not a rejected `apply`.
Trap: C imagines automatic detection that doesn't exist — Kubernetes has no visibility into what a container is actually listening on unless a probe explicitly checks it.

</details>

---

**Q9. Why does Canary's Service selector deliberately omit the `track` label, when Blue-Green's selector includes `version`?**

- A) It's a mistake in the YAML that happens to work anyway
- B) Omitting `track` makes the selector match both stable and canary Pods at once, which is the entire mechanism that enables traffic splitting
- C) `track` isn't a valid label key
- D) The Service type determines whether `track` is needed

<details>
<summary>Answer</summary>

**B** — Blue-Green needs the selector to match exactly one version at a time, so it includes the differentiating label; Canary needs the selector to match both at once, so it deliberately leaves that label out. Same mechanism, opposite selector shape, on purpose.
Trap: A dismisses a deliberate design choice as an accident — the omission is exactly what makes Canary's traffic-splitting possible.

</details>

---

**Q10. Why does editing a Service's selector work instantly with no error, when the same kind of edit on a Deployment's selector is rejected outright?**

- A) Services don't validate YAML the way Deployments do
- B) A Service's selector has no ownership relationship to protect, unlike a Deployment's, which is tied to its ReplicaSet chain
- C) It can't — both are equally immutable
- D) Only NodePort-type Services allow selector edits

<details>
<summary>Answer</summary>

**B** — Deployment selector immutability exists specifically to protect the Deployment→ReplicaSet→Pod ownership chain; a Service has no such structure to protect, so Kubernetes places no such restriction on it.
Trap: C assumes symmetry between two mechanisms that are actually deliberately different — this demo's entire Blue-Green pattern depends on that difference existing.

</details>

Score guide:
| Score | Action |
|---|---|
| 9-10/10 | Import Anki cards, move to next Demo |
| 7-8/10 | Review the wrong answer(s), then proceed |
| 6/10 | Re-read the relevant section, retry those questions |
| Below 6/10 | Re-read the full demo and redo the walkthrough before proceeding |
