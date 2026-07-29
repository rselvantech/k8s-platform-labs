# Quiz — 03-services/06-loadbalancer-traffic-policies: LoadBalancer and Traffic Policies

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to the next chapter.

**Q1. Does `minikube tunnel` provision a real cloud load balancer?**

- A) Yes, identical to a cloud provider's implementation
- B) No — it simulates one via a network route on your own machine
- C) Only on cloud-hosted minikube instances
- D) Only for NodePort Services, not LoadBalancer

<details>
<summary>Answer</summary>

**B** — It's a genuine, working `EXTERNAL-IP` for local development, but the mechanism is entirely local — nothing like it exists in a real cloud deployment.
Trap: A overstates the similarity; the *result* (a working EXTERNAL-IP) is real, but the *mechanism* is completely different from a cloud load balancer.

</details>

---

**Q2. Why does `externalTrafficPolicy: Cluster` (the default) cause a pod to see a node's IP instead of the real client's?**

- A) Kubernetes hides client IPs for privacy by default
- B) Cross-node routing requires SNAT so return traffic can find its way back
- C) It only happens with LoadBalancer Services, not NodePort
- D) DNS resolution replaces the client IP

<details>
<summary>Answer</summary>

**B** — SNAT is what makes routing to a pod on a different node than the one that received the traffic actually work — the trade-off is losing the original source IP.
Trap: C is factually wrong — this demo demonstrates the exact same SNAT behavior on a plain NodePort Service, no LoadBalancer required.

</details>

---

**Q3. What happens with `externalTrafficPolicy: Local` when a node has no local matching pod?**

- A) Traffic is forwarded to a node that does have one
- B) Traffic is dropped — no cross-node forwarding happens under `Local`
- C) The Service automatically switches to `Cluster` policy for that node
- D) The request succeeds but with a warning header

<details>
<summary>Answer</summary>

**B** — This is `Local` policy's real trade-off — no cross-node hop occurs at all, so a node with nothing local to serve the request just drops it.
Trap: A describes `Cluster` policy's behavior, the exact thing `Local` is specifically designed not to do.

</details>

---

**Q4. What is `healthCheckNodePort` for?**

- A) A port you configure manually to check pod health
- B) Auto-allocated with `externalTrafficPolicy: Local`, letting an external load balancer avoid nodes that would drop traffic
- C) A liveness probe endpoint for the Service object itself
- D) Only relevant for ClusterIP Services

<details>
<summary>Answer</summary>

**B** — It's automatically allocated, not something you set — a real external load balancer polls it to learn which nodes currently have local endpoints under `Local` policy.
Trap: A assumes manual configuration is required; it's auto-allocated the moment `Local` is set.

</details>

---

**Q5. What does `sessionAffinity: ClientIP` change about how a Service routes requests?**

- A) It encrypts traffic to that client
- B) It pins a given source IP to the same pod for a configurable window, instead of independently load-balancing each request
- C) It only affects DNS resolution, not actual routing
- D) It requires an Ingress controller to function

<details>
<summary>Answer</summary>

**B** — A direct contrast to every prior demo in this chapter's round-robin behavior — same client, same pod, until the timeout elapses.
Trap: D confuses this with cookie/header-based affinity, which genuinely does need an Ingress controller — plain `sessionAffinity: ClientIP` works on any Service.

</details>

---

**Q6. What's the key difference between `externalTrafficPolicy` and `internalTrafficPolicy`?**

- A) They're identical fields with different names
- B) `externalTrafficPolicy` controls source-IP preservation for traffic from outside the cluster; `internalTrafficPolicy` reduces cross-node hops for internal ClusterIP traffic, with no SNAT concern
- C) `internalTrafficPolicy` only applies to headless Services
- D) `externalTrafficPolicy` is deprecated in favor of `internalTrafficPolicy`

<details>
<summary>Answer</summary>

**B** — Different problems entirely: one is about whether the real client identity survives (external traffic was SNAT'd), the other is purely about network efficiency (internal traffic was never SNAT'd to begin with).
Trap: A treats them as redundant, missing that they solve genuinely different problems for genuinely different traffic sources.

</details>

---

**Q7. When does a Service need every port entry to have a `name`?**

- A) Always, even for a single port
- B) Only once `spec.ports[]` has more than one entry
- C) Only for LoadBalancer-type Services
- D) Only when `externalTrafficPolicy: Local` is set

<details>
<summary>Answer</summary>

**B** — Single-port Services (everything built earlier in this chapter) never needed this — it activates specifically once a second port is added.
Trap: A overstates the rule — a single unnamed port is completely valid, as every prior demo in this series has shown.

</details>

---

**Q8. A `NodePort` Service with `externalTrafficPolicy: Local` times out from every single node, not just some. What's the most likely actual cause?**

- A) `externalTrafficPolicy: Local` is fundamentally broken
- B) The selector likely matches zero pods anywhere — check `kubectl get endpointslices` before blaming the traffic policy
- C) `Local` policy requires at least 5 nodes to function
- D) The NodePort range is misconfigured

<details>
<summary>Answer</summary>

**B** — `Local` policy dropping traffic from *some* nodes (with no local pod) is expected; timing out from *every* node points at a more fundamental problem — no Endpoints exist for this Service at all, the same class of mistake as a selector typo.
Trap: A assumes the well-documented, intentional trade-off of `Local` policy is itself a bug — the actual symptom pattern (all nodes, not just some) rules that explanation out.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, chapter complete |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
