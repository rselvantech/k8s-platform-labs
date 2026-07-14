# Quiz — 01-core-concepts/02-namespaces: Namespaces

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. A pod in namespace `team-b` tries to reach a Service in `team-a` using only the short name. What happens?**

- A) It resolves normally — DNS is cluster-wide
- B) It fails with NXDOMAIN — short names only resolve within the same namespace
- C) It resolves but the connection is blocked by RBAC
- D) It works only if both namespaces have the same labels

<details>
<summary>Answer</summary>

**B** — DNS names are scoped to the namespace they're created in by default; the short form only resolves within the same namespace.
Trap: A tempts you to assume DNS is cluster-wide by default — it isn't. C confuses RBAC (an authorization boundary) with DNS resolution (a naming boundary) — unrelated mechanisms. D invents a labels-based DNS rule that doesn't exist.

</details>

---

**Q2. Which of these is a cluster-scoped (non-namespaced) object?**

- A) Deployment
- B) ConfigMap
- C) ClusterRole
- D) Service

<details>
<summary>Answer</summary>

**C** — ClusterRole exists at the cluster level, not inside any namespace.
Trap: A, B, and D are all namespaced objects — this tests whether you've actually memorized the split, not guessed from the name.

</details>

---

**Q3. A ResourceQuota sets `pods: "0"` in a namespace. You then create a Deployment there. What do you see?**

- A) The apply command itself fails immediately
- B) The Deployment is created but no Pods are ever created, visible in ReplicaSet events
- C) The Deployment silently redirects to the default namespace
- D) Kubernetes automatically raises the quota

<details>
<summary>Answer</summary>

**B** — The Deployment object is valid and gets created; the quota rejection happens one level down when the ReplicaSet controller tries to create Pods.
Trap: A is wrong because the YAML is valid at apply time — the failure is downstream. C and D describe behaviors Kubernetes doesn't have.

</details>

---

**Q4. What is required to reach a Service from a different namespace?**

- A) Nothing extra — namespaces don't affect DNS
- B) At minimum `<service>.<namespace>`
- C) A NetworkPolicy explicitly allowing it
- D) The full pod IP address

<details>
<summary>Answer</summary>

**B** — Crossing a namespace boundary requires at least `<service>.<namespace>`, resolved via the pod's DNS search-domain expansion.
Trap: C confuses network-layer isolation with DNS naming — no NetworkPolicy is needed by default for cross-namespace traffic. D is unnecessarily specific; DNS names, not raw IPs, are the normal mechanism.

</details>

---

**Q5. What happens when you delete a namespace that contains 10 Pods and 3 Deployments?**

- A) Only the namespace object is removed; the Pods and Deployments remain
- B) You're prompted to delete each object individually first
- C) Everything inside the namespace is deleted too — deletion cascades
- D) The Pods survive but the Deployments are deleted

<details>
<summary>Answer</summary>

**C** — Namespace deletion cascades completely; there is no selective or partial delete.
Trap: A describes the opposite of real behavior. D invents an asymmetric rule that doesn't exist.

</details>

---

**Q6. Why can two Deployments both be named "nginx" without any conflict?**

- A) Kubernetes automatically renames the second one
- B) Object names are unique per-namespace, not cluster-wide
- C) Deployment names aren't required to be unique at all
- D) They must be in the same namespace to share a name

<details>
<summary>Answer</summary>

**B** — Names only need to be unique within a namespace, giving each team naming freedom without collisions.
Trap: D states the exact opposite of the truth — same-namespace reuse is what's forbidden, not cross-namespace.

</details>

---

**Q7. A namespace has been `Terminating` for 20 minutes. What should you check first?**

- A) Restart the cluster
- B) Check for a finalizer blocking deletion via `kubectl describe namespace`
- C) Delete and recreate the namespace with the same name
- D) This is always expected — no action needed

<details>
<summary>Answer</summary>

**B** — A stuck deletion almost always traces back to a finalizer on a resource inside the namespace that hasn't cleared.
Trap: C won't work — you can't create a namespace with the same name while the old one is still Terminating. D dismisses a real, diagnosable problem as normal.

</details>

---

**Q8. Does `kubectl config set-context --current --namespace=<ns>` affect other users?**

- A) Yes — it changes the cluster's default namespace for everyone
- B) No — it's a local kubeconfig change only
- C) Yes, but only for users in the same RBAC group
- D) No, but it does change the default for future namespaces created

<details>
<summary>Answer</summary>

**B** — This command only edits your local `~/.kube/config`; it has no effect on the cluster or any other user's client.
Trap: A and C both wrongly assume this is a server-side setting — it's entirely client-side.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
