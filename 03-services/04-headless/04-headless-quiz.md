# Quiz — 03-services/04-headless: Headless Service

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. What's the actual difference between `clusterIP: None` and `clusterIP: ""`?**

- A) They're identical — both mean headless
- B) `None` means headless; `""` means auto-assign a normal ClusterIP
- C) `""` means headless; `None` means auto-assign
- D) Neither is valid YAML

<details>
<summary>Answer</summary>

**B** — Only the literal string `None` triggers headless behavior. An empty string is functionally the same as omitting the field entirely.
Trap: C reverses the actual mapping — a classic exam-day mix-up worth memorizing precisely.

</details>

---

**Q2. Does a headless Service use kube-proxy?**

- A) Yes, in a special headless-only mode
- B) No — no virtual IP, no proxy rules at all; DNS returns pod IPs directly
- C) Only for NodePort-type headless Services
- D) Only if selector is set

<details>
<summary>Answer</summary>

**B** — Headless Services skip the virtual-IP/kube-proxy layer entirely — that's the entire point of the pattern.
Trap: A invents a special kube-proxy mode that doesn't exist — headless simply removes kube-proxy from the picture.

</details>

---

**Q3. Does StatefulSet give its pods a stable IP address?**

- A) Yes, that's its main feature
- B) No — pod IPs stay ephemeral; it gives a stable name instead, and the headless Service keeps DNS current as the IP changes
- C) Only the first pod (index 0) gets a stable IP
- D) Only with a LoadBalancer-type headless Service

<details>
<summary>Answer</summary>

**B** — This is a very common misconception. Pod IP ephemerality (from `01-core-concepts`) applies regardless of controller type — StatefulSet's actual contribution is a stable, ordered name.
Trap: A states the exact misconception this demo's Concepts section explicitly corrects.

</details>

---

**Q4. A StatefulSet's `spec.serviceName` points at a Service name that doesn't exist. What happens on `kubectl apply`?**

- A) The apply is rejected with a validation error
- B) It's accepted; the StatefulSet and its pods create successfully, but per-pod DNS silently fails
- C) Kubernetes automatically creates the missing Service
- D) The StatefulSet stays in Pending forever

<details>
<summary>Answer</summary>

**B** — There's no validation linking `serviceName` to an actual existing Service — this is a genuinely silent failure mode, invisible in `kubectl get` output.
Trap: C imagines auto-remediation that doesn't exist — nothing creates the missing Service for you.

</details>

---

**Q5. What is the correct per-pod DNS format for a StatefulSet pod behind a headless Service?**

- A) `<service-name>.<pod-name>.<namespace>.svc.cluster.local`
- B) `<pod-name>.<service-name>.<namespace>.svc.cluster.local`
- C) `<pod-name>.<namespace>.<service-name>.svc.cluster.local`
- D) `<namespace>.<pod-name>.<service-name>.svc.cluster.local`

<details>
<summary>Answer</summary>

**B** — Pod name comes first, then the headless Service name, then namespace, then the standard suffix.
Trap: A swaps the first two components — an easy typo to make and a common exam trap.

</details>

---

**Q6. Does `kubectl create statefulset` exist as an imperative command?**

- A) Yes, identical syntax to `kubectl create deployment`
- B) No — StatefulSets have no imperative creation subcommand at all
- C) Yes, but only for headless-linked StatefulSets
- D) Only in `kubectl` versions before 1.20

<details>
<summary>Answer</summary>

**B** — Unlike Deployments, Services, and Jobs, there's no `kubectl create statefulset` — YAML is the only path.
Trap: A assumes StatefulSet follows the same imperative pattern as Deployment, which it doesn't.

</details>

---

**Q7. Can a headless Service be used with a regular Deployment instead of a StatefulSet?**

- A) No, headless only works with StatefulSets
- B) Yes — DNS still returns all pod IPs, but per-pod addressing isn't meaningful since Deployment pod names are random
- C) Yes, and it behaves identically to the StatefulSet case
- D) Only if the Deployment has exactly 1 replica

<details>
<summary>Answer</summary>

**B** — The headless mechanism itself doesn't require a StatefulSet, but per-pod DNS names only make sense when the pod names themselves are stable — which only a StatefulSet provides.
Trap: C overstates the similarity — the DNS-returns-all-IPs behavior is the same, but individual pod addressing isn't usefully available without stable names.

</details>

---

**Q8. Why does StatefulSet need a headless Service specifically, instead of a regular ClusterIP Service?**

- A) Regular ClusterIP Services don't support StatefulSets at all
- B) A regular ClusterIP would load-balance across all pods behind one IP — the opposite of addressing one specific pod directly
- C) Headless Services are required for any Service with more than 1 replica
- D) There's no real reason, it's just convention

<details>
<summary>Answer</summary>

**B** — The whole point of per-pod addressing is bypassing load-balancing to reach a specific pod — a regular ClusterIP's entire purpose (routing to any matching pod) works directly against that goal.
Trap: A is factually wrong and D dismisses a real architectural reason as arbitrary convention.

</details>

---

**Q9. What problem does `publishNotReadyAddresses: true` solve on a headless Service?**

- A) It makes unready pods pass their readiness check faster
- B) It publishes a pod's DNS record before it's Ready, enabling peer discovery during startup
- C) It removes the readiness requirement permanently for all future pods
- D) It's required for any StatefulSet with more than 1 replica

<details>
<summary>Answer</summary>

**B** — Without it, DNS only publishes Ready pods, which creates a chicken-and-egg problem for clustered apps that need to find their peers *before* any of them are individually ready.
Trap: A misreads this as affecting the readiness check itself — it only affects DNS publication, never touches the actual readiness probe or its result.

</details>

Score guide:
| Score | Action |
|---|---|
| 9/9 | Import Anki cards, move to next Demo |
| 8/9 | Review the wrong answer, then proceed |
| 6-7/9 | Re-read the relevant section, retry those questions |
| Below 6/9 | Re-read the full demo and redo the walkthrough before proceeding |
